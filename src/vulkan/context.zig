const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("volk.h");
    @cInclude("vk_mem_alloc.h");
});

const safeMode = build_options.vulkan_validation;
const isMacos = builtin.target.os.tag == .macos;

// FIXME: Remove all print statements

const QueueDetails = struct {
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
    vmaAllocator: c.VmaAllocator,
    surface: sdl3.vulkan.Surface,
    swapChain: c.VkSwapchainKHR,
    allocator: std.mem.Allocator,

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
        ctx.allocator = allocator;

        try initInstance(&ctx, apiVersion, safeMode);
        c.volkLoadInstanceOnly(ctx.instance);

        try initPhysicalDevice(&ctx);

        ctx.surface = try sdl3.vulkan.Surface.init(
            window,
            @ptrCast(ctx.instance),
            null,
        );

        const queueDetails = try getQueueDetails(&ctx);
        defer ctx.allocator.free(queueDetails.infos);

        try initDevice(&ctx, queueDetails.infos);
        c.volkLoadDevice(ctx.device);

        c.vkGetDeviceQueue.?(ctx.device, queueDetails.graphicsFamily, 0, &ctx.graphicsQueue);
        c.vkGetDeviceQueue.?(ctx.device, queueDetails.presentFamily, 0, &ctx.presentQueue);

        try initVmaAllocator(&ctx, apiVersion);

        try createSwapChain(&ctx, window, queueDetails);

        return ctx;
    }

    pub fn deinit(self: *Self) void {
        // FIXME: add validation to ensure device is not currently being used before calling destroy calls
        // TODO: check if vkAllocationCallback would need to be updated if using vulkan memory allocator
        _ = c.vkDeviceWaitIdle.?(self.device);

        if (self.swapChain != null) {
            c.vkDestroySwapchainKHR.?(self.device, self.swapChain, null);
        }

        if (self.vmaAllocator != null) {
            c.vmaDestroyAllocator(self.vmaAllocator);
        }

        c.vkDestroyDevice.?(self.device, null);
        sdl3.vulkan.Surface.deinit(self.surface);
        c.vkDestroyInstance.?(self.instance, null);
    }
};

fn initVmaAllocator(ctx: *VulkanCtx, apiVersion: u32) !void {
    // PLAN: revisit this
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

    try wrapCall(
        c.vmaCreateAllocator(&vmaAllocatorCreateInfo, &ctx.vmaAllocator),
        error.VMA_CreateAllocator,
    );
}

fn createSwapChain(ctx: *VulkanCtx, window: sdl3.video.Window, queueDetails: QueueDetails) !void {
    var surfaceCapabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    try wrapCall(
        c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(
            ctx.physicalDevice,
            @ptrCast(ctx.surface.surface),
            &surfaceCapabilities,
        ),
        error.Vulkan_GetPhysicalDeviceSurfaceCapabilitiesKHR,
    );

    std.debug.print("Surface capabilities - \n{any}\n", .{surfaceCapabilities});

    const surfaceFormat = try swapChainPickSurfaceFormat(ctx);
    const presentMode = try swapChainPickPresentMode(ctx);
    const surfaceExtent = try swapChainChooseExtent(window, surfaceCapabilities);

    std.debug.print("Surface Format - \n{any}\n", .{surfaceFormat});
    std.debug.print("Surface Mode - \n{any}\n", .{presentMode});
    std.debug.print("Extent {any}\n\n", .{surfaceExtent});

    // NOTE: minImageCount is generally 2, so this code essentially is `triple buferring`
    var minImageCount = @max(3, surfaceCapabilities.minImageCount);
    // NOTE: `surfaceCapabilities.maxImageCount = 0` indicates that there is no maximum
    if (surfaceCapabilities.maxImageCount > 0 and minImageCount > surfaceCapabilities.maxImageCount) {
        minImageCount = surfaceCapabilities.maxImageCount;
    }

    var imageCount = surfaceCapabilities.minImageCount + 1;
    if (surfaceCapabilities.maxImageCount > 0 and imageCount > surfaceCapabilities.maxImageCount) {
        imageCount = surfaceCapabilities.maxImageCount;
    }

    var swapChainCreateInfo = c.VkSwapchainCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .flags = 0,
        .surface = @ptrCast(ctx.surface.surface),
        .minImageCount = minImageCount,
        .imageFormat = surfaceFormat.format,
        .imageColorSpace = surfaceFormat.colorSpace,
        .imageExtent = surfaceExtent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = surfaceCapabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = presentMode,
        .clipped = c.VK_TRUE,
        // PLAN: This value will need revisiting once recreation of swap chain is touched upon
        .oldSwapchain = null,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    const queueIndices = [_]u32{ queueDetails.graphicsFamily, queueDetails.presentFamily };
    if (queueDetails.graphicsFamily != queueDetails.presentFamily) {
        // NOTE: A more performant way is to use exclusive mode and explicitly tranfer between queues
        // Although graphics and present queue families being different is rare case
        // Can validate if it is meaningful to create more performant flow
        swapChainCreateInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        swapChainCreateInfo.queueFamilyIndexCount = 2;
        swapChainCreateInfo.pQueueFamilyIndices = &queueIndices;
    }

    try wrapCall(
        c.vkCreateSwapchainKHR.?(ctx.device, &swapChainCreateInfo, null, &ctx.swapChain),
        error.Vulkan_CreateSwapchainKHR,
    );
}

