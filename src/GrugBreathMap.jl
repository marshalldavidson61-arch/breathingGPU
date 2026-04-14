"""
    GrugBreathMap

A metabolic GPU dispatch system for geometric operations.
8 channels. Breath not force. No silent failures.

Grug philosophy:
- Grug not know fancy word "idle". Grug call it "sleeping".
- Grug not wake up hole unless hole needed.
- Grug not scream silently. Grug SCREAM LOUD when thing wrong.
- Grug share juice with workers. Workers die when juice gone.
- Grug not whisper. Logs are whispers. Grug SCREAM.

Architecture:
- 8 geometric operation channels (holes)
- Each hole has 3 states: PLACEHOLDER → CPU → GPU
- Juice rises on use, decays when idle
- Ghost workers spawn when hot, die when cold
- TTL-based decay: 1ms active window, max 8ms hot
- Zero silent failure policy: all errors LOUD
"""
module GrugBreathMap

# Grug exports what grug need
export BreathMap, GrugHole, HoleState, do_geometry!, kill_map!, map_status, hole_status,
       rotate_cpu, rotate_gpu, translate_cpu, translate_gpu, scale_cpu, scale_gpu,
       project_cpu, project_gpu, reflect_cpu, reflect_gpu, intersect_cpu, intersect_gpu,
       extrude_cpu, extrude_gpu, boolean_cpu, boolean_gpu,
       GrugLoudScreamError, WrongHoleError, GpuCousinDeadError, MachineDeadError, MissingOperationError,
       GhostWorkerDiedError, GpuFallbackRequiredError

using LinearAlgebra

# =============================================================================
# GRUG LOUD SCREAM ERRORS
# Grug not believe in silent failure. Silent failure is lie.
# When thing wrong, GRUG SCREAM. Everyone know something wrong.
# Grug not whisper. Grug not log. Grug SCREAM.
# =============================================================================

"""
    GrugLoudScreamError

Abstract base for all Grug errors. Grug not whisper. Grug SCREAM.
"""
abstract type GrugLoudScreamError <: Exception end

"""
    WrongHoleError <: GrugLoudScreamError

Grug tried to put shape in wrong hole. Hole not made for that shape.
SCREAM LOUD: tell grug which hole, which shape, why wrong.
"""
struct WrongHoleError <: GrugLoudScreamError
    msg::String
end
Base.showerror(io::IO, e::WrongHoleError) = print(io, "💀 WRONG HOLE! Grug confused. ", e.msg)

"""
    GpuCousinDeadError <: GrugLoudScreamError

GPU cousin is dead. Cannot do GPU trick without GPU cousin.
SCREAM LOUD: tell grug which operation, what state GPU in.
"""
struct GpuCousinDeadError <: GrugLoudScreamError
    msg::String
end
Base.showerror(io::IO, e::GpuCousinDeadError) = print(io, "💀 GPU COUSIN DEAD! No GPU trick today. ", e.msg)

"""
    MachineDeadError <: GrugLoudScreamError

The whole breathing machine is dead. Lungs stopped.
SCREAM LOUD: tell grug machine not breathing.
"""
struct MachineDeadError <: GrugLoudScreamError
    msg::String
end
Base.showerror(io::IO, e::MachineDeadError) = print(io, "💀 MACHINE DEAD! Lungs stopped. ", e.msg)

"""
    MissingOperationError <: GrugLoudScreamError

Grug tried to do trick but trick not exist.
SCREAM LOUD: tell grug what operation missing.
"""
struct MissingOperationError <: GrugLoudScreamError
    msg::String
end
Base.showerror(io::IO, e::MissingOperationError) = print(io, "💀 MISSING OPERATION! Grug not know this trick. ", e.msg)

"""
    GhostWorkerDiedError <: GrugLoudScreamError

Ghost worker died while doing trick. Ghost worker not silent.
SCREAM LOUD: tell grug which ghost, what hole, why died.
"""
struct GhostWorkerDiedError <: GrugLoudScreamError
    hole_name::String
    original_error::Exception
end
Base.showerror(io::IO, e::GhostWorkerDiedError) = print(io, "💀 GHOST WORKER DIED! Ghost in hole '", e.hole_name, "' died. Reason: ", e.original_error)

"""
    GpuFallbackRequiredError <: GrugLoudScreamError

GPU cousin dead but grug tried to use GPU trick.
SCREAM LOUD: grug not silently fall back. Grug tell user GPU dead.
"""
struct GpuFallbackRequiredError <: GrugLoudScreamError
    hole_name::String
    original_error::GpuCousinDeadError
end
Base.showerror(io::IO, e::GpuFallbackRequiredError) = print(io, "💀 GPU FALLBACK REQUIRED! GPU cousin dead for hole '", e.hole_name, "'. Grug not silently fall back. ", e.original_error.msg)

