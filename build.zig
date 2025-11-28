const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Warning LTO breaks emscripten web target
    const want_lto = b.option(bool, "lto", "enable lto") orelse false;

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
    });

    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

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

    var mods = [_]*std.Build.Module{ dvui_backend_mod, engine_mod };
    compile_all_shaders(b, &mods);

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

fn compile_all_shaders(b: *std.Build, mods: []*std.Build.Module) void {
    const shaders_dir = b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            const basename = std.fs.path.basename(entry.name);
            const name = basename[0 .. basename.len - ext.len];
            if (std.mem.eql(u8, ext, ".glsl")) {
                add_glsl_shader(b, mods, name);
            } else if (std.mem.eql(u8, ext, ".slang")) {
                add_slang_shader(b, mods, name);
            }
        }
    }
}

fn add_glsl_shader(b: *std.Build, mods: []*std.Build.Module, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "{s}.spv", .{name}) catch @panic("OOM");
    const shader_type = std.fs.path.extension(name);

    std.debug.print("Found GLSL shader file to compile: {s}. Compiling to file: {s}\n", .{ name, outpath });
    const shader_compilation = b.addSystemCommand(&.{ "slangc", "-target", "spirv", "-entry", "main" });
    shader_compilation.addArg("-stage");
    if (std.mem.eql(u8, shader_type, ".vert")) {
        shader_compilation.addArg("vertex");
    } else if (std.mem.eql(u8, shader_type, ".frag")) {
        shader_compilation.addArg("fragment");
    } else {
        @panic("Unknown shader type. Expected vert or frag");
    }
    shader_compilation.addArg("-o");
    const outfile = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addArgs(&.{ "-O3", "-matrix-layout-row-major" });
    shader_compilation.addFileArg(b.path(source));

    for (mods) |mod| {
        mod.addAnonymousImport(outpath, .{ .root_source_file = outfile });
    }
}

fn add_slang_shader(b: *std.Build, mods: []*std.Build.Module, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.slang", .{name}) catch @panic("OOM");
    const shader_types: []const []const u8 = &.{ ".vert", ".frag" };
    for (shader_types) |shader_type| {
        const outpath = std.fmt.allocPrint(b.allocator, "{s}{s}.spv", .{ name, shader_type }) catch @panic("OOM");

        std.debug.print("Found Slang shader file to compile: {s}. Compiling to file: {s}\n", .{ name, outpath });
        const shader_compilation = b.addSystemCommand(&.{ "slangc", "-target", "spirv" });
        shader_compilation.addArg("-entry");
        if (std.mem.eql(u8, shader_type, ".vert")) {
            shader_compilation.addArg("vertexMain");
        } else if (std.mem.eql(u8, shader_type, ".frag")) {
            shader_compilation.addArg("fragmentMain");
        } else {
            @panic("Unknown shader type. Expected vert or frag");
        }
        shader_compilation.addArg("-o");
        const outfile = shader_compilation.addOutputFileArg(outpath);
        shader_compilation.addArg("-O3");
        shader_compilation.addFileArg(b.path(source));

        for (mods) |mod| {
            mod.addAnonymousImport(outpath, .{ .root_source_file = outfile });
        }
    }
}
