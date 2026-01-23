const builtin = @import("builtin");
const std = @import("std");
const sdl3 = @import("sdl3");

const c = @import("c.zig").namespace;

const context = @import("context.zig");
const wrapCall = context.wrapCall;

const isMacos = builtin.target.os.tag == .macos;

// FIXME: move info comments into doc style comments

pub const Device = struct {
    value: c.VkDevice,

    const Self = @This();

    pub fn init(physicalDevice: PhysicalDevice, queueCreateInfos: []c.VkDeviceQueueCreateInfo) !Self {
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

        var device: Device = undefined;

        try wrapCall(
            c.vkCreateDevice.?(physicalDevice.value, &deviceCreateInfo, null, &device.value),
            error.Vulkan_CreateDevice,
        );

        return device;
    }

    pub fn waitIdle(self: Self) !void {
        _ = c.vkDeviceWaitIdle.?(self.value);
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroyDevice.?(self.value, null);
    }
};

pub const SwapChain = struct {
    value: c.VkSwapchainKHR,
    images: c.VkImage,
    format: c.VkSurfaceFormatKHR,
    extent: c.VkExtent2D,
    presentMode: u32,

    const Self = @This();

    pub fn init(
        physicalDevice: PhysicalDevice,
        device: Device,
        surface: sdl3.vulkan.Surface,
        allocator: std.mem.Allocator,
        window: sdl3.video.Window,
        queueDetails: context.QueueInfo,
    ) !Self {
        var surfaceCapabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try wrapCall(
            c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(
                physicalDevice.value,
                @ptrCast(surface.surface),
                &surfaceCapabilities,
            ),
            error.Vulkan_GetPhysicalDeviceSurfaceCapabilitiesKHR,
        );

        var swapChain: SwapChain = undefined;

        const surfaceFormat = try pickSurfaceFormat(physicalDevice, surface, allocator);
        const presentMode = try pickPresentMode(physicalDevice, surface, allocator);
        const surfaceExtent = try chooseExtent(window, surfaceCapabilities);

        swapChain.format = surfaceFormat;
        swapChain.presentMode = presentMode;
        swapChain.extent = surfaceExtent;

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
            .surface = @ptrCast(surface.surface),
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
            // swapChainCreateInfo.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

            swapChainCreateInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swapChainCreateInfo.queueFamilyIndexCount = 2;
            swapChainCreateInfo.pQueueFamilyIndices = &queueIndices;
        }

        try wrapCall(
            c.vkCreateSwapchainKHR.?(device.value, &swapChainCreateInfo, null, &swapChain.value),
            error.Vulkan_CreateSwapchainKHR,
        );

        return swapChain;
    }

    pub fn deinit(self: *Self, device: Device) void {
        if (self.value != null) {
            c.vkDestroySwapchainKHR.?(device.value, self.value, null);
        }
    }

    pub fn getSwapChainImages(self: *Self, device: Device, allocator: std.mem.Allocator) ![]c.VkImage {
        var count: i32 = 0;
        try wrapCall(c.vkGetSwapchainImagesKHR.?(
            device,
            self,
            &count,
            null,
        ), error.Vulkan_vkGetSwapchainImagesKHR);
        const swapChainImages: []c.VkImage = try allocator.alloc(
            c.VkPresentModeKHR,
            count,
        );

        try wrapCall(
            c.vkGetSwapchainImagesKHR.?(
                device,
                self,
                &count,
                swapChainImages.ptr,
            ),
            error.Vulkan_vkGetSwapchainImagesKHR,
        );

        return swapChainImages;
    }

    fn pickSurfaceFormat(physicalDevice: PhysicalDevice, surface: sdl3.vulkan.Surface, allocator: std.mem.Allocator) !c.VkSurfaceFormatKHR {
        var numFormats: u32 = undefined;
        try wrapCall(c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
            physicalDevice.value,
            @ptrCast(surface.surface),
            &numFormats,
            null,
        ), error.Vulkan_GetPhysicalDeviceSurfaceFormatsKHR);
        const surfaceFormats: []c.VkSurfaceFormatKHR = try allocator.alloc(
            c.VkSurfaceFormatKHR,
            numFormats,
        );
        try wrapCall(
            c.vkGetPhysicalDeviceSurfaceFormatsKHR.?(
                physicalDevice.value,
                @ptrCast(surface.surface),
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

    fn pickPresentMode(physicalDevice: PhysicalDevice, surface: sdl3.vulkan.Surface, allocator: std.mem.Allocator) !u32 {
        var numModes: u32 = undefined;
        try wrapCall(c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
            physicalDevice.value,
            @ptrCast(surface.surface),
            &numModes,
            null,
        ), error.Vulkan_GetPhysicalDeviceSurfacePresentModesKHR);
        const surfaceModes: []c.VkPresentModeKHR = try allocator.alloc(
            c.VkPresentModeKHR,
            numModes,
        );

        try wrapCall(
            c.vkGetPhysicalDeviceSurfacePresentModesKHR.?(
                physicalDevice.value,
                @ptrCast(surface.surface),
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

    fn chooseExtent(window: sdl3.video.Window, capabilities: c.VkSurfaceCapabilitiesKHR) !c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        }

        const sizeInPixel = try window.getSizeInPixels();

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
};

pub const PhysicalDevice = struct {
    value: c.VkPhysicalDevice,

    const Self = @This();

    pub fn init(instance: Instance, allocator: std.mem.Allocator) !Self {
        var physicalDeviceCount: u32 = undefined;

        try wrapCall(
            c.vkEnumeratePhysicalDevices.?(instance.value, &physicalDeviceCount, null),
            error.Vulkan_EnumeratePhysicalDevices,
        );

        if (physicalDeviceCount == 0) {
            return error.Vulkan_NoPhysicalDeviceFound;
        }

        const deviceArr = try allocator.alloc(c.VkPhysicalDevice, physicalDeviceCount);

        try wrapCall(
            c.vkEnumeratePhysicalDevices.?(instance.value, &physicalDeviceCount, deviceArr.ptr),
            error.Vulkan_EnumeratePhysicalDevices,
        );

        // NOTE: separating this logic to be able to bypass later if needed
        var physicalDevice: PhysicalDevice = undefined;
        physicalDevice.value = pickPhysicalDevice(deviceArr);
        return physicalDevice;
    }

    fn pickPhysicalDevice(deviceArr: []c.VkPhysicalDevice) c.VkPhysicalDevice {
        if (deviceArr.len == 1) {
            return deviceArr[0];
        }
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

        return deviceArr[maxDeviceInd];
    }
};

pub const Instance = struct {
    value: c.VkInstance,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, apiVersion: u32, enableValidation: bool) !Self {
        const requiredExtensions = try sdl3.vulkan.getInstanceExtensions();

        var extensions = try allocator.alloc([*:0]const u8, requiredExtensions.len + if (isMacos) @as(u32, 1) else 0);
        defer allocator.free(extensions);

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
            try wrapCall(
                c.vkEnumerateInstanceLayerProperties.?(&pPropertyCount, null),
                error.Vulkan_EnumerateInstanceLayerProperties,
            );
            const layers = try allocator.alloc(c.VkLayerProperties, pPropertyCount);
            defer allocator.free(layers);

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

        var instance: Instance = undefined;

        try wrapCall(
            c.vkCreateInstance.?(&createInfo, null, &instance.value),
            error.Vulkan_CreateInstance,
        );

        return instance;
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroyInstance.?(self.value, null);
    }
};
