// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Preferences/Preferences.h"
#include "Platform/Linux/GTK/GObjectPointer.h"
#include "Platform/Linux/GTK/ProcessIconLoader.h"
#include "Platform/Linux/GTK/StatusMarkView.h"
#include "Platform/Linux/GTK/TabStrip.h"
#include "Platform/Linux/GTK/WindowTitleView.h"
#include "Platform/Linux/Presentation/ChromeContent.h"
#include "Platform/Linux/Presentation/ChromeGround.h"
#include "Platform/Linux/Presentation/WindowTitleContent.h"

#include <adwaita.h>

#include <gtk/gtk.h>

#include <cstdint>
#include <span>

namespace Ubiquitty::Linux::GTK {

/// A terminal window's GNOME chrome, built from libadwaita as GNOME's own
/// terminals build theirs: a raised top bar holding the header (new tab at the
/// start, the two-line title, the focused program's status mark, the primary
/// menu and the window controls at the end), the tab bar, and the find bar,
/// over the window's content.
///
/// Every control names a window action (`Presentation::ChromeActions`); the
/// chrome holds no callback into the window that owns it.
class WindowChrome final {
public:
    /// - Parameters:
    ///   - content: The window's content, under the top bar.
    ///   - searchBar: The find bar, shown under the tabs.
    WindowChrome(GtkWidget* content, GtkWidget* searchBar);
    /// Stops watching the toast on screen, which GTK may still hold.
    ~WindowChrome();
    WindowChrome(const WindowChrome&) = delete;
    WindowChrome& operator=(const WindowChrome&) = delete;

    /// The chrome and the content under it, for the window's content; borrowed.
    [[nodiscard]] GtkWidget* widget() const { return m_root.get(); }

    /// Hides the top bar while the window is fullscreen, and hands keyboard
    /// focus that lands in it back to the terminal.
    ///
    /// - Parameter window: The window whose content the chrome is.
    void attach(GtkWindow* window);

    /// Sets what the primary menu offers.
    ///
    /// - Parameter model: The primary menu's model.
    void setMenuModel(GMenuModel* model);

    /// The primary menu button, borrowed, for a context menu to pop up.
    [[nodiscard]] GtkMenuButton* menuButton() const;
    /// The tab bar, borrowed.
    [[nodiscard]] GtkWidget* tabBar() const { return m_tabs.bar(); }

    /// How the chrome is coloured: in the terminal theme's ground, with the
    /// light or dark style that suits it, or as the system styles it.
    ///
    /// - Parameters:
    ///   - style: The `[appearance] titlebar_style` preference.
    ///   - themeBackgroundRGB: The terminal theme's background, as 0xRRGGBB.
    void setStyle(Preferences::TitlebarStyle style, std::uint32_t themeBackgroundRGB);

    /// Shows the focused pane's title and marks.
    ///
    /// - Parameters:
    ///   - content: The header's two lines.
    ///   - marks: The pane's program icon and status.
    void showTitle(const Presentation::WindowTitleContent& content, const Presentation::PaneMarks& marks);

    /// Shows the window's tabs.
    ///
    /// - Parameter tabs: Every tab of the window, the active one marked.
    void showTabs(std::span<const Presentation::TabItem> tabs);

    /// Redraws what depends on the ground, after the system style changed.
    void refreshGround();

    /// Confirms an action that shows nothing of its own — a copy — with a
    /// libadwaita toast over the content. A toast for the same message still
    /// on screen is replaced, so repeating the action never queues them up.
    ///
    /// - Parameter message: What the toast says.
    void showToast(const char* message);

private:
    /// The ground the chrome is drawn on now.
    ///
    /// - Returns: The terminal theme's for a themed chrome, else the stock
    ///   header's of the system's light or dark style.
    [[nodiscard]] Presentation::ChromeGround ground() const;
    /// Installs the chrome's own rules once per display.
    ///
    /// - Parameter display: The display the window is on.
    static void installStyleSheet(GdkDisplay* display);

    ProcessIconLoader m_icons;
    GObjectPointer<GtkWidget> m_root;
    GtkWidget* m_menuButton = nullptr; // owned by m_root
    GtkWidget* m_toasts = nullptr; // owned by m_root
    AdwToast* m_shownToast = nullptr; // weak: cleared when the toast goes
    WindowTitleView m_title;
    StatusMarkView m_status;
    TabStrip m_tabs;
    Preferences::TitlebarStyle m_style = Preferences::TitlebarStyle::Native;
    std::uint32_t m_themeBackgroundRGB = Presentation::ChromeGround::lightHeaderRGB;
    bool m_hasShownTitle = false; // bool-ok: names the one state it reports
    Presentation::WindowTitleContent m_shownContent;
    Presentation::PaneMarks m_shownMarks;
    std::vector<Presentation::TabItem> m_shownTabs;
};

} // namespace Ubiquitty::Linux::GTK
