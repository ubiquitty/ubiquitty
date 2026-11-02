// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/VulkanRenderer.cpp — see VulkanRenderer.h.

#include "Platform/Linux/VulkanRenderer.h"
#include "Core/Rendering/OverlaySpanGather.h"
#include "PAL/Log.h"
#include "PAL/PAL.h"

#include "Platform/Linux/VulkanMemory.h"
#include <span>

#include "Core/Preferences/RenderStyle.h"
#include "Core/Rendering/CellInstanceBuilder.h"
#include "Core/Rendering/FrameDamage.h"
#include "Core/Rendering/OverlayBatching.h"
#include "Core/Screen/Addressing.h"
#include "Core/Screen/ScrollSearch.h"
#include "Platform/Linux/FontRouting.h"
#include "Platform/Linux/Raster.h"

#include "Core/Image/ImagePlacement.h"
#include "Core/Image/TerminalImage.h"
#include "Core/Kitty/UnicodePlaceholders.h"
#include "Core/Rendering/BackgroundImage.h"
#include "Core/TermPalette.h"
#include "Core/TerminalOperations.h"

#include <algorithm>
#include <array>
#include <cmath>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

namespace Ubiquitty::Linux {

namespace {
constexpr VkFormat imageFormat = VK_FORMAT_R8G8B8A8_UNORM; // matches GDK_MEMORY_R8G8B8A8

bool canMapExportedFrame(int fileDescriptor, std::size_t length)
{
    // GTK accepts a dma-buf's format before its software importer maps it.
    // A mapping refusal there cannot be reported back to this renderer.
    void* mapping = ::mmap(nullptr, length, PROT_READ, MAP_SHARED, fileDescriptor, 0);
    if (mapping == MAP_FAILED)
        return false;
    return ::munmap(mapping, length) == 0;
}

// The directory the executable lives in — the SPIR-V shaders are written
// next to the binary by the build (build/linux/cell.*.spv etc.).
std::string executableDirectory()
{
    char path[4096];
    const ssize_t length = ::readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (length <= 0)
        return ".";
    path[length] = '\0';
    std::string full(path);
    const std::size_t slash = full.find_last_of('/');
    return slash == std::string::npos ? std::string(".") : full.substr(0, slash);
}

} // namespace

std::string VulkanRenderer::diagnoseFontRoutes(std::string_view utf8Text) const { return Ubiquitty::Linux::diagnoseFontRoutes(utf8Text, "vulkan"); }

bool VulkanRenderer::init()
{
    VkApplicationInfo app {};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "ubiquitty-linux";
    app.apiVersion = VK_API_VERSION_1_1;

    VkInstanceCreateInfo ici {};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    if (vkCreateInstance(&ici, nullptr, &m_instance) != VK_SUCCESS)
        return false;

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(m_instance, &count, nullptr);
    if (count == 0)
        return false;
    std::vector<VkPhysicalDevice> devices(count);
    vkEnumeratePhysicalDevices(m_instance, &count, devices.data());

    bool picked = false;
    for (VkPhysicalDevice dev : devices) {
        uint32_t qcount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &qcount, nullptr);
        std::vector<VkQueueFamilyProperties> props(qcount);
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &qcount, props.data());
        for (uint32_t i = 0; i < qcount; ++i) {
            // Offscreen only: a graphics queue is all we need — never query present.
            if (props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                m_physical = dev;
                m_queueFamily = i;
                picked = true;
                break;
            }
        }
        if (picked)
            break;
    }
    if (!picked)
        return false;
    VkPhysicalDeviceProperties physicalProperties {};
    vkGetPhysicalDeviceProperties(m_physical, &physicalProperties);
    const VkPhysicalDeviceLimits& limits = physicalProperties.limits;
    m_maxTargetExtent = maxRenderTargetExtent(limits.maxImageDimension2D, limits.maxFramebufferWidth,
        limits.maxFramebufferHeight, limits.maxViewportDimensions[0], limits.maxViewportDimensions[1]);

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci {};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = m_queueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;

    // dma-buf export is enabled when the device offers it; without it frames
    // read back through the staging buffer, which every device can do.
    uint32_t extensionCount = 0;
    vkEnumerateDeviceExtensionProperties(m_physical, nullptr, &extensionCount, nullptr);
    std::vector<VkExtensionProperties> extensions(extensionCount);
    vkEnumerateDeviceExtensionProperties(m_physical, nullptr, &extensionCount, extensions.data());
    const auto hasExtension = [&](const char* name) {
        return std::ranges::any_of(extensions, [name](const VkExtensionProperties& extension) { return std::string_view(extension.extensionName) == name; });
    };
    const std::array<const char*, 2> exportExtensions { VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME };
    const bool canExport = std::ranges::all_of(exportExtensions, hasExtension);

    VkDeviceCreateInfo dci {};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    if (canExport) {
        dci.enabledExtensionCount = static_cast<uint32_t>(exportExtensions.size());
        dci.ppEnabledExtensionNames = exportExtensions.data();
    }
    if (vkCreateDevice(m_physical, &dci, nullptr, &m_device) != VK_SUCCESS)
        return false;
    if (canExport) {
        m_getMemoryFileDescriptor = reinterpret_cast<PFN_vkGetMemoryFdKHR>(vkGetDeviceProcAddr(m_device, "vkGetMemoryFdKHR"));
        m_canExportFrames = m_getMemoryFileDescriptor != nullptr && !std::getenv("UBIQUITTY_LINUX_NO_DMABUF");
    }
    PAL::logLine(stderr, "ubiquitty-linux: dma-buf presentation {}", m_canExportFrames ? "on" : (canExport ? "off (UBIQUITTY_LINUX_NO_DMABUF)" : "unavailable (no external-memory extensions)"));
    vkGetDeviceQueue(m_device, m_queueFamily, 0, &m_queue);

    VkCommandPoolCreateInfo pci {};
    pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = m_queueFamily;
    if (vkCreateCommandPool(m_device, &pci, nullptr, &m_commandPool) != VK_SUCCESS)
        return false;

    VkCommandBufferAllocateInfo cbai {};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = m_commandPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(m_device, &cbai, &m_commandBuffer) != VK_SUCCESS)
        return false;

    return true;
}

uint32_t VulkanRenderer::findMemoryType(uint32_t typeBits, VkMemoryPropertyFlags want) const
{
    return findVulkanMemoryType(m_physical, typeBits, want);
}

void VulkanRenderer::destroyExportSlots()
{
    // A texture GTK still holds keeps its own dup of the descriptor, and so
    // the kernel buffer; the slot's Vulkan objects and its descriptor go.
    // Bumping the generation voids every outstanding release token.
    m_exportGeneration.fetch_add(1, std::memory_order_acq_rel);
    for (std::size_t index = 0; index < exportSlotCount; ++index) {
        ExportSlot& slot = m_exportSlots[index];
        if (slot.fileDescriptor >= 0)
            ::close(slot.fileDescriptor);
        if (slot.image)
            vkDestroyImage(m_device, slot.image, nullptr);
        if (slot.memory)
            vkFreeMemory(m_device, slot.memory, nullptr);
        slot = {};
        m_isExportSlotHeld[index].store(false, std::memory_order_release);
    }
    m_exportWidth = m_exportHeight = 0;
}

bool VulkanRenderer::ensureExportSlots(uint32_t width, uint32_t height)
{
    // A device that offers the extensions can still refuse a linear,
    // exportable image of this format; that is said once and the export is
    // switched off, so frames read back rather than retrying every frame.
    const auto refuseExport = [this](const char* step) {
        PAL::logLine(stderr, "ubiquitty-linux: dma-buf presentation off: the export image could not be built ({})", step);
        destroyExportSlots();
        m_canExportFrames = false;
        return false;
    };
    if (width == m_exportWidth && height == m_exportHeight && m_exportSlots[0].image)
        return true;
    destroyExportSlots();
    for (ExportSlot& slot : m_exportSlots) {
        VkExternalMemoryImageCreateInfo external {};
        external.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
        external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        VkImageCreateInfo ic {};
        ic.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ic.pNext = &external;
        ic.imageType = VK_IMAGE_TYPE_2D;
        ic.format = imageFormat;
        ic.extent = { width, height, 1 };
        ic.mipLevels = 1;
        ic.arrayLayers = 1;
        ic.samples = VK_SAMPLE_COUNT_1_BIT;
        // Linear, so the compositor and GTK import it with the one modifier
        // every importer understands.
        ic.tiling = VK_IMAGE_TILING_LINEAR;
        ic.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        ic.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        ic.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (vkCreateImage(m_device, &ic, nullptr, &slot.image) != VK_SUCCESS)
            return refuseExport("step 1");
        VkMemoryRequirements req {};
        vkGetImageMemoryRequirements(m_device, slot.image, &req);
        VkExportMemoryAllocateInfo exportInfo {};
        exportInfo.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
        exportInfo.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        VkMemoryDedicatedAllocateInfo dedicated {};
        dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
        dedicated.pNext = &exportInfo;
        dedicated.image = slot.image;
        VkMemoryAllocateInfo mai {};
        mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.pNext = &dedicated;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (mai.memoryTypeIndex == UINT32_MAX)
            mai.memoryTypeIndex = findMemoryType(req.memoryTypeBits, 0);
        if (mai.memoryTypeIndex == UINT32_MAX)
            return refuseExport("step 2");
        if (vkAllocateMemory(m_device, &mai, nullptr, &slot.memory) != VK_SUCCESS)
            return refuseExport("step 3");
        if (vkBindImageMemory(m_device, slot.image, slot.memory, 0) != VK_SUCCESS)
            return refuseExport("step 4");
        VkMemoryGetFdInfoKHR descriptorInfo {};
        descriptorInfo.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
        descriptorInfo.memory = slot.memory;
        descriptorInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        if (m_getMemoryFileDescriptor(m_device, &descriptorInfo, &slot.fileDescriptor) != VK_SUCCESS)
            return refuseExport("step 5");
        if (!std::in_range<std::size_t>(req.size))
            return refuseExport("import mapping size");
        const auto allocationSize = static_cast<std::size_t>(req.size);
        const bool canImport = m_canImportFrame
            ? m_canImportFrame(m_frameImportContext, slot.fileDescriptor, allocationSize)
            : canMapExportedFrame(slot.fileDescriptor, allocationSize);
        if (!canImport)
            return refuseExport("import mapping refused");
        VkImageSubresource subresource {};
        subresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        VkSubresourceLayout layout {};
        vkGetImageSubresourceLayout(m_device, slot.image, &subresource, &layout);
        slot.stride = static_cast<uint32_t>(layout.rowPitch);
        slot.offset = static_cast<uint32_t>(layout.offset);
    }
    m_exportWidth = width;
    m_exportHeight = height;
    return true;
}

void VulkanRenderer::releaseExportedFrame(uint64_t token)
{
    const auto generation = static_cast<uint32_t>(token >> 32);
    const auto index = static_cast<std::size_t>(token & 0xFFFFFFFFu);
    if (index >= exportSlotCount || generation != m_exportGeneration.load(std::memory_order_acquire))
        return;
    m_isExportSlotHeld[index].store(false, std::memory_order_release);
}

void VulkanRenderer::destroyTarget()
{
    destroyExportSlots();
    if (m_stagingMapped) {
        vkUnmapMemory(m_device, m_stagingMemory);
        m_stagingMapped = nullptr;
    }
    if (m_staging) {
        vkDestroyBuffer(m_device, m_staging, nullptr);
        m_staging = VK_NULL_HANDLE;
    }
    if (m_stagingMemory) {
        vkFreeMemory(m_device, m_stagingMemory, nullptr);
        m_stagingMemory = VK_NULL_HANDLE;
    }
    if (m_image) {
        vkDestroyImage(m_device, m_image, nullptr);
        m_image = VK_NULL_HANDLE;
    }
    if (m_imageMemory) {
        vkFreeMemory(m_device, m_imageMemory, nullptr);
        m_imageMemory = VK_NULL_HANDLE;
    }
    m_width = m_height = 0;
}

bool VulkanRenderer::ensureTarget(uint32_t width, uint32_t height)
{
    if (width == m_width && height == m_height && m_image)
        return true;
    // Refused before the old target goes: past the device's limits the image
    // is invalid usage, not a failure the driver must report.
    if (!m_maxTargetExtent.contains(width, height))
        return false;
    destroyTarget();
    // The grid framebuffer holds a view of m_image; recreating the image
    // dangles it, so drop the grid target too (rebuilt on the next renderGrid).
    // The retained pair sizes with the same target, so a resize drops it with
    // everything else rather than leaving two images at the old extent.
    destroyGridTarget();
    destroyRetainedGridImages();

    VkImageCreateInfo ic {};
    ic.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ic.imageType = VK_IMAGE_TYPE_2D;
    ic.format = imageFormat;
    ic.extent = { width, height, 1 };
    ic.mipLevels = 1;
    ic.arrayLayers = 1;
    ic.samples = VK_SAMPLE_COUNT_1_BIT;
    ic.tiling = VK_IMAGE_TILING_OPTIMAL;
    ic.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    ic.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ic.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(m_device, &ic, nullptr, &m_image) != VK_SUCCESS)
        return false;

    VkMemoryRequirements req {};
    vkGetImageMemoryRequirements(m_device, m_image, &req);
    VkMemoryAllocateInfo mai {};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(m_device, &mai, nullptr, &m_imageMemory) != VK_SUCCESS)
        return false;
    if (vkBindImageMemory(m_device, m_image, m_imageMemory, 0) != VK_SUCCESS)
        return false;

    m_stagingSize = VkDeviceSize(width) * height * 4;
    VkBufferCreateInfo bc {};
    bc.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bc.size = m_stagingSize;
    bc.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(m_device, &bc, nullptr, &m_staging) != VK_SUCCESS)
        return false;
    VkMemoryRequirements breq {};
    vkGetBufferMemoryRequirements(m_device, m_staging, &breq);
    VkMemoryAllocateInfo bmai {};
    bmai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bmai.allocationSize = breq.size;
    // This buffer exists to be READ by the host: the frame is copied out of it
    // every repaint. A coherent-but-uncached type is write-combined on discrete
    // GPUs, where a full-frame read runs about an order of magnitude slower
    // than from normal memory, so a cached type is preferred and the coherent
    // one is the fallback rather than the choice.
    VkPhysicalDeviceMemoryProperties memoryProperties {};
    vkGetPhysicalDeviceMemoryProperties(m_physical, &memoryProperties);
    std::vector<VkMemoryPropertyFlags> typeFlags(memoryProperties.memoryTypeCount);
    for (std::uint32_t index = 0; index < memoryProperties.memoryTypeCount; ++index)
        typeFlags[index] = memoryProperties.memoryTypes[index].propertyFlags;
    const ReadbackMemoryChoice staging = chooseReadbackMemoryType(typeFlags, breq.memoryTypeBits);
    bmai.memoryTypeIndex = staging.typeIndex;
    m_isStagingCoherent = staging.isCoherent;
    if (bmai.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(m_device, &bmai, nullptr, &m_stagingMemory) != VK_SUCCESS)
        return false;
    if (vkBindBufferMemory(m_device, m_staging, m_stagingMemory, 0) != VK_SUCCESS)
        return false;
    // Keep the host mapping for the target's lifetime: remapping every frame
    // faults the GPU allocation back into the process's page tables.
    if (vkMapMemory(m_device, m_stagingMemory, 0, VK_WHOLE_SIZE, 0, &m_stagingMapped) != VK_SUCCESS)
        return false;

    m_width = width;
    m_height = height;
    return true;
}

bool VulkanRenderer::renderClear(uint32_t width, uint32_t height, float r, float g, float b, std::vector<uint8_t>& out)
{
    if (width == 0 || height == 0)
        return false;
    if (!ensureTarget(width, height))
        return false;

    if (vkResetCommandBuffer(m_commandBuffer, 0) != VK_SUCCESS)
        return false;
    VkCommandBufferBeginInfo bi {};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(m_commandBuffer, &bi) != VK_SUCCESS)
        return false;

    VkImageSubresourceRange range {};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    auto barrier = [&](VkImageLayout from, VkImageLayout to, VkAccessFlags srcA, VkAccessFlags dstA, VkPipelineStageFlags srcS, VkPipelineStageFlags dstS) {
        VkImageMemoryBarrier mb {};
        mb.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        mb.oldLayout = from;
        mb.newLayout = to;
        mb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        mb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        mb.image = m_image;
        mb.subresourceRange = range;
        mb.srcAccessMask = srcA;
        mb.dstAccessMask = dstA;
        vkCmdPipelineBarrier(m_commandBuffer, srcS, dstS, 0, 0, nullptr, 0, nullptr, 1, &mb);
    };

    barrier(VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);

    VkClearColorValue clear {};
    clear.float32[0] = r;
    clear.float32[1] = g;
    clear.float32[2] = b;
    clear.float32[3] = 1.0f;
    vkCmdClearColorImage(m_commandBuffer, m_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);

    barrier(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);

    VkBufferImageCopy region {};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = { width, height, 1 };
    vkCmdCopyImageToBuffer(m_commandBuffer, m_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, m_staging, 1, &region);

    if (vkEndCommandBuffer(m_commandBuffer) != VK_SUCCESS)
        return false;

    VkSubmitInfo si {};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &m_commandBuffer;
    if (vkQueueSubmit(m_queue, 1, &si, VK_NULL_HANDLE) != VK_SUCCESS)
        return false;
    vkQueueWaitIdle(m_queue);

    return readTarget(out);
}

bool VulkanRenderer::readTarget(std::vector<uint8_t>& out)
{
    if (!m_stagingMapped)
        return false;
    // Completion precedes this read. A cached, non-coherent heap additionally
    // needs invalidation; both the clear and the grid take this same path.
    if (!m_isStagingCoherent) {
        VkMappedMemoryRange range {};
        range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = m_stagingMemory;
        range.offset = 0;
        range.size = VK_WHOLE_SIZE;
        if (vkInvalidateMappedMemoryRanges(m_device, 1, &range) != VK_SUCCESS)
            return false;
    }
    const auto* pixels = static_cast<const std::uint8_t*>(m_stagingMapped);
    out.assign(pixels, pixels + static_cast<std::size_t>(m_stagingSize));
    return true;
}

void VulkanRenderer::shutdown()
{
    if (m_device) {
        destroyInstanceBuffers();
        destroyImageInstanceBuffer();
        if (m_imageTexturesCreated) {
            m_imageTextures.destroy(m_device);
            m_imageTexturesCreated = false;
        }
        destroyBackdropPipeline();
        destroyOverlayPipeline();
        destroyImagePipeline();
        destroyGridTarget();
        destroyRetainedGridImages();
        destroyGridPipelines();
        m_proportionalImage.destroy(m_device);
        m_proportionalStripImage.destroy(m_device);
        m_ligatureImage.destroy(m_device);
        if (m_colorAtlas)
            m_colorAtlas->destroy(m_device);
        if (m_atlas)
            m_atlas->destroy(m_device);
        m_atlasCreated = false;
        m_proportionalSheet.reset();
        m_proportionalStripSheet.reset();
        m_ligatureSheet.reset();
        m_colorAtlas.reset();
        m_atlas.reset();
        destroyTarget();
        if (m_commandPool)
            vkDestroyCommandPool(m_device, m_commandPool, nullptr);
        vkDestroyDevice(m_device, nullptr);
        m_device = VK_NULL_HANDLE;
    }
    if (m_instance) {
        vkDestroyInstance(m_instance, nullptr);
        m_instance = VK_NULL_HANDLE;
    }
}

void VulkanRenderer::rebuildAtlas()
{
    // Tear the GPU atlas down so the next renderGrid re-creates it from the
    // currently-injected rasterizer — used after a runtime font swap. The cell
    // dims (m_cellWidth/Height) + the render-target size are re-derived then,
    // and the descriptor re-binds to the new atlas's sampler/view. Wait for any
    // in-flight frame first: the atlas image is bound in the descriptor set the
    // last renderGrid used.
    if (m_device == VK_NULL_HANDLE)
        return;
    vkDeviceWaitIdle(m_device);
    m_proportionalImage.destroy(m_device);
    m_proportionalStripImage.destroy(m_device);
    m_ligatureImage.destroy(m_device);
    if (m_colorAtlas)
        m_colorAtlas->destroy(m_device);
    if (m_atlas)
        m_atlas->destroy(m_device);
    m_atlasCreated = false;
    m_proportionalSheet.reset();
    m_proportionalStripSheet.reset();
    m_ligatureSheet.reset();
    m_colorAtlas.reset();
    m_atlas.reset();
    m_descriptorWritten = false;
    m_isProportionalDescriptorWritten = false;
    m_isProportionalStripDescriptorWritten = false;
    m_isLigatureDescriptorWritten = false;
    m_lastFrameGlyphInstances = 0;
    m_lastFrameProportionalInstances = 0;
    m_lastFrameProportionalStripInstances = 0;
    m_lastFrameLigatureInstances = 0;
    // The retained grid target holds glyphs drawn from the atlas being torn
    // down; a partial frame would keep them under every clean row. Cleared so
    // the next frame rebuilds the target in full from the new atlas.
    m_hasRetainedTarget = false;
}

