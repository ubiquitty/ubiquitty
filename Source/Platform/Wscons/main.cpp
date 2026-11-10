// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Entry point for the OpenBSD/NetBSD console frontend. No GUI toolkit, no GPU:
// this program is the console — it takes over the wsdisplay framebuffer
// (WsconsDisplay), reads raw wskbd key events (WsconsKeyboard), and renders
// through the same portable Core + SoftwareRenderer path. Intended to replace
// getty in /etc/ttys.
//
// Exercised by hand on OpenBSD 7.9 x64 in QEMU and nowhere else; NetBSD and
// real hardware untested. Single-pane, single-threaded, Unifont-only (no external
// font dependency). Build Release: the full-repaint CPU renderer is unusable at -O0.

#include "Base/Types.h"
#include "Core/Preferences/Preferences.h"
#include "Core/Rendering/OverlayAssembly.h"
#include "Core/Rendering/SoftwareRenderer.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/Runtime/KeyEncode.h"
#include "Core/Runtime/LaunchCommand.h"
#include "Core/Runtime/TerminalRuntime.h"
#include "Core/Runtime/TriggerConfig.h"
#include "Core/Screen/Addressing.h"
#include "Core/TermPalette.h"
#include "Core/TerminalOperations.h"
#include "Core/Themes/TermPaletteFromTheme.h"
#include "Core/Themes/Themes.h"
#include "PAL/PAL.h"
#include "Platform/Wscons/CapabilityPolicy.h"
#include "Platform/Wscons/WsconsDisplay.h"
#include "Platform/Wscons/WsconsKeyboard.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <vector>

#include <csignal>
#include <poll.h>

namespace {

// Single-threaded frontend: ingest drain and render/blit both run on this thread,
// so the model "lock" is a no-op. onSyncFrameReadyLocked renders + blits a
// completed DECSET-2026 synchronized frame immediately.
class SingleThreadedDrainHost : public Ubiquitty::Runtime::DrainHost {
public:
    SingleThreadedDrainHost(Ubiquitty::Runtime::TerminalRuntime& runtime, Ubiquitty::Wscons::CellGrid& display, Ubiquitty::Rendering::SoftwareRenderer& renderer, int pixelScale)
        : m_runtime(runtime)
        , m_display(display)
        , m_renderer(renderer)
        , m_pixelScale(pixelScale)
    {
    }

    void lockModel() override { }
    void unlockModel() override { }

    void onSyncFrameReadyLocked(Ubiquitty::Runtime::SyncFrameReason) override { renderAndBlit(); }

    /// Returns the paints so far, which tell the loop whether a drain's settle painted.
    ///
    /// - Returns: The number of ``renderAndBlit()`` calls.
    [[nodiscard]] int paintCount() const { return m_paintCount; }

