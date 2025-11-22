const std = @import("std");

/// Generic benchmark tracker that creates storage for timing categories at compile time.
/// Usage:
///   const TimingCategory = enum { render, update, input };
///   var benchmark = Benchmark(TimingCategory).init();
///   benchmark.start(.render);
///   // ... do work ...
///   benchmark.stop(.render);
pub fn Benchmark(comptime CategoryEnum: type) type {
    // Ensure the type is an enum
    const type_info = @typeInfo(CategoryEnum);
    if (type_info != .@"enum") {
        @compileError("Benchmark expects an enum type");
    }

    const num_categories = type_info.@"enum".fields.len;

    return struct {
        const Self = @This();

        /// Storage for elapsed time for each category (in nanoseconds)
        elapsed_times: [num_categories]u64,

        /// Storage for active stopwatch start times (null if not running)
        start_times: [num_categories]?i128,

        /// Initialize a new benchmark tracker with all timings set to zero
        pub fn init() Self {
            return .{
                .elapsed_times = [_]u64{0} ** num_categories,
                .start_times = [_]?i128{null} ** num_categories,
            };
        }

        /// Reset all timing data
        pub fn reset(self: *Self) void {
            self.elapsed_times = [_]u64{0} ** num_categories;
            self.start_times = [_]?i128{null} ** num_categories;
        }

        /// Start timing for a specific category
        pub fn start(self: *Self, category: CategoryEnum) void {
            const index = @intFromEnum(category);
            self.start_times[index] = std.time.nanoTimestamp();
        }

        /// Stop timing for a specific category and add elapsed time to the total
        /// Returns the elapsed time for this measurement in nanoseconds
        pub fn stop(self: *Self, category: CategoryEnum) u64 {
            const end_time = std.time.nanoTimestamp();
            const index = @intFromEnum(category);

            if (self.start_times[index]) |start_time| {
                const elapsed = @as(u64, @intCast(end_time - start_time));
                self.elapsed_times[index] += elapsed;
                self.start_times[index] = null;
                return elapsed;
            }

            // If stopwatch wasn't running, return 0
            return 0;
        }

        /// Get the total elapsed time for a category in nanoseconds
        pub fn getElapsed(self: *const Self, category: CategoryEnum) u64 {
            const index = @intFromEnum(category);
            return self.elapsed_times[index];
        }

        /// Get the total elapsed time for a category in milliseconds
        pub fn getElapsedMs(self: *const Self, category: CategoryEnum) f64 {
            const ns = self.getElapsed(category);
            return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        }

        /// Get the total elapsed time for a category in microseconds
        pub fn getElapsedUs(self: *const Self, category: CategoryEnum) f64 {
            const ns = self.getElapsed(category);
            return @as(f64, @floatFromInt(ns)) / 1_000.0;
        }

        /// Check if a stopwatch is currently running for a category
        pub fn isRunning(self: *const Self, category: CategoryEnum) bool {
            const index = @intFromEnum(category);
            return self.start_times[index] != null;
        }

        /// Print a summary of all timing categories
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

// Example usage and tests
test "Benchmark basic usage" {
    const TimingCategory = enum { computation, io, rendering };

    var bench = Benchmark(TimingCategory).init();

    // Test initial state
    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.computation));
    try std.testing.expectEqual(false, bench.isRunning(.computation));

    // Test start/stop
    bench.start(.computation);
    try std.testing.expectEqual(true, bench.isRunning(.computation));

    std.Thread.sleep(1_000_000); // Sleep for 1ms

    const elapsed = bench.stop(.computation);
    try std.testing.expect(elapsed > 0);
    try std.testing.expectEqual(false, bench.isRunning(.computation));
    try std.testing.expectEqual(elapsed, bench.getElapsed(.computation));

    // Test accumulation
    const first_elapsed = bench.getElapsed(.computation);
    bench.start(.computation);
    std.Thread.sleep(1_000_000);
    _ = bench.stop(.computation);

    const total_elapsed = bench.getElapsed(.computation);
    try std.testing.expect(total_elapsed > first_elapsed);
}

test "Benchmark multiple categories" {
    const Categories = enum { category_a, category_b, category_c };
    var bench = Benchmark(Categories).init();

    bench.start(.category_a);
    std.Thread.sleep(1_000_000);
    _ = bench.stop(.category_a);

    bench.start(.category_b);
    std.Thread.sleep(2_000_000);
    _ = bench.stop(.category_b);

    try std.testing.expect(bench.getElapsed(.category_a) > 0);
    try std.testing.expect(bench.getElapsed(.category_b) > bench.getElapsed(.category_a));
    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.category_c));
}

test "Benchmark reset" {
    const Categories = enum { test_category };
    var bench = Benchmark(Categories).init();

    bench.start(.test_category);
    std.Thread.sleep(1_000_000);
    _ = bench.stop(.test_category);

    try std.testing.expect(bench.getElapsed(.test_category) > 0);

    bench.reset();
    try std.testing.expectEqual(@as(u64, 0), bench.getElapsed(.test_category));
}

test "Benchmark time conversion helpers" {
    const Categories = enum { conversion_test };
    var bench = Benchmark(Categories).init();

    bench.start(.conversion_test);
    std.Thread.sleep(5_000_000); // 5ms
    _ = bench.stop(.conversion_test);

    const elapsed_ms = bench.getElapsedMs(.conversion_test);
    const elapsed_us = bench.getElapsedUs(.conversion_test);

    // Just verify the conversions work and are reasonable
    try std.testing.expect(elapsed_ms >= 4.0 and elapsed_ms <= 10.0); // Allow some variance
    try std.testing.expect(elapsed_us >= 4_000.0 and elapsed_us <= 10_000.0);
}
