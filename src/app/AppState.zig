const std = @import("std");

const Game = @import("Game.zig");

const AppState = @This();

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

pub fn deinit(self: *AppState) void {
    const gpa = self.gpa;
    self.game.deinit(gpa);
    self.* = undefined;
    gpa.destroy(self);
}
