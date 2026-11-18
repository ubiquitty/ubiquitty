// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks forwarding of launch arguments to the application.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeLaunchForwarding()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-launch-forwarding: GTK needs a display\n");
        return 1;
    }
    bool didPass = true;
    const auto check = [&](bool isMet, const char* label) {
        g_print("smoke-launch-forwarding: %s -- %s\n", label, isMet ? "PASS" : "FAIL");
        didPass = didPass && isMet;
    };
    // Exercise GtkApplication's actual option parser, not only our post-parse
    // helper: GTK consumes a plain -- separator before the command-line signal.
    GtkApplication* parser = gtk_application_new("org.ubiquitty.launch-parser-test",
        static_cast<GApplicationFlags>(G_APPLICATION_NON_UNIQUE | G_APPLICATION_HANDLES_COMMAND_LINE));
    registerLaunchOptions(G_APPLICATION(parser));
    struct ParsedLaunch {
        Ubiquitty::Runtime::LaunchRequest request;
        std::string applicationID;
    } parsed;
    g_signal_connect(parser, "command-line", G_CALLBACK(+[](GApplication*, GApplicationCommandLine* commandLine, gpointer data) -> int {
        auto& parsed = *static_cast<ParsedLaunch*>(data);
        parsed.request = launchRequestFromCommandLine(commandLine);
        const char* identifier = nullptr;
        if (g_variant_dict_lookup(g_application_command_line_get_options_dict(commandLine), "app-id", "&s", &identifier))
            parsed.applicationID = identifier;
        return 0;
    }),
        &parsed);
    std::vector<std::string> parserWords { "ubiquitty", "--app-id=org.omarchy.btop", "--ubiquitty-exec=/bin/printf", "--ubiquitty-exec=--",
        "--ubiquitty-exec=-e", "--ubiquitty-exec=argument with spaces" };
    std::vector<char*> parserArgv;
    for (auto& word : parserWords)
        parserArgv.push_back(word.data());
    parserArgv.push_back(nullptr);
    const int parserStatus = g_application_run(G_APPLICATION(parser), static_cast<int>(parserWords.size()), parserArgv.data());
    check(parserStatus == 0 && parsed.request.status == Ubiquitty::Runtime::LaunchRequest::Status::Command
            && parsed.request.command == std::vector<std::string> { "/bin/printf", "--", "-e", "argument with spaces" },
        "GTK option parsing preserves literal child separators, options and spaces");
    check(parsed.applicationID == "org.omarchy.btop", "GTK forwarding preserves the per-window application ID");
    const std::array<const char*, 6> spacedID { "ubiquitty", "--app-id", "org.omarchy.btop", "-e", "env", "--app-id=child" };
    const auto split = Ubiquitty::Runtime::parseLaunchArguments(6, spacedID.data());
    const auto identifier = windowApplicationIDFromArguments(split.terminalArgumentCount, spacedID.data());
    check(identifier && *identifier == "org.omarchy.btop"
            && split.command == std::vector<std::string> { "env", "--app-id=child" },
        "space-separated application ID preserves the child argument boundary");
    const std::array<const char*, 2> emptyID { "ubiquitty", "--app-id=" };
    const std::array<const char*, 2> missingID { "ubiquitty", "--app-id" };
    const std::array<const char*, 2> invalidID { "ubiquitty", "--app-id=not an identifier" };
    check(!windowApplicationIDFromArguments(2, emptyID.data()) && !windowApplicationIDFromArguments(2, missingID.data())
            && !windowApplicationIDFromArguments(2, invalidID.data()),
        "empty, missing and malformed application IDs are rejected");
    g_object_unref(parser);
    const auto settle = [] {
        const gint64 deadline = g_get_monotonic_time() + 600000;
        do {
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
    };
    GtkApplication* application = gtk_application_new("org.ubiquitty.launch-forwarding-test", G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(G_APPLICATION(application), nullptr, nullptr)) {
        g_object_unref(application);
        return 1;
    }
    const auto newestOwner = [&]() -> std::shared_ptr<App> {
        const auto& windows = windowApps().windows;
        for (auto entry = windows.rbegin(); entry != windows.rend(); ++entry) {
            if ((*entry)->application == application && !(*entry)->isClosing)
                return *entry;
        }
        return nullptr;
    };
    const auto hasMarker = [](const std::shared_ptr<App>& owner, std::string_view marker) {
        if (!owner || owner->panes.empty())
            return false;
        AppScope scope(*owner);
        LinuxPane& pane = *owner->panes.front();
        const auto hold = holdPaneModel(pane);
        const auto* term = pane.session->terminal();
        return term && visibleRowText(*term, 0, 0, term->columns).find(marker) != std::string::npos;
    };
    // Child options and spaces stay individual arguments, and each invocation
    // starts in its caller's directory rather than the primary process's cwd.
    const char* initial[] { "ubiquitty", "-e", "/bin/sh", "-c",
        "printf '\\033[H\\033[2JFIRST:%s:%s' \"$PWD\" \"$1\"; exec cat", "sh", "first argument" };
    check(openWindowFromArguments(application, static_cast<int>(std::size(initial)), initial, "/tmp") == 0,
        "initial command accepted");
    settle();
    auto first = newestOwner();
    check(hasMarker(first, "FIRST:/tmp:first argument"), "initial -e preserves argv and caller cwd");
    const char* secondary[] { "ubiquitty", "--", "/bin/sh", "-c",
        "printf '\\033[H\\033[2JSECOND:%s:%s' \"$PWD\" \"$1\"; exec cat", "sh", "--child-option" };
    check(openWindowFromArguments(application, static_cast<int>(std::size(secondary)), secondary, "/") == 0,
        "secondary command accepted");
    settle();
    auto second = newestOwner();
    check(second != first && hasMarker(second, "SECOND:/:--child-option") && hasMarker(first, "FIRST:/tmp:first argument"),
        "secondary invocation opens its own command without replacing the first");
    const char* bare[] { "ubiquitty" };
    check(openWindowFromArguments(application, static_cast<int>(std::size(bare)), bare, "/tmp") == 0,
        "bare secondary invocation accepted");
    settle();
    auto activated = newestOwner();
    check(activated && activated != first && activated != second && activated->launchRequest.has_value()
            && activated->launchRequest->status == Ubiquitty::Runtime::LaunchRequest::Status::None
            && !activated->panes.empty() && activated->panes.front()->session->isShareableLocalSession(),
        "bare secondary invocation opens a login shell without rerunning either command");
    while (GList* windows = gtk_application_get_windows(application))
        gtk_window_destroy(GTK_WINDOW(windows->data));
    settle();
    g_object_unref(application);
    g_print("smoke-launch-forwarding: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
