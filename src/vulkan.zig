const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("volk.h");
    @cInclude("vk_mem_alloc.h");
});

// TODO: Create a compiler flag for ease
const safeMode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const isMacos = builtin.target.os.tag == .macos;

// FIXME: Remove all print statements

const QueueSetup = struct {
    infos: []c.VkDeviceQueueCreateInfo,
    graphicsFamily: u32,
    presentFamily: u32,
};

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

        c.volkInitializeCustom(@as(c.PFN_vkGetInstanceProcAddr, @ptrCast(@alignCast(procAddrFnPtr))));

        var ctx: VulkanCtx = undefined;

        try initInstance(&ctx, allocator, apiVersion, safeMode);
        c.volkLoadInstanceOnly(ctx.instance);

        try initPhysicalDevice(&ctx, allocator);

        ctx.surface = try sdl3.vulkan.Surface.init(
            window,
            @ptrCast(ctx.instance),
            null,
        );

        const queueSetup = try getQueueCreateInfo(&ctx, allocator);
        defer allocator.free(queueSetup.infos);

        try initDevice(&ctx, queueSetup.infos);
        c.volkLoadDevice(ctx.device);

        c.vkGetDeviceQueue.?(ctx.device, queueSetup.graphicsFamily, 0, &ctx.graphicsQueue);
        c.vkGetDeviceQueue.?(ctx.device, queueSetup.presentFamily, 0, &ctx.presentQueue);

        {
            var surfaceCapabilities: c.struct_VkSurfaceCapabilitiesKHR = undefined;
            _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &surfaceCapabilities,
            );
            std.debug.print("Surface capabilities - \n{any}\n", .{surfaceCapabilities});
        }

        {
            var numFormats: u32 = undefined;
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &numFormats,
                null,
            );
            const surfaceFormats: []c.struct_VkSurfaceFormatKHR = try allocator.alloc(
                c.struct_VkSurfaceFormatKHR,
                numFormats,
            );
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &numFormats,
                surfaceFormats.ptr,
            );
            std.debug.print("Surface Formats -\n{any}\n", .{surfaceFormats});
        }

        {
            var numModes: u32 = undefined;
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &numModes,
                null,
            );
            const surfaceModes: []c.VkPresentModeKHR = try allocator.alloc(
                c.VkPresentModeKHR,
                numModes,
            );
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
                ctx.physicalDevice,
                @ptrCast(ctx.surface.surface),
                &numModes,
                surfaceModes.ptr,
            );
            std.debug.print("Surface Modes - \n{any}\n", .{surfaceModes});
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
        // FIXME: add validation to ensure device is not currently being used before calling destroy calls
        // TODO: check if vkAllocationCallback would need to be updated if using vulkan memory allocator
        c.vkDestroyDevice.deinit.?(self.device, null);
        sdl3.vulkan.Surface.deinit(self.surface);
        c.vkDestroyInstance.?(self.instance, null);
        @panic("Not implemented");
    }
};

fn initInstance(ctx: *VulkanCtx, allocator: std.mem.Allocator, apiVersion: u32, enableValidation: bool) !void {
    const requiredExtensions = try sdl3.vulkan.getInstanceExtensions();

    var extensions = try allocator.alloc([*:0]const u8, requiredExtensions.len + if (isMacos) @as(u32, 1) else 0);
    defer allocator.free(extensions);

    @memcpy(extensions[0..requiredExtensions.len], requiredExtensions);

    if (isMacos) {
        extensions[requiredExtensions.len] = c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    }

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

    if (enableValidation) {
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
                if (std.mem.eql(
                    u8,
                    std.mem.span(@as([*:0]const u8, @ptrCast(&prop.layerName))),
                    std.mem.span(reqLayer),
                )) {
                    present = true;
                    break;
                }
            }

            if (!present) {
                std.debug.print("Missing layer - {s}\n", .{reqLayer});
                // TODO: Check if it is better to panic here
                return error.Vulkan_MissingRequiredLayer;
            }
        }
        createInfo.enabledLayerCount = @intCast(requiredLayers.len);
        createInfo.ppEnabledLayerNames = &requiredLayers;
    }

    if (c.vkCreateInstance.?(&createInfo, null, &ctx.instance) != c.VK_SUCCESS) {
        return error.Vulkan_VkCreateInstance;
    }
}

// FIXME: Move to device namespace
fn initPhysicalDevice(ctx: *VulkanCtx, allocator: std.mem.Allocator) !void {
    var physicalDeviceCount: u32 = undefined;

    _ = c.vkEnumeratePhysicalDevices.?(ctx.instance, &physicalDeviceCount, null);

    const deviceArr = try allocator.alloc(c.VkPhysicalDevice, physicalDeviceCount);

    // FIXME: Move this function style everywhere to standard library style functions
    if (c.vkEnumeratePhysicalDevices.?(ctx.instance, &physicalDeviceCount, deviceArr.ptr) != c.VK_SUCCESS) {
        return error.Vulkan_VkEnumeratePhysicalDevices;
    }

    if (physicalDeviceCount == 0) {
        // TODO: No point in continuing might as well just panic but just throwing error here
        return error.Vulkan_NoPhysicalDeviceFound;
    }

    if (physicalDeviceCount == 1) {
        ctx.physicalDevice = deviceArr[0];
        return;
    }

    // NOTE: separating this logic to be able to bypass later if needed
    pickDevice(ctx, deviceArr);
}

