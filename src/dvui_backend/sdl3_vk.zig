const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
pub const c = @import("vulkan").c;

pub const SDLBackend = @This();
const log = std.log.scoped(.SDLBackend);

pub const kind: dvui.enums.Backend = .custom;

pub const DvuiVkRenderer = @import("dvui_vulkan_renderer.zig");
const GenericError = dvui.Backend.GenericError;
const TextureError = dvui.Backend.TextureError;

window: *c.SDL.Window,
renderer: DvuiVkRenderer,
initial_scale: f32 = 1.0,
last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
arena: std.mem.Allocator = undefined,

// debug flags
log_events: bool = false,

pub fn init(alloc: std.mem.Allocator, window: *c.SDL.Window, options: DvuiVkRenderer.InitOptions) SDLBackend {
    // init on top of already initialized backend, overrides rendering
    const dvui_vk_backend = DvuiVkRenderer.init(alloc, options) catch @panic("unable to initialize DvuiVkRenderer");
    var self = SDLBackend{ .window = window, .renderer = dvui_vk_backend, .arena = alloc };
    self.renderer.framebuffer_size = self.windowSizeInPixels();
    _ = self.pixelSize();
    _ = self.windowSize();
    return self;
}

const SDL_ERROR = bool;
const SDL_SUCCESS: SDL_ERROR = true;
inline fn toErr(res: SDL_ERROR, what: []const u8) !void {
    if (res == SDL_SUCCESS) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    std.log.err("{s} failed, error={s}", .{ what, c.SDL.GetError() });
    return GenericError.BackendError;
}

