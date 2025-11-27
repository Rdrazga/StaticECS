//! StaticECS Version Information
//!
//! This module provides version constants and helpers for the StaticECS library.

const std = @import("std");

/// Semantic version structure.
pub const SemanticVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre_release: ?[]const u8 = null,
    build_metadata: ?[]const u8 = null,

    /// Format version as a string "major.minor.patch[-pre][+build]"
    pub fn format(
        self: SemanticVersion,
        writer: anytype,
    ) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });

        if (self.pre_release) |pre| {
            try writer.print("-{s}", .{pre});
        }
        if (self.build_metadata) |build| {
            try writer.print("+{s}", .{build});
        }
    }

    /// Returns a compile-time string representation.
    pub fn toString(comptime self: SemanticVersion) []const u8 {
        comptime {
            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            self.format(fbs.writer()) catch unreachable;
            const written = fbs.getWritten();
            var result: [written.len]u8 = undefined;
            @memcpy(&result, written);
            return &result;
        }
    }

    /// Check if this version is compatible with another (same major, >= minor).
    pub fn isCompatibleWith(self: SemanticVersion, other: SemanticVersion) bool {
        if (self.major != other.major) return false;
        if (self.major == 0) {
            // Pre-1.0: minor version changes may be breaking
            return self.minor == other.minor and self.patch >= other.patch;
        }
        // Post-1.0: same major, self.minor >= other.minor
        return self.minor >= other.minor or
            (self.minor == other.minor and self.patch >= other.patch);
    }

    /// Compare two versions. Returns negative if self < other, 0 if equal, positive if self > other.
    pub fn compare(self: SemanticVersion, other: SemanticVersion) i32 {
        if (self.major != other.major) {
            return if (self.major < other.major) -1 else 1;
        }
        if (self.minor != other.minor) {
            return if (self.minor < other.minor) -1 else 1;
        }
        if (self.patch != other.patch) {
            return if (self.patch < other.patch) -1 else 1;
        }
        return 0;
    }
};

/// The current version of the StaticECS library.
pub const ECS_VERSION = SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
    .pre_release = "alpha",
};

/// String representation of the current version.
pub const ECS_VERSION_STRING = ECS_VERSION.toString();

/// Check if a pinned version from WorldConfig is compatible with the current ECS version.
pub fn checkVersionCompatibility(
    pinned: ?struct { major: u32, minor: u32, patch: u32 },
) bool {
    if (pinned) |pin| {
        const pinned_version = SemanticVersion{
            .major = pin.major,
            .minor = pin.minor,
            .patch = pin.patch,
        };
        return ECS_VERSION.isCompatibleWith(pinned_version);
    }
    return true; // No pin means any version is acceptable
}

// ============================================================================
// Tests
// ============================================================================

test "SemanticVersion formatting" {
    const v = SemanticVersion{ .major = 1, .minor = 2, .patch = 3 };
    var buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{f}", .{v}) catch unreachable;
    try std.testing.expectEqualStrings("1.2.3", result);
}

test "SemanticVersion with pre-release" {
    const v = SemanticVersion{ .major = 0, .minor = 1, .patch = 0, .pre_release = "alpha" };
    var buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{f}", .{v}) catch unreachable;
    try std.testing.expectEqualStrings("0.1.0-alpha", result);
}

test "SemanticVersion compatibility" {
    const v1_0_0 = SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };
    const v1_1_0 = SemanticVersion{ .major = 1, .minor = 1, .patch = 0 };
    const v1_0_1 = SemanticVersion{ .major = 1, .minor = 0, .patch = 1 };
    const v2_0_0 = SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };

    // Same major, higher minor is compatible
    try std.testing.expect(v1_1_0.isCompatibleWith(v1_0_0));
    // Same major, same minor, higher patch is compatible
    try std.testing.expect(v1_0_1.isCompatibleWith(v1_0_0));
    // Different major is not compatible
    try std.testing.expect(!v2_0_0.isCompatibleWith(v1_0_0));
}

test "SemanticVersion compare" {
    const v1 = SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };
    const v2 = SemanticVersion{ .major = 1, .minor = 1, .patch = 0 };
    const v3 = SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expect(v1.compare(v2) < 0);
    try std.testing.expect(v2.compare(v1) > 0);
    try std.testing.expect(v1.compare(v1) == 0);
    try std.testing.expect(v1.compare(v3) < 0);
}

test "checkVersionCompatibility" {
    // No pin is always compatible
    try std.testing.expect(checkVersionCompatibility(null));

    // Pin matching current version
    try std.testing.expect(checkVersionCompatibility(.{
        .major = ECS_VERSION.major,
        .minor = ECS_VERSION.minor,
        .patch = ECS_VERSION.patch,
    }));
}
