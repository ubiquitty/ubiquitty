// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once
//
// wsconsio.h — a stand-in for OpenBSD/NetBSD's <dev/wscons/wsconsio.h>, so the
// Wscons frontend can be type-checked on a host that has no wscons.
//
// The frontend it serves is the only Source/Platform tree no build arm reaches:
// UBIQUITTY_FRONTEND=Wscons refuses to configure off OpenBSD/NetBSD, and no
// other target lists a Wscons translation unit. Without this stub, calls into
// portable Core go unchecked there — a two-argument call to a one-parameter span
// signature compiles nowhere and is reported by nothing.
//
// This declares only what the frontend names, with the field types it reads
// through, and it is not the real header: the ioctl numbers here are placeholders
// and the layouts match only in the members Source/Platform/Wscons touches. A
// binary built against it would talk to the kernel in a language the kernel does
// not speak, which is why check-wscons-compiles.sh stops at -fsyntax-only.
//
// A member the frontend starts using and this omits is a compile error here,
// which is the point: the stub is wrong in exactly the way the check reports.

#include <cstdint>

// Framebuffer geometry, from WSDISPLAYIO_GINFO.
struct wsdisplay_fbinfo {
    unsigned int height;
    unsigned int width;
    unsigned int depth;
    unsigned int cmsize;
};

// One key transition, from a read() on the keyboard device.
struct wscons_event {
    unsigned int type;
    int value;
    struct timespec time;
};

// Display ioctls.
#define WSDISPLAYIO_GINFO 0x40000001UL
#define WSDISPLAYIO_LINEBYTES 0x40000002UL
#define WSDISPLAYIO_SMODE 0x40000003UL

// Display modes: EMUL is the kernel's own terminal, DUMBFB hands the pixels over.
#define WSDISPLAYIO_MODE_EMUL 0
#define WSDISPLAYIO_MODE_DUMBFB 1

// Keyboard ioctls and the translation mode the frontend asks for.
#define WSKBDIO_SETMODE 0x40000004UL
#define WSKBDIO_BELL 0x40000005UL
#define WSKBD_TRANSLATED 1

// Key transition types.
#define WSCONS_EVENT_KEY_UP 1
#define WSCONS_EVENT_KEY_DOWN 2
