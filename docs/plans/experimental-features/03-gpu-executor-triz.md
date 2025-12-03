# GPU Executor TRIZ Analysis

**Status:** Complete
**Feature:** GPU Executor
**Module:** [`pipeline/executors.zig`](../../../src/ecs/pipeline/executors.zig)
**Last Updated:** 2024-11-29

## Executive Summary

**Recommendation: Conditional NO-GO (Defer)**

GPU execution for ECS systems faces fundamental technical contradictions that make general-purpose implementation infeasible within reasonable effort. The PCIe transfer bottleneck, shader divergence penalty, and cross-platform complexity outweigh benefits for typical ECS workloads. However, a **narrow vertical slice** for particle systems or physics simulations may be viable as a future research direction.

**Key Finding**: The break-even point for GPU benefit requires ~10,000+ entities with uniform, SIMD-friendly operations. Most ECS systems are entity-divergent (different code paths per entity), which incurs severe GPU penalties.

---

## Current State

The GPU executor in [`executors.zig`](../../../src/ecs/pipeline/executors.zig:99-139) is a placeholder with the following characteristics:

- **Structure**: Type-generating function `GpuComputeExecutor(comptime cfg: WorldConfig) type`
- **Config**: [`GpuComputeConfig`](../../../src/ecs/pipeline/executors.zig:68-77) with device_index, max_work_groups, work_group_size, shared_memory
- **Behavior**: All methods return `error.GpuUnavailable`
- **Integration**: None - completely non-functional

```zig
// Current state: All operations fail
pub fn init(gpu_config: GpuComputeConfig) error{GpuUnavailable}!Self {
    _ = gpu_config;
    return error.GpuUnavailable;
}
```

---

## TRIZ Analysis

### 1. Problem Statement

#### Technical System Description

The GPU executor is intended to offload data-parallel ECS system execution to GPU compute shaders. The goal is to accelerate systems that process large numbers of entities with uniform operations (e.g., particle physics, spatial hashing, boid simulations).

#### Core Challenges

| Challenge | Severity | Root Cause |
|-----------|----------|------------|
| **PCIe Bottleneck** | Critical | CPU↔GPU transfers at ~16 GB/s (PCIe 3.0 x16) vs ~50 GB/s CPU memory bandwidth |
| **Shader Divergence** | Critical | Per-entity branching causes GPU threads to serialize (SIMT penalty) |
| **Compilation Overhead** | High | Shader compilation at runtime, no comptime codegen for shaders |
| **Synchronization Latency** | High | GPU↔CPU sync requires pipeline flush (~1-5ms) |
| **Cross-Platform APIs** | High | Vulkan, Metal, DirectX12, WebGPU all differ significantly |
| **Memory Layout** | Medium | GPU prefers specific alignments (16-byte, 256-byte for buffers) |

#### Current ECS Data Layout

The [`archetype_table.zig`](../../../src/ecs/world/archetype_table.zig) already uses Structure-of-Arrays (SoA) storage:

```zig
// GPU-friendly: Contiguous component arrays
pub fn getComponentSlice(self: *Self, comptime T: type) ?[]T {
    // Returns dense array of component values
    return switch (capacity_mode) {
        .fixed => self.component_storage[i][0..self.count],
        .dynamic => self.component_storage[i].items,
    };
}
```

**Advantage**: SoA layout is optimal for GPU coalesced memory access.
**Disadvantage**: Zig types don't map to GLSL/HLSL/WGSL types automatically.

### 2. Ideal Final Result (IFR)

The **perfect GPU executor** would:

1. **Automatic Acceleration**: GPU automatically used for suitable systems (no user annotation required)
2. **Zero-Copy Transfer**: Component arrays transferred via mapped memory or unified address space
3. **Transparent Fallback**: Seamless CPU fallback when GPU unavailable or batch too small
4. **No User Complexity**: Users write normal Zig system code, no shader knowledge required
5. **Comptime Elimination**: Zero code generated when GPU disabled in config
6. **Cross-Platform**: Works on Vulkan, Metal, DirectX12, and WebGPU
7. **Deterministic Results**: Identical behavior to CPU execution (floating-point edge cases aside)

#### Reality Check

IFR items 1-4 and 7 are **technically infeasible** with current GPU technology:

- **Item 1 (Auto-selection)**: Requires static analysis of control flow - impossible for arbitrary Zig code
- **Item 2 (Zero-copy)**: Discrete GPUs have separate memory; unified memory (AMD APU, Apple M-series) is the exception
- **Item 4 (No shader knowledge)**: GPU kernels require fundamentally different programming model (no allocations, no pointers, limited control flow)
- **Item 7 (Determinism)**: GPU floating-point is implementation-defined; FMA operations differ from CPU

