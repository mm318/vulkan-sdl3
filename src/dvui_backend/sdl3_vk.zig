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
we_own_window: bool = false,
touch_mouse_events: bool = false,
log_events: bool = false,
initial_scale: f32 = 1.0,
last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
cursor_last: dvui.enums.Cursor = .arrow,
cursor_backing: [@typeInfo(dvui.enums.Cursor).@"enum".fields.len]?*c.SDL_Cursor = [_]?*c.SDL_Cursor{null} ** @typeInfo(dvui.enums.Cursor).@"enum".fields.len,
cursor_backing_tried: [@typeInfo(dvui.enums.Cursor).@"enum".fields.len]bool = [_]bool{false} ** @typeInfo(dvui.enums.Cursor).@"enum".fields.len,
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

pub fn initWindow(options: InitOptions) !SDLBackend {
    // needed according to https://discourse.libsdl.org/t/possible-to-run-sdl2-headless/25665/2
    // but getting error "offscreen not available"
    // if (options.hidden) _ = c.SDL_SetHint(c.SDL_HINT_VIDEODRIVER, "offscreen");

    // use the string version instead of the #define so we compile with SDL < 2.24

    _ = c.SDL_SetHint("SDL_HINT_WINDOWS_DPI_SCALING", "1");
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    try toErr(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS), "SDL_Init in initWindow");

    const hidden_flag = if (options.hidden) c.SDL_WINDOW_HIDDEN else 0;
    const fullscreen_flag = if (options.fullscreen) c.SDL_WINDOW_FULLSCREEN else 0;
    const window: *c.SDL_Window = c.SDL_CreateWindow(
        options.title,
        @as(c_int, @intFromFloat(options.size.w)),
        @as(c_int, @intFromFloat(options.size.h)),
        @intCast(c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | hidden_flag | fullscreen_flag),
    ) orelse return logErr("SDL_CreateWindow in initWindow");

    errdefer c.SDL_DestroyWindow(window);

    const renderer: *c.SDL_Renderer = blk: {
        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);

        try toErr(
            c.SDL_SetPointerProperty(props, c.SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, window),
            "SDL_SetPointerProperty in initWindow",
        );

        if (options.vsync) {
            try toErr(
                c.SDL_SetNumberProperty(props, c.SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 1),
                "SDL_SetNumberProperty in initWindow",
            );
        }

        break :blk c.SDL_CreateRendererWithProperties(props) orelse return logErr("SDL_CreateRendererWithProperties in initWindow");
    };
    errdefer c.SDL_DestroyRenderer(renderer);

    // do premultiplied alpha blending:
    // * rendering to a texture and then rendering the texture works the same
    // * any filtering happening across pixels won't bleed in transparent rgb values
    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    try toErr(c.SDL_SetRenderDrawBlendMode(renderer, pma_blend), "SDL_SetRenderDrawBlendMode in initWindow");

    var back = init(window, renderer);
    back.we_own_window = true;

    back.initial_scale = c.SDL_GetDisplayContentScale(c.SDL_GetDisplayForWindow(window));
    if (back.initial_scale == 0) return logErr("SDL_GetDisplayContentScale in initWindow");
    log.info("SDL3 backend scale {d}", .{back.initial_scale});

    if (back.initial_scale != 1.0) {
        _ = c.SDL_SetWindowSize(
            window,
            @as(c_int, @intFromFloat(back.initial_scale * options.size.w)),
            @as(c_int, @intFromFloat(back.initial_scale * options.size.h)),
        );
    }

    if (options.icon) |bytes| {
        try back.setIconFromFileContent(bytes);
    }

    if (options.min_size) |size| {
        const ret = c.SDL_SetWindowMinimumSize(
            window,
            @as(c_int, @intFromFloat(back.initial_scale * size.w)),
            @as(c_int, @intFromFloat(back.initial_scale * size.h)),
        );
        try toErr(ret, "SDL_SetWindowMinimumSize in initWindow");
    }

    if (options.max_size) |size| {
        const ret = c.SDL_SetWindowMaximumSize(
            window,
            @as(c_int, @intFromFloat(back.initial_scale * size.w)),
            @as(c_int, @intFromFloat(back.initial_scale * size.h)),
        );
        try toErr(ret, "SDL_SetWindowMaximumSize in initWindow");
    }

    return back;
}

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

