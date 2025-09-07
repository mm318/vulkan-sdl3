const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Warning LTO breaks emscripten web target
    const want_lto = b.option(bool, "lto", "enable lto");
    const benchmark = b.option(bool, "benchmark", "run benchmarks") orelse false;

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    const dvui_mod = dvui_dep.module("dvui_sdl3");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .emscripten,
    });
    exe_mod.addImport("dvui", dvui_mod);

    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.systemIntegrationOption("sdl3", .{})) {
        exe_mod.linkSystemLibrary("SDL3", .{});
    } else {
        if (dvui_dep.builder.lazyDependency("sdl3", .{
            .target = target,
            .optimize = optimize,
        })) |sdl3| {
            exe_mod.linkLibrary(sdl3.artifact("SDL3"));
        }
    }

    const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "game_of_life",
            .root_module = exe_mod,
        });
        if (want_lto != null and want_lto.?) {
            exe.lto = .thin;
        }

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_test_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    if (benchmark) {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (b.lazyDependency("zbench", .{
            .target = target,
            .optimize = optimize,
        })) |zbench| {
            bench_mod.addImport("zbench", zbench.module("zbench"));
        }

        const bench_exe = b.addExecutable(.{
            .name = "bechmark",
            .root_module = bench_mod,
        });
        b.installArtifact(bench_exe);

        const bench_tests = b.addTest(.{ .root_module = bench_mod });
        const run_bench_tests = b.addRunArtifact(bench_tests);
        test_step.dependOn(&run_bench_tests.step);
    }
}
