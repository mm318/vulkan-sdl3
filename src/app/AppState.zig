const std = @import("std");
const dvui = @import("vulkan_engine").dvui;
const VulkanEngine = @import("vulkan_engine");
const Game = @import("Game.zig");
const Benchmark = @import("benchmark.zig").Benchmark;

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

const Activities = enum { compute_game, draw_game, draw_ui };

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
last_error: ?anyerror = null,
game: Game,
last_time: u64 = 0,
seed: u64 = 0,
percent: u7 = 5,

// Rendering state
render_objects: std.ArrayList(VulkanEngine.RenderObject) = .{},
needs_render_update: bool = true,

ui: Ui,

benchmark: Benchmark(Activities) = Benchmark(Activities).init(),

/// Updates RenderObjects for a grid of cells (Game of Life)
/// grid_state: array where true = alive (white), false = dead (don't render)
/// grid_width, grid_height: dimensions of the grid
/// cell_size: size of each cell in world units
/// cell_gap: gap between cells in world units
fn updateGridObjects(
    allocator: std.mem.Allocator,
    objects: *std.ArrayList(VulkanEngine.RenderObject),
    engine: *const VulkanEngine,
    grid_state: []const bool,
    grid_width: usize,
    grid_height: usize,
    cell_size: f32,
    cell_gap: f32,
) []VulkanEngine.RenderObject {
    objects.clearRetainingCapacity();

    // Create transform matrix: scale to cell_size, then translate to position
    const scale_mat = VulkanEngine.Mat4.scale(VulkanEngine.Vec3.make(cell_size, cell_size, 1.0));
    for (0..grid_height) |y| {
        for (0..grid_width) |x| {
            const index = y * grid_width + x;

            // Only create render objects for alive cells (white squares)
            if (grid_state[index]) {
                const x_pos = @as(f32, @floatFromInt(x)) * (cell_size + cell_gap);
                const y_pos = @as(f32, @floatFromInt(y)) * (cell_size + cell_gap);

                // Matrix multiplication order: we want T * S, so we do translation.mul(scale)
                const trans_mat = VulkanEngine.Mat4.translation(VulkanEngine.Vec3.make(x_pos, y_pos, 0.0));
                const transform = trans_mat.mul(scale_mat);

                objects.append(allocator, VulkanEngine.RenderObject{
                    .mesh = &engine.quad_mesh,
                    .material = &engine.material,
                    .transform = transform,
                }) catch @panic("OOM");
            }
        }
    }

    return objects.items;
}

pub fn updateRenderObjects(self: *AppState, engine: *const VulkanEngine) []VulkanEngine.RenderObject {
    if (!self.needs_render_update) {
        return self.render_objects.items;
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
    const cell_gap = 0;

    // std.log.debug("Cell size: {d:.3}, gap: {d:.3}", .{ cell_size, cell_gap });

    // Create render objects for the actual game grid
    const render_objects = updateGridObjects(
        self.gpa,
        &self.render_objects,
        engine,
        self.game.grid.grid,
        self.game.width,
        self.game.height,
        cell_size,
        cell_gap,
    );
    std.log.debug(
        "Created {} render objects for grid {}x{}",
        .{ render_objects.len, self.game.width, self.game.height },
    );

    self.needs_render_update = false;

    return self.render_objects.items;
}

pub fn drawGame(self: *AppState, engine: *VulkanEngine) void {
    self.benchmark.start(.draw_game);
    defer _ = self.benchmark.stop(.draw_game);

    // Update render objects if needed
    const render_objects = self.updateRenderObjects(engine);

    // Render the grid
    engine.draw_objects(render_objects);
}

pub fn iterate(self: *AppState, current_time: u64) void {
    self.benchmark.start(.compute_game);
    defer _ = self.benchmark.stop(.compute_game);

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

pub fn handleUi(self: *AppState, window: *dvui.Window) void {
    self.benchmark.start(.draw_ui);
    defer _ = self.benchmark.stop(.draw_ui);

    const gpa = self.gpa;
    const arena = self.arena.allocator();
    const ui = &self.ui;
    {
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
}

pub fn deinit(self: *AppState) void {
    const gpa = self.gpa;
    self.render_objects.deinit(gpa);
    self.game.deinit(gpa);
    self.* = undefined;
    gpa.destroy(self);
}
