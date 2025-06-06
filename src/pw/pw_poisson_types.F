!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief functions related to the poisson solver on regular grids
!> \par History
!>      greens_fn: JGH (9-Mar-2001) : include influence_fn into
!>                         greens_fn_type add cell volume
!>                         as indicator for updates
!>      greens_fn: JGH (30-Mar-2001) : Added B-spline routines
!>      pws      : JGH (13-Mar-2001) : new pw_poisson_solver, delete
!>                         pw_greens_fn
!>      12.2004 condensed from pws, greens_fn and green_fns, by apsi and JGH,
!>              made thread safe, new input [fawzi]
!>      14-Mar-2006 : added short range screening function for SE codes
!> \author fawzi
! **************************************************************************************************
MODULE pw_poisson_types
   USE bessel_lib,                      ONLY: bessk0,&
                                              bessk1
   USE dielectric_types,                ONLY: dielectric_parameters
   USE dirichlet_bc_types,              ONLY: dirichlet_bc_parameters
   USE kinds,                           ONLY: dp
   USE mathconstants,                   ONLY: fourpi,&
                                              twopi
   USE mt_util,                         ONLY: MT0D,&
                                              MT1D,&
                                              MT2D,&
                                              MTin_create_screen_fn
   USE ps_implicit_types,               ONLY: MIXED_BC,&
                                              NEUMANN_BC,&
                                              ps_implicit_parameters,&
                                              ps_implicit_release,&
                                              ps_implicit_type
   USE ps_wavelet_types,                ONLY: WAVELET0D,&
                                              ps_wavelet_release,&
                                              ps_wavelet_type
   USE pw_grid_types,                   ONLY: pw_grid_type
   USE pw_grids,                        ONLY: pw_grid_release
   USE pw_pool_types,                   ONLY: pw_pool_create,&
                                              pw_pool_p_type,&
                                              pw_pool_release,&
                                              pw_pool_type,&
                                              pw_pools_dealloc
   USE pw_types,                        ONLY: pw_c1d_gs_type,&
                                              pw_r1d_gs_type
   USE realspace_grid_types,            ONLY: realspace_grid_type,&
                                              rs_grid_release
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'pw_poisson_types'

   PUBLIC :: pw_poisson_type
   PUBLIC :: greens_fn_type, pw_green_create, &
             pw_green_release
   PUBLIC :: pw_poisson_parameter_type

   INTEGER, PARAMETER, PUBLIC               :: pw_poisson_none = 0, &
                                               pw_poisson_periodic = 1, &
                                               pw_poisson_analytic = 2, &
                                               pw_poisson_mt = 3, &
                                               pw_poisson_hockney = 5, &
                                               pw_poisson_multipole = 4, &
                                               pw_poisson_wavelet = 6, &
                                               pw_poisson_implicit = 7
   ! EWALD methods
   INTEGER, PARAMETER, PUBLIC               :: do_ewald_none = 1, &
                                               do_ewald_ewald = 2, &
                                               do_ewald_pme = 3, &
                                               do_ewald_spme = 4

   INTEGER, PARAMETER, PUBLIC               :: PERIODIC3D = 1000, &
                                               ANALYTIC2D = 1001, &
                                               ANALYTIC1D = 1002, &
                                               ANALYTIC0D = 1003, &
                                               HOCKNEY2D = 1201, &
                                               HOCKNEY1D = 1202, &
                                               HOCKNEY0D = 1203, &
                                               MULTIPOLE2D = 1301, &
                                               MULTIPOLE1D = 1302, &
                                               MULTIPOLE0D = 1303, &
                                               PS_IMPLICIT = 1400

