#include <stdio.h>
#include <cuda_runtime.h>
#include <cuda.h>

#include <quda_internal.h>
#include <gauge_field.h>
#include <clover_field.h>
#include <llfat_quda.h>
#include <read_gauge.h>
#include <force_common.h>
#include <dslash_quda.h>
#include <index_helper.cuh>
#include <gauge_field_order.h>

#define MIN_COEFF 1e-7
#define BLOCK_DIM 64

namespace quda {

#ifdef GPU_FATLINK

  namespace fatlink {
    // Are we processor 0 in time?
    __constant__ bool Pt0;

    // Are we processor Nt-1 in time?
    __constant__ bool PtNm1;
  }

  template <int recon, bool temporal=true>
  __device__ inline int reconstruct_sign(int dir, int y[], const int border[], int X[]) {
    using namespace fatlink;
    int sign = 1;
    switch (dir) {
    case XUP:
      if ( ((y[3] - border[3]) & 1) != 0) sign = -1;
      break;
    case YUP:
      if ( ((y[0]-border[0]+y[3]-border[3]) & 1) != 0) sign = -1;
      break;
    case ZUP:
      if ( ((y[0]-border[0]+y[1]-border[1]+y[3]-border[3]) & 1) != 0) sign = -1;
      break;
    case TUP:
      if ( temporal && ( ((y[3]-border[3]) == X[3]-1 && PtNm1) || ((y[3]-border[3]) == -1 && Pt0) ) ) sign = -1;
      break;
    }
    return sign;
  }

  template<>  __device__ inline int reconstruct_sign<18,true>(int dir, int y[], const int border[], int X[]) { return 1; }
  template<>  __device__ inline int reconstruct_sign<18,false>(int dir, int y[], const int border[], int X[]) { return 1; }


  template <typename Float, typename Link, typename Gauge>
  struct LinkArg {
    unsigned int threads;

    int X[4];
    int E[4];
    int border[4];

    /** This keeps track of any parity changes that result in using a
    radius of 1 for the extended border (the staple computations use
    such an extension, and if an odd number of dimensions are
    partitioned then we have to correct for this when computing the local index */
    int odd_bit;

    Gauge u;
    Link link;
    Float coeff;

    LinkArg(Link link, Gauge u, Float coeff, const GaugeField &link_meta, const GaugeField &u_meta)
      : threads(link_meta.VolumeCB()), link(link), u(u), coeff(coeff),
	odd_bit( (commDimPartitioned(0)+commDimPartitioned(1) +
		  commDimPartitioned(2)+commDimPartitioned(3))%2 ) {
	for (int d=0; d<4; d++) {
	  X[d] = link_meta.X()[d];
	  E[d] = u_meta.X()[d];
	  border[d] = (E[d] - X[d]) / 2;
	}
    }
  };

  template <typename Float, int recon, typename Arg>
  __global__ void computeLongLink(Arg arg) {

    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int parity = blockIdx.y*blockDim.y + threadIdx.y;
    int dir = blockIdx.z*blockDim.z + threadIdx.z;
    if (idx >= arg.threads) return;
    if (dir >= 4) return;

    int y[4], x[4] = {0, 0, 0, 0}, dx[4] = {0, 0, 0, 0};
    getCoords(x, idx, arg.X, parity);
    for (int d=0; d<4; d++) x[d] += arg.border[d];

    typedef Matrix<complex<Float>,3> Link;
    Link a, b, c, f;

    arg.u.load((Float*)a.data, linkIndex(x,arg.E), dir, parity);
    int sign_a = reconstruct_sign<recon,false>(dir, x, arg.border, arg.X);
    for (int i=0; i<3; i++) a(2,i) *= static_cast<Float>(sign_a);

    dx[dir]++;
    arg.u.load((Float*)b.data, linkIndexShift(y, x, dx, arg.E), dir, 1-parity);
    int sign_b = reconstruct_sign<recon,false>(dir, y, arg.border, arg.X);
    for (int i=0; i<3; i++) b(2,i) *= static_cast<Float>(sign_a);

    dx[dir]++;
    arg.u.load((Float*)c.data, linkIndexShift(y, x, dx, arg.E), dir, parity);
    dx[dir]-=2;
    int sign_c = reconstruct_sign<recon,false>(dir, y, arg.border, arg.X);
    for (int i=0; i<3; i++) c(2,i) *= static_cast<Float>(sign_a);

    f = arg.coeff * a * b * c;

    arg.link.save((Float*)f.data, idx, dir, parity);
    return;
  }

