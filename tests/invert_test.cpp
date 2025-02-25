#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <string.h>

// QUDA headers
#include <quda.h>
#include <color_spinor_field.h> // convenient quark field container

// External headers
#include <misc.h>
#include <host_utils.h>
#include <command_line_params.h>
#include <dslash_reference.h>
#include "test.h"

QudaGaugeParam gauge_param;
QudaInvertParam inv_param;
QudaMultigridParam mg_param;
QudaInvertParam mg_inv_param;
QudaEigParam mg_eig_param[QUDA_MAX_MG_LEVEL];
QudaEigParam eig_param;
bool use_split_grid = false;
bool use_multi_src = false;

std::vector<char> gauge_;
std::array<void *, 4> gauge;
std::vector<char> clover;
std::vector<char> clover_inv;
QudaPrecision last_prec = QUDA_INVALID_PRECISION;

// if --enable-testing true is passed, we run the tests defined in here
#include <invert_test_gtest.hpp>

void display_test_info()
{
  printfQuda("running the following test:\n");
  printfQuda("prec    prec_sloppy   multishift  matpc_type  recon  recon_sloppy solve_type S_dimension T_dimension "
             "Ls_dimension   dslash_type  normalization\n");
  printfQuda(
    "%6s   %6s          %d     %12s     %2s     %2s         %10s %3d/%3d/%3d     %3d         %2d       %14s  %8s\n",
    get_prec_str(prec), get_prec_str(prec_sloppy), multishift, get_matpc_str(matpc_type), get_recon_str(link_recon),
    get_recon_str(link_recon_sloppy), get_solve_str(solve_type), xdim, ydim, zdim, tdim, Lsdim,
    get_dslash_str(dslash_type), get_mass_normalization_str(normalization));

  if (inv_multigrid) {
    printfQuda("MG parameters\n");
    printfQuda(" - number of levels %d\n", mg_levels);
    for (int i = 0; i < mg_levels - 1; i++) {
      printfQuda(" - level %d number of null-space vectors %d\n", i + 1, nvec[i]);
      printfQuda(" - level %d null-space vector batch size %d\n", i + 1, nvec_batch[i]);
      printfQuda(" - level %d number of pre-smoother applications %d\n", i + 1, nu_pre[i]);
      printfQuda(" - level %d number of post-smoother applications %d\n", i + 1, nu_post[i]);
    }

    printfQuda("MG Eigensolver parameters\n");
    for (int i = 0; i < mg_levels; i++) {
      if (low_mode_check || mg_eig[i]) {
        printfQuda(" - level %d solver mode %s\n", i + 1, get_eig_type_str(mg_eig_type[i]));
        printfQuda(" - level %d spectrum requested %s\n", i + 1, get_eig_spectrum_str(mg_eig_spectrum[i]));
        if (mg_eig_type[i] == QUDA_EIG_BLK_TR_LANCZOS)
          printfQuda(" - eigenvector block size %d\n", mg_eig_block_size[i]);
        printfQuda(" - level %d number of eigenvectors requested n_conv %d\n", i + 1, nvec[i]);
        printfQuda(" - level %d size of eigenvector search space %d\n", i + 1, mg_eig_n_ev[i]);
        printfQuda(" - level %d size of Krylov space %d\n", i + 1, mg_eig_n_kr[i]);
        printfQuda(" - level %d solver tolerance %e\n", i + 1, mg_eig_tol[i]);
        printfQuda(" - level %d convergence required (%s)\n", i + 1, mg_eig_require_convergence[i] ? "true" : "false");
        printfQuda(" - level %d Operator: daggered (%s) , norm-op (%s)\n", i + 1,
                   mg_eig_use_dagger[i] ? "true" : "false", mg_eig_use_normop[i] ? "true" : "false");
        if (mg_eig_use_poly_acc[i]) {
          printfQuda(" - level %d Chebyshev polynomial degree %d\n", i + 1, mg_eig_poly_deg[i]);
          printfQuda(" - level %d Chebyshev polynomial minumum %e\n", i + 1, mg_eig_amin[i]);
          if (mg_eig_amax[i] <= 0)
            printfQuda(" - level %d Chebyshev polynomial maximum will be computed\n", i + 1);
          else
            printfQuda(" - level %d Chebyshev polynomial maximum %e\n", i + 1, mg_eig_amax[i]);
        }
        printfQuda("\n");
      }
    }
  }

  if (inv_deflate) {
    printfQuda("\n   Eigensolver parameters\n");
    printfQuda(" - solver mode %s\n", get_eig_type_str(eig_type));
    printfQuda(" - spectrum requested %s\n", get_eig_spectrum_str(eig_spectrum));
    if (eig_type == QUDA_EIG_BLK_TR_LANCZOS) printfQuda(" - eigenvector block size %d\n", eig_block_size);
    printfQuda(" - number of eigenvectors requested %d\n", eig_n_conv);
    printfQuda(" - size of eigenvector search space %d\n", eig_n_ev);
    printfQuda(" - size of Krylov space %d\n", eig_n_kr);
    printfQuda(" - solver tolerance %e\n", eig_tol);
    printfQuda(" - convergence required (%s)\n", eig_require_convergence ? "true" : "false");
    if (eig_compute_svd) {
      printfQuda(" - Operator: MdagM. Will compute SVD of M\n");
      printfQuda(" - ***********************************************************\n");
      printfQuda(" - **** Overriding any previous choices of operator type. ****\n");
      printfQuda(" - ****    SVD demands normal operator, will use MdagM    ****\n");
      printfQuda(" - ***********************************************************\n");
    } else {
      printfQuda(" - Operator: daggered (%s) , norm-op (%s)\n", eig_use_dagger ? "true" : "false",
                 eig_use_normop ? "true" : "false");
    }
    if (eig_use_poly_acc) {
      printfQuda(" - Chebyshev polynomial degree %d\n", eig_poly_deg);
      printfQuda(" - Chebyshev polynomial minumum %e\n", eig_amin);
      if (eig_amax <= 0)
        printfQuda(" - Chebyshev polynomial maximum will be computed\n");
      else
        printfQuda(" - Chebyshev polynomial maximum %e\n\n", eig_amax);
    }
  }

  printfQuda("Grid partition info:     X  Y  Z  T\n");
  printfQuda("                         %d  %d  %d  %d\n", dimPartitioned(0), dimPartitioned(1), dimPartitioned(2),
             dimPartitioned(3));
}

