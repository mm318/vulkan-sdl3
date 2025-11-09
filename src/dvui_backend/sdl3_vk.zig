const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const c = @import("vulkan").c;

pub const kind: dvui.enums.Backend = .custom;

pub const SDLBackend = @This();
pub const Context = *SDLBackend;

pub const DvuiVkRenderer = @import("dvui_vulkan_renderer.zig");
const GenericError = dvui.Backend.GenericError;
const TextureError = dvui.Backend.TextureError;

const log = std.log.scoped(.SDLBackend);

window: *c.SDL.Window,
renderer: DvuiVkRenderer,
initial_scale: f32 = 1.0,
last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
arena: std.mem.Allocator = undefined,

pub fn init(alloc: std.mem.Allocator, window: *c.SDL.Window, options: DvuiVkRenderer.InitOptions) SDLBackend {
    // init on top of already initialized backend, overrides rendering
    const dvui_vk_backend = DvuiVkRenderer.init(alloc, options) catch @panic("unable to initialize DvuiVkRenderer");
    return SDLBackend{ .window = window, .renderer = dvui_vk_backend };
}

const SDL_ERROR = bool;
const SDL_SUCCESS: SDL_ERROR = true;
inline fn toErr(res: SDL_ERROR, what: []const u8) !void {
    if (res == SDL_SUCCESS) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    std.log.err("{s} failed, error={s}", .{ what, c.SDL.GetError() });
    return dvui.Backend.GenericError.BackendError;
}

pub fn refresh(_: *SDLBackend) void {
    var ue = std.mem.zeroes(c.SDL.Event);
    ue.type = c.SDL.EVENT_USER;
    toErr(c.SDL.PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
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
    try toErr(c.SDL.OpenURL(c_url.ptr), "SDL_OpenURL in openURL");
}

pub fn preferredColorScheme(_: *SDLBackend) ?dvui.enums.ColorScheme {
    return switch (c.SDL.GetSystemTheme()) {
        c.SDL.SYSTEM_THEME_DARK => .dark,
        c.SDL.SYSTEM_THEME_LIGHT => .light,
        else => null,
    };
}

pub fn begin(self: *SDLBackend, arena: std.mem.Allocator) !void {
    self.arena = arena;
    // hack: get proper physical size
    const win_size = self.windowSize();
    self.renderer.begin(.{ .w = win_size.w, .h = win_size.h });
}

pub fn end(_: *SDLBackend) !void {}

pub fn pixelSize(self: *SDLBackend) dvui.Size.Physical {
    const last_pixel_size = self.renderer.pixelSize();
    self.last_pixel_size = .{ .w = last_pixel_size.w, .h = last_pixel_size.h };
    return self.last_pixel_size;
}

pub fn windowSize(self: *SDLBackend) dvui.Size.Natural {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL.GetWindowSize(self.window, &w, &h), "SDL_GetWindowSize in windowSize") catch return self.last_window_size;
    self.last_window_size = .{ .w = @as(f32, @floatFromInt(w)), .h = @as(f32, @floatFromInt(h)) };
    return self.last_window_size;
}

pub fn contentScale(self: *SDLBackend) f32 {
    return self.initial_scale;
}

pub fn drawClippedTriangles(
    self: *SDLBackend,
    texture: ?dvui.Texture,
    vtx: []const dvui.Vertex,
    idx: []const u16,
    maybe_clipr: ?dvui.Rect.Physical,
) !void {
    self.renderer.drawClippedTriangles(texture, vtx, idx, maybe_clipr);
}

pub fn textureCreate(
    self: *SDLBackend,
    pixels: [*]const u8,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
) TextureError!dvui.Texture {
    return self.renderer.textureCreate(pixels, width, height, interpolation);
}

// pub fn textureUpdate(_: *SDLBackend, texture: dvui.Texture, pixels: [*]const u8) !void {
//     const tx: [*c]c.SDL.Texture = @ptrCast(@alignCast(texture.ptr));
//     if (!c.SDL.UpdateTexture(tx, null, pixels, @intCast(texture.width * 4))) return error.TextureUpdate;
// }

pub fn textureCreateTarget(
    self: *SDLBackend,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
) TextureError!dvui.TextureTarget {
    return self.renderer.textureCreateTarget(width, height, interpolation);
}

pub fn textureReadTarget(self: *SDLBackend, texture: dvui.TextureTarget, pixels_out: [*]u8) TextureError!void {
    return self.renderer.textureReadTarget(texture, pixels_out);
}

pub fn textureDestroy(_: *SDLBackend, texture: dvui.Texture) void {
    c.SDL.DestroyTexture(@as(*c.SDL.Texture, @ptrCast(@alignCast(texture.ptr))));
}

pub fn textureFromTarget(self: *SDLBackend, texture: dvui.TextureTarget) TextureError!dvui.Texture {
    return self.renderer.textureFromTarget(texture);
}

pub fn renderTarget(self: *SDLBackend, texture: ?dvui.TextureTarget) GenericError!void {
    return self.renderer.renderTarget(texture);
}

pub fn clipboardText(_: *SDLBackend) GenericError![]const u8 {
    return error.BackendError;
}

/// Set clipboard content (text only)
pub fn clipboardTextSet(_: *SDLBackend, _: []const u8) GenericError!void {
    return error.BackendError;
}

pub fn getSDLVersion() std.SemanticVersion {
    const v: u32 = @bitCast(c.SDL.GetVersion());
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
