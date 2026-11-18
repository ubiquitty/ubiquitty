// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-font-zoom — Ctrl++/−/0 runtime font zoom: assert the derived cell grows on
// zoom-in and restores on reset. No-op (auto-PASS) in Unifont mode (a fixed bitmap).
/// Checks cell growth on font zoom and restoration on reset.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFontZoom()
{
    setupFonts();
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        g_print("smoke-font-zoom: PASS (Unifont — zoom not applicable)\n");
        return 0;
    }
    const int width0 = app().rasterContext.cellWidth();
    const int height0 = app().rasterContext.cellHeight();
    const double points0 = app().fontSizePoints;
    applyFontZoom(app().fontPixelSize + 8);
    const int width1 = app().rasterContext.cellWidth();
    const int height1 = app().rasterContext.cellHeight();
    const bool grew = width1 > width0 && height1 > height0;
    resetFontZoom();
    const bool restored = app().fontSizePoints == points0 && app().rasterContext.cellWidth() == width0 && app().rasterContext.cellHeight() == height0;
    bool didPass = grew && restored;
    const auto check = [&](bool condition, const char* message) {
        if (!condition) {
            g_printerr("smoke-font-zoom: FAIL: %s\n", message);
            didPass = false;
        }
    };
    const std::optional<std::string> savedFamilyOverride = std::getenv("UBIQUITTY_FONT")
        ? std::optional<std::string>(std::getenv("UBIQUITTY_FONT"))
        : std::nullopt;
    const std::optional<std::string> savedSizeOverride = std::getenv("UBIQUITTY_FONT_SIZE")
        ? std::optional<std::string>(std::getenv("UBIQUITTY_FONT_SIZE"))
        : std::nullopt;
    unsetenv("UBIQUITTY_FONT");
    unsetenv("UBIQUITTY_FONT_SIZE");
    const auto configureLive = [&](const char* document) {
        check(Ubiquitty::Preferences::configure(std::string(document), Ubiquitty::Preferences::ParseMode::Strict).isApplied,
            "the live font document was refused");
        applyLiveConfiguration();
    };
    configureLive("[font]\nfamily = \"Ubiquitty Missing Font Fixture\"\nsize = 12\n");
    check(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native && app().glyphRasterizer->ready(),
        "an unavailable family keeps Fontconfig’s working native fallback");
    configureLive("[font]\nfamily = \"GNU Unifont\"\nsize = 12\n");
    check(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap, "an explicit bitmap selection takes effect");
    configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 13.5\nsymbol_fallback = \"Monaspace Neon\"\n");
    check(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native && app().glyphRasterizer->ready(),
        "a corrected family recovers from the bitmap fallback");
    check(app().fontFamily == "JetBrains Mono" && app().fallbackFontName == "Monaspace Neon", "the primary and symbol families reload");
    check(app().fontSizePoints == 13.5 && configuredFontSizePoints(Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences())) == 13.5,
        "a configured fractional size updates the reset target");
    applyFontZoom(20);
    resetFontZoom();
    check(app().fontSizePoints == 13.5, "font reset rounded the configured fractional point size");
    applyFontZoom(20);
    configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 13.5\nline_spacing = 2\n");
    check(app().fontSizePoints == 20 && configuredFontSizePoints(Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences())) == 13.5,
        "a spacing edit preserves the live zoom");
    configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 15.5\n");
    check(app().fontSizePoints == 15.5 && configuredFontSizePoints(Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences())) == 15.5,
        "an actual size edit replaces the live zoom");
    configureLive("[font]\nfamily = \"GNU Unifont\"\nsize = 15.5\n");
    check(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap, "a configured bitmap family takes effect");
    configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 15.5\n");
    check(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native, "a native family replaces a configured bitmap face");
    setenv("UBIQUITTY_FONT", "JetBrains Mono", 1);
    setenv("UBIQUITTY_FONT_SIZE", "18.5", 1);
    app().areFontsSetUp = false;
    setupFonts();
    app().appliedRenderConfiguration = Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences());
    applyFontZoom(22);
    configureLive("[font]\nfamily = \"GNU Unifont\"\nsize = 24\n");
    check(app().fontFamily == "JetBrains Mono" && app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native,
        "the environment family keeps priority over a live edit");
    check(app().fontSizePoints == 22 && configuredFontSizePoints(Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences())) == 18.5,
        "an overridden size edit preserves the live zoom and reset target");
    resetFontZoom();
    check(app().fontSizePoints == 18.5, "font reset rounded the environment point-size override");
    unsetenv("UBIQUITTY_FONT");
    unsetenv("UBIQUITTY_FONT_SIZE");
    configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 8.5\n");
    const int fractionalWidth = app().rasterContext.cellWidth();
    const int fractionalHeight = app().rasterContext.cellHeight();
    applyFontZoom(14);
    resetFontZoom();
    check(app().fontSizePoints == 8.5 && app().rasterContext.cellWidth() == fractionalWidth && app().rasterContext.cellHeight() == fractionalHeight,
        "font reset did not restore the exact 8.5-point cell metrics");
    if (gtk_init_check()) {
        configureLive("[font]\nfamily = \"JetBrains Mono\"\nsize = 11\nline_spacing = 0\n"
                      "[appearance]\npadding_left = 3\npadding_right = 5\npadding_top = 7\npadding_bottom = 11\n");
        LinuxPane& pane = *activePane();
        pane.session->start(startupRows, startupColumns);
        // A mounted, allocated picture exercises the same font-size path as a
        // live pane without mapping a window or taking the user's focus.
        GtkWidget* parent = GTK_WIDGET(g_object_ref_sink(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)));
        GtkWidget* picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
        GtkWidget* previousPicture = std::exchange(pane.picture, picture);
        gtk_box_append(GTK_BOX(parent), picture);
        constexpr int viewportWidth = 800;
        constexpr int viewportHeight = 480;
        gtk_widget_allocate(picture, viewportWidth, viewportHeight, -1, nullptr);
        if (pane.session->launchShellCommand("while IFS= read -r line; do :; done")) {
            const int previousScale = app().scale;
            for (const int scale : { 1, 2 }) {
                app().scale = scale;
                app().rasterContext.setDeviceScale(scale);
                rebuildFontsFromPreferences();
                updatePaneGridFromAllocation(pane);
                publishPanePixelGeometry(pane);
                for (const int direction : { 1, -1, 1, -1 }) {
                    // Let the pixel-only coalescing interval expire. An old-grid
                    // report would now be delivered, rather than hidden by it.
                    g_usleep(50000);
                    const auto before = pane.session->windowSizeDeliveryCount();
                    applyFontZoom(app().fontPixelSize + direction);
                    const int cellWidth = app().rasterContext.cellWidth();
                    const int cellHeight = app().rasterContext.cellHeight();
                    // The fixed 800x480 logical allocation contains explicit
                    // 3/5/7/11 logical-pixel padding. These independent content
                    // extents include both opposing edges at each device scale.
                    const int columns = 792 * scale / cellWidth;
                    const int rows = 462 * scale / cellHeight;
                    struct winsize windowSize {};
                    check(::ioctl(pane.session->fileDescriptor(), TIOCGWINSZ, &windowSize) == 0
                            && windowSize.ws_col == columns && windowSize.ws_row == rows
                            && windowSize.ws_xpixel == columns * cellWidth && windowSize.ws_ypixel == rows * cellHeight,
                        "font zoom did not publish the final grid and pixels together");
                    check(pane.columns == columns && pane.rows == rows,
                        "font zoom left the pane on its previous grid until the next frame");
                    {
                        const auto hold = holdPaneModel(pane);
                        const auto* terminal = pane.session->terminal();
                        check(terminal && terminal->cellPixelWidth == cellWidth && terminal->cellPixelHeight == cellHeight
                                && terminal->textAreaPixelWidth == columns * cellWidth && terminal->textAreaPixelHeight == rows * cellHeight
                                && terminal->drawablePixelWidth == viewportWidth * scale && terminal->drawablePixelHeight == viewportHeight * scale,
                            "font zoom did not retain distinct text and padding-inclusive drawable geometry");
                        g_print("smoke-font-zoom: scale=%d point-size=%g cell=%dx%d expected-grid=%dx%d PTY=%dx%d pixels=%dx%d drawable=%dx%d\n",
                            scale, app().fontSizePoints, cellWidth, cellHeight, columns, rows,
                            static_cast<int>(windowSize.ws_col), static_cast<int>(windowSize.ws_row),
                            static_cast<int>(windowSize.ws_xpixel), static_cast<int>(windowSize.ws_ypixel),
                            terminal ? terminal->drawablePixelWidth : 0, terminal ? terminal->drawablePixelHeight : 0);
                    }
                    check(pane.session->windowSizeDeliveryCount() == before + 1,
                        "font zoom did not deliver exactly one complete window size");
                    // The next frame performs these same two operations. It
                    // must not send the program a second resize for this zoom.
                    check(!updatePaneGridFromAllocation(pane) && !publishPanePixelGeometry(pane),
                        "the frame after font zoom publishes an additional resize");
                    check(pane.session->windowSizeDeliveryCount() == before + 1,
                        "the frame after font zoom delivered a duplicate window size");
                }
            }
            g_print("smoke-font-zoom: exercised eight allocated-pane resize steps at 1x and 2x\n");
            app().scale = previousScale;
            app().rasterContext.setDeviceScale(previousScale);
            pane.session->close();
        } else
            check(false, "could not open the font-zoom resize test PTY");
        pane.picture = previousPicture;
        gtk_box_remove(GTK_BOX(parent), picture);
        g_object_unref(picture);
        g_object_unref(parent);
    } else
        g_print("smoke-font-zoom: allocated-pane resize checks skipped (no GTK display)\n");
    if (savedFamilyOverride)
        setenv("UBIQUITTY_FONT", savedFamilyOverride->c_str(), 1);
    else
        unsetenv("UBIQUITTY_FONT");
    if (savedSizeOverride)
        setenv("UBIQUITTY_FONT_SIZE", savedSizeOverride->c_str(), 1);
    else
        unsetenv("UBIQUITTY_FONT_SIZE");
    g_print("smoke-font-zoom: %dx%d -> %dx%d (grew=%d), reset restored=%d -- %s\n", width0, height0, width1, height1, static_cast<int>(grew), static_cast<int>(restored), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