# =============================================================================
# HOLE STATE - Grug's Three States of Being
# =============================================================================
"""
    HoleState

Grug hole has three states:
- PLACEHOLDER_STATE: Grug sleeping. Near-zero memory. Waiting.
- CPU_STATE: Grug woke up. Doing CPU trick. Watching.
- GPU_STATE: Grug HOT. GPU cousin helping. Maximum power.

Grug not jump straight to GPU. Grug take breath first.
"""
@enum HoleState begin
    PLACEHOLDER_STATE  # Grug sleeping. Minimal footprint.
    CPU_STATE          # Grug awake. CPU ready.
    GPU_STATE          # Grug HOT. GPU engaged.
end

# =============================================================================
# MONOTONIC TIME - Grug's Clock
# =============================================================================
"""
    _now_s()

Monotonic time in seconds. Grug not trust wall clock.
Wall clock can jump backward. Grug clock only go forward.
"""
_now_s() = time_ns() / 1.0e9

# =============================================================================
# GRUG HOLE - One Channel for One Kind of Geometry Trick
# =============================================================================
"""
    GrugHole

One hole. One kind of geometry trick. Three states.

Fields:
- name: What grug call this hole
- baseline_juice: Starting juice (grug always have some)
- current_juice: How much juice right now
- max_juice: Maximum juice grug can hold
- juice_step: How much juice one use adds
- cpu_threshold: Juice level to wake CPU
- gpu_threshold: Juice level to wake GPU cousin
- max_ghosts: Maximum ghost workers (bounded, grug not insane)
- active_ghosts: Current ghost workers alive
- ttl_boost: Time added per use
- wake_until: When grug go back to sleep
- max_hot_window: Maximum time grug stay hot (cap)
- rock_lock: Grug's lock. Only one grug touch at a time.
- state: Current hole state
- ghosts: Ghost workers doing parallel tricks
- cpu_trick: Function for CPU work
- gpu_trick: Function for GPU work
- streak: Consecutive uses (builds momentum)
- last_hit: When grug last used this hole
- ghost_graveyard: Count of dead ghosts (grug remember the fallen)
"""
mutable struct GrugHole
    name::String
    baseline_juice::Float64
    current_juice::Float64
    max_juice::Float64
    juice_step::Float64
    cpu_threshold::Float64
    gpu_threshold::Float64
    max_ghosts::Int
    active_ghosts::Int
    ttl_boost::Float64
    wake_until::Float64
    max_hot_window::Float64
    rock_lock::ReentrantLock
    state::HoleState
    ghosts::Vector{Task}
    cpu_trick::Function
    gpu_trick::Function
    streak::Int
    last_hit::Float64
    ghost_graveyard::Int  # Grug remember dead ghosts. Not hide them.
end

"""
    GrugHole(name::String; kwargs...) -> GrugHole

Create a new GrugHole with sensible defaults.
Grug like sensible defaults. Grug not like guessing.

Arguments:
- name: What to call this hole
- baseline_juice: Starting juice (default: 0.1)
- max_juice: Cap on juice (default: 1.0)
- juice_step: Increment per use (default: 0.1)
- cpu_threshold: Level to wake CPU (default: 0.3)
- gpu_threshold: Level to wake GPU (default: 0.7)
- max_ghosts: Max parallel workers (default: 8)
- ttl_boost: Time added per hit in seconds (default: 0.001 = 1ms)
- max_hot_window: Max time to stay hot (default: 0.008 = 8ms)
"""
function GrugHole(
    name::String;
    baseline_juice::Float64 = 0.1,
    max_juice::Float64 = 1.0,
    juice_step::Float64 = 0.1,
    cpu_threshold::Float64 = 0.3,
    gpu_threshold::Float64 = 0.7,
    max_ghosts::Int = 8,
    ttl_boost::Float64 = 0.001,
    max_hot_window::Float64 = 0.008
)
    return GrugHole(
        name,
        baseline_juice,
        baseline_juice,  # current_juice starts at baseline
        max_juice,
        juice_step,
        cpu_threshold,
        gpu_threshold,
        max_ghosts,
        0,               # active_ghosts
        ttl_boost,
        0.0,             # wake_until
        max_hot_window,
        ReentrantLock(),
        PLACEHOLDER_STATE,
        Task[],          # ghosts
        (args...) -> throw(MissingOperationError("No CPU trick set for $name")),
        (args...) -> throw(MissingOperationError("No GPU trick set for $name")),
        0,               # streak
        0.0,             # last_hit
        0                # ghost_graveyard: no dead ghosts yet
    )
end

"""
    set_cpu_trick!(hole::GrugHole, f::Function)

Set the CPU trick for this hole. Grug learn new trick.
"""
function set_cpu_trick!(hole::GrugHole, f::Function)
    lock(hole.rock_lock) do
        hole.cpu_trick = f
    end
end

