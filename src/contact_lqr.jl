module ContactLQR

using RigidBodyDynamics
using ForwardDiff

"""
`care(A, B, Q, R)`

Compute 'X', the solution to the continuous-time algebraic Riccati equation,
defined as A'X + XA - (XB)R^-1(B'X) + Q = 0, where R is non-singular.

Algorithm taken from:
Laub, "A Schur Method for Solving Algebraic Riccati Equations."
http://dspace.mit.edu/bitstream/handle/1721.1/1301/R-0859-05666488.pdf

Implementation from https://github.com/JuliaControl/ControlSystems.jl/blob/master/src/matrix_comps.jl
by Jim Crist and other contributors. 
"""
function care(A, B, Q, R)
    G = try
        B*inv(R)*B'
    catch
        error("R must be non-singular.")
    end

    Z = [A  -G;
        -Q  -A']

    S = schurfact(Z)
    S = ordschur(S, real(S.values).<0)
    U = S.Z

    (m, n) = size(U)
    U11 = U[1:div(m, 2), 1:div(n,2)]
    U21 = U[div(m,2)+1:m, 1:div(n,2)]
    return U21/U11
end

"""
`lqr(A, B, Q, R)`

Calculate the optimal gain matrix `K` for the state-feedback law `u = K*x` that
minimizes the cost function:

J = integral(x'Qx + u'Ru, 0, inf).

For the continuous time model `dx = Ax + Bu`.

`lqr(sys, Q, R)`

Solve the LQR problem for state-space system `sys`. Works for both discrete
and continuous time systems.

See also `LQG`

Usage example:
```julia
A = [0 1; 0 0]
B = [0;1]
C = [1 0]
sys = ss(A,B,C,0)
Q = eye(2)
R = eye(1)
L = lqr(sys,Q,R)

u(t,x) = -L*x # Form control law,
t=0:0.1:5
x0 = [1,0]
y, t, x, uout = lsim(sys,u,t,x0)
plot(t,x, lab=["Position", "Velocity"]', xlabel="Time [s]")
```

Implementation from https://github.com/JuliaControl/ControlSystems.jl/blob/master/src/synthesis.jl
by Jim Crist and other contributors.
"""
function lqr(A, B, Q, R)
    S = care(A, B, Q, R)
    K = R\B'*S
    return K
end

function contact_jacobian(state, contacts)
    q = configuration(state)
    contact_jacobians = Matrix{eltype(q)}[]
    for contact in contacts
        J = ForwardDiff.jacobian(q) do q
            x = MechanismState(state.mechanism, q, zeros(eltype(q), num_velocities(state)))
            T = transform_to_root(x, contact.frame)
            (T * contact).v
        end
        push!(contact_jacobians, J)
    end
    Jc = vcat(contact_jacobians...)
    Jc = Jc[[i for i in 1:size(Jc, 1) if !all(Jc[i, :] .== 0)], :]
    Jc
end

function dynamics_with_contact_constraint(state::MechanismState, input::AbstractVector, Jc::AbstractMatrix)
    v = velocity(state)
    M = full(mass_matrix(state))
    C_plus_g = dynamics_bias(state)
    St = eye(num_velocities(state))
    for joint in joints(state.mechanism)
        bounds = effort_bounds(joint)
        for (i, b) in enumerate(bounds)
            if b.upper == b.lower == 0
                j = parentindexes(velocity(state, joint))[i]
                St[j, j] = 0
            end
        end
    end
    Jct = Jc'
    Jcbar = inv(M) * Jct * inv(Jc * inv(M) * Jct)
    Φ = (I - Jcbar * Jc) * inv(M)
    ϕ = -Φ * (C_plus_g)

    v̇ = Φ * St * input + ϕ
    vcat(v, v̇)
end

"""
From "Full Dynamics LQR Control of a Humanoid Robot: An Experimental Study on
Balancing and Squatting" by Sean Mason et al.
"""
function contact_linearize(state0, input0, Jc)
    if norm(velocity(state0)) > 0
        error("Only static postures supported")
    end
    mechanism = state0.mechanism
    
    function dynamics(x, u)
        q = x[1:num_positions(state0)]
        v = x[num_positions(state0) + 1 : end]
        state = MechanismState(mechanism, q, v)
        dynamics_with_contact_constraint(state, u, Jc)
    end
    
    A = ForwardDiff.jacobian(state_vector(state0)) do x
        dynamics(x, input0)
    end
    B = ForwardDiff.jacobian(input0) do u
        dynamics(state_vector(state0), u)
    end
    A, B, dynamics(state_vector(state0), input0)
end

"""
From "Balancing and Walking Using Full Dynamics LQR Control With Contact
Constraints" by Sean Mason et al.
"""
function contact_lqr(state::MechanismState, input::AbstractVector, Q::AbstractMatrix, R::AbstractMatrix, contacts::AbstractVector{<:Point3D})
    Jc = contact_jacobian(state, contacts)
    A, B, c = contact_linearize(state, input, Jc)
    N = nullspace([Jc zeros(Jc); zeros(Jc) Jc])
    Am = N' * A * N
    Bm = N' * B
    Rm = R
    Qm = N' * Q * N
    Km = lqr(Am, Bm, Qm, Rm)
    K = Km * N'
    return K
end


end
