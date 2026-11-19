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
    // The window opens at the launch grid, top padding under the header included.
    check(activePane()->columns == startupColumns && activePane()->rows == startupRows,
        (std::string("the window opens at the launch grid, not ") + std::to_string(activePane()->columns) + "x" + std::to_string(activePane()->rows)).c_str());
    if (GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(app().window)); surface && GDK_IS_TOPLEVEL(surface)) {
        const auto state = gdk_toplevel_get_state(GDK_TOPLEVEL(surface));
        const auto isCompositorSized = state & (GDK_TOPLEVEL_STATE_TILED | GDK_TOPLEVEL_STATE_FULLSCREEN | GDK_TOPLEVEL_STATE_MAXIMIZED);
        if (!isCompositorSized) {
            check(gtk_widget_get_width(activePane()->picture) + 1 >= startupColumns * logicalCellWidth(), "a floating window keeps the launch grid width after its minimum is relaxed");
            check(gtk_widget_get_height(activePane()->picture) + 1 >= startupRows * logicalCellHeight(), "a floating window keeps the launch grid height after its minimum is relaxed");
        }
    }
    check((app().chrome != nullptr) == !UBIQUITTY_LINUX_CHROMELESS, "the chrome matches the desktop build");
    check(gtk_window_get_decorated(GTK_WINDOW(app().window)) == !UBIQUITTY_LINUX_CHROMELESS, "window decorations match the desktop build");
    if (app().chrome) {
        check(adw_application_window_get_content(ADW_APPLICATION_WINDOW(app().window)) == app().chrome->widget(), "the libadwaita chrome holds the window content");
        check(gtk_widget_get_mapped(GTK_WIDGET(app().chrome->menuButton())), "the primary menu is in the header");
        check(!adw_tab_bar_get_tabs_revealed(ADW_TAB_BAR(app().chrome->tabBar())), "a window of one tab hides its tab bar");
        // The terminal has the keys while no widget has focus: a new window
        // leaves none in its top bar, and focus pushed onto a header button is
        // given straight back, so typing never lands on the menu.
        GtkWidget* focused = gtk_window_get_focus(GTK_WINDOW(app().window));
        check(!focused || !gtk_widget_is_ancestor(focused, app().chrome->widget()) || gtk_widget_get_ancestor(focused, GTK_TYPE_SEARCH_BAR),
            "a new window leaves no focus on its header");
        // Tab has nowhere to go in the header: none of its controls is in the
        // focus chain.
        check(!gtk_widget_child_focus(app().chrome->widget(), GTK_DIR_TAB_FORWARD), "the header's controls are out of the focus chain");
        // And focus put on one anyway is given back. The menu button is made
        // focusable for this one check, as a theme or GTK itself could.
        GtkWidget* menuButton = gtk_widget_get_first_child(GTK_WIDGET(app().chrome->menuButton()));
        gtk_widget_set_focusable(menuButton, TRUE);
        const gboolean didFocusButton = gtk_widget_grab_focus(menuButton);
        settle();
        gtk_widget_set_focusable(menuButton, FALSE);
        check(didFocusButton, "the menu button took focus for the hand-back check");
        check(gtk_window_get_focus(GTK_WINDOW(app().window)) == nullptr, "focus that lands on a header button is given back to the terminal");
        check(!doesMenuOwnKeys(), "typing reaches the terminal after focus touched the menu button");
        gtk_menu_button_popup(app().chrome->menuButton());
        settle();
        check(onKeyPressed(nullptr, GDK_KEY_Down, 0, static_cast<GdkModifierType>(0), nullptr) == GDK_EVENT_PROPAGATE,
            "menu navigation reaches GTK instead of the terminal");
        gtk_menu_button_popdown(app().chrome->menuButton());
    }
    const SurfaceID surface = app().model->activeSurface();
    const TabID firstTab = app().model->activeTab(surface);
    g_action_group_activate_action(G_ACTION_GROUP(app().window), "new-tab", nullptr);
    settle();
    check(app().model->tabCount(surface) == 2, "the header's new-tab action opens a second tab");
    if (app().chrome) {
        check(adw_tab_bar_get_tabs_revealed(ADW_TAB_BAR(app().chrome->tabBar())), "a second tab reveals the tab bar");
        // What a tab's button does when clicked: select its tab by identifier.
        g_action_group_change_action_state(G_ACTION_GROUP(app().window), "active-tab", g_variant_new_uint32(static_cast<std::uint32_t>(firstTab)));
        settle();
        check(app().model->activeTab(surface) == firstTab, "selecting a tab changes the focused session");
        GVariant* state = g_action_group_get_action_state(G_ACTION_GROUP(app().window), "active-tab");
        check(state && g_variant_get_uint32(state) == static_cast<std::uint32_t>(firstTab), "the checked tab follows the model");
        if (state)
            g_variant_unref(state);
        // What a tab's close button and a middle click do.
        const TabID secondTab = app().model->tabAt(surface, 1);
        g_action_group_activate_action(G_ACTION_GROUP(app().window), "close-tab", g_variant_new_uint32(static_cast<std::uint32_t>(secondTab)));
        settle();
        check(app().model->tabCount(surface) == 1, "closing a tab from the bar ends it");
        check(!adw_tab_bar_get_tabs_revealed(ADW_TAB_BAR(app().chrome->tabBar())), "the tab bar hides again at one tab");
        g_action_group_activate_action(G_ACTION_GROUP(app().window), "new-tab", nullptr);
        settle();
    }
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
    // Switching tabs keeps the grid inside its padding on every frame: a
    // remounted pane must not show one frame with the grid at the left edge
    // before it moves right into place.
    if (app().model->tabCount(surface) >= 2) {
        const auto leftPaddingOverrun = [&](GtkWidget* picture) -> int {
            const int width = gtk_widget_get_width(picture);
            const int height = gtk_widget_get_height(picture);
            if (!gtk_widget_get_mapped(picture) || width <= 0 || height <= 0)
                return -1;
            GdkPaintable* paintable = gtk_widget_paintable_new(picture);
            GtkSnapshot* snapshot = gtk_snapshot_new();
            gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
            GskRenderNode* node = gtk_snapshot_free_to_node(snapshot);
            g_object_unref(paintable);
            if (!node)
                return -1;
            const graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, static_cast<float>(width), static_cast<float>(height));
            GdkTexture* texture = gsk_renderer_render_texture(gtk_native_get_renderer(gtk_widget_get_native(picture)), node, &bounds);
            gsk_render_node_unref(node);
            if (!texture)
                return -1;
            const int textureWidth = gdk_texture_get_width(texture);
            const int textureHeight = gdk_texture_get_height(texture);
            std::vector<guchar> pixels(static_cast<std::size_t>(textureWidth) * static_cast<std::size_t>(textureHeight) * 4);
            gdk_texture_download(texture, pixels.data(), static_cast<gsize>(textureWidth) * 4);
            if (const char* debug = std::getenv("UBQ_SMOKE_PADDING_DUMP")) {
                static int dumped = 0;
                const std::string path = std::string(debug) + "/switch-" + std::to_string(dumped++) + ".png";
                if (dumped <= 40)
                    gdk_texture_save_to_png(texture, path.c_str());
            }
            g_object_unref(texture);
            // The first padded columns of every row: the theme's ground and nothing else.
            const int padding = textureWidth * 12 / width; // under the 14-point padding, at any scale
            int overrun = 0;
            for (int row = 0; row < textureHeight; ++row) {
                for (int column = 0; column < padding; ++column) {
                    const guchar* pixel = &pixels[(static_cast<std::size_t>(row) * static_cast<std::size_t>(textureWidth) + static_cast<std::size_t>(column)) * 4];
                    // Cairo order: B, G, R, A.
                    if (std::abs(pixel[2] - 161) > 8 || std::abs(pixel[1] - 178) > 8 || std::abs(pixel[0] - 195) > 8)
                        ++overrun;
                }
            }
            return overrun;
        };
        bool didKeepPadding = true;
        int framesSeen = 0;
        for (int round = 0; round < 4; ++round) {
            switchToTab(app().model->tabAt(surface, round % 2));
            const gint64 deadline = g_get_monotonic_time() + 500'000;
            while (g_get_monotonic_time() < deadline) {
                g_main_context_iteration(nullptr, FALSE);
                const int overrun = leftPaddingOverrun(activePane()->picture);
                if (overrun > 0) {
                    g_printerr("smoke-window-chrome: switch %d, frame %d: %d pixels of the grid inside the left padding\n", round, framesSeen, overrun);
                    didKeepPadding = false;
                }
                framesSeen += overrun >= 0;
                g_usleep(4000);
            }
        }
        check(framesSeen > 0, "a switched-to pane renders frames to inspect");
        check(didKeepPadding, "every frame after a tab switch keeps the grid inside its left padding");
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
    // Following the desktop's light and dark style: the style manager's dark
    // property is what the settings portal sets, and forcing it here takes the
    // same path a desktop switch does without touching the desktop.
    {
        // A theme of each polarity: a named theme of the other one is answered
        // with its sibling, which is Core's rule and not what this checks.
        std::string lightName;
        std::string darkName;
        for (int index = 0; index < Ubiquitty::Themes::themeCount() && (lightName.empty() || darkName.empty()); ++index) {
            std::string& name = Ubiquitty::Themes::isThemeDark(index) ? darkName : lightName;
            if (name.empty())
                name = Ubiquitty::Themes::themeName(index);
        }
        AdwStyleManager* styleManager = adw_style_manager_get_default();
        adw_style_manager_set_color_scheme(styleManager, ADW_COLOR_SCHEME_FORCE_LIGHT);
        check(Ubiquitty::Preferences::configure("[appearance]\nfollow_system = true\nsystem_light_theme = \"" + lightName
                      + "\"\nsystem_dark_theme = \"" + darkName + "\"\n",
                  Ubiquitty::Preferences::ParseMode::Strict)
                  .isApplied,
            "a follow-system document applies");
        settle();
        check(app().liveThemeName == lightName, "a light desktop selects the light theme");
        adw_style_manager_set_color_scheme(styleManager, ADW_COLOR_SCHEME_FORCE_DARK);
        settle();
        check(app().liveThemeName == darkName, "switching the desktop to dark selects the dark theme");
        adw_style_manager_set_color_scheme(styleManager, ADW_COLOR_SCHEME_FORCE_LIGHT);
        settle();
        check(app().liveThemeName == lightName, "switching back to light selects the light theme");
        adw_style_manager_set_color_scheme(styleManager, ADW_COLOR_SCHEME_DEFAULT);
    }
    check(Ubiquitty::Preferences::configure(savedDocument, Ubiquitty::Preferences::ParseMode::Strict).isApplied,
        "the original configuration is restored after the theme probe");
    const int restoredTheme = Ubiquitty::Themes::indexForName(savedThemeName.c_str());
    if (restoredTheme >= 0)
        applyThemeToAllPanes(restoredTheme);
    checkFrame(app().window, "tabs", "the window produces a rendered frame");
    // Split Right shows a second, live terminal beside the first: both panes
    // laid out side by side, each with a frame of its own, and the new one
    // drawing its shell's prompt rather than an empty or stretched frame.
    if (app().chrome) {
        LinuxPane* original = activePane();
        g_action_group_activate_action(G_ACTION_GROUP(app().window), "split-right", nullptr);
        LinuxPane* added = activePane();
        check(added != original && app().model->paneTree(surface)->paneCount() == 2, "Split Right adds a second pane to the tab");
        // A pane's frame as GTK draws it: the picture's own paintable is the
        // renderer's, so it is rendered through the window's renderer to read.
        const auto inkPixels = [&](GtkWidget* picture) -> int {
            const int width = gtk_widget_get_width(picture);
            const int height = gtk_widget_get_height(picture);
            if (!gtk_widget_get_mapped(picture) || width <= 0 || height <= 0)
                return -1;
            GdkPaintable* paintable = gtk_widget_paintable_new(picture);
            GtkSnapshot* snapshot = gtk_snapshot_new();
            gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
            GskRenderNode* node = gtk_snapshot_free_to_node(snapshot);
            g_object_unref(paintable);
            if (!node)
                return -1;
            const graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, static_cast<float>(width), static_cast<float>(height));
            GdkTexture* texture = gsk_renderer_render_texture(gtk_native_get_renderer(gtk_widget_get_native(picture)), node, &bounds);
            gsk_render_node_unref(node);
            if (!texture)
                return -1;
            const int textureWidth = gdk_texture_get_width(texture);
            const int textureHeight = gdk_texture_get_height(texture);
            std::vector<guchar> pixels(static_cast<std::size_t>(textureWidth) * static_cast<std::size_t>(textureHeight) * 4);
            gdk_texture_download(texture, pixels.data(), static_cast<gsize>(textureWidth) * 4);
            g_object_unref(texture);
            // The ground is the first pixel; ink is anything far from it.
            int ink = 0;
            for (std::size_t offset = 0; offset < pixels.size(); offset += 4) {
                const int distance = std::abs(pixels[offset] - pixels[0]) + std::abs(pixels[offset + 1] - pixels[1]) + std::abs(pixels[offset + 2] - pixels[2]);
                ink += distance > 96;
            }
            return ink;
        };
        bool isShown = false;
        const gint64 deadline = g_get_monotonic_time() + 15'000'000;
        while (!isShown && g_get_monotonic_time() < deadline) {
            g_main_context_iteration(nullptr, FALSE);
            isShown = added && original && gtk_widget_get_mapped(original->picture) && gtk_widget_get_mapped(added->picture)
                && gtk_widget_get_width(added->picture) > 0 && inkPixels(original->picture) > 0 && inkPixels(added->picture) > 0;
            g_usleep(10'000);
        }
        check(isShown, "both panes are mapped and each draws its own terminal");
        if (original && added) {
            graphene_point_t left {};
            graphene_point_t right {};
            const graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
            const bool didPlace = gtk_widget_compute_point(original->picture, app().window, &origin, &left)
                && gtk_widget_compute_point(added->picture, app().window, &origin, &right);
            check(didPlace && right.x > left.x + gtk_widget_get_width(original->picture) / 2.0f && std::abs(right.y - left.y) < 1.0f,
                "the new pane sits to the right of the first, at the same height");
            check(std::abs(gtk_widget_get_width(original->picture) - gtk_widget_get_width(added->picture)) <= 2,
                "the split divides the width evenly");
        }
        checkFrame(app().window, "split", "the split window produces a rendered frame");
        // Only the focused pane's cursor is live; the other's is steady.
        if (original && added && original->session->terminal()) {
            const auto hold = holdPaneModel(*original);
            const Ubiquitty::Linux::CursorOverlay other = resolvePaneCursorOverlay(*original, original->session->terminal());
            check(!other.focused && other.blinkAlpha == 1.0f, "the unfocused pane's cursor is drawn steady and unfocused");
        }
        // Back to one pane: the new one runs only its shell, so it closes unasked.
        g_action_group_activate_action(G_ACTION_GROUP(app().window), "close-pane", nullptr);
        settle();
        check(app().model->paneTree(surface)->paneCount() == 1, "Close Pane removes the split");
    }
    // A tab running a job asks before it closes, in a libadwaita alert, and
    // keeps its tab when the reader cancels.
    if (app().chrome) {
        const TabID runningTab = app().model->activeTab(surface);
        const int tabsBefore = app().model->tabCount(surface);
        activePane()->session->sendInput(std::string("sleep 30\r"));
        armPTYWriteDrain(activePane());
        const gint64 deadline = g_get_monotonic_time() + 15'000'000;
        while (g_get_monotonic_time() < deadline && app().model->isPaneSafeToClose(paneIDForPane(activePane()))) {
            g_main_context_iteration(nullptr, FALSE);
            (void)activePane()->session->sampleProcessStateOffDrain();
            g_usleep(20'000);
        }
        check(!app().model->isPaneSafeToClose(paneIDForPane(activePane())), "a pane running sleep is not safe to close");
        g_action_group_activate_action(G_ACTION_GROUP(app().window), "close-tab", g_variant_new_uint32(static_cast<std::uint32_t>(runningTab)));
        settle();
        AdwDialog* question = adw_application_window_get_visible_dialog(ADW_APPLICATION_WINDOW(app().window));
        check(question && ADW_IS_ALERT_DIALOG(question), "closing a tab that runs a job asks first");
        check(app().model->tabCount(surface) == tabsBefore, "the tab stays open while the question is asked");
        check(doesMenuOwnKeys(), "an open question takes the keyboard from the terminal");
        if (question) {
            checkFrame(app().window, "close-confirmation", "the close question produces a rendered frame");
            adw_alert_dialog_choose(ADW_ALERT_DIALOG(question), app().window, nullptr, nullptr, nullptr);
            adw_dialog_close(question);
            settle();
        }
        check(app().model->tabCount(surface) == tabsBefore, "cancelling keeps the tab");
    }
    g_action_group_activate_action(G_ACTION_GROUP(app().window), "about", nullptr);
    settle();
    AdwDialog* about = adw_application_window_get_visible_dialog(ADW_APPLICATION_WINDOW(app().window));
    check(about && ADW_IS_ABOUT_DIALOG(about), "About opens libadwaita's application information dialog");
    if (about && ADW_IS_ABOUT_DIALOG(about)) {
        AdwAboutDialog* dialog = ADW_ABOUT_DIALOG(about);
        check(g_strcmp0(adw_about_dialog_get_application_name(dialog), "Ubiquitty") == 0, "About names the application");
        check(g_strcmp0(adw_about_dialog_get_version(dialog), Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str()) == 0,
            "About shows the running build identity");
        check(g_strcmp0(adw_about_dialog_get_application_icon(dialog), Ubiquitty::Linux::GTK::applicationIconName) == 0,
            "About shows the application icon");
        check(gtk_icon_theme_has_icon(gtk_icon_theme_get_for_display(gtk_widget_get_display(app().window)), Ubiquitty::Linux::GTK::applicationIconName),
            "the bundled application icon is found");
        check(adw_about_dialog_get_license_type(dialog) == GTK_LICENSE_APACHE_2_0, "About identifies the application license");
        checkFrame(app().window, "about", "About produces a rendered frame");
        adw_dialog_close(about);
        settle();
    }
    app().configurationWatcher.stop();
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    g_object_unref(application);
    g_print("smoke-window-chrome: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
