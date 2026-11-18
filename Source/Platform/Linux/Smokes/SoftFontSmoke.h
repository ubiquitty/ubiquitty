// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The failure this exists for is a row pitch that walks: a plane blitted with the
// wrong stride lands partly in the NEIGHBOURING slot, and every count stays
// right, so a test that only asks "did the slot change" passes on it.
/// Checks soft-font coverage placement without disturbing adjacent slots.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSoftFont()
{
    Ubiquitty::Rendering::UnifontRasterizer rasterizer;
    Ubiquitty::Linux::VulkanGlyphAtlas atlas(8, 16, rasterizer);
    const Ubiquitty::Rendering::MonoAtlasBinding binding = atlas.bindMonoAtlas();
    const int slotWidth = binding.geometry.slotWidthInPixels;
    const int slotHeight = binding.geometry.slotHeightInPixels;
    const int columns = binding.geometry.columns;
    const int count = slotWidth * slotHeight;
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-softfont: FAIL: {}", what);
            ok = false;
        }
    };
    check(slotWidth > 0 && slotHeight > 0 && columns > 0, "the atlas reports a slot grid");
    check(binding.slotCapacity > columns, "the atlas holds more than one row of slots");
    if (!ok)
        return 1;

    // Slot 1 and slot 1+columns bracket slot 0: one to its right, one below it, so
    // a stride that is too long and one that is too short both land in a slot this
    // reads afterwards.
    const int target = 1;
    const int rightNeighbour = 2;
    const int belowNeighbour = 1 + columns;
    std::vector<std::uint8_t> plane(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i)
        plane[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(1 + (i % 255));

    auto slotByte = [&](int slot, int x, int y) {
        const std::span<const std::uint8_t> mirror = atlas.monoCoverage();
        const int x0 = (slot % columns) * slotWidth;
        const int y0 = (slot / columns) * slotHeight;
        return mirror[static_cast<std::size_t>(y0 + y) * static_cast<std::size_t>(atlas.atlasWidthInPixels()) + static_cast<std::size_t>(x0 + x)];
    };
    auto slotIsBlank = [&](int slot) {
        for (int y = 0; y < slotHeight; ++y)
            for (int x = 0; x < slotWidth; ++x)
                if (slotByte(slot, x, y) != 0)
                    return false;
        return true;
    };

    check(slotIsBlank(target) && slotIsBlank(rightNeighbour) && slotIsBlank(belowNeighbour), "the slots start blank");

    const std::span<const std::uint8_t> wholePlane { plane };

    // A plane the wrong shape is refused, and refusing means writing nothing —
    // a partial blit that then reports false is the same defect wearing a verdict.
    // A span carries its own length, so a pointer that disagrees with the count is
    // not a case this can be handed; an EMPTY span is what takes its place.
    check(!atlas.stageMonoCoverage(target, wholePlane.first(static_cast<std::size_t>(count) - 1)), "a short plane is refused");
    check(!atlas.stageMonoCoverage(target, {}), "an empty plane is refused");
    check(!atlas.stageMonoCoverage(-1, wholePlane), "a negative slot is refused");
    check(!atlas.stageMonoCoverage(binding.slotCapacity, wholePlane), "a slot past the end is refused");
    check(slotIsBlank(target), "a refused plane wrote nothing");

    check(atlas.stageMonoCoverage(target, wholePlane), "a correctly shaped plane is staged");

    int wrong = 0;
    for (int y = 0; y < slotHeight; ++y)
        for (int x = 0; x < slotWidth; ++x)
            if (slotByte(target, x, y) != plane[static_cast<std::size_t>(y) * static_cast<std::size_t>(slotWidth) + static_cast<std::size_t>(x)])
                ++wrong;
    check(wrong == 0, "every byte landed where the slot box says it goes");
    check(slotIsBlank(rightNeighbour), "the slot to the right is untouched");
    check(slotIsBlank(belowNeighbour), "the slot below is untouched");

    Ubiquitty::PAL::logLine(stdout, "smoke-softfont: slot={}x{} columns={} misplaced={} -- {}", slotWidth, slotHeight, columns, wrong, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
