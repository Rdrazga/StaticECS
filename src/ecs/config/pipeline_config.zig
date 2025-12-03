//! Pipeline configuration types for StaticECS (Phase 6).
//!
//! This module defines entity flow pipeline configurations:
//! - Internal: ECS manages entity lifecycle
//! - External: User manages entity flow with batch APIs
//! - Hybrid: Fast-path bypass for simple entities

// ============================================================================
// Pipeline Mode
// ============================================================================

/// Pipeline entity flow mode.
/// Determines how entities flow through processing stages.
/// Tiger Style: Mode selection at comptime enables zero-cost abstractions.
pub const PipelineMode = enum {
    /// ECS manages entity lifecycle internally.
    /// Entities flow through phases automatically.
    /// Best for: complex state machines, game-like processing.
    internal,

    /// User code manages entity flow externally.
    /// ECS provides batch import/export APIs.
    /// Best for: high-throughput pipelines, event streams.
    external,

    /// Hybrid mode with fast-path bypass.
    /// Simple entities bypass ECS, complex use full pipeline.
    /// Best for: HTTP servers, mixed workloads.
    hybrid,
};

// ============================================================================
// External Pipeline Configuration
// ============================================================================

/// External pipeline configuration.
/// Controls batch sizes and buffer capacities for external mode.
/// Tiger Style: All bounds configurable.
pub const ExternalPipelineConfig = struct {
    /// Maximum batch size for import/export operations.
    /// Default 256 balances memory usage with batching efficiency.
    batch_size: u32 = 256,

    /// Enable zero-copy imports when possible.
    /// When true, avoids copying component data during import.
    zero_copy: bool = true,

    /// Export buffer capacity (max entities buffered for export).
    /// Default 4096 allows high throughput.
    export_buffer_size: u32 = 4096,

    /// Import buffer capacity (max entities buffered for import).
    /// Default 4096 allows high throughput.
    import_buffer_size: u32 = 4096,
};

// ============================================================================
// Hybrid Pipeline Configuration
// ============================================================================

const std = @import("std");

/// Default fast-path predicate that rejects all entities.
/// Users should provide their own predicate for actual fast-path logic.
pub const DefaultFastPathPredicate = struct {
    /// Returns true if entity data can use fast-path processing.
    /// Default implementation returns false (no fast-path).
    pub fn canFastPath(entity_data: anytype) bool {
        _ = entity_data;
        return false;
    }
};

// ============================================================================
// Input Data Mapper Types
// ============================================================================

/// Default input data mapper for ECS fallback.
/// Zero-initializes components (backward-compatible behavior).
/// Users can provide custom mappers for specific component layouts.
///
/// Tiger Style: Comptime mapper type allows zero overhead when not mapping.
pub const DefaultInputDataMapper = struct {
    /// Map input data to component values.
    /// Default implementation returns zero-initialized components.
    pub fn mapInputToComponents(comptime ComponentTypes: []const type, input: anytype) Tuple(ComponentTypes) {
        _ = input;
        var result: Tuple(ComponentTypes) = undefined;
        inline for (0..ComponentTypes.len) |i| {
            result[i] = std.mem.zeroes(ComponentTypes[i]);
        }
        return result;
    }

    fn Tuple(comptime types: []const type) type {
        return std.meta.Tuple(types);
    }
};

/// Standard raw data component for storing unmapped input.
/// Include this in your archetype to preserve raw input data.
pub const RawInputData = struct {
    /// Raw input bytes (first 256 bytes).
    data: [256]u8 = undefined,
    /// Length of valid data.
    len: u32 = 0,
    /// User-defined flags from input.
    flags: u32 = 0,
};

/// Input data mapper that stores raw bytes in a RawInputData component.
/// Use when archetype contains RawInputData component.
///
/// Example:
/// ```zig
/// const config = WorldConfig{
///     .components = .{ .types = &.{ RawInputData, Position } },
///     .archetypes = .{ .archetypes = &.{
///         .{ .name = "raw_entity", .components = &.{ RawInputData, Position } },
///     }},
///     .pipeline = .{
///         .mode = .hybrid,
///         .hybrid = .{
///             .input_data_mapper_type = RawInputDataMapper,
///         },
///     },
/// };
/// ```
pub const RawInputDataMapper = struct {
    /// Map input data to component values, storing raw bytes in RawInputData if present.
    pub fn mapInputToComponents(comptime ComponentTypes: []const type, input: anytype) Tuple(ComponentTypes) {
        var result: Tuple(ComponentTypes) = undefined;
        inline for (0..ComponentTypes.len) |i| {
            const CompType = ComponentTypes[i];
            if (CompType == RawInputData) {
                // Map input to RawInputData component
                result[i] = mapToRawInputData(input);
            } else {
                // Zero-initialize other components
                result[i] = std.mem.zeroes(CompType);
            }
        }
        return result;
    }

    fn mapToRawInputData(input: anytype) RawInputData {
        var raw: RawInputData = .{};
        // Check if input has the expected fields
        if (@hasField(@TypeOf(input), "data") and @hasField(@TypeOf(input), "len")) {
            const input_len = @as(usize, input.len);
            const copy_len = @min(input_len, raw.data.len);
            @memcpy(raw.data[0..copy_len], input.data[0..copy_len]);
            raw.len = @intCast(copy_len);
            if (@hasField(@TypeOf(input), "flags")) {
                raw.flags = input.flags;
            }
        }
        return raw;
    }

    fn Tuple(comptime types: []const type) type {
        return std.meta.Tuple(types);
    }
};

/// Hybrid pipeline configuration.
/// Controls fast-path behavior and fallback settings.
/// Tiger Style: Predicate type is comptime for zero overhead when not matching.
pub const HybridPipelineConfig = struct {
    /// Fast-path predicate function type.
    /// Must have `fn canFastPath(data: anytype) bool` method.
    /// Default rejects all entities (no fast-path).
    fast_path_predicate_type: type = DefaultFastPathPredicate,

    /// Maximum entities in fast-path queue per tick.
    /// Default 1024 balances throughput with memory.
    fast_path_capacity: u32 = 1024,

    /// Fallback to ECS when fast-path queue is full.
    /// When false, returns error.FastPathFull instead.
    fallback_on_full: bool = true,

    /// Input data mapper type for ECS fallback.
    /// Must have `fn mapInputToComponents(comptime []const type, input) @Tuple(types)`.
    /// Default zero-initializes components; use RawInputDataMapper to preserve input bytes.
    input_data_mapper_type: type = DefaultInputDataMapper,

    /// Buffer size for InputData in bytes.
    /// Controls the maximum payload size for fast-path inputs.
    /// Default 256 matches legacy behavior.
    /// Tiger Style: Configurable at comptime for zero overhead sizing.
    input_buffer_size: u32 = 256,

    /// Buffer size for OutputData in bytes.
    /// Controls the maximum response size for fast-path outputs.
    /// Default 256 matches legacy behavior.
    output_buffer_size: u32 = 256,
};

// ============================================================================
// Combined Pipeline Configuration
// ============================================================================

/// Pipeline configuration options.
/// Added to WorldConfig as the `pipeline` field.
/// Tiger Style: Zero overhead when using internal mode (default).
pub const PipelineConfig = struct {
    /// Pipeline mode selection.
    mode: PipelineMode = .internal,

    /// External mode settings (only used when mode == .external).
    external: ExternalPipelineConfig = .{},

    /// Hybrid mode settings (only used when mode == .hybrid).
    hybrid: HybridPipelineConfig = .{},
};