VkShaderModule VulkanRenderer::loadShader(const char* spvFileName) const
{
    const std::string path = executableDirectory() + "/" + spvFileName;
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file)
        return VK_NULL_HANDLE;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (size <= 0 || (size % 4) != 0) {
        std::fclose(file);
        return VK_NULL_HANDLE;
    }
    std::vector<uint32_t> code(static_cast<std::size_t>(size) / 4);
    const std::size_t read = std::fread(code.data(), 1, static_cast<std::size_t>(size), file);
    std::fclose(file);
    if (read != static_cast<std::size_t>(size))
        return VK_NULL_HANDLE;

    VkShaderModuleCreateInfo info {};
    info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = static_cast<std::size_t>(size);
    info.pCode = code.data();
    VkShaderModule module = VK_NULL_HANDLE;
    if (vkCreateShaderModule(m_device, &info, nullptr, &module) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return module;
}

bool VulkanRenderer::ensureGridPipelines()
{
    if (m_cellPipeline != VK_NULL_HANDLE)
        return true;

    // One color attachment: R8G8B8A8_UNORM, CLEAR -> STORE, ending in
    // TRANSFER_SRC so the copy-to-host reads it directly.
    VkAttachmentDescription color {};
    color.format = imageFormat;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

    VkAttachmentReference colorRef {};
    colorRef.attachment = 0;
    colorRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass {};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colorRef;

    // External -> subpass: wait for the prior atlas upload (it transitioned the
    // atlas to SHADER_READ); subpass -> external: make the store visible to the
    // transfer read that copies the image to the staging buffer.
    VkSubpassDependency deps[2] {};
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    VkRenderPassCreateInfo rpInfo {};
    rpInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpInfo.attachmentCount = 1;
    rpInfo.pAttachments = &color;
    rpInfo.subpassCount = 1;
    rpInfo.pSubpasses = &subpass;
    rpInfo.dependencyCount = 2;
    rpInfo.pDependencies = deps;
    if (vkCreateRenderPass(m_device, &rpInfo, nullptr, &m_renderPass) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkCreateRenderPass failed building the grid pipelines");
        return false;
    }

    // The LOAD twin: a partial frame keeps the retained image's pixels and
    // repaints only the dirty rows over them. Load ops play no part in
    // render-pass compatibility, so the grid pipelines built against
    // m_renderPass bind under this pass unchanged. The attachment enters in
    // TRANSFER_SRC — where every grid pass leaves its image and where the
    // scroll band copy returns it — and leaves there again for the
    // full-image copy to the composited target.
    color.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    color.initialLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    if (vkCreateRenderPass(m_device, &rpInfo, nullptr, &m_gridLoadRenderPass) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkCreateRenderPass failed building the load grid pass");
        return false;
    }

    // One descriptor: binding 0 = combined image sampler (the atlas).
    // Binding 0 is the mono coverage sheet, binding 1 the colour one. Both are
    // in every set rather than in two layouts: the colour pass draws in the same
    // render pass with the same push constants, so a second layout would buy a
    // second pipeline layout and a second set to keep in step with the first.
    //
    // Binding 1 is filled even when no colour face is installed. A descriptor a
    // shader could sample must point at a real image — an unwritten one is
    // undefined behaviour rather than a quiet no-op — so the colour atlas hands
    // over a one-pixel sheet in that case and the absence of colour is carried
    // by `hasColorSource`, never by an empty binding.
    // Binding 2 is the proportional fallback strip, binding 3 the ligature
    // strip, and binding 4 the dedicated proportional sheet, which the rule
    // pass taps under a run drawn glyph by glyph. All start on mono until
    // their resources exist, so every declared selector reads a valid image.
    VkDescriptorSetLayoutBinding bindings[5] {};
    for (uint32_t i = 0; i < 5; ++i) {
        bindings[i].binding = i;
        bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[i].descriptorCount = 1;
        bindings[i].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dslInfo {};
    dslInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    dslInfo.bindingCount = 5;
    dslInfo.pBindings = bindings;
    if (vkCreateDescriptorSetLayout(m_device, &dslInfo, nullptr, &m_descriptorSetLayout) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkCreateDescriptorSetLayout failed building the grid pipelines");
        return false;
    }

    // Push constants: { vec2 viewportSize; vec2 cellSize; } (16 bytes), shared
    // by both vertex shaders.
    VkPushConstantRange pushRange {};
    pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pushRange.offset = 0;
    pushRange.size = sizeof(float) * 8;
    VkPipelineLayoutCreateInfo plInfo {};
    plInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plInfo.setLayoutCount = 1;
    plInfo.pSetLayouts = &m_descriptorSetLayout;
    plInfo.pushConstantRangeCount = 1;
    plInfo.pPushConstantRanges = &pushRange;
    if (vkCreatePipelineLayout(m_device, &plInfo, nullptr, &m_pipelineLayout) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkCreatePipelineLayout failed building the grid pipelines");
        return false;
    }

    VkDescriptorPoolSize poolSize {};
    poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    // Two descriptors of the one type, in the one set. `maxSets` stays 1: the
    // count here is descriptors, not sets, and sizing it to the sets rather than
    // to their contents is what makes vkAllocateDescriptorSets fail with
    // OUT_OF_POOL_MEMORY on a layout that grew.
    //
    // Four sets of five, because proportional glyphs, proportional fallback
    // strips, and ligature strips each draw through the mono pipeline over a
    // sheet of their own. Vulkan spells
    // "same pipeline, other texture" as another descriptor set.
    poolSize.descriptorCount = 20;
    VkDescriptorPoolCreateInfo dpInfo {};
    dpInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dpInfo.maxSets = 4;
    dpInfo.poolSizeCount = 1;
    dpInfo.pPoolSizes = &poolSize;
    if (vkCreateDescriptorPool(m_device, &dpInfo, nullptr, &m_descriptorPool) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkCreateDescriptorPool failed building the grid pipelines");
        return false;
    }
    // All sets come from one call over the same layout. They differ only in
    // what binding 0 is written to point at, which is why the layout is shared
    // and the pipeline never learns there are four.
    const VkDescriptorSetLayout setLayouts[4] = { m_descriptorSetLayout, m_descriptorSetLayout, m_descriptorSetLayout, m_descriptorSetLayout };
    VkDescriptorSet allocatedSets[4] {};
    VkDescriptorSetAllocateInfo dsAlloc {};
    dsAlloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    dsAlloc.descriptorPool = m_descriptorPool;
    dsAlloc.descriptorSetCount = 4;
    dsAlloc.pSetLayouts = setLayouts;
    if (vkAllocateDescriptorSets(m_device, &dsAlloc, allocatedSets) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: vkAllocateDescriptorSets failed building the grid pipelines");
        return false;
    }
    m_descriptorSet = allocatedSets[0];
    m_proportionalDescriptorSet = allocatedSets[1];
    m_proportionalStripDescriptorSet = allocatedSets[2];
    m_ligatureDescriptorSet = allocatedSets[3];

    VkShaderModule cellVert = loadShader("cell.vert.spv");
    VkShaderModule cellFrag = loadShader("cell.frag.spv");
    VkShaderModule glyphVert = loadShader("glyph.vert.spv");
    VkShaderModule glyphFrag = loadShader("glyph.frag.spv");
    VkShaderModule decoVert = loadShader("decoration.vert.spv");
    VkShaderModule decoFrag = loadShader("decoration.frag.spv");
    VkShaderModule colorVert = loadShader("color.vert.spv");
    VkShaderModule colorFrag = loadShader("color.frag.spv");
    VkShaderModule boxFillVert = loadShader("boxfill.vert.spv");
    VkShaderModule boxFillFrag = loadShader("boxfill.frag.spv");
    bool ok = cellVert && cellFrag && glyphVert && glyphFrag && decoVert && decoFrag && colorVert && colorFrag && boxFillVert && boxFillFrag;

    // How a pipeline's output meets the target.
    enum class PipelineBlend : std::uint8_t {
        // Written as computed: the shader has already mixed over the ground.
        Opaque,
        // Over the target by the output's alpha, the target's alpha kept.
        OverKeepingAlpha,
        // Ink over the target by its coverage, alpha mixed toward opaque the
        // way the CPU mixes the ground's alpha under ink.
        InkOver,
    };
    // Shared fixed-function state. Both passes draw 6 vertices (a quad from
    // gl_VertexIndex) per instance; no vertex POSITION buffer, only the
    // per-instance struct buffer at binding 0.
    auto buildPipeline = [&](VkShaderModule vert, VkShaderModule frag, uint32_t stride, const VkVertexInputAttributeDescription* attributes, uint32_t attrCount, PipelineBlend blend, VkPipeline* outPipeline,
                             const VkSpecializationInfo* fragmentSpecialization = nullptr) -> bool {
        VkPipelineShaderStageCreateInfo stages[2] {};
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vert;
        stages[0].pName = "main";
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = frag;
        stages[1].pName = "main";
        stages[1].pSpecializationInfo = fragmentSpecialization;

        VkVertexInputBindingDescription bindingDesc {};
        bindingDesc.binding = 0;
        bindingDesc.stride = stride;
        bindingDesc.inputRate = VK_VERTEX_INPUT_RATE_INSTANCE;
        VkPipelineVertexInputStateCreateInfo vertexInput {};
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &bindingDesc;
        vertexInput.vertexAttributeDescriptionCount = attrCount;
        vertexInput.pVertexAttributeDescriptions = attributes;

        VkPipelineInputAssemblyStateCreateInfo inputAssembly {};
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkPipelineViewportStateCreateInfo viewportState {};
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;

        VkPipelineRasterizationStateCreateInfo raster {};
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;

        VkPipelineMultisampleStateCreateInfo multisample {};
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState blendAttachment {};
        blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        blendAttachment.blendEnable = blend == PipelineBlend::Opaque ? VK_FALSE : VK_TRUE;
        // Color: srcColor*srcAlpha + dst*(1-srcAlpha) (decoration / translucent
        // selection over the opaque cell). Alpha: KEEP the destination alpha
        // (the cell pass wrote opaque 255), so a translucent overlay tints the
        // RGB but never punches a hole in the frame's alpha — matching the CPU
        // SoftwareRenderer, whose composite passes leave the alpha byte at 255.
        // Ink instead mixes the alpha toward opaque by its coverage, as the
        // CPU's ink does over a ground of the window's opacity.
        blendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        blendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blendAttachment.colorBlendOp = VK_BLEND_OP_ADD;
        blendAttachment.srcAlphaBlendFactor = blend == PipelineBlend::InkOver ? VK_BLEND_FACTOR_ONE : VK_BLEND_FACTOR_ZERO;
        blendAttachment.dstAlphaBlendFactor = blend == PipelineBlend::InkOver ? VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : VK_BLEND_FACTOR_ONE;
        blendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;
        VkPipelineColorBlendStateCreateInfo colorBlend {};
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blendAttachment;

        const VkDynamicState dynamics[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkPipelineDynamicStateCreateInfo dynamicState {};
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates = dynamics;

        VkGraphicsPipelineCreateInfo pipelineInfo {};
        pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipelineInfo.stageCount = 2;
        pipelineInfo.pStages = stages;
        pipelineInfo.pVertexInputState = &vertexInput;
        pipelineInfo.pInputAssemblyState = &inputAssembly;
        pipelineInfo.pViewportState = &viewportState;
        pipelineInfo.pRasterizationState = &raster;
        pipelineInfo.pMultisampleState = &multisample;
        pipelineInfo.pColorBlendState = &colorBlend;
        pipelineInfo.pDynamicState = &dynamicState;
        pipelineInfo.layout = m_pipelineLayout;
        pipelineInfo.renderPass = m_renderPass;
        pipelineInfo.subpass = 0;
        return vkCreateGraphicsPipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, outPipeline) == VK_SUCCESS;
    };

    // CellInstance attributes — locations map to the struct's field byte
    // offsets (location 2 / pillCaps is unused by the shader, omitted).
    const VkVertexInputAttributeDescription cellAttributes[] = {
        { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::CellInstance, gridPosition) },
        { 1, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::CellInstance, widthCells) },
        { 3, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::CellInstance, foreground) },
        { 4, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::CellInstance, background) },
        { 5, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::CellInstance, atlasTopLeft) },
        { 6, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::CellInstance, atlasBottomRight) },
    };
    // GlyphInstance attributes (the subpixel overflow pass) — the full slot quad.
    const VkVertexInputAttributeDescription glyphAttributes[] = {
        { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::GlyphInstance, originInPixels) },
        { 1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::GlyphInstance, sizeInPixels) },
        { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::GlyphInstance, foreground) },
        { 3, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::GlyphInstance, background) },
        { 4, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::GlyphInstance, atlasTopLeft) },
        { 5, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::GlyphInstance, atlasBottomRight) },
    };
    // DecorationInstance attributes, read as whole vec4s so the cut's
    // neighbour pairs fit in the sixteen attributes every device has.
    const VkVertexInputAttributeDescription decoAttributes[] = {
        { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::DecorationInstance, topLeftInPixels) },
        { 1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::DecorationInstance, bottomRightInPixels) },
        { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, color) },
        { 3, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, kind) },
        { 4, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, inkTopLeft) },
        { 5, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, padInAtlas) },
        // The glyph's own atlas slot, so the skip-ink taps stop at its edge
        // instead of reading the glyph packed beside it.
        { 6, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, glyphSlotTopLeftUV) },
        { 7, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, leftInk) },
        { 8, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, leftBox) },
        { 9, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, rightInk) },
        { 10, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::DecorationInstance, rightBox) },
    };
    const uint32_t cellAttributeCount = static_cast<uint32_t>(sizeof(cellAttributes) / sizeof(cellAttributes[0]));
    const uint32_t glyphAttributeCount = static_cast<uint32_t>(sizeof(glyphAttributes) / sizeof(glyphAttributes[0]));
    if (ok)
        ok = buildPipeline(cellVert, cellFrag, sizeof(Rendering::CellInstance), cellAttributes, cellAttributeCount, PipelineBlend::Opaque, &m_cellPipeline);
    // The glyph pass writes opaque (the integer mix over the cell bg) + discards
    // coverage 0, so it is opaque like the cell pass — no hardware blend (which
    // would diverge from the CPU integer mix).
    if (ok)
        ok = buildPipeline(glyphVert, glyphFrag, sizeof(Rendering::GlyphInstance), glyphAttributes, glyphAttributeCount, PipelineBlend::Opaque, &m_glyphPipeline);
    // The three that draw a frame with a picture under its text: the cells'
    // ground alone, then, once the picture is down, the cells' ink and the
    // glyph streams blended over it. The shaders' constant 0 picks the variant.
    const VkSpecializationMapEntry paintEntry { 0, 0, sizeof(std::int32_t) };
    const std::int32_t groundPaint = 1;
    const std::int32_t inkPaint = 2;
    const VkBool32 isOverTarget = VK_TRUE;
    const VkSpecializationInfo groundSpecialization { 1, &paintEntry, sizeof(groundPaint), &groundPaint };
    const VkSpecializationInfo inkSpecialization { 1, &paintEntry, sizeof(inkPaint), &inkPaint };
    const VkSpecializationInfo overTargetSpecialization { 1, &paintEntry, sizeof(isOverTarget), &isOverTarget };
    if (ok)
        ok = buildPipeline(cellVert, cellFrag, sizeof(Rendering::CellInstance), cellAttributes, cellAttributeCount, PipelineBlend::Opaque, &m_cellGroundPipeline, &groundSpecialization);
    if (ok)
        ok = buildPipeline(cellVert, cellFrag, sizeof(Rendering::CellInstance), cellAttributes, cellAttributeCount, PipelineBlend::InkOver, &m_cellInkPipeline, &inkSpecialization);
    if (ok)
        ok = buildPipeline(glyphVert, glyphFrag, sizeof(Rendering::GlyphInstance), glyphAttributes, glyphAttributeCount, PipelineBlend::InkOver, &m_glyphOverTargetPipeline, &overTargetSpecialization);
    if (ok)
        ok = buildPipeline(decoVert, decoFrag, sizeof(Rendering::DecorationInstance), decoAttributes, static_cast<uint32_t>(sizeof(decoAttributes) / sizeof(decoAttributes[0])), PipelineBlend::OverKeepingAlpha, &m_decorationPipeline);
    // The colour pass consumes GlyphInstance and its attributes unchanged — the
    // stream the builder fills is the same shape as the mono one, and only what
    // the shaders do with it differs.
    //
    // Blended, unlike the two mono passes. Those composite against the cell
    // background the instance carries, which is safe because a coverage glyph
    // stays inside the cell that owns it; a colour slot is square while its
    // destination is a cell span, so it overhangs into the neighbour whenever
    // the cell is not square and has to blend against what is actually there.
    if (ok)
        ok = buildPipeline(colorVert, colorFrag, sizeof(Rendering::GlyphInstance), glyphAttributes, glyphAttributeCount, PipelineBlend::OverKeepingAlpha, &m_colorPipeline);
    // OverlayInstance attributes of the box-fill stream. Blended: a quad's
    // coverage is a byte-quantised alpha over what the cells and earlier quads
    // wrote, and crossing diagonals compose in emitted order.
    const VkVertexInputAttributeDescription boxFillAttributes[] = {
        { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::OverlayInstance, topLeftInPixels) },
        { 1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::OverlayInstance, bottomRightInPixels) },
        { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, color) },
        { 3, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, cornerRadius) },
        { 9, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, cornerStyle) },
        { 4, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, strokeWidth) },
        { 5, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, shadeDensity) },
        { 6, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, shapeKind) },
        { 7, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, plA) },
        { 8, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, plB) },
    };
    if (ok)
        ok = buildPipeline(boxFillVert, boxFillFrag, sizeof(Rendering::OverlayInstance), boxFillAttributes, static_cast<uint32_t>(sizeof(boxFillAttributes) / sizeof(boxFillAttributes[0])), PipelineBlend::OverKeepingAlpha, &m_boxFillPipeline);

    if (cellVert)
        vkDestroyShaderModule(m_device, cellVert, nullptr);
    if (cellFrag)
        vkDestroyShaderModule(m_device, cellFrag, nullptr);
    if (glyphVert)
        vkDestroyShaderModule(m_device, glyphVert, nullptr);
    if (glyphFrag)
        vkDestroyShaderModule(m_device, glyphFrag, nullptr);
    if (decoVert)
        vkDestroyShaderModule(m_device, decoVert, nullptr);
    if (decoFrag)
        vkDestroyShaderModule(m_device, decoFrag, nullptr);
    if (colorVert)
        vkDestroyShaderModule(m_device, colorVert, nullptr);
    if (colorFrag)
        vkDestroyShaderModule(m_device, colorFrag, nullptr);
    if (boxFillVert)
        vkDestroyShaderModule(m_device, boxFillVert, nullptr);
    if (boxFillFrag)
        vkDestroyShaderModule(m_device, boxFillFrag, nullptr);
    return ok;
}

