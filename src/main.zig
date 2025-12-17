const sdl3 = @import("sdl3");
const std = @import("std");

const ScreenWidth = 1383;
const ScreenHeight = 1377;

const AppState = struct {
    window: sdl3.video.Window,
    renderer: sdl3.render.Renderer,
    width: usize,
    height: usize,
    initFlags: sdl3.InitFlags,

    const Self = @This();

    pub fn init(initFlags: sdl3.InitFlags, width: usize, height: usize) !Self {
        try sdl3.init(initFlags);
        const window = try sdl3.video.Window.init("Procedural generation", width, height, .{
            .always_on_top = true,
            .mouse_focus = true,
            .input_focus = true,
            .resizable = true,
        });
        window.raise() catch unreachable;
        try window.setPosition(.{ .absolute = 0 }, .{ .absolute = 0 });

        const renderer = try sdl3.render.Renderer.init(window, null);

        const state = AppState{
            .window = window,
            .renderer = renderer,
            .width = width,
            .height = height,
            .initFlags = initFlags,
        };

        return state;
    }

    pub fn deinit(self: *Self) void {
        defer sdl3.shutdown();
        defer sdl3.quit(self.initFlags);
    }
};

const Engine3D = struct {};

const Vec3 = @Vector(3, f32);
const Tri = struct {
    points: [3]Vec3,
    pub fn init(p: [9]f32) Tri {
        return .{
            .points = .{
                .{ p[0], p[1], p[2] },
                .{ p[3], p[4], p[5] },
                .{ p[6], p[7], p[8] },
            },
        };
    }

    const Self = @This();
    pub fn draw(self: *const Self, renderer: *const sdl3.render.Renderer) !void {
        try renderer.renderLine(.{ .x = self.points[0][0], .y = self.points[0][1] }, .{ .x = self.points[1][0], .y = self.points[1][1] });
        try renderer.renderLine(.{ .x = self.points[1][0], .y = self.points[1][1] }, .{ .x = self.points[2][0], .y = self.points[2][1] });
        try renderer.renderLine(.{ .x = self.points[2][0], .y = self.points[2][1] }, .{ .x = self.points[0][0], .y = self.points[0][1] });
    }

    pub fn copy(self: Self) Self {
        return self;
    }
};

const Mat4 = struct {
    m: [4][4]f32 = .{.{0} ** 4} ** 4,

    const Self = @This();

    pub fn multiplyVec(self: *const Self, vec: Vec3) Vec3 {
        var w = vec[0] * self.m[0][3] + vec[1] * self.m[1][3] + vec[2] * self.m[2][3] + self.m[3][3];

        if (w == 0) w = 1;

        return .{
            (vec[0] * self.m[0][0] + vec[1] * self.m[1][0] + vec[2] * self.m[2][0] + self.m[3][0]) / w,
            (vec[0] * self.m[0][1] + vec[1] * self.m[1][1] + vec[2] * self.m[2][1] + self.m[3][1]) / w,
            (vec[0] * self.m[0][2] + vec[1] * self.m[1][2] + vec[2] * self.m[2][2] + self.m[3][2]) / w,
        };
    }
};

const Mesh = struct {
    tris: []const Tri = undefined,
};

