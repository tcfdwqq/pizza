module update_psi_coll_smat

   use precision_mod
   use parallel_mod
   use mem_alloc, only: bytes_allocated
   use constants, only: one, zero, ci, half
   use outputs, only: vp_bal_type
   use namelists, only: kbotv, ktopv, alpha, r_cmb, CorFac, ViscFac, &
       &                l_coriolis_imp
   use radial_functions, only: rscheme, or1, or2, beta, dbeta, ekpump, oheight
   use blocking, only: nMstart, nMstop, l_rank_has_m0
   use truncation, only: n_r_max, idx2m, m2idx
   use radial_der, only: get_ddr, get_dr
   use fields, only: work_Mloc
   use algebra, only: prepare_full_mat, solve_full_mat
   use time_schemes, only: type_tscheme
   use time_array
   use useful, only: abortRun

   implicit none
   
   private

   logical,  allocatable :: lPsimat(:)
   complex(cp), allocatable :: psiMat(:,:,:)
   real(cp), allocatable :: uphiMat(:,:)
   integer,  allocatable :: psiPivot(:,:)
   real(cp), allocatable :: psiMat_fac(:,:,:)
   complex(cp), allocatable :: rhs(:)
   real(cp), allocatable :: rhs_m0(:)

   public :: update_om_coll_smat, initialize_om_coll_smat, finalize_om_coll_smat, &
   &         get_psi_rhs_imp_coll_smat

contains

   subroutine initialize_om_coll_smat

      allocate( lPsimat(nMstart:nMstop) )
      lPsimat(:)=.false.
      bytes_allocated = bytes_allocated+(nMstop-nMstart+1)*SIZEOF_LOGICAL

      allocate( psiMat(2*n_r_max, 2*n_r_max, nMstart:nMstop) )
      allocate( psiPivot(2*n_r_max, nMstart:nMstop) )
      allocate( psiMat_fac(2*n_r_max, 2, nMstart:nMstop) )
      allocate( rhs(2*n_r_max), rhs_m0(n_r_max) )

      bytes_allocated = bytes_allocated+(nMstop-nMstart+1)*4*n_r_max*n_r_max* &
      &                 SIZEOF_DEF_COMPLEX+2*n_r_max*(nMstop-nMstart+1)*      &
      &                 SIZEOF_INTEGER+ n_r_max*(3+4*(nMstop-nMstart+1))*     &
      &                 SIZEOF_DEF_REAL

      allocate( uphiMat(n_r_max,n_r_max) )
      bytes_allocated = bytes_allocated+n_r_max*n_r_max*SIZEOF_DEF_REAL

   end subroutine initialize_om_coll_smat
!------------------------------------------------------------------------------
   subroutine finalize_om_coll_smat

      deallocate( rhs_m0, rhs, psiMat_fac )
      deallocate( lPsimat, psiMat, uphiMat, psiPivot )

   end subroutine finalize_om_coll_smat
