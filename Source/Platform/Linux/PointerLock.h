// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The OS-level half of relative pointer lock (DECSET 7403) on GTK4/Linux: hiding
// the cursor and turning raw hardware movement into a delta, by whichever of two
// unrelated mechanisms the live display offers. Neither backend's headers are
// required to build the other — a container or a developer machine with only one
// windowing library installed still gets a working lock on it.
//
// X11 has no relative-motion API GTK4 exposes, so the accepted technique is a
// warp back to a fixed point after every motion event, with the delta read from
// where the pointer landed before the warp. The pointer keeps tracking the
// screen throughout (unlike AppKit's dissociate), so every warp is a real jump a
// caller must undo on release.
//
// Wayland forbids that: a compositor may reject or ignore a client-initiated
// warp, so `zwp_pointer_constraints_v1` (freeze the surface-local position) and
// `zwp_relative_pointer_v1` (report the raw deltas the freeze would otherwise
// throw away) exist for exactly this case. No warp, no restore — the compositor
// remembers where the pointer was.
//
// This header stays free of both `<gtk/gtk.h>` and the generated Wayland
// protocol headers so it can be included from a translation unit that does not
// want either; every handle crossing the boundary is an opaque pointer the
// caller already owns as its real type, cast back to it only inside the .cpp.

#pragma once

#include <cstdint>

