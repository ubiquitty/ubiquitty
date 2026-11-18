// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Exercises the real application actions and captures the GTK window content.
/// Checks application actions and captures the resulting GTK window content.
///
/// - Parameter outputDirectory: The directory receiving window captures.
/// - Returns: Zero on success, or a nonzero failure status.
int smokeWindowChrome(const char* outputDirectory)
{
    if (!gtk_init_check()) {
        g_printerr("smoke-window-chrome: GTK needs a display\n");
        return 1;
    }
    bool didPass = true;
    const auto check = [&](bool isMet, const char* message) {
        if (!isMet) {
            g_printerr("smoke-window-chrome: FAIL: %s\n", message);
            didPass = false;
        }
    };
    const auto settle = [] {
        const gint64 deadline = g_get_monotonic_time() + 300000;
        do {
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
    };
    // Layout can give a window its size before GTK has produced its render
    // node. Wait for both on the frame clock, bounded, before taking a picture.
    const auto capture = [&](GtkWidget* widget, const char* name) -> std::string {
        const gint64 deadline = g_get_monotonic_time() + 5'000'000;
        GdkPaintable* paintable = gtk_widget_paintable_new(widget);
        GskRenderNode* node = nullptr;
        int width = 0;
        int height = 0;
        do {
            width = gtk_widget_get_width(widget);
            height = gtk_widget_get_height(widget);
            if (gtk_widget_get_mapped(widget) && width > 0 && height > 0) {
                GtkSnapshot* snapshot = gtk_snapshot_new();
                gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
                node = gtk_snapshot_free_to_node(snapshot);
                if (node)
                    break;
            }
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
        g_object_unref(paintable);
        if (width <= 0 || height <= 0)
            return "it was given no size within 5 s";
        if (!node)
            return "its snapshot made no render node within 5 s";
        const graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, static_cast<float>(width), static_cast<float>(height));
        GdkTexture* texture = gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(widget)), node, &bounds);
        gsk_render_node_unref(node);
        if (!texture)
            return "its renderer drew no texture";
        bool didSave = true;
        if (outputDirectory) {
            const std::string path = std::string(outputDirectory) + "/" + name + ".png";
            didSave = gdk_texture_save_to_png(texture, path.c_str());
        }
        g_object_unref(texture);
        return didSave ? std::string() : "its frame could not be saved";
    };
    const auto checkFrame = [&](GtkWidget* widget, const char* name, const char* message) {
        const std::string missing = capture(widget, name);
        check(missing.empty(), (std::string(message) + (missing.empty() ? "" : ": " + missing)).c_str());
    };
    GtkApplication* application = gtk_application_new("org.ubiquitty.chrome-test", G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(G_APPLICATION(application), nullptr, nullptr)) {
        g_object_unref(application);
        return 1;
    }
    onActivate(application, nullptr);
    GList* createdWindows = gtk_application_get_windows(application);
    App* created = createdWindows ? appForWindow(GTK_WINDOW(createdWindows->data)) : nullptr;
    if (!created) {
        g_object_unref(application);
        return 1;
    }
    auto retainedOwner = created->shared_from_this();
    AppScope scope(*retainedOwner);
    // A silent child supplies no paintable to give the picture a natural size.
    // Exercise that startup independently of the shell and its first output.
    GtkWidget* silentWindow = gtk_window_new();
    GtkWidget* silentPicture = gtk_picture_new();
    gtk_widget_set_hexpand(silentPicture, TRUE);
    gtk_widget_set_vexpand(silentPicture, TRUE);
    gtk_widget_set_margin_start(silentPicture, 7);
    gtk_widget_set_margin_end(silentPicture, 11);
    gtk_widget_set_margin_top(silentPicture, 13);
    gtk_widget_set_margin_bottom(silentPicture, 17);
    gtk_widget_set_size_request(silentPicture, 640, 384);
    gtk_window_set_child(GTK_WINDOW(silentWindow), silentPicture);
    windowSignalConnect(silentWindow, "map", G_CALLBACK(+[](GtkWidget* window, gpointer picture) {
        preserveLaunchSize(GTK_WINDOW(window), GTK_WIDGET(picture));
    }),
        silentPicture);
    gtk_window_present(GTK_WINDOW(silentWindow));
    int launchWidth = 0;
    int launchHeight = 0;
    gtk_window_get_default_size(GTK_WINDOW(silentWindow), &launchWidth, &launchHeight);
    check(launchWidth >= 658 && launchHeight >= 414, "an empty startup picture preserves the grid and padding in the default size before allocation");
    settle();
    check(gtk_picture_get_paintable(GTK_PICTURE(silentPicture)) == nullptr, "the silent startup check needs no rendered frame");
    if (GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(silentWindow)); surface && GDK_IS_TOPLEVEL(surface)) {
        const auto state = gdk_toplevel_get_state(GDK_TOPLEVEL(surface));
        if (!(state & (GDK_TOPLEVEL_STATE_TILED | GDK_TOPLEVEL_STATE_FULLSCREEN | GDK_TOPLEVEL_STATE_MAXIMIZED))) {
            check(gtk_widget_get_width(silentPicture) >= 640 && gtk_widget_get_height(silentPicture) >= 384,
                "an empty floating picture keeps its launch allocation");
            gtk_window_set_default_size(GTK_WINDOW(silentWindow), launchWidth / 2, launchHeight / 2);
            settle();
            check(gtk_widget_get_width(silentPicture) < 640 && gtk_widget_get_height(silentPicture) < 384,
                "the launch minimum does not prevent a later smaller window");
            int resizedWidth = 0;
            int resizedHeight = 0;
            gtk_window_get_default_size(GTK_WINDOW(silentWindow), &resizedWidth, &resizedHeight);
            gtk_widget_set_visible(silentWindow, FALSE);
            gtk_window_present(GTK_WINDOW(silentWindow));
            settle();
            int remappedWidth = 0;
            int remappedHeight = 0;
            gtk_window_get_default_size(GTK_WINDOW(silentWindow), &remappedWidth, &remappedHeight);
            check(remappedWidth == resizedWidth && remappedHeight == resizedHeight, "remapping retains the user's smaller default size");
        }
    }
    gtk_window_destroy(GTK_WINDOW(silentWindow));
    settle();
    int minWidth = 0, minHeight = 0;
    gtk_widget_get_size_request(activePane()->picture, &minWidth, &minHeight);
    check(minWidth == -1 && minHeight == -1, "the launch grid imposes no permanent minimum size");
    if (GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(app().window)); surface && GDK_IS_TOPLEVEL(surface)) {
        const auto state = gdk_toplevel_get_state(GDK_TOPLEVEL(surface));
        const auto isCompositorSized = state & (GDK_TOPLEVEL_STATE_TILED | GDK_TOPLEVEL_STATE_FULLSCREEN | GDK_TOPLEVEL_STATE_MAXIMIZED);
        if (!isCompositorSized) {
            check(gtk_widget_get_width(activePane()->picture) + 1 >= startupColumns * logicalCellWidth(), "a floating window keeps the launch grid width after its minimum is relaxed");
            check(gtk_widget_get_height(activePane()->picture) + 1 >= startupRows * logicalCellHeight(), "a floating window keeps the launch grid height after its minimum is relaxed");
        }
    }
    check(app().tabStrip && gtk_widget_get_mapped(app().tabStrip) == !UBIQUITTY_LINUX_CHROMELESS, "tab visibility matches the desktop build");
    check(app().menuButton && gtk_widget_get_mapped(app().menuButton) == !UBIQUITTY_LINUX_CHROMELESS, "menu visibility matches the desktop build");
    check(gtk_window_get_decorated(GTK_WINDOW(app().window)) == !UBIQUITTY_LINUX_CHROMELESS, "window decorations match the desktop build");
    if (!UBIQUITTY_LINUX_CHROMELESS) {
        gtk_menu_button_popup(GTK_MENU_BUTTON(app().menuButton));
        settle();
        check(onKeyPressed(nullptr, GDK_KEY_Down, 0, static_cast<GdkModifierType>(0), nullptr) == GDK_EVENT_PROPAGATE,
            "menu navigation reaches GTK instead of the terminal");
        gtk_menu_button_popdown(GTK_MENU_BUTTON(app().menuButton));
    }
    const SurfaceID surface = app().model->activeSurface();
    const TabID firstTab = app().model->activeTab(surface);
    g_action_group_activate_action(G_ACTION_GROUP(app().window), "new-tab", nullptr);
    settle();
    check(app().model->tabCount(surface) == 2, "the menu opens a second tab");
    GtkWidget* firstButton = gtk_widget_get_first_child(app().tabStrip);
    if (firstButton) {
        g_signal_emit_by_name(firstButton, "clicked");
        settle();
        check(app().model->activeTab(surface) == firstTab, "clicking a tab changes the focused session");
        firstButton = gtk_widget_get_first_child(app().tabStrip);
        check(gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(firstButton)), "the selected tab follows the model");
    } else
        check(false, "the strip contains a tab button");
    const std::string savedDocument = Ubiquitty::Preferences::liveDocument();
    const std::string savedThemeName = app().liveThemeName;
    const auto configureTheme = [&](const char* background) {
        const std::string document = std::string("[appearance]\ntheme = \"Omarchy\"\nbackground_opacity = 1\npadding = 14\n")
            + "[[themes]]\nname = \"Omarchy\"\nfg = \"#ffffff\"\nbg = \"" + background + "\"\n";
        check(Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict).isApplied,
            "a live Omarchy theme document applies");
    };
    configureTheme("#112233");
    settle();
    checkFrame(app().window, "palette-a", "the initial live palette produces a frame");
    const int fixtureIndex = app().liveThemeIndex;
    configureTheme("#a1b2c3");
    settle();
    checkFrame(app().window, "palette-b", "the replacement live palette produces a frame");
    check(app().liveThemeIndex == fixtureIndex, "a palette reload retains the configured theme index");
    for (const auto& pane : app().panes) {
        const auto hold = holdPaneModel(*pane);
        const auto background = Ubiquitty::Rendering::resolvePaletteColor(pane->session->terminal()->palette,
            Ubiquitty::colorDefault, false);
        check(background.red == 161 && background.green == 178 && background.blue == 195,
            "a same-index palette replacement reaches every pane");
        check(!pane->pendingCapture, "a palette replacement discards stale captured pixels");
    }
    check(gtk_widget_has_css_class(app().window, "ubiquitty-themed-bg")
            && gtk_widget_has_css_class(app().paneContainer, "ubiquitty-themed-bg"),
        "the window padding and pane remainder use the refreshed themed background");
    const int manualTheme = 0;
    const std::string manualName = Ubiquitty::Themes::get(manualTheme)->name;
    applyThemeToAllPanes(manualTheme);
    configureTheme("#a1b2c3");
    check(app().liveThemeName == manualName, "an unrelated reload preserves the manual theme choice by name");
    applyThemeToAllPanes(fixtureIndex);
    auto chromeConfig = loadPreferences();
    chromeConfig.backgroundOpacity = 1.0;
    applyWindowGlobalRenderSettings(chromeConfig);
    applyChromeTheme(fixtureIndex);
    gchar* themeCSS = app().windowAppearance.cssProvider() ? gtk_css_provider_to_string(app().windowAppearance.cssProvider()) : nullptr;
    std::string compactCSS = themeCSS ? themeCSS : "";
    g_free(themeCSS);
    std::erase_if(compactCSS, [](unsigned char c) { return c == ' ' || c == '\n' || c == '\r' || c == '\t'; });
    check(compactCSS.find("rgb(161,178,195)") != std::string::npos || compactCSS.find("#a1b2c3") != std::string::npos,
        "the scoped padding CSS contains the replacement background");
    GtkCssProvider* const retainedProvider = app().windowAppearance.cssProvider();
    chromeConfig.backgroundOpacity = 0.5;
    applyWindowGlobalRenderSettings(chromeConfig);
    applyChromeTheme(fixtureIndex);
    check(gtk_widget_has_css_class(app().window, "ubiquitty-translucent"), "live translucency reaches the padding");
    chromeConfig.backgroundOpacity = 1.0;
    applyWindowGlobalRenderSettings(chromeConfig);
    applyChromeTheme(fixtureIndex);
    check(!gtk_widget_has_css_class(app().window, "ubiquitty-translucent") && app().windowAppearance.cssProvider() == retainedProvider,
        "returning to opaque replaces the same scoped provider without stale transparency");
    check(Ubiquitty::Preferences::configure(savedDocument, Ubiquitty::Preferences::ParseMode::Strict).isApplied,
        "the original configuration is restored after the theme probe");
    const int restoredTheme = Ubiquitty::Themes::indexForName(savedThemeName.c_str());
    if (restoredTheme >= 0)
        applyThemeToAllPanes(restoredTheme);
    checkFrame(app().window, "tabs", "the window produces a rendered frame");
    g_action_group_activate_action(G_ACTION_GROUP(app().window), "about", nullptr);
    settle();
    GListModel* windows = gtk_window_get_toplevels();
    GtkWidget* about = nullptr;
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GObject* window = G_OBJECT(g_list_model_get_item(windows, i));
        if (GTK_IS_ABOUT_DIALOG(window)) {
            about = GTK_WIDGET(window);
            break;
        }
        g_object_unref(window);
    }
    check(about != nullptr, "About opens an application information window");
    if (about) {
        check(gtk_widget_get_mapped(about), "About is mapped");
        check(g_strcmp0(gtk_about_dialog_get_program_name(GTK_ABOUT_DIALOG(about)), "Ubiquitty") == 0,
            "About names the application");
        check(g_strcmp0(gtk_about_dialog_get_version(GTK_ABOUT_DIALOG(about)), Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str()) == 0,
            "About shows the running build identity");
        check(gtk_about_dialog_get_license_type(GTK_ABOUT_DIALOG(about)) == GTK_LICENSE_APACHE_2_0,
            "About identifies the application license");
        checkFrame(about, "about", "About produces a rendered frame");
        gtk_window_close(GTK_WINDOW(about));
        g_object_unref(about);
    }
    app().configurationWatcher.stop();
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    g_object_unref(application);
    g_print("smoke-window-chrome: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
