// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/GTK/GObjectPointer.h"
#include "Platform/Linux/GTK/ProcessIconLoader.h"
#include "Platform/Linux/Presentation/ChromeContent.h"
#include "Platform/Linux/Presentation/ChromeGround.h"

#include <adwaita.h>

#include <span>
#include <vector>

namespace Ubiquitty::Linux::GTK {

/// The window's tabs on libadwaita's tab bar.
///
/// The model owns the tabs, their order and the selection; the strip mirrors
/// them onto an AdwTabView whose pages are placeholders, since the window
/// mounts the active tab's panes itself. What a person does on the bar —
/// select, close — is handed to the window as its tab actions, and a drag that
/// reorders tabs is put back, as the model does not reorder. Each page shows
/// the program's icon, its status as the page's indicator, a spinner while it
/// works and the attention mark for an unseen bell. The bar hides itself while
/// the window holds one tab.
class TabStrip final {
public:
    /// Builds the bar and the tab view it reads.
    ///
    /// - Parameter icons: The window's program icons, which outlive the strip.
    explicit TabStrip(ProcessIconLoader& icons);
    /// Disconnects the strip from the tab view, which may outlive it in GTK's
    /// hands for as long as the window disposes of it.
    ~TabStrip();
    TabStrip(const TabStrip&) = delete;
    TabStrip& operator=(const TabStrip&) = delete;

    /// The tab bar, borrowed.
    [[nodiscard]] GtkWidget* bar() const { return m_bar.get(); }
    /// The tab view the bar reads, borrowed. It must be in the window's widget
    /// tree, hidden; it holds no content.
    [[nodiscard]] GtkWidget* view() const { return GTK_WIDGET(m_view.get()); }

    /// Shows the window's tabs, in order.
    ///
    /// - Parameters:
    ///   - tabs: Every tab of the window, the active one marked.
    ///   - ground: The ground the program icons are drawn on.
    void show(std::span<const Presentation::TabItem> tabs, const Presentation::ChromeGround& ground);

private:
    /// Finds the page standing for a tab.
    ///
    /// - Parameter identifier: The model's tab identifier.
    /// - Returns: The page, or null when the view holds none for it.
    [[nodiscard]] AdwTabPage* pageFor(std::uint32_t identifier) const;
    /// Puts one tab's label, icon and status on its page.
    ///
    /// - Parameters:
    ///   - page: The tab's page.
    ///   - item: What the tab shows.
    ///   - ground: The ground the program icon is drawn on.
    void showPage(AdwTabPage* page, const Presentation::TabItem& item, const Presentation::ChromeGround& ground);

    /// Hands a selection a person made on the bar to the window's tab action.
    ///
    /// - Parameters:
    ///   - view: The tab view.
    ///   - strip: The strip, as the signal's data.
    static void onSelectedPage(AdwTabView* view, GParamSpec*, gpointer strip);
    /// Keeps a page the bar asked to close until the model has ended its tab.
    ///
    /// - Parameters:
    ///   - view: The tab view.
    ///   - page: The page asked about.
    ///   - strip: The strip, as the signal's data.
    /// - Returns: `GDK_EVENT_STOP`: the strip always answers the close itself.
    static gboolean onClosePage(AdwTabView* view, AdwTabPage* page, gpointer strip);
    /// Puts a dragged tab back in the model's order.
    ///
    /// - Parameters:
    ///   - view: The tab view.
    ///   - page: The page moved.
    ///   - position: Where it was dropped.
    ///   - strip: The strip, as the signal's data.
    static void onPageReordered(AdwTabView* view, AdwTabPage* page, int position, gpointer strip);
    /// Refuses to tear a dragged tab off into a window of its own.
    ///
    /// - Parameters:
    ///   - view: The tab view.
    ///   - strip: The strip, as the signal's data.
    /// - Returns: Null, which cancels the drop.
    static AdwTabView* onCreateWindow(AdwTabView* view, gpointer strip);

    ProcessIconLoader& m_icons;
    GObjectPointer<AdwTabView> m_view;
    GObjectPointer<GtkWidget> m_bar;
    std::vector<Presentation::TabItem> m_shown;
    Presentation::ChromeGround m_ground;
    // Set while the strip itself changes the view, so its own changes are not
    // taken for a person's.
    bool m_isSyncing = false;
};

} // namespace Ubiquitty::Linux::GTK
