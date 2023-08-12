using SymbolicRegression: SymbolicRegression
import SymbolicRegression:
    Node,
    Dataset,
    SRRegressor,
    MultitargetSRRegressor,
    node_to_symbolic,
    symbolic_to_node,
    eval_tree_array,
    eval_grad_tree_array
import MLJTestInterface as MTI
import MLJBase: machine, fit!, report, predict
using Test
using SymbolicUtils: SymbolicUtils
using Zygote
import Suppressor: @capture_err

macro quiet(ex)
    return quote
        redirect_stderr(devnull) do
            $ex
        end
    end |> esc
end

stop_kws = (; early_stop_condition=(loss, complexity) -> loss < 1e-7)

@testset "Generic interface tests" begin
    failures, summary = MTI.test(
        [SRRegressor], MTI.make_regression()...; mod=@__MODULE__, verbosity=0, throw=true
    )
    @test isempty(failures)

    X = randn(100, 3)
    Y = @. cos(X^2) * 3.2 - 0.5
    (X, Y) = MTI.table.((X, Y))
    w = ones(100)
    failures, summary = MTI.test(
        [MultitargetSRRegressor], X, Y, w; mod=@__MODULE__, verbosity=0, throw=true
    )
    @test isempty(failures)
end

@testset "Variable names" begin
    @testset "Single outputs" begin
        X = (a=rand(32), b=rand(32))
        y = X.a .^ 2.1
        # We also make sure the deprecated npop and npopulations still work:
        model = SRRegressor(; niterations=10, npop=33, npopulations=15, stop_kws...)
        mach = machine(model, X, y)
        fit!(mach)
        rep = report(mach)
        @test occursin("a", rep.equation_strings[rep.best_idx])
        @test sum(abs2, predict(mach, X) .- y) / length(y) < 1e-5

        @testset "Smoke test SymbolicUtils" begin
            eqn = node_to_symbolic(rep.equations[rep.best_idx], model)
            n = symbolic_to_node(eqn, model)
            eqn2 = convert(SymbolicUtils.Symbolic, n, model)
            n2 = convert(Node, eqn2, model)
        end
    end

    @testset "Multiple outputs" begin
        X = (a=rand(32), b=rand(32))
        y = X.a .^ 2.1
        model = MultitargetSRRegressor(; niterations=10, stop_kws...)
        mach = machine(model, X, reduce(hcat, [reshape(y, :, 1) for i in 1:3]))
        fit!(mach)
        rep = report(mach)
        @test all(
            eq -> occursin("a", eq), [rep.equation_strings[i][rep.best_idx[i]] for i in 1:3]
        )
    end

    @testset "Named outputs" begin
        X = (b1=randn(32), b2=randn(32))
        Y = (c1=X.b1 .* X.b2, c2=X.b1 .+ X.b2)
        w = ones(32)
        model = MultitargetSRRegressor(; niterations=10, stop_kws...)
        mach = machine(model, X, Y, w)
        fit!(mach)
        test_outs = predict(mach, X)
        @test isempty(setdiff((:c1, :c2), keys(test_outs)))
        @test_throws AssertionError predict(mach, (a1=randn(32), b2=randn(32)))
        VERSION >= v"1.8" && @test_throws "Variable names do not match fitted" predict(
            mach, (b1=randn(32), a2=randn(32))
        )
    end
end

@testset "Good predictions" begin
    X = randn(100, 3)
    Y = X
    model = MultitargetSRRegressor(; niterations=10, stop_kws...)
    mach = machine(model, X, Y)
    fit!(mach)
    @test sum(abs2, predict(mach, X) .- Y) / length(X) < 1e-6
end

@testset "Helpful errors" begin
    model = MultitargetSRRegressor()
    mach = machine(model, randn(32, 3), randn(32); scitype_check_level=0)
    @test_throws AssertionError @quiet(fit!(mach))
    VERSION >= v"1.8" &&
        @test_throws "For single-output regression, please" @quiet(fit!(mach))

    model = SRRegressor()
    mach = machine(model, randn(32, 3), randn(32, 2); scitype_check_level=0)
    @test_throws AssertionError @quiet(fit!(mach))
    VERSION >= v"1.8" &&
        @test_throws "For multi-output regression, please" @quiet(fit!(mach))

    model = SRRegressor(; verbosity=0)
    mach = machine(model, randn(32, 3), randn(32))
    @test_throws ErrorException @quiet(fit!(mach; verbosity=0))
