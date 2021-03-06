function [busout, genout, branchout, f, success, info, et, g, jac, xr, pimul] = ...
    mpopf(mpc, profile, mpopt)
%MPOPF  Solves an optimal power flow.
%   [RESULTS, SUCCESS] = MPOPF(MPC, PROFILE, MPOPT)
%
%   Returns either a RESULTS struct and an optional SUCCESS flag, or individual
%   data matrices, the objective function value and a SUCCESS flag. In the
%   latter case, there are additional optional return values. See Examples
%   below for the possible calling syntax options.
%
%   Examples:
%       Output argument options:
%
%       results = opf(...)
%       [results, success] = opf(...)
%       [bus, gen, branch, f, success] = opf(...)
%       [bus, gen, branch, f, success, info, et, g, jac, xr, pimul] = opf(...)
%
%       Input arguments options:
%
%       opf(mpc)
%       opf(mpc, mpopt)
%       opf(mpc, userfcn, mpopt)
%       opf(mpc, A, l, u)
%       opf(mpc, A, l, u, mpopt)
%       opf(mpc, A, l, u, mpopt, N, fparm, H, Cw)
%       opf(mpc, A, l, u, mpopt, N, fparm, H, Cw, z0, zl, zu)
%
%       opf(baseMVA, bus, gen, branch, areas, gencost)
%       opf(baseMVA, bus, gen, branch, areas, gencost, mpopt)
%       opf(baseMVA, bus, gen, branch, areas, gencost, userfcn, mpopt)
%       opf(baseMVA, bus, gen, branch, areas, gencost, A, l, u)
%       opf(baseMVA, bus, gen, branch, areas, gencost, A, l, u, mpopt)
%       opf(baseMVA, bus, gen, branch, areas, gencost, A, l, u, ...
%                                   mpopt, N, fparm, H, Cw)
%       opf(baseMVA, bus, gen, branch, areas, gencost, A, l, u, ...
%                                   mpopt, N, fparm, H, Cw, z0, zl, zu)
%
%   The data for the problem can be specified in one of three ways:
%   (1) a string (mpc) containing the file name of a MATPOWER case
%     which defines the data matrices baseMVA, bus, gen, branch, and
%     gencost (areas is not used at all, it is only included for
%     backward compatibility of the API).
%   (2) a struct (mpc) containing the data matrices as fields.
%   (3) the individual data matrices themselves.
%   
%   The optional user parameters for user constraints (A, l, u), user costs
%   (N, fparm, H, Cw), user variable initializer (z0), and user variable
%   limits (zl, zu) can also be specified as fields in a case struct,
%   either passed in directly or defined in a case file referenced by name.
%   
%   When specified, A, l, u represent additional linear constraints on the
%   optimization variables, l <= A*[x; z] <= u. If the user specifies an A
%   matrix that has more columns than the number of "x" (OPF) variables,
%   then there are extra linearly constrained "z" variables. For an
%   explanation of the formulation used and instructions for forming the
%   A matrix, see the manual.
%
%   A generalized cost on all variables can be applied if input arguments
%   N, fparm, H and Cw are specified.  First, a linear transformation
%   of the optimization variables is defined by means of r = N * [x; z].
%   Then, to each element of r a function is applied as encoded in the
%   fparm matrix (see manual). If the resulting vector is named w,
%   then H and Cw define a quadratic cost on w: (1/2)*w'*H*w + Cw * w .
%   H and N should be sparse matrices and H should also be symmetric.
%
%   The optional mpopt vector specifies MATPOWER options. If the OPF
%   algorithm is not explicitly set in the options MATPOWER will use
%   the default solver, based on a primal-dual interior point method.
%   For the AC OPF this is opf.ac.solver = 'MIPS', unless the TSPOPF optional
%   package is installed, in which case the default is 'PDIPM'. For the
%   DC OPF, the default is opf.dc.solver = 'MIPS'. See MPOPTION for
%   more details on the available OPF solvers and other OPF options
%   and their default values.
%
%   The solved case is returned either in a single results struct (described
%   below) or in the individual data matrices, bus, gen and branch. Also
%   returned are the final objective function value (f) and a flag which is
%   true if the algorithm was successful in finding a solution (success).
%   Additional optional return values are an algorithm specific return status
%   (info), elapsed time in seconds (et), the constraint vector (g), the
%   Jacobian matrix (jac), and the vector of variables (xr) as well 
%   as the constraint multipliers (pimul).
%
%   The single results struct is a MATPOWER case struct (mpc) with the
%   usual baseMVA, bus, branch, gen, gencost fields, along with the
%   following additional fields:
%
%       .order      see 'help ext2int' for details of this field
%       .et         elapsed time in seconds for solving OPF
%       .success    1 if solver converged successfully, 0 otherwise
%       .om         OPF model object, see 'help opf_model'
%       .x          final value of optimization variables (internal order)
%       .f          final objective function value
%       .mu         shadow prices on ...
%           .var
%               .l  lower bounds on variables
%               .u  upper bounds on variables
%           .nln
%               .l  lower bounds on nonlinear constraints
%               .u  upper bounds on nonlinear constraints
%           .lin
%               .l  lower bounds on linear constraints
%               .u  upper bounds on linear constraints
%       .raw        raw solver output in form returned by MINOS, and more
%           .xr     final value of optimization variables
%           .pimul  constraint multipliers
%           .info   solver specific termination code
%           .output solver specific output information
%              .alg algorithm code of solver used
%           .g      (optional) constraint values
%           .dg     (optional) constraint 1st derivatives
%           .df     (optional) obj fun 1st derivatives (not yet implemented)
%           .d2f    (optional) obj fun 2nd derivatives (not yet implemented)
%       .var
%           .val    optimization variable values, by named block
%               .Va     voltage angles
%               .Vm     voltage magnitudes (AC only)
%               .Pg     real power injections
%               .Qg     reactive power injections (AC only)
%               .y      constrained cost variable (only if have pwl costs)
%               (other) any user defined variable blocks
%           .mu     variable bound shadow prices, by named block
%               .l  lower bound shadow prices
%                   .Va, Vm, Pg, Qg, y, (other)
%               .u  upper bound shadow prices
%                   .Va, Vm, Pg, Qg, y, (other)
%       .nle    (AC only)
%           .lambda shadow prices on nonlinear equality constraints,
%                   by named block
%                   .Pmis   real power mismatch equations
%                   .Qmis   reactive power mismatch equations
%                   (other) use defined constraints
%       .nli    (AC only)
%           .mu     shadow prices on nonlinear inequality constraints,
%                   by named block
%                   .Sf     flow limits at "from" end of branches
%                   .St     flow limits at "to" end of branches
%                   (other) use defined constraints
%       .lin
%           .mu     shadow prices on linear constraints, by named block
%               .l  lower bounds
%                   .Pmis   real power mistmatch equations (DC only)
%                   .Pf     flow limits at "from" end of branches (DC only)
%                   .Pt     flow limits at "to" end of branches (DC only)
%                   .PQh    upper portion of gen PQ-capability curve (AC only)
%                   .PQl    lower portion of gen PQ-capability curve (AC only)
%                   .vl     constant power factor constraint for loads (AC only)
%                   .ycon   basin constraints for CCV for pwl costs
%                   (other) any user defined constraint blocks
%               .u  upper bounds
%                   .Pmis, Pf, Pt, PQh, PQl, vl, ycon, (other)
%       .cost       user defined cost values, by named block
%
%   See also RUNOPF, DCOPF, UOPF, CASEFORMAT.

