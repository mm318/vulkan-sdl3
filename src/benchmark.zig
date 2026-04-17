const std = @import("std");
const benchmark_clock = std.Io.Clock.awake;

fn sleepMilliseconds(ms: i64) void {
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = benchmark_clock,
    };
    duration.sleep(std.Options.debug_io) catch unreachable;
}

/// Generic benchmark tracker that creates storage for timing categories at compile time.
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

        pub fn getElapsed(self: *const Self, category: CategoryEnum) u64 {
            return self.elapsed_times[@intFromEnum(category)];
        }

        pub fn getElapsedMs(self: *const Self, category: CategoryEnum) f64 {
            const ns = self.getElapsed(category);
            return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        }

        pub fn getElapsedUs(self: *const Self, category: CategoryEnum) f64 {
            const ns = self.getElapsed(category);
            return @as(f64, @floatFromInt(ns)) / 1_000.0;
        }

        pub fn isRunning(self: *const Self, category: CategoryEnum) bool {
            return self.start_times[@intFromEnum(category)] != null;
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

test "Benchmark basic usage" {
    const TimingCategory = enum { computation, io, rendering };

    var bench = Benchmark(TimingCategory).init();

    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.computation));
    try std.testing.expectEqual(false, bench.isRunning(.computation));

    bench.start(.computation);
    try std.testing.expectEqual(true, bench.isRunning(.computation));

    sleepMilliseconds(1);

    const elapsed = bench.stop(.computation);
    try std.testing.expect(elapsed > 0);
    try std.testing.expectEqual(false, bench.isRunning(.computation));
    try std.testing.expectEqual(elapsed, bench.getElapsed(.computation));

    const first_elapsed = bench.getElapsed(.computation);
    bench.start(.computation);
    sleepMilliseconds(1);
    _ = bench.stop(.computation);

    const total_elapsed = bench.getElapsed(.computation);
    try std.testing.expect(total_elapsed > first_elapsed);
}

test "Benchmark multiple categories" {
    const Categories = enum { category_a, category_b, category_c };
    var bench = Benchmark(Categories).init();

    bench.start(.category_a);
    sleepMilliseconds(1);
    _ = bench.stop(.category_a);

    bench.start(.category_b);
    sleepMilliseconds(2);
    _ = bench.stop(.category_b);

    try std.testing.expect(bench.getElapsed(.category_a) > 0);
    try std.testing.expect(bench.getElapsed(.category_b) > bench.getElapsed(.category_a));
    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.category_c));
}

test "Benchmark reset" {
    const Categories = enum { test_category };
    var bench = Benchmark(Categories).init();

    bench.start(.test_category);
    sleepMilliseconds(1);
    _ = bench.stop(.test_category);

    try std.testing.expect(bench.getElapsed(.test_category) > 0);

    bench.reset();
    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.test_category));
}

test "Benchmark time conversion helpers" {
    const Categories = enum { conversion_test };
    var bench = Benchmark(Categories).init();

    bench.start(.conversion_test);
    sleepMilliseconds(5);
    _ = bench.stop(.conversion_test);

    const elapsed_ms = bench.getElapsedMs(.conversion_test);
    const elapsed_us = bench.getElapsedUs(.conversion_test);

    try std.testing.expect(elapsed_ms >= 4.0 and elapsed_ms <= 10.0);
    try std.testing.expect(elapsed_us >= 4_000.0 and elapsed_us <= 10_000.0);
}
