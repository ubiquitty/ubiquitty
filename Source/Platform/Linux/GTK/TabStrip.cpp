// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/TabStrip.h"

#include <algorithm>
#include <string>

namespace Ubiquitty::Linux::GTK {

using Presentation::ChromeGround;
using Presentation::TabItem;
using Presentation::ChromeActions::activeTab;
using Presentation::ChromeActions::closeTab;

namespace {

constexpr const char* identifierKey = "ubiquitty-tab-identifier";

std::uint32_t identifierOf(AdwTabPage* page)
{
    return GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(page), identifierKey));
}

// A tab page's tooltip is markup.
std::string escaped(const std::string& text)
{
    gchar* markup = g_markup_escape_text(text.c_str(), -1);
    std::string result(markup);
    g_free(markup);
    return result;
}

} // namespace

TabStrip::TabStrip(ProcessIconLoader& icons)
    : m_icons(icons)
    , m_view(adoptSunk(adw_tab_view_new()))
    , m_bar(adoptSunk(GTK_WIDGET(adw_tab_bar_new())))
{
    AdwTabView* view = m_view.get();
    // The terminal owns the keyboard: none of the view's own shortcuts
    // (Ctrl+Tab, Alt+1…9, Ctrl+Page Up…) may take a key from it.
    adw_tab_view_set_shortcuts(view, ADW_TAB_VIEW_SHORTCUT_NONE);
    gtk_widget_set_visible(GTK_WIDGET(view), FALSE);
    adw_tab_bar_set_view(ADW_TAB_BAR(m_bar.get()), view);
    adw_tab_bar_set_autohide(ADW_TAB_BAR(m_bar.get()), TRUE);
    g_signal_connect(view, "notify::selected-page", G_CALLBACK(onSelectedPage), this);
    g_signal_connect(view, "close-page", G_CALLBACK(onClosePage), this);
    g_signal_connect(view, "page-reordered", G_CALLBACK(onPageReordered), this);
    g_signal_connect(view, "create-window", G_CALLBACK(onCreateWindow), this);
}

TabStrip::~TabStrip()
{
    g_signal_handlers_disconnect_by_data(m_view.get(), this);
}

AdwTabPage* TabStrip::pageFor(std::uint32_t identifier) const
{
    const int count = adw_tab_view_get_n_pages(m_view.get());
    for (int index = 0; index < count; ++index) {
        AdwTabPage* page = adw_tab_view_get_nth_page(m_view.get(), index);
        if (identifierOf(page) == identifier)
            return page;
    }
    return nullptr;
}

void TabStrip::showPage(AdwTabPage* page, const TabItem& item, const ChromeGround& ground)
{
    adw_tab_page_set_title(page, item.label.c_str());
    std::string tooltip = escaped(item.label);
    if (!item.marks.processIconTitle.empty())
        tooltip += "\n" + escaped(item.marks.processIconTitle);
    adw_tab_page_set_tooltip(page, tooltip.c_str());
    adw_tab_page_set_icon(page, m_icons.icon(item.marks.processIconKey, ground));

    const std::optional<Presentation::StatusSymbol> symbol = item.marks.shownSymbol();
    // Work in flight is the page's own spinner, which libadwaita draws in
    // place of the icon.
    adw_tab_page_set_loading(page, symbol && symbol->isSpinner);
    if (symbol && !symbol->isSpinner) {
        GObjectPointer<GIcon> indicator(g_themed_icon_new(std::string(symbol->iconName).c_str()));
        adw_tab_page_set_indicator_icon(page, indicator.get());
        adw_tab_page_set_indicator_tooltip(page, std::string(symbol->spokenName).c_str());
    } else {
        adw_tab_page_set_indicator_icon(page, nullptr);
        adw_tab_page_set_indicator_tooltip(page, "");
    }
    adw_tab_page_set_indicator_activatable(page, FALSE);
    adw_tab_page_set_needs_attention(page, item.marks.hasUnheardBell && !item.isActive);
}

void TabStrip::show(std::span<const TabItem> tabs, const ChromeGround& ground)
{
    AdwTabView* view = m_view.get();
    m_isSyncing = true;
    for (int index = adw_tab_view_get_n_pages(view) - 1; index >= 0; --index) {
        AdwTabPage* page = adw_tab_view_get_nth_page(view, index);
        const std::uint32_t identifier = identifierOf(page);
        if (std::ranges::none_of(tabs, [&](const TabItem& item) { return item.identifier == identifier; }))
            adw_tab_view_close_page(view, page);
    }
    for (std::size_t position = 0; position < tabs.size(); ++position) {
        const TabItem& item = tabs[position];
        AdwTabPage* page = pageFor(item.identifier);
        if (!page) {
            page = adw_tab_view_append(view, gtk_box_new(GTK_ORIENTATION_VERTICAL, 0));
            g_object_set_data(G_OBJECT(page), identifierKey, GUINT_TO_POINTER(item.identifier));
        }
        adw_tab_view_reorder_page(view, page, static_cast<int>(position));
        showPage(page, item, ground);
        if (item.isActive)
            adw_tab_view_set_selected_page(view, page);
    }
    m_isSyncing = false;
    m_shown.assign(tabs.begin(), tabs.end());
    m_ground = ground;
}

void TabStrip::onSelectedPage(AdwTabView* view, GParamSpec*, gpointer data)
{
    const auto& strip = *static_cast<TabStrip*>(data);
    AdwTabPage* page = adw_tab_view_get_selected_page(view);
    if (strip.m_isSyncing || !page)
        return;
    gtk_widget_activate_action(GTK_WIDGET(view), activeTab, "u", identifierOf(page));
}

gboolean TabStrip::onClosePage(AdwTabView* view, AdwTabPage* page, gpointer data)
{
    const auto& strip = *static_cast<TabStrip*>(data);
    if (strip.m_isSyncing) {
        adw_tab_view_close_page_finish(view, page, TRUE);
        return GDK_EVENT_STOP;
    }
    // The model decides: the page stays until the window's next refresh says
    // its tab has gone.
    const std::uint32_t identifier = identifierOf(page);
    adw_tab_view_close_page_finish(view, page, FALSE);
    gtk_widget_activate_action(GTK_WIDGET(view), closeTab, "u", identifier);
    return GDK_EVENT_STOP;
}

void TabStrip::onPageReordered(AdwTabView*, AdwTabPage*, int, gpointer data)
{
    auto& strip = *static_cast<TabStrip*>(data);
    if (strip.m_isSyncing)
        return;
    const std::vector<TabItem> shown = strip.m_shown;
    strip.show(shown, strip.m_ground);
}

AdwTabView* TabStrip::onCreateWindow(AdwTabView*, gpointer)
{
    // A tab dragged out of the window is not torn off into a new one.
    return nullptr;
}

} // namespace Ubiquitty::Linux::GTK