!------------------------------------------------------------------------------
   subroutine update_om_coll_smat(psi_Mloc, om_Mloc, dom_Mloc, us_Mloc, up_Mloc, &
              &                   dVsOm_Mloc,  buo_imp_Mloc, dpsidt, vp_bal,     &
              &                   tscheme, lMat, l_vphi_bal_calc, time_solve,    &
              &                   n_solve_calls, time_lu, n_lu_calls, time_dct,  &
              &                   n_dct_calls)

      !-- Input variables
      type(type_tscheme), intent(in) :: tscheme
      logical,            intent(in) :: lMat
      logical,            intent(in) :: l_vphi_bal_calc
      complex(cp),        intent(in) :: buo_imp_Mloc(nMstart:nMstop,n_r_max)

      !-- Output variables
      complex(cp),       intent(out) :: psi_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: om_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: dom_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: us_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: up_Mloc(nMstart:nMstop,n_r_max)
      type(vp_bal_type), intent(inout) :: vp_bal
      type(type_tarray), intent(inout) :: dpsidt
      complex(cp),       intent(inout) :: dVsOm_Mloc(nMstart:nMstop,n_r_max)
      real(cp),          intent(inout) :: time_solve
      integer,           intent(inout) :: n_solve_calls
      real(cp),          intent(inout) :: time_lu
      integer,           intent(inout) :: n_lu_calls
      real(cp),          intent(inout) :: time_dct
      integer,           intent(inout) :: n_dct_calls

      !-- Local variables
      real(cp) :: uphi0(n_r_max), om0(n_r_max), runStart, runStop
      integer :: n_r, n_m, n_cheb, m

      if ( lMat ) lPsimat(:)=.false.

      !-- Finish calculation of advection
      call get_dr( dVsOm_Mloc, work_Mloc, nMstart, nMstop, n_r_max, &
           &       rscheme, nocopy=.true.)

      !-- Finish calculation of the explicit part for current time step
      do n_r=1,n_r_max
         do n_m=nMstart, nMstop
            m = idx2m(n_m)
            if ( m /= 0 ) then
               dpsidt%expl(n_m,n_r,1)=  dpsidt%expl(n_m,n_r,1)-   &
               &                     or1(n_r)*work_Mloc(n_m,n_r)
               !-- If Coriolis is treated explicitly, add it here:
               if ( .not. l_coriolis_imp ) then
                  dpsidt%expl(n_m,n_r,1)=dpsidt%expl(n_m,n_r,1) &
                  &            +CorFac*beta(n_r)*us_Mloc(n_m,n_r)
               end if
            end if
         end do
      end do

      !-- Calculation of the implicit part
      call get_psi_rhs_imp_coll_smat(us_Mloc, up_Mloc, om_Mloc, dom_Mloc,    &
           &                         dpsidt%old(:,:,1), dpsidt%impl(:,:,1),  &
           &                         vp_bal, l_vphi_bal_calc,                &
           &                         tscheme%l_calc_lin_rhs)

      !-- Now assemble the right hand side and store it in work_Mloc
      call tscheme%set_imex_rhs(work_Mloc, dpsidt, nMstart, nMstop, n_r_max)


      do n_m=nMstart,nMstop

         m = idx2m(n_m)

         if ( m == 0 ) then ! Axisymmetric component

            if ( .not. lPsimat(n_m) ) then
               call get_uphiMat(tscheme, uphiMat(:,:), psiPivot(1:n_r_max,n_m))
               lPsimat(n_m)=.true.
            end if

            rhs_m0(1)       = 0.0_cp
            rhs_m0(n_r_max) = 0.0_cp
            do n_r=2,n_r_max-1
               rhs_m0(n_r)=real(work_Mloc(n_m,n_r),kind=cp)
            end do

            if ( l_vphi_bal_calc ) then
               do n_r=1,n_r_max
                  vp_bal%dvpdt(n_r)     =real(up_Mloc(n_m,n_r))/tscheme%dt(1)
                  vp_bal%rey_stress(n_r)=real(dpsidt%expl(n_m,n_r,1))
               end do
            end if

            call solve_full_mat(uphiMat(:,:), n_r_max, n_r_max,   &
                 &              psiPivot(1:n_r_max,n_m), rhs_m0(:))

            do n_cheb=1,rscheme%n_max
               uphi0(n_cheb)=rhs_m0(n_cheb)
            end do

         else ! Non-axisymmetric components
         
            if ( .not. lPsimat(n_m) ) then
               call get_psiMat(tscheme, m, psiMat(:,:,n_m), psiPivot(:,n_m), &
                    &          psiMat_fac(:,:,n_m), time_lu, n_lu_calls)
               lPsimat(n_m)=.true.
            end if

            rhs(1)        =zero
            rhs(n_r_max)  =zero
            rhs(n_r_max+1)=zero
            rhs(2*n_r_max)=zero
            do n_r=2,n_r_max-1
               !-- Add buoyancy
               rhs(n_r)=work_Mloc(n_m,n_r)+buo_imp_Mloc(n_m,n_r)
               !-- Second part is zero (no time-advance in the psi-block)
               rhs(n_r+n_r_max)=zero
            end do

            do n_r=1,2*n_r_max
               rhs(n_r) = rhs(n_r)*psiMat_fac(n_r,1,n_m)
            end do
            runStart = MPI_Wtime()
            call solve_full_mat(psiMat(:,:,n_m), 2*n_r_max, 2*n_r_max, &
                 &              psiPivot(:, n_m), rhs(:))
            runStop = MPI_Wtime()
            if ( runStop > runStart ) then
               time_solve = time_solve + (runStop-runStart)
               n_solve_calls = n_solve_calls+1
            end if
            do n_r=1,2*n_r_max
               rhs(n_r) = rhs(n_r)*psiMat_fac(n_r,2,n_m)
            end do

            do n_cheb=1,rscheme%n_max
               om_Mloc(n_m,n_cheb) =rhs(n_cheb)
               psi_Mloc(n_m,n_cheb)=rhs(n_cheb+n_r_max)
            end do

         end if

      end do

      !-- set cheb modes > rscheme%n_max to zero (dealiazing)
      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do n_cheb=rscheme%n_max+1,n_r_max
            do n_m=nMstart,nMstop
               m = idx2m(n_m)
               if ( m == 0 ) then
                  uphi0(n_cheb)=0.0_cp
               else
                  om_Mloc(n_m,n_cheb) =zero
                  psi_Mloc(n_m,n_cheb)=zero
               end if
            end do
         end do
      end if

      !-- Bring uphi0 to the physical space
      if ( l_rank_has_m0 ) then
         call rscheme%costf1(uphi0, n_r_max)
         call get_dr(uphi0, om0, n_r_max, rscheme)

         if ( l_vphi_bal_calc ) then
            do n_r=1,n_r_max
               vp_bal%dvpdt(n_r)=uphi0(n_r)/tscheme%dt(1)-vp_bal%dvpdt(n_r)
            end do
         end if
      end if

      !-- Bring psi and omega to the physical space
      runStart = MPI_Wtime()
      call rscheme%costf1(psi_Mloc, nMstart, nMstop, n_r_max)
      call rscheme%costf1(om_Mloc, nMstart, nMstop, n_r_max)
      runStop = MPI_Wtime()
      if ( runStop > runStart ) then
         time_dct = time_dct + (runStop-runStart)
         n_dct_calls = n_dct_calls + 2
      end if

      !-- Get the radial derivative of psi to calculate uphi
      call get_dr(psi_Mloc, work_Mloc, nMstart, nMstop, n_r_max, rscheme)

      do n_r=1,n_r_max
         do n_m=nMstart,nMstop
            m = idx2m(n_m)

            if ( m == 0 ) then
               us_Mloc(n_m,n_r)=0.0_cp
               up_Mloc(n_m,n_r)=uphi0(n_r)
               om_Mloc(n_m,n_r)=om0(n_r)+or1(n_r)*uphi0(n_r)
            else
               us_Mloc(n_m,n_r)=ci*real(m,cp)*or1(n_r)*psi_Mloc(n_m,n_r)
               up_Mloc(n_m,n_r)=-work_Mloc(n_m,n_r)-beta(n_r)*psi_Mloc(n_m,n_r)
            end if
         end do
      end do

      !-- Roll the time arrays before filling again the first block
      call tscheme%rotate_imex(dpsidt, nMstart, nMstop, n_r_max)

   end subroutine update_om_coll_smat