! **************************************************************************************************
!> \brief parameters for the poisson solver independet of input_section
!> \author Ole Schuett
! **************************************************************************************************
   TYPE pw_poisson_parameter_type
      INTEGER                        :: solver = pw_poisson_none

      INTEGER, DIMENSION(3)          :: periodic = 0
      INTEGER                        :: ewald_type = do_ewald_none
      INTEGER                        :: ewald_o_spline = 0
      REAL(KIND=dp)                 :: ewald_alpha = 0.0_dp

      REAL(KIND=dp)                 :: mt_rel_cutoff = 0.0_dp
      REAL(KIND=dp)                 :: mt_alpha = 0.0_dp

      INTEGER                        :: wavelet_scf_type = 0
      INTEGER                        :: wavelet_method = WAVELET0D
      INTEGER                        :: wavelet_special_dimension = 0
      CHARACTER(LEN=1)               :: wavelet_geocode = "S"

      LOGICAL                        :: has_dielectric = .FALSE.
      TYPE(dielectric_parameters)    :: dielectric_params = dielectric_parameters()
      TYPE(ps_implicit_parameters)   :: ps_implicit_params = ps_implicit_parameters()
      TYPE(dirichlet_bc_parameters)  :: dbc_params = dirichlet_bc_parameters()
   END TYPE pw_poisson_parameter_type

! **************************************************************************************************
!> \brief environment for the poisson solver
!> \author fawzi
! **************************************************************************************************
   TYPE pw_poisson_type
      INTEGER :: pw_level = 0
      INTEGER :: method = pw_poisson_none
      INTEGER :: used_grid = 0
      LOGICAL :: rebuild = .TRUE.
      TYPE(greens_fn_type), POINTER               :: green_fft => NULL()
      TYPE(ps_wavelet_type), POINTER               :: wavelet => NULL()
      TYPE(pw_poisson_parameter_type)             :: parameters = pw_poisson_parameter_type()
      REAL(KIND=dp), DIMENSION(3, 3)             :: cell_hmat = 0.0_dp
      TYPE(pw_pool_p_type), DIMENSION(:), POINTER :: pw_pools => NULL()
      TYPE(pw_grid_type), POINTER                 :: mt_super_ref_pw_grid => NULL()
      TYPE(ps_implicit_type), POINTER             :: implicit_env => NULL()
      TYPE(pw_grid_type), POINTER                 :: dct_pw_grid => NULL()
      TYPE(realspace_grid_type), POINTER          :: diel_rs_grid => NULL()
   CONTAINS
      PROCEDURE, PUBLIC, NON_OVERRIDABLE :: create => pw_poisson_create
      PROCEDURE, PUBLIC, NON_OVERRIDABLE :: release => pw_poisson_release
   END TYPE pw_poisson_type

! **************************************************************************************************
!> \brief contains all the informations needed by the fft based poisson solvers
!> \author JGH,Teo,fawzi
! **************************************************************************************************
   TYPE greens_fn_type
      INTEGER :: method = PERIODIC3D
      INTEGER :: special_dimension = 0
      REAL(KIND=dp) :: radius = 0.0_dp
      REAL(KIND=dp) :: MT_alpha = 1.0_dp
      REAL(KIND=dp) :: MT_rel_cutoff = 1.0_dp
      REAL(KIND=dp) :: slab_size = 0.0_dp
      REAL(KIND=dp) :: alpha = 0.0_dp
      LOGICAL :: p3m = .FALSE.
      INTEGER :: p3m_order = 0
      REAL(KIND=dp) :: p3m_alpha = 0.0_dp
      REAL(KIND=dp), DIMENSION(:, :), ALLOCATABLE :: p3m_coeff
      REAL(KIND=dp), DIMENSION(:, :), ALLOCATABLE :: p3m_bm2
      LOGICAL :: sr_screening = .FALSE.
      REAL(KIND=dp) :: sr_alpha = 1.0_dp
      REAL(KIND=dp) :: sr_rc = 0.0_dp
      TYPE(pw_c1d_gs_type) :: influence_fn = pw_c1d_gs_type()
      TYPE(pw_c1d_gs_type), POINTER :: dct_influence_fn => NULL()
      TYPE(pw_c1d_gs_type), POINTER :: screen_fn => NULL()
      TYPE(pw_r1d_gs_type), POINTER :: p3m_charge => NULL()
   END TYPE greens_fn_type

CONTAINS

