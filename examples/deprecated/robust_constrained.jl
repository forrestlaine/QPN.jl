struct PolyObject{D, T}
    # Assumed clockwise ordering
    verts::Vector{SVector{D, T}}
end

struct HalfSpace{D, T}
    a::SVector{D, T} # normal
    b::T             # offset
end

function halfspaces(poly_obj::PolyObject{D, T}) where {D, T}
    N = length(poly_obj.verts)
    map(1:N) do i
        ii = mod1(i+1, N)
        d = poly_obj.verts[ii] - poly_obj.verts[i]
        a = SVector(d[2], -d[1])
        b = a'*poly_obj.verts[i]
        HalfSpace(a, b)
    end
end

function dyn(x, u; Δ = 0.1)
    x + Δ * [x[3:4]+0.5*Δ*u[1:2]; 
             u[1:2]]
end

function unpack(x; num_obj=2, T=5, num_obj_faces=4)
    id = 0
    X = []
    U = []
    O = []
    X0 = x[id+1:id+4]
    id += 4
    for t = 1:T
        xt = x[id+1:id+4]
        push!(X, xt)
        id += 4
    end
    for t = 1:T
        ut = x[id+1:id+2]
        push!(U, ut)
        id += 2
    end
    id += T*num_obj*num_obj_faces
    id += T*num_obj # skip s variables
    for i = 1:num_obj
        oi = x[id+1:id+2]
        push!(O, oi)
        id += 2
    end
    (; X, U, O, X0)
end


#function visualize(qpn, x; num_obj_faces=4, lane_width = 10.0)
#
#    N = length(x)
#    num_obj = 0
#    T = 0
#    for k = 1:5
#        try 
#            T = Int((N-7-k*2) / ((num_obj_faces+1)*k+6))
#            num_obj = k
#            break
#        catch e
#            continue
#        end
#    end
#    if T == 0
#        throw(error("Can't identify values of T and num_obj"))
#    end
#
#    f = Figure()
#    f = Figure(resolution=(1440,1440))
#    ax = f[1, 1] = Axis(f, aspect = DataAspect())
#    xlims!(ax, -4.0, 12.0)
#    ylims!(ax, -8.0, 8.0)
#
#    lines!(ax, [-4.0, 12], [-lane_width/2, -lane_width/2], color=:black)
#    lines!(ax, [-4.0, 12], [lane_width/2, lane_width/2], color=:black)
#
#
#
#    vals = unpack(x; num_obj, T, num_obj_faces)
#
#    p = Circle(Point(vals.X0[1:2]...), 0.1f0)
#    scatter!(ax, p, color=:green)
#
#    for i = 1:num_obj
#        verts = map(1:num_obj_faces) do j
#            θ = j*2π / num_obj_faces    
#            SVector(vals.O[i][1]+cos(θ), vals.O[i][2]+sin(θ))
#        end
#        push!(verts, verts[1])
#        lines!(ax, verts, color=:red)
#    end
#
#    for t = 1:T
#        xt = vals.X[t]
#        p = Circle(Point(xt[1:2]...), 0.1f0)
#        scatter!(ax, p, color=:blue)
#    end
#    display(f) 
#end

