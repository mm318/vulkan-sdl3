const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");
const c = SDLBackend.c;

const AppState = @import("AppState.zig");

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
const gpa = gpa_instance.allocator();

const vsync = true;
const min_refresh_fps: f32 = 30.0;
const show_demo = false;
const show_debug_window = false;

var open_debug_window_next_frame = show_debug_window;

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
        .size = .{
            .w = @floatFromInt(AppState.width),
            .h = @floatFromInt(AppState.height),
        },
        .min_size = .{ .w = 320.0, .h = 240.0 },
        .vsync = vsync,
        .title = "Sample Vulkan 2D Application",
    });
    defer backend.deinit();

    _ = c.SDL_EnableScreenSaver();

    var app = try AppState.init(gpa);
    defer app.deinit();
    app.resetGame();

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
        app.iterate(AppState.currentTimeMillis());
        const keep_running = gui_frame(&win, &app) and !quit;

        const end_micros = try win.end(.{});

        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (!keep_running) break :main_loop;

        const wait_event_micros = @min(win.waitTime(end_micros), max_wait_between_frames_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn gui_frame(win: *dvui.Window, app: *AppState) bool {
    {
        var root = dvui.box(@src(), .{}, .{
            .name = "main",
            .expand = .both,
        });
        defer root.deinit();

        app.drawGame(root.data().contentRectScale().r);
    }

    app.handleUi();

    if (open_debug_window_next_frame) {
        dvui.toggleDebugWindow();
        open_debug_window_next_frame = false;
    }

    if (show_demo) {
        dvui.Examples.demo();
    }

    _ = win;
    return checkQuit();
}

fn checkQuit() bool {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }
    return true;
}
