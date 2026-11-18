// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-keypad — a keypad key keeps its own identity under Kitty and gives it
// up under the legacy encoder, which is the distinction the keypad code points
// exist to carry.
//
// The failure this exists for is silent: reading the functional table alone
// answers 0 for every keypad key, the caller falls through to the typed
// character, and KP_5 reports as the digit 5 — indistinguishable on the wire
// from the key above the T. Every byte is well-formed and every count is right.
//
// The legacy arm is the other half and is not a formality: the legacy encoder
// has no byte form for a bare keypad code point, so reporting one there would
// leave an ordinary keypad press emitting nothing at all.
/// Checks keypad identity under Kitty encoding and its legacy fallback.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeKeypad()
{
    using Ubiquitty::Keys::KeyEncoder;
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-keypad: FAIL: {}", what);
            ok = false;
        }
    };

    Ubiquitty::Runtime::ModeSnapshot positionModes;
    positionModes.shouldReportKeyPositions = true;
    Ubiquitty::Runtime::KeyPress positionPress;
    positionPress.virtualKey = physicalPrintableKey(38);
    positionPress.unshiftedCodePoint = 0x0444;
    positionPress.modifiers = 2u << Ubiquitty::Keys::positionModifierShift;
    std::array<char, 16> positionBytes {};
    const int positionLength = Ubiquitty::Runtime::encodeKey(positionModes, positionPress, positionBytes, nullptr).length;
    check(std::string_view(positionBytes.data(), positionLength) == "\033_:C0102\033\\", "hardware A reports C01 with right Shift, independent of its layout");
    check(physicalPrintableKey(65) == Ubiquitty::Keys::VirtualKey::Space, "hardware space retains its position");
    check(physicalPrintableKey(999) == Ubiquitty::Keys::VirtualKey::None, "an unknown hardware position has no identity");

    const MappedKey underKitty = mapKey(GDK_KEY_KP_5, KeyEncoder::Kitty);
    const MappedKey underLegacy = mapKey(GDK_KEY_KP_5, KeyEncoder::Legacy);

    check(underKitty.code == static_cast<std::uint32_t>(Ubiquitty::Keys::Keymap::keymapKeyKeypad5),
        "Kitty reports the keypad code point");
    check(underKitty.functional, "and reports it as a functional key, not a typed character");
    check(underLegacy.code == static_cast<std::uint32_t>('5'), "legacy keeps the typed character");
    check(!underLegacy.functional, "and reports it as typed");

    // The digit above the T is unaffected by either encoder: it has no keypad
    // identity to gain, and a change there would mean the keypad lookup was
    // answering for keys that are not keypad keys.
    for (KeyEncoder encoder : { KeyEncoder::Legacy, KeyEncoder::Kitty }) {
        const MappedKey row = mapKey(GDK_KEY_5, encoder);
        check(row.code == static_cast<std::uint32_t>('5') && !row.functional, "the row digit types as itself");
    }

    // A functional key answers the same under both, since its table is not the
    // one the encoder choice selects between.
    for (KeyEncoder encoder : { KeyEncoder::Legacy, KeyEncoder::Kitty }) {
        const MappedKey up = mapKey(GDK_KEY_Up, encoder);
        check(up.functional && up.code == static_cast<std::uint32_t>(Ubiquitty::Keys::Keymap::keymapKeyUp),
            "an arrow key is unchanged by the encoder choice");
    }

    // The DECPAM arm, and the reason it is separate from the two above.
    //
    // Application keypad is live only in the LEGACY encoder — Core's gate at
    // Keymap.cpp requires the Kitty flags to be empty — and legacy is exactly
    // where reportedKeyCodePoint withholds the keypad code point, because the
    // legacy byte encoder has no form for one. So the SS3 path cannot read the
    // identity from the reported key: it reads it from keypadVirtualKeyFor
    // directly, and that is why the frontend gate exists rather than Core's
    // being reachable.
    //
    // A future arrangement that moves this routing into Core has to keep this
    // byte sequence. Pinning it here is what makes such a change checkable —
    // Core's own exhaustive sweep is handed the keypad code point and so cannot
    // see the frontend deciding not to supply one.
    const std::uint32_t decpamCode = Ubiquitty::Keys::keypadKeyCodePoint(keypadVirtualKeyFor(GDK_KEY_KP_5));
    check(decpamCode == static_cast<std::uint32_t>(Ubiquitty::Keys::Keymap::keymapKeyKeypad5),
        "the DECPAM path resolves the keypad identity the legacy encoder withholds");
    std::array<char, 8> ss3 {};
    const int ss3Length = Ubiquitty::Keys::Keymap::applicationKeypadSS3(decpamCode, ss3);
    check(ss3Length == 3 && ss3[0] == '\033' && ss3[1] == 'O' && ss3[2] == 'u',
        "and it encodes as ESC O u");

    // The whole path, as production runs it: a press reported the way sendKey
    // reports one, encoded by Core with application keypad on. The identity
    // travels in `virtualKey` because the code points hold the typed character
    // here — that is the substitution the whole finding turned on, and it is
    // what the existing Core cases cannot make, since they are handed the
    // keypad code point directly.
    check(mapKey(GDK_KEY_KP_5, KeyEncoder::Legacy).code == static_cast<std::uint32_t>('5'),
        "the legacy code point is the typed character");

    Ubiquitty::Runtime::ModeSnapshot decpamModes;
    decpamModes.applicationKeypad = true;

    Ubiquitty::Runtime::KeyPress decpamPress;
    decpamPress.virtualKey = keypadVirtualKeyFor(GDK_KEY_KP_5);
    decpamPress.unshiftedCodePoint = gdk_keyval_to_unicode(GDK_KEY_KP_5);
    decpamPress.shiftedCodePoint = decpamPress.unshiftedCodePoint;
    decpamPress.text[0] = decpamPress.unshiftedCodePoint;
    decpamPress.textLength = 1;

    std::array<char, 32> encoded {};
    const int decpamLength = Ubiquitty::Runtime::encodeKey(decpamModes, decpamPress, encoded, nullptr).length;
    check(decpamLength == 3 && encoded[0] == '\033' && encoded[1] == 'O' && encoded[2] == 'u',
        "DECPAM encodes the keypad key as ESC O u");

    // Without the key, the same press is an ordinary '5' — which is what every
    // press was before the identity travelled, and what a caller supplying no
    // key still gets.
    Ubiquitty::Runtime::KeyPress withoutKey = decpamPress;
    withoutKey.virtualKey = Ubiquitty::Keys::VirtualKey::None;
    std::array<char, 32> plain {};
    const int plainLength = Ubiquitty::Runtime::encodeKey(decpamModes, withoutKey, plain, nullptr).length;
    check(plainLength == 1 && plain[0] == '5', "and without the key it is the plain character");

    // Super+KP5 is a MODIFIED press and must not take the SS3 path. The press
    // this frontend reports does not report Super — it is a desktop key, not a
    // terminal modifier — so a gate reading only the reported modifiers sees an
    // unmodified press and emits ESC O u. The two masks answer different
    // questions and only one of them can say whether a key was held.
    Ubiquitty::Runtime::KeyPress superPress = decpamPress;
    superPress.wasModified = true; // Super held; not reported in `modifiers`
    std::array<char, 32> superBytes {};
    const int superLength = Ubiquitty::Runtime::encodeKey(decpamModes, superPress, superBytes, nullptr).length;
    check(!(superLength == 3 && superBytes[0] == '\033' && superBytes[1] == 'O'),
        "a Super-modified keypad press does not take the SS3 path");

    Ubiquitty::PAL::logLine(stdout, "smoke-keypad: kitty=U+{:05X} legacy=U+{:05X} decpam=ESC O {} -- {}",
        underKitty.code, underLegacy.code, ss3Length == 3 ? ss3[2] : '?', ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