### 3. Technical Contradictions

| # | Improving Parameter | Worsening Parameter | Contradiction Description |
|---|---------------------|---------------------|---------------------------|
| 1 | **Throughput** (entities/second) | **Latency** (time to first result) | GPU batch processing adds 1-5ms sync latency |
| 2 | **Parallelism** (GPU cores) | **Flexibility** (arbitrary code) | GPU SIMT model penalizes divergent branches |
| 3 | **Performance** (GPU speed) | **Portability** (cross-platform) | Vulkan-specific optimizations break on Metal/DirectX |
| 4 | **Simplicity** (user API) | **Capability** (GPU features) | Simple API cannot express GPU-specific concepts (workgroups, barriers) |
| 5 | **Memory Bandwidth** (GPU HBM) | **Transfer Overhead** (PCIe) | High GPU bandwidth negated by PCIe bottleneck |
| 6 | **Code Reuse** (Zig systems on GPU) | **Implementation Effort** | Shader transpilation from Zig is a multi-year research project |
| 7 | **Safety** (CPU fallback) | **Complexity** (two code paths) | Maintaining both GPU and CPU implementations doubles work |

#### Critical Contradiction Analysis

**Contradiction #5 (Memory Bandwidth vs Transfer Overhead)** is the fundamental blocker:

```
GPU Compute Scenario:
- 10,000 entities × 16 bytes/entity = 160 KB per component
- 5 components = 800 KB total transfer
- PCIe 3.0 x16: ~12.8 GB/s effective = 62 µs transfer time
- GPU compute (RTX 3080): 29.8 TFLOPS
  - Simple operation (multiply-add): 10,000 × 1 FLOP = 0.3 µs
- Total: 62 µs transfer + 0.3 µs compute = 62.3 µs

CPU Alternative:
- L3 cache bandwidth: ~200 GB/s
- 800 KB / 200 GB/s = 4 µs
- CPU compute (8-core, 4 GHz): 10,000 × 1 FLOP ≈ 2.5 µs (with SIMD)
- Total: 4 µs + 2.5 µs = 6.5 µs

Result: CPU is ~10x faster for small batches due to transfer overhead
```

**Break-even point**: ~100,000+ entities with compute-heavy operations (physics, AI)

### 4. Inventive Principles Analysis

#### Principle #1: Segmentation
**Application**: Separate GPU-suitable systems from CPU-only systems at compile time

```zig
// Proposed: System annotation for GPU eligibility
pub const GpuEligible = struct {
    /// Minimum entity count to dispatch to GPU
    min_entities: u32 = 10000,
    /// System has no per-entity branches
    uniform_control_flow: bool = true,
    /// Components are GPU-copyable (no pointers, fixed size)
    copyable_components: bool = true,
};

// User annotates system
const particleSystem = struct {
    pub const gpu_eligible = GpuEligible{ .min_entities = 5000 };
    pub fn run(positions: []Vec3, velocities: []const Vec3) void {
        // Uniform operation: positions[i] += velocities[i]
    }
};
```

- **Benefit**: Only eligible systems considered for GPU
- **Effort**: Medium (requires system metadata extension)

#### Principle #2: Extraction
**Application**: Extract only SoA component arrays to GPU, not entity metadata

- **Current**: Archetype tables contain entity IDs + components
- **Solution**: Transfer only component slices needed by GPU kernel
- **Benefit**: Minimizes PCIe traffic

```zig
// Extract only needed arrays
const positions = archetype.getComponentSlice(Position);  // Only this goes to GPU
const velocities = archetype.getComponentSlice(Velocity);
// Entity IDs stay on CPU - GPU doesn't need them
```

#### Principle #4: Asymmetry
**Application**: Different execution paths for different system types

- **CPU Path**: Complex, divergent systems (AI, state machines, queries)
- **GPU Path**: Uniform, data-parallel systems (particles, physics)
- **Hybrid Path**: GPU for bulk compute, CPU for exception handling

#### Principle #7: Nesting
**Application**: Layered architecture for GPU integration

- **Layer 1**: [`GpuComputeConfig`](../../../src/ecs/pipeline/executors.zig:68-77) - User configuration
- **Layer 2**: GPU Backend Selection (Vulkan/Metal/WebGPU)
- **Layer 3**: Buffer Management (staging, device-local)
- **Layer 4**: Shader Compilation (SPIR-V/MSL/DXIL)
- **Layer 5**: Dispatch & Sync

