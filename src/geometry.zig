const sdl3 = @import("sdl3");
const std = @import("std");
const zm = @import("zmath");

const root = @import("root.zig");
const camera = @import("camera.zig");

pub fn projectPoint(vec: zm.Vec, mat: zm.Mat) zm.Vec {
    const v = zm.mul(vec, mat);
    const w = if (v[3] == 0) 1 else v[3];
    return v / @as(zm.Vec, @splat(w));
}

pub const Tri = struct {
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
            .normal = self.normal,
        };
    }

    pub fn mul(self: *const Self, rotationMatrix: *const zm.Mat) Self {
        return Tri{
            .p = .{
                zm.mul(self.p[0], rotationMatrix.*),
                zm.mul(self.p[1], rotationMatrix.*),
                zm.mul(self.p[2], rotationMatrix.*),
            },
            .normal = self.normal,
        };
    }

    pub fn translate(self: *const Self, offset: zm.Vec) Self {
        return Tri{
            .p = .{
                self.p[0] + offset,
                self.p[1] + offset,
                self.p[2] + offset,
            },
            .normal = self.normal,
        };
    }

    pub fn scale(self: *const Self, factor: zm.Vec) Self {
        return Tri{
            .p = .{
                self.p[0] * factor,
                self.p[1] * factor,
                self.p[2] * factor,
            },
            .normal = self.normal,
        };
    }
};

pub const Mesh = struct {
    tris: std.ArrayList(Tri),
    pos: zm.Vec,

    const Self = @This();

    pub fn loadFromObjFile(filepath: [:0]const u8, allocator: std.mem.Allocator, pos: zm.Vec) !Self {
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

        return Mesh{ .tris = faces, .pos = pos };
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


pub fn getXRotationMatrix(theta: f32) zm.Mat {
    return zm.Mat{
        .{ 1, 0, 0, 0 },
        .{ 0, @cos(theta), -@sin(theta), 0 },
        .{ 0, @sin(theta), @cos(theta), 0 },
        .{ 0, 0, 0, 1 },
    };
}

pub fn getYRotationMatrix(theta: f32) zm.Mat {
    return zm.Mat{
        .{ @cos(theta), 0, @sin(theta), 0 },
        .{ 0, 1, 0, 0 },
        .{ -@sin(theta), @cos(theta), 0, 0 },
        .{ 0, 0, 0, 1 },
    };
}

pub fn getZRotationMatrix(theta: f32) zm.Mat {
    return zm.Mat{
        .{ @cos(theta), @sin(theta), 0, 0 },
        .{ -@sin(theta), @cos(theta), 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

pub fn getIdentityMatrix() zm.Mat {
    return zm.Mat{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

pub fn getProjectionMatrix(state: *root.AppState, cam: *camera.Camera) zm.Mat {
    const fieldOfViewRad = 1.0 / @tan(std.math.degreesToRadians(cam.fieldOfView * 0.5));

    return zm.Mat{
        .{ state.getAspectRatio() * fieldOfViewRad, 0, 0, 0 },
        .{ 0, fieldOfViewRad, 0, 0 },
        .{ 0, 0, cam.farDist / (cam.farDist - cam.nearDist), 1 },
        .{ 0, 0, (-cam.farDist * cam.nearDist) / (cam.farDist - cam.nearDist), 0 },
    };
}

pub fn getTranslationMatrix(x: f32, y: f32, z: f32) zm.Mat {
    return zm.Mat{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ x, y, z, 1 },
    };
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

