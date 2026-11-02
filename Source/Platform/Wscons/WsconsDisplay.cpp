// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Wscons/WsconsDisplay.h"

#include <cstring>
#include <vector>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>

#include <dev/wscons/wsconsio.h>

namespace Ubiquitty {
namespace Wscons {

bool CellGrid::init(const char* consolePath)
{
    if (!consolePath || consolePath[0] == '\0')
        return false;

    m_consoleFileDescriptor = ::open(consolePath, O_RDWR);
    if (m_consoleFileDescriptor < 0)
        return false;

    struct wsdisplay_fbinfo fbInfo;
    fbInfo = {};
    if (::ioctl(m_consoleFileDescriptor, WSDISPLAYIO_GINFO, &fbInfo) != 0) {
        ::close(m_consoleFileDescriptor);
        m_consoleFileDescriptor = -1;
        return false;
    }

    // Sanity-check driver-reported geometry before it feeds mmap length or blit
    // row math (the blit trusts these for every memcpy) — fail closed rather than
    // scribble on a malformed report.
    const int bytesPerPixel = (static_cast<int>(fbInfo.depth) + 7) / 8;
    if (fbInfo.width <= 0 || fbInfo.height <= 0 || bytesPerPixel <= 0 || bytesPerPixel > 4) {
        ::close(m_consoleFileDescriptor);
        m_consoleFileDescriptor = -1;
        return false;
    }

    int lineBytes = 0;
    if (::ioctl(m_consoleFileDescriptor, WSDISPLAYIO_LINEBYTES, &lineBytes) != 0 || lineBytes <= 0) {
        // Fall back to a packed-row assumption — some wscons drivers do not
        // implement LINEBYTES and pack scanlines tightly.
        lineBytes = static_cast<int>(fbInfo.width) * bytesPerPixel;
    }
    if (lineBytes < static_cast<int>(fbInfo.width) * bytesPerPixel) {
        ::close(m_consoleFileDescriptor);
        m_consoleFileDescriptor = -1;
        return false;
    }

    m_geometry.width = fbInfo.width;
    m_geometry.height = fbInfo.height;
    m_geometry.depthBits = fbInfo.depth;
    m_geometry.strideBytes = lineBytes;

    // Take exclusive raw-framebuffer control: the kernel's text-mode emulation
    // steps aside so our mmap'd bytes reach the screen. WSDISPLAYIO_MODE_EMUL is
    // restored in shutdown() — never leave a console stranded in graphics mode.
    int mode = WSDISPLAYIO_MODE_DUMBFB;
    if (::ioctl(m_consoleFileDescriptor, WSDISPLAYIO_SMODE, &mode) != 0) {
        ::close(m_consoleFileDescriptor);
        m_consoleFileDescriptor = -1;
        return false;
    }
    m_didSwitchMode = true;

    m_framebufferLength = static_cast<std::size_t>(m_geometry.strideBytes) * static_cast<std::size_t>(m_geometry.height);
    void* mapped = ::mmap(nullptr, m_framebufferLength, PROT_READ | PROT_WRITE, MAP_SHARED, m_consoleFileDescriptor, 0);
    if (mapped == MAP_FAILED) {
        shutdown();
        return false;
    }
    m_framebuffer = mapped;
    // Clear stale kernel text-mode content: blit() only touches the centered grid
    // region, so without this the untouched margin keeps showing it forever.
    std::memset(m_framebuffer, 0, m_framebufferLength);
    return true;
}

void CellGrid::emergencyRestoreTextMode()
{
    if (m_consoleFileDescriptor >= 0 && m_didSwitchMode) {
        int mode = WSDISPLAYIO_MODE_EMUL;
        (void)::ioctl(m_consoleFileDescriptor, WSDISPLAYIO_SMODE, &mode);
        m_didSwitchMode = false;
    }
}

void CellGrid::shutdown()
{
    if (m_framebuffer) {
        ::munmap(m_framebuffer, m_framebufferLength);
        m_framebuffer = nullptr;
        m_framebufferLength = 0;
    }
    if (m_consoleFileDescriptor >= 0) {
        if (m_didSwitchMode) {
            int mode = WSDISPLAYIO_MODE_EMUL;
            (void)::ioctl(m_consoleFileDescriptor, WSDISPLAYIO_SMODE, &mode);
            m_didSwitchMode = false;
        }
        ::close(m_consoleFileDescriptor);
        m_consoleFileDescriptor = -1;
    }
    m_geometry = DisplayGeometry {};
}

bool CellGrid::blit(const std::uint8_t* rgba, int width, int height, int scale)
{
    if (!m_framebuffer || !rgba || width <= 0 || height <= 0 || scale < 1)
        return false;

    // Scaled + centered: each source pixel becomes a scale x scale block, centered
    // in the framebuffer, so a small cheap-raster grid fills the screen without
    // full-resolution per-frame cost.
    const int scaledWidth = width * scale;
    const int scaledHeight = height * scale;
    const int columnsToCopy = (scaledWidth < m_geometry.width ? scaledWidth : m_geometry.width) / scale;
    const int rowsToCopy = (scaledHeight < m_geometry.height ? scaledHeight : m_geometry.height) / scale;
    const int xOffsetPixels = ((m_geometry.width - columnsToCopy * scale) / 2);
    const int yOffset = (m_geometry.height - rowsToCopy * scale) / 2;

    auto* destinationBase = static_cast<std::uint8_t*>(m_framebuffer);

    if (m_geometry.depthBits == 32) {
        // Source RGBA8 -> destination XRGB8888 (alpha dropped). Byte order assumes
        // little-endian BGRX (the common wsdisplay convention). Each source row is
        // expanded to a scaled scratch row once, then memcpy'd `scale` times.
        std::vector<std::uint8_t> scaledRow(static_cast<std::size_t>(columnsToCopy) * scale * 4);
        for (int y = 0; y < rowsToCopy; ++y) {
            const std::uint8_t* sourceRow = rgba + static_cast<std::size_t>(y) * width * 4;
            for (int x = 0; x < columnsToCopy; ++x) {
                const std::uint8_t r = sourceRow[x * 4 + 0];
                const std::uint8_t g = sourceRow[x * 4 + 1];
                const std::uint8_t b = sourceRow[x * 4 + 2];
                for (int repeat = 0; repeat < scale; ++repeat) {
                    std::uint8_t* outputBuffer = scaledRow.data() + (static_cast<std::size_t>(x) * scale + repeat) * 4;
                    outputBuffer[0] = b;
                    outputBuffer[1] = g;
                    outputBuffer[2] = r;
                    outputBuffer[3] = 0;
                }
            }
            for (int repeat = 0; repeat < scale; ++repeat) {
                std::uint8_t* destinationRow = destinationBase + static_cast<std::size_t>(yOffset + y * scale + repeat) * m_geometry.strideBytes + static_cast<std::size_t>(xOffsetPixels) * 4;
                std::memcpy(destinationRow, scaledRow.data(), scaledRow.size());
            }
        }
        return true;
    }

    if (m_geometry.depthBits == 16) {
        // RGB565 pack — the common fallback depth on older/embedded wsdisplay
        // targets. Same expand-once-per-source-row strategy as the 32bpp path.
        std::vector<std::uint16_t> scaledRow(static_cast<std::size_t>(columnsToCopy) * scale);
        for (int y = 0; y < rowsToCopy; ++y) {
            const std::uint8_t* sourceRow = rgba + static_cast<std::size_t>(y) * width * 4;
            for (int x = 0; x < columnsToCopy; ++x) {
                const std::uint8_t r = sourceRow[x * 4 + 0];
                const std::uint8_t g = sourceRow[x * 4 + 1];
                const std::uint8_t b = sourceRow[x * 4 + 2];
                const auto packed = static_cast<std::uint16_t>(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
                for (int repeat = 0; repeat < scale; ++repeat)
                    scaledRow[static_cast<std::size_t>(x) * scale + repeat] = packed;
            }
            for (int repeat = 0; repeat < scale; ++repeat) {
                std::uint8_t* destinationRow = destinationBase + static_cast<std::size_t>(yOffset + y * scale + repeat) * m_geometry.strideBytes + static_cast<std::size_t>(xOffsetPixels) * 2;
                std::memcpy(destinationRow, scaledRow.data(), scaledRow.size() * 2);
            }
        }
        return true;
    }

    // Unhandled depth (8bpp indexed consoles need a palette LUT this spike
    // does not build) — refuse rather than scribble garbage.
    return false;
}

} // namespace Wscons
} // namespace Ubiquitty
