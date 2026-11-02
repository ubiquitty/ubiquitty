// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/PointerLock.cpp — see PointerLock.h.

#include "Platform/Linux/PointerLock.h"

#include <cstdlib>

#include <gtk/gtk.h>

#include <graphene.h>

#include <cstring>

#ifdef UBIQUITTY_LINUX_HAS_X11
#include <gdk/x11/gdkx.h>

#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#endif

#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
#include <gdk/wayland/gdkwayland.h>

#include <wayland-client.h>

#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"
#endif

namespace Ubiquitty::Linux {

namespace {

#ifdef UBIQUITTY_LINUX_HAS_X11
// The Display and window id every X11 path below needs. GTK deprecates these
// X11 backend accessors and offers no replacement for them, and XFixes and
// XWarpPointer take nothing else, so the deprecation is acknowledged once, here,
// rather than at each call.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
Display* x11DisplayOf(GdkDisplay* display)
{
    return display ? gdk_x11_display_get_xdisplay(display) : nullptr;
}

Window x11WindowOf(GdkSurface* surface)
{
    return gdk_x11_surface_get_xid(surface);
}
#pragma GCC diagnostic pop
#endif

#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
// Binds the two globals this lock needs and ignores every other interface
// the registry advertises; `data` is the `PointerLockWaylandGlobals` the
// round trip in `bindPointerLockWaylandGlobals` is filling in.
void onPointerLockGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
    auto* globals = static_cast<PointerLockWaylandGlobals*>(data);
    if (std::strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0) {
        globals->pointerConstraints = wl_registry_bind(registry, name, &zwp_pointer_constraints_v1_interface, 1);
    } else if (std::strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0) {
        globals->relativePointerManager = wl_registry_bind(registry, name, &zwp_relative_pointer_manager_v1_interface, 1);
    }
}

void onPointerLockGlobalRemove(void*, wl_registry*, uint32_t) { }

constexpr wl_registry_listener pointerLockRegistryListener = {
    onPointerLockGlobal,
    onPointerLockGlobalRemove,
};

// The one relative-pointer-unstable-v1 event: a raw hardware sample, in
// surface-local logical pixels. `data` is the engaged `PointerLockOS`.
void onPointerLockRelativeMotion(void* data, zwp_relative_pointer_v1*, uint32_t, uint32_t, wl_fixed_t deltaX, wl_fixed_t deltaY, wl_fixed_t, wl_fixed_t)
{
    auto* os = static_cast<PointerLockOS*>(data);
    os->wlPendingDeltaX += wl_fixed_to_double(deltaX) * os->wlScale;
    os->wlPendingDeltaY += wl_fixed_to_double(deltaY) * os->wlScale;
    if (os->wake)
        os->wake();
}

constexpr zwp_relative_pointer_v1_listener pointerLockRelativeMotionListener = {
    onPointerLockRelativeMotion,
};
#endif

} // namespace

PointerLockWaylandGlobals bindPointerLockWaylandGlobals(void* gdkDisplay)
{
    PointerLockWaylandGlobals globals;
#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
    auto* display = static_cast<GdkDisplay*>(gdkDisplay);
    if (!display || !GDK_IS_WAYLAND_DISPLAY(display))
        return globals;
    wl_display* wlDisplay = gdk_wayland_display_get_wl_display(display);
    if (!wlDisplay)
        return globals;
    wl_registry* registry = wl_display_get_registry(wlDisplay);
    if (!registry)
        return globals;
    wl_registry_add_listener(registry, &pointerLockRegistryListener, &globals);
    // One round trip against the DEFAULT queue: the same queue GDK's own
    // Wayland backend dispatches from the GLib main loop, so this blocks only
    // long enough for the compositor to answer and never competes with GDK
    // for a private queue that does not exist here.
    wl_display_roundtrip(wlDisplay);
    wl_registry_destroy(registry);
#else
    (void)gdkDisplay;
#endif
    return globals;
}

PointerLockBackendKind pointerLockBackendFor(void* gdkDisplay, const PointerLockWaylandGlobals& wayland)
{
    auto* display = static_cast<GdkDisplay*>(gdkDisplay);
#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
    if (display && GDK_IS_WAYLAND_DISPLAY(display) && wayland.pointerConstraints && wayland.relativePointerManager)
        return PointerLockBackendKind::Wayland;
#endif
#ifdef UBIQUITTY_LINUX_HAS_X11
    if (display && GDK_IS_X11_DISPLAY(display))
        return PointerLockBackendKind::X11;
#endif
    (void)display;
    (void)wayland;
    return PointerLockBackendKind::Neither;
}

