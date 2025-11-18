const std = @import("std");
const builtin = @import("builtin");

const AppState = @import("AppState.zig");
const Game = @import("Game.zig");
const VulkanEngine = @import("vulkan_engine");

var debug_allocator = std.heap.DebugAllocator(.{}).init;

pub const std_options = std.Options{
    .log_level = if (builtin.mode != .Debug) .info else .debug,
};

const mlog = std.log.scoped(.main);

const texture_width = AppState.width / 10;
const texture_height = AppState.height / 10;

fn buildTimeVersion() std.SemanticVersion {
    return std.SemanticVersion{
        .major = VulkanEngine.c.SDL.MAJOR_VERSION,
        .minor = VulkanEngine.c.SDL.MINOR_VERSION,
        .patch = VulkanEngine.c.SDL.MICRO_VERSION,
    };
}

fn runTimeVersion() std.SemanticVersion {
    const version = VulkanEngine.c.SDL.GetVersion();
    return std.SemanticVersion{
        .major = @intCast(VulkanEngine.c.SDL.VERSION_NUM_MAJOR(version)),
        .minor = @intCast(VulkanEngine.c.SDL.VERSION_NUM_MINOR(version)),
        .patch = @intCast(VulkanEngine.c.SDL.VERSION_NUM_MICRO(version)),
    };
}

fn logSdlInfo(log: anytype) void {
    log.debug("SDL build time version: {f}", .{buildTimeVersion()});
    log.debug("SDL build time revision: {s}", .{VulkanEngine.c.SDL.REVISION});

    log.debug("SDL runtime version: {f}", .{runTimeVersion()});
    const revision: [*:0]const u8 = VulkanEngine.c.SDL.GetRevision();
    log.debug("SDL runtime revision: {s}", .{revision});
}

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer {
        if (is_debug) {
            std.debug.assert(debug_allocator.deinit() == .ok);
        }
    }

    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buff) catch @panic("cwd_buff too small");
    std.log.info("Running from: {s}", .{cwd});

    const state = try gpa.create(AppState);
    state.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .game = try Game.init(gpa, texture_width, texture_height),
        .seed = @bitCast(std.time.milliTimestamp()),
        .ui = .{},
    };
    defer state.deinit();

    state.game.fill(state.seed, state.percent);
    state.game.live(); // remove random noise

    logSdlInfo(mlog);

    var engine = VulkanEngine.init(
        gpa,
        .{ .width = AppState.width, .height = AppState.height },
        AppState,
        state,
        AppState.iterate,
        AppState.drawGame,
        AppState.handleUi,
    );
    defer engine.cleanup();

    engine.init_scene(); // TODO: plug whatever is needed for appIterate() here
    engine.init_gui(); // TODO: plug handleUi() here

    engine.run();
}
