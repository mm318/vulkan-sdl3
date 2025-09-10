const std = @import("std");
const builtin = @import("builtin");

const VulkanEngine = @import("vulkan/VulkanEngine.zig");

var debug_allocator = std.heap.DebugAllocator(.{}).init;
var gpa: ?std.mem.Allocator = null;

pub const std_options = std.Options{
    .log_level = if (builtin.mode != .Debug) .info else .debug,
};

pub fn main() !void {
    gpa, const is_debug = gpa: {
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

    var engine = VulkanEngine.init(gpa.?);
    defer engine.cleanup();

    // engine.load_textures();
    // engine.load_meshes();
    // engine.init_scene();
    // engine.init_imgui();

    engine.run();
}
