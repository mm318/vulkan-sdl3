const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;
const errify = sdl.errify;
const callbacks = @import("callbacks.zig");
const AppState = @import("AppState.zig");
const dvui = @import("dvui");
const SDLBackend = dvui.backend;
const builtin = @import("builtin");

var debug_allocator = std.heap.DebugAllocator(.{}).init;
const gpa = switch (builtin.target.os.tag) {
    .emscripten => std.heap.c_allocator, // wasm allocator segfaults even without LTO :(
    else => debug_allocator.allocator(),
};

pub const std_options = std.Options{
    .log_level = if (builtin.mode != .Debug) .info else .debug,
};

pub fn main() !u8 {
    defer {
        if (@hasDecl(@TypeOf(gpa), "deinit")) {
            std.debug.assert(gpa.deinit() == .ok);
        }
    }

    var empty_argv: [0:null]?[*:0]u8 = .{};
    const status: u8 = @truncate(
        @as(c_uint, @bitCast(sdl.c_main.SDL_RunApp(
            empty_argv.len,
            @ptrCast(&empty_argv),
            c_callbacks.main,
            null,
        ))),
    );
    return status;
}

const c_callbacks = struct {
    fn main(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
        return sdl.c_main.SDL_EnterAppMainCallbacks(
            argc,
            @ptrCast(argv),
            appInit,
            appIterate,
            @ptrCast(&appEvent),
            appQuit,
        );
    }

    fn appInit(opaque_state: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
        const state = callbacks.appInit(gpa, @ptrCast(argv.?[0..@intCast(argc)])) catch |err| {
            std.log.err("error on initialization: {}", .{err});
            return c.SDL_APP_FAILURE;
        };

        opaque_state.?.* = state;

        return c.SDL_APP_CONTINUE;
    }

    fn appIterate(opaque_state: ?*anyopaque) callconv(.c) c.SDL_AppResult {
        const state = AppState.fromOpaque(opaque_state);
        return callbacks.appIterate(state) catch |err| {
            state.last_error = err;
            return c.SDL_APP_FAILURE;
        };
    }

    fn appEvent(opaque_state: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
        const state = AppState.fromOpaque(opaque_state);
        return callbacks.appEvent(state, event.?) catch |err| {
            state.last_error = err;
            return c.SDL_APP_FAILURE;
        };
    }

    fn appQuit(opaque_state: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
        const state = if (opaque_state == null) null else AppState.fromOpaque(opaque_state);
        if (state) |s| {
            if (s.last_error) |err| {
                std.log.err("on app quit found error: {any}", .{err});
            }
        }
        callbacks.appQuit(state, result);
    }
};

comptime {
    if (builtin.os.tag == .emscripten) {
        @export(&exports.dvui_c_alloc, .{ .name = "dvui_c_alloc" });
        @export(&exports.dvui_c_free, .{ .name = "dvui_c_free" });
        @export(&exports.dvui_c_panic, .{ .name = "dvui_c_panic" });
        @export(&exports.dvui_c_sqrt, .{ .name = "dvui_c_sqrt" });
        @export(&exports.dvui_c_memcpy, .{ .name = "dvui_c_memcpy" });
        @export(&exports.dvui_c_memset, .{ .name = "dvui_c_memset" });
        @export(&exports.dvui_c_fabs, .{ .name = "dvui_c_fabs" });
        @export(&exports.dvui_c_floor, .{ .name = "dvui_c_floor" });
        @export(&exports.dvui_c_ceil, .{ .name = "dvui_c_ceil" });
    }
}