    void renderAndBlit()
    {
        ++m_paintCount;
        Ubiquitty::Terminal* term = m_runtime.borrowTermForRender();
        if (!term)
            return;

        Ubiquitty::Rendering::BuildInputs in;
        in.palette = &term->palette;
        in.screenReverse = Ubiquitty::isReverseVideo(term);
        in.rows = term->rows;
        in.columns = term->columns;
        std::vector<Ubiquitty::Cell> grid(static_cast<std::size_t>(in.rows) * static_cast<std::size_t>(in.columns));
        for (int row = 0; row < in.rows; ++row)
            Ubiquitty::Screen::getDisplayRow(*term, 0, row, &grid[static_cast<std::size_t>(row) * in.columns], in.columns);
        in.cells = grid.data();

        if (term->modes.isCursorVisible && term->screens.active) {
            // Cursor look comes from the live palette (theme / OSC 12); leaving
            // rgb unset renders a black block regardless of theme.
            const Ubiquitty::PaletteRGB cursorColor = term->palette.cursor;
            in.cursor.row = term->screens.active->cursorY;
            in.cursor.column = term->screens.active->cursorX;
            in.cursor.mixA = 1.0f;
            in.cursor.shouldInvertText = true;
            in.cursor.rgb = { Ubiquitty::channel16To8(cursorColor.red) / 255.0f, Ubiquitty::channel16To8(cursorColor.green) / 255.0f, Ubiquitty::channel16To8(cursorColor.blue) / 255.0f, 1.0f };
            Ubiquitty::Rendering::setCursorTextColor(in.cursor, Ubiquitty::Rendering::cursorTextColor(*term));
        }

        std::vector<std::uint8_t> rgba;
        int width = 0;
        int height = 0;
        const bool isDebugLoggingEnabled = ::getenv("UBIQUITTY_WSCONS_DEBUG") != nullptr;
        const std::uint32_t startMicros = isDebugLoggingEnabled ? Ubiquitty::PAL::monotonicMicros() : 0;
        const bool didRender = m_renderer.render(in, rgba, width, height);
        const std::uint32_t renderedMicros = isDebugLoggingEnabled ? Ubiquitty::PAL::monotonicMicros() : 0;
        if (didRender)
            m_display.blit(rgba.data(), width, height, m_pixelScale);
        if (isDebugLoggingEnabled) {
            const std::uint32_t blittedMicros = Ubiquitty::PAL::monotonicMicros();
            std::fprintf(stderr, "[render] %d by %d render=%uus blit=%uus total=%uus\n",
                width, height, renderedMicros - startMicros, blittedMicros - renderedMicros, blittedMicros - startMicros);
        }
    }

private:
    Ubiquitty::Runtime::TerminalRuntime& m_runtime;
    Ubiquitty::Wscons::CellGrid& m_display;
    Ubiquitty::Rendering::SoftwareRenderer& m_renderer;
    int m_pixelScale = 1;
    int m_paintCount = 0;
};

// Resolve a theme and copy it into the Terminal's live palette via the shared
// Ubiquitty::Themes::applyThemeToTerminal. Choice: UBIQUITTY_WSCONS_THEME env override first,
// then config [appearance] theme, else no-op (Core's neutral-dark default stands).
void applyTheme(Ubiquitty::Terminal& term)
{
    int index = -1;
    if (const char* envTheme = ::getenv("UBIQUITTY_WSCONS_THEME"))
        index = Ubiquitty::Themes::indexForName(envTheme);
    if (index < 0) {
        const Ubiquitty::Preferences::Values& config = Ubiquitty::Preferences::values();
        if (!config.themeName.value_or("").empty())
            index = Ubiquitty::Themes::indexForName(config.themeName->c_str());
    }
    if (index < 0)
        return;
    // applyThemeToTerminal, not applyToTermPalette: only the Terminal-taking
    // form moves paletteBaseline, which is what OSC 110/111/112 revert to.
    (void)Ubiquitty::Themes::applyThemeToTerminal(term, index);
}

// Console-restore-on-death. Exiting on a signal without re-issuing
// WSDISPLAYIO_SMODE(EMUL) strands the VT with no shell until reboot, and SIGTERM
// on shutdown makes this the ROUTINE exit path. The handler does one thing —
// emergencyRestoreTextMode — then re-raises with the default disposition. ioctl
// isn't async-signal-safe, but this single restore is the accepted minimal
// action. volatile: read inside a signal handler, so must not be cached across
// the install/handler boundary.
Ubiquitty::Wscons::CellGrid* volatile displayForSignalRestore = nullptr;

void restoreConsoleOnSignal(int signalNumber)
{
    if (Ubiquitty::Wscons::CellGrid* display = displayForSignalRestore) {
        displayForSignalRestore = nullptr;
        display->emergencyRestoreTextMode();
    }
    ::signal(signalNumber, SIG_DFL);
    ::raise(signalNumber);
}

void installConsoleRestoreHandlers(Ubiquitty::Wscons::CellGrid& display)
{
    displayForSignalRestore = &display;
    struct sigaction action;
    action = {};
    action.sa_handler = &restoreConsoleOnSignal;
    sigemptyset(&action.sa_mask);
    // Termination signals (SIGTERM = system shutdown, SIGINT/SIGHUP = admin)
    // and the crash signals the untested-on-real-hardware ioctl/blit paths
    // could raise. SIGKILL is untrappable — nothing to do there.
    for (const int signalNumber : { SIGTERM, SIGINT, SIGHUP, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT })
        (void)::sigaction(signalNumber, &action, nullptr);
}

} // namespace

