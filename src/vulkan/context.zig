const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");
const build_options = @import("build_options");

const c = @import("c.zig").namespace;
const vulkan = @import("vulkan.zig");
const VMA = @import("vma.zig").namespace;

const safeMode = build_options.vulkan_validation;
const isMacos = builtin.target.os.tag == .macos;

pub fn wrapCall(result: c.VkResult, errorName: anyerror) !void {
    if (result != c.VK_SUCCESS) {
        return errorName;
    }
}

pub const QueueInfo = struct {
    infos: []c.VkDeviceQueueCreateInfo,
    graphicsFamily: u32,
    presentFamily: u32,

    const Self = @This();

    // TODO: Check if using this style of pointer can have wanted cost
    fn init(ctx: *const VulkanCtx) !QueueInfo {
        var queueCount: u32 = 0;
        var graphicsFamily: ?u32 = null;
        var presentFamily: ?u32 = null;

        // NOTE:
        // https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Window_surface.html#_querying_for_presentation_support
        // It’s actually possible that the queue families supporting drawing commands and the queue families supporting
        // presentation do not overlap. Therefore, we have to take into account that there could be a distinct presentation queue.
        var queueFamilyCount: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice.value, &queueFamilyCount, null);
        const queueFamilies = try ctx.allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
        defer ctx.allocator.free(queueFamilies);
        c.vkGetPhysicalDeviceQueueFamilyProperties.?(ctx.physicalDevice.value, &queueFamilyCount, queueFamilies.ptr);

        for (queueFamilies, 0..) |family, i| {
            const idx = @as(u32, @intCast(i));

            // Check for Graphics support
            if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                graphicsFamily = idx;
            }

            // Check for Surface/Presentation support
            var presentSupport: c.VkBool32 = c.VK_FALSE;
            try wrapCall(c.vkGetPhysicalDeviceSurfaceSupportKHR.?(
                ctx.physicalDevice.value,
                idx,
                @ptrCast(ctx.surface.surface),
                &presentSupport,
            ), error.Vulkan_GetPhysicalDeviceSurfaceSupportKHR);
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

        return QueueInfo{
            .infos = queueCreateInfos,
            .graphicsFamily = gQInd,
            .presentFamily = pQInd,
        };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        defer allocator.free(self.infos);
    }
};

pub const VulkanCtx = struct {
    graphicsQueue: c.VkQueue,
    presentQueue: c.VkQueue,

    vmaAllocator: VMA,
    surface: sdl3.vulkan.Surface,
    allocator: std.mem.Allocator,
    instance: vulkan.Instance,
    physicalDevice: vulkan.PhysicalDevice,
    device: vulkan.Device,
    swapChain: vulkan.SwapChain,
    window: sdl3.video.Window,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, window: sdl3.video.Window, apiVersion: u32) !VulkanCtx {
        sdl3.vulkan.loadLibrary(null) catch {
            return error.SDL_Vulkan_LoadLibrary;
        };

        const procAddrFnPtr = sdl3.vulkan.getVkGetInstanceProcAddr() catch {
            return error.SDL_Vulkan_GetVkGetInstanceProcAddr;
        };

        c.volkInitializeCustom(@as(c.PFN_vkGetInstanceProcAddr, @ptrCast(@alignCast(procAddrFnPtr))));

        var self: VulkanCtx = undefined;
        self.allocator = allocator;
        self.window = window;

        self.instance = try vulkan.Instance.init(self.allocator, apiVersion, safeMode);
        c.volkLoadInstanceOnly(self.instance.value);

        self.physicalDevice = try vulkan.PhysicalDevice.init(self.instance, self.allocator);

        self.surface = try sdl3.vulkan.Surface.init(window, @ptrCast(self.instance.value), null);

        var queueInfo = try QueueInfo.init(&self);
        defer queueInfo.deinit(self.allocator);

        self.device = try vulkan.Device.init(self.physicalDevice, queueInfo.infos);
        c.volkLoadDevice(self.device.value);

        c.vkGetDeviceQueue.?(self.device.value, queueInfo.graphicsFamily, 0, &self.graphicsQueue);
        c.vkGetDeviceQueue.?(self.device.value, queueInfo.presentFamily, 0, &self.presentQueue);

        self.vmaAllocator = try VMA.init(self.physicalDevice, self.device, self.instance, apiVersion);

        self.swapChain = try vulkan.SwapChain.init(
            self.physicalDevice,
            self.device,
            self.surface,
            self.allocator,
            self.window,
            queueInfo,
        );

        return self;
    }

    pub fn deinit(self: *Self) void {
        // TODO: check if vkAllocationCallback would need to be updated if using vulkan memory allocator

        try self.device.waitIdle();

        self.swapChain.deinit(self.device);

        self.vmaAllocator.deinit();

        self.device.deinit();

        sdl3.vulkan.Surface.deinit(self.surface);

        self.instance.deinit();
    }
};