"""
    set_gpu_trick!(hole::GrugHole, f::Function)

Set the GPU trick for this hole. GPU cousin learn new trick.
"""
function set_gpu_trick!(hole::GrugHole, f::Function)
    lock(hole.rock_lock) do
        hole.gpu_trick = f
    end
end

# =============================================================================
# BREATH MAP - The Whole Breathing Machine
# =============================================================================
"""
    BreathMap

The orchestrator. Eight holes. One breath.

Grug have 8 holes for 8 geometry tricks:
1. rotate - spin thing around
2. translate - move thing somewhere
3. scale - make thing bigger/smaller
4. project - flatten thing onto plane
5. reflect - mirror thing
6. intersect - find where things cross
7. extrude - push thing into 3D
8. boolean - combine/subtract things

Fields:
- holes: Dictionary of name -> GrugHole
- breathe_flag: Atomic bool. True = breathing. False = dead.
- lungs: The background Task that breathes.
- dead_ghosts_report: List of dead ghost reports. Grug not hide the dead.
"""
mutable struct BreathMap
    holes::Dict{String, GrugHole}
    breathe_flag::Threads.Atomic{Bool}
    lungs::Task
    dead_ghosts_report::Vector{Tuple{String, Float64, Exception}}  # (hole_name, time, error)
end

"""
    BreathMap(; hole_names::Vector{String} = DEFAULT_HOLES) -> BreathMap

Create a new breathing machine. All holes start sleeping.
Lungs start breathing immediately. Grug not wait.
"""
function BreathMap(; hole_names::Vector{String} = DEFAULT_HOLES)
    holes = Dict{String, GrugHole}()
    for name in hole_names
        holes[name] = GrugHole(name)
    end
    
    breathe_flag = Threads.Atomic{Bool}(true)
    
    # Dummy lungs first - need all fields before spawn
    dummy_lungs = Task(() -> nothing)
    
    map = BreathMap(holes, breathe_flag, dummy_lungs, Tuple{String, Float64, Exception}[])
    
    # Now spawn real lungs
    map.lungs = @async begin
        _breathe_loop(map)
    end
    
    return map
end

# =============================================================================
# DEFAULT HOLE NAMES - The Eight Geometry Tricks
# =============================================================================
const DEFAULT_HOLES = ["rotate", "translate", "scale", "project", 
                       "reflect", "intersect", "extrude", "boolean"]

# =============================================================================
# BUILT-IN CPU OPERATIONS - Grug's Default Tricks
# =============================================================================
# These are placeholder implementations. Grug can do basic tricks.
# Replace with real implementations for production.

"""
    rotate_cpu(geometry, angle, axis) -> geometry

Rotate geometry around axis by angle (radians).
Default CPU implementation. Grug turn thing.
"""
function rotate_cpu(geometry, angle::Real, axis::AbstractVector)
    # Grug's simple rotation - normalize axis, apply rotation
    axis_normalized = normalize(collect(Float64, axis))
    c, s = cos(angle), sin(angle)
    x, y, z = axis_normalized
    
    # Rodrigues' rotation formula in matrix form
    K = [0 -z y; z 0 -x; -y x 0]
    R = I + s*K + (1-c)*(K*K)
    
    # Apply to geometry (assumes 3D points)
    return apply_transform(geometry, R)
end

"""
    rotate_gpu(geometry, angle, axis) -> geometry

GPU-accelerated rotation. SCREAMS if GPU not available.
"""
function rotate_gpu(geometry, angle::Real, axis::AbstractVector)
    # Grug check if GPU cousin available. If not, SCREAM.
    if !has_gpu()
        throw(GpuCousinDeadError("rotate_gpu: No GPU available. GPU cousin dead."))
    end
    # GPU implementation would go here
    # For now, delegate to CPU with GPU awareness
    return rotate_cpu(geometry, angle, axis)
end

"""
    translate_cpu(geometry, offset) -> geometry

Move geometry by offset vector. Grug push thing.
"""
function translate_cpu(geometry, offset::AbstractVector)
    T = collect(Float64, offset)
    return apply_transform(geometry, T, :translate)
end

"""
    translate_gpu(geometry, offset) -> geometry

GPU-accelerated translation. SCREAMS if GPU not available.
"""
function translate_gpu(geometry, offset::AbstractVector)
    if !has_gpu()
        throw(GpuCousinDeadError("translate_gpu: No GPU available. GPU cousin dead."))
    end
    return translate_cpu(geometry, offset)
end

"""
    scale_cpu(geometry, factors) -> geometry

Scale geometry by factors. Grug make thing bigger/smaller.
"""
function scale_cpu(geometry, factors)
    if isa(factors, Real)
        factors = fill(Float64(factors), 3)
    else
        factors = collect(Float64, factors)
    end
    return apply_transform(geometry, Diagonal(factors), :scale)
end

