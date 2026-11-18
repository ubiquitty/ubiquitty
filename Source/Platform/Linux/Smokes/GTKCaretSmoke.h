// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks GTK caret placement against the terminal cursor geometry.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeGTKCaret()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-gtk-caret: GTK needs a display\n");
        return 1;
    }
    struct Renderer {
        const char* name;
        GskRenderer* renderer;
    };
    std::vector<Renderer> renderers;
    const auto addRenderer = [&](const char* name, GskRenderer* renderer) {
        GError* error = nullptr;
        if (renderer && gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), &error)) {
            renderers.push_back({ name, renderer });
            return;
        }
        g_print("smoke-gtk-caret: GSK %s renderer unavailable (%s)\n", name, error ? error->message : "not built");
        if (error)
            g_error_free(error);
        if (renderer)
            g_object_unref(renderer);
    };
    addRenderer("cairo", gsk_cairo_renderer_new());
    addRenderer("gl", gsk_gl_renderer_new());
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    addRenderer("vulkan", gsk_vulkan_renderer_new());
    G_GNUC_END_IGNORE_DEPRECATIONS
    if (renderers.empty()) {
        g_printerr("smoke-gtk-caret: FAIL: no GSK renderer realized\n");
        return 1;
    }

    // The caret colour is GtkText's `caret-color`, which a terminal's is.
    GtkWidget* probe = g_object_ref_sink(gtk_text_new());
    GtkCssProvider* provider = gtk_css_provider_new();
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_style_context_add_provider(gtk_widget_get_style_context(probe), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_USER);
    G_GNUC_END_IGNORE_DEPRECATIONS

    struct Configuration {
        const char* name;
        int scale;
        int fontSize;
        int lineSpacing;
        double aspectRatio;
    };
    const Configuration configurations[] = {
        { "scale1", 1, 13, 0, 0.0 },
        { "scale2", 2, 13, 0, 0.0 },
        { "scale1-spaced", 1, 13, 3, 0.0 },
        { "scale2-spaced", 2, 13, 3, 0.0 },
        { "scale1-large", 1, 40, 0, 0.0 },
        { "scale2-large", 2, 40, 0, 0.0 },
        { "scale1-aspect", 1, 13, 0, 0.12 },
        { "scale2-aspect", 2, 13, 0, 0.12 },
    };
    struct Case {
        const char* name;
        const char* bytes;
        int anchorRow;
        int anchorColumn;
        float blinkAlpha;
        bool focused;
    };
    const Case cases[] = {
        { "prompt", "$ typed\x1b[1;8H", 0, 7, 1.0f, true },
        { "column-0", "first\x1b[2;1H", 1, 0, 1.0f, true },
        { "last-column", "\x1b[3;20Hz\x1b[3;20H", 2, 19, 1.0f, true },
        { "wide-lead", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;3H", 0, 2, 1.0f, true },
        { "wide-trail", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;4H", 0, 2, 1.0f, true },
        { "custom-colour", "\x1b]12;#ff0044\x07$ custom\x1b[1;4H", 0, 3, 1.0f, true },
        { "fade-0.75", "$ fade\x1b[1;3H", 0, 2, 0.75f, true },
        { "fade-0.5", "$ fade\x1b[1;3H", 0, 2, 0.5f, true },
        { "fade-0.25", "$ fade\x1b[1;3H", 0, 2, 0.25f, true },
        { "fade-0.9", "$ fade\x1b[1;3H", 0, 2, 0.9f, true },
        { "fade-0.62", "$ fade\x1b[1;3H", 0, 2, 0.62f, true },
        { "fade-0.3", "$ fade\x1b[1;3H", 0, 2, 0.3f, true },
        { "fade-0.1", "$ fade\x1b[1;3H", 0, 2, 0.1f, true },
        { "fade-off", "$ fade\x1b[1;3H", 0, 2, 0.0f, true },
        { "unfocused", "$ unfocused\x1b[1;5H", 0, 4, 1.0f, false },
        { "unfocused-wide", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;3H", 0, 2, 1.0f, false },
    };

    bool didPass = true;
    int compared = 0;
    for (const Configuration& configuration : configurations) {
        const std::string document = std::format("[font]\nsize = {}\nline_spacing = {}\n", configuration.fontSize, configuration.lineSpacing);
        if (!Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
            g_printerr("smoke-gtk-caret: FAIL: configuration refused\n");
            return 1;
        }
        app().scale = configuration.scale;
        app().fontDPI = 72.0;
        app().fontSizePoints = configuration.fontSize;
        app().rasterContext.setDeviceScale(configuration.scale);
        setupFonts();
        applyWindowGlobalRenderSettings(Ubiquitty::Preferences::values());
        rebuildFontsFromPreferences();
        GtkSettings* settings = gtk_settings_get_default();
        if (configuration.aspectRatio > 0.0)
            g_object_set(settings, "gtk-cursor-aspect-ratio", configuration.aspectRatio, nullptr);
        else
            gtk_settings_reset_property(settings, "gtk-cursor-aspect-ratio");
        // The arm reads the setting exactly as the window does.
        readToolkitCaretSettings();

        Ubiquitty::Linux::VulkanRenderer vulkan;
        vulkan.setGlyphRasterizer(currentRasterizer());
        vulkan.setLigatureRasterizer(currentRasterizer());
        const bool hasVulkan = vulkan.init();

        const Ubiquitty::Rendering::CellMetrics metrics = currentRasterizer().cellMetrics();
        const double lineSpacingPixels = app().rasterContext.renderConfiguration().lineSpacingPoints * 0.5 * configuration.scale;
        g_print("smoke-gtk-caret: %s: cell %gx%g device px, line spacing %g pt, gtk-cursor-aspect-ratio %g\n", configuration.name, metrics.cellWidth,
            metrics.cellHeight, app().rasterContext.renderConfiguration().lineSpacingPoints, app().rasterContext.toolkitCaret().aspectRatio);
        for (const Case& testCase : cases) {
            activePane()->session->start(4, 20);
            Ubiquitty::Terminal* term = activePane()->session->terminal();
            if (!term) {
                g_printerr("smoke-gtk-caret: FAIL: no terminal\n");
                return 1;
            }
            // A clean screen per case, so each case's text is the only text.
            Ubiquitty::processBytes(term, "\033c\033[5 q");
            Ubiquitty::processBytes(term, testCase.bytes);
            // GTK owns the caret's geometry and fade; its colour is the theme's
            // cursor colour as Core resolves it, so GTK is handed that colour.
            const Ubiquitty::PaletteRGB caret = term->palette.cursor;
            const std::string css = std::format("text {{ caret-color: rgb({},{},{}); }}", Ubiquitty::channel16To8(caret.red),
                Ubiquitty::channel16To8(caret.green), Ubiquitty::channel16To8(caret.blue));
            gtk_css_provider_load_from_string(provider, css.c_str());

            Ubiquitty::Linux::CursorOverlay hidden;
            Ubiquitty::Linux::CursorOverlay bar;
            bar.visible = true;
            bar.shape = Ubiquitty::Cursor::Shape::Bar;
            bar.blinkAlpha = testCase.blinkAlpha;
            bar.focused = testCase.focused;
            const GTKCaretGeometry geometry {
                .leftInPixels = testCase.anchorColumn * static_cast<double>(metrics.cellWidth),
                .lineTopInPixels = testCase.anchorRow * static_cast<double>(metrics.cellHeight) + lineSpacingPixels,
                .lineBottomInPixels = (testCase.anchorRow + 1) * static_cast<double>(metrics.cellHeight) - lineSpacingPixels,
            };
            // Each path against GTK's caret over that path's own caretless
            // frame, so the comparison sees the caret and nothing else.
            struct Path {
                const char* name = "";
                bool didRender = false;
                int width = 0;
                int height = 0;
                std::vector<std::uint8_t> background;
                std::vector<std::uint8_t> withBar;
            };
            std::array<Path, 2> paths;
            paths[0].name = "cpu";
            paths[1].name = "vulkan";
            {
                int width = 0, height = 0;
                paths[0].didRender = app().rasterContext.rasterizeTerm(term, paths[0].background, paths[0].width, paths[0].height, 0, nullptr, &hidden)
                    && app().rasterContext.rasterizeTerm(term, paths[0].withBar, width, height, 0, nullptr, &bar)
                    && width == paths[0].width && height == paths[0].height;
                paths[1].didRender = hasVulkan
                    && vulkan.renderGrid(app().rasterContext, term, paths[1].background, paths[1].width, paths[1].height, 0, nullptr, &hidden)
                    && vulkan.renderGrid(app().rasterContext, term, paths[1].withBar, width, height, 0, nullptr, &bar)
                    && width == paths[1].width && height == paths[1].height;
            }
            // Unfocused, GTK draws no caret but the terminal draws its steady
            // hollow outline (Docs/cursor-blink-design.md): the bar and the
            // underline must be the unfocused block's outline on both paths,
            // and visible.
            if (!testCase.focused) {
                Ubiquitty::Linux::CursorOverlay block = bar;
                block.shape = Ubiquitty::Cursor::Shape::Block;
                Ubiquitty::Linux::CursorOverlay underline = bar;
                underline.shape = Ubiquitty::Cursor::Shape::Underline;
                const auto render = [&](const Path& path, const Ubiquitty::Linux::CursorOverlay& cursor, std::vector<std::uint8_t>& out) {
                    int width = 0, height = 0;
                    const bool didRender = path.name == std::string_view("cpu")
                        ? app().rasterContext.rasterizeTerm(term, out, width, height, 0, nullptr, &cursor)
                        : vulkan.renderGrid(app().rasterContext, term, out, width, height, 0, nullptr, &cursor);
                    return didRender && width == path.width && height == path.height;
                };
                for (const Path& path : paths) {
                    if (!path.didRender)
                        continue;
                    std::vector<std::uint8_t> outline;
                    std::vector<std::uint8_t> underlined;
                    const bool didRenderOutline = render(path, block, outline);
                    const bool didRenderUnderline = render(path, underline, underlined);
                    for (const auto& [shapeName, frame] : { std::pair<const char*, const std::vector<std::uint8_t>*> { "bar", &path.withBar }, { "underline", &underlined } }) {
                        const bool isOutline = didRenderOutline && didRenderUnderline && *frame == outline;
                        const bool isVisible = *frame != path.background;
                        ++compared;
                        didPass = didPass && isOutline && isVisible;
                        g_print("smoke-gtk-caret: %s %-14s outline %-6s %s==unfocused-block %s visible %s -- %s\n", configuration.name, testCase.name,
                            path.name, shapeName, isOutline ? "identical" : "DIFFERS", isVisible ? "yes" : "NO", isOutline && isVisible ? "PASS" : "FAIL");
                        if (!isOutline && didRenderOutline && didRenderUnderline)
                            g_print("smoke-gtk-caret:   %s\n", describeDifference(outline, *frame, path.width).c_str());
                    }
                }
                continue;
            }
            const bool isFractional = testCase.blinkAlpha > 0.0f && testCase.blinkAlpha < 1.0f;
            for (const Renderer& renderer : renderers) {
                // Cairo is GTK's software renderer and blends in integers, so
                // its bytes are the same on every machine: the gate. GSK's GL
                // and Vulkan renderers blend in floats on the GPU; on a
                // half-transparent caret they round a channel either way of a
                // half, so there they are held to one level, and to every byte
                // wherever the caret is opaque or absent.
                const bool isExactRenderer = std::string_view(renderer.name) == "cairo";
                for (const Path& path : paths) {
                    if (!path.didRender) {
                        if (path.name == std::string_view("cpu")) {
                            didPass = false;
                            g_print("smoke-gtk-caret: %s %-14s %-6s cpu did not render -- FAIL\n", configuration.name, testCase.name, renderer.name);
                        }
                        continue;
                    }
                    const std::vector<std::uint8_t> gtk = renderGTKCaret(renderer.renderer, probe, path.background, path.width, path.height,
                        configuration.scale, geometry, testCase.blinkAlpha);
                    int largestDifference = gtk.size() == path.withBar.size() ? 0 : 256;
                    for (std::size_t index = 0; largestDifference < 256 && index < gtk.size(); ++index)
                        largestDifference = std::max(largestDifference, std::abs(static_cast<int>(gtk[index]) - static_cast<int>(path.withBar[index])));
                    const bool isIdentical = !gtk.empty() && largestDifference == 0;
                    const bool isWithinRenderer = isIdentical || (!gtk.empty() && !isExactRenderer && isFractional && largestDifference <= 1);
                    // The control: wherever GTK drew a caret, the caretless
                    // frame must not pass for GTK's.
                    const bool doesControlDiffer = gtk.empty() || testCase.blinkAlpha <= 0.0f || path.background != gtk;
                    const bool passed = isWithinRenderer && doesControlDiffer;
                    ++compared;
                    didPass = didPass && passed;
                    g_print("smoke-gtk-caret: %s %-14s %-6s gtk==%-6s %s control %s -- %s\n", configuration.name, testCase.name, renderer.name, path.name,
                        isIdentical ? "identical" : (isWithinRenderer ? "within-1" : "DIFFERS"), doesControlDiffer ? "differs" : "SAME", passed ? "PASS" : "FAIL");
                    if (!isIdentical && !gtk.empty())
                        g_print("smoke-gtk-caret:   %s\n", describeDifference(gtk, path.withBar, path.width).c_str());
                }
            }
        }
        if (hasVulkan)
            vulkan.shutdown();
    }
    gtk_settings_reset_property(gtk_settings_get_default(), "gtk-cursor-aspect-ratio");
    g_object_unref(provider);
    g_object_unref(probe);
    for (const Renderer& renderer : renderers) {
        gsk_renderer_unrealize(renderer.renderer);
        g_object_unref(renderer.renderer);
    }
    g_print("smoke-gtk-caret: %d comparisons -- %s\n", compared, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