#### Principle #10: Preliminary Action
**Application**: Pre-compile shaders and pre-allocate GPU buffers at init

```zig
// Proposed: World initialization pre-registers GPU resources
pub fn initGpu(self: *World) !void {
    // Pre-allocate staging buffer for max entity count
    self.gpu_staging = try GpuBuffer.init(.staging, self.config.max_entities * 64);
    
    // Pre-compile shaders for registered GPU systems
    for (self.gpu_systems) |system| {
        try self.shader_cache.compile(system.kernel_source);
    }
}
```

- **Benefit**: Eliminates runtime compilation latency
- **Effort**: High (requires shader pipeline)

#### Principle #15: Dynamics
**Application**: Runtime decision CPU vs GPU based on entity count

```zig
fn executeSystem(self: *Scheduler, system: System, archetype: *Archetype) void {
    const entity_count = archetype.len();
    
    if (system.gpu_eligible and entity_count >= system.gpu_threshold) {
        self.dispatchToGpu(system, archetype);
    } else {
        self.dispatchToCpu(system, archetype);
    }
}
```

#### Principle #16: Partial Action
**Application**: GPU for hot systems only, not entire scheduler

- Only particle systems, physics, or specific hot paths use GPU
- Rest of ECS remains CPU-only
- Avoids "GPU everywhere" complexity

#### Principle #25: Self-service
**Application**: Auto-detection of GPU-suitable systems via comptime analysis

```zig
// Comptime analysis of system function
fn isGpuEligible(comptime SystemFn: type) bool {
    const fn_info = @typeInfo(@TypeOf(SystemFn.run)).@"fn";
    
    // Check 1: All parameters are slices (SoA pattern)
    for (fn_info.params) |param| {
        if (@typeInfo(param.type) != .pointer) return false;
    }
    
    // Check 2: Return type is void (no complex return)
    if (fn_info.return_type != void) return false;
    
    return true;
}
```

- **Limitation**: Cannot detect control flow divergence at comptime
- **Benefit**: Reduces manual annotation burden

#### Principle #26: Copying
**Application**: Shadow copies for async GPU execution

- CPU retains read-only copy while GPU processes
- Results copied back after GPU completes
- Enables overlapping CPU/GPU work

```
Frame N:
  [CPU Systems] → [Copy to GPU] → [GPU Compute] → [Copy from GPU]
Frame N+1:
  [CPU Systems using old data] → [Wait for GPU] → [Apply new data]
```

### 5. Resources Analysis

#### Available Resources

| Resource Type | Resource | Current Usage | GPU Potential |
|--------------|----------|---------------|---------------|
| **System** | SoA archetype storage | Iteration, modification | Direct GPU buffer upload |
| **System** | Comptime type system | Type safety | Could generate shader types |
| **System** | [`BackendStats`](../../../src/ecs/scheduler/backends/interface.zig:38-60) | Tick/system metrics | Add GPU transfer time |
| **Information** | Component type info | Layout calculation | GPU buffer alignment |
| **Time** | Phase boundaries | System execution | GPU sync points |

#### Underutilized Resources

1. **Zig Comptime**: Could generate WGSL/GLSL from Zig types (research project)
2. **Archetype Metadata**: Component sizes/alignments known at comptime - useful for GPU layout
3. **Existing Batch Pattern**: [`BatchWorkerPool`](../../../src/ecs/pipeline/executors.zig:192-308) shows batch API pattern

#### External Resources Required

| Resource | Options | Complexity | Maintenance |
|---------|---------|------------|-------------|
| **GPU API** | wgpu-native, Vulkan, Metal | High | Ongoing |
| **Shader Compilation** | SPIR-V tools, WGSL parser | High | Ongoing |
| **Memory Management** | VMA, Metal heaps | Medium | Ongoing |

### 6. Solution Concepts

#### Solution 1: WebGPU via wgpu-native (Recommended if Go)
**Contradictions Addressed**: #3 (Portability)
**Principles Applied**: #1 (Segmentation), #7 (Nesting)

WebGPU provides cross-platform abstraction over Vulkan/Metal/DirectX12.

