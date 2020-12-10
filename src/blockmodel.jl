
import MathOptInterface: MOI
abstract type AbstractBlockModel end

"""
    init!(block::AbstractBlockModel, algparams::AlgParams, indexes)

Feed the optimization model by creating variables and constraints
inside the model.

"""
function init! end

"""
    optimize!(block::AbstractBlockModel, x0)

Solve the optimization problem, starting from an initial
variable `x0`.

"""
function optimize! end

# Objective
"""
    set_objective!(
        block::AbstractBlockModel,
        algparams::AlgParams,
        primal::PrimalSolution,
        dual::DualSolution
    )

Update the objective inside `block`'s optimization problem.
The new objective update the coefficients of the penalty
terms, to reflect the new `primal` and `dual` solutions
passed in the arguments.

"""
function set_objective! end

# Variables
"""
    add_variables!(block::AbstractBlockModel, algparams::AlgParams)

Add all optimization variables into the decomposed optimization
model `block`.

"""
function add_variables! end

# Constraints
function add_ctgs_linking_constraints! end

### Implementation of JuMPBlockModel
struct JuMPBlockModel <: AbstractBlockModel
    id::Int
    k::Int
    t::Int
    model::JuMP.Model
    data::OPFData
    params::ModelParams
end

function JuMPBlockModel(blk, opfdata, modelinfo, t, k)
    model = JuMP.Model()
    # k = indexes[block.id][1]
    # t = indexes[block.id][2]
    return JuMPBlockModel(blk, k, t, model, opfdata, modelinfo)
end

function init!(block::JuMPBlockModel, algparams::AlgParams)
    opfmodel = block.model
    # Reset optimizer
    Base.empty!(opfmodel)

    # Pass optimizer to model
    JuMP.set_optimizer(opfmodel, algparams.optimizer)
    JuMP.set_optimizer_attribute(opfmodel, "max_iter", algparams.nlpiterlim)

    # Get params
    opfdata = block.data
    modelinfo = block.params
    Kblock = modelinfo.num_ctgs + 1

    # Sanity check
    @assert modelinfo.num_time_periods == 1
    @assert !algparams.decompCtgs || Kblock == 1

    add_variables!(block, algparams)
    if !algparams.decompCtgs
        add_ctgs_linking_constraints!(block, algparams)
    end

    t, k = block.t, block.k

    (t == 1) &&
        fix.(opfmodel[:St][:,1], 0; force = true)
    (k == 1 && algparams.decompCtgs) &&
        fix.(opfmodel[:Sk][:,1,:], 0; force = true)

    # Fix penalty vars to 0
    fix.(opfmodel[:Zt], 0; force = true)
    if algparams.decompCtgs
        fix.(opfmodel[:Zk], 0; force = true)
        if modelinfo.ctgs_link_constr_type == :frequency_ctrl
            fix.(opfmodel[:ωt], 0; force = true)
        end
    end

    # Add block constraints
    if modelinfo.allow_constr_infeas
        σ_re = opfmodel[:sigma_real][:,j,1]
        σ_im = opfmodel[:sigma_imag][:,j,1]
        σ_fr = opfmodel[:sigma_lineFr][:,j,1]
        σ_to = opfmodel[:sigma_lineTo][:,j,1]
    else
        zb = zeros(length(opfdata.buses))
        zl = zeros(length(opfdata.lines))
        σ_re = zb
        σ_im = zb
        σ_fr = zl
        σ_to = zl
    end

    @views for j=1:Kblock
        opfdata_c = (j == 1) ? opfdata :
            opf_loaddata(rawdata; lineOff = opfdata.lines[rawdata.ctgs_arr[j - 1]], time_horizon_start = t, time_horizon_end = t, load_scale = modelinfo.load_scale, ramp_scale = modelinfo.ramp_scale)
        opf_model_add_real_power_balance_constraints(opfmodel, opfdata_c, opfmodel[:Pg][:,j,1], opfdata_c.Pd[:,1], opfmodel[:Vm][:,j,1], opfmodel[:Va][:,j,1], σ_re)
        opf_model_add_imag_power_balance_constraints(opfmodel, opfdata_c, opfmodel[:Qg][:,j,1], opfdata_c.Qd[:,1], opfmodel[:Vm][:,j,1], opfmodel[:Va][:,j,1], σ_im)
        opf_model_add_line_power_constraints(opfmodel, opfdata_c, opfmodel[:Vm][:,j,1], opfmodel[:Va][:,j,1], σ_fr, σ_to)
    end
    return opfmodel
end

function set_objective!(block::JuMPBlockModel, algparams::AlgParams,
                        primal::PrimalSolution, dual::DualSolution)
    blk = block.id
    opfmodel = block.model
    opfdata = block.data
    modelinfo = block.params
    k, t = block.k, block.t

    obj_expr = compute_objective_function(opfmodel, opfdata, modelinfo)
    auglag_penalty = opf_block_get_auglag_penalty_expr(
        blk, opfmodel, modelinfo, opfdata, k, t, algparams, primal, dual)
    @objective(opfmodel, Min, obj_expr + auglag_penalty)
    return
end

function get_solution(block::JuMPBlockModel)
    return value.(all_variables(block.model))
end

