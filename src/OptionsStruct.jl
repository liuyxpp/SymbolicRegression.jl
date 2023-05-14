module OptionsStructModule

using Optim: Optim
using StatsBase: StatsBase
import DynamicExpressions: AbstractOperatorEnum
import LossFunctions: SupervisedLoss

mutable struct MutationWeights
    mutate_constant::Float64
    mutate_operator::Float64
    add_node::Float64
    insert_node::Float64
    delete_node::Float64
    simplify::Float64
    randomize::Float64
    do_nothing::Float64
    optimize::Float64
end

const mutations = [fieldnames(MutationWeights)...]

"""
    MutationWeights(;kws...)

This defines how often different mutations occur. These weightings
will be normalized to sum to 1.0 after initialization.
# Arguments
- `mutate_constant::Float64`: How often to mutate a constant.
- `mutate_operator::Float64`: How often to mutate an operator.
- `add_node::Float64`: How often to append a node to the tree.
- `insert_node::Float64`: How often to insert a node into the tree.
- `delete_node::Float64`: How often to delete a node from the tree.
- `simplify::Float64`: How often to simplify the tree.
- `randomize::Float64`: How often to create a random tree.
- `do_nothing::Float64`: How often to do nothing.
- `optimize::Float64`: How often to optimize the constants in the tree, as a mutation.
  Note that this is different from `optimizer_probability`, which is
  performed at the end of an iteration for all individuals.
"""
@generated function MutationWeights(;
    mutate_constant=0.048,
    mutate_operator=0.47,
    add_node=0.79,
    insert_node=5.1,
    delete_node=1.7,
    simplify=0.0020,
    randomize=0.00023,
    do_nothing=0.21,
    optimize=0.0,
)
    return :(MutationWeights($(mutations...)))
end

"""Convert MutationWeights to a vector."""
@generated function Base.convert(
    ::Type{Vector}, weightings::MutationWeights
)::Vector{Float64}
    fields = [:(weightings.$(mut)) for mut in mutations]
    return :([$(fields...)])
end

"""Copy MutationWeights."""
@generated function Base.copy(weightings::MutationWeights)
    fields = [:(weightings.$(mut)) for mut in mutations]
    return :(MutationWeights($(fields...)))
end

"""Sample a mutation, given the weightings."""
function sample_mutation(weightings::MutationWeights)
    weights = convert(Vector, weightings)
    return StatsBase.sample(mutations, StatsBase.Weights(weights))
end

"""This struct defines how complexity is calculated."""
struct ComplexityMapping{T<:Real}
    use::Bool  # Whether we use custom complexity, or just use 1 for everythign.
    binop_complexities::Vector{T}  # Complexity of each binary operator.
    unaop_complexities::Vector{T}  # Complexity of each unary operator.
    variable_complexity::T  # Complexity of using a variable.
    constant_complexity::T  # Complexity of using a constant.
end

Base.eltype(::ComplexityMapping{T}) where {T} = T

function ComplexityMapping(use::Bool)
    return ComplexityMapping{Int}(use, zeros(Int, 0), zeros(Int, 0), 1, 1)
end

"""Promote type when defining complexity mapping."""
function ComplexityMapping(;
    binop_complexities::Vector{T1},
    unaop_complexities::Vector{T2},
    variable_complexity::T3,
    constant_complexity::T4,
) where {T1<:Real,T2<:Real,T3<:Real,T4<:Real}
    promoted_T = promote_type(T1, T2, T3, T4)
    return ComplexityMapping{promoted_T}(
        true,
        binop_complexities,
        unaop_complexities,
        variable_complexity,
        constant_complexity,
    )
end

struct Options{
    CT,OPT<:Optim.Options,EL<:Union{SupervisedLoss,Function},FL<:Union{Nothing,Function},W
}
    operators::AbstractOperatorEnum
    bin_constraints::Vector{Tuple{Int,Int}}
    una_constraints::Vector{Int}
    complexity_mapping::ComplexityMapping{CT}
    tournament_selection_n::Int
    tournament_selection_p::Float32
    tournament_selection_weights::W
    parsimony::Float32
    alpha::Float32
    maxsize::Int
    maxdepth::Int
    fast_cycle::Bool
    turbo::Bool
    migration::Bool
    hof_migration::Bool
    should_simplify::Bool
    should_optimize_constants::Bool
    output_file::String
    npopulations::Int
    perturbation_factor::Float32
    annealing::Bool
    batching::Bool
    batch_size::Int
    mutation_weights::MutationWeights
    crossover_probability::Float32
    warmup_maxsize_by::Float32
    use_frequency::Bool
    use_frequency_in_tournament::Bool
    adaptive_parsimony_scaling::Float64
    npop::Int
    ncycles_per_iteration::Int
    fraction_replaced::Float32
    fraction_replaced_hof::Float32
    topn::Int
    verbosity::Int
    save_to_file::Bool
    probability_negate_constant::Float32
    nuna::Int
    nbin::Int
    seed::Union{Int,Nothing}
    elementwise_loss::EL
    loss_function::FL
    progress::Bool
    terminal_width::Union{Int,Nothing}
    optimizer_algorithm::String
    optimizer_probability::Float32
    optimizer_nrestarts::Int
    optimizer_options::OPT
    recorder::Bool
    recorder_file::String
    prob_pick_first::Float32
    early_stop_condition::Union{Function,Nothing}
    return_state::Bool
    timeout_in_seconds::Union{Float64,Nothing}
    max_evals::Union{Int,Nothing}
    skip_mutation_failures::Bool
    nested_constraints::Union{Vector{Tuple{Int,Int,Vector{Tuple{Int,Int,Int}}}},Nothing}
    deterministic::Bool
    define_helper_functions::Bool
