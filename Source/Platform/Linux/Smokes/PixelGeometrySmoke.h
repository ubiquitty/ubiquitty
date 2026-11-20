// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks reported grid and pixel geometry against the renderer.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokePixelGeometry()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-pixel-geometry: GTK needs a display\n");
        return 1;
    }
    constexpr std::string_view configuration = "[font]\nfamily = \"GNU Unifont\"\nsize = 10\nline_spacing = 0\n"
                                               "[appearance]\npadding_left = 3\npadding_right = 5\npadding_top = 7\npadding_bottom = 11\n";
    if (!Ubiquitty::Preferences::configure(std::string(configuration), Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
        g_printerr("smoke-pixel-geometry: configuration failed\n");
        return 1;
    }
    setupFonts();
    LinuxPane& pane = *activePane();
    pane.session->start(3, 5);
    pane.rows = 3;
    pane.columns = 5;
    Ubiquitty::Terminal* terminal = pane.session->terminal();
    if (!terminal) {
        g_printerr("smoke-pixel-geometry: no terminal\n");
        return 1;
    }
    pane.picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
    int failures = 0;
    const auto check = [&](bool condition, const char* message) {
        if (!condition) {
            g_printerr("smoke-pixel-geometry: %s\n", message);
            ++failures;
        }
    };
    const auto checkReply = [&](std::string_view query, std::string_view expected) {
        Ubiquitty::processBytes(terminal, query);
        std::array<char, 128> reply;
        const int length = Ubiquitty::drainOutput(terminal, reply);
        check(std::string_view(reply.data(), static_cast<std::size_t>(length)) == expected, "pixel size report differs");
    };
    applyPanePadding(pane);
    checkReply("\033[16t\033[14t\033[?7402h\033[14t", "\033[6;16;8t\033[4;48;40t\033[4;66;48t");

    gtk_widget_allocate(pane.picture, 64, 80, -1, nullptr);
    check(publishPanePixelGeometry(pane), "allocated drawable was not published");
    checkReply("\033[14t", "\033[4;80;64t");
    check(!publishPanePixelGeometry(pane), "unchanged geometry was published again");

    gtk_widget_allocate(pane.picture, 65, 81, -1, nullptr);
    check(publishPanePixelGeometry(pane), "sub-cell drawable resize was not published");
    check(terminal->columns == 5 && terminal->rows == 3, "drawable resize changed the grid");
    checkReply("\033[14t", "\033[4;81;65t");

    pane.rows = 4;
    pane.columns = 6;
    check(publishPanePixelGeometry(pane), "grid resize was not published");
    checkReply("\033[?7402l\033[14t", "\033[4;64;48t");

    app().scale = 2;
    app().rasterContext.setDeviceScale(2);
    rebuildFontsFromPreferences();
    check(!publishPanePixelGeometry(pane), "font rebuild did not publish geometry");
    // The window size a program reads follows mode 7402: the text area while
    // it is reset, the drawable while it is set. Turning it on owes the PTY a
    // new winsize, which the next publication delivers.
    checkReply("\033[16t\033[14t\033[?7402h\033[14t", "\033[6;32;16t\033[4;128;96t\033[4;162;130t");
    // Written past the drain, whose pass would have published the mode: the
    // tick reads the publication to learn whether anything it publishes from
    // has changed, and takes no lock to ask.
    pane.session->republishSnapshot();
    check(publishPanePixelGeometry(pane), "a fullscreen-content toggle did not republish the reported size");

    Ubiquitty::processBytes(terminal, "\033[?7402l");
    pane.session->republishSnapshot();
    constexpr std::string_view changedPadding = "[font]\nfamily = \"GNU Unifont\"\nsize = 10\nline_spacing = 0\n"
                                                "[appearance]\npadding_left = 4\npadding_right = 6\npadding_top = 8\npadding_bottom = 12\n";
    check(Ubiquitty::Preferences::configure(std::string(changedPadding), Ubiquitty::Preferences::ParseMode::Strict).isApplied, "padding configuration failed");
    check(gtk_widget_get_margin_start(pane.picture) == 0 && gtk_widget_get_margin_end(pane.picture) == 0
            && gtk_widget_get_margin_top(pane.picture) == 0 && gtk_widget_get_margin_bottom(pane.picture) == 0,
        "padding became an external picture clip");
    const auto changedGeometry = paneGeometry(pane, { pane.columns, pane.rows });
    check(changedGeometry.rasterOrigin.x == 8 && changedGeometry.rasterOrigin.y == 16,
        "live padding change did not reach the internal frame origin");
    check(!publishPanePixelGeometry(pane), "live padding change did not publish geometry");
    int pixelX = 0;
    int pixelY = 0;
    Ubiquitty::processBytes(terminal, "\033[?7402l");
    devicePixelAtPoint(10000, 10000, pixelX, pixelY);
    check(pixelX == 96 && pixelY == 128, "pixel mouse coordinates exceed the published grid");

    app().scale = 1;
    app().rasterContext.setDeviceScale(1);
    rebuildFontsFromPreferences();
    Ubiquitty::processBytes(terminal, "\033[?25l");
    app().window = gtk_window_new();
    app().paneContainer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(pane.picture, TRUE);
    gtk_widget_set_vexpand(pane.picture, TRUE);
    gtk_picture_set_content_fit(GTK_PICTURE(pane.picture), GTK_CONTENT_FIT_FILL);
    gtk_box_append(GTK_BOX(app().paneContainer), pane.picture);
    gtk_window_set_child(GTK_WINDOW(app().window), app().paneContainer);
    windowSignalConnect(app().window, "realize", G_CALLBACK(onWindowRealized), nullptr);
    gtk_window_set_default_size(GTK_WINDOW(app().window), 160, 120);
    const auto waitUntil = [](const auto& predicate) {
        const gint64 deadline = g_get_monotonic_time() + 5000000;
        while (!predicate() && g_get_monotonic_time() < deadline) {
            while (g_main_context_iteration(nullptr, FALSE)) {
            }
            g_usleep(1000);
        }
        return predicate();
    };
    const int initialWidth = terminal->drawablePixelWidth;
    gtk_window_present(GTK_WINDOW(app().window));
    check(waitUntil([&] {
        return gtk_widget_get_mapped(app().window) && terminal->drawablePixelWidth != initialWidth && app().tickCallbackID == 0;
    }),
        "initial window layout did not publish and return to idle");
    const int idleColumns = terminal->columns;
    const int idleRows = terminal->rows;
    gtk_window_set_default_size(GTK_WINDOW(app().window), 240, 184);
    check(waitUntil([&] {
        return terminal->columns > idleColumns && terminal->rows > idleRows && app().tickCallbackID == 0;
    }),
        "native resize did not wake the idle clock, publish, and return to idle");
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    app().paneContainer = nullptr;

    if (pane.session->launchShellCommand("while IFS= read -r line; do :; done")) {
        app().scale = 2;
        app().fontSizePoints = 96;
        app().rasterContext.setDeviceScale(2);
        rebuildFontsFromPreferences();
        const int cellWidth = static_cast<int>(std::lround(logicalCellWidth()));
        const int cellHeight = static_cast<int>(std::lround(logicalCellHeight()));
        pane.columns = 1023;
        pane.rows = 2;
        pane.session->resizeGrid(2, 1023, Ubiquitty::Modes::ReflowMode::Fixed);
        gtk_widget_allocate(pane.picture, 1023 * cellWidth + 10, 2 * cellHeight + 20, -1, nullptr);
        publishPanePixelGeometry(pane);
        check(terminal->textAreaPixelWidth == 65535 && terminal->drawablePixelWidth == 65535, "wide grid did not saturate");
        const std::uint64_t deliveries = pane.session->windowSizeDeliveryCount();
        gtk_widget_allocate(pane.picture, 1024 * cellWidth + 10, 2 * cellHeight + 20, -1, nullptr);
        // A held frame exercises resize delivery without allocating a texture
        // for a nearly hundred-thousand-pixel-wide test grid.
        Ubiquitty::processBytes(terminal, "\033[?2026h");
        onTick(nullptr, nullptr, nullptr);
        struct winsize windowSize {};
        check(::ioctl(pane.session->fileDescriptor(), TIOCGWINSZ, &windowSize) == 0
                && windowSize.ws_col == 1024 && windowSize.ws_row == 2 && windowSize.ws_xpixel == 65535,
            "unchanged saturated pixels suppressed the PTY grid resize");
        check(pane.session->windowSizeDeliveryCount() == deliveries + 1, "grid resize was not delivered exactly once");
        pane.session->close();
    } else {
        check(false, "could not open the grid-resize test PTY");
    }
    g_object_unref(pane.picture);
    pane.picture = nullptr;
    g_print("smoke-pixel-geometry: %s (%d failures)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