void init(int argc, char **argv)
{
  // Set QUDA's internal parameters
  gauge_param = newQudaGaugeParam();
  setWilsonGaugeParam(gauge_param);

  inv_param = newQudaInvertParam();
  mg_param = newQudaMultigridParam();
  mg_inv_param = newQudaInvertParam();
  eig_param = newQudaEigParam();

  if (inv_multigrid) {
    setQudaMgSolveTypes();
    setMultigridInvertParam(inv_param);
    // Set sub structures
    mg_param.invert_param = &mg_inv_param;
    for (int i = 0; i < mg_levels; i++) {
      if (mg_eig[i]) {
        mg_eig_param[i] = newQudaEigParam();
        setMultigridEigParam(mg_eig_param[i], i);
        mg_param.eig_param[i] = &mg_eig_param[i];
      } else {
        mg_param.eig_param[i] = nullptr;
      }
    }
    // Set MG
    setMultigridParam(mg_param);
  } else {
    setInvertParam(inv_param);
  }

  if (inv_deflate) {
    setEigParam(eig_param);
    inv_param.eig_param = &eig_param;
  } else {
    inv_param.eig_param = nullptr;
  }

  // set parameters for the reference Dslash, and prepare fields to be loaded
  if (dslash_type == QUDA_DOMAIN_WALL_DSLASH || dslash_type == QUDA_DOMAIN_WALL_4D_DSLASH
      || dslash_type == QUDA_MOBIUS_DWF_DSLASH || dslash_type == QUDA_MOBIUS_DWF_EOFA_DSLASH) {
    dw_setDims(gauge_param.X, inv_param.Ls);
  } else {
    setDims(gauge_param.X);
  }

  // Allocate host side memory for the gauge field.
  //----------------------------------------------------------------------------
  gauge_.resize(4 * V * gauge_site_size * host_gauge_data_type_size);
  for (int i = 0; i < 4; i++) gauge[i] = gauge_.data() + i * V * gauge_site_size * host_gauge_data_type_size;
  constructHostGaugeField(gauge.data(), gauge_param, argc, argv);

  // Allocate host side memory for clover terms if needed.
  if (dslash_type == QUDA_CLOVER_WILSON_DSLASH || dslash_type == QUDA_TWISTED_CLOVER_DSLASH) {
    clover.resize(V * clover_site_size * host_clover_data_type_size);
    clover_inv.resize(V * clover_site_size * host_spinor_data_type_size);
    constructHostCloverField(clover.data(), clover_inv.data(), inv_param);
  }

  if (!enable_testing) {
    // Load the gauge field to the device
    loadGaugeQuda(gauge.data(), &gauge_param);

    if (dslash_type == QUDA_CLOVER_WILSON_DSLASH || dslash_type == QUDA_TWISTED_CLOVER_DSLASH) {
      // Load the clover terms to the device
      loadCloverQuda(clover.data(), clover_inv.data(), &inv_param);
    }

    // Compute plaquette as a sanity check
    double plaq[3];
    plaqQuda(plaq);
    printfQuda("Computed plaquette is %e (spatial = %e, temporal = %e)\n", plaq[0], plaq[1], plaq[2]);
  }
}