```zig
// Proposed: WebGPU backend
pub const WgpuBackend = struct {
    instance: *wgpu.Instance,
    adapter: *wgpu.Adapter,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    
    staging_buffer: *wgpu.Buffer,
    compute_buffer: *wgpu.Buffer,
    
    pub fn init() !WgpuBackend {
        const instance = wgpu.createInstance(.{});
        // ... adapter/device creation
    }
    
    pub fn dispatch(
        self: *WgpuBackend,
        pipeline: *wgpu.ComputePipeline,
        input: []const u8,
        output: []u8,
    ) void {
        // Copy input to staging
        self.queue.writeBuffer(self.staging_buffer, 0, input);
        
        // Dispatch compute
        const encoder = self.device.createCommandEncoder(.{});
        const pass = encoder.beginComputePass(.{});
        pass.setPipeline(pipeline);
        pass.dispatchWorkgroups(input.len / 64, 1, 1);
        pass.end();
        
        // Copy output back
        self.queue.submit(&[_]*wgpu.CommandBuffer{encoder.finish(.{})});
    }
};
```

**Pros**:
- Single API for all platforms
- Browser support via WebGPU (future WASM target)
- Active development (wgpu in Rust, wgpu-native for C/Zig)

**Cons**:
- Abstraction overhead (~5-10% vs native Vulkan)
- WGSL shader language different from GLSL/HLSL
- wgpu-native build complexity with Zig

**Effort**: 3-6 developer-months for MVP

#### Solution 2: Vulkan-Only (Linux/Windows Server Focus)
**Contradictions Addressed**: #3 (Portability) - by abandoning it
**Principles Applied**: #3 (Local Quality)

Skip cross-platform, optimize for server deployment.

**Pros**:
- Maximum performance
- Best documentation and tooling
- Synchronization control

**Cons**:
- No macOS support
- Vulkan complexity (hundreds of API calls)
- Driver dependency

**Effort**: 4-8 developer-months for MVP

#### Solution 3: Shader-Only Library (No Runtime Transpilation)
**Contradictions Addressed**: #6 (Code Reuse vs Effort)
**Principles Applied**: #16 (Partial Action)

Instead of Zig→GPU transpilation, provide pre-written shaders for common operations.

```zig
// User provides pre-written WGSL
const particleShader = @embedFile("shaders/particle_update.wgsl");

const GpuParticleSystem = GpuSystem(cfg){
    .shader_source = particleShader,
    .input_components = .{ Position, Velocity },
    .output_components = .{ Position },
};
```

**Pros**:
- No transpilation research needed
- Users can optimize shaders manually
- Predictable performance

**Cons**:
- Users must know shader languages
- Shader/Zig type mismatch possible
- Maintenance of shader library

**Effort**: 2-3 developer-months for MVP

#### Solution 4: Deferred to External Libraries
**Contradictions Addressed**: All - by not solving them
**Principles Applied**: N/A