pub fn setIconFromFileContent(self: *SDLBackend, file_content: []const u8) !void {
    var icon_w: c_int = undefined;
    var icon_h: c_int = undefined;
    var channels_in_file: c_int = undefined;
    const data = dvui.c.stbi_load_from_memory(file_content.ptr, @as(c_int, @intCast(file_content.len)), &icon_w, &icon_h, &channels_in_file, 4);
    if (data == null) {
        log.warn("when setting icon, stbi_load error: {s}", .{dvui.c.stbi_failure_reason()});
        return dvui.StbImageError.stbImageError;
    }
    defer dvui.c.stbi_image_free(data);
    try self.setIconFromABGR8888(data, icon_w, icon_h);
}

pub fn setIconFromABGR8888(self: *SDLBackend, data: [*]const u8, icon_w: c_int, icon_h: c_int) !void {
    const surface = c.SDL_CreateSurfaceFrom(
        icon_w,
        icon_h,
        c.SDL_PIXELFORMAT_ABGR8888,
        @ptrCast(@constCast(data)),
        4 * icon_w,
    ) orelse return logErr("SDL_CreateSurfaceFrom in setIconFromABGR8888");

    defer c.SDL_DestroySurface(surface);

    try toErr(c.SDL_SetWindowIcon(self.window, surface), "SDL_SetWindowIcon in setIconFromABGR8888");
}

/// Return true if interrupted by event
pub fn waitEventTimeout(_: *SDLBackend, timeout_micros: u32) !bool {
    if (timeout_micros == std.math.maxInt(u32)) {
        // wait no timeout
        _ = c.SDL_WaitEvent(null);
        return false;
    }

    if (timeout_micros > 0) {
        // wait with a timeout
        const timeout = @min((timeout_micros + 999) / 1000, std.math.maxInt(c_int));
        var ret: bool = undefined;
        ret = c.SDL_WaitEventTimeout(null, @as(c_int, @intCast(timeout)));

        // TODO: this call to SDL_PollEvent can be removed after resolution of
        // https://github.com/libsdl-org/SDL/issues/6539
        // maintaining this a little longer for people with older SDL versions
        _ = c.SDL_PollEvent(null);

        return ret;
    }

    // don't wait at all
    return false;
}

pub fn cursorShow(_: *SDLBackend, value: ?bool) !bool {
    const prev = c.SDL_CursorVisible();
    if (value) |val| {
        if (val) {
            if (!c.SDL_ShowCursor()) {
                return logErr("SDL_ShowCursor in cursorShow");
            }
        } else {
            if (!c.SDL_HideCursor()) {
                return logErr("SDL_HideCursor in cursorShow");
            }
        }
    }
    return prev;
}

pub fn refresh(_: *SDLBackend) void {
    var ue = std.mem.zeroes(c.SDL_Event);
    ue.type = c.SDL_EVENT_USER;
    toErr(c.SDL_PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
}

pub fn addAllEvents(self: *SDLBackend, win: *dvui.Window) !bool {
    //const flags = c.SDL_GetWindowFlags(self.window);
    //if (flags & c.SDL_WINDOW_MOUSE_FOCUS == 0 and flags & c.SDL_WINDOW_INPUT_FOCUS == 0) {
    //std.debug.print("bailing\n", .{});
    //}
    var event: c.SDL_Event = undefined;
    const poll_got_event = true;
    while (c.SDL_PollEvent(&event) == poll_got_event) {
        _ = try self.addEvent(win, event);
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                return true;
            },
            // TODO: revisit with sdl3
            //c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
            //std.debug.print("sdl window scale changed event\n", .{});
            //},
            //c.SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED => {
            //std.debug.print("sdl display scale changed event\n", .{});
            //},
            else => {},
        }
    }

    return false;
}

