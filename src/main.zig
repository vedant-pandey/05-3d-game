const sdl3 = @import("sdl3");
const std = @import("std");
const zm = @import("zmath");

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

pub fn projectPoint(vec: zm.Vec, mat: zm.Mat) zm.Vec {
    const v = zm.mul(vec, mat);
    const w = if (v[3] == 0) 1 else v[3];
    return v / @as(zm.Vec, @splat(w));
}

const Tri = struct {
    p: [3]zm.Vec,
    normal: zm.Vec = .{ 0, 0, 0, 1 },

    pub fn init(p: [9]f32) Tri {
        return Tri{
            .p = .{
                .{ p[0], p[1], p[2], 0 },
                .{ p[3], p[4], p[5], 0 },
                .{ p[6], p[7], p[8], 0 },
            },
        };
    }

    const Self = @This();
    pub fn drawWireframe(self: *const Self, renderer: *const sdl3.render.Renderer, color: sdl3.pixels.Color) !void {
        try renderer.setDrawColor(color);
        try renderer.renderLine(.{ .x = self.p[0][0], .y = self.p[0][1] }, .{ .x = self.p[1][0], .y = self.p[1][1] });
        try renderer.renderLine(.{ .x = self.p[1][0], .y = self.p[1][1] }, .{ .x = self.p[2][0], .y = self.p[2][1] });
        try renderer.renderLine(.{ .x = self.p[2][0], .y = self.p[2][1] }, .{ .x = self.p[0][0], .y = self.p[0][1] });
    }

    pub fn drawFill(self: *const Self, renderer: *const sdl3.render.Renderer, color: sdl3.pixels.FColor) !void {
        const v1 = sdl3.render.Vertex{
            .position = .{ .x = self.p[0][0], .y = self.p[0][1] },
            .color = color,
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        const v2 = sdl3.render.Vertex{
            .position = .{ .x = self.p[1][0], .y = self.p[1][1] },
            .color = color,
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        const v3 = sdl3.render.Vertex{
            .position = .{ .x = self.p[2][0], .y = self.p[2][1] },
            .color = color,
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        try renderer.renderGeometry(null, &.{ v1, v2, v3 }, null);
    }

    pub fn buildNormalAndGet(self: *Self) zm.Vec {
        const line1: zm.Vec = .{
            self.p[1][0] - self.p[0][0],
            self.p[1][1] - self.p[0][1],
            self.p[1][2] - self.p[0][2],
            0,
        };
        const line2: zm.Vec = .{
            self.p[2][0] - self.p[0][0],
            self.p[2][1] - self.p[0][1],
            self.p[2][2] - self.p[0][2],
            0,
        };
        self.normal = zm.normalize3(zm.cross3(line1, line2));

        return self.normal;
    }

    pub fn project(self: *Self, projectionMatrix:zm.Mat) Tri {
        return Tri{
            .p = .{
                projectPoint((self.p[0]), projectionMatrix),
                projectPoint((self.p[1]), projectionMatrix),
                projectPoint((self.p[2]), projectionMatrix),
            },
        };
    }

    pub fn copy(self: Self) Self {
        return self;
    }
};

const Mesh = struct {
    tris: std.ArrayList(Tri),

    pub fn loadFromObjFile(filepath: [:0]const u8, allocator: std.mem.Allocator) !Mesh {
        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();
        var buffer: [128]u8 = .{0} ** 128;
        var reader = file.reader(buffer[0..]);
        var verts = try std.ArrayList(zm.Vec).initCapacity(allocator, 1000);
        var faces = try std.ArrayList(Tri).initCapacity(allocator, 1000);

        while (reader.interface.takeDelimiterInclusive('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (trimmed[0] == 'v') {
                var it = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
                try verts.append(allocator, zm.Vec{
                    try std.fmt.parseFloat(f32, it.next().?),
                    try std.fmt.parseFloat(f32, it.next().?),
                    try std.fmt.parseFloat(f32, it.next().?),
                    1,
                });
            } else if (trimmed[0] == 'f') {
                var it = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
                try faces.append(allocator, .{ .p = .{
                    verts.items[try std.fmt.parseInt(usize, it.next().?, 0) - 1],
                    verts.items[try std.fmt.parseInt(usize, it.next().?, 0) - 1],
                    verts.items[try std.fmt.parseInt(usize, it.next().?, 0) - 1],
                } });
            }
        } else |_| {}

        return Mesh{ .tris = faces };
    }

    pub fn cubeMesh(allocator: std.mem.Allocator) !Mesh {
        var meshCube = Mesh{
            .tris = try std.ArrayList(Tri).initCapacity(allocator, 1000),
        };

        try meshCube.tris.append(allocator, Tri.init(.{ 0, 0, 0, 0, 1, 0, 1, 1, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 0, 0, 0, 1, 1, 0, 1, 0, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 0, 1, 1, 0, 1, 1, 1 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 0, 1, 1, 1, 1, 0, 1 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 1, 1, 1, 1, 0, 1, 1 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 1, 0, 1, 1, 0, 0, 1 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 0, 0, 1, 0, 1, 1, 0, 1, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 0, 0, 1, 0, 1, 0, 0, 0, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 0, 1, 0, 0, 1, 1, 1, 1, 1 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 0, 1, 0, 1, 1, 1, 1, 1, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 1, 0, 0, 1, 0, 0, 0 }));
        try meshCube.tris.append(allocator, Tri.init(.{ 1, 0, 1, 0, 0, 0, 1, 0, 0 }));
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = try AppState.init(.{ .video = true }, ScreenWidth, ScreenHeight);
    defer state.deinit();

    const meshCube = try Mesh.loadFromObjFile("./objs/VideoShip.obj", allocator);
    const vCamera = zm.Vec{ 0, 0, 0, 0 };

    const nearDist = 0.1;
    const farDist = 1000.0;
    const fieldOfView = 90.0;
    const aspectRatio: f32 = @as(f32, @floatFromInt(state.height)) / @as(f32, @floatFromInt(state.width));
    const fieldOfViewRad = 1.0 / std.math.tan(fieldOfView * 0.5 / 180.0 * std.math.pi);

    var projectMatrix2: zm.Mat = .{.{0} ** 4} ** 4;

    projectMatrix2[0][0] = aspectRatio * fieldOfViewRad;
    projectMatrix2[1][1] = fieldOfViewRad;
    projectMatrix2[2][2] = farDist / (farDist - nearDist);
    projectMatrix2[3][2] = (-farDist * nearDist) / (farDist - nearDist);
    projectMatrix2[2][3] = 1.0;
    projectMatrix2[3][3] = 0.0;

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

        var rotZMat: zm.Mat = .{.{0} ** 4} ** 4;
        var rotXMat: zm.Mat = .{.{0} ** 4} ** 4;

        rotZMat[0][0] = std.math.cos(fTheta);
        rotZMat[0][1] = std.math.sin(fTheta);
        rotZMat[1][0] = -std.math.sin(fTheta);
        rotZMat[1][1] = std.math.cos(fTheta);
        rotZMat[2][2] = 1;
        rotZMat[3][3] = 1;

        // Rotation X
        rotXMat[0][0] = 1;
        rotXMat[1][1] = std.math.cos(fTheta * 0.5);
        rotXMat[1][2] = std.math.sin(fTheta * 0.5);
        rotXMat[2][1] = -std.math.sin(fTheta * 0.5);
        rotXMat[2][2] = std.math.cos(fTheta * 0.5);
        rotXMat[3][3] = 1;

        try state.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try state.renderer.clear();

        try state.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });

        var trisToRaster = try std.ArrayList(Tri).initCapacity(allocator, 1000);

        // Illumination
        const light = zm.normalize3(zm.Vec{ 0, 0, -1, 0 });

        for (meshCube.tris.items) |tri| {
            // Rotate in Z axis
            const triRotZ = Tri{
                .p = .{
                    zm.mul(tri.p[0], rotZMat),
                    zm.mul(tri.p[1], rotZMat),
                    zm.mul(tri.p[2], rotZMat),
                },
            };

            // Rotate in X axis
            const triRotZX = Tri{
                .p = .{
                    zm.mul((triRotZ.p[0]), rotXMat),
                    zm.mul((triRotZ.p[1]), rotXMat),
                    zm.mul((triRotZ.p[2]), rotXMat),
                },
            };

            // Offset into the screen
            var translatedTri = triRotZX.copy();
            translatedTri.p[0][2] += 8;
            translatedTri.p[1][2] += 8;
            translatedTri.p[2][2] += 8;

            // Culling
            const normal = translatedTri.buildNormalAndGet();

            if (zm.dot3(normal, translatedTri.p[0] - vCamera)[0] > 0) continue;

            var projectedTri = translatedTri.project(projectMatrix2);

            projectedTri.p[0][0] += 1;
            projectedTri.p[0][1] += 1;
            projectedTri.p[1][0] += 1;
            projectedTri.p[1][1] += 1;
            projectedTri.p[2][0] += 1;
            projectedTri.p[2][1] += 1;

            projectedTri.p[0][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.p[0][1] *= 0.5 * @as(f32, @floatFromInt(state.height));
            projectedTri.p[1][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.p[1][1] *= 0.5 * @as(f32, @floatFromInt(state.height));
            projectedTri.p[2][0] *= 0.5 * @as(f32, @floatFromInt(state.width));
            projectedTri.p[2][1] *= 0.5 * @as(f32, @floatFromInt(state.height));

            projectedTri.normal = normal;
            try trisToRaster.append(allocator, projectedTri);
        }
        std.mem.sort(Tri, trisToRaster.items, {}, triLessThan);

        for (trisToRaster.items) |*tri| {

            // Use dot product with normal to evaluate light intensity
            const intensity = zm.dot3(tri.normal, light)[0];

            try tri.drawFill(&state.renderer, .{
                .r = 1 * intensity,
                .g = 1 * intensity,
                .b = 1 * intensity,
                .a = 1,
            });

            // Draw Wireframe
            try tri.drawWireframe(&state.renderer, .{
                .r = 0,
                .g = 0,
                .b = 0,
                .a = 255,
            });
        }

        try state.renderer.present();
    }
}

pub fn triLessThan(_: void, a: Tri, b: Tri) bool {
    const z1 = (a.p[0][2] + a.p[1][2] + a.p[2][2]) / 3;
    const z2 = (b.p[0][2] + b.p[1][2] + b.p[2][2]) / 3;
    return z1 > z2;
}