end

# - The Algorithm:
#   - Creating the Search Space:
#     - binary_operators
#     - unary_operators
#     - maxsize
#     - maxdepth
#   - Setting the Search Size:
#     - niterations
#     - populations
#     - population_size
#     - ncyclesperiteration
#   - The Objective:
#     - loss
#     - full_objective
#     - model_selection
#   - Working with Complexities:
#     - parsimony
#     - constraints
#     - nested_constraints
#     - complexity_of_operators
#     - complexity_of_constants
#     - complexity_of_variables
#     - warmup_maxsize_by
#     - use_frequency
#     - use_frequency_in_tournament
#     - adaptive_parsimony_scaling
#     - should_simplify
#   - Mutations:
#     - weight_add_node
#     - weight_insert_node
#     - weight_delete_node
#     - weight_do_nothing
#     - weight_mutate_constant
#     - weight_mutate_operator
#     - weight_randomize
#     - weight_simplify
#     - weight_optimize
#     - crossover_probability
#     - annealing
#     - alpha
#     - perturbation_factor
#     - skip_mutation_failures
#   - Tournament Selection:
#     - tournament_selection_n
#     - tournament_selection_p
#   - Constant Optimization:
#     - optimizer_algorithm
#     - optimizer_nrestarts
#     - optimize_probability
#     - optimizer_iterations
#     - should_optimize_constants
#   - Migration between Populations:
#     - fraction_replaced
#     - fraction_replaced_hof
#     - migration
#     - hof_migration
#     - topn
# - Data Preprocessing:
#   - denoise
#   - select_k_features
# - Stopping Criteria:
#   - max_evals
#   - timeout_in_seconds
#   - early_stop_condition
# - Performance and Parallelization:
#   - procs
#   - multithreading
#   - cluster_manager
#   - batching
#   - batch_size
#   - precision
#   - fast_cycle
#   - turbo
#   - enable_autodiff
#   - random_state
#   - deterministic
#   - warm_start
# - Monitoring:
#   - verbosity
#   - update_verbosity
#   - progress
# - Environment:
#   - temp_equation_file
#   - tempdir
#   - delete_tempfiles
#   - julia_project
#   - update
#   - julia_kwargs
# - Exporting the Results:
#   - equation_file
#   - output_jax_format
#   - output_torch_format
#   - extra_sympy_mappings
#   - extra_torch_mappings
#   - extra_jax_mappings
function __print(io::IO, opt::String)
    print(io, opt, ":")
end
function __print(io::IO, opt::Symbol, options::Options)
    s = let option_mapping = Dict([
            :unary_operators => "Unary operators",
            :binary_operators => "Binary operators",
            :maxsize => "Max size",
            :maxdepth => "Max depth",
            :niterations => "Search iterations",
            :ncycles_per_iteration => "Cycles per iteration",
            :npopulations => "Populations",
            :npop => "Size of each population",
            :elementwise_loss => "Elementwise loss",
            :loss_function => "Full loss function (if any)",
        ])
        option_mapping[opt]
    end

    l = if opt in (:unary_operators, :binary_operators)
        field = opt == :unary_operators ? :unaops : :binops
        out = join((s, ": [", join(getfield(options.operators, field), ", "), "]"), "")
        print(io, out)
        length(out)
    else
        out = join((s, ": ", getfield(options, opt)), "")
        print(io, out)
        length(out)
    end
    printstyled(" "^max(50 - l, 0), "# ", opt, color=:light_black)
end
function _print(io::IO, ind::Int, order::Symbol, args...)
    if ind > 0
        while ind > 4
            print(io, "│" * " "^3)
            ind -= 4
        end
        print(io, order == :mid ? "├" : "└", "─"^2 * " ")
    end
    __print(io, args...)
    println(io)
end

function Base.show(io::IO, ::MIME"text/plain", options::Options)
    let ind = 0
        _print(io, ind, :first, "Options")
        let ind = ind + 4
            _print(io, ind, :mid, "Search Space")
            let ind = ind + 4
                for opt in (:unary_operators, :binary_operators, :maxsize)
                    _print(io, ind, :mid, opt, options)
                end
                _print(io, ind, :last, :maxdepth, options)
            end
            _print(io, ind, :mid, "Search Size")
            let ind = ind + 4
                for opt in (:ncycles_per_iteration, :npopulations)
                    _print(io, ind, :mid, opt, options)
                end
                _print(io, ind, :last, :npop, options)
            end
            _print(io, ind, :mid, "The Objective")
            let ind = ind + 4
                for opt in (:elementwise_loss,)
                    _print(io, ind, :mid, opt, options)
                end
                _print(io, ind, :last, :loss_function, options)
            end
        end
    end
    return nothing
end

end
