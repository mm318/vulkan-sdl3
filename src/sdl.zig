const std = @import("std");

pub const c = @import("dvui").backend.c;
pub const c_main = @cImport({
    // these imports come from dvui
    // @cDefine("SDL_DISABLE_OLD_NAMES", {});
    // @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");

    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});

pub const PixelRGBX8888 = packed struct(u32) {
    _: u8 = 0,
    b: u8,
    g: u8,
    r: u8,
};

pub const FRect = c.SDL_FRect;
pub const Rect = c.SDL_Rect;
pub const Texture = c.SDL_Texture;
pub const Renderer = c.SDL_Renderer;
pub const Window = c.SDL_Window;

pub const TextureAccess = enum(c_uint) {
    static = c.SDL_TEXTUREACCESS_STATIC,
    streaming = c.SDL_TEXTUREACCESS_STREAMING,
    target = c.SDL_TEXTUREACCESS_TARGET,
};

pub const PixelFormat = enum(c_uint) {
    rgb24 = c.SDL_PIXELFORMAT_RGB24,
    rgbx8888 = c.SDL_PIXELFORMAT_RGBX8888,
    xbgr8888 = c.SDL_PIXELFORMAT_XBGR8888,
};

pub const SystemTheme = enum {
    unknown,
    light,
    dark,
};

fn errify(value: anytype) !switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer => @TypeOf(value),
    else => @compileError("unimplemented"),
} {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .bool => {
            if (value) {
                return;
            }
            return getError();
        },
        .pointer => {
            if (value != null) {
                return value;
            }
            return getError();
        },
        else => @compileError("unknown error type: " ++ @typeName(T)),
    }
}

fn getError() error{SdlError} {
    const err_message = c.SDL_GetError();
    std.log.err("{s}", .{err_message});
    return error.SdlError;
}

pub fn setHint(name: [*c]const u8, value: [*c]const u8) !void {
    try errify(c.SDL_SetHint(name, value));
}

pub fn setAppMetadata(appname: [*c]const u8, appversion: [*c]const u8, appidentifier: [*c]const u8) !void {
    try errify(c.SDL_SetAppMetadata(appname, appversion, appidentifier));
}

pub fn initialize(flags: c.SDL_InitFlags) !void {
    try errify(c.SDL_Init(flags));
}

pub fn createWindowAndRenderer(
    title: [*c]const u8,
    width: c_int,
    height: c_int,
    window_flags: c.SDL_WindowFlags,
    window: **c.SDL_Window,
    renderer: **c.SDL_Renderer,
) !void {
    try errify(c.SDL_CreateWindowAndRenderer(
        title,
        width,
        height,
        window_flags,
        @ptrCast(window),
        @ptrCast(renderer),
    ));
}

pub fn buildTimeVersion() std.SemanticVersion {
    return std.SemanticVersion{
        .major = c.SDL_MAJOR_VERSION,
        .minor = c.SDL_MINOR_VERSION,
        .patch = c.SDL_MICRO_VERSION,
    };
}

pub fn runTimeVersion() std.SemanticVersion {
    const version = c.SDL_GetVersion();
    return std.SemanticVersion{
        .major = @intCast(c.SDL_VERSIONNUM_MAJOR(version)),
        .minor = @intCast(c.SDL_VERSIONNUM_MINOR(version)),
        .patch = @intCast(c.SDL_VERSIONNUM_MICRO(version)),
    };
}

pub fn setRenderDrawColor(renderer: ?*c.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) !void {
    try errify(c.SDL_SetRenderDrawColor(renderer, r, g, b, a));
}

pub fn renderClear(renderer: *c.SDL_Renderer) !void {
    try errify(c.SDL_RenderClear(renderer));
}

pub fn createTexture(
    renderer: *c.SDL_Renderer,
    format: PixelFormat,
    access: TextureAccess,
    width: c_int,
    height: c_int,
) !*c.SDL_Texture {
    return try errify(c.SDL_CreateTexture(
        renderer,
        @intFromEnum(format),
        @intFromEnum(access),
        width,
        height,
    ));
}

pub fn destroyTexture(texture: *c.SDL_Texture) void {
    c.SDL_DestroyTexture(texture);
}

pub fn updateTexture(
    comptime P: anytype,
    texture: *c.SDL_Texture,
    rect: ?Rect,
    pixels: []P,
    pitch: c_int,
) !void {
    try errify(c.SDL_UpdateTexture(
        texture,
        mapToPtr(Rect, &rect),
        pixels.ptr,
        pitch,
    ));
}

pub fn renderTexture(renderer: *c.SDL_Renderer, texture: *c.SDL_Texture, source: ?FRect, destination: ?FRect) !void {
    try errify(c.SDL_RenderTexture(
        renderer,
        texture,
        mapToPtr(FRect, &source),
        mapToPtr(FRect, &destination),
    ));
}

pub fn lockTexture(
    comptime P: type,
    texture: *Texture,
    rect: ?Rect,
    pixels_out: *[*]P,
    pitch_in_bytes_out: *c_int,
) !void {
    try errify(c.SDL_LockTexture(
        texture,
        mapToPtr(Rect, &rect),
        // &untyped_pixels,
        @ptrCast(pixels_out),
        pitch_in_bytes_out,
    ));
}

pub fn unlockTexture(texture: *Texture) void {
    c.SDL_UnlockTexture(texture);
}

pub fn getTicks() u64 {
    return c.SDL_GetTicks();
}

pub fn renderPresent(renderer: *c.SDL_Renderer) !void {
    try errify(c.SDL_RenderPresent(renderer));
}

pub fn setRenderDrawBlendMode(renderer: *c.SDL_Renderer, mode: u32) !void {
    try errify(c.SDL_SetRenderDrawBlendMode(renderer, mode));
}

pub const ScaleMode = enum(c_int) {
    nearest = c.SDL_SCALEMODE_NEAREST,
    linear = c.SDL_SCALEMODE_LINEAR,
};

pub fn setTextureScaleMode(texture: *Texture, mode: ScaleMode) !void {
    try errify(c.SDL_SetTextureScaleMode(texture, @intFromEnum(mode)));
}

pub fn getSystemTheme() SystemTheme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_LIGHT => .light,
        c.SDL_SYSTEM_THEME_DARK => .dark,
        c.SDL_SYSTEM_THEME_UNKNOWN => .unknown,
        else => .unknown,
    };
}

pub fn getDisplayContentScale(window: *Window) f32 {
    return c.SDL_GetWindowDisplayScale(window);
}

pub fn setClipboardText(str: [:0]const u8) !void {
    try errify(c.SDL_SetClipboardText(str));
}

fn mapToPtr(comptime T: type, value: *const ?T) ?*const T {
    if (value.*) |*x| {
        return @constCast(x);
    }
    return null;
}