void VulkanRenderer::destroyGridPipelines()
{
    if (m_glyphOverTargetPipeline) {
        vkDestroyPipeline(m_device, m_glyphOverTargetPipeline, nullptr);
        m_glyphOverTargetPipeline = VK_NULL_HANDLE;
    }
    if (m_cellInkPipeline) {
        vkDestroyPipeline(m_device, m_cellInkPipeline, nullptr);
        m_cellInkPipeline = VK_NULL_HANDLE;
    }
    if (m_cellGroundPipeline) {
        vkDestroyPipeline(m_device, m_cellGroundPipeline, nullptr);
        m_cellGroundPipeline = VK_NULL_HANDLE;
    }
    if (m_colorPipeline) {
        vkDestroyPipeline(m_device, m_colorPipeline, nullptr);
        m_colorPipeline = VK_NULL_HANDLE;
    }
    if (m_boxFillPipeline) {
        vkDestroyPipeline(m_device, m_boxFillPipeline, nullptr);
        m_boxFillPipeline = VK_NULL_HANDLE;
    }
    if (m_decorationPipeline) {
        vkDestroyPipeline(m_device, m_decorationPipeline, nullptr);
        m_decorationPipeline = VK_NULL_HANDLE;
    }
    if (m_glyphPipeline) {
        vkDestroyPipeline(m_device, m_glyphPipeline, nullptr);
        m_glyphPipeline = VK_NULL_HANDLE;
    }
    if (m_cellPipeline) {
        vkDestroyPipeline(m_device, m_cellPipeline, nullptr);
        m_cellPipeline = VK_NULL_HANDLE;
    }
    if (m_descriptorPool) {
        vkDestroyDescriptorPool(m_device, m_descriptorPool, nullptr);
        m_descriptorPool = VK_NULL_HANDLE;
        m_descriptorSet = VK_NULL_HANDLE;
        m_proportionalDescriptorSet = VK_NULL_HANDLE;
        m_proportionalStripDescriptorSet = VK_NULL_HANDLE;
        m_ligatureDescriptorSet = VK_NULL_HANDLE;
        m_isProportionalDescriptorWritten = false;
        m_isProportionalStripDescriptorWritten = false;
        m_isLigatureDescriptorWritten = false;
        m_descriptorWritten = false;
    }
    if (m_pipelineLayout) {
        vkDestroyPipelineLayout(m_device, m_pipelineLayout, nullptr);
        m_pipelineLayout = VK_NULL_HANDLE;
    }
    if (m_descriptorSetLayout) {
        vkDestroyDescriptorSetLayout(m_device, m_descriptorSetLayout, nullptr);
        m_descriptorSetLayout = VK_NULL_HANDLE;
    }
    if (m_gridLoadRenderPass) {
        vkDestroyRenderPass(m_device, m_gridLoadRenderPass, nullptr);
        m_gridLoadRenderPass = VK_NULL_HANDLE;
    }
    if (m_renderPass) {
        vkDestroyRenderPass(m_device, m_renderPass, nullptr);
        m_renderPass = VK_NULL_HANDLE;
    }
}

void VulkanRenderer::destroyGridTarget()
{
    if (m_framebuffer) {
        vkDestroyFramebuffer(m_device, m_framebuffer, nullptr);
        m_framebuffer = VK_NULL_HANDLE;
    }
    if (m_colorView) {
        vkDestroyImageView(m_device, m_colorView, nullptr);
        m_colorView = VK_NULL_HANDLE;
    }
    // The image-pass background input-attachment descriptor binds m_colorView;
    // a recreated view must be re-bound on the next renderGrid.
    m_imageBackgroundWritten = false;
    m_framebufferWidth = m_framebufferHeight = 0;
}

bool VulkanRenderer::ensureRetainedGridImages(uint32_t width, uint32_t height)
{
    if (m_gridImages[0] != VK_NULL_HANDLE && width == m_gridImageWidth && height == m_gridImageHeight)
        return true;
    destroyRetainedGridImages();
    for (int i = 0; i < 2; ++i) {
        VkImageCreateInfo ic {};
        ic.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ic.imageType = VK_IMAGE_TYPE_2D;
        ic.format = imageFormat;
        ic.extent = { width, height, 1 };
        ic.mipLevels = 1;
        ic.arrayLayers = 1;
        ic.samples = VK_SAMPLE_COUNT_1_BIT;
        ic.tiling = VK_IMAGE_TILING_OPTIMAL;
        // Color target for the grid passes, transfer source for the band and
        // full-image copies, transfer destination for the bands it receives.
        ic.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        ic.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        ic.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (vkCreateImage(m_device, &ic, nullptr, &m_gridImages[i]) != VK_SUCCESS)
            return false;
        VkMemoryRequirements req {};
        vkGetImageMemoryRequirements(m_device, m_gridImages[i], &req);
        VkMemoryAllocateInfo mai {};
        mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (mai.memoryTypeIndex == UINT32_MAX)
            return false;
        if (vkAllocateMemory(m_device, &mai, nullptr, &m_gridImageMemory[i]) != VK_SUCCESS)
            return false;
        if (vkBindImageMemory(m_device, m_gridImages[i], m_gridImageMemory[i], 0) != VK_SUCCESS)
            return false;
        VkImageViewCreateInfo viewInfo {};
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = m_gridImages[i];
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = imageFormat;
        viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.layerCount = 1;
        if (vkCreateImageView(m_device, &viewInfo, nullptr, &m_gridImageViews[i]) != VK_SUCCESS)
            return false;
        VkFramebufferCreateInfo fbInfo {};
        fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        // Built against the CLEAR pass; the LOAD twin is render-pass
        // compatible (same attachment format, sample count and attachment
        // list), which is what licenses one framebuffer serving both.
        fbInfo.renderPass = m_renderPass;
        fbInfo.attachmentCount = 1;
        fbInfo.pAttachments = &m_gridImageViews[i];
        fbInfo.width = width;
        fbInfo.height = height;
        fbInfo.layers = 1;
        if (vkCreateFramebuffer(m_device, &fbInfo, nullptr, &m_gridFramebuffers[i]) != VK_SUCCESS)
            return false;
    }
    m_gridImageWidth = width;
    m_gridImageHeight = height;
    m_gridFrontIndex = 0;
    m_hasRetainedTarget = false;
    return true;
}

void VulkanRenderer::destroyRetainedGridImages()
{
    for (int i = 0; i < 2; ++i) {
        if (m_gridFramebuffers[i]) {
            vkDestroyFramebuffer(m_device, m_gridFramebuffers[i], nullptr);
            m_gridFramebuffers[i] = VK_NULL_HANDLE;
        }
        if (m_gridImageViews[i]) {
            vkDestroyImageView(m_device, m_gridImageViews[i], nullptr);
            m_gridImageViews[i] = VK_NULL_HANDLE;
        }
        if (m_gridImages[i]) {
            vkDestroyImage(m_device, m_gridImages[i], nullptr);
            m_gridImages[i] = VK_NULL_HANDLE;
        }
        if (m_gridImageMemory[i]) {
            vkFreeMemory(m_device, m_gridImageMemory[i], nullptr);
            m_gridImageMemory[i] = VK_NULL_HANDLE;
        }
    }
    m_gridImageWidth = m_gridImageHeight = 0;
    m_hasRetainedTarget = false;
}

bool VulkanRenderer::ensureGridTarget(uint32_t width, uint32_t height)
{
    if (m_framebuffer != VK_NULL_HANDLE && width == m_framebufferWidth && height == m_framebufferHeight)
        return true;
    destroyGridTarget();

    VkImageViewCreateInfo viewInfo {};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = m_image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = imageFormat;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.layerCount = 1;
    if (vkCreateImageView(m_device, &viewInfo, nullptr, &m_colorView) != VK_SUCCESS)
        return false;

    VkFramebufferCreateInfo fbInfo {};
    fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fbInfo.renderPass = m_renderPass;
    fbInfo.attachmentCount = 1;
    fbInfo.pAttachments = &m_colorView;
    fbInfo.width = width;
    fbInfo.height = height;
    fbInfo.layers = 1;
    if (vkCreateFramebuffer(m_device, &fbInfo, nullptr, &m_framebuffer) != VK_SUCCESS)
        return false;

    m_framebufferWidth = width;
    m_framebufferHeight = height;
    return true;
}

std::span<const Rendering::LetterExtent> VulkanRenderer::rowLetters(int row) const
{
    if (row < 0 || row >= static_cast<int>(m_letterRows.size()) || m_letterRows[static_cast<std::size_t>(row)] == 0u || m_letterColumns <= 0)
        return {};
    const std::size_t first = static_cast<std::size_t>(row) * static_cast<std::size_t>(m_letterColumns);
    if (first + static_cast<std::size_t>(m_letterColumns) > m_letters.size())
        return {};
    return std::span<const Rendering::LetterExtent>(m_letters).subspan(first, static_cast<std::size_t>(m_letterColumns));
}

int VulkanRenderer::columnAt(int row, double xInPixels) const
{
    const std::span<const Rendering::LetterExtent> letters = rowLetters(row);
    if (!letters.empty())
        return Rendering::letterColumnAt(letters, xInPixels);
    if (m_cellWidth <= 0 || m_letterColumns <= 0)
        return 0;
    return std::clamp(static_cast<int>(std::floor(xInPixels / static_cast<double>(m_cellWidth))), 0, m_letterColumns - 1);
}

double VulkanRenderer::xInCellsAt(int row, double xInPixels) const
{
    const std::span<const Rendering::LetterExtent> letters = rowLetters(row);
    if (!letters.empty())
        return Rendering::letterXInCells(letters, xInPixels);
    if (m_cellWidth <= 0)
        return 0.0;
    return std::clamp(xInPixels / static_cast<double>(m_cellWidth), 0.0, static_cast<double>(std::max(m_letterColumns, 0)));
}

void VulkanRenderer::destroyInstanceBuffers()
{
    if (m_cellBuffer) {
        vkDestroyBuffer(m_device, m_cellBuffer, nullptr);
        m_cellBuffer = VK_NULL_HANDLE;
    }
    if (m_cellBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_cellMapped) {
            vkUnmapMemory(m_device, m_cellBufferMemory);
            m_cellMapped = nullptr;
        }
        vkFreeMemory(m_device, m_cellBufferMemory, nullptr);
        m_cellBufferMemory = VK_NULL_HANDLE;
    }
    if (m_glyphBuffer) {
        vkDestroyBuffer(m_device, m_glyphBuffer, nullptr);
        m_glyphBuffer = VK_NULL_HANDLE;
    }
    if (m_glyphBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_glyphMapped) {
            vkUnmapMemory(m_device, m_glyphBufferMemory);
            m_glyphMapped = nullptr;
        }
        vkFreeMemory(m_device, m_glyphBufferMemory, nullptr);
        m_glyphBufferMemory = VK_NULL_HANDLE;
    }
    if (m_proportionalBuffer) {
        vkDestroyBuffer(m_device, m_proportionalBuffer, nullptr);
        m_proportionalBuffer = VK_NULL_HANDLE;
    }
    if (m_proportionalBufferMemory) {
        if (m_proportionalMapped) {
            vkUnmapMemory(m_device, m_proportionalBufferMemory);
            m_proportionalMapped = nullptr;
        }
        vkFreeMemory(m_device, m_proportionalBufferMemory, nullptr);
        m_proportionalBufferMemory = VK_NULL_HANDLE;
    }
    m_proportionalCapacity = 0;
    if (m_proportionalStripBuffer) {
        vkDestroyBuffer(m_device, m_proportionalStripBuffer, nullptr);
        m_proportionalStripBuffer = VK_NULL_HANDLE;
    }
    if (m_proportionalStripBufferMemory) {
        if (m_proportionalStripMapped) {
            vkUnmapMemory(m_device, m_proportionalStripBufferMemory);
            m_proportionalStripMapped = nullptr;
        }
        vkFreeMemory(m_device, m_proportionalStripBufferMemory, nullptr);
        m_proportionalStripBufferMemory = VK_NULL_HANDLE;
    }
    m_proportionalStripCapacity = 0;
    if (m_decorationBuffer) {
        vkDestroyBuffer(m_device, m_decorationBuffer, nullptr);
        m_decorationBuffer = VK_NULL_HANDLE;
    }
    if (m_decorationBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_decorationMapped) {
            vkUnmapMemory(m_device, m_decorationBufferMemory);
            m_decorationMapped = nullptr;
        }
        vkFreeMemory(m_device, m_decorationBufferMemory, nullptr);
        m_decorationBufferMemory = VK_NULL_HANDLE;
    }
    if (m_colorBuffer) {
        vkDestroyBuffer(m_device, m_colorBuffer, nullptr);
        m_colorBuffer = VK_NULL_HANDLE;
    }
    if (m_colorBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_colorMapped) {
            vkUnmapMemory(m_device, m_colorBufferMemory);
            m_colorMapped = nullptr;
        }
        vkFreeMemory(m_device, m_colorBufferMemory, nullptr);
        m_colorBufferMemory = VK_NULL_HANDLE;
    }
    m_colorCapacity = 0;
    if (m_ligatureBuffer) {
        vkDestroyBuffer(m_device, m_ligatureBuffer, nullptr);
        m_ligatureBuffer = VK_NULL_HANDLE;
    }
    if (m_ligatureBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_ligatureMapped) {
            vkUnmapMemory(m_device, m_ligatureBufferMemory);
            m_ligatureMapped = nullptr;
        }
        vkFreeMemory(m_device, m_ligatureBufferMemory, nullptr);
        m_ligatureBufferMemory = VK_NULL_HANDLE;
    }
    m_ligatureCapacity = 0;
    if (m_wideBuffer) {
        vkDestroyBuffer(m_device, m_wideBuffer, nullptr);
        m_wideBuffer = VK_NULL_HANDLE;
    }
    if (m_wideBufferMemory) {
        if (m_wideMapped) {
            vkUnmapMemory(m_device, m_wideBufferMemory);
            m_wideMapped = nullptr;
        }
        vkFreeMemory(m_device, m_wideBufferMemory, nullptr);
        m_wideBufferMemory = VK_NULL_HANDLE;
    }
    m_wideCapacity = 0;
    if (m_overlayBuffer) {
        vkDestroyBuffer(m_device, m_overlayBuffer, nullptr);
        m_overlayBuffer = VK_NULL_HANDLE;
    }
    if (m_overlayBufferMemory) {
        // Unmapped before the free, and the pointer cleared with it: a stale
        // mapped pointer outliving its memory is a write into freed pages that
        // no frame would report.
        if (m_overlayMapped) {
            vkUnmapMemory(m_device, m_overlayBufferMemory);
            m_overlayMapped = nullptr;
        }
        vkFreeMemory(m_device, m_overlayBufferMemory, nullptr);
        m_overlayBufferMemory = VK_NULL_HANDLE;
    }
    if (m_boxFillBuffer) {
        vkDestroyBuffer(m_device, m_boxFillBuffer, nullptr);
        m_boxFillBuffer = VK_NULL_HANDLE;
    }
    if (m_boxFillBufferMemory) {
        if (m_boxFillMapped) {
            vkUnmapMemory(m_device, m_boxFillBufferMemory);
            m_boxFillMapped = nullptr;
        }
        vkFreeMemory(m_device, m_boxFillBufferMemory, nullptr);
        m_boxFillBufferMemory = VK_NULL_HANDLE;
    }
    m_cellCapacity = m_glyphCapacity = m_decorationCapacity = m_overlayCapacity = m_boxFillCapacity = 0;
}

bool VulkanRenderer::ensureInstanceBuffers(std::size_t cellCount, std::size_t glyphCount,
    std::size_t proportionalCount, std::size_t proportionalStripCount, std::size_t decorationCount,
    std::size_t overlayCount, std::size_t colorCount,
    std::size_t ligatureCount, std::size_t wideCount, std::size_t boxFillCount)
{
    // Mapped here, once, rather than per frame: the memory is
    // HOST_VISIBLE|HOST_COHERENT, persistent mapping of it is legal, and the
    // pointer does not move for the buffer's life. A frame writes through it and
    // needs no flush.
    auto make = [&](std::size_t bytes, VkBuffer* outBuffer, VkDeviceMemory* outMemory, void** outMapped) -> bool {
        VkBufferCreateInfo info {};
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = bytes;
        info.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (vkCreateBuffer(m_device, &info, nullptr, outBuffer) != VK_SUCCESS)
            return false;
        VkMemoryRequirements req {};
        vkGetBufferMemoryRequirements(m_device, *outBuffer, &req);
        VkMemoryAllocateInfo alloc {};
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize = req.size;
        // The builder adjusts emitted glyph bounds and reads overlay quads.
        // Prefer cached memory for those CPU reads while retaining coherence.
        constexpr VkMemoryPropertyFlags requiredProperties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, requiredProperties | VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
        if (alloc.memoryTypeIndex == UINT32_MAX)
            alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, requiredProperties);
        if (alloc.memoryTypeIndex == UINT32_MAX)
            return false;
        if (vkAllocateMemory(m_device, &alloc, nullptr, outMemory) != VK_SUCCESS)
            return false;
        if (vkBindBufferMemory(m_device, *outBuffer, *outMemory, 0) != VK_SUCCESS)
            return false;
        return vkMapMemory(m_device, *outMemory, 0, VK_WHOLE_SIZE, 0, outMapped) == VK_SUCCESS;
    };

    if (cellCount > m_cellCapacity || glyphCount > m_glyphCapacity
        || proportionalCount > m_proportionalCapacity
        || proportionalStripCount > m_proportionalStripCapacity
        || decorationCount > m_decorationCapacity
        || overlayCount > m_overlayCapacity || colorCount > m_colorCapacity
        || ligatureCount > m_ligatureCapacity || wideCount > m_wideCapacity
        || boxFillCount > m_boxFillCapacity) {
        destroyInstanceBuffers();
        // Guarded by count: a zero-length VkBufferCreateInfo::size is invalid
        // per spec, and lavapipe segfaults on it rather than erroring. Every
        // caller below already checks capacity/drawCount > 0 before touching
        // the buffer, so leaving it VK_NULL_HANDLE here is safe.
        if (cellCount > 0 && !make(cellCount * sizeof(Rendering::CellInstance), &m_cellBuffer, &m_cellBufferMemory, &m_cellMapped))
            return false;
        if (glyphCount > 0 && !make(glyphCount * sizeof(Rendering::GlyphInstance), &m_glyphBuffer, &m_glyphBufferMemory, &m_glyphMapped))
            return false;
        if (proportionalCount > 0 && !make(proportionalCount * sizeof(Rendering::GlyphInstance), &m_proportionalBuffer, &m_proportionalBufferMemory, &m_proportionalMapped))
            return false;
        if (proportionalStripCount > 0 && !make(proportionalStripCount * sizeof(Rendering::GlyphInstance), &m_proportionalStripBuffer, &m_proportionalStripBufferMemory, &m_proportionalStripMapped))
            return false;
        if (decorationCount > 0 && !make(decorationCount * sizeof(Rendering::DecorationInstance), &m_decorationBuffer, &m_decorationBufferMemory, &m_decorationMapped))
            return false;
        if (overlayCount > 0 && !make(overlayCount * sizeof(Rendering::OverlayInstance), &m_overlayBuffer, &m_overlayBufferMemory, &m_overlayMapped))
            return false;
        // The colour stream is GlyphInstance, the same struct the mono pass
        // uses — one shape, two atlases.
        if (colorCount > 0 && !make(colorCount * sizeof(Rendering::GlyphInstance), &m_colorBuffer, &m_colorBufferMemory, &m_colorMapped))
            return false;
        // Ligature strips are GlyphInstance too — the third stream on that one
        // shape, and the reason the mono pipeline can draw all of them.
        if (ligatureCount > 0 && !make(ligatureCount * sizeof(Rendering::GlyphInstance), &m_ligatureBuffer, &m_ligatureBufferMemory, &m_ligatureMapped))
            return false;
        if (wideCount > 0 && !make(wideCount * sizeof(Rendering::GlyphInstance), &m_wideBuffer, &m_wideBufferMemory, &m_wideMapped))
            return false;
        if (boxFillCount > 0 && !make(boxFillCount * sizeof(Rendering::OverlayInstance), &m_boxFillBuffer, &m_boxFillBufferMemory, &m_boxFillMapped))
            return false;
        m_cellCapacity = cellCount;
        m_glyphCapacity = glyphCount;
        m_proportionalCapacity = proportionalCount;
        m_proportionalStripCapacity = proportionalStripCount;
        m_decorationCapacity = decorationCount;
        m_overlayCapacity = overlayCount;
        m_colorCapacity = colorCount;
        m_ligatureCapacity = ligatureCount;
        m_wideCapacity = wideCount;
        m_boxFillCapacity = boxFillCount;
    }
    return true;
}

