//! Entity and system definition types for StaticECS configuration.
//!
//! This module defines types for declaring:
//! - Archetype structures (component sets)
//! - System metadata and function references

const core = @import("core_types.zig");

// Re-export dependencies used in public API
pub const AsynchronyKind = core.AsynchronyKind;
pub const ParallelismMode = core.ParallelismMode;

// ============================================================================
// Archetype Definition
// ============================================================================

/// ArchetypeDef defines a single archetype's structure.
pub const ArchetypeDef = struct {
    /// Symbolic identifier for diagnostics and APIs (sentinel-terminated for struct field names).
    name: [:0]const u8,
    /// Subset of ComponentsSpec.types stored in this archetype.
    components: []const type,
};

// ============================================================================
// System Definition
// ============================================================================

/// SystemDef defines a single system's metadata.
pub const SystemDef = struct {
    name: []const u8,
    /// Pointer to the system function.
    /// Use `asSystemFn` to safely convert a typed function to this field.
    func: *const anyopaque,
    /// Phase index (0-based, into WorldConfig.phases).
    /// Default is 1 which maps to "update" in DEFAULT_PHASES.
    /// Use Phase enum for convenience: `.phase = Phase.update.index()`
    phase: u8 = 1,
    asynchrony: AsynchronyKind = .none,
    parallelism: ParallelismMode = .none,
    read_components: []const type = &.{},
    write_components: []const type = &.{},
    /// Whether this system requires I/O context for async operations.
    /// When true, the system can access IoContext via ctx.getIo().
    /// Requires ExecutionModel other than blocking_single_thread.
    needs_io: bool = false,
};

/// Compile-time helper to validate and convert a system function to the opaque pointer.
/// This provides type-safety at the configuration site.
///
/// The function must have one of these signatures:
/// - `fn(*anyopaque) FrameError!void` (legacy, no compile-time type checking)
/// - `fn(*SystemContext) FrameError!void` (preferred, where SystemContext is any type)
///
/// Usage in WorldConfig:
/// ```zig
/// .func = asSystemFn(mySystem),
/// ```
pub fn asSystemFn(comptime func: anytype) *const anyopaque {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn);

    if (fn_info != .@"fn" and fn_info != .pointer) {
        @compileError("asSystemFn: expected a function, got " ++ @typeName(Fn));
    }

    // For function pointers, get the underlying function type
    const actual_fn_info = if (fn_info == .pointer)
        @typeInfo(fn_info.pointer.child)
    else
        fn_info;

    if (actual_fn_info != .@"fn") {
        @compileError("asSystemFn: expected a function type");
    }

    const params = actual_fn_info.@"fn".params;

    // Validate: must have exactly 1 parameter (the context)
    if (params.len != 1) {
        @compileError("asSystemFn: system function must have exactly 1 parameter (context pointer)");
    }

    // Validate: parameter must be a pointer
    const param_type = params[0].type orelse
        @compileError("asSystemFn: parameter type must be known at compile time");

    const param_info = @typeInfo(param_type);
    if (param_info != .pointer) {
        @compileError("asSystemFn: first parameter must be a pointer type");
    }

    // Validate: return type must be FrameError!void or just void
    // (We allow void for systems that never fail)
    const return_type = actual_fn_info.@"fn".return_type orelse
        @compileError("asSystemFn: return type must be known at compile time");

    const return_info = @typeInfo(return_type);
    switch (return_info) {
        .void => {}, // OK: system never fails
        .error_union => {
            // OK: system may fail - payload should be void
            if (return_info.error_union.payload != void) {
                @compileError("asSystemFn: system must return FrameError!void or void, not " ++ @typeName(return_type));
            }
        },
        else => {
            @compileError("asSystemFn: system must return FrameError!void or void, not " ++ @typeName(return_type));
        },
    }

    return @ptrCast(&func);
}
