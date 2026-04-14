# GrugBreathMap

> **Grug not know fancy word "idle". Grug call it "sleeping". Grug not wake up hole unless hole needed.**

A metabolic GPU dispatch system for geometric operations. Eight channels. Breath not force. No silent failures.

## Philosophy

**Breath not force.** Most GPU acceleration systems are always-on, consuming memory and resources even when idle. GrugBreathMap is different. It breathes.

- Holes sleep at baseline (placeholder state, near-zero memory)
- Holes wake up when used (CPU state)
- Holes get hot when heavily used (GPU state)
- Holes decay back to sleep when idle
- All errors are LOUD - no silent failures

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/marshalldavidson61-arch/breathingGPU")
```

## Quick Start

```julia
using GrugBreathMap

# Create a breathing map with all default tricks
map = BreathMapWithTricks()

# Do geometry - hole wakes up
point = [1.0, 0.0, 0.0]
rotated = do_geometry!(map, "rotate", point, π/2, [0.0, 0.0, 1.0])
# → [0.0, 1.0, 0.0]

# Check status
status = map_status(map)
println(status)

# When done, kill the machine
kill_map!(map)
```

## The Eight Holes

Grug has 8 holes for 8 geometry tricks:

| Hole | What Grug Do | CPU Args | GPU Args |
|------|--------------|----------|----------|
| `rotate` | Spin thing around | `(geometry, angle, axis)` | Same |
| `translate` | Move thing somewhere | `(geometry, offset)` | Same |
| `scale` | Make thing bigger/smaller | `(geometry, factors)` | Same |
| `project` | Flatten thing onto plane | `(geometry, plane_normal)` | Same |
| `reflect` | Mirror thing | `(geometry, plane_normal)` | Same |
| `intersect` | Find where things cross | `(geo_a, geo_b)` | Same |
| `extrude` | Push thing into 3D | `(geometry, distance, direction)` | Same |
| `boolean` | Combine/subtract things | `(geo_a, geo_b, :operation)` | Same |

## Metabolic Dispatch

GrugBreathMap uses a **metabolic dispatch** system:

```
PLACEHOLDER_STATE  →  CPU_STATE  →  GPU_STATE
      ↑                   ↑              ↑
   (sleeping)        (awake)         (HOT)
      │                   │              │
   baseline           juice >        juice >
   juice             cpu_threshold   gpu_threshold
      └──────────────────┴──────────────┘
              decay when idle
```

- **Juice**: Metabolic energy that rises on use, decays when idle
- **Streak**: Consecutive uses - builds momentum
- **Ghost Workers**: Ephemeral parallel tasks that spawn when hot (max 8 per hole)
- **TTL**: 1ms active window, capped at 8ms max hot

## Error Handling

Grug does not believe in silent failures. All errors SCREAM:

```julia
# Wrong hole name
do_geometry!(map, "bad_hole", ...)
# → 💀 WRONG HOLE! Grug confused. Hole 'bad_hole' not found.

# GPU not available
do_geometry!(map, "rotate", ...)  # when GPU required but unavailable
# → 💀 GPU COUSIN DEAD! No GPU trick today.

# Machine not breathing
do_geometry!(map, "rotate", ...)  # after kill_map!
# → 💀 MACHINE DEAD! Lungs stopped.
```

## Custom Tricks

Grug can learn new tricks:

```julia
map = BreathMap()

# Set custom CPU trick
set_cpu_trick!(map.holes["rotate"], function(geometry, angle, axis)
    # Your custom rotation implementation
    return rotated_geometry
end)

# Set custom GPU trick
set_gpu_trick!(map.holes["rotate"], function(geometry, angle, axis)
    # Your GPU-accelerated implementation
    return rotated_geometry_fast
end)
```

## Architecture

```
GrugBreathMap
├── BreathMap (orchestrator)
│   ├── holes: Dict{String, GrugHole}
│   ├── breathe_flag: Atomic{Bool}
│   └── lungs: Task (background breathing loop)
│
├── GrugHole (one channel)
│   ├── state: HoleState (PLACEHOLDER/CPU/GPU)
│   ├── juice: metabolic energy
│   ├── ghosts: ephemeral workers
│   ├── cpu_trick: Function
│   └── gpu_trick: Function
│
└── Errors (all LOUD)
    ├── WrongHoleError
    ├── GpuCousinDeadError
    ├── MachineDeadError
    └── MissingOperationError
```

## Running Tests

```julia
using Pkg
Pkg.test("GrugBreathMap")
```

## License

MIT License - Grug share. Knowledge free. Breath free.

## Philosophy (Extended)

From the conversations that birthed this:

> "knowledge is free. breath is free. it has nothing to do with authority"

> "you separate all the grains of sand on the beach now no one can use it"

This is anti-silo architecture. The operations are simple, composable, and bounded. No black boxes. No proprietary lock-in. Just breath.

---

*Grug not force. Grug breathe.*