!------------------------------------------------------------------------------
   subroutine get_psi_rhs_imp_coll_smat(us_Mloc, up_Mloc, om_Mloc, dom_Mloc,  &
              &                         psi_last, dpsi_imp_Mloc_last, vp_bal, &
              &                         l_vphi_bal_calc, l_calc_lin_rhs)

      !-- Input variables
      complex(cp), intent(in) :: us_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: up_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(in) :: om_Mloc(nMstart:nMstop,n_r_max)
      logical,     intent(in) :: l_vphi_bal_calc
      logical,     intent(in) :: l_calc_lin_rhs

      !-- Output variables
      complex(cp), intent(out) :: dom_Mloc(nMstart:nMstop,n_r_max)
      complex(cp), intent(inout) :: psi_last(nMstart:nMstop,n_r_max)
      complex(cp), intent(inout) :: dpsi_imp_Mloc_last(nMstart:nMstop,n_r_max)
      type(vp_bal_type), intent(inout) :: vp_bal

      !-- Local variables
      real(cp) :: duphi0(n_r_max), d2uphi0(n_r_max), uphi0(n_r_max)
      real(cp) :: dm2
      integer :: n_r, n_m, m, m0

      do n_r=1,n_r_max
         do n_m=nMstart,nMstop
            m = idx2m(n_m)
            if ( m == 0 ) then
               psi_last(n_m,n_r)=up_Mloc(n_m,n_r)
            else
               psi_last(n_m,n_r)=om_Mloc(n_m,n_r)
            end if
         end do
      end do

      if ( l_calc_lin_rhs .or. l_vphi_bal_calc ) then

         call get_ddr(om_Mloc, dom_Mloc, work_Mloc, nMstart, nMstop, &
              &       n_r_max, rscheme)

         m0 = m2idx(0)

         if ( l_rank_has_m0 ) then
            do n_r=1,n_r_max
               uphi0(n_r)=real(up_Mloc(m0, n_r),kind=cp)
            end do
            call get_ddr(uphi0, duphi0, d2uphi0, n_r_max, rscheme)
         end if

         do n_r=1,n_r_max
            do n_m=nMstart,nMstop
               m = idx2m(n_m)
               if ( m == 0 ) then
                  dpsi_imp_Mloc_last(n_m,n_r)=ViscFac*   d2uphi0(n_r)+     &
                  &                ViscFac*or1(n_r)*      duphi0(n_r)-     &
                  & (ViscFac*or2(n_r)+CorFac*ekpump(n_r))* uphi0(n_r)

                  if ( l_vphi_bal_calc ) then
                     vp_bal%visc(n_r)=ViscFac*(d2uphi0(n_r)+or1(n_r)*duphi0(n_r)-&
                     &                or2(n_r)*uphi0(n_r))
                     vp_bal%pump(n_r)=-CorFac*ekpump(n_r)*uphi0(n_r)
                  end if
               else
                  dm2 = real(m,cp)*real(m,cp)
                  dpsi_imp_Mloc_last(n_m,n_r)=ViscFac* work_Mloc(n_m,n_r) &
                  &           +ViscFac*or1(n_r)*        dom_Mloc(n_m,n_r) &
                  & -(CorFac*ekpump(n_r)+ViscFac*dm2*or2(n_r))*           &
                  &                                      om_Mloc(n_m,n_r) &
                  & +half*CorFac*ekpump(n_r)*beta(n_r)*  up_Mloc(n_m,n_r) &
                  & +CorFac*( ekpump(n_r)*beta(n_r)*(-ci*real(m,cp)+      &
                  &              5.0_cp*r_cmb*oheight(n_r)) )*            &
                  &                                      us_Mloc(n_m,n_r)

                  if ( l_coriolis_imp ) then
                     dpsi_imp_Mloc_last(n_m,n_r)=dpsi_imp_Mloc_last(n_m,n_r) &
                     &                   + CorFac*beta(n_r)*us_Mloc(n_m,n_r)
                  end if
               end if
            end do
         end do

      end if ! if wimp /= .or. l_vphi_bal_calc

   end subroutine get_psi_rhs_imp_coll_smat