bool VulkanRenderer::ensureImagePipeline()
{
    if (m_imagePipeline != VK_NULL_HANDLE)
        return true;

    // A second render pass over the same color attachment: LOAD the grid
    // result, bind it as input attachment 0 (the background read) and as the
    // color attachment, and self-blend each image quad on top. The attachment
    // sits in GENERAL for both reads and writes (a feedback loop); a by-region
    // self-dependency makes a prior image draw's write visible to a later
    // image's subpassLoad. initial/final layout GENERAL — the caller
    // transitions the image into GENERAL before the pass and back to
    // TRANSFER_SRC for the host copy.
    VkAttachmentDescription color {};
    color.format = imageFormat;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_GENERAL;
    color.finalLayout = VK_IMAGE_LAYOUT_GENERAL;

    VkAttachmentReference colorRef {};
    colorRef.attachment = 0;
    colorRef.layout = VK_IMAGE_LAYOUT_GENERAL;
    VkAttachmentReference inputRef {};
    inputRef.attachment = 0;
    inputRef.layout = VK_IMAGE_LAYOUT_GENERAL;

    VkSubpassDescription subpass {};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colorRef;
    subpass.inputAttachmentCount = 1;
    subpass.pInputAttachments = &inputRef;

    // [0] external -> subpass: the prior render pass's color write must be
    // visible to this pass's load + input read. [1] subpass self-dependency
    // (by-region): a draw's color write visible to a later draw's input read.
    // [2] subpass -> external: the final write visible to the transfer copy.
    VkSubpassDependency deps[3] {};
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[0].dstAccessMask = VK_ACCESS_INPUT_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = 0;
    deps[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_INPUT_ATTACHMENT_READ_BIT;
    deps[1].dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT;
    deps[2].srcSubpass = 0;
    deps[2].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[2].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[2].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[2].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[2].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    VkRenderPassCreateInfo rpInfo {};
    rpInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpInfo.attachmentCount = 1;
    rpInfo.pAttachments = &color;
    rpInfo.subpassCount = 1;
    rpInfo.pSubpasses = &subpass;
    rpInfo.dependencyCount = 3;
    rpInfo.pDependencies = deps;
    if (vkCreateRenderPass(m_device, &rpInfo, nullptr, &m_imageRenderPass) != VK_SUCCESS)
        return false;

    // set 0: the per-image source texture (combined image sampler).
    VkDescriptorSetLayoutBinding samplerBinding {};
    samplerBinding.binding = 0;
    samplerBinding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    samplerBinding.descriptorCount = 1;
    samplerBinding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo samplerInfo {};
    samplerInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    samplerInfo.bindingCount = 1;
    samplerInfo.pBindings = &samplerBinding;
    if (vkCreateDescriptorSetLayout(m_device, &samplerInfo, nullptr, &m_imageSamplerSetLayout) != VK_SUCCESS)
        return false;

    // set 1: the input-attachment background (the grid result under the image).
    VkDescriptorSetLayoutBinding backgroundBinding {};
    backgroundBinding.binding = 0;
    backgroundBinding.descriptorType = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT;
    backgroundBinding.descriptorCount = 1;
    backgroundBinding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo backgroundInfo {};
    backgroundInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    backgroundInfo.bindingCount = 1;
    backgroundInfo.pBindings = &backgroundBinding;
    if (vkCreateDescriptorSetLayout(m_device, &backgroundInfo, nullptr, &m_imageBackgroundSetLayout) != VK_SUCCESS)
        return false;

    // Shared push constants ({ vec2 viewportSize; vec2 cellSize; }) as the grid.
    VkPushConstantRange pushRange {};
    pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pushRange.offset = 0;
    pushRange.size = sizeof(float) * 8;
    const VkDescriptorSetLayout setLayouts[2] = { m_imageSamplerSetLayout, m_imageBackgroundSetLayout };
    VkPipelineLayoutCreateInfo plInfo {};
    plInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plInfo.setLayoutCount = 2;
    plInfo.pSetLayouts = setLayouts;
    plInfo.pushConstantRangeCount = 1;
    plInfo.pPushConstantRanges = &pushRange;
    if (vkCreatePipelineLayout(m_device, &plInfo, nullptr, &m_imagePipelineLayout) != VK_SUCCESS)
        return false;

    // One input-attachment descriptor set (the background), allocated from a
    // small pool. Bound to the color attachment's view in renderGrid.
    VkDescriptorPoolSize poolSize {};
    poolSize.type = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT;
    poolSize.descriptorCount = 1;
    VkDescriptorPoolCreateInfo poolInfo {};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.maxSets = 1;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    if (vkCreateDescriptorPool(m_device, &poolInfo, nullptr, &m_imageBackgroundPool) != VK_SUCCESS)
        return false;
    VkDescriptorSetAllocateInfo dsAlloc {};
    dsAlloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    dsAlloc.descriptorPool = m_imageBackgroundPool;
    dsAlloc.descriptorSetCount = 1;
    dsAlloc.pSetLayouts = &m_imageBackgroundSetLayout;
    if (vkAllocateDescriptorSets(m_device, &dsAlloc, &m_imageBackgroundSet) != VK_SUCCESS)
        return false;

    VkShaderModule imageVert = loadShader("image.vert.spv");
    VkShaderModule imageFrag = loadShader("image.frag.spv");
    bool ok = imageVert && imageFrag;

    if (ok) {
        VkPipelineShaderStageCreateInfo stages[2] {};
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = imageVert;
        stages[0].pName = "main";
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = imageFrag;
        stages[1].pName = "main";

        // ImageInstance per-instance attributes (VulkanImageTextures.h).
        const VkVertexInputAttributeDescription attributes[] = {
            { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(ImageInstance, minXInPixels) },
            { 1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(ImageInstance, maxXInPixels) },
            { 2, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(ImageInstance, u0) },
            { 3, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(ImageInstance, u1) },
            { 4, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(ImageInstance, texWidth) },
            { 5, 0, VK_FORMAT_R32_SFLOAT, offsetof(ImageInstance, straightAlpha) },
            { 6, 0, VK_FORMAT_R32_SFLOAT, offsetof(ImageInstance, filtered) },
        };
        VkVertexInputBindingDescription bindingDesc {};
        bindingDesc.binding = 0;
        bindingDesc.stride = sizeof(ImageInstance);
        bindingDesc.inputRate = VK_VERTEX_INPUT_RATE_INSTANCE;
        VkPipelineVertexInputStateCreateInfo vertexInput {};
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &bindingDesc;
        vertexInput.vertexAttributeDescriptionCount = static_cast<uint32_t>(sizeof(attributes) / sizeof(attributes[0]));
        vertexInput.pVertexAttributeDescriptions = attributes;

        VkPipelineInputAssemblyStateCreateInfo inputAssembly {};
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkPipelineViewportStateCreateInfo viewportState {};
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;

        VkPipelineRasterizationStateCreateInfo raster {};
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;

        VkPipelineMultisampleStateCreateInfo multisample {};
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        // The shader does the over-blend itself (integer domain) and writes the
        // final color, so fixed-function blending is OFF — like the cell pass.
        VkPipelineColorBlendAttachmentState blendAttachment {};
        blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        blendAttachment.blendEnable = VK_FALSE;
        VkPipelineColorBlendStateCreateInfo colorBlend {};
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blendAttachment;

        const VkDynamicState dynamics[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkPipelineDynamicStateCreateInfo dynamicState {};
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates = dynamics;

        VkGraphicsPipelineCreateInfo pipelineInfo {};
        pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipelineInfo.stageCount = 2;
        pipelineInfo.pStages = stages;
        pipelineInfo.pVertexInputState = &vertexInput;
        pipelineInfo.pInputAssemblyState = &inputAssembly;
        pipelineInfo.pViewportState = &viewportState;
        pipelineInfo.pRasterizationState = &raster;
        pipelineInfo.pMultisampleState = &multisample;
        pipelineInfo.pColorBlendState = &colorBlend;
        pipelineInfo.pDynamicState = &dynamicState;
        pipelineInfo.layout = m_imagePipelineLayout;
        pipelineInfo.renderPass = m_imageRenderPass;
        pipelineInfo.subpass = 0;
        ok = vkCreateGraphicsPipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &m_imagePipeline) == VK_SUCCESS;
    }

    if (imageVert)
        vkDestroyShaderModule(m_device, imageVert, nullptr);
    if (imageFrag)
        vkDestroyShaderModule(m_device, imageFrag, nullptr);
    return ok;
}

void VulkanRenderer::destroyImagePipeline()
{
    if (m_imagePipeline) {
        vkDestroyPipeline(m_device, m_imagePipeline, nullptr);
        m_imagePipeline = VK_NULL_HANDLE;
    }
    if (m_imageBackgroundPool) {
        vkDestroyDescriptorPool(m_device, m_imageBackgroundPool, nullptr);
        m_imageBackgroundPool = VK_NULL_HANDLE;
        m_imageBackgroundSet = VK_NULL_HANDLE;
        m_imageBackgroundWritten = false;
    }
    if (m_imagePipelineLayout) {
        vkDestroyPipelineLayout(m_device, m_imagePipelineLayout, nullptr);
        m_imagePipelineLayout = VK_NULL_HANDLE;
    }
    if (m_imageBackgroundSetLayout) {
        vkDestroyDescriptorSetLayout(m_device, m_imageBackgroundSetLayout, nullptr);
        m_imageBackgroundSetLayout = VK_NULL_HANDLE;
    }
    if (m_imageSamplerSetLayout) {
        vkDestroyDescriptorSetLayout(m_device, m_imageSamplerSetLayout, nullptr);
        m_imageSamplerSetLayout = VK_NULL_HANDLE;
    }
    if (m_imageRenderPass) {
        vkDestroyRenderPass(m_device, m_imageRenderPass, nullptr);
        m_imageRenderPass = VK_NULL_HANDLE;
    }
}

namespace {

// The background-image pass's push constants, laid out as backdrop.vert and
// backdrop.frag declare them.
struct BackdropPush {
    std::array<float, 2> viewportSize;
    std::array<float, 2> topLeft;
    std::array<float, 2> bottomRight;
    std::array<float, 2> uv0;
    std::array<float, 2> uvPerPixel;
    std::array<float, 2> textureSize;
    float opacity;
    float shouldRepeat;
};
static_assert(sizeof(BackdropPush) == 14 * sizeof(float));

} // namespace

bool VulkanRenderer::ensureBackdropPipeline()
{
    if (m_backdropPipeline != VK_NULL_HANDLE)
        return true;
    if (!ensureImagePipeline())
        return false;

    // Core's transfer tables, the numbers the CPU composite reads, in one
    // host-visible buffer the shader indexes.
    const Rendering::SRGBTransferTables& tables = Rendering::srgbTransferTables();
    constexpr VkDeviceSize transferSize = sizeof(float) * (256 + 255 + 256);
    VkBufferCreateInfo bufferInfo {};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = transferSize;
    bufferInfo.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(m_device, &bufferInfo, nullptr, &m_backdropTransferBuffer) != VK_SUCCESS)
        return false;
    VkMemoryRequirements requirements {};
    vkGetBufferMemoryRequirements(m_device, m_backdropTransferBuffer, &requirements);
    VkMemoryAllocateInfo allocation {};
    allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = findMemoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (allocation.memoryTypeIndex == UINT32_MAX
        || vkAllocateMemory(m_device, &allocation, nullptr, &m_backdropTransferMemory) != VK_SUCCESS
        || vkBindBufferMemory(m_device, m_backdropTransferBuffer, m_backdropTransferMemory, 0) != VK_SUCCESS)
        return false;
    void* mapped = nullptr;
    if (vkMapMemory(m_device, m_backdropTransferMemory, 0, transferSize, 0, &mapped) != VK_SUCCESS)
        return false;
    std::memcpy(mapped, tables.decoded.data(), sizeof(float) * tables.decoded.size());
    std::memcpy(static_cast<std::uint8_t*>(mapped) + sizeof(float) * tables.decoded.size(), tables.codeBoundaries.data(),
        sizeof(float) * tables.codeBoundaries.size());
    std::memcpy(static_cast<std::uint8_t*>(mapped) + sizeof(float) * (tables.decoded.size() + tables.codeBoundaries.size()),
        tables.fractions.data(), sizeof(float) * tables.fractions.size());
    vkUnmapMemory(m_device, m_backdropTransferMemory);

    VkDescriptorSetLayoutBinding transferBinding {};
    transferBinding.binding = 0;
    transferBinding.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    transferBinding.descriptorCount = 1;
    transferBinding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo transferLayoutInfo {};
    transferLayoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    transferLayoutInfo.bindingCount = 1;
    transferLayoutInfo.pBindings = &transferBinding;
    if (vkCreateDescriptorSetLayout(m_device, &transferLayoutInfo, nullptr, &m_backdropTransferSetLayout) != VK_SUCCESS)
        return false;
    VkDescriptorPoolSize poolSize {};
    poolSize.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    poolSize.descriptorCount = 1;
    VkDescriptorPoolCreateInfo poolInfo {};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.maxSets = 1;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    if (vkCreateDescriptorPool(m_device, &poolInfo, nullptr, &m_backdropTransferPool) != VK_SUCCESS)
        return false;
    VkDescriptorSetAllocateInfo setAllocation {};
    setAllocation.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    setAllocation.descriptorPool = m_backdropTransferPool;
    setAllocation.descriptorSetCount = 1;
    setAllocation.pSetLayouts = &m_backdropTransferSetLayout;
    if (vkAllocateDescriptorSets(m_device, &setAllocation, &m_backdropTransferSet) != VK_SUCCESS)
        return false;
    VkDescriptorBufferInfo transferInfo {};
    transferInfo.buffer = m_backdropTransferBuffer;
    transferInfo.range = transferSize;
    VkWriteDescriptorSet write {};
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = m_backdropTransferSet;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    write.pBufferInfo = &transferInfo;
    vkUpdateDescriptorSets(m_device, 1, &write, 0, nullptr);

    VkPushConstantRange pushRange {};
    pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    pushRange.size = sizeof(BackdropPush);
    const VkDescriptorSetLayout setLayouts[3] = { m_imageSamplerSetLayout, m_imageBackgroundSetLayout, m_backdropTransferSetLayout };
    VkPipelineLayoutCreateInfo layoutInfo {};
    layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layoutInfo.setLayoutCount = 3;
    layoutInfo.pSetLayouts = setLayouts;
    layoutInfo.pushConstantRangeCount = 1;
    layoutInfo.pPushConstantRanges = &pushRange;
    if (vkCreatePipelineLayout(m_device, &layoutInfo, nullptr, &m_backdropPipelineLayout) != VK_SUCCESS)
        return false;

    VkShaderModule vertex = loadShader("backdrop.vert.spv");
    VkShaderModule fragment = loadShader("backdrop.frag.spv");
    bool ok = vertex && fragment;
    if (ok) {
        VkPipelineShaderStageCreateInfo stages[2] {};
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vertex;
        stages[0].pName = "main";
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = fragment;
        stages[1].pName = "main";
        // The quad's corners come from the push constants; no vertex buffer.
        VkPipelineVertexInputStateCreateInfo vertexInput {};
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        VkPipelineInputAssemblyStateCreateInfo inputAssembly {};
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkPipelineViewportStateCreateInfo viewportState {};
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;
        VkPipelineRasterizationStateCreateInfo raster {};
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample {};
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        // The shader composites against the frame it reads and writes the
        // result, so fixed-function blending is off, as for the image pass.
        VkPipelineColorBlendAttachmentState blendAttachment {};
        blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        blendAttachment.blendEnable = VK_FALSE;
        VkPipelineColorBlendStateCreateInfo colorBlend {};
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blendAttachment;
        const VkDynamicState dynamics[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkPipelineDynamicStateCreateInfo dynamicState {};
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates = dynamics;
        VkGraphicsPipelineCreateInfo pipelineInfo {};
        pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipelineInfo.stageCount = 2;
        pipelineInfo.pStages = stages;
        pipelineInfo.pVertexInputState = &vertexInput;
        pipelineInfo.pInputAssemblyState = &inputAssembly;
        pipelineInfo.pViewportState = &viewportState;
        pipelineInfo.pRasterizationState = &raster;
        pipelineInfo.pMultisampleState = &multisample;
        pipelineInfo.pColorBlendState = &colorBlend;
        pipelineInfo.pDynamicState = &dynamicState;
        pipelineInfo.layout = m_backdropPipelineLayout;
        pipelineInfo.renderPass = m_imageRenderPass;
        pipelineInfo.subpass = 0;
        ok = vkCreateGraphicsPipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &m_backdropPipeline) == VK_SUCCESS;
    }
    if (vertex)
        vkDestroyShaderModule(m_device, vertex, nullptr);
    if (fragment)
        vkDestroyShaderModule(m_device, fragment, nullptr);
    return ok;
}

void VulkanRenderer::destroyBackdropPipeline()
{
    if (m_backdropPipeline) {
        vkDestroyPipeline(m_device, m_backdropPipeline, nullptr);
        m_backdropPipeline = VK_NULL_HANDLE;
    }
    if (m_backdropPipelineLayout) {
        vkDestroyPipelineLayout(m_device, m_backdropPipelineLayout, nullptr);
        m_backdropPipelineLayout = VK_NULL_HANDLE;
    }
    if (m_backdropTransferPool) {
        vkDestroyDescriptorPool(m_device, m_backdropTransferPool, nullptr);
        m_backdropTransferPool = VK_NULL_HANDLE;
        m_backdropTransferSet = VK_NULL_HANDLE;
    }
    if (m_backdropTransferSetLayout) {
        vkDestroyDescriptorSetLayout(m_device, m_backdropTransferSetLayout, nullptr);
        m_backdropTransferSetLayout = VK_NULL_HANDLE;
    }
    if (m_backdropTransferBuffer) {
        vkDestroyBuffer(m_device, m_backdropTransferBuffer, nullptr);
        m_backdropTransferBuffer = VK_NULL_HANDLE;
    }
    if (m_backdropTransferMemory) {
        vkFreeMemory(m_device, m_backdropTransferMemory, nullptr);
        m_backdropTransferMemory = VK_NULL_HANDLE;
    }
}

bool VulkanRenderer::ensureOverlayPipeline()
{
    if (m_overlayBlendPipeline != VK_NULL_HANDLE)
        return true;
    // Reuse the image pass's render pass (the input-attachment background) +
    // its background set layout (set 0 = the grid result read via subpassLoad).
    if (!ensureImagePipeline())
        return false;

    // Pipeline layout: set 0 = the input-attachment background; the same
    // vertex push constants ({ vec2 viewportSize; vec2 cellSize; }) as the grid.
    VkPushConstantRange pushRange {};
    pushRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pushRange.offset = 0;
    pushRange.size = sizeof(float) * 8;
    VkPipelineLayoutCreateInfo plInfo {};
    plInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plInfo.setLayoutCount = 1;
    plInfo.pSetLayouts = &m_imageBackgroundSetLayout;
    plInfo.pushConstantRangeCount = 1;
    plInfo.pPushConstantRanges = &pushRange;
    if (vkCreatePipelineLayout(m_device, &plInfo, nullptr, &m_overlayBlendPipelineLayout) != VK_SUCCESS)
        return false;

    VkShaderModule overlayVert = loadShader("overlay.vert.spv");
    VkShaderModule overlayFrag = loadShader("overlay.frag.spv");
    bool ok = overlayVert && overlayFrag;
    if (ok) {
        VkPipelineShaderStageCreateInfo stages[2] {};
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = overlayVert;
        stages[0].pName = "main";
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = overlayFrag;
        stages[1].pName = "main";

        // OverlayInstance per-instance attributes — the rect, the color,
        // strokeWidth for the hollow case and the corner pair that rounds a
        // highlight pill (shadeDensity / shapeKind / plA / plB are 0 this
        // stage and unused).
        const VkVertexInputAttributeDescription overlayAttributes[] = {
            { 0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::OverlayInstance, topLeftInPixels) },
            { 1, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Rendering::OverlayInstance, bottomRightInPixels) },
            { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, color) },
            { 3, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, cornerRadius) },
            { 4, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, strokeWidth) },
            { 5, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, cornerStyle) },
            { 6, 0, VK_FORMAT_R32_SFLOAT, offsetof(Rendering::OverlayInstance, shapeKind) },
            { 7, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, plA) },
            { 8, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Rendering::OverlayInstance, plB) },
        };
        VkVertexInputBindingDescription bindingDesc {};
        bindingDesc.binding = 0;
        bindingDesc.stride = sizeof(Rendering::OverlayInstance);
        bindingDesc.inputRate = VK_VERTEX_INPUT_RATE_INSTANCE;
        VkPipelineVertexInputStateCreateInfo vertexInput {};
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &bindingDesc;
        vertexInput.vertexAttributeDescriptionCount = static_cast<uint32_t>(sizeof(overlayAttributes) / sizeof(overlayAttributes[0]));
        vertexInput.pVertexAttributeDescriptions = overlayAttributes;

        VkPipelineInputAssemblyStateCreateInfo inputAssembly {};
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkPipelineViewportStateCreateInfo viewportState {};
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;

        VkPipelineRasterizationStateCreateInfo raster {};
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;

        VkPipelineMultisampleStateCreateInfo multisample {};
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        // The shader does the over-blend itself (integer domain) and writes the
        // final color, so fixed-function blending is OFF — like the image pass.
        VkPipelineColorBlendAttachmentState blendAttachment {};
        blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        blendAttachment.blendEnable = VK_FALSE;
        VkPipelineColorBlendStateCreateInfo colorBlend {};
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blendAttachment;

        const VkDynamicState dynamics[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkPipelineDynamicStateCreateInfo dynamicState {};
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates = dynamics;

        VkGraphicsPipelineCreateInfo pipelineInfo {};
        pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipelineInfo.stageCount = 2;
        pipelineInfo.pStages = stages;
        pipelineInfo.pVertexInputState = &vertexInput;
        pipelineInfo.pInputAssemblyState = &inputAssembly;
        pipelineInfo.pViewportState = &viewportState;
        pipelineInfo.pRasterizationState = &raster;
        pipelineInfo.pMultisampleState = &multisample;
        pipelineInfo.pColorBlendState = &colorBlend;
        pipelineInfo.pDynamicState = &dynamicState;
        pipelineInfo.layout = m_overlayBlendPipelineLayout;
        pipelineInfo.renderPass = m_imageRenderPass;
        pipelineInfo.subpass = 0;
        ok = vkCreateGraphicsPipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &m_overlayBlendPipeline) == VK_SUCCESS;
    }

    if (overlayVert)
        vkDestroyShaderModule(m_device, overlayVert, nullptr);
    if (overlayFrag)
        vkDestroyShaderModule(m_device, overlayFrag, nullptr);
    return ok;
}