int main(int argc, char** argv)
{
    // Defaults match the currently-active VT convention (getty already owns
    // it before this program takes over): override for testing against a
    // non-console VT.
    const char* consolePath = argc > 1 ? argv[1] : "/dev/ttyC0"; // OpenBSD naming; NetBSD uses /dev/ttyE0
    const char* keyboardPath = argc > 2 ? argv[2] : "/dev/wskbd0";

    Ubiquitty::PAL::Context palContext;
    palContext.monotonicClock = &Ubiquitty::PAL::monotonicTicks;
    Ubiquitty::PAL::installContext(palContext);

    Ubiquitty::Wscons::CellGrid display;
    if (!display.init(consolePath)) {
        std::fprintf(stderr, "ubiquitty-wscons: failed to open/mode-switch %s\n", consolePath);
        return 1;
    }
    // From this line on the VT is in raw framebuffer mode — install the
    // restore-on-death handlers immediately, before anything that can fail.
    installConsoleRestoreHandlers(display);

    Ubiquitty::Wscons::Keyboard keyboard;
    if (!keyboard.init(keyboardPath)) {
        std::fprintf(stderr, "ubiquitty-wscons: failed to open %s\n", keyboardPath);
        return 1;
    }

    // Unifont bundled rasterizer, no external font dependency (matches the
    // Agent/MCP screenshot path — see Source/Agent/AgentSession.cpp).
    constexpr int cellWidth = 8;
    constexpr int cellHeight = 16;
    Ubiquitty::Rendering::SoftwareRenderer renderer(cellWidth, cellHeight);

    // Grid takes as many cells as fit the framebuffer over the Unifont cell at 2x;
    // render happens at 1x (cheap raster) and CellGrid::blit doubles each pixel,
    // centered. UBIQUITTY_WSCONS_SCALE=N overrides (3/4 = chunkier + faster).
    int scale = 2;
    if (const char* scaleOverride = ::getenv("UBIQUITTY_WSCONS_SCALE")) {
        scale = std::atoi(scaleOverride);
        if (scale < 1)
            scale = 1;
    }
    const int columns = display.geometry().width / (cellWidth * scale);
    const int rows = display.geometry().height / (cellHeight * scale);
    if (columns <= 0 || rows <= 0) {
        std::fprintf(stderr, "ubiquitty-wscons: console geometry too small (%d by %d at scale %d)\n", display.geometry().width, display.geometry().height, scale);
        return 1;
    }
    std::fprintf(stderr, "ubiquitty-wscons: %d by %d px, scale %d -> %d by %d cells\n", display.geometry().width, display.geometry().height, scale, columns, rows);

    Ubiquitty::Runtime::TerminalRuntime runtime;
    Ubiquitty::Runtime::RuntimeInitParameters initParameters;
    initParameters.rows = rows;
    initParameters.columns = columns;
    runtime.init(initParameters);

    if (!runtime.launch(Ubiquitty::Runtime::LaunchCommand::loginShell(), Ubiquitty::Preferences::terminalIdentity(Ubiquitty::Preferences::values()))) {
        std::fprintf(stderr, "ubiquitty-wscons: failed to spawn the login shell\n");
        return 1;
    }

    // Outlives the Terminal it is installed on, which is why it sits here rather
    // than inside the block below.
    Ubiquitty::Wscons::WsconsCapabilityPolicy capabilityPolicy;

    if (Ubiquitty::Terminal* term = runtime.borrowTermForRender()) {
        // Seeded before this frontend wires its first host-escaping client: a
        // null policy answers Core's fallback for a terminal nobody configured
        // rather than this frontend's own answer, so the gate has to exist
        // before there is anything to gate.
        term->capabilityPolicy = &capabilityPolicy;
        applyTheme(*term);
        // [triggers] and [characterClass] — parsed from the same config.toml the
        // theme above comes from, and applied nowhere before Core owned the work.
        const std::string triggerReport = Ubiquitty::Runtime::describeTriggerConfig(
            Ubiquitty::Runtime::applyTriggerConfig(*term, Ubiquitty::Preferences::values()));
        if (!triggerReport.empty())
            std::fprintf(stderr, "ubiquitty-wscons: %s\n", triggerReport.c_str());
    }

    SingleThreadedDrainHost drainHost(runtime, display, renderer, scale);
    drainHost.renderAndBlit(); // paint the first (empty) frame before any output arrives

    // A drain whose settle painted owes nothing; one that did not owes a paint,
    // which the runtime releases once nothing withholds it. A program can open
    // a block, or leave a frame the coherence rule holds, and go quiet, so the
    // loop wakes when the hold expires or the rule may answer differently.
    for (;;) {
        struct pollfd fds[2];
        fds[0].fd = runtime.streamFileDescriptor();
        // Writability is asked for only while input sits queued behind a full
        // PTY — asked for always, a writable fd wakes every iteration and the
        // loop spins.
        fds[0].events = static_cast<short>(POLLIN | (runtime.hasPendingWrite() ? POLLOUT : 0));
        fds[1].fd = keyboard.fileDescriptor();
        fds[1].events = POLLIN;

        // A frame the coherence rule held at a drain's end is asked again on
        // the rule's schedule: a program that went quiet writes no byte that
        // would ask for it. A frame it releases is painted by the host. This loop
        // reads the pty itself, so a drain that has ended has seen the writer stop.
        const int paintsBeforeHeldFrame = drainHost.paintCount();
        const std::optional<std::uint64_t> untilHeldFrame = runtime.publishHeldFrameIfDue(drainHost, Ubiquitty::Runtime::TerminalRuntime::HeldFrameWriter::Stopped);
        if (drainHost.paintCount() != paintsBeforeHeldFrame)
            runtime.noteDrainForOwnPaint(Ubiquitty::Runtime::TerminalRuntime::SettlePaint::Painted);
        int timeoutMilliseconds = runtime.owedPaintWaitMilliseconds(Ubiquitty::PAL::monotonicTicks(), Ubiquitty::PAL::monotonicMicros());
        if (untilHeldFrame) {
            const int untilHeldFrameMilliseconds = static_cast<int>(std::clamp<std::uint64_t>((*untilHeldFrame + 999) / 1000, 1, 1000));
            if (timeoutMilliseconds < 0 || timeoutMilliseconds > untilHeldFrameMilliseconds)
                timeoutMilliseconds = untilHeldFrameMilliseconds;
        }
        const int rc = ::poll(fds, 2, timeoutMilliseconds);
        if (rc < 0)
            break;

        if (fds[0].revents & POLLOUT)
            runtime.drainPendingWrite();

        if (fds[0].revents & POLLIN) {
            const int paintsBefore = drainHost.paintCount();
            const Ubiquitty::Runtime::DrainOutcome outcome = runtime.drainAvailable(drainHost);
            if (outcome.reachedEnd)
                break; // the shell exited
            runtime.noteDrainForOwnPaint(drainHost.paintCount() != paintsBefore
                    ? Ubiquitty::Runtime::TerminalRuntime::SettlePaint::Painted
                    : Ubiquitty::Runtime::TerminalRuntime::SettlePaint::Owed);
        }
        if (runtime.takeOwedPaint(Ubiquitty::PAL::monotonicTicks(), Ubiquitty::PAL::monotonicMicros()))
            drainHost.renderAndBlit();

        if (fds[1].revents & POLLIN) {
            Ubiquitty::Runtime::KeyPress press;
            if (keyboard.readEvent(press)) {
                char bytes[64];
                // Every mode the bytes depend on is the terminal's — DECCKM,
                // DECPAM, the modifyOtherKeys levels, the Kitty flag stack. This
                // backend read one of them and passed zero for the rest, so a
                // program that turned any of the others on was answered as if it
                // had not. Whether a release produces bytes is the terminal's
                // too, which is why nothing here filters one out.
                const Ubiquitty::Terminal* term = runtime.borrowTermForRender();
                const Ubiquitty::Runtime::ModeSnapshot modes
                    = term ? Ubiquitty::Runtime::sampleModes(*term) : Ubiquitty::Runtime::ModeSnapshot {};
                const int length = Ubiquitty::Runtime::encodeKey(modes, press, bytes,
                    term ? Ubiquitty::userDefinedKeysOrNull(*term) : nullptr)
                                       .length;
                if (::getenv("UBIQUITTY_WSCONS_DEBUG")) {
                    std::fprintf(stderr, "[encode] key=%u -> length=%d bytes=", static_cast<unsigned>(press.virtualKey), length);
                    for (int i = 0; i < length; ++i)
                        std::fprintf(stderr, "%02x ", static_cast<unsigned char>(bytes[i]));
                    std::fprintf(stderr, "\n");
                }
                if (length > 0)
                    runtime.sendInputBytes({ bytes, static_cast<std::size_t>(length) });
            }
        }
    }

    runtime.close();
    return 0;
}
