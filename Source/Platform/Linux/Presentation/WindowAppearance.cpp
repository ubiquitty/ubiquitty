// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Presentation/WindowAppearance.h"

#include "Core/Themes/Themes.h"

#include <array>
#include <cstdint>

namespace Ubiquitty::Linux::Presentation {

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

void WindowAppearance::apply(GtkWidget* window, GtkWidget* paneContainer, const Themes::Theme& theme, double backgroundOpacity)
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
    const std::string tabs = scope + " .ubiquitty-tabs";
    const std::string header = scope + " headerbar.ubiquitty-titlebar";
    const std::string css = (isTranslucent ? scope + ", " + scope + " * { background-color: transparent; }" : std::string {})
        + scope + ".ubiquitty-themed-bg, " + scope + " .ubiquitty-themed-bg { background-color: " + backdrop + "; }"
        + header + " { background: " + backdrop + "; color: " + ink + "; box-shadow: none; border: none; }"
        + header + " button { color: " + ink + "; }"
        + tabs + " { background: " + backdrop + "; color: " + ink + "; padding: 4px 8px; border-bottom: 1px solid alpha(" + ink + ", 0.12); }"
        + tabs + " button { background: transparent; color: inherit; box-shadow: none; border: 1px solid transparent; border-radius: 6px; padding: 4px 10px; min-height: 26px; }"
        + tabs + " button:hover { background: alpha(" + ink + ", 0.08); }"
        + tabs + " button:checked { background: alpha(" + ink + ", 0.12); border-bottom-color: " + ink + "; }"
        + tabs + " button:focus-visible { outline: 2px solid " + ink + "; outline-offset: -2px; }"
        + tabs + " popover contents { background: " + backdrop + "; color: " + ink + "; }";
    gtk_css_provider_load_from_string(m_provider.get(), css.c_str());
}

} // namespace Ubiquitty::Linux::Presentation