std::vector<std::array<double, 2>> solve(test_t param)
{
  inv_param.cuda_prec = ::testing::get<0>(param);
  inv_param.clover_cuda_prec = ::testing::get<0>(param);
  inv_param.cuda_prec_sloppy = ::testing::get<1>(param);
  inv_param.cuda_prec_refinement_sloppy = ::testing::get<1>(param);
  inv_param.cuda_prec_eigensolver = ::testing::get<1>(param);
  inv_param.clover_cuda_prec_sloppy = ::testing::get<1>(param);
  inv_param.clover_cuda_prec_refinement_sloppy = ::testing::get<1>(param);
  inv_param.clover_cuda_prec_eigensolver = ::testing::get<1>(param);
  inv_param.inv_type = ::testing::get<2>(param);
  inv_param.solution_type = ::testing::get<3>(param);
  inv_param.solve_type = ::testing::get<4>(param);
  multishift = ::testing::get<5>(param);
  inv_param.solution_accumulator_pipeline = ::testing::get<6>(param);

  // schwarz parameters
  auto schwarz_param = ::testing::get<7>(param);
  inv_param.schwarz_type           = ::testing::get<0>(schwarz_param);
  inv_param.inv_type_precondition  = ::testing::get<1>(schwarz_param);
  inv_param.cuda_prec_precondition = ::testing::get<2>(schwarz_param);
  inv_param.clover_cuda_prec_precondition = ::testing::get<2>(schwarz_param);

  inv_param.residual_type = ::testing::get<8>(param);

  // reset lambda_max if we're doing a testing loop to ensure correct lambma_max
  if (enable_testing) inv_param.ca_lambda_max = -1.0;

  logQuda(QUDA_SUMMARIZE, "Solution = %s, Solve = %s, Solver = %s, Precision = %s, Sloppy precision = %s\n",
          get_solution_str(inv_param.solution_type), get_solve_str(inv_param.solve_type),
          get_solver_str(inv_param.inv_type), get_prec_str(inv_param.cuda_prec),
          get_prec_str(inv_param.cuda_prec_sloppy));

  // params corresponds to split grid
  for (int i = 0; i < 4; i++) inv_param.split_grid[i] = grid_partition[i];
  int num_sub_partition = grid_partition[0] * grid_partition[1] * grid_partition[2] * grid_partition[3];
  use_split_grid = num_sub_partition > 1;
  use_multi_src = use_split_grid || (Nsrc_tile > 1);

  // Now QUDA is initialised and the fields are loaded, we may setup the preconditioner
  void *mg_preconditioner = nullptr;
  if (inv_multigrid) {
    if (use_split_grid) { errorQuda("Split grid does not work with MG yet."); }
    mg_preconditioner = newMultigridQuda(&mg_param);
    inv_param.preconditioner = mg_preconditioner;

    printfQuda("MG Setup Done: %g secs, %g Gflops\n", mg_param.invert_param->secs,
               mg_param.invert_param->gflops / mg_param.invert_param->secs);
    if (mg_param.invert_param->energy > 0) {
      printfQuda("Energy = %g J, Mean power = %g W, mean temp = %g C, mean clock = %f\n", mg_param.invert_param->energy,
                 mg_param.invert_param->power, mg_param.invert_param->temp, mg_param.invert_param->clock);
    }
  }

  // Vector construct START
  //-----------------------------------------------------------------------------------
  if (Nsrc > QUDA_MAX_MULTI_SRC)
    errorQuda("Nsrc = %d which is great than QUDA_MAX_MULTI_SRC = %d\n", Nsrc, QUDA_MAX_MULTI_SRC);
  std::vector<quda::ColorSpinorField> in(Nsrc);
  std::vector<quda::ColorSpinorField> out(Nsrc);
  std::vector<quda::ColorSpinorField> out_multishift(multishift * Nsrc);
  quda::ColorSpinorField check;
  quda::ColorSpinorParam cs_param;
  constructWilsonTestSpinorParam(&cs_param, &inv_param, &gauge_param);
  check = quda::ColorSpinorField(cs_param);
  std::vector<std::vector<void *>> _hp_multi_x(Nsrc, std::vector<void *>(multishift));

  // QUDA host array for internal checks and malloc
  // Vector construct END
  //-----------------------------------------------------------------------------------

  // Shifts
  std::vector<double> shifts(multishift);

  // QUDA invert test BEGIN
  //----------------------------------------------------------------------------
  if (multishift > 1) {
    if (use_split_grid) { errorQuda("Split grid does not work with multishift yet."); }
    inv_param.num_offset = multishift;

    // Consistency check for shifts, tols, tols_hq size if we're setting custom values
    if (multishift_masses.size() != 0)
      errorQuda("Multishift masses are not supported for Wilson-type fermions");
    if (multishift_shifts.size() != 0 && multishift_shifts.size() != static_cast<unsigned long>(multishift))
      errorQuda("Multishift shift count %d does not agree with number of shifts passed in %lu\n", multishift, multishift_shifts.size());
    if (multishift_tols.size() != 0 && multishift_tols.size() != static_cast<unsigned long>(multishift))
      errorQuda("Multishift tolerance count %d does not agree with number of masses passed in %lu\n", multishift, multishift_tols.size());
    if (multishift_tols_hq.size() != 0 && multishift_tols_hq.size() != static_cast<unsigned long>(multishift))
      errorQuda("Multishift hq tolerance count %d does not agree with number of masses passed in %lu\n", multishift, multishift_tols_hq.size());

    // Copy offsets and tolerances into inv_param; copy data pointers
    for (int i = 0; i < multishift; i++) {
      shifts[i] = (multishift_shifts.size() == 0 ? (i * i * 0.01) : multishift_shifts[i]);
      inv_param.offset[i] = shifts[i];
      inv_param.tol_offset[i] = (multishift_tols.size() == 0 ? inv_param.tol : multishift_tols[i]);
      inv_param.tol_hq_offset[i] = (multishift_tols_hq.size() == 0 ? inv_param.tol_hq : multishift_tols_hq[i]);

      // Allocate memory and set pointers
      for (int n = 0; n < Nsrc; n++) {
        out_multishift[n * multishift + i] = quda::ColorSpinorField(cs_param);
        _hp_multi_x[n][i] = out_multishift[n * multishift + i].data();
      }
    }
  }

  std::vector<double> time(Nsrc);
  std::vector<double> gflops(Nsrc);
  std::vector<int> iter(Nsrc);

  quda::RNG rng(check, 1234);

  for (int i = 0; i < Nsrc; i++) {
    // Populate the host spinor with random numbers.
    in[i] = quda::ColorSpinorField(cs_param);
    spinorNoise(in[i], rng, QUDA_NOISE_GAUSS);
    out[i] = quda::ColorSpinorField(cs_param);
  }

  if (distance_pc_alpha0 != 0.0 && distance_pc_t0 >= 0) {
    inv_param.distance_pc_alpha0 = distance_pc_alpha0;
    inv_param.distance_pc_t0 = distance_pc_t0;
    verifySpinorDistanceReweight(in[0], distance_pc_alpha0, distance_pc_t0);
  }

  if (!use_multi_src || multishift > 1) {

    for (int i = 0; i < Nsrc; i++) {
      // If deflating, preserve the deflation space between solves
      if (inv_deflate) eig_param.preserve_deflation = i < Nsrc - 1 ? QUDA_BOOLEAN_TRUE : QUDA_BOOLEAN_FALSE;
      // Perform QUDA inversions
      if (multishift > 1) {
        invertMultiShiftQuda(_hp_multi_x[i].data(), in[i].data(), &inv_param);
      } else {
        invertQuda(out[i].data(), in[i].data(), &inv_param);
      }

      // move residuals to i^th location for verification after solves have finised
      inv_param.true_res[i] = inv_param.true_res[0];
      inv_param.true_res_hq[i] = inv_param.true_res_hq[0];

      time[i] = inv_param.secs;
      gflops[i] = inv_param.gflops / inv_param.secs;
      iter[i] = inv_param.iter;
      printfQuda("Done: %i iter / %g secs = %g Gflops\n", inv_param.iter, inv_param.secs,
                 inv_param.gflops / inv_param.secs);
      if (inv_param.energy > 0) {
        printfQuda("Energy = %g J, Mean power = %g W, mean temp = %g C, mean clock = %f\n", inv_param.energy,
                   inv_param.power, inv_param.temp, inv_param.clock);
      }
    }

  } else {

    inv_param.num_src = Nsrc_tile;
    inv_param.num_src_per_sub_partition = Nsrc_tile / num_sub_partition;
    // Host arrays for solutions, sources, and check
    std::vector<void *> _hp_x(Nsrc_tile);
    std::vector<void *> _hp_b(Nsrc_tile);

    for (int j = 0; j < Nsrc; j += Nsrc_tile) {
      // If deflating, preserve the deflation space between solves
      if (inv_deflate) eig_param.preserve_deflation = j < Nsrc - Nsrc_tile ? QUDA_BOOLEAN_TRUE : QUDA_BOOLEAN_FALSE;

      for (int i = 0; i < Nsrc_tile; i++) {
        _hp_x[i] = out[j + i].data();
        _hp_b[i] = in[j + i].data();
      }

      invertMultiSrcQuda(_hp_x.data(), _hp_b.data(), &inv_param);

      // move residuals to (i+j)^th location for verification after solves have finished
      for (int i = 0; i < Nsrc_tile; i++) {
        inv_param.true_res[j + i] = inv_param.true_res[i];
        inv_param.true_res_hq[j + i] = inv_param.true_res_hq[i];
      }

      printfQuda("Done: %d sub-partitions - %i total iter / %g secs = %g Gflops, %g secs per source\n", num_sub_partition,
                 inv_param.iter, inv_param.secs, inv_param.gflops / inv_param.secs, inv_param.secs / Nsrc_tile);
      if (inv_param.energy > 0) {
        printfQuda("Energy = %g J (%g J per source), Mean power = %g W, mean temp = %g C, mean clock = %f\n",
                   inv_param.energy, inv_param.energy / Nsrc_tile, inv_param.power, inv_param.temp, inv_param.clock);
      }
    }
  }

  // QUDA invert test COMPLETE
  //----------------------------------------------------------------------------

  // free the multigrid solver
  if (inv_multigrid) destroyMultigridQuda(mg_preconditioner);

  // Compute performance statistics
  if (!use_multi_src) performanceStats(time, gflops, iter);

  std::vector<std::array<double, 2>> res(Nsrc);
  // Perform host side verification of inversion if requested
  if (verify_results) {
    for (int i = 0; i < Nsrc; i++) {
      res[i] = verifyInversion(out[i].data(), _hp_multi_x[i].data(), in[i].data(), check.data(), gauge_param, inv_param,
                               gauge.data(), clover.data(), clover_inv.data(), i);
    }
  }
  return res;
}

