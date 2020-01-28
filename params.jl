
mutable struct ALADINParams
    PG::Vector{Dict{Int, Float64}} #[p][g] := Pg of gen g in partition p
    QG::Vector{Dict{Int, Float64}} #[p][g] := Qg of gen g in partition p
    VM::Vector{Dict{Int, Float64}} #[p][b] := Vm of bus b in partition p
    VA::Vector{Dict{Int, Float64}} #[p][b] := Va of bus b in partition p
    λVM::Dict{Tuple{Int, Int}, Float64} #[(i, p)] := λ for the consensus constraint VM[i,partition[i]] = VM[i,p], p ≢ partition[i]
    λVA::Dict{Tuple{Int, Int}, Float64} #[(i, p)] := λ for the consensus constraint VA[i,partition[i]] = VA[i,p], p ≢ partition[i]
    tol::Float64
    zero::Float64 # tolerance below which is regarded as zero
    ρ::Float64
    μ::Float64
end


function initializePararms(opfdata::OPFData, network::OPFNetwork)
    np = network.num_partitions
    PG = Vector{Dict{Int, Float64}}(undef, np)
    QG = Vector{Dict{Int, Float64}}(undef, np)
    VM = Vector{Dict{Int, Float64}}(undef, np)
    VA = Vector{Dict{Int, Float64}}(undef, np)
    for p in 1:np
        PG[p] = Dict{Int, Float64}()
        QG[p] = Dict{Int, Float64}()
        VM[p] = Dict{Int, Float64}()
        VA[p] = Dict{Int, Float64}()
        for g in network.gener_part[p]
            PG[p][g] = 0.5*(opfdata.generators[g].Pmax+opfdata.generators[g].Pmin)
            QG[p][g] = 0.5*(opfdata.generators[g].Qmax+opfdata.generators[g].Qmin)
        end
        for b in network.buses_bloc[p]
            VM[p][b] = 0.5*(opfdata.buses[b].Vmax+opfdata.buses[b].Vmin)
            VA[p][b] = opfdata.buses[opfdata.bus_ref].Va
        end
    end

    λVM = Dict{Tuple{Int, Int}, Float64}()
    λVA = Dict{Tuple{Int, Int}, Float64}()
    for n in network.consensus_nodes
        partition = get_prop(network.graph, n, :partition)
        blocks = get_prop(network.graph, n, :blocks)
        for p in blocks
            (p == partition) && continue
            λVM[(n, p)] = 0.0
            λVA[(n, p)] = 0.0
        end
    end

    tol = 1e-3
    zero = 1e-4
    ρ = 100000.0
    μ = 100000.0
    return ALADINParams(PG, QG, VM, VA, λVM, λVA, tol, zero, ρ, μ)
end

