#include "staggered_dslash_test_utils.h"

using namespace quda;

class StaggeredDslashTest : public ::testing::Test
{
protected:
  StaggeredDslashTestWrapper dslash_test_wrapper;

  void display_test_info()
  {
    printfQuda("running the following test:\n");
    printfQuda("prec recon   test_type     dagger   S_dim         T_dimension\n");
    printfQuda("%s   %s       %s           %d       %d/%d/%d        %d \n", get_prec_str(prec),
               get_recon_str(link_recon), get_string(dtest_type_map, dtest_type).c_str(), dagger, xdim, ydim, zdim, tdim);
    printfQuda("Grid partition info:     X  Y  Z  T\n");
    printfQuda("                         %d  %d  %d  %d\n", dimPartitioned(0), dimPartitioned(1), dimPartitioned(2),
               dimPartitioned(3));
  }

public:
  virtual void SetUp()
  {
    dslash_test_wrapper.init_test();
    display_test_info();
  }

  virtual void TearDown() { dslash_test_wrapper.end(); }

  static void SetUpTestCase() { initQuda(device_ordinal); }

  // Per-test-case tear-down.
  // Called after the last test in this test case.
  // Can be omitted if not needed.
  static void TearDownTestCase()
  {
    StaggeredDslashTestWrapper::destroy();
    endQuda();
  }
};

TEST_F(StaggeredDslashTest, benchmark) { dslash_test_wrapper.run_test(niter, /**show_metrics =*/true); }

TEST_F(StaggeredDslashTest, verify)
{
  if (!verify_results) GTEST_SKIP();

  dslash_test_wrapper.staggeredDslashRef();
  dslash_test_wrapper.run_test(2);

  double deviation = dslash_test_wrapper.verify();
  double tol = getTolerance(dslash_test_wrapper.inv_param.cuda_prec);

  // give it a tiny bump for fixed precision, recon 8
  if (dslash_test_wrapper.inv_param.cuda_prec <= QUDA_HALF_PRECISION
      && dslash_test_wrapper.gauge_param.reconstruct == QUDA_RECONSTRUCT_9)
    tol *= 1.1;

  ASSERT_LE(deviation, tol) << "reference and QUDA implementations do not agree";
}

int main(int argc, char **argv)
{
  // initalize google test
  ::testing::InitGoogleTest(&argc, argv);

  // override the default dslash from Wilson
  dslash_type = QUDA_ASQTAD_DSLASH;

  // command line options
  auto app = make_app();
  app->add_option("--test", dtest_type, "Test method")->transform(CLI::CheckedTransformer(dtest_type_map));
  add_comms_option_group(app);

  try {
    app->parse(argc, argv);
  } catch (const CLI::ParseError &e) {
    return app->exit(e);
  }

  initComms(argc, argv, gridsize_from_cmdline);

  // Ensure gtest prints only from rank 0
  ::testing::TestEventListeners &listeners = ::testing::UnitTest::GetInstance()->listeners();
  if (comm_rank() != 0) { delete listeners.Release(listeners.default_result_printer()); }

  // Only these fermions are supported in this file
  if constexpr (is_enabled_laplace()) {
    if (!is_staggered(dslash_type) && !is_laplace(dslash_type))
      errorQuda("dslash_type %s not supported", get_dslash_str(dslash_type));
  } else {
    if (is_laplace(dslash_type))
      errorQuda("The Laplace dslash is not enabled, cmake configure with -DQUDA_DIRAC_LAPLACE=ON");
    if (!is_staggered(dslash_type)) errorQuda("dslash_type %s not supported", get_dslash_str(dslash_type));
  }

  // Sanity check: if you pass in a gauge field, want to test the asqtad/hisq dslash,
  // and don't ask to build the fat/long links... it doesn't make sense.
  if (latfile.size() > 0 && !compute_fatlong && dslash_type == QUDA_ASQTAD_DSLASH)
    errorQuda(
      "Cannot load a gauge field and test the ASQTAD/HISQ operator without setting \"--compute-fat-long true\".");

  // Set n_naiks to 2 if eps_naik != 0.0
  if (eps_naik != 0.0) {
    if (compute_fatlong)
      n_naiks = 2;
    else
      eps_naik = 0.0; // to avoid potential headaches
  }

  if (is_laplace(dslash_type) && dtest_type != dslash_test_type::Mat)
    errorQuda("Test type %s is not supported for the Laplace operator", get_string(dtest_type_map, dtest_type).c_str());

  int test_rc = RUN_ALL_TESTS();

  finalizeComms();
  return test_rc;
}
