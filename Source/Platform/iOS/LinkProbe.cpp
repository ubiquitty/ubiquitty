// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The iOS arm's link check.
//
// libubiquitty-core-ios.a is the deliverable, and an archive is not a link: ar
// resolves nothing, so a library whose subset dropped a definition a kept
// translation unit still calls packages cleanly and fails in whatever links it
// next. This module force-loads the Core, facade, and bridge archives, so every
// object is pulled in rather than the reachable subset. Their Swift service
// owners link normally, as in the app, and the cut in CMakeLists.txt is answered
// by the linker at build time.
//
// It also pins the other half: any PAL down-function the Core still references
// is undefined here, and the list the link prints is exactly what an iOS shell
// has to supply. Today that list is empty.
//
// The body drives a terminal rather than merely naming a symbol. A probe that
// only declares would link against an archive whose parser, screen and row
// store were all absent.

#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"

extern "C" int ubiquittyIOSLinkProbe();

int ubiquittyIOSLinkProbe()
{
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 24, 80);
    Ubiquitty::processBytes(&terminal, "hello\r\n");
    return terminal.columns;
}