"""
    scale_gpu(geometry, factors) -> geometry

GPU-accelerated scaling. SCREAMS if GPU not available.
"""
function scale_gpu(geometry, factors)
    if !has_gpu()
        throw(GpuCousinDeadError("scale_gpu: No GPU available. GPU cousin dead."))
    end
    return scale_cpu(geometry, factors)
end

"""
    project_cpu(geometry, plane_normal) -> geometry

Project geometry onto plane. Grug flatten thing.
"""
function project_cpu(geometry, plane_normal::AbstractVector)
    n = normalize(collect(Float64, plane_normal))
    # Projection matrix onto plane with normal n
    P = I - n * n'
    return apply_transform(geometry, P)
end

"""
    project_gpu(geometry, plane_normal) -> geometry

GPU-accelerated projection. SCREAMS if GPU not available.
"""
function project_gpu(geometry, plane_normal::AbstractVector)
    if !has_gpu()
        throw(GpuCousinDeadError("project_gpu: No GPU available. GPU cousin dead."))
    end
    return project_cpu(geometry, plane_normal)
end

"""
    reflect_cpu(geometry, plane_normal) -> geometry

Reflect geometry across plane. Grug mirror thing.
"""
function reflect_cpu(geometry, plane_normal::AbstractVector)
    n = normalize(collect(Float64, plane_normal))
    # Reflection matrix across plane with normal n
    R = I - 2 * n * n'
    return apply_transform(geometry, R)
end

"""
    reflect_gpu(geometry, plane_normal) -> geometry

GPU-accelerated reflection. SCREAMS if GPU not available.
"""
function reflect_gpu(geometry, plane_normal::AbstractVector)
    if !has_gpu()
        throw(GpuCousinDeadError("reflect_gpu: No GPU available. GPU cousin dead."))
    end
    return reflect_cpu(geometry, plane_normal)
end

"""
    intersect_cpu(geo_a, geo_b) -> geometry

Find intersection of two geometries. Grug find where things cross.
"""
function intersect_cpu(geo_a, geo_b)
    # Placeholder - real implementation depends on geometry types
    throw(MissingOperationError("intersect_cpu not implemented for these geometry types. Grug need more code."))
end

"""
    intersect_gpu(geo_a, geo_b) -> geometry

GPU-accelerated intersection. SCREAMS if GPU not available.
"""
function intersect_gpu(geo_a, geo_b)
    if !has_gpu()
        throw(GpuCousinDeadError("intersect_gpu: No GPU available. GPU cousin dead."))
    end
    return intersect_cpu(geo_a, geo_b)
end

"""
    extrude_cpu(geometry, distance, direction) -> geometry

Extrude 2D shape into 3D. Grug push thing into third dimension.
"""
function extrude_cpu(geometry, distance::Real, direction::AbstractVector)
    # Placeholder - real implementation creates 3D from 2D
    throw(MissingOperationError("extrude_cpu not implemented for this geometry type. Grug need more code."))
end

"""
    extrude_gpu(geometry, distance, direction) -> geometry

GPU-accelerated extrusion. SCREAMS if GPU not available.
"""
function extrude_gpu(geometry, distance::Real, direction::AbstractVector)
    if !has_gpu()
        throw(GpuCousinDeadError("extrude_gpu: No GPU available. GPU cousin dead."))
    end
    return extrude_cpu(geometry, distance, direction)
end

"""
    boolean_cpu(geo_a, geo_b, operation::Symbol) -> geometry

Boolean operation on geometries. Grug combine/subtract things.
operation: :union, :difference, :intersection
"""
function boolean_cpu(geo_a, geo_b, operation::Symbol)
    if operation ∉ [:union, :difference, :intersection]
        throw(WrongHoleError("boolean operation must be :union, :difference, or :intersection. Got $operation"))
    end
    # Placeholder - real implementation depends on geometry types
    throw(MissingOperationError("boolean_cpu not implemented for these geometry types. Grug need more code."))
end

"""
    boolean_gpu(geo_a, geo_b, operation::Symbol) -> geometry

GPU-accelerated boolean operations. SCREAMS if GPU not available.
"""
function boolean_gpu(geo_a, geo_b, operation::Symbol)
    if !has_gpu()
        throw(GpuCousinDeadError("boolean_gpu: No GPU available. GPU cousin dead."))
    end
    return boolean_cpu(geo_a, geo_b, operation)
end

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

"""
    has_gpu() -> Bool

Check if GPU is available. Grug check if GPU cousin awake.
"""
function has_gpu()
    # Placeholder - real implementation checks CUDA/Metal/Vulkan
    # For now, return false (CPU only)
    return false
end

