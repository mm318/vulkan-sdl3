const std = @import("std");
const Self = @This();

grid: []bool,
width: usize,
height: usize,
generation: usize = 0,
alive: usize = 0,

pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Self {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    const grid = try gpa.alloc(bool, width * height);
    errdefer gpa.free(grid);

    return Self{
        .grid = grid,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    gpa.free(self.grid);
    self.* = undefined;
}

pub fn countNeighbors(self: Self, x: usize, y: usize) usize {
    var count: usize = 0;
    for (&[_]isize{ -1, 0, 1 }) |xd| {
        for (&[_]isize{ -1, 0, 1 }) |yd| {
            var target_x = x;
            switch (xd) {
                -1 => target_x -|= 1,
                0 => {},
                1 => target_x +|= 1,
                else => unreachable,
            }
            var target_y = y;
            switch (yd) {
                -1 => target_y -|= 1,
                0 => {},
                1 => target_y +|= 1,
                else => unreachable,
            }

            if (target_x == x and target_y == y) continue;
            if (target_x >= self.width) continue;
            if (target_y >= self.height) continue;

            count += @intFromBool(self.at(target_x, target_y));
        }
    }
    return count;
}

pub fn at(self: Self, x: usize, y: usize) bool {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    return self.grid[x + y * self.width];
}

pub fn atMut(self: *Self, x: usize, y: usize) *bool {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    return &self.grid[x + y * self.width];
}

pub fn live(self: *Self) void {
    self.generation += 1;
    var it = self.iterator();
    while (it.next()) |cell| {
        const neighbors = self.countNeighbors(cell.x, cell.y);
        switch (neighbors) {
            0...1 => {
                self.atMut(cell.x, cell.y).* = false;
            },
            2 => {},
            3 => {
                if (cell.alive) {
                    continue;
                }

                self.atMut(cell.x, cell.y).* = true;
            },
            else => {
                self.atMut(cell.x, cell.y).* = false;
            },
        }
    }
}

pub fn fill(self: *Self, seed: u64, percent: f32) void {
    std.debug.assert(percent <= 1.0);
    std.debug.assert(percent >= 0.0);

    var xoshiro = std.Random.Xoshiro256.init(seed);
    const rng = xoshiro.random();

    const num: usize = @intFromFloat(@as(f32, @floatFromInt(self.width * self.height)) * percent + 1.0);
    for (0..num) |_| {
        const i = rng.uintLessThan(usize, self.grid.len);

        self.alive += 1;
        self.grid[i] = true;
    }
}

pub fn iterator(self: Self) Iterator {
    return .{
        .grid = self.grid,
        .width = self.width,
        .height = self.height,
    };
}

pub const Iterator = struct {
    pub const Item = struct {
        x: usize,
        y: usize,
        alive: bool,
    };

    grid: []bool,
    width: usize,
    height: usize,
    offset: usize = 0,

    pub fn next(self: *@This()) ?Item {
        if (self.offset >= self.grid.len) {
            return null;
        }

        defer self.offset += 1;

        return Item{
            .x = self.offset % self.width,
            .y = self.offset / self.width,
            .alive = self.grid[self.offset],
        };
    }
};
