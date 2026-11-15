// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Diagnostics/Rendering/PaddingSmoke.h"

#include "Core/Preferences/RenderStyle.h"
#include "Core/Rendering/PNGEncoder.h"
#include "Core/Runtime/TerminalSession.h"
#include "Core/TerminalOperations.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/FontRouting.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/Presentation/PaneGeometry.h"
#include "Platform/Linux/Raster.h"
#include "Platform/Linux/VulkanRenderer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <memory>
#include <string_view>
#include <vector>

namespace Ubiquitty::Linux::Diagnostics {

namespace {

void writeComparison(std::string_view scene, const std::vector<std::uint8_t>& cpu,
    const std::vector<std::uint8_t>& gpu, IntSize size)
{
    const char* directory = std::getenv("UBIQUITTY_SMOKE_IMAGE_DIR");
    if (!directory || size.width <= 0 || size.height <= 0)
        return;
    const auto bytes = static_cast<std::size_t>(size.width) * size.height * 4;
    for (const auto& [name, pixels] : { std::pair { "cpu", &cpu }, std::pair { "gpu", &gpu } }) {
        if (pixels->size() != bytes)
            continue;
        const auto png = Rendering::encodePNG(*pixels, size);
        const auto path = std::format("{}/padding-{}-{}.png", directory, scene, name);
        if (FILE* file = std::fopen(path.c_str(), "wb")) {
            std::fwrite(png.data(), 1, png.size(), file);
            std::fclose(file);
        }
    }
}

} // namespace

int smokePadding()
{
    // The reported 8.5pt face at a 96-DPI desktop and a 2x backing scale.
    auto savedConfiguration = Preferences::Effective::renderConfiguration(Preferences::values());
    savedConfiguration.lineSpacingPoints = 2;
    const double pixelsPerPoint = 96.0 / 72.0 * 2.0;
    FreeTypeRasterizer face(8.5 * pixelsPerPoint, "Monaspace Neon Var", {}, {},
        bundledFontPath("Monaspace Neon Var"), 2, Preferences::Effective::lineSpacingInPixels(savedConfiguration, pixelsPerPoint));
    if (!face.ready()) {
        std::fprintf(stderr, "smoke-padding: bundled Monaspace initialization failed\n");
        return 1;
    }
    RasterContext raster;
    raster.setDeviceScale(2);
    raster.setGlyphRasterizer(face);
    VulkanRenderer renderer;
    renderer.setGlyphRasterizer(face);
    renderer.setLigatureRasterizer(face);
    if (!renderer.init()) {
        std::fprintf(stderr, "smoke-padding: SKIPPED — Vulkan initialization failed\n");
        return 77;
    }
    const auto releaseSession = [](Runtime::TerminalSession* session) { releaseTerminalSession(session); };
    std::unique_ptr<Runtime::TerminalSession, decltype(releaseSession)> session(Runtime::TerminalSession::make(), releaseSession);
    if (!session) {
        renderer.shutdown();
        return 1;
    }
    session->start(4, 20);
    auto* terminal = session->terminal();
    terminal->palette.defaultBackground = { 0x1010, 0x1818, 0x2020 };
    terminal->palette.defaultForeground = { 0xffff, 0xffff, 0xffff };
    processBytes(terminal, "\x1b[?25l");
    int failures = 0;
    for (const auto alpha : { std::uint8_t { 255 }, std::uint8_t { 128 } }) {
        auto configuration = savedConfiguration;
        configuration.backgroundOpacity = alpha / 255.0;
        configuration.lineSpacingPoints = 2;
        raster.setRenderConfiguration(configuration);
        const auto geometry = raster.frameCaptureGeometry({ 28, 28 },
            { static_cast<float>(20 * raster.cellWidth() + 56), static_cast<float>(4 * raster.cellHeight() + 56) });
        const std::array<std::uint8_t, 4> background { 16, 24, 32, alpha };
        for (const auto scene : { std::string_view { "leading" }, std::string_view { "erase" } }) {
            processBytes(terminal, scene == "leading" ? "\x1b[H\x1b[2KWwork" : "\x1b[H\x1b[2K");
            const auto partialBefore = renderer.partialFrameCount();
            CursorOverlay cursor;
            std::vector<std::uint8_t> cpu;
            std::vector<std::uint8_t> gpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            int gpuWidth = 0;
            int gpuHeight = 0;
            bool didPass = raster.rasterizeTerm(terminal, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor, 0, nullptr, &geometry)
                && renderer.renderGrid(raster, terminal, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor, 0, {}, nullptr, nullptr, &geometry)
                && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu.size() == gpu.size();
            int maxChannelDifference = 0;
            std::size_t overhangPixels = 0;
            if (didPass) {
                for (std::size_t index = 0; index < cpu.size(); ++index)
                    maxChannelDifference = std::max(maxChannelDifference, std::abs(static_cast<int>(cpu[index]) - static_cast<int>(gpu[index])));
                for (int y = 28; y < 28 + raster.cellHeight(); ++y) {
                    for (int x = 0; x < 28; ++x) {
                        const auto offset = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
                        overhangPixels += !std::equal(background.begin(), background.end(), cpu.begin() + static_cast<std::ptrdiff_t>(offset));
                    }
                }
                for (const auto pixel : { IntPoint { 0, 0 }, IntPoint { cpuWidth - 1, 0 }, IntPoint { 0, cpuHeight - 1 }, IntPoint { cpuWidth - 1, cpuHeight - 1 } }) {
                    const auto offset = (static_cast<std::size_t>(pixel.y) * cpuWidth + pixel.x) * 4;
                    didPass &= std::equal(background.begin(), background.end(), cpu.begin() + static_cast<std::ptrdiff_t>(offset));
                }
                didPass &= maxChannelDifference <= 1;
                didPass &= scene == "leading" ? overhangPixels > 0 : overhangPixels == 0 && renderer.partialFrameCount() > partialBefore;
            }
            if (!didPass)
                writeComparison(std::format("{}-{}", scene, alpha), cpu, gpu, { cpuWidth, cpuHeight });
            failures += !didPass;
            std::printf("smoke-padding: %.*s alpha=%u overhang=%zu max-channel-difference=%d partial=%llu -- %s\n",
                static_cast<int>(scene.size()), scene.data(), alpha, overhangPixels, maxChannelDifference,
                static_cast<unsigned long long>(renderer.partialFrameCount() - partialBefore), didPass ? "PASS" : "FAIL");
        }
        // An admitted boundary frame owns its placement even when the view
        // already asks for another origin. A later live frame must retire that
        // placement before it may load any retained pixels.
        processBytes(terminal, "\x1b[HWwork");
        const auto movedGeometry = raster.frameCaptureGeometry({ 31, 19 }, geometry.viewportSizeInPixels);
        Rendering::TerminalSnapshotOptions options;
        options.drawCursor = false;
        options.originInPixels = geometry.originInPixels;
        options.viewportSizeInPixels = geometry.viewportSizeInPixels;
        options.subpixelPhaseCount = raster.frameGeometryPhaseCount();
        options.style.backgroundOpacity = raster.backgroundOpacity();
        const auto releaseCapture = [](Rendering::FrameCapture* capture) { releaseFrameCapture(capture); };
        std::unique_ptr<Rendering::FrameCapture, decltype(releaseCapture)> capture(Rendering::FrameCapture::make(), releaseCapture);
        const bool didCapture = capture && capture->capture(*terminal, options, face.cellMetrics(), raster.frameCaptureGeometry().glyphSlot);
        for (const auto mode : { std::string_view { "capture" }, std::string_view { "moved-live" } }) {
            std::vector<std::uint8_t> cpu;
            std::vector<std::uint8_t> gpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            int gpuWidth = 0;
            int gpuHeight = 0;
            CursorOverlay cursor;
            const auto& referenceGeometry = mode == "capture" ? geometry : movedGeometry;
            const auto partialBefore = renderer.partialFrameCount();
            const auto* captured = mode == "capture" ? capture.get() : nullptr;
            bool didPass = didCapture
                && raster.rasterizeTerm(terminal, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor, 0, nullptr, &referenceGeometry)
                && renderer.renderGrid(raster, terminal, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor, 0, {}, captured, nullptr, &movedGeometry)
                && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu.size() == gpu.size();
            int maxChannelDifference = 0;
            if (didPass) {
                for (std::size_t index = 0; index < cpu.size(); ++index)
                    maxChannelDifference = std::max(maxChannelDifference, std::abs(static_cast<int>(cpu[index]) - static_cast<int>(gpu[index])));
                didPass &= maxChannelDifference <= 1 && renderer.partialFrameCount() == partialBefore;
            }
            failures += !didPass;
            std::printf("smoke-padding: %.*s alpha=%u max-channel-difference=%d -- %s\n",
                static_cast<int>(mode.size()), mode.data(), alpha, maxChannelDifference, didPass ? "PASS" : "FAIL");
        }
    }
    // Fractional requested padding is authored once before rasterization,
    // input mapping and retained scroll copies consume the same device grid.
    const FloatSize cell { static_cast<float>(raster.cellWidth()), static_cast<float>(raster.cellHeight()) };
    const auto authored = Presentation::PaneGeometry::resolve(
        { 20 * cell.width + 56, 4 * cell.height + 13 }, { 28.25f, 27.75f, 6.75f, 6.25f }, cell, { 20, 4 });
    const auto fractionalGeometry = raster.frameCaptureGeometry(authored.rasterOrigin, authored.rasterSize);
    for (const auto scene : { std::string_view { "fractional-seed" }, std::string_view { "fractional-scroll" } }) {
        processBytes(terminal, scene == "fractional-seed" ? "\x1b[H\x1b[2J\x1b[31mM111\r\n\x1b[32mM222\r\n\x1b[33mM333\r\n\x1b[34mM444" : "\r\n\x1b[35mM555");
        const auto partialBefore = renderer.partialFrameCount();
        CursorOverlay cursor;
        std::vector<std::uint8_t> cpu;
        std::vector<std::uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        bool didPass = authored.rasterOrigin.x == 28 && authored.rasterOrigin.y == 7
            && authored.textureOrigin.x == 0 && authored.textureOrigin.y == 0
            && raster.rasterizeTerm(terminal, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor, 0, nullptr, &fractionalGeometry)
            && renderer.renderGrid(raster, terminal, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor, 0, {}, nullptr, nullptr, &fractionalGeometry)
            && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu.size() == gpu.size();
        int maxChannelDifference = 0;
        if (didPass) {
            for (std::size_t index = 0; index < cpu.size(); ++index)
                maxChannelDifference = std::max(maxChannelDifference, std::abs(static_cast<int>(cpu[index]) - static_cast<int>(gpu[index])));
            didPass &= maxChannelDifference <= 1;
            if (scene == "fractional-scroll")
                didPass &= renderer.partialFrameCount() > partialBefore;
        }
        if (!didPass)
            writeComparison(scene, cpu, gpu, { cpuWidth, cpuHeight });
        failures += !didPass;
        std::printf("smoke-padding: %.*s max-channel-difference=%d partial=%llu -- %s\n",
            static_cast<int>(scene.size()), scene.data(), maxChannelDifference,
            static_cast<unsigned long long>(renderer.partialFrameCount() - partialBefore), didPass ? "PASS" : "FAIL");
    }
    // A direct caller can still request a fractional GPU origin. Its full
    // redraw must not enter the integral retained-copy path on a later frame.
    const auto directFractional = raster.frameCaptureGeometry({ 28, 6.75f }, authored.rasterSize);
    const auto fractionalPartialBefore = renderer.partialFrameCount();
    bool didKeepFullRedraw = true;
    for (int attempt = 0; attempt < 2; ++attempt) {
        CursorOverlay cursor;
        std::vector<std::uint8_t> gpu;
        int width = 0, height = 0;
        didKeepFullRedraw &= renderer.renderGrid(raster, terminal, gpu, width, height, 0, nullptr, &cursor, 0, {}, nullptr, nullptr, &directFractional);
    }
    didKeepFullRedraw &= renderer.partialFrameCount() == fractionalPartialBefore;
    failures += !didKeepFullRedraw;
    std::printf("smoke-padding: direct-fractional-full-redraw -- %s\n", didKeepFullRedraw ? "PASS" : "FAIL");
    renderer.shutdown();
    std::printf("smoke-padding: %d failure(s) -- %s\n", failures, failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}

} // namespace Ubiquitty::Linux::Diagnostics
