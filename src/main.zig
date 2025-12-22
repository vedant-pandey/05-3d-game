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

    pub fn lessThan(_: void, a: Tri, b: Tri) bool {
        const z1 = (a.p[0][2] + a.p[1][2] + a.p[2][2]) / 3;
        const z2 = (b.p[0][2] + b.p[1][2] + b.p[2][2]) / 3;
        return z1 > z2;
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

    pub fn scale(self: *const Self, x: f32, y: f32, z: f32) Tri {
        var tri = self.copy();

        tri.p[0][0] *= x;
        tri.p[1][0] *= x;
        tri.p[2][0] *= x;
        tri.p[0][1] *= y;
        tri.p[1][1] *= y;
        tri.p[2][1] *= y;
        tri.p[0][2] *= z;
        tri.p[1][2] *= z;
        tri.p[2][2] *= z;

        return tri;
    }

    pub fn copy(self: Self) Self {
        return self;
    }
};

const Mesh = struct {
    tris: std.ArrayList(Tri),

    const Self = @This();

    pub fn loadFromObjFile(filepath: [:0]const u8, allocator: std.mem.Allocator) !Self {
        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();
        var buffer: [128]u8 = .{0} ** 128;
        var reader = file.reader(buffer[0..]);
        var verts = try std.ArrayList(zm.Vec).initCapacity(allocator, 100);
        defer verts.deinit(allocator);

        var faces = try std.ArrayList(Tri).initCapacity(allocator, 100);

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

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.tris.deinit(allocator);
    }

    pub fn cubeMesh(allocator: std.mem.Allocator) !Self {
        var meshCube = Mesh{
            .tris = try std.ArrayList(Tri).initCapacity(allocator, 100),
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

const Camera = struct {
    pos: zm.Vec,
    dir: zm.Vec,
    nearDist: f32 = 0.1,
    farDist: f32 = 1000.0,
    fieldOfView: f32 = 90.0,
    up: zm.Vec,
    yaw: f32 = 90,
    pitch: f32 = 0,
    sensitivity: f32 = 0.1,

    const Self = @This();

    pub fn moveRight(self: *Self, dist: f32) void {
        const right = zm.normalize3(zm.cross3(self.dir, self.up));
        self.pos += right * @as(zm.Vec, @splat(dist));
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

pub fn getProjectionMatrix2(state: *AppState, cam: *Camera) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;
    const fieldOfViewRad = 1.0 / std.math.tan(std.math.degreesToRadians(cam.fieldOfView * 0.5));

    mat[0][0] = state.getAspectRatio() * fieldOfViewRad;
    mat[1][1] = fieldOfViewRad;
    mat[2][2] = cam.farDist / (cam.farDist - cam.nearDist);
    mat[3][2] = (-cam.farDist * cam.nearDist) / (cam.farDist - cam.nearDist);
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

pub fn pointAt(pos: *const zm.Vec, target: *const zm.Vec, up: *const zm.Vec) zm.Mat {
    const newForward = zm.normalize3(target.* - pos.*);

    const a = newForward * zm.dot3(up.*, newForward);
    const newUp = zm.normalize3(up.* - a);

    const newRight = zm.cross3(newUp, newForward);

    return zm.Mat{
        newRight,
        newUp,
        newForward,
        pos.*,
    };
}

pub fn camInverse(m: *const zm.Mat) zm.Mat {
    var mat: zm.Mat = .{.{0} ** 4} ** 4;

    mat[0][0] = m[0][0];
    mat[0][1] = m[1][0];
    mat[0][2] = m[2][0];
    mat[0][3] = 0.0;
    mat[1][0] = m[0][1];
    mat[1][1] = m[1][1];
    mat[1][2] = m[2][1];
    mat[1][3] = 0.0;
    mat[2][0] = m[0][2];
    mat[2][1] = m[1][2];
    mat[2][2] = m[2][2];
    mat[2][3] = 0.0;
    mat[3][0] = -(m[3][0] * mat[0][0] + m[3][1] * mat[1][0] + m[3][2] * mat[2][0]);
    mat[3][1] = -(m[3][0] * mat[0][1] + m[3][1] * mat[1][1] + m[3][2] * mat[2][1]);
    mat[3][2] = -(m[3][0] * mat[0][2] + m[3][1] * mat[1][2] + m[3][2] * mat[2][2]);
    mat[3][3] = 1.0;

    return mat;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = try AppState.init(.{ .video = true }, ScreenWidth, ScreenHeight);
    defer state.deinit();

    var meshCube = try Mesh.loadFromObjFile("./objs/axis.obj", allocator);
    defer meshCube.deinit(allocator);

    var cam = Camera{
        .pos = .{ 0, 0, 0, 1 },
        .dir = .{ 0, 0, 1, 1 },
        .nearDist = 0.1,
        .farDist = 1000.0,
        .fieldOfView = 90.0,
        .up = zm.Vec{ 0, 1, 0, 0 },
        .yaw = 90,
        .pitch = 0,
        .sensitivity = 0.1,
    };

    const upDir = zm.Vec{ 0, 1, 0, 0 };

    const projectionMatrix = getProjectionMatrix2(&state, &cam);

    var lastTick = sdl3.timer.getNanosecondsSinceInit();
    var curTick = sdl3.timer.getMillisecondsSinceInit();
    var dt: f32 = 0;

    var trisToRaster = try std.ArrayList(Tri).initCapacity(allocator, 1000);
    defer trisToRaster.deinit(allocator);

    var lights = try std.ArrayList(zm.Vec).initCapacity(allocator, 10);
    try lights.append(allocator, zm.normalize3(zm.Vec{ 0, 0, -1, 0 }));

    defer lights.deinit(allocator);

    const ambientLight: f32 = 0.1;

    var quit = false;
    var theta: f32 = 0;
    while (!quit) {
        lastTick = curTick;
        curTick = sdl3.timer.getMillisecondsSinceInit();
        dt = @as(f32, @floatFromInt(curTick - lastTick)) / 500.0;

        theta += dt;
        const speed = 8 * dt;

        while (sdl3.events.poll()) |event| {
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .key_down => {
                    switch (event.key_down.key.?) {
                        .q => {
                            quit = true;
                        },
                        .w => {
                            cam.pos[1] += speed;
                        },
                        .s => {
                            cam.pos[1] -= speed;
                        },
                        .a => {
                            cam.moveRight(-speed);
                        },
                        .d => {
                            cam.moveRight(speed);
                        },
                        .j => {
                            cam.pos -= cam.dir * @as(zm.Vec, @splat(speed));
                        },
                        .k => {
                            cam.pos += cam.dir * @as(zm.Vec, @splat(speed));
                        },
                        else => {},
                    }
                },
                .mouse_motion => {
                    const x = event.mouse_motion.x_rel;
                    const y = event.mouse_motion.y_rel;
                    cam.yaw += x * cam.sensitivity;
                    cam.pitch -= y * cam.sensitivity;

                    // Clamp pitch so you can't flip the camera upside down
                    if (cam.pitch > 89.0) cam.pitch = 89.0;
                    if (cam.pitch < -89.0) cam.pitch = -89.0;
                },
                .window_resized => {
                    state.height = @intCast(event.window_resized.height);
                    state.width = @intCast(event.window_resized.width);
                    std.debug.print("{} {} \n", .{ state.height, state.width });
                },
                else => {},
            }
        }

        try state.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try state.renderer.clear();

        try state.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });

        const worldMat = zm.mul(
            zm.mul(
                // getZRotationMatrix(theta),
                // getXRotationMatrix(0.5 * theta),
                getZRotationMatrix(0),
                getXRotationMatrix(0),
            ),
            getTranslationMatrix(0, 0, 0.5),
        );

        const radYaw = std.math.degreesToRadians(cam.yaw);
        const radPitch = std.math.degreesToRadians(cam.pitch);
        cam.dir = zm.normalize3(zm.Vec{
            std.math.cos(radYaw) * std.math.cos(radPitch), // x
            std.math.sin(radPitch), // y
            std.math.sin(radYaw) * std.math.cos(radPitch), // z
            0,
        });
        var targetDir = cam.pos + cam.dir;
        const matCam = pointAt(&cam.pos, &targetDir, &upDir);
        const viewMat = camInverse(&matCam);

        trisToRaster.clearRetainingCapacity();

        for (meshCube.tris.items) |tri| {
            var triViewed = tri
                .mul(&worldMat)
                .translate(0, 0, 8)
                .mul(&viewMat);

            // Culling
            const normal = triViewed.buildNormalAndGet();

            if (zm.dot3(normal, triViewed.p[0])[0] > 0) continue;

            // Clipping
            const clipped = clipTriangleAgainstPlane(.{ 0, 0, 1, 0 }, .{ 0, 0, 1, 0 }, triViewed);
            for (0..clipped.count) |i| {
                const clippedTri = clipped.tris[i];

                // Project
                var projectedTri = clippedTri
                    // Project to screen
                    .project(&projectionMatrix)
                    // Fix XY plane
                    .scale(-1, -1, 1)
                    // Offset to center
                    .translate(1, 1, 0)
                    // Scale to screen size
                    .scale(0.5 * @as(f32, @floatFromInt(state.width)), 0.5 * @as(f32, @floatFromInt(state.width)), 1);

                // Keep the original normal for lighting
                projectedTri.normal = normal;

                try trisToRaster.append(allocator, projectedTri);
            }
        }

        // Sorting back to front
        std.mem.sort(Tri, trisToRaster.items, {}, Tri.lessThan);

        var trisOnScreen = try std.ArrayList(Tri).initCapacity(allocator, 10); // Input buffer
        defer trisOnScreen.deinit(allocator);

        var iterativeClipList = try std.ArrayList(Tri).initCapacity(allocator, 10); // Output buffer
        defer iterativeClipList.deinit(allocator);

        for (trisToRaster.items) |tri| {
            var intensity = ambientLight;

            trisOnScreen.clearRetainingCapacity();
            try trisOnScreen.append(allocator, tri);
            for (0..4) |p| {
                iterativeClipList.clearRetainingCapacity();
                while (trisOnScreen.items.len > 0) {
                    const clipTris = switch (p) {
                        0 => clipTriangleAgainstPlane(
                            .{ 0, 0, 0, 1 },
                            .{ 0, 1, 0, 1 },
                            trisOnScreen.pop().?,
                        ),
                        1 => clipTriangleAgainstPlane(
                            .{ 0, @as(f32, @floatFromInt(state.height)) - 1, 0, 1 },
                            .{ 0, -1, 0, 1 },
                            trisOnScreen.pop().?,
                        ),
                        2 => clipTriangleAgainstPlane(
                            .{ 0, 0, 0, 1 },
                            .{ 1, 0, 0, 1 },
                            trisOnScreen.pop().?,
                        ),
                        3 => clipTriangleAgainstPlane(
                            .{ @as(f32, @floatFromInt(state.width)) - 1, 0, 0, 1 },
                            .{ -1, 0, 0, 1 },
                            trisOnScreen.pop().?,
                        ),
                        else => unreachable,
                    };
                    for (0..clipTris.count) |i| {
                        try iterativeClipList.append(allocator, clipTris.tris[i]);
                    }
                }
                for (iterativeClipList.items) |t| {
                    try trisOnScreen.append(allocator, t);
                }
            }

            for (trisOnScreen.items) |tri2| {
                for (lights.items) |worldLight| {
                    const light = zm.normalize3(zm.mul(worldLight, viewMat));
                    const lightIntensity = zm.dot3(tri2.normal, light)[0];

                    // Only add positive light
                    if (lightIntensity > 0) {
                        intensity += lightIntensity;
                    }
                }

                intensity = @min(intensity, 1.0);

                try tri2.drawFill(&state.renderer, .{
                    .r = 1 * intensity,
                    .g = 1 * intensity,
                    .b = 1 * intensity,
                    .a = 1,
                });

                // Draw Wireframe
                try tri2.drawWireframe(&state.renderer, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
            }
        }

        try state.renderer.present();
    }
}

pub fn vectorIntersectPlane(planeP: zm.Vec, planeN: zm.Vec, lineStart: zm.Vec, lineEnd: zm.Vec) zm.Vec {
    const nPlaneNorm = zm.normalize3(planeN);
    const planeD = -zm.dot3(nPlaneNorm, planeP)[0];
    const ad = zm.dot3(lineStart, nPlaneNorm)[0];
    const bd = zm.dot3(lineEnd, nPlaneNorm)[0];
    const t = (-planeD - ad) / (bd - ad);
    const lineStartToLineEnd = lineEnd - lineStart;
    const lineToIntersect = lineStartToLineEnd * @as(zm.Vec, @splat(t));
    return lineStart + lineToIntersect;
}

pub fn clipTriangleAgainstPlane(planeP: zm.Vec, planeN: zm.Vec, inTri: Tri) struct { count: usize, tris: [2]Tri } {
    const nPlaneNorm = zm.normalize3(planeN);

    var inPoints: [3]zm.Vec = undefined;
    var inCount: usize = 0;
    var outPoints: [3]zm.Vec = undefined;
    var outCount: usize = 0;

    // Classify each point as inside or outside the plane
    inline for (0..3) |i| {
        const d = zm.dot3(nPlaneNorm, inTri.p[i])[0] - zm.dot3(nPlaneNorm, planeP)[0];
        if (d >= 0) {
            inPoints[inCount] = inTri.p[i];
            inCount += 1;
        } else {
            outPoints[outCount] = inTri.p[i];
            outCount += 1;
        }
    }

    var outTris: [2]Tri = undefined;

    if (inCount == 0) {
        return .{ .count = 0, .tris = outTris };
    } else if (inCount == 3) {
        outTris[0] = inTri;
        return .{ .count = 1, .tris = outTris };
    } else if (inCount == 1 and outCount == 2) {
        outTris[0].p[0] = inPoints[0];
        outTris[0].p[1] = vectorIntersectPlane(planeP, nPlaneNorm, inPoints[0], outPoints[0]);
        outTris[0].p[2] = vectorIntersectPlane(planeP, nPlaneNorm, inPoints[0], outPoints[1]);
        outTris[0].normal = inTri.normal;

        return .{ .count = 1, .tris = outTris };
    } else if (inCount == 2 and outCount == 1) {
        outTris[0].p[0] = inPoints[0];
        outTris[0].p[1] = inPoints[1];
        outTris[0].p[2] = vectorIntersectPlane(planeP, nPlaneNorm, inPoints[0], outPoints[0]);
        outTris[0].normal = inTri.normal;

        outTris[1].p[0] = inPoints[1];
        outTris[1].p[1] = outTris[0].p[2];
        outTris[1].p[2] = vectorIntersectPlane(planeP, nPlaneNorm, inPoints[1], outPoints[0]);
        outTris[1].normal = inTri.normal;

        return .{ .count = 2, .tris = outTris };
    }

    return .{ .count = 0, .tris = outTris };
}
