// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The compose engine, driven as the key handler drives it: a sequence it
// finishes and encodes, one it refuses at the first key, and one given up
// before its end.
/// Checks completed, refused and cancelled compose-key sequences.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeCompose()
{
    using Ubiquitty::Input::ComposeResult;
    Ubiquitty::Input::ComposeEngine engine;

    // Acute then e: pending after the first key, é after the second.
    engine.begin();
    const bool isAwaitingSecondKey = engine.feed('\'') == ComposeResult::Pending;
    const bool didComposeAcuteE = engine.feed('e') == ComposeResult::Composed && engine.result() == 0x00E9u;
    std::string encoded;
    Ubiquitty::Unicode::appendUTF8(encoded, engine.result());
    const bool didEncodeAsUTF8 = encoded == "\xC3\xA9";

    // A key no sequence starts with ends the attempt at once.
    engine.begin();
    const bool didRefuseUnknownStart = engine.feed('q') == ComposeResult::Invalid && !engine.active();

    // A reset mid-sequence leaves the engine inactive, so the next key is not taken.
    engine.begin();
    (void)engine.feed('~');
    engine.reset();
    const bool didCancelCleanly = !engine.active() && engine.feed('n') == ComposeResult::Inactive;

    const bool didPass = isAwaitingSecondKey && didComposeAcuteE && didEncodeAsUTF8 && didRefuseUnknownStart && didCancelCleanly;
    g_print("smoke-compose: pending=%d composed=%d utf8=%d invalid=%d cancelled=%d -- %s\n",
        static_cast<int>(isAwaitingSecondKey), static_cast<int>(didComposeAcuteE), static_cast<int>(didEncodeAsUTF8),
        static_cast<int>(didRefuseUnknownStart), static_cast<int>(didCancelCleanly), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
