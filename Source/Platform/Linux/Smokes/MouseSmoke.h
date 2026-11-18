// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// SGR mouse (DECSET 1000 + 1006) reports pinned at one cell: the Linux-native
// button identities, the four wheel directions, and two numbers outside the
// set, which must encode as nothing.
/// Checks SGR encoding of native mouse buttons and wheel directions.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeMouse()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-mouse: no term\n");
        return 1;
    }
    const char enableSGR[] = "\x1b[?1000h\x1b[?1006h";
    Ubiquitty::processBytes(term, std::string_view(enableSGR, sizeof(enableSGR) - 1));

    const int row = 2, column = 5;
    struct Expectation {
        std::string_view label;
        int buttonCode;
        std::string_view report;
    };
    using Ubiquitty::Input::WheelDirection;
    using Ubiquitty::Input::xtermWheelButtonCode;
    const std::array<Expectation, 9> expectations { {
        { "left", mouseButtonCode(GDK_BUTTON_PRIMARY), "\x1b[<0;6;3M" },
        { "wheel-up", xtermWheelButtonCode(WheelDirection::Up), "\x1b[<64;6;3M" },
        { "wheel-down", xtermWheelButtonCode(WheelDirection::Down), "\x1b[<65;6;3M" },
        { "wheel-left", xtermWheelButtonCode(WheelDirection::Left), "\x1b[<66;6;3M" },
        { "wheel-right", xtermWheelButtonCode(WheelDirection::Right), "\x1b[<67;6;3M" },
        { "button-8", mouseButtonCode(8), "\x1b[<128;6;3M" },
        { "button-9", mouseButtonCode(9), "\x1b[<129;6;3M" },
        { "button-10", mouseButtonCode(10), "\x1b[<130;6;3M" },
        { "button-11", mouseButtonCode(11), "\x1b[<131;6;3M" },
    } };
    const bool didRefuseUnsupported = mouseButtonCode(4) == -1 && mouseButtonCode(12) == -1;
    bool didPass = didRefuseUnsupported;
    for (const Expectation& expectation : expectations) {
        std::array<char, 32> report {};
        const int length = Ubiquitty::encodeMouseReport(*term, Ubiquitty::Mouse::EventType::Press, expectation.buttonCode, row, column, 0, report, -1, -1);
        const bool matches = length >= 0 && std::string_view(report.data(), static_cast<std::size_t>(length)) == expectation.report;
        g_print("smoke-mouse: %-11.*s Cb=%d %s\n", static_cast<int>(expectation.label.size()), expectation.label.data(), expectation.buttonCode, matches ? "PASS" : "FAIL");
        didPass = didPass && matches;
    }
    // A scroll need not carry coordinates. The pointer's pane-local point
    // must survive even while the host owns mouse reporting; defaulting to
    // (0,0) sends tmux's wheel to its top-left pane instead of the hovered pane.
    const double pointerX = 5.5 * app().rasterContext.cellWidth() / app().scale;
    const double pointerY = 2.5 * app().rasterContext.cellHeight() / app().scale;
    onMouseEnter(nullptr, pointerX, pointerY, activePane());
    const graphene_point_t point = pointerPointForScroll(*activePane(), nullptr);
    Ubiquitty::Input::ScrollFact wheel;
    int wheelRow = 0, wheelColumn = 0;
    cellAtPoint(point.x, point.y, wheelRow, wheelColumn);
    wheel.row = wheelRow;
    wheel.column = wheelColumn;
    wheel.deltaY = 1;
    Ubiquitty::Input::PointerLadder ladder;
    const auto routedWheel = Ubiquitty::Input::routeScroll(ladder, *term, wheel, currentWheelPolicy());
    const bool didWheelTargetPass = routedWheel.wasConsumed
        && std::string_view(routedWheel.bytes.data(), static_cast<std::size_t>(routedWheel.byteLength)) == "\x1b[<64;6;3M";
    didPass = didPass && didWheelTargetPass;
    g_print("smoke-mouse: wheel-at-pointer=%s\n", didWheelTargetPass ? "PASS" : "FAIL");
    g_print("smoke-mouse: unsupported-buttons=%s overall=%s\n", didRefuseUnsupported ? "PASS" : "FAIL", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