! **************************************************************************************************
!> \brief Allocates and sets up the green functions for the fft based poisson
!>      solvers
!> \param green ...
!> \param poisson_params ...
!> \param cell_hmat ...
!> \param pw_pool ...
!> \param mt_super_ref_pw_grid ...
!> \param dct_pw_grid ...
!> \author Fawzi, based on previous functions by JGH and Teo
! **************************************************************************************************
   SUBROUTINE pw_green_create(green, poisson_params, cell_hmat, pw_pool, &
                              mt_super_ref_pw_grid, dct_pw_grid)
      TYPE(greens_fn_type), INTENT(OUT)                  :: green
      TYPE(pw_poisson_parameter_type), INTENT(IN)        :: poisson_params
      REAL(KIND=dp), DIMENSION(3, 3), INTENT(IN)         :: cell_hmat
      TYPE(pw_pool_type), POINTER                        :: pw_pool
      TYPE(pw_grid_type), POINTER                        :: mt_super_ref_pw_grid, dct_pw_grid

      INTEGER                                            :: dim, i, ig, iz, n, nz
      REAL(KIND=dp)                                      :: g2, g3d, gg, gxy, gz, j0g, j1g, k0g, &
                                                            k1g, rlength, zlength
      REAL(KIND=dp), DIMENSION(3)                        :: abc
      TYPE(pw_c1d_gs_type), POINTER                      :: dct_gf
      TYPE(pw_grid_type), POINTER                        :: dct_grid
      TYPE(pw_pool_type), POINTER                        :: pw_pool_xpndd

      !CPASSERT(cell%orthorhombic)
      DO i = 1, 3
         abc(i) = cell_hmat(i, i)
      END DO
      dim = COUNT(poisson_params%periodic == 1)

      SELECT CASE (poisson_params%solver)
      CASE (pw_poisson_periodic)
         green%method = PERIODIC3D
         IF (dim /= 3) THEN
            CPABORT("Illegal combination of periodicity and Poisson solver periodic3d")
         END IF
      CASE (pw_poisson_multipole)
         green%method = MULTIPOLE0D
         IF (dim /= 0) THEN
            CPABORT("Illegal combination of periodicity and Poisson solver mulipole0d")
         END IF
      CASE (pw_poisson_analytic)
         SELECT CASE (dim)
         CASE (0)
            green%method = ANALYTIC0D
            green%radius = 0.5_dp*MINVAL(abc)
         CASE (1)
            green%method = ANALYTIC1D
            green%special_dimension = MAXLOC(poisson_params%periodic(1:3), 1)
            green%radius = MAXVAL(abc(1:3))
            DO i = 1, 3
               IF (i == green%special_dimension) CYCLE
               green%radius = MIN(green%radius, 0.5_dp*abc(i))
            END DO
         CASE (2)
            green%method = ANALYTIC2D
            i = MINLOC(poisson_params%periodic, 1)
            green%special_dimension = i
            green%slab_size = abc(i)
         CASE (3)
            green%method = PERIODIC3D
         CASE DEFAULT
            CPABORT("")
         END SELECT
      CASE (pw_poisson_mt)
         green%MT_rel_cutoff = poisson_params%mt_rel_cutoff
         green%MT_alpha = poisson_params%mt_alpha
         green%MT_alpha = green%MT_alpha/MINVAL(abc)
         SELECT CASE (dim)
         CASE (0)
            green%method = MT0D
            green%radius = 0.5_dp*MINVAL(abc)
         CASE (1)
            green%method = MT1D
            green%special_dimension = MAXLOC(poisson_params%periodic(1:3), 1)
            green%radius = MAXVAL(abc(1:3))
            DO i = 1, 3
               IF (i == green%special_dimension) CYCLE
               green%radius = MIN(green%radius, 0.5_dp*abc(i))
            END DO
         CASE (2)
            green%method = MT2D
            i = MINLOC(poisson_params%periodic, 1)
            green%special_dimension = i
            green%slab_size = abc(i)
         CASE (3)
            CPABORT("Illegal combination of periodicity and Poisson solver (MT)")
         CASE DEFAULT
            CPABORT("")
         END SELECT
      CASE (pw_poisson_implicit)
         green%method = PS_IMPLICIT
      CASE DEFAULT
         CPABORT("An unknown Poisson solver was specified")
      END SELECT

      ! allocate influence function,...
      SELECT CASE (green%method)
      CASE (PERIODIC3D, ANALYTIC2D, ANALYTIC1D, ANALYTIC0D, MT2D, MT1D, MT0D, MULTIPOLE0D, PS_IMPLICIT)
         CALL pw_pool%create_pw(green%influence_fn)

         IF (poisson_params%ewald_type == do_ewald_spme) THEN
            green%p3m = .TRUE.
            green%p3m_order = poisson_params%ewald_o_spline
            green%p3m_alpha = poisson_params%ewald_alpha
            n = green%p3m_order
            ALLOCATE (green%p3m_coeff(-(n - 1):n - 1, 0:n - 1))
            CALL spme_coeff_calculate(n, green%p3m_coeff)
            NULLIFY (green%p3m_charge)
            ALLOCATE (green%p3m_charge)
            CALL pw_pool%create_pw(green%p3m_charge)
            CALL influence_factor(green)
            CALL calc_p3m_charge(green)
         ELSE
            green%p3m = .FALSE.
         END IF
         !
         SELECT CASE (green%method)
         CASE (MT0D, MT1D, MT2D)
            CALL MTin_create_screen_fn(green%screen_fn, pw_pool=pw_pool, method=green%method, &
                                       alpha=green%MT_alpha, &
                                       special_dimension=green%special_dimension, slab_size=green%slab_size, &
                                       super_ref_pw_grid=mt_super_ref_pw_grid)
         CASE (PS_IMPLICIT)
            IF ((poisson_params%ps_implicit_params%boundary_condition .EQ. MIXED_BC) .OR. &
                (poisson_params%ps_implicit_params%boundary_condition .EQ. NEUMANN_BC)) THEN
               CALL pw_pool_create(pw_pool_xpndd, pw_grid=dct_pw_grid)
               NULLIFY (green%dct_influence_fn)
               ALLOCATE (green%dct_influence_fn)
               CALL pw_pool_xpndd%create_pw(green%dct_influence_fn)
               CALL pw_pool_release(pw_pool_xpndd)
            END IF
         END SELECT

      CASE DEFAULT
         CPABORT("")
      END SELECT

      ! initialize influence function
      ASSOCIATE (gf => green%influence_fn, grid => green%influence_fn%pw_grid)
         SELECT CASE (green%method)
         CASE (PERIODIC3D, MULTIPOLE0D)

            DO ig = grid%first_gne0, grid%ngpts_cut_local
               g2 = grid%gsq(ig)
               gf%array(ig) = fourpi/g2
            END DO
            IF (grid%have_g0) gf%array(1) = 0.0_dp

         CASE (ANALYTIC2D)

            iz = green%special_dimension ! iz is the direction with NO PBC
            zlength = green%slab_size ! zlength is the thickness of the cell
            DO ig = grid%first_gne0, grid%ngpts_cut_local
               nz = grid%g_hat(iz, ig)
               g2 = grid%gsq(ig)
               g3d = fourpi/g2
               gxy = MAX(0.0_dp, g2 - grid%g(iz, ig)*grid%g(iz, ig))
               gg = 0.5_dp*SQRT(gxy)
               gf%array(ig) = g3d*(1.0_dp - (-1.0_dp)**nz*EXP(-gg*zlength))
            END DO
            IF (grid%have_g0) gf%array(1) = 0.0_dp

         CASE (ANALYTIC1D)
            ! see 'ab initio molecular dynamics' table 3.1
            ! iz is the direction of the PBC ( can be 1,2,3 -> x,y,z )
            iz = green%special_dimension
            ! rlength is the radius of the tube
            rlength = green%radius
            DO ig = grid%first_gne0, grid%ngpts_cut_local
               g2 = grid%gsq(ig)
               g3d = fourpi/g2
               gxy = SQRT(MAX(0.0_dp, g2 - grid%g(iz, ig)*grid%g(iz, ig)))
               gz = ABS(grid%g(iz, ig))
               j0g = BESSEL_J0(rlength*gxy)
               j1g = BESSEL_J1(rlength*gxy)
               IF (gz > 0) THEN
                  k0g = bessk0(rlength*gz)
                  k1g = bessk1(rlength*gz)
               ELSE
                  k0g = 0
                  k1g = 0
               END IF
               gf%array(ig) = g3d*(1.0_dp + rlength* &
                                   (gxy*j1g*k0g - gz*j0g*k1g))
            END DO
            IF (grid%have_g0) gf%array(1) = 0.0_dp

         CASE (ANALYTIC0D)

            rlength = green%radius ! rlength is the radius of the sphere
            DO ig = grid%first_gne0, grid%ngpts_cut_local
               g2 = grid%gsq(ig)
               gg = SQRT(g2)
               g3d = fourpi/g2
               gf%array(ig) = g3d*(1.0_dp - COS(rlength*gg))
            END DO
            IF (grid%have_g0) &
               gf%array(1) = 0.5_dp*fourpi*rlength*rlength

         CASE (MT2D, MT1D, MT0D)

            DO ig = grid%first_gne0, grid%ngpts_cut_local
               g2 = grid%gsq(ig)
               g3d = fourpi/g2
               gf%array(ig) = g3d + green%screen_fn%array(ig)
            END DO
            IF (grid%have_g0) &
               gf%array(1) = green%screen_fn%array(1)

         CASE (PS_IMPLICIT)

            DO ig = grid%first_gne0, grid%ngpts_cut_local
               g2 = grid%gsq(ig)
               gf%array(ig) = fourpi/g2
            END DO
            IF (grid%have_g0) gf%array(1) = 0.0_dp

            IF (ASSOCIATED(green%dct_influence_fn)) THEN
               dct_gf => green%dct_influence_fn
               dct_grid => green%dct_influence_fn%pw_grid

               DO ig = dct_grid%first_gne0, dct_grid%ngpts_cut_local
                  g2 = dct_grid%gsq(ig)
                  dct_gf%array(ig) = fourpi/g2
               END DO
               IF (dct_grid%have_g0) dct_gf%array(1) = 0.0_dp
            END IF

         CASE DEFAULT
            CPABORT("")
         END SELECT
      END ASSOCIATE

   END SUBROUTINE pw_green_create

