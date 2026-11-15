// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Diagnostics/Rendering/SkipInkSmoke.h"

#include "Core/Preferences/RenderStyle.h"
#include "Core/Rendering/LinkColor.h"
#include "Core/Rendering/PNGEncoder.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Core/Runtime/TerminalSession.h"
#include "Core/TerminalOperations.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/Raster.h"
#include "Platform/Linux/VulkanRenderer.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <format>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <vector>

namespace Ubiquitty::Linux::Diagnostics {

int smokeSkipInk()
{
    Ubiquitty::Linux::FreeTypeRasterizer primary(16, "JetBrains Mono", {}, {}, Ubiquitty::Linux::bundledFontPath("JetBrains Mono"));
    Ubiquitty::Linux::FreeTypeRasterizer cjk(16, "Noto Sans CJK JP");
    Ubiquitty::Rendering::UnifontRasterizer bitmap(1, 0);
    if (!primary.ready() || !cjk.ready()) {
        std::fprintf(stderr, "smoke-skip-ink: native font initialization failed\n");
        return 1;
    }
    Ubiquitty::Linux::RasterContext rasterContext;
    const auto releaseSession = [](Ubiquitty::Runtime::TerminalSession* session) { releaseTerminalSession(session); };
    std::unique_ptr<Ubiquitty::Runtime::TerminalSession, decltype(releaseSession)> session(Ubiquitty::Runtime::TerminalSession::make(), releaseSession);
    if (!session)
        return 1;
    session->start(8, 48);
    Ubiquitty::Terminal* terminal = session->terminal();
    if (!terminal)
        return 1;
    const auto savedConfiguration = Ubiquitty::Preferences::Effective::renderConfiguration(Ubiquitty::Preferences::values());

    struct FontArm {
        Ubiquitty::Rendering::GlyphRasterizer* rasterizer;
        const char* name;
        Ubiquitty::Rendering::FontRasterizerKind kind;
    };
    const std::array arms {
        FontArm { &primary, "native", Ubiquitty::Rendering::FontRasterizerKind::Native },
        FontArm { &cjk, "native-wide", Ubiquitty::Rendering::FontRasterizerKind::Native },
        FontArm { &bitmap, "bitmap", Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap },
    };
    enum class SkipInk {
        Disabled,
        Enabled
    };
    enum class CutCoverage {
        Required,
        Optional
    };
    struct Scene {
        const char* name;
        std::string bytes;
        CutCoverage cutCoverage;
        std::uint32_t blinkTicks = 0;
        std::uint8_t foregroundAlpha = 255;
    };
    const auto toColor = [](const Ubiquitty::PaletteRGB& color) {
        return Ubiquitty::ColorRGBA { Ubiquitty::channel16To8(color.red), Ubiquitty::channel16To8(color.green), Ubiquitty::channel16To8(color.blue), 255 };
    };
    const auto linkColor = Ubiquitty::Rendering::resolveLinkColor(toColor(terminal->palette.indexed[4]), toColor(terminal->palette.indexed[12]),
        toColor(terminal->palette.defaultBackground), toColor(terminal->palette.defaultForeground));
    const std::string linkColoredUnderline = std::format("\x1b[?25l\x1b[4;38;2;{};{};{}mgyp.example", linkColor.red, linkColor.green, linkColor.blue);
    const std::array scenes {
        Scene { "combined",
            "\x1b[?25l\x1b[4;38;2;255;0;0;58;2;0;255;0mgjpqy ffi => \xe4\xb8\xad\xe4\xb8\xad"
            "\r\n\x1b]66;p=1:c=32;gjpqy ffi Wj \xe4\xb8\xad\x07"
            "\r\n\x1b#6gjpqy ffi \xe4\xb8\xad"
            "\x1b[4;1H\x1b]66;s=2;gj\xe4\xb8\xad\x07"
            "\x1b[6;1H\xe4\xb8\xad\xe7\x94\xb0 gjpqy"
            "\x1b[7;1H\x1b[0m\x1b]8;;https://gyp.example\x1b\\gyp.example\x1b]8;;\x1b\\",
            CutCoverage::Required },
        Scene { "doubled-narrow", "\x1b[?25l\x1b[4;38;2;255;0;0;58;2;0;255;0m\x1b#6gjpqy ffi", CutCoverage::Optional },
        Scene { "doubled-wide", "\x1b[?25l\x1b[4;38;2;255;0;0;58;2;0;255;0m\x1b#6\xe4\xb8\xad", CutCoverage::Optional },
        Scene { "doubled-mixed", "\x1b[?25l\x1b[4;38;2;255;0;0;58;2;0;255;0m\x1b#6gjpqy ffi \xe4\xb8\xad", CutCoverage::Optional },
        Scene { "link", "\x1b[?25l\x1b]8;;https://gyp.example\x1b\\gyp.example\x1b]8;;\x1b\\", CutCoverage::Required },
        Scene { "underlined-text", "\x1b[?25l\x1b[4;38;2;58;58;149mgyp.example", CutCoverage::Required },
        Scene { "link-colored-text", linkColoredUnderline, CutCoverage::Required },
        Scene { "link-with-SGR", "\x1b[?25l\x1b[4m\x1b]8;;https://gyp.example\x1b\\gyp.example\x1b]8;;\x1b\\", CutCoverage::Required },
        Scene { "italic-outer", std::format("\x1b[?25l\x1b[1;3H\x1b[3;4;38;2;{};{};{}mfjf", linkColor.red, linkColor.green, linkColor.blue), CutCoverage::Required },
        Scene { "italic-link-outer", "\x1b[?25l\x1b[1;3H\x1b[3m\x1b]8;;https://gyp.example\x1b\\fjf\x1b]8;;\x1b\\", CutCoverage::Required },
        Scene { "italic-underlined-link", "\x1b[?25l\x1b[1;3H\x1b[3;4m\x1b]8;;https://gyp.example\x1b\\fjf\x1b]8;;\x1b\\", CutCoverage::Required },
        Scene { "wide-blink-off", "\x1b[?25l\x1b[5;32m\xe4\xb8\xad", CutCoverage::Optional, 42 },
        Scene { "wide-alpha", "\x1b[?25l\x1b[32m\xe4\xb8\xad", CutCoverage::Optional, 0, 128 },
        Scene { "mono-alpha", "\x1b[?25l\x1b[32mgjpqy", CutCoverage::Optional, 0, 128 },
    };
    int failures = 0;
    for (const auto& arm : arms) {
        auto& rasterizer = *arm.rasterizer;
        rasterContext.setGlyphRasterizer(rasterizer);
        rasterContext.setEmbeddedBitmapScale(arm.kind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap ? 1 : 0);
        rasterContext.resetSoftwareRenderer();
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!renderer.init()) {
            std::fprintf(stderr, "smoke-skip-ink: SKIPPED — Vulkan initialization failed\n");
            return 77;
        }
        std::vector<std::uint8_t> warmup;
        int width = 0, height = 0;
        if (!renderer.renderGrid(rasterContext, terminal, warmup, width, height)) {
            renderer.shutdown();
            std::fprintf(stderr, "smoke-skip-ink: SKIPPED — initial frame unavailable\n");
            return 77;
        }
        session->setTextMeasurer(
            [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t weight,
                Ubiquitty::ProportionalShapedGlyph* glyphs, int capacity, float* advance) {
                auto& source = *static_cast<Ubiquitty::Linux::VulkanRenderer*>(context);
                *advance = source.proportionalCellAdvanceInPixels();
                return source.shapeProportionalRun(std::span(codePoints, static_cast<std::size_t>(count)),
                    Ubiquitty::ProportionalRunStyle { .faceBits = faceBits, .weight = weight },
                    std::span(glyphs, static_cast<std::size_t>(capacity)));
            },
            &renderer);
        for (const auto& scene : scenes) {
            Ubiquitty::hardReset(*terminal);
            Ubiquitty::resize(*terminal, 8, 48);
            terminal->drawsSizedText = true;
            terminal->drawsProportionalText = true;
            terminal->palette.indexedAlpha[2] = scene.foregroundAlpha;
            ++terminal->paletteEpoch;
            Ubiquitty::processBytes(terminal, scene.bytes);
            std::vector<std::uint8_t> withoutSkip;
            std::size_t changedPixels = 0;
            int maxChannelDifference = 0;
            bool didPass = true;
            for (const auto skipInk : { SkipInk::Disabled, SkipInk::Enabled, SkipInk::Disabled }) {
                const bool shouldSkip = skipInk == SkipInk::Enabled;
                auto configuration = savedConfiguration;
                configuration.shouldUnderlineSkipInk = shouldSkip;
                configuration.shouldUnderlineLinks = true;
                configuration.underlineOffsetPoints = -1;
                configuration.underlineThicknessScale = 1.5;
                configuration.underlineSkipInkPaddingPoints = 0.5;
                rasterContext.setRenderConfiguration(configuration);
                std::vector<std::uint8_t> cpu, gpu;
                int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
                const bool didDrawCPU = rasterContext.rasterizeTerm(terminal, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr, scene.blinkTicks);
                const bool didDrawGPU = renderer.renderGrid(rasterContext, terminal, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr, scene.blinkTicks);
                const bool hasSameGeometry = didDrawCPU && didDrawGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight
                    && cpu.size() == gpu.size();
                didPass &= hasSameGeometry;
                if (hasSameGeometry) {
                    int maxFrameDifference = 0;
                    for (std::size_t index = 0; index < cpu.size(); ++index)
                        maxFrameDifference = std::max(maxFrameDifference, std::abs(static_cast<int>(cpu[index]) - static_cast<int>(gpu[index])));
                    maxChannelDifference = std::max(maxChannelDifference, maxFrameDifference);
                    if (const char* directory = std::getenv("UBIQUITTY_SMOKE_IMAGE_DIR"); directory && maxFrameDifference > 1) {
                        for (const auto& [name, pixels] : { std::pair { "cpu", &cpu }, std::pair { "gpu", &gpu } }) {
                            const auto png = Ubiquitty::Rendering::encodePNG(*pixels, { cpuWidth, cpuHeight });
                            const auto path = std::format("{}/skip-ink-{}-{}-{}-{}.png", directory, arm.name, scene.name,
                                shouldSkip ? "on" : "off", name);
                            if (FILE* file = std::fopen(path.c_str(), "wb")) {
                                std::fwrite(png.data(), 1, png.size(), file);
                                std::fclose(file);
                            }
                        }
                    }
                    const int rowHeight = Ubiquitty::Rendering::cellDimension(rasterizer.cellMetrics().cellHeight);
                    for (int row = 0; row < 8; ++row) {
                        int rowDifference = 0;
                        std::size_t firstDifference = cpu.size();
                        for (int y = row * rowHeight; y < std::min((row + 1) * rowHeight, cpuHeight); ++y) {
                            for (int x = 0; x < cpuWidth; ++x) {
                                const auto index = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
                                int delta = 0;
                                for (int channel = 0; channel < 4; ++channel)
                                    delta = std::max(delta, std::abs(static_cast<int>(cpu[index + channel]) - static_cast<int>(gpu[index + channel])));
                                rowDifference = std::max(rowDifference, delta);
                                if (delta > 1 && firstDifference == cpu.size())
                                    firstDifference = index;
                            }
                        }
                        if (rowDifference > 1) {
                            const auto pixel = firstDifference / 4;
                            const int cpuColumn = rasterContext.columnAt(row, static_cast<double>(pixel % cpuWidth));
                            const int gpuColumn = renderer.columnAt(row, static_cast<double>(pixel % cpuWidth));
                            std::printf("  %s/%s skip=%d row=%d max=%d first=(%zu,%zu) CPU=%u,%u,%u,%u GPU=%u,%u,%u,%u columns=%d/%d\n", arm.name, scene.name,
                                static_cast<int>(shouldSkip), row, rowDifference, pixel % cpuWidth, pixel / cpuWidth,
                                cpu[firstDifference], cpu[firstDifference + 1], cpu[firstDifference + 2], cpu[firstDifference + 3],
                                gpu[firstDifference], gpu[firstDifference + 1], gpu[firstDifference + 2], gpu[firstDifference + 3],
                                cpuColumn, gpuColumn);
                            const auto cpuLetters = rasterContext.rowLetters(row);
                            const auto gpuLetters = renderer.rowLetters(row);
                            if (cpuColumn >= 0 && gpuColumn >= 0 && static_cast<std::size_t>(cpuColumn) < cpuLetters.size()
                                && static_cast<std::size_t>(gpuColumn) < gpuLetters.size()) {
                                std::printf("    letter CPU left=%g advance=%g GPU left=%g advance=%g\n",
                                    cpuLetters[static_cast<std::size_t>(cpuColumn)].leftInPixels,
                                    cpuLetters[static_cast<std::size_t>(cpuColumn)].advanceInPixels,
                                    gpuLetters[static_cast<std::size_t>(gpuColumn)].leftInPixels,
                                    gpuLetters[static_cast<std::size_t>(gpuColumn)].advanceInPixels);
                            }
                        }
                    }
                }
                if (shouldSkip && cpu.size() == withoutSkip.size()) {
                    for (std::size_t index = 0; index < cpu.size(); index += 4)
                        changedPixels += std::memcmp(cpu.data() + index, withoutSkip.data() + index, 4) != 0;
                } else if (!shouldSkip) {
                    if (withoutSkip.empty())
                        withoutSkip = std::move(cpu);
                    else
                        didPass &= cpu == withoutSkip;
                }
            }
            didPass &= (scene.cutCoverage == CutCoverage::Optional || changedPixels > 0) && maxChannelDifference <= 1;
            failures += !didPass;
            std::printf("smoke-skip-ink: %s/%s changed=%zu max-channel-difference=%d -- %s\n", arm.name, scene.name, changedPixels,
                maxChannelDifference, didPass ? "PASS" : "FAIL");
        }
        session->setTextMeasurer(nullptr, nullptr);
        renderer.shutdown();
        rasterContext.resetSoftwareRenderer();
    }
    std::printf("smoke-skip-ink: %d failure(s) -- %s\n", failures, failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}

} // namespace Ubiquitty::Linux::Diagnostics
