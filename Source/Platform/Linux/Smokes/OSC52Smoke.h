// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Feed an OSC 52 SET whose payload base64-encodes "PASTED" and assert the
// ClipboardClient recorded the decoded bytes — the OSC 52 copy path (Core does
// the base64 decode + routes to ClipboardClient::writeClipboard).
/// Checks decoded clipboard bytes delivered by OSC 52.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeOSC52()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-osc52: no GTK display; run under xvfb-run\n");
        return 1;
    }
    app().window = gtk_window_new();
    Ubiquitty::Linux::Clipboard::setReadRequestHandler(requestClipboardReadFromGTK);
    activePane()->clipboardClient.setRequester(activePane());
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-osc52: no term\n");
        return 1;
    }
    term->clipboardClient = &activePane()->clipboardClient;
    term->capabilityPolicy = &app().capabilityPolicy; // a null policy answers PAL's defaults, not this frontend's
    // OSC 52 ; c ; <base64> BEL — "UEFTVEVE" is base64("PASTED").
    const char osc[] = "\x1b]52;c;UEFTVEVE\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    const std::string captured = Ubiquitty::Linux::Clipboard::lastSetText();
    const bool didWrite = captured == "PASTED";
    term->capabilityPolicy = nullptr;
    term->osc52ClipboardReadPolicy = Ubiquitty::OSC::ClipboardReadPolicy::Allow;
    const std::array<Ubiquitty::ClipboardItem, 2> items {
        Ubiquitty::ClipboardItem { "text/plain", std::span<const char>("P", 1) },
        Ubiquitty::ClipboardItem { "text/html", std::span<const char>("<b>P</b>", 8) },
    };
    activePane()->clipboardClient.writeClipboardItems(Ubiquitty::ClipboardBuffer::Primary, items);
    std::string reply;
    activePane()->session->setReplySink([](void* context, std::string_view bytes) {
        static_cast<std::string*>(context)->append(bytes);
    },
        &reply);
    const std::string enable = "\033[?2004;5522h";
    activePane()->session->feedBytes({ enable.data(), enable.size() });
    pasteClipboard(gtk_widget_get_primary_clipboard(app().window), Ubiquitty::ClipboardBuffer::Primary);
    const bool didNotify = reply.starts_with("\033]5522;type=read:status=OK:loc=primary\033\\")
        && reply.find("\033[200~") == std::string::npos;
    reply.clear();
    const std::string read = "\033]5522;type=read:loc=primary;dGV4dC9odG1s\033\\";
    activePane()->session->feedBytes({ read.data(), read.size() });
    const gint64 deadline = g_get_monotonic_time() + 2000000;
    while (term->isOSC52ClipboardReadInFlight && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(nullptr, false)) {
        }
        g_usleep(1000);
    }
    const bool didRead = reply.find("mime=dGV4dC9odG1s;PGI+UDwvYj4=") != std::string::npos
        && reply.ends_with("status=DONE\033\\");
    activePane()->session->setReplySink(nullptr, nullptr);
    term->clipboardClient = nullptr;
    const bool didPass = didWrite && didNotify && didRead;
    g_print("smoke-osc52: primary notification=%s, HTML read=%s\n", didNotify ? "PASS" : "FAIL", didRead ? "PASS" : "FAIL");
    g_print("smoke-osc52: clipboard write = \"%s\" -- %s (expected \"PASTED\")\n", captured.c_str(), didPass ? "PASS" : "FAIL");
    Ubiquitty::Linux::Clipboard::setReadRequestHandler(nullptr);
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    return didPass ? 0 : 1;
}
