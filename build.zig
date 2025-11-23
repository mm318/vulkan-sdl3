const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vulkan12_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv64,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .os_tag = .vulkan,
        .ofmt = .spirv,
    });

    // Warning LTO breaks emscripten web target
    const want_lto = b.option(bool, "lto", "enable lto") orelse false;

    //
    // dependencies from build.zig.zon
    //
    const zmath_dep = b.dependency("zmath", .{
        .target = target,
    });
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
    });
    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    //
    // modules
    //
    const vulkan_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/vulkan_init.zig"),
        .target = target,
        .optimize = optimize,
    });
    vulkan_mod.linkLibrary(sdl3_dep.artifact("SDL3"));
    vulkan_mod.addIncludePath(b.path("src/vulkan/"));
    vulkan_mod.addCSourceFile(.{ .file = b.path("src/vulkan/vk_mem_alloc.cpp") });

    const dvui_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/dvui_backend/sdl3_vk.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_backend_mod.addImport("vulkan", vulkan_mod);

    const dvui_mod = dvui_dep.module("dvui");
    @import("dvui").linkBackend(dvui_mod, dvui_backend_mod);

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/VulkanEngine.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_mod.addImport("vulkan", vulkan_mod);
    engine_mod.addImport("dvui", dvui_mod);
    engine_mod.addImport("dvui_backend", dvui_backend_mod);
    add_zig_shaders(b, engine_mod, vulkan12_target, zmath_dep.module("root"));
    add_glsl_shaders(b, engine_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .emscripten,
    });
    exe_mod.addImport("vulkan_engine", engine_mod);

    const exe = b.addExecutable(.{
        .name = "game_of_life",
        .root_module = exe_mod,
    });
    if (want_lto) {
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
}

fn add_zig_shaders(
    b: *std.Build,
    dest_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    zmath_mod: *std.Build.Module,
) void {
    const shaders_dir = b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".zig")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.zig", .{name}) catch @panic("OOM");
                const shader = b.addObject(.{
                    .name = name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(source),
                        .target = target,
                        .optimize = .ReleaseFast,
                    }),
                    .use_llvm = false,
                    .use_lld = false,
                });
                shader.root_module.addImport("zmath", zmath_mod);

                dest_mod.addAnonymousImport(name, .{ .root_source_file = shader.getEmittedBin() });
            }
        }
    }
}

fn add_glsl_shaders(b: *std.Build, mod: *std.Build.Module) void {
    const shaders_dir = b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                add_glsl_shader(b, mod, name);
            }
        }
    }
}

fn add_glsl_shader(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    mod.addAnonymousImport(name, .{ .root_source_file = output });
}