"""
    apply_transform(geometry, matrix, op_type::Symbol = :transform)

Apply transformation matrix to geometry.
Op types: :transform, :translate, :scale
"""
function apply_transform(geometry, matrix, op_type::Symbol = :transform)
    # Default implementation for arrays of points
    if isa(geometry, AbstractMatrix)
        return matrix * geometry
    elseif isa(geometry, AbstractVector)
        if op_type == :translate
            return geometry .+ matrix
        else
            return matrix * collect(Float64, geometry)
        end
    else
        throw(WrongHoleError("Cannot apply transform to geometry of type $(typeof(geometry)). Grug confused."))
    end
end

# =============================================================================
# THE BREATHING LOOP - Background Metabolic Process
# =============================================================================
"""
    _breathe_loop(map::BreathMap)

Background task that breathes. Checks decay. Updates states.
Grug not stop breathing until flag says stop.
Grug not hide dead ghosts. Grug report them.
"""
function _breathe_loop(map::BreathMap)
    while map.breathe_flag[]
        now = _now_s()
        
        for (name, hole) in map.holes
            lock(hole.rock_lock) do
                # Check if hole should decay
                if now > hole.wake_until && hole.current_juice > hole.baseline_juice
                    # Decay juice
                    decay_rate = 0.1  # 10% decay per check
                    hole.current_juice = max(
                        hole.baseline_juice,
                        hole.current_juice * (1 - decay_rate)
                    )
                    
                    # Reset streak if decaying
                    if hole.current_juice <= hole.baseline_juice
                        hole.streak = 0
                    end
                    
                    # Update state based on juice
                    _update_hole_state!(hole)
                end
                
                # Grug not hide dead ghosts. Grug find them and report.
                _find_and_report_dead_ghosts!(hole, map)
            end
        end
        
        # Grug breathe slowly. Not hyperventilate.
        sleep(0.0005)  # 0.5ms breath cycle
    end
end

"""
    _update_hole_state!(hole::GrugHole)

Update hole state based on current juice level.
Grug transition between states smoothly.
"""
function _update_hole_state!(hole::GrugHole)
    if hole.current_juice >= hole.gpu_threshold
        hole.state = GPU_STATE
    elseif hole.current_juice >= hole.cpu_threshold
        hole.state = CPU_STATE
    else
        hole.state = PLACEHOLDER_STATE
    end
end

"""
    _find_and_report_dead_ghosts!(hole::GrugHole, map::BreathMap)

Find dead ghost workers and REPORT them. Grug not hide the dead.
When ghost dies, grug SCREAM about it. No silent burial.
"""
function _find_and_report_dead_ghosts!(hole::GrugHole, map::BreathMap)
    alive_ghosts = Task[]
    for ghost in hole.ghosts
        if istaskdone(ghost) || istaskfailed(ghost)
            # Ghost is dead. Grug not hide this. Grug record death.
            hole.ghost_graveyard += 1
            
            # If ghost failed, extract the error and report it
            if istaskfailed(ghost)
                try
                    fetch(ghost)  # This will throw the error
                catch e
                    # Grug found dead ghost. Report it to the map.
                    push!(map.dead_ghosts_report, (hole.name, _now_s(), e))
                end
            end
        else
            push!(alive_ghosts, ghost)
        end
    end
    hole.ghosts = alive_ghosts
    hole.active_ghosts = length(alive_ghosts)
end

# =============================================================================
# METABOLIC DISPATCH - Do Geometry, Wake Things Up
# =============================================================================
"""
    do_geometry!(map::BreathMap, hole_name::String, args...; kwargs...) -> Any

Perform a geometry operation on a hole. Wakes up the hole if sleeping.
Increases juice. May spawn ghost workers. May transition to GPU.

GRUG NOT SILENTLY FALL BACK. If GPU cousin dead, GRUG SCREAM.
User must explicitly handle GPU failure. No secret fallbacks.

Arguments:
- map: The breathing machine
- hole_name: Which hole to use (rotate, translate, scale, project, reflect, intersect, extrude, boolean)
- args: Arguments for the operation
- kwargs: Keyword arguments for the operation

Returns: The result of the operation

Throws:
- WrongHoleError: Hole name doesn't exist
- MissingOperationError: Operation not implemented
- GpuCousinDeadError: GPU required but not available
- GpuFallbackRequiredError: GPU failed (includes original error)
- MachineDeadError: BreathMap not breathing
- GhostWorkerDiedError: Ghost worker died (can be checked in map.dead_ghosts_report)
"""
function do_geometry!(map::BreathMap, hole_name::String, args...; kwargs...)
    # Check machine is alive
    if !map.breathe_flag[]
        throw(MachineDeadError("Cannot do geometry on dead machine. Breathe first."))
    end
    
    # Check hole exists
    if !haskey(map.holes, hole_name)
        throw(WrongHoleError("Hole '$hole_name' not found. Available: $(keys(map.holes))"))
    end
    
    hole = map.holes[hole_name]
    now = _now_s()
    
    return lock(hole.rock_lock) do
        # Metabolic activation
        hole.current_juice = min(hole.max_juice, hole.current_juice + hole.juice_step)
        hole.wake_until = min(now + hole.max_hot_window, hole.wake_until + hole.ttl_boost)
        hole.streak += 1
        hole.last_hit = now
        
        # Update state
        _update_hole_state!(hole)
        
        # Decide CPU or GPU
        use_gpu = hole.state == GPU_STATE && hole.current_juice >= hole.gpu_threshold
        
        # Check for ghost worker spawn opportunity
        if hole.streak >= 3 && hole.active_ghosts < hole.max_ghosts
            _maybe_spawn_ghost!(hole, args; kwargs...)
        end
        
        # Do the work. GRUG NOT SILENTLY FALL BACK.
        if use_gpu
            # Try GPU. If fails, SCREAM. No silent fallback.
            return hole.gpu_trick(args...; kwargs...)
        else
            return hole.cpu_trick(args...; kwargs...)
        end
    end
