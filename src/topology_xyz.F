!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!
! **************************************************************************************************
MODULE topology_xyz
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE cp_parser_methods,               ONLY: parser_get_next_line,&
                                              parser_get_object,&
                                              read_integer_object
   USE cp_parser_types,                 ONLY: cp_parser_type,&
                                              parser_create,&
                                              parser_release
   USE cp_units,                        ONLY: cp_unit_to_cp2k
   USE input_section_types,             ONLY: section_vals_type
   USE kinds,                           ONLY: default_string_length,&
                                              dp,&
                                              max_line_length
   USE memory_utilities,                ONLY: reallocate
   USE message_passing,                 ONLY: mp_para_env_type
   USE periodic_table,                  ONLY: nelem,&
                                              ptable
   USE string_table,                    ONLY: id2str,&
                                              s2s,&
                                              str2id
   USE topology_types,                  ONLY: atom_info_type,&
                                              topology_parameters_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'topology_xyz'

   PRIVATE
   PUBLIC :: read_coordinate_xyz

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param topology ...
!> \param para_env ...
!> \param subsys_section ...
!> \author Teodoro Laino
! **************************************************************************************************
   SUBROUTINE read_coordinate_xyz(topology, para_env, subsys_section)
      TYPE(topology_parameters_type)                     :: topology
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(section_vals_type), POINTER                   :: subsys_section

      CHARACTER(len=*), PARAMETER :: routineN = 'read_coordinate_xyz'

      CHARACTER(LEN=default_string_length)               :: my_default_index, strtmp
      CHARACTER(LEN=max_line_length)                     :: error_message
      INTEGER                                            :: frame, handle, ian, iw, j, natom
      LOGICAL                                            :: my_end
      TYPE(atom_info_type), POINTER                      :: atom_info
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_parser_type)                               :: parser

      CALL timeset(routineN, handle)

      NULLIFY (logger)
      logger => cp_get_default_logger()
      iw = cp_print_key_unit_nr(logger, subsys_section, "PRINT%TOPOLOGY_INFO/XYZ_INFO", &
                                extension=".subsysLog")

      atom_info => topology%atom_info

      IF (iw > 0) THEN
         WRITE (UNIT=iw, FMT="(T2,A)") &
            "BEGIN of XYZ data read from file "//TRIM(topology%coord_file_name)
      END IF

      CALL parser_create(parser, topology%coord_file_name, para_env=para_env, &
                         parse_white_lines=.TRUE.)

      ! Element is assigned on the basis of the atm_name
      topology%aa_element = .TRUE.

      natom = 0
      frame = 0
      CALL parser_get_next_line(parser, 1)
      Frames: DO
         ! Atom numbers
         CALL parser_get_object(parser, natom)
         frame = frame + 1
         IF (frame == 1) THEN
            CALL reallocate(atom_info%id_molname, 1, natom)
            CALL reallocate(atom_info%id_resname, 1, natom)
            CALL reallocate(atom_info%resid, 1, natom)
            CALL reallocate(atom_info%id_atmname, 1, natom)
            CALL reallocate(atom_info%r, 1, 3, 1, natom)
            CALL reallocate(atom_info%atm_mass, 1, natom)
            CALL reallocate(atom_info%atm_charge, 1, natom)
            CALL reallocate(atom_info%occup, 1, natom)
            CALL reallocate(atom_info%beta, 1, natom)
            CALL reallocate(atom_info%id_element, 1, natom)
         ELSE IF (natom > SIZE(atom_info%id_atmname)) THEN
            CPABORT("Atom number differs in different frames!")
         END IF
         ! Dummy line
         CALL parser_get_next_line(parser, 2)
         DO j = 1, natom
            ! Atom coordinates
            READ (parser%input_line, *) strtmp, &
               atom_info%r(1, j), &
               atom_info%r(2, j), &
               atom_info%r(3, j)
            error_message = ""
            CALL read_integer_object(strtmp, ian, error_message)
            IF (LEN_TRIM(error_message) == 0) THEN
               ! Integer value found: assume atomic number, check it, and load
               ! the corresponding element symbol if valid
               IF ((ian < 0) .OR. (ian > nelem)) THEN
                  error_message = "Invalid atomic number <"//TRIM(strtmp)// &
                                  "> found in the xyz file <"//TRIM(topology%coord_file_name)//">!"
                  CPABORT(TRIM(error_message))
               ELSE
                  atom_info%id_atmname(j) = str2id(s2s(ptable(ian)%symbol))
               END IF
            ELSE
               atom_info%id_atmname(j) = str2id(s2s(strtmp))
            END IF
            ! For default, set atom name to residue name to molecule name
            WRITE (my_default_index, '(I0)') j
            atom_info%id_molname(j) = str2id(s2s(TRIM(id2str(atom_info%id_atmname(j)))//TRIM(my_default_index)))
            atom_info%id_resname(j) = atom_info%id_molname(j)
            atom_info%resid(j) = 1
            atom_info%id_element(j) = atom_info%id_atmname(j)
            atom_info%atm_mass(j) = HUGE(0.0_dp)
            atom_info%atm_charge(j) = -HUGE(0.0_dp)
            IF (iw > 0) THEN
               WRITE (UNIT=iw, FMT="(T2,A4,3F8.3,2X,A)") &
                  TRIM(id2str(atom_info%id_atmname(j))), &
                  atom_info%r(1, j), &
                  atom_info%r(2, j), &
                  atom_info%r(3, j), &
                  ADJUSTL(TRIM(id2str(atom_info%id_molname(j))))
            END IF
            atom_info%r(1, j) = cp_unit_to_cp2k(atom_info%r(1, j), "angstrom")
            atom_info%r(2, j) = cp_unit_to_cp2k(atom_info%r(2, j), "angstrom")
            atom_info%r(3, j) = cp_unit_to_cp2k(atom_info%r(3, j), "angstrom")
            ! If there's a white line or end of file exit.. otherwise read other available
            ! snapshots
            CALL parser_get_next_line(parser, 1, at_end=my_end)
            my_end = my_end .OR. (LEN_TRIM(parser%input_line) == 0)
            IF (my_end) THEN
               IF (j /= natom) &
                  CALL cp_abort(__LOCATION__, &
                                "Number of lines in XYZ format not equal to the number of atoms."// &
                                " Error in XYZ format. Very probably the line with title is missing or is empty."// &
                                " Please check the XYZ file and rerun your job!")
               EXIT Frames
            END IF
         END DO
      END DO Frames
      CALL parser_release(parser)

      IF (iw > 0) THEN
         WRITE (UNIT=iw, FMT="(T2,A)") &
            "END of XYZ frame data read from file "//TRIM(topology%coord_file_name)
      END IF

      topology%natoms = natom
      topology%molname_generated = .TRUE.

      CALL cp_print_key_finished_output(iw, logger, subsys_section, &
                                        "PRINT%TOPOLOGY_INFO/XYZ_INFO")

      CALL timestop(handle)

   END SUBROUTINE read_coordinate_xyz

END MODULE topology_xyz
