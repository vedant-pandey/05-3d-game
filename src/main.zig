const sdl3 = @import("sdl3");
const std = @import("std");
const zm = @import("zmath");
const builtin = @import("builtin");

const c = @cImport({
    // @cDefine("VK_NO_PROTOTYPES", "");
    @cInclude("volk.h");

    // @cInclude("vulkan/vulkan.h");
    @cInclude("SDL3/SDL_vulkan.h");
    @cInclude("vk_mem_alloc.h");
});

const ScreenWidth = 1383;
const ScreenHeight = 1377;

const safeMode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const isMacos = builtin.target.os.tag == .macos;

const VulkanCtx = struct {
    instance: c.VkInstance,
    physicalDevice: c.VkPhysicalDevice,
    device: c.VkDevice,
    graphicsQueue: c.VkQueue,
    presentQueue: c.VkQueue,
    allocator: c.VmaAllocator,
    // surface: c.VkSurfaceKHR,
    surface: sdl3.vulkan.Surface,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, window: sdl3.video.Window, apiVersion: u32) !VulkanCtx {
        sdl3.vulkan.loadLibrary(null) catch {
            return error.SDL_Vulkan_LoadLibrary;
        };

        const procAddrFnPtr = c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse {
            return error.SDL_Vulkan_GetVkGetInstanceProcAddr;
        };

        c.volkInitializeCustom(@as(c.PFN_vkGetInstanceProcAddr, @ptrCast(procAddrFnPtr)));

        const requiredExtensions = try sdl3.vulkan.getInstanceExtensions();

        var extensions = try allocator.alloc([*:0]const u8, requiredExtensions.len + if (isMacos) @as(u32, 1) else 0);
        defer allocator.free(extensions);

        @memcpy(extensions[0..requiredExtensions.len], requiredExtensions);

        if (isMacos) {
            extensions[requiredExtensions.len] = c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        }

        var ctx: VulkanCtx = undefined;

        var createInfo = c.struct_VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledExtensionCount = @intCast(extensions.len),
            .ppEnabledExtensionNames = extensions.ptr,
            .pApplicationInfo = &c.VkApplicationInfo{
                .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
                .pNext = null,
                .pApplicationName = "vulkan renderer",
                .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
                .pEngineName = "No engine",
                .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
                .apiVersion = apiVersion,
            },
            .flags = if (isMacos) c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else 0,
        };

        if (safeMode) {
            const requiredLayers = [_][*:0]const u8{
                "VK_LAYER_KHRONOS_validation",
            };

            var pPropertyCount: u32 = undefined;
            _ = c.vkEnumerateInstanceLayerProperties.?(&pPropertyCount, null);
            const layers = try allocator.alloc(c.VkLayerProperties, pPropertyCount);
            defer allocator.free(layers);

            if (c.vkEnumerateInstanceLayerProperties.?(&pPropertyCount, layers.ptr) != c.VK_SUCCESS) {
                return error.Vulkan_VkEnumerateInstanceLayerProperties;
            }

            for (requiredLayers) |reqLayer| {
                var present = false;
                for (layers) |prop| {
                    if (std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&prop.layerName))), std.mem.span(reqLayer))) {
                        present = true;
                        break;
                    }
                }

                if (!present) {
                    std.debug.print("Missing layer - {s}\n", .{reqLayer});
                    return error.Vulkan_MissingRequiredLayer;
                }
            }
            createInfo.enabledLayerCount = @intCast(requiredLayers.len);
            createInfo.ppEnabledLayerNames = &requiredLayers;
        }

        if (c.vkCreateInstance.?(&createInfo, null, &ctx.instance) != c.VK_SUCCESS) {
            return error.Vulkan_VkCreateInstance;
        }
        c.volkLoadInstanceOnly(ctx.instance);

        var physicalDeviceCount: u32 = 1;

        // NOTE:: vkEnumeratePhysicalDevices can also return VK_INCOMPLETE as success but I'll ignore it for now
        // since I'm only querying a single device
        if (c.vkEnumeratePhysicalDevices.?(ctx.instance, &physicalDeviceCount, &ctx.physicalDevice) != c.VK_SUCCESS) {
            return error.Vulkan_VkCreateInstance;
        }

        // {
        //     // BUG: Mac Metal does not support geometryShader,
        //     // so any geomtry shader would need to be converted to compute shader, which may possibly require multi-pass
        //
        //     var vkPhysicalDeviceProperties: c.VkPhysicalDeviceProperties = undefined;
        //     c.vkGetPhysicalDeviceProperties.?(ctx.physicalDevice, &vkPhysicalDeviceProperties);
        //     std.debug.print("{any}\n", .{vkPhysicalDeviceProperties.deviceType});
        //
        //     var dynamicRenderingFeatures = c.VkPhysicalDeviceDynamicRenderingFeatures{
        //         .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
        //         .pNext = null,
        //     };
        //     var extendedDynamicState2Features = c.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT{
        //         .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
        //         .pNext = &dynamicRenderingFeatures,
        //     };
        //
        //     var vkPhysicalDeviceFeatures2 = c.VkPhysicalDeviceFeatures2{
        //         .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        //         .pNext = &extendedDynamicState2Features,
        //     };
        //
        //     // NOTE: vkGetPhysicalDeviceFeatures2
        //     c.vkGetPhysicalDeviceFeatures2.?(ctx.physicalDevice, &vkPhysicalDeviceFeatures2);
        //     std.debug.print("{any}\n", .{vkPhysicalDeviceFeatures2});
        //     // .{
        //     //     .sType = 1000059000,
        //     //     .pNext = "anyopaque@16cebf4f0",
        //     //     .features = .{ .robustBufferAccess = 1, .fullDrawIndexUint32 = 1, .imageCubeArray = 1, .independentBlend = 1, .geometryShader = 0, .tessellationShader = 1, .sampleRateShading = 1, .dualSrcBlend = 1, .logicOp = 0, .multiDrawIndirect = 1, .drawIndirectFirstInstance = 1, .depthClamp = 1, .depthBiasClamp = 1, .fillModeNonSolid = 1, .depthBounds = 0, .wideLines = 0, .largePoints = 1, .alphaToOne = 1, .multiViewport = 1, .samplerAnisotropy = 1, .textureCompressionETC2 = 1, .textureCompressionASTC_LDR = 1, .textureCompressionBC = 1, .occlusionQueryPrecise = 1, .pipelineStatisticsQuery = 0, .vertexPipelineStoresAndAtomics = 1, .fragmentStoresAndAtomics = 1, .shaderTessellationAndGeometryPointSize = 1, .shaderImageGatherExtended = 1, .shaderStorageImageExtendedFormats = 1, .shaderStorageImageMultisample = 0, .shaderStorageImageReadWithoutFormat = 1, .shaderStorageImageWriteWithoutFormat = 1, .shaderUniformBufferArrayDynamicIndexing = 1, .shaderSampledImageArrayDynamicIndexing = 1, .shaderStorageBufferArrayDynamicIndexing = 1, .shaderStorageImageArrayDynamicIndexing = 1, .shaderClipDistance = 1, .shaderCullDistance = 0, .shaderFloat64 = 0, .shaderInt64 = 1, .shaderInt16 = 1, .shaderResourceResidency = 0, .shaderResourceMinLod = 1, .sparseBinding = 0, .sparseResidencyBuffer = 0, .sparseResidencyImage2D = 0, .sparseResidencyImage3D = 0, .sparseResidency2Samples = 0, .sparseResidency4Samples = 0, .sparseResidency8Samples = 0, .sparseResidency16Samples = 0, .sparseResidencyAliased = 0, .variableMultisampleRate = 0, .inheritedQueries = 1, }, };
        //     // };
        //
        //     std.debug.print("{any}\n", .{extendedDynamicState2Features});
        //     // .{
        //     //     .sType = 1000377000,
        //     //     .pNext = "anyopaque@16b4a3490",
        //     //     .extendedDynamicState2 = 1,
        //     //     .extendedDynamicState2LogicOp = 0,
        //     //     .extendedDynamicState2PatchControlPoints = 1,
        //     // };
        //
        //     std.debug.print("{any}\n", .{dynamicRenderingFeatures});
        //     // .{
        //     //     .sType = 1000044003,
        //     //     .pNext = null,
        //     //     .dynamicRendering = 1,
        //     // };
        //
        // }

        // {
        //     // NOTE: Check queue flag properties
        //
        //     var pQueueFamilyPropertyCount: u32 = undefined;
        //
        //     c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &pQueueFamilyPropertyCount, null);
        //     const pQueueFamilyProperties = try allocator.alloc(c.struct_VkQueueFamilyProperties, pQueueFamilyPropertyCount);
        //     defer allocator.free(pQueueFamilyProperties);
        //
        //     c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &pQueueFamilyPropertyCount, pQueueFamilyProperties.ptr);
        //     for (pQueueFamilyProperties, 0..) |prop, i| {
        //         // NOTE:
        //         // VK_QUEUE_GRAPHICS_BIT specifies that queues in this queue family support graphics operations.
        //         std.debug.print("{} - VK_QUEUE_GRAPHICS_BIT - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 });
        //         // VK_QUEUE_COMPUTE_BIT specifies that queues in this queue family support compute operations.
        //         std.debug.print("{} - VK_QUEUE_COMPUTE_BIT - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0 });
        //         // VK_QUEUE_TRANSFER_BIT specifies that queues in this queue family support transfer operations.
        //         std.debug.print("{} - VK_QUEUE_TRANSFER_BIT - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_TRANSFER_BIT != 0 });
        //         // VK_QUEUE_SPARSE_BINDING_BIT specifies that queues in this queue family support sparse memory management
        //         // operations (see Sparse Resources). If any of the sparse resource features are supported,
        //         // then at least one queue family must support this bit.
        //         std.debug.print("{} - VK_QUEUE_SPARSE_BINDING_BIT - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_SPARSE_BINDING_BIT != 0 });
        //         // VK_QUEUE_VIDEO_DECODE_BIT_KHR specifies that queues in this queue family support video decode operations.
        //         std.debug.print("{} - VK_QUEUE_PROTECTED_BIT - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_PROTECTED_BIT != 0 });
        //         // VK_QUEUE_VIDEO_ENCODE_BIT_KHR specifies that queues in this queue family support video encode operations.
        //         std.debug.print("{} - VK_QUEUE_VIDEO_DECODE_BIT_KHR - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_VIDEO_DECODE_BIT_KHR != 0 });
        //         // VK_QUEUE_OPTICAL_FLOW_BIT_NV specifies that queues in this queue family support optical flow operations.
        //         std.debug.print("{} - VK_QUEUE_VIDEO_ENCODE_BIT_KHR - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_VIDEO_ENCODE_BIT_KHR != 0 });
        //         // VK_QUEUE_DATA_GRAPH_BIT_ARM specifies that queues in this queue family support data graph operations.
        //         std.debug.print("{} - VK_QUEUE_OPTICAL_FLOW_BIT_NV - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_OPTICAL_FLOW_BIT_NV != 0 });
        //         // VK_QUEUE_PROTECTED_BIT specifies that queues in this queue family support the VK_DEVICE_QUEUE_CREATE_PROTECTED_BIT bit.
        //         // (see Protected Memory). If the physical device supports the protectedMemory feature,
        //         // at least one of its queue families must support this bit.
        //         std.debug.print("{} - VK_QUEUE_DATA_GRAPH_BIT_ARM - {any}\n", .{ i, prop.queueFlags & c.VK_QUEUE_DATA_GRAPH_BIT_ARM != 0 });
        //         std.debug.print("\n", .{});
        //     }
        // }

        // NOTE: for my current machine (macbook m1 max) - There are 4 queues each of which support graphics, compute, and transfer

        var dynamicRenderingFeatures = c.VkPhysicalDeviceVulkan13Features{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = null,
            .dynamicRendering = c.VK_TRUE,
        };
        var extendedDynamicState2Features = c.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
            .pNext = &dynamicRenderingFeatures,
            .extendedDynamicState2 = c.VK_TRUE,
        };
        var vkPhysicalDeviceFeatures2 = c.VkPhysicalDeviceFeatures2{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &extendedDynamicState2Features,
        };

        ctx.surface = try sdl3.vulkan.Surface.init(
            window,
            @ptrCast(ctx.instance),
            null,
        );

        // NOTE:
        // https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Window_surface.html#_querying_for_presentation_support
        // It’s actually possible that the queue families supporting drawing commands and the queue families supporting
        // presentation do not overlap. Therefore, we have to take into account that there could be a distinct presentation queue.
        var queueFamilyCount: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &queueFamilyCount, null);
        const queueFamilies = try allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
        defer allocator.free(queueFamilies);
        c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &queueFamilyCount, queueFamilies.ptr);

        var graphicsFamily: ?u32 = null;
        var presentFamily: ?u32 = null;

        for (queueFamilies, 0..) |family, i| {
            const idx = @as(u32, @intCast(i));

            // Check for Graphics support
            if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                graphicsFamily = idx;
            }

            // Check for Surface/Presentation support
            var presentSupport: c.VkBool32 = c.VK_FALSE;
            _ = c.vkGetPhysicalDeviceSurfaceSupportKHR.?(ctx.physicalDevice, idx, @ptrCast(ctx.surface.surface), &presentSupport);
            if (presentSupport == c.VK_TRUE) {
                presentFamily = idx;
            }

            if (graphicsFamily != null and presentFamily != null) break;
        }

        const gQueueFamilyInd = graphicsFamily orelse return error.NoGraphicsQueue;
        const pQueueFamilyInd = presentFamily orelse return error.NoPresentQueue;

        const queuePriority = [_]f32{1.0};
        var queueCreateInfos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queueCount: u32 = 0;

        queueCreateInfos[0] = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = gQueueFamilyInd,
            .queueCount = 1,
            .pQueuePriorities = &queuePriority,
        };
        queueCount = 1;

        // NOTE: Only add the Present queue if it's a different family
        if (gQueueFamilyInd != pQueueFamilyInd) {
            queueCreateInfos[1] = .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = pQueueFamilyInd,
                .queueCount = 1,
                .pQueuePriorities = &queuePriority,
            };
            queueCount = 2;
        }

        const enabledExtensionNames =
            [_][*:0]const u8{
                c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                c.VK_KHR_SPIRV_1_4_EXTENSION_NAME,
                c.VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
                c.VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
            } ++
            if (isMacos)
                .{"VK_KHR_portability_subset"}
            else
                .{};

        const deviceCreateInfo = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &vkPhysicalDeviceFeatures2,
            .enabledExtensionCount = enabledExtensionNames.len,
            .ppEnabledExtensionNames = &enabledExtensionNames,
            .queueCreateInfoCount = queueCount, // Use our local count
            .pQueueCreateInfos = &queueCreateInfos,
            // NOTE: This should be null if passing vkPhysicalDeviceFeatures2 in pNext
            // .pEnabledFeatures = &c.VkPhysicalDeviceFeatures{},
        };

        if (c.vkCreateDevice.?(ctx.physicalDevice, &deviceCreateInfo, null, &ctx.device) != c.VK_SUCCESS) {
            return error.Vulkan_VkCreateDevice;
        }

        c.volkLoadDevice(ctx.device);

        c.vkGetDeviceQueue.?(ctx.device, gQueueFamilyInd, 0, &ctx.graphicsQueue);
        c.vkGetDeviceQueue.?(ctx.device, pQueueFamilyInd, 0, &ctx.presentQueue);

        const vmaAllocatorCreateInfo = c.VmaAllocatorCreateInfo{
            .physicalDevice = ctx.physicalDevice,
            .device = ctx.device,
            .vulkanApiVersion = apiVersion,
            .instance = ctx.instance,
            .pVulkanFunctions = &c.VmaVulkanFunctions{
                .vkGetPhysicalDeviceProperties = c.vkGetPhysicalDeviceProperties,
                .vkGetPhysicalDeviceMemoryProperties = c.vkGetPhysicalDeviceMemoryProperties,
                .vkAllocateMemory = c.vkAllocateMemory,
                .vkFreeMemory = c.vkFreeMemory,
                .vkMapMemory = c.vkMapMemory,
                .vkUnmapMemory = c.vkUnmapMemory,
                .vkFlushMappedMemoryRanges = c.vkFlushMappedMemoryRanges,
                .vkInvalidateMappedMemoryRanges = c.vkInvalidateMappedMemoryRanges,
                .vkBindBufferMemory = c.vkBindBufferMemory,
                .vkBindImageMemory = c.vkBindImageMemory,
                .vkGetBufferMemoryRequirements = c.vkGetBufferMemoryRequirements,
                .vkGetImageMemoryRequirements = c.vkGetImageMemoryRequirements,
                .vkCreateBuffer = c.vkCreateBuffer,
                .vkDestroyBuffer = c.vkDestroyBuffer,
                .vkCreateImage = c.vkCreateImage,
                .vkDestroyImage = c.vkDestroyImage,
                .vkCmdCopyBuffer = c.vkCmdCopyBuffer,
                .vkGetBufferMemoryRequirements2KHR = c.vkGetBufferMemoryRequirements2,
                .vkGetImageMemoryRequirements2KHR = c.vkGetImageMemoryRequirements2,
                .vkBindBufferMemory2KHR = c.vkBindBufferMemory2,
                .vkBindImageMemory2KHR = c.vkBindImageMemory2,
                .vkGetPhysicalDeviceMemoryProperties2KHR = c.vkGetPhysicalDeviceMemoryProperties2,
            },
        };

        if (c.vmaCreateAllocator(&vmaAllocatorCreateInfo, &ctx.allocator) != c.VK_SUCCESS) {
            return error.VMA_CreateAllocator;
        }

        return ctx;
    }

    pub fn deinit(self: *Self) !void {
        _ = self;
        @panic("Not implemented");
    }
};

