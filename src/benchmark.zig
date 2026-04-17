const std = @import("std");
const benchmark_clock = std.Io.Clock.awake;

pub fn Benchmark(comptime CategoryEnum: type) type {
    const type_info = @typeInfo(CategoryEnum);
    if (type_info != .@"enum") {
        @compileError("Benchmark expects an enum type");
    }

    const num_categories = type_info.@"enum".fields.len;

    return struct {
        const Self = @This();

        elapsed_times: [num_categories]u64,
        start_times: [num_categories]?std.Io.Timestamp,

        pub fn init() Self {
            return .{
                .elapsed_times = [_]u64{0} ** num_categories,
                .start_times = [_]?std.Io.Timestamp{null} ** num_categories,
            };
        }

        pub fn reset(self: *Self) void {
            self.elapsed_times = [_]u64{0} ** num_categories;
            self.start_times = [_]?std.Io.Timestamp{null} ** num_categories;
        }

        pub fn start(self: *Self, category: CategoryEnum) void {
            self.start_times[@intFromEnum(category)] = std.Io.Timestamp.now(std.Options.debug_io, benchmark_clock);
        }

        pub fn stop(self: *Self, category: CategoryEnum) u64 {
            const end_time = std.Io.Timestamp.now(std.Options.debug_io, benchmark_clock);
            const index = @intFromEnum(category);

            if (self.start_times[index]) |start_time| {
                const elapsed = @as(u64, @intCast(start_time.durationTo(end_time).toNanoseconds()));
                self.elapsed_times[index] += elapsed;
                self.start_times[index] = null;
                return elapsed;
            }

            return 0;
        }

        pub fn printSummary(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.writeAll("=== Benchmark Summary ===\n");
            inline for (type_info.@"enum".fields, 0..) |field, i| {
                const elapsed_ns = self.elapsed_times[i];
                const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
                try writer.print("  {s}: {d:.3} ms ({d} ns)\n", .{
                    field.name,
                    elapsed_ms,
                    elapsed_ns,
                });
            }
        }
    };
}