fn swapChainChooseExtent(window: sdl3.video.Window, capabilities: c.VkSurfaceCapabilitiesKHR) !c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }
    const sizeInPixel = try window.getSizeInPixels();

    // BUG: Why not printing this???
    std.debug.print("Size in pixel - \n{any}\n", .{sizeInPixel});

    return c.VkExtent2D{
        .width = std.math.clamp(
            @as(u32, @intCast(sizeInPixel.@"0")),
            capabilities.minImageExtent.width,
            capabilities.maxImageExtent.width,
        ),
        .height = std.math.clamp(
            @as(u32, @intCast(sizeInPixel.@"1")),
            capabilities.minImageExtent.height,
            capabilities.maxImageExtent.height,
        ),
    };
}

fn swapChainPickPresentMode(ctx: *const VulkanCtx) !u32 {
    var numModes: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
        ctx.physicalDevice,
        @ptrCast(ctx.surface.surface),
        &numModes,
        null,
    );
    const surfaceModes: []c.VkPresentModeKHR = try ctx.allocator.alloc(
        c.VkPresentModeKHR,
        numModes,
    );

    try wrapCall(
        c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
            ctx.physicalDevice,
            @ptrCast(ctx.surface.surface),
            &numModes,
            surfaceModes.ptr,
        ),
        error.Vulkan_GetPhysicalDeviceSurfacePresentModesKHR,
    );

    for (surfaceModes) |mode| {
        // NOTE: on mobile devices fifo mode might be the best suited
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }

    std.debug.print("Desired mode not present, falling back to fifo mode\n", .{});

    return c.VK_PRESENT_MODE_FIFO_KHR;
}

// FIXME: under swapchain namespace
fn swapChainPickSurfaceFormat(ctx: *const VulkanCtx) !c.VkSurfaceFormatKHR {
    var numFormats: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
        ctx.physicalDevice,
        @ptrCast(ctx.surface.surface),
        &numFormats,
        null,
    );
    const surfaceFormats: []c.VkSurfaceFormatKHR = try ctx.allocator.alloc(
        c.VkSurfaceFormatKHR,
        numFormats,
    );
    try wrapCall(
        c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
            ctx.physicalDevice,
            @ptrCast(ctx.surface.surface),
            &numFormats,
            surfaceFormats.ptr,
        ),
        error.Vulkan_GetPhysicalDeviceSurfaceFormatsKHR,
    );

    for (surfaceFormats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return format;
        }
    }

    std.debug.print("Desired format not present, select first available format", .{});

    return surfaceFormats[0];
}

