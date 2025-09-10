const std = @import("std");
const Game = @import("Game.zig");
const zbench = @import("zbench");

var game: Game = undefined;

test "benchmark" {
    const gpa = std.testing.allocator;
    var bench = zbench.Benchmark.init(gpa, .{});
    defer bench.deinit();

    game = try Game.init(gpa, 1280, 720);
    defer game.deinit(gpa);

    game.reset();
    game.fill(0, 25);

    try bench.add("live", benchLive, .{});
    try bench.run(std.io.getStdErr().writer());
}

fn benchLive(_: std.mem.Allocator) void {
    std.mem.doNotOptimizeAway(game.live());
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    game = try Game.init(gpa, 1280, 720);
    defer game.deinit(gpa);

    game.reset();
    game.fill(0, 25);

    for (0..100) |_| {
        std.mem.doNotOptimizeAway(game.live());
    }
}