fn pickDevice(ctx: *VulkanCtx, deviceArr: []c.VkPhysicalDevice) void {
    var maxDeviceScore: i32 = std.math.minInt(i32);
    var maxDeviceInd: usize = 0;

    for (deviceArr, 0..) |device, i| {
        var deviceProperties = c.VkPhysicalDeviceProperties2{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        };
        var curDeviceScore: i32 = 0;
        deviceProperties = c.VkPhysicalDeviceProperties2{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        };
        c.vkGetPhysicalDeviceProperties2.?(device, &deviceProperties);

        var deviceFeatures = c.VkPhysicalDeviceFeatures2{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        };
        c.vkGetPhysicalDeviceFeatures2.?(device, &deviceFeatures);

        if (deviceProperties.properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            curDeviceScore += 1000;
        }

        curDeviceScore += @intCast(deviceProperties.properties.limits.maxImageDimension2D);

        if (deviceFeatures.features.geometryShader == c.VK_FALSE) {
            // NOTE: https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/00_Setup/03_Physical_devices_and_queue_families.html#_base_device_suitability_checks
            // In Vulkan guide if the device does not have a geometry shader the device currently queried gets rejected
            // But since in mac we dont have geometryShader we can instead give this a big negative score
            // This would be a pain later while attempting to create parity using geometry shader and compute shader

            // FIXME: A better option is always to give the end user the choice of selecting
            // the gpu device on their system but I'll leave this for future scope
            curDeviceScore -= 2000;
        }

        if (curDeviceScore > maxDeviceScore) {
            maxDeviceScore = curDeviceScore;
            maxDeviceInd = i;
        }
    }

    ctx.physicalDevice = deviceArr[maxDeviceInd];
}

fn initDevice(ctx: *VulkanCtx, queueCreateInfos: []c.struct_VkDeviceQueueCreateInfo) !void {
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

    // TODO: Implement a better chaining interface using comptime
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

    const deviceCreateInfo = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &vkPhysicalDeviceFeatures2,
        .enabledExtensionCount = enabledExtensionNames.len,
        .ppEnabledExtensionNames = &enabledExtensionNames,
        .queueCreateInfoCount = @intCast(queueCreateInfos.len),
        .pQueueCreateInfos = queueCreateInfos.ptr,
        // NOTE: This should be null if passing vkPhysicalDeviceFeatures2 in pNext
        // .pEnabledFeatures = &c.VkPhysicalDeviceFeatures{},
    };

    if (c.vkCreateDevice.?(ctx.physicalDevice, &deviceCreateInfo, null, &ctx.device) != c.VK_SUCCESS) {
        return error.Vulkan_VkCreateDevice;
    }
}

// FIXME: Move to queue namespace
// TODO: Check if using this style of pointer can have wanted cost
// fn getQueueCreateInfo(ctx: *const VulkanCtx, allocator: std.mem.Allocator) ![]c.VkDeviceQueueCreateInfo {
fn getQueueCreateInfo(ctx: *const VulkanCtx, allocator: std.mem.Allocator) !QueueSetup {
    var queueCount: u32 = 0;
    var graphicsFamily: ?u32 = null;
    var presentFamily: ?u32 = null;

    // NOTE:
    // https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Window_surface.html#_querying_for_presentation_support
    // It’s actually possible that the queue families supporting drawing commands and the queue families supporting
    // presentation do not overlap. Therefore, we have to take into account that there could be a distinct presentation queue.
    var queueFamilyCount: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &queueFamilyCount, null);
    const queueFamilies = try allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
    defer allocator.free(queueFamilies);
    c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &queueFamilyCount, queueFamilies.ptr);

    for (queueFamilies, 0..) |family, i| {
        const idx = @as(u32, @intCast(i));

        // Check for Graphics support
        if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
            graphicsFamily = idx;
        }

        // Check for Surface/Presentation support
        var presentSupport: c.VkBool32 = c.VK_FALSE;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR.?(
            ctx.physicalDevice,
            idx,
            @ptrCast(ctx.surface.surface),
            &presentSupport,
        );
        if (presentSupport == c.VK_TRUE) {
            presentFamily = idx;
        }

        if (graphicsFamily != null and presentFamily != null) break;
    }

    const gQInd = graphicsFamily orelse return error.NoGraphicsQueue;
    const pQInd = presentFamily orelse return error.NoPresentQueue;
    var queueCreateInfos = try allocator.alloc(c.VkDeviceQueueCreateInfo, if (gQInd == pQInd) 1 else 2);

    const queuePriority = [_]f32{1.0};

    queueCreateInfos[0] = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = gQInd,
        .queueCount = 1,
        .pQueuePriorities = &queuePriority,
    };
    queueCount = 1;

    // NOTE: Only add the Present queue if it's a different family
    if (gQInd != pQInd) {
        queueCreateInfos[1] = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = pQInd,
            .queueCount = 1,
            .pQueuePriorities = &queuePriority,
        };
        queueCount = 2;
    }

    return QueueSetup{
        .infos = queueCreateInfos,
        .graphicsFamily = gQInd,
        .presentFamily = pQInd,
    };
}
