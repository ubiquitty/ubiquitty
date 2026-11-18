// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-smartclick — smart double-click token detection (the gate selectionOperationBeginWord
// uses when config.smart_double_click is on). Feeds a line with a URL, a path, and
// plain words, and asserts smartTokenSpanAtCell selects the WHOLE URL / path token
// when the click lands inside it, and reports no token on a plain word.
/// Checks smart selection of URLs and paths while leaving plain words unclassified.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSmartClick()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-smartclick: no term\n");
        return 1;
    }
    const char* line = "see https://example.com/x now and /usr/local/bin too";
    Ubiquitty::processBytes(term, line);

    auto spanText = [&](int column0, int column1) {
        std::string outputBuffer;
        for (int column = column0; column <= column1; ++column) {
            const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, column);
            const uint32_t codePoint = (cell != nullptr) ? cell->codePoint : static_cast<uint32_t>(' ');
            outputBuffer.push_back((codePoint >= 0x20 && codePoint < 0x7F) ? static_cast<char>(codePoint) : '?');
        }
        return outputBuffer;
    };

    const auto urlSpan = smartTokenSpanAtCell(0, 10); // column 10 is inside the URL
    const std::string urlText = urlSpan ? spanText(urlSpan->first, urlSpan->last) : std::string();
    const auto pathSpan = smartTokenSpanAtCell(0, 40); // column 40 is inside the path
    const std::string pathText = pathSpan ? spanText(pathSpan->first, pathSpan->last) : std::string();
    const bool hasNoTokenOnAPlainWord = !smartTokenSpanAtCell(0, 1); // column 1 = 'e' of "see"

    const bool didPass = urlSpan && urlText == "https://example.com/x" && pathSpan && pathText == "/usr/local/bin" && hasNoTokenOnAPlainWord;
    g_print("smoke-smartclick: url=\"%s\" path=\"%s\" word-has-no-token=%d -- %s\n", urlText.c_str(), pathText.c_str(), static_cast<int>(hasNoTokenOnAPlainWord), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
