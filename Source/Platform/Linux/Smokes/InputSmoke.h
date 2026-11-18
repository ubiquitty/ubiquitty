// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Launch a shell and type "ls\n" through the real key path, then dump the
// screen — exercises the key seam + sendInputBytes end to end.
/// Checks shell input through the real key path and dumps the resulting screen.
///
/// - Parameter path: The path receiving the terminal screen dump.
/// - Returns: Zero on success, or a nonzero failure status.
int smokeInput(const char* path)
{
    setupFonts();
    if (!launchShell()) {
        g_printerr("smoke-input: failed to launch shell\n");
        return 1;
    }
    const int fileDescriptor = activePane()->session->fileDescriptor();
    drainBriefly(fileDescriptor, 6); // let the prompt arrive (modes cached)
    sendKey(GDK_KEY_l, 0, static_cast<GdkModifierType>(0));
    sendKey(GDK_KEY_s, 0, static_cast<GdkModifierType>(0));
    drainBriefly(fileDescriptor, 3); // echo of "ls"
    sendKey(GDK_KEY_Return, 0, static_cast<GdkModifierType>(0));
    drainBriefly(fileDescriptor, 12); // run + output
    return writePNG(path);
}