%   MATPOWER
%   Copyright (c) 1996-2016, Power Systems Engineering Research Center (PSERC)
%   by Ray Zimmerman, PSERC Cornell
%   and Carlos E. Murillo-Sanchez, PSERC Cornell & Universidad Nacional de Colombia
%
%   This file is part of MATPOWER.
%   Covered by the 3-clause BSD License (see LICENSE file for details).
%   See http://www.pserc.cornell.edu/matpower/ for more info.

%%----- initialization -----
t0 = clock;         %% start timer

%% define named indices into data matrices
[PQ, PV, REF, NONE, BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, ...
    VA, BASE_KV, ZONE, VMAX, VMIN, LAM_P, LAM_Q, MU_VMAX, MU_VMIN] = idx_bus;
[GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, GEN_STATUS, PMAX, PMIN, ...
    MU_PMAX, MU_PMIN, MU_QMAX, MU_QMIN, PC1, PC2, QC1MIN, QC1MAX, ...
    QC2MIN, QC2MAX, RAMP_AGC, RAMP_10, RAMP_30, RAMP_Q, APF] = idx_gen;
[F_BUS, T_BUS, BR_R, BR_X, BR_B, RATE_A, RATE_B, RATE_C, ...
    TAP, SHIFT, BR_STATUS, PF, QF, PT, QT, MU_SF, MU_ST, ...
    ANGMIN, ANGMAX, MU_ANGMIN, MU_ANGMAX] = idx_brch;
