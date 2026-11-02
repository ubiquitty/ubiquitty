// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/macOS/Diag.cpp
//
// macOS backend for the PAL diagnostics sink (see Source/PAL/PAL.h, "Logging /
// diagnostics sink"). One message reaches two destinations: stderr, which
// Scripts/run-macos.sh streams in --console mode, and the unified log, where
// Console.app files it under the process's bundle id. Both are plain C, so this
// is a C++ translation unit.
//
// The two halves are spelled separately because the message is a view and not a
// string: Core hands over a slice of the halt-journal ring, which carries no
// terminator. The stderr half writes the byte range and appends the newline the
// caller left off; the unified-log half copies the range, because os_log's
// format string is a literal and its `%s` argument is a C string.
//
// The stderr half is the same two calls the Linux and host backends make
// (Source/Platform/Linux/PAL.cpp, Source/Platform/Host/HostPAL.cpp), so a
// diagnostic reads the same way on every arm. An empty message is a no-op on
// all three.
//

#include "PAL/PAL.h"

#include <os/log.h>

#include <cstdio>
#include <string>

namespace Ubiquitty::PAL {

void diagWrite(std::string_view message)
{
    if (message.empty())
        return;
    (void)std::fwrite(message.data(), 1, message.size(), stderr);
    (void)std::fputc('\n', stderr);
    const std::string line(message);
    os_log(OS_LOG_DEFAULT, "%{public}s", line.c_str());
}

} // namespace Ubiquitty::PAL
