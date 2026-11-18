// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-drop — headless check of the drop assembly (the GtkDropTarget wiring is
// build-verified; the live drag needs a display): spaces, shell metacharacters,
// and parentheses are backslash-escaped, multibyte UTF-8 passes through, paths
// are space-joined with a trailing space.
/// Checks shell escaping and joining of dropped file paths.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeDrop()
{
    const std::vector<std::string> paths = { "/home/u/file.txt", "/home/u/my docs/a (1).txt", "/tmp/x;rm -rf y", "/p/ünï.md" };
    const std::string outputBuffer = assembleDroppedPaths(paths);
    const std::string expected = "/home/u/file.txt /home/u/my\\ docs/a\\ \\(1\\).txt /tmp/x\\;rm\\ -rf\\ y /p/ünï.md ";
    const bool didPass = outputBuffer == expected;
    g_print("smoke-drop: %s\n  got:      %s\n", didPass ? "PASS" : "FAIL", outputBuffer.c_str());
    if (!didPass)
        g_print("  expected: %s\n", expected.c_str());
    return didPass ? 0 : 1;
}
