const std = @import("std");
const sdl3 = @import("sdl3");
const vk = @import("vulkan.zig");

const c = @cImport({
    @cInclude("volk.h");
});

pub const AppState = struct {
    window: sdl3.video.Window,
    renderer: sdl3.render.Renderer,
    width: usize,
    height: usize,
    initFlags: sdl3.InitFlags,
    keyState: []const bool,
    paused: bool,
    quit: bool,
    allocator: std.mem.Allocator,
    relMouseMode: bool = true,

    ctx: vk.VulkanCtx,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, initFlags: sdl3.InitFlags, width: usize, height: usize) !Self {
        try sdl3.init(initFlags);
        const window = try sdl3.video.Window.init("3D Renderer", width, height, .{
            .always_on_top = true,
            .mouse_focus = true,
            .input_focus = true,
            // .resizable = true,
            .vulkan = true,
        });

        const renderer = try sdl3.render.Renderer.init(window, null);

        var state = AppState{
            .window = window,
            .renderer = renderer,
            .width = width,
            .height = height,
            .initFlags = initFlags,
            .keyState = sdl3.keyboard.getState(),
            .paused = false,
            .quit = false,
            .allocator = allocator,
            // .ctx = try vk.VulkanCtx.init(allocator, window, c.VK_API_VERSION_1_4),
            .ctx = undefined,
        };


        state.window.raise() catch unreachable;
        try state.window.setPosition(.{ .absolute = 0 }, .{ .absolute = 0 });
        try sdl3.mouse.setWindowRelativeMode(state.window, true);

        return state;
    }

    pub fn deinit(self: *Self) void {
        // self.renderer.deinit();

        // try self.ctx.deinit();
        self.window.deinit();
        sdl3.quit(self.initFlags);
        sdl3.shutdown();
    }

    pub fn resize(self: *Self, height: i32, width: i32) void {
        self.height = @intCast(height);
        self.width = @intCast(width);
    }

    pub inline fn getAspectRatio(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(self.width));
    }
};