[PW_LINEAR, POLYNOMIAL, MODEL, STARTUP, SHUTDOWN, NCOST, COST] = idx_cost;

%% process input arguments
%[mpc, profile, mpopt] = opf_args(varargin{:});

%% if 'opf.ac.solver' not set, choose MIPS
if strcmp(upper(mpopt.opf.ac.solver), 'DEFAULT')
    mpopt = mpoption(mpopt, 'opf.ac.solver', 'IPOPT');   %% originally MIPS
end

%% handle deprecated 'opf.init_from_mpc' option
if mpopt.opf.start == 0
    if mpopt.opf.init_from_mpc == 0     %% ignore MPC
        mpopt.opf.start = 1;
    elseif mpopt.opf.init_from_mpc == 1 %% use MPC
        mpopt.opf.start = 2;
    end
end

%% initialize state with power flow solution, if requested
if mpopt.opf.start == 3
    mpopt_pf = mpoption(mpopt, 'out.all', 0, 'verbose', max(0, mpopt.verbose-1));
    if mpopt.verbose
        fprintf('Running power flow to initialize OPF.\n');
    end
    rpf = runpf(mpc, mpopt_pf);
    if rpf.success
        mpc = rpf;      %% or should I just copy Va, Vm, Pg, Qg?
    end
end

%% add zero columns to bus, gen, branch for multipliers, etc if needed
nb   = size(mpc.bus, 1);    %% number of buses
nl   = size(mpc.branch, 1); %% number of branches
ng   = size(mpc.gen, 1);    %% number of dispatchable injections
if size(mpc.bus,2) < MU_VMIN
  mpc.bus = [mpc.bus zeros(nb, MU_VMIN-size(mpc.bus,2)) ];
end
if size(mpc.gen,2) < MU_QMIN
  mpc.gen = [ mpc.gen zeros(ng, MU_QMIN-size(mpc.gen,2)) ];
end
if size(mpc.branch,2) < MU_ANGMAX
  mpc.branch = [ mpc.branch zeros(nl, MU_ANGMAX-size(mpc.branch,2)) ];
end

%%-----  make sure load scaling profile is a row vector            -------
if(size(profile,1) <= 0 || size(profile,2) <= 0)
   error('Load scaling profile cannot be empty'); 
end

%transform profile to row vector
if(size(profile,1) > 1)
    profile = profile';
end

%%-----  convert to internal numbering, remove out-of-service stuff  -----
% Storage devices are appended to the mpc.gen struct. Ext2int requires
% ordering of mpc.gen according to increasing bus number.
% There will be problem if the storage is placed somewhere in between the normal generators
% we will need to take care of the ordering => This is handled by ext2int call below.
% The A matrix needs to be reordered accordingly, storages from the end need to be
% shuffled in between the time-steps, so that the vars from period_i are consecutively ordered
Aext = mpc.A;
mpc = ext2int(mpc);
%permute the A manually
mpc.A = ext2intA(mpc, length(profile), Aext);


%%----- build mpopf indexing -----
%pass index functions to solvers in order to properly construct x and evaluate callbacks
index = struct('getGlobalIndices', @getGlobalIndices, ...
               'getLocalIndicesOPF', @getLocalIndicesOPF);
           
mpopf_aux = struct('profile', profile, 'index', index);

%%-----  construct OPF model object  -----
om = mpopf_setup(mpc, mpopf_aux, mpopt);

%%-----  execute the OPF  -----
if nargout > 7
    mpopt.opf.return_raw_der = 1;
end
if ~isempty(mpc.bus)
    [results, success, raw] = mpopf_execute(om, mpopf_aux, mpopt);
else
    results = mpc;
    success = 0;
    raw.output.message = 'MATPOWER case contains no connected buses';
    if mpopt.verbose
        fprintf('OPF not valid : %s', raw.output.message);
    end
end

%%-----  revert to original ordering, including out-of-service stuff  -----
results = int2ext(results);
results.A = Aext;

