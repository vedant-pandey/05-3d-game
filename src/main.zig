const std = @import("std");
const sdl3 = @import("sdl3");
const zm = @import("zmath");
const build_options = @import("build_options");

const root = @import("root.zig");
const geometry = @import("geometry.zig");
const camera = @import("camera.zig");

const ScreenWidth = 1383;
const ScreenHeight = 1377;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = try root.AppState.init(allocator, .{ .video = true }, ScreenWidth, ScreenHeight);
    defer state.deinit();

    var meshes = [_]geometry.Mesh{
        try geometry.Mesh.loadFromObjFile("./objs/axis.obj", state.allocator, .{ 0, 0, 15, 0 }),
        try geometry.Mesh.loadFromObjFile("./objs/VideoShip.obj", state.allocator, .{ -10, 10, 25, 0 }),
        try geometry.Mesh.loadFromObjFile("./objs/mountains.obj", state.allocator, .{ 0, -25, 0, 0 }),
    };

    defer {
        for (&meshes) |*mesh| {
            mesh.deinit(state.allocator);
        }
    }

    var cam = camera.Camera{
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

    const projectionMatrix = geometry.getProjectionMatrix(&state, &cam);

    var lastTick = sdl3.timer.getNanosecondsSinceInit();
    var curTick = sdl3.timer.getMillisecondsSinceInit();
    var dt: f32 = 0;

    var trisToRaster = try std.ArrayList(geometry.Tri).initCapacity(state.allocator, 1000);
    defer trisToRaster.deinit(state.allocator);

    var lights = try std.ArrayList(zm.Vec).initCapacity(state.allocator, 10);
    try lights.append(state.allocator, zm.normalize3(zm.Vec{ 0, 0, -1, 0 }));

    defer lights.deinit(state.allocator);

    const ambientLight: f32 = 0.5;

    var trisOnScreen = try std.ArrayList(geometry.Tri).initCapacity(state.allocator, 10); // Input buffer
    defer trisOnScreen.deinit(state.allocator);

    var iterativeClipList = try std.ArrayList(geometry.Tri).initCapacity(state.allocator, 10); // Output buffer
    defer iterativeClipList.deinit(state.allocator);

    var quit = false;
    var theta: f32 = 0;
    while (!quit) {
        lastTick = curTick;
        curTick = sdl3.timer.getMillisecondsSinceInit();
        dt = @as(f32, @floatFromInt(curTick - lastTick)) / 1000.0;

        if (!state.paused) {
            theta += dt;
        }

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
                        .space => {
                            state.paused = !state.paused;
                        },
                        .escape => {
                            state.relMouseMode = !state.relMouseMode;
                            try sdl3.mouse.setWindowRelativeMode(state.window, state.relMouseMode);
                        },
                        else => {},
                    }
                },
                .mouse_motion => {
                    if (state.relMouseMode) {
                        const x = event.mouse_motion.x_rel;
                        const y = event.mouse_motion.y_rel;
                        cam.yaw += x * cam.sensitivity;
                        cam.pitch -= y * cam.sensitivity;

                        // Clamp pitch so you can't flip the camera upside down
                        if (cam.pitch > 89.0) cam.pitch = 89.0;
                        if (cam.pitch < -89.0) cam.pitch = -89.0;
                    }
                },
                .window_resized => {
                    state.resize(event.window_resized.height, event.window_resized.width);
                },
                else => {},
            }
        }

        if (state.keyState[@intFromEnum(sdl3.Scancode.w)]) {
            cam.pos[1] += speed;
        }
        if (state.keyState[@intFromEnum(sdl3.Scancode.s)]) {
            cam.pos[1] -= speed;
        }
        if (state.keyState[@intFromEnum(sdl3.Scancode.a)]) {
            cam.moveRight(-speed);
        }
        if (state.keyState[@intFromEnum(sdl3.Scancode.d)]) {
            cam.moveRight(speed);
        }
        if (state.keyState[@intFromEnum(sdl3.Scancode.j)]) {
            cam.pos -= cam.dir * @as(zm.Vec, @splat(speed));
        }
        if (state.keyState[@intFromEnum(sdl3.Scancode.k)]) {
            cam.pos += cam.dir * @as(zm.Vec, @splat(speed));
        }

        if (!build_options.enable_vulkan) {
            try state.renderer.?.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
            try state.renderer.?.clear();

            try state.renderer.?.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
        }

        const worldMat = zm.mul(
            zm.mul(
                // getZRotationMatrix(theta),
                // getXRotationMatrix(0.5 * theta),
                geometry.getZRotationMatrix(0),
                geometry.getXRotationMatrix(0),
            ),
            geometry.getTranslationMatrix(0, 0, 0.5),
        );

        const radYaw = std.math.degreesToRadians(cam.yaw);
        const radPitch = std.math.degreesToRadians(cam.pitch);
        cam.dir = zm.normalize3(zm.Vec{
            @cos(radYaw) * @cos(radPitch), // x
            @sin(radPitch), // y
            @sin(radYaw) * @cos(radPitch), // z
            0,
        });
        var targetDir = cam.pos + cam.dir;
        const matCam = geometry.pointAt(&cam.pos, &targetDir, &upDir);
        const viewMat = camera.camInverse(&matCam);

        trisToRaster.clearRetainingCapacity();

        for (meshes) |mesh| {
            for (mesh.tris.items) |tri| {
                var triViewed = tri
                    .mul(&worldMat)
                    .translate(mesh.pos)
                    .mul(&viewMat);

                // Culling
                const normal = triViewed.buildNormalAndGet();

                if (zm.dot3(normal, triViewed.p[0])[0] > 0) continue;

                // Clipping
                const clipped = camera.clipTriangleAgainstPlane(.{ 0, 0, 1, 0 }, .{ 0, 0, 1, 0 }, triViewed);
                for (0..clipped.count) |i| {
                    const clippedTri = clipped.tris[i];

                    // Project
                    var projectedTri = clippedTri
                        // Project to screen
                        .project(&projectionMatrix)
                        // Fix XY plane
                        .scale(.{ -1, -1, 1, 1 })
                        // Offset to center
                        .translate(.{ 1, 1, 0, 0 })
                        // Scale to screen size
                        .scale(.{ 0.5 * @as(f32, @floatFromInt(state.width)), 0.5 * @as(f32, @floatFromInt(state.width)), 1, 1 });

                    // Keep the original normal for lighting
                    projectedTri.normal = normal;

                    try trisToRaster.append(state.allocator, projectedTri);
                }
            }
        }

        // Sorting back to front
        std.mem.sort(geometry.Tri, trisToRaster.items, {}, geometry.Tri.lessThan);

        for (trisToRaster.items) |tri| {
            trisOnScreen.clearRetainingCapacity();
            try trisOnScreen.append(state.allocator, tri);

            try camera.clipTriToScreen(&state, &iterativeClipList, &trisOnScreen);

            for (trisOnScreen.items) |tri2| {
                var intensity = ambientLight;
                for (lights.items) |worldLight| {
                    const light = zm.normalize3(zm.mul(worldLight, viewMat));
                    const lightIntensity = zm.dot3(tri2.normal, light)[0];

                    // Only add positive light
                    if (lightIntensity > 0) {
                        intensity += lightIntensity;
                    }
                }

                intensity = @min(intensity, 1.0);

                if (!build_options.enable_vulkan) {
                    try tri2.drawFill(&state.renderer.?, .{
                        .r = 1 * intensity,
                        .g = 1 * intensity,
                        .b = 1 * intensity,
                        .a = 1,
                    });

                    // Draw Wireframe
                    try tri2.drawWireframe(&state.renderer.?, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
                }
            }
        }

        if (!build_options.enable_vulkan) {
            try state.renderer.?.present();
        }
    }
}
