const c = @import("c.zig").namespace;
const context = @import("context.zig");
const vulkan = @import("vulkan.zig");

const wrapCall = context.wrapCall;

pub const namespace = struct {
    value: c.VmaAllocator,

    const Self = @This();

    pub fn init(
        physicalDevice: vulkan.PhysicalDevice,
        device: vulkan.Device,
        instance: vulkan.Instance,
        apiVersion: u32,
    ) !Self {
        // PLAN: revisit this
        const vmaAllocatorCreateInfo = c.VmaAllocatorCreateInfo{
            .physicalDevice = physicalDevice.value,
            .device = device.value,
            .vulkanApiVersion = apiVersion,
            .instance = instance.value,
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

        var vmaAllocator: Self = undefined;

        try wrapCall(
            c.vmaCreateAllocator(&vmaAllocatorCreateInfo, &vmaAllocator.value),
            error.VMA_CreateAllocator,
        );

        return vmaAllocator;
    }

    pub fn deinit(self: *Self) void {
        if (self.value != null) {
            c.vmaDestroyAllocator(self.value);
        }
    }
};
