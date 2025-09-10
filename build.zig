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

    if (dvui_dep.builder.lazyDependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    })) |sdl3| {
        exe_mod.linkLibrary(sdl3.artifact("SDL3"));
    }

    const exe = b.addExecutable(.{
        .name = "game_of_life",
        .root_module = exe_mod,
    });
    if (want_lto != null and want_lto.?) {
        exe.lto = .thin;
    }
    exe.addIncludePath(b.path("src/vulkan/"));
    exe.addCSourceFile(.{ .file = b.path("src/vulkan/vk_mem_alloc.cpp") });
    compile_all_shaders(b, exe);
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

fn compile_all_shaders(b: *std.Build, exe: *std.Build.Step.Compile) void {
    // This is a fix for a change between zig 0.11 and 0.12

    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir("shaders", .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                add_shader(b, exe, name);
            }
        }
    }
}

fn add_shader(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    exe.root_module.addAnonymousImport(name, .{ .root_source_file = output });
}
