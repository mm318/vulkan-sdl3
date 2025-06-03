const std = @import("std");
const sdl = @import("sdl.zig");
const dvui = @import("dvui");
const Game = @import("Game.zig");
const SdlBackend = dvui.backend;
const AppState = @This();

pub const Ui = struct {
    backend: SdlBackend,
    window: dvui.Window,
    seed_text_input: []u8 = &.{},
    seed_text_valid: bool = true,
    percent_slider: f32 = 0.05 * 4,
    repeat: f32 = 0.0,
    wait: f32 = 1.0,

    pub fn normalizeWait(self: *const Ui) u64 {
        return @intFromFloat(self.wait * 1000.0);
    }

    pub fn normalizeRepeat(self: *const Ui) usize {
        return @intFromFloat(self.repeat * 1000.0 + 1.0);
    }

    pub fn normalizePercent(self: *const Ui) u7 {
        const percents: u7 = @intFromFloat(self.percent_slider * 100.0 / 4.0);
        if (percents == 0) return 1;
        return percents;
    }
};

gpa: std.mem.Allocator,
last_error: ?anyerror = null,
window: *sdl.c.SDL_Window,
renderer: *sdl.c.SDL_Renderer,
texture: *sdl.c.SDL_Texture,
game: Game,
last_time: u64 = 0,
seed: u64 = 0,
percent: u7 = 5,

ui: Ui,

pub fn deinit(self: *AppState) void {
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

pub fn fromOpaque(appstate: ?*anyopaque) *AppState {
    return @alignCast(@ptrCast(appstate.?));
}
