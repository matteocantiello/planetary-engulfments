!***********************************************************************
!
!   Copyright (C) 2010  Bill Paxton
!
!   this file is part of mesa.
!
!   mesa is free software; you can redistribute it and/or modify
!   it under the terms of the gnu general library public license as published
!   by the free software foundation; either version 2 of the license, or
!   (at your option) any later version.
!
!   mesa is distributed in the hope that it will be useful,
!   but without any warranty; without even the implied warranty of
!   merchantability or fitness for a particular puR_companionose.  see the
!   gnu library general public license for more details.
!
!   you should have received a copy of the gnu library general public license
!   along with this software; if not, write to the free software
!   foundation, inc., 59 temple place, suite 330, boston, ma 02111-1307 usa
!
! ***********************************************************************

! added little comment

      module run_star_extras

      use star_lib
      use star_def
      use const_def
      use crlibm_lib

      implicit none


    ! These values can be saved in photos and restored at restarts
      real(dp) :: r_engulf, Deltar, R_bondi, r_influence
      real(dp) :: stop_age

    ! the routines that take care of doing the save/restore are the following:
    ! alloc_extra_info and unpack_extra_info << called by extras_startup
    ! store_extra_info << called by extras_finish_step
    ! these routines call move_extra_info.
    ! it must know about each of your variables to be saved/restored.
    ! so edit move_extra_info when you change the set of variables.

    ! these routines are called by the standard run_star check_model
      contains

      subroutine extras_controls(id, ierr)
         integer, intent(in) :: id
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return

       ! this is the place to set any procedure pointers you want to change
       ! e.g., other_wind, other_mixing, other_energy  (see star_data.inc)

       ! Uncomment these lines if you wish to use the functions in this file,
       ! otherwise we use a null_ version which does nothing.
         s% other_energy => energy_routine

         s% extras_startup => extras_startup
         s% extras_start_step => extras_start_step
         s% extras_check_model => extras_check_model
         s% extras_finish_step => extras_finish_step
         s% extras_after_evolve => extras_after_evolve
         s% how_many_extra_history_columns => how_many_extra_history_columns
         s% data_for_extra_history_columns => data_for_extra_history_columns
         s% how_many_extra_profile_columns => how_many_extra_profile_columns
         s% data_for_extra_profile_columns => data_for_extra_profile_columns

         s% how_many_extra_history_header_items => how_many_extra_history_header_items
         s% data_for_extra_history_header_items => data_for_extra_history_header_items
         s% how_many_extra_profile_header_items => how_many_extra_profile_header_items
         s% data_for_extra_profile_header_items => data_for_extra_profile_header_items

       ! Once you have set the function pointers you want,
       ! then uncomment this (or set it in your star_job inlist)
       ! to disable the printed warning message,
       ! s% job% warn_run_star_extras =.false.


      end subroutine extras_controls

      subroutine energy_routine(id, ierr)
        integer, intent(in) :: id
        integer, intent(out) :: ierr
        logical :: restart, first
        type (star_info), pointer :: s
        integer :: k, nz
        integer :: krr_center, krr_bottom_bondi, krr_top_bondi, krr_bottom_companion, krr_top_companion
        real(dp) :: e_orbit, M_companion, R_companion, area, de, sound_speed, r_influence
        real(dp) :: rr, v_kepler, rho_bar_companion, rho_bar_bondi, rho_bar_drag
        real(dp) :: dmsum_companion,dmsum_bondi,dmsum_drag, de_heat
        real(dp) :: f_disruption
        real(dp) :: penetration_depth
        ierr = 0

      ! Reads model infos from star structure s. Initialize variables.
        call star_ptr(id, s, ierr)
        if (ierr /= 0) return


        nz = s% nz               ! Mesh size (primary)
        s% extra_heat(:) = 0     ! Initialize extra_heat vector

      ! Initialize injected energy and radial coordinate change
        de = 0d0
        deltar = 0d0
        f_disruption = 0d0
        R_bondi = 0d0

      ! Mass and radius of injested companion from inlist. Also include a stop point if you want to stop before destruction.
        M_companion = s% x_ctrl(1) * Msun
        R_companion = s% x_ctrl(2) * Rsun


      ! r_engulf is the coordinate of the planet's center wrt the primary's core.
      ! If this is the beginning of an engulfment run, r_engulf is set to be the radius
      ! of the star in 'extras_startup' plus either the radius of the companion or the bondi readius, whichever is
      ! largest, so as to initialize a grazing collision.
      ! If it's a restart, MESA will remember the radial location of the engulfed
      ! companion, r_engulf, from a photo. This is because we are moving r_engulf data in
      ! photos using 'move_extra_info' and this data is retrieved in 'extras_startup' using 'unpack_extra_info'

      ! Calculate orbital keplerian velocity of the companion (we assume circular orbits)
      ! If the companion's centre is outside the primary this is easyly done, but if it is inside, we need to use
      ! only the mass of the primary inside the orbit, so we need to locate the index where the companion core is.
      ! Calculate the bondi radius of the companion after ensuring the the sound speed is 10 km/s outside the star
        if (r_engulf > s% r(1)) then
            call orbital_velocity(s% m(1), r_engulf, v_kepler)
            sound_speed = 10. * 1.d5 ! set c_sound to be ISM in cgs
        else
            krr_center=1
            do while (krr_center >= 1 .and. krr_center < nz .and. s% r(krr_center) >= r_engulf)
                krr_center = krr_center + 1
            end do
            call orbital_velocity(s% m(krr_center), r_engulf, v_kepler)
            sound_speed = s% csound(krr_center)
        endif

        call bondi_radius (M_companion, sound_speed, v_kepler, R_bondi)
        r_influence = max(R_bondi,R_companion)


      ! Find gridpoint corresponding to the location of the engulfed companion bottom, center and top
        krr_bottom_companion=1
        do while (krr_bottom_companion >= 1 .and. &
                  krr_bottom_companion < nz .and. &
                  s% r(krr_bottom_companion) >= r_engulf-R_companion)
            krr_bottom_companion = krr_bottom_companion + 1
        end do
        krr_center = krr_bottom_companion
        do while (krr_center >=2 .and. s% r(krr_center) < r_engulf)
           krr_center = krr_center - 1
        end do
        krr_top_companion = krr_center
        do while (krr_top_companion >= 2 .and. s% r(krr_top_companion) < r_engulf+R_companion)
            krr_top_companion = krr_top_companion - 1
        end do

       ! Find gridpoint corresponding to the location of the engulfed companion's Bondi radius,  bottom, center and top
         krr_bottom_bondi=1
         do while (krr_bottom_bondi >= 1 .and. krr_bottom_bondi < nz .and. s% r(krr_bottom_bondi) >= r_engulf-R_bondi)
             krr_bottom_bondi = krr_bottom_bondi + 1
         end do
         krr_center = krr_bottom_bondi
         do while (krr_center >=2 .and. s% r(krr_center) < r_engulf)
            krr_center = krr_center - 1
         end do
         krr_top_bondi = krr_center
         do while (krr_top_bondi >= 2 .and. s% r(krr_top_bondi) < r_engulf+R_bondi)
             krr_top_bondi = krr_top_bondi - 1
         end do

      ! Calculate mass contained in the spherical shell occupied by the companion (shellular approximation)
      ! and the mass-weighted density of the region of impact for drag calculation
        dmsum_companion = sum(s% dm(krr_top_companion:krr_bottom_companion))
        dmsum_bondi = sum(s% dm(krr_top_bondi:krr_bottom_bondi))
        rho_bar_companion = dot_product &
                            (s% rho(krr_top_companion:krr_bottom_companion), &
                             s% dm(krr_top_companion:krr_bottom_companion))/dmsum_companion
        rho_bar_bondi = dot_product &
                            (s% rho(krr_top_bondi:krr_bottom_bondi), &
                             s% dm(krr_top_bondi:krr_bottom_bondi))/dmsum_bondi
        if (R_bondi >= R_companion) then
           dmsum_drag = dmsum_bondi
           rho_bar_drag = rho_bar_bondi
        else
           dmsum_drag = dmsum_companion
           rho_bar_drag = rho_bar_companion
        endif

      ! write(*,*)'indeces,bottom,centre,top',krr_bottom_bondi,krr_bottom_companion,krr_center,krr_top_companion,krr_top_bondi


      ! Check if the companion has been destroyed by ram pressure (f>1). This is important only for planets.
        f_disruption = check_disruption(M_companion,R_companion,v_kepler,rho_bar_companion)

      ! Calculate area for drag
        penetration_depth = 0d0
        area = 0d0 ! Initialize cross section of companion (physical of Bondi) for calculating aerodynamic or gravitational drag

      ! Do the calculation only if this is a grazing collision and if the planet has not been destroyed yet
        if (r_engulf > s% r(1) + r_influence) then
            penetration_depth = 0.d0
        else
            penetration_depth = penetration_depth_function(r_influence,s% r(1), r_engulf)
        endif


        if (penetration_depth >= 0.0 .and. (r_engulf >= (s% r(1) - r_influence)) .and. (f_disruption <= 1d0)) then
            ! Calculate intersected area. Rstar-rr is x in sketch
              area = intercepted_area (penetration_depth, r_influence)
              write(*,*) 'Grazing Collision. Engulfed area fraction: ', s% model_number, area/(pi * pow2(r_influence))
        else
            ! Full engulfment. Cross section area = Planet area
              area = pi * pow2(r_influence)
              write(*,*) 'Full engulfment. r_influence, area',s% model_number,r_influence/Rsun,area
        end if

      !  write(*,'(a,i5,4f11.6,3e14.5)') &
      !          'r_engulf, R_bondi, r_influence, penetration depth, rho_bar_bondi, rho_bar_companion, area ',&
      !           s% model_number, r_engulf/Rsun, R_bondi/Rsun, r_influence/Rsun, &
      !           penetration_depth/Rsun, rho_bar_bondi, rho_bar_companion, area


      ! If the companion has not been destroyed by ram pressure, deposit drag luminosity and heat the envelope
      ! Spread in the region occupied by the planet. Update radial coordinate of the engulfed planet too.
        if ( f_disruption <= 1d0 ) then

            ! Note we use s% r(krr_bottom)+R_companion instead of s% r(krr_center) because during grazing phase krr_center = krr_bottom
              call drag (s% m(krr_center), M_companion, area, rho_bar_drag, s% dt, r_engulf, de, Deltar)
            !  write(*,'(A,i4,2f10.4,2e15.4,f12.4,e12.4,e12.4)')'after call drag', s% model_number, s% m(krr_center)/Msun, &
						!		       area, rho_bar_drag, s% dt, r_engulf/Rsun, de, Deltar/Rsun

            ! If the planet has not been destroyed by ram pressure, deposit drag luminosity and heat the envelope
            ! Spread in the region occupied by the planet or by the Bondi sphere.
            ! Update radial coordinate of the engulfed planet in 'extras_finish_step' using Deltar.
              do k = min(krr_top_bondi,krr_top_companion), max(krr_bottom_bondi,krr_bottom_companion)
                 s% extra_heat(k) = (de/dmsum_drag/s% dt) ! Uniform heating (erg/g/sec)
              end do

              ! Calculate orbital energy
              call orbital_energy(s% m(krr_center), M_companion, r_engulf, e_orbit)
              write(*,*) 'Injected Energy / Orbital Energy: ', abs(de/e_orbit)
        else
              write(*,*) '***************** Planet destroyed at R/Rsun = ', r_engulf/Rsun,'*********************'
              Deltar = 0d0
              s% use_other_energy = .false.
              stop_age = s% star_age + 1d1 * s% kh_timescale
              write(*,*)'stop_age and KH timescale are',stop_age, s% kh_timescale
        endif



        ! Save variables for history

          s% xtra1 = v_kepler/1d5                ! Orbital velocity
          s% xtra2 = Deltar                      ! Infall distance
          s% xtra3 = de                          ! Injected energy
          s% xtra4 = f_disruption                ! Disruption factor
          s% xtra5 = area/(pi * pow2(max(R_companion,R_bondi)))  ! Engulfed fraction
          s% xtra6 = dmsum_drag/Msun             ! Heated mass (Msun)
          s% xtra7 = R_bondi/Rsun                ! Bondi radius (Rsun)
          s% xtra8 = sound_speed/1.d5            ! Sound speed (km/s)

      end subroutine energy_routine

    ! Useful subroutines and functions
    ! Calculate change in radial position and energy loss due to drag
      subroutine drag (m1, m2, area, rho, dt, r, de, dr)
           real(dp) :: delta_m1, cdr, cde
           real(dp), intent(in) ::  m1, m2, area, rho, dt, r
           real(dp), intent(out) :: de, dr

         ! Calculate Deltar (infall distance due to aerodynamic drag)
         ! We consider cross section area of planet. For compact objects (e.g. NS) one needs to use the accretion radius instead.
         ! See e.g. equation B.3 in Tylenda & Soker 2006
           cdr = area*sqrt(standard_cgrav*m1) / m2
           dr = cdr * rho * sqrt(r) * dt
         ! Calculate DeltaE (energy loss)
         ! See e.g. equation B.2 in Tylenda & Soker 2006, where we have used v = keplerian velocity
           cde = (0.5d0*area)*(standard_cgrav*m1)**1.5d0
           de = cde *  rho * r**(-1.5d0) * dt
          ! write(*,'(A,e11.4,2X,A,e11.3,2X,A,e11.3)')&
					!'From inside drag this is dr=', dr/Rsun,'this is r=',r/Rsun,'this is dt',dt
      end subroutine drag

    ! Calculate orbital velocity
      subroutine orbital_velocity(m1, r, v_kepler)
           real(dp), intent(in)  :: m1, r
           real(dp), intent(out) :: v_kepler
         ! use const_def, only: standard_cgrav
           v_kepler = sqrt(standard_cgrav*m1/r)
      end subroutine orbital_velocity

      subroutine bondi_radius (m2, sound_speed, v, R_bondi)
           real(dp), intent(in)  :: m2, v, sound_speed
           real(dp), intent(out) :: R_bondi
           if (v < sound_speed) then
                R_Bondi = 2.d0 * standard_cgrav * m2 / ( pow2(v) + pow2(sound_speed) )
           else
                R_bondi = 2.d0 * standard_cgrav * m2 / pow2(v)
           endif
        !   write(*,*)'Inside Bondi SUB: this is m2, sound_speed, v, R_bondi', &
        !              m2/Msun, sound_speed/1.d5, v/1.d5, R_bondi/Rsun
      end subroutine bondi_radius

    ! Calculate binary orbital energy
      subroutine orbital_energy(m1, m2, r, energy)
           real(dp), intent(in) ::  m1, m2,  r
           real(dp), intent(out) :: energy
         ! use const_def, only: standard_cgrav
           energy = -standard_cgrav*m1*m2/(2d0*r)
      !     write(*,*)'Inside orbital energy SUB: this is m1, m2, r, energy', &
      !                m1/Msun, m2/Msun, r/Rsun, energy
      end subroutine orbital_energy


    ! Calculate 2D Intercepted area of planet grazing host star noting that the radius is not
    ! necessarily the radius of the planet, it could be the Bondi radius if it is larger.
    ! R_companion = max (planet radius, Bondi radius), x = Rstar-r_engulf (see sketch)
      real(dp) function intercepted_area(x, R_inf) result(area)
           real(dp), intent(in) :: x, R_inf
           real(dp) :: alpha, y

         ! Case when less than half of the planet is engulfed
           if (x < R_inf) then
                y = R_inf - x
                alpha = acos (y/R_inf)
                area = R_inf * (R_inf*alpha - y * sin(alpha))
            !    write(*,*)'From intercepted_area SUB: less than half: x,R_inf,alpha,area', x/Rsun, R_inf/Rsun, alpha, area
           else
         ! Case when more than half of the planet is engulfed
                y = x - R_inf
                alpha = acos (y/R_inf)
                area = pi*pow2(R_inf) - R_inf * (R_inf*alpha - (y * sin(alpha)))
            !    write(*,*)'From intercepted_area SUB: more than half: x,R_inf,alpha,area', x/Rsun, R_inf/Rsun, alpha, area
           endif
      end function intercepted_area

      real(dp) function penetration_depth_function(r_influence, R_star, r_engulf) result(penetration_depth)
           real(dp) :: r_influence, R_star, r_engulf
           penetration_depth = r_influence + R_star - r_engulf
           if (penetration_depth < 0d0) penetration_depth = 0d0
           write(*,*)'From penetration_depth, r_influence,r_engulf,penetration_depth',r_influence,r_engulf,penetration_depth
      end function penetration_depth_function

      real(dp) function check_disruption(M_companion,R_companion,v_planet,rho_ambient) result(f)
         ! f > 1 means disruption. This is expected when the ram pressure integrated
         ! over the planet cross section approaches the planet binding energy
           real(dp), intent(in) :: M_companion,R_companion,v_planet,rho_ambient
           real(dp) :: v_esc_planet_square, rho_planet
           rho_planet = 3d0*M_companion/(4d0*pi*pow3(R_companion))
           v_esc_planet_square = standard_cgrav*M_companion/R_companion
         ! Eq.5 in Jia & Spruit 2018  https://arxiv.org/abs/1808.00467
           f = (rho_ambient*pow2(v_planet)) / (rho_planet*v_esc_planet_square)
           write(*,*)'From Check_Disruption rho_ambient, rho_planet, v_planet, f', &
                     rho_ambient, rho_planet, v_planet, f
      end function check_disruption


      integer function extras_startup(id, restart, ierr)
         integer, intent(in) :: id
         logical, intent(in) :: restart
         integer, intent(out) :: ierr
         real(dp) :: v_kepler, sound_speed, r_influence, r_engulf_prior
         type (star_info), pointer :: s

         ierr = 0
         call star_ptr(id, s, ierr)

         if (ierr /= 0) return
         extras_startup = 0

         if (.not. restart) then

         ! Estimate of Keplerian velocity based on separation = stellar radius + r_influence
         ! The loop is because initial value of r_engulf needs r_influence, which needs R_bondi, which needs
         ! v_kepler, which needs r_engulf

           r_engulf = s% r(1)
           r_engulf_prior = s% r(1) * 0.9d0
           sound_speed = 10. * 1.d5 ! set c_sound to be ISM in cgs
           do while ((r_engulf - r_engulf_prior)/r_engulf > 0.001)
             call orbital_velocity(s% m(1), r_engulf, v_kepler)
             call bondi_radius (s% x_ctrl(1)*Msun, sound_speed, v_kepler, R_bondi)
             r_influence = max(R_bondi, s% x_ctrl(2)*Rsun)
             r_engulf_prior = r_engulf
             r_engulf = s% r(1) + r_influence
             write(*,*)'From INIT loop',r_engulf/Rsun,R_bondi/Rsun,r_engulf_prior/Rsun,&
                r_influence/Rsun,(r_engulf - r_engulf_prior)/r_engulf,v_kepler/1.d5
           end do


         ! If this is not a restart, set the collision radius as the stellar radius at the beginning of calculation + companion radius OR Bondi radius
         ! whichever is the largest, aka a grazing collision (r_engulf is the coordinate of the planet's centre)
           r_engulf = s% r(1) + r_influence
           write(*,*)'From STARTUP this is r_engulf, Rstar, Rbondi, Rcompanion', &
                      r_engulf/Rsun, s% r(1)/Rsun, R_bondi/Rsun, s% x_ctrl(2)
           stop_age = -101d0
           call alloc_extra_info(s)
         else ! it is a restart -> Unpack value of r_engulf from photo
            call unpack_extra_info(s)
            !ORSOLA I want to restart after destruction, so I want to eliminate the stop time.
            !stop_age = -101d0
         end if
         write(*,*)'Inside STARTUP: r_engulf, R_companion, Bondi R:', r_engulf/Rsun, s% x_ctrl(2), R_bondi/Rsun
      end function extras_startup


      integer function extras_start_step(id, id_extra)
         integer, intent(in) :: id, id_extra
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return

         extras_start_step = 0
      end function extras_start_step


      ! returns either keep_going, retry, backup, or terminate.
      integer function extras_check_model(id, id_extra)
         integer, intent(in) :: id, id_extra
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         extras_check_model = keep_going

         ! if you want to check multiple conditions, it can be useful
         ! to set a different termination code depending on which
         ! condition was triggered.  MESA provides 9 customizeable
         ! termination codes, named t_xtra1 .. t_xtra9.  You can
         ! customize the messages that will be printed upon exit by
         ! setting the corresponding termination_code_str value.
         ! termination_code_str(t_xtra1) = 'my termination condition'

         ! by default, indicate where (in the code) MESA terminated
         if (extras_check_model == terminate) s% termination_code = t_extras_check_model
      end function extras_check_model


      integer function how_many_extra_history_columns(id, id_extra)
         integer, intent(in) :: id, id_extra
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         how_many_extra_history_columns = 11
      end function how_many_extra_history_columns


      subroutine data_for_extra_history_columns(id, id_extra, n, names, vals, ierr)
         integer, intent(in) :: id, id_extra, n
         character (len=maxlen_history_column_name) :: names(n)
         real(dp) :: vals(n)
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return

         names(1) = 'R_Engulfed_Planet' ! Radial distance from stellar center of engulfed planet
         names(2) = 'Orbital_velocity' ! v_kepler
         names(3) = 'Log_Infall_distance'  ! dr
         names(4) = 'Log_Injected_energy'  ! de=dl*dt
         names(5) = 'Log_Destruction_factor'  ! Eq. 5 from Jia & Spruit 2018
         names(6) = 'Engulfed_fraction'  ! Cross section of the planet/Bondi area engulfed in the star (plane parallel approx, i.e. Max(Rplanet, Rbondi) << Rstar)
         names(7) = 'Total_mass_affected'
         names(8) = 'Planet_mass'
         names(9) = 'Planet_radius'
         names(10) = 'Bondi_radius'
         names(11) = 'Sound_speed'
         vals(1) = r_engulf / Rsun
         vals(2) = s% xtra1                 ! Orbital velocity
         vals(3) = safe_log10_cr( s% xtra2) ! Infall distance
         vals(4) = safe_log10_cr( s% xtra3) ! Injected energy
         vals(5) = safe_log10_cr( s% xtra4) ! Disruption factor (ratio between ram pressure and binding energy density)
         vals(6) = s% xtra5                 ! Engulfed fraction
         vals(7) = s% xtra6
         vals(8) = s% x_ctrl(1)
         vals(9) = s% x_ctrl(2)
         vals(10) = s% xtra7
         vals(11) = s% xtra8
         ! note: do NOT add the extras names to history_columns.list
         ! the history_columns.list is only for the built-in log column options.
         ! it must not include the new column names you are adding here.
      end subroutine data_for_extra_history_columns


      integer function how_many_extra_profile_columns(id, id_extra)
         use star_def, only: star_info
         integer, intent(in) :: id, id_extra
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         how_many_extra_profile_columns = 1
      end function how_many_extra_profile_columns


      subroutine data_for_extra_profile_columns(id, id_extra, n, nz, names, vals, ierr)
         use star_def, only: star_info, maxlen_profile_column_name
         use const_def, only: dp
         integer, intent(in) :: id, id_extra, n, nz
         character (len=maxlen_profile_column_name) :: names(n)
         real(dp) :: vals(nz,n)
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         integer :: k
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return

         ! Adding extra heating so that we can plot on pgstar
         names(1) = 'engulfment_heating'
         do k = 1, nz
            vals(k,1) =  safe_log10_cr(s% extra_heat(k))
         end do

         !note: do NOT add the extra names to profile_columns.list
         ! the profile_columns.list is only for the built-in profile column options.
         ! it must not include the new column names you are adding here.
      end subroutine data_for_extra_profile_columns

      subroutine how_many_extra_history_header_items(id, id_extra, num_cols)
         integer, intent(in) :: id, id_extra
         integer, intent(out) :: num_cols
         num_cols=0
      end subroutine how_many_extra_history_header_items

      subroutine data_for_extra_history_header_items( &
                  id, id_extra, num_extra_header_items, &
                  extra_header_item_names, extra_header_item_vals, ierr)
         integer, intent(in) :: id, id_extra, num_extra_header_items
         character (len=*), pointer :: extra_header_item_names(:)
         real(dp), pointer :: extra_header_item_vals(:)
         type(star_info), pointer :: s
         integer, intent(out) :: ierr
         ierr = 0
         call star_ptr(id,s,ierr)
         if(ierr/=0) return

         !here is an example for adding an extra history header item
         !set num_cols=1 in how_many_extra_history_header_items and then unccomment these lines
         !extra_header_item_names(1) = 'mixing_length_alpha'
         !extra_header_item_vals(1) = s% mixing_length_alpha
      end subroutine data_for_extra_history_header_items


      subroutine how_many_extra_profile_header_items(id, id_extra, num_cols)
          integer, intent(in) :: id, id_extra
          integer, intent(out) :: num_cols
          num_cols = 0
      end subroutine how_many_extra_profile_header_items

      subroutine data_for_extra_profile_header_items( &
                  id, id_extra, num_extra_header_items, &
                  extra_header_item_names, extra_header_item_vals, ierr)
          integer, intent(in) :: id, id_extra, num_extra_header_items
          character (len=*), pointer :: extra_header_item_names(:)
          real(dp), pointer :: extra_header_item_vals(:)
          type(star_info), pointer :: s
          integer, intent(out) :: ierr
          ierr = 0
          call star_ptr(id,s,ierr)
          if(ierr/=0) return

          !here is an example for adding an extra profile header item
          !set num_cols=1 in how_many_extra_profile_header_items and then unccomment these lines
          !extra_header_item_names(1) = 'mixing_length_alpha'
          !extra_header_item_vals(1) = s% mixing_length_alpha
      end subroutine data_for_extra_profile_header_items


      ! returns either keep_going or terminate.
      ! note: cannot request retry or backup; extras_check_model can do that.

      integer function extras_finish_step(id, id_extra)
         integer, intent(in) :: id, id_extra
         integer :: ierr, k
         logical :: grazing_phase
         real(dp) :: dr, delta_e, area, energy, r_influence, penetration_depth, dr_next
         real(dp) :: v_kepler
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         extras_finish_step = keep_going
         call store_extra_info(s)

       ! Update the radial coordinate of the engulfed companion
         r_engulf = max(r_engulf-Deltar, 0d0)

       ! CALCULATE r_influence AGAIN as it is not available to this part of the code
       ! But before we need bondi radius and orbital velocity.
       ! Calculate approx gridpoint location of planet center
         k=1
         do while (s% r(k) > r_engulf)
            k=k+1
         end do
         call orbital_velocity(s% m(1), r_engulf, v_kepler)
         call bondi_radius (s% x_ctrl(1)*Msun, s% csound(k), v_kepler, R_bondi)
         r_influence = max(R_bondi,s% x_ctrl(2)*Rsun)
        ! write(*,*)'From early',r_engulf/Rsun, Deltar/Rsun, r_influence/Rsun,R_bondi/Rsun

       ! Stop the run if: 1) we are at or past the stop age, but only if it has been set (default value is -101d0)
       !                  2) r_engulf is smaller than inlist-provided stop point x_ctrl(3) in Rsun or if
       !                  2B) r_engulf has become smaller than the companion radius or Bondi Radius, whichever is largest
         if (stop_age .GT. 0d0 .AND. s% star_age .GT. stop_age) then
           write(*,*) "Star should be thermally relaxed. Stopping."
           extras_finish_step = terminate
         endif
         if (r_engulf < r_influence .or. r_engulf < s% x_ctrl(3)*Rsun) then
          ! write(*,'(A,f10.4,A,f10.4,A,f10.4)') "Reached stop point from inlist. r_engulf=", r_engulf/Rsun, &
          !                                      'r_influence=',r_influence/Rsun, 'inslist stop:',s% x_ctrl(3)
           !extras_finish_step = terminate
           s% use_other_energy = .false.
           stop_age = s% star_age + 1d1 * s% kh_timescale
         endif

       ! Determine next timestep dt_next so that companion  infall distance dr is not too large compared to the influence radius
         delta_e = 0d0
         dr = 0d0
         energy = 0d0
         penetration_depth = 0d0
         grazing_phase = .false.

       ! Only do this if the planet is still around and falling into the star
         !write(*,*)'grazer outside if f_disruption, Deltar',s% model_number,s% xtra4,Deltar/Rsun
         if (s% xtra4 < 1d0 .and. Deltar >= 0d0) then
         ! Calculate predicted dr in two cases: grazing phase and full engulfment
           penetration_depth = penetration_depth_function(r_influence,s% r(1), r_engulf)
           !write(*,*)'From outside grazer',s% model_number,r_influence/Rsun,(r_influence + s% r(1) - r_engulf)/Rsun,&
          !               penetration_depth/Rsun, r_influence/Rsun,s% r(1)/Rsun,r_engulf/Rsun
           if (penetration_depth <= 2d0*r_influence) then
              area = intercepted_area (penetration_depth, r_influence)
              grazing_phase = .true.
          !  write(*,*)'From grazer 1: r_infl, r_engulf-r_infl,Rstar,penetration,Deltar', &
          !              s% model_number,r_influence/Rsun,(r_engulf-r_influence)/Rsun,s% r(1)/Rsun, &
          !              penetration_depth/Rsun, Deltar/Rsun
           else
              area = pi * pow2(r_influence)
            !  write(*,*)'From grazer 2: r_infl, r_engulf-r_infl,Rstar,penetration,Deltar', &
            !            s% model_number,r_influence/Rsun,(r_engulf-r_influence)/Rsun,s% r(1)/Rsun, &
            !            penetration_depth/Rsun, Deltar/Rsun
           end if

         ! Estimate dr
           !write(*,*)'From inside finish step, just before drag call',s% model_number,s% m(k)/Msun
           call drag(s% m(k), s% x_ctrl(1)*Msun, area, s% rho(k), s% dt_next, s% r(k), delta_e, dr_next)
           !write(*,'(A,i4,f12.4,6e12.4)')'From end drag', &
          !      s% model_number,s% m(k)/Msun,area,s% rho(k),s% dt_next,s% r(k)/Rsun,delta_e,dr_next/Rsun

           if (grazing_phase) then                       ! Grazing Phase (requires small dr)
             do while (dr_next/r_influence > s% x_ctrl(4))
               s% dt_next = s% dt_next/2d0               ! There are better strategies, but this is simple enough
               call drag (s% m(k), s% x_ctrl(1)*Msun,area,s% rho(k),s% dt_next,s% r(k),delta_e,dr_next)
               write(*,*) s% model_number,&
                         'Grazing dr/r_influence too large: ', dr_next/r_influence,'Decreasing timestep to ', s% dt_next
             end do
           else
             do while (dr_next/r_influence > s% x_ctrl(5))   ! or Full Engulfment (allow for larger dr)
               s% dt_next = s% dt_next/2d0
               call drag (s% m(k), s% x_ctrl(1)*Msun,area,s% rho(k),s% dt_next,s% r(k),delta_e,dr_next)
               write(*,*) s% model_number,&
                         ! 'Engulfed dr/r_p too large: ', dr/(max(R_bondi,s% x_ctrl(2) * Rsun)),'Decreasing timestep to ', s% dt_next
                         'Engulfed dr/r_influence too large: ', dr_next/r_influence,'Decreasing timestep to ', s% dt_next
             end do
           end if
         end if


         ! to save a profile,
            ! s% need_to_save_profiles_now = .true.
         ! to update the star log,
            ! s% need_to_update_history_now = .true.

         ! see extras_check_model for information about custom termination codes
         ! by default, indicate where (in the code) MESA terminated
         if (extras_finish_step == terminate) s% termination_code = t_extras_finish_step
      end function extras_finish_step



      subroutine extras_after_evolve(id, id_extra, ierr)
         integer, intent(in) :: id, id_extra
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
      end subroutine extras_after_evolve


      ! routines for saving and restoring extra data so can do restarts

         ! put these defs at the top and delete from the following routines
         !integer, parameter :: extra_info_alloc = 1
         !integer, parameter :: extra_info_get = 2
         !integer, parameter :: extra_info_put = 3


      subroutine alloc_extra_info(s)
         integer, parameter :: extra_info_alloc = 1
         type (star_info), pointer :: s
         call move_extra_info(s,extra_info_alloc)
      end subroutine alloc_extra_info


      subroutine unpack_extra_info(s)
         integer, parameter :: extra_info_get = 2
         type (star_info), pointer :: s
         call move_extra_info(s,extra_info_get)
      end subroutine unpack_extra_info


      subroutine store_extra_info(s)
         integer, parameter :: extra_info_put = 3
         type (star_info), pointer :: s
         call move_extra_info(s,extra_info_put)
      end subroutine store_extra_info


      subroutine move_extra_info(s,op)
         integer, parameter :: extra_info_alloc = 1
         integer, parameter :: extra_info_get = 2
         integer, parameter :: extra_info_put = 3
         type (star_info), pointer :: s
         integer, intent(in) :: op

         integer :: i, j, num_ints, num_dbls, ierr

         i = 0
         ! call move_int or move_flg
         num_ints = i

         i = 0
         ! call move_dbl
         ! (TAs) Important to understand what this is and what is done here. This is essential for MESA to remember r_engulf between timesteps
         ! and to allow for restarts from photos
         call move_dbl(r_engulf)
         call move_dbl(stop_age)
         num_dbls = i

         if (op /= extra_info_alloc) return
         if (num_ints == 0 .and. num_dbls == 0) return

         ierr = 0
         call star_alloc_extras(s% id, num_ints, num_dbls, ierr)
         if (ierr /= 0) then
            write(*,*) 'failed in star_alloc_extras'
            write(*,*) 'alloc_extras num_ints', num_ints
            write(*,*) 'alloc_extras num_dbls', num_dbls
            stop 1
         end if

         contains

         subroutine move_dbl(dbl)
            real(dp) :: dbl
            i = i+1
            select case (op)
            case (extra_info_get)
               dbl = s% extra_work(i)
            case (extra_info_put)
               s% extra_work(i) = dbl
            end select
         end subroutine move_dbl

         subroutine move_int(int)
            integer :: int
            i = i+1
            select case (op)
            case (extra_info_get)
               int = s% extra_iwork(i)
            case (extra_info_put)
               s% extra_iwork(i) = int
            end select
         end subroutine move_int

         subroutine move_flg(flg)
            logical :: flg
            i = i+1
            select case (op)
            case (extra_info_get)
               flg = (s% extra_iwork(i) /= 0)
            case (extra_info_put)
               if (flg) then
                  s% extra_iwork(i) = 1
               else
                  s% extra_iwork(i) = 0
               end if
            end select
         end subroutine move_flg

      end subroutine move_extra_info

      end module run_star_extras