PointerLockDelta pointerLockX11Recentre(void* widgetPtr, PointerLockOS& os, double widgetX, double widgetY)
{
    PointerLockDelta delta;
#ifdef UBIQUITTY_LINUX_HAS_X11
    if (os.backend != PointerLockBackendKind::X11)
        return delta;
    auto* widget = static_cast<GtkWidget*>(widgetPtr);
    GdkDisplay* display = gtk_widget_get_display(widget);
    Display* xdisplay = display ? x11DisplayOf(display) : nullptr;
    GtkNative* native = gtk_widget_get_native(widget);
    GdkSurface* surface = native ? gtk_native_get_surface(native) : nullptr;
    if (!xdisplay || !surface)
        return delta;
    const Window xid = x11WindowOf(surface);
    const int scale = gtk_widget_get_scale_factor(widget);
    const double widgetWidth = static_cast<double>(gtk_widget_get_width(widget));
    const double widgetHeight = static_cast<double>(gtk_widget_get_height(widget));

    // The engaging call passes the sentinel (-1, -1): there is no prior
    // recentre to diff against, only the first one to plant. Every later
    // call is a real motion event, always in the same widget-local space the
    // recentre target below is expressed in, so the raw subtraction is the
    // delta whether or not either point sits at the widget's true centre.
    const bool isFirstRecentre = widgetX < 0.0 && widgetY < 0.0;
    if (!isFirstRecentre) {
        delta.x = (widgetX - widgetWidth / 2.0) * scale;
        delta.y = (widgetY - widgetHeight / 2.0) * scale;
    }

    const graphene_point_t widgetCentre = GRAPHENE_POINT_INIT(static_cast<float>(widgetWidth / 2.0), static_cast<float>(widgetHeight / 2.0));
    graphene_point_t rootCentre = GRAPHENE_POINT_INIT(0.0f, 0.0f);
    // A false return means no shared ancestor transform exists, which cannot
    // happen for a widget and its own root; rootCentre is left at its
    // GRAPHENE_POINT_INIT zero in that unreachable case, a safe (if wrong)
    // recentre target rather than an uninitialised one.
    const gboolean computedRootCentre = gtk_widget_compute_point(widget, GTK_WIDGET(gtk_widget_get_root(widget)), &widgetCentre, &rootCentre);
    (void)computedRootCentre;
    double nativeOffsetX = 0.0, nativeOffsetY = 0.0;
    gtk_native_get_surface_transform(native, &nativeOffsetX, &nativeOffsetY);
    os.x11CentreSurfaceX = static_cast<int>(static_cast<double>(rootCentre.x) + nativeOffsetX + 0.5);
    os.x11CentreSurfaceY = static_cast<int>(static_cast<double>(rootCentre.y) + nativeOffsetY + 0.5);
    XWarpPointer(xdisplay, None, xid, 0, 0, 0, 0, os.x11CentreSurfaceX, os.x11CentreSurfaceY);
#else
    (void)widgetPtr;
    (void)os;
    (void)widgetX;
    (void)widgetY;
#endif
    return delta;
}

// Says why an engage was refused, when the trace switch is on: the grab has
// several ways to fail on a display that looks capable, and a silent false
// leaves the reader guessing at which.
static void tracePointerLockRefusal(const char* why)
{
    if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr)
        g_printerr("pointer-lock: engage refused: %s\n", why);
}

