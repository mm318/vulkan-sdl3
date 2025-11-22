const std = @import("std");
const dvui = @import("vulkan_engine").dvui;
const VulkanEngine = @import("vulkan_engine");
const Game = @import("Game.zig");

const AppState = @This();

const log = std.log.scoped(.app_state);

pub const width = 1280;
pub const height = 720;

pub const Ui = struct {
    seed_text_input: []u8 = &.{},
    seed_text_valid: bool = true,
    percent_slider: f32 = 0.05 * 4,
    repeat: f32 = 0.0,
    wait: f32 = 1.0,
    randomize_seed: bool = false,

    pub fn normalizeWait(self: *const Ui) u64 {
        return @intFromFloat(self.wait * 1000.0);
    }

    pub fn normalizeRepeat(self: *const Ui) usize {
        return @intFromFloat(self.repeat * 1000.0 + 1.0);
    }

    pub fn normalizePercent(self: *const Ui) u7 {
        const percents: u7 = @intFromFloat(self.percent_slider * 100.0 / 4.0);
        if (percents == 0) return 1;
        return percents;
    }
};

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
last_error: ?anyerror = null,
game: Game,
last_time: u64 = 0,
seed: u64 = 0,
percent: u7 = 5,

ui: Ui,

// Rendering state
engine: ?*VulkanEngine = null,
render_objects: []VulkanEngine.RenderObject = &.{},
needs_render_update: bool = true,

pub fn iterate(self: *AppState, current_time: u64) void {
    const wait_time: u64 = self.ui.normalizeWait();
    const repeats: usize = self.ui.normalizeRepeat();
    if (wait_time == 0) {
        for (0..repeats) |_| {
            self.game.live();
            self.needs_render_update = true;
        }
    } else {
        if (current_time -| wait_time > self.last_time) {
            for (0..repeats) |_| {
                self.game.live();
                self.needs_render_update = true;
            }
            self.last_time = current_time;
        }
    }
}

pub fn drawGame(self: *AppState) void {
    const engine = self.engine orelse return;

    // Update render objects if needed
    self.updateRenderObjects(engine);

    std.log.info("drawGame: about to render {} objects", .{self.render_objects.len});

    // Render the grid
    engine.render_grid_objects(self.render_objects);
}

pub fn handleUi(self: *AppState, window: *dvui.Window) void {
    const gpa = self.gpa;
    const arena = self.arena.allocator();
    const ui = &self.ui;
    {
        window.begin(std.time.nanoTimestamp()) catch @panic("window.begin() failed");

        var float = dvui.floatingWindow(@src(), .{
            .center_on = .{ .x = width - 280, .y = 0, .w = 280, .h = height },
        }, .{});
        defer float.deinit();

        _ = dvui.windowHeader("Controls", "", null);

        dvui.label(@src(), "Generation: {d}", .{self.game.generation}, .{});

        dvui.label(@src(), "Repeats: {d}", .{ui.normalizeRepeat()}, .{});
        _ = dvui.slider(@src(), .{ .fraction = &ui.repeat }, .{ .expand = .horizontal });

        dvui.label(@src(), "Wait time: {d} ms", .{ui.normalizeWait()}, .{});
        _ = dvui.slider(@src(), .{ .fraction = &ui.wait }, .{ .expand = .horizontal });

        if (dvui.labelClick(@src(), "Seed: {d}", .{self.seed}, .{}, .{})) {
            const str_seed = std.fmt.allocPrintSentinel(arena, "{d}", .{self.seed}, 0) catch @panic("allocation failure");
            defer arena.free(str_seed);

            window.backend.clipboardTextSet(str_seed) catch log.warn("failed to set clipboard text", .{});
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

        dvui.label(@src(), "Fill percent: {d:2}%", .{self.percent}, .{});
        _ = dvui.slider(@src(), .{ .fraction = &ui.percent_slider }, .{ .expand = .horizontal });

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
                self.seed = new_seed;
            }
            self.percent = ui.normalizePercent();
            if (ui.randomize_seed) {
                self.seed = @bitCast(std.time.milliTimestamp());
            }

            self.game.reset();
            self.game.fill(self.seed, self.percent);
            self.game.live();
        }

        // if (window.cursorRequestedFloating()) |cursor| {
        //     // cursor is over floating window, dvui sets it
        //     try ui.backend.setCursor(cursor);
        // } else {
        //     // cursor should be handled by application
        //     try ui.backend.setCursor(.bad);
        // }
        // try ui.backend.textInputRect(window.textInputRequested());
    }

    _ = window.end(.{}) catch @panic("win.end() failed");
}

pub fn updateRenderObjects(self: *AppState, engine: *VulkanEngine) void {
    if (!self.needs_render_update) return;

    // Free old render objects
    if (self.render_objects.len > 0) {
        self.gpa.free(self.render_objects);
    }

    // Calculate cell size to fit the grid nicely
    const grid_width_f: f32 = @floatFromInt(self.game.width);
    const grid_height_f: f32 = @floatFromInt(self.game.height);

    // Adjust these to fit your desired grid appearance
    const viewport_width: f32 = 130.0; // Should match draw_objects grid_width
    const viewport_height: f32 = 75.0; // Should match draw_objects grid_height

    const cell_size_x = (viewport_width * 0.95) / grid_width_f;
    const cell_size_y = (viewport_height * 0.95) / grid_height_f;
    const cell_size = @min(cell_size_x, cell_size_y); // Use smaller to maintain aspect ratio
    const cell_gap = cell_size * 0.05; // 5% gap

    std.log.info("Cell size: {d:.3}, gap: {d:.3}", .{ cell_size, cell_gap });

    // Create render objects for the actual game grid
    self.render_objects = VulkanEngine.create_grid_objects(
        self.gpa,
        &engine.quad_mesh,
        &engine.default_material,
        self.game.grid.grid,
        self.game.width,
        self.game.height,
        cell_size,
        cell_gap,
    );

    std.log.info("Created {} render objects for grid {}x{}", .{ self.render_objects.len, self.game.width, self.game.height });

    self.needs_render_update = false;
}

pub fn deinit(self: *AppState) void {
    const gpa = self.gpa;
    if (self.render_objects.len > 0) {
        gpa.free(self.render_objects);
    }
    self.game.deinit(gpa);
    self.* = undefined;
    gpa.destroy(self);
}
