// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// A document saved with an error is said in the window, not only on standard
// error. The bar under the panes names the line through the same subscription
// a live reload reaches; a dismissed line stays quiet while the document
// repeats it, another line is heard, and a document that applies whole
// withdraws it. The setting on the refused line keeps the value it had.
/// Checks that configuration errors reach the window and preserve refused settings.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeConfigurationError()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-config-error: GTK needs a display\n");
        return 1;
    }
    int failures = 0;
    const auto check = [&](bool isMet, const char* message) {
        if (!isMet) {
            g_printerr("smoke-config-error: FAIL %s\n", message);
            ++failures;
        }
    };
    const auto save = [](const char* document) {
        (void)Ubiquitty::Preferences::configure(std::string(document), Ubiquitty::Preferences::ParseMode::Permissive);
    };
    const auto isBarShown = [] { return gtk_action_bar_get_revealed(GTK_ACTION_BAR(app().configurationBar)) != FALSE; };
    const auto shownLine = [] { return std::string(gtk_label_get_text(GTK_LABEL(app().configurationLabel))); };

    // The startup order: a configure before the bar exists leaves the line,
    // and the bar shows it when it is built.
    save("[font]\nsize = 15\n");
    save("[font]\nsize = \"large\"\n");
    GtkWidget* bar = GTK_WIDGET(g_object_ref_sink(makeConfigurationBar()));
    const std::string wrongKind = "config.toml line 2: font.size takes a number \xE2\x80\x94 ignored";
    check(isBarShown(), "a line refused before the window existed is not shown when the bar is built");
    check(shownLine() == wrongKind, "the bar does not name the refused line");
    check(Ubiquitty::Preferences::Effective::fontSize(Ubiquitty::Preferences::values()) == 15.0, "the refused line did not keep the size it had");

    onConfigurationBarDismissed(nullptr, nullptr);
    check(!isBarShown(), "a dismissed line is still shown");
    save("[font]\nsize = \"large\"\n");
    check(!isBarShown(), "a dismissed line came back when the same document was saved again");

    save("[font]\nsize = 16\n[cursor]\nblink = \"yes\"\n");
    check(isBarShown(), "a different refused line is not shown after another was dismissed");
    check(shownLine() == "config.toml line 4: cursor.blink takes true or false \xE2\x80\x94 ignored", "the bar does not name the new line");

    save("[font]\nsize = 16\n");
    check(!isBarShown(), "a document that applied whole left the bar shown");
    check(shownLine().empty(), "a document that applied whole left the line in the bar");

    // Back to the defaults, so the process the smoke ran in is left as found.
    save("");
    g_object_unref(bar);
    app().configurationBar = nullptr;
    app().configurationLabel = nullptr;
    g_print("smoke-config-error: %s (%d failures)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
