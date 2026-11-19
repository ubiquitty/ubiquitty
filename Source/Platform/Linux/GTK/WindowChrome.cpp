// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/WindowChrome.h"

#include <adwaita.h>

#include <algorithm>

namespace Ubiquitty::Linux::GTK {

using Presentation::ChromeGround;

namespace {

constexpr const char* styleSheetKey = "ubiquitty-chrome-style-sheet";

// The chrome's few rules of its own; every colour is libadwaita's.
constexpr const char* styleSheet = R"css(
.ubiquitty-window-title .title,
.ubiquitty-window-title .subtitle {
    padding-left: 0;
    padding-right: 0;
}
.ubiquitty-process-icon.plate {
    background-color: currentColor;
    border-radius: 4px;
    padding: 1px;
}
)css";

constexpr const char* searchBarKey = "ubiquitty-chrome-search-bar";

void onFullscreened(GtkWindow* window, GParamSpec*, gpointer toolbar)
{
    adw_toolbar_view_set_reveal_top_bars(ADW_TOOLBAR_VIEW(toolbar), !gtk_window_is_fullscreen(window));
}

// The terminal is the window itself, not a widget in it: it has the keys while
// no widget has focus. Focus that lands in the top bar — GTK gives a new window
// its first focusable widget, a header button — is cleared, except in the find
// bar, which is for typing, and in a menu that is open. Clearing it, not
// grabbing the window: a window's grab_focus hands focus to its first
// focusable child, which is the header again.
void onFocusWidget(GtkWindow* window, GParamSpec*, gpointer toolbar)
{
    GtkWidget* focus = gtk_window_get_focus(window);
    if (!focus || !gtk_widget_is_ancestor(focus, GTK_WIDGET(toolbar)))
        return;
    if (gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))
        return;
    auto* searchBar = static_cast<GtkWidget*>(g_object_get_data(G_OBJECT(toolbar), searchBarKey));
    if (searchBar && (focus == searchBar || gtk_widget_is_ancestor(focus, searchBar)))
        return;
    // Inside the content, past the top bar, is the panes' own business.
    GtkWidget* content = adw_toolbar_view_get_content(ADW_TOOLBAR_VIEW(toolbar));
    if (content && (focus == content || gtk_widget_is_ancestor(focus, content)))
        return;
    gtk_window_set_focus(window, nullptr);
}

} // namespace

WindowChrome::WindowChrome(GtkWidget* content, GtkWidget* searchBar)
    : m_root(adoptSunk(adw_toolbar_view_new()))
    , m_menuButton(gtk_menu_button_new())
    , m_toasts(adw_toast_overlay_new())
    , m_title(m_icons)
    , m_tabs(m_icons)
{
    AdwToolbarView* toolbar = ADW_TOOLBAR_VIEW(m_root.get());
    // Raised: the top bar casts its shadow over the terminal, as libadwaita
    // terminals draw it.
    adw_toolbar_view_set_top_bar_style(toolbar, ADW_TOOLBAR_RAISED);

    GtkWidget* header = adw_header_bar_new();
    GtkWidget* newTab = gtk_button_new_from_icon_name("tab-new-symbolic");
    gtk_widget_set_tooltip_text(newTab, "New Tab");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(newTab), Presentation::ChromeActions::newTab);
    gtk_widget_set_focusable(newTab, FALSE);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), newTab);

    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(m_menuButton), "open-menu-symbolic");
    // The primary menu: F10 opens it, per the HIG.
    gtk_menu_button_set_primary(GTK_MENU_BUTTON(m_menuButton), TRUE);
    gtk_widget_set_tooltip_text(m_menuButton, "Main Menu");
    // F10 still opens it: the primary menu is reached by its key, not by Tab.
    if (GtkWidget* button = gtk_widget_get_first_child(m_menuButton))
        gtk_widget_set_focusable(button, FALSE);
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), m_menuButton);
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), m_title.widget());

    adw_toolbar_view_add_top_bar(toolbar, header);
    adw_toolbar_view_add_top_bar(toolbar, m_tabs.bar());
    if (searchBar) {
        adw_toolbar_view_add_top_bar(toolbar, searchBar);
        g_object_set_data(G_OBJECT(toolbar), searchBarKey, searchBar);
    }

    GtkWidget* body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(body), m_tabs.view());
    gtk_box_append(GTK_BOX(body), content);
    adw_toast_overlay_set_child(ADW_TOAST_OVERLAY(m_toasts), body);
    adw_toolbar_view_set_content(toolbar, m_toasts);
}

