const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");
const c = SDLBackend.c;

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
const gpa = gpa_instance.allocator();

const vsync = true;
const min_refresh_fps: f32 = 30.0;
const show_demo = true;
const show_debug_window = true;

const CanvasTarget = extern struct {
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
};

const basic_triangle_shaders = struct {
    const spv_raw_triangle_vert align(8) = @embedFile("shaders/RawTriangle.vert.spv").*;
    const spv_solid_color_frag align(8) = @embedFile("shaders/SolidColor.frag.spv").*;
};

const ShaderSelection = struct {
    code: []const u8,
    format: c.SDL_GPUShaderFormat,
    entrypoint: [:0]const u8,
};

var open_debug_window_next_frame = show_debug_window;
var canvas_target: ?dvui.TextureTarget = null;
var canvas_texture: ?dvui.Texture = null;

var fill_pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var line_pipeline: ?*c.SDL_GPUGraphicsPipeline = null;

var use_wireframe_mode = false;
var use_small_viewport = false;
var use_scissor_rect = false;

/// This uses the standalone dvui frame loop and ports SDL_gpu_examples/BasicTriangle:
/// - triangle draw with fill/wireframe pipeline toggle
/// - optional small viewport/scissor rect
/// - rendering goes into the main dvui canvas widget
pub fn main() !void {
    if (@import("builtin").os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

    dvui.Examples.show_demo_window = show_demo;

    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    var backend = try SDLBackend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 1600.0, .h = 1600.0 },
        .min_size = .{ .w = 320.0, .h = 240.0 },
        .vsync = vsync,
        .title = "DVUI Standalone + BasicTriangle Canvas",
    });
    defer backend.deinit();
    defer cleanupBasicTriangleResources(&backend);
    defer cleanupCanvasResources(&backend);

    _ = c.SDL_EnableScreenSaver();

    try initBasicTriangleResources(&backend);

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var interrupted = false;
    const max_wait_between_frames_micros: u32 = @intFromFloat(1_000_000.0 / min_refresh_fps);

    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        const quit = try backend.addAllEvents(&win);
        // Always build the frame, even on quit events, so backend uploads/draws stay valid.
        const frame_keep_running = gui_frame(&backend);
        const keep_running = frame_keep_running and !quit;

        const end_micros = try win.end(.{});

        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (!keep_running) break :main_loop;

        // Keep redraws alive even when dvui has no pending refresh, best-effort >= 30 FPS.
        const wait_event_micros = @min(win.waitTime(end_micros), max_wait_between_frames_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn gui_frame(backend: *SDLBackend.SDLBackend) bool {
    const px = backend.pixelSize();
    const canvas_w = @max(@as(u32, 1), @as(u32, @intFromFloat(px.w)));
    const canvas_h = @max(@as(u32, 1), @as(u32, @intFromFloat(px.h)));

    ensureCanvasTexture(backend, canvas_w, canvas_h) catch |err| {
        std.log.err("Could not create canvas target {}x{}: {any}", .{ canvas_w, canvas_h, err });
    };

    if (canvas_target) |target| {
        renderCanvasTarget(backend, target);
    }

    {
        var root = dvui.box(@src(), .{}, .{
            .name = "main",
            .expand = .both,
            .background = true,
        });
        defer root.deinit();

        if (canvas_texture) |tex| {
            _ = dvui.image(@src(), .{
                .source = .{ .texture = tex },
                .shrink = .both,
            }, .{
                .name = "sdl3_canvas",
                .expand = .both,
                .margin = .{},
                .padding = .{},
                .border = .{},
                .corner_radius = .{},
            });
        } else {
            dvui.labelNoFmt(@src(), "Canvas unavailable", .{}, .{ .expand = .both });
        }
    }

    if (open_debug_window_next_frame) {
        dvui.toggleDebugWindow();
        open_debug_window_next_frame = false;
    }

    // Demo and debug windows are floating overlays.
    dvui.Examples.demo();

    return applyHotkeysAndCheckQuit();
}

fn applyHotkeysAndCheckQuit() bool {
    var keep_running = true;
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down) continue;
                switch (ke.code) {
                    .left => use_wireframe_mode = !use_wireframe_mode,
                    .down => use_small_viewport = !use_small_viewport,
                    .right => use_scissor_rect = !use_scissor_rect,
                    else => {},
                }
            },
            .window => |w| {
                if (w.action == .close) keep_running = false;
            },
            .app => |a| {
                if (a.action == .quit) keep_running = false;
            },
            else => {},
        }
    }
    return keep_running;
}

fn selectBasicTriangleShader(device: *c.SDL_GPUDevice, stage: c.SDL_GPUShaderStage) !ShaderSelection {
    const formats = c.SDL_GetGPUShaderFormats(device);

    const is_vertex = stage == c.SDL_GPU_SHADERSTAGE_VERTEX;
    const is_fragment = stage == c.SDL_GPU_SHADERSTAGE_FRAGMENT;
    if (!is_vertex and !is_fragment) {
        return error.UnsupportedShaderStage;
    }

    if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        return .{
            .code = if (is_vertex) &basic_triangle_shaders.spv_raw_triangle_vert else &basic_triangle_shaders.spv_solid_color_frag,
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .entrypoint = "main",
        };
    }

    return error.UnsupportedShaderFormat;
}

