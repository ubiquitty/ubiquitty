// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Exercise the presentation node itself, without a Vulkan device or a window.
// A stale frame keeps its origin and pixel size as the allocation changes.
/// Checks stale-frame origin, clipping and buffer return across allocation changes.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFramePaintable()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-frame-paintable: no GTK display\n");
        return 1;
    }
    int failures = 0;
    for (const int scale : { 1, 2 }) {
        const int pixelWidth = 8 * scale;
        const int pixelHeight = 4 * scale;
        std::vector<std::uint8_t> pixels(static_cast<std::size_t>(pixelWidth * pixelHeight * 4));
        for (int row = 0; row < pixelHeight; ++row) {
            for (int column = 0; column < pixelWidth; ++column) {
                const auto offset = static_cast<std::size_t>((row * pixelWidth + column) * 4);
                pixels[offset] = column < 2 * scale ? 255 : 0;
                pixels[offset + 2] = column < 2 * scale ? 0 : 255;
                pixels[offset + 3] = 255;
            }
        }
        GBytes* bytes = g_bytes_new(pixels.data(), pixels.size());
        GdkTexture* texture = GDK_TEXTURE(gdk_memory_texture_new(pixelWidth, pixelHeight, GDK_MEMORY_R8G8B8A8, bytes, static_cast<std::size_t>(pixelWidth * 4)));
        g_bytes_unref(bytes);
        const graphene_rect_t bounds = GRAPHENE_RECT_INIT(2.0f * scale, 1.0f * scale, static_cast<float>(pixelWidth), static_cast<float>(pixelHeight));
        GdkPaintable* paintable = makeFramePaintable(texture, bounds, 12, 6, static_cast<float>(scale));
        g_object_unref(texture);
        if (gdk_paintable_get_intrinsic_width(paintable) != 12 || gdk_paintable_get_intrinsic_height(paintable) != 6)
            ++failures;
        for (const auto& [width, height] : { std::pair { 4, 4 }, std::pair { 12, 6 }, std::pair { 16, 10 } }) {
            GtkSnapshot* snapshot = gtk_snapshot_new();
            gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
            GskRenderNode* node = gtk_snapshot_free_to_node(snapshot);
            if (!node) {
                ++failures;
                continue;
            }
            cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
            cairo_t* context = cairo_create(surface);
            gsk_render_node_draw(node, context);
            cairo_destroy(context);
            cairo_surface_flush(surface);
            const unsigned char* output = cairo_image_surface_get_data(surface);
            const int stride = cairo_image_surface_get_stride(surface);
            bool matches = cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS;
            for (int row = 0; row < height; ++row) {
                for (int column = 0; column < width; ++column) {
                    const bool isInFrame = column >= 2 && column < 10 && row >= 1 && row < 5;
                    const std::uint32_t expected = isInFrame ? (column < 4 ? 0xFFFF0000u : 0xFF0000FFu) : 0u;
                    std::uint32_t actual = 0;
                    std::memcpy(&actual, output + row * stride + column * 4, sizeof(actual));
                    matches = matches && actual == expected;
                }
            }
            cairo_surface_destroy(surface);
            gsk_render_node_unref(node);
            if (!matches) {
                g_printerr("smoke-frame-paintable: scale %d, allocation %dx%d stretched, shifted or filled the frame\n", scale, width, height);
                ++failures;
            }
        }
        g_object_unref(paintable);
    }
    // GDK may release a window's pixels on a render worker with no AppScope.
    // Returning them must use the pool captured at creation, not that thread's
    // default window or whichever window happens to be active later.
    auto owner = std::make_shared<App>();
    auto buffer = std::make_unique<std::vector<uint8_t>>(4, 255);
    const auto* originalBuffer = buffer.get();
    GdkTexture* pooledTexture = makeMemoryFrameTexture(owner, std::move(buffer), 1, 1);
    std::thread reclaimer([pooledTexture] { g_object_unref(pooledTexture); });
    reclaimer.join();
    const bool didReturnToOwner = owner->framePool.take().get() == originalBuffer;
    if (!didReturnToOwner)
        ++failures;
    g_print("smoke-frame-paintable: worker-release-owner=%s\n", didReturnToOwner ? "PASS" : "FAIL");
    auto lastBuffer = std::make_unique<std::vector<uint8_t>>(4, 255);
    GdkTexture* lastTexture = makeMemoryFrameTexture(owner, std::move(lastBuffer), 1, 1);
    std::weak_ptr<App> lifetime = owner;
    owner.reset();
    const bool didKeepOwnerAlive = !lifetime.expired();
    std::thread lastReclaimer([lastTexture] { g_object_unref(lastTexture); });
    lastReclaimer.join();
    const bool didReleaseOwner = lifetime.expired();
    if (!didKeepOwnerAlive || !didReleaseOwner)
        ++failures;
    g_print("smoke-frame-paintable: texture-retains-owner=%d final-release-destroys-owner=%d\n", didKeepOwnerAlive, didReleaseOwner);

    g_print("smoke-frame-paintable: %s (%d failures; 1x/2x shrink, same size and grow)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
