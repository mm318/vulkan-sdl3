const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const AppState = @import("AppState.zig");
const dvui = @import("dvui");
const Game = @import("Game.zig");
const SdlBackend = dvui.backend;

const width = 1280;
const height = 720;
const texture_width = width / 10;
const texture_height = height / 10;

pub fn appInit(gpa: std.mem.Allocator, _: [][*:0]u8) !*AppState {
    const log = std.log.scoped(.init);

    try sdl.setHint("SDL_HINT_WINDOWS_DPI_SCALING", "1");
    try sdl.setHint(c.SDL_HINT_RENDER_VSYNC, "1");
    try sdl.setAppMetadata("Game of Life", "dev", "cc.knightpp.game_of_life");
    try sdl.initialize(c.SDL_INIT_VIDEO);

    var window: *c.SDL_Window = undefined;
    var renderer: *c.SDL_Renderer = undefined;
    try sdl.createWindowAndRenderer(
        "Game of Life",
        width,
        height,
        sdl.c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        &window,
        &renderer,
    );
    errdefer c.SDL_DestroyWindow(window);
    errdefer c.SDL_DestroyRenderer(renderer);

    {
        log.debug(
            "SDL render drivers: renderer={s} num_render_drivers={d}",
            .{
                c.SDL_GetRendererName(renderer).?,
                c.SDL_GetNumRenderDrivers(),
            },
        );
        var i: c_int = 0;
        while (i < c.SDL_GetNumRenderDrivers()) : (i += 1) {
            log.debug("{d}) {s}", .{ i + 1, c.SDL_GetRenderDriver(i) });
        }
    }

    const pma_blend = c.SDL_ComposeCustomBlendMode(
        c.SDL_BLENDFACTOR_ONE,
        c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        c.SDL_BLENDOPERATION_ADD,
        c.SDL_BLENDFACTOR_ONE,
        c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        c.SDL_BLENDOPERATION_ADD,
    );
    try sdl.setRenderDrawBlendMode(renderer, pma_blend);

    const texture = try sdl.createTexture(
        renderer,
        .rgbx8888,
        .streaming,
        texture_width,
        texture_height,
    );
    errdefer sdl.destroyTexture(texture);

    try sdl.setTextureScaleMode(texture, .nearest);

    const state = try gpa.create(AppState);
    errdefer gpa.destroy(state);

    var game = try Game.init(gpa, texture_width, texture_height);
    errdefer game.deinit(gpa);

    state.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .window = window,
        .renderer = renderer,
        .texture = texture,
        .game = game,
        .ui = .{
            .backend = SdlBackend.init(window, renderer),
            .window = undefined,
        },
    };

    try parseArgs(gpa, state);

    game.fill(state.seed, state.percent);
    game.live(); // remove random noise

    const backend = &state.ui.backend;
    backend.initial_scale = c.SDL_GetDisplayContentScale(c.SDL_GetDisplayForWindow(window));
    state.ui.window = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .arena = state.arena,
    });
    errdefer state.ui.window.deinit();

    // state.ui.backend.initial_scale = c.SDL_GetDisplayContentScale(c.SDL_GetDisplayForWindow(window));
    // log.info("SDL3 backend scale {d}", .{state.ui.backend.initial_scale});

    queryAndSetTheme(state);

    return state;
}

pub fn appIterate(state: *AppState) !c.SDL_AppResult {
    _ = state.arena.reset(.retain_capacity);
    try sdl.renderClear(state.renderer);

    const wait_time: u64 = state.ui.normalizeWait();
    const repeats: usize = state.ui.normalizeRepeat();
    if (wait_time == 0) {
        for (0..repeats) |_| {
            state.game.live();
        }
    } else {
        const current_time = sdl.getTicks();
        if (current_time -| wait_time > state.last_time) {
            for (0..repeats) |_| {
                state.game.live();
            }

            state.last_time = current_time;
        }
    }

    try drawGameOnTexture(state);
    try sdl.renderTexture(state.renderer, state.texture, null, null);
    try handleUi(state);

    try sdl.renderPresent(state.renderer);

    return c.SDL_APP_CONTINUE;
}

pub fn appEvent(state: *AppState, event: *c.SDL_Event) !c.SDL_AppResult {
    const log = std.log.scoped(.event);

    if (try state.ui.backend.addEvent(&state.ui.window, event.*)) {
        return c.SDL_APP_CONTINUE;
    }

    switch (event.type) {
        c.SDL_EVENT_QUIT => return c.SDL_APP_SUCCESS,
        c.SDL_EVENT_KEY_DOWN | c.SDL_EVENT_KEY_UP => {
            const scancode_name = c.SDL_GetScancodeName(event.key.scancode);
            log.debug("event on {s}", .{scancode_name});
        },
        c.SDL_EVENT_SYSTEM_THEME_CHANGED => {
            log.debug("system theme has changed to {s}", .{@tagName(sdl.getSystemTheme())});
            queryAndSetTheme(state);
        },
        else => {},
    }

    return c.SDL_APP_CONTINUE;
}

pub fn appQuit(maybe_state: ?*AppState, result: c.SDL_AppResult) void {
    _ = result;
    if (maybe_state == null) return;

    const state = maybe_state.?;

    state.deinit();
}