fn createBasicTriangleShader(device: *c.SDL_GPUDevice, stage: c.SDL_GPUShaderStage) !*c.SDL_GPUShader {
    const shader_sel = try selectBasicTriangleShader(device, stage);

    var shader_info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    shader_info.code = shader_sel.code.ptr;
    shader_info.code_size = shader_sel.code.len;
    shader_info.entrypoint = shader_sel.entrypoint.ptr;
    shader_info.format = shader_sel.format;
    shader_info.stage = stage;
    shader_info.num_samplers = 0;
    shader_info.num_uniform_buffers = 0;
    shader_info.num_storage_buffers = 0;
    shader_info.num_storage_textures = 0;

    return c.SDL_CreateGPUShader(device, &shader_info) orelse {
        std.log.err("Failed to create BasicTriangle shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
}

fn initBasicTriangleResources(backend: *SDLBackend.SDLBackend) !void {
    if (fill_pipeline != null) return;

    const vertex_shader = try createBasicTriangleShader(backend.device, c.SDL_GPU_SHADERSTAGE_VERTEX);
    defer c.SDL_ReleaseGPUShader(backend.device, vertex_shader);

    const fragment_shader = try createBasicTriangleShader(backend.device, c.SDL_GPU_SHADERSTAGE_FRAGMENT);
    defer c.SDL_ReleaseGPUShader(backend.device, fragment_shader);

    var color_target_desc = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
    color_target_desc.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

    var pipeline_info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
    pipeline_info.target_info.num_color_targets = 1;
    pipeline_info.target_info.color_target_descriptions = &color_target_desc;
    pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pipeline_info.vertex_shader = vertex_shader;
    pipeline_info.fragment_shader = fragment_shader;

    pipeline_info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
    fill_pipeline = c.SDL_CreateGPUGraphicsPipeline(backend.device, &pipeline_info);
    if (fill_pipeline == null) {
        std.log.err("Failed to create BasicTriangle fill pipeline: {s}", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    }

    pipeline_info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_LINE;
    line_pipeline = c.SDL_CreateGPUGraphicsPipeline(backend.device, &pipeline_info);
    if (line_pipeline == null) {
        // Wireframe is optional on some platforms/devices.
        std.log.warn("Failed to create BasicTriangle line pipeline: {s}", .{c.SDL_GetError()});
    }

    std.log.info("BasicTriangle controls: Left=wireframe, Down=small viewport, Right=scissor rect", .{});
}

fn cleanupBasicTriangleResources(backend: *SDLBackend.SDLBackend) void {
    if (line_pipeline) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(backend.device, pipeline);
        line_pipeline = null;
    }

    if (fill_pipeline) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(backend.device, pipeline);
        fill_pipeline = null;
    }

    use_wireframe_mode = false;
    use_small_viewport = false;
    use_scissor_rect = false;
}

fn ensureCanvasTexture(backend: *SDLBackend.SDLBackend, width: u32, height: u32) !void {
    if (canvas_target) |target| {
        if (target.width == width and target.height == height) return;
        cleanupCanvasResources(backend);
    }

    const target = try backend.textureCreateTarget(width, height, .linear, .rgba_32);
    const texture = try backend.textureFromTarget(target);
    canvas_target = target;
    canvas_texture = texture;
}

fn cleanupCanvasResources(backend: *SDLBackend.SDLBackend) void {
    if (canvas_texture) |tex| {
        backend.textureDestroy(tex);
    }
    canvas_texture = null;
    canvas_target = null;
}

fn smallViewport(width: u32, height: u32) c.SDL_GPUViewport {
    const wf = @as(f32, @floatFromInt(width));
    const hf = @as(f32, @floatFromInt(height));
    return .{
        .x = wf * 0.25,
        .y = hf * 0.25,
        .w = @max(1.0, wf * 0.5),
        .h = @max(1.0, hf * 0.5),
        .min_depth = 0.1,
        .max_depth = 1.0,
    };
}

fn scissorRect(width: u32, height: u32) c.SDL_Rect {
    const x = width / 2;
    const y = height / 2;
    const w = @max(@as(u32, 1), width / 2);
    const h = @max(@as(u32, 1), height / 2);
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(h),
    };
}

fn renderCanvasTarget(backend: *SDLBackend.SDLBackend, target: dvui.TextureTarget) void {
    const cmd = backend.cmd orelse return;

    const target_impl: *CanvasTarget = @ptrCast(@alignCast(target.ptr));

    var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    color_target.texture = target_impl.texture;
    color_target.clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
    color_target.store_op = c.SDL_GPU_STOREOP_STORE;

    const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse {
        std.log.err("Failed to begin BasicTriangle pass: {s}", .{c.SDL_GetError()});
        return;
    };
    defer c.SDL_EndGPURenderPass(pass);

    const pipeline = if (use_wireframe_mode and line_pipeline != null) line_pipeline.? else fill_pipeline orelse return;
    c.SDL_BindGPUGraphicsPipeline(pass, pipeline);

    if (use_small_viewport) {
        var vp = smallViewport(target.width, target.height);
        c.SDL_SetGPUViewport(pass, &vp);
    }

    if (use_scissor_rect) {
        var scissor = scissorRect(target.width, target.height);
        c.SDL_SetGPUScissor(pass, &scissor);
    }

    c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
}
