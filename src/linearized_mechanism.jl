
module Linear

    using RigidBodyDynamics
    import RigidBodyDynamics: configuration, velocity
    using ForwardDiff
    using JuMP: AbstractJuMPScalar, getvalue, Variable, AffExpr
    using LCPSim: StateRecord

    export set_current_configuration!,
           set_current_velocity!,
           set_linearization_configuration!,
           set_linearization_velocity!,
           current_configuration,
           current_velocity,
           LinearizedState,
           linearization_state,
           linearized

    qv(state::Union{MechanismState, StateRecord}) = vcat(Vector(configuration(state)), Vector(velocity(state)))

    struct LinearizedState{T, M, SLinear <: MechanismState{<:Number}, SDual <: MechanismState{<:ForwardDiff.Dual}}
        current_state::StateRecord{T, M}
        linearization_state::SLinear
        dual_state::SDual

        function LinearizedState{T}(linear::S) where {T, M, S <: MechanismState{<:Number, M}}
            mechanism = linear.mechanism
            nq = num_positions(mechanism)
            nv = num_velocities(mechanism)
            na = num_additional_states(mechanism)
            N = nq + nv
            D = typeof(ForwardDiff.Dual(0.0, ForwardDiff.Partials(ntuple(i -> 0.0, N))))
            xdiff = Vector{D}(N)
            ForwardDiff.seed!(xdiff, qv(linear), ForwardDiff.construct_seeds(ForwardDiff.Partials{N, Float64}))
            diffstate = MechanismState(mechanism, xdiff[1:nq], xdiff[nq + (1:nv)], zeros(D, na))
            current = StateRecord(mechanism, Vector{T}(N))
            new{T, M, S, typeof(diffstate)}(StateRecord(mechanism, Vector{T}(N)),
                                         linear,
                                         diffstate)
        end

        function LinearizedState{T}(linear::MechanismState{<:AbstractJuMPScalar}) where T
            q = getvalue(configuration(linear))
            v = getvalue(velocity(linear))
            s = getvalue(additional_state(linear))
            if any(isnan, q) || any(isnan, v) || any(isnan, s)
                throw(ArgumentError("To construct a linearized state, the given state must have a defined value (which you can provide with JuMP.setvalue() or JuMP.fix()"))
            end
            LinearizedState{T}(MechanismState(linear.mechanism, q, v, s))
        end
    end


    function LinearizedState(linear::MechanismState, current_state::Union{<:StateRecord{T}, <:MechanismState{T}}) where T
        state = LinearizedState{T}(linear)
        set_current_configuration!(state, configuration(current_state))
        set_current_velocity!(state, velocity(current_state))
        state
    end

    set_current_configuration!(state::LinearizedState, q::AbstractVector) = set_configuration!(state.current_state, q)
    set_current_velocity!(state::LinearizedState, v::AbstractVector) = set_velocity!(state.current_state, v)
    function set_linearization_configuration!(state::LinearizedState, q::AbstractVector)
        set_configuration!(state.linearization_state, q)
        qdual = configuration(state.dual_state)
        qdual .= ForwardDiff.Dual.(q, ForwardDiff.partials.(qdual))
        setdirty!(state.dual_state)
    end
    function set_linearization_velocity!(state::LinearizedState, v::AbstractVector)
        set_velocity!(state.linearization_state, v)
        vdual = velocity(state.dual_state)
        vdual .= ForwardDiff.Dual.(v, ForwardDiff.partials.(vdual))
        setdirty!(state.dual_state)
    end

    unwrap(p::Point3D) = (v -> Point3D(p.frame, v), p.v)
    unwrap(p::FreeVector3D) = (v -> FreeVector3D(p.frame, v), p.v)
    unwrap(p::Transform3D) = (v -> Transform3D(p.from, p.to, v), p.mat)
    unwrap(p) = (identity, p)

    current_configuration(s::LinearizedState, joint::Joint) =
        @view configuration(current_state(s))[parentindexes(configuration(s.dual_state, joint))...]
    current_velocity(s::LinearizedState, joint::Joint) =
        @view velocity(current_state(s))[parentindexes(velocity(s.dual_state, joint))...]


    linearization_state(s::LinearizedState) = s.linearization_state
    linearization_state_vector(s::LinearizedState) = Vector(s.linearization_state)
    current_state(s::LinearizedState) = s.current_state

    function linearized(f::Function, s::LinearizedState)
        wrapper, ydual = unwrap(f(s.dual_state))
        nx = num_positions(current_state(s)) + num_velocities(current_state(s))
        v = ForwardDiff.value.(ydual)
        Δx = qv(current_state(s)) .- qv(linearization_state(s))

        if isa(v, AbstractArray)
            J = similar(v, (length(v), nx))
            ForwardDiff.extract_jacobian!(Void, J, ydual, nx)
            wrapper(v .+ reshape(J * Δx, size(v)))
        else
            wrapper(v + ForwardDiff.partials(ydual)' * Δx)
        end
    end

    function jacobian(f::Function, s::LinearizedState)
        wrapper, ydual = unwrap(f(s.dual_state))
        nx = num_positions(current_state(s)) + num_velocities(current_state(s))
        v = ForwardDiff.value.(ydual)
        J = similar(v, (length(v), nx))
        ForwardDiff.extract_jacobian!(Void, J, ydual, nx)
        J
    end

    function linearized(f::Function, s::LinearizedState{Variable}, min_coefficient=1e-15)
        wrapper, ydual = unwrap(f(s.dual_state))
        nx = num_positions(current_state(s)) + num_velocities(current_state(s))
        v = ForwardDiff.value.(ydual)
        x_current = qv(current_state(s))
        x_linear = qv(linearization_state(s))

        if isa(v, AbstractArray)
            J = similar(v, (length(v), nx))
            ForwardDiff.extract_jacobian!(Void, J, ydual, nx)
            result = AffExpr.(v)
            for i in 1:length(v)
                for j in 1:length(x_current)
                    if abs(J[i, j]) >= min_coefficient
                        push!(result[i], J[i, j], x_current[j])
                        result[i].constant -= J[i, j] * x_linear[j]
                    end
                end
            end
            wrapper(result)
        else
            result = AffExpr(v)
            partials = ForwardDiff.partials(ydual)
            for j in 1:length(x_current)
                if abs(partials[j]) >= min_coefficient
                    push!(result, partials[j], x_current[j])
                    result.constant -= partials[j] * x_linear[j]
                end
            end
            wrapper(result)
        end
    end

end
