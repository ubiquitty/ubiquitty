// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/WindowAppearance.h"

#include "Core/Themes/Contrast.h"
#include "Core/Themes/Themes.h"
#include "Platform/Linux/Presentation/ChromeGround.h"

#include <array>
#include <cstdint>

namespace Ubiquitty::Linux::GTK {

namespace {

// WCAG 2's minimum for body text, which a title is.
constexpr double minimumHeaderContrast = 4.5;

} // namespace

void WindowAppearance::ObjectRelease::operator()(gpointer object) const
{
    g_object_unref(object);
}

WindowAppearance::~WindowAppearance()
{
    reset();
}

void WindowAppearance::reset()
{
    if (m_provider && m_display)
        gtk_style_context_remove_provider_for_display(m_display.get(), GTK_STYLE_PROVIDER(m_provider.get()));
    m_provider.reset();
    m_display.reset();
}

GtkCssProvider* WindowAppearance::cssProvider() const
{
    return m_provider.get();
}

GdkRGBA WindowAppearance::nativeLinkColor()
{
    std::unique_ptr<GtkWidget, ObjectRelease> probe(gtk_link_button_new("https://example.invalid"));
    g_object_ref_sink(probe.get());
    GdkRGBA color {};
    gtk_widget_get_color(probe.get(), &color);
    return color;
}

void WindowAppearance::apply(GtkWidget* window, GtkWidget* paneContainer, const Themes::Theme& theme, double backgroundOpacity,
    Preferences::TitlebarStyle titlebarStyle)
{
    if (!window)
        return;
    // The grid texture carries opacity. Transparent widget backgrounds expose
    // the compositor through padding and unused portions of the pane area.
    const bool isTranslucent = backgroundOpacity < 1.0;
    gtk_widget_add_css_class(window, "ubiquitty-themed-bg");
    if (paneContainer)
        gtk_widget_add_css_class(paneContainer, "ubiquitty-themed-bg");
    if (isTranslucent)
        gtk_widget_add_css_class(window, "ubiquitty-translucent");
    else
        gtk_widget_remove_css_class(window, "ubiquitty-translucent");
    if (m_scopeClass.empty())
        m_scopeClass = "ubiquitty-window-" + std::to_string(reinterpret_cast<std::uintptr_t>(this));
    gtk_widget_add_css_class(window, m_scopeClass.c_str());

    GdkDisplay* display = gtk_widget_get_display(window);
    if (m_display.get() != display)
        reset();
    if (!m_provider) {
        m_provider.reset(gtk_css_provider_new());
        m_display.reset(GDK_DISPLAY(g_object_ref(display)));
        gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(m_provider.get()), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    const ColorRGBA backgroundColor = theme.defaultBackground;
    const ColorRGBA foregroundColor = theme.defaultForeground;
    std::array<char, 8> background {};
    std::array<char, 8> foreground {};
    g_snprintf(background.data(), background.size(), "#%02x%02x%02x", backgroundColor.red, backgroundColor.green, backgroundColor.blue);
    g_snprintf(foreground.data(), foreground.size(), "#%02x%02x%02x", foregroundColor.red, foregroundColor.green, foregroundColor.blue);
    const std::string backdrop = isTranslucent ? "transparent" : background.data();
    const std::string ink = foreground.data();
    const std::string scope = "." + m_scopeClass;
    // A themed chrome sets libadwaita's header ground: a shade off the
    // terminal's, so the raised top bar reads as a bar over it. It takes the
    // terminal's ink only where that ink reads on it. Everything else — menus, dialogs, buttons — stays the system's.
    const auto packed = [](const ColorRGBA& color) {
        return (std::uint32_t { color.red } << 16) | (std::uint32_t { color.green } << 8) | color.blue;
    };
    const bool isInkReadable = Themes::Contrast::wcagContrastRatio(packed(foregroundColor), packed(backgroundColor)) >= minimumHeaderContrast;
    const std::string headerGround = isInkReadable ? "mix(" + std::string(background.data()) + ", " + ink + ", 0.04)" : std::string(background.data());
    // An ink that does not read is replaced by libadwaita's own for a ground
    // of that polarity, whatever style the desktop is in.
    const bool isGroundDark = Presentation::ChromeGround::fromBackground(packed(backgroundColor)).isDark;
    const std::string headerInk = isInkReadable ? ink : (isGroundDark ? "#ffffff" : "rgb(0 0 6 / 80%)");
    const std::string themedChrome = titlebarStyle == Preferences::TitlebarStyle::Themed
        ? scope + " { --headerbar-bg-color: " + headerGround + "; --headerbar-backdrop-color: var(--headerbar-bg-color);"
            + " --headerbar-fg-color: " + headerInk + "; --headerbar-border-color: " + headerInk + "; }"
        : std::string {};
    // Translucency exposes the compositor through the window's own ground and
    // the pane area, not through the chrome or its menus.
    const std::string css = (isTranslucent ? scope + " { background-color: transparent; }" : std::string {})
        + scope + ".ubiquitty-themed-bg, " + scope + " .ubiquitty-themed-bg { background-color: " + backdrop + "; }"
        + themedChrome;
    gtk_css_provider_load_from_string(m_provider.get(), css.c_str());
}

} // namespace Ubiquitty::Linux::GTK
