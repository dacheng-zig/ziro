const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_stack_size = b.option(usize, "ziro_default_stack_size", "Default stack size for coroutines") orelse 1024 * 4;
    const debug_log_level = b.option(usize, "ziro_debug_log_level", "Debug log level for coroutines") orelse 0;

    // xev dependency for async io
    const xev = b.dependency("libxev", .{}).module("xev");

    // create dynamic module 'ziro_options'
    const ziro_options = b.addOptions();
    ziro_options.addOption(usize, "default_stack_size", default_stack_size);
    ziro_options.addOption(usize, "debug_log_level", debug_log_level);
    const ziro_options_module = ziro_options.createModule();

    const ziro = b.addModule("ziro", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "xev", .module = xev },
            .{ .name = "ziro_options", .module = ziro_options_module },
        },
    });

    {
        const ziro_test = b.addTest(.{
            .name = "zirotest",
            .root_source_file = b.path("src/ziro_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        ziro_test.root_module.addImport("ziro", ziro);
        ziro_test.linkLibC();

        const ziro_test_internal = b.addTest(.{
            .name = "zirotest-internal",
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        ziro_test_internal.root_module.addImport("ziro_options", ziro_options_module);
        ziro_test_internal.linkLibC();

        const test_step = b.step("test-ziro", "Run tests");
        test_step.dependOn(&b.addRunArtifact(ziro_test).step);
        test_step.dependOn(&b.addRunArtifact(ziro_test_internal).step);
    }

    {
        const aio_test = b.addTest(.{
            .name = "aiotest",
            .root_source_file = b.path("src/asyncio_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        aio_test.root_module.addImport("ziro", ziro);
        aio_test.root_module.addImport("xev", xev);
        aio_test.linkLibC();

        const test_step = b.step("test-aio", "Run async io tests");
        test_step.dependOn(&b.addRunArtifact(aio_test).step);
    }

    {
        const bench = b.addExecutable(.{
            .name = "benchmark",
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench.root_module.addImport("ziro", ziro);
        bench.linkLibC();

        const bench_run = b.addRunArtifact(bench);
        if (b.args) |args| {
            bench_run.addArgs(args);
        }

        const bench_step = b.step("benchmark", "Run benchmark");
        bench_step.dependOn(&bench_run.step);
        bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
    }

    {
        const example_exe = b.addExecutable(.{
            .name = "example-http",
            .root_source_file = b.path("examples/http.zig"),
            .target = target,
            .optimize = optimize,
        });
        example_exe.root_module.addImport("ziro", ziro);
        example_exe.root_module.addImport("xev", xev);
        example_exe.linkLibC();

        const sleep_run = b.addRunArtifact(example_exe);
        if (b.args) |args| {
            sleep_run.addArgs(args);
        }

        const example_step = b.step("example-http", "Run http example");
        example_step.dependOn(&sleep_run.step);
        example_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
    }

    {
        const sleep_example = b.addExecutable(.{
            .name = "example-sleep",
            .root_source_file = b.path("examples/sleep.zig"),
            .target = target,
            .optimize = optimize,
        });
        sleep_example.root_module.addImport("ziro", ziro);
        sleep_example.root_module.addImport("xev", xev);
        sleep_example.linkLibC();

        const sleep_run = b.addRunArtifact(sleep_example);
        if (b.args) |args| {
            sleep_run.addArgs(args);
        }

        const sleep_step = b.step("example-sleep", "Run sleep example");
        sleep_step.dependOn(&sleep_run.step);
        sleep_step.dependOn(&b.addInstallArtifact(sleep_example, .{}).step);
    }
}