// this is used to fix dvui stb implementation
// this is copied from https://github.com/david-vanderson/dvui/blob/main/src/backends/web.zig
pub const exports = struct {
    fn dvui_c_alloc(size: usize) callconv(.c) ?*anyopaque {
        const buffer = gpa.alignedAlloc(u8, 8, size + 8) catch {
            //log.debug("dvui_c_alloc {d} failed", .{size});
            return null;
        };
        std.mem.writeInt(u64, buffer[0..@sizeOf(u64)], buffer.len, builtin.cpu.arch.endian());
        //log.debug("dvui_c_alloc {*} {d}", .{ buffer.ptr + 8, size });
        return buffer.ptr + 8;
    }

    fn dvui_c_free(ptr: ?*anyopaque) callconv(.c) void {
        const buffer = @as([*]align(8) u8, @alignCast(@ptrCast(ptr orelse return))) - 8;
        const len = std.mem.readInt(u64, buffer[0..@sizeOf(u64)], builtin.cpu.arch.endian());
        //log.debug("dvui_c_free {?*} {d}", .{ ptr, len - 8 });

        gpa.free(buffer[0..@intCast(len)]);
    }

    fn dvui_c_realloc_sized(ptr: ?*anyopaque, oldsize: usize, newsize: usize) ?*anyopaque {
        //_ = oldsize;
        //log.debug("dvui_c_realloc_sized {d} {d}", .{ oldsize, newsize });

        if (ptr == null) {
            return dvui_c_alloc(newsize);
        }

        //const buffer = @as([*]u8, @ptrCast(ptr.?)) - 8;
        //const len = std.mem.readInt(u64, buffer[0..@sizeOf(u64)], builtin.cpu.arch.endian());

        //const slice = buffer[0..@intCast(len)];
        //log.debug("dvui_c_realloc_sized buffer {*} {d}", .{ ptr, len });

        //_ = gpa.resize(slice, newsize + 16);
        const newptr = dvui_c_alloc(newsize);
        const newbuf = @as([*]u8, @ptrCast(newptr));
        @memcpy(newbuf[0..oldsize], @as([*]u8, @ptrCast(ptr))[0..oldsize]);
        dvui_c_free(ptr);
        return newptr;

        //std.mem.writeInt(usize, slice[0..@sizeOf(usize)], slice.len, builtin.cpu.arch.endian());
        //return slice.ptr + 16;
    }

    fn dvui_c_panic(msg: [*c]const u8) callconv(.c) noreturn {
        std.debug.print("panic: {s}\n", .{msg});
        unreachable;
    }

    fn dvui_c_sqrt(x: f64) callconv(.c) f64 {
        return @sqrt(x);
    }

    fn dvui_c_pow(x: f64, y: f64) callconv(.c) f64 {
        return @exp(@log(x) * y);
    }

    fn dvui_c_ldexp(x: f64, n: c_int) callconv(.c) f64 {
        return x * @exp2(@as(f64, @floatFromInt(n)));
    }

    fn dvui_c_floor(x: f64) callconv(.c) f64 {
        return @floor(x);
    }

    fn dvui_c_ceil(x: f64) callconv(.c) f64 {
        return @ceil(x);
    }

    fn dvui_c_fmod(x: f64, y: f64) callconv(.c) f64 {
        return @mod(x, y);
    }

    fn dvui_c_cos(x: f64) callconv(.c) f64 {
        return @cos(x);
    }

    fn dvui_c_acos(x: f64) callconv(.c) f64 {
        return std.math.acos(x);
    }

    fn dvui_c_fabs(x: f64) callconv(.c) f64 {
        return @abs(x);
    }

    fn dvui_c_strlen(x: [*c]const u8) callconv(.c) usize {
        return std.mem.len(x);
    }

    fn dvui_c_memcpy(dest: [*c]u8, src: [*c]const u8, n: usize) callconv(.c) [*c]u8 {
        @memcpy(dest[0..n], src[0..n]);
        return dest;
    }

    fn dvui_c_memmove(dest: [*c]u8, src: [*c]const u8, n: usize) callconv(.c) [*c]u8 {
        //log.debug("dvui_c_memmove callconv(.c) dest {*} callconv(.c) src callconv(.c) {*} {d}", callconv(.c) .{ dest, src, n });
        const buf = dvui.currentWindow().arena().alloc(u8, n) catch unreachable;
        @memcpy(buf, src[0..n]);
        @memcpy(dest[0..n], buf);
        return dest;
    }

    fn dvui_c_memset(dest: [*c]u8, x: u8, n: usize) callconv(.c) [*c]u8 {
        @memset(dest[0..n], x);
        return dest;
    }

    fn gpa_u8(len: usize) callconv(.c) [*c]u8 {
        const buf = gpa.alloc(u8, len) catch return @ptrFromInt(0);
        return buf.ptr;
    }

    fn gpa_free(ptr: [*c]u8, len: usize) callconv(.c) void {
        gpa.free(ptr[0..len]);
    }
};