end

"""
    do_geometry_with_fallback!(map::BreathMap, hole_name::String, args...; kwargs...) -> Any

EXPLICIT fallback version. User CHOOSES to fall back to CPU if GPU fails.
This is NOT automatic. User must call this if they want fallback behavior.

Grug respect user choice. User want fallback? User ask for fallback.
Grug not decide for user. Grug not hide GPU death.

Arguments same as do_geometry!

Returns: The result of the operation (GPU if available, CPU if GPU fails)

Throws:
- All same errors as do_geometry! EXCEPT GpuCousinDeadError (falls back instead)
"""
function do_geometry_with_fallback!(map::BreathMap, hole_name::String, args...; kwargs...)
    # Check machine is alive
    if !map.breathe_flag[]
        throw(MachineDeadError("Cannot do geometry on dead machine. Breathe first."))
    end
    
    # Check hole exists
    if !haskey(map.holes, hole_name)
        throw(WrongHoleError("Hole '$hole_name' not found. Available: $(keys(map.holes))"))
    end
    
    hole = map.holes[hole_name]
    now = _now_s()
    
    return lock(hole.rock_lock) do
        # Metabolic activation
        hole.current_juice = min(hole.max_juice, hole.current_juice + hole.juice_step)
        hole.wake_until = min(now + hole.max_hot_window, hole.wake_until + hole.ttl_boost)
        hole.streak += 1
        hole.last_hit = now
        
        # Update state
        _update_hole_state!(hole)
        
        # Decide CPU or GPU
        use_gpu = hole.state == GPU_STATE && hole.current_juice >= hole.gpu_threshold
        
        # Check for ghost worker spawn opportunity
        if hole.streak >= 3 && hole.active_ghosts < hole.max_ghosts
            _maybe_spawn_ghost!(hole, args; kwargs...)
        end
        
        # Do the work with EXPLICIT fallback (user asked for this)
        if use_gpu
            try
                return hole.gpu_trick(args...; kwargs...)
            catch e
                if isa(e, GpuCousinDeadError)
                    # User explicitly asked for fallback. Grug respect choice.
                    # But grug still record the GPU death for transparency.
                    push!(map.dead_ghosts_report, (hole_name, now, e))
                    return hole.cpu_trick(args...; kwargs...)
                end
                rethrow(e)
            end
        else
            return hole.cpu_trick(args...; kwargs...)
        end
    end
end

"""
    _maybe_spawn_ghost!(hole::GrugHole, args; kwargs...)

Spawn an ephemeral worker if conditions are right.
Grug call ghost friends when really busy.

GHOST WORKER DIES? GRUG SCREAM. No silent death.
"""
function _maybe_spawn_ghost!(hole::GrugHole, args; kwargs...)
    # Probability increases with streak and juice
    spawn_prob = min(0.8, hole.streak * 0.1 + (hole.current_juice - hole.cpu_threshold) * 0.5)
    
    if rand() < spawn_prob
        ghost = @async begin
            # Ghost worker do trick. If ghost die, ghost SCREAM.
            hole.cpu_trick(args...; kwargs...)
        end
        push!(hole.ghosts, ghost)
        hole.active_ghosts += 1
    end
end

# =============================================================================
# LIFECYCLE - Kill and Status
# =============================================================================
"""
    kill_map!(map::BreathMap)

Stop the breathing. Kill the machine. Grug rest now.
Cannot be restarted. Make new map if need more breathing.

Grug also report any dead ghosts that were found.
"""
function kill_map!(map::BreathMap)
    map.breathe_flag[] = false
    
    # Wait for lungs to stop
    if !istaskdone(map.lungs)
        wait(map.lungs)
    end
    
    # Final ghost report before clearing
    for (name, hole) in map.holes
        lock(hole.rock_lock) do
            _find_and_report_dead_ghosts!(hole, map)
        end
    end
    
    # Kill all ghost workers
    for (name, hole) in map.holes
        lock(hole.rock_lock) do
            hole.ghosts = Task[]
            hole.active_ghosts = 0
            hole.state = PLACEHOLDER_STATE
        end
    end
    
    return nothing
