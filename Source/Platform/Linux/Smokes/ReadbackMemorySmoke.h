// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-softfont — the DECDLD staging seam on the Vulkan backend, headlessly.
// Core rasterises a soft font into a coverage plane and hands it over; the
// backend's whole obligation is to copy it into the slot the cache assigned. The
// mirror the image uploads from is readable without a device, so the placement
// is checkable on a machine with no GPU — which is every machine this runs on.
//
// --smoke-readback-memory — the frame is read back from cached memory.
//
// The readback staging buffer is written by the GPU and read by the host, and
// the memory type decides how fast that read is. On discrete GPUs the
// host-visible types that are coherent but not cached are write-combined: a CPU
// read from them bypasses the cache and runs about an order of magnitude slower
// than normal memory, which for a full frame is megabytes per repaint.
//
// This machine's device offers whatever it offers, so the choice is checked
// against memory tables rather than against hardware -- the tables below are
// the shapes real devices have, including the one where the only cached type is
// not coherent and the caller has to invalidate before reading. Getting that
// second one wrong reads the previous frame, and on the first frame reads
// nothing at all.
/// Checks that Vulkan frame readback uses an appropriate memory type.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeReadbackMemory()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-readback-memory: FAIL: {}", what);
            ok = false;
        }
    };

    constexpr VkMemoryPropertyFlags deviceLocal = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    constexpr VkMemoryPropertyFlags writeCombined = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    constexpr VkMemoryPropertyFlags cachedCoherent
        = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    constexpr VkMemoryPropertyFlags cachedOnly = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    constexpr std::uint32_t everyType = 0xFFFFFFFFu;

    // A discrete GPU: device-local, a write-combined upload type, and a cached
    // readback type. The cached one is the answer even though the
    // write-combined type comes first and satisfies the old flags.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedCoherent };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 2, "a cached type was passed over for a write-combined one");
        check(choice.isCoherent, "a cached coherent type was reported as needing an invalidate");
    }

    // The device whose only cached type is not coherent. The choice must take
    // it and report that it is not coherent, since the caller then has to
    // invalidate before reading.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedOnly };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 2, "the only cached type was passed over");
        check(!choice.isCoherent, "a non-coherent type was reported as coherent, so no invalidate would run");
    }

    // No cached type at all: the write-combined one is what the device has.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 1, "the only host-visible type was not chosen");
        check(choice.isCoherent, "a coherent type was reported as needing an invalidate");
    }

    // The buffer's own requirements exclude the cached type, which is the case
    // a chooser reading only the property flags gets wrong: it would name a
    // type this buffer cannot be bound to.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedCoherent };
        const std::uint32_t withoutCached = 0b011;
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, withoutCached);
        check(choice.typeIndex == 1, "a type the buffer cannot bind was chosen");
    }

    // Nothing host-visible: no answer rather than a wrong one.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == UINT32_MAX, "a device with no host-visible type produced a type index");
    }

    Ubiquitty::PAL::logLine(stdout, "smoke-readback-memory: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
