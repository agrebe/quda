#include <color_spinor_field.h>
#include <contract_quda.h>

#include <tunable_nd.h>
#include <tunable_reduction.h>
#include <instantiate.h>
#include <kernels/blas_3d.cuh>
#include <blas_3d.h>

namespace quda
{

  namespace blas3d
  {

    template <typename Float, int nColor> class copy3D : TunableKernel2D
    {
    protected:
      ColorSpinorField &y;
      ColorSpinorField &x;
      const int t_slice;
      const copy3dType type;

      unsigned int minThreads() const { return y.VolumeCB(); }

    public:
      copy3D(ColorSpinorField &y, ColorSpinorField &x, const int t_slice, const copy3dType type) :
        TunableKernel2D(y, y.SiteSubset()), y(y), x(x), t_slice(t_slice), type(type)
      {
        strcat(aux, type == COPY_TO_3D ? ",to_3d" : ",from_3d");
        apply(device::get_default_stream());
      }

      void apply(const qudaStream_t &stream)
      {
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        copy3dArg<Float, nColor> arg(y, x, t_slice);
        switch (type) {
        case COPY_TO_3D: launch<copyTo3d>(tp, stream, arg); break;
        case COPY_FROM_3D: launch<copyFrom3d>(tp, stream, arg); break;
        default: errorQuda("Unknown 3D copy type");
        }
      }

      long long bytes() const { return x.Bytes() + y.Bytes(); }
    };

    void copy(const int slice, const copy3dType type, ColorSpinorField &x, ColorSpinorField &y)
    {
      checkPrecision(x, y);

      // Check spins
      if (x.Nspin() != y.Nspin()) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

      // Check colors
      if (x.Ncolor() != y.Ncolor()) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());

      // Check orth dim
      if (x.X()[3] != 1) errorQuda("Unexpected dimensions in x[3]=%d", x.X()[3]);

      // Check slice value
      if (slice >= y.X()[3]) errorQuda("Unexpected slice %d", slice);

      // We must give a 4D Lattice field as the first argument
      instantiate<copy3D>(y, x, slice, type);
    }

    template <typename Float, int nColor> class axpby3D : TunableKernel2D
    {
    protected:
      ColorSpinorField &x;
      ColorSpinorField &y;
      void *a;
      void *b;

      unsigned int minThreads() const { return x.VolumeCB(); }

    public:
      axpby3D(ColorSpinorField &x, ColorSpinorField &y, void *a, void *b) :
        TunableKernel2D(x, x.SiteSubset()), x(x), y(y), a(a), b(b)
      {
        apply(device::get_default_stream());
      }

      void apply(const qudaStream_t &stream)
      {
        size_t data_bytes = x.X()[3] * x.Precision();
        void *d_a = pool_device_malloc(data_bytes);
        void *d_b = pool_device_malloc(data_bytes);
        qudaMemcpy(d_a, a, data_bytes, qudaMemcpyHostToDevice);
        qudaMemcpy(d_b, b, data_bytes, qudaMemcpyHostToDevice);

        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        launch<axpby3d>(tp, stream, axpby3dArg<Float, nColor>((Float *)d_a, x, (Float *)d_b, y));

        pool_device_free(d_b);
        pool_device_free(d_a);
      }

      long long flops() const { return 6 * x.Volume() * x.Nspin() * x.Ncolor(); }
      long long bytes() const { return x.Bytes() + 2 * y.Bytes(); }
    };

    void axpby(std::vector<double> &a, ColorSpinorField &x, std::vector<double> &b, ColorSpinorField &y)
    {
      checkPrecision(x, y);

      // Check spins
      if (x.Nspin() != y.Nspin()) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

      // Check colors
      if (x.Ncolor() != y.Ncolor()) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());

      // Check coefficients
      if (a.size() != b.size() && a.size() != (unsigned int)x.X()[3])
        errorQuda("Unexpected coeff array sizes a=%lu b=%lu, x[3]=%d", a.size(), b.size(), x.X()[3]);

