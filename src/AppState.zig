const std = @import("std");
const dvui = @import("dvui");

const Benchmark = @import("benchmark.zig").Benchmark;
const Game = @import("Game.zig");

const AppState = @This();
const log = std.log.scoped(.app_state);
const app_clock = std.Io.Clock.awake;

pub const width: u32 = 1280;
pub const height: u32 = 720;
const grid_width = width / 10;
const grid_height = height / 10;
const controls_width: f32 = 280.0;

pub fn currentTimeMillis() u64 {
    return @intCast(std.Io.Timestamp.now(std.Options.debug_io, app_clock).toMilliseconds());
}

pub const Ui = struct {
    seed_text_input: std.ArrayList(u8) = .empty,
    seed_text_valid: bool = true,
    percent_slider: f32 = 0.05 * 4.0,
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
game: Game,
last_time: u64 = 0,
seed: u64 = 0,
percent: u7 = 5,
ui: Ui,
benchmark: Benchmark(Activities) = Benchmark(Activities).init(),

pub fn init(gpa: std.mem.Allocator) !AppState {
    return .{
        .gpa = gpa,
        .game = try Game.init(gpa, grid_width, grid_height),
        .seed = currentTimeMillis(),
        .ui = .{},
    };
}

pub fn resetGame(self: *AppState) void {
    self.game.reset();
    self.game.fill(self.seed, self.percent);
    self.game.live();
    self.last_time = currentTimeMillis();
}

pub fn iterate(self: *AppState, current_time: u64) void {
    self.benchmark.start(.compute_game);
    defer _ = self.benchmark.stop(.compute_game);

    const wait_time = self.ui.normalizeWait();
    const repeats = self.ui.normalizeRepeat();

    if (wait_time == 0) {
        for (0..repeats) |_| self.game.live();
        return;
    }

    if (current_time -| wait_time > self.last_time) {
        for (0..repeats) |_| self.game.live();
        self.last_time = current_time;
    }
}

pub fn drawGame(self: *AppState, bounds: dvui.Rect.Physical) void {
    self.benchmark.start(.draw_game);
    defer _ = self.benchmark.stop(.draw_game);

    if (bounds.empty()) return;

    bounds.fill(.{}, .{ .color = dvui.Color.black });

    const grid_width_f: f32 = @floatFromInt(self.game.width);
    const grid_height_f: f32 = @floatFromInt(self.game.height);
    const cell_size = @min(bounds.w / grid_width_f, bounds.h / grid_height_f);
    if (cell_size <= 0) return;

    const draw_width = cell_size * grid_width_f;
    const draw_height = cell_size * grid_height_f;
    const origin_x = bounds.x + @floor((bounds.w - draw_width) / 2.0);
    const origin_y = bounds.y + @floor((bounds.h - draw_height) / 2.0);

    var it = self.game.iterator();
    while (it.next()) |cell| {
        if (!cell.alive) continue;

        const x0 = @floor(origin_x + cell_size * @as(f32, @floatFromInt(cell.x)));
        const y0 = @floor(origin_y + cell_size * @as(f32, @floatFromInt(cell.y)));
        const x1 = @ceil(origin_x + cell_size * @as(f32, @floatFromInt(cell.x + 1)));
        const y1 = @ceil(origin_y + cell_size * @as(f32, @floatFromInt(cell.y + 1)));

        const cell_rect: dvui.Rect.Physical = .{
            .x = x0,
            .y = y0,
            .w = @max(1.0, x1 - x0),
            .h = @max(1.0, y1 - y0),
        };
        cell_rect.fill(.{}, .{ .color = dvui.Color.white });
    }
}

pub fn handleUi(self: *AppState) void {
    self.benchmark.start(.draw_ui);
    defer _ = self.benchmark.stop(.draw_ui);

    const ui = &self.ui;
    const wr = dvui.windowRect();

    var float = dvui.floatingWindow(@src(), .{
        .center_on = .{
            .x = wr.w - controls_width,
            .y = 0,
            .w = controls_width,
            .h = wr.h,
        },
    }, .{});
    defer float.deinit();

    float.dragAreaSet(dvui.windowHeader("Controls", "", null));

    dvui.label(@src(), "Generation: {d}", .{self.game.generation}, .{});

    dvui.label(@src(), "Repeats: {d}", .{ui.normalizeRepeat()}, .{});
    _ = dvui.slider(@src(), .{ .fraction = &ui.repeat }, .{ .expand = .horizontal });

    dvui.label(@src(), "Wait time: {d} ms", .{ui.normalizeWait()}, .{});
    _ = dvui.slider(@src(), .{ .fraction = &ui.wait }, .{ .expand = .horizontal });

    if (dvui.labelClick(@src(), "Seed: {d}", .{self.seed}, .{}, .{})) {
        var seed_buf: [32]u8 = undefined;
        const seed_str = std.fmt.bufPrint(&seed_buf, "{d}", .{self.seed}) catch "";
        dvui.clipboardTextSet(seed_str);
    }

    _ = dvui.checkbox(@src(), &ui.randomize_seed, "Randomize seed?", .{});

    const custom_seed_len = if (!ui.randomize_seed) blk: {
        const text_entry = dvui.textEntry(@src(), .{
            .placeholder = "custom seed",
            .scroll_vertical = false,
            .scroll_horizontal = true,
            .text = .{ .array_list = .{
                .backing = &ui.seed_text_input,
                .allocator = self.gpa,
                .limit = 64,
            } },
        }, .{
            .expand = .horizontal,
            .color_border = if (ui.seed_text_valid) null else dvui.Color.red,
        });
        defer text_entry.deinit();
        break :blk text_entry.len;
    } else 0;

    dvui.label(@src(), "Fill percent: {d:2}%", .{self.percent}, .{});
    _ = dvui.slider(@src(), .{ .fraction = &ui.percent_slider }, .{ .expand = .horizontal });

    if (dvui.button(@src(), "Start over", .{ .draw_focus = false }, .{ .expand = .horizontal })) btn: {
        if (custom_seed_len != 0) {
            const new_seed = std.fmt.parseInt(u64, ui.seed_text_input.items[0..custom_seed_len], 10) catch {
                ui.seed_text_valid = false;
                break :btn;
            };
            ui.seed_text_valid = true;
            self.seed = new_seed;
        }

        self.percent = ui.normalizePercent();
        if (ui.randomize_seed) {
            self.seed = currentTimeMillis();
        }

        self.resetGame();
    }
}

pub fn deinit(self: *AppState) void {
    self.ui.seed_text_input.deinit(self.gpa);
    self.game.deinit(self.gpa);
    self.* = undefined;
}
