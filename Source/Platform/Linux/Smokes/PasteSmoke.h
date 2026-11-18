// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Assert wrapPaste brackets text under DECSET-2004 and passes it through
// otherwise — the pure paste-wrapping helper, no display / Ubiquitty::Terminal needed.
/// Checks bracketed paste with its terminal mode enabled and disabled.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokePaste()
{
    const std::string bracketed = Ubiquitty::Input::wrapPaste("hi", Ubiquitty::Input::BracketedPaste::Enabled);
    const std::string plain = Ubiquitty::Input::wrapPaste("hi", Ubiquitty::Input::BracketedPaste::Disabled);
    const bool didBracketedPasteMatch = bracketed == "\x1b[200~hi\x1b[201~";
    const bool didPlainPasteMatch = plain == "hi";
    g_print("smoke-paste: bracketed=\"");
    printEscaped(bracketed);
    g_print("\" plain=\"");
    printEscaped(plain);
    g_print("\" -- %s\n", (didBracketedPasteMatch && didPlainPasteMatch) ? "PASS" : "FAIL");
    return (didBracketedPasteMatch && didPlainPasteMatch) ? 0 : 1;
}
