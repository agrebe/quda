#include <instantiate.h>
#include <multigrid.h>
#include <tunable_nd.h>
#include <reference_wrapper_helper.h>
#include <kernels/block_transpose.cuh>
#include <int_list.hpp>

/**
  @file BlockTranspose does the transpose between the two different orders of batched colorspinor fields:
    - B: nVec -> spatial/N -> spin/color -> N, where N is for that in floatN
    - V: spatial -> spin/color -> nVec
 */

namespace quda
{

  namespace impl
  {

    using namespace quda::colorspinor;

    template <class v_t, class b_t, typename vFloat, typename bFloat, int nSpin, int nColor, int nVec>
    class BlockTranspose : public TunableKernel2D
    {

      using real = typename mapper<vFloat>::type;
      template <bool is_device, typename vOrder, typename bOrder, bool from_to_non_rel>
      using Arg
        = BlockTransposeArg<v_t, b_t, is_device, vFloat, vOrder, bFloat, bOrder, nSpin, nColor, nVec, from_to_non_rel>;

      v_t &V;
      cvector_ref<b_t> &B;
      bool from_to_non_rel;

    public:
      BlockTranspose(v_t &V, cvector_ref<b_t> &B, bool from_to_non_rel_) :
        TunableKernel2D(V, B.size()), V(V), B(B), from_to_non_rel(from_to_non_rel_)
      {
        if constexpr (std::is_const_v<v_t>) {
          strcat(aux, ",v2b");
        } else {
          strcat(aux, ",b2v");
        }
        setRHSstring(aux, B.size());
        if (from_to_non_rel) { strcat(aux, ",from_to_non_rel"); }
        resizeStep(1);
        apply(device::get_default_stream());
      }

      virtual int blockStep() const { return 8; }

      virtual int blockMin() const { return 8; }

      void initTuneParam(TuneParam &param) const
      {
        TunableKernel2D::initTuneParam(param);
        param.block.z = 1;
        param.grid.z = nColor * V.SiteSubset();
      }

      void defaultTuneParam(TuneParam &param) const { initTuneParam(param); }

      template <typename vAccessor, typename bAccessor> void launch_device_(TuneParam &tp, const qudaStream_t &stream)
      {
        if (from_to_non_rel) {
          if constexpr (nSpin == 4) {
            Arg<true, vAccessor, bAccessor, true> arg(V, B, tp.block.x, tp.block.y);
            tp.set_max_shared_bytes = true;
            launch_device<BlockTransposeKernel>(tp, stream, arg);
          } else {
            errorQuda("from_to_non_rel is only defined for nSpin(=%d) == 4.", nSpin);
          }
        } else {
          Arg<true, vAccessor, bAccessor, false> arg(V, B, tp.block.x, tp.block.y);
          tp.set_max_shared_bytes = true;
          launch_device<BlockTransposeKernel>(tp, stream, arg);
        }
      }

      void apply(const qudaStream_t &stream)
      {
        constexpr bool disable_ghost = true;
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        if (V.Location() == QUDA_CPU_FIELD_LOCATION) {
          errorQuda("BlockTranspose does not support host invokation yet.");
        } else {
          constexpr auto vOrder = QUDA_SPACE_SPIN_COLOR_FIELD_ORDER;
          constexpr auto bOrder = colorspinor::getNative<bFloat>(nSpin);
          if (V.FieldOrder() == vOrder && B[0].FieldOrder() == bOrder) {
            typedef FieldOrderCB<real, nSpin, nColor, nVec, vOrder, vFloat, vFloat, disable_ghost> vAccessor;
            typedef FieldOrderCB<real, nSpin, nColor, 1, bOrder, bFloat, bFloat, disable_ghost> bAccessor;
            if constexpr (std::is_const_v<v_t>) {
              launch_device_<const vAccessor, bAccessor>(tp, stream);
            } else {
              launch_device_<vAccessor, bAccessor>(tp, stream);
            }
          } else {
            errorQuda("Unsupported field order V=%d B=%d", V.FieldOrder(), B[0].FieldOrder());
          }
        }
      }

      virtual unsigned int sharedBytesPerBlock(const TuneParam &param) const
      {
        return (param.block.x + 1) * param.block.y * nSpin * 2 * sizeof(real);
      }

      virtual unsigned int minThreads() const { return V.VolumeCB(); }

      long long flops() const { return 0; }

      long long bytes() const { return V.Bytes() + B.size() * B[0].Bytes(); }
    };

  } // namespace impl

