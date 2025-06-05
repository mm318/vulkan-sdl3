const std = @import("std");
const Game = @This();

const Grid = struct {
    grid: []bool,

    fn at(self: Grid, offset: usize) bool {
        return self.grid[offset];
    }

    fn setAt(self: *Grid, offset: usize, v: bool) void {
        self.grid[offset] = v;
    }

    fn reset(self: *Grid) void {
        @memset(self.grid, false);
    }

    fn copyTo(self: Grid, other: *Grid) void {
        @memcpy(other.grid, self.grid);
    }
};

grid: Grid,
grid_buf: Grid,

width: usize,
height: usize,
generation: usize = 0,

pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Game {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    const grid = try gpa.alloc(bool, width * height);
    errdefer gpa.free(grid);

    const grid_buf = try gpa.alloc(bool, width * height);
    errdefer gpa.free(grid_buf);

    return Game{
        .grid = .{ .grid = grid },
        .grid_buf = .{ .grid = grid_buf },
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Game, gpa: std.mem.Allocator) void {
    gpa.free(self.grid.grid);
    gpa.free(self.grid_buf.grid);
    self.* = undefined;
}

pub fn countNeighbors(self: Game, x: usize, y: usize) usize {
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

            count += @intFromBool(self.grid.at(self.posToOffset(target_x, target_y)));
        }
    }
    return count;
}

pub fn live(self: *Game) void {
    self.grid.copyTo(&self.grid_buf);
    var buf = self.grid_buf;
    defer std.mem.swap(Grid, &self.grid, &self.grid_buf);

    self.generation += 1;
    var it = self.iterator();
    while (it.next()) |cell| {
        const neighbors = self.countNeighbors(cell.x, cell.y);
        const offset = self.posToOffset(cell.x, cell.y);

        switch (neighbors) {
            0...1 => {
                buf.setAt(offset, false);
            },
            2 => {},
            3 => {
                if (cell.alive) {
                    continue;
                }

                buf.setAt(offset, true);
            },
            else => {
                buf.setAt(offset, false);
            },
        }
    }
}

pub fn fill(self: *Game, seed: u64, percent: u7) void {
    std.debug.assert(percent <= 100 and percent >= 0);

    var xoshiro = std.Random.Xoshiro256.init(seed);
    const rng = xoshiro.random();

    const num: usize = blk: {
        const cells: f32 = @floatFromInt(self.width * self.height);
        const fraction = @as(f32, @floatFromInt(percent)) / 100.0;

        break :blk @intFromFloat(cells * fraction);
    };
    for (0..num) |_| {
        const i = rng.uintLessThan(usize, self.len());

        self.grid.setAt(i, true);
    }
}

pub fn iterator(self: Game) Iterator {
    return .{
        .grid = self.grid,
        .width = self.width,
    };
}

pub const Iterator = struct {
    pub const Item = struct {
        x: usize,
        y: usize,
        alive: bool,
    };

    grid: Grid,
    width: usize,
    offset: usize = 0,

    pub fn next(self: *@This()) ?Item {
        if (self.offset >= self.grid.grid.len) {
            return null;
        }

        defer self.offset += 1;

        return Item{
            .x = self.offset % self.width,
            .y = self.offset / self.width,
            .alive = self.grid.at(self.offset),
        };
    }
};

pub fn reset(self: *Game) void {
    self.generation = 0;
    self.grid.reset();
}

pub fn len(self: Game) usize {
    return self.width * self.height;
}

pub fn at(self: Game, offset: usize) bool {
    return self.grid.at(offset);
}

fn posToOffset(self: Game, x: usize, y: usize) usize {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);

    return x + y * self.width;
}
