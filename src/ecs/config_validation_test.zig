//! Configuration Validation Test Suite
//!
//! This module tests that valid configurations compile and work correctly.
//!
//! **Compile-Time Error Testing**:
//! Zig's `@compileError` cannot be tested at runtime - invalid configs simply
//! won't compile. This is by design: the type system catches errors early.
//!
//! To manually verify comptime errors, uncomment the code blocks in the
//! "Manual Comptime Error Tests" section at the bottom of this file.
//! Each block should fail to compile with the documented error message.
//!
//! **Documented Comptime Errors**:
//! 1. `entity_index_bits` out of range [8, 24]
//! 2. `max_entities` = 0
//! 3. `max_entities` exceeds `entity_index_bits` capacity
//! 4. No phases defined
//! 5. Phase count exceeds `max_phases` option
//! 6. Single archetype mode with != 1 archetype
//! 7. Fixed-rate tick mode without `target_hz`
//! 8. Archetype component not in ComponentsSpec
//! 9. System component not in ComponentsSpec
//! 10. System phase index invalid
//! 11. Duplicate archetypes with same component set

const std = @import("std");
const testing = std.testing;

const config = @import("config.zig");
const WorldConfig = config.WorldConfig;
const Phase = config.Phase;
const PhaseDef = config.PhaseDef;
const ArchetypeDef = config.ArchetypeDef;
const SystemDef = config.SystemDef;
const asSystemFn = config.asSystemFn;
const validateWorldConfig = config.validateWorldConfig;
const validateSchedulerConfig = config.validateSchedulerConfig;

const world_mod = @import("world.zig");

const error_types = @import("error/error_types.zig");
const FrameError = error_types.FrameError;

// ============================================================================
// Test Components
// ============================================================================

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: u32 };

// ============================================================================
// Test Systems
// ============================================================================

/// Dummy system function using type erasure via anyopaque.
/// The actual context is SystemContext(config, WorldType) which gets cast when invoked.
fn dummySystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
}

// ============================================================================
// Comptime Config Constants (for configs with systems that require comptime)
// ============================================================================

// Config with systems - must be comptime because SystemDef contains []const type fields
const systems_config = WorldConfig{
    .components = .{ .types = &.{ Position, Velocity } },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "moving", .components = &.{ Position, Velocity } },
    } },
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .func = asSystemFn(dummySystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
        },
    },
};

// Config with needs_io system - must be comptime
const needs_io_config = WorldConfig{
    .components = .{ .types = &.{Position} },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "entity", .components = &.{Position} },
    } },
    .systems = .{
        .systems = &.{
            .{
                .name = "io_system",
                .func = asSystemFn(dummySystem),
                .needs_io = true,
            },
        },
    },
    .schedule = .{
        .execution_model = .evented_single_thread,
    },
};

// ============================================================================
// Valid Configuration Tests
// ============================================================================

test "valid minimal config compiles" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
    };

    // Validate at comptime
    comptime validateWorldConfig(cfg);

    // Create world type to verify it compiles
    const World = world_mod.World(cfg);
    var world = World.init(testing.allocator);
    defer world.deinit();

    try testing.expect(world.entityCount() == 0);
}

test "valid config with multiple components and archetypes" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity, Health } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "dynamic", .components = &.{ Position, Velocity } },
            .{ .name = "actor", .components = &.{ Position, Velocity, Health } },
        } },
    };

    comptime validateWorldConfig(cfg);

    const World = world_mod.World(cfg);
    var world = World.init(testing.allocator);
    defer world.deinit();

    try testing.expect(world.entityCount() == 0);
}

test "valid config with max_entities at bit width limit" {
    // 16-bit index allows up to 65535 entities
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .options = .{
            .entity_index_bits = 16,
            .max_entities = 65535, // Max for 16 bits
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with 24-bit entity index" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .options = .{
            .entity_index_bits = 24,
            .max_entities = 1000000, // 1M entities fits in 24 bits
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with 8-bit entity index" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .options = .{
            .entity_index_bits = 8,
            .max_entities = 200, // Fits in 8 bits (max 255)
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with custom phases" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .phases = .{
            .phases = &.{
                .{ .name = "input", .order = 0 },
                .{ .name = "physics", .order = 1 },
                .{ .name = "render", .order = 2 },
            },
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with fixed_rate tick and target_hz" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .tick = .{
            .mode = .fixed_rate,
            .target_hz = 60,
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with single_archetype layout mode" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "only", .components = &.{ Position, Velocity } },
        } },
        .options = .{
            .layout_mode = .single_archetype,
        },
    };

    comptime validateWorldConfig(cfg);
}

