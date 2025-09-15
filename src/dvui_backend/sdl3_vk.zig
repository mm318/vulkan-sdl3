const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const sdl_options = @import("sdl_options");
pub const c = blk: {
    break :blk @cImport({
        @cDefine("SDL_DISABLE_OLD_NAMES", {});
        @cInclude("SDL3/SDL.h");

        @cDefine("SDL_MAIN_HANDLED", {});
        @cInclude("SDL3/SDL_main.h");
    });
};

pub const kind: dvui.enums.Backend = .sdl3_vk;

pub const SDLBackend = @This();
pub const Context = *SDLBackend;
// const DvuiVkRenderer = @import("dvui_vulkan_renderer.zig");

const log = std.log.scoped(.SDLBackend);

window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
// renderer: DvuiVkRenderer,
initial_scale: f32 = 1.0,
last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
arena: std.mem.Allocator = undefined,

pub const InitOptions = struct {
    /// The allocator used for temporary allocations used during init()
    allocator: std.mem.Allocator,
    /// The initial size of the application window
    size: dvui.Size,
    /// Set the minimum size of the window
    min_size: ?dvui.Size = null,
    /// Set the maximum size of the window
    max_size: ?dvui.Size = null,
    vsync: bool,
    /// The application title to display
    title: [:0]const u8,
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
    /// use when running tests
    hidden: bool = false,
    fullscreen: bool = false,
};

pub fn init(window: *c.SDL_Window, renderer: *c.SDL_Renderer) SDLBackend {
    return SDLBackend{ .window = window, .renderer = renderer };
}

const SDL_ERROR = bool;
const SDL_SUCCESS: SDL_ERROR = true;
inline fn toErr(res: SDL_ERROR, what: []const u8) !void {
    if (res == SDL_SUCCESS) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    std.log.err("{s} failed, error={s}", .{ what, c.SDL_GetError() });
    return dvui.Backend.GenericError.BackendError;
}

pub fn refresh(_: *SDLBackend) void {
    var ue = std.mem.zeroes(c.SDL_Event);
    ue.type = c.SDL_EVENT_USER;
    toErr(c.SDL_PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
}

pub fn deinit(self: *SDLBackend) void {
    self.* = undefined;
}

pub fn backend(self: *SDLBackend) dvui.Backend {
    return dvui.Backend.init(self);
}

pub fn nanoTime(_: *SDLBackend) i128 {
    return std.time.nanoTimestamp();
}

pub fn sleep(_: *SDLBackend, ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn openURL(self: *SDLBackend, url: []const u8) !void {
    const c_url = try self.arena.dupeZ(u8, url);
    defer self.arena.free(c_url);
    try toErr(c.SDL_OpenURL(c_url.ptr), "SDL_OpenURL in openURL");
}

pub fn preferredColorScheme(_: *SDLBackend) ?dvui.enums.ColorScheme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_DARK => .dark,
        c.SDL_SYSTEM_THEME_LIGHT => .light,
        else => null,
    };
}

pub fn begin(self: *SDLBackend, arena: std.mem.Allocator) !void {
    self.arena = arena;
    const size = self.pixelSize();
    try toErr(c.SDL_SetRenderClipRect(self.renderer, &c.SDL_Rect{
        .x = 0,
        .y = 0,
        .w = @intFromFloat(size.w),
        .h = @intFromFloat(size.h),
    }), "SDL_SetRenderClipRect in begin");
}

pub fn end(_: *SDLBackend) !void {}

pub fn pixelSize(self: *SDLBackend) dvui.Size.Physical {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(
        c.SDL_GetCurrentRenderOutputSize(self.renderer, &w, &h),
        "SDL_GetCurrentRenderOutputSize in pixelSize",
    ) catch return self.last_pixel_size;
    self.last_pixel_size = .{ .w = @as(f32, @floatFromInt(w)), .h = @as(f32, @floatFromInt(h)) };
    return self.last_pixel_size;
}

pub fn windowSize(self: *SDLBackend) dvui.Size.Natural {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL_GetWindowSize(self.window, &w, &h), "SDL_GetWindowSize in windowSize") catch return self.last_window_size;
    self.last_window_size = .{ .w = @as(f32, @floatFromInt(w)), .h = @as(f32, @floatFromInt(h)) };
    return self.last_window_size;
}

pub fn contentScale(self: *SDLBackend) f32 {
    return self.initial_scale;
}