pub fn main() !void {
    var state = try AppState.init(.{ .video = true }, ScreenWidth, ScreenHeight);
    defer state.deinit();

    const meshCube = Mesh{
        .tris = &[_]Tri{
            Tri.init(.{ 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0 }),
            Tri.init(.{ 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 0.0 }),
            Tri.init(.{ 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0 }),
            Tri.init(.{ 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0 }),
            Tri.init(.{ 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0 }),
            Tri.init(.{ 1.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0 }),
            Tri.init(.{ 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0 }),
            Tri.init(.{ 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0 }),
            Tri.init(.{ 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0 }),
            Tri.init(.{ 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0 }),
            Tri.init(.{ 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 }),
            Tri.init(.{ 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0 }),
        },
    };

    const nearDist = 0.1;
    const farDist = 1000.0;
    const fieldOfView = 90.0;
    const aspectRatio: f32 = @as(f32, @floatFromInt(state.height)) / @as(f32, @floatFromInt(state.width));
    const fieldOfViewRad = 1.0 / std.math.tan(fieldOfView * 0.5 / 180.0 * std.math.pi);

    var projectMatrix = Mat4{};

    projectMatrix.m[0][0] = aspectRatio * fieldOfViewRad;
    projectMatrix.m[1][1] = fieldOfViewRad;
    projectMatrix.m[2][2] = farDist / (farDist - nearDist);
    projectMatrix.m[3][2] = (-farDist * nearDist) / (farDist - nearDist);
    projectMatrix.m[2][3] = 1.0;
    projectMatrix.m[3][3] = 0.0;

    var lastTick = sdl3.timer.getNanosecondsSinceInit();
    var curTick = sdl3.timer.getMillisecondsSinceInit();
    var dt: f32 = 0;

    var quit = false;
    var fTheta: f32 = 0;
    while (!quit) {
        while (sdl3.events.poll()) |event| {
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .key_down => {
                    switch (event.key_down.key.?) {
                        .q => {
                            quit = true;
                        },
                        else => {},
                    }
                },
                .window_resized => {
                    state.height = @intCast(event.window_resized.height);
                    state.width = @intCast(event.window_resized.width);
                    std.debug.print("{} {} \n", .{ state.height, state.width });
                },
                else => {},
            }
        }

        lastTick = curTick;
        curTick = sdl3.timer.getMillisecondsSinceInit();
        dt = @as(f32, @floatFromInt(curTick - lastTick)) / 500.0;

        fTheta += dt;

        var rotZMat = Mat4{};
        var rotXMat = Mat4{};

        rotZMat.m[0][0] = std.math.cos(dt);

        rotZMat.m[0][0] = std.math.cos(fTheta);
        rotZMat.m[0][1] = std.math.sin(fTheta);
        rotZMat.m[1][0] = -std.math.sin(fTheta);
        rotZMat.m[1][1] = std.math.cos(fTheta);
        rotZMat.m[2][2] = 1;
        rotZMat.m[3][3] = 1;

        // Rotation X
        rotXMat.m[0][0] = 1;
        rotXMat.m[1][1] = std.math.cos(fTheta * 0.5);
        rotXMat.m[1][2] = std.math.sin(fTheta * 0.5);
        rotXMat.m[2][1] = -std.math.sin(fTheta * 0.5);
        rotXMat.m[2][2] = std.math.cos(fTheta * 0.5);
        rotXMat.m[3][3] = 1;

        try state.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try state.renderer.clear();

        try state.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
        for (meshCube.tris) |tri| {
            const triRotZ = Tri{
                .points = .{
                    rotZMat.multiplyVec(tri.points[0]),
                    rotZMat.multiplyVec(tri.points[1]),
                    rotZMat.multiplyVec(tri.points[2]),
                },
            };

            const triRotZX = Tri{
                .points = .{
                    rotXMat.multiplyVec(triRotZ.points[0]),
                    rotXMat.multiplyVec(triRotZ.points[1]),
                    rotXMat.multiplyVec(triRotZ.points[2]),
                },
            };
            var translatedTri = triRotZX.copy();
            translatedTri.points[0][2] += 3;
            translatedTri.points[1][2] += 3;
            translatedTri.points[2][2] += 3;
            var projectedTri = Tri{
                .points = .{
                    projectMatrix.multiplyVec(translatedTri.points[0]),
                    projectMatrix.multiplyVec(translatedTri.points[1]),
                    projectMatrix.multiplyVec(translatedTri.points[2]),
                },
            };

            projectedTri.points[0][0] += 1;
            projectedTri.points[0][1] += 1;
            projectedTri.points[1][0] += 1;
            projectedTri.points[1][1] += 1;
            projectedTri.points[2][0] += 1;
            projectedTri.points[2][1] += 1;

            projectedTri.points[0][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.points[0][1] *= 0.5 * @as(f32, @floatFromInt(state.height));
            projectedTri.points[1][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.points[1][1] *= 0.5 * @as(f32, @floatFromInt(state.height));
            projectedTri.points[2][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.points[2][1] *= 0.5 * @as(f32, @floatFromInt(state.height));

            try projectedTri.draw(&state.renderer);
        }

        try state.renderer.present();
    }
}
