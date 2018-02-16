clear; close all;
addpath( ...
    '/Users/Juraj/Documents/Optimization/matpower/lib', ...
    '/Users/Juraj/Documents/Optimization/matpower/lib/t', ...
    '/Users/Juraj/Documents/Optimization/matpower/data', ...
    '/Users/Juraj/Documents/Optimization/matpower/mips/lib', ...
    '/Users/Juraj/Documents/Optimization/matpower/mips/lib/t', ...
    '/Users/Juraj/Documents/Optimization/matpower/most/lib', ...
    '/Users/Juraj/Documents/Optimization/matpower/most/lib/t', ...
    '/Users/Juraj/Documents/Optimization/matpower/mptest/lib', ...
    '/Users/Juraj/Documents/Optimization/matpower/mptest/lib/t', ...
    '-end' );


setenv('OMP_NUM_THREADS', '1');
%setenv('IPOPT_WRITE_MAT','1');

define_constants;
%% Select and configure the solver
SOLVER = 1;
if (SOLVER == 1)
    %for further options see ipopt.opt
    mpopt = mpoption('opf.ac.solver', 'IPOPT', 'verbose', 2);
elseif (SOLVER == 2)
    mpopt = mpoption('opf.ac.solver', 'MIPS', 'verbose', 3);
    mpopt.mips.max_it  = 100;
    mpopt.mips.max_stepsize = 1e12;
    mpopt.mips.feastol = 1e-4;
    mpopt.mips.gradtol = 1e-2;
    mpopt.mips.comptol = 1e-2;
    mpopt.mips.costtol = 1e-2;
    %mpopt.mips.linsolver='PARDISO';
else
    mpopt = mpoption('opf.ac.solver', 'OPTIZELLE');
end

mpopt = mpoption(mpopt, 'opf.init_from_mpc', 2);

%% load MATPOWER case struct, see help caseformat
%mpc = loadcase('case89pegase');
%mpc = loadcase('case_swiss');
mpc = loadcase('case118');
%mpc = loadcase('case9');
%mpc = loadcase('case89pegase');
%mpc = loadcase('case1354pegase');
%mpc = loadcase('case2868rte');
%mpc = loadcase('case9241pegase');
%mpc = case231swiss;
%mpc = loadcase('case_ACTIVSg2000');

%%
%insert missing branch limits
no_limit = find(mpc.branch(:,RATE_A) < 1e-10);
mpc.branch(no_limit,RATE_A) = 1e5;

%FOR SWISS GRID, not enough Qg
%mpc.gen(:,QMAX)=mpc.gen(:,QMAX)*10;
%mpc.gen(:,QMIN)=mpc.gen(:,QMIN)+5*mpc.gen(:,QMIN);

%% Print info on load and generation capacity of the CASE
generatorsON = find(mpc.gen(:,GEN_STATUS) > 0);

PGmin_sum = sum(mpc.gen(generatorsON,PMIN));
PGmax_sum = sum(mpc.gen(generatorsON,PMAX));
QGmin_sum = sum(mpc.gen(generatorsON,QMIN));
QGmax_sum = sum(mpc.gen(generatorsON,QMAX));

PD_sum = sum(mpc.bus(:,PD));
QD_sum = sum(mpc.bus(:,QD));

fprintf('     MIN       ACTUAL        MAX\n');
fprintf('P: %.2f <= %.2f <= %.2f\n', PGmin_sum, PD_sum, PGmax_sum);
fprintf('Q: %.2f <= %.2f <= %.2f\n', QGmin_sum, QD_sum, QGmax_sum);

%% Specify contingencies case 118
cont = -5;

%% Set required tolerance for satysfying PF equations (i.e. equality constraints |gx| < tol) and run SCOPF
tol = 1e-4;
r = runscopf(mpc, cont, mpopt, tol);

%%
% read-in IPOPT hessian and permute it
% name = ls('mat-ipopt_004-*');
% starts = strfind(name,'mat-ipopt'); %check if there is more mat-ipopt_004s
% if size(starts,2) > 1
%    name = name(1:starts(2)-2); %pick first file 004_
% else
%     name = name(1:end-1); % delete trailing ' '
% end
% 
% A = readcsr(name, 0, 1);
% 
% [P Pinv, npart] = KKTpermute(mpc, length(cont)+1);
% AP = A(P,P');