pub fn setCursor(self: *SDLBackend, cursor: dvui.enums.Cursor) !void {
    if (cursor == self.cursor_last) return;
    defer self.cursor_last = cursor;
    const new_shown_state = if (cursor == .hidden) false else if (self.cursor_last == .hidden) true else null;
    if (new_shown_state) |new_state| {
        if (try self.cursorShow(new_state) == new_state) {
            log.err("Cursor shown state was out of sync", .{});
        }
        // Return early if we are hiding
        if (new_state == false) return;
    }

    const enum_int = @intFromEnum(cursor);
    const tried = self.cursor_backing_tried[enum_int];
    if (!tried) {
        self.cursor_backing_tried[enum_int] = true;
        self.cursor_backing[enum_int] = switch (cursor) {
            .arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .ibeam => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
            .wait => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_WAIT),
            .wait_arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_PROGRESS),
            .crosshair => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_CROSSHAIR),
            .arrow_nw_se => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NWSE_RESIZE),
            .arrow_ne_sw => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NESW_RESIZE),
            .arrow_w_e => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_EW_RESIZE),
            .arrow_n_s => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NS_RESIZE),
            .arrow_all => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_MOVE),
            .bad => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NOT_ALLOWED),
            .hand => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .hidden => unreachable,
        };
    }

    if (self.cursor_backing[enum_int]) |cur| {
        try toErr(c.SDL_SetCursor(cur), "SDL_SetCursor in setCursor");
    } else {
        log.err("setCursor \"{s}\" failed", .{@tagName(cursor)});
        return logErr("SDL_CreateSystemCursor in setCursor");
    }
}

pub fn textInputRect(self: *SDLBackend, rect: ?dvui.Rect.Natural) !void {
    if (rect) |r| {
        // This is the offset from r.x in window coords, supposed to be the
        // location of the cursor I think so that the IME window can be put
        // at the cursor location.  We will use 0 for now, might need to
        // change it (or how we determine rect) if people are using huge
        // text entries).
        const cursor = 0;

        try toErr(c.SDL_SetTextInputArea(
            self.window,
            &c.SDL_Rect{
                .x = @intFromFloat(r.x),
                .y = @intFromFloat(r.y),
                .w = @intFromFloat(r.w),
                .h = @intFromFloat(r.h),
            },
            cursor,
        ), "SDL_SetTextInputArea in textInputRect");

        try toErr(c.SDL_StartTextInput(self.window), "SDL_StartTextInput in textInputRect");
    } else {
        try toErr(c.SDL_StopTextInput(self.window), "SDL_StopTextInput in textInputRect");
    }
}

