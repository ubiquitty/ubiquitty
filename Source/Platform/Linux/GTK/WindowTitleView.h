// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/GTK/GObjectPointer.h"
#include "Platform/Linux/GTK/ProcessIconLoader.h"
#include "Platform/Linux/Presentation/ChromeContent.h"
#include "Platform/Linux/Presentation/ChromeGround.h"
#include "Platform/Linux/Presentation/WindowTitleContent.h"

#include <gtk/gtk.h>

namespace Ubiquitty::Linux::GTK {

/// The header bar's title widget, laid out as libadwaita's two-line window
/// title: the program's icon and a bold title on the first line, and under it
/// a smaller subtitle with what the program said about its work, or the
/// working directory when it said nothing. The status mark is the header's,
/// beside New Tab.
class WindowTitleView final {
public:
    /// Builds the title widget.
    ///
    /// - Parameter icons: The window's program icons, which outlive the view.
    explicit WindowTitleView(ProcessIconLoader& icons);
    WindowTitleView(const WindowTitleView&) = delete;
    WindowTitleView& operator=(const WindowTitleView&) = delete;

    /// The view's widget, borrowed.
    [[nodiscard]] GtkWidget* widget() const { return m_root.get(); }

    /// Shows the focused pane's title and marks.
    ///
    /// - Parameters:
    ///   - content: The two lines.
    ///   - marks: The pane's program, whose icon leads the title.
    ///   - ground: The ground the icon is drawn on.
    void show(const Presentation::WindowTitleContent& content, const Presentation::PaneMarks& marks, const Presentation::ChromeGround& ground);

private:
    /// Shows the program's icon, on a plate where Core says it needs one.
    ///
    /// - Parameters:
    ///   - marks: The pane's program.
    ///   - ground: The ground the icon is drawn on.
    void showIcon(const Presentation::PaneMarks& marks, const Presentation::ChromeGround& ground);

    ProcessIconLoader& m_icons;
    GObjectPointer<GtkWidget> m_root;
    GtkWidget* m_icon = nullptr; // owned by m_root
    GtkWidget* m_title = nullptr; // owned by m_root
    GtkWidget* m_subtitle = nullptr; // owned by m_root
};

} // namespace Ubiquitty::Linux::GTK
