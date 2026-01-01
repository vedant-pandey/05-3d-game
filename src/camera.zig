const std = @import("std");
const zm = @import("zmath");
const geometry = @import("geometry.zig");
const root = @import("root.zig");

pub const Camera = struct {
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

pub fn clipTriangleAgainstPlane(planeP: zm.Vec, planeN: zm.Vec, inTri: geometry.Tri) struct { count: usize, tris: [2]geometry.Tri } {
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

    var outTris: [2]geometry.Tri = undefined;

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

pub fn clipTriToScreen(state: *const root.AppState, iterativeClipList: *std.ArrayList(geometry.Tri), trisOnScreen: *std.ArrayList(geometry.Tri)) !void {
    const clippingPlanes = [_][2]zm.Vec{
        .{ .{ 0, 0, 0, 1 }, .{ 0, 1, 0, 1 } },
        .{ .{ 0, @as(f32, @floatFromInt(state.height)) - 1, 0, 1 }, .{ 0, -1, 0, 1 } },
        .{ .{ 0, 0, 0, 1 }, .{ 1, 0, 0, 1 } },
        .{ .{ @as(f32, @floatFromInt(state.width)) - 1, 0, 0, 1 }, .{ -1, 0, 0, 1 } },
    };

    for (clippingPlanes) |p| {
        iterativeClipList.clearRetainingCapacity();
        while (trisOnScreen.items.len > 0) {
            const clipTris = clipTriangleAgainstPlane(p[0], p[1], trisOnScreen.pop().?);
            for (0..clipTris.count) |i| {
                try iterativeClipList.append(state.allocator, clipTris.tris[i]);
            }
        }
        for (iterativeClipList.items) |t| {
            try trisOnScreen.append(state.allocator, t);
        }
    }
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

