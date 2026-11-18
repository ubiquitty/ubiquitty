// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks retained rendering of captured frames against fresh rendering.
///
/// - Parameter renderer: The Vulkan renderer under examination.
/// - Returns: Whether every check passed.
bool smokeCapturedRetainedFrames(Ubiquitty::Linux::VulkanRenderer& renderer)
{
    constexpr int rows = 6;
    constexpr int columns = 20;
    Ubiquitty::Runtime::TerminalRuntime runtime;
    runtime.init(Ubiquitty::Runtime::RuntimeInitParameters { rows, columns, false });
    Ubiquitty::Terminal* terminal = runtime.borrowTermForRender();
    if (!terminal)
        return false;
    Ubiquitty::processBytes(terminal, "\x1b[?25lAAAA BBBB\r\nCCCC DDDD\r\nEEEE FFFF\r\nGGGG HHHH");
    const auto geometry = app().rasterContext.frameCaptureGeometry();
    Ubiquitty::Rendering::TerminalSnapshotOptions options;
    options.drawCursor = false;
    options.style = geometry.style;
    options.cellHeightPoints = geometry.cellHeightPoints;
    options.lineSpacingPoints = geometry.lineSpacingPoints;
    options.toolkitCaret = geometry.toolkitCaret;
    std::unique_ptr<Ubiquitty::Rendering::FrameCapture, LinuxPane::FrameRelease> captured(Ubiquitty::Rendering::FrameCapture::make());
    std::array<std::uint8_t, rows> dirtyRows;
    dirtyRows.fill(1);
    const auto captureRecord = [&](std::uint64_t sequence, std::uint64_t baseSequence) {
        Ubiquitty::Rendering::FrameRecordHeader header;
        header.sequence = sequence;
        header.baseSequence = baseSequence;
        header.viewGeneration = 1;
        header.paletteGeneration = terminal->paletteEpoch;
        header.kind = baseSequence == 0 ? Ubiquitty::Rendering::FrameRecordKind::Full : Ubiquitty::Rendering::FrameRecordKind::Delta;
        Ubiquitty::Rendering::FrameDamage damage;
        damage.canReuse = baseSequence != 0;
        Ubiquitty::Rendering::CapturedRowRefresh refresh;
        refresh.canReuseRows = damage.canReuse;
        refresh.rowDirty = dirtyRows;
        return captured->captureRecord(*terminal, options, geometry.metrics, geometry.glyphSlot, header, damage, refresh);
    };
    Ubiquitty::Rendering::FrameCapture::ViewTierOverrides emptyView;
    const auto render = [&](Ubiquitty::Terminal* owner, const Ubiquitty::Rendering::FrameCapture::ViewTierOverrides* view,
                            std::vector<std::uint8_t>& pixels) {
        int width = 0, height = 0;
        return renderer.renderGrid(app().rasterContext, owner, pixels, width, height, 0, nullptr, nullptr, 0, {}, captured.get(), view)
            && width == columns * app().rasterContext.cellWidth() && height == rows * app().rasterContext.cellHeight();
    };
    bool didPass = true;
    const auto check = [&](bool isMet, const char* name) {
        didPass = didPass && isMet;
        g_print("smoke-cursor: captured-retained %s -- %s\n", name, isMet ? "PASS" : "FAIL");
    };
    std::vector<std::uint8_t> full, incremental, reference;
    if (!captureRecord(1, 0) || !render(terminal, &emptyView, full)) {
        check(false, "initial full frame");
        return false;
    }
    Ubiquitty::processBytes(terminal, "\x1b[3;1HIIII JJJJ");
    dirtyRows.fill(0);
    dirtyRows[2] = 1;
    const std::uint64_t partialBefore = renderer.partialFrameCount();
    const bool didDrawDelta = captureRecord(2, 1) && render(terminal, &emptyView, incremental);
    check(didDrawDelta && renderer.partialFrameCount() == partialBefore + 1, "sparse delta loads the target");
    check(render(terminal, nullptr, reference) && incremental == reference, "sparse delta matches a whole rebuild");

    // Restate a known empty view before each refusal, so the refusal is the
    // lineage check rather than the conservative unknown-tier fallback.
    if (!render(terminal, &emptyView, full))
        return false;
    Ubiquitty::processBytes(terminal, "\x1b[2;1HKKKK LLLL");
    dirtyRows.fill(0);
    dirtyRows[1] = 1;
    const std::uint64_t beforeGap = renderer.partialFrameCount();
    check(captureRecord(4, 3) && render(terminal, &emptyView, incremental)
            && renderer.partialFrameCount() == beforeGap,
        "a skipped base rebuilds whole");
    check(render(terminal, nullptr, reference) && incremental == reference, "a skipped base keeps every pixel");
    if (!render(terminal, &emptyView, full))
        return false;

    Ubiquitty::Runtime::TerminalRuntime otherRuntime;
    otherRuntime.init(Ubiquitty::Runtime::RuntimeInitParameters { rows, columns, false });
    Ubiquitty::Terminal* otherTerminal = otherRuntime.borrowTermForRender();
    const std::uint64_t beforeOwnerChange = renderer.partialFrameCount();
    dirtyRows.fill(0);
    check(otherTerminal && captureRecord(5, 4) && render(otherTerminal, &emptyView, incremental)
            && renderer.partialFrameCount() == beforeOwnerChange,
        "another pane cannot load this target");
    check(otherTerminal && render(otherTerminal, nullptr, reference) && incremental == reference, "another pane keeps every pixel");
    if (!render(otherTerminal, &emptyView, full))
        return false;
    auto viewWithExternalDamage = emptyView;
    viewWithExternalDamage.overlayDirtyRows = dirtyRows.data();
    viewWithExternalDamage.overlayDirtyRowCount = rows;
    const std::uint64_t beforeExternalDamage = renderer.partialFrameCount();
    check(captureRecord(6, 5) && render(otherTerminal, &viewWithExternalDamage, incremental)
            && renderer.partialFrameCount() == beforeExternalDamage,
        "external overlay damage rebuilds whole");
    check(render(nullptr, &emptyView, reference) && incremental == reference, "a capture needs no live model read");
    return didPass;
}