fn initInstance(ctx: *VulkanCtx, apiVersion: u32, enableValidation: bool) !void {
    const requiredExtensions = try sdl3.vulkan.getInstanceExtensions();

    var extensions = try ctx.allocator.alloc([*:0]const u8, requiredExtensions.len + if (isMacos) @as(u32, 1) else 0);
    defer ctx.allocator.free(extensions);

    @memcpy(extensions[0..requiredExtensions.len], requiredExtensions);

    if (isMacos) {
        extensions[requiredExtensions.len] = c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    }

    var createInfo = c.VkInstanceCreateInfo{
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
        const layers = try ctx.allocator.alloc(c.VkLayerProperties, pPropertyCount);
        defer ctx.allocator.free(layers);

        try wrapCall(
            c.vkEnumerateInstanceLayerProperties.?(&pPropertyCount, layers.ptr),
            error.Vulkan_EnumerateInstanceLayerProperties,
        );

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

    try wrapCall(
        c.vkCreateInstance.?(&createInfo, null, &ctx.instance),
        error.Vulkan_CreateInstance,
    );
}

// FIXME: Move to device namespace
fn initPhysicalDevice(ctx: *VulkanCtx) !void {
    var physicalDeviceCount: u32 = undefined;

    _ = c.vkEnumeratePhysicalDevices.?(ctx.instance, &physicalDeviceCount, null);

    const deviceArr = try ctx.allocator.alloc(c.VkPhysicalDevice, physicalDeviceCount);

    // FIXME: Move this function style everywhere to standard library style functions
    try wrapCall(
        c.vkEnumeratePhysicalDevices.?(ctx.instance, &physicalDeviceCount, deviceArr.ptr),
        error.Vulkan_EnumeratePhysicalDevices,
    );

    if (physicalDeviceCount == 0) {
        // TODO: No point in continuing might as well just panic but just throwing error here
        return error.Vulkan_NoPhysicalDeviceFound;
    }

    if (physicalDeviceCount == 1) {
        ctx.physicalDevice = deviceArr[0];
        return;
    }

    // NOTE: separating this logic to be able to bypass later if needed
    pickPhysicalDevice(ctx, deviceArr);
}

fn pickPhysicalDevice(ctx: *VulkanCtx, deviceArr: []c.VkPhysicalDevice) void {
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

fn initDevice(ctx: *VulkanCtx, queueCreateInfos: []c.VkDeviceQueueCreateInfo) !void {
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
        .queueCreateInfoCount = @intCast(queueCreateInfos.len),
        .pQueueCreateInfos = queueCreateInfos.ptr,
        // NOTE: This should be null if passing vkPhysicalDeviceFeatures2 in pNext
        // .pEnabledFeatures = &c.VkPhysicalDeviceFeatures{},
    };

    try wrapCall(
        c.vkCreateDevice.?(ctx.physicalDevice, &deviceCreateInfo, null, &ctx.device),
        error.Vulkan_CreateDevice,
    );
}

// FIXME: Move to queue namespace
// TODO: Check if using this style of pointer can have wanted cost
fn getQueueDetails(ctx: *const VulkanCtx) !QueueDetails {
    var queueCount: u32 = 0;
    var graphicsFamily: ?u32 = null;
    var presentFamily: ?u32 = null;

    // NOTE:
    // https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Window_surface.html#_querying_for_presentation_support
    // It’s actually possible that the queue families supporting drawing commands and the queue families supporting
    // presentation do not overlap. Therefore, we have to take into account that there could be a distinct presentation queue.
    var queueFamilyCount: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice, &queueFamilyCount, null);
    const queueFamilies = try ctx.allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
    defer ctx.allocator.free(queueFamilies);
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
    var queueCreateInfos = try ctx.allocator.alloc(c.VkDeviceQueueCreateInfo, if (gQInd == pQInd) 1 else 2);

    const queuePriority = [_]f32{0.5};

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

    return QueueDetails{
        .infos = queueCreateInfos,
        .graphicsFamily = gQInd,
        .presentFamily = pQInd,
    };
}

// PLAN: Move this to util namespace
fn wrapCall(result: c.VkResult, errorName: anyerror) !void {
    if (result != c.VK_SUCCESS) {
        return errorName;
    }
}