! **************************************************************************************************
!> \brief destroys the type (deallocates data)
!> \param gftype ...
!> \param pw_pool ...
!> \par History
!>      none
!> \author Joost VandeVondele
!>      Teodoro Laino
! **************************************************************************************************
   SUBROUTINE pw_green_release(gftype, pw_pool)
      TYPE(greens_fn_type), INTENT(INOUT)                :: gftype
      TYPE(pw_pool_type), OPTIONAL, POINTER              :: pw_pool

      LOGICAL                                            :: can_give_back

      can_give_back = PRESENT(pw_pool)
      IF (can_give_back) can_give_back = ASSOCIATED(pw_pool)
      IF (can_give_back) THEN
         CALL pw_pool%give_back_pw(gftype%influence_fn)
         IF (ASSOCIATED(gftype%dct_influence_fn)) THEN
            CALL pw_pool%give_back_pw(gftype%dct_influence_fn)
            DEALLOCATE (gftype%dct_influence_fn)
         END IF
         IF (ASSOCIATED(gftype%screen_fn)) THEN
            CALL pw_pool%give_back_pw(gftype%screen_fn)
            DEALLOCATE (gftype%screen_fn)
         END IF
         IF (ASSOCIATED(gftype%p3m_charge)) THEN
            CALL pw_pool%give_back_pw(gftype%p3m_charge)
            DEALLOCATE (gftype%p3m_charge)
         END IF
      ELSE
         CALL gftype%influence_fn%release()
         IF (ASSOCIATED(gftype%dct_influence_fn)) THEN
            CALL gftype%dct_influence_fn%release()
            DEALLOCATE (gftype%dct_influence_fn)
         END IF
         IF (ASSOCIATED(gftype%screen_fn)) THEN
            CALL gftype%screen_fn%release()
            DEALLOCATE (gftype%screen_fn)
         END IF
         IF (ASSOCIATED(gftype%p3m_charge)) THEN
            CALL gftype%p3m_charge%release()
            DEALLOCATE (gftype%p3m_charge)
         END IF
      END IF
      IF (ALLOCATED(gftype%p3m_bm2)) &
         DEALLOCATE (gftype%p3m_bm2)
      IF (ALLOCATED(gftype%p3m_coeff)) &
         DEALLOCATE (gftype%p3m_coeff)
   END SUBROUTINE pw_green_release

