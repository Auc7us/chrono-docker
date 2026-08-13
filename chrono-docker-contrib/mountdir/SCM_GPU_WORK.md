# Move SCM terrain ray-casting and contact forces to the GPU

Branch `feat/scm-gpu-backend` (19 commits), stacked on `feat/gpu-backend-hardware-first`. Target
that branch, not `main`.

## Change

Both per-node-independent stages of an SCM step move to the GPU: ray-casting (one ray per active
grid node against vehicle collision geometry) and contact forces (Bekker / Janosi-Hanamoto at
every hit). Kernels are HIP (`terrain/gpu/*.hip.cpp`) with plain C++ host wrappers, so one source
serves ROCm and, via HIP-on-NVIDIA, CUDA hardware. The CPU implementation is untouched and remains
the fallback.

On by default where hardware and toolchain allow, with no CMake option, environment variable or
API call required:

| | Default | Force off |
|---|---|---|
| Build | `CH_ENABLE_VEHICLE_SCM_GPU=ON` | set `OFF` |
| Contact forces | enabled (`min_hits=8192` CPU-fallback heuristic) | `SetScmGpuEnabled(false)` |
| Ray-casting | enabled | `EnableRaycastGpuHip(false)` |

Ray-casting also needs explicit active domains (`AddActiveDomain`) and triangle-mesh collision
geometry, the only shape type these kernels intersect. Lacking either, the backend declines the
step and the CPU path runs, so the default is safe for models that cannot use it
(`demo_ROBOT_RoboSimian_SCM` is one). Per-step fallback is silent by design;
`GetNumRaycastGpuSteps()` and `GetNumContactForceGpuSteps()` report what actually ran.

Ray-cast kernels are FP32 on every platform so a model behaves the same on AMD and NVIDIA. FP64
stays available through `SCM_RAYCAST_GPU_PRECISION`; the two differ by 3 um of sinkage against the
1.3 cm between the GPU and CPU ray-cast paths. `EnableRaycastGpuReference()` runs the same
algorithm on the CPU as a validation stand-in.

`CHRONO_ENABLE_HIP_ON_NVIDIA` flips to `ON` here (the option itself lives in the base branch).
These kernels exist only in HIP, so on NVIDIA "is HIP available" and "can this use the GPU" are one
question. DEM and FSI::SPH still resolve to CUDA. Without HIP the feature resolves to `NONE` and
the CPU path runs, reported as a status line, without forcing the option `OFF` in the cache.

Ray-body culling: each body carries a face range and a world AABB that a ray slab-tests before
touching its triangles, and nodes outside every body's (x,y) footprint never become queries at
all. Without it every ray scanned every triangle in the scene, 669M tests per step at 6 obstacles.

## Active-domain crash fix (review this first)

Independent of the GPU work. Fixes a null dereference that crashes `demo_ROBOT_Curiosity_SCM`,
`demo_ROBOT_Curiosity_SCM_Sensor` and `demo_ROBOT_Viper_SCM_Sensor` on current `main` with no GPU
modules enabled.

`SetupInitial()` appends a placeholder domain with `m_body = nullptr`. `AddActiveDomain()` appends
real domains and sets `m_user_domains = true` but never removes the placeholder, so the first step
iterates every domain and dereferences the null body. Calling `AddActiveDomain()` after
`Initialize()` crashes, before it works; that is undocumented and not the order the demos use.

Exposed by `6aba95d7d` (Jul 2026), which added `SetupInitial()` to all three `Initialize()`
overloads. The placeholder dates from `725aa2aca` (Apr 2025) but was dormant until then. The demos
did not change, and the crash only appears after a rebuild.

Fix, in `AddActiveDomain()`:

```cpp
if (!m_loader->m_user_domains)
    m_loader->m_active_domains.clear();
```

`clear()` is immediately followed by the existing `push_back`, so the unchecked
`m_active_domains[0]` in the other branch is not newly exposed.

## Testing

19 files, +3297/-166. RTX 4080 (CUDA 13.2, ROCm 7.2.4) and MI300X/gfx942. Configured with no GPU
flags, SCM resolves to HIP while DEM and FSI::SPH stay CUDA: 0 failures, 19 libraries, 230 demos.

`demo_ROBOT_Viper_SCM`, 2 s headless, steady-state ms/step with warm-up excluded, both backends
confirmed to have run every step (`raycast=4001/4001 forces=4001/4001`).

RTX 4080:

| Grid | GPU | CPU | speedup | GPU, 6 obstacles | CPU, 6 obstacles | speedup |
|---|---|---|---|---|---|---|
| 10 cm | 0.33 | 0.54 | 1.6x | 0.87 | 1.56 | 1.8x |
| 5 cm | 0.60 | 1.52 | 2.5x | 1.78 | 4.30 | 2.4x |
| 2 cm | 1.50 | 7.00 | 4.7x | 6.15 | 21.6 | 3.5x |
| 1 cm | 5.25 | 26.0 | 5.0x | 22.5 | 80.6 | 3.6x |

MI300X, whose host is 1.7-2x slower, so compare speedups rather than absolute times:

| Grid | GPU | CPU | speedup | GPU, 6 obstacles | CPU, 6 obstacles | speedup |
|---|---|---|---|---|---|---|
| 10 cm | 0.64 | 0.89 | 1.4x | 1.51 | 2.92 | 1.9x |
| 5 cm | 0.93 | 2.59 | 2.8x | 2.99 | 7.23 | 2.4x |
| 2 cm | 2.21 | 13.9 | 6.3x | 11.0 | 41.3 | 3.7x |
| 1 cm | 7.99 | 50.6 | 6.3x | 38.8 | 156.8 | 4.0x |

Speedup grows with resolution because ray count scales as 1/delta^2 while the serial remainder
does not. Obstacles reduce it: each carries an active domain covering far more soil than the
wheels do, and most of the work it adds stays on the CPU either way (contact patches, bulldozing,
erosion). Cross-vendor agreement is far tighter than CPU-vs-GPU: GPU sinkage on the two machines
matches to 0.07% at 10 cm and 0.008% at 2 cm, CPU rows to within 0.3%.

### Open question

The GPU ray cast does not reproduce Bullet's result: 5.4-5.6 cm of wheel sinkage against 4.1-4.3 cm
through `ChCollisionSystem::RayHit`, on both vendors. It is the formulation, not the GPU, since
the CPU reference implementation of the same algorithm lands within 0.09% of the kernels. Ruled
out by measurement: the contact-force backend (~2%), the collision margin (`GetEnvelope()` is 0
for these models, and zeroing the remaining 5 mm mesh thickness moves sinkage 4.7 mm, not 12) and
precision (3 um). Which formulation is closer to reality is unresolved. The 5 cm grid is a further
loose end, giving 4.5 cm identically on both machines where the other three resolutions give 5.4
to 5.6.

### Not covered

- `demo_ROBOT_RoboSimian_SCM` checked only for correct CPU fallback, not for GPU execution.
- Run-time visualization on AMD (VSG unavailable on that cluster).
- AMD parts other than gfx942, and Windows / MSVC.