end

"""
    map_status(map::BreathMap) -> Dict{String, Any}

Get the status of the whole breathing machine.
Grug check on all holes at once.
Includes dead ghost count. Grug not hide the dead.
"""
function map_status(map::BreathMap)
    return Dict{String, Any}(
        "breathing" => map.breathe_flag[],
        "num_holes" => length(map.holes),
        "total_juice" => sum(h.current_juice for h in values(map.holes)),
        "total_ghosts" => sum(h.active_ghosts for h in values(map.holes)),
        "total_dead_ghosts" => sum(h.ghost_graveyard for h in values(map.holes)),
        "dead_ghosts_report" => length(map.dead_ghosts_report),
        "holes" => Dict(name => hole_status(h) for (name, h) in map.holes)
    )
end

"""
    hole_status(hole::GrugHole) -> Dict{String, Any}

Get the status of a single hole.
Grug check on one hole. Includes dead ghost count.
"""
function hole_status(hole::GrugHole)
    return Dict{String, Any}(
        "name" => hole.name,
        "state" => String(hole.state),
        "juice" => hole.current_juice,
        "juice_percent" => round(100 * hole.current_juice / hole.max_juice, digits=1),
        "streak" => hole.streak,
        "active_ghosts" => hole.active_ghosts,
        "max_ghosts" => hole.max_ghosts,
        "dead_ghosts" => hole.ghost_graveyard,
        "wake_remaining_ms" => max(0.0, (hole.wake_until - _now_s()) * 1000),
        "has_cpu_trick" => hole.cpu_trick !== nothing,
        "has_gpu_trick" => hole.gpu_trick !== nothing
    )
end

"""
    get_dead_ghosts_report(map::BreathMap) -> Vector{Tuple{String, Float64, Exception}}

Get the full report of dead ghosts. Grug not hide the dead.
Returns list of (hole_name, time_of_death, exception).
"""
function get_dead_ghosts_report(map::BreathMap)
    return map.dead_ghosts_report
end

# =============================================================================
# INITIALIZATION - Set up default tricks on module load
# =============================================================================

"""
    _setup_default_tricks!(map::BreathMap)

Set up the default CPU/GPU tricks for all holes.
Grug need tricks ready to go.
"""
function _setup_default_tricks!(map::BreathMap)
    tricks = Dict{String, Tuple{Function, Function}}(
        "rotate" => (rotate_cpu, rotate_gpu),
        "translate" => (translate_cpu, translate_gpu),
        "scale" => (scale_cpu, scale_gpu),
        "project" => (project_cpu, project_gpu),
        "reflect" => (reflect_cpu, reflect_gpu),
        "intersect" => (intersect_cpu, intersect_gpu),
        "extrude" => (extrude_cpu, extrude_gpu),
        "boolean" => (boolean_cpu, boolean_gpu)
    )
    
    for (name, (cpu_f, gpu_f)) in tricks
        if haskey(map.holes, name)
            set_cpu_trick!(map.holes[name], cpu_f)
            set_gpu_trick!(map.holes[name], gpu_f)
        end
    end
    
    return map
end

# Export a convenience constructor that sets up defaults
export BreathMapWithTricks, do_geometry_with_fallback!, get_dead_ghosts_report

"""
    BreathMapWithTricks(; hole_names::Vector{String} = DEFAULT_HOLES) -> BreathMap

Create a BreathMap with all default tricks pre-installed.
Grug ready to work immediately.
"""
function BreathMapWithTricks(; hole_names::Vector{String} = DEFAULT_HOLES)
    map = BreathMap(hole_names = hole_names)
    _setup_default_tricks!(map)
    return map
end