!------------------------------------------------------------------------------
   subroutine get_psiMat(tscheme, m, psiMat, psiPivot, psiMat_fac, time_lu, &
              &          n_lu_calls)

      !-- Input variables
      type(type_tscheme), intent(in) :: tscheme
      integer,  intent(in) :: m

      !-- Output variables
      complex(cp), intent(out) :: psiMat(2*n_r_max,2*n_r_max)
      integer,     intent(out) :: psiPivot(2*n_r_max)
      real(cp),    intent(out) :: psiMat_fac(2*n_r_max,2)
      real(cp),    intent(inout) :: time_lu
      integer,     intent(inout) :: n_lu_calls

      !-- Local variables
      integer :: nR_out, nR, nR_psi, nR_out_psi, info
      real(cp) :: dm2, runStart, runStop

      dm2 = real(m,cp)*real(m,cp)

      !----- Boundary conditions:
      do nR_out=1,rscheme%n_max

         nR_out_psi = nR_out+n_r_max

         !-- Non-penetation condition
         psiMat(1,nR_out)          =0.0_cp
         psiMat(1,nR_out_psi)      =rscheme%rnorm*rscheme%rMat(1,nR_out)
         psiMat(n_r_max,nR_out)    =0.0_cp
         psiMat(n_r_max,nR_out_psi)=rscheme%rnorm*rscheme%rMat(n_r_max,nR_out)

         if ( ktopv == 1 ) then ! free-slip
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=rscheme%rnorm*(                &
            &                                 rscheme%d2rMat(1,nR_out)- &
            &                           or1(1)*rscheme%drMat(1,nR_out) )
         else
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=rscheme%rnorm*rscheme%drMat(1,nR_out)
         end if
         if ( kbotv == 1 ) then
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=rscheme%rnorm*(                 &
            &                            rscheme%d2rMat(n_r_max,nR_out)- &
            &                or1(n_r_max)*rscheme%drMat(n_r_max,nR_out) )
         else
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=rscheme%rnorm* &
            &                            rscheme%drMat(n_r_max,nR_out)
         end if
      end do


      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do nR_out=rscheme%n_max+1,n_r_max
            nR_out_psi = nR_out+n_r_max
            psiMat(1,nR_out)            =0.0_cp
            psiMat(n_r_max,nR_out)      =0.0_cp
            psiMat(n_r_max+1,nR_out)    =0.0_cp
            psiMat(2*n_r_max,nR_out)    =0.0_cp
            psiMat(1,nR_out_psi)        =0.0_cp
            psiMat(n_r_max,nR_out_psi)  =0.0_cp
            psiMat(n_r_max+1,nR_out_psi)=0.0_cp
            psiMat(2*n_r_max,nR_out_psi)=0.0_cp
         end do
      end if

      !----- Other points:
      do nR_out=1,n_r_max
         nR_out_psi=nR_out+n_r_max
         do nR=2,n_r_max-1
            nR_psi=nR+n_r_max

            psiMat(nR,nR_out)= rscheme%rnorm * (                         &
            &                                  rscheme%rMat(nR,nR_out) - &
            &   tscheme%wimp_lin(1)*(ViscFac*rscheme%d2rMat(nR,nR_out) + &
            &    ViscFac*or1(nR)*             rscheme%drMat(nR,nR_out) - &
            &  (CorFac*ekpump(nR)+ViscFac*dm2*or2(nR))*                  &
            &                                  rscheme%rMat(nR,nR_out) ) )

            psiMat(nR,nR_out_psi)=-rscheme%rnorm*tscheme%wimp_lin(1)*(   &
            &-half*CorFac*ekpump(nR)*beta(nR)*rscheme%drMat(nR,nR_out)+  &
            &  CorFac*( -half*ekpump(nR)*beta(nR)*beta(nR)               &
            &   +ekpump(nR)*beta(nR)*or1(nR)*( dm2+                      &
            &              5.0_cp*r_cmb*oheight(nR)*ci*real(m,cp)) )*    &
            &                                  rscheme%rMat(nR,nR_out) ) 

            if ( l_coriolis_imp ) then
               psiMat(nR,nR_out_psi) = psiMat(nR,nR_out_psi) -        &
               &                 rscheme%rnorm*tscheme%wimp_lin(1)*   &
               &               CorFac*beta(nR)*or1(nR)*ci*real(m,cp)* &
               &                rscheme%rMat(nR,nR_out)
            end if

            psiMat(nR_psi,nR_out)= rscheme%rnorm*rscheme%rMat(nR,nR_out)

            psiMat(nR_psi,nR_out_psi)= rscheme%rnorm * (              &
            &                             rscheme%d2rMat(nR,nR_out) + &
            &      (or1(nR)+beta(nR))*     rscheme%drMat(nR,nR_out) + &
            &  (or1(nR)*beta(nR)+dbeta(nR)-dm2*or2(nR))*              &
            &                               rscheme%rMat(nR,nR_out) )

         end do
      end do

      !----- Factor for highest and lowest cheb:
      do nR=1,n_r_max
         nR_psi = nR+n_r_max
         psiMat(nR,1)            =rscheme%boundary_fac*psiMat(nR,1)
         psiMat(nR,n_r_max)      =rscheme%boundary_fac*psiMat(nR,n_r_max)
         psiMat(nR,n_r_max+1)    =rscheme%boundary_fac*psiMat(nR,n_r_max+1)
         psiMat(nR,2*n_r_max)    =rscheme%boundary_fac*psiMat(nR,2*n_r_max)
         psiMat(nR_psi,1)        =rscheme%boundary_fac*psiMat(nR_psi,1)
         psiMat(nR_psi,n_r_max)  =rscheme%boundary_fac*psiMat(nR_psi,n_r_max)
         psiMat(nR_psi,n_r_max+1)=rscheme%boundary_fac*psiMat(nR_psi,n_r_max+1)
         psiMat(nR_psi,2*n_r_max)=rscheme%boundary_fac*psiMat(nR_psi,2*n_r_max)
      end do

      ! compute the linesum of each line
      do nR=1,2*n_r_max
         psiMat_fac(nR,1)=one/maxval(abs(psiMat(nR,:)))
      end do
      ! now divide each line by the linesum to regularize the matrix
      do nR=1,2*n_r_max
         psiMat(nR,:) = psiMat(nR,:)*psiMat_fac(nR,1)
      end do

      ! also compute the rowsum of each column
      do nR=1,2*n_r_max
         psiMat_fac(nR,2)=one/maxval(abs(psiMat(:,nR)))
      end do
      ! now divide each row by the rowsum
      do nR=1,2*n_r_max
         psiMat(:,nR) = psiMat(:,nR)*psiMat_fac(nR,2)
      end do

      !----- LU decomposition:
      runStart = MPI_Wtime()
      call prepare_full_mat(psiMat,2*n_r_max,2*n_r_max,psiPivot,info)
      runStop = MPI_Wtime()
      if ( runStop > runStart ) then
         time_lu = time_lu+(runStop-runStart)
         n_lu_calls = n_lu_calls+1
      end if
      if ( info /= 0 ) then
         call abortRun('Singular matrix psiMat!')
      end if


   end subroutine get_psiMat
