const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main ECS library module
    _ = b.addModule("static-ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Documentation generation
    const docs_obj = b.addObject(.{
        .name = "static-ecs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ======================================================================
    // Examples
    // ======================================================================

    // ECS module for examples
    const ecs_module = b.addModule("ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Game Loop Example
    const game_example = b.addExecutable(.{
        .name = "example-game-loop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/game-loop/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_module },
            },
        }),
    });
    b.installArtifact(game_example);

    const run_game_example = b.addRunArtifact(game_example);
    run_game_example.step.dependOn(b.getInstallStep());

    const run_game_step = b.step("run-example-game", "Run the game loop example");
    run_game_step.dependOn(&run_game_example.step);

    // HTTP Server Example
    const http_example = b.addExecutable(.{
        .name = "example-http-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http-server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_module },
            },
        }),
    });
    b.installArtifact(http_example);

    const run_http_example = b.addRunArtifact(http_example);
    run_http_example.step.dependOn(b.getInstallStep());

    const run_http_step = b.step("run-example-server", "Run the HTTP server example");
    run_http_step.dependOn(&run_http_example.step);

    // Data Pipeline Example
    const pipeline_example = b.addExecutable(.{
        .name = "example-data-pipeline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/data-pipeline/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_module },
            },
        }),
    });
    b.installArtifact(pipeline_example);

    const run_pipeline_example = b.addRunArtifact(pipeline_example);
    run_pipeline_example.step.dependOn(b.getInstallStep());

    const run_pipeline_step = b.step("run-example-pipeline", "Run the data pipeline example");
    run_pipeline_step.dependOn(&run_pipeline_example.step);

    // Build all examples
    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(&game_example.step);
    examples_step.dependOn(&http_example.step);
    examples_step.dependOn(&pipeline_example.step);

    // ======================================================================
    // Benchmark Step
    // ======================================================================
    //
    // Benchmark step:
    //   zig build benchmark          - Run all benchmarks
    //   zig build benchmark -- -h    - Show benchmark options (if implemented)
    //
    // Note: Benchmarks always run with ReleaseFast optimization
    // regardless of the -Doptimize flag to ensure consistent timing.
    //
    // Reference: TC-L1 issue - benchmarks must run in ReleaseFast mode for
    // accurate performance measurements, not debug mode.

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always ReleaseFast for accurate benchmarks
        }),
    });
    b.installArtifact(benchmark_exe);

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    run_benchmark.step.dependOn(b.getInstallStep());

    // Allow passing args to benchmark
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    const benchmark_step = b.step("benchmark", "Run performance benchmarks in ReleaseFast mode");
    benchmark_step.dependOn(&run_benchmark.step);
}
