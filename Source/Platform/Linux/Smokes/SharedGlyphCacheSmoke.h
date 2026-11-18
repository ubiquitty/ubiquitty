// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks glyph-cache reuse across renderer instances.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSharedGlyphCache()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-shared-glyph-cache: GTK needs a display\n");
        return 1;
    }
    bool didPass = true;
    const auto check = [&](bool isMet, const char* label) {
        g_print("smoke-shared-glyph-cache: %s -- %s\n", label, isMet ? "PASS" : "FAIL");
        didPass = didPass && isMet;
    };
    const auto settle = [] {
        const gint64 deadline = g_get_monotonic_time() + 300000;
        do {
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
    };
    GtkApplication* application = gtk_application_new("org.ubiquitty.shared-glyph-test", G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(G_APPLICATION(application), nullptr, nullptr)) {
        g_object_unref(application);
        return 1;
    }
    const auto newestOwner = [&]() -> std::shared_ptr<App> {
        for (auto entry = windowApps().windows.rbegin(); entry != windowApps().windows.rend(); ++entry) {
            if ((*entry)->application == application && !(*entry)->isClosing)
                return *entry;
        }
        return nullptr;
    };
    const auto closeRemaining = [&] {
        while (GList* windows = gtk_application_get_windows(application))
            gtk_window_destroy(GTK_WINDOW(windows->data));
        settle();
        g_object_unref(application);
    };
    const std::array<const char*, 3> command { "ubiquitty", "-e", "/bin/cat" };
    check(openWindowFromArguments(application, command.size(), command.data(), "/tmp") == 0, "first silent window opens");
    settle();
    auto first = newestOwner();
    check(openWindowFromArguments(application, command.size(), command.data(), "/tmp") == 0, "second silent window opens");
    settle();
    auto second = newestOwner();
    if (!first || !second || first == second || first->panes.empty() || second->panes.empty()) {
        check(false, "both window owners exist");
        closeRemaining();
        return 1;
    }
    auto* firstPane = first->panes.front().get();
    auto* secondPane = second->panes.front().get();
    Ubiquitty::Linux::SharedFontRequest baseRequest;
    {
        AppScope scope(*first);
        baseRequest = sharedFontRequest();
    }
    // The shared minimum budget covers these 80x24 windows and keeps the
    // eviction regression bounded independently of the connected monitor.
    for (const auto& owner : { first, second }) {
        AppScope scope(*owner);
        owner->vulkan.setSharedGlyphRasterizer(owner->sharedFonts->rasterizer(owner->fontRasterizerKind),
            owner->sharedFonts->configuration(owner->fontRasterizerKind), 0);
    }
    const auto feed = [](App& owner, LinuxPane& pane, std::string_view bytes) {
        AppScope scope(owner);
        const auto hold = holdPaneModel(pane);
        Ubiquitty::processBytes(pane.session->terminal(), bytes);
    };
    const auto render = [](App& owner, LinuxPane& pane, std::vector<std::uint8_t>& pixels) {
        AppScope scope(owner);
        const auto hold = holdPaneModel(pane);
        auto* terminal = pane.session->terminal();
        // Closing a tiled window lets the compositor grow its neighbour.
        // Compare glyph lifetime at the same fixture size across that resize.
        Ubiquitty::resize(*terminal, startupRows, startupColumns);
        int width = 0, height = 0;
        const bool didRender = owner.vulkan.renderGrid(owner.rasterContext, terminal, pixels, width, height);
        const bool hasFixtureSize = width == startupColumns * owner.rasterContext.cellWidth()
            && height == startupRows * owner.rasterContext.cellHeight();
        if (didRender && !hasFixtureSize)
            g_printerr("smoke-shared-glyph-cache: frame escaped the fixed %dx%d grid: %dx%d pixels\n", startupColumns, startupRows, width, height);
        return didRender && hasFixtureSize;
    };
    constexpr std::string_view sample = "\033[?25l\033[0m\033[H\033[2Jcache ffi -> \033[1mbold\033[0m \033[3mitalic\033[0m";
    feed(*first, *firstPane, sample);
    feed(*second, *secondPane, sample);
    std::vector<std::uint8_t> firstPixels, secondPixels;
    check(render(*first, *firstPane, firstPixels), "first window warms the atlas");
    const auto warmed = first->vulkan.sharedAtlasStatistics();
    check(render(*second, *secondPane, secondPixels), "second window draws the warm glyphs");
    const auto reused = second->vulkan.sharedAtlasStatistics();
    const auto device = first->vulkan.sharedDeviceIdentity();
    const auto atlas = first->vulkan.sharedFontAtlasIdentity();
    const std::string key(first->vulkan.sharedFontAtlasKey());
    const auto atlasLifetime = first->vulkan.sharedFontAtlasWeak();
    const std::weak_ptr<Ubiquitty::Linux::SharedFontResources> fontLifetime = first->sharedFonts;
    check(device && device == second->vulkan.sharedDeviceIdentity() && atlas && atlas == second->vulkan.sharedFontAtlasIdentity()
            && !key.empty() && key == second->vulkan.sharedFontAtlasKey(),
        "matching windows share the device and font atlas");
    check(first->vulkan.privateTargetIdentity() && second->vulkan.privateTargetIdentity()
            && first->vulkan.privateTargetIdentity() != second->vulkan.privateTargetIdentity() && firstPixels == secondPixels,
        "private frame targets render identical pixels");
    check(reused.rasterizedSlots == warmed.rasterizedSlots && reused.uploadBatches == warmed.uploadBatches,
        "the second window adds no masks or atlas uploads");
    check(reused.activeLeases >= 2 && reused.pinnedSlots > 0, "both views hold live glyph leases");

    for (const std::string_view variant : { "family", "dpi", "features" }) {
        auto request = baseRequest;
        if (variant == "family") {
            request.family = baseRequest.family == "Noto Sans" ? "JetBrains Mono" : "Noto Sans";
            request.primaryPath = bundledFontPathForFamily(request.family);
        } else if (variant == "dpi") {
            request.pixelSize += 2;
            request.pixelsPerPoint *= static_cast<double>(request.pixelSize) / baseRequest.pixelSize;
        } else {
            request.features = baseRequest.features == "liga=0" ? "liga=1" : "liga=0";
        }
        auto fonts = Ubiquitty::Linux::SharedFontResources::acquire(std::move(request));
        auto face = fonts->rasterizer(Ubiquitty::Rendering::FontRasterizerKind::Native);
        Ubiquitty::Linux::RasterContext context;
        context.setRenderConfiguration(first->rasterContext.renderConfiguration());
        context.setDeviceScale(baseRequest.deviceScale);
        context.setGlyphRasterizer(*face);
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setSharedGlyphRasterizer(face, fonts->configuration(Ubiquitty::Rendering::FontRasterizerKind::Native), 0);
        auto terminal = std::make_unique<Ubiquitty::Terminal>();
        Ubiquitty::resize(*terminal, 3, 32);
        Ubiquitty::processBytes(terminal.get(), sample);
        int width = 0, height = 0;
        std::vector<std::uint8_t> pixels;
        const bool didRender = renderer.init() && renderer.renderGrid(context, terminal.get(), pixels, width, height);
        check(didRender && renderer.sharedDeviceIdentity() == device && renderer.sharedFontAtlasIdentity() != atlas
                && !renderer.sharedFontAtlasKey().empty() && renderer.sharedFontAtlasKey() != key,
            variant == "family"    ? "a different font has its own atlas"
                : variant == "dpi" ? "a different raster DPI has its own atlas"
                                   : "different shaping features have their own atlas");
        renderer.shutdown();
    }

    const int capacity = reused.slotCapacity;
    const auto* secondTerm = secondPane->session->terminal();
    const int batchSize = std::max(1, std::min(capacity / 16, secondTerm->rows * (secondTerm->columns / 2)));
    const int wanted = capacity + capacity / 4;
    bool didRenderPressure = capacity > 0;
    constexpr int cjkCount = 0x9FFF - 0x4E00 + 1;
    constexpr int hangulCount = 0xD7A3 - 0xAC00 + 1;
    constexpr int coveredCount = cjkCount + hangulCount;
    const int columnsPerLine = std::max(1, secondTerm->columns / 2);
    int inserted = 0;
    while (didRenderPressure && inserted < wanted) {
        std::string bytes = "\033[?25l\033[H\033[2J";
        const int count = std::min(batchSize, wanted - inserted);
        int currentStyle = -1;
        for (int index = 0; index < count; ++index) {
            const int ordinal = inserted + index;
            const int style = ordinal / coveredCount;
            if (style != currentStyle) {
                bytes += style == 0 ? "\033[0m" : style == 1 ? "\033[1m"
                    : style == 2                             ? "\033[3m"
                                                             : "\033[1;3m";
                currentStyle = style;
            }
            const int scalar = ordinal % coveredCount;
            const auto codePoint = static_cast<std::uint32_t>(scalar < cjkCount ? 0x4E00 + scalar : 0xAC00 + scalar - cjkCount);
            Ubiquitty::Unicode::appendUTF8(bytes, codePoint);
            if ((index + 1) % columnsPerLine == 0 && index + 1 < count)
                bytes += "\r\n";
        }
        feed(*second, *secondPane, bytes);
        didRenderPressure = render(*second, *secondPane, secondPixels);
        inserted += count;
    }
    const auto afterPressure = second->vulkan.sharedAtlasStatistics();
    check(didRenderPressure && afterPressure.rasterizedSlots - reused.rasterizedSlots > static_cast<std::uint64_t>(capacity),
        "the busy window churns more glyphs than the atlas can hold");
    {
        AppScope scope(*first);
        const auto hold = holdPaneModel(*firstPane);
        // Force a whole-frame rebuild without changing the palette's pixels.
        ++firstPane->session->terminal()->paletteEpoch;
    }
    std::vector<std::uint8_t> afterPressurePixels;
    check(render(*first, *firstPane, afterPressurePixels) && afterPressurePixels == firstPixels
            && first->vulkan.sharedAtlasStatistics().rasterizedSlots == afterPressure.rasterizedSlots,
        "the idle window keeps its visible glyphs and exact pixels under pressure");

    gtk_window_destroy(GTK_WINDOW(first->window));
    first.reset();
    check(!atlasLifetime.expired(), "closing one window keeps the other view's shared atlas lease");
    // Dispatching the compositor's new allocation can legitimately grow the
    // survivor's atlas beyond this fixture's minimal capacity.
    settle();
    check(secondPane->session && secondPane->session->isShareableLocalSession(),
        "the remaining window keeps its local child alive");
    feed(*second, *secondPane, sample);
    check(render(*second, *secondPane, secondPixels) && secondPixels == firstPixels,
        "the remaining window still renders the original glyphs");
    const auto survivingAtlasLifetime = second->vulkan.sharedFontAtlasWeak();
    gtk_window_destroy(GTK_WINDOW(second->window));
    second.reset();
    const gint64 expiryDeadline = g_get_monotonic_time() + 3000000;
    while ((!atlasLifetime.expired() || !survivingAtlasLifetime.expired()) && g_get_monotonic_time() < expiryDeadline) {
        g_main_context_iteration(nullptr, FALSE);
        g_usleep(1000);
    }
    check(atlasLifetime.expired() && survivingAtlasLifetime.expired(), "the weak atlas registry expires after the last view closes");
    check(fontLifetime.expired(), "closed frame owners release the last native font provider");
    closeRemaining();
    g_print("smoke-shared-glyph-cache: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