bool pointerLockEngage(void* widgetPtr, const PointerLockWaylandGlobals& wayland, void (*wake)(), PointerLockOS& os)
{
    auto* widget = static_cast<GtkWidget*>(widgetPtr);
    if (!widget) {
        tracePointerLockRefusal("no widget");
        return false;
    }
    GdkDisplay* display = gtk_widget_get_display(widget);
    const PointerLockBackendKind backend = pointerLockBackendFor(display, wayland);
    if (backend == PointerLockBackendKind::Neither) {
        tracePointerLockRefusal(wayland.pointerConstraints == nullptr ? "no backend: the Wayland constraints global is unbound and the display is not X11" : "no backend for this display");
        return false;
    }

    // Named-cursor hide first, on both backends: X11's XFixesHideCursor is
    // process-wide and per-window at once, but the widget's own idea of its
    // cursor must agree, or a later unrelated set_cursor call (a hover
    // affordance racing the grab) would show it again underneath the hide.
    gtk_widget_set_cursor_from_name(widget, "none");

#ifdef UBIQUITTY_LINUX_HAS_X11
    if (backend == PointerLockBackendKind::X11) {
        Display* xdisplay = x11DisplayOf(display);
        GtkNative* native = gtk_widget_get_native(widget);
        GdkSurface* surface = native ? gtk_native_get_surface(native) : nullptr;
        if (!xdisplay || !surface) {
            tracePointerLockRefusal("x11: no display or unrealized surface");
            return false;
        }
        const Window xid = x11WindowOf(surface);
        Window rootReturn = 0, childReturn = 0;
        int rootX = 0, rootY = 0, winX = 0, winY = 0;
        unsigned int maskReturn = 0;
        XQueryPointer(xdisplay, xid, &rootReturn, &childReturn, &rootX, &rootY, &winX, &winY, &maskReturn);
        os.x11RestoreRootX = rootX;
        os.x11RestoreRootY = rootY;
        XFixesHideCursor(xdisplay, xid);
        os.backend = PointerLockBackendKind::X11;
        (void)pointerLockX11Recentre(widget, os, -1.0, -1.0); // plants the first recentre point; no delta to read yet
        (void)wake; // X11 delivers deltas through ordinary motion events; nothing to wake
        return true;
    }
#endif

#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
    if (backend == PointerLockBackendKind::Wayland) {
        GdkSeat* seat = gdk_display_get_default_seat(display);
        GdkDevice* pointerDevice = seat ? gdk_seat_get_pointer(seat) : nullptr;
        wl_pointer* wlPointer = pointerDevice ? gdk_wayland_device_get_wl_pointer(pointerDevice) : nullptr;
        GtkNative* native = gtk_widget_get_native(widget);
        GdkSurface* surface = native ? gtk_native_get_surface(native) : nullptr;
        wl_surface* wlSurface = surface ? gdk_wayland_surface_get_wl_surface(surface) : nullptr;
        if (!wlPointer || !wlSurface) {
            tracePointerLockRefusal(!wlPointer ? "wayland: the seat has no pointer" : "wayland: unrealized surface");
            return false;
        }
        auto* constraints = static_cast<zwp_pointer_constraints_v1*>(wayland.pointerConstraints);
        auto* relativeManager = static_cast<zwp_relative_pointer_manager_v1*>(wayland.relativePointerManager);
        zwp_locked_pointer_v1* locked = zwp_pointer_constraints_v1_lock_pointer(
            constraints, wlSurface, wlPointer, nullptr, ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
        if (!locked) {
            tracePointerLockRefusal("wayland: lock_pointer returned no object");
            return false;
        }
        zwp_relative_pointer_v1* relative = zwp_relative_pointer_manager_v1_get_relative_pointer(relativeManager, wlPointer);
        if (!relative) {
            zwp_locked_pointer_v1_destroy(locked);
            return false;
        }
        os.wlPendingDeltaX = 0.0;
        os.wlPendingDeltaY = 0.0;
        os.wlScale = gtk_widget_get_scale_factor(widget);
        os.wake = wake;
        zwp_relative_pointer_v1_add_listener(relative, &pointerLockRelativeMotionListener, &os);
        os.wlLockedPointer = locked;
        os.wlRelativePointer = relative;
        os.backend = PointerLockBackendKind::Wayland;
        return true;
    }
#endif
    (void)wake;
    return false;
}

void pointerLockRelease(void* widgetPtr, PointerLockOS& os)
{
    auto* widget = static_cast<GtkWidget*>(widgetPtr);
#ifdef UBIQUITTY_LINUX_HAS_X11
    if (os.backend == PointerLockBackendKind::X11 && widget) {
        GdkDisplay* display = gtk_widget_get_display(widget);
        Display* xdisplay = display ? x11DisplayOf(display) : nullptr;
        GtkNative* native = gtk_widget_get_native(widget);
        GdkSurface* surface = native ? gtk_native_get_surface(native) : nullptr;
        if (xdisplay && surface) {
            const Window xid = x11WindowOf(surface);
            XFixesShowCursor(xdisplay, xid);
            // The pointer never stopped tracking the screen during the grab
            // (X11 has no dissociate), so every recentre was a real, visible
            // jump; this undoes the last one and puts it back exactly where
            // the program that asked for the lock found it.
            XWarpPointer(xdisplay, None, DefaultRootWindow(xdisplay), 0, 0, 0, 0, os.x11RestoreRootX, os.x11RestoreRootY);
            XFlush(xdisplay);
        }
    }
#endif
#ifdef UBIQUITTY_LINUX_HAS_WAYLAND
    if (os.backend == PointerLockBackendKind::Wayland) {
        if (os.wlRelativePointer)
            zwp_relative_pointer_v1_destroy(static_cast<zwp_relative_pointer_v1*>(os.wlRelativePointer));
        if (os.wlLockedPointer)
            zwp_locked_pointer_v1_destroy(static_cast<zwp_locked_pointer_v1*>(os.wlLockedPointer));
    }
#endif
    os.wlLockedPointer = nullptr;
    os.wlRelativePointer = nullptr;
    os.wlPendingDeltaX = 0.0;
    os.wlPendingDeltaY = 0.0;
    os.wlScale = 1.0;
    os.wake = nullptr;
    os.backend = PointerLockBackendKind::Neither;
    if (widget)
        gtk_widget_set_cursor(widget, nullptr); // back to the inherited (shown) cursor
}

PointerLockDelta takeWaylandPointerLockDelta(PointerLockOS& os)
{
    PointerLockDelta delta;
    if (os.backend != PointerLockBackendKind::Wayland)
        return delta;
    delta.x = os.wlPendingDeltaX;
    delta.y = os.wlPendingDeltaY;
    os.wlPendingDeltaX = 0.0;
    os.wlPendingDeltaY = 0.0;
    return delta;
}

} // namespace Ubiquitty::Linux