pub fn drawClippedTriangles(self: *SDLBackend, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const u16, maybe_clipr: ?dvui.Rect.Physical,) !void {
    //std.debug.print("drawClippedTriangles:\n", .{});
    //for (vtx) |v, i| {
    //  std.debug.print("  {d} vertex {}\n", .{i, v});
    //}
    //for (idx) |id, i| {
    //  std.debug.print("  {d} index {d}\n", .{i, id});
    //}

    var oldclip: c.SDL_Rect = undefined;

    if (maybe_clipr) |clipr| {
        try toErr(
            c.SDL_GetRenderClipRect(self.renderer, &oldclip),
            "SDL_GetRenderClipRect in drawClippedTriangles",
        );

        const clip = c.SDL_Rect{
            .x = @intFromFloat(clipr.x),
            .y = @intFromFloat(clipr.y),
            .w = @intFromFloat(clipr.w),
            .h = @intFromFloat(clipr.h),
        };
        try toErr(
            c.SDL_SetRenderClipRect(self.renderer, &clip),
            "SDL_SetRenderClipRect in drawClippedTriangles",
        );
    }

    var tex: ?*c.SDL_Texture = null;
    if (texture) |t| {
        tex = @ptrCast(@alignCast(t.ptr));
    }

    // not great, but seems sdl3 strictly accepts color only in floats
    // TODO: review if better solution is possible
    const vcols = try self.arena.alloc(c.SDL_FColor, vtx.len);
    defer self.arena.free(vcols);
    for (vcols, 0..) |*col, i| {
        col.r = @as(f32, @floatFromInt(vtx[i].col.r)) / 255.0;
        col.g = @as(f32, @floatFromInt(vtx[i].col.g)) / 255.0;
        col.b = @as(f32, @floatFromInt(vtx[i].col.b)) / 255.0;
        col.a = @as(f32, @floatFromInt(vtx[i].col.a)) / 255.0;
    }

    try toErr(c.SDL_RenderGeometryRaw(
        self.renderer,
        tex,
        @as(*const f32, @ptrCast(&vtx[0].pos)),
        @sizeOf(dvui.Vertex),
        vcols.ptr,
        @sizeOf(c.SDL_FColor),
        @as(*const f32, @ptrCast(&vtx[0].uv)),
        @sizeOf(dvui.Vertex),
        @as(c_int, @intCast(vtx.len)),
        idx.ptr,
        @as(c_int, @intCast(idx.len)),
        @sizeOf(u16),
    ), "SDL_RenderGeometryRaw, in drawClippedTriangles");

    if (maybe_clipr) |_| {
        try toErr(
            c.SDL_SetRenderClipRect(self.renderer, &oldclip),
            "SDL_SetRenderClipRect in drawClippedTriangles reset clip",
        );
    }
}

pub fn textureCreate(self: *SDLBackend, pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation,) !dvui.Texture {
    const surface = c.SDL_CreateSurfaceFrom(
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(height)),
        c.SDL_PIXELFORMAT_ABGR8888,
        @constCast(pixels),
        @as(c_int, @intCast(4 * width)),
    ) orelse return logErr("SDL_CreateSurfaceFrom in textureCreate");

    defer c.SDL_DestroySurface(surface);

    const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse return logErr("SDL_CreateTextureFromSurface in textureCreate");
    errdefer c.SDL_DestroyTexture(texture);

    try toErr(switch (interpolation) {
        .nearest => c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST),
        .linear => c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR),
    }, "SDL_SetTextureScaleMode in textureCreates");

    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD,);
    try toErr(c.SDL_SetTextureBlendMode(texture, pma_blend), "SDL_SetTextureBlendMode in textureCreate");
    return dvui.Texture{ .ptr = texture, .width = width, .height = height };
}

pub fn textureUpdate(_: *SDLBackend, texture: dvui.Texture, pixels: [*]const u8) !void {
    const tx: [*c]c.SDL_Texture = @ptrCast(@alignCast(texture.ptr));
    if (!c.SDL_UpdateTexture(tx, null, pixels, @intCast(texture.width * 4))) return error.TextureUpdate;
}

pub fn textureCreateTarget(self: *SDLBackend, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.TextureTarget {
    const texture = c.SDL_CreateTexture(
        self.renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_TARGET,
        @intCast(width),
        @intCast(height),
    ) orelse return logErr("SDL_CreateTexture in textureCreateTarget");
    errdefer c.SDL_DestroyTexture(texture);

    try toErr(switch (interpolation) {
        .nearest => c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST),
        .linear => c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR),
    }, "SDL_SetTextureScaleMode in textureCreates");

    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD,);
    try toErr(
        c.SDL_SetTextureBlendMode(texture, pma_blend),
        "SDL_SetTextureBlendMode in textureCreateTarget",
    );
    //try toErr(c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND), "SDL_SetTextureBlendMode in textureCreateTarget",);

    // make sure texture starts out transparent
    // null is the default render target
    const old = c.SDL_GetRenderTarget(self.renderer);
    defer toErr(
        c.SDL_SetRenderTarget(self.renderer, old),
        "SDL_SetRenderTarget in textureCreateTarget",
    ) catch log.err("Could not reset render target", .{});

    var oldBlend: c_uint = undefined;
    try toErr(
        c.SDL_GetRenderDrawBlendMode(self.renderer, &oldBlend),
        "SDL_GetRenderDrawBlendMode in textureCreateTarget",
    );
    defer toErr(
        c.SDL_SetRenderDrawBlendMode(self.renderer, oldBlend),
        "SDL_SetRenderDrawBlendMode in textureCreateTarget",
    ) catch log.err("Could not reset render blend mode", .{});

    try toErr(
        c.SDL_SetRenderTarget(self.renderer, texture),
        "SDL_SetRenderTarget in textureCreateTarget",
    );
    try toErr(
        c.SDL_SetRenderDrawBlendMode(self.renderer, c.SDL_BLENDMODE_NONE),
        "SDL_SetRenderDrawBlendMode in textureCreateTarget",
    );
    try toErr(
        c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 0),
        "SDL_SetRenderDrawColor in textureCreateTarget",
    );
    try toErr(
        c.SDL_RenderFillRect(self.renderer, null),
        "SDL_RenderFillRect in textureCreateTarget",
    );

    return dvui.TextureTarget{ .ptr = texture, .width = width, .height = height };
}