namespace Ubiquitty::Linux {

/// Which mechanism a lock will use once engaged.
///
/// The X11 headers this module includes (only inside the .cpp) `#define
/// None` as a bare integer macro, which would silently rewrite an enumerator
/// of that name wherever it is USED after that include — not just declared —
/// so this enum spells the empty case `Neither` rather than the name every
/// other lock-verdict enum in this codebase uses for it.
enum class PointerLockBackendKind : std::uint8_t {
    /// Neither backend can drive a lock here — a display that is neither X11
    /// nor Wayland, or one whose required extension/protocol is absent.
    Neither,
    /// GDK's display is X11; the lock recentres the pointer on every motion.
    X11,
    /// GDK's display is Wayland and the compositor advertises both globals
    /// this lock needs.
    Wayland,
};

/// A relative-motion sample, in device pixels, however it was produced.
struct PointerLockDelta {
    double x = 0.0;
    double y = 0.0;
};

/// The two Wayland protocol globals a lock needs, bound once from a display's
/// registry. Each is the real `zwp_pointer_constraints_v1*` /
/// `zwp_relative_pointer_manager_v1*`, carried as `void*` so this header does
/// not need the generated protocol headers; null when the build has no
/// Wayland support or the compositor does not advertise one.
struct PointerLockWaylandGlobals {
    void* pointerConstraints = nullptr;
    void* relativePointerManager = nullptr;
};

/// The state one grab holds, whether currently engaged or released. There is
/// at most one live grab per process — pointer lock follows the single focused
/// surface a GTK application shares one OS cursor across — so a caller keeps
/// exactly one of these rather than one per pane.
struct PointerLockOS {
    /// Which mechanism is driving the current grab; `Neither` when nothing is
    /// engaged.
    PointerLockBackendKind backend = PointerLockBackendKind::Neither;
    /// X11: the pointer's ROOT-window position before the grab, so release
    /// can put it back exactly where the program found it.
    int x11RestoreRootX = 0;
    int x11RestoreRootY = 0;
    /// X11: the last point the pointer was recentred to, in the toplevel
    /// surface's own coordinates — what an arriving motion event's position
    /// is measured against to produce the next delta.
    int x11CentreSurfaceX = 0;
    int x11CentreSurfaceY = 0;
    /// Wayland: the live `zwp_locked_pointer_v1*` / `zwp_relative_pointer_v1*`,
    /// null when not engaged on this backend.
    void* wlLockedPointer = nullptr;
    void* wlRelativePointer = nullptr;
    /// Wayland: the delta the relative-pointer listener has deposited since
    /// the last `takeWaylandPointerLockDelta`, in device pixels.
    double wlPendingDeltaX = 0.0;
    double wlPendingDeltaY = 0.0;
    /// Wayland: the widget's scale factor at engage, applied to the
    /// protocol's logical-pixel deltas so both backends report device
    /// pixels — the listener callback has no widget to read it from live.
    double wlScale = 1.0;
    /// Called from the Wayland listener (which runs during GDK's own event
    /// dispatch, not from a caller-visible poll) the moment a delta lands, so
    /// the caller can book a frame to drain and report it. Null is a valid
    /// "nobody asked to be woken" — the caller then only sees a deposited
    /// delta on its next unrelated poll.
    void (*wake)() = nullptr;
};

/// Binds the pointer-constraints and relative-pointer globals from a Wayland
/// display's registry.
///
/// A synchronous round trip against the display's default event queue —
/// paid once, the first time a surface on this display asks to lock. A
/// no-Wayland build, or a non-Wayland `gdkDisplay`, returns both null.
///
/// - Parameter gdkDisplay: The `GdkDisplay*` to bind against.
/// - Returns: The bound globals, or both null when the compositor does not
///   advertise them.
[[nodiscard]] PointerLockWaylandGlobals bindPointerLockWaylandGlobals(void* gdkDisplay);

/// Which backend a display can drive a lock through.
///
/// - Parameters:
///   - gdkDisplay: The `GdkDisplay*` the surface asking to lock is on.
///   - wayland: The globals bound for it, from `bindPointerLockWaylandGlobals`.
/// - Returns: The backend `pointerLockEngage` would use, or `Neither` if
///   neither applies.
[[nodiscard]] PointerLockBackendKind pointerLockBackendFor(void* gdkDisplay, const PointerLockWaylandGlobals& wayland);

/// Engages the OS grab on `widget`'s surface: hides the cursor and starts
/// capturing relative motion through whichever backend the display supports.
///
/// X11: performs the first recentre and remembers the restore point; every
/// later motion event's recentre is `pointerLockX11Recentre`, called from the
/// caller's ordinary motion handler while the grab stays engaged.
/// Wayland: locks the surface-local position and starts the relative-pointer
/// listener, which deposits deltas `takeWaylandPointerLockDelta` polls.
///
/// - Parameters:
///   - widget: The focused pane's `GtkWidget*` picture, whose surface is
///     grabbed.
///   - wayland: The globals bound for this widget's display.
///   - wake: Called from the Wayland listener when a delta lands; may be
///     null.
///   - os: Filled in with the engaged state.
/// - Returns: Whether a backend engaged the grab; false leaves `os`
///   untouched and the caller's cursor still showing.
[[nodiscard]] bool pointerLockEngage(void* widget, const PointerLockWaylandGlobals& wayland, void (*wake)(), PointerLockOS& os);

/// Releases whichever grab `os` holds: destroys the Wayland listener/lock
/// objects, or restores the X11 pointer to where the grab found it, and
/// unhides the cursor either way. A release with nothing engaged
/// (`os.backend == Neither`) is a no-op.
///
/// - Parameters:
///   - widget: The `GtkWidget*` the grab was taken on, to unhide its cursor.
///   - os: The state to release; left at `PointerLockBackendKind::Neither`.
void pointerLockRelease(void* widget, PointerLockOS& os);

/// Recentres the X11 pointer to `widget`'s middle and reports the delta from
/// the point it was recentred to last.
///
/// Call from the ordinary GTK motion handler for every motion event while
/// `os.backend == X11`. A Wayland grab's surface receives no ordinary motion
/// events while locked — the protocol withholds them by design — so this is
/// never the source of a Wayland delta; call it unconditionally and it
/// returns a zero delta when `os.backend != X11`.
///
/// - Parameters:
///   - widget: The `GtkWidget*` the grab is on.
///   - os: The engaged lock state; its recentre point is updated.
///   - widgetX: The motion event's widget-local X, in logical pixels.
///   - widgetY: The motion event's widget-local Y, in logical pixels.
/// - Returns: The delta since the last recentre, in device pixels; zero when
///   this event was itself the artefact of the previous recentre.
[[nodiscard]] PointerLockDelta pointerLockX11Recentre(void* widget, PointerLockOS& os, double widgetX, double widgetY);

/// Takes and clears the delta a Wayland lock's relative-pointer listener has
/// deposited since the last call.
///
/// - Parameter os: The engaged lock state.
/// - Returns: The pending delta, in device pixels; zero when `os.backend !=
///   Wayland` or nothing arrived since the last call.
[[nodiscard]] PointerLockDelta takeWaylandPointerLockDelta(PointerLockOS& os);

} // namespace Ubiquitty::Linux
