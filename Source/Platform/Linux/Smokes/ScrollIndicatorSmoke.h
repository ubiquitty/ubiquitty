// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks scroll-indicator state against the pane viewport.
///
/// - Returns: Whether every check passed.
bool smokeScrollIndicator()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-scroll-indicator: GTK display unavailable\n");
        return false;
    }
    Ubiquitty::Rendering::ScrollIndicatorParameters parameters;
    parameters.alpha = 1;
    parameters.scrollbackCount = 100;
    parameters.rows = 20;
    parameters.viewportSizeInPixels = { 320, 240 };
    parameters.isFullScreen = true;
    Ubiquitty::Rendering::OverlayQuad bottom;
    Ubiquitty::Rendering::OverlayQuad top;
    const bool hasBottom = Ubiquitty::Rendering::buildScrollIndicatorQuad(parameters, bottom);
    parameters.viewOffset = 100;
    const bool hasTop = Ubiquitty::Rendering::buildScrollIndicatorQuad(parameters, top);
    const bool isGeometryCorrect = hasBottom && hasTop && top.minY < bottom.minY
        && top.minX == bottom.minX && top.maxX == bottom.maxX && top.minX > 0 && top.maxX < 320;
    const std::uint32_t stamp = 100;
    const bool doesFade = Ubiquitty::scrollIndicatorAlpha(stamp, stamp + 59) == 1
        && Ubiquitty::scrollIndicatorAlpha(stamp, stamp + 78) > 0
        && Ubiquitty::scrollIndicatorAlpha(stamp, stamp + 78) < 1
        && Ubiquitty::scrollIndicatorAlpha(stamp, stamp + 96) == 0;
    parameters.alpha = 0;
    const bool isHidden = !Ubiquitty::Rendering::buildScrollIndicatorQuad(parameters, top);
    GtkWidget* const savedOverlay = app().scrollIndicator;
    app().scrollIndicator = GTK_WIDGET(g_object_ref_sink(gtk_drawing_area_new()));
    gtk_widget_set_can_target(app().scrollIndicator, FALSE);
    noteScrollIndicatorActivity(*activePane());
    const bool didWake = gtk_widget_get_visible(app().scrollIndicator) && app().scrollIndicatorSource != 0
        && !gtk_widget_get_can_target(app().scrollIndicator);
    if (app().scrollIndicatorSource != 0) {
        g_source_remove(app().scrollIndicatorSource);
        app().scrollIndicatorSource = 0;
    }
    activePane()->lastScrollIndicatorTick = Ubiquitty::PAL::monotonicTicks().count - 100;
    onScrollIndicatorDue(nullptr);
    const bool didSleep = !gtk_widget_get_visible(app().scrollIndicator) && app().scrollIndicatorSource == 0;
    g_object_unref(app().scrollIndicator);
    app().scrollIndicator = savedOverlay;
    const bool didPass = isGeometryCorrect && doesFade && isHidden && didWake && didSleep;
    g_print("smoke-scroll-indicator: geometry=%d fade=%d wake=%d sleep=%d -- %s\n", isGeometryCorrect, doesFade, didWake, didSleep,
        didPass ? "PASS" : "FAIL");
    return didPass;
}
