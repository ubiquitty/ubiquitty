// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Selection + copy-to-clipboard self-test. Feeds a known two-line screen,
// CHAR-selects row 0 columns 1..3 (= "BCD"), asserts getBounds + the extracted
// UTF-8 + the clipboard capture all read "BCD", renders the canned screen WITH
// the selection to /tmp/sel_overlay.png so the TRANSLUCENT highlight can be
// eyeballed (the selected cells are not inverted in the grid — they carry a
// translucent overlay quad, so the glyph reads through), and asserts the CPU
// SoftwareRenderer and GPU VulkanRenderer composite that overlay byte-identically
// WITH the selection set (the key CPU<->GPU oracle for the selection overlay).
/// Checks selection bounds, copied text and overlay rendering on both renderers.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSelection()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-selection: no term\n");
        return 1;
    }
    const char screen[] = "ABCDE\r\nFGHIJ\r\n";
    Ubiquitty::processBytes(term, std::string_view(screen, sizeof(screen) - 1));

    // CHAR-select row 0, columns 1..3 ("BCD") through the facade — the same
    // beginGesture/dragGesture pair the pointer ladder drives.
    activePane()->viewOffset = 0;
    Ubiquitty::Selection::init(activePane()->selection);
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 0, 3, 0);

    const std::string extracted = selectionText();

    // Drive the real copy path and read back what the PAL was handed.
    const bool copied = copySelectionToClipboard();
    const std::string captured = Ubiquitty::Linux::Clipboard::lastSetText();

    // An endpoint on the trailing half of a wide glyph. A continuation cell
    // repeats its lead's code point and the emission walk skips continuations,
    // so bounds that start on that half begin one column past the only cell that
    // produces the character: the copy loses it entirely rather than clipping it,
    // and the result is still well-formed UTF-8 of the right shape, which is why
    // a length or a row count cannot catch this and the bytes have to be named.
    Ubiquitty::processBytes(term, std::string_view("\xe4\xb8\x96\xe7\x95\x8c\r\n"));
    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 2, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const bool didCopyWide = copySelectionToClipboard();
    const std::string capturedWide = Ubiquitty::Linux::Clipboard::lastSetText();
    const bool didWidePass = didCopyWide && capturedWide == "\xe4\xb8\x96\xe7\x95\x8c";

    // The facade resolves the anchor wide-aware, so an endpoint on the glyph's
    // trailing half still copies the whole character — the bytes are the check.
    g_print("smoke-selection: wide clipboard=\"%s\" (%zu bytes) -- %s\n",
        capturedWide.c_str(), capturedWide.size(), didWidePass ? "PASS" : "FAIL");

    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 0, 3, 0);

    // CPU==GPU oracle WITH the selection set: the translucent overlay quad must
    // composite identically on both backends (the key check this stage adds).
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-selection", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
    const bool didOracleAgree = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);

    // The same selection under a colour the host named (OSC 17): the native
    // style draws it behind the text, as each selected cell's background
    // washed by the native opacity. Both backends take that fill from Core's
    // capture; a backend that substitutes its own tint draws another colour at
    // another weight while the cell-pass bake still reads as behind the text.
    Ubiquitty::processBytes(term, std::string_view("\x1b]17;rgb:00/80/ff\x07"));
    std::vector<uint8_t> hostCPU;
    std::vector<uint8_t> hostGPU;
    int hostCPUWidth = 0, hostCPUHeight = 0, hostGPUWidth = 0, hostGPUHeight = 0;
    const bool didRasterizeHostCPU = app().rasterContext.rasterizeTerm(term, hostCPU, hostCPUWidth, hostCPUHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didRenderHostGPU = renderer.renderGrid(app().rasterContext, term, hostGPU, hostGPUWidth, hostGPUHeight, activePane()->viewOffset, &activePane()->selection);
    // A boundary frame freezes the grid before the pointer's next gesture.
    // Selection is the view's present-time overlay, so moving or clearing it
    // must change this same captured picture without waiting for more output.
    const auto geometry = app().rasterContext.frameCaptureGeometry();
    Ubiquitty::Rendering::TerminalSnapshotOptions options;
    options.style = geometry.style;
    options.drawCursor = false;
    options.cellHeightPoints = geometry.cellHeightPoints;
    options.lineSpacingPoints = geometry.lineSpacingPoints;
    options.toolkitCaret = geometry.toolkitCaret;
    std::unique_ptr<Ubiquitty::Rendering::FrameCapture, LinuxPane::FrameRelease> boundary(Ubiquitty::Rendering::FrameCapture::make());
    bool didCapturedSelectionPass = boundary->capture(*term, options, geometry.metrics, geometry.glyphSlot);
    std::vector<Ubiquitty::Rendering::SelectionRowSpan> spans(static_cast<std::size_t>(Ubiquitty::Selection::viewportSpanCapacity(term->rows, term->columns)));
    Ubiquitty::Linux::CursorOverlay hiddenCursor;
    std::vector<uint8_t> unselectedCapture;
    for (const int selectedRow : { -1, 0, 1, -1 }) {
        Ubiquitty::Selection::init(activePane()->selection);
        if (selectedRow >= 0) {
            Ubiquitty::Selection::beginGesture(activePane()->selection, *term, selectedRow, 1, 1, 0, plainStyle);
            Ubiquitty::Selection::dragGesture(activePane()->selection, *term, selectedRow, 3, 0);
        }
        Ubiquitty::Selection::ViewportEnds ends;
        const auto selected = activePane()->session->viewSelectionOverCapture(&activePane()->selection, *boundary,
            { spans.data(), spans.size() }, ends);
        Ubiquitty::Rendering::FrameCapture::ViewTierOverrides view;
        view.selectionSpans = spans.data();
        view.selectionSpanCount = selected.count;
        view.selectionColor = boundary->selectionFillColor();
        view.isSelectionBehindText = boundary->isSelectionFillBehindText();
        view.hasSelectionForegroundOverride = boundary->hasSelectionForegroundOverride();
        view.selectionForeground = boundary->selectionForeground();
        std::vector<uint8_t> referencePixels, capturedPixels;
        int referenceWidth = 0, referenceHeight = 0, capturedWidth = 0, capturedHeight = 0;
        const bool didDrawReference = renderer.renderGrid(app().rasterContext, term, referencePixels, referenceWidth, referenceHeight,
            0, &activePane()->selection, &hiddenCursor);
        const bool didDrawCaptured = renderer.renderGrid(app().rasterContext, term, capturedPixels, capturedWidth, capturedHeight,
            0, &activePane()->selection, &hiddenCursor, 0, {}, boundary.get(), &view);
        bool didCopyCurrentSelection = true;
        if (selectedRow >= 0) {
            const std::string wanted = selectedRow == 0 ? "BCD" : "GHI";
            didCopyCurrentSelection = selected.count > 0 && selectionText() == wanted
                && copySelectionToClipboard() && Ubiquitty::Linux::Clipboard::lastSetText() == wanted;
        }
        const bool didPicturesAgree = didDrawReference && didDrawCaptured
            && referenceWidth == capturedWidth && referenceHeight == capturedHeight && referencePixels == capturedPixels;
        if (unselectedCapture.empty())
            unselectedCapture = capturedPixels;
        const bool didSelectionChangePicture = selectedRow < 0 ? capturedPixels == unselectedCapture : capturedPixels != unselectedCapture;
        didCapturedSelectionPass = didCapturedSelectionPass && didPicturesAgree && didCopyCurrentSelection && didSelectionChangePicture;
        g_print("smoke-selection: captured row %d spans=%d copied=%d same=%d changed=%d -- %s\n", selectedRow, selected.count,
            static_cast<int>(didCopyCurrentSelection), static_cast<int>(didPicturesAgree), static_cast<int>(didSelectionChangePicture),
            didPicturesAgree && didCopyCurrentSelection && didSelectionChangePicture ? "PASS" : "FAIL");
    }
    renderer.shutdown();
    const bool didCompareHost = didRasterizeHostCPU && didRenderHostGPU;
    const bool didHostOracleAgree = !didCompareHost
        || (hostCPUWidth == hostGPUWidth && hostCPUHeight == hostGPUHeight && hostCPU == hostGPU);

    // Render the canned screen WITH the selection to a PNG (eyeball the
    // translucent highlight — text readable through it).
    if (didRasterizeCPU) {
        const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
        if (FILE* f = std::fopen("/tmp/sel_overlay.png", "wb")) {
            std::fwrite(png.data(), 1, png.size(), f);
            std::fclose(f);
            g_print("smoke-selection: wrote /tmp/sel_overlay.png (%dx%d)\n", cpuWidth, cpuHeight);
        }
    }

    const bool didPass = extracted == "BCD" && copied && captured == "BCD" && didWidePass && didOracleAgree && didHostOracleAgree && didCapturedSelectionPass;
    g_print("smoke-selection: extracted=\"%s\" clipboard=\"%s\" "
            "CPU==GPU(with selection)=%s CPU==GPU(behind the text, OSC 17)=%s -- %s\n",
        extracted.c_str(), captured.c_str(), oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (didOracleAgree ? OracleOutcome::Matched : OracleOutcome::Differed)),
        oracleLabel(!didCompareHost ? OracleOutcome::NotCompared : (didHostOracleAgree ? OracleOutcome::Matched : OracleOutcome::Differed)), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
