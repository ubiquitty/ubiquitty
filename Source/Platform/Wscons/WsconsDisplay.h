// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Takes exclusive control of the OpenBSD/NetBSD console framebuffer (wsdisplay in
// "dumb fb" mode via WSDISPLAYIO_SMODE(DUMBFB)) and blits tightly-packed RGBA8
// into it. No swapchain/compositor/GPU. The CPU SoftwareRenderer produces this
// exact RGBA8 shape (an oracle on the GPU frontends); here it is the only renderer.
//
// Only OpenBSD 7.9 x64 under QEMU has run this, by hand; NetBSD and real
// hardware have not. Depth conversion leans hardest on what the target's
// wsdisplay_fbinfo reports, so a framebuffer at a depth not yet seen is the
// first place to look when the picture comes out wrong.

#include <cstdint>
#include <vector>

namespace Ubiquitty {
namespace Wscons {

struct DisplayGeometry {
    int width = 0;
    int height = 0;
    int depthBits = 0; // reported bits-per-pixel (8/16/24/32)
    int strideBytes = 0; // bytes per scanline (may exceed width*bytesPerPixel — padding)
};

// Owns the console device fd across the mode switch (dumb-fb in, text-mode
// emulation restored on shutdown) and the mmap'd framebuffer. One instance per
// process — wsdisplay is exclusively owned in DUMBFB mode.
class CellGrid {
public:
    CellGrid() = default;
    ~CellGrid() { shutdown(); }
    CellGrid(const CellGrid&) = delete;
    CellGrid& operator=(const CellGrid&) = delete;

    // Opens `consolePath` (the currently-active VT), switches it to
    // WSDISPLAYIO_MODE_DUMBFB, reads geometry (WSDISPLAYIO_GINFO +
    // WSDISPLAYIO_LINEBYTES), and mmaps the framebuffer. False on any failure
    // (leaves the console in its original mode).
    bool init(const char* consolePath);

    // Restores WSDISPLAYIO_MODE_EMUL, unmaps, closes. Idempotent. Not
    // async-signal-safe (munmap + vector-free); a signal handler uses
    // emergencyRestoreTextMode instead.
    void shutdown();

    // Console restore for the death-signal handler: one ioctl(WSDISPLAYIO_SMODE,
    // EMUL) — no unmap/free/close (the process is dying; the kernel reclaims
    // those). ioctl isn't on the async-signal-safe list, but this single call is
    // the accepted minimal action: without it a signal-driven exit strands the VT
    // in raw framebuffer mode until reboot (SIGTERM on every shutdown is routine
    // for a getty replacement). Idempotent; safe to race shutdown().
    void emergencyRestoreTextMode();

    const DisplayGeometry& geometry() const { return m_geometry; }

    // Blit `rgba` (tightly packed RGBA8, row stride width*4) into the framebuffer,
    // expanding each source pixel into a scale x scale block, centered, converted
    // to the console's native depth. Clips if the scaled image overshoots. False
    // when uninitialized or the console depth is unhandled.
    bool blit(const std::uint8_t* rgba, int width, int height, int scale = 1);

private:
    int m_consoleFileDescriptor = -1;
    void* m_framebuffer = nullptr; // mmap'd, length m_geometry.height * m_geometry.strideBytes
    std::size_t m_framebufferLength = 0;
    DisplayGeometry m_geometry;
    bool m_didSwitchMode = false; // true once DUMBFB is active — shutdown() must restore EMUL
};

} // namespace Wscons
} // namespace Ubiquitty