pub fn refresh(_: *SDLBackend) void {
    var ue = std.mem.zeroes(c.SDL.Event);
    ue.type = c.SDL.EVENT_USER;
    toErr(c.SDL.PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
}

pub fn deinit(self: *SDLBackend) void {
    self.renderer.deinit(self.arena);
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

pub fn openURL(self: *SDLBackend, url: []const u8, _: bool) !void {
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
    _ = arena;
    self.renderer.begin(self.pixelSize());
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

pub fn windowSizeInPixels(self: *SDLBackend) c.vk.Extent2D {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL.GetWindowSizeInPixels(self.window, &w, &h), "SDL_GetWindowSizeInPixels in windowSizeInPixels") catch @panic("Unable to get window size");
    return .{ .width = @intCast(w), .height = @intCast(h) };
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

pub fn textureDestroy(self: *SDLBackend, texture: dvui.Texture) void {
    self.renderer.textureDestroy(texture);
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

pub fn addEvent(self: *SDLBackend, win: *dvui.Window, event: c.SDL.Event) !bool {
    switch (event.type) {
        c.SDL.EVENT_KEY_DOWN => {
            const sdl_scancode: c.SDL.Scancode = event.key.scancode;
            const code = SDL_scancode_to_dvui(sdl_scancode);
            const mod = SDL_keymod_to_dvui(event.key.mod);
            if (self.log_events) {
                log.debug("event KEYDOWN {any} {s} {any} {any}\n", .{ sdl_scancode, @tagName(code), mod, event.key.repeat });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = if (event.key.repeat) .repeat else .down,
                .mod = mod,
            });
        },
        c.SDL.EVENT_KEY_UP => {
            const sdl_scancode: c.SDL.Scancode = event.key.scancode;
            const code = SDL_scancode_to_dvui(sdl_scancode);
            const mod = SDL_keymod_to_dvui(event.key.mod);
            if (self.log_events) {
                log.debug("event KEYUP {any} {s} {any}\n", .{ sdl_scancode, @tagName(code), mod });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = .up,
                .mod = mod,
            });
        },
        c.SDL.EVENT_TEXT_INPUT => {
            const txt = std.mem.sliceTo(event.text.text, 0);
            if (self.log_events) {
                log.debug("event TEXTINPUT {s}\n", .{txt});
            }

            return try win.addEventText(.{ .text = txt });
        },
        c.SDL.EVENT_TEXT_EDITING => {
            const strlen: u8 = @intCast(c.SDL.strlen(event.edit.text));
            if (self.log_events) {
                log.debug("event TEXTEDITING {s} start {d} len {d} strlen {d}\n", .{ event.edit.text, event.edit.start, event.edit.length, strlen });
            }
            return try win.addEventText(.{ .text = event.edit.text[0..strlen], .selected = true });
        },
        c.SDL.EVENT_MOUSE_MOTION => {
            // sdl gives us mouse coords in "window coords" which is kind of
            // like natural coords but ignores content scaling
            const pixel_size = self.pixelSize();
            const window_size = self.windowSize();
            const scale_x = pixel_size.w / window_size.w;
            const scale_y = pixel_size.h / window_size.h;

            if (self.log_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEMOTION {d} {d} {} {}\n", .{ touch_str, event.motion.x, event.motion.y, scale_x, scale_y });
            }

            return try win.addEventMouseMotion(.{
                .pt = .{
                    .x = event.motion.x * scale_x,
                    .y = event.motion.y * scale_y,
                },
            });
        },
        c.SDL.EVENT_MOUSE_BUTTON_DOWN => {
            if (self.log_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEBUTTONDOWN {d}\n", .{ touch_str, event.button.button });
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .press);
        },
        c.SDL.EVENT_MOUSE_BUTTON_UP => {
            if (self.log_events) {
                const touch = event.motion.which == c.SDL.TOUCH_MOUSEID;
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                log.debug("event{s}MOUSEBUTTONUP {d}\n", .{ touch_str, event.button.button });
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .release);
        },
        c.SDL.EVENT_MOUSE_WHEEL => {
            // .precise added in 2.0.18
            const ticks_x = event.wheel.x;
            const ticks_y = event.wheel.y;

            if (self.log_events) {
                log.debug("event MOUSEWHEEL {d} {d} {d}\n", .{ ticks_x, ticks_y, event.wheel.which });
            }

            var ret = false;
            if (ticks_x != 0) ret = try win.addEventMouseWheel(ticks_x * dvui.scroll_speed, .horizontal);
            if (ticks_y != 0) ret = try win.addEventMouseWheel(ticks_y * dvui.scroll_speed, .vertical);
            return ret;
        },
        c.SDL.EVENT_FINGER_DOWN => {
            if (self.log_events) {
                log.debug("event FINGERDOWN {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL.EVENT_FINGER_UP => {
            if (self.log_events) {
                log.debug("event FINGERUP {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL.EVENT_FINGER_MOTION => {
            if (self.log_events) {
                log.debug("event FINGERMOTION {d} {d} {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy });
            }

            return try win.addEventTouchMotion(.touch0, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy);
        },
        else => {
            if (self.log_events) {
                log.debug("unhandled SDL event type {any}\n", .{event.type});
            }
            return false;
        },
    }
}

pub fn SDL_mouse_button_to_dvui(button: u8) dvui.enums.Button {
    return switch (button) {
        c.SDL.BUTTON_LEFT => .left,
        c.SDL.BUTTON_MIDDLE => .middle,
        c.SDL.BUTTON_RIGHT => .right,
        c.SDL.BUTTON_X1 => .four,
        c.SDL.BUTTON_X2 => .five,
        else => blk: {
            log.debug("SDL_mouse_button_to_dvui.unknown button {d}", .{button});
            break :blk .six;
        },
    };
}

pub fn SDL_keymod_to_dvui(keymod: c.SDL.Keymod) dvui.enums.Mod {
    if (keymod == c.SDL.KMOD_NONE) return dvui.enums.Mod.none;

    var m: u16 = 0;
    if ((keymod & c.SDL.KMOD_LSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.lshift);
    if ((keymod & c.SDL.KMOD_RSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.rshift);
    if ((keymod & c.SDL.KMOD_LCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if ((keymod & c.SDL.KMOD_RCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if ((keymod & c.SDL.KMOD_LALT) > 0) m |= @intFromEnum(dvui.enums.Mod.lalt);
    if ((keymod & c.SDL.KMOD_RALT) > 0) m |= @intFromEnum(dvui.enums.Mod.ralt);
    if ((keymod & c.SDL.KMOD_LGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.lcommand);
    if ((keymod & c.SDL.KMOD_RGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.rcommand);

    return @as(dvui.enums.Mod, @enumFromInt(m));
}

pub fn SDL_scancode_to_dvui(scancode: c.SDL.Scancode) dvui.enums.Key {
    return switch (scancode) {
        c.SDL.SCANCODE_A => .a,
        c.SDL.SCANCODE_B => .b,
        c.SDL.SCANCODE_C => .c,
        c.SDL.SCANCODE_D => .d,
        c.SDL.SCANCODE_E => .e,
        c.SDL.SCANCODE_F => .f,
        c.SDL.SCANCODE_G => .g,
        c.SDL.SCANCODE_H => .h,
        c.SDL.SCANCODE_I => .i,
        c.SDL.SCANCODE_J => .j,
        c.SDL.SCANCODE_K => .k,
        c.SDL.SCANCODE_L => .l,
        c.SDL.SCANCODE_M => .m,
        c.SDL.SCANCODE_N => .n,
        c.SDL.SCANCODE_O => .o,
        c.SDL.SCANCODE_P => .p,
        c.SDL.SCANCODE_Q => .q,
        c.SDL.SCANCODE_R => .r,
        c.SDL.SCANCODE_S => .s,
        c.SDL.SCANCODE_T => .t,
        c.SDL.SCANCODE_U => .u,
        c.SDL.SCANCODE_V => .v,
        c.SDL.SCANCODE_W => .w,
        c.SDL.SCANCODE_X => .x,
        c.SDL.SCANCODE_Y => .y,
        c.SDL.SCANCODE_Z => .z,

        c.SDL.SCANCODE_0 => .zero,
        c.SDL.SCANCODE_1 => .one,
        c.SDL.SCANCODE_2 => .two,
        c.SDL.SCANCODE_3 => .three,
        c.SDL.SCANCODE_4 => .four,
        c.SDL.SCANCODE_5 => .five,
        c.SDL.SCANCODE_6 => .six,
        c.SDL.SCANCODE_7 => .seven,
        c.SDL.SCANCODE_8 => .eight,
        c.SDL.SCANCODE_9 => .nine,

        c.SDL.SCANCODE_F1 => .f1,
        c.SDL.SCANCODE_F2 => .f2,
        c.SDL.SCANCODE_F3 => .f3,
        c.SDL.SCANCODE_F4 => .f4,
        c.SDL.SCANCODE_F5 => .f5,
        c.SDL.SCANCODE_F6 => .f6,
        c.SDL.SCANCODE_F7 => .f7,
        c.SDL.SCANCODE_F8 => .f8,
        c.SDL.SCANCODE_F9 => .f9,
        c.SDL.SCANCODE_F10 => .f10,
        c.SDL.SCANCODE_F11 => .f11,
        c.SDL.SCANCODE_F12 => .f12,

        c.SDL.SCANCODE_KP_DIVIDE => .kp_divide,
        c.SDL.SCANCODE_KP_MULTIPLY => .kp_multiply,
        c.SDL.SCANCODE_KP_MINUS => .kp_subtract,
        c.SDL.SCANCODE_KP_PLUS => .kp_add,
        c.SDL.SCANCODE_KP_ENTER => .kp_enter,
        c.SDL.SCANCODE_KP_0 => .kp_0,
        c.SDL.SCANCODE_KP_1 => .kp_1,
        c.SDL.SCANCODE_KP_2 => .kp_2,
        c.SDL.SCANCODE_KP_3 => .kp_3,
        c.SDL.SCANCODE_KP_4 => .kp_4,
        c.SDL.SCANCODE_KP_5 => .kp_5,
        c.SDL.SCANCODE_KP_6 => .kp_6,
        c.SDL.SCANCODE_KP_7 => .kp_7,
        c.SDL.SCANCODE_KP_8 => .kp_8,
        c.SDL.SCANCODE_KP_9 => .kp_9,
        c.SDL.SCANCODE_KP_PERIOD => .kp_decimal,

        c.SDL.SCANCODE_RETURN => .enter,
        c.SDL.SCANCODE_ESCAPE => .escape,
        c.SDL.SCANCODE_TAB => .tab,
        c.SDL.SCANCODE_LSHIFT => .left_shift,
        c.SDL.SCANCODE_RSHIFT => .right_shift,
        c.SDL.SCANCODE_LCTRL => .left_control,
        c.SDL.SCANCODE_RCTRL => .right_control,
        c.SDL.SCANCODE_LALT => .left_alt,
        c.SDL.SCANCODE_RALT => .right_alt,
        c.SDL.SCANCODE_LGUI => .left_command,
        c.SDL.SCANCODE_RGUI => .right_command,
        c.SDL.SCANCODE_MENU => .menu,
        c.SDL.SCANCODE_NUMLOCKCLEAR => .num_lock,
        c.SDL.SCANCODE_CAPSLOCK => .caps_lock,
        c.SDL.SCANCODE_PRINTSCREEN => .print,
        c.SDL.SCANCODE_SCROLLLOCK => .scroll_lock,
        c.SDL.SCANCODE_PAUSE => .pause,
        c.SDL.SCANCODE_DELETE => .delete,
        c.SDL.SCANCODE_HOME => .home,
        c.SDL.SCANCODE_END => .end,
        c.SDL.SCANCODE_PAGEUP => .page_up,
        c.SDL.SCANCODE_PAGEDOWN => .page_down,
        c.SDL.SCANCODE_INSERT => .insert,
        c.SDL.SCANCODE_LEFT => .left,
        c.SDL.SCANCODE_RIGHT => .right,
        c.SDL.SCANCODE_UP => .up,
        c.SDL.SCANCODE_DOWN => .down,
        c.SDL.SCANCODE_BACKSPACE => .backspace,
        c.SDL.SCANCODE_SPACE => .space,
        c.SDL.SCANCODE_MINUS => .minus,
        c.SDL.SCANCODE_EQUALS => .equal,
        c.SDL.SCANCODE_LEFTBRACKET => .left_bracket,
        c.SDL.SCANCODE_RIGHTBRACKET => .right_bracket,
        c.SDL.SCANCODE_BACKSLASH => .backslash,
        c.SDL.SCANCODE_SEMICOLON => .semicolon,
        c.SDL.SCANCODE_APOSTROPHE => .apostrophe,
        c.SDL.SCANCODE_COMMA => .comma,
        c.SDL.SCANCODE_PERIOD => .period,
        c.SDL.SCANCODE_SLASH => .slash,
        c.SDL.SCANCODE_GRAVE => .grave,

        else => blk: {
            log.debug("SDL_scancode_to_dvui unknown scancode {d}", .{scancode});
            break :blk .unknown;
        },
    };
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
