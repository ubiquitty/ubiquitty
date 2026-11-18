// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks independent application state across multiple windows.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeMultiwindow()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-multiwindow: GTK needs a display\n");
        return 1;
    }
    bool didPass = true;
    const auto check = [&](bool isMet, const char* label) {
        g_print("smoke-multiwindow: %s -- %s\n", label, isMet ? "PASS" : "FAIL");
        didPass = didPass && isMet;
    };
    const auto settle = [] {
        const gint64 deadline = g_get_monotonic_time() + 600000;
        do {
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
    };
    GtkApplication* application = gtk_application_new("org.ubiquitty.multiwindow-test", G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(G_APPLICATION(application), nullptr, nullptr)) {
        g_object_unref(application);
        return 1;
    }
    onActivate(application, nullptr);
    settle();
    GList* windows = gtk_application_get_windows(application);
    GtkWindow* firstWindow = windows ? GTK_WINDOW(windows->data) : nullptr;
    std::shared_ptr<App> first = firstWindow && appForWindow(firstWindow) ? appForWindow(firstWindow)->shared_from_this() : nullptr;
    if (!first || first->panes.empty()) {
        check(false, "first activation owns a window and pane");
        g_object_unref(application);
        return 1;
    }
    LinuxPane* firstPane = first->panes.front().get();
    auto* firstSession = firstPane->session;
    const int firstDescriptor = firstSession ? firstSession->fileDescriptor() : -1;
    onActivate(application, nullptr);
    settle();
    GtkWindow* secondWindow = nullptr;
    for (GList* item = gtk_application_get_windows(application); item; item = item->next) {
        if (item->data != firstWindow)
            secondWindow = GTK_WINDOW(item->data);
    }
    std::shared_ptr<App> second = secondWindow && appForWindow(secondWindow) ? appForWindow(secondWindow)->shared_from_this() : nullptr;
    check(second && second != first && g_list_length(gtk_application_get_windows(application)) == 2,
        "two activations own two windows in one application");
    if (!second || second->panes.empty()) {
        gtk_window_destroy(firstWindow);
        g_object_unref(application);
        return 1;
    }
    LinuxPane* secondPane = second->panes.front().get();
    check(firstSession && firstPane->session == firstSession && firstSession->fileDescriptor() == firstDescriptor
            && firstSession->isShareableLocalSession() && secondPane->session
            && secondPane->session != firstSession && secondPane->session->fileDescriptor() != firstDescriptor
            && first->model.get() != second->model.get() && &first->vulkan != &second->vulkan,
        "second activation preserves the first session and owns its own renderer");

    int signalCount = 0;
    GtkWidget* button = GTK_WIDGET(g_object_ref_sink(gtk_button_new()));
    using SignalProbe = std::pair<App*, int*>;
    SignalProbe signalData { first.get(), &signalCount };
    {
        AppScope scope(*first);
        windowSignalConnect(button, "clicked", G_CALLBACK(+[](GtkButton*, gpointer data) {
            auto& state = *static_cast<SignalProbe*>(data);
            if (&app() == state.first)
                ++*state.second;
        }),
            &signalData);
    }
    {
        AppScope scope(*second);
        g_signal_emit_by_name(button, "clicked");
        check(signalCount == 1 && &app() == second.get(), "signals retain their owner and restore the caller context");
    }
    g_object_unref(button);

    const auto sendMarker = [&](App& owner, LinuxPane& pane, const char* marker) {
        AppScope scope(owner);
        const std::string command = std::string("printf '\\033[H\\033[2J") + marker + "\\n'\n";
        pane.session->sendInput(command);
        armPTYWriteDrain(&pane);
    };
    const auto hasMarker = [](App& owner, LinuxPane& pane, std::string_view marker) {
        AppScope scope(owner);
        const auto hold = holdPaneModel(pane);
        const auto* term = pane.session ? pane.session->terminal() : nullptr;
        return term && visibleRowText(*term, 0, 0, term->columns).find(marker) != std::string::npos;
    };
    sendMarker(*first, *firstPane, "FIRST-WINDOW");
    sendMarker(*second, *secondPane, "SECOND-WINDOW");
    settle();
    check(hasMarker(*first, *firstPane, "FIRST-WINDOW") && hasMarker(*second, *secondPane, "SECOND-WINDOW"),
        "both windows consume their own PTY output");
    check(firstPane->picture && secondPane->picture
            && gtk_picture_get_paintable(GTK_PICTURE(firstPane->picture))
            && gtk_picture_get_paintable(GTK_PICTURE(secondPane->picture)),
        "both windows publish a rendered frame");
    gtk_window_destroy(secondWindow);
    settle();
    check(second->isClosing && !first->isClosing && firstPane->session == firstSession
            && firstSession->isShareableLocalSession(),
        "closing the second window preserves the first child");
    sendMarker(*first, *firstPane, "AFTER-CLOSE");
    settle();
    check(hasMarker(*first, *firstPane, "AFTER-CLOSE"), "the surviving window keeps processing output");
    gtk_window_destroy(firstWindow);
    settle();
    g_object_unref(application);
    g_print("smoke-multiwindow: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
