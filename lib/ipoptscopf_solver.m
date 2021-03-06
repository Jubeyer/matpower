function [results, success, raw] = ipoptscopf_solver(om, model, mpopt)
%IPOPTOPF_SOLVER  Solves AC optimal power flow with security constraints using IPOPT.
%
%   [RESULTS, SUCCESS, RAW] = IPOPTSCOPF_SOLVER(OM, MODEL, MPOPT)
%
%   Inputs are an OPF model object, SCOPF model and a MATPOWER options struct.
%
%   Model is a struct with following fields:
%       .cont Containts a list of contingencies
%       .index Contains functions to handle proper indexing of SCOPF variables
%           .getGlobalIndices
%           .getLocalIndicesOPF
%           .getLocalIndicesSCOPF
%           .getREFgens
%           .getPVbuses
%
%   Outputs are a RESULTS struct, SUCCESS flag and RAW output struct.
%
%   The internal x that ipopt works with has structure
%   [Va1 Vm1 Qg1 Pg_ref1... VaN VmN QgN Pg_refN] [Vm Pg] for all contingency scenarios 1..N
%   with corresponding bounds xmin < x < xmax
%
%   We impose nonlinear equality and inequality constraints g(x) and h(x)
%   with corresponding bounds cl < [g(x); h(x)] < cu
%   and linear constraints l < Ax < u.
%
%   See also OPF, IPOPT.
%% TODO
% need to work more efficiently with sparse indexing during construction
% of global hessian/jacobian

% how to account for the sparse() leaving out zeros from the sparse
% structure? We want to have exactly same structure across scenarios

%%----- initialization -----
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

%% unpack data
mpc = om.get_mpc();
[baseMVA, bus, gen, branch, gencost] = ...
    deal(mpc.baseMVA, mpc.bus, mpc.gen, mpc.branch, mpc.gencost);
[vv, ll, nn] = om.get_idx();

cont = model.cont;


%% problem dimensions
nb = size(bus, 1);          %% number of buses
ng = size(gen, 1);          %% number of gens
nl = size(branch, 1);       %% number of branches
ns = size(cont, 1);         %% number of scenarios (nominal + ncont)

% get indices of REF gen and of REF/PV buses
[REFgen_idx, nREFgen_idx] = model.index.getREFgens(mpc);
[REFbus_idx,nREFbus_idx] = model.index.getXbuses(mpc,3);%3==REF
[PVbus_idx, nPVbus_idx] = model.index.getXbuses(mpc,2);%2==PV

% indices of local OPF solution vector x = [VA VM PG QG]
[VAscopf, VMscopf, PGscopf, QGscopf] = model.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = model.index.getLocalIndicesOPF(mpc);

%% build admittance matrices for nominal case
[Ybus, Yf, Yt] = makeYbus(baseMVA, bus, branch);

%% bounds on optimization vars xmin <= x <= xmax 
[x0, xmin, xmax] = om.params_var();

% Note that variables with equal upper and lower bounds are removed by IPOPT
% so we add small perturbation to x_u[], we don't want them removed
% because the Schur solver assumes particular structure that would
% be changed by removing variables.
% Exept for the Va at the refernece bus which we want to remove (in each scenario).
idx = find(xmin == xmax);
xmax(idx) = xmax(idx) + 1e-10;
for i = 0:ns-1
    idx = model.index.getGlobalIndices(mpc, ns, i);
    xmax(idx(VAscopf(REFbus_idx))) = xmin(REFbus_idx);
end
%xmax(REFbus_idx) = xmin(REFbus_idx); %only nominal case

%% try to select an interior initial point based on bounds