! **************************************************************************************************
!> \brief Calculates the influence_factor for the
!>      SPME Green's function in reciprocal space'''
!> \param gftype ...
!> \par History
!>      none
!> \author DH (29-Mar-2001)
! **************************************************************************************************
   SUBROUTINE influence_factor(gftype)
      TYPE(greens_fn_type), INTENT(INOUT)                :: gftype

      COMPLEX(KIND=dp)                                   :: b_m, exp_m, sum_m
      INTEGER                                            :: dim, j, k, l, n, pt
      INTEGER, DIMENSION(3)                              :: npts
      INTEGER, DIMENSION(:), POINTER                     :: lb, ub
      REAL(KIND=dp)                                      :: l_arg, prod_arg, val
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: m_assign

      n = gftype%p3m_order

      ! calculate the assignment function values

      lb => gftype%influence_fn%pw_grid%bounds(1, :)
      ub => gftype%influence_fn%pw_grid%bounds(2, :)
      IF (ALLOCATED(gftype%p3m_bm2)) THEN
         IF (LBOUND(gftype%p3m_bm2, 2) /= MINVAL(lb(:)) .OR. &
             UBOUND(gftype%p3m_bm2, 2) /= MAXVAL(ub(:))) THEN
            DEALLOCATE (gftype%p3m_bm2)
         END IF
      END IF
      IF (.NOT. ALLOCATED(gftype%p3m_bm2)) THEN
         ALLOCATE (gftype%p3m_bm2(3, MINVAL(lb(:)):MAXVAL(ub(:))))
      END IF

      ALLOCATE (m_assign(0:n - 2))
      m_assign = 0.0_dp
      DO k = 0, n - 2
         j = -(n - 1) + 2*k
         DO l = 0, n - 1
            l_arg = 0.5_dp**l
            prod_arg = gftype%p3m_coeff(j, l)*l_arg
            m_assign(k) = m_assign(k) + prod_arg
         END DO
      END DO

      ! calculate the absolute b values

      npts(:) = ub(:) - lb(:) + 1
      DO dim = 1, 3
         DO pt = lb(dim), ub(dim)
            val = twopi*(REAL(pt, KIND=dp)/REAL(npts(dim), KIND=dp))
            exp_m = CMPLX(COS(val), -SIN(val), KIND=dp)
            sum_m = CMPLX(0.0_dp, 0.0_dp, KIND=dp)
            DO k = 0, n - 2
               sum_m = sum_m + m_assign(k)*exp_m**k
            END DO
            b_m = exp_m**(n - 1)/sum_m
            gftype%p3m_bm2(dim, pt) = SQRT(REAL(b_m*CONJG(b_m), KIND=dp))
         END DO
      END DO

      DEALLOCATE (m_assign)
   END SUBROUTINE influence_factor