pub fn deinit(self: *SDLBackend) void {
    for (self.cursor_backing) |cursor| {
        if (cursor) |cur| {
            c.SDL_DestroyCursor(cur);
        }
    }

    if (self.we_own_window) {
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
    self.* = undefined;
}

pub fn renderPresent(self: *SDLBackend) !void {
    try toErr(c.SDL_RenderPresent(self.renderer), "SDL_RenderPresent in renderPresent");
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

pub fn clipboardText(self: *SDLBackend) ![]const u8 {
    const p = c.SDL_GetClipboardText();
    defer c.SDL_free(p); // must free even on error

    const str = std.mem.span(p);
    // Log error, but don't fail the application
    if (str.len == 0) logErr("SDL_GetClipboardText in clipboardText") catch {};

    return try self.arena.dupe(u8, str);
}

pub fn clipboardTextSet(self: *SDLBackend, text: []const u8) !void {
    if (text.len == 0) return;
    const c_text = try self.arena.dupeZ(u8, text);
    defer self.arena.free(c_text);
    try toErr(c.SDL_SetClipboardText(c_text.ptr), "SDL_SetClipboardText in clipboardTextSet");
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

pub fn drawClippedTriangles(self: *SDLBackend, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const u16, maybe_clipr: ?dvui.Rect.Physical) !void {
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

pub fn textureCreate(self: *SDLBackend, pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
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

    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
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

    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
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

pub fn addEvent(self: *SDLBackend, win: *dvui.Window, event: c.SDL_Event) !bool {
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            const sdl_key: i32 = @intCast(event.key.key);
            const code = SDL_keysym_to_dvui(@intCast(sdl_key));
            const mod = SDL_keymod_to_dvui(@intCast(event.key.mod));
            if (self.log_events) {
                log.debug("event KEYDOWN {any} {s} {any} {any}\n", .{ sdl_key, @tagName(code), mod, event.key.repeat });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = if (event.key.repeat) .repeat else .down,
                .mod = mod,
            });
        },
        c.SDL_EVENT_KEY_UP => {
            const sdl_key: i32 = @intCast(event.key.key);
            const code = SDL_keysym_to_dvui(@intCast(sdl_key));
            const mod = SDL_keymod_to_dvui(@intCast(event.key.mod));
            if (self.log_events) {
                log.debug("event KEYUP {any} {s} {any}\n", .{ sdl_key, @tagName(code), mod });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = .up,
                .mod = mod,
            });
        },
        c.SDL_EVENT_TEXT_INPUT => {
            const txt = std.mem.sliceTo(event.text.text, 0);
            if (self.log_events) {
                log.debug("event TEXTINPUT {s}\n", .{txt});
            }

            return try win.addEventText(txt);
        },
        c.SDL_EVENT_TEXT_EDITING => {
            const strlen: u8 = @intCast(c.SDL_strlen(event.edit.text));
            if (self.log_events) {
                log.debug("event TEXTEDITING {s} start {d} len {d} strlen {d}\n", .{ event.edit.text, event.edit.start, event.edit.length, strlen });
            }
            return try win.addEventTextEx(event.edit.text[0..strlen], true);
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEMOTION {d} {d}\n", .{ touch_str, event.motion.x, event.motion.y });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            // sdl gives us mouse coords in "window coords" which is kind of
            // like natural coords but ignores content scaling
            const scale = self.pixelSize().w / self.windowSize().w;

            return try win.addEventMouseMotion(.{
                .x = event.motion.x * scale,
                .y = event.motion.y * scale,
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEBUTTONDOWN {d}\n", .{ touch_str, event.button.button });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .press);
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEBUTTONUP {d}\n", .{ touch_str, event.button.button });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .release);
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
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
        c.SDL_EVENT_FINGER_DOWN => {
            if (self.log_events) {
                log.debug("event FINGERDOWN {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.touch0, .press, .{ .x = event.tfinger.x, .y = event.tfinger.y });
        },
        c.SDL_EVENT_FINGER_UP => {
            if (self.log_events) {
                log.debug("event FINGERUP {d} {d} {d}\n", .{ event.tfinger.fingerID, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.touch0, .release, .{ .x = event.tfinger.x, .y = event.tfinger.y });
        },
        c.SDL_EVENT_FINGER_MOTION => {
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
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_X1 => .four,
        c.SDL_BUTTON_X2 => .five,
        else => blk: {
            log.debug("SDL_mouse_button_to_dvui.unknown button {d}", .{button});
            break :blk .six;
        },
    };
}

pub fn SDL_keymod_to_dvui(keymod: u16) dvui.enums.Mod {
    if (keymod == c.SDL_KMOD_NONE) return dvui.enums.Mod.none;

    var m: u16 = 0;
    if ((keymod & c.SDL_KMOD_LSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.lshift);
    if ((keymod & c.SDL_KMOD_RSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.rshift);
    if ((keymod & c.SDL_KMOD_LCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if ((keymod & c.SDL_KMOD_RCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if ((keymod & c.SDL_KMOD_LALT) > 0) m |= @intFromEnum(dvui.enums.Mod.lalt);
    if ((keymod & c.SDL_KMOD_RALT) > 0) m |= @intFromEnum(dvui.enums.Mod.ralt);
    if ((keymod & c.SDL_KMOD_LGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.lcommand);
    if ((keymod & c.SDL_KMOD_RGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.rcommand);

    return @as(dvui.enums.Mod, @enumFromInt(m));
}

pub fn SDL_keysym_to_dvui(keysym: i32) dvui.enums.Key {
    return switch (keysym) {
        c.SDLK_A => .a,
        c.SDLK_B => .b,
        c.SDLK_C => .c,
        c.SDLK_D => .d,
        c.SDLK_E => .e,
        c.SDLK_F => .f,
        c.SDLK_G => .g,
        c.SDLK_H => .h,
        c.SDLK_I => .i,
        c.SDLK_J => .j,
        c.SDLK_K => .k,
        c.SDLK_L => .l,
        c.SDLK_M => .m,
        c.SDLK_N => .n,
        c.SDLK_O => .o,
        c.SDLK_P => .p,
        c.SDLK_Q => .q,
        c.SDLK_R => .r,
        c.SDLK_S => .s,
        c.SDLK_T => .t,
        c.SDLK_U => .u,
        c.SDLK_V => .v,
        c.SDLK_W => .w,
        c.SDLK_X => .x,
        c.SDLK_Y => .y,
        c.SDLK_Z => .z,

        c.SDLK_0 => .zero,
        c.SDLK_1 => .one,
        c.SDLK_2 => .two,
        c.SDLK_3 => .three,
        c.SDLK_4 => .four,
        c.SDLK_5 => .five,
        c.SDLK_6 => .six,
        c.SDLK_7 => .seven,
        c.SDLK_8 => .eight,
        c.SDLK_9 => .nine,

        c.SDLK_F1 => .f1,
        c.SDLK_F2 => .f2,
        c.SDLK_F3 => .f3,
        c.SDLK_F4 => .f4,
        c.SDLK_F5 => .f5,
        c.SDLK_F6 => .f6,
        c.SDLK_F7 => .f7,
        c.SDLK_F8 => .f8,
        c.SDLK_F9 => .f9,
        c.SDLK_F10 => .f10,
        c.SDLK_F11 => .f11,
        c.SDLK_F12 => .f12,

        c.SDLK_KP_DIVIDE => .kp_divide,
        c.SDLK_KP_MULTIPLY => .kp_multiply,
        c.SDLK_KP_MINUS => .kp_subtract,
        c.SDLK_KP_PLUS => .kp_add,
        c.SDLK_KP_ENTER => .kp_enter,
        c.SDLK_KP_0 => .kp_0,
        c.SDLK_KP_1 => .kp_1,
        c.SDLK_KP_2 => .kp_2,
        c.SDLK_KP_3 => .kp_3,
        c.SDLK_KP_4 => .kp_4,
        c.SDLK_KP_5 => .kp_5,
        c.SDLK_KP_6 => .kp_6,
        c.SDLK_KP_7 => .kp_7,
        c.SDLK_KP_8 => .kp_8,
        c.SDLK_KP_9 => .kp_9,
        c.SDLK_KP_PERIOD => .kp_decimal,

        c.SDLK_RETURN => .enter,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_TAB => .tab,
        c.SDLK_LSHIFT => .left_shift,
        c.SDLK_RSHIFT => .right_shift,
        c.SDLK_LCTRL => .left_control,
        c.SDLK_RCTRL => .right_control,
        c.SDLK_LALT => .left_alt,
        c.SDLK_RALT => .right_alt,
        c.SDLK_LGUI => .left_command,
        c.SDLK_RGUI => .right_command,
        c.SDLK_MENU => .menu,
        c.SDLK_NUMLOCKCLEAR => .num_lock,
        c.SDLK_CAPSLOCK => .caps_lock,
        c.SDLK_PRINTSCREEN => .print,
        c.SDLK_SCROLLLOCK => .scroll_lock,
        c.SDLK_PAUSE => .pause,
        c.SDLK_DELETE => .delete,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_INSERT => .insert,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_SPACE => .space,
        c.SDLK_MINUS => .minus,
        c.SDLK_EQUALS => .equal,
        c.SDLK_LEFTBRACKET => .left_bracket,
        c.SDLK_RIGHTBRACKET => .right_bracket,
        c.SDLK_BACKSLASH => .backslash,
        c.SDLK_SEMICOLON => .semicolon,
        c.SDLK_APOSTROPHE => .apostrophe,
        c.SDLK_COMMA => .comma,
        c.SDLK_PERIOD => .period,
        c.SDLK_SLASH => .slash,
        c.SDLK_GRAVE => .grave,

        else => blk: {
            log.debug("SDL_keysym_to_dvui unknown keysym {d}", .{keysym});
            break :blk .unknown;
        },
    };
}

pub fn getSDLVersion() std.SemanticVersion {
    const v: u32 = @bitCast(c.SDL_GetVersion());
    return .{
        .major = @divTrunc(v, 1000000),
        .minor = @mod(@divTrunc(v, 1000), 1000),
        .patch = @mod(v, 1000),
    };
}

// This must be exposed in the app's root source file.
pub fn main() !u8 {
    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;

    if (builtin.os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    if ((sdl_options.callbacks orelse true) and (builtin.target.os.tag == .macos or builtin.target.os.tag == .windows)) {
        // We are using sdl's callbacks to support rendering during OS resizing

        // For programs that provide their own entry points instead of relying on SDL's main function
        // macro magic, 'SDL_SetMainReady()' should be called before calling 'SDL_Init()'.
        c.SDL_SetMainReady();

        // This is more or less what 'SDL_main.h' does behind the curtains.
        const status = c.SDL_EnterAppMainCallbacks(0, null, appInit, appIterate, appEvent, appQuit);

        return @bitCast(@as(i8, @truncate(status)));
    }

    log.info("version: {f} no callbacks", .{getSDLVersion()});

    const init_opts = app.config.get();

    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    const gpa = gpa_instance.allocator();

    // init SDL backend (creates and owns OS window)
    var back = try initWindow(.{
        .allocator = gpa,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
    });
    defer back.deinit();

    toErr(c.SDL_EnableScreenSaver(), "SDL_EnableScreenSaver in sdl main") catch {};

    //// init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, back.backend(), init_opts.window_init_options);
    defer win.deinit();

    if (app.initFn) |initFn| {
        try win.begin(win.frame_time_ns);
        try initFn(&win);
        _ = try win.end(.{});
    }
    defer if (app.deinitFn) |deinitFn| deinitFn();

    var interrupted = false;

    main_loop: while (true) {

        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        const quit = try back.addAllEvents(&win);
        if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        try toErr(c.SDL_SetRenderDrawColor(back.renderer, 0, 0, 0, 255), "SDL_SetRenderDrawColor in sdl main");
        try toErr(c.SDL_RenderClear(back.renderer), "SDL_RenderClear in sdl main");

        const res = try app.frameFn();

        const end_micros = try win.end(.{});

        try back.setCursor(win.cursorRequested());
        try back.textInputRect(win.textInputRequested());

        try back.renderPresent();

        if (res != .ok) break :main_loop;

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_event_micros);
    }

    return 0;
}

/// used when doing sdl callbacks
const CallbackState = struct {
    win: dvui.Window,
    back: SDLBackend,
    gpa: std.heap.GeneralPurposeAllocator(.{}) = .init,
    interrupted: bool = false,
    have_resize: bool = false,
    no_wait: bool = false,
};

/// used when doing sdl callbacks
var appState: CallbackState = .{ .win = undefined, .back = undefined };

// sdl3 callback
fn appInit(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    _ = argc;
    _ = argv;
    //_ = c.SDL_SetAppMetadata("dvui-demo", "0.1", "com.example.dvui-demo");

    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;

    log.info("version: {f} callbacks", .{getSDLVersion()});

    const init_opts = app.config.get();

    const gpa = appState.gpa.allocator();

    // init SDL backend (creates and owns OS window)
    appState.back = initWindow(.{
        .allocator = gpa,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
    }) catch |err| {
        log.err("initWindow failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    toErr(c.SDL_EnableScreenSaver(), "SDL_EnableScreenSaver in sdl main") catch {};

    //// init dvui Window (maps onto a single OS window)
    appState.win = dvui.Window.init(@src(), gpa, appState.back.backend(), app.config.options.window_init_options) catch |err| {
        log.err("dvui.Window.init failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    if (app.initFn) |initFn| {
        appState.win.begin(appState.win.frame_time_ns) catch |err| {
            log.err("dvui.Window.begin failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };

        initFn(&appState.win) catch |err| {
            log.err("dvui.App.initFn failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };

        _ = appState.win.end(.{}) catch |err| {
            log.err("dvui.Window.end failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };
    }

    return c.SDL_APP_CONTINUE;
}

// sdl3 callback
// This function runs once at shutdown.
fn appQuit(_: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    _ = result;

    const app = dvui.App.get() orelse unreachable;
    if (app.deinitFn) |deinitFn| deinitFn();
    appState.win.deinit();
    appState.back.deinit();
    if (appState.gpa.deinit() != .ok) @panic("Memory leak on exit!");

    // SDL will clean up the window/renderer for us.
}

// sdl3 callback
// This function runs when a new event (mouse input, keypresses, etc) occurs.
fn appEvent(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    if (event.?.type == c.SDL_EVENT_USER) {
        // SDL3 says this function might be called on whatever thread pushed
        // the event.  Events from SDL itself are always on the main thread.
        // EVENT_USER is what we use from other threads to wake dvui up, so to
        // prevent concurrent access return early.
        return c.SDL_APP_CONTINUE;
    }

    const e = event.?.*;
    _ = appState.back.addEvent(&appState.win, e) catch |err| {
        log.err("dvui.Window.addEvent failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    if (event.?.type == c.SDL_EVENT_WINDOW_RESIZED) {
        //std.debug.print("resize {d}x{d}\n", .{e.window.data1, e.window.data2});
        // getting a resize event means we are likely in a callback, so don't call any wait functions
        appState.have_resize = true;
    }

    if (event.?.type == c.SDL_EVENT_QUIT) {
        return c.SDL_APP_SUCCESS; // end the program, reporting success to the OS.
    }

    return c.SDL_APP_CONTINUE;
}

// sdl3 callback
// This function runs once per frame, and is the heart of the program.
fn appIterate(_: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    // beginWait coordinates with waitTime below to run frames only when needed
    const nstime = appState.win.beginWait(appState.interrupted or appState.no_wait);

    // marks the beginning of a frame for dvui, can call dvui functions after this
    appState.win.begin(nstime) catch |err| {
        log.err("dvui.Window.begin failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    // if dvui widgets might not cover the whole window, then need to clear
    // the previous frame's render
    toErr(c.SDL_SetRenderDrawColor(appState.back.renderer, 0, 0, 0, 255), "SDL_SetRenderDrawColor in sdl main") catch return c.SDL_APP_FAILURE;
    toErr(c.SDL_RenderClear(appState.back.renderer), "SDL_RenderClear in sdl main") catch return c.SDL_APP_FAILURE;

    const app = dvui.App.get() orelse unreachable;
    const res = app.frameFn() catch |err| {
        log.err("dvui.App.frameFn failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    const end_micros = appState.win.end(.{}) catch |err| {
        log.err("dvui.Window.end failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    appState.back.setCursor(appState.win.cursorRequested()) catch return c.SDL_APP_FAILURE;
    appState.back.textInputRect(appState.win.textInputRequested()) catch return c.SDL_APP_FAILURE;

    appState.back.renderPresent() catch return c.SDL_APP_FAILURE;

    if (res != .ok) return c.SDL_APP_SUCCESS;

    const wait_event_micros = appState.win.waitTime(end_micros);

    //std.debug.print("waitEventTimeout {d} {} resize {}\n", .{wait_event_micros, gno_wait, ghave_resize});

    // If a resize event happens we are likely in a callback.  If for any
    // reason we are called nested while waiting in the below waitEventTimeout
    // we are in a callback.
    //
    // During a callback we don't want to call SDL_WaitEvent or
    // SDL_WaitEventTimeout.  Otherwise all event handling gets screwed up and
    // either never recovers or recovers after many seconds.
    if (appState.no_wait or appState.have_resize) {
        appState.have_resize = false;
        return c.SDL_APP_CONTINUE;
    }

    appState.no_wait = true;
    appState.interrupted = appState.back.waitEventTimeout(wait_event_micros) catch return c.SDL_APP_FAILURE;
    appState.no_wait = false;

    return c.SDL_APP_CONTINUE;
}

test {
    //std.debug.print("{s} backend test\n", .{if (sdl3) "SDL3" else "SDL2"});
    std.testing.refAllDecls(@This());
}
