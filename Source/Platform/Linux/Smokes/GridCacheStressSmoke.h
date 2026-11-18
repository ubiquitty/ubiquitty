// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-gridcache-stress — the retained grid against a full re-render, over
// every event that changes pixels without necessarily changing a cell.
//
// The single-feed smoke above holds three frames to the CPU oracle; this one
// holds a long feed, a moving search match, a selection drawn behind the text,
// and two terminals of one size taking turns on one renderer, which is how the
// window renders a split. Each frame is held to the same frame from a fresh
// renderer, which has no target to keep and builds every row: the cache-off
// picture, from the same encode, so a difference is the retained lane's and
// nothing else's. Run under UBIQUITTY_GRID_CACHE=0 as well: the same frames
// must match with no partial frame taken, which is the switch reaching this arm.
/// Compares retained rendering against fresh rendering across pixel-changing events.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeGridCacheStress()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-gridcache-stress", "vulkan init failed");
    constexpr int rows = 10;
    constexpr int columns = 40;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    auto other = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*other, rows, columns);
    if (!term) {
        g_printerr("smoke-gridcache-stress: no term\n");
        renderer.shutdown();
        return 1;
    }
    const auto screenOfText = [](const char* label) {
        std::string text;
        for (int row = 1; row <= rows; ++row)
            text += std::format("\x1b[{};1H{} {} \x1b[31mred\x1b[0m \x1b[44mblue\x1b[0m gjpqy -> != ===", row, label, row);
        return text;
    };

    bool didEveryFramePass = true;
    std::string failedFrames;
    int frameCount = 0;
    // One frame: the subject, then the oracle. The oracle drains nothing the
    // subject has not, so it cannot move the subject's baseline.
    const auto frame = [&](const char* name, Ubiquitty::Terminal* subject, int viewOffset, Ubiquitty::Selection::Session* selection) {
        std::vector<uint8_t> retained;
        std::vector<uint8_t> full;
        int retainedWidth = 0, retainedHeight = 0, fullWidth = 0, fullHeight = 0;
        const bool didRenderRetained = renderer.renderGrid(app().rasterContext, subject, retained, retainedWidth, retainedHeight, viewOffset, selection, nullptr);
        Ubiquitty::Linux::VulkanRenderer fresh;
        fresh.setGlyphRasterizer(currentRasterizer());
        fresh.setLigatureRasterizer(currentRasterizer());
        const bool didRenderFull = fresh.init()
            && fresh.renderGrid(app().rasterContext, subject, full, fullWidth, fullHeight, viewOffset, selection, nullptr);
        fresh.shutdown();
        ++frameCount;
        const bool same = didRenderRetained && didRenderFull && retainedWidth == fullWidth && retainedHeight == fullHeight && retained == full;
        if (same)
            return;
        int differingPixels = 0;
        int firstRow = -1;
        for (std::size_t i = 0; i + 3 < retained.size() && i + 3 < full.size(); i += 4) {
            if (std::memcmp(retained.data() + i, full.data() + i, 4) == 0)
                continue;
            if (firstRow < 0 && fullWidth > 0)
                firstRow = static_cast<int>((i / 4) / static_cast<std::size_t>(fullWidth));
            ++differingPixels;
        }
        g_print("smoke-gridcache-stress: %-28s retained!=full, %d pixel(s) differ from y %d (partial frames so far %llu)\n", name,
            differingPixels, firstRow, static_cast<unsigned long long>(renderer.partialFrameCount()));
        // The pair for the eye, named by frame number, as the smoke above
        // writes its own.
        if (retainedWidth == fullWidth && retainedHeight == fullHeight && !full.empty()) {
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("retained", retained), { "full", full } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { fullWidth, fullHeight });
                const std::string path = std::format("/tmp/gridcache_stress_{:02}_{}.png", frameCount, label);
                if (FILE* file = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), file);
                    std::fclose(file);
                }
            }
        }
        didEveryFramePass = false;
        failedFrames += failedFrames.empty() ? name : std::string(", ") + name;
    };

    struct Step {
        const char* name;
        std::string bytes;
        int viewOffset = 0;
    };
    const Step steps[] = {
        { "first", screenOfText("row") },
        { "settle", "" },
        { "edit", "\x1b[3;5Hedited" },
        { "scroll", std::format("\x1b[{};1H\r\nscrolled one\r\nscrolled two", rows) },
        { "margined scroll up", "\x1b[3;6r\x1b[6;1H\r\nin region\r\nagain\x1b[r" },
        { "margined scroll down", "\x1b[2;5r\x1b[2;1H\x1bM\x1bMdown\x1b[r" },
        { "SU", "\x1b[2S" },
        { "SD", "\x1b[1T" },
        { "IL", "\x1b[4;1H\x1b[2L" },
        { "DL", "\x1b[3;1H\x1b[1M" },
        { "EL", "\x1b[2;3H\x1b[K" },
        { "ICH DCH", "\x1b[6;2H\x1b[3@\x1b[7;2H\x1b[2P" },
        { "combining above", "\x1b[9;1He\xcc\x81\xcc\x82\xcc\x83\xcc\x84 a\xcc\x8a\xcc\x8b" },
        { "combining cleared", "\x1b[9;1H\x1b[2K" },
        { "OSC 4", "\x1b]4;1;rgb:00/ff/00\x07" },
        { "OSC 10", "\x1b]10;rgb:ff/ff/00\x07" },
        { "OSC 11", "\x1b]11;rgb:20/00/40\x07" },
        { "OSC reset", "\x1b]104\x07\x1b]110\x07\x1b]111\x07" },
        { "DECSCNM on", "\x1b[?5h" },
        { "DECSCNM off", "\x1b[?5l" },
        { "DECDWL", "\x1b[2;1H\x1b#6" },
        { "DECDHL", "\x1b[4;1H\x1b#3\x1b[5;1H\x1b#4" },
        { "DECSWL", "\x1b[2;1H\x1b#5\x1b[4;1H\x1b#5\x1b[5;1H\x1b#5" },
        { "DECALN", "\x1b#8" },
        { "refill", screenOfText("row") },
        { "alternate", "\x1b[?1049h\x1b[H\x1b[2Jalternate" },
        { "primary", "\x1b[?1049l" },
        { "wide", "\x1b[6;1H\xe4\xb8\x96\xe7\x95\x8c x" },
        { "sync", "\x1b[?2026h\x1b[2;1Hsync body\x1b[?2026l" },
        { "RIS", "\x1b"
                 "c" },
        { "refill after RIS", screenOfText("row") },
        { "red background", "\x1b]11;rgb:80/00/00\x07" },
        { "RIS to blue", "\x1b"
                         "c"
                         "\x1b]11;rgb:00/00/80\x07" },
        { "refill on blue", screenOfText("row") },
        { "scrolled back", "\r\nmore\r\nlines\r\nhistory", 2 },
        { "tail", "", 0 },
        { "idle", "" },
    };
    for (const Step& step : steps) {
        if (!step.bytes.empty())
            Ubiquitty::processBytes(term, step.bytes);
        frame(step.name, term, step.viewOffset, nullptr);
    }
    const std::uint64_t partialAfterFeed = renderer.partialFrameCount();

    // The focused search match is drawn into the cells it covers. Moving it
    // to the next match changes no cell, so only the plan can owe its rows.
    Ubiquitty::processBytes(term, screenOfText("find"));
    frame("find text", term, 0, nullptr);
    frame("find settle", term, 0, nullptr);
    const auto search = activePane()->session->searchScrollbackAndWait("blue", Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Literal, Ubiquitty::CaseSensitivity::Insensitive);
    if (search.isComplete && !search.isPatternInvalid) {
        frame("search opened", term, 0, nullptr);
        for (const char* name : { "search next 1", "search next 2", "search next 3" }) {
            (void)activePane()->session->stepSearchMatch(Ubiquitty::Runtime::TerminalSession::SearchStep::Forward);
            frame(name, term, 0, nullptr);
        }
        activePane()->session->clearScrollbackSearch();
        frame("search closed", term, 0, nullptr);
    } else
        didEveryFramePass = false;

    // A selection drawn behind the text: the host named its colour (OSC 17),
    // so the fill is each selected cell's background rather than an overlay.
    Ubiquitty::processBytes(term, "\x1b]17;rgb:00/80/ff\x07");
    frame("selection colour", term, 0, nullptr);
    Ubiquitty::Selection::Session selection;
    Ubiquitty::Selection::init(selection);
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(selection, *term, 2, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(selection, *term, 4, 6, 0);
    frame("selection drawn", term, 0, &selection);
    Ubiquitty::Selection::dragGesture(selection, *term, 6, 12, 0);
    frame("selection grown", term, 0, &selection);
    Ubiquitty::Selection::dragGesture(selection, *term, 3, 2, 0);
    frame("selection shrunk", term, 0, &selection);
    Ubiquitty::Selection::init(selection);
    frame("selection cleared", term, 0, &selection);

    // Two panes of one size on the window's one renderer, in turns. Each has
    // its own grid and its own damage; the target holds whichever drew last.
    // Two fresh panes fed alike count their damage alike, so each one's
    // generation meets the one the other's last frame left in the baseline.
    auto left = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*left, rows, columns);
    Ubiquitty::processBytes(left.get(), screenOfText("left"));
    Ubiquitty::processBytes(other.get(), screenOfText("right"));
    frame("pane A", left.get(), 0, nullptr);
    frame("pane B", other.get(), 0, nullptr);
    for (int turn = 0; turn < 3; ++turn) {
        Ubiquitty::processBytes(left.get(), std::format("\x1b[{};1Hleft turn {}", turn + 2, turn));
        frame("pane A turn", left.get(), 0, nullptr);
        Ubiquitty::processBytes(other.get(), std::format("\x1b[{};1Hright turn {}", turn + 5, turn));
        frame("pane B turn", other.get(), 0, nullptr);
        frame("pane A idle", left.get(), 0, nullptr);
        frame("pane B idle", other.get(), 0, nullptr);
    }
    renderer.shutdown();

    // The coverage bound, and the switch: with the cache on the feed took the
    // partial lane, with it off no frame did.
    const bool isCacheEnabled = Ubiquitty::Rendering::isRetainedGridCacheEnabled();
    const bool didTakeExpectedLane = isCacheEnabled ? partialAfterFeed > 0 : renderer.partialFrameCount() == 0;
    g_print("smoke-gridcache-stress: %d frames, cache %s, partial frames %llu (after the feed %llu)\n", frameCount,
        isCacheEnabled ? "on" : "off", static_cast<unsigned long long>(renderer.partialFrameCount()),
        static_cast<unsigned long long>(partialAfterFeed));
    if (!didTakeExpectedLane) {
        g_print("smoke-gridcache-stress: FAILED - the partial lane %s\n", isCacheEnabled ? "was never taken" : "was taken with the cache off");
        didEveryFramePass = false;
    }
    if (didEveryFramePass)
        g_print("smoke-gridcache-stress: PASS\n");
    else
        g_print("smoke-gridcache-stress: FAILED frame(s): %s\n", failedFrames.c_str());
    return didEveryFramePass ? 0 : 1;
}