end

@testset "Unfinished search" begin
    model = SRRegressor(; timeout_in_seconds=1e-10)
    mach = machine(model, randn(32, 3), randn(32))
    fit!(mach)
    # Ensure that the hall of fame is empty:
    _, hof = mach.fitresult.state
    hof.exists .= false
    # Recompute the report:
    mach.report[:fit] = SymbolicRegression.MLJInterfaceModule.full_report(
        model, mach.fitresult
    )
    @test report(mach).best_idx == 0
    @test predict(mach, randn(32, 3)) == zeros(32)
    msg = @capture_err begin
        predict(mach, randn(32, 3))
    end
    @test occursin("Evaluation failed either due to", msg)

    model = MultitargetSRRegressor(; timeout_in_seconds=1e-10)
    mach = machine(model, randn(32, 3), randn(32, 3))
    fit!(mach)
    # Ensure that the hall of fame is empty:
    _, hofs = mach.fitresult.state
    foreach(hofs) do hof
        hof.exists .= false
    end
    mach.report[:fit] = SymbolicRegression.MLJInterfaceModule.full_report(
        model, mach.fitresult
    )
    @test report(mach).best_idx == [0, 0, 0]
    @test predict(mach, randn(32, 3)) == zeros(32, 3)
    msg = @capture_err begin
        predict(mach, randn(32, 3))
    end
    @test occursin("Evaluation failed either due to", msg)
end

const WasEvaluated = Ref(false)
const WasEvaluatedLock = Threads.SpinLock()

# This tests both `.extra` and `idx`
function derivative_loss(tree, dataset::Dataset{T,L}, options, idx) where {T,L}
    # Select from the batch indices, if given
    X = idx === nothing ? dataset.X : view(dataset.X, :, idx)

    ŷ, ∂ŷ, completed = eval_grad_tree_array(tree, X, options; variable=true)

    !completed && return L(Inf)

    y = idx === nothing ? dataset.y : view(dataset.y, idx)
    ∂y = idx === nothing ? dataset.extra.∂y : view(dataset.extra.∂y, idx)

    mse_deriv = sum(i -> (∂ŷ[i] - ∂y[i])^2, eachindex(∂y)) / length(∂y)
    mse_value = sum(i -> (ŷ[i] - y[i])^2, eachindex(y)) / length(y)

    WasEvaluated[] || lock(WasEvaluatedLock) do
        WasEvaluated[] = true
    end

    return mse_value + mse_deriv
end

true_f(x) = x^3 / 3 - cos(x)
deriv_f(x) = x^2 + sin(x)

@testset "Test `extra` parameter" begin
    X = reshape(0.0:0.32:10.0, :, 1)
    y = true_f.(X[:, 1])
    ∂y = deriv_f.(X[:, 1])

    model = SRRegressor(;
        binary_operators=[+, -, *],
        unary_operators=[cos],
        loss_function=derivative_loss,
        enable_autodiff=true,
        batching=true,
        batch_size=25,
        niterations=100,
        early_stop_condition=1e-6,
    )
    mach = machine(model, X, y, (; ∂y=∂y))
    VERSION >= v"1.8" && @test_warn "experimental" fit!(mach)

    @test WasEvaluated[]
    @test predict(mach, X) ≈ y

    @testset "Test errors associated with `extra`" begin
        # No loss function:
        model = SRRegressor(; loss_function=nothing)
        mach = machine(model, X, y, (; ∂y=∂y))
        @test_throws ErrorException @quiet(fit!(mach; verbosity=0))
        VERSION >= v"1.8" && @test_throws "You have passed" @quiet(fit!(mach))

        # Bad setting for `extra`
        model = SRRegressor(; loss_function=derivative_loss)
        mach = machine(model, X, y, "extra")
        @test_throws ErrorException @quiet(fit!(mach; verbosity=0))
        VERSION >= v"1.8" && @test_throws "Unexpected input" @quiet(fit!(mach))
    end
end