WindowChrome::~WindowChrome()
{
    if (m_shownToast)
        g_object_remove_weak_pointer(G_OBJECT(m_shownToast), reinterpret_cast<gpointer*>(&m_shownToast));
}

void WindowChrome::showToast(const char* message)
{
    if (m_shownToast) {
        g_object_remove_weak_pointer(G_OBJECT(m_shownToast), reinterpret_cast<gpointer*>(&m_shownToast));
        adw_toast_dismiss(m_shownToast);
        m_shownToast = nullptr;
    }
    AdwToast* toast = adw_toast_new(message);
    adw_toast_set_timeout(toast, 2);
    m_shownToast = toast;
    g_object_add_weak_pointer(G_OBJECT(toast), reinterpret_cast<gpointer*>(&m_shownToast));
    adw_toast_overlay_add_toast(ADW_TOAST_OVERLAY(m_toasts), toast);
}

void WindowChrome::attach(GtkWindow* window)
{
    installStyleSheet(gtk_widget_get_display(GTK_WIDGET(window)));
    // Tied to the toolbar's life, so the handler cannot outlive what it hides.
    g_signal_connect_object(window, "notify::fullscreened", G_CALLBACK(onFullscreened), m_root.get(), G_CONNECT_DEFAULT);
    g_signal_connect_object(window, "notify::focus-widget", G_CALLBACK(onFocusWidget), m_root.get(), G_CONNECT_DEFAULT);
}

void WindowChrome::installStyleSheet(GdkDisplay* display)
{
    if (!display || g_object_get_data(G_OBJECT(display), styleSheetKey))
        return;
    GtkCssProvider* provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, styleSheet);
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    // The display holds the provider for as long as it lives.
    g_object_set_data_full(G_OBJECT(display), styleSheetKey, provider, +[](gpointer object) { g_object_unref(object); });
}

void WindowChrome::setMenuModel(GMenuModel* model)
{
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(m_menuButton), model);
}

GtkMenuButton* WindowChrome::menuButton() const
{
    return GTK_MENU_BUTTON(m_menuButton);
}

void WindowChrome::setStyle(Preferences::TitlebarStyle style, std::uint32_t themeBackgroundRGB)
{
    m_style = style;
    m_themeBackgroundRGB = themeBackgroundRGB;
    // The style manager is never forced to a scheme: it stays the desktop's,
    // which is what an appearance-following theme reads, and a themed header
    // carries its own ink (WindowAppearance).
    refreshGround();
}

ChromeGround WindowChrome::ground() const
{
    if (m_style == Preferences::TitlebarStyle::Themed)
        return ChromeGround::fromBackground(m_themeBackgroundRGB);
    return ChromeGround::forStockHeader(adw_style_manager_get_dark(adw_style_manager_get_default()));
}

void WindowChrome::showTitle(const Presentation::WindowTitleContent& content, const Presentation::PaneMarks& marks)
{
    // The window polls its title; an unchanged one touches no widget.
    if (m_hasShownTitle && content == m_shownContent && marks == m_shownMarks)
        return;
    m_hasShownTitle = true;
    m_shownContent = content;
    m_shownMarks = marks;
    m_title.show(content, marks, ground());
}

void WindowChrome::showTabs(std::span<const Presentation::TabItem> tabs)
{
    if (std::ranges::equal(tabs, m_shownTabs))
        return;
    m_shownTabs.assign(tabs.begin(), tabs.end());
    m_tabs.show(tabs, ground());
}

void WindowChrome::refreshGround()
{
    const ChromeGround current = ground();
    m_title.show(m_shownContent, m_shownMarks, current);
    m_tabs.show(m_shownTabs, current);
}

} // namespace Ubiquitty::Linux::GTK