%% zero out result fields of out-of-service gens & branches
if ~isempty(results.order.gen.status.off)
  results.gen(results.order.gen.status.off, [PG QG MU_PMAX MU_PMIN]) = 0;
end
if ~isempty(results.order.branch.status.off)
  results.branch(results.order.branch.status.off, [PF QF PT QT MU_SF MU_ST MU_ANGMIN MU_ANGMAX]) = 0;
end

%%-----  finish preparing output  -----
et = etime(clock, t0);      %% compute elapsed time
if nargout > 0
  if nargout <= 2
    results.et = et;
    results.success = success;
    results.raw = raw;
    busout = results;
    genout = success;
  else
    [busout, genout, branchout, f, info, xr, pimul] = deal(results.bus, ...
        results.gen, results.branch, results.f, raw.info, raw.xr, raw.pimul);
    if isfield(results, 'g')
      g = results.g;
    end
    if isfield(results, 'dg')
      jac = results.dg;
    end
  end
elseif success
  results.et = et;
  results.success = success;
  printpf(results, 1, mpopt);
end

%% -----  helper functions  ----- 
function idx = getGlobalIndices(mpc, nt, i)
% returns indices of local OPF variables of period i in vector x_ipopt
% OPF variables are ordered local first, global variables then: [Va Vm Pg Qg]
% scenarios i are indexed 0..NS-1
nb = size(mpc.bus, 1);          %% number of buses
ng = size(mpc.gen, 1);          %% number of gens
nl = size(mpc.branch, 1);       %% number of branches

%TODO what about the ref. angle that is removed by ipopt?
nPart = 2*nb + 2*ng; %number of local variables for each time period [Va Vm Pg Qg]

li1 = i*nb + (1:nb); %indices of local [Va] of period i
li2 = nt*nb + i*nb + (1:nb); %indices of local [Vm] of period i
li3 = 2*nt*nb + i*ng + (1:ng); %indices of local [Pg] of period i
li4 = 2*nt*nb + nt*ng + i*ng + (1:ng); %indices of local [Qg] at period i

idx = [li1 li2 li3 li4]; %return in order [Va Vm Pg Qg]

function [VAi, VMi, PGi, QGi] = getLocalIndicesOPF(mpc)
%extracts variables from OPF variables vector x
%usage: x([VAi VMi PGi QGi])
nb = size(mpc.bus, 1);          %% number of buses
ng = size(mpc.gen, 1);          %% number of gens
nl = size(mpc.branch, 1);       %% number of branches

VAi = 1:nb;
VMi = nb + (1:nb);
PGi = 2*nb + (1:ng);
QGi = 2*nb + ng + (1:ng);

% We need to permute columns of the A
% The ordering of variables is:
% Va(1-N)   Vm(1-N)  Pg(1-N) Pg_dis(1-N) Pg_c(1-N) and same for Qg... 
% The goal is to have ordering
% Va(1-N)   Vm(1-N)  [Pg(1) Pg_dis(1) Pg_c(1)].ext2int  [...(2)].ext2int
% the reasong for applying ext2int is to sort generators according to
% increasing bus number
function Ap = ext2intA(mpc, nt, A)
nb = size(mpc.bus, 1);          %% number of buses
ns = mpc.nstorage;              %% number of storages
ng = size(mpc.gen, 1) - 2*ns;   %% number of gens
NG = ng + 2*ns;                 %% number of gens incl. storages

perm = ones(size(A,2),1);

%do not permute Va Vm variables
VaVmOffset = nt*2*nb;
perm(1:VaVmOffset) = 1:VaVmOffset;
offset = VaVmOffset;

for i = 0:nt-1
   Pg_i = VaVmOffset + i*ng + (1:ng);
   PgD_i = VaVmOffset + nt*ng + i*ns + (1:ns);
   PgC_i = VaVmOffset + nt*ng + nt*ns + i*ns + (1:ns);
   
   %gather Pg variables of the i-th period
   gen_i = [Pg_i PgD_i PgC_i];
   
   %permute the Pg variables of i-th period
   %and insert it to the perm. of A
   perm(offset + (1:NG)) = gen_i(mpc.order.gen.e2i);
   offset = offset + NG;
end

%do not permute Qg variables, zeros in A
perm(offset+1:end) = offset+1:size(A,2);

%and finally apply the permutation to A
Ap = A(:,perm);