! **************************************************************************************************
!> \brief ...
!> \param gf ...
! **************************************************************************************************
   PURE SUBROUTINE calc_p3m_charge(gf)

      TYPE(greens_fn_type), INTENT(INOUT)                :: gf

      INTEGER                                            :: ig, l, m, n
      REAL(KIND=dp)                                      :: arg, novol

      ! check if charge function is consistent with current box volume

      ASSOCIATE (grid => gf%influence_fn%pw_grid, bm2 => gf%p3m_bm2)
         arg = 1.0_dp/(8.0_dp*gf%p3m_alpha**2)
         novol = REAL(grid%ngpts, KIND=dp)/grid%vol
         DO ig = 1, grid%ngpts_cut_local
            l = grid%g_hat(1, ig)
            m = grid%g_hat(2, ig)
            n = grid%g_hat(3, ig)
            gf%p3m_charge%array(ig) = novol*EXP(-arg*grid%gsq(ig))* &
                                      bm2(1, l)*bm2(2, m)*bm2(3, n)
         END DO
      END ASSOCIATE

   END SUBROUTINE calc_p3m_charge

! **************************************************************************************************
!> \brief Initialize the poisson solver
!>      You should call this just before calling the work routine
!>      pw_poisson_solver
!>      Call pw_poisson_release when you have finished
!> \param poisson_env ...
!> \par History
!>      none
!> \author JGH (12-Mar-2001)
! **************************************************************************************************
   SUBROUTINE pw_poisson_create(poisson_env)

      CLASS(pw_poisson_type), INTENT(INOUT)              :: poisson_env

      ! Cleanup a potential previous poisson_env
      CALL poisson_env%release()

   END SUBROUTINE pw_poisson_create

