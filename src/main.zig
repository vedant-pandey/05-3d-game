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
        const window = try sdl3.video.Window.init("3D Renderer", width, height, .{
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

    pub inline fn getAspectRatio(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(self.width));
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

    pub fn project(self: *const Self, projectionMatrix: *const zm.Mat) Tri {
        return Tri{
            .p = .{
                projectPoint((self.p[0]), projectionMatrix.*),
                projectPoint((self.p[1]), projectionMatrix.*),
                projectPoint((self.p[2]), projectionMatrix.*),
            },
        };
    }

    pub fn mul(self: *const Self, rotationMatrix: *const zm.Mat) Self {
        return Tri{
            .p = .{
                zm.mul(self.p[0], rotationMatrix.*),
                zm.mul(self.p[1], rotationMatrix.*),
                zm.mul(self.p[2], rotationMatrix.*),
            },
        };
    }

    pub fn translate(self: *const Self, x: f32, y: f32, z: f32) Tri {
        var translatedTri = self.copy();

        translatedTri.p[0][0] += x;
        translatedTri.p[1][0] += x;
        translatedTri.p[2][0] += x;
        translatedTri.p[0][1] += y;
        translatedTri.p[1][1] += y;
        translatedTri.p[2][1] += y;
        translatedTri.p[0][2] += z;
        translatedTri.p[1][2] += z;
        translatedTri.p[2][2] += z;

        return translatedTri;
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

pub fn getXRotationMatrix(theta: f32) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = 1;
    mat[1][1] = std.math.cos(theta);
    mat[1][2] = std.math.sin(theta);
    mat[2][1] = -std.math.sin(theta);
    mat[2][2] = std.math.cos(theta);
    mat[3][3] = 1.0;

    return mat;
}

pub fn getYRotationMatrix(theta: f32) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = std.math.cos(theta);
    mat[0][2] = std.math.sin(theta);
    mat[2][0] = -std.math.sin(theta);
    mat[1][1] = 1.0;
    mat[2][2] = std.math.cos(theta);
    mat[3][3] = 1.0;
    return mat;
}

pub fn getZRotationMatrix(theta: f32) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = std.math.cos(theta);
    mat[0][1] = std.math.sin(theta);
    mat[1][0] = -std.math.sin(theta);
    mat[1][1] = std.math.cos(theta);
    mat[2][2] = 1.0;
    mat[3][3] = 1.0;
    return mat;
}

pub fn getIdentityMatrix() zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = 1;
    mat[1][1] = 1;
    mat[2][2] = 1;
    mat[3][3] = 1;
    return mat;
}

pub fn getProjectionMatrix(nearDist: f32, farDist: f32, fieldOfViewRad: f32, aspectRatio: f32) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = aspectRatio * fieldOfViewRad;
    mat[1][1] = fieldOfViewRad;
    mat[2][2] = farDist / (farDist - nearDist);
    mat[3][2] = (-farDist * nearDist) / (farDist - nearDist);
    mat[2][3] = 1.0;
    mat[3][3] = 0.0;
    return mat;
}

pub fn getTranslationMatrix(x: f32, y: f32, z: f32) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = 1;
    mat[1][1] = 1;
    mat[2][2] = 1;
    mat[3][3] = 1;
    mat[3][0] = x;
    mat[3][1] = y;
    mat[3][2] = z;

    return mat;
}

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
    const fieldOfView: f32 = 90.0;
    const fieldOfViewRad = 1.0 / std.math.tan(std.math.degreesToRadians(fieldOfView * 0.5));

    const projectionMatrix = getProjectionMatrix(
        nearDist,
        farDist,
        fieldOfViewRad,
        state.getAspectRatio(),
    );

    var lastTick = sdl3.timer.getNanosecondsSinceInit();
    var curTick = sdl3.timer.getMillisecondsSinceInit();
    var dt: f32 = 0;

    var quit = false;
    var theta: f32 = 0;
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

        theta += dt;

        const rotZMat = getZRotationMatrix(theta);
        const rotXMat = getXRotationMatrix(0.5 * theta);

        try state.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try state.renderer.clear();

        try state.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });

        const worldMat = zm.mul(zm.mul(rotZMat, rotXMat), getTranslationMatrix(0, 0, 0.5));

        var trisToRaster = try std.ArrayList(Tri).initCapacity(allocator, 1000);

        // Illumination
        const light = zm.normalize3(zm.Vec{ 0, 0, -1, 0 });

        for (meshCube.tris.items) |tri| {
            const triRotZX = tri.mul(&worldMat);

            // Offset into the screen
            var translatedTri = triRotZX.translate(0, 0, 8);

            // Culling
            const normal = translatedTri.buildNormalAndGet();

            if (zm.dot3(normal, translatedTri.p[0] - vCamera)[0] > 0) continue;

            var projectedTri = translatedTri.project(&projectionMatrix);

            // Move to center
            projectedTri = projectedTri.translate(1, 1, 0);

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