  template <class v_t, class b_t, typename vFloat, typename bFloat, int nSpin, int nColor, int nVec, int... N>
  void launch_span_nVec(v_t &V, cvector_ref<b_t> &B, bool from_to_non_rel, IntList<nVec, N...>)
  {
    if (V.Nvec() == nVec) {
      impl::BlockTranspose<v_t, b_t, vFloat, bFloat, nSpin, nColor, nVec> transpose(V, B, from_to_non_rel);
    } else {
      IntList<N...> nVecs_remaining;
      if constexpr (sizeof...(N) > 0) {
        launch_span_nVec<v_t, b_t, vFloat, bFloat, nSpin, nColor>(V, B, from_to_non_rel, nVecs_remaining);
      } else {
        errorQuda("nVec = %d not instantiated", V.Nvec());
      }
    }
  }

  template <class v_t, class b_t, typename vFloat, typename bFloat, int nSpin, int nColor, int... N>
  void launch_span_nColor(v_t &V, cvector_ref<b_t> &B, bool from_to_non_rel, IntList<nColor, N...>)
  {
    if (B[0].Ncolor() == nColor) {
      // clang-format off
      IntList<@QUDA_MULTIGRID_MRHS_LIST@> nVecs;
      // clang-format on
      launch_span_nVec<v_t, b_t, vFloat, bFloat, nSpin, nColor>(V, B, from_to_non_rel, nVecs);
    } else {
      IntList<N...> nColors_remaining;
      if constexpr (sizeof...(N) > 0) {
        launch_span_nColor<v_t, b_t, vFloat, bFloat, nSpin>(V, B, from_to_non_rel, nColors_remaining);
      } else {
        errorQuda("nColor = %d not instantiated", B.Ncolor());
      }
    }
  }

  template <class v_t, class b_t, typename vFloat, typename bFloat, int nSpin, int... N>
  void launch_span_nSpin(v_t &V, cvector_ref<b_t> &B, bool from_to_non_rel, IntList<nSpin, N...>)
  {
    if (V.Nspin() != B[0].Nspin()) { errorQuda("V.Nspin() (=%d) != B.Nspin() (=%d)", V.Nspin(), B[0].Nspin()); }

    if (V.Nspin() == nSpin) {
      if constexpr (is_enabled_spin(nSpin)) {
        // clang-format off
        IntList<@QUDA_MULTIGRID_NC_NVEC_LIST@> nColors;
        // clang-format on
        launch_span_nColor<v_t, b_t, vFloat, bFloat, nSpin>(V, B, from_to_non_rel, nColors);
      } else {
        errorQuda("nSpin = %d not instantiated", nSpin);
      }
    } else {
      if constexpr (sizeof...(N) > 0) {
        IntList<N...> nSpins_remaining;
        launch_span_nSpin<v_t, b_t, vFloat, bFloat>(V, B, from_to_non_rel, nSpins_remaining);
      } else {
        errorQuda("Unexpected nSpin = %d", V.Nspin());
      }
    }
  }

  template <class v_t, class b_t> void block_transpose(v_t &V, cvector_ref<b_t> &B, bool from_to_non_rel)
  {
    if (!is_enabled(V.Precision()) || !is_enabled(B[0].Precision()))
      errorQuda("QUDA_PRECISION=%d does not enable required precision combination (V = %d B = %d)", QUDA_PRECISION,
                V.Precision(), B[0].Precision());

    IntList<1, 2, 4> nSpins;

    if constexpr (is_enabled_multigrid()) {
      if (V.Precision() == QUDA_DOUBLE_PRECISION && B[0].Precision() == QUDA_DOUBLE_PRECISION) {
        if constexpr (is_enabled_multigrid_double())
          launch_span_nSpin<v_t, b_t, double, double>(V, B, from_to_non_rel, nSpins);
        else
          errorQuda("Double precision multigrid has not been enabled");
      } else if (V.Precision() == QUDA_SINGLE_PRECISION && B[0].Precision() == QUDA_SINGLE_PRECISION) {
        if constexpr (is_enabled(QUDA_SINGLE_PRECISION))
          launch_span_nSpin<v_t, b_t, float, float>(V, B, from_to_non_rel, nSpins);
      } else {
        errorQuda("Unsupported precision combination V=%d B=%d", V.Precision(), B[0].Precision());
      }
    } else {
      errorQuda("Multigrid has not been built");
    }
  }

  void BlockTransposeForward(ColorSpinorField &V, cvector_ref<const ColorSpinorField> &B, bool from_non_rel)
  {
    block_transpose(V, B, from_non_rel);
  }

  void BlockTransposeBackward(const ColorSpinorField &V, cvector_ref<ColorSpinorField> &B, bool to_non_rel)
  {
    block_transpose(V, B, to_non_rel);
  }

} // namespace quda