function setup(::Val{:robust_constrained}; T=5,
                 num_obj=1,
                 num_obj_faces=4,
                 obstacle_spacing = 1.0,
                 lane_heading = 0.0,
                 initial_speed=3.0,
                 lane_width = 10.0,
                 initial_box_length = 6.0,
                 lane_dist_incentive = 10.0,
                 max_accel = 10.0,
                 kwargs...)

    lane_vec = [cos(lane_heading), sin(lane_heading)]
    
    x = QPN.variables(:x, 1:4, 1:T)
    u = QPN.variables(:u, 1:2, 1:T)
    x̄ = QPN.variables(:x̄, 1:4)
    s = QPN.variables(:s, 1:num_obj, 1:T)
    o = QPN.variables(:o, 1:2, 1:num_obj)
    h = QPN.variables(:h, 1:num_obj_faces, 1:num_obj, 1:T)
    c = QPN.variable(:c)
    v = QPN.variable(:v)
    w = QPN.variable(:w)
    
    qp_net = QPNet(x̄,x,u,h,s,o,c,v,w)
 
    objs = map(1:num_obj) do i
        verts = map(1:num_obj_faces) do j
            θ = j*2π / num_obj_faces    
            SVector(o[1, i]+cos(θ), o[2, i]+sin(θ))
        end
        PolyObject(verts)
    end
    obstacle_distances_along = collect(1:num_obj) * obstacle_spacing .+ initial_box_length / 2
    obstacle_offsets = [(-1)^i for i in 1:num_obj] .* lane_width/5.0
    
    obj_halfspaces = [halfspaces(obj) for obj in objs]
    right_laneline_normal = SVector(-sin(lane_heading), cos(lane_heading))
    lane_halfspaces = [HalfSpace(right_laneline_normal, -lane_width/2), 
                       HalfSpace(-right_laneline_normal, -lane_width/2)]
   
    #####################################################################
    
    # Add players responsible for identifying least-violated obstacle halfspace
    # constraint (min s s.t. s ≥ (aᵢ'x - bᵢ)) 
    # [recall obstacle avoidance ⇿ ∃ i s.t. aᵢ'x > bᵢ, i.e. only one halfspace
    # constraint needs to be satisfied to "avoid" the obstacle]
    
    s_players = Dict()

    for t = 1:T
        for i = 1:num_obj
            cost = s[i, t] # min s[t,i]
            cons = mapreduce(vcat, 1:num_obj_faces) do j
                hs = obj_halfspaces[i][j]
                [h[j, i, t] - (hs.a'*x[1:2,t] - hs.b),
                 s[i, t] - h[j, i, t]]
            end
            lb = fill(0.0, 2*num_obj_faces)
            ub = mapreduce(vcat, 1:num_obj_faces) do j
                [0.0, Inf]
            end
            con_id = QPN.add_constraint!(qp_net, cons, lb, ub)
            
            vars = [s[i, t]; [h[j, i, t] for j in 1:num_obj_faces]]
            player_id = QPN.add_qp!(qp_net, cost, [con_id,], vars...)
            s_players[t,i] = player_id
        end
    end
    
    #####################################################################
   
    # Add player responsible for finding most-violated constraint
    # (max c s.t. c <= all other constraints)
    min_cons = []
    for t = 1:T
        #for lane_hs in lane_halfspaces
        #    push!(min_cons, (lane_hs.a'*x[1:2,t] - lane_hs.b) - c)
        #end
        for i in 1:num_obj
            push!(min_cons, s[i,t] - c)
        end
    end
    lb = fill(0.0, length(min_cons))
    ub = fill(Inf, length(min_cons))
    con_id = QPN.add_constraint!(qp_net, min_cons, lb, ub)
    cost = -c
    c_player = QPN.add_qp!(qp_net, cost, [con_id,], c)

    #####################################################################

    # Add player responsible for choosing initial state and obstacle centers
    # to draw trajectory to boundary of infeasibility
   
    # Setup Dynamic Equation constraints
    dynamic_cons = []
    for t = 1:T
        if t==1
            append!(dynamic_cons, x[:, t] - dyn(x̄, u[:, t]))
        else
            append!(dynamic_cons, x[:, t] - dyn(x[:, t-1], u[:, t]))
        end
    end
    lb = fill(0.0, length(dynamic_cons))
    ub = fill(0.0, length(dynamic_cons))
    dyn_con_id = QPN.add_constraint!(qp_net, dynamic_cons, lb, ub)

    # Setup Initial State constraints
    initial_state_cons = []
    R = [lane_vec right_laneline_normal]
    append!(initial_state_cons, R\x̄[1:2])
    append!(initial_state_cons, x̄[3:4])
    #lb = [-initial_box_length/2, -lane_width/2, initial_speed, 0.0]
    #ub = [initial_box_length/2, lane_width/2, initial_speed, 0.0]
    lb = [0, 0.0, initial_speed, 0.0]
    ub = [0, 0.0, initial_speed, 0.0]
    init_con_id = QPN.add_constraint!(qp_net, initial_state_cons, lb, ub)

    # Setup Obstacle Constraints
    obstacle_cons = []
    lb = []
    ub = []
    for i in 1:num_obj
        append!(obstacle_cons, R\o[:,i])
        append!(lb, [obstacle_distances_along[i], obstacle_offsets[i]-lane_width/5])
        append!(ub, [obstacle_distances_along[i], obstacle_offsets[i]+lane_width/5])
        #append!(ub, [obstacle_distances_along[i], 0.0])
    end
    obstacle_con_id = QPN.add_constraint!(qp_net, obstacle_cons, lb, ub)

    v_con_id = QPN.add_constraint!(qp_net, [v-c,], [0.0,], [Inf,])

    cost = 0.5*(v)^2
    v_player = QPN.add_qp!(qp_net, cost, [dyn_con_id, init_con_id, obstacle_con_id, v_con_id], x̄, x, o, v)
    #####################################################################

    # Add player responsible for modifying obstacles, initial state,
    # so as to create worst-case cost (no private vars introduced)
    

    #w_con_id = QPN.add_constraint!(qp_net, [0.5+c-w,], [0.0,], [Inf,])
    #
    #primary_cost = 0.5*w^2
    #w_player = QPN.add_qp!(qp_net, primary_cost, [w_con_id,], w, u)

    #####################################################################

    # Add player responsible for modifying obstacles, initial state,
    # so as to create worst-case cost (no private vars introduced)
    
    #primary_cost = sum(lane_dist_incentive * x[1:2, t]'*lane_vec for t = 1:T)
    #level = 2
    #player_id = QPN.add_qp!(qp_net, level, primary_cost, Int[])
    
    #####################################################################

    # Add player responsible for choosing control variables
    # to avoid worst-case obstacles, initial condition

    cons = []
    #for t = 1:T
    #    for i = 1:num_obj
    #        append!(cons, s[i,t])
    #    end
    #end
    for t = 1:T
        append!(cons, u[:, t])
    end
    lb = fill(-max_accel, 2*T)
    ub = fill(max_accel, 2*T)
    #lb = [zeros(num_obj*T); fill(-max_accel, 2*T)]
    #ub = [fill(Inf, num_obj*T); fill(max_accel, 2*T)]
    con_id = QPN.add_constraint!(qp_net, cons, lb, ub)

    #primary_cost = sum(-lane_dist_incentive * x[1:2, t]'*lane_vec + 0.001*u[2,t]^2 for t = 1:T)
    primary_cost = sum((u[1,t]-15)^2+u[2,t]^2 for t = 1:T)
    u_player = QPN.add_qp!(qp_net, primary_cost, [con_id,], u)


    #################3
    
    # Add edges
    #

    QPN.assign_constraint_groups!(qp_net)
    QPN.set_options!(qp_net; kwargs...)
    
    qp_net
end

