#include <dirac_quda.h>
#include <dslash_quda.h>
#include <blas_quda.h>
#include <multigrid.h>

namespace quda
{

  DiracCloverHasenbuschTwist::DiracCloverHasenbuschTwist(const DiracParam &param) : DiracClover(param), mu(param.mu) {}

  DiracCloverHasenbuschTwist::DiracCloverHasenbuschTwist(const DiracCloverHasenbuschTwist &dirac) :
    DiracClover(dirac),
    mu(dirac.mu)
  {
  }

  DiracCloverHasenbuschTwist::~DiracCloverHasenbuschTwist() {}

  DiracCloverHasenbuschTwist &DiracCloverHasenbuschTwist::operator=(const DiracCloverHasenbuschTwist &dirac)
  {
    if (&dirac != this) {
      DiracWilson::operator=(dirac);
      clover = dirac.clover;
      mu = dirac.mu;
    }
    return *this;
  }

  void DiracCloverHasenbuschTwist::M(cvector_ref<ColorSpinorField> &out, cvector_ref<const ColorSpinorField> &in) const
  {
    if (symmetric) {
      ApplyWilsonCloverHasenbuschTwist(out(this_parity), in(other_parity), *gauge, *clover, -kappa, mu, in(this_parity),
                                       this_parity, dagger, commDim.data, profile);
      ApplyWilsonClover(out(other_parity), in(this_parity), *gauge, *clover, -kappa, in(other_parity), other_parity,
                        dagger, commDim.data, profile);
    } else {
      ApplyWilsonClover(out(other_parity), in(this_parity), *gauge, *clover, -kappa, in(other_parity), other_parity,
                        dagger, commDim.data, profile);
      ApplyTwistedClover(out(this_parity), in(other_parity), *gauge, *clover, -kappa, mu, in(this_parity), this_parity,
                         dagger, commDim.data, profile);
    }
  }

  void DiracCloverHasenbuschTwist::MdagM(cvector_ref<ColorSpinorField> &out, cvector_ref<const ColorSpinorField> &in) const
  {
    checkFullSpinor(out, in);
    auto tmp = getFieldTmp(out);

    M(tmp, in);
    Mdag(out, tmp);
  }

  void DiracCloverHasenbuschTwist::createCoarseOp(GaugeField &, GaugeField &, const Transfer &, double, double, double,
                                                  double, bool) const
  {
    // double a = 2.0 * kappa * mu * T.Vectors().TwistFlavor();
    // CoarseOp(Y, X, T, *gauge, &clover, kappa, a, mu_factor, QUDA_CLOVER_DIRAC, QUDA_MATPC_INVALID);
    errorQuda("Not Yet Implemented");
  }

  /* **********************************************
   * DiracCloverHasenbuschTwistPC Starts Here
   * ********************************************* */

  DiracCloverHasenbuschTwistPC::DiracCloverHasenbuschTwistPC(const DiracParam &param) :
    DiracCloverPC(param),
    mu(param.mu)
  {
  }

  DiracCloverHasenbuschTwistPC::DiracCloverHasenbuschTwistPC(const DiracCloverHasenbuschTwistPC &dirac) :
    DiracCloverPC(dirac),
    mu(dirac.mu)
  {
  }

  DiracCloverHasenbuschTwistPC::~DiracCloverHasenbuschTwistPC() {}

  DiracCloverHasenbuschTwistPC &DiracCloverHasenbuschTwistPC::operator=(const DiracCloverHasenbuschTwistPC &dirac)
  {
    if (&dirac != this) {
      DiracCloverPC::operator=(dirac);
      mu = dirac.mu;
    }
    return *this;
  }

  // xpay version of the above
  void DiracCloverHasenbuschTwistPC::DslashXpayTwistClovInv(cvector_ref<ColorSpinorField> &out,
                                                            cvector_ref<const ColorSpinorField> &in, QudaParity parity,
                                                            cvector_ref<const ColorSpinorField> &x, double k,
                                                            double b) const
  {
    checkParitySpinor(in, out);
    checkSpinorAlias(in, out);

    ApplyWilsonCloverHasenbuschTwistPCClovInv(out, in, *gauge, *clover, k, b, x, parity, dagger, commDim.data, profile);
  }

  // xpay version of the above
  void DiracCloverHasenbuschTwistPC::DslashXpayTwistNoClovInv(cvector_ref<ColorSpinorField> &out,
                                                              cvector_ref<const ColorSpinorField> &in,
                                                              QudaParity parity, cvector_ref<const ColorSpinorField> &x,
                                                              double k, double b) const
  {
    checkParitySpinor(in, out);
    checkSpinorAlias(in, out);

    ApplyWilsonCloverHasenbuschTwistPCNoClovInv(out, in, *gauge, *clover, k, b, x, parity, dagger, commDim.data, profile);
  }

  // Apply the even-odd preconditioned clover-improved Dirac operator
  void DiracCloverHasenbuschTwistPC::M(cvector_ref<ColorSpinorField> &out, cvector_ref<const ColorSpinorField> &in) const
  {
    double kappa2 = -kappa * kappa;
    auto tmp = getFieldTmp(out);

    if (!symmetric) {
      // No need to change order of calls for dagger
      // because the asymmetric operator is actually symmetric
      // A_oo -D_oe A^{-1}_ee D_eo -> A_oo -D^\dag_oe A^{-1}_ee D^\dag_eo
      // the pieces in Dslash and DslashXPay respect the dagger

      // DiracCloverHasenbuschTwistPC::Dslash applies A^{-1}Dslash
      Dslash(tmp, in, other_parity);

      // applies (A + imu*g5 - kappa^2 D)-
      ApplyTwistedClover(out, tmp, *gauge, *clover, kappa2, mu, in, this_parity, dagger, commDim.data, profile);
    } else if (!dagger) { // symmetric preconditioning
      // We need two cases because M = 1-ADAD and M^\dag = 1-D^\dag A D^dag A
      // where A is actually a clover inverse.

      // This is the non-dag case: AD
      Dslash(tmp, in, other_parity);

      // Then x + AD (AD)
      DslashXpayTwistClovInv(out, tmp, this_parity, in, kappa2, mu);
    } else { // symmetric preconditioning, dagger
      // This is the dagger: 1 - DADA
      //  i) Apply A
      CloverInv(out, in, this_parity);
      // ii) Apply A D => ADA
      Dslash(tmp, out, other_parity);
      // iii) Apply  x + D(ADA)
      DslashXpayTwistNoClovInv(out, tmp, this_parity, in, kappa2, mu);
    }
  }

  void DiracCloverHasenbuschTwistPC::MdagM(cvector_ref<ColorSpinorField> &out, cvector_ref<const ColorSpinorField> &in) const
  {
    auto tmp = getFieldTmp(out);
    M(tmp, in);
    Mdag(out, tmp);
  }

  void DiracCloverHasenbuschTwistPC::createCoarseOp(GaugeField &, GaugeField &, const Transfer &, double, double,
                                                    double, double, bool) const
  {
    // double a = - 2.0 * kappa * mu * T.Vectors().TwistFlavor();
    // CoarseOp(Y, X, T, *gauge, &clover, kappa, a, -mu_factor,QUDA_CLOVERPC_DIRAC, matpcType);
    errorQuda("Not yet implemented");
  }

} // namespace quda
