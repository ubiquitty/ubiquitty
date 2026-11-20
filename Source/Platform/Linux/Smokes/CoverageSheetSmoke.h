// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-coverage-sheet — a partial upload leaves the sheet holding the mirror.
//
// The glyph sheet is megabytes and a faulted glyph changes kilobytes of it, so
// the upload copies the band of rows the changed slots sit in rather than the
// whole thing. What can go wrong is the arithmetic: a wrong offset lands a
// glyph's coverage in a neighbouring slot, which draws as a different
// character rather than as an error. Nothing downstream reports it.
//
// So the sheet is read back and compared to the host mirror byte for byte. The
// image carries TRANSFER_SRC for this, and the comparison covers the whole
// sheet after a partial copy -- an offset that writes the right bytes to the
// wrong place fails on the rows it disturbed as much as on the rows it missed.
//
// Runs on whatever Vulkan device is present; the container's is lavapipe. The
// arithmetic under test is the host's, so a software device answers it exactly
// as a discrete one would.
/// Checks partial glyph-sheet uploads against the complete host mirror.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeCoverageSheet()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-coverage-sheet: FAIL: {}", what);
            ok = false;
        }
    };

    VkApplicationInfo applicationInfo {};
    applicationInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    applicationInfo.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo instanceInfo {};
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.pApplicationInfo = &applicationInfo;
    VkInstance instance = VK_NULL_HANDLE;
    if (vkCreateInstance(&instanceInfo, nullptr, &instance) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no Vulkan instance)");
        return 0;
    }

    std::uint32_t deviceCount = 0;
    vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr);
    if (deviceCount == 0) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no Vulkan device)");
        return 0;
    }
    std::vector<VkPhysicalDevice> physicalDevices(deviceCount);
    vkEnumeratePhysicalDevices(instance, &deviceCount, physicalDevices.data());
    const VkPhysicalDevice physical = physicalDevices[0];

    std::uint32_t familyCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr);
    std::vector<VkQueueFamilyProperties> families(familyCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data());
    std::uint32_t familyIndex = familyCount;
    for (std::uint32_t i = 0; i < familyCount; ++i) {
        if (families[i].queueFlags & VK_QUEUE_TRANSFER_BIT) {
            familyIndex = i;
            break;
        }
    }
    if (familyIndex == familyCount) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no transfer queue)");
        return 0;
    }

    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueInfo {};
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueInfo.queueFamilyIndex = familyIndex;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    VkDeviceCreateInfo deviceInfo {};
    deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    VkDevice device = VK_NULL_HANDLE;
    if (vkCreateDevice(physical, &deviceInfo, nullptr, &device) != VK_SUCCESS) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no logical device)");
        return 0;
    }
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, familyIndex, 0, &queue);

    VkCommandPoolCreateInfo poolInfo {};
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.queueFamilyIndex = familyIndex;
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    check(vkCreateCommandPool(device, &poolInfo, nullptr, &commandPool) == VK_SUCCESS, "command pool");

    // Small enough to compare exhaustively, and not a multiple of anything the
    // copy might round to: a width that is a nice power of two would hide a
    // stride mistake that a real sheet's width would expose.
    constexpr int sheetWidth = 96;
    constexpr int sheetHeight = 64;
    constexpr int bandHeight = 16; // one slot row

    Ubiquitty::Linux::VulkanCoverageSheet sheet;
    check(sheet.create(device, physical, sheetWidth, sheetHeight), "sheet created");

    std::vector<std::uint8_t> mirror(static_cast<std::size_t>(sheetWidth) * sheetHeight);
    // A value that varies along each axis, so a copy landing at the wrong row
    // shows up as a mismatch rather than as the same byte in a different place.
    const auto fillMirror = [&](std::uint8_t salt) {
        for (int y = 0; y < sheetHeight; ++y) {
            for (int x = 0; x < sheetWidth; ++x)
                mirror[static_cast<std::size_t>(y) * sheetWidth + x] = static_cast<std::uint8_t>(x * 3 + y * 7 + salt);
        }
    };
    fillMirror(0);
    check(sheet.upload(device, queue, commandPool, mirror), "the whole sheet uploaded");

    // Read the image back into a host-visible buffer.
    const auto readImage = [&](VkImage image, int imageWidth, int imageHeight, int bytesPerPixel, std::vector<std::uint8_t>& out) {
        const std::size_t byteCount = static_cast<std::size_t>(imageWidth) * imageHeight * bytesPerPixel;
        out.assign(byteCount, 0);
        VkBufferCreateInfo bufferInfo {};
        bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bufferInfo.size = byteCount;
        bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        VkBuffer readbackBuffer = VK_NULL_HANDLE;
        if (vkCreateBuffer(device, &bufferInfo, nullptr, &readbackBuffer) != VK_SUCCESS)
            return false;
        VkMemoryRequirements requirements {};
        vkGetBufferMemoryRequirements(device, readbackBuffer, &requirements);
        VkMemoryAllocateInfo allocateInfo {};
        allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocateInfo.allocationSize = requirements.size;
        allocateInfo.memoryTypeIndex = Ubiquitty::Linux::findVulkanMemoryType(physical, requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        VkDeviceMemory readbackMemory = VK_NULL_HANDLE;
        if (vkAllocateMemory(device, &allocateInfo, nullptr, &readbackMemory) != VK_SUCCESS) {
            vkDestroyBuffer(device, readbackBuffer, nullptr);
            return false;
        }
        vkBindBufferMemory(device, readbackBuffer, readbackMemory, 0);

        VkCommandBufferAllocateInfo commandInfo {};
        commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        commandInfo.commandPool = commandPool;
        commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        commandInfo.commandBufferCount = 1;
        VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
        vkAllocateCommandBuffers(device, &commandInfo, &commandBuffer);
        VkCommandBufferBeginInfo beginInfo {};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(commandBuffer, &beginInfo);

        VkImageMemoryBarrier toSource {};
        toSource.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toSource.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        toSource.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        toSource.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toSource.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toSource.image = image;
        toSource.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        toSource.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        toSource.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &toSource);

        VkBufferImageCopy region {};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = { static_cast<uint32_t>(imageWidth), static_cast<uint32_t>(imageHeight), 1 };
        vkCmdCopyImageToBuffer(commandBuffer, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            readbackBuffer, 1, &region);

        VkImageMemoryBarrier backToShader = toSource;
        backToShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        backToShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        backToShader.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        backToShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &backToShader);

        vkEndCommandBuffer(commandBuffer);
        VkSubmitInfo submit {};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
        vkQueueWaitIdle(queue);
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);

        void* mapped = nullptr;
        const bool didMap = vkMapMemory(device, readbackMemory, 0, byteCount, 0, &mapped) == VK_SUCCESS;
        if (didMap) {
            std::memcpy(out.data(), mapped, byteCount);
            vkUnmapMemory(device, readbackMemory);
        }
        vkDestroyBuffer(device, readbackBuffer, nullptr);
        vkFreeMemory(device, readbackMemory, nullptr);
        return didMap;
    };

    std::vector<std::uint8_t> readback;
    check(readImage(sheet.imageForReadback(), sheetWidth, sheetHeight, 1, readback), "the sheet read back");
    check(readback == mirror, "a whole-sheet upload did not leave the sheet holding the mirror");

    // One band changed, and only that band copied. The comparison is over the
    // whole sheet: rows outside the band must still hold what the first upload
    // put there, and rows inside it must hold the new bytes.
    fillMirror(0x5A);
    constexpr int bandFirstRow = bandHeight * 2;
    check(sheet.upload(device, queue, commandPool, mirror, bandFirstRow, bandHeight), "the band uploaded");
    std::vector<std::uint8_t> afterBand;
    check(readImage(sheet.imageForReadback(), sheetWidth, sheetHeight, 1, afterBand), "the sheet read back after the band");

    bool doesBandMatch = true;
    bool isOutsideKept = true;
    for (int y = 0; y < sheetHeight; ++y) {
        for (int x = 0; x < sheetWidth; ++x) {
            const std::size_t index = static_cast<std::size_t>(y) * sheetWidth + x;
            const bool isInBand = y >= bandFirstRow && y < bandFirstRow + bandHeight;
            if (isInBand) {
                if (afterBand[index] != mirror[index])
                    doesBandMatch = false;
            } else if (afterBand[index] != static_cast<std::uint8_t>(x * 3 + y * 7)) {
                isOutsideKept = false;
            }
        }
    }
    check(doesBandMatch, "the copied band does not hold the new bytes");
    check(isOutsideKept, "a band copy disturbed rows outside it");

    // A range past the end is refused rather than clamped.
    check(!sheet.upload(device, queue, commandPool, mirror, sheetHeight - 1, bandHeight), "a range past the sheet was accepted");
    check(!sheet.upload(device, queue, commandPool, mirror, -1, bandHeight), "a negative first row was accepted");
    // An empty range is a caller saying nothing changed.
    check(sheet.upload(device, queue, commandPool, mirror, 0, 0), "an empty range was refused");

    // Two independent staging buffers share one submission. Recording alone
    // must not publish an image layout: the caller can discard that command
    // buffer before it ever reaches the queue.
    {
        Ubiquitty::Linux::VulkanCoverageSheet batchedSheet;
        Ubiquitty::Rendering::UnifontRasterizer batchedRasterizer;
        Ubiquitty::Linux::VulkanColorGlyphAtlas batchedColor(batchedRasterizer, 16);
        const bool wereSheetsCreated = batchedSheet.create(device, physical, sheetWidth, sheetHeight)
            && batchedColor.create(device, physical);
        check(wereSheetsCreated, "batched sheets created");
        VkCommandBufferAllocateInfo allocateInfo {};
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocateInfo.commandPool = commandPool;
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocateInfo.commandBufferCount = 1;
        VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
        const bool wasCommandAllocated = vkAllocateCommandBuffers(device, &allocateInfo, &commandBuffer) == VK_SUCCESS;
        check(wasCommandAllocated, "batch command buffer allocated");
        const auto beginBatch = [&] {
            VkCommandBufferBeginInfo beginInfo {};
            beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            return vkResetCommandBuffer(commandBuffer, 0) == VK_SUCCESS
                && vkBeginCommandBuffer(commandBuffer, &beginInfo) == VK_SUCCESS;
        };
        const auto submitBatch = [&] {
            if (vkEndCommandBuffer(commandBuffer) != VK_SUCCESS)
                return false;
            VkSubmitInfo submit {};
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &commandBuffer;
            return vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS
                && vkQueueWaitIdle(queue) == VK_SUCCESS;
        };
        if (wereSheetsCreated && wasCommandAllocated) {
            bool didRecord = beginBatch()
                && batchedSheet.recordUpload(commandBuffer, mirror, 0, sheetHeight);
            check(didRecord, "discarded upload recorded");
            check(!batchedSheet.isReadable(), "recording published an unsubmitted image layout");
            // Discard the recorded copy, then submit an empty replacement. Its
            // completion must not commit the abandoned copy's pending state.
            const bool didCompleteEmpty = didRecord && beginBatch()
                && batchedSheet.recordUpload(commandBuffer, mirror, 0, 0)
                && submitBatch();
            check(didCompleteEmpty, "empty replacement completed");
            if (didCompleteEmpty)
                batchedSheet.didUpload();
            check(!batchedSheet.isReadable(), "empty replacement committed an abandoned copy");

            didRecord = didCompleteEmpty && beginBatch()
                && batchedSheet.recordUpload(commandBuffer, mirror, 0, sheetHeight)
                && batchedColor.recordUpload(commandBuffer);
            check(didRecord, "both sheet uploads recorded");
            check(!batchedSheet.isReadable(), "batch recording published an incomplete image layout");
            const bool didComplete = didRecord && submitBatch();
            check(didComplete, "both sheets completed in one submission");
            if (didComplete) {
                check(!batchedSheet.isReadable(), "completion bypassed the upload commit");
                batchedSheet.didUpload();
                batchedColor.didUpload();
                check(batchedSheet.isReadable(), "completed upload did not publish its image layout");
                std::vector<std::uint8_t> batchedReadback;
                const bool didReadCoverage = readImage(batchedSheet.imageForReadback(), sheetWidth, sheetHeight, 1, batchedReadback);
                check(didReadCoverage && batchedReadback == mirror, "batched coverage differs from its mirror");
                const bool didReadColor = readImage(batchedColor.imageForReadback(), batchedColor.widthForReadback(), batchedColor.heightForReadback(), 4, batchedReadback);
                const auto colorMirror = batchedColor.mirrorForReadback();
                check(didReadColor && batchedReadback.size() == colorMirror.size()
                        && std::equal(colorMirror.begin(), colorMirror.end(), batchedReadback.begin()),
                    "batched color differs from its mirror");

                // Rectangles that lie apart, each staged behind the one before
                // it. The whole mirror changes and only the rectangles are
                // copied: they must hold the new bytes, and every byte outside
                // them what the upload before left there.
                using Rect = Ubiquitty::Linux::VulkanCoverageSheet::Rect;
                const std::vector<std::uint8_t> before = mirror;
                fillMirror(0xA7);
                const std::array<Rect, 3> rects { {
                    { .x = 5, .y = 3, .width = 17, .height = 9 },
                    { .x = 60, .y = 3, .width = 31, .height = 9 }, // beside the first, in its rows
                    { .x = 0, .y = sheetHeight - bandHeight, .width = sheetWidth, .height = bandHeight }, // the last band, whole
                } };
                const bool didCopyRects = beginBatch() && batchedSheet.recordUpload(commandBuffer, mirror, rects) && submitBatch();
                check(didCopyRects, "the rectangles uploaded");
                if (didCopyRects) {
                    batchedSheet.didUpload();
                    std::vector<std::uint8_t> afterRects;
                    check(readImage(batchedSheet.imageForReadback(), sheetWidth, sheetHeight, 1, afterRects), "the sheet read back after the rectangles");
                    bool doRectsMatch = afterRects.size() == mirror.size();
                    bool isOutsideRectsKept = doRectsMatch;
                    for (int y = 0; doRectsMatch && y < sheetHeight; ++y) {
                        for (int x = 0; x < sheetWidth; ++x) {
                            const std::size_t index = static_cast<std::size_t>(y) * sheetWidth + x;
                            const bool isInRect = std::ranges::any_of(rects, [&](const Rect& rect) {
                                return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
                            });
                            if (isInRect && afterRects[index] != mirror[index])
                                doRectsMatch = false;
                            if (!isInRect && afterRects[index] != before[index])
                                isOutsideRectsKept = false;
                        }
                    }
                    check(doRectsMatch, "a copied rectangle does not hold the new bytes");
                    check(isOutsideRectsKept, "a rectangle copy disturbed bytes outside it");
                }
                // A rectangle reaching past the sheet is refused rather than
                // clamped, and no rectangle at all is nothing to copy.
                const std::array<Rect, 1> pastTheEdge { { { .x = sheetWidth - 6, .y = 0, .width = 7, .height = 4 } } };
                check(beginBatch() && !batchedSheet.recordUpload(commandBuffer, mirror, pastTheEdge), "a rectangle past the sheet was accepted");
                check(beginBatch() && batchedSheet.recordUpload(commandBuffer, mirror, std::span<const Rect> {}), "an empty list of rectangles was refused");
            }
        }
        if (wasCommandAllocated)
            vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        batchedColor.destroy(device);
        batchedSheet.destroy(device);
    }

    sheet.destroy(device);

    // The colour sheet, which has no other check at all. The CPU renderer holds
    // no colour atlas, so the CPU/GPU oracle that covers the mono path cannot
    // see an emoji -- and this sheet is four bytes per pixel, so its band
    // arithmetic multiplies where the mono sheet's does not. That is the one
    // place a stride mistake can hide.
    {
        Ubiquitty::Rendering::UnifontRasterizer colorRasterizer;
        Ubiquitty::Linux::VulkanColorGlyphAtlas colorAtlas(colorRasterizer, 16);
        if (!colorAtlas.create(device, physical)) {
            Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: colour sheet not created (skipped)");
        } else {
            const int colorWidth = colorAtlas.widthForReadback();
            const int colorHeight = colorAtlas.heightForReadback();
            const int slotEdge = colorAtlas.slotEdgeForReadback();
            check(colorWidth > 0 && colorHeight > 0 && slotEdge > 0, "the colour sheet reports an extent");

            check(colorAtlas.upload(device, queue, commandPool), "the whole colour sheet uploaded");

            // A slot in a middle band, so a band that lands at the top or runs
            // to the end is a mismatch rather than a coincidence.
            const int columns = colorWidth / slotEdge;
            check(columns > 0, "the colour sheet has a slot grid");
            // Rasterising into a slot is the public way to move the mirror.
            // Whether the bundled font has a colour face for the code point
            // decides the pixels, not the band: either way the slot is written
            // and the band that carries it is what this checks.
            const int touchedSlot = columns * 2 + 1;
            constexpr std::uint32_t grinningFace = 0x1F600;
            (void)colorAtlas.rasteriseColorGlyph(&grinningFace, 1, touchedSlot);
            check(colorAtlas.upload(device, queue, commandPool), "the colour band uploaded");

            const std::span<const std::uint8_t> colorMirror = colorAtlas.mirrorForReadback();
            std::vector<std::uint8_t> colorReadback(colorMirror.size(), 0);
            const bool didReadColor = readImage(colorAtlas.imageForReadback(), colorWidth, colorHeight, 4, colorReadback);
            check(didReadColor, "the colour sheet read back");
            if (didReadColor) {
                check(std::equal(colorMirror.begin(), colorMirror.end(), colorReadback.begin()),
                    // copy-ok: a self-check verdict for the harness log, not interface text
                    "the colour sheet does not hold its mirror after a band upload");
            }
            colorAtlas.destroy(device);
        }
    }

    vkDestroyCommandPool(device, commandPool, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);

    Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
