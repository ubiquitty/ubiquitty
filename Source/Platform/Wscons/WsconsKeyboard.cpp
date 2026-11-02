// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Wscons/WsconsKeyboard.h"

#include "Core/Keys/KeyTranslation.h"
#include "Core/Keys/Keymap.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <unistd.h>

#include <dev/wscons/wsconsio.h>

namespace Ubiquitty {
namespace Wscons {

bool Keyboard::init(const char* devicePath)
{
    if (!devicePath || devicePath[0] == '\0')
        return false;
    m_fileDescriptor = ::open(devicePath, O_RDONLY);
    if (m_fileDescriptor < 0)
        return false;

    // Requested for completeness; event.value arrives as a raw USB HID usage code
    // regardless (see the header note), so decoding doesn't depend on it.
    int mode = WSKBD_TRANSLATED;
    (void)::ioctl(m_fileDescriptor, WSKBDIO_SETMODE, &mode);
    return true;
}

void Keyboard::shutdown()
{
    if (m_fileDescriptor >= 0) {
        ::close(m_fileDescriptor);
        m_fileDescriptor = -1;
    }
}

// USB HID Usage Page 0x07 usage codes -> the portable VirtualKey identity.
// Mirrors virtualKeyFor() in the Linux frontend — same shared table on the far
// side.
static Keys::VirtualKey hidUsageToVirtualKey(unsigned usage)
{
    using Keys::VirtualKey;
    switch (usage) {
    case 0x28:
        return VirtualKey::Return;
    case 0x29:
        return VirtualKey::Escape;
    case 0x2A:
        return VirtualKey::Backspace;
    case 0x2B:
        return VirtualKey::Tab;
    case 0x49:
        return VirtualKey::Insert;
    case 0x4A:
        return VirtualKey::Home;
    case 0x4B:
        return VirtualKey::PageUp;
    case 0x4C:
        return VirtualKey::ForwardDelete;
    case 0x4D:
        return VirtualKey::End;
    case 0x4E:
        return VirtualKey::PageDown;
    case 0x4F:
        return VirtualKey::RightArrow;
    case 0x50:
        return VirtualKey::LeftArrow;
    case 0x51:
        return VirtualKey::DownArrow;
    case 0x52:
        return VirtualKey::UpArrow;
    case 0x3A:
        return VirtualKey::F1;
    case 0x3B:
        return VirtualKey::F2;
    case 0x3C:
        return VirtualKey::F3;
    case 0x3D:
        return VirtualKey::F4;
    case 0x3E:
        return VirtualKey::F5;
    case 0x3F:
        return VirtualKey::F6;
    case 0x40:
        return VirtualKey::F7;
    case 0x41:
        return VirtualKey::F8;
    case 0x42:
        return VirtualKey::F9;
    case 0x43:
        return VirtualKey::F10;
    case 0x44:
        return VirtualKey::F11;
    case 0x45:
        return VirtualKey::F12;
    default:
        return VirtualKey::None;
    }
}

// Printable-key usage codes -> (unshifted, shifted) US QWERTY character.
// 0 means "not a printable key this table covers" (includes 0x00 sentinel —
// no printable key maps to NUL).
struct PrintableKey {
    unsigned usage;
    char plain;
    char shifted;
};
static constexpr PrintableKey printableKeys[] = {
    { 0x04, 'a', 'A' },
    { 0x05, 'b', 'B' },
    { 0x06, 'c', 'C' },
    { 0x07, 'd', 'D' },
    { 0x08, 'e', 'E' },
    { 0x09, 'f', 'F' },
    { 0x0A, 'g', 'G' },
    { 0x0B, 'h', 'H' },
    { 0x0C, 'i', 'I' },
    { 0x0D, 'j', 'J' },
    { 0x0E, 'k', 'K' },
    { 0x0F, 'l', 'L' },
    { 0x10, 'm', 'M' },
    { 0x11, 'n', 'N' },
    { 0x12, 'o', 'O' },
    { 0x13, 'p', 'P' },
    { 0x14, 'q', 'Q' },
    { 0x15, 'r', 'R' },
    { 0x16, 's', 'S' },
    { 0x17, 't', 'T' },
    { 0x18, 'u', 'U' },
    { 0x19, 'v', 'V' },
    { 0x1A, 'w', 'W' },
    { 0x1B, 'x', 'X' },
    { 0x1C, 'y', 'Y' },
    { 0x1D, 'z', 'Z' },
    { 0x1E, '1', '!' },
    { 0x1F, '2', '@' },
    { 0x20, '3', '#' },
    { 0x21, '4', '$' },
    { 0x22, '5', '%' },
    { 0x23, '6', '^' },
    { 0x24, '7', '&' },
    { 0x25, '8', '*' },
    { 0x26, '9', '(' },
    { 0x27, '0', ')' },
    { 0x2C, ' ', ' ' },
    { 0x2D, '-', '_' },
    { 0x2E, '=', '+' },
    { 0x2F, '[', '{' },
    { 0x30, ']', '}' },
    { 0x31, '\\', '|' },
    { 0x33, ';', ':' },
    { 0x34, '\'', '"' },
    { 0x35, '`', '~' },
    { 0x36, ',', '<' },
    { 0x37, '.', '>' },
    { 0x38, '/', '?' },
};

// Which of a printable key's two US-QWERTY characters to produce.
enum class ShiftState : std::uint8_t {
    Unshifted,
    Shifted,
};

static bool hidUsageToCharacter(unsigned usage, ShiftState shiftState, char& outCharacter)
{
    for (const auto& key : printableKeys) {
        if (key.usage == usage) {
            outCharacter = shiftState == ShiftState::Shifted ? key.shifted : key.plain;
            return true;
        }
    }
    return false;
}

bool Keyboard::readEvent(Runtime::KeyPress& out)
{
    struct wscons_event event;
    const ssize_t n = ::read(m_fileDescriptor, &event, sizeof(event));
    if (n != static_cast<ssize_t>(sizeof(event)))
        return false;

    const bool isPress = event.type == WSCONS_EVENT_KEY_DOWN;
    const bool isRelease = event.type == WSCONS_EVENT_KEY_UP;
    if (!isPress && !isRelease)
        return false; // not a key event (mux/mouse-shared device, etc.)

    const auto usage = static_cast<unsigned>(event.value);

    if (::getenv("UBIQUITTY_WSCONS_DEBUG"))
        std::fprintf(stderr, "[wskbd] type=%d usage=0x%x press=%d\n", event.type, usage, isPress ? 1 : 0);

    // Modifier make/break: update held state, emit nothing (the poll loop keeps
    // going — see the header contract).
    switch (usage) {
    case 0xE0: // LeftControl
    case 0xE4: // RightControl
        m_isControlHeld = isPress;
        return false;
    case 0xE1: // LeftShift
    case 0xE5: // RightShift
        m_isShiftHeld = isPress;
        return false;
    case 0xE2: // LeftAlternate
    case 0xE6: // RightAlternate
        m_isAlternateHeld = isPress;
        return false;
    default:
        break;
    }

    out = {};
    out.eventType = isPress ? Keys::KeyEventType::Press : Keys::KeyEventType::Release;

    std::uint32_t modifiers = 0;
    if (m_isControlHeld)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierCtrl;
    if (m_isAlternateHeld)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierAlternate;

    // Shift is a modifier bit on every key, printable ones included. A backend
    // that folds it into the character and also withholds the bit leaves the
    // terminal unable to tell Shift+a from a, so modifyOtherKeys and the Kitty
    // shifted alternate both go missing.
    if (m_isShiftHeld)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierShift;

    out.virtualKey = hidUsageToVirtualKey(usage);
    out.modifiers = modifiers;
    out.wasModified = modifiers != 0;

    // A functional key has no character, and Core reads its identity off
    // `virtualKey`. A printable one carries both of its US-QWERTY faces: which
    // reports and which rides as the shifted alternate is Core's ladder.
    bool isMapped = Keys::functionalKeyCodePoint(out.virtualKey) != 0;
    char unshifted = 0;
    if (hidUsageToCharacter(usage, ShiftState::Unshifted, unshifted)) {
        isMapped = true;
        out.unshiftedCodePoint = static_cast<std::uint32_t>(static_cast<unsigned char>(unshifted));
        char shifted = 0;
        if (hidUsageToCharacter(usage, ShiftState::Shifted, shifted))
            out.shiftedCodePoint = static_cast<std::uint32_t>(static_cast<unsigned char>(shifted));
        out.textLength = 1;
        out.text[0] = m_isShiftHeld && out.shiftedCodePoint != 0 ? out.shiftedCodePoint : out.unshiftedCodePoint;
    }

    if (::getenv("UBIQUITTY_WSCONS_DEBUG")) {
        std::fprintf(stderr, "[wskbd] usage=0x%x -> key=%u unshifted=0x%x shifted=0x%x modifiers=0x%x mapped=%d\n",
            usage, static_cast<unsigned>(out.virtualKey), out.unshiftedCodePoint, out.shiftedCodePoint, out.modifiers, isMapped ? 1 : 0);
    }
    return isMapped;
}

} // namespace Wscons
} // namespace Ubiquitty
