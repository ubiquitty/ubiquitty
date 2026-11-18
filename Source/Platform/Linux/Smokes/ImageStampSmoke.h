// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image-stamp — a same-id, same-geometry re-transmit reaches the screen.
//
// The Vulkan texture cache keys on Image::imageContentStamp, which folds the
// generation Core bumps whenever a same-id transmit replaces pixels. Keying on
// geometry instead compiles, passes every existing image oracle, and freezes an
// animation on frame one: the id and the size are unchanged, so the cache hands
// back the first upload forever.
//
// Nothing covered that. The Core primitive is pinned by test_kitty_placeholders
// and the neutral helpers by test_terminalimage_widen; both stop short of the
// cache that consumes them. This renders the re-transmit and looks at pixels.
//
// Kitty rather than sixel, because the aliasing needs an EXPLICIT id: each sixel
// transmission is a new image and would never collide. `a=T,i=1` transmits and
// displays under an id the second feed reuses.
//
// One renderer across both frames, or the cache under test is thrown away
// between them and the smoke proves nothing.
/// Checks that retransmitting an image updates pixels without changing its identity or geometry.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImageStamp()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-stamp: no term\n");
        return 1;
    }

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-image-stamp", "vulkan init failed");

    // 2x2 24-bit RGB, transmitted and displayed under id 1. The second carries
    // the same id and the same geometry and different pixels, which is the whole
    // point: everything a geometry key can see is identical.
    const char redImage[] = "\x1b_Ga=T,f=24,s=2,v=2,i=1;/wAA/wAA/wAA/wAA\x1b\\";
    const char blueImage[] = "\x1b_Ga=T,f=24,s=2,v=2,i=1;AAD/AAD/AAD/AAD/\x1b\\";

    // Home first, and again before the second transmit. `a=T` displays at the
    // cursor, and a transmit moves it -- so without this the two images land on
    // different cells and the frames differ because the picture moved rather
    // than because its pixels were replaced. The cursor is hidden: a one-cell
    // image leaves it on the image's cell, and the block cursor draws over the
    // over-text images, so a visible cursor would cover the pixel under test.
    Ubiquitty::processBytes(term, "\x1b[?25l");
    Ubiquitty::processBytes(term, "\x1b[H");
    Ubiquitty::processBytes(term, std::string_view(redImage, sizeof(redImage) - 1));
    if (Ubiquitty::Image::placementCount(term) < 1) {
        g_printerr("smoke-image-stamp: the first transmit produced no placement — nothing to re-transmit over\n");
        renderer.shutdown();
        return 1;
    }

    std::vector<uint8_t> first;
    int firstWidth = 0, firstHeight = 0;
    if (!renderer.renderGrid(app().rasterContext, term, first, firstWidth, firstHeight, 0, nullptr, nullptr)) {
        renderer.shutdown();
        return skipNoGPUFrame("smoke-image-stamp", "the first renderGrid failed");
    }

    Ubiquitty::processBytes(term, "\x1b[H");
    Ubiquitty::processBytes(term, std::string_view(blueImage, sizeof(blueImage) - 1));
    std::vector<uint8_t> second;
    int secondWidth = 0, secondHeight = 0;
    if (!renderer.renderGrid(app().rasterContext, term, second, secondWidth, secondHeight, 0, nullptr, nullptr)) {
        renderer.shutdown();
        return skipNoGPUFrame("smoke-image-stamp", "the second renderGrid failed");
    }
    renderer.shutdown();

    // The frames have to be comparable before a difference between them means
    // anything: a geometry change would make them differ for the wrong reason.
    if (firstWidth != secondWidth || firstHeight != secondHeight) {
        g_printerr("smoke-image-stamp: FAIL: the two frames are different sizes (%dx%d vs %dx%d)\n",
            firstWidth, firstHeight, secondWidth, secondHeight);
        return 1;
    }
    // The image's own top-left pixel, not the whole frame: anything else that
    // differs between the two frames would report a difference whether or not
    // the picture changed, which is a check that cannot fail.
    const auto redAt = [](const std::vector<uint8_t>& frame) -> int {
        return frame.size() >= 4 ? static_cast<int>(frame[0]) : -1;
    };
    const auto blueAt = [](const std::vector<uint8_t>& frame) -> int {
        return frame.size() >= 4 ? static_cast<int>(frame[2]) : -1;
    };
    const int firstRed = redAt(first), firstBlue = blueAt(first);
    const int secondRed = redAt(second), secondBlue = blueAt(second);

    // The first frame has to actually be the red image, or the comparison below
    // is between two things neither of which is the picture under test.
    if (!(firstRed > 200 && firstBlue < 60)) {
        g_printerr("smoke-image-stamp: FAIL: the first frame's top-left is not the red image (r=%d b=%d)\n",
            firstRed, firstBlue);
        return 1;
    }
    if (!(secondBlue > 200 && secondRed < 60)) {
        g_printerr("smoke-image-stamp: FAIL: the re-transmitted image did not reach the screen — "
                   "top-left is still r=%d b=%d, so the texture cache returned the first upload "
                   "for a new one under the same id and size\n",
            secondRed, secondBlue);
        return 1;
    }
    g_print("smoke-image-stamp: the image's own pixel went red(%d,%d) -> blue(%d,%d) on a same-id, same-geometry re-transmit\n",
        firstRed, firstBlue, secondRed, secondBlue);
    g_print("smoke-image-stamp: PASS\n");
    return 0;
}
