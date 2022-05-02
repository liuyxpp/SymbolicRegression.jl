module HallOfFameModule

import ..CoreModule: CONST_TYPE, MAX_DEGREE, Node, Options, Dataset, stringTree
import ..EquationUtilsModule: countNodes
import ..PopMemberModule: PopMember, copyPopMember
import ..LossFunctionsModule: EvalLoss
using Printf: @sprintf

""" List of the best members seen all time in `.members` """
mutable struct HallOfFame
    members::Array{PopMember, 1}
    exists::Array{Bool, 1} #Whether it has been set

    # Arranged by complexity - store one at each.
end

"""
    HallOfFame(options::Options)

Create empty HallOfFame. The HallOfFame stores a list
of `PopMember` objects in `.members`, which is enumerated
by size (i.e., `.members[1]` is the constant solution).
`.exists` is used to determine whether the particular member
has been instantiated or not.
"""
function HallOfFame(options::Options)
    actualMaxsize = options.maxsize + MAX_DEGREE
    HallOfFame([PopMember(Node(convert(CONST_TYPE, 1)), 1f9, 1f9) for i=1:actualMaxsize], [false for i=1:actualMaxsize])
end


"""
    calculateParetoFrontier(dataset::Dataset{T}, hallOfFame::HallOfFame,
                            options::Options) where {T<:Real}
"""
function calculateParetoFrontier(dataset::Dataset{T},
                                 hallOfFame::HallOfFame,
                                 options::Options)::Array{PopMember, 1} where {T<:Real}
    # Dominating pareto curve - must be better than all simpler equations
    dominating = PopMember[]
    actualMaxsize = options.maxsize + MAX_DEGREE
    for size=1:actualMaxsize
        if !hallOfFame.exists[size]
            continue
        end
        member = hallOfFame.members[size]
        # We check if this member is better than all members which are smaller than it and
        # also exist.
        betterThanAllSmaller = true
        for i=1:(size-1)
            if !hallOfFame.exists[i]
                continue
            end
            simpler_member = hallOfFame.members[i]
            if member.loss >= simpler_member.loss
                betterThanAllSmaller = false
                break
            end
        end
        if betterThanAllSmaller
            push!(dominating, copyPopMember(member))
        end
    end
    return dominating
end

"""
    calculateParetoFrontier(X::AbstractMatrix{T}, y::AbstractVector{T},
                            hallOfFame::HallOfFame, options::Options;
                            weights=nothing, varMap=nothing) where {T<:Real}

Compute the dominating Pareto frontier for a given hallOfFame. This
is the list of equations where each equation has a better loss than all
simpler equations.
"""
function calculateParetoFrontier(X::AbstractMatrix{T},
                                 y::AbstractVector{T},
                                 hallOfFame::HallOfFame,
                                 options::Options;
                                 weights=nothing,
                                 varMap=nothing) where {T<:Real}
    calculateParetoFrontier(Dataset(X, y, weights=weights, varMap=varMap), hallOfFame, options)
end

function string_dominating_pareto_curve(hallOfFame, baselineMSE,
                                        dataset, options,
                                        avgy)
    output = ""
    curMSE = Float64(baselineMSE)
    lastMSE = curMSE
    lastComplexity = 0
    output *= "Hall of Fame:\n"
    output *= "-----------------------------------------\n"
    output *= @sprintf("%-10s  %-8s   %-8s  %-8s\n", "Complexity", "Loss", "Score", "Equation")

    dominating = calculateParetoFrontier(dataset, hallOfFame, options)
    for member in dominating
        complexity = countNodes(member.tree)
        if member.loss < 0.0
            throw(DomainError(member.loss, "Your loss function must be non-negative. To do this, consider wrapping your loss inside an exponential, which will not affect the search (unless you are using annealing)."))
        end
        # User higher precision when finding the original loss:
        relu(x) = x < 0 ? 0 : x
        curMSE = member.loss
        
        delta_c = complexity - lastComplexity
        ZERO_POINT = 1e-10
        delta_l_mse = log(abs(curMSE/lastMSE) + ZERO_POINT)
        score = convert(Float32, -delta_l_mse/delta_c)
        output *= @sprintf("%-10d  %-8.3e  %-8.3e  %-s\n" , complexity, curMSE, score, stringTree(member.tree, options, varMap=dataset.varMap))
        lastMSE = curMSE
        lastComplexity = complexity
    end
    output *= "\n"
    return output
end

end
