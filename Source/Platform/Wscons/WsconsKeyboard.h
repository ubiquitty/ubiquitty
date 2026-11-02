// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Reads /dev/wskbd events and reports them as the portable Runtime::KeyPress
// every frontend reports, via the same shared Keys::VirtualKey table. This file
// owns the only wscons-specific piece: the key-event -> VirtualKey map.
// Which bytes a key produces is the terminal's; see Core/Runtime/KeyEncode.h.
//
// On the one configuration tried, QEMU's usb-kbd under OpenBSD 7.9 x64,
// WSKBDIO_SETMODE(WSKBD_TRANSLATED) has no effect: event.value carries the raw
// USB HID usage (usage page 0x07), and this backend maps those usages itself.
// US QWERTY only: a non-US layout, dead keys and compose all need the
// kernel's translated keymap, and WSKBD_TRANSLATED delivers nothing on this
// config — the usage codes arrive raw whether it is set or not.

#include "Core/Runtime/KeyPress.h"

#include <cstdint>

namespace Ubiquitty {
namespace Wscons {

class Keyboard {
public:
    Keyboard() = default;
    ~Keyboard() { shutdown(); }
    Keyboard(const Keyboard&) = delete;
    Keyboard& operator=(const Keyboard&) = delete;

    // Opens `devicePath`. Still requests WSKBD_TRANSLATED (harmless if ignored —
    // see the note above), but decoding does not depend on it taking effect.
    bool init(const char* devicePath);
    void shutdown();

    // The pollable fd (the caller's poll/select loop drives reads).
    int fileDescriptor() const { return m_fileDescriptor; }

    /// Reads and translates one pending `wscons_event`.
    ///
    /// A false answer is the ordinary case, not an error: a bare modifier
    /// make/break is consumed internally to fold into the next key, and an
    /// unhandled event type produces nothing, so the caller's poll loop keeps
    /// looping either way.
    ///
    /// - Parameter out: filled with the key press, repeat or release when one
    ///   was translated, and untouched otherwise.
    /// - Returns: true when `out` holds an event.
    bool readEvent(Runtime::KeyPress& out);

private:
    int m_fileDescriptor = -1;
    // Modifier hold-state: raw HID mode reports modifier keys as make/break usage
    // codes (0xE0-0xE7), not a live bitmask, so track it across calls to fold into
    // the next non-modifier key's modifiers / shifted-character lookup.
    bool m_isShiftHeld = false;
    bool m_isControlHeld = false;
    bool m_isAlternateHeld = false;
};

} // namespace Wscons
} // namespace Ubiquitty