      // We must give a Lattice field as the first argument
      instantiate<axpby3D>(x, y, a.data(), b.data());
    }

    void ax(std::vector<double> &a, ColorSpinorField &x)
    {
      std::vector<double> zeros(a.size(), 0.0);
      axpby(a, x, zeros, x);
    }

    template <typename Float, int nColor> class caxpby3D : TunableKernel2D
    {
    protected:
      ColorSpinorField &x;
      ColorSpinorField &y;
      void *a;
      void *b;

      unsigned int minThreads() const { return x.VolumeCB(); }

    public:
      caxpby3D(ColorSpinorField &x, ColorSpinorField &y, void *a, void *b) :
        TunableKernel2D(x, x.SiteSubset()), x(x), y(y), a(a), b(b)
      {
        apply(device::get_default_stream());
      }

      void apply(const qudaStream_t &stream)
      {
        size_t data_bytes = 2 * x.X()[3] * x.Precision();
        void *d_a = pool_device_malloc(data_bytes);
        void *d_b = pool_device_malloc(data_bytes);
        qudaMemcpy(d_a, a, data_bytes, qudaMemcpyHostToDevice);
        qudaMemcpy(d_b, b, data_bytes, qudaMemcpyHostToDevice);

        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        launch<caxpby3d>(tp, stream, caxpby3dArg<Float, nColor>((complex<Float> *)d_a, x, (complex<Float> *)d_b, y));

        pool_device_free(d_a);
        pool_device_free(d_b);
      }

      long long flops() const { return 14 * x.Volume() * x.Nspin() * x.Ncolor(); }
      long long bytes() const { return x.Bytes() + 2 * y.Bytes(); }
    };

    void caxpby(std::vector<Complex> &a, ColorSpinorField &x, std::vector<Complex> &b, ColorSpinorField &y)
    {
      checkPrecision(x, y);

      // Check spins
      if (x.Nspin() != y.Nspin()) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

      // Check colors
      if (x.Ncolor() != y.Ncolor()) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());

      // Check coefficients
      if (a.size() != b.size() && a.size() != (unsigned int)x.X()[3])
        errorQuda("Unexpected coeff array sizes a=%lu b=%lu, x[3]=%d", a.size(), b.size(), x.X()[3]);

      // We must give a Lattice field as the first argument
      instantiate<caxpby3D>(x, y, a.data(), b.data());
    }

    template <typename Float, int nColor> class reDotProduct3D : TunableMultiReduction
    {
      const ColorSpinorField &x;
      const ColorSpinorField &y;
      std::vector<double> &result_global;

    public:
      reDotProduct3D(const ColorSpinorField &x, const ColorSpinorField &y, std::vector<double> &result_global) :
        TunableMultiReduction(x, x.SiteSubset(), x.X()[3]), x(x), y(y), result_global(result_global)
      {
        apply(device::get_default_stream());
      }

      void apply(const qudaStream_t &stream)
      {
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

        std::vector<double> result_local(x.X()[3]);
        reDotProduct3dArg<Float, nColor> arg(x, y);
        launch<reDotProduct3d>(result_local, tp, stream, arg);

        // Copy results back to host array
        if (!activeTuning()) {
          for (int i = 0; i < x.X()[3]; i++) { result_global[comm_coord(3) * x.X()[3] + i] = result_local[i]; }
        }
      }

      long long flops() const { return x.Volume() * x.Nspin() * x.Ncolor() * 2; }
      long long bytes() const { return x.Bytes() + y.Bytes(); }
    };

    void reDotProduct(std::vector<double> &result, const ColorSpinorField &x, const ColorSpinorField &y)
    {
      // Check spins
      if (x.Nspin() != y.Nspin()) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

      // Check colors
      if (x.Ncolor() != y.Ncolor()) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());

      // Check coefficients
      if (result.size() != (unsigned int)x.X()[3])
        errorQuda("Unexpected coeff array size a=%lu, x[3]=%d", result.size(), x.X()[3]);

      // We must give a Lattice field as the first argument
      instantiate<reDotProduct3D>(x, y, result);
    }

    template <typename Float, int nColor> class cDotProduct3D : TunableMultiReduction
    {
      const ColorSpinorField &x;
      const ColorSpinorField &y;
      std::vector<Complex> &result_global;

    public:
      cDotProduct3D(const ColorSpinorField &x, const ColorSpinorField &y, std::vector<Complex> &result_global) :
        TunableMultiReduction(x, x.SiteSubset(), x.X()[3]), x(x), y(y), result_global(result_global)
      {
        apply(device::get_default_stream());
      }

      void apply(const qudaStream_t &stream)
      {
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

        std::vector<double> result_local(2 * x.X()[3]);
        cDotProduct3dArg<Float, nColor> arg(x, y);
        launch<cDotProduct3d>(result_local, tp, stream, arg);

        // Copy results back to host array
        if (!activeTuning()) {
          for (int i = 0; i < x.X()[3]; i++) {
            result_global[comm_coord(3) * x.X()[3] + i].real(result_local[2 * i + 0]);
            result_global[comm_coord(3) * x.X()[3] + i].imag(result_local[2 * i + 1]);
          }
        }
      }

      long long flops() const { return x.Volume() * x.Nspin() * x.Ncolor() * 8; }
      long long bytes() const { return x.Bytes() + y.Bytes(); }
    };

    void cDotProduct(std::vector<Complex> &result, const ColorSpinorField &x, const ColorSpinorField &y)
    {
      // Check spins
      if (x.Nspin() != y.Nspin()) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

      // Check colors
      if (x.Ncolor() != y.Ncolor()) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());

      // Check coefficients
      if (result.size() != (unsigned int)x.X()[3])
        errorQuda("Unexpected coeff array size a=%lu, x[3]=%d", result.size(), x.X()[3]);

      // We must give a Lattice field as the first argument
      instantiate<cDotProduct3D>(x, y, result);
    }

  } // namespace blas3d

} // namespace quda
