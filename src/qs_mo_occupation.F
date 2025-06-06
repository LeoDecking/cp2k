!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Set occupation of molecular orbitals
!> \par History
!>      - set_mo_occupation subroutines moved from qs_mo_types (11.12.2014 MI)
!> \author  MI
! **************************************************************************************************

MODULE qs_mo_occupation

   USE cp_control_types,                ONLY: hairy_probes_type
   USE cp_log_handling,                 ONLY: cp_to_string
   USE fermi_utils,                     ONLY: FermiFixed,&
                                              FermiFixedDeriv
   USE hairy_probes,                    ONLY: probe_occupancy
   USE input_constants,                 ONLY: smear_energy_window,&
                                              smear_fermi_dirac,&
                                              smear_list
   USE kahan_sum,                       ONLY: accurate_sum
   USE kinds,                           ONLY: dp
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              has_uniform_occupation,&
                                              mo_set_type,&
                                              set_mo_set
   USE scf_control_types,               ONLY: smear_type
   USE util,                            ONLY: sort
   USE xas_env_types,                   ONLY: get_xas_env,&
                                              xas_environment_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_mo_occupation'

   PUBLIC :: set_mo_occupation

   INTERFACE set_mo_occupation
      MODULE PROCEDURE set_mo_occupation_1, set_mo_occupation_2
   END INTERFACE

CONTAINS

! **************************************************************************************************
!> \brief  Occupation for smeared spin polarized electronic structures
!>         with relaxed multiplicity
!>
!> \param mo_array ...
!> \param smear ...
!> \date    10.03.2011 (MI)
!> \author  MI
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE set_mo_occupation_3(mo_array, smear)

      TYPE(mo_set_type), DIMENSION(2), INTENT(INOUT)     :: mo_array
      TYPE(smear_type), POINTER                          :: smear

      CHARACTER(LEN=*), PARAMETER :: routineN = 'set_mo_occupation_3'

      INTEGER                                            :: all_nmo, handle, homo_a, homo_b, i, &
                                                            lfomo_a, lfomo_b, nmo_a, nmo_b, &
                                                            xas_estate
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: all_index
      LOGICAL                                            :: is_large
      REAL(KIND=dp)                                      :: all_nelec, kTS, mu, nelec_a, nelec_b, &
                                                            occ_estate
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: all_eigval, all_occ
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigval_a, eigval_b, occ_a, occ_b

      CALL timeset(routineN, handle)

      NULLIFY (eigval_a, eigval_b, occ_a, occ_b)
      CALL get_mo_set(mo_set=mo_array(1), nmo=nmo_a, eigenvalues=eigval_a, &
                      occupation_numbers=occ_a)
      CALL get_mo_set(mo_set=mo_array(2), nmo=nmo_b, eigenvalues=eigval_b, &
                      occupation_numbers=occ_b)
      all_nmo = nmo_a + nmo_b
      ALLOCATE (all_eigval(all_nmo))
      ALLOCATE (all_occ(all_nmo))
      ALLOCATE (all_index(all_nmo))

      all_eigval(1:nmo_a) = eigval_a(1:nmo_a)
      all_eigval(nmo_a + 1:all_nmo) = eigval_b(1:nmo_b)

      CALL sort(all_eigval, all_nmo, all_index)

      xas_estate = -1
      occ_estate = 0.0_dp

      nelec_a = 0.0_dp
      nelec_b = 0.0_dp
      all_nelec = 0.0_dp
      nelec_a = accurate_sum(occ_a(:))
      nelec_b = accurate_sum(occ_b(:))
      all_nelec = nelec_a + nelec_b

      DO i = 1, all_nmo
         IF (all_index(i) <= nmo_a) THEN
            all_occ(i) = occ_a(all_index(i))
         ELSE
            all_occ(i) = occ_b(all_index(i) - nmo_a)
         END IF
      END DO

      CALL FermiFixed(all_occ, mu, kTS, all_eigval, all_nelec, &
                      smear%electronic_temperature, 1._dp, xas_estate, occ_estate)

      is_large = ABS(MAXVAL(all_occ) - 1.0_dp) > smear%eps_fermi_dirac
      ! this is not a real problem, but the temperature might be a bit large
      CPWARN_IF(is_large, "Fermi-Dirac smearing includes the first MO")

      is_large = ABS(MINVAL(all_occ)) > smear%eps_fermi_dirac
      IF (is_large) &
         CALL cp_warn(__LOCATION__, &
                      "Fermi-Dirac smearing includes the last MO => "// &
                      "Add more MOs for proper smearing.")

      ! check that the total electron count is accurate
      is_large = (ABS(all_nelec - accurate_sum(all_occ(:))) > smear%eps_fermi_dirac*all_nelec)
      CPWARN_IF(is_large, "Total number of electrons is not accurate")

      DO i = 1, all_nmo
         IF (all_index(i) <= nmo_a) THEN
            occ_a(all_index(i)) = all_occ(i)
            eigval_a(all_index(i)) = all_eigval(i)
         ELSE
            occ_b(all_index(i) - nmo_a) = all_occ(i)
            eigval_b(all_index(i) - nmo_a) = all_eigval(i)
         END IF
      END DO

      nelec_a = accurate_sum(occ_a(:))
      nelec_b = accurate_sum(occ_b(:))

      DO i = 1, nmo_a
         IF (occ_a(i) < 1.0_dp) THEN
            lfomo_a = i
            EXIT
         END IF
      END DO
      DO i = 1, nmo_b
         IF (occ_b(i) < 1.0_dp) THEN
            lfomo_b = i
            EXIT
         END IF
      END DO
      homo_a = lfomo_a - 1
      DO i = nmo_a, lfomo_a, -1
         IF (occ_a(i) > smear%eps_fermi_dirac) THEN
            homo_a = i
            EXIT
         END IF
      END DO
      homo_b = lfomo_b - 1
      DO i = nmo_b, lfomo_b, -1
         IF (occ_b(i) > smear%eps_fermi_dirac) THEN
            homo_b = i
            EXIT
         END IF
      END DO

      CALL set_mo_set(mo_set=mo_array(1), kTS=kTS/2.0_dp, mu=mu, n_el_f=nelec_a, &
                      lfomo=lfomo_a, homo=homo_a, uniform_occupation=.FALSE.)
      CALL set_mo_set(mo_set=mo_array(2), kTS=kTS/2.0_dp, mu=mu, n_el_f=nelec_b, &
                      lfomo=lfomo_b, homo=homo_b, uniform_occupation=.FALSE.)

      CALL timestop(handle)

   END SUBROUTINE set_mo_occupation_3