function optimize!(block::JuMPBlockModel, x0)
    blk = block.id
    opfmodel = block.model
    set_start_value.(all_variables(opfmodel), x0)
    JuMP.optimize!(opfmodel)

    status = termination_status(opfmodel)
    if status ∉ MOI_OPTIMAL_STATUSES
        @warn("Block $blk subproblem not solved to optimality. status: $status")
    end
    if !has_values(opfmodel)
        error("no solution vector available in block $blk subproblem")
    end

    return get_solution(block)
end

function add_variables!(block::JuMPBlockModel, algparams::AlgParams)
    opf_model_add_variables(
        block.model, block.data, block.params, algparams,
    )
end

function add_ctgs_linking_constraints!(block::JuMPBlockModel, algparams)
    opf_model_add_ctgs_linking_constraints(
        block.model, block.data, block.params,
    )
end

### Implementation of ExaBlockModel
struct ExaBlockModel <: AbstractBlockModel
    id::Int
    k::Int
    t::Int
    model::ExaPF.AbstractNLPEvaluator
    data::OPFData
    params::ModelParams
end

function ExaBlockModel(blk, raw_data, opfdata, modelinfo, t, k)

    horizon = size(opfdata.Pd, 2)
    data = Dict{String, Array}()
    data["bus"] = raw_data.bus_arr
    data["branch"] = raw_data.branch_arr
    data["gen"] = raw_data.gen_arr
    data["cost"] = raw_data.costgen_arr
    data["baseMVA"] = [raw_data.baseMVA]

    power_network = PS.PowerNetwork(data)

    if t == 1
        time = ExaPF.Origin
    elseif t == horizon
        time = ExaPF.Final
    else
        time = ExaPF.Normal
    end

    # Instantiate model in memory
    model = ExaPF.ProxALEvaluator(power_network, time)
    return ExaBlockModel(blk, k, t, model, opfdata, modelinfo)
end

function init!(block::ExaBlockModel, algparams::AlgParams)
    opfmodel = block.model
    # Reset optimizer
    # TODO
    ExaPF.reset!(opfmodel)

    # Get params
    opfdata = block.data
    modelinfo = block.params
    Kblock = modelinfo.num_ctgs + 1
    t, k = block.t, block.k

    # Sanity check
    @assert modelinfo.num_time_periods == 1
    @assert !algparams.decompCtgs || Kblock == 1

    # TODO: currently, only one contingency is supported
    j = 1
    pd = opfdata.Pd[:,1]
    qd = opfdata.Qd[:,1]
    ExaPF.setvalues!(opfmodel, PS.ActiveLoad(), pd)
    ExaPF.setvalues!(opfmodel, PS.ReactiveLoad(), qd)

    return opfmodel
end

function add_ctgs_linking_constraints!(block::ExaBlockModel)
    error("Contingencies are not supported in ExaPF")
end

function set_objective!(block::ExaBlockModel, algparams::AlgParams,
                        primal::PrimalSolution, dual::DualSolution)
    examodel = block.model
    opfdata = block.data
    modelinfo = block.params
    # Generators
    gens = block.data.generators

    t, k = block.t, block.k
    ramp_agc = [g.ramp_agc for g in gens]

    λf = dual.ramping[:, t]
    λt = dual.ramping[:, t+1]
    pgf = primal.Pg[:, 1, t-1] .+ primal.Zt[:, t] .- ramp_agc
    pgc = primal.Pg[:, k, t]
    pgt = primal.Pg[:, 1, t+1] .- primal.St[:, t+1] .+ ramp_agc

    ExaPF.update_multipliers!(examodel, λf, λt)
    ExaPF.update_primal!(examodel, pgf, pgc, pgt)
    return
end

function optimize!(block::ExaBlockModel, x0, optimizer)
    blk = block.id
    opfmodel = block.model

    # Convert ExaPF to MOI model
    block_data = MOI.NLPBlockData(opfmodel)
    x♭, x♯ = ExaPF.bounds(opfmodel, ExaPF.Variables())
    x0 = ExaPF.initial(opfmodel)
    n = ExaPF.n_variables(opfmodel)
    vars = MOI.add_variables(optimizer, n)
    # Set bounds and initial values
    for i in 1:n
        MOI.add_constraint(
            optimizer,
            MOI.SingleVariable(vars[i]),
            MOI.LessThan(x♯[i])
        )
        MOI.add_constraint(
            optimizer,
            MOI.SingleVariable(vars[i]),
            MOI.GreaterThan(x♭[i])
        )
        MOI.set(optimizer, MOI.VariablePrimalStart(), vars[i], x0[i])
    end
    MOI.set(optimizer, MOI.NLPBlock(), block_data)
    MOI.set(optimizer, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.optimize!(optimizer)
    status = MOI.get(optimizer, MOI.TerminationStatus())
    x_opt = [MOI.get(optimizer, MOI.VariablePrimal(), v) for v in vars]
    solution = (
        status=status,
        minimum=MOI.get(optimizer, MOI.ObjectiveValue()),
        minimizer=x_opt
    )
    MOI.empty!(optimizer)
    if status ∉ MOI_OPTIMAL_STATUSES
        @warn("Block $blk subproblem not solved to optimality. status: $status")
    end
    return solution
end