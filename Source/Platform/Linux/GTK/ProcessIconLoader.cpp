// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/ProcessIconLoader.h"

#include "Core/Title/ProcessIcons.h"
#include "Platform/Linux/BundledFontDirectory.h"

#include <cstddef>
#include <span>

namespace Ubiquitty::Linux::GTK {

namespace {

// Rendered at this many pixels a side: four times a 16-pixel title icon, so a
// 2x display scales it down rather than up.
constexpr int templatePixels = 64;

// A template icon is an alpha mask. Every pixel takes the ink, keeping the
// mask's own coverage times the ink's opacity.
GIcon* tintedTemplate(const std::string& path, bool isInkLight) // bool-ok: the ink's one polarity
{
    GError* error = nullptr;
    GObjectPointer<GdkPixbuf> source(gdk_pixbuf_new_from_file_at_size(path.c_str(), templatePixels, templatePixels, &error));
    if (!source) {
        g_clear_error(&error);
        return nullptr;
    }
    GObjectPointer<GdkPixbuf> pixels(gdk_pixbuf_add_alpha(source.get(), FALSE, 0, 0, 0));
    if (!pixels)
        return nullptr;
    const int width = gdk_pixbuf_get_width(pixels.get());
    const int height = gdk_pixbuf_get_height(pixels.get());
    const int stride = gdk_pixbuf_get_rowstride(pixels.get());
    guint length = 0;
    guchar* bytes = gdk_pixbuf_get_pixels_with_length(pixels.get(), &length);
    const std::span<guchar> data(bytes, length);
    // GNOME's header ink: white on a dark ground, black at 80% on a light one.
    const guchar ink = isInkLight ? 0xFF : 0x00;
    const double opacity = isInkLight ? 1.0 : 0.8;
    for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
            const std::size_t offset = static_cast<std::size_t>(row) * static_cast<std::size_t>(stride) + static_cast<std::size_t>(column) * 4;
            data[offset] = ink;
            data[offset + 1] = ink;
            data[offset + 2] = ink;
            data[offset + 3] = static_cast<guchar>(data[offset + 3] * opacity);
        }
    }
    GBytes* buffer = g_bytes_new(data.data(), data.size());
    GdkTexture* texture = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, buffer, static_cast<gsize>(stride));
    g_bytes_unref(buffer);
    return G_ICON(texture);
}

} // namespace

const std::string& ProcessIconLoader::iconDirectory()
{
    // The build stages the catalog beside the binary, as it stages the fonts,
    // so the one derivation of "beside the binary" serves both.
    static const std::string directory = [] {
        const std::string base = bundledFontDirectory();
        return base.empty() ? std::string() : base + "/process-icons";
    }();
    return directory;
}

GIcon* ProcessIconLoader::icon(std::string_view key, const Presentation::ChromeGround& ground)
{
    if (key.empty() || iconDirectory().empty())
        return nullptr;
    const std::string keyString(key);
    const bool isTemplate = Title::isProcessIconTemplate(keyString);
    // A drawn icon is the same on every ground; a template has one per ink.
    const auto cacheKey = std::make_pair(keyString, isTemplate && ground.isDark);
    if (const auto found = m_icons.find(cacheKey); found != m_icons.end())
        return found->second.get();
    const std::string file = Title::processIconFile(keyString);
    GIcon* loaded = nullptr;
    if (!file.empty()) {
        const std::string path = iconDirectory() + "/" + file;
        if (isTemplate) {
            loaded = tintedTemplate(path, ground.isDark);
        } else {
            GObjectPointer<GFile> source(g_file_new_for_path(path.c_str()));
            loaded = g_file_icon_new(source.get());
        }
    }
    // A failure is remembered too, so a missing file is looked for once.
    return m_icons.emplace(cacheKey, GObjectPointer<GIcon>(loaded)).first->second.get();
}

} // namespace Ubiquitty::Linux::GTK
