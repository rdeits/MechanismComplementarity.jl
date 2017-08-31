# Comparison of two (equivalent) ways of constructing a mechanism with an 
# x, y, θ base: an explicit Planar joint vs. two Prismatic joints and one Rotational
# joint in series. 

using LCPSim
using Base.Test
using RigidBodyDynamics
using RigidBodyDynamics: Bounds
using StaticArrays: SVector
using Cbc: CbcSolver
using Rotations: RotY

const urdf = joinpath(@__DIR__, "..", "examples", "box.urdf")

function box_with_planar_base()
    mechanism = parse_urdf(Float64, urdf)
    core = findbody(mechanism, "core")
    floating_base = joint_to_parent(core, mechanism)
    set_joint_type!(floating_base, Planar([1., 0, 0], [0., 0, 1.]))
    floating_base.position_bounds = [Bounds(-5., 5), Bounds(0., 3), Bounds(-2π, 2π)]
    floating_base.velocity_bounds = [Bounds(-10., 10), Bounds(-10., 10), Bounds(-2π, 2π)]
    floating_base.effort_bounds .= Bounds(0., 0)

    x0 = MechanismState{Float64}(mechanism)
    set_velocity!(x0, zeros(num_velocities(x0)))
    set_configuration!(x0, floating_base, [-1, 0.3, -0.3])
    configuration_derivative_to_velocity!(velocity(x0, floating_base), floating_base, configuration(x0, floating_base), [3., 0, 0])
    mechanism, x0
end

function box_with_dummy_links()
    urdf_mech = parse_urdf(Float64, urdf)
    mechanism, base = planar_revolute_base()
    attach!(mechanism, base, urdf_mech)

    x0 = MechanismState{Float64}(mechanism)
    set_velocity!(x0, zeros(num_velocities(x0)))
    set_configuration!(x0, findjoint(mechanism, "base_x"), [-1])
    set_configuration!(x0, findjoint(mechanism, "base_z"), [0.3])
    set_configuration!(x0, findjoint(mechanism, "base_rotation"), [0.3])
    set_velocity!(x0, findjoint(mechanism, "base_x"), [3])
    mechanism, x0
end

function environment_with_floor(mechanism)
    world = root_body(mechanism)
    floor = planar_obstacle(default_frame(world), [0, 0, 1.], [0, 0, 0.], 0.5)
    free_space = space_between([floor])

    core = findbody(mechanism, "core")
    env = Environment(
        Dict(core => ContactEnvironment(
                    [
                    Point3D(default_frame(core), SVector(0.1, 0, 0.2)),
                    Point3D(default_frame(core), SVector(-0.1, 0, 0.2)),
                    Point3D(default_frame(core), SVector(0.1, 0, -0.2)),
                    Point3D(default_frame(core), SVector(-0.1, 0, -0.2)),
                     ],
                    [floor],
                    [free_space])))
    env
end

@testset "planar vs dummy link brick" begin
    mech1, x1 = box_with_planar_base()
    env1 = environment_with_floor(mech1)

    mech2, x2 = box_with_dummy_links()
    env2 = environment_with_floor(mech2)

    controller = x -> zeros(num_velocities(x))
    Δt = 0.05

    results1 = LCPSim.simulate(x1, controller, env1, Δt, 125, CbcSolver())
    results2 = LCPSim.simulate(x2, controller, env2, Δt, 125, CbcSolver())

    for i in 1:20
        set_configuration!(x1, configuration(results1[i].state))
        set_velocity!(x1, velocity(results1[i].state))
        set_configuration!(x2, configuration(results2[i].state))
        set_velocity!(x2, velocity(results2[i].state))
        T1 = transform_to_root(x1, findbody(mech1, "core"))
        T2 = transform_to_root(x2, findbody(mech2, "core"))
        @test isapprox(rotation(T1), rotation(T2), atol=1e-3)
        @test isapprox(translation(T1), translation(T2), atol=1e-3)
    end

    for i in 20:100
        set_configuration!(x1, configuration(results1[i].state))
        set_velocity!(x1, velocity(results1[i].state))
        set_configuration!(x2, configuration(results2[i].state))
        set_velocity!(x2, velocity(results2[i].state))
        T1 = transform_to_root(x1, findbody(mech1, "core"))
        T2 = transform_to_root(x2, findbody(mech2, "core"))
        @test isapprox(rotation(T1), rotation(T2), atol=1e-2)
        @test isapprox(translation(T1), translation(T2), atol=1e-2)
    end

    @test norm(velocity(results1[end].state)) <= 0.4
    @test norm(velocity(results2[end].state)) <= 0.4
end