void VulkanRenderer::destroyOverlayPipeline()
{
    if (m_overlayBlendPipeline) {
        vkDestroyPipeline(m_device, m_overlayBlendPipeline, nullptr);
        m_overlayBlendPipeline = VK_NULL_HANDLE;
    }
    if (m_overlayBlendPipelineLayout) {
        vkDestroyPipelineLayout(m_device, m_overlayBlendPipelineLayout, nullptr);
        m_overlayBlendPipelineLayout = VK_NULL_HANDLE;
    }
}

void VulkanRenderer::destroyImageInstanceBuffer()
{
    if (m_imageInstanceBuffer) {
        vkDestroyBuffer(m_device, m_imageInstanceBuffer, nullptr);
        m_imageInstanceBuffer = VK_NULL_HANDLE;
    }
    if (m_imageInstanceBufferMemory) {
        vkFreeMemory(m_device, m_imageInstanceBufferMemory, nullptr);
        m_imageInstanceBufferMemory = VK_NULL_HANDLE;
    }
    m_imageInstanceCapacity = 0;
}

bool VulkanRenderer::ensureImageInstanceBuffer(std::size_t instanceCount)
{
    if (instanceCount <= m_imageInstanceCapacity && m_imageInstanceBuffer != VK_NULL_HANDLE)
        return true;
    destroyImageInstanceBuffer();
    const std::size_t bytes = instanceCount * sizeof(ImageInstance);
    VkBufferCreateInfo info {};
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = bytes;
    info.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(m_device, &info, nullptr, &m_imageInstanceBuffer) != VK_SUCCESS)
        return false;
    VkMemoryRequirements req {};
    vkGetBufferMemoryRequirements(m_device, m_imageInstanceBuffer, &req);
    VkMemoryAllocateInfo alloc {};
    alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (alloc.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(m_device, &alloc, nullptr, &m_imageInstanceBufferMemory) != VK_SUCCESS)
        return false;
    if (vkBindBufferMemory(m_device, m_imageInstanceBuffer, m_imageInstanceBufferMemory, 0) != VK_SUCCESS)
        return false;
    m_imageInstanceCapacity = instanceCount;
    return true;
}

std::uint32_t VulkanRenderer::lastFrameStretchedProportionalInstanceCount() const
{
    const auto stretchedIn = [](const void* mapped, std::uint32_t count) {
        std::uint32_t stretched = 0;
        const auto* instances = static_cast<const Rendering::GlyphInstance*>(mapped);
        for (std::uint32_t index = 0; mapped && index < count; ++index) {
            const Rendering::GlyphInstance& instance = instances[index];
            stretched += instance.sizeInPixels.x > 1.5f * (instance.atlasBottomRight.x - instance.atlasTopLeft.x);
        }
        return stretched;
    };
    return stretchedIn(m_proportionalMapped, m_lastFrameProportionalInstances)
        + stretchedIn(m_proportionalStripMapped, m_lastFrameProportionalStripInstances);
}

std::uint32_t VulkanRenderer::lastFrameScaledGlyphInstanceCount() const
{
    const auto* instances = static_cast<const Rendering::GlyphInstance*>(m_glyphMapped);
    std::uint32_t scaled = 0;
    for (std::uint32_t index = 0; instances && index < m_lastFrameGlyphInstances; ++index) {
        const Rendering::GlyphInstance& instance = instances[index];
        const float sourceWidth = instance.atlasBottomRight.x - instance.atlasTopLeft.x;
        const float sourceHeight = instance.atlasBottomRight.y - instance.atlasTopLeft.y;
        scaled += std::fabs(sourceWidth - instance.sizeInPixels.x) >= 0.001f
            || std::fabs(sourceHeight - instance.sizeInPixels.y) >= 0.001f;
    }
    return scaled;
}