const AppState = struct {
    window: sdl3.video.Window,
    // renderer: sdl3.render.Renderer,
    width: usize,
    height: usize,
    initFlags: sdl3.InitFlags,
    keyState: []const bool,
    paused: bool,
    quit: bool,
    allocator: std.mem.Allocator,
    relMouseMode: bool = true,

    ctx: VulkanCtx,

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
            // .renderer = renderer,
            .width = width,
            .height = height,
            .initFlags = initFlags,
            .keyState = sdl3.keyboard.getState(),
            .paused = false,
            .quit = false,
            .allocator = allocator,
            .ctx = try VulkanCtx.init(allocator, window, c.VK_API_VERSION_1_4),
        };

        // const renderer = try sdl3.render.Renderer.init(window, null);

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

const Mesh = struct {
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

pub fn getProjectionMatrix(state: *AppState, cam: *Camera) zm.Mat {
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

    var state = try AppState.init(allocator, .{ .video = true }, ScreenWidth, ScreenHeight);
    defer state.deinit();

    var meshes = [_]Mesh{
        try Mesh.loadFromObjFile("./objs/axis.obj", state.allocator, .{ 0, 0, 15, 0 }),
        try Mesh.loadFromObjFile("./objs/videoship.obj", state.allocator, .{ -10, 10, 25, 0 }),
        try Mesh.loadFromObjFile("./objs/mountains.obj", state.allocator, .{ 0, -25, 0, 0 }),
    };

    defer {
        for (&meshes) |*mesh| {
            mesh.deinit(state.allocator);
        }
    }

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

    const projectionMatrix = getProjectionMatrix(&state, &cam);

    var lastTick = sdl3.timer.getNanosecondsSinceInit();
    var curTick = sdl3.timer.getMillisecondsSinceInit();
    var dt: f32 = 0;

    var trisToRaster = try std.ArrayList(Tri).initCapacity(state.allocator, 1000);
    defer trisToRaster.deinit(state.allocator);

    var lights = try std.ArrayList(zm.Vec).initCapacity(state.allocator, 10);
    try lights.append(state.allocator, zm.normalize3(zm.Vec{ 0, 0, -1, 0 }));

    defer lights.deinit(state.allocator);

    const ambientLight: f32 = 0.5;

    var trisOnScreen = try std.ArrayList(Tri).initCapacity(state.allocator, 10); // Input buffer
    defer trisOnScreen.deinit(state.allocator);

    var iterativeClipList = try std.ArrayList(Tri).initCapacity(state.allocator, 10); // Output buffer
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

        // try state.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        // try state.renderer.clear();
        //
        // try state.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });

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
            @cos(radYaw) * @cos(radPitch), // x
            @sin(radPitch), // y
            @sin(radYaw) * @cos(radPitch), // z
            0,
        });
        var targetDir = cam.pos + cam.dir;
        const matCam = pointAt(&cam.pos, &targetDir, &upDir);
        const viewMat = camInverse(&matCam);

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
                const clipped = clipTriangleAgainstPlane(.{ 0, 0, 1, 0 }, .{ 0, 0, 1, 0 }, triViewed);
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
        std.mem.sort(Tri, trisToRaster.items, {}, Tri.lessThan);

        for (trisToRaster.items) |tri| {
            trisOnScreen.clearRetainingCapacity();
            try trisOnScreen.append(state.allocator, tri);

            try clipTriToScreen(&state, &iterativeClipList, &trisOnScreen);

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

                // try tri2.drawFill(&state.renderer, .{
                //     .r = 1 * intensity,
                //     .g = 1 * intensity,
                //     .b = 1 * intensity,
                //     .a = 1,
                // });
                //
                // // Draw Wireframe
                // try tri2.drawWireframe(&state.renderer, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
            }
        }

        // try state.renderer.present();
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

pub fn clipTriToScreen(state: *const AppState, iterativeClipList: *std.ArrayList(Tri), trisOnScreen: *std.ArrayList(Tri)) !void {
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