  template <typename Float, int recon, typename Arg>
  class LongLink : public TunableVectorYZ {
    Arg &arg;
    const GaugeField &meta;
    unsigned int minThreads() const { return arg.threads; }
    bool tuneGridDim() const { return false; }

  public:
    LongLink(Arg &arg, const GaugeField &meta) : TunableVectorYZ(2,4), arg(arg), meta(meta) {}
    virtual ~LongLink() {}

    void apply(const cudaStream_t &stream) {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      computeLongLink<Float,recon><<<tp.grid,tp.block>>>(arg);
    }

    TuneKey tuneKey() const {
      std::stringstream aux;
      aux << "threads=" << arg.threads << ",prec="  << sizeof(Float);
      return TuneKey(meta.VolString(), typeid(*this).name(), aux.str().c_str());
    }

    long long flops() const { return 2*4*arg.threads*198; }
    long long bytes() const { return 2*4*arg.threads*(3*arg.u.Bytes()+arg.link.Bytes()); }
  };

  void computeLongLink(GaugeField &lng, const GaugeField &u, double coeff)
  {
    if (u.Precision() == QUDA_DOUBLE_PRECISION) {
      typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef LinkArg<double,L,L> Arg;
	Arg arg(L(lng), L(u), coeff, lng, u);
	LongLink<double,18,Arg> longLink(arg,lng);
	longLink.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_12>::type G;
	typedef LinkArg<double,L,G> Arg;
	Arg arg(L(lng), G(u), coeff, lng, u);
	LongLink<double,12,Arg> longLink(arg,lng);
	longLink.apply(0);
      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else if (u.Precision() == QUDA_SINGLE_PRECISION) {
      typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef LinkArg<float,L,L> Arg;
	Arg arg(L(lng), L(u), coeff, lng, u) ;
	LongLink<float,18,Arg> longLink(arg,lng);
	longLink.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_12>::type G;
	typedef LinkArg<float,L,G> Arg;
	Arg arg(L(lng), G(u), coeff, lng, u);
	LongLink<float,12,Arg> longLink(arg,lng);
	longLink.apply(0);

      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else {
      errorQuda("Unsupported precision %d\n", u.Precision());
    }
    return;
  }

  template <typename Float, int recon, typename Arg>
  __global__ void computeOneLink(Arg arg)  {

    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int parity = blockIdx.y * blockDim.y + threadIdx.y;
    int dir =  blockIdx.z * blockDim.z + threadIdx.z;
    if (idx >= arg.threads) return;
    if (dir >= 4) return;

    int x[4] = {0, 0, 0, 0};
    getCoords(x, idx, arg.X, parity);
    for (int d=0; d<4; d++) x[d] += arg.border[d];

    typedef Matrix<complex<Float>,3> Link;
    Link a, fat;

    for (int dir=0; dir < 4; dir++) {
      arg.u.load((Float*)a.data, linkIndex(x,arg.E), dir, parity);
      int sign_a = reconstruct_sign<recon,false>(dir, x, arg.border, arg.X);
      for (int i=0; i<3; i++) a(2,i) *= static_cast<Float>(sign_a);

      fat = arg.coeff*a;

      arg.link.save((Float*)fat.data, idx, dir, parity);
    }
    return;
  }

  template <typename Float, int recon, typename Arg>
  class OneLink : public TunableVectorYZ {
    Arg &arg;
    const GaugeField &meta;
    unsigned int minThreads() const { return arg.threads; }
    bool tuneGridDim() const { return false; }

  public:
    OneLink(Arg &arg, const GaugeField &meta) : TunableVectorYZ(2,4), arg(arg), meta(meta) {}
    virtual ~OneLink() {}

    void apply(const cudaStream_t &stream) {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      computeOneLink<Float,recon><<<tp.grid,tp.block>>>(arg);
    }

    TuneKey tuneKey() const {
      std::stringstream aux;
      aux << "threads=" << arg.threads << ",prec="  << sizeof(Float);
      return TuneKey(meta.VolString(), typeid(*this).name(), aux.str().c_str());
    }

    long long flops() const { return 2*4*arg.threads*18; }
    long long bytes() const { return 2*4*arg.threads*(arg.u.Bytes()+arg.link.Bytes()); }
  };

  void computeOneLink(GaugeField &fat, const GaugeField &u, double coeff)
  {
    if (u.Precision() == QUDA_DOUBLE_PRECISION) {
      typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef LinkArg<double,L,L> Arg;
	Arg arg(L(fat), L(u), coeff, fat, u);
	OneLink<double,18,Arg> oneLink(arg,fat);
	oneLink.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_12>::type G;
	typedef LinkArg<double,L,G> Arg;
	Arg arg(L(fat), G(u), coeff, fat, u);
	OneLink<double,12,Arg> oneLink(arg,fat);
	oneLink.apply(0);
      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else if (u.Precision() == QUDA_SINGLE_PRECISION) {
      typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef LinkArg<float,L,L> Arg;
	Arg arg(L(fat), L(u), coeff, fat, u);
	OneLink<float,18,Arg> oneLink(arg,fat);
	oneLink.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_12>::type G;
	typedef LinkArg<float,L,G> Arg;
	Arg arg(L(fat), G(u), coeff, fat, u);
	OneLink<float,12,Arg> oneLink(arg,fat);
	oneLink.apply(0);
      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else {
      errorQuda("Unsupported precision %d\n", u.Precision());
    }
    return;
  }

  template <typename Float, typename Fat, typename Staple, typename Mulink, typename Gauge>
  struct StapleArg {
    unsigned int threads;

    int X[4];
    int E[4];
    int border[4];

    int inner_X[4];
    int inner_border[4];

    /** This keeps track of any parity changes that result in using a
    radius of 1 for the extended border (the staple computations use
    such an extension, and if an odd number of dimensions are
    partitioned then we have to correct for this when computing the local index */
    int odd_bit;

    Gauge u;
    Fat fat;
    Staple staple;
    Mulink mulink;
    Float coeff;

    StapleArg(Fat fat, Staple staple, Mulink mulink, Gauge u, Float coeff,
	      const GaugeField &fat_meta, const GaugeField &u_meta)
      : threads(1), fat(fat), staple(staple), mulink(mulink), u(u), coeff(coeff),
	odd_bit( (commDimPartitioned(0)+commDimPartitioned(1) +
		  commDimPartitioned(2)+commDimPartitioned(3))%2 ) {
	for (int d=0; d<4; d++) {
	  X[d] = (fat_meta.X()[d] + u_meta.X()[d]) / 2;
	  E[d] = u_meta.X()[d];
	  border[d] = (E[d] - X[d]) / 2;
	  threads *= X[d];

	  inner_X[d] = fat_meta.X()[d];
	  inner_border[d] = (E[d] - inner_X[d]) / 2;
	}
	threads /= 2; // account for parity in y dimension
    }
  };

  template<typename Float, int mu, int nu, int recon, int recon_mu, typename Arg>
  __device__ inline void computeStaple(Matrix<complex<Float>,3> &staple, Arg &arg, int x[], int parity) {
    Matrix<complex<Float>,3> a, b, c;
    int y[4], dx[4] = {0, 0, 0, 0};

    /* Computes the upper staple :
     *                 mu (B)
     *               +-------+
     *       nu	   |	   |
     *	     (A)   |	   |(C)
     *		   X	   X
     */
    {
      /* load matrix A*/
      arg.u.load((Float*)a.data, linkIndex(x, arg.E), nu, parity);
      int sign_a = reconstruct_sign<recon,false>(nu, x, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) a(2,i) *= static_cast<Float>(sign_a);

      /* load matrix B*/
      dx[nu]++;
      arg.mulink.load((Float*)b.data, linkIndexShift(y, x, dx, arg.E), mu, 1-parity);
      int sign_b = reconstruct_sign<recon_mu,false>(mu, y, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) b(2,i) *= static_cast<Float>(sign_b);
      dx[nu]--;

      /* load matrix C*/
      dx[mu]++;
      arg.u.load((Float*)c.data, linkIndexShift(y, x, dx, arg.E), nu, 1-parity);
      int sign_c = reconstruct_sign<recon,false>(nu, y, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) c(2,i) *= static_cast<Float>(sign_c);
      dx[mu]--;

      staple = a * b * conj(c);
    }

    /* Computes the lower staple :
     *                 X       X
     *           nu    |       |
     *	         (A)   |       | (C)
     *		       +-------+
     *                  mu (B)
     */
    {
      /* load matrix A*/
      dx[nu]--;
      arg.u.load((Float*)a.data, linkIndexShift(y, x, dx, arg.E), nu, 1-parity);
      int sign_a = reconstruct_sign<recon,false>(nu, y, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) a(2,i) *= static_cast<Float>(sign_a);

      /* load matrix B*/
      arg.mulink.load((Float*)b.data, linkIndexShift(y, x, dx, arg.E), mu, 1-parity);
      int sign_b = reconstruct_sign<recon_mu,false>(mu, y, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) b(2,i) *= static_cast<Float>(sign_b);

      /* load matrix C*/
      dx[mu]++;
      arg.u.load((Float*)c.data, linkIndexShift(y, x, dx, arg.E), nu, parity);
      int sign_c = reconstruct_sign<recon,false>(nu, y, arg.inner_border, arg.inner_X);
      for (int i=0; i<3; i++) c(2,i) *= static_cast<Float>(sign_c);
      dx[mu]--;
      dx[nu]++;

      staple = staple + conj(a)*b*c;
    }
  }

  template<typename Float, int recon, int recon_mu, bool save_staple, typename Arg>
  __global__ void computeStaple(Arg arg, int nu, int dir1, int dir2)
  {
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int parity = blockIdx.y*blockDim.y + threadIdx.y;
    int mu = blockIdx.z*blockDim.z + threadIdx.z;
    if (idx >= arg.threads) return;
    if (mu == nu || mu == dir1 || mu == dir2 || mu >= 4) return;

    int y[4], x[4] = {0, 0, 0, 0}, dx[4] = {0, 0, 0, 0};
    getCoords(x, idx, arg.X, (parity+arg.odd_bit)%2);
    for (int d=0; d<4; d++) x[d] += arg.border[d];

    Matrix<complex<Float>,3> staple, fat;
    switch(mu) {
    case 0:
      switch(nu) {
      case 1: computeStaple<Float,0,1,recon,recon_mu>(staple, arg, x, parity); break;
      case 2: computeStaple<Float,0,2,recon,recon_mu>(staple, arg, x, parity); break;
      case 3: computeStaple<Float,0,3,recon,recon_mu>(staple, arg, x, parity); break;
      } break;
    case 1:
      switch(nu) {
      case 0: computeStaple<Float,1,0,recon,recon_mu>(staple, arg, x, parity); break;
      case 2: computeStaple<Float,1,2,recon,recon_mu>(staple, arg, x, parity); break;
      case 3: computeStaple<Float,1,3,recon,recon_mu>(staple, arg, x, parity); break;
      } break;
    case 2:
      switch(nu) {
      case 0: computeStaple<Float,2,0,recon,recon_mu>(staple, arg, x, parity); break;
      case 1: computeStaple<Float,2,1,recon,recon_mu>(staple, arg, x, parity); break;
      case 3: computeStaple<Float,2,3,recon,recon_mu>(staple, arg, x, parity); break;
      } break;
    case 3:
      switch(nu) {
      case 0: computeStaple<Float,3,0,recon,recon_mu>(staple, arg, x, parity); break;
      case 1: computeStaple<Float,3,1,recon,recon_mu>(staple, arg, x, parity); break;
      case 2: computeStaple<Float,3,2,recon,recon_mu>(staple, arg, x, parity); break;
      } break;
    }

    // exclude inner halo
    if ( !(x[0] < arg.inner_border[0] || x[0] >= arg.inner_X[0] + arg.inner_border[0] ||
	   x[1] < arg.inner_border[1] || x[1] >= arg.inner_X[1] + arg.inner_border[1] ||
	   x[2] < arg.inner_border[2] || x[2] >= arg.inner_X[2] + arg.inner_border[2] ||
	   x[3] < arg.inner_border[3] || x[3] >= arg.inner_X[3] + arg.inner_border[3]) ) {
      // convert to inner coords
      int inner_x[] = {x[0]-arg.inner_border[0], x[1]-arg.inner_border[1], x[2]-arg.inner_border[2], x[3]-arg.inner_border[3]};
      arg.fat.load((Float*)fat.data, linkIndex(inner_x, arg.inner_X), mu, parity);
      fat += arg.coeff * staple;
      arg.fat.save((Float*)fat.data, linkIndex(inner_x, arg.inner_X), mu, parity);
    }

    if (save_staple) arg.staple.save((Float*)staple.data, linkIndex(x, arg.E), mu, parity);
    return;
  }

  template <typename Float, int recon, int recon_mu, typename Arg>
  class Staple : public TunableVectorYZ {
    Arg &arg;
    const GaugeField &meta;
    unsigned int minThreads() const { return arg.threads; }
    bool tuneGridDim() const { return false; }
    int nu;
    int dir1;
    int dir2;
    bool save_staple;

  public:
    Staple(Arg &arg, int nu, int dir1, int dir2, bool save_staple, const GaugeField &meta)
      : TunableVectorYZ(2,4), nu(nu), dir1(dir1), dir2(dir2), save_staple(save_staple),
	arg(arg), meta(meta) {}
    virtual ~Staple() {}

    void apply(const cudaStream_t &stream) {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      if (save_staple)
	computeStaple<Float,recon,recon_mu,true><<<tp.grid,tp.block>>>(arg, nu, dir1, dir2);
      else
	computeStaple<Float,recon,recon_mu,false><<<tp.grid,tp.block>>>(arg, nu, dir1, dir2);
    }

    TuneKey tuneKey() const {
      std::stringstream aux;
      aux << "threads=" << arg.threads << ",prec="  << sizeof(Float);
      aux << ",nu=" << nu << ",dir1=" << dir1 << ",dir2=" << dir2 << "save_staple=" << save_staple;
      return TuneKey(meta.VolString(), typeid(*this).name(), aux.str().c_str());
    }

    void preTune() { arg.fat.save(); arg.staple.save(); }
    void postTune() { arg.fat.load(); arg.staple.load(); }

    // mu != nu 3 -> loops = 3
    // mu != nu != rho 2 -> loops = 2
    // mu != nu != rho != sig 1 -> loops = 1
    long long flops() const {
      int loops = 3 - ( (dir1 > -1) ? 1 : 0 ) - ( (dir2 > -1) ? 1 : 0 );
      return 2*loops*arg.threads*( 4*198 + 18 + 36 );
    }
    long long bytes() const {
      int loops = 3 - ( (dir1 > -1) ? 1 : 0 ) - ( (dir2 > -1) ? 1 : 0 );
      return 2*loops*(2*meta.VolumeCB()*arg.fat.Bytes() + // fat load/store is only done on interior
		      arg.threads*(4*arg.u.Bytes() + 2*arg.mulink.Bytes() + save_staple ? arg.staple.Bytes() : 0));
    }
  };

  // Compute the staple field for direction nu,excluding the directions dir1 and dir2.
  void computeStaple(GaugeField &fat, GaugeField &staple, const GaugeField &mulink, const GaugeField &u,
		     int nu, int dir1, int dir2, double coeff, bool save_staple) {

    if (u.Precision() == QUDA_DOUBLE_PRECISION) {
      typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef StapleArg<double,L,L,L,L> Arg;
	Arg arg(L(fat), L(staple), L(mulink), L(u), coeff, fat, u);
	Staple<double,18,18,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	stapler.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<double,QUDA_RECONSTRUCT_12>::type G;
	if (mulink.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	  typedef StapleArg<double,L,L,L,G> Arg;
	  Arg arg(L(fat), L(staple), L(mulink), G(u), coeff, fat, u);
	  Staple<double,12,18,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	  stapler.apply(0);
	} else if (mulink.Reconstruct() == QUDA_RECONSTRUCT_12) {
	  typedef StapleArg<double,L,L,G,G> Arg;
	  Arg arg(L(fat), L(staple), G(mulink), G(u), coeff, fat, u);
	  Staple<double,12,12,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	  stapler.apply(0);
	} else {
	  errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
	}
      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else if (u.Precision() == QUDA_SINGLE_PRECISION) {
      typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_NO>::type L;
      if (u.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef StapleArg<float,L,L,L,L> Arg;
	Arg arg(L(fat), L(staple), L(mulink), L(u), coeff, fat, u);
	Staple<float,18,18,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	stapler.apply(0);
      } else if (u.Reconstruct() == QUDA_RECONSTRUCT_12) {
	typedef typename gauge_mapper<float,QUDA_RECONSTRUCT_12>::type G;
	if (mulink.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	  typedef StapleArg<double,L,L,L,G> Arg;
	  Arg arg(L(fat), L(staple), L(mulink), G(u), coeff, fat, u);
	  Staple<float,12,18,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	  stapler.apply(0);
	} else if (mulink.Reconstruct() == QUDA_RECONSTRUCT_12) {
	  typedef StapleArg<double,L,L,G,G> Arg;
	  Arg arg(L(fat), L(staple), G(mulink), G(u), coeff, fat, u);
	  Staple<float,12,12,Arg> stapler(arg, nu, dir1, dir2, save_staple, fat);
	  stapler.apply(0);
	} else {
	  errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
	}
      } else {
	errorQuda("Reconstruct %d is not supported\n", u.Reconstruct());
      }
    } else {
      errorQuda("Unsupported precision %d\n", u.Precision());
    }
  }

#endif //GPU_FATLINK

  void fatLongKSLink(cudaGaugeField* fat, cudaGaugeField* lng,  const cudaGaugeField& u, const double *coeff)
  {

#ifdef GPU_FATLINK
    GaugeFieldParam gParam(u);
    gParam.reconstruct = QUDA_RECONSTRUCT_NO;
    gParam.setPrecision(gParam.precision);
    gParam.create = QUDA_NULL_FIELD_CREATE;
    cudaGaugeField staple(gParam);
    cudaGaugeField staple1(gParam);

    bool first_node_in_t = (commCoords(3) == 0);
    bool last_node_in_t = (commCoords(3) == commDim(3)-1);
    cudaMemcpyToSymbol(fatlink::Pt0, &(first_node_in_t), sizeof(bool));
    cudaMemcpyToSymbol(fatlink::PtNm1, &(last_node_in_t), sizeof(bool));

    if( ((fat->X()[0] % 2 != 0) || (fat->X()[1] % 2 != 0) || (fat->X()[2] % 2 != 0) || (fat->X()[3] % 2 != 0))
	&& (u.Reconstruct()  != QUDA_RECONSTRUCT_NO)){
      errorQuda("Reconstruct %d and odd dimensionsize is not supported by link fattening code (yet)\n",
		u.Reconstruct());
    }

    computeOneLink(*fat, u, coeff[0]-6.0*coeff[5]);

    // if this pointer is not NULL, compute the long link
    if (lng) computeLongLink(*lng, u, coeff[1]);

    // Check the coefficients. If all of the following are zero, return.
    if (fabs(coeff[2]) < MIN_COEFF && fabs(coeff[3]) < MIN_COEFF &&
	fabs(coeff[4]) < MIN_COEFF && fabs(coeff[5]) < MIN_COEFF) return;

    for (int nu = 0; nu < 4; nu++) {
      computeStaple(*fat, staple, u, u, nu, -1, -1, coeff[2], 1);

      if (coeff[5] != 0.0) computeStaple(*fat, staple, staple, u, nu, -1, -1, coeff[5], 0);

      for (int rho = 0; rho < 4; rho++) {
        if (rho != nu) {

          computeStaple(*fat, staple1, staple, u, rho, nu, -1, coeff[3], 1);

	  if (fabs(coeff[4]) > MIN_COEFF) {
	    for (int sig = 0; sig < 4; sig++) {
              if (sig != nu && sig != rho) {
                computeStaple(*fat, staple, staple1, u, sig, nu, rho, coeff[4], 0);
              }
	    } //sig
	  } // MIN_COEFF
	}
      } //rho
    } //nu

    cudaDeviceSynchronize();
    checkCudaError();
#else
    errorQuda("Fat-link computation not enabled");
#endif

    return;
  }

#undef BLOCK_DIM
#undef MIN_COEFF

} // namespace quda
