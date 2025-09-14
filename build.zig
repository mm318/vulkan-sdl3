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
        .backend = .custom,
    });

    const sdl3_dep = dvui_dep.builder.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    const dvui_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/dvui_backend/sdl3_vk.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_backend_mod.linkLibrary(sdl3_dep.artifact("SDL3"));

    const dvui_mod = dvui_dep.module("dvui");
    @import("dvui").linkBackend(dvui_mod, dvui_backend_mod);

    const vulkan_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/VulkanEngine.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile_all_shaders(b, vulkan_engine_mod);
    vulkan_engine_mod.linkLibrary(sdl3_dep.artifact("SDL3"));
    vulkan_engine_mod.addImport("dvui", dvui_mod);
    vulkan_engine_mod.addImport("dvui_backend", dvui_backend_mod);
    vulkan_engine_mod.addIncludePath(b.path("src/vulkan/"));
    vulkan_engine_mod.addCSourceFile(.{ .file = b.path("src/vulkan/vk_mem_alloc.cpp") });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .emscripten,
    });
    exe_mod.addImport("vulkan_engine", vulkan_engine_mod);

    const exe = b.addExecutable(.{
        .name = "game_of_life",
        .root_module = exe_mod,
    });
    if (want_lto != null and want_lto.?) {
        exe.lto = .thin;
    }
    exe.linkLibCpp();
    exe.linkSystemLibrary(if (target.result.os.tag == .windows) "vulkan-1" else "vulkan");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
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

fn compile_all_shaders(b: *std.Build, mod: *std.Build.Module) void {
    const shaders_dir = b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                add_shader(b, mod, name);
            }
        }
    }
}

fn add_shader(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    mod.addAnonymousImport(name, .{ .root_source_file = output });
}
