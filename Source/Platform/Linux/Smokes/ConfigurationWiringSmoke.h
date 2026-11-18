// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Both halves of the configuration land: the process-wide settings and the
// per-terminal ones. A terminal seeded from a document asking for a wide
// ambiguous width, NFC search, dropped invalid UTF-8 and a named built-in
// theme reads all four back.
/// Checks that process-wide and per-terminal configuration reaches a new terminal.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeConfigurationWiring()
{
    const Ubiquitty::Themes::Theme* theme = Ubiquitty::Themes::builtInGet(0);
    if (!theme) {
        g_printerr("smoke-config-wiring: no built-in theme\n");
        return 1;
    }
    Ubiquitty::Preferences::Values document;
    document.ambiguousWidth = 2;
    document.normalization = "nfc";
    document.invalidUTF8 = "drop";
    document.themeName = theme->name;

    Ubiquitty::Runtime::TerminalRuntime runtime;
    runtime.init(Ubiquitty::Runtime::RuntimeInitParameters { startupRows, startupColumns, false });
    Ubiquitty::Terminal* term = runtime.borrowTermForRender();
    if (!term) {
        g_printerr("smoke-config-wiring: no term\n");
        return 1;
    }
    applyProcessConfiguration(document);
    (void)Ubiquitty::Runtime::seedTerminalConfiguration(*term, document);

    const auto sameChannel = [](auto terminalChannel, auto themeChannel) { return terminalChannel == Ubiquitty::channel8To16(themeChannel); };
    const bool isAmbiguousWidthApplied = term->ambiguousWidth == Ubiquitty::Unicode::Width::AmbiguousWidth::Wide;
    const bool isNormalizationNFC = Ubiquitty::Screen::ScrollSearch::normalizationForm() == Ubiquitty::Unicode::NormalizationForm::NFC;
    const bool invalidUTF8Matches = Ubiquitty::Modes::invalidUTF8Policy(term) == Ubiquitty::Unicode::InvalidUTF8Policy::Drop;
    const bool doesThemeMatch = sameChannel(term->palette.defaultBackground.red, theme->defaultBackground.red)
        && sameChannel(term->palette.defaultBackground.green, theme->defaultBackground.green)
        && sameChannel(term->palette.defaultBackground.blue, theme->defaultBackground.blue)
        && sameChannel(term->palette.indexed[0].red, theme->ansi[0].red);
    const bool isWired = isAmbiguousWidthApplied && isNormalizationNFC && invalidUTF8Matches && doesThemeMatch;

    // Back to the defaults, so the process the smoke ran in is left as found.
    applyProcessConfiguration(Ubiquitty::Preferences::Values {});
    g_print("smoke-config-wiring: width=%d normalization=%d invalid-utf8=%d theme=%d -- %s\n",
        static_cast<int>(isAmbiguousWidthApplied), static_cast<int>(isNormalizationNFC), static_cast<int>(invalidUTF8Matches), static_cast<int>(doesThemeMatch), isWired ? "PASS" : "FAIL");
    return isWired ? 0 : 1;
}