if mpopt.opf.init_from_mpc == 0
    ll = xmin; uu = xmax;
    ll(xmin == -Inf) = -1e10;               %% replace Inf with numerical proxies
    uu(xmax ==  Inf) =  1e10;
    x0 = (ll + uu) / 2;                     %% set x0 mid-way between bounds
    k = find(xmin == -Inf & xmax < Inf);    %% if only bounded above
    x0(k) = xmax(k) - 1;                    %% set just below upper bound
    k = find(xmin > -Inf & xmax == Inf);    %% if only bounded below
    x0(k) = xmin(k) + 1;                    %% set just above lower bound
    
    % adjust voltage angles to match reference bus
    Varefs = bus(REFbus_idx, VA) * (pi/180);
    for i = 0:ns-1
        idx = model.index.getGlobalIndices(mpc, ns, i);
        x0(idx(VAscopf)) = Varefs(1);
    end

elseif mpopt.opf.init_from_mpc == 1
    %solve local PF and use it as an initial guess
    x0 = ones(length(xmin),1);
    
    for i = 1:ns
        %update mpc first by removing a line
        c = cont(i);
        mpc_tmp = mpc;
        if(c > 0)
            mpc_tmp.branch(c,BR_STATUS) = 0;
        end    
        
        mpopt0 = mpoption('verbose', 0, 'out.all', 0);
        [results, success] = runpf(mpc_tmp, mpopt0);
    
        %external to internal permunation
        Pgen = results.order.gen.e2i;
        genON = find(results.gen(:,GEN_STATUS)==1); %ON generators
        Pbus = results.order.bus.e2i;
        x = [ results.bus(:,VA)/(180/pi); ...
              results.bus(:,VM); ...
              results.gen(genON(Pgen),PG)/results.baseMVA; ...
              results.gen(genON(Pgen),QG)/results.baseMVA ];
        
        %embed local PF solution into the x0
        idx = model.index.getGlobalIndices(mpc, ns, i-1);
        x0(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = x([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);
        if i == 1
           x0(idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = x([VMopf(PVbus_idx) PGopf(nREFgen_idx)]);
        end
    end   
    
elseif mpopt.opf.init_from_mpc == 2
    %solve nominal OPF and use it as an initial guess
    x0 = ones(length(xmin),1);
    
    mpopt0 = mpoption('verbose', 0, 'out.all', 0);
    mpopt_tmp = mpoption(mpopt0, 'opf.ac.solver', 'IPOPT');
    [results, success] = runopf(mpc, mpopt_tmp);
    
    %external to internal permunation
    Pgen = results.order.gen.e2i;
    genON = find(results.gen(:,GEN_STATUS)==1); %ON generators
    Pbus = results.order.bus.e2i;
    x = [ results.bus(:,VA)/(180/pi); ...
          results.bus(:,VM); ...
          results.gen(genON(Pgen),PG)/results.baseMVA; ...
          results.gen(genON(Pgen),QG)/results.baseMVA ];

    % verify if we reconstructed x correctly
    err = find(abs(x - results.x) > 1e-10);
    if (~isempty(err))
       error('Different ordering of internal/external MPC structure'); 
    end
    
    for i = 1:ns
        %embed local OPF solution into the x0
        idx = model.index.getGlobalIndices(mpc, ns, i-1);
        x0(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = x([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);
        if i == 1
           x0(idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = x([VMopf(PVbus_idx) PGopf(nREFgen_idx)]);
        end
    end 
    
elseif mpopt.opf.init_from_mpc == 3
    %solve local OPFs and use it as an initial guess
    x0 = ones(length(xmin),1);
    for i = 1:ns
        %update mpc first by removing a line
        c = cont(i);
        mpc_tmp = mpc;
        if(c > 0)
            mpc_tmp.branch(c,BR_STATUS) = 0;
        end
    
        %run opf
        mpopt0 = mpoption('verbose', 0, 'out.all', 0);
        mpopt_tmp = mpoption(mpopt0, 'opf.ac.solver', 'IPOPT');
        [results, success] = runopf(mpc_tmp, mpopt_tmp);
        
        %external to internal permunation
        Pgen = results.order.gen.e2i;
        genON = find(results.gen(:,GEN_STATUS)==1); %ON generators
        Pbus = results.order.bus.e2i;
        x = [ results.bus(:,VA)/(180/pi); ...
              results.bus(:,VM); ...
              results.gen(genON(Pgen),PG)/results.baseMVA; ...
              results.gen(genON(Pgen),QG)/results.baseMVA ];
        
        % verify if we reconstructed x correctly
        err = find(abs(x - results.x) > 1e-10);
        if (~isempty(err))
           error('Different ordering of internal/external MPC structure'); 
        end

        %embed local OPF solution into the x0
        idx = model.index.getGlobalIndices(mpc, ns, i-1);
        x0(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = x([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);
        if i == 1
           x0(idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = x([VMopf(PVbus_idx) PGopf(nREFgen_idx)]);
        end
    end 
    
elseif mpopt.opf.init_from_mpc == 4
    %solve local SCOPFs and use it as an initial guess
    x0 = ones(length(xmin),1);
    for i = 1:ns
        %update mpc first by removing a line
        c = cont(i);
        cont_tmp = [];
        mpc_tmp = mpc;
        if(c > 0)
            cont_tmp = [c];
        end
    
        %run opf
        mpopt0 = mpoption('verbose', 0, 'out.all', 0);
        mpopt_tmp = mpoption(mpopt0, 'opf.ac.solver', 'IPOPT', 'opf.init_from_mpc', 0);
        tolerance = 1e-3;
        mpopt_tmp.ipopt.opts = struct('max_iter', 250, 'tol', tolerance, ...
        'dual_inf_tol', tolerance, 'constr_viol_tol', tolerance, ...
        'compl_inf_tol', tolerance);
        [results, success] = runscopf(mpc_tmp, cont_tmp, mpopt_tmp, 1e-2);
        
        %extract solution of local SCOPF
        x = results.raw.xr;

        %embed local SCOPF solution into the x0
        idx = model.index.getGlobalIndices(mpc, ns, i-1);
        if i == 1
           idx_tmp = model.index.getGlobalIndices(mpc, 1, 0); %only nominal case, pure OPF solution
           x0(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = x(idx_tmp([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)]));
           x0(idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = x(idx_tmp([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)]));
        else
           idx_tmp = model.index.getGlobalIndices(mpc, 2, 1); %nominal case and a single contingency c
           x0(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = x(idx_tmp([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])); 
        end
    end    

end

%% find branches with flow limits

%insert default limits to branches that do not have this value
il_ = find(branch(:, RATE_A) ~= 0 & branch(:, RATE_A) < 1e10);
il = [1:nl]';               
nl2 = length(il);           %% number of constrained lines

if size(il_, 1) ~= nl2
    error('Not all branches have specified RATE_A field.');
end


%% build linear constraints l <= A*x <= u

% [A, l, u] = om.params_lin_constraint();
A = [];
l = [];
u = [];


%% build local connectivity matrices
f = branch(:, F_BUS);                           %% list of "from" buses
t = branch(:, T_BUS);                           %% list of "to" buses
Cf = sparse(1:nl, f, ones(nl, 1), nl, nb);      %% connection matrix for line & from buses
Ct = sparse(1:nl, t, ones(nl, 1), nl, nb);      %% connection matrix for line & to buses
Cl = Cf + Ct;                                   %% for each line - from & to 
Cb_nominal = Cl' * Cl + speye(nb);              %% for each bus - contains adjacent buses
Cl2_nominal = Cl(il, :);                        %% branches with active flow limit
Cg = sparse(gen(:, GEN_BUS), (1:ng)', 1, nb, ng); %%locations where each gen. resides

%% Jacobian of constraints
Js = sparse(0,0);

for i = 0:ns-1
    %update Cb to reflect the bus connectivity caused by contingency
    Cb = Cb_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        f = branch(c, F_BUS);                           %% "from" bus
        t = branch(c, T_BUS);                           %% "to" bus
        Cb(f,t) = 0;
        Cb(t,f) = 0;
    end
    
    %update Cl to reflect the contingency
    Cl2 = Cl2_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        Cl2(c, :) = 0;
    end
    
    % Jacobian wrt local variables
    %     dVa  dVm(nPV)   dQg   dPg(REF)   <- local variables for each scenario
    %    | Cb     Cb'      0     Cg' | ('one' at row of REF bus, otherwise zeros) 
    %    |                           |
    %    | Cb     Cb'      Cg     0  |
    %    |                           |
    %    | Cl     Cl'      0      0  | 
    %    |                           |
    %    | Cl     Cl'      0      0  |
    Js_local = [
        Cb      Cb(:, nPVbus_idx)    sparse(nb, ng)   Cg(:, REFgen_idx);
        Cb      Cb(:, nPVbus_idx)     Cg              sparse(nb, 1);
        Cl2     Cl2(:, nPVbus_idx)   sparse(nl2, ng+1);
        Cl2     Cl2(:, nPVbus_idx)   sparse(nl2, ng+1);
    ];
    % Jacobian wrt global variables
    %     dVm(PV) dPg(nREF)   <- global variables for all scenarios
    %    | Cb'        Cg'  | ('one' at row of REF bus, otherwise zeros) 
    %    |                 |
    %    | Cb'         0   |
    %    |                 |
    %    | Cl'         0   |
    %    |                 |
    %    | Cl'         0   |
    Js_global = [
     Cb(:, PVbus_idx)  Cg(:, nREFgen_idx);
     Cb(:, PVbus_idx)  sparse(nb, ng-1);
     Cl2(:, PVbus_idx) sparse(nl2, ng-1);
     Cl2(:, PVbus_idx) sparse(nl2, ng-1);
    ];

    Js = [Js;
          sparse(size(Js_local,1), i*size(Js_local,2)) Js_local sparse(size(Js_local,1), (ns-1-i)*size(Js_local,2)) Js_global];

%     Js = kron(eye(ns), Js_local); %replicate jac. w.r.t local variables
%     Js = [Js kron(ones(ns,1), Js_global)]; % replicate and append jac w.r.t global variables
end
Js = [Js; A]; %append linear constraints

%% Hessian of lagrangian Hs = f(x)_dxx + c(x)_dxx + h(x)_dxx
Hs = sparse(0,0);
Hs_gl = sparse(0,0);

for i = 0:ns-1
    %update Cb to reflect the bus connectivity caused by contingency
    Cb = Cb_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        f = branch(c, F_BUS);                           %% "from" bus
        t = branch(c, T_BUS);                           %% "to" bus
        Cb(f,t) = 0;
        Cb(t,f) = 0;
    end
    
    %update Cl to reflect the contingency
    Cl2 = Cl2_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        Cl2(c, :) = 0;
    end

    %--- hessian wrt. scenario local variables ---

    %          dVa  dVm(nPV)  dQg dPg(REF)
    % dVa     | Cb     Cb'     0     0  | 
    %         |                         |
    % dVm(nPV)| Cb'    Cb'     0     0  |
    %         |                         |
    % dQg     |  0      0      0     0  |
    %         |                         |
    % dPg(REF)|  0      0      0    Cg' | (only nominal case has Cg', because it is used in cost function)

    Hs_ll =[
        Cb                Cb(:, nPVbus_idx)          sparse(nb, ng+1);%assuming 1 REF gen
        Cb(nPVbus_idx,:)  Cb(nPVbus_idx, nPVbus_idx) sparse(length(nPVbus_idx), ng+1);
                   sparse(ng+1, nb+length(nPVbus_idx)+ng+1);
    ];
    %replicate hess. w.r.t local variables
    %Hs = kron(eye(ns), Hs_ll); 
    
    %set d2Pg(REF) to 1 in nominal case
    if (i==0)
        Hs_ll(nb+length(nPVbus_idx)+ng+1, nb+length(nPVbus_idx)+ng+1) = 1;
    end

    %--- hessian w.r.t local-global variables ---

    %          dVm(PV)  dPg(nREF)
    % dVa     | Cb'     0    | 
    %         |              |
    % dVm(nPV)| Cb'     0    |
    %         |              |
    % dQg     |  0      0    |
    %         |              |
    % dPg(REF)|  0      0    | 
    Hs_lg  = [
       Cb(:, PVbus_idx)           sparse(nb, ng-1);
       Cb(nPVbus_idx, PVbus_idx)  sparse(length(nPVbus_idx), ng-1);
       sparse(ng+length(REFgen_idx), length(PVbus_idx)+ng-1)
    ];
    %Hs_lg = kron(ones(ns,1), Hs_lg);
    
    Hs = [Hs;
          sparse(size(Hs_ll,1), i*size(Hs_ll,2)) Hs_ll sparse(size(Hs_ll,1), (ns-1-i)*size(Hs_ll,2)) Hs_lg];
    Hs_gl = [Hs_gl Hs_lg'];
    
end

% --- hessian w.r.t global variables ---

%        dVm(PV)  dPg(nREF)
% dVm(PV)  | Cb'  0   |
%          |          |
% dPg(nREF)| 0  f_xx' |
Hs_gg =[
    Cb_nominal(PVbus_idx, PVbus_idx)          sparse(length(PVbus_idx), ng-1);
    sparse(ng-1, length(PVbus_idx))               eye(ng-1);
];

% --- Put together local and global hessian ---
% local hessians sits at (1,1) block
% hessian w.r.t global variables is appended to lower right corner (2,2)
% and hessian w.r.t local/global variables to the (1,2) and (2,1) blocks
%        (l)      (g)
% (l) | Hs_ll    Hs_lg |
%     |                |
% (g) | Hs_gl    Hs_gg |
Hs = [Hs;
      Hs_gl   Hs_gg];
      

Hs = tril(Hs);

%% set options struct for IPOPT
options.ipopt = ipopt_options([], mpopt);

%% extra data to pass to functions
options.auxdata = struct( ...
    'om',       om, ...
    'cont',     cont, ...
    'index',    model.index, ...
    'mpopt',    mpopt, ...
    'il',       il, ...
    'A',        A, ...
    'Js',       Js, ...
    'Hs',       Hs    );

%% define variable and constraint bounds
options.lb = xmin;
options.ub = xmax;
options.cl = [repmat([zeros(2*nb, 1);  -Inf(2*nl2, 1)], [ns, 1]); l];
options.cu = [repmat([zeros(2*nb, 1); zeros(2*nl2, 1)], [ns, 1]); u+1e10]; %add 1e10 so that ipopt doesn't remove l==u case

%% assign function handles
funcs.objective         = @objective;
funcs.gradient          = @gradient;
funcs.constraints       = @constraints;
funcs.jacobian          = @jacobian;
funcs.hessian           = @hessian;
funcs.jacobianstructure = @(d) Js;
funcs.hessianstructure  = @(d) Hs;

%% run the optimization, call ipopt
if 1 %have_fcn('ipopt_auxdata')
    [x, info] = ipopt_auxdata(x0,funcs,options);
else
    [x, info] = ipopt(x0,funcs,options);
end

if info.status == 0 || info.status == 1
    success = 1;
else
    success = 0;
    display(['Ipopt finished with error: ', num2str(info.status)]);
end

if isfield(info, 'iter')
    output.iterations = info.iter;
else
    output.iterations = [];
end

f = opf_costfcn(x, om);
[h, g] = opf_consfcn(x, om);
    
%pack some additional info to output so that we can verify the solution
meta.Ybus = Ybus;
meta.Yf = Yf;
meta.Yt = Yt;
meta.lb = options.lb;
meta.ub = options.ub;
meta.A = A;
meta.lenX = length(x); %no. of variables
meta.lenXlocal = nb + length(nPVbus_idx) + ng + 1; %Va, Vm_nPV, Qg, Pg_REF
meta.lenXglobal = length(PVbus_idx) + ng - 1; %Vm_PV, Pg_nREF
meta.lenG = ns*2*nb;   %total no. of eq constraints
meta.lenH = ns*2*nl2;  %total no. of ineq constraints
meta.lenA = 0;         %total no. of lin constraints
meta.cont = model.cont;
meta.zl = info.zl;
meta.zu = info.zu;
meta.lambda = info.lambda;
meta.g = g;
meta.h = h;
    
raw = struct('xr', x, 'info', info.status, 'output', output, 'meta', meta);
results = struct('f', f, 'x', x, 'om', om);

%% -----  callback functions  -----
function f = objective(x, d)
f = opf_costfcn(x, d.om);

function df = gradient(x, d)
[~, df] = opf_costfcn(x, d.om);


function constr = constraints(x, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;
NG = 2*nb;
NH = 2*nl;

constr = zeros(ns*(NCONSTR), 1);
[h, g] = opf_consfcn(x, d.om);

%reorder constraints so that we have [g1; h1; g2; h2; ...]
for i = 0:ns-1
    constr_local = i*(NCONSTR) + (1:NCONSTR);
    g_local = i*(NG) + (1:NG);
    h_local = i*(NH) + (1:NH);
    
    constr(constr_local) = [g(g_local); h(h_local)];
end

if ~isempty(d.A)
    constr = [constr; d.A*x]; %append linear constraints
end


function J = jacobian(x, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;          %% number of constraints (eq + ineq)
NG = 2*nb;
NH = 2*nl;

J = sparse(ns*(NCONSTR), size(x,1));

% get indices of REF gen and PV bus
[REFgen_idx, nREFgen_idx] = d.index.getREFgens(mpc);
[PVbus_idx, nPVbus_idx] = d.index.getXbuses(mpc,2);%2==PV

[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = d.index.getLocalIndicesOPF(mpc);

%opf_consfcn calls our callbacks fcn_{miss,flow}(x, om)
%from scopf_setup.m that evaluates constraints and jacobians.
%Before passing x to fcn_{miss,flow}() it is permuted to OPF ordering
%and each set of constraints for given contingency is given different part 
%of x containing only local variables for the contingency and shared ones
[~, ~, dhn, dgn] = opf_consfcn(x, d.om);
dgn = dgn';
dhn = dhn';

% reorder eq/ineq jacobian properly [dg1; dh1; dg2; dh2; ...]
% make proper column offsets according to x
for i = 0:ns-1
    mis_local = (1:NG) + i*NG;
    branch_local = (1:NH) + i*NH;
    
    idx = d.index.getGlobalIndices(mpc, ns, i);
    
    %jacobian wrt local variables
    J(i*NCONSTR + (1:NCONSTR), idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = [dgn(mis_local,[VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);...
                                                                                                  dhn(branch_local,[VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)])];
    %jacobian wrt global variables
    J(i*NCONSTR + (1:NCONSTR), idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = [dgn(mis_local, [VMopf(PVbus_idx) PGopf(nREFgen_idx)]);...
                                                                                  dhn(branch_local, [VMopf(PVbus_idx) PGopf(nREFgen_idx)])];
end
J = [J; d.A]; %append Jacobian of linear constraints


function H = hessian(x, sigma, lambda, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;          %% number of constraints (eq + ineq)
NG = 2*nb;
NH = 2*nl;

%extract multipliers for eq and ineq constraints, we have [g1; h1; g2; h2; ...]
eq_idx = kron(ones(ns,1), ([1:NG]')) + kron([0:ns-1]', NCONSTR*ones(NG,1));
ineq_idx = kron(ones(ns,1), (NG + [1:NH]')) + kron([0:ns-1]', NCONSTR*ones(NH,1));

lam.eqnonlin = lambda(eq_idx);
lam.ineqnonlin = lambda(ineq_idx);

H = scopf_hessfcn(x, lam, sigma, d);

