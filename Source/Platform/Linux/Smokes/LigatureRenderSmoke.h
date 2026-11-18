// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-ligature-render — the strip pass reaches the screen, and the picture
// it changes is the one it should.
//
// Two arms of the same renderer over the same terminal, differing only in
// whether a shaping face was injected. Byte equality between them is the wrong
// verdict either way, so this asserts three things one frame cannot:
//
//   1. the shaping arm drew strip instances at all — a pass that builds an
//      empty stream every frame is invisible in any comparison of pictures;
//   2. the two arms DIFFER on a row holding `!=` and `->`, which is the whole
//      claim: the strips are not merely drawn, they changed the glyphs;
//   3. the two arms AGREE on a row with no ligature in it. Without this the
//      difference in (2) is unattributed — two renderer instances can differ
//      for reasons that have nothing to do with shaping, and a test that only
//      demands "not equal" passes just as well when everything is wrong.
/// Checks that shaped ligature strips change the intended pixels.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeLigatureRender()
{
    setupFonts();
    // The BUNDLED face, not the host's. The default font on this container is
    // DejaVu Sans Mono, which has no programming ligatures: over it the strip
    // path and the per-glyph path agree by construction, and check (2) below
    // would be asserting something the font cannot do. JetBrains Mono ships
    // beside the binary and ligates, which is what makes the assertion real.
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: SKIP - no bundled primary face beside the binary");
        return 0;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: SKIP - the bundled face loaded no shaper");
        return 0;
    }

    // Row 0 ligates in a programming face; row 1 cannot ligate at all, and is
    // the control. Each row is one pen, so each is a single run.
    // Cleared and homed first. The arms share one pane, and `runtime.init` does
    // not empty the screen: without this each arm renders over the last one's
    // text, the arms differ everywhere, and the null control below is what says
    // so rather than the difference passing as a result about ligatures.
    const char content[] = "\x1b[2J\x1b[Ha != b -> c\r\nplain text row";

    // Which arm this is, named rather than passed as a bare true. The two calls
    // sit next to each other and differ in one argument; a bool there reads as
    // `renderOneArm(true, ...)` at the point where the reader most needs to know
    // which of the two they are looking at.
    enum class LigatureArm {
        Shaping,
        Control
    };
    auto renderOneArm = [&](LigatureArm arm, std::vector<uint8_t>& outRGBA, int& outWidth,
                            int& outHeight, std::uint32_t& outLigatureInstances) -> bool {
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(bundled);
        if (arm == LigatureArm::Shaping)
            renderer.setLigatureRasterizer(bundled);
        if (!renderer.init())
            return false;
        activePane()->session->start(startupRows, startupColumns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            renderer.shutdown();
            return false;
        }
        Ubiquitty::processBytes(term, std::string_view(content, sizeof(content) - 1));
        const bool didRender = renderer.renderGrid(app().rasterContext, term, outRGBA, outWidth, outHeight, 0, nullptr, nullptr);
        outLigatureInstances = renderer.lastFrameLigatureInstanceCount();
        renderer.shutdown();
        return didRender;
    };

    std::vector<uint8_t> shapedRGBA;
    std::vector<uint8_t> unshapedRGBA;
    int shapedWidth = 0, shapedHeight = 0, unshapedWidth = 0, unshapedHeight = 0;
    std::uint32_t shapedInstances = 0, unshapedInstances = 0;
    if (!renderOneArm(LigatureArm::Shaping, shapedRGBA, shapedWidth, shapedHeight, shapedInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the shaping arm rendered no frame");
    if (!renderOneArm(LigatureArm::Control, unshapedRGBA, unshapedWidth, unshapedHeight, unshapedInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the control arm rendered no frame");

    // The null: a third arm, identical to the second. Two renderer instances
    // over one shared rasterizer and one shared pane can differ for reasons that
    // have nothing to do with shaping — they take turns faulting glyphs into a
    // cache the rasterizer owns, and the pane carries whatever the previous arm
    // left on screen. Any difference this pair shows is the harness's, and it is
    // read as that rather than as evidence about ligatures.
    std::vector<uint8_t> nullRGBA;
    int nullWidth = 0, nullHeight = 0;
    std::uint32_t nullInstances = 0;
    if (!renderOneArm(LigatureArm::Control, nullRGBA, nullWidth, nullHeight, nullInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the null arm rendered no frame");
    if (shapedWidth != unshapedWidth || shapedHeight != unshapedHeight) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the arms rendered different sizes ({}x{} vs {}x{})",
            shapedWidth, shapedHeight, unshapedWidth, unshapedHeight);
        return 1;
    }

    bool didEveryCheckPass = true;

    // (0) The null must be silent before anything else here means a thing.
    if (nullRGBA.size() == unshapedRGBA.size()) {
        int nullDifferences = 0;
        for (std::size_t i = 0; i < nullRGBA.size(); i += 4) {
            if (std::memcmp(nullRGBA.data() + i, unshapedRGBA.data() + i, 4) != 0)
                ++nullDifferences;
        }
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: null (control vs control) differs in {} pixel(s)", nullDifferences);
        if (nullDifferences != 0) {
            Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - two identical arms disagree, so no comparison below "
                                            "can be attributed to shaping");
            didEveryCheckPass = false;
        }
    }

    // (1) The pass ran.
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: strip instances shaped={} control={}", shapedInstances, unshapedInstances);
    if (shapedInstances == 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the shaping arm drew no strip instances");
        didEveryCheckPass = false;
    }
    if (unshapedInstances != 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the control arm drew {} strip instance(s) with no shaper",
            unshapedInstances);
        didEveryCheckPass = false;
    }

    // Rows in pixels. Row 0 holds the ligatures; row 1 is the control.
    const int cellHeight = shapedHeight / startupRows;
    auto countDifferingPixelsInRow = [&](int row) {
        int differing = 0;
        for (int y = row * cellHeight; y < (row + 1) * cellHeight && y < shapedHeight; ++y) {
            for (int x = 0; x < shapedWidth; ++x) {
                const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                               + static_cast<std::size_t>(x))
                    * 4;
                if (std::memcmp(shapedRGBA.data() + offset, unshapedRGBA.data() + offset, 4) != 0)
                    ++differing;
            }
        }
        return differing;
    };

    // (2) The ligature row changed.
    const int ligatureRowDifferences = countDifferingPixelsInRow(0);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: ligature row differs in {} pixel(s)", ligatureRowDifferences);
    if (ligatureRowDifferences == 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - `!=` and `->` drew identically with and without a shaper");
        didEveryCheckPass = false;
    }

    // (2b) The strips were DRAWN, not merely routed away from the mono path.
    //
    // This is the check that (2) cannot make, and the reason it exists is a
    // mutation that survived without it: deleting the ligature draw call
    // entirely still moved 443 pixels on the ligature row and still passed. A
    // covered cell carries no UV of its own — Core routes its glyph into the
    // strip stream — so a pass that builds instances and never draws them empties
    // those cells, and "the row changed" is just as true of a row that went
    // blank. Ink is what tells the two apart: the strips carry roughly the ink
    // the glyphs did, and a missing draw leaves the run's cells background.
    auto countInkedPixelsInRow = [&](const std::vector<uint8_t>& image, int row) {
        int isPixelInked = 0;
        for (int y = row * cellHeight; y < (row + 1) * cellHeight && y < shapedHeight; ++y) {
            // The row's own background, read from its last column, which no
            // text reaches. Sampled per row rather than fixed as a constant,
            // because a theme or a selection changes it per row and a constant
            // would count a recoloured background as ink.
            const std::size_t backgroundOffset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                                     + static_cast<std::size_t>(shapedWidth - 1))
                * 4;
            for (int x = 0; x < shapedWidth; ++x) {
                const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                               + static_cast<std::size_t>(x))
                    * 4;
                if (std::memcmp(image.data() + offset, image.data() + backgroundOffset, 4) != 0)
                    ++isPixelInked;
            }
        }
        return isPixelInked;
    };
    const int shapedInk = countInkedPixelsInRow(shapedRGBA, 0);
    const int controlInk = countInkedPixelsInRow(unshapedRGBA, 0);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: ligature row ink shaped={} control={}", shapedInk, controlInk);
    // Half the control's ink is a floor, not a target: a ligature is a different
    // drawing and legitimately carries somewhat more or less ink than the
    // characters it replaced. What it cannot do is approach zero, which is what
    // the run's cells hold when nothing draws them.
    if (shapedInk * 2 < controlInk) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the ligature row lost its ink ({} vs {}), so the "
                                        "strips were routed off the mono path and never drawn",
            shapedInk, controlInk);
        didEveryCheckPass = false;
    }

    // (3) The control row did not.
    const int plainRowDifferences = countDifferingPixelsInRow(1);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: plain row differs in {} pixel(s)", plainRowDifferences);
    if (plainRowDifferences != 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - a row with no ligature in it changed too, so the "
                                        "difference above is not attributable to shaping");
        didEveryCheckPass = false;
    }

    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: {}", didEveryCheckPass ? "PASS" : "FAILED");
    return didEveryCheckPass ? 0 : 1;
}