bool VulkanRenderer::renderGrid(RasterContext& rasterContext, Ubiquitty::Terminal* term, std::vector<uint8_t>& out, int& widthOut, int& heightOut, int viewOffset, Ubiquitty::Selection::Session* selection, const CursorOverlay* cursor, uint32_t blinkTicks, ModelCaptureHandoff handoff)
{
    m_didDeclineOversizedGrid = false;
    if (!term)
        return false;
    const int columns = term->columns;
    const int rows = term->rows;
    if (columns <= 0 || rows <= 0)
        return false;

    VkPhysicalDeviceProperties physicalProperties {};
    vkGetPhysicalDeviceProperties(m_physical, &physicalProperties);
    const int maxTextureDimension = static_cast<int>(physicalProperties.limits.maxImageDimension2D);

    // The frame is the model's grid at this cell, and the model's grid can
    // outgrow the window: DECSLPP and DECSNLS set it to the page length a
    // program names, a remote owner sizes it to a window elsewhere, and a large
    // font multiplies either. Past the device's limits the target is invalid
    // usage a driver need not report, so such a grid is declined before an
    // image is made at its extent and, once an atlas stands, before the atlas
    // is recut for its cell count. It is declined ahead of the capture, so a
    // caller holding the model for this frame still holds it to draw the frame
    // another way.
    const auto declineOversizedGrid = [&] {
        m_didDeclineOversizedGrid = true;
        // The frame is drawn elsewhere, so the export asked of it is not owed:
        // left standing, it would carry to the next frame, which may need its
        // pixels on the host.
        m_isExportRequested = false;
        const ImageExtent declined { static_cast<uint32_t>(columns) * static_cast<uint32_t>(m_cellWidth),
            static_cast<uint32_t>(rows) * static_cast<uint32_t>(m_cellHeight) };
        if (declined != m_lastDeclinedExtent) {
            m_lastDeclinedExtent = declined;
            PAL::logLine(stderr, "vulkan: declined a {}x{} grid: its {}x{} frame is past this device's {}x{}",
                columns, rows, declined.width, declined.height, m_maxTargetExtent.width, m_maxTargetExtent.height);
        }
        return false;
    };
    // The cell is the atlas's: with no atlas yet, the check after it is cut
    // below decides.
    if (m_atlas && !m_maxTargetExtent.containsGrid(columns, rows, m_cellWidth, m_cellHeight))
        return declineOversizedGrid();

    // A grid grown past the one the atlas was cut for has more cells than the
    // atlas has slots, and a screen of sized text there runs out of windows;
    // the atlas is rebuilt for the larger grid, once per high-water mark.
    if (m_atlas && !m_atlas->holdsScreen(columns * rows, maxTextureDimension))
        rebuildAtlas();
    // Construct the atlas lazily so an injected rasterizer is wired in; else it
    // uses its own UnifontRasterizer. Cell dims come from the atlas (font-derived,
    // or Unifont 8×16) and drive the image size / metrics / push constants below.
    if (!m_atlas) {
        // The queried limit, not the spec floor: a grid clamped to 4096 on a
        // device that allows 16384 shrinks the atlas for no reason, and one
        // built past the real limit fails image creation.
        // The grid this atlas serves, so its slot count is bounded by what one
        // frame can reference rather than by a constant. A screen cannot show
        // more distinct glyphs than it has cells.
        const int cellsInWidestScreen = columns * rows;
        if (m_injectedRasterizer)
            m_atlas.emplace(*m_injectedRasterizer, maxTextureDimension, cellsInWidestScreen);
        else
            m_atlas.emplace(fallbackCellWidth, fallbackCellHeight, maxTextureDimension, cellsInWidestScreen);
        m_cellWidth = m_atlas->cellWidth();
        m_cellHeight = m_atlas->cellHeight();
    }
    if (!m_maxTargetExtent.containsGrid(columns, rows, m_cellWidth, m_cellHeight))
        return declineOversizedGrid();
    // Beside it, over the same rasterizer, so the two sheets answer about one
    // font.
    if (!m_colorAtlas) {
        // Cut through the same helper the builder sizes the destination quad
        // with, over the same metrics it receives below — the rasterizer's own
        // floats. m_cellWidth and m_cellHeight have been through cellDimension,
        // which rounds to nearest, so a square derived from them reaches a third
        // number rather than the builder's. A slot that differs from the quad it
        // draws into resamples every colour glyph, and rounding to nearest can
        // differ upward, which is the direction that puts the master a texel
        // past the cell.
        Rendering::GlyphRasterizer& colorRasterizer = m_injectedRasterizer ? *m_injectedRasterizer : m_atlas->rasterizer();
        const auto colorMetrics = colorRasterizer.cellMetrics();
        m_colorAtlas.emplace(colorRasterizer,
            static_cast<int>(Rendering::colourGlyphSquareInPixels(colorMetrics.cellWidth, colorMetrics.cellHeight)));
    }
    // The strip sheet, over the shaping rasterizer if one was injected. Its
    // margins come from the same policy the mono atlas sized its slots with, so
    // a strip's slot and a glyph's slot are the same box: the builder maps a
    // covered cell's atlas-pixel range onto the slot linearly, and a strip sized
    // by a second rule would put the sub-slice map a fraction of a cell out on
    // every ligature.
    // Asked, and able to answer: a face with no shaper builds no sheet, so a
    // caller may inject whatever it renders with and let the capability decide.
    if (!m_ligatureSheet && m_ligatureRasterizer && m_ligatureRasterizer->hasLigatureShaping()) {
        const Rendering::GlyphSlot stripSlot = Rendering::computeGlyphSlot(m_ligatureRasterizer->glyphOverhang());
        m_ligatureSheet.emplace(m_cellWidth, m_cellHeight, stripSlot.marginInPixels.width,
            stripSlot.marginInPixels.height, m_ligatureRasterizer);
    }
    if (!m_proportionalStripSheet && m_ligatureRasterizer && m_ligatureRasterizer->hasProportionalFace()) {
        const Rendering::GlyphSlot stripSlot = Rendering::computeGlyphSlot(m_ligatureRasterizer->glyphOverhang());
        m_proportionalStripSheet.emplace(m_cellWidth, m_cellHeight, stripSlot.marginInPixels.width,
            stripSlot.marginInPixels.height, m_ligatureRasterizer);
    }
    if (!m_proportionalSheet) {
        Rendering::GlyphRasterizer& proportionalRasterizer
            = m_ligatureRasterizer && m_ligatureRasterizer->hasProportionalFace()
            ? *m_ligatureRasterizer
            : m_atlas->rasterizer();
        const Rendering::GlyphSlot proportionalSlot = Rendering::computeGlyphSlot(
            proportionalRasterizer.glyphOverhang());
        m_proportionalSheet.emplace(m_cellWidth, m_cellHeight,
            proportionalSlot.marginInPixels.width,
            proportionalSlot.marginInPixels.height, &proportionalRasterizer,
            maxTextureDimension);
    }

    const uint32_t width = static_cast<uint32_t>(columns) * m_cellWidth;
    const uint32_t height = static_cast<uint32_t>(rows) * m_cellHeight;
    // Each of these returns false with no reason of its own, and the caller
    // reports only that renderGrid failed — so a headless run says the GPU arm
    // was skipped and cannot say which resource it could not build. Named here
    // because the frame is already lost when one fires: this costs nothing on
    // the path that works.
    if (!ensureTarget(width, height)) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: renderGrid could not build the {}x{} target", width, height);
        return false;
    }
    if (!ensureGridPipelines()) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: renderGrid could not build the grid pipelines");
        return false;
    }
    if (!ensureGridTarget(width, height)) {
        Ubiquitty::PAL::logLine(stderr, "vulkan: renderGrid could not build the {}x{} grid target", width, height);
        return false;
    }
    if (!m_atlasCreated) {
        auto destroyAtlasResources = [&] {
            m_proportionalImage.destroy(m_device);
            m_proportionalStripImage.destroy(m_device);
            m_ligatureImage.destroy(m_device);
            m_colorAtlas->destroy(m_device);
            m_atlas->destroy(m_device);
        };
        if (!m_atlas->create(m_device, m_physical, m_queue, m_queueFamily, m_commandPool)) {
            destroyAtlasResources();
            return false;
        }
        if (!m_colorAtlas->create(m_device, m_physical)) {
            destroyAtlasResources();
            return false;
        }
        if (m_proportionalSheet->isUsable()
            && !m_proportionalImage.create(m_device, m_physical,
                m_proportionalSheet->widthInPixels(),
                m_proportionalSheet->heightInPixels())) {
            Ubiquitty::PAL::logLine(stderr,
                "vulkan: the proportional glyph sheet's image could not be created");
            destroyAtlasResources();
            return false;
        }
        if (m_proportionalStripSheet && m_proportionalStripSheet->isUsable()
            && !m_proportionalStripImage.create(m_device, m_physical,
                m_proportionalStripSheet->widthInPixels(),
                m_proportionalStripSheet->heightInPixels())) {
            Ubiquitty::PAL::logLine(stderr,
                "vulkan: the proportional strip sheet's image could not be created");
            destroyAtlasResources();
            return false;
        }
        if (m_ligatureSheet && m_ligatureSheet->isUsable()
            && !m_ligatureImage.create(m_device, m_physical,
                m_ligatureSheet->widthInPixels(),
                m_ligatureSheet->heightInPixels())) {
            Ubiquitty::PAL::logLine(stderr,
                "vulkan: the ligature strip sheet's image could not be created");
            destroyAtlasResources();
            return false;
        }
        m_atlasCreated = true;
    }

    // The retained snapshot: Core drains the damage and refreshes only the
    // dirty rows, so a steady frame stops paying the full row sweep the fresh
    // copy performs. Two hazards force the fresh path, both invisible to the
    // damage stream:
    //  - a live IME pre-edit or an open Beam palette: snapshotVisibleGrid
    //    composites them into the copy, and they must never enter the
    //    retained cells;
    //  - a row that may need shaping: the fresh copy is unshaped and the CPU
    //    raster — the oracle this arm is compared against — draws it that
    //    way, while the retained refresh reads shaped rows. The two reads are
    //    byte-identical only while every row is all-LTR (a plain copy plus
    //    the canonical blank). rowMayNeedShaping is a superset flag, so a
    //    false positive forfeits the reuse, never a pixel.
    // The baseline survives fresh frames untouched: nothing else drains this
    // grid, and the damage the parser queued meanwhile arrives at the next
    // drain as the dirty rows it is.
    std::vector<Ubiquitty::Cell> grid;
    // Defaults refuse reuse; a fresh-path frame never plans.
    Rendering::RetainedFramePlan framePlan;
    // Resolved once for the frame: the builder consumes it, and the tier it
    // emits for a focused block is drawn after the plan's rows.
    Rendering::CursorRenderState cursorState;
    rasterContext.fillCursorState(term, viewOffset, cursor, cursorState);
    bool shouldUseRetainedCells = term->grid != nullptr && !rasterContext.snapshotCompositesOverlay();
    for (int row = 0; shouldUseRetainedCells && row < rows; ++row)
        shouldUseRetainedCells = !Ubiquitty::Screen::rowMayNeedShaping(*term, viewOffset, row);
    const bool drawsThroughRetainedTarget = shouldUseRetainedCells && ensureRetainedGridImages(width, height);
    if (shouldUseRetainedCells) {
        // Core plans the frame whole: drain, both verdicts, the scroll
        // copies, and the baseline advance. This arm contributes one
        // render-side fact — whether its pair survived at this size.
        m_rowDirty.resize(static_cast<std::size_t>(rows));
        Rendering::RetainedFrameRequest request;
        request.rows = rows;
        request.columns = columns;
        request.viewOffset = viewOffset;
        request.isTargetMatching = drawsThroughRetainedTarget && m_hasRetainedTarget;
        request.cellHeightInPixels = static_cast<int>(m_cellHeight);
        request.textureHeightInPixels = static_cast<int>(height);
        framePlan = Rendering::planRetainedFrame(*term->grid, *term, m_retainedBaseline, request, m_rowDirty);
        m_retainedCells.resize(static_cast<std::size_t>(rows) * columns);
        m_retainedLineAttributes.resize(static_cast<std::size_t>(rows));
        m_retainedRowMarks.resize(static_cast<std::size_t>(rows));
        Rendering::refreshCapturedRows(*term, framePlan.refresh, m_retainedCells, m_retainedLineAttributes, m_retainedRowMarks);
    } else {
        rasterContext.snapshotVisibleGrid(term, viewOffset, grid);
    }
    // The builder consumes row geometry and proportional-run hints beside the
    // cells. The fresh snapshot contains only cells, while the retained path
    // stores line attributes but not row flags, so gather the missing facts
    // from the same visible rows here.
    std::vector<std::uint8_t> freshLineAttributes;
    if (!shouldUseRetainedCells) {
        freshLineAttributes.resize(static_cast<std::size_t>(rows), Ubiquitty::lineAttributeNormal);
    }
    std::vector<std::uint8_t> rowFlags(static_cast<std::size_t>(rows), 0u);
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    const int firstAbsoluteRow = history - std::clamp(viewOffset, 0, history);
    for (int row = 0; row < rows; ++row) {
        if (!shouldUseRetainedCells) {
            freshLineAttributes[static_cast<std::size_t>(row)]
                = Ubiquitty::Screen::rowLineAttribute(term, firstAbsoluteRow + row);
        }
        rowFlags[static_cast<std::size_t>(row)]
            = Ubiquitty::Screen::rowFlags(term, firstAbsoluteRow + row);
    }
    bool canReuseGridTarget = drawsThroughRetainedTarget && framePlan.shouldLoadRetainedTarget;
    const Rendering::ScrollBlitPlan& gridBlitPlan = framePlan.blitPlan;

    std::vector<Rendering::SelectionRowSpan> selectionSpans;
    selectionRowSpans(term, viewOffset, selection, selectionSpans);
    std::vector<Rendering::SelectionRowSpan> searchMatchSpans;
    Rendering::collectSearchMatchRowSpans(*term, viewOffset, searchMatchSpans);
    std::vector<Rendering::SelectionRowSpan> otherSearchMatchSpans;
    Rendering::collectOtherSearchMatchRowSpans(*term, viewOffset, otherSearchMatchSpans);
    std::vector<Rendering::SelectionRowSpan> triggerHighlightSpans;
    Rendering::collectTriggerHighlightRowSpans(*term, viewOffset, triggerHighlightSpans);
    std::vector<Rendering::SelectionRowSpan> hiliteSpans;
    Rendering::collectHiliteRegionRowSpans(*term, viewOffset, hiliteSpans);

    Rendering::BuildInputs in;
    in.cells = shouldUseRetainedCells ? m_retainedCells.data() : grid.data();
    in.lineAttributes = shouldUseRetainedCells
        ? m_retainedLineAttributes.data()
        : freshLineAttributes.data();
    in.rowFlags = rowFlags.data();
    // Only under a Load verdict: with a Clear pass every row must be built,
    // and the builder reads null as "no damage mask".
    in.dirtyRows = canReuseGridTarget ? m_rowDirty.data() : nullptr;
    // The resolver's context is the terminal the cells came from, so a cell's
    // cluster is read back from the same model that holds its base code point.
    in.clusterResolverContext = term;
    in.clusterResolver = [](const Ubiquitty::Cell* cell, std::span<std::uint32_t> codePoints, void* terminal) -> int {
        const auto* owner = static_cast<const Ubiquitty::Terminal*>(terminal);
        return Ubiquitty::cellClusterCodePoints(owner, cell, codePoints.data(), static_cast<int>(codePoints.size()));
    };
    in.rows = rows;
    in.columns = columns;
    in.palette = &term->palette;
    in.textSizeTable = &term->textSizeTable;
    in.ambiguousWidth = term->ambiguousWidth;
    in.screenReverse = Ubiquitty::isReverseVideo(term);
    const Rendering::RenderConfiguration& configuration = rasterContext.renderConfiguration();
    in.brightenBold = configuration.shouldBrightenBold;
    // The bitmap-tier flag the CPU raster takes from the same setting, so the
    // shaders quantise exactly when SoftwareRenderer does.
    in.isBitmapFace = rasterContext.embeddedBitmapScale() > 0;
    m_isBitmapTier = in.isBitmapFace;
    in.selectionSpans = selectionSpans.data();
    in.selectionSpanCount = static_cast<int>(selectionSpans.size());
    // The fill the CPU path's capture resolves: the configured selection
    // style, over the host's OSC 17 colour when it named one. This arm has no
    // platform selection colour to offer.
    const Rendering::Vec4 hostSelection { term->selectionBackgroundRed / 65535.0f, term->selectionBackgroundGreen / 65535.0f,
        term->selectionBackgroundBlue / 65535.0f, 1.0f };
    const Rendering::SelectionFill selectionFill = Rendering::resolveSelectionFill(
        configuration.selectionStyle, Rendering::Vec4 {}, term->selectionBackgroundSet ? &hostSelection : nullptr);
    in.selectionColor = selectionFill.color;
    in.isSelectionBehindText = !selectionSpans.empty() && selectionFill.isBehindText;
    // A selection behind the text is in the pair's pixels and in no cell, so
    // the rows it reaches and leaves are marked here, beside the drain's.
    if (drawsThroughRetainedTarget)
        Rendering::markBakedSelectionRows(m_bakedSelection,
            in.isSelectionBehindText ? std::span<const Rendering::SelectionRowSpan>(selectionSpans) : std::span<const Rendering::SelectionRowSpan> {},
            selectionFill.color, framePlan.damage, m_rowDirty);
    in.searchMatchSpans = searchMatchSpans.data();
    in.searchMatchSpanCount = static_cast<int>(searchMatchSpans.size());
    in.searchMatchHighlight = focusedSearchMatchHighlightColor();
    in.focusedMatchAgeSeconds = m_focusedMatchBounce.ageSeconds(Screen::ScrollSearch::activeMatchEpoch(*term), blinkTicks);
    m_focusedMatchAgeSeconds = in.focusedMatchAgeSeconds;
    in.otherSearchMatchSpans = otherSearchMatchSpans.data();
    in.otherSearchMatchSpanCount = static_cast<int>(otherSearchMatchSpans.size());
    in.triggerHighlightSpans = triggerHighlightSpans.data();
    in.triggerHighlightSpanCount = static_cast<int>(triggerHighlightSpans.size());
    in.hiliteRegionSpans = hiliteSpans.data();
    in.hiliteRegionSpanCount = static_cast<int>(hiliteSpans.size());
    in.backgroundOpacity = rasterContext.backgroundOpacity();
    in.shouldEnhanceTextContrast = configuration.shouldEnhanceTextContrast;
    // SGR 5/6 text blink through the shared cell builder + Core curve: gated on
    // hasBlinkHint; blinkTicks==0 holds blink text fully opaque.
    in.resolveBlink = term->grid != nullptr && term->grid->hasBlinkHint();
    in.blinkTicks = blinkTicks;
    // The cursor is built through the same shared fillCursorState helper the CPU
    // path uses, so both backends land identically.
    in.cursor = cursorState;

    // CellMetrics from the atlas's rasterizer — exactly as SoftwareRenderer::render
    // does (the same instance), so the decoration + glyph geometry line up.
    in.metrics = m_atlas->rasterizer().cellMetrics();
    in.glyphReferenceAdvanceInPixels = in.metrics.cellWidth;
    in.glyphReferenceLineHeightInPixels = in.metrics.cellHeight;
    in.glyphBoxWidthInPixels = static_cast<float>(m_atlas->cellWidth());
    // The CPU path reaches this through TerminalFrameInputs::capture, which this
    // one does not run. Left out, the two arms disagree about every rule the
    // configuration styles — and the oracle that compares them renders both from
    // the same face, so it reports the disagreement as a GPU fault.
    Rendering::TerminalSnapshotStyle style;
    Preferences::Effective::applyRuleSettings(style, configuration, static_cast<double>(rasterContext.deviceScale()));
    Rendering::applyRuleStyle(in.metrics, style);
    // The rest of the rule settings the CPU capture reads from the same style.
    in.drawsBrailleGrid = style.shouldDrawBrailleGrid;
    in.brailleStyle = style.brailleStyle;
    in.shadeStyle = style.shadeStyle;
    // The point space the CPU path is given through applyPointSpace: the
    // cursor's thin shapes are defined in points, and a pass that leaves these
    // at zero draws them at one pixel per point — half the width the CPU raster
    // of the same window draws at a backing scale of two.
    in.cellHeightPoints = static_cast<double>(in.metrics.cellHeight) / static_cast<double>(rasterContext.deviceScale());
    in.lineSpacingPoints = configuration.lineSpacingPoints;
    in.toolkitCaret = rasterContext.toolkitCaret();

    // Subpixel overflow pass: route mono glyphs with ink past the cell box through
    // the glyph pass with margins so they render uncropped. The same margins the
    // atlas slot was sized to (computeGlyphSlot over the rasterizer's overhang).
    // Zero overhang (Unifont) ⇒ off (cell-baked path). The CPU path computes the
    // identical fields over the same rasterizer.
    const Rendering::GlyphSlot glyphSlot = Rendering::computeGlyphSlot(m_atlas->rasterizer().glyphOverhang());
    in.subpixelGlyphs = glyphSlot.marginInPixels.width > 0 || glyphSlot.marginInPixels.height > 0;
    in.glyphMarginInPixels.width = static_cast<float>(glyphSlot.marginInPixels.width);
    in.glyphMarginInPixels.height = static_cast<float>(glyphSlot.marginInPixels.height);
    in.glyphSlotWidthInPixels = static_cast<float>(m_atlas->cellWidth() + 2 * glyphSlot.marginInPixels.width);
    in.glyphSlotHeightInPixels = static_cast<float>(m_atlas->cellHeight() + 2 * glyphSlot.marginInPixels.height);

    // One cell over the grid: the cursor tier repeats the cursor's cell at the
    // tail of every stream (InstanceCounts::cursorTier), and every capacity
    // below is a multiple of this one, so the tier's ink and rules ride along.
    // Sized to the grid alone, the tail is the one instance that does not fit,
    // and the draw clamps to capacity — a focused block that is silently not
    // drawn on exactly the grids that fill their buffer.
    // One more a row as well: a row laid out as letters (LetterLayout.h)
    // paints the pane past its last cell with a quad of its own.
    const std::size_t cellCapacity = static_cast<std::size_t>(rows) * columns + 1 + static_cast<std::size_t>(rows);
    const std::size_t glyphCapacity = cellCapacity; // up to one overflow glyph / cell
    const std::size_t decorationCapacity = cellCapacity * 8; // up to ~8 rules / cell
    // Overlays: the cursor (1) plus up to one translucent selection quad per row.
    const std::size_t overlayCapacity = Rendering::maxOverlaysForRows(rows, otherSearchMatchSpans.size(), triggerHighlightSpans.size(), hiliteSpans.size());
    // One colour glyph per cell at most: an emoji spans two columns, so a screen
    // of them fills half the cells, and sizing to the cell count is the bound
    // that cannot be exceeded rather than the one that is usually right.
    const std::size_t colorCapacity = m_colorAtlas->hasColorSource() ? cellCapacity : 0;
    // One strip slice per covered cell at most, so the cell count bounds it for
    // the same reason the colour stream's does.
    const bool canShapeLigatures = m_ligatureSheet && m_ligatureSheet->isUsable();
    const std::size_t ligatureCapacity = canShapeLigatures ? cellCapacity : 0;
    const bool canShapeProportional = m_proportionalSheet
        && m_proportionalSheet->isUsable();
    const bool canShapeProportionalStrips = m_proportionalStripSheet
        && m_proportionalStripSheet->isUsable()
        && m_proportionalStripSheet->hasProportionalFace();
    const std::size_t proportionalCapacity = canShapeProportional
        ? cellCapacity
        : 0;
    const std::size_t proportionalStripCapacity = canShapeProportionalStrips
        ? cellCapacity
        : 0;
    // One wide glyph per cell bounds the stream, as it bounds the colour one.
    const std::size_t wideCapacity = cellCapacity;
    // A box cell decomposes into several quads; the builder reports the count
    // it needed and the frame regrows below, as the software renderer does.
    const std::size_t boxFillCapacity = cellCapacity;
    if (!ensureInstanceBuffers(cellCapacity, glyphCapacity,
            proportionalCapacity, proportionalStripCapacity, decorationCapacity, overlayCapacity,
            colorCapacity, ligatureCapacity, wideCapacity, std::max(boxFillCapacity, m_boxFillCapacity))) {
        return false;
    }

    if (!m_cellMapped || !m_glyphMapped || !m_decorationMapped
        || !m_overlayMapped || !m_boxFillMapped) {
        return false;
    }

    m_atlas->setColorAtlas(&*m_colorAtlas);
    m_atlas->setProportionalSheet(canShapeProportional
            ? &*m_proportionalSheet
            : nullptr);
    m_atlas->setProportionalStripSheet(canShapeProportionalStrips
            ? &*m_proportionalStripSheet
            : nullptr);
    m_atlas->setLigatureSheet(canShapeLigatures ? &*m_ligatureSheet : nullptr);
    const Rendering::GlyphBackend backend = m_atlas->glyphBackend();

    auto buildFrame = [&] {
        Rendering::InstanceBuffers buffers;
        buffers.cells = static_cast<Rendering::CellInstance*>(m_cellMapped);
        buffers.cellCapacity = m_cellCapacity;
        buffers.glyphs = static_cast<Rendering::GlyphInstance*>(m_glyphMapped);
        buffers.glyphCapacity = m_glyphCapacity;
        buffers.proportionalGlyphs = canShapeProportional
            ? static_cast<Rendering::GlyphInstance*>(m_proportionalMapped)
            : nullptr;
        buffers.proportionalGlyphCapacity = canShapeProportional
            ? m_proportionalCapacity
            : 0;
        buffers.proportionalStrips = canShapeProportionalStrips
            ? static_cast<Rendering::GlyphInstance*>(m_proportionalStripMapped)
            : nullptr;
        buffers.proportionalStripCapacity = canShapeProportionalStrips
            ? m_proportionalStripCapacity
            : 0;
        buffers.decorations = static_cast<Rendering::DecorationInstance*>(
            m_decorationMapped);
        buffers.decorationCapacity = m_decorationCapacity;
        buffers.overlays = static_cast<Rendering::OverlayInstance*>(m_overlayMapped);
        buffers.overlayCapacity = m_overlayCapacity;
        buffers.colorGlyphs = m_colorCapacity > 0
            ? static_cast<Rendering::GlyphInstance*>(m_colorMapped)
            : nullptr;
        buffers.colorGlyphCapacity = buffers.colorGlyphs ? m_colorCapacity : 0;
        buffers.ligatureGlyphs = canShapeLigatures
            ? static_cast<Rendering::GlyphInstance*>(m_ligatureMapped)
            : nullptr;
        buffers.ligatureGlyphCapacity = buffers.ligatureGlyphs
            ? m_ligatureCapacity
            : 0;
        buffers.wideGlyphs = static_cast<Rendering::GlyphInstance*>(m_wideMapped);
        buffers.wideGlyphCapacity = m_wideCapacity;
        buffers.boxFills = static_cast<Rendering::OverlayInstance*>(m_boxFillMapped);
        buffers.boxFillCapacity = m_boxFillCapacity;
        buffers.rowInkCrossings = m_rowInkCrossings.data();
        buffers.rowInkCrossingCapacity = m_rowInkCrossings.size();
        buffers.letters = m_letters.data();
        buffers.letterCapacity = m_letters.size();
        buffers.letterRows = m_letterRows.data();
        buffers.letterRowCapacity = m_letterRows.size();
        return Rendering::buildCellInstances(in, backend, buffers);
    };
    m_rowInkCrossings.assign(static_cast<std::size_t>(rows) + 1, 0);
    // The letters persist across frames, so a row a damage-first build keeps
    // keeps its layout; a grid of another shape starts them over.
    {
        const std::size_t letterCount = static_cast<std::size_t>(rows) * static_cast<std::size_t>(in.columns);
        if (m_letters.size() != letterCount || m_letterRows.size() != static_cast<std::size_t>(rows)) {
            m_letters.assign(letterCount, Rendering::LetterExtent {});
            m_letterRows.assign(static_cast<std::size_t>(rows), 0u);
        }
        m_letterColumns = in.columns;
    }
    Rendering::InstanceCounts counts;
    const auto buildFrameWithRoom = [&] {
        counts = buildFrame();
        if (counts.proportionalGlyphs > m_proportionalCapacity
            || counts.proportionalStrips > m_proportionalStripCapacity
            || counts.ligatureGlyphs > m_ligatureCapacity
            || counts.wideGlyphs > m_wideCapacity
            || counts.boxFills > m_boxFillCapacity) {
            if (!ensureInstanceBuffers(cellCapacity, glyphCapacity,
                    std::max(counts.proportionalGlyphs, m_proportionalCapacity),
                    std::max(counts.proportionalStrips, m_proportionalStripCapacity), decorationCapacity, overlayCapacity,
                    colorCapacity, std::max(counts.ligatureGlyphs, m_ligatureCapacity), std::max(counts.wideGlyphs, m_wideCapacity),
                    std::max(counts.boxFills, m_boxFillCapacity))) {
                return false;
            }
            counts = buildFrame();
        }
        return true;
    };
    if (!buildFrameWithRoom())
        return false;
    // Ink a glyph carries across a row edge is drawn by neither row's repaint
    // alone, so a partial frame that borders a crossing, in the pair or in this
    // build, is built again over every row and Clears the pair. This atlas
    // measures a glyph's ink as it rasterises it, so the crossings are the
    // ink's. A frame that built every row into the pair records the crossings
    // the pair now holds.
    if (canReuseGridTarget
        && !Rendering::settleRowInkCrossings(m_rowDirty, m_targetRowInkCrossings, m_rowInkCrossings,
            framePlan.damage.scrollTop, framePlan.damage.scrollBottom, framePlan.damage.scrollDelta)) {
        canReuseGridTarget = false;
        in.dirtyRows = nullptr;
        if (!buildFrameWithRoom())
            return false;
    }
    // The frame's pictures, resolved and uploaded while the caller still holds
    // the model: a placeholder reads its marks through the cluster store, and
    // the textures copy the image table's own pixels. The quads are what
    // SoftwareRenderer::resolveImageQuads resolves: the placements through the
    // shared helper (origin 0,0, the renderer's cell, this viewOffset), then a
    // quad for each placeholder cell this frame captured, in the capacity the
    // capture and the macOS arm resolve into, ordered once with a STABLE sort
    // (ties keep resolve order). The instances before `imageUnderCount` draw
    // beneath the text and the rest over it; no instance means no image pass.
    Image::ImageQuad quads[Image::maxTerminalImagePlacementCount];
    const int imageCount = Image::maxTerminalImageCount; // the Terminal's image table is a fixed-size array
    const std::span<const Image::TerminalImage> storedImages { term->images.stored.data(), static_cast<std::size_t>(imageCount) };
    const FloatSize imageCell { static_cast<float>(m_cellWidth), static_cast<float>(m_cellHeight) };
    int quadCount = Ubiquitty::Image::resolveImagePlacements(storedImages,
        { term->images.placements.data(), Image::maxTerminalImagePlacementCount },
        { columns, rows }, imageCell,
        /*origin=*/ {}, viewOffset, quads, /*fitOptions=*/ {},
        term->screens.isUsingAlternateScreen);
    if (quadCount < Image::maxTerminalImagePlacementCount) {
        const Kitty::PlaceholderGrid placeholderGrid {
            .cells = { in.cells, static_cast<std::size_t>(rows) * static_cast<std::size_t>(columns) },
            .size = { columns, rows },
            .readCluster = in.clusterResolver,
            .readClusterContext = in.clusterResolverContext,
        };
        quadCount += Kitty::resolvePlaceholders(placeholderGrid, storedImages, imageCell, /*origin=*/ {},
            std::span { quads }.subspan(static_cast<std::size_t>(quadCount)));
    }

    std::vector<ImageInstance> imageInstances;
    std::vector<uint32_t> imageDrawIDs; // imageID per instance (for the per-draw texture bind)
    std::size_t imageUnderCount = 0;
    if (quadCount > 0) {
        // The split is counted below in instances rather than taken from the
        // order: a quad whose texture is missing drops out of the instances.
        (void)Ubiquitty::Image::orderImageQuadsForDrawing({ quads, static_cast<std::size_t>(quadCount) });

        if (!ensureImagePipeline())
            return false;
        if (!m_imageTexturesCreated) {
            if (!m_imageTextures.create(m_device, m_physical, m_queue, m_queueFamily, m_commandPool, m_imageSamplerSetLayout))
                return false;
            m_imageTexturesCreated = true;
        }
        // This frame's own submit is the last thing renderGrid does, and it
        // waits on the queue before returning, so nothing is executing here.
        // The eviction can destroy at once rather than idling the device to
        // find out.
        std::array<std::uint32_t, Image::maxTerminalImagePlacementCount> filteredImageIDs {};
        std::size_t filteredCount = 0;
        for (int i = 0; i < quadCount; ++i) {
            if (quads[i].filter == Image::ImageFilter::Smooth)
                filteredImageIDs[filteredCount++] = quads[i].imageID;
        }
        if (!m_imageTextures.sync(m_device, m_physical, m_queue, m_commandPool, term->images.stored.data(), imageCount,
                VulkanImageTextures::QueueState::Idle, { filteredImageIDs.data(), filteredCount }))
            return false;

        imageInstances.reserve(static_cast<std::size_t>(quadCount));
        imageDrawIDs.reserve(static_cast<std::size_t>(quadCount));
        for (int i = 0; i < quadCount; ++i) {
            const Image::ImageQuad& q = quads[i];
            // Skip a quad whose source texture failed to upload (no descriptor).
            if (m_imageTextures.descriptorFor(q.imageID) == VK_NULL_HANDLE)
                continue;
            // Look up the source image's pixel size for the texel math.
            int srcImageWidth = 0;
            int srcImageHeight = 0;
            for (int ii = 0; ii < imageCount; ++ii) {
                const Ubiquitty::Image::TerminalImage& candidate = term->images.stored[static_cast<std::size_t>(ii)];
                if (candidate.used && candidate.imageID == q.imageID) {
                    srcImageWidth = static_cast<int>(candidate.width);
                    srcImageHeight = static_cast<int>(candidate.height);
                    break;
                }
            }
            if (srcImageWidth <= 0 || srcImageHeight <= 0)
                continue;
            ImageInstance instance;
            instance.minXInPixels = q.minXInPixels;
            instance.minYInPixels = q.minYInPixels;
            instance.maxXInPixels = q.maxXInPixels;
            instance.maxYInPixels = q.maxYInPixels;
            instance.u0 = q.u0;
            instance.v0 = q.v0;
            instance.u1 = q.u1;
            instance.v1 = q.v1;
            instance.texWidth = static_cast<float>(srcImageWidth);
            instance.texHeight = static_cast<float>(srcImageHeight);
            instance.straightAlpha = q.straightAlpha ? 1.0f : 0.0f;
            instance.filtered = q.filter == Image::ImageFilter::Smooth ? 1.0f : 0.0f;
            imageInstances.push_back(instance);
            imageDrawIDs.push_back(q.imageID);
            if (q.zIndex < 0)
                ++imageUnderCount;
        }

        if (!imageInstances.empty()) {
            if (!ensureImageInstanceBuffer(imageInstances.size()))
                return false;
            void* mappedInstances = nullptr;
            if (vkMapMemory(m_device, m_imageInstanceBufferMemory, 0, VK_WHOLE_SIZE, 0, &mappedInstances) != VK_SUCCESS)
                return false;
            std::memcpy(mappedInstances, imageInstances.data(), imageInstances.size() * sizeof(ImageInstance));
            vkUnmapMemory(m_device, m_imageInstanceBufferMemory);
            // The input-attachment background descriptor is bound below, in the
            // shared overlay + image pass setup (m_imageBackgroundWritten).
        }
    }
    const bool hasImagePass = !imageInstances.empty();
    // A picture under the text splits the grid: the cells' ground is drawn,
    // then the picture, then the ink over it on the target, so the pair keeps
    // the ground without its ink and a Load of it would lose the text. Core
    // refuses the retained target on any frame showing a picture; a partial
    // build reaching here anyway is rebuilt whole, as an ink crossing is above.
    const bool hasImagesUnderText = imageUnderCount > 0;
    if (hasImagesUnderText && canReuseGridTarget) {
        canReuseGridTarget = false;
        in.dirtyRows = nullptr;
        if (!buildFrameWithRoom())
            return false;
    }
    if (drawsThroughRetainedTarget && !canReuseGridTarget)
        m_targetRowInkCrossings = m_rowInkCrossings;
    // The builder and the image pass have read their last Terminal field: the
    // instances, the palette, the size table and the pictures they needed are
    // in the buffers and textures, and nothing below reads the model. The
    // caller's hold on it can end here.
    if (handoff.onCaptured)
        handoff.onCaptured(handoff.context);
    // The quads a draw may cover together, decided here because this is where
    // the builder has just written them and the pass records later. A barrier is
    // needed only where one quad can read what another wrote, and a selection's
    // per-row spans never can.
    {
        const std::span<const Rendering::OverlayInstance> overlays {
            static_cast<const Rendering::OverlayInstance*>(m_overlayMapped),
            counts.overlays < m_overlayCapacity ? counts.overlays : m_overlayCapacity
        };
        m_overlayRunLengths.clear();
        for (std::size_t index = 0; index < overlays.size();) {
            const std::size_t run = Rendering::disjointOverlayRun(overlays, index);
            m_overlayRunLengths.push_back(run);
            index += run;
        }
    }
    const uint32_t cellDraw = static_cast<uint32_t>(counts.cells < m_cellCapacity ? counts.cells : m_cellCapacity);
    const uint32_t glyphDraw = static_cast<uint32_t>(counts.glyphs < m_glyphCapacity ? counts.glyphs : m_glyphCapacity);
    const uint32_t proportionalDraw = static_cast<uint32_t>(counts.proportionalGlyphs < m_proportionalCapacity
            ? counts.proportionalGlyphs
            : m_proportionalCapacity);
    const uint32_t proportionalStripDraw = static_cast<uint32_t>(counts.proportionalStrips < m_proportionalStripCapacity
            ? counts.proportionalStrips
            : m_proportionalStripCapacity);
    const uint32_t decorationDraw = static_cast<uint32_t>(counts.decorations < m_decorationCapacity ? counts.decorations : m_decorationCapacity);
    const uint32_t overlayDraw = static_cast<uint32_t>(counts.overlays < m_overlayCapacity ? counts.overlays : m_overlayCapacity);
    const uint32_t colorDraw = static_cast<uint32_t>(counts.colorGlyphs < m_colorCapacity ? counts.colorGlyphs : m_colorCapacity);
    const uint32_t ligatureDraw = static_cast<uint32_t>(counts.ligatureGlyphs < m_ligatureCapacity ? counts.ligatureGlyphs : m_ligatureCapacity);
    const uint32_t wideDraw = static_cast<uint32_t>(counts.wideGlyphs < m_wideCapacity ? counts.wideGlyphs : m_wideCapacity);
    const uint32_t boxFillDraw = static_cast<uint32_t>(counts.boxFills < m_boxFillCapacity ? counts.boxFills : m_boxFillCapacity);
    // Each stream in two segments: the head, and the cursor tier at its tail
    // (CellInstanceBuilder.h, InstanceCounts::cursorTier) — the cursor's cell
    // re-emitted with the cursor's colours, built last by Core. The head is the
    // grid; the tier is drawn after the grid and the images and before the
    // overlays, whether the frame draws through the retained pair or straight
    // into the target, so the grid never carries a cursor and a blink or a
    // move owes it no row.
    struct StreamSpan {
        uint32_t first = 0;
        uint32_t count = 0;
    };
    const auto tierOf = [](uint32_t draw, std::size_t tail) {
        return static_cast<uint32_t>(std::min<std::size_t>(tail, draw));
    };
    const auto headOf = [](uint32_t draw, uint32_t tier) { return StreamSpan { 0, draw - tier }; };
    const auto tailOf = [](uint32_t draw, uint32_t tier) { return StreamSpan { draw - tier, tier }; };
    const Rendering::InstanceCounts::CursorTier& tier = counts.cursorTier;
    const uint32_t cellTier = tierOf(cellDraw, tier.cells);
    const uint32_t glyphTier = tierOf(glyphDraw, tier.glyphs);
    const uint32_t proportionalTier = tierOf(proportionalDraw, tier.proportionalGlyphs);
    const uint32_t proportionalStripTier = tierOf(proportionalStripDraw, tier.proportionalStrips);
    const uint32_t colorTier = tierOf(colorDraw, tier.colorGlyphs);
    const uint32_t ligatureTier = tierOf(ligatureDraw, tier.ligatureGlyphs);
    const uint32_t wideTier = tierOf(wideDraw, tier.wideGlyphs);
    const uint32_t boxFillTier = tierOf(boxFillDraw, tier.boxFills);
    const uint32_t decorationTier = tierOf(decorationDraw, tier.decorations);
    const bool hasCursorTier = cellTier + glyphTier + wideTier + proportionalTier + proportionalStripTier + colorTier
            + ligatureTier + decorationTier + boxFillTier
        > 0;
    m_lastFrameGlyphInstances = glyphDraw;
    m_lastFrameProportionalInstances = proportionalDraw;
    m_lastFrameProportionalStripInstances = proportionalStripDraw;
    m_lastFrameLigatureInstances = ligatureDraw;

    // Point the descriptor at the atlas (once; the atlas image/view/sampler
    // are stable for the renderer's lifetime).
    if (!m_descriptorWritten) {
        // Bindings 2, 3 and 4 start on mono and are taken over by the
        // proportional strip, ligature strip and proportional sheet resources
        // below.
        VkDescriptorImageInfo imageInfo[5] {};
        imageInfo[0].sampler = m_atlas->sampler();
        imageInfo[0].imageView = m_atlas->view();
        imageInfo[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        imageInfo[1].sampler = m_colorAtlas->sampler();
        imageInfo[1].imageView = m_colorAtlas->view();
        imageInfo[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        imageInfo[2] = imageInfo[0];
        imageInfo[3] = imageInfo[0];
        imageInfo[4] = imageInfo[0];
        VkWriteDescriptorSet writes[5] {};
        for (uint32_t i = 0; i < 5; ++i) {
            writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[i].dstSet = m_descriptorSet;
            writes[i].dstBinding = i;
            writes[i].descriptorCount = 1;
            writes[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[i].pImageInfo = &imageInfo[i];
        }
        // All in one call. A binding the layout declares and nobody writes is
        // undefined behaviour the moment any shader in the set could sample it,
        // and it costs nothing at run time until then — so it passes every check
        // right up to the frame that reads it.
        vkUpdateDescriptorSets(m_device, 5, writes, 0, nullptr);
        m_descriptorWritten = true;
    }
    // The proportional set differs from the main set only at binding 0. The
    // other declared bindings are still populated before the set is bound.
    // The sixth write points the main set's binding 4 at the proportional
    // sheet: the rule pass draws under the main set, and that is where it
    // taps the glyphs of a run drawn glyph by glyph for skip-ink.
    if (canShapeProportional && !m_isProportionalDescriptorWritten) {
        VkDescriptorImageInfo proportionalInfo[5] {};
        proportionalInfo[0].sampler = m_proportionalImage.sampler();
        proportionalInfo[0].imageView = m_proportionalImage.view();
        proportionalInfo[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        proportionalInfo[1].sampler = m_colorAtlas->sampler();
        proportionalInfo[1].imageView = m_colorAtlas->view();
        proportionalInfo[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        proportionalInfo[2] = proportionalInfo[0];
        proportionalInfo[3] = proportionalInfo[0];
        proportionalInfo[4] = proportionalInfo[0];
        VkWriteDescriptorSet proportionalWrites[6] {};
        for (uint32_t i = 0; i < 6; ++i) {
            proportionalWrites[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            proportionalWrites[i].dstSet = i < 5 ? m_proportionalDescriptorSet : m_descriptorSet;
            proportionalWrites[i].dstBinding = i < 5 ? i : 4;
            proportionalWrites[i].descriptorCount = 1;
            proportionalWrites[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            proportionalWrites[i].pImageInfo = &proportionalInfo[i < 5 ? i : 0];
        }
        vkUpdateDescriptorSets(m_device, 6, proportionalWrites, 0, nullptr);
        m_isProportionalDescriptorWritten = true;
    }
    if (canShapeProportionalStrips && !m_isProportionalStripDescriptorWritten) {
        VkDescriptorImageInfo proportionalStripInfo[5] {};
        proportionalStripInfo[0].sampler = m_proportionalStripImage.sampler();
        proportionalStripInfo[0].imageView = m_proportionalStripImage.view();
        proportionalStripInfo[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        proportionalStripInfo[1].sampler = m_colorAtlas->sampler();
        proportionalStripInfo[1].imageView = m_colorAtlas->view();
        proportionalStripInfo[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        proportionalStripInfo[2] = proportionalStripInfo[0];
        proportionalStripInfo[3] = proportionalStripInfo[0];
        proportionalStripInfo[4] = proportionalStripInfo[0];
        VkWriteDescriptorSet proportionalStripWrites[6] {};
        for (uint32_t i = 0; i < 6; ++i) {
            proportionalStripWrites[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            proportionalStripWrites[i].dstSet = i < 5 ? m_proportionalStripDescriptorSet : m_descriptorSet;
            proportionalStripWrites[i].dstBinding = i < 5 ? i : 2;
            proportionalStripWrites[i].descriptorCount = 1;
            proportionalStripWrites[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            proportionalStripWrites[i].pImageInfo = &proportionalStripInfo[i < 5 ? i : 0];
        }
        vkUpdateDescriptorSets(m_device, 6, proportionalStripWrites, 0, nullptr);
        m_isProportionalStripDescriptorWritten = true;
    }
    // The ligature set: binding 0 is the strip sheet, binding 1 the same colour
    // image the first set names, and its remaining bindings are valid strip
    // images. Binding 1
    // goes unread by the mono pipeline, and is written anyway — the layout
    // declares it, and a descriptor left unwritten in a set that is bound is
    // undefined behaviour whether or not this frame's shader happens to sample
    // it. The fifth write points the main set's binding 3 at the strip sheet:
    // the rule pass draws under the main set, and that is where it reads
    // strips for skip-ink.
    if (canShapeLigatures && !m_isLigatureDescriptorWritten) {
        VkDescriptorImageInfo ligatureInfo[5] {};
        ligatureInfo[0].sampler = m_ligatureImage.sampler();
        ligatureInfo[0].imageView = m_ligatureImage.view();
        ligatureInfo[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ligatureInfo[1].sampler = m_colorAtlas->sampler();
        ligatureInfo[1].imageView = m_colorAtlas->view();
        ligatureInfo[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ligatureInfo[2] = ligatureInfo[0];
        ligatureInfo[3] = ligatureInfo[0];
        ligatureInfo[4] = ligatureInfo[0];
        VkWriteDescriptorSet ligatureWrites[6] {};
        for (uint32_t i = 0; i < 6; ++i) {
            ligatureWrites[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            ligatureWrites[i].dstSet = i < 5 ? m_ligatureDescriptorSet : m_descriptorSet;
            ligatureWrites[i].dstBinding = i < 5 ? i : 3;
            ligatureWrites[i].descriptorCount = 1;
            ligatureWrites[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            ligatureWrites[i].pImageInfo = &ligatureInfo[i < 5 ? i : 0];
        }
        vkUpdateDescriptorSets(m_device, 6, ligatureWrites, 0, nullptr);
        m_isLigatureDescriptorWritten = true;
    }

    // The window's background image, placed by Core over the frame and
    // composited beneath it after the cursor tier, as the CPU raster does.
    // Uploaded only when the raster context's image changed.
    const Rendering::BackgroundImageLayer backdrop = rasterContext.backgroundImageLayer();
    BackdropPush backdropPush {};
    bool hasBackdropPass = false;
    if (backdrop.isVisible()) {
        const Rendering::BackgroundImagePlacement placement = Rendering::backgroundImagePlacement(backdrop.mode,
            static_cast<float>(width), static_cast<float>(height), static_cast<float>(backdrop.pixels->width), static_cast<float>(backdrop.pixels->height));
        if (placement.rightInPixels > placement.leftInPixels && placement.bottomInPixels > placement.topInPixels) {
            if (!ensureBackdropPipeline())
                return false;
            if (!m_imageTexturesCreated) {
                if (!m_imageTextures.create(m_device, m_physical, m_queue, m_queueFamily, m_commandPool, m_imageSamplerSetLayout))
                    return false;
                m_imageTexturesCreated = true;
            }
            if (!m_imageTextures.syncBackdrop(m_device, m_physical, m_queue, m_commandPool, backdrop.pixels,
                    rasterContext.backgroundImageGeneration(), VulkanImageTextures::QueueState::Idle))
                return false;
            const Rendering::BackgroundImageSampling sampling = Rendering::backgroundImageSampling(placement);
            backdropPush = BackdropPush {
                .viewportSize = { static_cast<float>(width), static_cast<float>(height) },
                .topLeft = { placement.leftInPixels, placement.topInPixels },
                .bottomRight = { placement.rightInPixels, placement.bottomInPixels },
                .uv0 = { sampling.u0, sampling.v0 },
                .uvPerPixel = { sampling.uPerPixel, sampling.vPerPixel },
                .textureSize = { static_cast<float>(backdrop.pixels->width), static_cast<float>(backdrop.pixels->height) },
                .opacity = backdrop.opacity,
                .shouldRepeat = placement.shouldRepeat ? 1.0f : 0.0f,
            };
            hasBackdropPass = m_imageTextures.backdropDescriptor() != VK_NULL_HANDLE;
        }
    }

    if (vkResetCommandBuffer(m_commandBuffer, 0) != VK_SUCCESS)
        return false;
    VkCommandBufferBeginInfo beginInfo {};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(m_commandBuffer, &beginInfo) != VK_SUCCESS)
        return false;

    // Every sheet owns its staging bytes until this frame completes. Record
    // their copies before the draw so one submission orders all uploads and
    // rendering, without a host queue wait between individual sheets.
    if (!m_atlas->recordUpload(m_device, m_commandBuffer)
        || !m_colorAtlas->recordUpload(m_device, m_commandBuffer))
        return false;
    if (canShapeProportional) {
        const Rendering::AtlasRowBand dirty = m_proportionalSheet->dirtyRows();
        if ((!m_proportionalImage.isReadable() || dirty.rowCount > 0)
            && !m_proportionalImage.recordUpload(m_device, m_commandBuffer,
                m_proportionalSheet->coverage(), dirty.firstRow, dirty.rowCount))
            return false;
    }
    if (canShapeProportionalStrips
        && (m_proportionalStripSheet->isDirty() || !m_proportionalStripImage.isReadable())
        && !m_proportionalStripImage.recordUpload(m_device, m_commandBuffer,
            m_proportionalStripSheet->coverage(), 0, m_proportionalStripSheet->heightInPixels()))
        return false;
    if (canShapeLigatures && (m_ligatureSheet->isDirty() || !m_ligatureImage.isReadable())
        && !m_ligatureImage.recordUpload(m_device, m_commandBuffer,
            m_ligatureSheet->coverage(), 0, m_ligatureSheet->heightInPixels()))
        return false;

    // A retained frame draws its grid passes into the pair, never into
    // m_image: the pair must hold the grid alone, and the overlays land on
    // the copy. The flag drops here and returns after the submit completes,
    // so a frame that fails mid-encode cannot leave a half-written target
    // for the next frame to Load.
    if (drawsThroughRetainedTarget)
        m_hasRetainedTarget = false;
    if (canReuseGridTarget && gridBlitPlan.bandCount > 0) {
        // The pending scroll, as Core laid it out: copy the surviving bands
        // from the front image to the back and swap — the same blit the
        // Swift arm runs between its texture pair. The exposed band is
        // absent from the plan by design; the drain marked it dirty and the
        // content pass repaints it.
        const int backIndex = 1 - m_gridFrontIndex;
        VkImageSubresourceRange wholeImage {};
        wholeImage.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        wholeImage.levelCount = 1;
        wholeImage.layerCount = 1;
        VkImageMemoryBarrier toDestination {};
        toDestination.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        // UNDEFINED discards: the back image is two frames stale, and every
        // byte of it is either copied over or repainted as a dirty row.
        toDestination.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        toDestination.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toDestination.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toDestination.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toDestination.image = m_gridImages[backIndex];
        toDestination.subresourceRange = wholeImage;
        toDestination.srcAccessMask = 0;
        toDestination.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toDestination);
        for (const Rendering::ScrollBlitBand& blitBand : gridBlitPlan.activeBands()) {
            VkImageCopy copy {};
            copy.srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
            copy.dstSubresource = copy.srcSubresource;
            copy.srcOffset = { 0, blitBand.sourceYInPixels, 0 };
            copy.dstOffset = { 0, blitBand.destinationYInPixels, 0 };
            copy.extent = { width, static_cast<uint32_t>(blitBand.heightInPixels), 1 };
            vkCmdCopyImage(m_commandBuffer, m_gridImages[m_gridFrontIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                m_gridImages[backIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        }
        // The Load pass declares TRANSFER_SRC on entry — where a grid pass
        // leaves its image — so the freshly written back image is returned
        // there rather than teaching the pass a second entry layout.
        VkImageMemoryBarrier toSource = toDestination;
        toSource.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toSource.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        toSource.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toSource.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr, 1, &toSource);
        m_gridFrontIndex = backIndex;
    }

    VkClearValue clear {};
    clear.color = { { 0.0f, 0.0f, 0.0f, 1.0f } }; // opaque black; the cell pass repaints every background
    VkRenderPassBeginInfo rpBegin {};
    rpBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpBegin.renderPass = canReuseGridTarget ? m_gridLoadRenderPass : m_renderPass;
    rpBegin.framebuffer = drawsThroughRetainedTarget ? m_gridFramebuffers[m_gridFrontIndex] : m_framebuffer;
    rpBegin.renderArea.extent = { width, height };
    rpBegin.clearValueCount = 1;
    rpBegin.pClearValues = &clear;
    vkCmdBeginRenderPass(m_commandBuffer, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport viewport {};
    viewport.width = static_cast<float>(width);
    viewport.height = static_cast<float>(height);
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(m_commandBuffer, 0, 1, &viewport);
    VkRect2D scissor {};
    scissor.extent = { width, height };
    vkCmdSetScissor(m_commandBuffer, 0, 1, &scissor);

    // Viewport, cell, and the bitmap flag used for glyph filtering and the
    // overlay/decoration coverage quantisation; padded to four-float rows.
    const float push[8] = { static_cast<float>(width), static_cast<float>(height), static_cast<float>(m_cellWidth), static_cast<float>(m_cellHeight),
        m_isBitmapTier ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f };
    vkCmdPushConstants(m_commandBuffer, m_pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), push);
    vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);

    const VkDeviceSize offset = 0;
    // Which half of the grid a draw of its streams paints. A frame with a
    // picture under its text draws the cells' ground, then the picture, then
    // the ink over it; every other frame draws the grid whole.
    enum class GridPaint : std::uint8_t {
        // The cells' ground and their cell-baked ink together, the glyph
        // streams mixed over each instance's cell background.
        Whole,
        // The cells' ground alone. The caller passes only the cell and box
        // spans.
        Ground,
        // The cells' cell-baked ink and every glyph stream, blended over what
        // the target holds. The caller passes no box span.
        Ink,
    };
    // The grid streams in compositing order — cells, ink, rules — for one
    // segment of each. Called once for the heads inside the grid pass, and
    // once for the cursor tier's tails in a LOAD pass over the target after
    // the images; a frame with a picture under its text draws its heads in
    // two halves around the picture.
    const auto drawGridStreams = [&](GridPaint paint, StreamSpan cells, StreamSpan boxFills, StreamSpan glyphs, StreamSpan wide, StreamSpan proportional,
                                     StreamSpan proportionalStrips, StreamSpan color, StreamSpan ligature,
                                     StreamSpan decorations) {
        VkPipeline cellPipeline = m_cellPipeline;
        if (paint == GridPaint::Ground)
            cellPipeline = m_cellGroundPipeline;
        else if (paint == GridPaint::Ink)
            cellPipeline = m_cellInkPipeline;
        const VkPipeline glyphPipeline = paint == GridPaint::Ink ? m_glyphOverTargetPipeline : m_glyphPipeline;
        if (cells.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, cellPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_cellBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, cells.count, 0, cells.first);
        }
        // The box quads directly over the cell backgrounds and under every
        // ink stream, where SoftwareRenderer composites them.
        if (boxFills.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_boxFillPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_boxFillBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, boxFills.count, 0, boxFills.first);
        }
        // Subpixel overflow glyphs over the cell backgrounds, under the
        // decorations (the macOS draw order). Shares m_pipelineLayout + the
        // atlas descriptor + push constants already bound above. Empty in
        // cell-baked mode (glyphDraw 0).
        if (glyphs.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, glyphPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_glyphBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, glyphs.count, 0, glyphs.first);
        }
        // The wide stream after the mono overflow glyphs, where the CPU
        // compositor puts it, on the same pipeline and sheet.
        if (wide.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, glyphPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_wideBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, wide.count, 0, wide.first);
        }
        // Proportional and strip streams use nearest taps across their atlas
        // rect, including double-width and double-height row geometry. Mono
        // scaled quads use the face's filtering rule instead.
        const auto pushAtlasSpread = [this](float flag) {
            vkCmdPushConstants(m_commandBuffer, m_pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, sizeof(float) * 5, sizeof(flag), &flag);
        };
        if (proportional.count > 0 || proportionalStrips.count > 0 || ligature.count > 0)
            pushAtlasSpread(1.0f);
        if (proportional.count > 0) {
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                m_pipelineLayout, 0, 1, &m_proportionalDescriptorSet, 0, nullptr);
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                glyphPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_proportionalBuffer,
                &offset);
            vkCmdDraw(m_commandBuffer, 6, proportional.count, 0, proportional.first);
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);
        }
        if (proportionalStrips.count > 0) {
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                m_pipelineLayout, 0, 1, &m_proportionalStripDescriptorSet, 0, nullptr);
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                glyphPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_proportionalStripBuffer,
                &offset);
            vkCmdDraw(m_commandBuffer, 6, proportionalStrips.count, 0, proportionalStrips.first);
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);
        }
        // Colour emoji over the mono glyphs and under the decorations, which
        // is where the CPU compositor puts them. Same layout and descriptor
        // set as the passes above; the pipeline differs in its shaders and in
        // blending against the framebuffer rather than against the instance's
        // carried background.
        if (color.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_colorPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_colorBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, color.count, 0, color.first);
        }
        // Ligature strips, on the mono pipeline over the strip sheet — the
        // macOS encoder draws them with `pipelines.glyph` and a rebound
        // texture, and this is that draw with the rebind spelled as a
        // descriptor set. Same shader, so the coverage formula the CPU oracle
        // pins is the one strips take too.
        //
        // The set is rebound to the atlas afterwards rather than before the
        // next pass, because the decoration pass below samples binding 0 for
        // skip-ink and would read strips as glyph coverage.
        if (ligature.count > 0) {
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_pipelineLayout, 0, 1, &m_ligatureDescriptorSet, 0, nullptr);
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, glyphPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_ligatureBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, ligature.count, 0, ligature.first);
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);
        }
        if (proportional.count > 0 || proportionalStrips.count > 0 || ligature.count > 0)
            pushAtlasSpread(0.0f);
        if (decorations.count > 0) {
            vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_decorationPipeline);
            vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_decorationBuffer, &offset);
            vkCmdDraw(m_commandBuffer, 6, decorations.count, 0, decorations.first);
        }
    };
    const auto drawCursorTier = [&]() {
        drawGridStreams(GridPaint::Whole, tailOf(cellDraw, cellTier), tailOf(boxFillDraw, boxFillTier), tailOf(glyphDraw, glyphTier), tailOf(wideDraw, wideTier), tailOf(proportionalDraw, proportionalTier),
            tailOf(proportionalStripDraw, proportionalStripTier), tailOf(colorDraw, colorTier),
            tailOf(ligatureDraw, ligatureTier), tailOf(decorationDraw, decorationTier));
    };
    if (hasImagesUnderText) {
        // The ground alone; the picture and the ink follow on the target.
        drawGridStreams(GridPaint::Ground, headOf(cellDraw, cellTier), headOf(boxFillDraw, boxFillTier), {}, {}, {}, {}, {}, {}, {});
    } else {
        drawGridStreams(GridPaint::Whole, headOf(cellDraw, cellTier), headOf(boxFillDraw, boxFillTier), headOf(glyphDraw, glyphTier), headOf(wideDraw, wideTier), headOf(proportionalDraw, proportionalTier),
            headOf(proportionalStripDraw, proportionalStripTier), headOf(colorDraw, colorTier),
            headOf(ligatureDraw, ligatureTier), headOf(decorationDraw, decorationTier));
    }
    vkCmdEndRenderPass(m_commandBuffer);

    if (drawsThroughRetainedTarget) {
        // One full-image copy rebuilds the composited target from the grid
        // pair — the Swift arm's fullscreen blit. m_image's previous content
        // is discarded (UNDEFINED): every byte is about to be overwritten,
        // and the overlays land on this copy, so the pair never carries a
        // cursor, a selection or an inline image.
        VkImageSubresourceRange wholeImage {};
        wholeImage.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        wholeImage.levelCount = 1;
        wholeImage.layerCount = 1;
        VkImageMemoryBarrier imageToDestination {};
        imageToDestination.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        imageToDestination.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        imageToDestination.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        imageToDestination.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        imageToDestination.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        imageToDestination.image = m_image;
        imageToDestination.subresourceRange = wholeImage;
        imageToDestination.srcAccessMask = 0;
        imageToDestination.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &imageToDestination);
        VkImageCopy copy {};
        copy.srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        copy.dstSubresource = copy.srcSubresource;
        copy.extent = { width, height, 1 };
        vkCmdCopyImage(m_commandBuffer, m_gridImages[m_gridFrontIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        // Back to TRANSFER_SRC — the state the overlay pass transitions from
        // and the host copy reads — with the destination scope wide enough
        // that the copy's write is visible to the input-attachment reads and
        // over-blends downstream, whose own barrier only covers color writes.
        VkImageMemoryBarrier imageToSource = imageToDestination;
        imageToSource.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        imageToSource.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        imageToSource.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        imageToSource.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT
            | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_INPUT_ATTACHMENT_READ_BIT;
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &imageToSource);
    }

    // Three layers over the grid result, in the CPU compositor's order: the
    // inline images, then the cursor tier, then the overlay quads. A frame
    // with a picture under its text first draws that band and the text's ink
    // over it, then the rest of the images. The images
    // and the overlays over-blend in the integer domain (shaders read the
    // target via subpassLoad), so they match the CPU path byte for byte even
    // for translucent alpha, where fixed-function blend would round
    // differently; each runs in m_imageRenderPass over m_framebuffer (LOAD
    // preserves the target), and each quad is its own draw with a by-region
    // self-dependency, so an earlier draw's blended write is visible to a
    // later draw's subpassLoad — the same sequential over-blend. The tier is
    // the LOAD twin of the grid pass, which the grid pipelines bind under
    // unchanged: it draws the cursor's cell with the cursor's colours over
    // the pictures and under the selection tint, as every other arm does.
    //
    // The grid result sits in TRANSFER_SRC between layers, which is where the
    // copy left it and where the host copy expects it. A blend layer
    // transitions it to GENERAL (color attachment and input-attachment
    // background), runs, and transitions it back; the tier pass enters and
    // leaves TRANSFER_SRC through the grid pass's own external dependencies.
    const bool hasOverlayPass = overlayDraw > 0;
    if (hasOverlayPass || hasImagePass || hasBackdropPass) {
        // ensureImagePipeline() created the render pass + background set;
        // ensureOverlayPipeline() additionally builds the overlay pipeline.
        // Both share m_imageBackgroundSet (the grid-result input attachment).
        if (hasOverlayPass) {
            if (!ensureOverlayPipeline())
                return false;
        } else if (!ensureImagePipeline()) {
            return false;
        }
        // Bind the color attachment view as the input-attachment background
        // (re-bound whenever the grid target view was recreated). Done once;
        // shared by the overlay + image draws below.
        if (!m_imageBackgroundWritten) {
            VkDescriptorImageInfo backgroundInfo {};
            backgroundInfo.imageView = m_colorView;
            backgroundInfo.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
            VkWriteDescriptorSet write {};
            write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = m_imageBackgroundSet;
            write.dstBinding = 0;
            write.descriptorCount = 1;
            write.descriptorType = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT;
            write.pImageInfo = &backgroundInfo;
            vkUpdateDescriptorSets(m_device, 1, &write, 0, nullptr);
            m_imageBackgroundWritten = true;
        }
    }
    VkImageSubresourceRange range {};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;
    VkImageMemoryBarrier toGeneral {};
    toGeneral.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toGeneral.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toGeneral.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    toGeneral.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toGeneral.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toGeneral.image = m_image;
    toGeneral.subresourceRange = range;
    toGeneral.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    toGeneral.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_INPUT_ATTACHMENT_READ_BIT;
    VkImageMemoryBarrier toTransfer {};
    toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toTransfer.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toTransfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toTransfer.image = m_image;
    toTransfer.subresourceRange = range;
    toTransfer.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    VkImageMemoryBarrier selfBarrier {};
    selfBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    selfBarrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    selfBarrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    selfBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    selfBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    selfBarrier.image = m_image;
    selfBarrier.subresourceRange = range;
    selfBarrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    selfBarrier.dstAccessMask = VK_ACCESS_INPUT_ATTACHMENT_READ_BIT;
    const auto regionBarrier = [&]() { vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_DEPENDENCY_BY_REGION_BIT, 0, nullptr, 0, nullptr, 1, &selfBarrier); };
    const auto beginBlendLayer = [&]() {
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toGeneral);
        VkRenderPassBeginInfo imageBegin {};
        imageBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        imageBegin.renderPass = m_imageRenderPass;
        imageBegin.framebuffer = m_framebuffer;
        imageBegin.renderArea.extent = { width, height };
        imageBegin.clearValueCount = 0; // LOAD_OP_LOAD — nothing to clear
        vkCmdBeginRenderPass(m_commandBuffer, &imageBegin, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(m_commandBuffer, 0, 1, &viewport);
        vkCmdSetScissor(m_commandBuffer, 0, 1, &scissor);
    };
    const auto endBlendLayer = [&]() {
        vkCmdEndRenderPass(m_commandBuffer);
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toTransfer);
    };

    // The inline images of one band, each its own draw (binding its source
    // texture in set 0) with a by-region barrier between draws so overlapping
    // z-sorted images blend in order.
    const auto drawImageBand = [&](std::size_t first, std::size_t end) {
        beginBlendLayer();
        vkCmdPushConstants(m_commandBuffer, m_imagePipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), push);
        vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_imagePipeline);
        vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_imageInstanceBuffer, &offset);
        vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_imagePipelineLayout, 1, 1, &m_imageBackgroundSet, 0, nullptr);
        for (std::size_t i = first; i < end; ++i) {
            const VkDescriptorSet sourceSet = m_imageTextures.descriptorFor(imageDrawIDs[i]);
            vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_imagePipelineLayout, 0, 1, &sourceSet, 0, nullptr);
            vkCmdDraw(m_commandBuffer, 6, 1, 0, static_cast<uint32_t>(i));
            if (i + 1 < end)
                regionBarrier();
        }
        endBlendLayer();
    };

    // The pictures under the text over the cells' ground, then the ink over
    // them: the grid pass's LOAD twin over the target, as the cursor tier is
    // drawn, with the cell-baked ink and every glyph stream blended over what
    // the target holds rather than over the cell background the picture
    // covers. The rules follow the ink, as they do in the grid pass.
    if (hasImagesUnderText) {
        drawImageBand(0, imageUnderCount);
        VkRenderPassBeginInfo inkBegin {};
        inkBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        inkBegin.renderPass = m_gridLoadRenderPass;
        inkBegin.framebuffer = m_framebuffer;
        inkBegin.renderArea.extent = { width, height };
        inkBegin.clearValueCount = 1;
        inkBegin.pClearValues = &clear;
        vkCmdBeginRenderPass(m_commandBuffer, &inkBegin, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(m_commandBuffer, 0, 1, &viewport);
        vkCmdSetScissor(m_commandBuffer, 0, 1, &scissor);
        vkCmdPushConstants(m_commandBuffer, m_pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), push);
        vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);
        drawGridStreams(GridPaint::Ink, headOf(cellDraw, cellTier), {}, headOf(glyphDraw, glyphTier), headOf(wideDraw, wideTier), headOf(proportionalDraw, proportionalTier),
            headOf(proportionalStripDraw, proportionalStripTier), headOf(colorDraw, colorTier),
            headOf(ligatureDraw, ligatureTier), headOf(decorationDraw, decorationTier));
        vkCmdEndRenderPass(m_commandBuffer);
    }
    // The pictures over the text: every image when none lies beneath it.
    if (imageInstances.size() > imageUnderCount)
        drawImageBand(imageUnderCount, imageInstances.size());

    // The cursor tier over the images: the grid pass's LOAD twin over the
    // target's own framebuffer keeps its pixels and draws the cursor's cell
    // with the cursor's colours on top.
    if (hasCursorTier) {
        VkRenderPassBeginInfo tierBegin {};
        tierBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        tierBegin.renderPass = m_gridLoadRenderPass;
        tierBegin.framebuffer = m_framebuffer;
        tierBegin.renderArea.extent = { width, height };
        tierBegin.clearValueCount = 1;
        tierBegin.pClearValues = &clear;
        vkCmdBeginRenderPass(m_commandBuffer, &tierBegin, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(m_commandBuffer, 0, 1, &viewport);
        vkCmdSetScissor(m_commandBuffer, 0, 1, &scissor);
        vkCmdPushConstants(m_commandBuffer, m_pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), push);
        vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_pipelineLayout, 0, 1, &m_descriptorSet, 0, nullptr);
        drawCursorTier();
        vkCmdEndRenderPass(m_commandBuffer);
    }

    // The background image beneath everything above, one quad over its
    // placed rectangle, before the overlays draw over it.
    if (hasBackdropPass) {
        beginBlendLayer();
        vkCmdPushConstants(m_commandBuffer, m_backdropPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
            sizeof(backdropPush), &backdropPush);
        vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_backdropPipeline);
        const VkDescriptorSet backdropSets[3] = { m_imageTextures.backdropDescriptor(), m_imageBackgroundSet, m_backdropTransferSet };
        vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_backdropPipelineLayout, 0, 3, backdropSets, 0, nullptr);
        vkCmdDraw(m_commandBuffer, 6, 1, 0, 0);
        endBlendLayer();
    }

    // The overlay quads last: one draw per run of quads that cannot see each
    // other, and a barrier only across a boundary. A dragged selection is one
    // run, so a sixty-row drag records one draw instead of sixty draws with
    // fifty-nine barriers that ordered nothing.
    if (hasOverlayPass) {
        beginBlendLayer();
        vkCmdPushConstants(m_commandBuffer, m_overlayBlendPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), push);
        vkCmdBindPipeline(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_overlayBlendPipeline);
        vkCmdBindVertexBuffers(m_commandBuffer, 0, 1, &m_overlayBuffer, &offset);
        vkCmdBindDescriptorSets(m_commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, m_overlayBlendPipelineLayout, 0, 1, &m_imageBackgroundSet, 0, nullptr);
        uint32_t drawn = 0;
        for (const std::size_t run : m_overlayRunLengths) {
            if (drawn >= overlayDraw)
                break;
            const uint32_t instances = static_cast<uint32_t>(run) > overlayDraw - drawn
                ? overlayDraw - drawn
                : static_cast<uint32_t>(run);
            vkCmdDraw(m_commandBuffer, 6, instances, 0, drawn);
            drawn += instances;
            if (drawn < overlayDraw)
                regionBarrier();
        }
        endBlendLayer();
    }

    // Every layer left the image in TRANSFER_SRC. A frame asked to export
    // copies it into a free exportable image on the GPU, which the
    // compositor reads directly; any other frame copies it to the staging
    // buffer for host readback.
    const bool isExportAsked = std::exchange(m_isExportRequested, false);
    m_exportedFrame.reset();
    std::optional<std::size_t> exportSlot;
    if (isExportAsked && m_canExportFrames && ensureExportSlots(width, height)) {
        for (std::size_t index = 0; index < exportSlotCount; ++index) {
            bool isFree = false;
            if (m_isExportSlotHeld[index].compare_exchange_strong(isFree, true, std::memory_order_acq_rel)) {
                exportSlot = index;
                break;
            }
        }
    }
    if (isExportAsked && m_canExportFrames && !exportSlot && !m_hasReportedFullExportRing) {
        m_hasReportedFullExportRing = true;
        PAL::logLine(stderr, "ubiquitty-linux: dma-buf ring full; this frame reads back");
    }
    if (exportSlot) {
        VkImage target = m_exportSlots[*exportSlot].image;
        VkImageMemoryBarrier toTransfer {};
        toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.srcAccessMask = 0;
        toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toTransfer.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; // overwritten whole
        toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.image = target;
        toTransfer.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toTransfer);
        VkImageCopy copy {};
        copy.srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        copy.dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        copy.extent = { width, height, 1 };
        vkCmdCopyImage(m_commandBuffer, m_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, target, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        // Handed to a foreign consumer: GENERAL, with the writes made visible
        // to whatever reads the memory next.
        VkImageMemoryBarrier toForeign = toTransfer;
        toForeign.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toForeign.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        toForeign.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toForeign.newLayout = VK_IMAGE_LAYOUT_GENERAL;
        vkCmdPipelineBarrier(m_commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &toForeign);
    } else {
        VkBufferImageCopy region {};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = { width, height, 1 };
        vkCmdCopyImageToBuffer(m_commandBuffer, m_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, m_staging, 1, &region);
    }

    if (vkEndCommandBuffer(m_commandBuffer) != VK_SUCCESS)
        return false;
    VkSubmitInfo submit {};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &m_commandBuffer;
    if (vkQueueSubmit(m_queue, 1, &submit, VK_NULL_HANDLE) != VK_SUCCESS)
        return false;
    const std::uint32_t waitStartMicros = PAL::monotonicMicros();
    if (vkQueueWaitIdle(m_queue) != VK_SUCCESS)
        return false;
    m_lastFrameWaitSeconds = static_cast<double>(static_cast<std::uint32_t>(PAL::monotonicMicros() - waitStartMicros)) / 1e6;
    m_atlas->didUpload();
    m_colorAtlas->didUpload();
    m_proportionalImage.didUpload();
    m_proportionalStripImage.didUpload();
    m_ligatureImage.didUpload();
    if (canShapeProportional)
        m_proportionalSheet->didUpload();
    if (canShapeProportionalStrips)
        m_proportionalStripSheet->clearDirty();
    if (canShapeLigatures)
        m_ligatureSheet->clearDirty();
    // The pair now holds the pixels the CPU baseline describes; only a frame
    // that reached its submit may say so. A frame with a picture under its
    // text inked the target and left the pair its ground alone, so its pair
    // describes nothing a later frame may load.
    if (drawsThroughRetainedTarget && !hasImagesUnderText)
        m_hasRetainedTarget = true;
    if (canReuseGridTarget)
        ++m_partialFrameCount;

    widthOut = static_cast<int>(width);
    heightOut = static_cast<int>(height);
    if (exportSlot) {
        const ExportSlot& slot = m_exportSlots[*exportSlot];
        const int descriptor = ::dup(slot.fileDescriptor);
        if (descriptor >= 0) {
            m_exportedFrame = ExportedFrame {
                .fileDescriptor = descriptor,
                .width = width,
                .height = height,
                .stride = slot.stride,
                .offset = slot.offset,
                .releaseToken = (static_cast<uint64_t>(m_exportGeneration.load(std::memory_order_acquire)) << 32) | *exportSlot,
            };
            m_lastFrameReadbackSeconds = 0.0;
            out.clear();
            return true;
        }
        // No descriptor to hand over: the frame is in the slot, not the
        // staging buffer, so it is reported failed and the next frame reads
        // back with the export switched off.
        m_isExportSlotHeld[*exportSlot].store(false, std::memory_order_release);
        m_canExportFrames = false;
        return false;
    }

    const std::uint32_t readbackStartMicros = PAL::monotonicMicros();
    if (!readTarget(out))
        return false;
    m_lastFrameReadbackSeconds = static_cast<double>(static_cast<std::uint32_t>(PAL::monotonicMicros() - readbackStartMicros)) / 1e6;
    return true;
}

} // namespace Ubiquitty::Linux