! **************************************************************************************************
!> \brief releases the poisson solver
!> \param poisson_env ...
!> \par History
!>      none
!> \author fawzi (11.2002)
! **************************************************************************************************
   SUBROUTINE pw_poisson_release(poisson_env)

      CLASS(pw_poisson_type), INTENT(INOUT)               :: poisson_env

      IF (ASSOCIATED(poisson_env%pw_pools)) THEN
         CALL pw_pools_dealloc(poisson_env%pw_pools)
      END IF

      IF (ASSOCIATED(poisson_env%green_fft)) THEN
         CALL pw_green_release(poisson_env%green_fft)
         DEALLOCATE (poisson_env%green_fft)
      END IF
      CALL pw_grid_release(poisson_env%mt_super_ref_pw_grid)
      CALL ps_wavelet_release(poisson_env%wavelet)
      CALL ps_implicit_release(poisson_env%implicit_env, &
                               poisson_env%parameters%ps_implicit_params)
      CALL pw_grid_release(poisson_env%dct_pw_grid)
      IF (ASSOCIATED(poisson_env%diel_rs_grid)) THEN
         CALL rs_grid_release(poisson_env%diel_rs_grid)
         DEALLOCATE (poisson_env%diel_rs_grid)
      END IF

   END SUBROUTINE pw_poisson_release

! **************************************************************************************************
!> \brief Calculates the coefficients for the charge assignment function
!> \param n ...
!> \param coeff ...
!> \par History
!>      none
!> \author DG (29-Mar-2001)
! **************************************************************************************************
   SUBROUTINE spme_coeff_calculate(n, coeff)

      INTEGER, INTENT(IN)                                :: n
      REAL(KIND=dp), DIMENSION(-(n-1):n-1, 0:n-1), &
         INTENT(OUT)                                     :: coeff

      INTEGER                                            :: i, j, l, m
      REAL(KIND=dp)                                      :: b
      REAL(KIND=dp), DIMENSION(n, -n:n, 0:n-1)           :: a

      a = 0.0_dp
      a(1, 0, 0) = 1.0_dp

      DO i = 2, n
         m = i - 1
         DO j = -m, m, 2
            DO l = 0, m - 1
               b = (a(m, j - 1, l) + &
                    REAL((-1)**l, KIND=dp)*a(m, j + 1, l))/ &
                   REAL((l + 1)*2**(l + 1), KIND=dp)
               a(i, j, 0) = a(i, j, 0) + b
            END DO
            DO l = 0, m - 1
               a(i, j, l + 1) = (a(m, j + 1, l) - &
                                 a(m, j - 1, l))/REAL(l + 1, KIND=dp)
            END DO
         END DO
      END DO

      coeff = 0.0_dp
      DO i = 0, n - 1
         DO j = -(n - 1), n - 1, 2
            coeff(j, i) = a(n, j, i)
         END DO
      END DO

   END SUBROUTINE spme_coeff_calculate

END MODULE pw_poisson_types
