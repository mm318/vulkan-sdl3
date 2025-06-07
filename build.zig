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
    if (target.result.os.tag == .emscripten) {
        // Build for the Web.
        const dvui_sdl3_mod = dvui_dep.module("sdl3");

        if (b.sysroot) |sysroot| {
            const path: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) };
            exe_mod.addSystemIncludePath(path);
            dvui_sdl3_mod.addSystemIncludePath(path);
        } else {
            std.log.err("'--sysroot' is required when building for Emscripten", .{});
            std.process.exit(1);
        }

        const app_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "game_of_life",
            .root_module = exe_mod,
        });
        app_lib.want_lto = want_lto;

        const run_emcc = b.addSystemCommand(&.{"emcc"});

        // Pass 'app_lib' and any static libraries it links with as input files.
        // 'app_lib.getCompileDependencies()' will always return 'app_lib' as the first element.
        for (app_lib.getCompileDependencies(false)) |lib| {
            if (lib.isStaticLibrary()) {
                run_emcc.addArtifactArg(lib);
            }
        }

        run_emcc.addArgs(&.{
            // I need more memory
            "-sALLOW_MEMORY_GROWTH=1",
            "-sSTACK_SIZE=8mb",
            "-sENVIRONMENT=web",
            // fixes Aborted(Cannot use convertFrameToPC (needed by __builtin_return_address) without -sUSE_OFFSET_CONVERTER)
            "-sUSE_OFFSET_CONVERTER=1",
            // doesn't work in nixpkgs
            // see https://github.com/NixOS/nixpkgs/issues/323598
            "-sMINIFY_HTML=0",
            // "-sSTB_IMAGE=1", // TODO: try to use this instaed of what dvui provides?
        });

        if (target.result.cpu.arch == .wasm64) {
            run_emcc.addArg("-sMEMORY64");
        }

        run_emcc.addArgs(switch (optimize) {
            .Debug => &.{
                "-O0",
                // Preserve DWARF debug information.
                "-g",
                // Use UBSan (full runtime).
                "-fsanitize=undefined",
            },
            .ReleaseSafe => &.{
                "-O3",
                // Use UBSan (minimal runtime).
                "-fsanitize=undefined",
                "-fsanitize-minimal-runtime",
                "-sSAFE_HEAP=2",
                "-sASSERTIONS=2",
                "-sSTACK_OVERFLOW_CHECK=2",
                "-sMALLOC='emmalloc-memvalidate'",
                "-sABORTING_MALLOC=0",
            },
            .ReleaseFast => &.{
                "-O3",
            },
            .ReleaseSmall => &.{
                "-Oz",
            },
        });

        if (optimize != .Debug) {
            run_emcc.addArg("-flto");
            // Fails with ERROR - [JSC_UNDEFINED_VARIABLE] variable _free is undeclared
            // https://qa.fmod.com/t/errors-optimizing-with-closure-compiler-emscripten/20366?
            // run_emcc.addArgs(&.{ "--closure", "1" });
        }

        // Patch the default HTML shell.
        run_emcc.addArg("--pre-js");
        run_emcc.addFileArg(b.addWriteFiles().add("pre.js", (
            // Display messages printed to stderr.
            \\Module['printErr'] ??= Module['print'];
            \\
        )));

        run_emcc.addArg("-o");
        const app_html = run_emcc.addOutputFileArg("game_of_life.html");

        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = app_html.dirname(),
            .install_dir = .{ .custom = "www" },
            .install_subdir = "",
        }).step);

        const run_emrun = b.addSystemCommand(&.{"emrun"});
        run_emrun.addArg(b.pathJoin(&.{ b.install_path, "www", "game_of_life.html" }));
        if (b.args) |args| run_emrun.addArgs(args);
        run_emrun.step.dependOn(b.getInstallStep());

        run_step.dependOn(&run_emrun.step);
    } else {
        const exe = b.addExecutable(.{
            .name = "game_of_life",
            .root_module = exe_mod,
        });
        exe.want_lto = want_lto;

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);
    }

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

        const bench_tests = b.addTest(.{ .root_module = bench_mod });
        const run_bench_tests = b.addRunArtifact(bench_tests);
        test_step.dependOn(&run_bench_tests.step);
    }
}