Acknowledge GPU is out of scope. Point users to:
- [Mach Engine](https://machengine.org/) - Zig game engine with GPU support
- Direct Vulkan/wgpu integration in user code

```zig
// Close the placeholder - document recommended approach
pub fn GpuComputeExecutor(comptime cfg: WorldConfig) type {
    @compileError(
        \\GPU execution is not implemented in StaticECS.
        \\For GPU compute, integrate wgpu-native or Vulkan directly.
        \\See: docs/EXPERIMENTAL.md#gpu-compute-guidance
    );
}
```

**Pros**:
- Zero maintenance burden
- Honest about capabilities
- Users can make informed choices

**Cons**:
- Disappointing if GPU was expected feature
- Placeholder remains forever

**Effort**: 1-2 hours

### 7. Go/No-Go Analysis

#### Decision Matrix

| Factor | Weight | Go Score | No-Go Score | Notes |
|--------|--------|----------|-------------|-------|
| **User Demand** | 20% | 3/10 | 7/10 | Server ECS rarely needs GPU |
| **Technical Complexity** | 25% | 2/10 | 8/10 | Multi-month R&D effort |
| **Maintenance Burden** | 20% | 2/10 | 8/10 | GPU APIs change frequently |
| **Performance Benefit** | 15% | 4/10 | 6/10 | Only for specific workloads |
| **Alternative Solutions** | 10% | 3/10 | 7/10 | wgpu integration is straightforward |
| **Strategic Value** | 10% | 5/10 | 5/10 | "Has GPU" is marketing value |

**Weighted Score**:
- Go: 2.75/10
- No-Go: 7.25/10

#### Recommendation: **NO-GO (Defer)**

**Rationale**:

1. **Effort-to-Benefit Ratio**: 3-6 months of development for a feature that benefits <5% of use cases

2. **Technical Contradictions Unresolved**: The PCIe bottleneck (#5) cannot be solved without unified memory hardware, which is not universal

3. **Maintenance Burden**: GPU APIs (Vulkan, Metal, DirectX, WebGPU) are moving targets with breaking changes

4. **Better Alternatives Exist**: Users needing GPU can integrate wgpu-native directly with minimal effort

5. **Core Value Proposition**: StaticECS focuses on "maximum performance within constraints" - GPU adds complexity that violates this principle for most users

#### Conditional Future Reconsideration

Revisit this decision if:

1. **WebGPU matures**: wgpu-native becomes stable and easy to integrate with Zig build system
2. **User demand increases**: Multiple users request GPU support for specific workloads
3. **Unified memory becomes standard**: Apple M-series success pushes industry toward unified memory
4. **Zig shader compilation emerges**: Community develops Zig→WGSL/SPIR-V transpiler

### 8. Implementation Recommendations

#### Immediate Actions (Current Sprint)

1. **Update Placeholder Documentation**
   - Clearly state GPU is not planned
   - Provide guidance for direct wgpu integration
   - Remove "Future plans: SPIR-V" from docs (misleading)

2. **Consider Compile Error**
   - Replace `error.GpuUnavailable` with `@compileError`
   - Prevents users from expecting runtime fallback

```zig
pub fn GpuComputeExecutor(comptime cfg: WorldConfig) type {
    _ = cfg;
    @compileError(
        \\GpuComputeExecutor is not implemented. For GPU compute:
        \\1. Integrate wgpu-native directly with your ECS
        \\2. Use getComponentSlice() to access SoA data for GPU upload
        \\See: docs/EXPERIMENTAL.md#gpu-integration-guidance
    );
}
```

3. **Add Integration Guidance**
   - Document how to use archetype slices with external GPU libraries
   - Provide example of wgpu integration pattern

#### If Decision Reversed (Future Go)

**Phase 1: Proof of Concept (4 weeks)**
- Integrate wgpu-native with Zig build
- Implement single GPU system (particle update)
- Measure actual performance vs CPU BatchWorkerPool
- **Gate**: Must show 2x+ speedup for 50k+ entities

**Phase 2: MVP (8 weeks)**
- Buffer management (staging, device-local, ring buffers)
- Pipeline caching
- 3-5 pre-written shaders (particles, physics, spatial hash)
- Async execution with fence synchronization

**Phase 3: Production (12+ weeks)**
- Multi-GPU support
- Memory defragmentation
- Profiling integration
- Comprehensive test suite

**Total Effort**: 6-12 developer-months

---

## Appendix: Technical Reference

### A.1 Relevant Code Locations

| Component | File | Purpose |
|-----------|------|---------|
| GPU Placeholder | [`executors.zig:99-139`](../../../src/ecs/pipeline/executors.zig:99) | Current non-functional implementation |
| GPU Config | [`executors.zig:68-77`](../../../src/ecs/pipeline/executors.zig:68) | Configuration structure |
| SoA Storage | [`archetype_table.zig:46-673`](../../../src/ecs/world/archetype_table.zig:46) | GPU-friendly data layout |
| Backend Interface | [`interface.zig:75-135`](../../../src/ecs/scheduler/backends/interface.zig:75) | Pattern for GPU backend |
| Batch Pattern | [`executors.zig:192-308`](../../../src/ecs/pipeline/executors.zig:192) | Reference for batch API |

### A.2 PCIe Bandwidth Calculations

| GPU Generation | Theoretical | Effective | Notes |
|---------------|-------------|-----------|-------|
| PCIe 3.0 x16 | 15.75 GB/s | ~12.8 GB/s | Most common |
| PCIe 4.0 x16 | 31.5 GB/s | ~25 GB/s | Modern GPUs |
| PCIe 5.0 x16 | 63 GB/s | ~50 GB/s | Emerging |
| Apple M-series | N/A | ~200 GB/s | Unified memory |

### A.3 Break-Even Analysis

```
Variables:
  N = entity count
  S = bytes per entity (all components)
  T_transfer = S × N / PCIe_bandwidth
  T_gpu_compute = N × ops_per_entity / GPU_FLOPS
  T_cpu_compute = N × ops_per_entity / CPU_FLOPS × SIMD_factor

Break-even when: T_transfer + T_gpu_compute < T_cpu_compute

For typical ECS (S=64 bytes, 10 ops/entity):
  PCIe 3.0: N > 50,000 entities
  PCIe 4.0: N > 25,000 entities
  Unified memory: N > 1,000 entities (negligible transfer)
```

---

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Parent planning document
- [EXPERIMENTAL.md](../../EXPERIMENTAL.md) - Experimental features status
- [wgpu-native](https://github.com/gfx-rs/wgpu-native) - Cross-platform GPU API
- [Vulkan Tutorial](https://vulkan-tutorial.com/) - Vulkan fundamentals
- [WebGPU Spec](https://www.w3.org/TR/webgpu/) - W3C WebGPU specification