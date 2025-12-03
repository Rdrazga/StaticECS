//! Entity and system definition types for StaticECS configuration.
//!
//! This module defines types for declaring:
//! - Archetype structures (component sets)
//! - System metadata and function references
//!
//! Type Safety: System function pointers use TypedFnPtr for debug-mode
//! verification of context types. This catches type mismatches in debug
//! builds while having zero overhead in release builds.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core_types.zig");

// Re-export dependencies used in public API
pub const AsynchronyKind = core.AsynchronyKind;
pub const ParallelismMode = core.ParallelismMode;
pub const TypedContext = core.TypedContext;

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

// ============================================================================
// Type-Safe Function Pointer
// ============================================================================

/// TypedFnPtr provides debug-mode type verification for function pointers.
///
/// This wrapper addresses the type-safety issue with storing system functions
/// as `*const anyopaque`:
/// - Zero overhead in release builds (no type info storage)
/// - Debug-mode verification of expected context parameter type
/// - Compile-time validation via asSystemFn()
///
/// Tiger_Style: Fail-fast on type mismatches in debug builds.
pub const TypedFnPtr = struct {
    /// The opaque function pointer.
    ptr: *const anyopaque,
    /// Expected context type name (debug/safe builds only).
    context_type_name: DebugTypeName,

    /// In debug/safe builds, store the context type name for verification.
    /// In release builds, this is void (zero size).
    const DebugTypeName = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
        []const u8
    else
        void;

    /// Get the raw function pointer for invocation.
    pub fn rawPtr(self: TypedFnPtr) *const anyopaque {
        return self.ptr;
    }

    /// Get the expected context type name (debug/safe builds only).
    /// Returns null in release builds.
    pub fn getContextTypeName(self: TypedFnPtr) ?[]const u8 {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            return self.context_type_name;
        }
        return null;
    }

    /// Verify that the context type matches the expected type.
    /// In debug/safe builds, panics on mismatch.
    /// In release builds, this is a no-op.
    pub fn verifyContextType(self: TypedFnPtr, comptime T: type) void {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            const expected = @typeName(T);
            if (!std.mem.eql(u8, self.context_type_name, expected)) {
                std.debug.panic(
                    "TypedFnPtr context type mismatch: expected '{s}', function expects '{s}'",
                    .{ expected, self.context_type_name },
                );
            }
        }
    }
};

// ============================================================================
// System Definition
// ============================================================================

/// SystemDef defines a single system's metadata.
pub const SystemDef = struct {
    name: []const u8,
    /// Pointer to the system function with debug-mode type verification.
    /// Use `asSystemFn` to safely convert a typed function to this field.
    /// In debug builds, stores the expected context parameter type.
    func: TypedFnPtr,
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

/// Compile-time helper to validate and convert a system function to a TypedFnPtr.
/// This provides type-safety at the configuration site and debug-mode verification.
///
/// The function must have one of these signatures:
/// - `fn(*anyopaque) FrameError!void` (legacy, no compile-time type checking)
/// - `fn(*SystemContext) FrameError!void` (preferred, where SystemContext is any type)
///
/// In debug/safe builds, the expected context type is stored for runtime verification.
/// In release builds, this has zero overhead.
///
/// Usage in WorldConfig:
/// ```zig
/// .func = asSystemFn(mySystem),
/// ```
pub fn asSystemFn(comptime func: anytype) TypedFnPtr {
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

    // Extract the context type (what the pointer points to)
    const context_type = param_info.pointer.child;

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

    // Compute context_type_name at comptime to ensure the entire result is comptime-known
    const context_type_name: TypedFnPtr.DebugTypeName = comptime blk: {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            break :blk @typeName(context_type);
        } else {
            break :blk {};
        }
    };

    return comptime .{
        .ptr = @ptrCast(&func),
        .context_type_name = context_type_name,
    };
}

/// @deprecated Use asSystemFn() which returns TypedFnPtr.
/// Creates a raw function pointer without type verification.
/// Maintained for backward compatibility with code using .func = @ptrCast(...).
pub fn asSystemFnUnsafe(comptime func: anytype) TypedFnPtr {
    const context_type_name: TypedFnPtr.DebugTypeName = comptime blk: {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            break :blk "(unsafe - no type checking)";
        } else {
            break :blk {};
        }
    };

    return comptime .{
        .ptr = @ptrCast(&func),
        .context_type_name = context_type_name,
    };
}