!------------------------------------------------------------------------------
   subroutine get_uphiMat(tscheme, uphiMat, uphiPivot)

      !-- Input variables
      type(type_tscheme), intent(in) :: tscheme

      !-- Output variables
      real(cp), intent(out) :: uphiMat(n_r_max,n_r_max)
      integer,  intent(out) :: uphiPivot(n_r_max)

      !-- Local variables
      integer :: nR_out, nR, info

      !----- Boundary conditions:
      do nR_out=1,rscheme%n_max
         if ( ktopv == 1 ) then !-- Free-slip
            uphiMat(1,nR_out)=rscheme%rnorm*(rscheme%drMat(1,nR_out)-or1(1)* &
            &                                 rscheme%rMat(1,nR_out))
         else
            uphiMat(1,nR_out)=rscheme%rnorm*rscheme%rMat(1,nR_out)
         end if
         if ( kbotv == 1 ) then !-- Free-slip
            uphiMat(n_r_max,nR_out)=rscheme%rnorm*(                 &
            &                        rscheme%drMat(n_r_max,nR_out)  &
            &           -or1(n_r_max)*rscheme%rMat(n_r_max,nR_out))
         else
            uphiMat(n_r_max,nR_out)=rscheme%rnorm* &
            &                       rscheme%rMat(n_r_max,nR_out)
         end if
      end do


      if ( rscheme%n_max < n_r_max ) then ! fill with zeros !
         do nR_out=rscheme%n_max+1,n_r_max
            uphiMat(1,nR_out)      =0.0_cp
            uphiMat(n_r_max,nR_out)=0.0_cp
         end do
      end if

      !----- Other points:
      do nR_out=1,n_r_max
         do nR=2,n_r_max-1
            uphiMat(nR,nR_out)= rscheme%rnorm * (                     &
            &                               rscheme%rMat(nR,nR_out) - &
            &tscheme%wimp_lin(1)*(ViscFac*rscheme%d2rMat(nR,nR_out) + &
            &    ViscFac*or1(nR)*          rscheme%drMat(nR,nR_out) - &
            &  (CorFac*ekpump(nR)+ViscFac*or2(nR))*                   &
            &                               rscheme%rMat(nR,nR_out) ) )
         end do
      end do

      !----- Factor for highest and lowest cheb:
      do nR=1,n_r_max
         uphiMat(nR,1)      =rscheme%boundary_fac*uphiMat(nR,1)
         uphiMat(nR,n_r_max)=rscheme%boundary_fac*uphiMat(nR,n_r_max)
      end do

      !----- LU decomposition:
      call prepare_full_mat(uphiMat,n_r_max,n_r_max,uphiPivot,info)
      if ( info /= 0 ) then
         call abortRun('Singular matrix uphiMat!')
      end if

   end subroutine get_uphiMat
!------------------------------------------------------------------------------
end module update_psi_coll_smat
