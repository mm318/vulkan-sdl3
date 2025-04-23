const std = @import("std");
const sdl = @import("sdl.zig");
const dvui = @import("dvui");
const Game = @import("Game.zig");
const SdlBackend = dvui.backend;
const Self = @This();

gpa: std.mem.Allocator,
last_error: ?anyerror = null,
window: *sdl.c.SDL_Window,
renderer: *sdl.c.SDL_Renderer,
texture: *sdl.c.SDL_Texture,
game: Game,
repeat: f32 = 0.0,
wait: f32 = 1.0,
last_time: u64 = 0,

ui: struct {
    backend: SdlBackend,
    window: dvui.Window,
},

pub fn deinit(self: *Self) void {
    const gpa = self.gpa;

    self.ui.backend.deinit();
    self.ui.window.deinit();
    sdl.c.SDL_DestroyRenderer(self.renderer);
    sdl.c.SDL_DestroyWindow(self.window);
    sdl.destroyTexture(self.texture);
    self.game.deinit(gpa);

    self.* = undefined;
    gpa.destroy(self);
}

pub fn fromOpaque(appstate: ?*anyopaque) *Self {
    return @alignCast(@ptrCast(appstate.?));
}
