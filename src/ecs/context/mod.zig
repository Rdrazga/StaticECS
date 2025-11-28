//! Context Module - Re-exports for System Context Components
//!
//! This module provides centralized re-exports for all context-related types:
//! - Command types and buffers for deferred operations
//! - Resources for type-safe global singleton storage
//! - I/O context for async operation capabilities
//! - Concurrent command buffers for parallel execution

// ============================================================================
// Command Types
// ============================================================================

pub const command_types = @import("command_types.zig");

/// A deferred command to be executed after system iteration.
pub const CommandType = command_types.CommandType;

/// Spawn command with configurable data size.
pub const SpawnCommandType = command_types.SpawnCommandType;

/// Set component command with configurable data size.
pub const SetComponentCommandType = command_types.SetComponentCommandType;

/// Custom command type (size-independent).
pub const CustomCommand = command_types.CustomCommand;

/// Default maximum size for inline component data in commands.
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE = command_types.DEFAULT_MAX_COMPONENT_DATA_SIZE;

/// Legacy type alias for backward compatibility with default size.
pub const Command = command_types.Command;

/// Generate a unique component type ID at compile time.
pub const componentTypeId = command_types.componentTypeId;

// ============================================================================
// Command Buffer
// ============================================================================

pub const command_buffer = @import("command_buffer.zig");

/// Command buffer for collecting deferred operations during system execution.
pub const CommandBufferType = command_buffer.CommandBufferType;

/// Legacy CommandBuffer with default component data size.
pub const CommandBuffer = command_buffer.CommandBuffer;

// ============================================================================
// Concurrent Commands
// ============================================================================

pub const concurrent_commands = @import("concurrent_commands.zig");

/// Per-system command buffers for concurrent execution.
pub const ConcurrentCommandBuffers = concurrent_commands.ConcurrentCommandBuffers;

/// Create ConcurrentCommandBuffers type from WorldConfig.
pub const ConcurrentCommandBuffersFromConfig = concurrent_commands.ConcurrentCommandBuffersFromConfig;

// ============================================================================
// Resources
// ============================================================================

pub const resources = @import("resources.zig");

/// Resources provides access to global singleton data.
pub const Resources = resources.Resources;

// ============================================================================
// I/O Context
// ============================================================================

pub const io_context = @import("io_context.zig");

/// IoContext provides I/O capabilities to systems that need them.
pub const IoContext = io_context.IoContext;

/// Error type for I/O context operations.
pub const IoError = io_context.IoError;

/// Re-export IoBackend types for convenience.
pub const IoBackend = io_context.IoBackend;
pub const IoBackendError = io_context.IoBackendError;
pub const BackendOptions = io_context.BackendOptions;

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all submodule tests
    _ = command_types;
    _ = command_buffer;
    _ = concurrent_commands;
    _ = resources;
    _ = io_context;
}