! **************************************************************************************************
!> \brief   Prepare an occupation of alpha and beta MOs following an Aufbau
!>          principle, i.e. allowing a change in multiplicity.
!> \param mo_array ...
!> \param smear ...
!> \param eval_deriv ...
!> \param tot_zeff_corr ...
!> \param probe ...
!> \date    25.01.2010 (MK)
!> \par   History
!>        10.2019 Added functionality to adjust mo occupation if the core
!>                charges are changed via CORE_CORRECTION during surface dipole
!>                calculation. Total number of electrons matches the total core
!>                charges if tot_zeff_corr is non-zero. Not yet implemented for
!>                OT type method. [Soumya Ghosh]
!> \author  Matthias Krack (MK)
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE set_mo_occupation_2(mo_array, smear, eval_deriv, tot_zeff_corr, probe)

      TYPE(mo_set_type), DIMENSION(:), INTENT(INOUT)     :: mo_array
      TYPE(smear_type), POINTER                          :: smear
      REAL(KIND=dp), DIMENSION(:), OPTIONAL, POINTER     :: eval_deriv
      REAL(KIND=dp), OPTIONAL                            :: tot_zeff_corr
      TYPE(hairy_probes_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: probe

      CHARACTER(LEN=*), PARAMETER :: routineN = 'set_mo_occupation_2'

      INTEGER                                            :: handle, i, lumo_a, lumo_b, &
                                                            multiplicity_new, multiplicity_old, &
                                                            nelec
      REAL(KIND=dp)                                      :: nelec_f, threshold
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigval_a, eigval_b

      CALL timeset(routineN, handle)

      ! Fall back for the case that we have only one MO set
      IF (SIZE(mo_array) == 1) THEN
         IF (PRESENT(probe)) THEN
            CALL set_mo_occupation_1(mo_array(1), smear=smear, probe=probe)
         ELSE IF (PRESENT(eval_deriv)) THEN
! Change of MO occupancy to account for CORE_CORRECTION is not yet implemented
            CALL set_mo_occupation_1(mo_array(1), smear=smear, eval_deriv=eval_deriv)
         ELSE
            IF (PRESENT(tot_zeff_corr)) THEN
               CALL set_mo_occupation_1(mo_array(1), smear=smear, tot_zeff_corr=tot_zeff_corr)
            ELSE
               CALL set_mo_occupation_1(mo_array(1), smear=smear)
            END IF
         END IF
         CALL timestop(handle)
         RETURN
      END IF

      IF (PRESENT(probe)) THEN
         CALL set_mo_occupation_1(mo_array(1), smear=smear, probe=probe)
         CALL set_mo_occupation_1(mo_array(2), smear=smear, probe=probe)
      END IF

      IF (smear%do_smear) THEN
         IF (smear%fixed_mag_mom < 0.0_dp) THEN
            IF (PRESENT(tot_zeff_corr)) THEN
               CALL cp_warn(__LOCATION__, &
                            "CORE_CORRECTION /= 0.0 might cause the cell to charge up "// &
                            "that will lead to application of different background "// &
                            "correction compared to the reference system. "// &
                            "Use FIXED_MAGNETIC_MOMENT >= 0.0 if using SMEAR keyword "// &
                            "to correct the electron density")
            END IF
            IF (smear%fixed_mag_mom /= -1.0_dp) THEN
               CPASSERT(.NOT. (PRESENT(eval_deriv)))
               CALL set_mo_occupation_3(mo_array, smear=smear)
               CALL timestop(handle)
               RETURN
            END IF
         ELSE
            nelec_f = mo_array(1)%n_el_f + mo_array(2)%n_el_f
            IF (ABS((mo_array(1)%n_el_f - mo_array(2)%n_el_f) - smear%fixed_mag_mom) > smear%eps_fermi_dirac*nelec_f) THEN
               mo_array(1)%n_el_f = nelec_f/2.0_dp + smear%fixed_mag_mom/2.0_dp
               mo_array(2)%n_el_f = nelec_f/2.0_dp - smear%fixed_mag_mom/2.0_dp
            END IF
            CPASSERT(.NOT. (PRESENT(eval_deriv)))
            IF (PRESENT(tot_zeff_corr)) THEN
               CALL set_mo_occupation_1(mo_array(1), smear=smear, tot_zeff_corr=tot_zeff_corr)
               CALL set_mo_occupation_1(mo_array(2), smear=smear, tot_zeff_corr=tot_zeff_corr)
            ELSE
               CALL set_mo_occupation_1(mo_array(1), smear=smear)
               CALL set_mo_occupation_1(mo_array(2), smear=smear)
            END IF
         END IF
      END IF

      IF (.NOT. ((mo_array(1)%flexible_electron_count > 0.0_dp) .AND. &
                 (mo_array(2)%flexible_electron_count > 0.0_dp))) THEN
         IF (PRESENT(probe)) THEN
            CALL set_mo_occupation_1(mo_array(1), smear=smear, probe=probe)
            CALL set_mo_occupation_1(mo_array(2), smear=smear, probe=probe)
         ELSE IF (PRESENT(eval_deriv)) THEN
            CALL set_mo_occupation_1(mo_array(1), smear=smear, eval_deriv=eval_deriv)
            CALL set_mo_occupation_1(mo_array(2), smear=smear, eval_deriv=eval_deriv)
         ELSE
            IF (PRESENT(tot_zeff_corr)) THEN
               CALL set_mo_occupation_1(mo_array(1), smear=smear, tot_zeff_corr=tot_zeff_corr)
               CALL set_mo_occupation_1(mo_array(2), smear=smear, tot_zeff_corr=tot_zeff_corr)
            ELSE
               CALL set_mo_occupation_1(mo_array(1), smear=smear)
               CALL set_mo_occupation_1(mo_array(2), smear=smear)
            END IF
         END IF
         CALL timestop(handle)
         RETURN
      END IF

      nelec = mo_array(1)%nelectron + mo_array(2)%nelectron

      multiplicity_old = mo_array(1)%nelectron - mo_array(2)%nelectron + 1

      IF (mo_array(1)%nelectron >= mo_array(1)%nmo) &
         CALL cp_warn(__LOCATION__, &
                      "All alpha MOs are occupied. Add more alpha MOs to "// &
                      "allow for a higher multiplicity")
      IF ((mo_array(2)%nelectron >= mo_array(2)%nmo) .AND. (mo_array(2)%nelectron /= mo_array(1)%nelectron)) &
         CALL cp_warn(__LOCATION__, "All beta MOs are occupied. Add more beta MOs to "// &
                      "allow for a lower multiplicity")

      eigval_a => mo_array(1)%eigenvalues
      eigval_b => mo_array(2)%eigenvalues

      lumo_a = 1
      lumo_b = 1

      ! Apply Aufbau principle
      DO i = 1, nelec
         ! Threshold is needed to ensure a preference for alpha occupation in the case
         ! of degeneracy
         threshold = MAX(mo_array(1)%flexible_electron_count, mo_array(2)%flexible_electron_count)
         IF ((eigval_a(lumo_a) - threshold) < eigval_b(lumo_b)) THEN
            lumo_a = lumo_a + 1
         ELSE
            lumo_b = lumo_b + 1
         END IF
         IF (lumo_a > mo_array(1)%nmo) THEN
            IF (i /= nelec) &
               CALL cp_warn(__LOCATION__, &
                            "All alpha MOs are occupied. Add more alpha MOs to "// &
                            "allow for a higher multiplicity")
            IF (i < nelec) THEN
               lumo_a = lumo_a - 1
               lumo_b = lumo_b + 1
            END IF
         END IF
         IF (lumo_b > mo_array(2)%nmo) THEN
            IF (lumo_b < lumo_a) &
               CALL cp_warn(__LOCATION__, &
                            "All beta MOs are occupied. Add more beta MOs to "// &
                            "allow for a lower multiplicity")
            IF (i < nelec) THEN
               lumo_a = lumo_a + 1
               lumo_b = lumo_b - 1
            END IF
         END IF
      END DO

      mo_array(1)%homo = lumo_a - 1
      mo_array(2)%homo = lumo_b - 1

      IF (mo_array(2)%homo > mo_array(1)%homo) THEN
         CALL cp_warn(__LOCATION__, &
                      "More beta ("// &
                      TRIM(ADJUSTL(cp_to_string(mo_array(2)%homo)))// &
                      ") than alpha ("// &
                      TRIM(ADJUSTL(cp_to_string(mo_array(1)%homo)))// &
                      ") MOs are occupied. Resorting to low spin state")
         mo_array(1)%homo = nelec/2 + MODULO(nelec, 2)
         mo_array(2)%homo = nelec/2
      END IF

      mo_array(1)%nelectron = mo_array(1)%homo
      mo_array(2)%nelectron = mo_array(2)%homo
      multiplicity_new = mo_array(1)%nelectron - mo_array(2)%nelectron + 1

      IF (multiplicity_new /= multiplicity_old) &
         CALL cp_warn(__LOCATION__, &
                      "Multiplicity changed from "// &
                      TRIM(ADJUSTL(cp_to_string(multiplicity_old)))//" to "// &
                      TRIM(ADJUSTL(cp_to_string(multiplicity_new))))

      IF (PRESENT(probe)) THEN
         CALL set_mo_occupation_1(mo_array(1), smear=smear, probe=probe)
         CALL set_mo_occupation_1(mo_array(2), smear=smear, probe=probe)
      ELSE IF (PRESENT(eval_deriv)) THEN
         CALL set_mo_occupation_1(mo_array(1), smear=smear, eval_deriv=eval_deriv)
         CALL set_mo_occupation_1(mo_array(2), smear=smear, eval_deriv=eval_deriv)
      ELSE
         IF (PRESENT(tot_zeff_corr)) THEN
            CALL set_mo_occupation_1(mo_array(1), smear=smear, tot_zeff_corr=tot_zeff_corr)
            CALL set_mo_occupation_1(mo_array(2), smear=smear, tot_zeff_corr=tot_zeff_corr)
         ELSE
            CALL set_mo_occupation_1(mo_array(1), smear=smear)
            CALL set_mo_occupation_1(mo_array(2), smear=smear)
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE set_mo_occupation_2

! **************************************************************************************************
!> \brief   Smearing of the MO occupation with all kind of occupation numbers
!> \param   mo_set MO dataset structure
!> \param   smear optional smearing information
!> \param   eval_deriv on entry the derivative of the KS energy wrt to the occupation number
!>                     on exit  the derivative of the full free energy (i.e. KS and entropy) wrt to the eigenvalue
!> \param xas_env ...
!> \param tot_zeff_corr ...
!> \param probe ...
!> \date    17.04.2002 (v1.0), 26.08.2008 (v1.1)
!> \par   History
!>        10.2019 Added functionality to adjust mo occupation if the core
!>                charges are changed via CORE_CORRECTION during surface dipole
!>                calculation. Total number of electrons matches the total core
!>                charges if tot_zeff_corr is non-zero. Not yet implemented for
!>                OT type method. [Soumya Ghosh]
!> \author  Matthias Krack
!> \version 1.1
! **************************************************************************************************
   SUBROUTINE set_mo_occupation_1(mo_set, smear, eval_deriv, xas_env, tot_zeff_corr, probe)

      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set
      TYPE(smear_type), OPTIONAL, POINTER                :: smear
      REAL(KIND=dp), DIMENSION(:), OPTIONAL, POINTER     :: eval_deriv
      TYPE(xas_environment_type), OPTIONAL, POINTER      :: xas_env
      REAL(KIND=dp), OPTIONAL                            :: tot_zeff_corr
      TYPE(hairy_probes_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: probe

      CHARACTER(LEN=*), PARAMETER :: routineN = 'set_mo_occupation_1'

      INTEGER                                            :: handle, i_first, imo, ir, irmo, nmo, &
                                                            nomo, xas_estate
      LOGICAL                                            :: equal_size, is_large
      REAL(KIND=dp)                                      :: delectron, e1, e2, edelta, edist, &
                                                            el_count, lengthscale, nelec, &
                                                            occ_estate, total_zeff_corr, &
                                                            xas_nelectron
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: dfde

      CALL timeset(routineN, handle)

      CPASSERT(ASSOCIATED(mo_set%eigenvalues))
      CPASSERT(ASSOCIATED(mo_set%occupation_numbers))
      mo_set%occupation_numbers(:) = 0.0_dp

      ! Quick return, if no electrons are available
      IF (mo_set%nelectron == 0) THEN
         CALL timestop(handle)
         RETURN
      END IF

      xas_estate = -1
      occ_estate = 0.0_dp
      IF (PRESENT(xas_env)) THEN
         CALL get_xas_env(xas_env=xas_env, xas_nelectron=xas_nelectron, occ_estate=occ_estate, xas_estate=xas_estate)
         nomo = CEILING(xas_nelectron + 1.0 - occ_estate - EPSILON(0.0_dp))

         mo_set%occupation_numbers(1:nomo) = mo_set%maxocc
         IF (xas_estate > 0) mo_set%occupation_numbers(xas_estate) = occ_estate
         el_count = SUM(mo_set%occupation_numbers(1:nomo))
         IF (el_count > xas_nelectron) &
            mo_set%occupation_numbers(nomo) = mo_set%occupation_numbers(nomo) - (el_count - xas_nelectron)
         el_count = SUM(mo_set%occupation_numbers(1:nomo))
         is_large = ABS(el_count - xas_nelectron) > xas_nelectron*EPSILON(el_count)
         CPASSERT(.NOT. is_large)
      ELSE
         IF (MODULO(mo_set%nelectron, INT(mo_set%maxocc)) == 0) THEN
            nomo = NINT(mo_set%nelectron/mo_set%maxocc)
            ! Initialize MO occupations
            mo_set%occupation_numbers(1:nomo) = mo_set%maxocc
         ELSE
            nomo = INT(mo_set%nelectron/mo_set%maxocc) + 1
            ! Initialize MO occupations
            mo_set%occupation_numbers(1:nomo - 1) = mo_set%maxocc
            mo_set%occupation_numbers(nomo) = mo_set%nelectron - (nomo - 1)*mo_set%maxocc
         END IF
! introduce applied potential correction here
! electron density is adjusted according to applied core correction
! ref: SS, MT, MWF, JN PRL, 2018, 120, 246801
! see whether both surface dipole correction and core correction is present in
! the inputfile
         IF (PRESENT(tot_zeff_corr)) THEN
! find the additional core charges
            total_zeff_corr = tot_zeff_corr
            IF (INT(mo_set%maxocc) == 1) total_zeff_corr = total_zeff_corr/2.0_dp
            delectron = 0.0_dp
            IF (total_zeff_corr < 0.0_dp) THEN
! remove electron density from the mos
               delectron = ABS(total_zeff_corr) - REAL(mo_set%maxocc, KIND=dp)
               IF (delectron > 0.0_dp) THEN
                  mo_set%occupation_numbers(nomo) = 0.0_dp
                  irmo = CEILING(delectron/REAL(mo_set%maxocc, KIND=dp))
                  DO ir = 1, irmo
                     delectron = delectron - REAL(mo_set%maxocc, KIND=dp)
                     IF (delectron < 0.0_dp) THEN
                        mo_set%occupation_numbers(nomo - ir) = -delectron
                     ELSE
                        mo_set%occupation_numbers(nomo - ir) = 0.0_dp
                     END IF
                  END DO
                  nomo = nomo - irmo
                  IF (mo_set%occupation_numbers(nomo) == 0.0_dp) nomo = nomo - 1
               ELSEIF (delectron < 0.0_dp) THEN
                  mo_set%occupation_numbers(nomo) = -delectron
               ELSE
                  mo_set%occupation_numbers(nomo) = 0.0_dp
                  nomo = nomo - 1
               END IF
            ELSEIF (total_zeff_corr > 0.0_dp) THEN
! add electron density to the mos
               delectron = total_zeff_corr - REAL(mo_set%maxocc, KIND=dp)
               IF (delectron > 0.0_dp) THEN
                  mo_set%occupation_numbers(nomo + 1) = REAL(mo_set%maxocc, KIND=dp)
                  nomo = nomo + 1
                  irmo = CEILING(delectron/REAL(mo_set%maxocc, KIND=dp))
                  DO ir = 1, irmo
                     delectron = delectron - REAL(mo_set%maxocc, KIND=dp)
                     IF (delectron < 0.0_dp) THEN
                        mo_set%occupation_numbers(nomo + ir) = delectron + REAL(mo_set%maxocc, KIND=dp)
                     ELSE
                        mo_set%occupation_numbers(nomo + ir) = REAL(mo_set%maxocc, KIND=dp)
                     END IF
                  END DO
                  nomo = nomo + irmo
               ELSE
                  mo_set%occupation_numbers(nomo + 1) = total_zeff_corr
                  nomo = nomo + 1
               END IF
            END IF
         END IF
      END IF
      nmo = SIZE(mo_set%eigenvalues)

      CPASSERT(nmo >= nomo)
      CPASSERT((SIZE(mo_set%occupation_numbers) == nmo))

      mo_set%homo = nomo
      mo_set%lfomo = nomo + 1
      mo_set%mu = mo_set%eigenvalues(nomo)

      ! Check consistency of the array lengths
      IF (PRESENT(eval_deriv)) THEN
         equal_size = (SIZE(mo_set%occupation_numbers, 1) == SIZE(eval_deriv, 1))
         CPASSERT(equal_size)
      END IF

!calling of HP module HERE, before smear
      IF (PRESENT(probe)) THEN
         i_first = 1
         IF (smear%fixed_mag_mom == -1.0_dp) THEN
            nelec = REAL(mo_set%nelectron, dp)
         ELSE
            nelec = mo_set%n_el_f
         END IF

         mo_set%occupation_numbers(:) = 0.0_dp

         CALL probe_occupancy(mo_set%occupation_numbers, mo_set%mu, mo_set%kTS, &
                              mo_set%eigenvalues, mo_set%mo_coeff, mo_set%maxocc, &
                              probe, N=nelec)
         !NB: mu and T are taken from the hairy_probe type (defined in cp_control_types.F); these values are set in the input

         ! Find the lowest fractional occupied MO (LFOMO)
         DO imo = i_first, nmo
            IF (mo_set%occupation_numbers(imo) < mo_set%maxocc) THEN
               mo_set%lfomo = imo
               EXIT
            END IF
         END DO
         is_large = ABS(MAXVAL(mo_set%occupation_numbers) - mo_set%maxocc) > probe(1)%eps_hp
         ! this is not a real problem, but the temperature might be a bit large
         IF (is_large) &
            CPWARN("Hair-probes occupancy distribution includes the first MO")

         ! Find the highest (fractional) occupied MO which will be now the HOMO
         DO imo = nmo, mo_set%lfomo, -1
            IF (mo_set%occupation_numbers(imo) > probe(1)%eps_hp) THEN
               mo_set%homo = imo
               EXIT
            END IF
         END DO
         is_large = ABS(MINVAL(mo_set%occupation_numbers)) > probe(1)%eps_hp
         IF (is_large) &
            CALL cp_warn(__LOCATION__, &
                         "Hair-probes occupancy distribution includes the last MO => "// &
                         "Add more MOs for proper smearing.")

         ! check that the total electron count is accurate
         is_large = (ABS(nelec - accurate_sum(mo_set%occupation_numbers(:))) > probe(1)%eps_hp*nelec)
         IF (is_large) &
            CPWARN("Total number of electrons is not accurate")

      END IF

      ! Quick return, if no smearing information is supplied (TO BE FIXED, smear should become non-optional...)
      IF (.NOT. PRESENT(smear)) THEN
         ! there is no dependence of the energy on the eigenvalues
         mo_set%uniform_occupation = .TRUE.
         IF (PRESENT(eval_deriv)) THEN
            eval_deriv = 0.0_dp
         END IF
         CALL timestop(handle)
         RETURN
      END IF

      ! Check if proper eigenvalues are already available
      IF (smear%method /= smear_list) THEN
         IF ((ABS(mo_set%eigenvalues(1)) < 1.0E-12_dp) .AND. &
             (ABS(mo_set%eigenvalues(nmo)) < 1.0E-12_dp)) THEN
            CALL timestop(handle)
            RETURN
         END IF
      END IF

      ! Perform smearing
      IF (smear%do_smear) THEN
         IF (PRESENT(xas_env)) THEN
            i_first = xas_estate + 1
            nelec = xas_nelectron
         ELSE
            i_first = 1
            IF (smear%fixed_mag_mom == -1.0_dp) THEN
               nelec = REAL(mo_set%nelectron, dp)
            ELSE
               nelec = mo_set%n_el_f
            END IF
         END IF
         SELECT CASE (smear%method)
         CASE (smear_fermi_dirac)
            IF (.NOT. PRESENT(eval_deriv)) THEN
               CALL FermiFixed(mo_set%occupation_numbers(1:mo_set%nmo), mo_set%mu, mo_set%kTS, &
                               mo_set%eigenvalues(1:mo_set%nmo), Nelec, &
                               smear%electronic_temperature, mo_set%maxocc, xas_estate, occ_estate)
            ELSE
               ! could be a relatively large matrix, but one could get rid of it by never storing it
               ! we only need dE/df * df/de, one could equally parallelize over entries, this could become expensive
               ALLOCATE (dfde(nmo, nmo))
               ! lengthscale could become a parameter, but this is pretty good
               lengthscale = 10*smear%electronic_temperature

               CALL FermiFixedDeriv(dfde, mo_set%occupation_numbers(1:mo_set%nmo), mo_set%mu, &
                                    mo_set%kTS, mo_set%eigenvalues(1:mo_set%nmo), Nelec, &
                                    smear%electronic_temperature, mo_set%maxocc, lengthscale, xas_estate, occ_estate)

               ! deriv of E_{KS}-kT*S wrt to f_i
               eval_deriv = eval_deriv - mo_set%eigenvalues + mo_set%mu
               ! correspondingly the deriv of  E_{KS}-kT*S wrt to e_i
               eval_deriv = MATMUL(TRANSPOSE(dfde), eval_deriv)

               DEALLOCATE (dfde)
            END IF

            ! Find the lowest fractional occupied MO (LFOMO)
            DO imo = i_first, nmo
               IF (mo_set%occupation_numbers(imo) < mo_set%maxocc) THEN
                  mo_set%lfomo = imo
                  EXIT
               END IF
            END DO
            is_large = ABS(MAXVAL(mo_set%occupation_numbers) - mo_set%maxocc) > smear%eps_fermi_dirac
            ! this is not a real problem, but the temperature might be a bit large
            CPWARN_IF(is_large, "Fermi-Dirac smearing includes the first MO")

            ! Find the highest (fractional) occupied MO which will be now the HOMO
            DO imo = nmo, mo_set%lfomo, -1
               IF (mo_set%occupation_numbers(imo) > smear%eps_fermi_dirac) THEN
                  mo_set%homo = imo
                  EXIT
               END IF
            END DO
            is_large = ABS(MINVAL(mo_set%occupation_numbers)) > smear%eps_fermi_dirac
            IF (is_large) &
               CALL cp_warn(__LOCATION__, &
                            "Fermi-Dirac smearing includes the last MO => "// &
                            "Add more MOs for proper smearing.")

            ! check that the total electron count is accurate
            is_large = (ABS(nelec - accurate_sum(mo_set%occupation_numbers(:))) > smear%eps_fermi_dirac*nelec)
            CPWARN_IF(is_large, "Total number of electrons is not accurate")

         CASE (smear_energy_window)
            ! not implemented
            CPASSERT(.NOT. PRESENT(eval_deriv))

            ! Define the energy window for the eigenvalues
            e1 = mo_set%eigenvalues(mo_set%homo) - 0.5_dp*smear%window_size
            IF (e1 <= mo_set%eigenvalues(1)) THEN
               CPWARN("Energy window for smearing includes the first MO")
            END IF

            e2 = mo_set%eigenvalues(mo_set%homo) + 0.5_dp*smear%window_size
            IF (e2 >= mo_set%eigenvalues(nmo)) &
               CALL cp_warn(__LOCATION__, &
                            "Energy window for smearing includes the last MO => "// &
                            "Add more MOs for proper smearing.")

            ! Find the lowest fractional occupied MO (LFOMO)
            DO imo = i_first, nomo
               IF (mo_set%eigenvalues(imo) > e1) THEN
                  mo_set%lfomo = imo
                  EXIT
               END IF
            END DO

            ! Find the highest fractional occupied (non-zero) MO which will be the HOMO
            DO imo = nmo, nomo, -1
               IF (mo_set%eigenvalues(imo) < e2) THEN
                  mo_set%homo = imo
                  EXIT
               END IF
            END DO

            ! Get the number of electrons to be smeared
            edist = 0.0_dp
            nelec = 0.0_dp

            DO imo = mo_set%lfomo, mo_set%homo
               nelec = nelec + mo_set%occupation_numbers(imo)
               edist = edist + ABS(e2 - mo_set%eigenvalues(imo))
            END DO

            ! Smear electrons inside the energy window
            DO imo = mo_set%lfomo, mo_set%homo
               edelta = ABS(e2 - mo_set%eigenvalues(imo))
               mo_set%occupation_numbers(imo) = MIN(mo_set%maxocc, nelec*edelta/edist)
               nelec = nelec - mo_set%occupation_numbers(imo)
               edist = edist - edelta
            END DO

         CASE (smear_list)
            equal_size = SIZE(mo_set%occupation_numbers, 1) == SIZE(smear%list, 1)
            CPASSERT(equal_size)
            mo_set%occupation_numbers = smear%list
            ! there is no dependence of the energy on the eigenvalues
            IF (PRESENT(eval_deriv)) THEN
               eval_deriv = 0.0_dp
            END IF
            ! most general case
            mo_set%lfomo = 1
            mo_set%homo = nmo
         END SELECT

         ! Check, if the smearing involves more than one MO
         IF (mo_set%lfomo == mo_set%homo) THEN
            mo_set%homo = nomo
            mo_set%lfomo = nomo + 1
         ELSE
            mo_set%uniform_occupation = .FALSE.
         END IF

      END IF ! do smear

      ! zeros don't count as uniform
      mo_set%uniform_occupation = has_uniform_occupation(mo_set=mo_set)

      CALL timestop(handle)

   END SUBROUTINE set_mo_occupation_1

END MODULE qs_mo_occupation
