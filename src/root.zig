const std = @import("std");
const sdl3 = @import("sdl3");
const vk = @import("vulkan.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("volk.h");
});

pub const AppState = struct {
    window: sdl3.video.Window,
    width: usize,
    height: usize,
    initFlags: sdl3.InitFlags,
    keyState: []const bool,
    paused: bool,
    quit: bool,
    allocator: std.mem.Allocator,
    relMouseMode: bool = true,

    renderer: ?sdl3.render.Renderer,
    ctx: ?vk.VulkanCtx,

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

        var state = AppState{
            .window = window,
            .width = width,
            .height = height,
            .initFlags = initFlags,
            .keyState = sdl3.keyboard.getState(),
            .paused = false,
            .quit = false,
            .allocator = allocator,
            .renderer = if (!build_options.enable_vulkan) try sdl3.render.Renderer.init(window, null) else null,
            .ctx = if (build_options.enable_vulkan) try vk.VulkanCtx.init(allocator, window, c.VK_API_VERSION_1_4) else null,
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