int main(int argc, char **argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  setQudaDefaultMgTestParams();
  // Parse command line options
  auto app = make_app();
  add_eigen_option_group(app);
  add_deflation_option_group(app);
  add_eofa_option_group(app);
  add_madwf_option_group(app);
  add_multigrid_option_group(app);
  add_comms_option_group(app);
  add_testing_option_group(app);
  try {
    app->parse(argc, argv);
  } catch (const CLI::ParseError &e) {
    return app->exit(e);
  }

  // If a value greater than 1 is passed, heavier masses will be constructed
  // and the multi-shift solver will be called
  if (multishift > 1) {
    // set a correct default for the multi-shift solver
    solution_type = QUDA_MATPCDAG_MATPC_SOLUTION;
  }

  // Set values for precisions via the command line.
  setQudaPrecisions();

  // initialize QMP/MPI, QUDA comms grid and RNG (host_utils.cpp)
  initComms(argc, argv, gridsize_from_cmdline);

  if (inv_deflate && inv_multigrid) {
    errorQuda("Error: Cannot use both deflation and multigrid preconditioners on top level solve");
  }

  if (dslash_type != QUDA_WILSON_DSLASH && dslash_type != QUDA_CLOVER_WILSON_DSLASH
      && dslash_type != QUDA_TWISTED_MASS_DSLASH && dslash_type != QUDA_DOMAIN_WALL_4D_DSLASH
      && dslash_type != QUDA_MOBIUS_DWF_DSLASH && dslash_type != QUDA_MOBIUS_DWF_EOFA_DSLASH
      && dslash_type != QUDA_TWISTED_CLOVER_DSLASH && dslash_type != QUDA_DOMAIN_WALL_DSLASH) {
    errorQuda("dslash_type %d not supported", dslash_type);
  }

  if (inv_multigrid) {
    // Only these fermions are supported with MG
    if (dslash_type != QUDA_WILSON_DSLASH && dslash_type != QUDA_CLOVER_WILSON_DSLASH
        && dslash_type != QUDA_TWISTED_MASS_DSLASH && dslash_type != QUDA_TWISTED_CLOVER_DSLASH) {
      errorQuda("dslash_type %d not supported for MG\n", dslash_type);
    }

    // Only these solve types are supported with MG
    if (solve_type != QUDA_DIRECT_SOLVE && solve_type != QUDA_DIRECT_PC_SOLVE) {
      errorQuda("Solve_type %d not supported with MG. Please use QUDA_DIRECT_SOLVE or QUDA_DIRECT_PC_SOLVE", solve_type);
    }
  }

  // All parameters have been set. Display the parameters via stdout
  display_test_info();

  initQuda(device_ordinal);

  init(argc, argv);

  int result = 0;
  if (enable_testing) { // tests are defined in invert_test_gtest.hpp
    ::testing::TestEventListeners &listeners = ::testing::UnitTest::GetInstance()->listeners();
    if (quda::comm_rank() != 0) { delete listeners.Release(listeners.default_result_printer()); }
    result = RUN_ALL_TESTS();
  } else {
    for (int rep = 0; rep < nrepeat; rep++)
      solve(test_t {prec, prec_sloppy, inv_type, solution_type, solve_type, multishift, solution_accumulator_pipeline,
                    schwarz_t {precon_schwarz_type, inv_multigrid ? QUDA_MG_INVERTER : precon_type, prec_precondition},
                    inv_param.residual_type});
  }

  // finalize the QUDA library
  freeGaugeQuda();
  if (dslash_type == QUDA_CLOVER_WILSON_DSLASH || dslash_type == QUDA_TWISTED_CLOVER_DSLASH) freeCloverQuda();
  endQuda();
  finalizeComms();

  return result;
}
