const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("volk.h");
    @cInclude("vk_mem_alloc.h");
});

const safeMode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const isMacos = builtin.target.os.tag == .macos;

pub const VulkanCtx = struct {
    instance: c.VkInstance,
    physicalDevice: c.VkPhysicalDevice,
    device: c.VkDevice,
    graphicsQueue: c.VkQueue,
    presentQueue: c.VkQueue,
    allocator: c.VmaAllocator,
    surface: sdl3.vulkan.Surface,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, window: sdl3.video.Window, apiVersion: u32) !VulkanCtx {
        sdl3.vulkan.loadLibrary(null) catch {
            return error.SDL_Vulkan_LoadLibrary;
        };

        const procAddrFnPtr = sdl3.vulkan.getVkGetInstanceProcAddr() catch {
            return error.SDL_Vulkan_GetVkGetInstanceProcAddr;
        };

        c.volkInitializeCustom(@as(c.PFN_vkGetInstanceProcAddr, @alignCast(@ptrCast(procAddrFnPtr))));

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
            return error.Vulkan_VkEnumeratePhysicalDevices;
        }

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

        {
            var surfaceCapabilities: c.struct_VkSurfaceCapabilitiesKHR = undefined;
            _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &surfaceCapabilities,
            );
            std.debug.print("{any}\n", .{surfaceCapabilities});
        }

        {
            var numFormats: u32 = undefined;
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(ctx.physicalDevice, @ptrCast(ctx.surface.surface), &numFormats, null);
            const surfaceFormats: []c.struct_VkSurfaceFormatKHR = try allocator.alloc(c.struct_VkSurfaceFormatKHR, numFormats);
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(ctx.physicalDevice, @ptrCast(ctx.surface.surface), &numFormats, surfaceFormats.ptr);
            std.debug.print("{any}\n", .{surfaceFormats});
        }

        {
            var numModes: u32 = undefined;
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(ctx.physicalDevice, @ptrCast(ctx.surface.surface), &numModes, null);
            const surfaceModes: []c.VkPresentModeKHR = try allocator.alloc(c.VkPresentModeKHR, numModes);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(ctx.physicalDevice, @ptrCast(ctx.surface.surface), &numModes, surfaceModes.ptr);
            std.debug.print("{any}\n", .{surfaceModes});
        }

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

fn isDeviceSuitable(physicalDevice: c.VkPhysicalDevice) bool {
    {
        // BUG: Mac Metal does not support geometryShader,
        // so any geomtry shader would need to be converted to compute shader, which may possibly require multi-pass

        var vkPhysicalDeviceProperties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties.?(physicalDevice, &vkPhysicalDeviceProperties);
        std.debug.print("{any}\n", .{vkPhysicalDeviceProperties.deviceType});

        var dynamicRenderingFeatures = c.VkPhysicalDeviceDynamicRenderingFeatures{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
            .pNext = null,
        };
        var extendedDynamicState2Features = c.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
            .pNext = &dynamicRenderingFeatures,
        };

        var vkPhysicalDeviceFeatures2 = c.VkPhysicalDeviceFeatures2{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &extendedDynamicState2Features,
        };

        // NOTE: vkGetPhysicalDeviceFeatures2
        c.vkGetPhysicalDeviceFeatures2.?(physicalDevice, &vkPhysicalDeviceFeatures2);
        std.debug.print("{any}\n", .{vkPhysicalDeviceFeatures2});
        // .{
        //     .sType = 1000059000,
        //     .pNext = "anyopaque@16cebf4f0",
        //     .features = .{ .robustBufferAccess = 1, .fullDrawIndexUint32 = 1, .imageCubeArray = 1, .independentBlend = 1, .geometryShader = 0, .tessellationShader = 1, .sampleRateShading = 1, .dualSrcBlend = 1, .logicOp = 0, .multiDrawIndirect = 1, .drawIndirectFirstInstance = 1, .depthClamp = 1, .depthBiasClamp = 1, .fillModeNonSolid = 1, .depthBounds = 0, .wideLines = 0, .largePoints = 1, .alphaToOne = 1, .multiViewport = 1, .samplerAnisotropy = 1, .textureCompressionETC2 = 1, .textureCompressionASTC_LDR = 1, .textureCompressionBC = 1, .occlusionQueryPrecise = 1, .pipelineStatisticsQuery = 0, .vertexPipelineStoresAndAtomics = 1, .fragmentStoresAndAtomics = 1, .shaderTessellationAndGeometryPointSize = 1, .shaderImageGatherExtended = 1, .shaderStorageImageExtendedFormats = 1, .shaderStorageImageMultisample = 0, .shaderStorageImageReadWithoutFormat = 1, .shaderStorageImageWriteWithoutFormat = 1, .shaderUniformBufferArrayDynamicIndexing = 1, .shaderSampledImageArrayDynamicIndexing = 1, .shaderStorageBufferArrayDynamicIndexing = 1, .shaderStorageImageArrayDynamicIndexing = 1, .shaderClipDistance = 1, .shaderCullDistance = 0, .shaderFloat64 = 0, .shaderInt64 = 1, .shaderInt16 = 1, .shaderResourceResidency = 0, .shaderResourceMinLod = 1, .sparseBinding = 0, .sparseResidencyBuffer = 0, .sparseResidencyImage2D = 0, .sparseResidencyImage3D = 0, .sparseResidency2Samples = 0, .sparseResidency4Samples = 0, .sparseResidency8Samples = 0, .sparseResidency16Samples = 0, .sparseResidencyAliased = 0, .variableMultisampleRate = 0, .inheritedQueries = 1, }, };
        // };

        std.debug.print("{any}\n", .{extendedDynamicState2Features});
        // .{
        //     .sType = 1000377000,
        //     .pNext = "anyopaque@16b4a3490",
        //     .extendedDynamicState2 = 1,
        //     .extendedDynamicState2LogicOp = 0,
        //     .extendedDynamicState2PatchControlPoints = 1,
        // };

        std.debug.print("{any}\n", .{dynamicRenderingFeatures});
        // .{
        //     .sType = 1000044003,
        //     .pNext = null,
        //     .dynamicRendering = 1,
        // };

    }

    return true;
}