test "valid config with systems" {
    // Use module-level comptime config (SystemDef requires comptime for []const type fields)
    comptime validateWorldConfig(systems_config);
    comptime validateSchedulerConfig(systems_config);
}

test "valid config with evented execution model" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .schedule = .{
            .execution_model = .evented_single_thread,
        },
    };

    comptime validateWorldConfig(cfg);
    comptime validateSchedulerConfig(cfg);
}

test "valid config with concurrent threadpool" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        } },
        .schedule = .{
            .execution_model = .concurrent_threadpool,
        },
    };

    comptime validateWorldConfig(cfg);
    comptime validateSchedulerConfig(cfg);
}

test "valid config with needs_io system" {
    // Use module-level comptime config (SystemDef requires comptime for []const type fields)
    comptime validateWorldConfig(needs_io_config);
}

// ============================================================================
// Manual Comptime Error Tests
// ============================================================================
//
// These tests verify that invalid configs produce compile errors.
// Uncomment ONE AT A TIME to verify the expected error message.
// Each should fail to compile with the documented error.

// --- Error 1: entity_index_bits out of range (too low) ---
// Expected: "WorldConfig: entity_index_bits must be between 8 and 24 (inclusive)"
//
// test "comptime error: entity_index_bits too low" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .options = .{ .entity_index_bits = 7 }, // Invalid: < 8
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 2: entity_index_bits out of range (too high) ---
// Expected: "WorldConfig: entity_index_bits must be between 8 and 24 (inclusive)"
//
// test "comptime error: entity_index_bits too high" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .options = .{ .entity_index_bits = 25 }, // Invalid: > 24
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 3: max_entities = 0 ---
// Expected: "WorldConfig: max_entities must be greater than zero"
//
// test "comptime error: zero max_entities" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .options = .{ .max_entities = 0 }, // Invalid
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 4: max_entities exceeds bit width ---
// Expected: "WorldConfig: max_entities exceeds capacity of entity_index_bits"
//
// test "comptime error: max_entities exceeds bit width" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .options = .{
//             .entity_index_bits = 8,
//             .max_entities = 300, // Invalid: 300 > 255 (max for 8 bits)
//         },
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 5: No phases defined ---
// Expected: "WorldConfig: at least one phase must be defined"
//
// test "comptime error: no phases" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .phases = .{ .phases = &.{} }, // Invalid: empty
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 6: fixed_rate without target_hz ---
// Expected: "WorldConfig: fixed_rate tick mode requires target_hz to be set"
//
// test "comptime error: fixed_rate without hz" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .tick = .{
//             .mode = .fixed_rate,
//             .target_hz = null, // Invalid: required
//         },
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 7: single_archetype with multiple archetypes ---
// Expected: "WorldConfig: single_archetype layout_mode requires exactly one archetype definition"
//
// test "comptime error: single_archetype with multiple" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{ Position, Velocity } },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "a", .components = &.{Position} },
//             .{ .name = "b", .components = &.{Velocity} },
//         } },
//         .options = .{ .layout_mode = .single_archetype }, // Invalid
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 8: Archetype component not in spec ---
// Expected: "WorldConfig: archetype 'bad' references component not in ComponentsSpec"
//
// test "comptime error: archetype component not in spec" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} }, // Only Position
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "bad", .components = &.{ Position, Velocity } }, // Velocity not in spec
//         } },
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 9: System component not in spec ---
// Expected: "WorldConfig: system 'bad' read_components references component not in ComponentsSpec"
//
// test "comptime error: system component not in spec" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .systems = .{
//             .systems = &.{
//                 .{
//                     .name = "bad",
//                     .func = asSystemFn(dummySystem),
//                     .read_components = &.{Velocity}, // Not in spec
//                 },
//             },
//         },
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 10: System invalid phase index ---
// Expected: "WorldConfig: system 'bad' references invalid phase index"
//
// test "comptime error: invalid phase index" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "entity", .components = &.{Position} },
//         } },
//         .systems = .{
//             .systems = &.{
//                 .{
//                     .name = "bad",
//                     .func = asSystemFn(dummySystem),
//                     .phase = 99, // Invalid: > phase count
//                 },
//             },
//         },
//     };
//     comptime validateWorldConfig(cfg);
// }

// --- Error 11: Duplicate archetypes ---
// Expected: "WorldConfig: duplicate archetype definitions with same component set: 'a' and 'b'"
//
// test "comptime error: duplicate archetypes" {
//     const cfg = WorldConfig{
//         .components = .{ .types = &.{Position} },
//         .archetypes = .{ .archetypes = &.{
//             .{ .name = "a", .components = &.{Position} },
//             .{ .name = "b", .components = &.{Position} }, // Same components as 'a'
//         } },
//     };
//     comptime validateWorldConfig(cfg);
// }
