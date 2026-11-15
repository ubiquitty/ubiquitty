// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <gtk/gtk.h>

#include <memory>
#include <string>

namespace Ubiquitty::Themes {
struct Theme;
}

namespace Ubiquitty::Linux::Presentation {

/// Owns the GTK styles that present one window's terminal palette.
///
/// Each controller scopes its display provider to its own window. GTK calls
/// and teardown belong to the presentation thread.
class WindowAppearance final {
public:
    /// Creates an appearance owner without an installed style provider.
    WindowAppearance() = default;
    /// Removes the installed provider and releases its GTK references.
    ~WindowAppearance();
    WindowAppearance(const WindowAppearance&) = delete;
    WindowAppearance& operator=(const WindowAppearance&) = delete;

    /// Applies the selected palette to window chrome, padding and pane remainders.
    ///
    /// - Parameters:
    ///   - window: The window associated with this controller.
    ///   - paneContainer: The pane container, or null before panes are mounted.
    ///   - theme: The resolved palette selected by the shared theme policy.
    ///   - backgroundOpacity: The grid's opacity; translucency exposes its backdrop.
    void apply(GtkWidget* window, GtkWidget* paneContainer, const Themes::Theme& theme, double backgroundOpacity);

    /// Removes the display provider while preserving the controller's scope identity.
    void reset();

    /// Returns the installed provider without transferring its ownership.
    ///
    /// - Returns: A borrowed provider, or null until styles are applied.
    [[nodiscard]] GtkCssProvider* cssProvider() const;

    /// Reads GTK's native link color from an unparented link widget.
    ///
    /// - Returns: The toolkit's link foreground in straight-alpha sRGB.
    [[nodiscard]] static GdkRGBA nativeLinkColor();

private:
    /// Releases the reference held by an owned GTK object.
    struct ObjectRelease {
        /// Drops one strong GObject reference.
        ///
        /// - Parameter object: The non-null object released by its owner.
        void operator()(gpointer object) const;
    };

    std::unique_ptr<GdkDisplay, ObjectRelease> m_display;
    std::unique_ptr<GtkCssProvider, ObjectRelease> m_provider;
    std::string m_scopeClass;
};

} // namespace Ubiquitty::Linux::Presentation