fn drawGameOnTexture(state: *AppState) !void {
    var pitch_bytes: c_int = undefined;
    var pixels_many: [*]sdl.PixelRGBX8888 = undefined;

    try sdl.lockTexture(sdl.PixelRGBX8888, state.texture, null, &pixels_many, &pitch_bytes);
    defer sdl.unlockTexture(state.texture);

    std.debug.assert(pitch_bytes > 0);

    const pitch_items = @as(usize, @intCast(@divExact(pitch_bytes, @sizeOf(sdl.PixelRGBX8888)))) * texture_height;
    const pixels = pixels_many[0..pitch_items];

    std.debug.assert(pixels.len == state.game.len());
    for (pixels, 0..) |*pixel, i| {
        if (state.game.at(i)) {
            pixel.* = .{
                .r = 0xff,
                .g = 0xff,
                .b = 0xff,
            };
        } else {
            pixel.* = .{
                .r = 0,
                .g = 0,
                .b = 0,
            };
        }
    }
}

// ui should be rendered last to override the game texture
fn handleUi(state: *AppState) !void {
    const gpa = state.gpa;
    const arena = state.arena.allocator();
    const ui = &state.ui;
    {
        try ui.window.begin(std.time.nanoTimestamp());

        var float = dvui.floatingWindow(@src(), .{}, .{});
        defer float.deinit();

        _ = dvui.windowHeader("Controls", "", null);

        dvui.label(@src(), "Generation: {d}", .{state.game.generation}, .{});

        dvui.label(@src(), "Repeats: {d}", .{ui.normalizeRepeat()}, .{});
        _ = dvui.slider(@src(), .horizontal, &ui.repeat, .{
            .expand = .horizontal,
        });

        dvui.label(@src(), "Wait time: {d} ms", .{ui.normalizeWait()}, .{});
        _ = dvui.slider(@src(), .horizontal, &ui.wait, .{
            .expand = .horizontal,
        });

        if (dvui.labelClick(@src(), "Seed: {d}", .{state.seed}, .{}, .{})) {
            const str_seed = try std.fmt.allocPrintSentinel(arena, "{d}", .{state.seed}, 0);
            defer arena.free(str_seed);

            try sdl.setClipboardText(str_seed);
        }

        _ = dvui.checkbox(@src(), &ui.randomize_seed, "Randomize seed?", .{});

        const custom_seed_len = if (!ui.randomize_seed) blk: {
            const text_entry = dvui.textEntry(@src(), .{
                .placeholder = "custom seed",
                .scroll_vertical = false,
                .scroll_horizontal = true,
                .text = .{ .buffer_dynamic = .{
                    .backing = &ui.seed_text_input,
                    .allocator = gpa,
                    .limit = 64,
                } },
            }, .{
                .expand = .horizontal,
                .color_border = if (ui.seed_text_valid) null else .{ .g = 0, .b = 0 },
            });
            text_entry.deinit();

            break :blk text_entry.len;
        } else 0;

        dvui.label(@src(), "Fill percent: {d:2}%", .{state.percent}, .{});
        _ = dvui.slider(@src(), .horizontal, &ui.percent_slider, .{ .expand = .horizontal });

        if (dvui.button(
            @src(),
            "Start over",
            .{ .draw_focus = false },
            .{ .expand = .horizontal },
        )) btn: {
            if (custom_seed_len != 0) {
                const new_seed = std.fmt.parseInt(u64, ui.seed_text_input[0..custom_seed_len], 10) catch {
                    ui.seed_text_valid = false;
                    break :btn;
                };
                ui.seed_text_valid = true;
                state.seed = new_seed;
            }
            state.percent = ui.normalizePercent();
            if (ui.randomize_seed) {
                state.seed = @bitCast(std.time.milliTimestamp());
            }

            state.game.reset();
            state.game.fill(state.seed, state.percent);
            state.game.live();
        }

        if (ui.window.cursorRequestedFloating()) |cursor| {
            // cursor is over floating window, dvui sets it
            try ui.backend.setCursor(cursor);
        } else {
            // cursor should be handled by application
            try ui.backend.setCursor(.bad);
        }
        try ui.backend.textInputRect(ui.window.textInputRequested());
    }

    _ = try ui.window.end(.{});
}

fn queryAndSetTheme(state: *AppState) void {
    switch (sdl.getSystemTheme()) {
        .light, .unknown => state.ui.window.theme = dvui.Theme.builtin.adwaita_light,
        .dark => state.ui.window.theme = dvui.Theme.builtin.adwaita_dark,
    }
}

fn parseArgs(gpa: std.mem.Allocator, state: *AppState) !void {
    var it = try std.process.argsWithAllocator(gpa);
    defer it.deinit();

    _ = it.next();

    var i: usize = 0;
    while (it.next()) |arg| {
        defer i += 1;

        switch (i) {
            0 => {
                state.seed = try std.fmt.parseInt(u64, arg, 10);
            },
            1 => {
                state.percent = try std.fmt.parseInt(u7, arg, 10);
            },
            else => {
                std.log.err("unknown arg: {s}", .{arg});
                return error.UnknownArg;
            },
        }
    }

    if (i == 0) {
        state.seed = @bitCast(std.time.milliTimestamp());
    }
}