pub fn textureReadTarget(self: *SDLBackend, texture: dvui.TextureTarget, pixels_out: [*]u8) !void {
    // null is the default target
    const orig_target = c.SDL_GetRenderTarget(self.renderer);
    try toErr(c.SDL_SetRenderTarget(self.renderer, @ptrCast(@alignCast(texture.ptr))), "SDL_SetRenderTarget in textureReadTarget");
    defer toErr(
        c.SDL_SetRenderTarget(self.renderer, orig_target),
        "SDL_SetRenderTarget in textureReadTarget",
    ) catch log.err("Could not reset render target", .{});

    var surface: *c.SDL_Surface = c.SDL_RenderReadPixels(self.renderer, null) orelse
        logErr("SDL_RenderReadPixels in textureReadTarget") catch
        return dvui.Backend.TextureError.TextureRead;
    defer c.SDL_DestroySurface(surface);

    if (texture.width * texture.height != surface.*.w * surface.*.h) {
        log.err(
            "texture and target surface sizes did not match: texture {d} {d} surface {d} {d}\n",
            .{ texture.width, texture.height, surface.*.w, surface.*.h },
        );
        return dvui.Backend.TextureError.TextureRead;
    }

    // TODO: most common format is RGBA8888, doing conversion during copy to pixels_out should be faster
    if (surface.*.format != c.SDL_PIXELFORMAT_ABGR8888) {
        surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888) orelse
            logErr("SDL_ConvertSurface in textureReadTarget") catch
            return dvui.Backend.TextureError.TextureRead;
    }
    @memcpy(
        pixels_out[0 .. texture.width * texture.height * 4],
        @as(?[*]u8, @ptrCast(surface.*.pixels)).?[0 .. texture.width * texture.height * 4],
    );
}

pub fn textureDestroy(_: *SDLBackend, texture: dvui.Texture) void {
    c.SDL_DestroyTexture(@as(*c.SDL_Texture, @ptrCast(@alignCast(texture.ptr))));
}

pub fn textureFromTarget(self: *SDLBackend, texture: dvui.TextureTarget) !dvui.Texture {
    // SDL can't read from non-target textures, so read all the pixels and make a new texture
    const pixels = try self.arena.alloc(u8, texture.width * texture.height * 4);
    defer self.arena.free(pixels);
    try self.textureReadTarget(texture, pixels.ptr);

    c.SDL_DestroyTexture(@as(*c.SDL_Texture, @ptrCast(@alignCast(texture.ptr))));

    return self.textureCreate(pixels.ptr, texture.width, texture.height, .linear);
}

pub fn renderTarget(self: *SDLBackend, texture: ?dvui.TextureTarget) !void {
    const ptr: ?*anyopaque = if (texture) |tex| tex.ptr else null;
    try toErr(c.SDL_SetRenderTarget(self.renderer, @ptrCast(@alignCast(ptr))), "SDL_SetRenderTarget in renderTarget");

    // by default sdl sets an empty clip, let's ensure it is the full texture/screen
    // sdl3 crashes if w/h are too big, this seems to work
    try toErr(
        c.SDL_SetRenderClipRect(self.renderer, &c.SDL_Rect{ .x = 0, .y = 0, .w = 65536, .h = 65536 }),
        "SDL_SetRenderClipRect in renderTarget",
    );
}

pub fn getSDLVersion() std.SemanticVersion {
    const v: u32 = @bitCast(c.SDL_GetVersion());
    return .{
        .major = @divTrunc(v, 1000000),
        .minor = @mod(@divTrunc(v, 1000), 1000),
        .patch = @mod(v, 1000),
    };
}

test {
    //std.debug.print("{s} backend test\n", .{if (sdl3) "SDL3" else "SDL2"});
    std.testing.refAllDecls(@This());
}
