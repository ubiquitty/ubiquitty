// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks the texture fallback when DMA-buffer import fails.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeDmabufImportFailure()
{
    bool didPass = true;
    const auto check = [&](bool didHold, std::string_view reason) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-dmabuf-import-failure: FAIL: {}", reason);
            didPass = false;
        }
    };
    setupFonts();
    activePane()->session->start(4, 16);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-dmabuf-import-failure: FAIL: no terminal\n");
        return 1;
    }
    Ubiquitty::Rendering::UnifontRasterizer rasterizer(1);
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    for (const int refusalIndex : { 1, 2, 3 }) {
        Ubiquitty::processBytes(term, "\x1b[?25l\x1b[2J\x1b[H\x1b[31mImport fallback");
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        if (!renderer.init() || !renderer.canExportFrames()) {
            renderer.shutdown();
            g_print("smoke-dmabuf-import-failure: SKIP (no Vulkan dma-buf exporter)\n");
            return smokeSkippedExitCode;
        }
        struct ImportProbe {
            int refusalIndex;
            int calls = 0;
            bool hasValidBuffer = true;
        } probe { .refusalIndex = refusalIndex };
        renderer.setFrameImportProbe([](void* context, int fileDescriptor, std::size_t length) {
            auto& probe = *static_cast<ImportProbe*>(context);
            probe.hasValidBuffer &= fileDescriptor >= 0 && length > 0;
            return ++probe.calls < probe.refusalIndex;
        },
            &probe);
        std::vector<std::uint8_t> reference;
        int referenceWidth = 0;
        int referenceHeight = 0;
        check(renderer.renderGrid(app().rasterContext, term, reference, referenceWidth, referenceHeight), "baseline readback failed");
        check(!reference.empty(), "baseline has no pixels");
        renderer.requestFrameExport();
        std::vector<std::uint8_t> frame;
        int width = 0;
        int height = 0;
        check(renderer.renderGrid(app().rasterContext, term, frame, width, height), "the refused frame did not draw");
        // A device can offer the export extensions and still refuse to build
        // the exportable image (Mesa's lavapipe does). Export is then off before
        // any import, so the refusal this smoke drives never happens.
        if (probe.calls == 0 && !renderer.canExportFrames()) {
            renderer.shutdown();
            g_print("smoke-dmabuf-import-failure: SKIP (the exporter could not build its image, so no import was offered)\n");
            return smokeSkippedExitCode;
        }
        check(probe.calls == refusalIndex && probe.hasValidBuffer, "the requested import refusal was not exercised");
        check(!renderer.canExportFrames(), "export was not disabled after refusal");
        check(width == referenceWidth && height == referenceHeight && frame == reference, "the refused frame lost its pixels instead of reading back");
        const auto checkNoExport = [&] {
            if (const auto exported = renderer.takeExportedFrame()) {
                check(false, "an export escaped after import refusal");
                ::close(exported->fileDescriptor);
                renderer.releaseExportedFrame(exported->releaseToken);
            }
        };
        checkNoExport();
        Ubiquitty::processBytes(term, "\r\x1b[32mStill drawing!");
        renderer.requestFrameExport();
        check(renderer.renderGrid(app().rasterContext, term, frame, width, height), "the following frame did not draw");
        check(frame.size() == reference.size() && frame != reference, "the following frame did not show changed content");
        check(probe.calls == refusalIndex, "a later frame retried the refused import");
        checkNoExport();
        renderer.shutdown();
    }
    Ubiquitty::PAL::logLine(stdout, "smoke-dmabuf-import-failure: {} (refusal at each ring slot, same-frame readback, subsequent rendering)", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