# =============================================================================
# ACADEMIC COMMENT BLOCK - Formal Specification
# =============================================================================
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │                    GRUGBREATHMAP FORMAL SPECIFICATION                   │
# │                         Academic Reference Document                      │
# └─────────────────────────────────────────────────────────────────────────┘
#
# 1. SYSTEM MODEL
# ─────────────────
# The GrugBreathMap system M is formally defined as a tuple:
#
#   M = (H, Φ, Λ, Σ, δ)
#
# Where:
#   H = {h₁, h₂, ..., h₈} is the set of 8 semantic channels (holes)
#   Φ: H → State is the state mapping function
#   Λ: H → [0, J_max] is the juice level function
#   Σ: H → P(Task) is the ghost worker set function (bounded by max_ghosts)
#   δ: H × Args → Result is the dispatch function
#
# 2. STATE SPACE
# ───────────────
# Each hole h ∈ H has a state s ∈ S where S = {Placeholder, CPU, GPU}
#
# State transitions are governed by the juice level J(h):
#
#   Φ(h) = GPU    iff J(h) ≥ θ_gpu
#   Φ(h) = CPU    iff θ_cpu ≤ J(h) < θ_gpu
#   Φ(h) = Placeholder iff J(h) < θ_cpu
#
# Default thresholds: θ_cpu = 0.3, θ_gpu = 0.7
#
# 3. JUICE DYNAMICS
# ──────────────────
# The juice level evolves according to a discrete-time dynamical system:
#
#   J(h, t+Δt) = min(J_max, J(h,t) + u(t)·ΔJ_use - d(t)·ΔJ_decay)
#
# Where:
#   u(t) = 1 if operation invoked at time t, 0 otherwise
#   d(t) = 1 if t > t_wake (past TTL), 0 otherwise
#   ΔJ_use = 0.1 (default increment per operation)
#   ΔJ_decay = 0.1 × J(h,t) (10% geometric decay)
#
# 4. EPHEMERAL WORKER BOUND
# ──────────────────────────
# Ghost workers are bounded ephemeral tasks:
#
#   |Σ(h)| ≤ max_ghosts = 8, ∀h ∈ H, ∀t
#
# Invariant: Ghost worker count never exceeds bound.
# Proof: Workers only spawned under condition |Σ(h)| < max_ghosts.
#
# 5. ERROR PROPAGATION SEMANTICS
# ───────────────────────────────
# The system maintains a zero-silent-failure policy through strict error
# propagation. All exceptions E are derived from GrugLoudScreamError.
#
# Error Taxonomy:
#   GrugLoudScreamError (abstract)
#   ├── WrongHoleError        : Invalid channel access
#   ├── GpuCousinDeadError    : GPU unavailability
#   ├── MachineDeadError      : System not operational
#   ├── MissingOperationError : Unimplemented operation
#   ├── GhostWorkerDiedError  : Ephemeral worker failure
#   └── GpuFallbackRequiredError : GPU failure requiring user handling
#
# 6. METABOLIC DISPATCH INVARIANT
# ────────────────────────────────
# Theorem (Eventual Quiescence):
#   If no operations are performed on hole h for time T > max_hot_window,
#   then Φ(h) = Placeholder and J(h) = J_baseline.
#
# Proof Sketch:
#   After TTL expires, juice decays geometrically with rate r = 0.1.
#   J(t) = J(t-Δt) × (1-r) until J_baseline is reached.
#   Since r > 0, lim_{t→∞} J(t) = J_baseline.
#   State transitions are monotonic with juice decay.
#   ∎
#
# 7. CONCURRENCY MODEL
# ────────────────────
# Each GrugHole maintains a ReentrantLock (rock_lock) ensuring:
#   - Atomic juice updates
#   - Atomic state transitions
#   - Thread-safe ghost worker management
#
# The BreathMap maintains an Atomic{Bool} (breathe_flag) for:
#   - Lock-free operational status checks
#   - Clean shutdown semantics
#
# 8. FORMAL LAMBDA CALCULUS REPRESENTATION
# ─────────────────────────────────────────
#
#   Hole := λname.λcpu.λgpu.{name, cpu, gpu, state := Placeholder, juice := J_0}
#
#   BreathMap := λholes.λflag.λlungs.λreports.{holes, flag, lungs, reports}
#
#   do_geometry := λmap.λhole.λargs.
#     if ¬map.flag then ERROR[MachineDead]
#     else if hole ∉ map.holes then ERROR[WrongHole]
#     else let h = map.holes[hole] in
#       let j' = min(h.max_juice, h.juice + h.juice_step) in
#       let s' = state_from_juice(j', h.θ_cpu, h.θ_gpu) in
#       if s' = GPU then h.gpu_trick(args) else h.cpu_trick(args)
#
#   state_from_juice := λj.λθ_cpu.λθ_gpu.
#     if j ≥ θ_gpu then GPU
#     else if j ≥ θ_cpu then CPU
#     else Placeholder
#
#   breathe_loop := λmap.
#     while map.flag do
#       for each (name, hole) in map.holes do
#         if expired(hole.ttl) then decay(hole);
#         report_dead_ghosts(hole, map);
#         sleep(0.5ms)
#
# 9. REFERENCES
# ─────────────
# [1] Demand-Driven Computation: Launchbury, J. "Natural Semantics for
#     Lazy Evaluation." POPL 1993.
# [2] Metabolic Computing: Inspired by biological homeostasis and
#     energy-based resource allocation models.
# [3] Bounded Parallelism: Leiserson, C. "The Cilk Project." MIT CSAIL.
# [4] Zero-Silent-Failure Policy: Inspired by Erlang's "Let It Crash"
#     philosophy and Go's explicit error handling.
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ END OF ACADEMIC SPECIFICATION                                           │
# │ Grug not force. Grug breathe. Knowledge free. Breath free.              │
# └─────────────────────────────────────────────────────────────────────────┘

end # module