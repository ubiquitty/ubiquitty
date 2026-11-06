// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GTK4 entry for the Linux frontend. A login shell runs on a PTY (Core runs
// locally); its master fd is polled by the GLib main loop, host bytes drain into
// Core via TerminalSession::drain, the grid repaints on the widget frame
// clock, and key events are encoded by the portable Keymap and written to the PTY.
// The grid is CPU-rasterized (Unifont) as a GdkMemoryTexture; the Vulkan path
// swaps the raster for a GPU grid.
//
// Single-threaded by construction: the Terminal is touched only on the GTK main
// thread. Each pane holds the same TerminalSession the macOS drive wraps — the
// session's ingest thread is never started, so drain() runs on the main
// loop and its model lock is uncontended.
//
// Self-tests (headless, lavapipe-friendly — no display needed):
//   --smoke               offscreen Vulkan clear → pixel readback (GPU path)
//   --smoke-grid          CPU-rasterize a canned screen → check text was drawn
//   --dump-png PATH       write the canned screen to a PNG (CPU software path)
//   --dump-png-vk PATH    write the same canned screen via the GPU grid path
//   --dump-png-live PATH  launch a real shell, drain briefly, write the screen
//   --smoke-input PATH    launch a shell, type "ls\n" via the key path, dump it
//   --selftest-font-toggle  render FreeType, swap to Unifont (rebuildAtlas), assert
//   --smoke-mouse         enable SGR mouse, encode a left press, assert the bytes
//   --smoke-title         feed OSC 0, assert titleChanged + titleUTF8
//   --smoke-scrollback    feed numbered lines, assert a history offset shows an
//                         OLDER top row than the live tail (offset 0)
//   --smoke-selection     feed a 2-line screen, CHAR-select "BCD", assert the
//                         extracted text + clipboard capture == "BCD", assert the
//                         translucent selection overlay composites CPU==GPU
//                         byte-identically, and dump it to /tmp/sel_overlay.png
//   --smoke-scaled-run-selection  select a scaled proportional run's letters
//                         through its last letter's ink, as --select-rect does,
//                         assert the highlight covers that ink on every band row
//                         on the CPU and Vulkan arms alike, and that a drag short
//                         of it leaves the ink unlit
//   --smoke-paste         assert wrapPaste wraps with the bracketed-paste guards
//                         when bracketed and passes text through unchanged otherwise
//   --smoke-osc52         feed an OSC 52 SET, assert the ClipboardClient recorded
//                         the base64-decoded bytes (the OSC 52 copy path)
//   --smoke-osc7          feed an OSC 7, assert the ShellClient recorded the
//                         directory the shell named (the title's primary source)
//   --smoke-capability-origin  an exfiltrating read is denied a Remote origin
//                         and served to a Local one (both arms), and a Remote
//                         DA query is answered
//   --smoke-focus         enable DECSET 1004, assert setFocused(true/false) emits
//                         CSI I / CSI O to the gtkApplication, and nothing when 1004 is off
//   --smoke-pointer-lock  enable DECSET 7403, assert the lock verdict follows mode +
//                         focus, a grab report teaches the release hint, a motion
//                         delta reports while a zero delta is swallowed, and the
//                         break-out chord clears the mode at its pinned tick hold
//   --smoke-link          feed an OSC 8 hyperlink, assert a stamped cell resolves
//                         to its URI, then assert the launch-scheme allowlist
//                         (http/https/file accepted, javascript rejected), that a
//                         plain click opens only a declared link, and what a click
//                         may do with real files: open, reveal or refuse
//   --smoke-ime           set an IME pre-edit, assert snapshotVisibleGrid overlays
//                         it underlined at the cursor + the UTF-8 codepoint decode
//   --smoke-compose       drive the compose engine through a sequence it finishes,
//                         one it refuses and one given up, with no display
//   --smoke-find          feed numbered lines, regex-search via ScrollSearch, assert
//                         the match count, that the highlighted row reads the match,
//                         and that next/prev step + wrap the active index
//   --smoke-rectsel       Alternate-drag a rectangular selection, assert the column-block
//                         extraction differs from a linear char-drag's
//   --smoke-smartclick    assert smart double-click selects a whole URL/path token
//                         under the click, and no token on a plain word
//   --smoke-titlebuild    assert the rich-title directory segment (basename / ~ /
//                         full-path) + that formatTitle weaves the segments
//   --smoke-inspector     assert the process-inspector row format + marker column
//                         ($/# login shell, • not-safe-to-close, none allowlisted)
//   --smoke-ligature-sheet  walk a row into runs, draw one strip, assert it landed
//   --smoke-ligature-render draw the strips through the GPU pass, with a control
//                         inside its own slot and left the rest of the sheet clear
//   --smoke-fileread      read a file through the kitty t=f client: assert it is wired,
//                         that a Remote origin is denied, and that t=t removes what it read
//   --smoke-trigger       install a copy trigger, feed a matching line, assert the
//                         clipboard took the match and a non-matching line did not
//   --smoke-ligature-shaping  shape programming operators against the text face,
//                         assert a substitution happened and that letters get none
//   --smoke-gridcache     render one terminal three times (full / edit / scroll),
//                         assert CPU==GPU each frame, and that the later
//                         frames took the retained-grid partial lane
//   --bench-gridcache-scroll [frames]  partial-frame share and frame time while
//                         ligature-heavy code scrolls, with the machine it ran on
//   --smoke-gridcache-stress  the retained grid against the CPU oracle over a long
//                         feed, a moving search match, a selection behind the text,
//                         and two same-size panes taking turns on one renderer
//   --smoke-buffer-growth  one renderer, two frames, the second on a grid the
//                         first's instance buffers cannot hold (they are re-mapped)
//   --smoke-cursor        render the canned screen for each cursor shape (block /
//                         bar / underline / unfocused-hollow) via the CPU + GPU
//                         paths and assert byte-identical; leave /tmp/cursor_bar.png
//   --smoke-rich-capture  skip ordinary rich-text captures, preserve bar carets,
//                         and clear retained blocks after deletion or screen changes
//   --smoke-image         feed a tiny solid-red DEC sixel, render via the CPU path
//                         to /tmp/image.png, and assert the image region is red
//                         (not the background) — the inline-image draw path
//   --smoke-image-stamp   a same-id, same-geometry kitty re-transmit reaches the
//                         screen (the texture cache keys on content, not geometry)
//   --smoke-image-vk      same sixel via both the CPU + GPU image passes, assert
//                         the PNGs are byte-identical (sha256) — the CPU<->GPU
//                         inline-image oracle; leaves /tmp/image_vk.png
//   --smoke-image-vk-placeholders  kitty Unicode placeholder cells drawn by
//                         both arms, byte-identical, each showing its tile
//   --smoke-image-vk-under-text  a z<0 picture under text on both arms: the
//                         text reads on top, and the frames agree to within
//                         one level a channel
//   --smoke-weight        feed SGR 1:5, assert the Core parses the weight + a
//                         weighted run renders byte-identically on CPU + GPU
//   --smoke-opacity       at opacity 0.5, assert a blank background pixel's alpha is ~128
//                         and the screen renders byte-identically on CPU + GPU
//   --smoke-background-image  a background image in each placement mode, under a
//                         translucent theme, renders byte-identically on CPU + GPU
//                         and shows through the open alpha
//   --smoke-beam          open the command palette, assert it lays out, composites
//                         into the grid (the frame DIFFERS from the closed one),
//                         renders byte-identically on CPU + GPU, narrows on a
//                         typed query, and closes on Escape
//   --smoke-tabs          drive the tab data logic (Workspace<->pane-registry
//                         lockstep, switch/close, last-tab guard) without a window
//   --smoke-splits        drive the split lifecycle (split/moveFocus/close-collapse,
//                         last-pane escalation) with launched panes, without a window
//   --smoke-pacing        that a repaint request reaches the idle<->active pacing policy
//   --smoke-atlas-capacity  that the glyph atlas is cut for the screen it serves
//   --smoke-coverage-sheet  that a partial sheet upload leaves the sheet holding the mirror
//   --smoke-readback-memory that the frame is read back from cached memory
//   --smoke-dmabuf-import-failure that a refused import reads back this and later frames
//   --smoke-oversized-grid  that a page past the device's largest frame is declined,
//                         not failed, and the next grid that fits draws on the GPU
//   --smoke-clear         Ctrl+Shift+K clear-buffer: assert the screen wipes
//   --smoke-font-zoom     Ctrl++/-/0 font zoom: assert the derived cell grows/resets
//   --smoke-pixel-geometry  GTK allocation, font scale, and padding reach Core reports
//   --smoke-prompt-navigation    Ctrl+Shift+Up/Down: assert jump to an OSC 133 prompt mark
//   --smoke-select-all    Ctrl+Shift+A: assert whole-buffer text spans scrollback
//   --print-config [PATH] parse a config (PATH, or a temp config with known
//                         values) via the portable loader, print the applied
//                         fields, and assert the parse round-trips (PASS/FAIL)

#include "Core/App/BannerTitle.h"
#include "Core/App/ProgramActivity.h"
#include "Core/App/TitleCompose.h"
#include "Core/Attributes/Hyperlinks.h"
#include "Core/Cell.h"
#include "Core/CellPen.h"
#include "Core/Codec/Base64.h"
#include "Core/Diagnostics/EscapeDecode.h"
#include "Core/Diagnostics/RenderScenes.h"
#include "Core/Diagnostics/SnapshotArguments.h"
#include "Core/Modes/Scroll.h"
#include "Core/Modes/SyncOutput.h"
#include "Core/Mouse/Mouse.h"
#include "Core/Mouse/MouseEvent.h"
#include "Core/OSC/MousePointerShape.h"
#include "Core/OSC/Notification.h"
#include "Core/Rendering/RemoteViewport.h"
#include "Core/RichText/Blocks.h"
#include "Core/Runtime/FrameDriver.h"
#include "Core/Runtime/KeyEncode.h"
#include "Core/Runtime/LaunchArguments.h"
#include "Core/Runtime/LaunchCommand.h"
#include "Core/Runtime/ModeSnapshot.h"
#include "Core/Runtime/ProcessPreferences.h"
#include "Core/Runtime/SearchCounterText.h"
#include "Core/Runtime/TerminalLaunchSeed.h"
#include "Core/Runtime/TerminalRuntime.h"
#include "Core/Runtime/TerminalSession.h"
#include "Core/Runtime/TriggerConfig.h"
#include "Core/Runtime/TriggerEffect.h"
#include "Core/Runtime/WorkspaceSession.h"
#include "Core/Screen/Addressing.h"
#include "Core/Screen/ClearBuffer.h"
#include "Core/Screen/CommandBlocks.h"
#include "Core/Screen/Marks.h"
#include "Core/Screen/Scrollback.h"
#include "Platform/Linux/AccessibleTerminal.h"
#include "Platform/Linux/BitmapFace.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/CapabilityPolicy.h"
#include "Platform/Linux/Clipboard.h"
#include "Platform/Linux/ConfigurationWatcher.h"
#include "Platform/Linux/FontRouting.h"
#include "Platform/Linux/FontSizing.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/PTYWatch.h"
#include "Platform/Linux/PaneViewport.h"
#include "Platform/Linux/PangoRichText.h"
#include "Platform/Linux/PointerLock.h"
#include "Platform/Linux/Raster.h"
#include "Platform/Linux/Updater.h"
#include "Platform/Linux/VulkanMemory.h"
#include "Platform/Linux/VulkanRenderer.h"

#include "Base/FractionalAccumulator.h"
#include "Base/WeakPtr.h"
#include "Core/Attributes/LinkRun.h"
#include "Core/CellGrid.h"
#include "Core/CommandPalette/BeamSession.h"
#include "Core/CommandPalette/SettingsCommands.h"
#include "Core/Cursor/Blink.h"
#include "Core/GridBounds.h"
#include "Core/Image/ImagePlacement.h"
#include "Core/Input/BeamKey.h"
#include "Core/Input/ComposeEngine.h"
#include "Core/Input/Keybindings.h"
#include "Core/Input/ModifierPolicy.h"
#include "Core/Input/PasteNormalize.h"
#include "Core/Input/PointerInput.h"
#include "Core/Input/PointerLadder.h"
#include "Core/Input/PointerShape.h"
#include "Core/Input/ShellEscape.h"
#include "Core/Input/TransientHint.h"
#include "Core/Keys/KeyEvent.h"
#include "Core/Keys/KeyTranslation.h"
#include "Core/Keys/Keymap.h"
#include "Core/Keys/KittyKeyboard.h"
#include "Core/Kitty/UnicodePlaceholders.h"
#include "Core/Modes/TerminalModes.h"
#include "Core/OSC/Dispatch.h"
#include "Core/OSC/ProgressIndicator.h"
#include "Core/OSC/TextSizing.h"
#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/CursorPreferences.h"
#include "Core/Preferences/EffectiveValue.h"
#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Preferences/Preferences.h"
#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Preferences/PreferencesDefaults.h"
#include "Core/Preferences/RenderConfigurationFold.h"
#include "Core/Preferences/Schema.h"
#include "Core/Preferences/SnapshotConfigurationFlags.h"
#include "Core/Preferences/Vocabulary.h"
#include "Core/Protocol/Sync/WireVersion.h"
#include "Core/Rendering/BeamLayout.h"
#include "Core/Rendering/BoxDrawingRasterizer.h"
#include "Core/Rendering/BundledFonts.h"
#include "Core/Rendering/CellMetrics.h"
#include "Core/Rendering/ColorResolve.h"
#include "Core/Rendering/CursorPresentation.h"
#include "Core/Rendering/FontSelection.h"
#include "Core/Rendering/FrameDamage.h"
#include "Core/Rendering/GridCapturePlan.h"
#include "Core/Rendering/HintToastLayout.h"
#include "Core/Rendering/ImageQuads.h"
#include "Core/Rendering/LigatureSheet.h"
#include "Core/Rendering/OverlaySpanGather.h"
#include "Core/Rendering/PNGEncoder.h"
#include "Core/Rendering/PaddingGeometry.h"
#include "Core/Rendering/ProportionalRun.h"
#include "Core/Rendering/RenderPathMarker.h"
#include "Core/Rendering/ShadeStyle.h"
#include "Core/Rendering/TerminalSnapshot.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Core/Runtime/TabStripChrome.h"
#include "Core/Screen/PromptNavigation.h"
#include "Core/Screen/ScrollSearch.h"
#include "Core/Screen/ScrollTuning.h"
#include "Core/Screen/ViewPlacement.h"
#include "Core/Selection/Selection.h"
#include "Core/Selection/SelectionText.h"
#include "Core/Selection/TerminalSelection.h"
#include "Core/Session/FileLink.h"
#include "Core/Session/LayoutTree.h"
#include "Core/Session/SessionOrigin.h"
#include "Core/TermPalette.h"
#include "Core/TerminalOperations.h"
#include "Core/Themes/ChromeStyle.h"
#include "Core/Themes/TermPaletteFromTheme.h"
#include "Core/Themes/ThemePreferences.h"
#include "Core/Themes/Themes.h"
#include "Core/Title/Directory.h"
#include "Core/Title/Format.h"
#include "Core/Title/Truncate.h"
#include "Core/Triggers/Actions.h"
#include "Core/Triggers/Engine.h"
#include "Core/Unicode/Normalize.h"
#include "Core/Unicode/UTF8Decoder.h"
#include "Core/Unicode/UTF8Encoder.h"
#include "Core/Unicode/Width.h"
#include "Core/VT/Constants.h"
#include "PAL/Log.h"
#include "PAL/PAL.h"
#include "PAL/Process.h"
#include "PAL/Stream.h"
#include "Platform/POSIX/GatedFileRead.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <format>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

#include <fcntl.h>
#include <linux/magic.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/vfs.h>
#include <unistd.h>

#include <gdk/gdkkeysyms.h>
#include <glib-unix.h>
#include <gtk/gtk.h>

namespace {

constexpr int startupColumns = 80;
constexpr int startupRows = 24;
// Cell dims are font-derived at runtime — app().rasterContext.cellWidth() /
// cellHeight() (Unifont 8×16 when forced or FreeType init fails).

// Per-pane frontend state: one live session plus the interaction + view chrome
// that belongs to it. One LinuxPane per Layout pane; activePane is the focused
// pane the input + render paths read/write. Today there is exactly one (a single
// surface / tab / pane); tabs + splits will add more, each mapped by its PaneID.
// Reads the file a kitty graphics t=f / t=t transmission names, so a client
// streaming framebuffer video can hand over a path instead of base64 through the
// pty. Unwired, Core drops the transmission and the image never arrives.
//
// Every hardening rule is Ubiquitty::POSIX::readGatedFile's and is answered
// there rather than restated here — the open flags, the regular-file check on the
// descriptor, the gate on the descriptor's own canonical path, the bounded read,
// and the containment and identity checks the delete needs. The macOS arm calls
// the same function, which is the point of it living in Platform/POSIX.
//
// What differs between the arms is when the delete happens. macOS defers it onto
// a serial queue to keep the syscalls off its ingest thread, and pays for that
// with a same-name-reuse hazard it cancels against. This frontend deletes inline,
// so there is no pending queue for a later frame's delete to sit in and no hazard
// to cancel — which is why it passes no before-read hook.
//
// Neither arm declares t=t (FileReadClient::supportsTemporaryFileTransport says
// why), so Core refuses a t=t before this is asked. The delete stays, gated as
// readGatedFile gates it, so the declaration is the only thing to change.
class LinuxFileReadClient final : public Ubiquitty::FileReadClient {
public:
    // Seeded where the Terminal is wired rather than at construction: the pane
    // owning this exists before its Terminal does, and the gate needs the very
    // Terminal whose parser is asking.
    void setTerminal(Ubiquitty::Terminal* term) { m_term = term; }

    [[nodiscard]] int readFile(const char* path, bool unlinkAfter, unsigned char* outputBuffer, int maxLength) override // bool-ok: seam-defined
    {
        if (!m_term || !path || !outputBuffer || maxLength <= 0)
            return -1;
        Ubiquitty::POSIX::GatedFileIdentity identity;
        const int result = Ubiquitty::POSIX::readGatedFile(*m_term, path,
            std::span<unsigned char>(outputBuffer, static_cast<std::size_t>(maxLength)),
            unlinkAfter ? Ubiquitty::POSIX::GatedFileDisposition::DeleteAfterReading : Ubiquitty::POSIX::GatedFileDisposition::Keep, &identity);
        if (result >= 0 && unlinkAfter && identity.isValid())
            Ubiquitty::POSIX::verifiedUnlink(identity);
        return result;
    }

    // t=s, through the same shared implementation the macOS arm calls. The read
    // primitive differs by platform and each would be wrong the other way round:
    // there read(2) fails on an shm descriptor so it maps, and mapping is safe
    // because a Darwin shm object cannot shrink once sized. Here read(2) works
    // and mapping is what is unsafe — a second ftruncate succeeds, so a writer
    // can pull the pages out between the size being read and the bytes being
    // copied, and touching an unbacked page of a shared mapping is SIGBUS chosen
    // by whoever sent the sequence.
    [[nodiscard]] bool supportsSharedMemoryTransport() const override { return true; }

    [[nodiscard]] int readSharedMemory(const char* name, bool unlinkAfter, unsigned char* outputBuffer, int maxLength) override // bool-ok: seam-defined
    {
        if (!m_term || !name || !outputBuffer || maxLength <= 0)
            return -1;
        return Ubiquitty::POSIX::readGatedSharedMemory(*m_term, name,
            std::span<unsigned char>(outputBuffer, static_cast<std::size_t>(maxLength)),
            unlinkAfter ? Ubiquitty::POSIX::SharedMemoryDisposition::UnlinkAfterReading
                        : Ubiquitty::POSIX::SharedMemoryDisposition::Keep);
    }

private:
    // Borrowed. Each pane's client is destroyed with the pane, before its
    // Terminal, which is the same lifetime the other clients here have.
    Ubiquitty::Terminal* m_term = nullptr;
};

struct LinuxPane : Ubiquitty::CanMakeWeakPtr {
    std::uint8_t keyPositionModifiers = 0;
    bool hasUnheardBell = false;
    // Declared before `runtime`, and the order is the point: the Terminal inside
    // the runtime holds a CheckedPtr to this, and members are destroyed in
    // reverse declaration order. Below the runtime it would be destroyed while
    // that pointer still referenced it, which CanMakeCheckedPtr asserts on.
    LinuxFileReadClient fileReadClient; // kitty graphics t=f / t=t, per Terminal
    // This pane's OSC 52 client, per pane so a read query names the pane
    // whose program asked on whichever thread the parser runs. Same lifetime
    // rule as the file client above.
    Ubiquitty::Linux::LinuxClipboardClient clipboardClient;
    Ubiquitty::Linux::PangoRichText richText;
    Ubiquitty::Rendering::TerminalFrameInputs richTextFrame;
    // The session this pane presents — the same Core owner the macOS drive
    // wraps, so the pointer ladder, the drain host and the model lock live in
    // one place. In the GUI the WINDOW MODEL owns it (the model closes and
    // releases it in the same verb that removes the pane, before this view
    // is destroyed), so this is a borrow; a headless entry owns its own
    // below and points this at it.
    Ubiquitty::Runtime::TerminalSession* session = nullptr;
    // Whether Core's ingest thread parses this pane's bytes — the pipeline
    // the Swift arm runs, reader thread and flood ring included. The window's
    // panes start it and hear of each delivery through the drain signal; a
    // headless entry drains inline on this thread through the fd watch. While
    // it runs, every direct Terminal read on this thread goes through the
    // session's ModelReadScope, and the inline affordances — the fd watch,
    // the writability watch, the held-frame timer — stay unarmed: the loop
    // owns the transport, the queued writes and the coherence rule's clock.
    bool isIngesting = false;
    // The pointer-lock mode (private 7403) as the last delivery published it.
    // The verdict is asked on an edge of it, not on every delivery: a flood
    // delivers hundreds of times a second, and each ask is a model lock the
    // parser donates.
    bool hasPointerLockMode = false;
    // The one reference a headless entry owns. --smoke-* / --dump-* drive a
    // passive terminal with their own parameters and no shell, which is not
    // a window the model launches; the GUI leaves this empty. Declared after
    // `fileReadClient` so the Terminal inside dies first (the CheckedPtr
    // order rule above).
    struct SessionRelease {
        void operator()(Ubiquitty::Runtime::TerminalSession* session) const { releaseTerminalSession(session); }
    };
    std::unique_ptr<Ubiquitty::Runtime::TerminalSession, SessionRelease> headlessSession;
    Ubiquitty::Runtime::ModeSnapshot modes; // keyboard/terminal modes from the last drain
    // Mouse-tracking flags from the last drain; the pointer path reads them to
    // decide whether (and how) to encode a mouse report. Single-threaded — no lock.
    Ubiquitty::Runtime::DrainOutcome mouseModes;
    // Scrollback viewport offset: 0 = live tail, up scrolls into history (clamped to
    // scrollbackCount). Selection coords are VISIBLE-grid rows/columns read through it.
    int viewOffset = 0;
    std::uint64_t searchRevealGeneration = 0;
    std::uint32_t searchRevealEpoch = 0;
    // Portable mouse text selection through Core's Terminal-bound facade —
    // the same Session the macOS surface owns, so gesture sequencing, word
    // and line growth, wide bounds and the copy walk are answered once.
    Ubiquitty::Selection::Session selection;
    float lastCursorBlinkAlpha = 1.0f; // last painted blink phase (onTick repaint gate)
    Ubiquitty::Rendering::CursorPresentation cursorPresentation;
    Ubiquitty::Rendering::RemoteViewportPlacement presentation;
    Ubiquitty::FloatSize presentationViewport;
    Ubiquitty::Linux::PaneViewportPublisher viewportPublisher;
    guint cursorPresentationSource = 0;
    guint ptySource = 0; // GLib fd-watch tag draining this pane's PTY (0 = none)
    guint ptyWriteSource = 0; // one-shot writability watch flushing queued input (0 = none)
    guint heldFrameSource = 0; // one-shot timer asking the coherence rule again for a frame it held (0 = none)
    // This pane's grid dimensions. Today every pane fills the window so they track
    // app().columns/app().rows; with split panes each pane sizes to its own sub-rectangle, so the
    // coordinate math (cellAtPoint/links/selection) reads these, not the globals.
    int columns = startupColumns;
    int rows = startupRows;
    GtkWidget* picture = nullptr; // this pane's GtkPicture (one per visible pane)
    int promptNavigationRow = -1; // anchor row for Jump-to-Prompt (OSC 133 mark navigation)
    Ubiquitty::Input::ComposeState compose;

    ~LinuxPane()
    {
        if (cursorPresentationSource != 0) {
            g_source_remove(cursorPresentationSource);
        }
    }
};

// What one delivery tells this side, whichever thread parsed: the inline
// drain reads it off the outcome, the ingest hop off the flags and the
// snapshot. Both end in applyPaneDelivery.
struct PaneDelivery {
    bool didOutputArrive = false;
    Ubiquitty::BellCue bell; // mode Off when no bell rang
    std::uint32_t bellsRung = 0; // the bells this pane's own route counted; none rings nothing
    bool didTitleChange = false;
    bool didDirectoryChange = false;
    bool didProcessStateChange = false;
    bool didProgressChange = false;
    bool didTabStatusChange = false;
    bool didSearchChange = false;
    bool shouldReconcilePointerLock = true;
    bool hasNotifications = false;
    bool hasWindowRequests = false;
    bool hasTriggerMatches = false;
    bool didExit = false;
    Ubiquitty::Screen::HistoryFacts history;
};

// Folds the session's event flags into a delivery: the queue bits, which the
// queues raise whether or not a drain carried the bytes, and the screen bit
// the local-echo feed raises with no drain at all.
void noteEventFlags(PaneDelivery& delivery, std::uint32_t events)
{
    const auto has = [events](Ubiquitty::Runtime::EventKind kind) { return (events & (1u << static_cast<unsigned>(kind))) != 0; };
    delivery.didOutputArrive = delivery.didOutputArrive || has(Ubiquitty::Runtime::EventKind::ScreenDirty);
    delivery.didTabStatusChange = has(Ubiquitty::Runtime::EventKind::TabStatusChanged);
    delivery.didSearchChange = has(Ubiquitty::Runtime::EventKind::SearchChanged);
    delivery.hasNotifications = has(Ubiquitty::Runtime::EventKind::NotificationPosted);
    delivery.hasWindowRequests = has(Ubiquitty::Runtime::EventKind::WindowRequestPending);
    delivery.hasTriggerMatches = has(Ubiquitty::Runtime::EventKind::TriggerMatched);
}

void applyPaneDelivery(LinuxPane& pane, const PaneDelivery& delivery);
void servicePaneQueues(LinuxPane& pane, const PaneDelivery& delivery);
void serviceIngestEvents(LinuxPane& pane);
/// Refreshes the open find scope from its originating pane's search publication.
void refreshBeamFindScope();
/// Applies a search publication to its originating pane and the focused find bar.
void showSearchOutcome(LinuxPane& pane, const Ubiquitty::Search::Status& status);
bool isPerfLogEnabled();
void ringBell(const Ubiquitty::BellCue& cue);
const char* cursorNameForShape(Ubiquitty::MousePointerShape shape);
void updateProgressBar();

// A read hold on a pane's model, empty for a pane without a session. Free
// while the pane drains inline; the lock while its ingest thread runs.
[[nodiscard]] std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope> holdPaneModel(const LinuxPane& pane)
{
    if (!pane.session)
        return std::nullopt;
    return std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope>(std::in_place, *pane.session);
}

// Declared ahead of the input handlers that arm it; defined beside the PTY
// read handler it pairs with.
void armPTYWriteDrain(LinuxPane* pane);
// Heap-owned so each LinuxPane keeps a STABLE address: TerminalRuntime is
// non-movable (owns unique_ptr Terminal/Stream + a CheckedPtr) and each pane's
// PTY fd source holds a raw LinuxPane*. The outer vector may reallocate; the
// panes it points at never move.

namespace Layout = Ubiquitty::Session::Layout;
namespace Panes = Ubiquitty::Panes;

// The Core-owned layout topology this frontend projects (Docs/session-model.md):
// one surface / tab / pane today; tabs + splits will add more, each pane mapped to
// a LinuxPane by its PaneID. It owns which pane holds focus; this frontend reads
// that rather than keeping a second answer beside it.

using Layout::invalidPane;
using Layout::invalidTab;
using Layout::PaneID;
using Layout::Surface;
using Layout::SurfaceID;
using Layout::TabID;

// The frontend's whole mutable state, with one owner, so its teardown order is a
// property of one declaration instead of where each definition happened to sit in
// the file. What the panes point into is inherited rather than declared here; see
// PaneReferents.
// Everything a pane holds a non-owning pointer into. These are a BASE of App
// rather than members of it: the language destroys a base subobject after every
// member, so a pane's Terminal releases its checked pointers into the clipboard
// client, and its runtime its reference to the drain host, while both still
// exist. Written as members, the guarantee would rest on where their two lines
// happened to sit, and moving either one is an abort at process exit.
// OSC 7 (the shell announcing its directory) and OSC 9/99/777 (a desktop
// notification). Core reaches both only through a ShellClient, so without one
// installed it drops them — the title fell back to the /proc read and a
// notification went nowhere.
//
// No marshalling here, unlike the macOS client which hops to the main thread:
// this frontend has no ingest thread at all. Core is driven from the PTY
// readable callback, which GTK raises on the main loop, so every call arrives
// there already and deferring one to an idle source would only delay it by a
// frame.
// The window seam Core reaches for OSC 22 and OSC 1337 StealFocus.
//
// Two of the interface's methods are answered here and the rest keep Core's
// no-op default, which is the documented way a frontend declines one. What is
// declined and why:
//
//   requestAttention  GTK4 removed the urgency hint and offers no
//                     client-settable replacement; a compositor grants
//                     attention through an activation token the client cannot
//                     mint for itself. Nudging by presenting the window would
//                     be stealFocus wearing the wrong name, and the interface
//                     draws exactly that distinction.
//   setFont, selectColorPreset,
//   setDisplayPower, setPasswordPromptActive, resize, setColumnMode,
//   performWindowOperation
//                     no frontend machinery behind them yet. Each is a
//                     separate piece of work rather than a line here.
// The pixel buffers frames hand to GTK. A texture holds its bytes until it
// dies, which is after the next frame replaced it, so a buffer cannot be
// reused in place; a fresh vector per frame was a 3.6 MB allocation and a page
// zeroing by the kernel every frame, a tenth of the GTK thread during a flood.
// Buffers come back through the texture's free function, which GTK may run
// off this thread, so the pool is locked.
class FrameBufferPool {
public:
    /// A buffer to render into, keeping the capacity of its last frame.
    ///
    /// - Returns: A pooled buffer, or a fresh one when none is free.
    [[nodiscard]] std::unique_ptr<std::vector<uint8_t>> take()
    {
        const std::scoped_lock hold(m_lock);
        if (m_free.empty())
            return std::make_unique<std::vector<uint8_t>>();
        std::unique_ptr<std::vector<uint8_t>> buffer = std::move(m_free.back());
        m_free.pop_back();
        return buffer;
    }

    /// Returns a buffer GTK has finished with; past the bound it is freed.
    ///
    /// - Parameter buffer: The buffer the texture's bytes were over.
    void give(std::unique_ptr<std::vector<uint8_t>> buffer)
    {
        const std::scoped_lock hold(m_lock);
        if (m_free.size() < pooledFrameBuffers)
            m_free.push_back(std::move(buffer));
    }

private:
    // Two in flight (the texture on screen and the one being made) plus one
    // for a frame GTK keeps a moment longer.
    static constexpr std::size_t pooledFrameBuffers = 3;
    std::mutex m_lock;
    std::vector<std::unique_ptr<std::vector<uint8_t>>> m_free;
};

struct PaneReferents {
    Ubiquitty::Linux::LinuxCapabilityPolicy capabilityPolicy;
};

struct App : PaneReferents {
    ~App()
    {
        // Renderer-owned sheets borrow the faces, which are still alive here.
        vulkan.shutdown();
    }
    Ubiquitty::Linux::ConfigurationWatcher configurationWatcher;
    // The window follows every configure through this subscription; the
    // renderer configuration it last applied tells a typography change, which
    // needs new faces, from one that only restyles the frame.
    std::optional<Ubiquitty::Preferences::ConfigurationSubscription> configurationSubscription;
    Ubiquitty::Rendering::RenderConfiguration appliedRenderConfiguration {};
    // The reserved gesture being taught, and when it stops being said. This arm
    // has no titlebar to hang a hint from, so it draws one into cells beside the
    // palette. A persistent hint (the pointer-lock chord) carries no deadline:
    // its condition, not a clock, ends it.
    // Whether the one wake-up at Core's hint expiry is already booked.
    bool isHintRepaintBooked = false;
    // ---- window + chrome ----
    GtkApplication* application = nullptr; // the bell notification is sent through it
    GtkWidget* window = nullptr;
    GtkWidget* paneContainer = nullptr; // holds the active tab's pane widget tree (one leaf, or GtkPaned)
    GtkWidget* tabStrip = nullptr;
    GtkWidget* menuButton = nullptr;
    GtkWidget* progressBar = nullptr; // GtkDrawingArea, can't-target so input passes through
    GtkWidget* searchBar = nullptr;
    GtkWidget* searchEntry = nullptr;
    GtkWidget* searchLabel = nullptr; // "k of n" match counter
    GtkWidget* inspectorWindow = nullptr;
    GtkWidget* inspectorLabel = nullptr;
    GtkWidget* accessibleTerminal = nullptr;
    GtkIMContext* imContext = nullptr; // input method (dead keys / compose / CJK)
    GtkWidget* focusedPicture = nullptr; // the FOCUSED pane's GtkPicture (alias of activePane()->picture)
    bool isFullScreen = false; // window fullscreen state (F11 toggles; macOS toggleFullScreen parity)
    std::string lastTitle;

    // ---- frame state ----
    bool isRepaintPending = true; // set by requestRepaint(); cleared by the frame that paints
    FrameBufferPool framePool;
    // The accessible snapshot is republished at most every
    // accessiblePublishIntervalSeconds while frames stream, with one trailing
    // publish after the last frame, so an assistive reader sees a settled grid
    // without the GTK thread snapshotting 120 grids a second.
    double lastAccessiblePublishSeconds = 0.0;
    guint accessiblePublishSource = 0;
    // The perf line's counters for the second in progress: how often the
    // frame clock ticked, how many ticks the withhold rule refused, how many
    // ingest hops were serviced and what they cost, and how long the tick
    // waited for the model. Reset with the line.
    struct PerfWindow {
        int ticks = 0;
        int withheldTicks = 0;
        int hops = 0;
        double hopSeconds = 0.0;
        // Where a hop's time went: the flag take (the pane-link poll), the
        // viewport follow, the queued seams, the pointer-lock verdict, the
        // title. Each but the title is a session call that takes the model
        // lock, and a lock taken without the render announcement waits for
        // the parser's whole pass.
        double hopFlagsSeconds = 0.0;
        double hopFollowSeconds = 0.0;
        double hopQueuesSeconds = 0.0;
        double hopPointerSeconds = 0.0;
        double hopTitleSeconds = 0.0;
        // Frames handed to the compositor as dma-bufs rather than read back.
        int exportedFrames = 0;
        double holdWaitSeconds = 0.0;
        double maxHoldWaitSeconds = 0.0;
    } perfWindow;
    // Idle<->active pacing, the same policy the macOS drive runs. GTK's frame
    // clock calls back at the display rate for as long as a callback is
    // installed, and this frontend's callback does the grid math and the blink
    // reconciliation on every one of them — on a terminal nobody is watching,
    // that is the display rate's worth of work and wakeups for no frame.
    Ubiquitty::Runtime::FrameDriver frameDriver;
    // GTK's caret blink: its settings, and the two clocks GtkText keeps for
    // its focused text, in GLib monotonic microseconds — when the cycle
    // starts, which input holds back half a period, and the last interaction,
    // which the blink timeout counts from.
    Ubiquitty::Cursor::Blink::ToolkitBlink toolkitBlink;
    gint64 caretBlinkCycleStartMicros = 0;
    gint64 caretInteractionMicros = 0;
    // The wake at the end of a lit or dark stretch, when no frame clock runs.
    guint caretBlinkSource = 0;
    // The installed tick callback, or zero when the clock is not driving us.
    // Removed when output goes idle and re-installed by requestRepaint(), which
    // is why every path that wants a frame goes through it.
    guint tickCallbackID = 0;
    double progressPhase = 0.0; // indeterminate comet position, wraps at 1.0
    uint32_t lastBlinkPaintTicks = 0;
    int columns = startupColumns, rows = startupRows; // current grid; tracks the widget size
    int scale = 1;

    // ---- fonts + rendering ----
    bool isVulkanReady = false;
    std::optional<Ubiquitty::Linux::FreeTypeRasterizer> glyphRasterizer;
    // The bitmap font and the toggle target. Optional so it can be built with the
    // configured line spacing once that is known: default-constructed it carries
    // none, and switching to it would change the row height under the user.
    std::optional<Ubiquitty::Rendering::UnifontRasterizer> unifontRasterizer;
    std::optional<Ubiquitty::Rendering::BoxDrawingRasterizer> boxRasterizer;
    bool areFontsSetUp = false;
    Ubiquitty::Rendering::FontRasterizerKind fontRasterizerKind = Ubiquitty::Rendering::FontRasterizerKind::Native;
    int fontPixelSize = 16; // live FreeType pixel size (zoomed at runtime); seeded in setupFonts
    // The configured size in POINTS, which is what `[font] size` is written in
    // and what the double-valued field holds. Kept beside the integer above
    // rather than replacing it, because the zoom steps and the reset are whole
    // pixels and read that one; this is what the rasterizer is sized from.
    double fontSizePoints = 12.0;
    double fontDPI = 96.0; // logical dots per inch, independent of the backing scale
    int lineSpacingPixels = 0; // font.line_spacing in device px; seeded in setupFonts
    int trackingPixels = 0; // font.character_spacing in device px, may be negative; seeded in setupFonts
    std::string backgroundImagePath; // the `[appearance] background_image` the raster context holds the decode of
    int uprightWeight = 0; // font.weight (usWeightClass), 0 = the face's own; seeded in setupFonts
    int boldWeight = 0; // font.bold_weight (usWeightClass), 0 = the face's own bold; seeded in setupFonts
    double widthPercent = 0.0; // font.width as a percent of normal, 0 = the face's own; seeded in setupFonts
    std::string fontVariations; // font.variations, a tag=value axis list; folds on top of the derived wght/wdth pair
    std::string fontFeatures; // font.features, an OpenType tag list requested of the shaper on every run
    // Whether the face's own ligatures may apply ([font] ligatures). HarfBuzz
    // turns liga/clig/calt on by default for horizontal text, so this is not a
    // flag the shaper reads — it decides whether a suppression is REQUESTED.
    Ubiquitty::Linux::Ligatures ligatures = Ubiquitty::Linux::Ligatures::Enabled;
    int defaultFontPixelSize = 16; // the resolved startup size, for zoom-reset
    std::string fontFamily; // resolved face family, kept so a zoom can re-emplace the rasterizer
    std::string fallbackFontName; // config [font] fallback; empty -> bundled Symbols Nerd Font
    std::string bundledFallbackPath; // bundled Symbols Nerd Font next to the binary; kept for zoom

    // Both caches release before the face objects they borrow above.
    Ubiquitty::Linux::RasterContext rasterContext;
    Ubiquitty::Linux::VulkanRenderer vulkan;

    // ---- input ----
    Ubiquitty::Input::BindingTable bindingTable;
    std::optional<Ubiquitty::Input::ChordResolver> chordResolver;
    // The pressed pointer button while one is held, for the 1002 drag-motion
    // facts; Other means none is down.
    Ubiquitty::Input::PointerButton heldPointerButton = Ubiquitty::Input::PointerButton::Other;
    Ubiquitty::MousePointerShape hoverCursorShape = Ubiquitty::MousePointerShape::Default;
    // Where the pointer last hovered with nothing reporting it, so a modifier
    // key, which moves no pointer, can re-ask what the hand shows there.
    double hoverX = 0;
    double hoverY = 0;
    bool isHoverPointKnown = false;

    // ---- pointer lock (DECSET 7403) ----
    // The OS-level grab; at most one is ever live, so this is per-app rather
    // than per-pane, mirroring the single OS cursor a GTK application shares
    // across every pane.
    Ubiquitty::Linux::PointerLockOS pointerLockOS;
    // The Wayland globals, bound lazily on the first engage attempt (binding
    // is a round trip against the compositor, which a headless/X11 run
    // never needs to pay).
    Ubiquitty::Linux::PointerLockWaylandGlobals pointerLockWayland;
    bool isPointerLockWaylandBound = false;
    bool isPointerLocked = false;
    // Which pane's grab this is, kept because RELEASE must act on the pane
    // that took the grab even after focus has since moved to another one
    // (that move is what triggered the release).
    LinuxPane* pointerLockPane = nullptr;
    // Non-modifier keys down right now, for the break-out chord: ⌃⌘ with
    // any other key is a shortcut, and only the pair alone arms.
    int heldNonModifierKeyCount = 0;
    guint pointerLockChordTimerID = 0;
    // The modifier state from the most recent key event, read back at the
    // chord's deadline tick -- GTK4 has no live "query current modifiers"
    // call, so this stands in for one; any change arrives through a key
    // event before the deadline can fire, so it is never stale at the ask.
    GdkModifierType pointerLockLastModifiers = static_cast<GdkModifierType>(0);

    // ---- palette + config ----
    Ubiquitty::CommandPalette::BeamSession beamSession;
    Ubiquitty::WeakPtr<LinuxPane> beamFindPane;
    std::map<std::string, Ubiquitty::Screen::LogicalPosition> beamFindTargets;
    std::string beamFindQuery;
    bool wasBeamInFindScope = false;
    int liveThemeIndex = -1;
    const Ubiquitty::Preferences::Values* config = nullptr;
    // What the live configuration document could not apply, as the bar under
    // the panes says it; empty when it applied whole. Held apart from the bar
    // because the startup configure runs before the window exists.
    std::string configurationDiagnostic;
    // The diagnostic lines the reader dismissed, for as long as the app runs:
    // the same document saved again stays quiet, and one that says something
    // else is heard.
    std::vector<std::string> dismissedConfigurationDiagnostics;
    GtkWidget* configurationBar = nullptr; // GtkActionBar, revealed while a diagnostic stands
    GtkWidget* configurationLabel = nullptr;

    // ---- the panes and the model that owns them ----
    // PaneID -> LinuxPane projection of the model's panes.
    std::map<PaneID, LinuxPane*> paneByID;
    // The `-e` command this process was started with, owned by main for the
    // whole run, and whether a pane has taken it. The FIRST pane runs it; a new
    // tab or split is the user asking for another shell, and re-running the
    // child there is behaviour a `-e` script cannot undo.
    const Ubiquitty::Runtime::LaunchRequest* launchRequest = nullptr;
    bool didConsumeLaunchRequest = false;
    // Heap-owned so each LinuxPane keeps a STABLE address: TerminalRuntime is
    // non-movable (owns unique_ptr Terminal/Stream + a CheckedPtr) and each pane's
    // PTY fd source holds a raw LinuxPane*. The outer vector may reallocate; the
    // panes it points at never move.
    std::vector<std::unique_ptr<LinuxPane>> panes;
    // The window model (Docs/design/shell-workspace-session.md): topology,
    // pane sessions and verb resolution in one Core owner. Caller-drained —
    // the fd watch drains on the GTK loop, and the model starts no thread.
    // OSC 66 text is drawn: a proportional run (Docs/proportional-text.md)
    // shapes in fontconfig's sans-serif through the strip sheet, and a sized
    // block takes the builder's own degradation — the grid glyph stretched
    // over its cells, as the portable tier draws it — until this renderer
    // grows the sized hooks; refusing would print both plainly and answer a
    // measurement in the grid face. Declared after `panes` on
    // purpose: members are destroyed in reverse order, and the model's
    // teardown closes every session — each Terminal must die before the pane
    // clients it references (the CheckedPtr order rule), so the model goes
    // first.
    struct ModelRelease {
        void operator()(Ubiquitty::Runtime::WorkspaceSession* model) const { releaseWorkspaceSession(model); }
    };
    std::unique_ptr<Ubiquitty::Runtime::WorkspaceSession, ModelRelease> model {
        Ubiquitty::Runtime::WorkspaceSession::make(
            Ubiquitty::Runtime::WorkspaceSession::IngestPolicy::CallerDrained,
            Ubiquitty::Runtime::DrawnText::SizedAndProportional)
    };
};

// Asks for a frame, and makes sure something is left to draw it. Declared ahead
// of its body because callers reach it from above the frame clock's own
// callback, whose address the body needs.
enum class RepaintCause : std::uint8_t {
    Activity,
    CursorStep
};
void requestRepaint(RepaintCause = RepaintCause::Activity);
void scheduleCaretBlink(const Ubiquitty::Terminal*);
void restartCaretBlink(bool isInput); // bool-ok: GtkText's pend (input) versus focus restart.
double cursorPresentationInterval(GtkWidget*);

// A base subobject is destroyed after every member, whatever order the members
// are written in, so inheriting the referents is what keeps the panes from
// outliving them — not the position of a line.
static_assert(std::is_base_of_v<PaneReferents, App>, "the panes' referents must be a base of App, so no member reordering can outlive them");

// The one instance. Owned here rather than by main so a GTK callback -- which
// carries no state of its own -- can reach it, and constructed on first use so
// nothing depends on the order two definitions happen to appear in.
App& app()
{
    static App instance;
    return instance;
}

// PaneID -> LinuxPane projection of the window model.
// The pane being drained, as a handle rather than an address. A synchronous OSC 52
// read handler firing mid-drain reads it to capture the REQUESTING pane, which is
// not always the focused one (a background tab/pane can issue the read), and the
// drain can outlive that pane: closing it erases the entry, so the handle resolves
// to null rather than to freed storage. Handles are never reused, so a stale one
// cannot come to name a different pane either.
// The tab strip (per-window chrome): a horizontal GtkBox of one toggle button per
// tab + a "+" button. Hidden while there is a single tab.
// Last window title set, so updateWindowTitle skips redundant sets; cleared on a
// tab switch to force a repaint for the newly-active pane.

// Tab + split lifecycle (defined after bindPane/attachPaneControllers, forward-
// declared for onKeyPressed / onPtyReadable which call them before that point).
void newTab();
void closePaneTab(LinuxPane* pane);
void switchToTab(TabID tab);
std::string buildTabLabel(LinuxPane& pane, int index);
void switchTabRelative(int delta);
void rebuildTabStrip();
void updateWindowTitle();
const Ubiquitty::Preferences::Values& loadPreferences();
Ubiquitty::App::PaneTitleFacts paneTitleFacts(LinuxPane& pane, const Ubiquitty::Preferences::Effective::TitleComposition& composition);
Ubiquitty::App::TitleViewerFacts titleViewerFacts(std::string fallbackName);
void rebuildPaneTree();
void splitFocusedPaneUX(Panes::Orientation orientation);
void closeFocusedPaneUX();
void moveFocusUX(Panes::Direction direction);

// Pointer lock (DECSET 7403), forward-declared for onKeyPressed / onKeyReleased
// / onMouseMotion, which call them before the section that defines them.
void updatePointerLock();
void applyPointerLock(Ubiquitty::Input::PointerLockVerdict verdict);
void bookPointerLockChordTick();
void reportPointerLockX11Motion(double widgetX, double widgetY, GdkModifierType state);
void drainPointerLockMotion();
Ubiquitty::Input::PointerLockKeyState pointerLockKeyStateFromModifiers(GdkModifierType state);
void notePointerLockChordFromKeyEvent(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge);

// The hover hand, forward-declared for onKeyPressed / onKeyReleased, which
// re-ask it when Ctrl goes down or up.
void updateHoverForModifierKey(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge);

LinuxPane* paneForID(PaneID id)
{
    const auto it = app().paneByID.find(id);
    return it != app().paneByID.end() ? it->second : nullptr;
}

// The focused pane, resolved through the Workspace rather than cached beside it.
// A cached address survives the pane it names — closing one erases it from app().panes,
// which destroys it — and every focus change already writes the model, so a copy
// here could only ever be the same answer or a stale one. Null when no pane holds
// focus, which callers already handle.
//
// The resolution is two lookups, so a loop reading it per cell hoists it first.
LinuxPane* activePane()
{
    return paneForID(app().model->focusedPane(app().model->activeSurface()));
}

// The pane a mid-drain OSC 52 handler must reply to, or null once it is closed.
// What this window holds about where one pane sits, for a banner's place line.
// Names and counts as they are; which of them the line states is Core's
// (Session::describeBannerPlace). This frontend opens shells on this machine
// in one window, so there is no host, no workspace and no window to tell
// apart: the tab's title as its strip shows it, and the pane among its tab's.
Ubiquitty::Session::BannerPlaceFacts bannerPlaceFacts(PaneID paneID)
{
    Ubiquitty::Session::BannerPlaceFacts facts;
    const SurfaceID surface = app().model->activeSurface();
    const int tabCount = app().model->tabCount(surface);
    facts.tabCount = std::max(1, tabCount);
    facts.paneNumber = static_cast<int>(paneID);
    for (int index = 0; index < tabCount; ++index) {
        const Panes::Tree* tree = app().model->paneTree(surface, app().model->tabAt(surface, index));
        if (tree == nullptr || !tree->holdsPane(static_cast<int>(paneID)))
            continue;
        facts.paneCount = std::max(1, tree->paneCount());
        // The tab is named by its focused pane, as its label is.
        if (LinuxPane* naming = paneForID(static_cast<PaneID>(tree->focusedPaneID())); naming != nullptr && naming->session != nullptr) {
            const Ubiquitty::Preferences::Effective::TitleComposition composition = Ubiquitty::Preferences::Effective::tabTitleComposition(loadPreferences());
            facts.tabTitle = Ubiquitty::App::composeBannerTitle(paneTitleFacts(*naming, composition), titleViewerFacts("Tab " + std::to_string(index + 1)), composition, Ubiquitty::Session::TitleSurface::Tab);
        }
        break;
    }
    return facts;
}

// Where the person's attention is, for a banner one pane asked for: four
// observations, and Core's verdict on them (OSC::isBannerWanted).
Ubiquitty::OSC::BannerAudience bannerAudience(PaneID paneID)
{
    Ubiquitty::OSC::BannerAudience audience;
    if (!app().window)
        return audience;
    const bool isWindowActive = gtk_window_is_active(GTK_WINDOW(app().window));
    audience.isAppActive = isWindowActive;
    audience.isWindowKey = isWindowActive;
    const SurfaceID surface = app().model->activeSurface();
    audience.isPaneFocused = app().model->focusedPane(surface) == paneID;
    const Panes::Tree* shown = app().model->paneTree(surface, app().model->activeTab(surface));
    audience.isPaneVisible = shown != nullptr && shown->holdsPane(static_cast<int>(paneID)) && gtk_widget_get_mapped(app().window);
    return audience;
}

// Posts the banner Core composes for one pane's notification. What it says and
// in which slot, whether someone already looking gets one, and which earlier
// banner it replaces are Core's, shared with the other frontends. A
// GNotification has a heading and running text, so the line that would stand
// beneath the heading leads the text; sending under an id a standing
// notification holds replaces that one.
void postPaneBanner(PaneID paneID, std::string_view title, std::string_view body, std::string_view name, Ubiquitty::NotificationOccasion occasion)
{
    if (!app().application || app().model == nullptr)
        return;
    const Ubiquitty::OSC::Banner banner = Ubiquitty::OSC::composeBanner(std::string(title), std::string(body), Ubiquitty::Session::describeBannerPlace(bannerPlaceFacts(paneID)));
    if (!banner.shouldPost || !Ubiquitty::OSC::isBannerWanted(bannerAudience(paneID), occasion))
        return;
    GNotification* notification = g_notification_new(banner.title.c_str());
    if (const std::string text = Ubiquitty::OSC::bannerRunningText(banner); !text.empty())
        g_notification_set_body(notification, text.c_str());
    // One window, so the window's name in the identifier is a constant. The
    // bell posts under an id of its own and is not replaced by this.
    const std::string identifier = Ubiquitty::OSC::bannerRequestIdentifier(Ubiquitty::OSC::BannerSource::Program, "main", static_cast<std::uint64_t>(paneID), std::string(name));
    g_application_send_notification(G_APPLICATION(app().application), identifier.c_str(), notification);
    g_object_unref(notification);
}

PaneID paneIDForPane(const LinuxPane* pane);

// Starts a program from an argv Core built, through no shell, so each word
// reaches it as one argument nothing in it can escape. The search-path flag
// resolves a bare program name in this process, as the macOS arm looks it up
// on PATH, so a name found nowhere fails here and its caller's fallback runs.
// `what` names the caller in the line a failure leaves. Returns whether the
// program was started.
bool spawnWithoutShell(const std::vector<std::string>& argv, const char* what)
{
    if (argv.empty())
        return false;
    std::vector<char*> arguments;
    arguments.reserve(argv.size() + 1);
    for (const std::string& word : argv)
        arguments.push_back(const_cast<char*>(word.c_str()));
    arguments.push_back(nullptr);
    GError* error = nullptr;
    const gboolean didSpawn = g_spawn_async(nullptr, arguments.data(), nullptr,
        static_cast<GSpawnFlags>(G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL),
        nullptr, nullptr, nullptr, &error);
    if (!didSpawn)
        g_printerr("ubiquitty-linux: %s failed to launch %s: %s\n", what, argv[0].c_str(), error ? error->message : "unknown error");
    if (error)
        g_error_free(error);
    return didSpawn;
}

// Runs one trigger act Core resolved in this pane's name. Every
// security-relevant decision is Core's and was taken before the act reached
// the queue: whether a run_command or webhook rule may fire at all (the two
// `[triggers]` gates, both closed by default), how a command template became
// an argv with the match as one inert argument, and which webhook schemes
// are admissible. What differs between the arms is only the spawn and the
// banner.
void applyTriggerEffect(LinuxPane& pane, PaneID paneID, const Ubiquitty::Runtime::TriggerEffect& effect)
{
    switch (effect.kind) {
    case Ubiquitty::Runtime::TriggerEffectKind::Notify:
        // The same pair, through the same composition, as a program's
        // notification, so a rule and an escape leave the same banner.
        postPaneBanner(paneID, effect.title, effect.body, {}, Ubiquitty::NotificationOccasion::Always);
        break;
    case Ubiquitty::Runtime::TriggerEffectKind::Copy:
        pane.clipboardClient.writeClipboard(Ubiquitty::ClipboardBuffer::Clipboard,
            std::span<const char>(effect.text.data(), effect.text.size()));
        break;
    case Ubiquitty::Runtime::TriggerEffectKind::SetTitle:
        if (app().window && !effect.title.empty())
            gtk_window_set_title(GTK_WINDOW(app().window), effect.title.c_str());
        break;
    case Ubiquitty::Runtime::TriggerEffectKind::RunCommand:
        // No shell anywhere on this path: the match rides as one argument.
        (void)spawnWithoutShell(effect.arguments, "run_command trigger");
        break;
    case Ubiquitty::Runtime::TriggerEffectKind::Webhook: {
        static bool hasReported = false;
        if (!hasReported) {
            hasReported = true;
            g_printerr("ubiquitty-linux: webhook triggers are enabled in config but this frontend"
                       " sends none — the GTK build links no HTTP client\n");
        }
        break;
    }
    case Ubiquitty::Runtime::TriggerEffectKind::None:
        break;
    }
}

// Delivers what the parser queued in the session — banners, window verbs,
// trigger reports — on this thread. The parser may run on Core's ingest
// thread, so the reactions that reach GTK live here, where the queues are
// read, and not on the Terminal, where they would be called. The same seams
// the Swift arm reads.
void servicePaneQueues(LinuxPane& pane, const PaneDelivery& delivery)
{
    const PaneID paneID = paneIDForPane(&pane);
    if (delivery.hasNotifications) {
        for (;;) {
            const Ubiquitty::Runtime::TerminalSession::Notification notification = pane.session->takeNotification();
            if (!notification.isPresent)
                break;
            postPaneBanner(paneID, notification.title, notification.body, notification.identifier, notification.occasion);
        }
    }
    if (delivery.hasWindowRequests) {
        for (;;) {
            const Ubiquitty::Runtime::TerminalSession::WindowRequest request = pane.session->takeWindowRequest();
            if (request.kind == Ubiquitty::Runtime::TerminalSession::WindowRequest::Kind::None)
                break;
            // OSC 1337 StealFocus asks to be activated outright, which is what
            // present does. Gated like every other host-escaping effect: a
            // Remote origin is refused before it reaches the queue. The other
            // verbs — CSI t, DECCOLM, attention, colour presets — have no
            // answer in this frontend yet.
            if (request.kind == Ubiquitty::Runtime::TerminalSession::WindowRequest::Kind::StealFocus && app().window)
                gtk_window_present(GTK_WINDOW(app().window));
        }
    }
    if (delivery.hasTriggerMatches) {
        for (;;) {
            const Ubiquitty::Runtime::TriggerEffect effect = pane.session->takeTriggerEffect(loadPreferences());
            if (effect.kind == Ubiquitty::Runtime::TriggerEffectKind::None)
                break;
            applyTriggerEffect(pane, paneID, effect);
        }
    }
}

// Points one pane's Terminal at the clients that serve it.
//
// One function rather than the same six assignments at the pane-creation site.
// Every pane gets these — the shared ones from the application, the file reader
// from the pane itself, because the gate it consults is that Terminal's. A tab or
// split that missed one would differ from its neighbours in a way only the
// missing feature shows.
//
// --smoke-fileread calls this rather than wiring its own, which is what lets it
// see the wiring going away: a test that sets up its own subject reports on the
// setup and passes with the production path removed. The older OSC smokes still
// attach the two or three clients they exercise by hand and detach them again;
// they assert about the sequences rather than about the wiring.
void wirePaneClients(LinuxPane& pane, Ubiquitty::Terminal& term)
{
    // OSC 52 clipboard: wired per pane rather than only for the default in
    // onActivate, so reads and writes work in every tab and split.
    pane.clipboardClient.setRequester(&pane);
    term.clipboardClient = &pane.clipboardClient;
    pane.fileReadClient.setTerminal(&term);
    term.fileReadClient = &pane.fileReadClient; // kitty graphics t=f / t=t
    term.capabilityPolicy = &app().capabilityPolicy; // a null policy answers PAL's defaults, not this frontend's
    // OSC 7 lands in the Terminal itself; the banners, the window verbs and
    // the trigger reports queue in the session, and servicePaneQueues reads
    // them on this thread after each delivery.
    (void)pane.session->installNotificationQueue();
    (void)pane.session->installWindowRequestQueue();
    (void)pane.session->installTriggerQueue();
}

PaneID paneIDForPane(const LinuxPane* pane)
{
    for (const auto& entry : app().paneByID)
        if (entry.second == pane)
            return entry.first;
    return invalidPane;
}

// The TabID whose (single) pane is paneID, scanning the active surface — the model
// is the authority, so this is derived, not cached.
TabID tabIDForPane(PaneID paneID)
{
    const SurfaceID surface = app().model->activeSurface();
    for (int i = 0; i < app().model->tabCount(surface); ++i) {
        const TabID tab = app().model->tabAt(surface, i);
        const Panes::Tree* tree = app().model->paneTree(surface, tab);
        if (!tree)
            continue;
        bool hasPane = false;
        Panes::forEachLeaf(*tree, [&](int leaf) {
            if (static_cast<PaneID>(leaf) == paneID)
                hasPane = true;
        });
        if (hasPane)
            return tab;
    }
    return invalidTab;
}

// Create the lone passive pane the headless harness drives; idempotent. The
// --smoke-* / --dump-* paths reach activePane()->session directly and start it
// with their own parameters, so the session here is pane-owned and unstarted —
// a window the model launches is the GUI's shape, not this one. Adopts the
// model's pre-minted root PaneID into the registry.
LinuxPane& ensureDefaultPane()
{
    if (!activePane()) {
        app().panes.push_back(std::make_unique<LinuxPane>());
        LinuxPane* pane = app().panes.front().get();
        pane->headlessSession.reset(Ubiquitty::Runtime::TerminalSession::make());
        pane->session = pane->headlessSession.get();
        app().paneByID[app().model->focusedPane(app().model->activeSurface())] = pane;
    }
    return *activePane();
}

// The process-wide user config (~/.config/ubiquitty/config.toml, $XDG_CONFIG_HOME-
// aware). Lazy-loaded once via the same Preferences::values() entry point the macOS
// frontend uses everywhere; a missing file leaves a fully-defaulted struct (the
// *Set flags are all false, so apply steps fall back to env/compile-time
// defaults). loadPreferences() runs early in onActivate, before setupFonts/launchShell.

const Ubiquitty::Preferences::Values& loadPreferences()
{
    if (!app().config)
        app().config = &Ubiquitty::Preferences::values();
    return *app().config;
}

void applyProcessConfiguration(const Ubiquitty::Preferences::Values& config)
{
    Ubiquitty::Runtime::applyProcessPreferences(config);
}

// The keys that are per-terminal state rather than process state: the OSC 52
// clipboard policy, the per-OSC / per-DCS sequence gate, the `[cursor]`
// preferences, the storage-tube colours and the ambiguous-width choice. A new pane is seeded through
// seedTerminalConfiguration; a reload re-seeds every live one here.
void applyPerTerminalConfiguration(const Ubiquitty::Preferences::Values& config)
{
    for (const std::unique_ptr<LinuxPane>& pane : app().panes) {
        if (!pane->session)
            continue;
        if (Ubiquitty::Terminal* term = pane->session->terminal()) {
            const auto hold = holdPaneModel(*pane);
            Ubiquitty::Runtime::seedOSC52Policy(*term, config);
            Ubiquitty::Runtime::seedSequenceGate(*term, config);
            // Re-seeded the way a reload must: the helper leaves `cursorStyle`
            // alone, so a DECSCUSR a running program sent still stands.
            Ubiquitty::Preferences::Effective::applyCursorPreferences(*term, config);
            Ubiquitty::Runtime::seedTekColorPreference(*term, config);
            term->ambiguousWidth = Ubiquitty::Unicode::Width::ambiguousWidthFromCells(Ubiquitty::Preferences::Effective::ambiguousWidth(config));
        }
    }
}

// Apply the window's current GTK scale factor (re-rasterize at the device cell on
// HiDPI). Defined below; forward-declared so onWindowMappedRelaxSize can apply the
// map-time scale (notify::scale-factor doesn't reliably fire for the initial map).
void onScaleFactorChanged(GObject*, GParamSpec*, gpointer);

void onWindowSurfaceSizeChanged(GObject*, GParamSpec*, gpointer)
{
    requestRepaint();
}

void onWindowRealized(GtkWidget* window, gpointer)
{
    if (GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(window))) {
        // Size notifications wake an idle frame clock without subscribing to
        // every layout pass. The weak object connection follows the window's
        // lifetime; unrealizing it destroys the source surface.
        g_signal_connect_object(surface, "notify::width", G_CALLBACK(onWindowSurfaceSizeChanged), window, G_CONNECT_DEFAULT);
        g_signal_connect_object(surface, "notify::height", G_CALLBACK(onWindowSurfaceSizeChanged), window, G_CONNECT_DEFAULT);
    }
}

// On first map: relax the launch-time grid size pin (see onActivate) so the user
// can resize below 80x24, and apply the now-resolved display scale — the map is
// the first point the window's scale_factor reflects its monitor.
void onWindowMappedRelaxSize(GtkWidget* window, gpointer picture)
{
    if (picture)
        gtk_widget_set_size_request(GTK_WIDGET(picture), -1, -1);
    onScaleFactorChanged(G_OBJECT(window), nullptr, nullptr);
    requestRepaint();
}

void onWindowUnmapped(GtkWidget*, gpointer)
{
    scheduleCaretBlink(nullptr);
    if (app().paneContainer && app().tickCallbackID != 0) {
        gtk_widget_remove_tick_callback(app().paneContainer, app().tickCallbackID);
        app().tickCallbackID = 0;
    }
    app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::OnDemand);
}

// OSC 52 clipboard client (the running program reads/writes the clipboard).
// Attached to the Ubiquitty::Terminal in onActivate.
// OSC 9;4 progress: per-pane bars drawn on the top edge of each visible pane,
// matching macOS. One full-area GtkOverlay child (above the grid) paints a thin
// bar at every pane picture's top, each fed by its own Ubiquitty::Terminal progress and tinted
// through the shared Core::ProgressIndicator policy (focused pane = accent,
// unfocused split pane = dimmed gray, error = red). A single (unsplit) pane is
// the degenerate case — one bar at the window top. app().progressPhase is the shared
// indeterminate comet position (0..1, advanced per frame while any pane spins).
// Monotonic tick of the last painted frame, for the SGR 5/6 text-blink repaint
// gate (Core::needsAnimationRedraw). Global because the blink phase is clock-
// based, shared across all panes.

// Make `pane` the focused pane (focus-follows-click): re-point activePane(), keep the
// focused-picture alias + the Workspace model in lockstep, repaint. A no-op when it
// is already focused. The previous + new panes both repaint (the in-grid cursor goes
// hollow/solid). Called at the top of the press/scroll handlers, which carry their
// pane as user_data; the handler bodies then read the now-correct activePane().
void focusPaneFromEvent(LinuxPane* pane)
{
    if (!pane || pane == activePane())
        return;
    app().model->focusPane(app().model->activeSurface(), paneIDForPane(pane));
    restartCaretBlink(false);
    if (app().window && gtk_window_is_active(GTK_WINDOW(app().window))) {
        pane->hasUnheardBell = false;
    }
    app().focusedPicture = pane->picture;
    updateWindowTitle();
    rebuildTabStrip();
    // A grab follows the FOCUSED pane; switching tabs/splits moves focus off
    // whichever pane held it, which this reconciles the same way a window
    // focus edge does.
    updatePointerLock();
    requestRepaint();
}
void onClipboardPasted(GObject* source, GAsyncResult* result, gpointer);

void pasteClipboard(GdkClipboard* clipboard, Ubiquitty::ClipboardBuffer buffer)
{
    std::string names;
    gsize count = 0;
    auto* formats = gdk_clipboard_get_formats(clipboard);
    const auto* types = gdk_content_formats_get_mime_types(formats, &count);
    for (gsize index = 0; index < count; ++index) {
        if (!names.empty())
            names += ' ';
        names += types[index];
    }
    if (gdk_content_formats_contain_gtype(formats, G_TYPE_STRING)
        && !gdk_content_formats_contain_mime_type(formats, "text/plain")) {
        if (!names.empty())
            names += ' ';
        names += "text/plain";
    }
    if (activePane()->session->sendPasteNotification(names, buffer)) {
        armPTYWriteDrain(activePane());
        return;
    }
    gdk_clipboard_read_text_async(clipboard, nullptr, onClipboardPasted, nullptr);
}

// Find bar (Ctrl+F): a GtkSearchBar over the portable Core ScrollSearch engine —
// the same engine the macOS find bar drives. The active match is shown by
// scrolling the viewport to it and handing its spans to the builder, which bakes
// the highlight into those cells: the same Core path, colour and ink every other
// frontend renders a match through.

// Process inspector (Ctrl+Shift+I): a window listing the PTY session's process
// tree, parity with the macOS Inspector. Lazily created; refreshed while shown.

// Forward decl: the key handler (Ctrl+Shift+C) copies before the selection
// section that defines it.
bool copySelectionToClipboard();
void selectAll(); // Ctrl+Shift+A — select the whole buffer (defined below)
bool openLinkAtCell(int row, int column, GdkModifierType state, int pressCount); // the press handler's link fallback (defined below)

// Clamp the ACTIVE PANE's viewport offset in place. The bound itself is
// `Screen::clampViewOffset`; distinct name because this one mutates a pane
// rather than returning a value, and a shared name makes the two
// indistinguishable to any tree-wide rename.
void clampActivePaneViewOffset(const Ubiquitty::Terminal* term)
{
    const auto hold = holdPaneModel(*activePane());
    activePane()->viewOffset = Ubiquitty::Screen::clampViewOffset(activePane()->viewOffset,
        term != nullptr ? Ubiquitty::Screen::scrollbackCount(term) : 0);
}

// The live window renders through the Vulkan GPU path (offscreen VkImage ->
// GdkMemoryTexture); it is byte-identical to the CPU SoftwareRenderer, which
// stays as a fallback if Vulkan init fails (e.g. no ICD).

// The real-font glyph raster (fontconfig + FreeType). Constructed once and
// shared by both the CPU SoftwareRenderer (via LinuxRaster) and the Vulkan glyph
// atlas, so their coverage stays byte-identical (the CPU<->GPU oracle). If
// FreeType/fontconfig init fails the rasterizer transparently falls back to
// Unifont, so the frontend always renders something. Selecting "GNU Unifont"
// skips it entirely (both paths use their own embedded-Unifont rasterizer) — a
// fallback knob + the pure-Unifont golden-image baseline check.

// CellGrid scale factor (device pixels per logical pixel), from the window's GTK
// scale_factor. 1 until the window maps on a HiDPI monitor — onScaleFactorChanged
// then re-rasterizes. The FreeType rasterizer is sized at deviceFontPixelSize()
// so glyphs are sharp at the device resolution, which means cellWidth()/cellHeight()
// are DEVICE pixels; the texture is rendered at that device resolution and GTK maps
// it 1:1 (no blurry upscale). Layout + pointer math instead use the LOGICAL cell.
float logicalCellWidth() { return app().rasterContext.cellWidth() / static_cast<float>(app().scale); }
float logicalCellHeight() { return app().rasterContext.cellHeight() / static_cast<float>(app().scale); }

bool publishPanePixelGeometry(LinuxPane& pane)
{
    Ubiquitty::Terminal* terminal = pane.session ? pane.session->terminal() : nullptr;
    if (!terminal) {
        return false;
    }
    const Ubiquitty::IntSize cell { app().rasterContext.cellWidth(), app().rasterContext.cellHeight() };
    const Ubiquitty::IntSize textArea { cell.width * pane.columns, cell.height * pane.rows };
    Ubiquitty::IntSize drawable = textArea;
    if (pane.picture) {
        const int width = gtk_widget_get_width(pane.picture);
        const int height = gtk_widget_get_height(pane.picture);
        if (width > 0 && height > 0) {
            drawable = { width * app().scale, height * app().scale };
        }
        drawable.width += (gtk_widget_get_margin_start(pane.picture) + gtk_widget_get_margin_end(pane.picture)) * app().scale;
        drawable.height += (gtk_widget_get_margin_top(pane.picture) + gtk_widget_get_margin_bottom(pane.picture)) * app().scale;
    }
    std::uint32_t epochBefore = 0;
    {
        const auto hold = holdPaneModel(pane);
        epochBefore = terminal->absoluteRowEpoch;
    }
    // The publisher asks the session, under the session's own lock.
    pane.session->noteViewportBeforeResize(&pane.selection, pane.viewOffset);
    const auto publication = pane.viewportPublisher.publish(*pane.session, { pane.columns, pane.rows }, { cell, textArea, drawable });
    // Only the actual owner may have repacked absolute rows, which leaves a
    // rectangle's columns, and the alternate screen's rows, meaningless; a
    // flowing selection on the primary screen follows its characters. A remote
    // report leaves the verified picture (and its selection) untouched until
    // its host replies.
    if (publication == Ubiquitty::Linux::ViewportPublication::Grid) {
        pane.viewOffset = pane.session->selectionViewportAfterResize(&pane.selection, pane.viewOffset);
        const auto hold = holdPaneModel(pane);
        if (Ubiquitty::Selection::dropSelectionAcrossResize(pane.selection.state, epochBefore, *terminal))
            requestRepaint();
    }
    return publication != Ubiquitty::Linux::ViewportPublication::Unchanged;
}

// Wraps the chosen font rasterizer so block/shade/quadrant/sextant codePoints
// render as cell-exact procedural coverage (gapless tiles) instead of seam-leaving
// font glyphs. Re-pointed at the live base on every currentRasterizer() call.

// The glyph rasterizer for the current mode: the real font (FreeType) unless the
// user toggled to Unifont, or FreeType is unavailable — wrapped in the box-drawing
// decorator. Both backends — the CPU SoftwareRenderer and the GPU VulkanGlyphAtlas
// — fault through the same instance, keeping their coverage byte-identical (the
// CPU<->GPU oracle) and giving both seam-free procedural box glyphs.
Ubiquitty::Rendering::GlyphRasterizer& currentRasterizer()
{
    Ubiquitty::Rendering::GlyphRasterizer* base;
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native && app().glyphRasterizer && app().glyphRasterizer->ready())
        base = &*app().glyphRasterizer;
    else
        base = &*app().unifontRasterizer;
    if (!app().boxRasterizer)
        app().boxRasterizer.emplace(*base);
    else
        app().boxRasterizer->setInner(*base);
    // A shade-style change is a typography change, so the sheets that baked
    // the old slots are rebuilt before the next fault reaches this.
    app().boxRasterizer->setShadeStyle(app().appliedRenderConfiguration.shadeStyle);
    return *app().boxRasterizer;
}

// Build the FreeType rasterizer once (so the runtime toggle can switch to it) and
// inject the initial-mode rasterizer into the CPU path. Idempotent.
//
// PRECEDENCE — font family/size: config [font] family/size override the built-in
// defaults (monospace, 16px), but the UBIQUITTY_FONT/UBIQUITTY_FONT_SIZE envs still
// win over config so they stay a live debugging knob. Net order, highest first:
//   env > config > default.
// Selecting family = "GNU Unifont" uses the embedded rasterizer; a
// FreeType/fontconfig initialization failure also uses it as the
// always-available fallback.
// Absolute path of the bundled Symbols Nerd Font fallback, which the build
// places next to the binary (CMake copy into the build dir; the AppImage stages
// it beside ubiquitty-linux) — located via readlink(/proc/self/exe), the same
// way VulkanRenderer locates its SPIR-V shaders. Empty if the path can't be
// resolved (the fallback face then degrades to absent → primary -> Unifont).
std::string bundledFallbackFontPath()
{
    const std::string directory = Ubiquitty::Linux::bundledFontDirectory();
    if (directory.empty())
        return std::string();
    return directory + "/SymbolsNerdFontMono-Regular.ttf";
}

// The bundled file a configured family selects, or empty when the family is not
// one this project ships — in which case fontconfig answers, which is the right
// route for a face the user installed themselves.
std::string bundledFontPathForFamily(std::string_view family)
{
    return Ubiquitty::Linux::bundledFontPath(family);
}

// GTK font DPI describes logical pixels per inch; the window scale converts
// logical pixels to backing pixels. Neither conversion may round the points.
int deviceFontPixelSize()
{
    return Ubiquitty::Linux::fontPixelSize(app().fontSizePoints, app().fontDPI, app().scale);
}

double deviceFontPixelsPerPoint()
{
    return Ubiquitty::Linux::fontPixelsPerPoint(app().fontDPI, app().scale);
}

void publishPaneTypography(LinuxPane& pane)
{
    if (!pane.session)
        return;
    const auto& configuration = app().rasterContext.renderConfiguration();
    const double zoom = configuration.fontSizePoints > 0 ? app().fontSizePoints / configuration.fontSizePoints : 1;
    const double size = Ubiquitty::Rendering::proportionalFacePointSize(app().fontSizePoints, configuration.proportionalFontSizePoints * zoom);
    const auto catalog = pane.richText.fontCatalog();
    pane.session->setFontCatalogProvider(catalog.function, catalog.context);
    pane.session->publishTypography(pane.richText.configure(app().fontFamily, configuration.proportionalFontFamily.string(),
        currentRasterizer().cellMetrics(), size, deviceFontPixelSize() / deviceFontPixelsPerPoint(), deviceFontPixelsPerPoint()));
}

bool capturePaneRichText(LinuxPane& pane, const Ubiquitty::Linux::CursorOverlay* cursor, int viewOffset,
    Ubiquitty::FloatPoint origin = {})
{
    Ubiquitty::Terminal* term = pane.session ? pane.session->terminal() : nullptr;
    if (!term)
        return false;
    const auto hold = holdPaneModel(pane);
    Ubiquitty::Rendering::CursorRenderState presented;
    app().rasterContext.fillCursorState(term, viewOffset, cursor, presented);
    // Only rich text needs the composite: a bar outside a block is GTK's caret,
    // which the grid's cursor tier draws. Keep one final capture after visible
    // blocks disappear so the retained rasters and selection quads clear.
    if (term->richTextBlocks.blocks(Ubiquitty::RichText::activeScreen(*term)).empty()
        && pane.richTextFrame.richTextQuads().empty())
        return false;
    Ubiquitty::Rendering::TerminalSnapshotOptions options;
    options.viewOffset = viewOffset;
    options.originInPixels = origin;
    options.drawCursor = presented.row >= 0;
    options.isFocused = presented.focused;
    options.cursorMixAlpha = presented.mixA;
    // The grid's frames name no platform selection colour, so they draw the
    // shared tint; the rich text frame resolves the same fill, or a block's
    // bands take a native wash the selected cells beside them do not.
    options.style.selectionStyle = app().rasterContext.renderConfiguration().selectionStyle;
    std::array<Ubiquitty::RichText::BlockSelection, Ubiquitty::RichText::maxBlocksPerScreen> selections {};
    options.richTextSelections = selections;
    options.richTextSelectionCount = Ubiquitty::Selection::blockSelections(pane.selection, *term, selections);
    Ubiquitty::Preferences::Effective::applyCursorSettings(options, app().rasterContext.renderConfiguration());
    options.toolkitCaret = app().rasterContext.toolkitCaret();
    Ubiquitty::Rendering::applyPointSpace(options, currentRasterizer().cellMetrics().cellHeight,
        deviceFontPixelsPerPoint(), app().rasterContext.renderConfiguration().lineSpacingPoints);
    return pane.richTextFrame.capture(*term, options, currentRasterizer().cellMetrics(), {});
}

// GTK's caret settings, read where GtkText reads them: the display's
// GtkSettings. The aspect ratio sizes the bar as GTK's insertion caret. With
// no display (a headless snapshot) the raster keeps GTK's own default.
void readToolkitCaretSettings()
{
    GtkSettings* settings = gtk_settings_get_default();
    if (!settings)
        return;
    double aspectRatio = 0.0;
    gboolean isBlinking = TRUE;
    int blinkTime = 0;
    int blinkTimeout = 0;
    g_object_get(settings, "gtk-cursor-aspect-ratio", &aspectRatio, "gtk-cursor-blink", &isBlinking, "gtk-cursor-blink-time", &blinkTime,
        "gtk-cursor-blink-timeout", &blinkTimeout, nullptr);
    app().rasterContext.setToolkitCaretAspectRatio(aspectRatio);
    app().toolkitBlink = {
        .isEnabled = isBlinking != FALSE,
        .periodMilliseconds = static_cast<std::uint32_t>(std::max(blinkTime, 0)),
        .timeoutSeconds = static_cast<std::uint32_t>(std::max(blinkTimeout, 0)),
    };
}

// GtkText's restarts. Input restarts the cycle half a period late and focus
// restarts it at once; both restart the timeout. A click only restarts the
// timeout, as GtkText's click gesture does.
void restartCaretBlink(bool isInput) // bool-ok: GtkText's pend (input) versus focus restart.
{
    const gint64 now = g_get_monotonic_time();
    app().caretInteractionMicros = now;
    app().caretBlinkCycleStartMicros = now + Ubiquitty::Cursor::Blink::toolkitBlinkDelayMicroseconds(app().toolkitBlink, isInput);
    requestRepaint();
}

void noteCaretInteraction()
{
    app().caretInteractionMicros = g_get_monotonic_time();
    requestRepaint();
}

// The focused cursor's blink at `now`, a GLib monotonic reading. The toolkit
// supplies its timeout; an explicit cursor rate still sets the period.
Ubiquitty::Cursor::Blink::ToolkitBlinkPhase caretBlinkPhase(const Ubiquitty::Terminal& term, gint64 now)
{
    if (!Ubiquitty::Cursor::isStyleBlinking(term) || term.windowFocused == 0
        || !app().window || !gtk_window_is_active(GTK_WINDOW(app().window)))
        return {};
    Ubiquitty::Cursor::Blink::ToolkitBlink blink = app().toolkitBlink;
    if (term.cursorBlinkPeriodMilliseconds != 0)
        blink.periodMilliseconds = term.cursorBlinkPeriodMilliseconds;
    return Ubiquitty::Cursor::Blink::toolkitBlinkPaintPhase(blink, now - app().caretBlinkCycleStartMicros, now - app().caretInteractionMicros);
}

double displayFontDPI()
{
    int setting = -1;
    if (GtkSettings* settings = gtk_settings_get_default())
        g_object_get(settings, "gtk-xft-dpi", &setting, nullptr);
    return Ubiquitty::Linux::fontDPIFromSettings(setting);
}

// The glyph-fallback face to name to fontconfig, or empty for the bundled one:
// the default family is the Symbols Nerd Font shipped next to the binary, which
// is loaded from its path because it need not be installed.
std::string linuxSymbolFallbackName(const Ubiquitty::Rendering::RenderConfiguration& configuration)
{
    const std::string_view family = configuration.symbolFallbackFamily.view();
    return family == Ubiquitty::Rendering::Font::FontFallbackPolicy::defaultSymbolFallbackFamily ? std::string() : std::string(family);
}

void setupFonts()
{
    if (app().areFontsSetUp)
        return;
    app().areFontsSetUp = true;

    const Ubiquitty::Preferences::Values& config = loadPreferences();
    const Ubiquitty::Rendering::RenderConfiguration configuration = Ubiquitty::Preferences::Effective::renderConfiguration(config);

    // Font family — fontconfig's "monospace" alias by default; config [font]
    // family overrides it (fc-matched, nearest installed face on a miss).
    std::string fontFamily = configuration.fontFamily.string();
    if (const char* fontEnvironment = std::getenv("UBIQUITTY_FONT"))
        fontFamily = fontEnvironment;
    const Ubiquitty::Rendering::FontRasterizerKind selectedRasterizerKind = Ubiquitty::Rendering::selectFontFamily(fontFamily).rasterizerKind;

    // Glyph-fallback font for code points the primary lacks (Nerd Font icons,
    // Powerline, symbols). config [font] symbol_fallback names a face; the
    // default family is the bundled Symbols Nerd Font shipped next to the
    // binary, which is reached by its path rather than by name.
    std::string fallbackFontName = linuxSymbolFallbackName(configuration);
    const std::string bundledFallbackPath = bundledFallbackFontPath();
    const std::string bundledPrimaryPath = bundledFontPathForFamily(fontFamily);

    // Font point size — 12pt (16px at 96 DPI) by default; config [font] size overrides it, and the
    // UBIQUITTY_FONT_SIZE env overrides config. The cell is DERIVED from the face at
    // this size (FreeTypeRasterizer::cellMetrics), so a larger size gives a
    // proportionally larger cell.
    // Held as points, not rounded here: the rounding belongs where the scale is
    // applied (`deviceFontPixelSize`), and doing it now would spend the
    // fraction before the display could express it.
    double fontSizePoints = 12.0;
    if (config.fontSize.has_value()) {
        const double parsed = configuration.fontSizePoints;
        if (parsed >= 4.0 && parsed <= 256.0)
            fontSizePoints = parsed;
    }
    if (const char* sizeEnv = std::getenv("UBIQUITTY_FONT_SIZE")) {
        // An override a person types on a command line, so it takes the same
        // fractional spelling the config key does.
        const double parsed = std::strtod(sizeEnv, nullptr);
        if (parsed >= 4.0 && parsed <= 256.0)
            fontSizePoints = parsed;
    }
    app().fontSizePoints = fontSizePoints;
    // The integer twin, for the zoom steps and the reset, which are whole
    // pixels. A fractional configured size resets to its nearest whole one.
    const int fontPixelSize = static_cast<int>(std::lround(fontSizePoints));
    app().fontPixelSize = fontPixelSize;
    app().defaultFontPixelSize = fontPixelSize;
    app().fontFamily = fontFamily;
    app().fallbackFontName = fallbackFontName;
    app().bundledFallbackPath = bundledFallbackPath;
    // Rasterize at the DEVICE size (logical * scale) so glyphs are sharp on HiDPI;
    // app().scale is 1 here (the window hasn't mapped) and bumped by onScaleFactorChanged.
    // line_spacing and character_spacing are configured in points; the
    // rasterizers work in device pixels, so both scale with the display like
    // the size does, and both faces are built from the one conversion.
    const Ubiquitty::Linux::FaceSpacing spacing = Ubiquitty::Linux::faceSpacing(configuration, deviceFontPixelsPerPoint());
    app().lineSpacingPixels = spacing.lineSpacingInPixels;
    app().trackingPixels = spacing.characterSpacingInPixels;
    // Weights are usWeightClass numbers and carry no unit, so no scale.
    app().uprightWeight = configuration.fontWeight;
    app().boldWeight = configuration.boldFontWeight;
    // A percent of normal, which is the unit the `wdth` axis is specified in,
    // so it reaches the face unscaled like the weights do.
    app().widthPercent = configuration.fontWidthPercent;
    // The axis list, unparsed: the grammar is Core's and the rasterizer reads it
    // once at construction. Kept as the specification rather than as resolved
    // settings so a re-emplace after a zoom carries what the user wrote.
    app().fontVariations = configuration.fontVariations.string();
    app().fontFeatures = configuration.fontFeatures.string();
    // Through the accessor rather than the field: `hasLigatures` is resolved
    // against the default there.
    app().ligatures = Ubiquitty::Preferences::Effective::ligatures(config)
        ? Ubiquitty::Linux::Ligatures::Enabled
        : Ubiquitty::Linux::Ligatures::Disabled;
    // The same spacing on the bitmap tier, so toggling the font moves neither
    // the rows nor the columns. The scale carries the size as well as the
    // display: Unifont's cell is a fixed 8x16 bitmap, so a configured size
    // larger than that is drawn by upscaling it.
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    Ubiquitty::Linux::emplaceBitmapFace(app().unifontRasterizer, app().fontSizePoints, deviceFontPixelsPerPoint(), spacing);
    app().glyphRasterizer.emplace(deviceFontPixelSize(), fontFamily, fallbackFontName, bundledFallbackPath, bundledPrimaryPath, app().scale, app().lineSpacingPixels, app().trackingPixels, app().uprightWeight, app().boldWeight, app().widthPercent, app().fontVariations, app().fontFeatures, app().ligatures, Ubiquitty::Preferences::buildFontRoutePreferences(config));
    Ubiquitty::Linux::configureFontRouting(deviceFontPixelSize(), config);
    // Font family selection owns the rasterizer choice. A failed native-font
    // load still falls back to the embedded rasterizer so text remains usable.
    app().fontRasterizerKind = selectedRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap || !app().glyphRasterizer->ready()
        ? Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap
        : Ubiquitty::Rendering::FontRasterizerKind::Native;
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    app().rasterContext.setEmbeddedBitmapScale(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap
            ? Ubiquitty::Rendering::unifontScaleForRequestedSize(app().fontSizePoints, deviceFontPixelsPerPoint())
            : 0);

    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        const char* why = selectedRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap ? "selected" : "FreeType/fontconfig init failed";
        g_print("ubiquitty-linux: glyph font = GNU Unifont (%s, 1-bit)\n", why);
    } else {
        const Ubiquitty::Rendering::CellMetrics m = app().glyphRasterizer->cellMetrics();
        g_print("ubiquitty-linux: glyph font = %s (FreeType AA, %gpt, %g DPI, %dpx, cell %dx%d)\n", app().glyphRasterizer->faceName(), app().fontSizePoints, app().fontDPI, deviceFontPixelSize(), static_cast<int>(m.cellWidth + 0.5f), static_cast<int>(m.cellHeight + 0.5f));
    }
}

// Re-inject the current-mode rasterizer into both backends and rebuild their glyph
// atlas / CPU renderer so a runtime font swap takes effect. The next onTick
// re-derives the grid from the new cell dims; app().isRepaintPending forces a redraw.
void applyFontMode()
{
    Ubiquitty::Rendering::GlyphRasterizer& chosen = currentRasterizer();
    app().rasterContext.setGlyphRasterizer(chosen);
    app().vulkan.setGlyphRasterizer(chosen);
    app().vulkan.setLigatureRasterizer(chosen);
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    for (const auto& pane : app().panes) {
        publishPaneTypography(*pane);
        publishPanePixelGeometry(*pane);
    }
    requestRepaint();
}

// Runtime font-size zoom (View menu Cmd+/Cmd-/Cmd-0 parity): re-emplace the FreeType
// rasterizer at the new pixel size and rebuild both backends; the next onTick
// re-derives each pane's grid from the new cell metrics. No-op in Unifont mode (a
// fixed bitmap) or when the size is unchanged. The clamp is single-sourced with
// macOS via Zoom::clampFontZoom (the shared font.size range).
void applyFontZoom(int newPixelSize)
{
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap)
        return;
    newPixelSize = Ubiquitty::Preferences::Zoom::clampFontZoom(newPixelSize);
    if (newPixelSize == app().fontPixelSize)
        return;
    app().fontPixelSize = newPixelSize;
    // A zoom step names a whole size, so it replaces the configured fraction
    // rather than riding on top of it — otherwise the first step from 15.5
    // would land on 15.5 again and read as a zoom that did nothing.
    app().fontSizePoints = newPixelSize;
    // Release every borrowed-face cache before replacing its owner.
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    app().glyphRasterizer.emplace(deviceFontPixelSize(), app().fontFamily, app().fallbackFontName, app().bundledFallbackPath, bundledFontPathForFamily(app().fontFamily), app().scale, app().lineSpacingPixels, app().trackingPixels, app().uprightWeight, app().boldWeight, app().widthPercent, app().fontVariations, app().fontFeatures, app().ligatures, Ubiquitty::Preferences::buildFontRoutePreferences(loadPreferences()));
    applyFontMode();
}

// HiDPI: the window moved to a monitor with a different scale (initial map on a
// HiDPI display, or an RDP/monitor change). Re-rasterize the FreeType face at the
// new device size (deviceFontPixelSize()) and rebuild both glyph backends, so the
// texture is produced at device resolution and renders crisp instead of upscaled.
// DPI changes also rebuild spacing, fallback routing and the bitmap face.
void rebuildFontsFromPreferences();

void onScaleFactorChanged(GObject*, GParamSpec*, gpointer)
{
    const int newScale = app().window ? gtk_widget_get_scale_factor(app().window) : 1;
    const double newDPI = displayFontDPI();
    if (newScale < 1 || (newScale == app().scale && newDPI == app().fontDPI))
        return;
    app().scale = newScale;
    app().fontDPI = newDPI;
    app().rasterContext.setDeviceScale(newScale);
    if (app().areFontsSetUp) {
        rebuildFontsFromPreferences();
        const Ubiquitty::Rendering::CellMetrics m = currentRasterizer().cellMetrics();
        g_print("ubiquitty-linux: display scale = %dx → rasterizing at %dpx (device cell %dx%d)\n", app().scale, deviceFontPixelSize(), static_cast<int>(m.cellWidth + 0.5f), static_cast<int>(m.cellHeight + 0.5f));
    }
    for (const auto& pane : app().panes) {
        publishPanePixelGeometry(*pane);
    }
    requestRepaint();
}

// The model is touched only on the GTK main thread, so locking is a no-op;
// a completed DECSET-2026 sync frame just marks the view dirty.

// The leading title segment policy (the working directory rendered per the
// [title] Path option) lives in the shared Title::titleDirectorySegment so
// macOS and Linux agree byte-for-byte; this file-local alias keeps the call
// sites short. home/~ are platform-resolved at the call sites and passed in.
using Ubiquitty::Title::titleDirectorySegment;

// One pane's title facts, gathered for App::composeTitle: the program's title,
// its status label, the grid and how the session ended, and, only where the
// composition asks for them, Core's cached directory and process chain.
// Which parts show, their order, the join and the fallback are
// Core's; this gathers and nothing else.
Ubiquitty::App::PaneTitleFacts paneTitleFacts(LinuxPane& pane, const Ubiquitty::Preferences::Effective::TitleComposition& composition)
{
    Ubiquitty::App::PaneTitleFacts facts;
    facts.end = pane.session->sessionEnd();
    Ubiquitty::Terminal* term = pane.session->terminal();
    const auto hold = holdPaneModel(pane);
    if (term != nullptr) {
        facts.programTitle = term->titleUTF8;
        const std::string activityLabel = Ubiquitty::App::programActivityLabel(term->programStatus);
        facts.programStatus = activityLabel.empty() ? std::string(Ubiquitty::tabStatusText(term)) : activityLabel;
        facts.columns = term->columns;
        facts.rows = term->rows;
    }
    if (composition.showsDirectory) {
        const char* home = std::getenv("HOME");
        // The title's directory, not the pane's: under a plain ssh the
        // pane's is the local client's folder, which the session has left.
        facts.currentDirectory = pane.session->titleDirectory();
        facts.homeDirectory = home != nullptr ? home : "";
    }
    if (composition.showsProcess) {
        facts.processChain = pane.session->processChain();
        facts.processChainWithArguments = pane.session->processChainWithArguments();
    }
    return facts;
}

// What this frontend adds to a pane's facts when it composes a title. A GTK
// window title is one string: nothing draws a component beside it.
Ubiquitty::App::TitleViewerFacts titleViewerFacts(std::string fallbackName)
{
    Ubiquitty::App::TitleViewerFacts viewer;
    viewer.windowTitleForm = Ubiquitty::App::WindowTitleForm::PlainText;
    viewer.fallbackName = std::move(fallbackName);
    return viewer;
}

// The window title, composed by Core from the active pane's facts under the
// reader's window composition. set_title only on an actual change (the
// periodic refresh + the OSC path both call this).
void updateWindowTitle()
{
    if (!app().window)
        return;
    if (!activePane()->session->terminal())
        return;
    const Ubiquitty::Preferences::Effective::TitleComposition composition = Ubiquitty::Preferences::Effective::windowTitleComposition(loadPreferences());
    std::string title = Ubiquitty::App::composeTitle(paneTitleFacts(*activePane(), composition), titleViewerFacts("Ubiquitty (Linux)"), composition, Ubiquitty::Session::TitleSurface::Window).title;
    if (activePane()->hasUnheardBell) {
        title = "🔔 " + title;
    }
    const char* resolved = title.c_str();
    if (app().lastTitle != resolved) {
        app().lastTitle = resolved;
        gtk_window_set_title(GTK_WINDOW(app().window), resolved);
    }
}

// Refresh the title when the drain flagged an OSC 0/2 change (folded in as the
// [osc] segment by updateWindowTitle). The Terminal's latch is consumed by
// TerminalRuntime::finishDrainPass into DrainOutcome.titleChanged; the [osc]
// segment itself reads titleUTF8, so a background pane's dropped event is
// re-resolved from state on tab switch or the periodic rebuild.
void applyWindowTitle(bool titleChanged)
{
    if (!titleChanged)
        return;
    updateWindowTitle();
}

// One drain pass for a specific pane: pump available host bytes into its Core,
// cache the modes the key + pointer paths read. A background pane fully advances
// its Terminal/scrollback; the VISIBLE side-effects (the single texture's dirty flag +
// the window title) fire only when this is the focused pane — that gate is the
// single-texture invariant.
// Scrolled-back viewport policy on each drain: hold the viewed rows in place as
// the tail grows (reading or selecting from history), unless the Core's DEC-1010
// scroll-on-output policy (shouldSnapToTail) snaps the view back to the live
// tail. The decision and the compensation are Core's (Input::viewportAfterOutput),
// so the three frontends cannot disagree about when a scrolled-back view snaps.
// Runs per pane, not just the focused one, so a background tab's scrollback
// read survives its own drain.
void followTailOrHoldViewport(LinuxPane& pane, const Ubiquitty::Screen::HistoryFacts& history)
{
    // Core decides and Core compensates. This frontend supplies the facts it
    // owns -- where the view sits, and what the drain handed it -- and applies
    // the verdict.
    const Ubiquitty::Selection::OutputUpdate output = pane.session->updateSelectionAfterOutput(&pane.selection, pane.viewOffset, history);
    pane.viewOffset = static_cast<int>(output.viewport.viewOffset);
}

void scheduleHeldFrame(LinuxPane& pane);

// The held-frame timer: the program went quiet, so no byte will ask the
// coherence rule again for the frame it held at the drain's end.
gboolean onHeldFrameDue(gpointer user)
{
    auto* pane = static_cast<LinuxPane*>(user);
    pane->heldFrameSource = 0;
    scheduleHeldFrame(*pane);
    if (pane == activePane())
        requestRepaint();
    return G_SOURCE_REMOVE;
}

// Asks the rule for a frame it holds and arms the timer for when it may answer
// differently. Rearmed on every drain, since a drain can bring the answer
// closer than the armed one.
void scheduleHeldFrame(LinuxPane& pane)
{
    if (pane.heldFrameSource != 0) {
        g_source_remove(pane.heldFrameSource);
        pane.heldFrameSource = 0;
    }
    // The loop asks the coherence rule itself; this timer is the inline
    // drain's substitute for a thread that keeps asking.
    if (!pane.session || pane.isIngesting)
        return;
    if (const std::optional<std::uint64_t> due = pane.session->publishHeldFrameIfDue()) {
        const guint milliseconds = static_cast<guint>(std::clamp<std::uint64_t>((*due + 999) / 1000, 1, G_MAXUINT));
        pane.heldFrameSource = g_timeout_add(milliseconds, onHeldFrameDue, &pane);
    }
}

void removeHeldFrameTimer(LinuxPane& pane)
{
    if (pane.heldFrameSource != 0) {
        g_source_remove(pane.heldFrameSource);
        pane.heldFrameSource = 0;
    }
}

Ubiquitty::Runtime::DrainOutcome drainPane(LinuxPane& pane)
{
    const Ubiquitty::Runtime::DrainOutcome outputBuffer = pane.session->drain();
    if (!outputBuffer.reachedEnd)
        scheduleHeldFrame(pane);
    pane.modes = outputBuffer.modes;
    pane.mouseModes = outputBuffer;
    PaneDelivery delivery;
    delivery.didOutputArrive = outputBuffer.bytesDrained > 0;
    delivery.bell = {
        .mode = outputBuffer.bell,
        .shouldPopWindow = outputBuffer.popOnBell,
        .shouldRaiseUrgency = outputBuffer.bellRaisesUrgency,
        .shouldNotify = outputBuffer.bellWantsNotification,
    };
    delivery.bellsRung = outputBuffer.bellsRung;
    delivery.didTitleChange = outputBuffer.titleChanged;
    delivery.didDirectoryChange = outputBuffer.currentDirectoryChanged;
    delivery.didProcessStateChange = outputBuffer.processStateChanged;
    delivery.didExit = outputBuffer.reachedEnd;
    delivery.history = outputBuffer.history;
    noteEventFlags(delivery, pane.session->takeEventFlags());
    applyPaneDelivery(pane, delivery);
    return outputBuffer;
}

// Reacts to one delivery on this thread: the title and the strip, the bell,
// the viewport policy, the queued seams, the frame. The inline drain and the
// ingest hop both end here, so the two paths cannot disagree about what a
// delivery means.
void applyPaneDelivery(LinuxPane& pane, const PaneDelivery& delivery)
{
    // A bell plays for the pane whose route rang it, in the cue Core resolved.
    const bool didBellRing = delivery.bellsRung > 0 && delivery.bell.mode != Ubiquitty::BellMode::Off;
    if (didBellRing) {
        const bool isForeground = &pane == activePane() && app().window && gtk_window_is_active(GTK_WINDOW(app().window));
        pane.hasUnheardBell = pane.hasUnheardBell || Ubiquitty::Runtime::doesBellMarkUnheard(isForeground);
        ringBell(delivery.bell);
    }
    if (delivery.didTabStatusChange || didBellRing) {
        updateWindowTitle();
        rebuildTabStrip();
    }
    const auto elapsedSince = [](std::uint32_t startMicros) {
        return static_cast<double>(static_cast<std::uint32_t>(Ubiquitty::PAL::monotonicMicros() - startMicros)) / 1e6;
    };
    std::uint32_t partStartMicros = Ubiquitty::PAL::monotonicMicros();
    if (delivery.didOutputArrive)
        followTailOrHoldViewport(pane, delivery.history);
    app().perfWindow.hopFollowSeconds += elapsedSince(partStartMicros);
    partStartMicros = Ubiquitty::PAL::monotonicMicros();
    servicePaneQueues(pane, delivery);
    app().perfWindow.hopQueuesSeconds += elapsedSince(partStartMicros);
    if (delivery.didProgressChange)
        updateProgressBar();
    if (delivery.didSearchChange) {
        showSearchOutcome(pane, pane.session->searchStatus());
        if (app().beamFindPane.get() == &pane)
            refreshBeamFindScope();
        requestRepaint();
    }
    if (&pane == activePane()) {
        if (delivery.didOutputArrive)
            requestRepaint();
        partStartMicros = Ubiquitty::PAL::monotonicMicros();
        applyWindowTitle(delivery.didTitleChange || delivery.didDirectoryChange || delivery.didProcessStateChange);
        app().perfWindow.hopTitleSeconds += elapsedSince(partStartMicros);
        // The delivery that carried \e[?7403h/l is this arm's snapshot
        // equivalent: the mode is read back from the session here.
        if (delivery.shouldReconcilePointerLock) {
            partStartMicros = Ubiquitty::PAL::monotonicMicros();
            updatePointerLock();
            app().perfWindow.hopPointerSeconds += elapsedSince(partStartMicros);
        }
    }
}

// Event producers post with a weak pane reference. Delivery is queued even
// when an inline parser signals on the GTK thread, so it cannot reenter the
// model operation that raised the event. Unregister waits for active signals
// before the pane can be destroyed.
gboolean onIngestEventsDue(gpointer data)
{
    const auto& weak = *static_cast<Ubiquitty::WeakPtr<LinuxPane>*>(data);
    if (LinuxPane* pane = weak.get(); pane && pane->session)
        serviceIngestEvents(*pane);
    return G_SOURCE_REMOVE;
}

void onIngestDrainSignal(void* context)
{
    auto* pane = static_cast<LinuxPane*>(context);
    auto hop = std::make_unique<Ubiquitty::WeakPtr<LinuxPane>>(pane->weakPtr());
    g_idle_add_full(G_PRIORITY_DEFAULT, onIngestEventsDue, hop.release(),
        [](gpointer data) { delete static_cast<Ubiquitty::WeakPtr<LinuxPane>*>(data); });
}

// What the event producers delivered, read on this thread: the flags say what
// happened, the snapshot says what the modes are now. The snapshot is the
// published copy the drain refreshes, so the modes and the mouse flags cost
// no lock here, exactly as the Swift arm reads them.
void serviceIngestEvents(LinuxPane& pane)
{
    using Ubiquitty::Runtime::EventKind;
    const std::uint32_t hopStartMicros = Ubiquitty::PAL::monotonicMicros();
    const std::uint32_t events = pane.session->takeEventFlags();
    app().perfWindow.hopFlagsSeconds += static_cast<double>(static_cast<std::uint32_t>(Ubiquitty::PAL::monotonicMicros() - hopStartMicros)) / 1e6;
    const auto has = [events](EventKind kind) { return (events & (1u << static_cast<unsigned>(kind))) != 0; };
    const Ubiquitty::Runtime::RuntimeSnapshot snapshot = pane.session->readSnapshot();
    pane.modes = snapshot.modes;
    pane.mouseModes.mouseReportsActive = snapshot.mouseReportsActive;
    pane.mouseModes.mouseMotionReportsActive = snapshot.mouseMotionReportsActive;
    pane.mouseModes.mouseAnyEventActive = snapshot.mouseAnyEventActive;
    pane.mouseModes.mouseHiliteActive = snapshot.mouseHiliteActive;
    pane.mouseModes.mouseSGRPixelsActive = snapshot.mouseSGRPixelsActive;
    PaneDelivery delivery;
    if (has(EventKind::Bell))
        delivery.bell = pane.session->lastBellCue();
    delivery.bellsRung = pane.session->takeBellsRung();
    delivery.didTitleChange = has(EventKind::TitleChanged);
    delivery.didDirectoryChange = has(EventKind::DirectoryChanged);
    delivery.didProcessStateChange = has(EventKind::ProcessStateChanged);
    delivery.didProgressChange = has(EventKind::ProgressChanged);
    delivery.didExit = has(EventKind::Exited);
    delivery.history = snapshot.history;
    delivery.shouldReconcilePointerLock = snapshot.mouseRelativePointerLockActive != pane.hasPointerLockMode;
    pane.hasPointerLockMode = snapshot.mouseRelativePointerLockActive;
    noteEventFlags(delivery, events);
    // An application-requested pointer shape lands without waiting for the
    // next motion, so a program that sets a wait cursor and then works shows
    // it at once; the hover path's cached shape follows so the next motion
    // compares against what is on screen.
    if (&pane == activePane() && app().focusedPicture && snapshot.isAppPointerShapeSet
        && snapshot.appRequestedPointerShape != app().hoverCursorShape) {
        gtk_widget_set_cursor_from_name(app().focusedPicture, cursorNameForShape(snapshot.appRequestedPointerShape));
        app().hoverCursorShape = snapshot.appRequestedPointerShape;
    }
    applyPaneDelivery(pane, delivery);
    ++app().perfWindow.hops;
    app().perfWindow.hopSeconds += static_cast<double>(static_cast<std::uint32_t>(Ubiquitty::PAL::monotonicMicros() - hopStartMicros)) / 1e6;
    if (delivery.didExit)
        closePaneTab(&pane); // may destroy the pane: nothing after this
}

// Starts Core's ingest thread for a window pane, or leaves it inline when the
// session's transport cannot be polled — a remote attachment, say.
void beginPaneIngest(LinuxPane& pane)
{
    if (pane.isIngesting || !pane.session)
        return;
    pane.session->setDrainSignal(&pane, onIngestDrainSignal);
    if (isPerfLogEnabled())
        pane.session->startTallyingPerfDrains();
    // A newly launched pane has no rooted picture or frame clock yet. Give
    // the adaptive driver a rate before the ingest thread starts: without it,
    // its conservative unknown-rate answer requests a frame on every tick
    // even after output stops. The tick replaces this fallback with GTK's rate.
    pane.session->setPresentationFrameIntervalSeconds(cursorPresentationInterval(pane.picture));
    // The drain's screen-change rate decides between continuous and
    // on-demand presentation; the tick reads the recommendation.
    pane.session->setAdaptivePresentation(Ubiquitty::Runtime::AdaptiveDrive::On);
    pane.isIngesting = pane.session->startIngest();
}

// Stops the pane's ingest thread before anything the thread reaches dies:
// the drain signal names the pane, and the model closes the session next.
void endPaneIngest(LinuxPane& pane)
{
    if (!pane.session)
        return;
    pane.isIngesting = false;
    pane.session->stopIngest();
    pane.session->setDrainSignal(nullptr, nullptr);
}

// Periodic title refresh: the foreground process + working directory change with
// no byte traffic (running a command, `cd`), so poll them off a timer and rebuild
// the title (updateWindowTitle only calls set_title on a real change). The OSC
// segment is refreshed eagerly by applyWindowTitle on each drain.
gboolean onTitleRefresh(gpointer)
{
    for (const auto& pane : app().panes)
        (void)pane->session->sampleProcessStateOffDrain();
    updateWindowTitle();
    // Track background tabs' foreground process/directory in their labels (skip the common
    // single-tab case — the strip is hidden then).
    if (app().model->tabCount(app().model->activeSurface()) > 1)
        rebuildTabStrip();
    return G_SOURCE_CONTINUE;
}

// Resolve this frame's cursor look from the Terminal (DECSCUSR shape, the blink, and
// the window-focus state) via the shared Cursor::resolve policy.
// Both render paths consume it through fillCursorState, so the focused-block tier
// + the bar/underline/hollow overlay land identically (the CPU<->GPU oracle). In
// a scrolled-back view the cursor is suppressed downstream (viewOffset > 0).
Ubiquitty::Linux::CursorOverlay resolveCursorOverlay(const Ubiquitty::Terminal* term)
{
    Ubiquitty::Linux::CursorOverlay cursor;
    const Ubiquitty::Cursor::RenderState state = Ubiquitty::Cursor::resolveAppearance(term, Ubiquitty::PAL::monotonicTicks().count);
    cursor.visible = term != nullptr && term->modes.isCursorVisible != 0;
    cursor.shape = state.shape;
    cursor.blinkAlpha = state.blinkAlpha;
    cursor.focused = term != nullptr && term->windowFocused != 0;
    // All three shapes follow GTK's blink setting and idle timeout. The
    // bounded paint phase keeps each fade below the display's refresh rate.
    if (term)
        cursor.blinkAlpha = caretBlinkPhase(*term, g_get_monotonic_time()).alpha;
    return cursor;
}

// Wakes the focused cursor at its next opacity step. A one-shot repaint does
// not extend the output-activity clock, so the frame callback can disarm
// between steps and after GTK's blink timeout.
void scheduleCaretBlink(const Ubiquitty::Terminal* term)
{
    if (app().caretBlinkSource != 0) {
        g_source_remove(app().caretBlinkSource);
        app().caretBlinkSource = 0;
    }
    if (!term || !term->modes.isCursorVisible || !app().window || !gtk_widget_get_mapped(app().window)
        || !gtk_window_is_active(GTK_WINDOW(app().window)) || activePane()->viewOffset != 0)
        return;
    const std::int64_t microseconds = caretBlinkPhase(*term, g_get_monotonic_time()).microsecondsUntilChange;
    if (microseconds <= 0)
        return;
    const guint milliseconds = static_cast<guint>(std::clamp<std::int64_t>((microseconds + 999) / 1000, 1, 60000));
    app().caretBlinkSource = g_timeout_add(milliseconds, [](gpointer) -> gboolean {
        app().caretBlinkSource = 0;
        requestRepaint(RepaintCause::CursorStep);
        return G_SOURCE_REMOVE; }, nullptr);
}

Ubiquitty::Linux::CursorOverlay resolvePresentedCursorOverlay(LinuxPane& pane, double nowSeconds, double intervalSeconds)
{
    const Ubiquitty::Terminal* term = pane.session ? pane.session->terminal() : nullptr;
    const auto hold = holdPaneModel(pane);
    Ubiquitty::Linux::CursorOverlay cursor = resolveCursorOverlay(term);
    Ubiquitty::Linux::CursorOverlay candidate = cursor;
    candidate.visible = true;
    Ubiquitty::Rendering::CursorPresentation::Frame frame;
    app().rasterContext.fillCursorState(term, pane.viewOffset, &candidate, frame.cursor);
    frame.isEligible = frame.cursor.row >= 0;
    frame.isProgramVisible = cursor.visible;
    if (term) {
        frame.geometry.rows = term->rows;
        frame.geometry.columns = term->columns;
        frame.geometry.viewOffset = pane.viewOffset;
        frame.geometry.cellWidth = static_cast<float>(app().rasterContext.cellWidth());
        frame.geometry.cellHeight = static_cast<float>(app().rasterContext.cellHeight());
        frame.geometry.viewportWidth = static_cast<float>(term->columns) * frame.geometry.cellWidth;
        frame.geometry.viewportHeight = static_cast<float>(term->rows) * frame.geometry.cellHeight;
        frame.geometry.isAlternateActive = term->screens.isUsingAlternateScreen;
        frame.geometry.hasStatusLineOnBottomRow = pane.viewOffset == 0 && term->statusLineType != 0;
    }
    Ubiquitty::Rendering::CursorRenderState presented = pane.cursorPresentation.update(frame, nowSeconds, intervalSeconds, false);
    if (term && presented.row >= 0 && presented.row < term->rows) {
        presented.lineAttribute = Ubiquitty::Screen::rowLineAttribute(term, Ubiquitty::Screen::scrollbackCount(term) + presented.row);
    }
    cursor.presentation = presented;
    return cursor;
}

gboolean onCursorPresentationDue(gpointer user)
{
    auto* pane = static_cast<LinuxPane*>(user);
    pane->cursorPresentationSource = 0;
    if (pane->picture && gtk_widget_get_mapped(pane->picture)) {
        requestRepaint();
    }
    return G_SOURCE_REMOVE;
}

void scheduleCursorPresentation(LinuxPane& pane, double nowSeconds)
{
    if (pane.cursorPresentationSource != 0) {
        g_source_remove(pane.cursorPresentationSource);
        pane.cursorPresentationSource = 0;
    }
    const double deadline = pane.cursorPresentation.deadlineSeconds();
    if (deadline == 0) {
        return;
    }
    const guint milliseconds = static_cast<guint>(std::clamp(std::ceil((deadline - nowSeconds) * 1000.0), 1.0, 1000.0));
    pane.cursorPresentationSource = g_timeout_add(milliseconds, onCursorPresentationDue, &pane);
}

double cursorPresentationInterval(GtkWidget* picture)
{
    gint64 intervalMicroseconds = 0;
    if (picture) {
        if (GdkFrameClock* clock = gtk_widget_get_frame_clock(picture))
            gdk_frame_clock_get_refresh_info(clock, 0, &intervalMicroseconds, nullptr);
    }
    return intervalMicroseconds > 0 ? static_cast<double>(intervalMicroseconds) / 1e6 : 1.0 / 60.0;
}

void updateIMCursorLocation(Ubiquitty::CellPosition cursor); // defined with the IME handlers below

// ---- Beam -------------------------------------------------------------------
//
// The palette is per WINDOW, like the tab strip: one session, drawn over the
// focused pane. Everything it knows how to do is portable — BeamSession ranks,
// BeamLayout draws, BeamKey decides who owns a keystroke — so this file only
// supplies the command list and runs what comes back.

namespace {

// The theme drill's command id. A drill's option index is the theme index, so
// picking one applies it here rather than round-tripping through the caller.
constexpr const char* beamThemeCommandID = "beam.theme";

// The live theme, which is not the configured one once Beam has changed it.
// Seeded from [appearance] at startup so the drill opens with the running theme
// ticked rather than the first in the list.

// Every installed theme, in registry order — the drill's option index is the
// registry index, so nothing has to map between the two.
std::vector<Ubiquitty::CommandPalette::PaletteOption> themeOptionLabels()
{
    std::vector<Ubiquitty::CommandPalette::PaletteOption> options;
    const int count = Ubiquitty::Themes::count();
    options.reserve(static_cast<std::size_t>(count > 0 ? count : 0));
    for (int i = 0; i < count; ++i) {
        const Ubiquitty::Themes::Theme* theme = Ubiquitty::Themes::get(i);
        options.push_back(Ubiquitty::CommandPalette::PaletteOption { theme && theme->name ? theme->name : "" });
    }
    return options;
}

// Paint the window chrome — the background behind the grid's padding and the
// GtkHeaderBar that replaces the system title bar — in a theme's colours.
//
// Called for every theme the window takes, not only the one it launched on. The
// chrome carries theme colours as much as the grid does, so a change that
// repaints the panes and not this leaves a title bar and a padding border in the
// colours of a theme that is no longer anywhere else on screen, and nothing
// downstream re-derives them.
//
// A translucent window has no themed chrome to paint: its widgets are
// transparent so the compositor shows the desktop through, and an opaque
// background installed here would fill in exactly what that asks to see through.
void applyChromeTheme(int index)
{
    const Ubiquitty::Themes::Theme* theme = index >= 0 ? Ubiquitty::Themes::get(index) : nullptr;
    if (!theme || app().rasterContext.backgroundOpacity() < 1.0f)
        return;

    // One provider for the process, reloaded rather than replaced. A provider is
    // added to the display for as long as the display lives, so minting a fresh
    // one per theme change stacks every theme the window has ever worn and
    // leaves only the last of them readable.
    static GtkCssProvider* provider = nullptr;
    if (!provider) {
        provider = gtk_css_provider_new();
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    const Ubiquitty::ColorRGBA bg = theme->defaultBackground;
    const Ubiquitty::ColorRGBA fg = theme->defaultForeground;
    char css[2048];
    g_snprintf(css, sizeof(css),
        "@define-color ubiquitty_background #%02x%02x%02x;"
        "@define-color ubiquitty_foreground #%02x%02x%02x;"
        ".ubiquitty-themed-bg { background-color: #%02x%02x%02x; }"
        " headerbar.ubiquitty-titlebar {"
        " background: #%02x%02x%02x; color: #%02x%02x%02x;"
        " box-shadow: none; border: none; }"
        // Recolour the window-control button icons (symbolic) so close/min/max
        // track the theme foreground on the themed bar.
        " headerbar.ubiquitty-titlebar button { color: #%02x%02x%02x; }"
        " .ubiquitty-tabs { background: @ubiquitty_background; color: @ubiquitty_foreground;"
        " padding: 4px 8px; border-bottom: 1px solid alpha(@ubiquitty_foreground, 0.12); }"
        " .ubiquitty-tabs button { background: transparent; color: inherit; box-shadow: none;"
        " border: 1px solid transparent; border-radius: 6px; padding: 4px 10px; min-height: 26px; }"
        " .ubiquitty-tabs button:hover { background: alpha(@ubiquitty_foreground, 0.08); }"
        " .ubiquitty-tabs button:checked { background: alpha(@ubiquitty_foreground, 0.12);"
        " border-bottom-color: @ubiquitty_foreground; }"
        " .ubiquitty-tabs button:focus-visible { outline: 2px solid @ubiquitty_foreground; outline-offset: -2px; }"
        " .ubiquitty-tabs popover contents { background: @ubiquitty_background; color: @ubiquitty_foreground; }",
        bg.red, bg.green, bg.blue, fg.red, fg.green, fg.blue,
        bg.red, bg.green, bg.blue, bg.red, bg.green, bg.blue, fg.red, fg.green, fg.blue, fg.red, fg.green, fg.blue);
    gtk_css_provider_load_from_string(provider, css);
}

// Apply a theme to every pane, not just the focused one. Each pane owns its own
// Terminal and renders straight from `term->palette`, so theming only the front
// one leaves the others on the previous colours until they happen to be
// re-themed — visible the moment the user switches tabs.
void applyThemeToAllPanes(int index)
{
    const Ubiquitty::Themes::Theme* theme = index >= 0 ? Ubiquitty::Themes::get(index) : nullptr;
    if (!theme)
        return;
    app().liveThemeIndex = index;
    applyChromeTheme(index);
    for (const std::unique_ptr<LinuxPane>& pane : app().panes) {
        if (!pane)
            continue;
        if (Ubiquitty::Terminal* term = pane->session->terminal()) {
            const auto hold = holdPaneModel(*pane);
            (void)Ubiquitty::Themes::applyThemeToTerminal(*term, index);
        }
    }
}

// Actions Beam offers, derived from Core's named-action catalog rather than
// written out again. That catalog is already the source of truth for [keys] and
// the preferences UI, so a command listed here is one this frontend can
// genuinely run, and adding an action to Core makes it appear in every
// frontend's palette without a second edit.
//
// Two are dropped rather than listed:
//   toggle_beam  — you are looking at it.
//   new_window   — executeBindingAction leaves it unhandled on Linux, and a
//                  palette entry that does nothing is worse than an absent one.
Ubiquitty::CommandPalette::PaletteCommandList beamCommands()
{
    using namespace Ubiquitty;
    CommandPalette::PaletteCommandList commands;
    int count = 0;
    const Input::NamedActionEntry* entries = Input::namedActionCatalog(count);
    for (int i = 0; i < count; ++i) {
        const std::string token = entries[i].token;
        if (token == "toggle_beam" || token == "new_window")
            continue;
        CommandPalette::PaletteCommand command;
        command.id = token;
        command.title = entries[i].label;
        commands.push_back(std::move(command));
    }

    // Themes are a drill, matching the browser frontend: the values are the
    // installed theme names and the chosen index applies straight to the palette.
    CommandPalette::PaletteCommand theme;
    theme.id = beamThemeCommandID;
    theme.title = "Change Theme";
    theme.group = "Appearance";
    theme.kind = CommandPalette::CommandKind::DrillOptions;
    theme.keywords = { "colors", "colour", "scheme", "appearance" };
    commands.push_back(std::move(theme));
    return commands;
}

// What a GoTo row's command id begins with, the tab or pane it names spelled
// after it. Two prefixes rather than one with a discriminator, because the two
// destinations are reached by different verbs — a tab through `switchToTab`,
// which remembers which of its panes held focus, and a pane through the focus
// path a click takes, which does not change tab.
//
// Neither may be a string `parseAction` accepts, for the reason the block prefix
// carries: an id it resolved by accident would run an action the user never
// picked, and one it rejected would leave the row inert.
constexpr const char* beamGoToTabIDPrefix = "beam.goto.tab.";
constexpr const char* beamGoToPaneIDPrefix = "beam.goto.pane.";

// Every tab in the active surface, and every pane in the active tab — the ':'
// scope.
//
// Tabs are listed whatever their number, including when there is one. A palette
// whose scope appears only above two tabs has contents that depend on state the
// prompt does not show, and the row costs a line.
//
// Panes are the ACTIVE tab's only. A pane in another tab is reachable, but
// focusing it would have to switch tab first, and a row that silently does two
// things is worse than the two rows that do them: the tab row above already
// moves there, and the panes it holds are listed once it is active.
//
// The current one in each list wears its state in the group rather than the
// title, so a query ranked against the title never matches on the marker.
Ubiquitty::CommandPalette::PaletteCommandList beamGoToCommands()
{
    using namespace Ubiquitty;
    CommandPalette::PaletteCommandList commands;
    if (app().model == nullptr)
        return commands;

    const SurfaceID surface = app().model->activeSurface();
    const TabID activeTab = app().model->activeTab(surface);
    const int tabCount = app().model->tabCount(surface);
    for (int i = 0; i < tabCount; ++i) {
        const TabID tab = app().model->tabAt(surface, i);
        const Panes::Tree* tree = app().model->paneTree(surface, tab);
        const PaneID paneID = tree != nullptr ? static_cast<PaneID>(tree->focusedPaneID()) : invalidPane;
        LinuxPane* pane = paneForID(paneID);
        CommandPalette::PaletteCommand command;
        command.id = beamGoToTabIDPrefix + std::to_string(static_cast<std::uint32_t>(tab));
        // The tab strip's own label, so a row reads as the tab the user can see
        // rather than as a second description of it.
        command.title = pane != nullptr ? buildTabLabel(*pane, i) : ("Tab " + std::to_string(i + 1));
        command.group = tab == activeTab ? "Tab · current" : "Tab";
        command.keywords = { "tab" };
        commands.push_back(std::move(command));
    }

    const Panes::Tree* tree = app().model->paneTree(surface, activeTab);
    if (tree == nullptr)
        return commands;
    const PaneID focused = static_cast<PaneID>(tree->focusedPaneID());
    CommandPalette::PaletteCommandList paneRows;
    Panes::forEachLeaf(*tree, [&](int leaf) {
        const PaneID paneID = static_cast<PaneID>(leaf);
        CommandPalette::PaletteCommand command;
        command.id = beamGoToPaneIDPrefix + std::to_string(static_cast<std::uint32_t>(paneID));
        // Numbered by walk order, not by PaneID: the id counts up as panes are
        // opened and closed, so after a close it names a position no pane holds
        // and the list reads as though one is missing.
        const int ordinal = static_cast<int>(paneRows.size()) + 1;
        LinuxPane* pane = paneForID(paneID);
        command.title = pane != nullptr ? buildTabLabel(*pane, ordinal - 1) : ("Pane " + std::to_string(ordinal));
        command.group = paneID == focused ? "Pane · current" : "Pane";
        command.keywords = { "pane", "split" };
        paneRows.push_back(std::move(command));
    });
    // One pane is not a choice, and listing it as one implies there is somewhere
    // else to go. The tabs above stand on their own.
    if (paneRows.size() > 1)
        commands.insert(commands.end(), std::make_move_iterator(paneRows.begin()), std::make_move_iterator(paneRows.end()));
    return commands;
}

// What a Settings row's command id begins with, the key's `[section] name`
// spelled after it as `section.key`.
//
// The section and the name rather than the enumerator's position, because the
// position is a build detail and the pair is what a person reads in their file
// — a row id that appears in a log or a binding names the thing they edited.
constexpr const char* beamSettingCommandIDPrefix = "beam.setting.";

// The `[section] key` a Settings row names, or null when the id names none.
const Ubiquitty::Preferences::WriteDescriptor* beamSettingDescriptorFor(const std::string& commandID)
{
    using namespace Ubiquitty::Preferences;
    if (!commandID.starts_with(beamSettingCommandIDPrefix))
        return nullptr;
    const std::string_view spelled { commandID.c_str() + std::strlen(beamSettingCommandIDPrefix) };
    const std::size_t dot = spelled.find('.');
    if (dot == std::string_view::npos)
        return nullptr;
    const std::string_view section = spelled.substr(0, dot);
    const std::string_view key = spelled.substr(dot + 1);
    for (int i = 0; i < writeDescriptorCount; ++i) {
        if (section == writeDescriptors[i].section && key == writeDescriptors[i].key)
            return &writeDescriptors[i];
    }
    return nullptr;
}

// A row's title: the key as its owner wrote it, with the underscores opened out.
//
// Not a table of display names. A second vocabulary of labels is a second thing
// to keep true, and the key is what the person edits in the file — a palette
// naming it something else makes the row and the file two different things to
// learn.
std::string beamSettingTitle(const Ubiquitty::Preferences::WriteDescriptor& descriptor)
{
    std::string title = std::string(descriptor.section) + " · " + descriptor.key;
    for (char& character : title) {
        if (character == '_')
            character = ' ';
    }
    return title;
}

// Every preference the palette can both show and change — the '#' scope.
//
// Built from Core's own tables and nothing else: `writeDescriptors` names the
// keys, `effectiveValue` says what each reads as, `Schema::rangeFor` bounds the
// numeric ones and `vocabularyFor` lists the closed ones. There is no per-key
// code here, so a key added to Core appears in this palette without a second
// edit — which is the property the macOS catalog does not have.
//
// A key is listed only when the palette can EDIT it, because a row that cannot
// be accepted is worse than an absent one: it ranks against the query, takes a
// selection, and does nothing. Three shapes qualify and the rest are named in
// the count below rather than silently dropped.
Ubiquitty::CommandPalette::PaletteCommandList beamSettingsCommands()
{
    using namespace Ubiquitty;
    namespace Prefs = Ubiquitty::Preferences;
    CommandPalette::PaletteCommandList commands;
    const Prefs::Values& values = loadPreferences();

    for (int i = 0; i < Prefs::writeDescriptorCount; ++i) {
        const Prefs::WriteDescriptor& descriptor = Prefs::writeDescriptors[i];
        const std::optional<Prefs::Value> value = Prefs::effectiveValue(descriptor.id, values);
        if (!value.has_value())
            continue;

        CommandPalette::PaletteCommand command;
        command.id = beamSettingCommandIDPrefix + std::string(descriptor.section) + "." + descriptor.key;
        command.title = beamSettingTitle(descriptor);
        command.group = "Setting";
        command.keywords = { descriptor.section, descriptor.key, "setting", "preference" };

        // The VALUE's kind, not the descriptor's, and the two disagree on seven
        // keys: [font] size, [font] line_spacing, the four [appearance] paddings
        // and titleless_padding_top all parse and resolve as double while their
        // write serializer says Int. A control chosen from the descriptor gives
        // an integer stepper to a setting whose live value is 15.5.
        switch (value->kind) {
        case Prefs::SerializeKind::Bool:
            // Flipped in place. A toggle behind a drill would be two keystrokes
            // to change one bit, and the drill would hold two rows named for
            // the states rather than for the setting.
            command.kind = CommandPalette::CommandKind::Action;
            command.value = value->boolean ? "On" : "Off";
            break;
        case Prefs::SerializeKind::EnumToken: {
            const std::span<const Prefs::VocabularyTerm> terms = Prefs::vocabularyFor(descriptor.id);
            if (terms.empty())
                continue; // an open vocabulary: `[window] drag_modifier` is a chord
            command.kind = CommandPalette::CommandKind::DrillOptions;
            const int current = Prefs::vocabularyIndexOf(descriptor.id, value->text.c_str());
            command.value = current >= 0 ? terms[static_cast<std::size_t>(current)].label : value->text;
            break;
        }
        case Prefs::SerializeKind::Int:
        case Prefs::SerializeKind::Double: {
            const Prefs::Schema::NumericRange* range = Prefs::Schema::rangeFor(descriptor.section, descriptor.key);
            if (range == nullptr)
                continue; // unbounded: an editor with no bounds cannot clamp what it takes
            command.kind = CommandPalette::CommandKind::DrillNumber;
            const double live = value->kind == Prefs::SerializeKind::Int
                ? static_cast<double>(value->integer)
                : value->number;
            // Core formats it, so the preview here and the one the macOS
            // palette shows are the same string for the same number.
            command.value = CommandPalette::Settings::valuePreview(live, range->step, range->unit);
            break;
        }
        case Prefs::SerializeKind::String:
        case Prefs::SerializeKind::LegacyBoolOrToken:
            // Free text needs a text editor, and `BeamAction` carries an option
            // index and a number and no string, so the session has nowhere to
            // put what was typed. Listed by neither this nor the macOS palette.
            continue;
        }
        commands.push_back(std::move(command));
    }
    return commands;
}

// Register the values behind every drill the '#' scope offers.
//
// Separate from building the list because the session holds these rather than
// fetching them: a drill that asked a getter could have its value move while it
// was open, and the session could not tell that from the user typing.
void registerBeamSettingsDrills(const Ubiquitty::CommandPalette::PaletteCommandList& commands)
{
    namespace Prefs = Ubiquitty::Preferences;
    using namespace Ubiquitty::CommandPalette;
    const Prefs::Values& values = loadPreferences();

    for (const PaletteCommand& command : commands) {
        const Prefs::WriteDescriptor* descriptor = beamSettingDescriptorFor(command.id);
        if (descriptor == nullptr)
            continue;
        const std::optional<Prefs::Value> value = Prefs::effectiveValue(descriptor->id, values);
        if (!value.has_value())
            continue;

        if (command.kind == CommandKind::DrillOptions) {
            const std::span<const Prefs::VocabularyTerm> terms = Prefs::vocabularyFor(descriptor->id);
            std::vector<PaletteOption> options;
            options.reserve(terms.size());
            for (const Prefs::VocabularyTerm& term : terms)
                options.push_back(PaletteOption { term.label });
            app().beamSession.setOptions(command.id, std::move(options),
                Prefs::vocabularyIndexOf(descriptor->id, value->text.c_str()));
            continue;
        }
        if (command.kind == CommandKind::DrillNumber) {
            const Prefs::Schema::NumericRange* range = Prefs::Schema::rangeFor(descriptor->section, descriptor->key);
            if (range == nullptr)
                continue;
            PaletteNumber number;
            number.value = value->kind == Prefs::SerializeKind::Int
                ? static_cast<double>(value->integer)
                : value->number;
            number.minimum = range->minimum;
            number.maximum = range->maximum;
            // A slider declares no step; Core nudges it across about twenty
            // stops, which is the same arithmetic the macOS number editor uses.
            number.step = range->step > 0.0 ? range->step : Settings::sliderStep(range->minimum, range->maximum);
            number.unit = range->unit;
            app().beamSession.setNumber(command.id, number);
        }
    }
}

// Find command IDs name one published list's durable destinations.
//
// Distinct from the Blocks prefix even though both resolve to a scroll: the two
// scopes are filled from different walks and a shared prefix would make a row
// from one runnable while the other was registered.
constexpr const char* beamFindCommandIDPrefix = "beam.find.";

/// Builds the available find rows and retains their logical destinations.
///
/// - Parameter pane: The palette's originating pane, or null for no terminal.
/// - Returns: One command per published label, bounded by the request's limit.
Ubiquitty::CommandPalette::PaletteCommandList beamFindCommands(LinuxPane* pane)
{
    using namespace Ubiquitty;
    CommandPalette::PaletteCommandList commands;
    app().beamFindTargets.clear();
    if (!pane || !pane->session)
        return commands;
    app().beamFindPane = pane->weakPtr();
    const auto generation = pane->session->searchStatus().generation;
    for (const Search::Label& label : pane->session->searchLabels()) {
        CommandPalette::PaletteCommand command;
        command.id = beamFindCommandIDPrefix + std::to_string(generation) + "." + std::to_string(commands.size());
        command.title = label.text.empty() ? ("Row " + std::to_string(label.absoluteRow)) : label.text;
        app().beamFindTargets.emplace(command.id, label.position);
        commands.push_back(std::move(command));
    }
    return commands;
}

// What a Blocks row's command id begins with, the block's absolute prompt row
// spelled after it.
//
// Every other id the palette hands back is a named-action token, and this must
// be one no token can spell: `parseAction` decides what an accepted row runs, so
// an id it accepted by accident would run an action the user never picked, and
// one it rejected would leave the row doing nothing at all.
constexpr const char* beamBlockCommandIDPrefix = "beam.block.";

// The focused terminal's OSC 133 command blocks as palette rows — the '@' scope.
//
// The walk is Core's: the order, the bound, how a multi-row command becomes one
// label, the whitespace between the rows, the empty-prompt rule and the
// alternate-screen rule are all settled in Screen::commandBlocks, so what is
// left here is the one thing Core leaves to a frontend — how a failure reads.
// macOS wears "✗" for it, so this does too.
//
// The prompt row rides in the id because it is what accepting the row scrolls
// to, and a row's position in the list is not: ranking reorders, so a position
// resolved after a query has narrowed the list names a different block.
Ubiquitty::CommandPalette::PaletteCommandList beamBlockCommands(const Ubiquitty::Terminal* term)
{
    using namespace Ubiquitty;
    CommandPalette::PaletteCommandList commands;
    // Null is a state this receives: fillBeamScopes reads the same pointer to
    // decide the '@' scope is unavailable and then passes it here regardless.
    // Stated rather than left to Screen::commandBlocks, which also answers
    // empty for null — a caller relying on a callee's tolerance is one edit
    // away from a crash it did not cause.
    if (!term)
        return commands;
    const Screen::CommandBlockList blocks = Screen::commandBlocks(term, Screen::maxCommandBlocks);
    commands.reserve(blocks.size());
    for (const Screen::CommandBlock& block : blocks) {
        CommandPalette::PaletteCommand command;
        command.id = beamBlockCommandIDPrefix + std::to_string(block.promptRow);
        command.title = block.command;
        command.group = block.didFail ? "✗" : "";
        commands.push_back(std::move(command));
    }
    return commands;
}

// Fill the palette's scopes for one summon, and say whether the terminal-only
// scopes have a terminal behind them.
//
// Both lists are a SNAPSHOT taken here. Re-registering per keystroke would walk
// the whole buffer again on every character and reset the selection under the
// user, so a block that ran while the palette was open is absent until the next
// summon.
//
// The gate and the block list read the same terminal: a summon with none offers
// no '@' at all, rather than a scope the user can enter and find empty.
void fillBeamScopes(const Ubiquitty::Terminal* term)
{
    using namespace Ubiquitty::CommandPalette;
    app().beamSession.setTerminalAvailability(term != nullptr ? TerminalAvailability::Available : TerminalAvailability::Unavailable);
    app().beamSession.setCommands(Scope::Actions, beamCommands());
    app().beamSession.setCommands(Scope::Blocks, beamBlockCommands(term));
    app().beamSession.setCommands(Scope::GoTo, beamGoToCommands());
    const PaletteCommandList settings = beamSettingsCommands();
    registerBeamSettingsDrills(settings);
    app().beamSession.setCommands(Scope::Settings, settings);
    app().beamSession.setOptions(beamThemeCommandID, themeOptionLabels(), app().liveThemeIndex);
}

// Scroll the focused pane's viewport until `absoluteRow` is on screen, through
// the reveal policy in Core that the find bar's jump already uses — a block and
// a search match landing at different heights would be two answers to the one
// question of where a revealed row belongs.
//
// History counts as zero while the alternate screen is up, matching the bound
// the block walk addressed the row under; reading the retained line count here
// would resolve that row somewhere else.
void scrollToAbsoluteRow(int absoluteRow)
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    const auto hold = holdPaneModel(*activePane());
    const int history = Ubiquitty::Screen::scrollableRowCount(term);
    activePane()->viewOffset = Ubiquitty::Screen::viewOffsetToReveal(history, term->rows, absoluteRow, Ubiquitty::Screen::RevealPlacement::CommandBlock);
    requestRepaint();
}

// Lay the palette out for this frame against the pane being rendered. Per frame
// from the live state, so a theme change or a resize is reflected without the
// session being told either happened; closed, the canvas has no rows and the
// composite downstream is skipped.
Ubiquitty::Rendering::BeamGeometry layoutBeamForFrame(const Ubiquitty::Terminal& term)
{
    Ubiquitty::Rendering::BeamGeometry geometry = Ubiquitty::Rendering::layoutBeam(
        app().beamSession.state(), Ubiquitty::Themes::resolveChromeStyle(term.palette), term.rows, term.columns);
    // Hand the drawn row count back so the session scrolls against the box that is
    // actually on screen. Without it the selection can walk off the bottom of a
    // short grid and never scroll into view, which reads as a frozen palette.
    // Only when it drew something: a window of zero would leave the session unable
    // to scroll the next list until a later frame corrected it.
    if (geometry.bodyRows > 0)
        app().beamSession.setViewportRows(geometry.bodyRows);
    return geometry;
}
// Lay the reserved-gesture hint out for this frame. Core keeps the words, the
// budget and the clock; this asks what stands now, and books the one repaint
// Core names so a lesson fades without a frame of its own. Read per frame from
// the live theme, like the palette, so a theme change needs no notification.
Ubiquitty::Rendering::HintToastGeometry layoutHintForFrame(const Ubiquitty::Runtime::TerminalSession& session, const Ubiquitty::Terminal& term)
{
    // The keys this arm reads wear words: Command is GDK_SUPER_MASK, the
    // key labelled Super or with a logo, and a reader looking for ⌘ on it
    // would not find one.
    const char* text = Ubiquitty::Input::hintText(session.hintShowing(), Ubiquitty::Input::ModifierVocabulary::Words);
    if (*text == '\0')
        return {};
    const std::uint32_t left = session.hintTicksUntilExpiry();
    if (left != 0 && !app().isHintRepaintBooked) {
        app().isHintRepaintBooked = true;
        // One tick past the expiry, so the frame lands on its far side.
        g_timeout_add(static_cast<guint>((left + 1) * 1000 / 60), [](gpointer) -> gboolean {
            app().isHintRepaintBooked = false;
            requestRepaint();
            return G_SOURCE_REMOVE; }, nullptr);
    }
    return Ubiquitty::Rendering::layoutHintToast(text,
        Ubiquitty::Themes::resolveChromeStyle(term.palette), term.rows, term.columns);
}

} // namespace

// Render one pane into its GtkPicture. Each visible pane is a single texture from
// one renderGrid/rasterizeTerm call keyed to that pane's own Terminal (whose columns/rows
// are its own), so the CPU(SoftwareRenderer)==GPU(Vulkan) byte-identical oracle
// holds per pane. The output size is derived inside renderGrid/rasterizeTerm from
// the term's grid — no dependence on the window-global app().columns/app().rows.
// Whether UBIQUITTY_PERFLOG asked for the per-second frame line. Read once:
// getenv takes a lock on some libcs, and this sits on the frame path.
bool isPerfLogEnabled()
{
    static const bool enabled = ::getenv("UBIQUITTY_PERFLOG") != nullptr;
    return enabled;
}

// A texture over the frame's host pixels. GTK reads the bytes lazily, so they
// outlive this frame: the pooled buffer rides inside the GBytes and comes back
// to the pool when GTK lets the bytes go.
GdkTexture* makeMemoryFrameTexture(std::unique_ptr<std::vector<uint8_t>> frameBuffer, int width, int height)
{
    std::vector<uint8_t>* frame = frameBuffer.release();
    GBytes* bytes = g_bytes_new_with_free_func(frame->data(), frame->size(), [](gpointer pointer) { app().framePool.give(std::unique_ptr<std::vector<uint8_t>>(static_cast<std::vector<uint8_t>*>(pointer))); }, frame);
    GdkTexture* texture = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, static_cast<gsize>(width) * 4);
    g_bytes_unref(bytes);
    return texture;
}

// The DRM name of VK_FORMAT_R8G8B8A8_UNORM's byte order, and the modifier of a
// linear image; spelled here so the frontend needs no libdrm header.
constexpr std::uint32_t drmFormatABGR8888 = 'A' | ('B' << 8) | ('2' << 16) | (static_cast<std::uint32_t>('4') << 24);
constexpr std::uint64_t drmModifierLinear = 0;

// What the dma-buf texture's destroy notify needs: the descriptor to close and
// the token that frees the renderer's slot.
struct ExportedFrameRelease {
    int fileDescriptor;
    std::uint64_t releaseToken;
};

// A texture over an exported frame's dma-buf. The bytes stay in GPU memory and
// reach the compositor without a host copy. GTK does not take the descriptor;
// the destroy notify closes it and returns the slot when GTK lets it go.
// Null when GTK refuses the import, with the descriptor closed and the slot
// returned.
GdkTexture* makeExportedFrameTexture(GtkWidget* picture, const Ubiquitty::Linux::VulkanRenderer::ExportedFrame& frame)
{
    GdkDmabufTextureBuilder* builder = gdk_dmabuf_texture_builder_new();
    gdk_dmabuf_texture_builder_set_display(builder, gtk_widget_get_display(picture));
    gdk_dmabuf_texture_builder_set_width(builder, frame.width);
    gdk_dmabuf_texture_builder_set_height(builder, frame.height);
    gdk_dmabuf_texture_builder_set_fourcc(builder, drmFormatABGR8888);
    gdk_dmabuf_texture_builder_set_modifier(builder, drmModifierLinear);
    // The frame carries straight alpha, as the memory texture's R8G8B8A8 does.
    gdk_dmabuf_texture_builder_set_premultiplied(builder, FALSE);
    gdk_dmabuf_texture_builder_set_n_planes(builder, 1);
    gdk_dmabuf_texture_builder_set_fd(builder, 0, frame.fileDescriptor);
    gdk_dmabuf_texture_builder_set_stride(builder, 0, frame.stride);
    gdk_dmabuf_texture_builder_set_offset(builder, 0, frame.offset);
    auto* release = new ExportedFrameRelease { frame.fileDescriptor, frame.releaseToken };
    GError* error = nullptr;
    GdkTexture* texture = gdk_dmabuf_texture_builder_build(builder, [](gpointer data) {
        std::unique_ptr<ExportedFrameRelease> owned(static_cast<ExportedFrameRelease*>(data));
        ::close(owned->fileDescriptor);
        app().vulkan.releaseExportedFrame(owned->releaseToken); }, release, &error);
    g_object_unref(builder);
    if (!texture) {
        g_warning("dma-buf import refused (%s); frames read back for this run", error ? error->message : "no reason given");
        if (error)
            g_error_free(error);
        ::close(release->fileDescriptor);
        app().vulkan.releaseExportedFrame(release->releaseToken);
        delete release;
    }
    return texture;
}

void renderPaneInto(LinuxPane& pane, GtkWidget* picture, std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope>* outerHold)
{
    if (!picture)
        return; // headless (no window) — the smoke paths render via rasterizeTerm directly
    const std::uint32_t frameStartMicros = Ubiquitty::PAL::monotonicMicros();
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term)
        return;
    // Held for the capture: the renderer reads the grid where it builds the
    // frame's instances and hands the model back before the GPU pass, so the
    // parser waits for the build and not for the draw and the readback. The
    // CPU raster reads throughout, so the hold outlives it. The session asks
    // for nothing under it. The focused pane arrives with the tick's own hold,
    // which this frame ends at the handoff: one announced wait per frame
    // rather than one per reader, since each is a donation the parser pays.
    std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope> ownHold;
    if (!outerHold && pane.session)
        ownHold.emplace(*pane.session);
    auto* const hold = outerHold ? outerHold : &ownHold;
    std::unique_ptr<std::vector<uint8_t>> frameBuffer = app().framePool.take();
    std::vector<uint8_t>& rgba = *frameBuffer;
    int width = 0, height = 0;
    const double nowSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
    Ubiquitty::Linux::CursorOverlay cursor = resolvePresentedCursorOverlay(pane, nowSeconds, cursorPresentationInterval(picture));
    scheduleCursorPresentation(pane, nowSeconds);
    if (&pane == activePane())
        scheduleCaretBlink(term);
    // SGR 5/6 text blink rides the same per-frame monotonic tick as the cursor,
    // resolved once here and handed to whichever path renders so the CPU<->GPU
    // oracle holds. The builder gates on hasBlinkHint, so no-blink screens are
    // unaffected.
    const uint32_t blinkTicks = Ubiquitty::PAL::monotonicTicks().count;
    // Beam belongs to the window, so it draws over the focused pane only. The
    // chrome is module state the snapshot reads, so it is set for every pane —
    // an empty geometry for the others — rather than only when the palette is
    // open. Setting it once and leaving it would stamp the palette into whichever
    // pane rendered next.
    Ubiquitty::Rendering::BeamGeometry chrome;
    Ubiquitty::Rendering::HintToastGeometry hint;
    if (&pane == activePane()) {
        chrome = layoutBeamForFrame(*term);
        hint = layoutHintForFrame(*pane.session, *term);
    }
    app().rasterContext.setBeamChrome(&chrome);
    app().rasterContext.setHintChrome(&hint);
    const bool hasRichFrame = capturePaneRichText(pane, &cursor, pane.viewOffset);
    // A caret inside a block is the block's: Pango owns its insertion offset.
    const bool drawsRichCaret = hasRichFrame && pane.richTextFrame.hasRichTextCaret();
    if (drawsRichCaret) {
        cursor.visible = false;
        cursor.presentation = Ubiquitty::Rendering::CursorRenderState {};
    }
    // GPU path when available; the CPU rasterizer is a byte-identical fallback.
    // Both consume the same scrollback viewport offset + cursor (the CPU<->GPU oracle).
    // The placement's facts about the frame being drawn, read while the hold
    // stands so they describe this frame and not a later pass's.
    const Ubiquitty::GridSize gridSize { term->columns, term->rows };
    const Ubiquitty::CellPosition cursorPosition { term->screens.active->cursorY, term->screens.active->cursorX };
    const bool isProgramViewport = term->isTekModeActive || term->modes.fullscreenContent;
    const bool shouldFollowCursor = pane.viewOffset == 0 && term->modes.isCursorVisible != 0;
    const Ubiquitty::Linux::ModelCaptureHandoff handoff {
        .onCaptured = [](void* context) {
            auto* capturedHold = static_cast<std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope>*>(context);
            if (*capturedHold)
                (*capturedHold)->release();
        },
        .context = hold,
    };
    // A frame with no CPU composite left to do goes to the compositor as a
    // dma-buf, never through host memory; a rich-text frame needs its pixels
    // here, so it reads back.
    //
    // A Tektronix frame is drawn by the CPU raster, which composites Core's
    // beam over the tube; the GPU pipeline has no Tek pass, and a tube frame is
    // vectors over a flat fill rather than a grid worth a GPU build.
    const bool shouldRenderOnGPU = app().isVulkanReady && !term->isTekModeActive;
    if (shouldRenderOnGPU && !hasRichFrame && app().vulkan.canExportFrames())
        app().vulkan.requestFrameExport();
    bool ok = shouldRenderOnGPU ? app().vulkan.renderGrid(app().rasterContext, term, rgba, width, height, pane.viewOffset, &pane.selection, &cursor, blinkTicks, handoff) : app().rasterContext.rasterizeTerm(term, rgba, width, height, pane.viewOffset, &pane.selection, &cursor, blinkTicks);
    const bool didDrawOnGPU = ok && shouldRenderOnGPU;
    const std::optional<Ubiquitty::Linux::VulkanRenderer::ExportedFrame> exportedFrame = didDrawOnGPU ? app().vulkan.takeExportedFrame() : std::nullopt;
    if (exportedFrame)
        ++app().perfWindow.exportedFrames;
    if (!ok && shouldRenderOnGPU) {
        // A grid larger than any frame the device can draw is this frame's
        // size, not a failed GPU: a program's page length, a remote owner's
        // geometry or a large font put the model there, and the next grid that
        // fits goes back to the GPU. The renderer declined it before its capture, so the hold
        // still stands for the CPU raster. Any other failure — device lost, a
        // missing shader — must not freeze the window: the pane keeps its last
        // texture and every later frame fails the same way. That demotes to
        // the CPU raster once, for good; the exit path's teardown is gated on
        // the same flag, so a lost device is not torn down twice. Either way
        // this same frame is painted through the CPU raster.
        if (!app().vulkan.didDeclineOversizedGrid()) {
            g_warning("Vulkan render failed; demoting to the CPU raster for this run");
            app().isVulkanReady = false;
        }
        ok = app().rasterContext.rasterizeTerm(term, rgba, width, height, pane.viewOffset, &pane.selection, &cursor, blinkTicks);
    }
    if (!ok)
        return;
    if (hasRichFrame) {
        const auto overlayHold = holdPaneModel(pane);
        pane.richText.composite(pane.richTextFrame, rgba, width, height,
            app().rasterContext.snapshotOverlayRegions(*term, pane.viewOffset), drawsRichCaret);
    }
    const Ubiquitty::FloatSize viewport {
        static_cast<float>(std::max(gtk_widget_get_width(picture) * app().scale, 1)),
        static_cast<float>(std::max(gtk_widget_get_height(picture) * app().scale, 1))
    };
    pane.presentation = Ubiquitty::Rendering::remoteViewportPlacement({
        .policy = app().rasterContext.renderConfiguration().nonOwnerPresentation,
        .viewport = viewport,
        .cell = { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) },
        .grid = gridSize,
        .cursor = cursorPosition,
        .previousPanOffset = pane.presentation.panOffset,
        .minimumScale = static_cast<float>(std::min(1.0, Ubiquitty::Preferences::Zoom::clampFontZoom(0.0) / app().fontSizePoints)),
        .isGeometryOwnedElsewhere = pane.session->isRemoteGeometryOwnedElsewhere(),
        .isProgramViewport = isProgramViewport,
        .shouldFollowCursor = shouldFollowCursor,
    });
    pane.presentationViewport = viewport;
    if (&pane == activePane())
        updateIMCursorLocation(cursorPosition);
    // The focused pill's bounce is a smooth animation while it runs: another
    // frame is owed until the curve rests.
    if (didDrawOnGPU ? app().vulkan.isFocusedMatchBouncing() : app().rasterContext.isFocusedMatchBouncing())
        requestRepaint();
    // Where a frame's wall clock went, once a second, when UBIQUITTY_PERFLOG is
    // set. The macOS arm has carried this for a long time and the Linux arm has
    // not, which is why questions about this frame path -- how much of it is the
    // GPU, how much is the copy back out of it -- have had no answer here.
    //
    // The split is the one those questions need. `wait` is the whole GPU render
    // as the CPU experiences it, because the pipeline submits and waits and
    // nothing overlaps it. `readback` is the host half of the round trip: the
    // copy out of the staging buffer that a presentation path handing the image
    // straight to the compositor would not pay.
    if (isPerfLogEnabled()) {
        static double windowStartSeconds = 0.0;
        static double waitSum = 0.0;
        static double maxWaitSeconds = 0.0;
        static double readbackSum = 0.0;
        static double maxReadbackSeconds = 0.0;
        static double frameSum = 0.0;
        static double maxFrameSeconds = 0.0;
        static int frames = 0;

        const std::uint32_t nowMicros = Ubiquitty::PAL::monotonicMicros();
        const double nowSeconds = static_cast<double>(nowMicros) / 1e6;
        const double frameSeconds = static_cast<double>(static_cast<std::uint32_t>(nowMicros - frameStartMicros)) / 1e6;
        const double waitSeconds = didDrawOnGPU ? app().vulkan.lastFrameWaitSeconds() : 0.0;
        const double readbackSeconds = didDrawOnGPU ? app().vulkan.lastFrameReadbackSeconds() : 0.0;
        frameSum += frameSeconds;
        waitSum += waitSeconds;
        readbackSum += readbackSeconds;
        maxFrameSeconds = frameSeconds > maxFrameSeconds ? frameSeconds : maxFrameSeconds;
        maxWaitSeconds = waitSeconds > maxWaitSeconds ? waitSeconds : maxWaitSeconds;
        maxReadbackSeconds = readbackSeconds > maxReadbackSeconds ? readbackSeconds : maxReadbackSeconds;
        ++frames;

        if (windowStartSeconds == 0.0)
            windowStartSeconds = nowSeconds;
        const double windowSeconds = nowSeconds - windowStartSeconds;
        if (windowSeconds >= 1.0 && frames > 0) {
            const App::PerfWindow& window = app().perfWindow;
            // The loop's own account of the second: what it delivered and
            // what it parsed, so a frame count can be read against the
            // deliveries that asked for it.
            const Ubiquitty::Runtime::TerminalSession::PerfDrainTally tally = pane.isIngesting ? pane.session->takePerfDrainTally() : Ubiquitty::Runtime::TerminalSession::PerfDrainTally {};
            Ubiquitty::PAL::logLine(stderr,
                "[perf] {:.2f}s | {:3}fr {:5.0f}fps exported={} | frame(ms) avg={:6.3f} max={:6.3f} | wait={:6.3f}/{:6.3f} | readback={:6.3f}/{:6.3f} | ticks={} withheld={} | hops={} avg={:.3f}ms (flags {:.1f} follow {:.1f} queues {:.1f} title {:.1f} pointer {:.1f} ms) | hold(ms) avg={:.3f} max={:.3f} | ingest: {} deliveries {:.1f} MB {:.0f} ms parse (longest {:.1f} ms) | {}x{} | backend={}",
                windowSeconds, frames, frames / windowSeconds, window.exportedFrames,
                frameSum / frames * 1000.0, maxFrameSeconds * 1000.0,
                waitSum / frames * 1000.0, maxWaitSeconds * 1000.0,
                readbackSum / frames * 1000.0, maxReadbackSeconds * 1000.0,
                window.ticks, window.withheldTicks,
                window.hops, window.hops > 0 ? window.hopSeconds / window.hops * 1000.0 : 0.0,
                window.hopFlagsSeconds * 1000.0, window.hopFollowSeconds * 1000.0, window.hopQueuesSeconds * 1000.0,
                window.hopTitleSeconds * 1000.0, window.hopPointerSeconds * 1000.0,
                window.ticks > 0 ? window.holdWaitSeconds / window.ticks * 1000.0 : 0.0, window.maxHoldWaitSeconds * 1000.0,
                tally.deliveries, static_cast<double>(tally.bytes) / 1e6, static_cast<double>(tally.ingestMicroseconds) / 1000.0,
                static_cast<double>(tally.longestIngestMicroseconds) / 1000.0,
                width, height, app().isVulkanReady ? "vulkan" : "cpu");
            windowStartSeconds = nowSeconds;
            waitSum = maxWaitSeconds = readbackSum = maxReadbackSeconds = frameSum = maxFrameSeconds = 0.0;
            frames = 0;
            app().perfWindow = {};
        }
    }

    GdkTexture* texture = exportedFrame ? makeExportedFrameTexture(picture, *exportedFrame) : nullptr;
    if (exportedFrame && !texture) {
        // GTK refused the import: the frame exists only in GPU memory, so this
        // one is dropped, the export is switched off for the run, and the next
        // frame reads back.
        app().vulkan.disableFrameExport();
        requestRepaint();
        return;
    }
    if (!texture)
        texture = makeMemoryFrameTexture(std::move(frameBuffer), width, height);
    // The immutable node transforms the complete CPU or Vulkan picture once.
    // No resampling/readback pass is added to either renderer, and GTK clips
    // the image rather than stretching it to a different owner's grid.
    GtkSnapshot* snapshot = gtk_snapshot_new();
    const graphene_rect_t clip = GRAPHENE_RECT_INIT(0, 0, viewport.width, viewport.height);
    gtk_snapshot_push_clip(snapshot, &clip);
    const graphene_rect_t bounds = GRAPHENE_RECT_INIT(pane.presentation.origin.x, pane.presentation.origin.y,
        width * pane.presentation.scale, height * pane.presentation.scale);
    gtk_snapshot_append_texture(snapshot, texture, &bounds);
    gtk_snapshot_pop(snapshot);
    const graphene_size_t size = GRAPHENE_SIZE_INIT(viewport.width, viewport.height);
    GdkPaintable* paintable = gtk_snapshot_free_to_paintable(snapshot, &size);
    gtk_picture_set_paintable(GTK_PICTURE(picture), paintable);
    g_object_unref(paintable);
    g_object_unref(texture);
}

// Paint the focused pane into the shared picture. (Split panes render each visible
// leaf into its own picture; today there is one, app().focusedPicture.)
void renderGridFrame() { renderPaneInto(*activePane(), app().focusedPicture, nullptr); }

// Input.

struct MappedKey {
    std::uint32_t code; // Kitty-identity codePoint (0 = nothing to send)
    bool functional; // true: KEYMAP_KK_* key; false: a printable codePoint
};

// GDK keyval → the portable Keys::VirtualKey identity. This is the only
// place that names a native GDK keyval: it hands the rest of the input path
// off to the SHARED Native-VK → Kitty codePoint table
// (Source/Core/Keys/KeyTranslation.h), which the macOS frontend also routes
// through — so the functional-key table (Insert and ISO_Left_Tab
// included) is written once. Returns
// Keys::VirtualKey::None for a printable key (whose codePoint comes from
// gdk_keyval_to_unicode) and for keys with no functional identity.
// ISO_Left_Tab (Shift+Tab) folds to Tab, matching the macOS native
// translation.
//
// The numeric keypad is not translated here: GTK still feeds an
// unmodified keypad key as its gdk_keyval_to_unicode character so normal
// keypad typing keeps working (the encoder has no legacy byte form for a
// bare keypad PUA codePoint). The application-keypad SS3 form is handled by
// the separate keypadVirtualKeyFor + early SS3 gate in sendKey, mirroring the
// macOS frontend (which keeps the typed character as the encoder keyCode and
// only consults the keypad identity at the application-keypad gate).
Ubiquitty::Keys::VirtualKey virtualKeyFor(guint keyval)
{
    using Key = Ubiquitty::Keys::VirtualKey;
    switch (keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
        return Key::Return;
    case GDK_KEY_Tab:
    case GDK_KEY_ISO_Left_Tab:
        return Key::Tab;
    case GDK_KEY_BackSpace:
        return Key::Backspace;
    case GDK_KEY_Escape:
        return Key::Escape;
    case GDK_KEY_Left:
        return Key::LeftArrow;
    case GDK_KEY_Right:
        return Key::RightArrow;
    case GDK_KEY_Up:
        return Key::UpArrow;
    case GDK_KEY_Down:
        return Key::DownArrow;
    case GDK_KEY_Home:
        return Key::Home;
    case GDK_KEY_End:
        return Key::End;
    case GDK_KEY_Page_Up:
        return Key::PageUp;
    case GDK_KEY_Page_Down:
        return Key::PageDown;
    case GDK_KEY_Insert:
        return Key::Insert;
    case GDK_KEY_Delete:
        return Key::ForwardDelete; // X11 "Delete" is the forward-delete key
    default:
        break;
    }
    if (keyval >= GDK_KEY_F1 && keyval <= GDK_KEY_F12)
        return static_cast<Key>(static_cast<std::uint16_t>(Key::F1) + (keyval - GDK_KEY_F1));
    return Key::None;
}

// GDK keypad keyval → the portable Keys::VirtualKey::Keypad* identity. This is
// the only place that names a native keypad GDK keyval; the SS3 final then comes
// from the SHARED Keys::keypadKeyCodePoint + Keys::Keymap::applicationKeypadSS3 tables
// (the macOS frontend routes through the same pair). Returns VirtualKey::None for
// any non-keypad keyval and for keypad keys with no application-keypad SS3 form
// (GDK_KEY_KP_Enter is a Functional key — virtualKeyFor folds it to Return — and
// the navigation keypad keys, e.g. KP_Up, carry their cursor identity instead).
Ubiquitty::Keys::VirtualKey keypadVirtualKeyFor(guint keyval)
{
    using Key = Ubiquitty::Keys::VirtualKey;
    switch (keyval) {
    case GDK_KEY_KP_0:
        return Key::Keypad0;
    case GDK_KEY_KP_1:
        return Key::Keypad1;
    case GDK_KEY_KP_2:
        return Key::Keypad2;
    case GDK_KEY_KP_3:
        return Key::Keypad3;
    case GDK_KEY_KP_4:
        return Key::Keypad4;
    case GDK_KEY_KP_5:
        return Key::Keypad5;
    case GDK_KEY_KP_6:
        return Key::Keypad6;
    case GDK_KEY_KP_7:
        return Key::Keypad7;
    case GDK_KEY_KP_8:
        return Key::Keypad8;
    case GDK_KEY_KP_9:
        return Key::Keypad9;
    case GDK_KEY_KP_Decimal:
        return Key::KeypadDecimal;
    case GDK_KEY_KP_Divide:
        return Key::KeypadDivide;
    case GDK_KEY_KP_Multiply:
        return Key::KeypadMultiply;
    case GDK_KEY_KP_Subtract:
        return Key::KeypadSubtract;
    case GDK_KEY_KP_Add:
        return Key::KeypadAdd;
    case GDK_KEY_KP_Equal:
        return Key::KeypadEqual;
    default:
        return Key::None;
    }
}

// GDK keyval → the portable bare-modifier Keys::VirtualKey identity, left/right
// distinguished. This is the only place that names a native modifier GDK keyval;
// the Kitty PUA codePoint then comes from the SHARED Keys::modifierKittyCodePoint
// table (the macOS frontend routes the same way). GTK delivers a bare modifier as
// an ordinary key-pressed / key-released event, so the press/release direction is
// the signal that fired — no device-mask discrimination is needed here, unlike
// macOS's flagsChanged: path. Meta_L/R fold to Alternate (the X11 Meta modifier).
// Returns VirtualKey::None for any non-modifier keyval.
Ubiquitty::Keys::VirtualKey modifierVirtualKeyFor(guint keyval)
{
    using Key = Ubiquitty::Keys::VirtualKey;
    switch (keyval) {
    case GDK_KEY_Caps_Lock:
        return Ubiquitty::Keys::VirtualKey::CapsLock;
    case GDK_KEY_Shift_L:
        return Key::LeftShift;
    case GDK_KEY_Shift_R:
        return Key::RightShift;
    case GDK_KEY_Control_L:
        return Key::LeftControl;
    case GDK_KEY_Control_R:
        return Key::RightControl;
    case GDK_KEY_Alt_L:
    case GDK_KEY_Meta_L:
        return Key::LeftAlternate;
    case GDK_KEY_Alt_R:
    case GDK_KEY_Meta_R:
        return Key::RightAlternate;
    case GDK_KEY_Super_L:
        return Key::LeftSuper;
    case GDK_KEY_Super_R:
        return Key::RightSuper;
    default:
        return Key::None;
    }
}

// GDK keyval → Kitty key identity, via the shared functional-key table.
// Functional keys map to KEYMAP_KK_* (so backspace is 127, arrows the PUA
// range, etc.); everything else (printable keys and the keypad, which
// virtualKeyFor leaves as None) resolves to its Unicode codePoint (layout +
// shift already applied by GDK). GDK_KEY_KP_Enter folds to Return (a
// newline), matching the macOS routing where KeypadEnter is Functional.
MappedKey mapKey(guint keyval, Ubiquitty::Keys::KeyEncoder encoder)
{
    const std::uint32_t functional
        = Ubiquitty::Keys::reportedKeyCodePoint(virtualKeyFor(keyval), encoder);
    if (functional != 0)
        return { functional, true };
    const std::uint32_t keypad
        = Ubiquitty::Keys::reportedKeyCodePoint(keypadVirtualKeyFor(keyval), encoder);
    if (keypad != 0)
        return { keypad, true };
    // A keypad key has no functional identity of its own — virtualKeyFor leaves
    // it None so the legacy encoder keeps the typed character — but under Kitty
    // the CSI-u form carries the keypad code point, which is the distinction the
    // keypad table exists for. Resolved through the same Core function, from the
    // keypad identity this file already knows how to read.
    return { gdk_keyval_to_unicode(keyval), false };
}

// The keyval this physical key carries with no modifier applied.
//
// GDK reports the keyval the layout already resolved, so Shift+`;` arrives as
// `:` and the key's own identity is gone. The terminal reports the unshifted
// key and carries the typed glyph as the shifted alternate — that is what
// `CSI 59:58;2u` means — so the layout is asked for level 0 of the group the
// event was actually translated in.
//
// - Parameters:
//   - keycode: The hardware code, or 0 when the caller has none.
//   - keyval: The keyval GDK reported, returned unchanged when the layout
//     cannot answer.
// - Returns: The unshifted keyval.
guint unshiftedKeyval(guint keycode, guint keyval)
{
    GdkDisplay* display = gdk_display_get_default();
    if (keycode == 0 || display == nullptr)
        return keyval;

    GdkKeymapKey* keys = nullptr;
    guint* keyvals = nullptr;
    int count = 0;
    if (!gdk_display_map_keycode(display, keycode, &keys, &keyvals, &count))
        return keyval;

    // The group is the active layout; a key that produced its shifted face in
    // group 1 must not be answered with group 0's unshifted face. Found from
    // the entry that matches what GDK actually reported.
    int group = 0;
    for (int index = 0; index < count; ++index) {
        if (keyvals[index] == keyval) {
            group = keys[index].group;
            break;
        }
    }

    guint unshifted = keyval;
    for (int index = 0; index < count; ++index) {
        if (keys[index].level == 0 && keys[index].group == group) {
            unshifted = keyvals[index];
            break;
        }
    }
    g_free(keys);
    g_free(keyvals);
    return unshifted;
}

Ubiquitty::Keys::VirtualKey physicalPrintableKey(guint keycode)
{
    static constexpr std::uint16_t usages[] = {
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        30,
        31,
        32,
        33,
        34,
        35,
        36,
        37,
        38,
        39,
        45,
        46,
        0,
        0,
        20,
        26,
        8,
        21,
        23,
        28,
        24,
        12,
        18,
        19,
        47,
        48,
        0,
        0,
        4,
        22,
        7,
        9,
        10,
        11,
        13,
        14,
        15,
        51,
        52,
        53,
        0,
        49,
        29,
        27,
        6,
        25,
        5,
        17,
        16,
        54,
        55,
        56,
        0,
        0,
        0,
        44,
        57,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        100,
        0,
    };
    return keycode < std::size(usages) ? Ubiquitty::Keys::printableKeyForHID(usages[keycode]) : Ubiquitty::Keys::VirtualKey::None;
}

void updatePositionModifiers(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType eventType)
{
    auto* pane = activePane();
    if (!pane)
        return;
    auto& held = pane->keyPositionModifiers;
    if (!(state & GDK_SHIFT_MASK))
        held &= ~3;
    if (!(state & GDK_CONTROL_MASK))
        held &= ~8;
    if (!(state & GDK_ALT_MASK))
        held &= ~0x30;
    if (!(state & GDK_SUPER_MASK))
        held &= ~0xc0;
    held = (held & ~4) | ((state & GDK_LOCK_MASK) ? 4 : 0);
    if (keyval == GDK_KEY_Caps_Lock) {
        if (eventType == Ubiquitty::Keys::KeyEventType::Press)
            held ^= 4;
        return;
    }
    const auto modifier = Ubiquitty::Keys::isoModifierKey(modifierVirtualKeyFor(keyval));
    if (eventType == Ubiquitty::Keys::KeyEventType::Release)
        held &= ~modifier;
    else
        held |= modifier;
}

// Encode one key and write it to the PTY. Returns true if bytes were sent.
//
// `keycode` is the hardware code the event carried, or 0 when the caller has
// none (the self-tests synthesise keyvals). It resolves the layout's unshifted
// face of the key, which GDK's keyval alone cannot give: the keyval is already
// shifted, so Shift+`;` arrives as `:` with no way back to `;`.
bool sendKey(guint keyval, guint keycode, GdkModifierType state)
{
    std::uint32_t modifiers = 0;
    if (state & GDK_CONTROL_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierCtrl;
    if (state & GDK_ALT_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierAlternate;
    // Super is the desktop key, not a terminal one, so it is not reported.
    if (state & GDK_SHIFT_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierShift;

    Ubiquitty::Runtime::KeyPress press;
    // Every modifier this frontend recognises, whether or not it is reported.
    // Super is dropped from `modifiers` above; it still means the press was not
    // bare, and a path asking that question reads this.
    constexpr unsigned anyModifier = GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SHIFT_MASK | GDK_SUPER_MASK;
    press.wasModified = (static_cast<unsigned>(state) & anyModifier) != 0;
    press.modifiers = modifiers | (static_cast<std::uint32_t>(activePane()->keyPositionModifiers) << Ubiquitty::Keys::positionModifierShift);
    press.eventType = Ubiquitty::Keys::KeyEventType::Press;

    // The key's identity. A keypad key has no functional identity of its own —
    // virtualKeyFor leaves it None so the legacy encoder keeps the typed
    // character — but under Kitty the CSI-u form carries the keypad code point.
    // Which table answers is Core's, from this one field.
    const Ubiquitty::Keys::VirtualKey functionalKey = virtualKeyFor(keyval);
    press.virtualKey = functionalKey != Ubiquitty::Keys::VirtualKey::None
        ? functionalKey
        : keypadVirtualKeyFor(keyval);
    if (press.virtualKey == Ubiquitty::Keys::VirtualKey::None)
        press.virtualKey = physicalPrintableKey(keycode);

    // The two faces of a printable key. GDK hands over the shifted one, so the
    // unshifted face comes back from the layout; when the layout cannot answer
    // (no keycode) both faces are the same and Core reports the one key.
    const std::uint32_t typed = gdk_keyval_to_unicode(keyval);
    press.shiftedCodePoint = typed;
    press.unshiftedCodePoint = gdk_keyval_to_unicode(unshiftedKeyval(keycode, keyval));
    if (press.unshiftedCodePoint == 0)
        press.unshiftedCodePoint = typed;
    if (typed != 0) {
        press.text[0] = typed;
        press.textLength = 1;
    }

    // DECCKM, DECPAM, VT52, LNM, the modifyOtherKeys levels, DECUDK and the
    // Kitty flag stack all belong to the pane's terminal, so the snapshot is
    // handed over whole. A frontend that reads them one at a time owns a copy
    // of the encoder's argument list, and each arm picks a different field.
    char bytes[64];
    const int count = Ubiquitty::Runtime::encodeKey(activePane()->modes, activePane()->session->link(), press, bytes).length;
    if (count <= 0)
        return false;
    activePane()->session->sendInput({ bytes, static_cast<std::size_t>(count) });
    armPTYWriteDrain(activePane());
    return true;
}

// GDK modifier state → the four facts Core's chord rules are asked of. Super is
// this desktop's Command: a spec naming "cmd" or "super" means the same key.
Ubiquitty::Input::HeldModifiers heldModifiers(GdkModifierType state)
{
    return { .hasCommand = (state & GDK_SUPER_MASK) != 0,
        .hasControl = (state & GDK_CONTROL_MASK) != 0,
        .hasAlternate = (state & GDK_ALT_MASK) != 0,
        .hasShift = (state & GDK_SHIFT_MASK) != 0 };
}

// GDK modifier state → the KEYMAP_MOD_* bitmask the shared encoders read. Super is
// carried (the Kitty protocol reports it); Caps Lock maps to keymapModifierCapsLock.
std::uint32_t gdkModifierMask(GdkModifierType state)
{
    std::uint32_t modifiers = 0;
    if (state & GDK_SHIFT_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierShift;
    if (state & GDK_ALT_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierAlternate;
    if (state & GDK_CONTROL_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierCtrl;
    if (state & GDK_SUPER_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierSuper;
    if (state & GDK_LOCK_MASK)
        modifiers |= Ubiquitty::Keys::Keymap::keymapModifierCapsLock;
    return modifiers;
}

// Forward a bare modifier key (Ctrl/Shift/Alternate/Super) as a Kitty press or
// release. Which bytes it becomes is Runtime::encodeKey's, as it is for every
// other key: the REPORT_ALL gate and the CSI-u form sit behind that call, and
// this only maps the native keyval to its virtual key and supplies the modifier
// mask. eventType comes from which GTK handler fired. Returns whether bytes were
// sent (so the caller can swallow the key). Only REPORT_ALL apps expect these;
// a release is dropped unless REPORT_EVENTS is set.
bool forwardModifierKeyEvent(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType eventType)
{
    const Ubiquitty::Keys::VirtualKey modifierKey = modifierVirtualKeyFor(keyval);
    if (Ubiquitty::Keys::modifierKittyCodePoint(modifierKey) == 0)
        return false;

    Ubiquitty::Runtime::KeyPress press;
    press.eventType = eventType;
    press.virtualKey = modifierKey;
    press.modifiers = gdkModifierMask(state) | (static_cast<std::uint32_t>(activePane()->keyPositionModifiers) << Ubiquitty::Keys::positionModifierShift);
    press.wasModified = press.modifiers != 0;

    char bytes[64];
    const int count = Ubiquitty::Runtime::encodeKey(activePane()->modes, activePane()->session->link(), press, bytes).length;
    if (count <= 0)
        return false;
    activePane()->session->sendInput({ bytes, static_cast<std::size_t>(count) });
    armPTYWriteDrain(activePane());
    return true;
}

// Paste.

// Send pasted text to the PTY via the shared, fence-safe wrapPaste
// (Source/Core/Input/PasteNormalize.h): CR/LF is normalised, any embedded
// ESC[200~ / ESC[201~ fence marker is neutralised, and the body is wrapped in
// the bracketed-paste guards (DECSET 2004) when the gtkApplication enabled the mode so it
// can tell a paste from typed input. Routing through the shared helper keeps
// the bytes byte-identical with the macOS frontend.
void pasteText(std::string_view text)
{
    if (text.empty())
        return;
    activePane()->session->sendPaste(std::string(text));
    armPTYWriteDrain(activePane());
}

// File drop.

// Assemble dropped file paths into ready-to-paste shell arguments: each path
// shell-escaped (the shared Input::shellEscapedPath — the dropped-path escaping rule),
// space-separated with a trailing space so the drop reads as ready-to-use
// arguments at the prompt. Empty paths are skipped. Tested via --smoke-drop.
std::string assembleDroppedPaths(const std::vector<std::string>& paths)
{
    std::string outputBuffer;
    for (const std::string& path : paths) {
        if (path.empty())
            continue;
        outputBuffer += Ubiquitty::Input::shellEscapedPath(path);
        outputBuffer += ' ';
    }
    return outputBuffer;
}

// GtkDropTarget "drop" handler: a file (or files) dropped on a pane writes the
// escaped paths to the PTY verbatim (the escaping is the safety — not a bracketed
// paste). Mirrors macOS UBTerminalView -performDragOperation:.
gboolean onFileDrop(GtkDropTarget*, const GValue* value, double, double, gpointer userData)
{
    LinuxPane* pane = static_cast<LinuxPane*>(userData);
    if (pane == nullptr || !G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST))
        return FALSE;
    GdkFileList* fileList = static_cast<GdkFileList*>(g_value_get_boxed(value));
    if (fileList == nullptr)
        return FALSE;
    std::vector<std::string> paths;
    for (GSList* node = gdk_file_list_get_files(fileList); node != nullptr; node = node->next) {
        char* path = g_file_get_path(G_FILE(node->data)); // transfer full
        if (path != nullptr)
            paths.emplace_back(path);
        g_free(path);
    }
    const std::string outputBuffer = assembleDroppedPaths(paths);
    if (outputBuffer.empty())
        return FALSE;
    pane->session->sendInput(outputBuffer);
    armPTYWriteDrain(pane);
    return TRUE;
}

// --smoke-softfont — the DECDLD staging seam on the Vulkan backend, headlessly.
// Core rasterises a soft font into a coverage plane and hands it over; the
// backend's whole obligation is to copy it into the slot the cache assigned. The
// mirror the image uploads from is readable without a device, so the placement
// is checkable on a machine with no GPU — which is every machine this runs on.
//
// --smoke-readback-memory — the frame is read back from cached memory.
//
// The readback staging buffer is written by the GPU and read by the host, and
// the memory type decides how fast that read is. On discrete GPUs the
// host-visible types that are coherent but not cached are write-combined: a CPU
// read from them bypasses the cache and runs about an order of magnitude slower
// than normal memory, which for a full frame is megabytes per repaint.
//
// This machine's device offers whatever it offers, so the choice is checked
// against memory tables rather than against hardware -- the tables below are
// the shapes real devices have, including the one where the only cached type is
// not coherent and the caller has to invalidate before reading. Getting that
// second one wrong reads the previous frame, and on the first frame reads
// nothing at all.
int smokeReadbackMemory()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-readback-memory: FAIL: {}", what);
            ok = false;
        }
    };

    constexpr VkMemoryPropertyFlags deviceLocal = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    constexpr VkMemoryPropertyFlags writeCombined = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    constexpr VkMemoryPropertyFlags cachedCoherent
        = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    constexpr VkMemoryPropertyFlags cachedOnly = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    constexpr std::uint32_t everyType = 0xFFFFFFFFu;

    // A discrete GPU: device-local, a write-combined upload type, and a cached
    // readback type. The cached one is the answer even though the
    // write-combined type comes first and satisfies the old flags.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedCoherent };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 2, "a cached type was passed over for a write-combined one");
        check(choice.isCoherent, "a cached coherent type was reported as needing an invalidate");
    }

    // The device whose only cached type is not coherent. The choice must take
    // it and report that it is not coherent, since the caller then has to
    // invalidate before reading.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedOnly };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 2, "the only cached type was passed over");
        check(!choice.isCoherent, "a non-coherent type was reported as coherent, so no invalidate would run");
    }

    // No cached type at all: the write-combined one is what the device has.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == 1, "the only host-visible type was not chosen");
        check(choice.isCoherent, "a coherent type was reported as needing an invalidate");
    }

    // The buffer's own requirements exclude the cached type, which is the case
    // a chooser reading only the property flags gets wrong: it would name a
    // type this buffer cannot be bound to.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal, writeCombined, cachedCoherent };
        const std::uint32_t withoutCached = 0b011;
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, withoutCached);
        check(choice.typeIndex == 1, "a type the buffer cannot bind was chosen");
    }

    // Nothing host-visible: no answer rather than a wrong one.
    {
        const VkMemoryPropertyFlags types[] = { deviceLocal };
        const Ubiquitty::Linux::ReadbackMemoryChoice choice
            = Ubiquitty::Linux::chooseReadbackMemoryType(types, everyType);
        check(choice.typeIndex == UINT32_MAX, "a device with no host-visible type produced a type index");
    }

    Ubiquitty::PAL::logLine(stdout, "smoke-readback-memory: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// --smoke-coverage-sheet — a partial upload leaves the sheet holding the mirror.
//
// The glyph sheet is megabytes and a faulted glyph changes kilobytes of it, so
// the upload copies the band of rows the changed slots sit in rather than the
// whole thing. What can go wrong is the arithmetic: a wrong offset lands a
// glyph's coverage in a neighbouring slot, which draws as a different
// character rather than as an error. Nothing downstream reports it.
//
// So the sheet is read back and compared to the host mirror byte for byte. The
// image carries TRANSFER_SRC for this, and the comparison covers the whole
// sheet after a partial copy -- an offset that writes the right bytes to the
// wrong place fails on the rows it disturbed as much as on the rows it missed.
//
// Runs on whatever Vulkan device is present; the container's is lavapipe. The
// arithmetic under test is the host's, so a software device answers it exactly
// as a discrete one would.
int smokeCoverageSheet()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-coverage-sheet: FAIL: {}", what);
            ok = false;
        }
    };

    VkApplicationInfo applicationInfo {};
    applicationInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    applicationInfo.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo instanceInfo {};
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.pApplicationInfo = &applicationInfo;
    VkInstance instance = VK_NULL_HANDLE;
    if (vkCreateInstance(&instanceInfo, nullptr, &instance) != VK_SUCCESS) {
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no Vulkan instance)");
        return 0;
    }

    std::uint32_t deviceCount = 0;
    vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr);
    if (deviceCount == 0) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no Vulkan device)");
        return 0;
    }
    std::vector<VkPhysicalDevice> physicalDevices(deviceCount);
    vkEnumeratePhysicalDevices(instance, &deviceCount, physicalDevices.data());
    const VkPhysicalDevice physical = physicalDevices[0];

    std::uint32_t familyCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr);
    std::vector<VkQueueFamilyProperties> families(familyCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data());
    std::uint32_t familyIndex = familyCount;
    for (std::uint32_t i = 0; i < familyCount; ++i) {
        if (families[i].queueFlags & VK_QUEUE_TRANSFER_BIT) {
            familyIndex = i;
            break;
        }
    }
    if (familyIndex == familyCount) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no transfer queue)");
        return 0;
    }

    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueInfo {};
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueInfo.queueFamilyIndex = familyIndex;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    VkDeviceCreateInfo deviceInfo {};
    deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    VkDevice device = VK_NULL_HANDLE;
    if (vkCreateDevice(physical, &deviceInfo, nullptr, &device) != VK_SUCCESS) {
        vkDestroyInstance(instance, nullptr);
        Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: SKIP (no logical device)");
        return 0;
    }
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, familyIndex, 0, &queue);

    VkCommandPoolCreateInfo poolInfo {};
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.queueFamilyIndex = familyIndex;
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    check(vkCreateCommandPool(device, &poolInfo, nullptr, &commandPool) == VK_SUCCESS, "command pool");

    // Small enough to compare exhaustively, and not a multiple of anything the
    // copy might round to: a width that is a nice power of two would hide a
    // stride mistake that a real sheet's width would expose.
    constexpr int sheetWidth = 96;
    constexpr int sheetHeight = 64;
    constexpr int bandHeight = 16; // one slot row

    Ubiquitty::Linux::VulkanCoverageSheet sheet;
    check(sheet.create(device, physical, sheetWidth, sheetHeight), "sheet created");

    std::vector<std::uint8_t> mirror(static_cast<std::size_t>(sheetWidth) * sheetHeight);
    // A value that varies along each axis, so a copy landing at the wrong row
    // shows up as a mismatch rather than as the same byte in a different place.
    const auto fillMirror = [&](std::uint8_t salt) {
        for (int y = 0; y < sheetHeight; ++y) {
            for (int x = 0; x < sheetWidth; ++x)
                mirror[static_cast<std::size_t>(y) * sheetWidth + x] = static_cast<std::uint8_t>(x * 3 + y * 7 + salt);
        }
    };
    fillMirror(0);
    check(sheet.upload(device, queue, commandPool, mirror), "the whole sheet uploaded");

    // Read the image back into a host-visible buffer.
    const auto readImage = [&](VkImage image, int imageWidth, int imageHeight, int bytesPerPixel, std::vector<std::uint8_t>& out) {
        const std::size_t byteCount = static_cast<std::size_t>(imageWidth) * imageHeight * bytesPerPixel;
        out.assign(byteCount, 0);
        VkBufferCreateInfo bufferInfo {};
        bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bufferInfo.size = byteCount;
        bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        VkBuffer readbackBuffer = VK_NULL_HANDLE;
        if (vkCreateBuffer(device, &bufferInfo, nullptr, &readbackBuffer) != VK_SUCCESS)
            return false;
        VkMemoryRequirements requirements {};
        vkGetBufferMemoryRequirements(device, readbackBuffer, &requirements);
        VkMemoryAllocateInfo allocateInfo {};
        allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocateInfo.allocationSize = requirements.size;
        allocateInfo.memoryTypeIndex = Ubiquitty::Linux::findVulkanMemoryType(physical, requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        VkDeviceMemory readbackMemory = VK_NULL_HANDLE;
        if (vkAllocateMemory(device, &allocateInfo, nullptr, &readbackMemory) != VK_SUCCESS) {
            vkDestroyBuffer(device, readbackBuffer, nullptr);
            return false;
        }
        vkBindBufferMemory(device, readbackBuffer, readbackMemory, 0);

        VkCommandBufferAllocateInfo commandInfo {};
        commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        commandInfo.commandPool = commandPool;
        commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        commandInfo.commandBufferCount = 1;
        VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
        vkAllocateCommandBuffers(device, &commandInfo, &commandBuffer);
        VkCommandBufferBeginInfo beginInfo {};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(commandBuffer, &beginInfo);

        VkImageMemoryBarrier toSource {};
        toSource.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toSource.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        toSource.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        toSource.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toSource.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toSource.image = image;
        toSource.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        toSource.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        toSource.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &toSource);

        VkBufferImageCopy region {};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = { static_cast<uint32_t>(imageWidth), static_cast<uint32_t>(imageHeight), 1 };
        vkCmdCopyImageToBuffer(commandBuffer, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            readbackBuffer, 1, &region);

        VkImageMemoryBarrier backToShader = toSource;
        backToShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        backToShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        backToShader.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        backToShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &backToShader);

        vkEndCommandBuffer(commandBuffer);
        VkSubmitInfo submit {};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
        vkQueueWaitIdle(queue);
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);

        void* mapped = nullptr;
        const bool didMap = vkMapMemory(device, readbackMemory, 0, byteCount, 0, &mapped) == VK_SUCCESS;
        if (didMap) {
            std::memcpy(out.data(), mapped, byteCount);
            vkUnmapMemory(device, readbackMemory);
        }
        vkDestroyBuffer(device, readbackBuffer, nullptr);
        vkFreeMemory(device, readbackMemory, nullptr);
        return didMap;
    };

    std::vector<std::uint8_t> readback;
    check(readImage(sheet.imageForReadback(), sheetWidth, sheetHeight, 1, readback), "the sheet read back");
    check(readback == mirror, "a whole-sheet upload did not leave the sheet holding the mirror");

    // One band changed, and only that band copied. The comparison is over the
    // whole sheet: rows outside the band must still hold what the first upload
    // put there, and rows inside it must hold the new bytes.
    fillMirror(0x5A);
    constexpr int bandFirstRow = bandHeight * 2;
    check(sheet.upload(device, queue, commandPool, mirror, bandFirstRow, bandHeight), "the band uploaded");
    std::vector<std::uint8_t> afterBand;
    check(readImage(sheet.imageForReadback(), sheetWidth, sheetHeight, 1, afterBand), "the sheet read back after the band");

    bool doesBandMatch = true;
    bool isOutsideKept = true;
    for (int y = 0; y < sheetHeight; ++y) {
        for (int x = 0; x < sheetWidth; ++x) {
            const std::size_t index = static_cast<std::size_t>(y) * sheetWidth + x;
            const bool isInBand = y >= bandFirstRow && y < bandFirstRow + bandHeight;
            if (isInBand) {
                if (afterBand[index] != mirror[index])
                    doesBandMatch = false;
            } else if (afterBand[index] != static_cast<std::uint8_t>(x * 3 + y * 7)) {
                isOutsideKept = false;
            }
        }
    }
    check(doesBandMatch, "the copied band does not hold the new bytes");
    check(isOutsideKept, "a band copy disturbed rows outside it");

    // A range past the end is refused rather than clamped.
    check(!sheet.upload(device, queue, commandPool, mirror, sheetHeight - 1, bandHeight), "a range past the sheet was accepted");
    check(!sheet.upload(device, queue, commandPool, mirror, -1, bandHeight), "a negative first row was accepted");
    // An empty range is a caller saying nothing changed.
    check(sheet.upload(device, queue, commandPool, mirror, 0, 0), "an empty range was refused");

    // Two independent staging buffers share one submission. Recording alone
    // must not publish an image layout: the caller can discard that command
    // buffer before it ever reaches the queue.
    {
        Ubiquitty::Linux::VulkanCoverageSheet batchedSheet;
        Ubiquitty::Rendering::UnifontRasterizer batchedRasterizer;
        Ubiquitty::Linux::VulkanColorGlyphAtlas batchedColor(batchedRasterizer, 16);
        const bool wereSheetsCreated = batchedSheet.create(device, physical, sheetWidth, sheetHeight)
            && batchedColor.create(device, physical);
        check(wereSheetsCreated, "batched sheets created");
        VkCommandBufferAllocateInfo allocateInfo {};
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocateInfo.commandPool = commandPool;
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocateInfo.commandBufferCount = 1;
        VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
        const bool wasCommandAllocated = vkAllocateCommandBuffers(device, &allocateInfo, &commandBuffer) == VK_SUCCESS;
        check(wasCommandAllocated, "batch command buffer allocated");
        const auto beginBatch = [&] {
            VkCommandBufferBeginInfo beginInfo {};
            beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            return vkResetCommandBuffer(commandBuffer, 0) == VK_SUCCESS
                && vkBeginCommandBuffer(commandBuffer, &beginInfo) == VK_SUCCESS;
        };
        const auto submitBatch = [&] {
            if (vkEndCommandBuffer(commandBuffer) != VK_SUCCESS)
                return false;
            VkSubmitInfo submit {};
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &commandBuffer;
            return vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS
                && vkQueueWaitIdle(queue) == VK_SUCCESS;
        };
        if (wereSheetsCreated && wasCommandAllocated) {
            bool didRecord = beginBatch()
                && batchedSheet.recordUpload(device, commandBuffer, mirror, 0, sheetHeight);
            check(didRecord, "discarded upload recorded");
            check(!batchedSheet.isReadable(), "recording published an unsubmitted image layout");
            // Discard the recorded copy, then submit an empty replacement. Its
            // completion must not commit the abandoned copy's pending state.
            const bool didCompleteEmpty = didRecord && beginBatch()
                && batchedSheet.recordUpload(device, commandBuffer, mirror, 0, 0)
                && submitBatch();
            check(didCompleteEmpty, "empty replacement completed");
            if (didCompleteEmpty)
                batchedSheet.didUpload();
            check(!batchedSheet.isReadable(), "empty replacement committed an abandoned copy");

            didRecord = didCompleteEmpty && beginBatch()
                && batchedSheet.recordUpload(device, commandBuffer, mirror, 0, sheetHeight)
                && batchedColor.recordUpload(device, commandBuffer);
            check(didRecord, "both sheet uploads recorded");
            check(!batchedSheet.isReadable(), "batch recording published an incomplete image layout");
            const bool didComplete = didRecord && submitBatch();
            check(didComplete, "both sheets completed in one submission");
            if (didComplete) {
                check(!batchedSheet.isReadable(), "completion bypassed the upload commit");
                batchedSheet.didUpload();
                batchedColor.didUpload();
                check(batchedSheet.isReadable(), "completed upload did not publish its image layout");
                std::vector<std::uint8_t> batchedReadback;
                const bool didReadCoverage = readImage(batchedSheet.imageForReadback(), sheetWidth, sheetHeight, 1, batchedReadback);
                check(didReadCoverage && batchedReadback == mirror, "batched coverage differs from its mirror");
                const bool didReadColor = readImage(batchedColor.imageForReadback(), batchedColor.widthForReadback(), batchedColor.heightForReadback(), 4, batchedReadback);
                const auto colorMirror = batchedColor.mirrorForReadback();
                check(didReadColor && batchedReadback.size() == colorMirror.size()
                        && std::equal(colorMirror.begin(), colorMirror.end(), batchedReadback.begin()),
                    "batched color differs from its mirror");
            }
        }
        if (wasCommandAllocated)
            vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        batchedColor.destroy(device);
        batchedSheet.destroy(device);
    }

    sheet.destroy(device);

    // The colour sheet, which has no other check at all. The CPU renderer holds
    // no colour atlas, so the CPU/GPU oracle that covers the mono path cannot
    // see an emoji -- and this sheet is four bytes per pixel, so its band
    // arithmetic multiplies where the mono sheet's does not. That is the one
    // place a stride mistake can hide.
    {
        Ubiquitty::Rendering::UnifontRasterizer colorRasterizer;
        Ubiquitty::Linux::VulkanColorGlyphAtlas colorAtlas(colorRasterizer, 16);
        if (!colorAtlas.create(device, physical)) {
            Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: colour sheet not created (skipped)");
        } else {
            const int colorWidth = colorAtlas.widthForReadback();
            const int colorHeight = colorAtlas.heightForReadback();
            const int slotEdge = colorAtlas.slotEdgeForReadback();
            check(colorWidth > 0 && colorHeight > 0 && slotEdge > 0, "the colour sheet reports an extent");

            check(colorAtlas.upload(device, queue, commandPool), "the whole colour sheet uploaded");

            // A slot in a middle band, so a band that lands at the top or runs
            // to the end is a mismatch rather than a coincidence.
            const int columns = colorWidth / slotEdge;
            check(columns > 0, "the colour sheet has a slot grid");
            // Rasterising into a slot is the public way to move the mirror.
            // Whether the bundled font has a colour face for the code point
            // decides the pixels, not the band: either way the slot is written
            // and the band that carries it is what this checks.
            const int touchedSlot = columns * 2 + 1;
            constexpr std::uint32_t grinningFace = 0x1F600;
            (void)colorAtlas.rasteriseColorGlyph(&grinningFace, 1, touchedSlot);
            check(colorAtlas.upload(device, queue, commandPool), "the colour band uploaded");

            const std::span<const std::uint8_t> colorMirror = colorAtlas.mirrorForReadback();
            std::vector<std::uint8_t> colorReadback(colorMirror.size(), 0);
            const bool didReadColor = readImage(colorAtlas.imageForReadback(), colorWidth, colorHeight, 4, colorReadback);
            check(didReadColor, "the colour sheet read back");
            if (didReadColor) {
                check(std::equal(colorMirror.begin(), colorMirror.end(), colorReadback.begin()),
                    // copy-ok: a self-check verdict for the harness log, not interface text
                    "the colour sheet does not hold its mirror after a band upload");
            }
            colorAtlas.destroy(device);
        }
    }

    vkDestroyCommandPool(device, commandPool, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);

    Ubiquitty::PAL::logLine(stdout, "smoke-coverage-sheet: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// --smoke-atlas-capacity — the atlas is cut for the screen it serves.
//
// A glyph the atlas has no slot for draws as bare background, so running out is
// a missing character rather than a slow frame -- and the CPU renderer has no
// atlas to run out of, so the two backends disagree about what is on screen. A
// fixed thousand slots is under one screenful of a large window: 200x50 is
// 10000 cells, and a screenful of CJK prose or a mixed-script editor reaches
// that many distinct glyphs without trying.
//
// Headless: the sizing is decided in the constructor from the cell metrics and
// the texture limit, so no device is needed to ask what it decided.
int smokeAtlasCapacity()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-atlas-capacity: FAIL: {}", what);
            ok = false;
        }
    };

    // A device limit large enough that the grid, not the clamp, is what this
    // measures. The clamp has its own coverage; what is checked here is the
    // request reaching it.
    constexpr int textureLimit = 16384;
    Ubiquitty::Rendering::UnifontRasterizer rasterizer;

    Ubiquitty::Linux::VulkanGlyphAtlas unmeasured(8, 16, rasterizer, textureLimit, /*cellsInWidestScreen=*/0);
    const int floorCapacity = unmeasured.bindMonoAtlas().slotCapacity;
    check(floorCapacity > 0, "an atlas with no screen measurement still has slots");

    // An ordinary large window, whose cells a fixed thousand slots cannot hold.
    constexpr int wideScreenCells = 200 * 50;
    Ubiquitty::Linux::VulkanGlyphAtlas measured(8, 16, rasterizer, textureLimit, wideScreenCells);
    const int measuredCapacity = measured.bindMonoAtlas().slotCapacity;

    check(measuredCapacity > floorCapacity, "a measured screen does not enlarge the atlas");
    check(measuredCapacity >= wideScreenCells,
        "the atlas cannot hold one screenful, so a screen of distinct glyphs draws blanks");

    // Bigger screen, bigger atlas: the size tracks the grid rather than sitting
    // at whichever constant was written down.
    Ubiquitty::Linux::VulkanGlyphAtlas larger(8, 16, rasterizer, textureLimit, 300 * 80);
    check(larger.bindMonoAtlas().slotCapacity > measuredCapacity, "a larger screen does not enlarge the atlas further");

    Ubiquitty::PAL::logLine(stdout, "smoke-atlas-capacity: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// The failure this exists for is a row pitch that walks: a plane blitted with the
// wrong stride lands partly in the NEIGHBOURING slot, and every count stays
// right, so a test that only asks "did the slot change" passes on it.
int smokeSoftFont()
{
    Ubiquitty::Rendering::UnifontRasterizer rasterizer;
    Ubiquitty::Linux::VulkanGlyphAtlas atlas(8, 16, rasterizer);
    const Ubiquitty::Rendering::MonoAtlasBinding binding = atlas.bindMonoAtlas();
    const int slotWidth = binding.geometry.slotWidthInPixels;
    const int slotHeight = binding.geometry.slotHeightInPixels;
    const int columns = binding.geometry.columns;
    const int count = slotWidth * slotHeight;
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-softfont: FAIL: {}", what);
            ok = false;
        }
    };
    check(slotWidth > 0 && slotHeight > 0 && columns > 0, "the atlas reports a slot grid");
    check(binding.slotCapacity > columns, "the atlas holds more than one row of slots");
    if (!ok)
        return 1;

    // Slot 1 and slot 1+columns bracket slot 0: one to its right, one below it, so
    // a stride that is too long and one that is too short both land in a slot this
    // reads afterwards.
    const int target = 1;
    const int rightNeighbour = 2;
    const int belowNeighbour = 1 + columns;
    std::vector<std::uint8_t> plane(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i)
        plane[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(1 + (i % 255));

    auto slotByte = [&](int slot, int x, int y) {
        const std::span<const std::uint8_t> mirror = atlas.monoCoverage();
        const int x0 = (slot % columns) * slotWidth;
        const int y0 = (slot / columns) * slotHeight;
        return mirror[static_cast<std::size_t>(y0 + y) * static_cast<std::size_t>(atlas.atlasWidthInPixels()) + static_cast<std::size_t>(x0 + x)];
    };
    auto slotIsBlank = [&](int slot) {
        for (int y = 0; y < slotHeight; ++y)
            for (int x = 0; x < slotWidth; ++x)
                if (slotByte(slot, x, y) != 0)
                    return false;
        return true;
    };

    check(slotIsBlank(target) && slotIsBlank(rightNeighbour) && slotIsBlank(belowNeighbour), "the slots start blank");

    const std::span<const std::uint8_t> wholePlane { plane };

    // A plane the wrong shape is refused, and refusing means writing nothing —
    // a partial blit that then reports false is the same defect wearing a verdict.
    // A span carries its own length, so a pointer that disagrees with the count is
    // not a case this can be handed; an EMPTY span is what takes its place.
    check(!atlas.stageMonoCoverage(target, wholePlane.first(static_cast<std::size_t>(count) - 1)), "a short plane is refused");
    check(!atlas.stageMonoCoverage(target, {}), "an empty plane is refused");
    check(!atlas.stageMonoCoverage(-1, wholePlane), "a negative slot is refused");
    check(!atlas.stageMonoCoverage(binding.slotCapacity, wholePlane), "a slot past the end is refused");
    check(slotIsBlank(target), "a refused plane wrote nothing");

    check(atlas.stageMonoCoverage(target, wholePlane), "a correctly shaped plane is staged");

    int wrong = 0;
    for (int y = 0; y < slotHeight; ++y)
        for (int x = 0; x < slotWidth; ++x)
            if (slotByte(target, x, y) != plane[static_cast<std::size_t>(y) * static_cast<std::size_t>(slotWidth) + static_cast<std::size_t>(x)])
                ++wrong;
    check(wrong == 0, "every byte landed where the slot box says it goes");
    check(slotIsBlank(rightNeighbour), "the slot to the right is untouched");
    check(slotIsBlank(belowNeighbour), "the slot below is untouched");

    Ubiquitty::PAL::logLine(stdout, "smoke-softfont: slot={}x{} columns={} misplaced={} -- {}", slotWidth, slotHeight, columns, wrong, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

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

// --smoke-drop — headless check of the drop assembly (the GtkDropTarget wiring is
// build-verified; the live drag needs a display): spaces, shell metacharacters,
// and parentheses are backslash-escaped, multibyte UTF-8 passes through, paths
// are space-joined with a trailing space.
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

// GTK clipboard reads are async; the read completes here on the main thread.
// `source` is the GdkClipboard the read was started on (the system clipboard for
// Ctrl+Shift+V, the PRIMARY selection for middle-click). NULL text = empty /
// non-text clipboard → nothing to paste.
void onClipboardPasted(GObject* source, GAsyncResult* result, gpointer)
{
    char* text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, nullptr);
    if (text) {
        pasteText(text);
        g_free(text);
    }
}

// The find bar reads search publications without waiting for the scan. Reveal
// generations belong to the pane, so an inactive pane cannot move the active one.
void showSearchOutcome(LinuxPane& pane, const Ubiquitty::Search::Status& status)
{
    if (&pane == activePane() && app().searchLabel) {
        const std::string text = Ubiquitty::Runtime::searchCounterText(status.foundCount, status.activeIndex, status.isPatternInvalid, status.isComplete);
        gtk_label_set_text(GTK_LABEL(app().searchLabel), text.c_str());
    }
    const bool shouldReveal = pane.searchRevealGeneration != status.generation || pane.searchRevealEpoch != status.revealEpoch;
    pane.searchRevealGeneration = status.generation;
    pane.searchRevealEpoch = status.revealEpoch;
    if (shouldReveal && status.revealViewOffset >= 0)
        pane.viewOffset = status.revealViewOffset;
    requestRepaint();
}

void runSearch(Ubiquitty::Runtime::TerminalSession* session, const char* pattern)
{
    if (!session)
        return;
    (void)session->setSearchQuery(pattern ? pattern : "", Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Regex, Ubiquitty::CaseSensitivity::Insensitive);
    if (activePane()->session == session)
        showSearchOutcome(*activePane(), session->searchStatus());
}

// Automation waits through the same controller the live entry queues.
Ubiquitty::Search::Status runSearchAndWait(Ubiquitty::Runtime::TerminalSession* session, const char* pattern,
    Ubiquitty::Runtime::TerminalSession::SearchPatternForm form = Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Regex)
{
    if (!session)
        return {};
    const auto status = session->searchScrollbackAndWait(pattern ? pattern : "", form, Ubiquitty::CaseSensitivity::Insensitive);
    if (activePane()->session == session)
        showSearchOutcome(*activePane(), status);
    return status;
}

Ubiquitty::Search::Status onSearchStep(Ubiquitty::Runtime::TerminalSession* session, Ubiquitty::Runtime::TerminalSession::SearchStep step)
{
    if (!session)
        return {};
    (void)session->stepSearchMatch(step);
    const auto status = session->searchStatus();
    if (activePane()->session == session)
        showSearchOutcome(*activePane(), status);
    return status;
}

void onSearchChanged(GtkSearchEntry* entry, gpointer) { runSearch(activePane()->session, gtk_editable_get_text(GTK_EDITABLE(entry))); }
void onSearchActivate(GtkSearchEntry*, gpointer) { onSearchStep(activePane()->session, Ubiquitty::Runtime::TerminalSession::SearchStep::Forward); }
void onSearchNext(GtkSearchEntry*, gpointer) { onSearchStep(activePane()->session, Ubiquitty::Runtime::TerminalSession::SearchStep::Forward); }
void onSearchPrevious(GtkSearchEntry*, gpointer) { onSearchStep(activePane()->session, Ubiquitty::Runtime::TerminalSession::SearchStep::Backward); }

void hideSearchBar()
{
    if (!app().searchBar)
        return;
    gtk_search_bar_set_search_mode(GTK_SEARCH_BAR(app().searchBar), FALSE);
    if (Ubiquitty::Runtime::TerminalSession* session = activePane()->session)
        session->clearScrollbackSearch();
    requestRepaint();
    if (app().window)
        gtk_widget_grab_focus(app().window);
}

void onSearchStop(GtkSearchEntry*, gpointer) { hideSearchBar(); }

void showSearchBar()
{
    if (!app().searchBar)
        return;
    gtk_search_bar_set_search_mode(GTK_SEARCH_BAR(app().searchBar), TRUE);
    if (app().searchEntry)
        gtk_widget_grab_focus(app().searchEntry);
}

// Process inspector (Ctrl+Shift+I).
// Lists the PTY session's process tree (parity with the macOS Inspector), each
// row marked by the portable PAL::Process::marker policy.

// One process row: "<marker> <name> (<pid>)". The marker is "$" / "#" for a
// (root) login shell, "•" for a process that isn't safe to close, else empty.
std::string formatProcessRow(const Ubiquitty::PAL::Process::Record& record)
{
    const bool isRoot = record.user == "root";
    const std::string_view marker = Ubiquitty::PAL::Process::marker(record.name, record.isSessionLeader ? Ubiquitty::PAL::Process::SessionLeaderStatus::Leader : Ubiquitty::PAL::Process::SessionLeaderStatus::NonLeader, isRoot ? Ubiquitty::PAL::Process::UserPrivilege::Root : Ubiquitty::PAL::Process::UserPrivilege::NonRoot);
    // A zombie/defunct process is tagged inline (the GTK list has no per-row
    // color yet); other states aren't surfaced. record.state stays Unknown until
    // the Linux /proc walk fills it (the gather is an inert stub today).
    const char* suffix = record.state == Ubiquitty::PAL::Process::State::Zombie ? " (zombie)" : "";
    std::string line;
    if (!marker.empty()) {
        line.append(marker);
        line.push_back(' ');
    }
    line.append(record.name);
    line.append(" (");
    line.append(std::to_string(record.processID));
    line.push_back(')');
    line.append(suffix);
    return line;
}

// Snapshot the session's process subtree to one row per line. The portable
// gatherProcesses fills the records; formatProcessRow renders each.
std::string buildProcessListText()
{
    Ubiquitty::PAL::Stream* stream = activePane()->session->stream();
    if (!stream)
        return "No session";
    Ubiquitty::PAL::Process::Record records[128];
    const int count = stream->process().gatherProcesses({ records, 128 });
    if (count <= 0)
        return "No running processes";
    std::string outputBuffer;
    for (int i = 0; i < count; ++i) {
        outputBuffer += formatProcessRow(records[i]);
        if (i + 1 < count)
            outputBuffer.push_back('\n');
    }
    return outputBuffer;
}

void refreshInspector()
{
    if (app().inspectorLabel)
        gtk_label_set_text(GTK_LABEL(app().inspectorLabel), buildProcessListText().c_str());
}

// Re-snapshot the tree while the inspector is shown (processes come and go with
// no byte traffic). Keeps the timer alive when hidden.
gboolean onInspectorRefresh(gpointer)
{
    if (app().inspectorWindow && gtk_widget_get_visible(app().inspectorWindow))
        refreshInspector();
    return G_SOURCE_CONTINUE;
}

void toggleInspector()
{
    if (app().inspectorWindow) {
        const gboolean visible = gtk_widget_get_visible(app().inspectorWindow);
        if (!visible)
            refreshInspector();
        gtk_widget_set_visible(app().inspectorWindow, !visible);
        return;
    }
    app().inspectorWindow = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(app().inspectorWindow), "Processes");
    gtk_window_set_default_size(GTK_WINDOW(app().inspectorWindow), 480, 320);
    if (app().window)
        gtk_window_set_transient_for(GTK_WINDOW(app().inspectorWindow), GTK_WINDOW(app().window));
    gtk_window_set_hide_on_close(GTK_WINDOW(app().inspectorWindow), TRUE); // Esc/close → hide, reuse
    GtkWidget* scroller = gtk_scrolled_window_new();
    app().inspectorLabel = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(app().inspectorLabel), 0.0F);
    gtk_label_set_yalign(GTK_LABEL(app().inspectorLabel), 0.0F);
    gtk_label_set_selectable(GTK_LABEL(app().inspectorLabel), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), app().inspectorLabel);
    gtk_window_set_child(GTK_WINDOW(app().inspectorWindow), scroller);
    refreshInspector();
    gtk_window_present(GTK_WINDOW(app().inspectorWindow));
}

// Bridge Terminal::rowMark to the shared prompt-navigation state machine's mark provider,
// matching the macOS wcRowMarkAt bridge so both frontends route through the same
// pure Ubiquitty::Screen::stepToPrompt.
static uint8_t paneRowMarkAt(void* context, int absoluteRow) { return Ubiquitty::Screen::rowMark(static_cast<const Ubiquitty::Terminal*>(context), absoluteRow); }

// Jump the focused pane's scrollback viewport to the previous (-1) or next (+1)
// shell prompt — OSC 133 CMD_EXECUTED marks (View > Jump to Prompt parity). The
// anchor-row state machine lives in Ubiquitty::Screen::stepToPrompt (shared with the
// macOS frontend): an anchor (promptNavigationRow) lets
// repeated jumps step prompt-by-prompt; from a fresh view it starts at the
// viewport edge. Lands the prompt one row below the top for preceding context.
// This shell only owns the GTK glue the result describes (bell / viewOffset /
// repaint).
void jumpToPrompt(int direction)
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    const auto hold = holdPaneModel(*activePane());
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    const Ubiquitty::Screen::PromptStepResult step = Ubiquitty::Screen::stepToPrompt(history, activePane()->rows, activePane()->viewOffset, activePane()->promptNavigationRow, direction, paneRowMarkAt, term, Ubiquitty::Screen::osc133MarkCmdExecuted);
    switch (step.action) {
    case Ubiquitty::Screen::PromptStepAction::Bell:
        if (app().window)
            gtk_widget_error_bell(app().window);
        return;
    case Ubiquitty::Screen::PromptStepAction::Scroll:
    case Ubiquitty::Screen::PromptStepAction::SnapToTail:
        activePane()->promptNavigationRow = step.newAnchor;
        activePane()->viewOffset = step.newViewOffset;
        requestRepaint();
        return;
    }
}

// [keys] bindings.
//
// The user's [keys] config (spec -> action) is consumed through the same
// portable Input::BindingTable + ChordResolver the macOS frontend uses, so a
// custom keymap, a leader/chord prefix, and the named action vocabulary behave
// identically on both. The only platform-specific glue is the GDK keyval ->
// KeyChord adapter (mapKeyvalToChord) and the action dispatch
// (executeBindingAction). The built-in GTK accelerators below (Ctrl+Shift+V/C/…)
// remain the defaults; a user binding for the same chord wins because the
// resolver runs FIRST and consumes the key on a match.

// (Re)build the binding table from the resolved [keys] config (global folded
// with the Linux platform overrides) and re-seed the resolver. Any in-progress
// chord prefix is dropped. Called once at startup; safe to call again if the
// config is reloaded.
void rebuildKeyBindings()
{
    app().bindingTable.clear();
    const std::vector<Ubiquitty::Preferences::KeyBindingEntry> bindings = Ubiquitty::Preferences::resolveCurrentKeyBindings(loadPreferences());
    for (const Ubiquitty::Preferences::KeyBindingEntry& binding : bindings)
        app().bindingTable.add(binding.spec, binding.action);
    app().chordResolver.emplace(app().bindingTable);

    // Every pane rebuilds: the trigger is one setting, and a pane left with
    // the previous one would compose by a key the reader has replaced.
    const std::string composeKey = loadPreferences().composeKey.value_or(std::string());
    for (const auto& pane : app().panes)
        pane->compose.rebuild(composeKey);
}

// GDK keyval + modifier state -> the Input::KeyChord a binding matches against.
// The chord key is the base-layout codePoint parseKeySpec produces: a
// KEYMAP_KK_* PUA codePoint for a functional key (reusing mapKey), otherwise the
// unshifted, lower-cased character. GDK already folds the active layout + shift
// into the keyval, but a binding written "cmd+k" matches the *unshifted* key, so
// we recover the layout-independent base via gdk_keyval_to_lower before mapping.
// resolveChordKey then folds ASCII letter case into the shift bit. Returns false
// (chord untouched) for a pure modifier / dead key with no usable codePoint.
bool mapKeyvalToChord(guint keyval, GdkModifierType state, Ubiquitty::Input::KeyChord& outputBuffer)
{
    Ubiquitty::Input::KeyChord chord;
    if (state & GDK_SHIFT_MASK)
        chord.modifiers |= Ubiquitty::Input::bindModShift;
    if (state & GDK_ALT_MASK)
        chord.modifiers |= Ubiquitty::Input::bindModAlternate;
    if (state & GDK_CONTROL_MASK)
        chord.modifiers |= Ubiquitty::Input::bindModCtrl;
    if (state & GDK_SUPER_MASK)
        chord.modifiers |= Ubiquitty::Input::bindModSuper;

    // Functional keys (arrows, F-keys, enter/tab/…) carry the same PUA identity
    // the keymap encoder uses, so reuse mapKey and match parseKeySpec's named
    // keys directly. Legacy, because a binding names a key the way a user writes
    // it in [keys] and that spelling does not change with the terminal's current
    // keyboard mode: a chord that matched before the program asked for Kitty has
    // to go on matching after.
    const MappedKey mapped = mapKey(keyval, Ubiquitty::Keys::KeyEncoder::Legacy);
    if (mapped.code == 0)
        return false;
    if (mapped.functional) {
        chord.key = mapped.code;
        outputBuffer = chord;
        return true;
    }

    // Printable: take the UNSHIFTED keyval so "shift+3" matches a "3" binding
    // (not the layout's shifted "#"), then fold letter case into the shift bit.
    const guint base = gdk_keyval_to_lower(keyval);
    const uint32_t codePoint = gdk_keyval_to_unicode(base);
    if (codePoint == 0)
        return false;
    // The unshifted keyval is already in hand above, so Core is given no layout
    // character to prefer: this arm has answered the question itself.
    chord.key = Ubiquitty::Input::resolveChordKey(codePoint, /*unshiftedLayoutCharacter*/ 0, chord.modifiers);
    outputBuffer = chord;
    return true;
}

// Toggle the window between fullscreen and normal (F11 / ToggleFullscreen).
void toggleFullscreen()
{
    app().isFullScreen = !app().isFullScreen;
    if (app().window) {
        if (app().isFullScreen)
            gtk_window_fullscreen(GTK_WINDOW(app().window));
        else
            gtk_window_unfullscreen(GTK_WINDOW(app().window));
    }
}

// Scroll the current prompt to the top of the screen — the Cmd-K gesture.
//
// Nothing is destroyed: the rows above the prompt go into scrollback exactly as
// ordinary output would have put them there. Under a program that owns the
// layout Core forwards Ctrl-L instead of guessing; the send lambda is what
// carries it. See `Core/Screen/ClearBuffer.h`.
// Sends what a clear verb asked the process for, once the model hold that
// composed it has ended: the send may take the model lock for its echo.
void sendBytesToActivePane(const std::string& bytes)
{
    if (bytes.empty())
        return;
    activePane()->session->sendInput(std::span<const char>(bytes.data(), bytes.size()));
    armPTYWriteDrain(activePane());
}

void clearScreenAction()
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    std::string bytesToSend;
    {
        const auto hold = holdPaneModel(*activePane());
        Ubiquitty::Screen::clearScreen(
            term, Ubiquitty::Screen::ClearBoundary::CurrentPrompt, &activePane()->selection.state,
            [] { activePane()->viewOffset = 0; },
            [&bytesToSend](std::span<const char> bytes) { bytesToSend.append(bytes.data(), bytes.size()); });
    }
    sendBytesToActivePane(bytesToSend);
    requestRepaint();
}

// Clear the screen and the scrollback, keeping a half-typed command line.
//
// The Ctrl-L the outcome carries is required, not decorative: without it the
// prompt sits at row 0 while the shell's line editor still echoes where it
// believes the prompt is. See `Core/Screen/ClearBuffer.h`.
void clearBufferAction()
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    std::string bytesToSend;
    {
        const auto hold = holdPaneModel(*activePane());
        Ubiquitty::Screen::clearBuffer(
            term, &activePane()->selection.state,
            [] { activePane()->viewOffset = 0; },
            [&bytesToSend](std::span<const char> bytes) { bytesToSend.append(bytes.data(), bytes.size()); });
    }
    sendBytesToActivePane(bytesToSend);
    requestRepaint();
}

// Drop the scrollback and leave the visible grid alone: history is not the
// screen, so this is not `clearBufferAction`.
void clearScrollbackAction()
{
    if (Ubiquitty::Terminal* term = activePane()->session->terminal()) {
        const auto hold = holdPaneModel(*activePane());
        Ubiquitty::Screen::clearScrollback(term, &activePane()->selection.state, [] { activePane()->viewOffset = 0; });
        requestRepaint();
    }
}

// Offset the local scrollback viewport by `lines` (positive = older history),
// clamped to the retained range. The page actions and the built-in
// Shift+PageUp both route through here with Core's one page amount.
void offsetViewByLines(int lines)
{
    activePane()->viewOffset += lines;
    clampActivePaneViewOffset(activePane()->session->terminal());
    requestRepaint();
}

// Run a resolved [keys] BindingAction by routing it to the frontend handler that
// implements the same command for the built-in accelerator. All decision logic
// already ran in the resolver; this is pure dispatch. Mirrors the macOS
// executeBindingAction so the two frontends honor the same action vocabulary.
void executeBindingAction(const Ubiquitty::Input::BindingAction& action)
{
    using Ubiquitty::Input::ActionKind;
    // Core's one page rule, shared with the built-in Shift+PageUp and the
    // macOS arms, so a bound page and a built-in page move the same distance.
    const int page = static_cast<int>(Ubiquitty::Keys::pageLinesForRows(activePane()->rows));
    switch (action.kind) {
    case ActionKind::None:
        break;

    case ActionKind::SendBytes:
        if (!action.bytes.empty()) {
            activePane()->session->sendInput({ action.bytes.data(), action.bytes.size() });
            armPTYWriteDrain(activePane());
            activePane()->viewOffset = 0; // typing snaps to the live tail
            requestRepaint();
        }
        break;

    case ActionKind::Copy:
        copySelectionToClipboard();
        break;
    case ActionKind::Paste:
        if (app().window)
            pasteClipboard(gtk_widget_get_clipboard(app().window), Ubiquitty::ClipboardBuffer::Clipboard);
        break;
    case ActionKind::SelectAll:
        selectAll();
        break;

    case ActionKind::ScrollLineUp:
        offsetViewByLines(+1);
        break;
    case ActionKind::ScrollLineDown:
        offsetViewByLines(-1);
        break;
    case ActionKind::ScrollPageUp:
        offsetViewByLines(+page);
        break;
    case ActionKind::ScrollPageDown:
        offsetViewByLines(-page);
        break;
    case ActionKind::ScrollToTop:
        activePane()->viewOffset = INT_MAX;
        clampActivePaneViewOffset(activePane()->session->terminal());
        requestRepaint();
        break;
    case ActionKind::ScrollToBottom:
        offsetViewByLines(-activePane()->viewOffset); // snap to the live tail
        break;

    case ActionKind::NewTab:
        newTab();
        break;
    case ActionKind::CloseTab:
        closeFocusedPaneUX();
        break;
    case ActionKind::NextTab:
        switchTabRelative(+1);
        break;
    case ActionKind::PrevTab:
        switchTabRelative(-1);
        break;

    case ActionKind::IncreaseFontSize:
        applyFontZoom(app().fontPixelSize + 1);
        break;
    case ActionKind::DecreaseFontSize:
        applyFontZoom(app().fontPixelSize - 1);
        break;
    case ActionKind::ResetFontSize:
        applyFontZoom(app().defaultFontPixelSize);
        break;

    case ActionKind::ToggleFullscreen:
        toggleFullscreen();
        break;
    case ActionKind::ClearScrollback:
        clearScrollbackAction();
        break;
    case ActionKind::ClearScreen:
        clearScreenAction();
        break;
    case ActionKind::ClearBuffer:
        clearBufferAction();
        break;

    // macro:<name> — look the body up in the live Settings, decode its escapes,
    // and send it to the focused pane (same path as SendBytes).
    case ActionKind::Macro: {
        const std::string* body = Ubiquitty::Preferences::findMacroBody(Ubiquitty::Preferences::values(), action.name);
        std::string decoded;
        if (body && Ubiquitty::Input::decodeSendPayload(*body, decoded) && !decoded.empty()) {
            activePane()->session->sendInput(decoded);
            armPTYWriteDrain(activePane());
            activePane()->viewOffset = 0;
            requestRepaint();
        }
        break;
    }

    // Beam draws into the grid here rather than into a native popover: GTK has no
    // equivalent of the macOS panel, and the in-grid surface is portable Core that
    // already renders identically in the browser.
    case ActionKind::ToggleBeam:
        if (!app().beamSession.isOpen()) {
            // Seeded on first open rather than at startup: the drill is the only
            // thing that reads it, and resolving [appearance] here keeps the
            // theme hookup in one place instead of two that must agree.
            if (app().liveThemeIndex < 0)
                app().liveThemeIndex = Ubiquitty::Runtime::launchThemeIndex(Ubiquitty::Preferences::values());
            const auto hold = holdPaneModel(*activePane());
            fillBeamScopes(activePane()->session->terminal());
        }
        app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
        requestRepaint();
        break;

    // No multi-window or named-command frontend dispatch on Linux yet; left
    // cleanly unhandled rather than inventing a half-feature (matches macOS).
    case ActionKind::NewWindow:
    case ActionKind::Named:
        break;
    }
}

// Carry out whatever the palette decided. Every command id except the theme
// drill is a named-action token, so running one is the same path a [keys]
// binding takes — Beam cannot drift from the keyboard, and an action added to
// Core's catalog works from both without being wired twice.
// Query edits enqueue a search; publications fill its list. Leaving the scope
// cancels the originating pane's query and drops its transient highlights.
void refreshBeamFindScope()
{
    using namespace Ubiquitty::CommandPalette;
    const bool isInFindScope = app().beamSession.isOpen() && app().beamSession.state().scope == Scope::Find;
    if (!isInFindScope) {
        if (app().wasBeamInFindScope) {
            app().wasBeamInFindScope = false;
            app().beamFindQuery.clear();
            if (LinuxPane* pane = app().beamFindPane.get(); pane && pane->session)
                pane->session->clearScrollbackSearch();
            app().beamFindPane = nullptr;
            app().beamFindTargets.clear();
            requestRepaint();
        }
        return;
    }

    const std::string& query = app().beamSession.state().query;
    if (!app().wasBeamInFindScope) {
        if (LinuxPane* pane = activePane())
            app().beamFindPane = pane->weakPtr();
    }
    LinuxPane* pane = app().beamFindPane.get();
    if (pane && pane->session && (!app().wasBeamInFindScope || query != app().beamFindQuery))
        pane->session->setSearchQuery(query, Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Regex, Ubiquitty::CaseSensitivity::Insensitive, -1, -1, Ubiquitty::Search::maxStoredLabels);
    app().wasBeamInFindScope = true;
    app().beamFindQuery = query;
    app().beamSession.setCommands(Scope::Find, beamFindCommands(pane));
}

// The configuration store's current text, empty when there is none yet.
//
// Through PAL's blob surface rather than a path, because this frontend has no
// path to use: the mapping from `configurationBlobKey` to
// `~/.config/ubiquitty/config.toml` is the POSIX backend's own and it does not
// publish it. Spelling that rule here would be a second copy that keeps writing
// to the old place the day the backend moves it.
std::string readPreferencesStore()
{
    const int size = Ubiquitty::PAL::preferencesLoad(Ubiquitty::PAL::configurationBlobKey, nullptr, 0);
    if (size <= 0)
        return {}; // absent or empty; a first write creates it
    std::string body(static_cast<std::size_t>(size), '\0');
    const int read = Ubiquitty::PAL::preferencesLoad(Ubiquitty::PAL::configurationBlobKey, body.data(), size);
    if (read < 0)
        return {};
    body.resize(static_cast<std::size_t>(read));
    return body;
}

// Re-read the font settings and rebuild the rasterizer around them.
//
// The shaping inputs — the feature run, the axis list, the weights — are
// resolved once in the rasterizer's constructor, because they are configuration
// and re-deriving them per shaped run would spend a parse on an answer that
// cannot change without a new rasterizer. That is true of the object and false
// of the session: a settings row changes them while one is alive.
//
// So a font key needs the object replaced, not merely the frame repainted.
// Reloading the values and calling `requestRepaint` redraws the same glyphs
// through the same shaper and shows nothing — which is the defect this whole
// surface exists to remove, one layer further in.
//
// `applyFontMode` afterwards re-points both backends at the new rasterizer and
// drops the caches keyed to the old one; without it the atlas keeps serving
// glyphs shaped under the previous settings.
void rebuildFontsFromPreferences()
{
    // Both backends release their borrowed-face caches before either face moves.
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    const Ubiquitty::Rendering::RenderConfiguration configuration = Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences());
    // Spacing is configured in points and reaches both faces in device pixels,
    // so it scales with the display exactly as it does at startup. The bitmap
    // face is rebuilt with it in either mode: its cell carries the spacing.
    const Ubiquitty::Linux::FaceSpacing spacing = Ubiquitty::Linux::faceSpacing(configuration, deviceFontPixelsPerPoint());
    app().lineSpacingPixels = spacing.lineSpacingInPixels;
    app().trackingPixels = spacing.characterSpacingInPixels;
    Ubiquitty::Linux::emplaceBitmapFace(app().unifontRasterizer, app().fontSizePoints, deviceFontPixelsPerPoint(), spacing);
    app().rasterContext.setEmbeddedBitmapScale(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap
            ? Ubiquitty::Rendering::unifontScaleForRequestedSize(app().fontSizePoints, deviceFontPixelsPerPoint())
            : 0);
    Ubiquitty::Linux::configureFontRouting(deviceFontPixelSize(), loadPreferences());
    // Unifont is a bitmap face with no shaper, so it has no feature run to
    // rebuild and `applyFontZoom` declines for the same reason.
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        applyFontMode();
        return;
    }
    app().fontFeatures = configuration.fontFeatures.string();
    app().fontVariations = configuration.fontVariations.string();
    app().ligatures = configuration.hasLigatures ? Ubiquitty::Linux::Ligatures::Enabled : Ubiquitty::Linux::Ligatures::Disabled;
    // The rest of the constructor's arguments are read from app() below, and
    // setupFonts is the only other writer of them — it runs once, behind
    // areFontsSetUp. Refreshed only the three above, a `[font] weight`, `width`,
    // `line_spacing` or `character_spacing` change re-emplaced the rasterizer
    // with the value it already had, so the setting did nothing until the next
    // launch while the caller's own comment says every key in the section feeds
    // this constructor.
    //
    // The weights and the width percent carry no unit and reach the face
    // unscaled.
    app().uprightWeight = configuration.fontWeight;
    app().boldWeight = configuration.boldFontWeight;
    app().widthPercent = configuration.fontWidthPercent;
    // The size is not re-read here. app().fontSizePoints is also
    // where applyFontZoom records a zoom step, so taking the configured size
    // back would discard the zoom on any unrelated `[font]` edit. A size change
    // that must take effect without a relaunch belongs on the zoom path, which
    // already re-emplaces the rasterizer and re-derives the grid.
    app().glyphRasterizer.emplace(deviceFontPixelSize(), app().fontFamily, app().fallbackFontName,
        app().bundledFallbackPath, bundledFontPathForFamily(app().fontFamily), app().scale,
        app().lineSpacingPixels, app().trackingPixels, app().uprightWeight, app().boldWeight,
        app().widthPercent, app().fontVariations, app().fontFeatures, app().ligatures,
        Ubiquitty::Preferences::buildFontRoutePreferences(loadPreferences()));
    applyFontMode();
}

// Put a settings change into effect: one key edited in the live document,
// which Core configures from and stores where the file a person edits lives.
// The window hears the configure through its subscription and redraws there,
// the same path a save from an editor takes.
bool applyBeamSetting(const Ubiquitty::Preferences::WriteDescriptor& descriptor, const Ubiquitty::Preferences::Value& value)
{
    return Ubiquitty::Preferences::configureOwnKey(descriptor.id, value).has_value();
}

void applyWindowGlobalRenderSettings(const Ubiquitty::Preferences::Values& config);
void applyPanePadding(LinuxPane& pane);
std::optional<std::string> readFeedFile(const char* path);

// Shows what the live configuration document could not apply in the bar under
// the panes, or hides the bar when it applied whole. A refused line is a
// setting the reader wrote and did not get, and standard error is not where
// they look. A line the reader dismissed stays hidden until the document says
// something else.
void updateConfigurationBar()
{
    if (!app().configurationBar)
        return;
    const std::string& line = app().configurationDiagnostic;
    const std::vector<std::string>& dismissed = app().dismissedConfigurationDiagnostics;
    const bool isShown = !line.empty() && std::find(dismissed.begin(), dismissed.end(), line) == dismissed.end();
    gtk_label_set_text(GTK_LABEL(app().configurationLabel), isShown ? line.c_str() : "");
    gtk_action_bar_set_revealed(GTK_ACTION_BAR(app().configurationBar), isShown);
}

// Reads the line Core composes for the live document's diagnostics, as the
// configure that just ran left them, and shows it.
void showConfigurationDiagnostics()
{
    const std::string summary = Ubiquitty::Preferences::liveDiagnosticSummary();
    app().configurationDiagnostic = summary.empty() ? std::string() : "config.toml " + summary;
    updateConfigurationBar();
}

// Hides the standing diagnostic and remembers that it was read.
void onConfigurationBarDismissed(GtkButton*, gpointer)
{
    const std::string& line = app().configurationDiagnostic;
    if (!line.empty())
        app().dismissedConfigurationDiagnostics.push_back(line);
    updateConfigurationBar();
}

// Builds the bar a configuration diagnostic is shown in: a GtkActionBar, which
// reveals and hides itself, as the window's last row. The button leaves focus
// where it was, so the next keystroke still reaches the terminal.
GtkWidget* makeConfigurationBar()
{
    app().configurationBar = gtk_action_bar_new();
    app().configurationLabel = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(app().configurationLabel), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(app().configurationLabel), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(app().configurationLabel), 0.0f);
    gtk_widget_set_hexpand(app().configurationLabel, TRUE);
    gtk_action_bar_pack_start(GTK_ACTION_BAR(app().configurationBar), app().configurationLabel);
    GtkWidget* dismiss = gtk_button_new_with_label("Dismiss");
    gtk_widget_set_focus_on_click(dismiss, FALSE);
    g_signal_connect(dismiss, "clicked", G_CALLBACK(onConfigurationBarDismissed), nullptr);
    gtk_action_bar_pack_end(GTK_ACTION_BAR(app().configurationBar), dismiss);
    updateConfigurationBar();
    return app().configurationBar;
}

// What a configure owes the open window: the process and per-terminal state,
// the window's render configuration, new faces when the typography moved, and
// a redraw of everything — the frontend reads most keys where it uses them.
void applyLiveConfiguration()
{
    // Before the early return: the startup configure runs before the faces and
    // the window exist, and the bar shows the line it finds once it is built.
    showConfigurationDiagnostics();
    // Before the faces exist there is nothing configured to re-apply: the
    // startup path reads the document it configured as it builds them.
    if (!app().areFontsSetUp)
        return;
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    applyProcessConfiguration(config);
    applyPerTerminalConfiguration(config);
    applyWindowGlobalRenderSettings(config);
    const Ubiquitty::Rendering::RenderConfiguration configuration = Ubiquitty::Preferences::Effective::renderConfiguration(config);
    if (!configuration.hasSameTypography(app().appliedRenderConfiguration))
        rebuildFontsFromPreferences();
    app().appliedRenderConfiguration = configuration;
    for (const auto& pane : app().panes) {
        applyPanePadding(*pane);
    }
    rebuildTabStrip();
    requestRepaint();
    if (activePane() != nullptr)
        renderGridFrame();
}

void runBeamAction(const Ubiquitty::CommandPalette::BeamAction& action)
{
    using Kind = Ubiquitty::CommandPalette::BeamAction::Kind;
    if (action.kind != Kind::Run)
        return; // None redraws; Closed has nothing to do beyond the redraw

    // The theme is applied here rather than handed back to a caller: it is a
    // change to every pane's palette, which this frontend owns, and the drill's
    // option index is the registry index already.
    if (action.commandID == beamThemeCommandID) {
        if (action.optionIndex >= 0)
            applyThemeToAllPanes(action.optionIndex);
        return;
    }

    // A Blocks row names a place in the buffer rather than an action, so running
    // one is a scroll. Answered before the action parse, which has no spelling
    // for a row id and would leave the jump doing nothing.
    if (action.commandID.starts_with(beamBlockCommandIDPrefix)) {
        scrollToAbsoluteRow(std::atoi(action.commandID.c_str() + std::strlen(beamBlockCommandIDPrefix)));
        return;
    }

    // A Settings row changes the preference it names. The three shapes the
    // scope offers are the three the session can hand back: a toggle arrives as
    // a plain Run, an options drill carries the chosen index, a number drill
    // carries the parsed and clamped value.
    if (const Ubiquitty::Preferences::WriteDescriptor* descriptor = beamSettingDescriptorFor(action.commandID);
        descriptor != nullptr) {
        namespace Prefs = Ubiquitty::Preferences;
        const std::optional<Prefs::Value> live = Prefs::effectiveValue(descriptor->id, loadPreferences());
        if (!live.has_value())
            return;
        // Written in the DESCRIPTOR's kind, because that is the serializer
        // `writeValue` checks the value against — it refuses a mismatch rather
        // than emitting a literal the reader will not parse back. So for the
        // seven keys whose live value is a double under an Int descriptor, a
        // row reads 15.5 and writes 15. That round trip loses the fraction, and
        // it is a pre-existing property of the descriptors rather than of this
        // scope: correcting them changes what lands in a person's file.
        switch (descriptor->kind) {
        case Prefs::SerializeKind::Bool:
            (void)applyBeamSetting(*descriptor, Prefs::Value::ofBool(descriptor->kind, !live->boolean));
            return;
        case Prefs::SerializeKind::EnumToken: {
            const std::span<const Prefs::VocabularyTerm> terms = Prefs::vocabularyFor(descriptor->id);
            // The index is into the list this frontend registered, which is the
            // vocabulary's own order — not into the ranked rows, which a query
            // reorders. Bounds-checked because a drill closed by anything but a
            // choice reports -1.
            if (action.optionIndex < 0 || static_cast<std::size_t>(action.optionIndex) >= terms.size())
                return;
            (void)applyBeamSetting(*descriptor,
                Prefs::Value::ofText(descriptor->kind, terms[static_cast<std::size_t>(action.optionIndex)].token));
            return;
        }
        case Prefs::SerializeKind::Int:
            (void)applyBeamSetting(*descriptor,
                Prefs::Value::ofInteger(descriptor->kind, static_cast<long long>(std::llround(action.numberValue))));
            return;
        case Prefs::SerializeKind::Double:
            (void)applyBeamSetting(*descriptor, Prefs::Value::ofNumber(descriptor->kind, action.numberValue));
            return;
        case Prefs::SerializeKind::String:
        case Prefs::SerializeKind::LegacyBoolOrToken:
            return; // never listed, so never accepted
        }
        return;
    }

    // A Find row names a place in the buffer, the same shape as a Blocks row and
    // reached by the same reveal so a match and a block do not land at two
    // different heights for the one verb.
    if (action.commandID.starts_with(beamFindCommandIDPrefix)) {
        const auto target = app().beamFindTargets.find(action.commandID);
        LinuxPane* pane = app().beamFindPane.get();
        if (target != app().beamFindTargets.end() && pane && pane->session) {
            const int offset = pane->session->searchPositionViewOffset(target->second);
            if (offset >= 0)
                pane->viewOffset = offset;
            requestRepaint();
        }
        return;
    }

    // A GoTo row names a destination rather than an action, the same shape as a
    // Blocks row and answered before the action parse for the same reason.

    if (action.commandID.starts_with(beamGoToTabIDPrefix)) {
        switchToTab(static_cast<TabID>(std::strtoul(action.commandID.c_str() + std::strlen(beamGoToTabIDPrefix), nullptr, 10)));
        return;
    }
    if (action.commandID.starts_with(beamGoToPaneIDPrefix)) {
        const PaneID paneID = static_cast<PaneID>(std::strtoul(action.commandID.c_str() + std::strlen(beamGoToPaneIDPrefix), nullptr, 10));
        // Through the same verb a click takes, so the focus change carries the
        // chrome reset with it rather than leaving the previous pane's find bar
        // and preedit pointed at a terminal that no longer holds focus.
        if (LinuxPane* pane = paneForID(paneID); pane != nullptr)
            focusPaneFromEvent(pane);
        return;
    }

    const Ubiquitty::Input::BindingAction binding = Ubiquitty::Input::parseAction(action.commandID);
    if (binding.valid())
        executeBindingAction(binding);
}

bool doesMenuOwnKeys()
{
    GtkWidget* focus = app().window ? gtk_window_get_focus(GTK_WINDOW(app().window)) : nullptr;
    if (app().menuButton) {
        GtkPopover* popover = gtk_menu_button_get_popover(GTK_MENU_BUTTON(app().menuButton));
        if ((popover && gtk_widget_get_visible(GTK_WIDGET(popover))) || focus == app().menuButton
            || (focus && gtk_widget_is_ancestor(focus, app().menuButton)))
            return true;
    }
    return false;
}

gboolean onKeyPressed(GtkEventControllerKey* controller, guint keyval, guint keycode, GdkModifierType state, gpointer)
{
    if (doesMenuOwnKeys())
        return GDK_EVENT_PROPAGATE;
    restartCaretBlink(true);
    updatePositionModifiers(keyval, state, Ubiquitty::Keys::KeyEventType::Press);
    updateHoverForModifierKey(keyval, state, Ubiquitty::Keys::KeyEventType::Press);
    // The break-out chord is native, above the key resolver and the host, so
    // no rebind, mode, or escape stream can shadow the release — reported
    // before Beam, before bindings, before everything.
    notePointerLockChordFromKeyEvent(keyval, state, Ubiquitty::Keys::KeyEventType::Press);

    // An open Beam gets first refusal, ahead of the bindings — otherwise typing a
    // query would fire single-key [keys] bindings and the palette would never see
    // the character. Core decides ownership, not this file: classifyBeamKey
    // reports handled=false for anything the palette has no use for, so an open
    // palette does not swallow the terminal's input wholesale, and the toggle
    // chord still reaches the resolver below to close it.
    if (app().beamSession.isOpen()) {
        Ubiquitty::Input::KeyChord chord;
        if (mapKeyvalToChord(keyval, state, chord)) {
            const std::uint32_t text = gdk_keyval_to_unicode(keyval);
            const Ubiquitty::Input::BeamKeyOutcome outcome
                = Ubiquitty::Input::classifyBeamKey(chord.key, chord.modifiers & Ubiquitty::Input::bindModMask, text);
            if (outcome.handled) {
                runBeamAction(app().beamSession.apply(outcome.event, outcome.codePoint));
                refreshBeamFindScope();
                requestRepaint();
                return GDK_EVENT_STOP;
            }
        }
    }

    // Custom [keys] bindings get the key before the built-in accelerators, the
    // input method, and the default keymap — the portable resolver owns all the
    // policy: a single chord fires immediately (Matched), a leader/chord prefix
    // swallows the key while it captures (Pending), and anything unbound
    // (NoMatch) falls through untouched. Only the GDK -> KeyChord translation
    // and the action execution live here.
    if (app().chordResolver) {
        Ubiquitty::Input::KeyChord chord;
        if (mapKeyvalToChord(keyval, state, chord)) {
            Ubiquitty::Input::BindingAction action;
            switch (app().chordResolver->feed(chord, action)) {
            case Ubiquitty::Input::ResolveResult::Matched:
                executeBindingAction(action);
                return GDK_EVENT_STOP;
            case Ubiquitty::Input::ResolveResult::Pending:
                return GDK_EVENT_STOP; // leader/chord in progress: swallow the key
            case Ubiquitty::Input::ResolveResult::NoMatch:
                break; // fall through to the built-in accelerators
            }
        }
    }

    // Compose, when the terminal decodes it, sits between the user's own
    // bindings and GTK's input method: Core's Input::ComposeState owns the
    // ladder over the trigger and the engine, as it does on the macOS arms,
    // and this frontend hands it the chord and the code point the key typed.
    // A finished sequence is written to the pane; a key the sequence took is
    // stopped here either way; a key it did not take goes on down the ladder.
    if (auto& compose = activePane()->compose; compose.isArmed() && !activePane()->modes.shouldReportKeyPositions) {
        Ubiquitty::Input::KeyChord chord {};
        (void)mapKeyvalToChord(keyval, state, chord);
        const Ubiquitty::Input::ComposeAction action = compose.offer(chord, gdk_keyval_to_unicode(keyval));
        if (action == Ubiquitty::Input::ComposeAction::Write) {
            std::string utf8;
            Ubiquitty::Unicode::appendUTF8(utf8, compose.composed());
            activePane()->viewOffset = 0;
            activePane()->session->sendInput(utf8);
            armPTYWriteDrain(activePane());
            requestRepaint();
        }
        if (action != Ubiquitty::Input::ComposeAction::Pass)
            return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+V pastes the system clipboard (the de-facto terminal paste
    // accelerator). The read is async; onClipboardPasted feeds it (bracketed per
    // the live mode) once it lands. Consumed here, never sent to the PTY.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_V || keyval == GDK_KEY_v)) {
        if (app().window)
            pasteClipboard(gtk_widget_get_clipboard(app().window), Ubiquitty::ClipboardBuffer::Clipboard);
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+C copies the current selection (the de-facto terminal copy
    // accelerator; plain Ctrl+C stays SIGINT). Consumed here, never sent to the PTY.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_C || keyval == GDK_KEY_c)) {
        copySelectionToClipboard();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+F opens the find bar (Shift'd so plain ^F still reaches apps).
    // Consumed here, never sent to the PTY.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_F || keyval == GDK_KEY_f)) {
        showSearchBar();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+I toggles the process inspector. Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_I || keyval == GDK_KEY_i)) {
        toggleInspector();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+A selects + copies the whole buffer (macOS Edit > Select All / Cmd-A
    // parity). Consumed here, never sent to the PTY.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_A || keyval == GDK_KEY_a)) {
        selectAll();
        return GDK_EVENT_STOP;
    }

    // F11 toggles fullscreen (macOS toggleFullScreen / ⌘↩ parity; F11 is the Linux
    // convention). Consumed here, never sent to the PTY. Shares toggleFullscreen
    // with the ToggleFullscreen [keys] action.
    if (keyval == GDK_KEY_F11) {
        toggleFullscreen();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+K clears the screen, preserving a half-typed command (Cmd-K parity).
    // Consumed here, never sent to the PTY. Shares clearBufferAction with
    // the ClearScrollback [keys] action.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_K || keyval == GDK_KEY_k)) {
        clearBufferAction();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+L drops everything above the previous executed prompt (Cmd-L
    // parity), falling back to an input-preserving full clear when none exists.
    // The whole policy lives in Screen::clearToPreviousMark — the mark search,
    // the full-clear fallback, and the state each invalidates. Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_L || keyval == GDK_KEY_l)) {
        if (Ubiquitty::Terminal* term = activePane()->session->terminal()) {
            std::string bytesToSend;
            {
                const auto hold = holdPaneModel(*activePane());
                Ubiquitty::Screen::clearToPreviousMark(
                    term, &activePane()->selection.state, [] { activePane()->viewOffset = 0; },
                    [&bytesToSend](std::span<const char> bytes) { bytesToSend.append(bytes.data(), bytes.size()); });
            }
            sendBytesToActivePane(bytesToSend);
            requestRepaint();
        }
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+Up / Ctrl+Shift+Down jump to the previous / next shell prompt (OSC
    // 133 marks; View > Jump to Prompt parity). Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_Up || keyval == GDK_KEY_Down)) {
        jumpToPrompt(keyval == GDK_KEY_Up ? -1 : +1);
        return GDK_EVENT_STOP;
    }

    // Ctrl++ / Ctrl+= zoom the font in, Ctrl+- out, Ctrl+0 resets (View > Zoom
    // parity). No-op in Unifont mode. Consumed here.
    if ((state & GDK_CONTROL_MASK) && (keyval == GDK_KEY_plus || keyval == GDK_KEY_equal || keyval == GDK_KEY_KP_Add)) {
        applyFontZoom(app().fontPixelSize + 1);
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK) && (keyval == GDK_KEY_minus || keyval == GDK_KEY_KP_Subtract)) {
        applyFontZoom(app().fontPixelSize - 1);
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK) && (keyval == GDK_KEY_0 || keyval == GDK_KEY_KP_0)) {
        applyFontZoom(app().defaultFontPixelSize);
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+T opens a new tab; Ctrl+Shift+W closes the focused PANE — collapsing
    // one split level, or the tab/window when it's the tab's last pane. Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_T || keyval == GDK_KEY_t)) {
        newTab();
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_W || keyval == GDK_KEY_w)) {
        closeFocusedPaneUX();
        return GDK_EVENT_STOP;
    }

    // Ctrl+Shift+E splits the focused pane into side-by-side columns (a vertical
    // divider); Ctrl+Shift+D stacks them (top/bottom). Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_E || keyval == GDK_KEY_e)) {
        splitFocusedPaneUX(Panes::Orientation::Vertical);
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK) && (state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_D || keyval == GDK_KEY_d)) {
        splitFocusedPaneUX(Panes::Orientation::Horizontal);
        return GDK_EVENT_STOP;
    }

    // Ctrl+Alternate+arrows move focus between split panes (spatial). Consumed here.
    if ((state & GDK_CONTROL_MASK) && (state & GDK_ALT_MASK) && (keyval == GDK_KEY_Left || keyval == GDK_KEY_Right || keyval == GDK_KEY_Up || keyval == GDK_KEY_Down)) {
        using D = Panes::Direction;
        const D direction = keyval == GDK_KEY_Left ? D::Left : keyval == GDK_KEY_Right ? D::Right
            : keyval == GDK_KEY_Up                                                     ? D::Up
                                                                                       : D::Down;
        moveFocusUX(direction);
        return GDK_EVENT_STOP;
    }

    // Ctrl+PageDown / Ctrl+PageUp cycle tabs (SHIFT clear, so Shift+PageUp still
    // pages scrollback below). Consumed here.
    if ((state & GDK_CONTROL_MASK) && !(state & GDK_SHIFT_MASK) && (keyval == GDK_KEY_Page_Down || keyval == GDK_KEY_Page_Up)) {
        switchTabRelative(keyval == GDK_KEY_Page_Down ? +1 : -1);
        return GDK_EVENT_STOP;
    }

    // Shift+PageUp / Shift+PageDown page the local scrollback viewport (a page is
    // one screenful minus a row of overlap). Handled here, never sent to the PTY.
    if (state & GDK_SHIFT_MASK) {
        // Core's one page rule, shared with the macOS navigation chords.
        const int page = static_cast<int>(Ubiquitty::Keys::pageLinesForRows(activePane()->rows));
        if (keyval == GDK_KEY_Page_Up || keyval == GDK_KEY_Page_Down) {
            activePane()->viewOffset += (keyval == GDK_KEY_Page_Up) ? page : -page;
            clampActivePaneViewOffset(activePane()->session->terminal());
            requestRepaint();
            return GDK_EVENT_STOP;
        }
    }

    // A bare modifier press (Ctrl/Shift/Alternate/Super with no other key) is forwarded
    // to the gtkApplication as a Kitty press event when REPORT_ALL is on, then consumed — it
    // has no character to type and must not reach the IM. The shared
    // Kitty::bareModifierKeyEvent gates on REPORT_ALL, so this is a no-op for everyone
    // else (and onKeyReleased mirrors it for the release). Matches the macOS
    // flagsChanged: forwarding.
    if (forwardModifierKeyEvent(keyval, state, Ubiquitty::Keys::KeyEventType::Press))
        return GDK_EVENT_STOP;

    // Alt is always the terminal Meta modifier here: Alt+letter must reach the
    // shell as an ESC-prefixed byte, not as the input method's composed glyph.
    // A Linux layout's third level is AltGr (ISO_Level3_Shift), a modifier
    // apart from GDK_ALT_MASK, so `[keys] option_as_alt` (which exists for the
    // Mac Option key that is both) does not apply and every Alt acts as Meta.
    // Route through the SHARED Option-as-Meta bypass predicate (the same one
    // the macOS frontend uses) so the two agree: when Alternate is held without
    // Super, skip the IM and encode the key directly. Super-chords are gtkApplication
    // shortcuts, never Meta, so they fall through to the IM.
    const bool bypassInputMethod = Ubiquitty::Input::eventShouldBypassTextInputForTerminalEncoding(Ubiquitty::Input::OptionAsAlternate::Both,
        (state & GDK_ALT_MASK) ? Ubiquitty::Input::AlternateModifier::Held : Ubiquitty::Input::AlternateModifier::Up, (state & GDK_SUPER_MASK) ? Ubiquitty::Input::SuperModifier::Held : Ubiquitty::Input::SuperModifier::Up);

    // Let the input method compose first (dead keys, compose, CJK). If it
    // consumes the key — building a composition, or committing one (onIMCommit
    // fires synchronously and writes the bytes) — we're done; otherwise fall
    // through to the keymap encoder for an ordinary keystroke. The Meta bypass
    // above skips this so Alternate+letter is encoded, not composed.
    if (app().imContext && !bypassInputMethod && !activePane()->modes.shouldReportKeyPositions) {
        GdkEvent* event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
        if (event && gtk_im_context_filter_keypress(app().imContext, event))
            return GDK_EVENT_STOP;
    }

    // Any key that sends input snaps the view back to the live tail, so typing
    // returns to the prompt, when the Core's DEC-1011 scrollOnKeypress policy
    // says so (shouldSnapToTail); otherwise a scrolled-back read holds.
    {
        const auto hold = holdPaneModel(*activePane());
        if (Ubiquitty::Modes::shouldSnapToTail(activePane()->session->terminal(), Ubiquitty::Modes::SnapTrigger::Keypress))
            activePane()->viewOffset = 0;
    }
    return sendKey(keyval, keycode, state) ? GDK_EVENT_STOP : GDK_EVENT_PROPAGATE;
}

// Key released. The only release the terminal forwards is a bare modifier under
// Kitty REPORT_ALL + REPORT_EVENTS (Doom: Ctrl up = stop firing); ordinary keys
// have no standard release form and the shared Kitty::bareModifierKeyEvent drops a release
// unless REPORT_EVENTS is set, so this is a no-op for every other app. Mirrors the
// press forwarding in onKeyPressed and the macOS flagsChanged: release path.
void onKeyReleased(GtkEventControllerKey*, guint keyval, guint, GdkModifierType state, gpointer)
{
    updatePositionModifiers(keyval, state, Ubiquitty::Keys::KeyEventType::Release);
    updateHoverForModifierKey(keyval, state, Ubiquitty::Keys::KeyEventType::Release);
    // A modifier release can be what disarms the chord (Control or Command
    // let go while the other is still held); reported the same way every
    // other chord edge is.
    notePointerLockChordFromKeyEvent(keyval, state, Ubiquitty::Keys::KeyEventType::Release);
    if (!doesMenuOwnKeys())
        forwardModifierKeyEvent(keyval, state, Ubiquitty::Keys::KeyEventType::Release);
}

// Focus reporting.

// Window gained / lost key focus. setFocused records it on the Terminal
// (Terminal::windowFocused) and, when the gtkApplication enabled DECSET 1004, emits CSI I
// (focus-in) / CSI O (focus-out) to the program; the reply is flushed to the
// PTY on the next drain (or immediately when bytes are already pending).
void onFocusEnter(GtkEventControllerFocus*, gpointer)
{
    restartCaretBlink(false);
    activePane()->hasUnheardBell = false;
    updateWindowTitle();
    rebuildTabStrip();
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Focused);
    activePane()->session->flushReplies();
    if (app().imContext)
        gtk_im_context_focus_in(app().imContext);
    // A backgrounded lock would trap a pointer no window owns; regaining
    // focus re-takes it without the program re-sending the mode.
    updatePointerLock();
}

void onFocusLeave(GtkEventControllerFocus*, gpointer)
{
    scheduleCaretBlink(nullptr);
    activePane()->compose.reset();
    activePane()->keyPositionModifiers = 0;
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Unfocused);
    activePane()->session->flushReplies();
    if (app().imContext)
        gtk_im_context_focus_out(app().imContext);
    updatePointerLock();
    requestRepaint();
}

// ---- Pointer lock (DECSET 7403) --------------------------------------------
//
// Core decides whether the surface should hold the grab (`pointerLockVerdict`)
// and whether the break-out chord has been held long enough
// (`tickPointerLockChord`); this section supplies the two facts only GTK can
// answer -- live window focus/activation, and the current modifier state --
// and drives PointerLock.{h,cpp}'s OS mechanism with what Core decides.

// GDK modifier state -> the break-out chord's key facts. Command is
// GDK_SUPER_MASK, matching forwardPointerFact's `hasCommand` above -- the
// Linux ⌘ is Super, not Alt, so the chord and the pointer ladder agree on
// which physical key answers "Command".
Ubiquitty::Input::PointerLockKeyState pointerLockKeyStateFromModifiers(GdkModifierType state)
{
    Ubiquitty::Input::PointerLockKeyState keys;
    keys.isControlHeld = (state & GDK_CONTROL_MASK) != 0;
    keys.isCommandHeld = (state & GDK_SUPER_MASK) != 0;
    keys.isShiftHeld = (state & GDK_SHIFT_MASK) != 0;
    keys.isOptionHeld = (state & GDK_ALT_MASK) != 0;
    return keys;
}

gboolean onPointerLockChordTick(gpointer)
{
    app().pointerLockChordTimerID = 0;
    LinuxPane* pane = activePane();
    if (!pane || !pane->session)
        return G_SOURCE_REMOVE;
    const Ubiquitty::Input::PointerLockKeyState keysNow = pointerLockKeyStateFromModifiers(app().pointerLockLastModifiers);
    if (pane->session->tickPointerLockChord(keysNow) == Ubiquitty::Input::PointerLockChordVerdict::BreakOut)
        updatePointerLock(); // the session already cleared the mode; this tears down the OS grab
    else
        bookPointerLockChordTick(); // a release in the last instant re-armed nothing; ask again at the new deadline (0 if disarmed)
    return G_SOURCE_REMOVE;
}

// Books Core's one wake-up for the armed chord, if any. Idempotent -- an
// already-armed timer stays the one timer, matching the hint's own
// one-tick-past-the-deadline booking below in layoutHintForFrame.
void bookPointerLockChordTick()
{
    LinuxPane* pane = activePane();
    if (!pane || !pane->session || app().pointerLockChordTimerID != 0)
        return;
    const std::uint32_t ticks = pane->session->pointerLockChordTicksUntilDeadline();
    if (ticks == 0)
        return;
    app().pointerLockChordTimerID = g_timeout_add(static_cast<guint>((ticks + 1) * 1000 / 60), onPointerLockChordTick, nullptr);
}

// Reports one key event to the break-out chord and books its wake-up.
// Called unconditionally from onKeyPressed / onKeyReleased, on every key --
// the chord sits above the entire configurable key stack, so nothing an app
// or a [keys] rebind does can suppress it. Core gates arming on a grab
// actually being held (PointerLadder.cpp), so this costs nothing when no
// lock is live.
void notePointerLockChordFromKeyEvent(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge)
{
    // A non-modifier key joining the chord makes it a real shortcut, not the
    // break-out -- modifierVirtualKeyFor answers None for exactly the keys
    // that mean this. Counted down and up rather than read off the event
    // alone: a key released while the pair stays down must let the chord
    // arm again, and a release event names the key that just left, not what
    // is still held.
    if (modifierVirtualKeyFor(keyval) == Ubiquitty::Keys::VirtualKey::None) {
        if (edge == Ubiquitty::Keys::KeyEventType::Release)
            app().heldNonModifierKeyCount = std::max(0, app().heldNonModifierKeyCount - 1);
        else
            ++app().heldNonModifierKeyCount;
    }
    LinuxPane* pane = activePane();
    if (!pane || !pane->session)
        return;
    app().pointerLockLastModifiers = state;
    Ubiquitty::Input::PointerLockKeyState keys = pointerLockKeyStateFromModifiers(state);
    keys.isAnyNonModifierKeyHeld = app().heldNonModifierKeyCount > 0;
    pane->session->notePointerLockChord(keys);
    bookPointerLockChordTick();
}

// The one fact Core cannot see: whether this pane's surface is the live
// input target. `windowFocused` is Core's own copy of the focus edges above;
// `gtk_window_is_active` is the toplevel's activation, the second half
// AppKit's isKeyWindow + NSApp.isActive answer together.
bool isPointerLockSurfaceFocused(const LinuxPane& pane)
{
    if (&pane != activePane())
        return false;
    const Ubiquitty::Terminal* term = pane.session ? pane.session->terminal() : nullptr;
    const auto hold = holdPaneModel(pane);
    return term != nullptr && term->windowFocused != 0
        && app().window != nullptr && gtk_window_is_active(GTK_WINDOW(app().window));
}

// Wakes the frame clock from the Wayland relative-motion listener, which runs
// during GDK's own event dispatch and has no repaint request of its own to
// make -- a bare trampoline so PointerLock.cpp never has to know requestRepaint exists.
void wakePointerLockFrame() { requestRepaint(); }

// Whether a pane pointer names a pane that still exists. The grab's holder
// is kept by address, and a teardown that forgot to release would otherwise
// hand this file a pointer into freed memory.
bool isLivePane(const LinuxPane* pane)
{
    for (const auto& live : app().panes)
        if (live.get() == pane)
            return true;
    return false;
}

// The one idempotent OS-grab toggle, guarded by app().isPointerLocked --
// mirrors the macOS surface's applyPointerLock: engage+report on Hold,
// release+report on Release, one source of truth so the two halves of a
// transition can never both fire, or neither.
void applyPointerLock(Ubiquitty::Input::PointerLockVerdict verdict)
{
    const bool wantsLocked = verdict == Ubiquitty::Input::PointerLockVerdict::Hold;
    if (wantsLocked == app().isPointerLocked)
        return;
    if (wantsLocked) {
        LinuxPane* pane = activePane();
        if (!pane || !pane->picture || !pane->session)
            return;
        // Bound lazily: a round trip against the compositor, worth paying
        // only the first time a surface on this display asks to lock.
        if (!app().isPointerLockWaylandBound) {
            app().pointerLockWayland = Ubiquitty::Linux::bindPointerLockWaylandGlobals(gtk_widget_get_display(pane->picture));
            app().isPointerLockWaylandBound = true;
        }
        if (!Ubiquitty::Linux::pointerLockEngage(pane->picture, app().pointerLockWayland, &wakePointerLockFrame, app().pointerLockOS))
            return; // neither backend could engage on this display -- the grab stays untaken
        app().isPointerLocked = true;
        app().pointerLockPane = pane;
        pane->session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
        // A trace for driving the real grab on a real display, where no smoke
        // can reach: which backend took it, and that it was taken.
        if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr)
            g_printerr("pointer-lock: engaged backend=%s\n", app().pointerLockOS.backend == Ubiquitty::Linux::PointerLockBackendKind::Wayland ? "wayland" : "x11");
    } else {
        // The pane that TOOK the grab, not necessarily the one focused now --
        // a release is often triggered by focus having already moved away.
        // A holder that is no longer among the live panes was destroyed with
        // the grab still held; reading it would be a use after free, and the
        // release then happens without it. That is a defect in whichever
        // teardown skipped the release, and it is said out loud.
        LinuxPane* pane = app().pointerLockPane != nullptr ? app().pointerLockPane : activePane();
        if (pane != nullptr && !isLivePane(pane)) {
            g_critical("pointer lock: the pane holding the grab was destroyed before releasing it");
            pane = nullptr;
        }
        if (app().pointerLockChordTimerID != 0) {
            g_source_remove(app().pointerLockChordTimerID);
            app().pointerLockChordTimerID = 0;
        }
        if (pane && pane->picture)
            Ubiquitty::Linux::pointerLockRelease(pane->picture, app().pointerLockOS);
        app().isPointerLocked = false;
        app().pointerLockPane = nullptr;
        if (pane && pane->session)
            pane->session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Released);
        if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr)
            g_printerr("pointer-lock: released\n");
    }
    requestRepaint(); // the release-lesson hint's appearance/withdrawal needs a frame
}

// Reconciles the OS grab against Core's verdict. Idempotent and cheap while
// nothing is locked; called from every edge that can move the answer -- a
// PTY drain (the mode bit), a focus edge, a window-active edge, a pane
// switch.
void updatePointerLock()
{
    LinuxPane* pane = activePane();
    if (!pane || !pane->session) {
        applyPointerLock(Ubiquitty::Input::PointerLockVerdict::Release);
        return;
    }
    Ubiquitty::Input::PointerLockFacts facts;
    facts.isSurfaceFocused = isPointerLockSurfaceFocused(*pane);
    const Ubiquitty::Input::PointerLockVerdict verdict = pane->session->pointerLockVerdict(facts);
    if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr && pane->session->readSnapshot().mouseRelativePointerLockActive)
        g_printerr("pointer-lock: verdict=%s focused=%d held=%d\n", verdict == Ubiquitty::Input::PointerLockVerdict::Hold ? "hold" : "release",
            static_cast<int>(facts.isSurfaceFocused), static_cast<int>(app().isPointerLocked));
    applyPointerLock(verdict);
}

// X11: recentres and reports the resulting delta, called from every motion
// event while the grab is engaged on this backend. The warp's own echo
// motion computes to a zero delta and Core's ladder already swallows a
// zero-delta report, so there is nothing to special-case here.
void reportPointerLockX11Motion(double widgetX, double widgetY, GdkModifierType state)
{
    LinuxPane* pane = app().pointerLockPane;
    if (!pane || !pane->picture || !pane->session)
        return;
    const Ubiquitty::Linux::PointerLockDelta delta = Ubiquitty::Linux::pointerLockX11Recentre(pane->picture, app().pointerLockOS, widgetX, widgetY);
    if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr && (delta.x != 0.0 || delta.y != 0.0))
        g_printerr("pointer-lock: x11 delta %g %g\n", delta.x, delta.y);
    Ubiquitty::Runtime::TerminalSession::PointerFact fact;
    fact.kind = Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion;
    fact.button = Ubiquitty::Input::PointerButton::None;
    fact.deltaX = static_cast<std::ptrdiff_t>(delta.x);
    fact.deltaY = static_cast<std::ptrdiff_t>(delta.y);
    const Ubiquitty::Input::PointerLockKeyState keys = pointerLockKeyStateFromModifiers(state);
    fact.hasShift = keys.isShiftHeld;
    fact.hasAlternate = keys.isOptionHeld;
    fact.hasControl = keys.isControlHeld;
    fact.hasCommand = keys.isCommandHeld;
    pane->session->pointerFact(fact, &pane->selection);
}

// The toplevel's activation changed (another app came forward, or this one
// did) — the other half of `isPointerLockSurfaceFocused` that a focus-in/out
// edge alone cannot see.
void onPointerLockWindowActiveNotify(GObject*, GParamSpec*, gpointer)
{
    updatePointerLock();
    if (app().window && !gtk_window_is_active(GTK_WINDOW(app().window)))
        scheduleCaretBlink(nullptr);
    requestRepaint();
}

// Wayland: the locked surface receives no ordinary motion events (the
// protocol withholds them by design), so the relative-pointer listener's
// deposits are drained here instead, once per frame tick -- the same tick
// `wakePointerLockFrame` re-arms when the clock had gone idle.
void drainPointerLockMotion()
{
    if (!app().isPointerLocked || app().pointerLockOS.backend != Ubiquitty::Linux::PointerLockBackendKind::Wayland)
        return;
    LinuxPane* pane = app().pointerLockPane;
    if (!pane || !pane->session)
        return;
    const Ubiquitty::Linux::PointerLockDelta delta = Ubiquitty::Linux::takeWaylandPointerLockDelta(app().pointerLockOS);
    if (delta.x == 0.0 && delta.y == 0.0)
        return;
    if (std::getenv("UBIQUITTY_POINTER_LOCK_TRACE") != nullptr)
        g_printerr("pointer-lock: wayland delta %g %g\n", delta.x, delta.y);
    Ubiquitty::Runtime::TerminalSession::PointerFact fact;
    fact.kind = Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion;
    fact.button = Ubiquitty::Input::PointerButton::None;
    fact.deltaX = static_cast<std::ptrdiff_t>(delta.x);
    fact.deltaY = static_cast<std::ptrdiff_t>(delta.y);
    const Ubiquitty::Input::PointerLockKeyState keys = pointerLockKeyStateFromModifiers(app().pointerLockLastModifiers);
    fact.hasShift = keys.isShiftHeld;
    fact.hasAlternate = keys.isOptionHeld;
    fact.hasControl = keys.isControlHeld;
    fact.hasCommand = keys.isCommandHeld;
    pane->session->pointerFact(fact, &pane->selection);
}

// Input method (IME): dead keys / compose / CJK.
// Parity with the macOS NSTextInputClient path. A GtkIMContext gets first crack
// at every key (onKeyPressed → filter_keypress); while composing it emits the
// preedit (shown underlined inline at the cursor) and, on accept, "commit" with
// the final UTF-8 — sent to the PTY as ordinary typed input.

// Decode a NUL-terminated UTF-8 string to codepoints (for the inline preedit).
std::vector<std::uint32_t> codePointsFromUTF8(const char* utf8)
{
    std::vector<std::uint32_t> outputBuffer;
    if (!utf8)
        return outputBuffer;
    for (const char* p = utf8; *p != '\0'; p = g_utf8_next_char(p))
        outputBuffer.push_back(static_cast<std::uint32_t>(g_utf8_get_char(p)));
    return outputBuffer;
}

// The IM produced final text (a committed composition, or a dead-key result like
// "é"). It is typed input, so send the raw UTF-8 to the PTY — not bracketed (that
// guard is for clipboard paste) — and snap the view back to the live tail.
void onIMCommit(GtkIMContext*, const char* text, gpointer)
{
    if (!text || text[0] == '\0')
        return;
    activePane()->viewOffset = 0;
    activePane()->session->sendInput({ text, std::strlen(text) });
    armPTYWriteDrain(activePane());
    app().rasterContext.setPreedit(nullptr, 0);
    requestRepaint();
}

// The composition in progress changed: show it underlined at the cursor.
void onIMPreeditChanged(GtkIMContext* context, gpointer)
{
    char* text = nullptr;
    PangoAttrList* attributes = nullptr;
    int cursorPosition = 0; // glyph caret within the preedit; unused (we draw the whole run)
    gtk_im_context_get_preedit_string(context, &text, &attributes, &cursorPosition);
    const std::vector<std::uint32_t> codePoints = codePointsFromUTF8(text);
    app().rasterContext.setPreedit(codePoints.data(), static_cast<int>(codePoints.size()));
    if (attributes)
        pango_attr_list_unref(attributes);
    g_free(text);
    activePane()->viewOffset = 0;
    requestRepaint();
}

// Composition ended (committed or cancelled): drop the inline preedit.
void onIMPreeditEnd(GtkIMContext*, gpointer)
{
    app().rasterContext.setPreedit(nullptr, 0);
    requestRepaint();
}

// Tell the IM where the cursor is (client-widget pixels) so the candidate window
// tracks it instead of pinning to the window origin.
void updateIMCursorLocation(Ubiquitty::CellPosition cursor)
{
    if (!app().imContext)
        return;
    const int cw = app().rasterContext.cellWidth();
    const int ch = app().rasterContext.cellHeight();
    // The IME anchor uses the same complete-picture map as the drawn cursor.
    const Ubiquitty::FloatRect cell = Ubiquitty::Rendering::cellRect(cursor, { static_cast<float>(cw), static_cast<float>(ch) }, Ubiquitty::Rendering::EdgeInsets {}, /*extraTop*/ 0.0f);
    GdkRectangle rect;
    const auto origin = activePane()->presentation.viewportPoint(cell.origin);
    rect.x = static_cast<int>(origin.x / app().scale);
    rect.y = static_cast<int>(origin.y / app().scale);
    rect.width = std::max(1, static_cast<int>(cw * activePane()->presentation.scale / app().scale));
    rect.height = std::max(1, static_cast<int>(ch * activePane()->presentation.scale / app().scale));
    gtk_im_context_set_cursor_location(app().imContext, &rect);
}

// Mouse reporting.

// Map a pointer position (widget pixels) to a zero-based terminal cell, clamped
// to the live grid. The cell is the font-derived runtime cell (same metric the
// grid + window are sized at).
// The pixel along the grid a widget point stands at, in device pixels from
// the grid's left edge, through the picture placement.
double gridXAtPoint(double x, double y)
{
    const auto point = activePane()->presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
    return static_cast<double>(point.x);
}

// The column under a pixel along a row of the frame on screen: the letter
// there where the primary face laid the row out as proportional runs, else
// the column at the pitch. The renderer that drew the frame answers, GPU or
// CPU, from the layout it kept (LetterLayout.h).
int columnAtGridX(int row, double xInPixels)
{
    return app().isVulkanReady ? app().vulkan.columnAt(row, xInPixels) : app().rasterContext.columnAt(row, xInPixels);
}

// Where along its row a widget point stands, in cells, for the pointer fact:
// on a row laid out as letters the letter under it plus the fraction crossed.
double xInCellsAtPoint(double x, double y, int row)
{
    const double xInPixels = gridXAtPoint(x, y);
    return app().isVulkanReady ? app().vulkan.xInCellsAt(row, xInPixels) : app().rasterContext.xInCellsAt(row, xInPixels);
}

void cellAtPoint(double x, double y, int& row, int& column)
{
    // Convert widget points to device pixels, then undo the picture placement
    // once. Hit testing always addresses the host's actual grid.
    const auto* terminal = activePane()->session->terminal();
    const auto hold = holdPaneModel(*activePane());
    const auto point = activePane()->presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
    const Ubiquitty::CellPosition cell = Ubiquitty::Rendering::pointToCell(point, {},
        { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) },
        terminal ? Ubiquitty::GridSize { terminal->columns, terminal->rows } : Ubiquitty::GridSize {}, Ubiquitty::Rendering::RowClamp::Clamped);
    row = cell.row;
    // The row is the grid's; the column along it is the frame's, which on a
    // proportional face's row is the letter under the point.
    column = terminal ? std::clamp(columnAtGridX(cell.row, static_cast<double>(point.x)), 0, std::max(terminal->columns - 1, 0)) : cell.column;
}

// Map a pointer position (widget pixels) to the 1-based device-pixel coordinate
// SGR-pixel mode (DECSET 1016) reports — the inverse the encoder expects, not
// a raw widget pixel. Routes through the shared Rendering::pointToDevicePixel
// so padding/extraTop are applied in exactly one place. Pointer coords are LOGICAL widget pixels;
// the backing scale (app().scale) converts them to the device pixels SGR-pixel mode
// reports — matching macOS, which multiplies its point coords by the retina scale.
// 1-based + clamped to >= 1 in-helper.
void devicePixelAtPoint(double x, double y, int& pixelX, int& pixelY)
{
    const Ubiquitty::Terminal* terminal = activePane()->session->terminal();
    const auto hold = holdPaneModel(*activePane());
    const Ubiquitty::IntSize extent = terminal ? Ubiquitty::reportedTextAreaPixels(*terminal) : Ubiquitty::IntSize {};
    const auto point = activePane()->presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
    const Ubiquitty::IntPoint pixel = Ubiquitty::Rendering::pointToDevicePixel(point, {}, 1.0f, extent);
    pixelX = pixel.x;
    pixelY = pixel.y;
}

// Clickable links (OSC 8 + bare-URL detection).

/// Where the link under a cell came from, which decides what may open it.
enum class LinkSource : uint8_t {
    /// No link covers the cell.
    None,
    /// The program stamped the cell with an OSC 8 link.
    Declared,
    /// The terminal read the row's text as a URL; the program never said so.
    Guessed,
};

// Resolve the openable URL under a VISIBLE-grid cell (row, column at activePane()->viewOffset):
// first the explicit OSC 8 link the parser stamped on the cell (resolved
// through the Terminal's link table), else a bare URL detected on the row's text
// by the portable LinkRun matcher (http(s)://, ftp://, mailto:, www., ...).
// Writes the NUL-terminated URI to `out` and returns where it came from. Pure
// read over the model; what a click may do with it is linkDispatchForURI's.
LinkSource linkURIAtCell(int row, int column, char* outputBuffer, int outputCapacity)
{
    if (!outputBuffer || outputCapacity < 1)
        return LinkSource::None;
    outputBuffer[0] = '\0';
    const Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return LinkSource::None;
    const auto hold = holdPaneModel(*activePane());

    // OSC 8 hyperlink: the cell carries a link id; resolve it to the interned
    // URI through the Terminal's link table.
    const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, activePane()->viewOffset, row, column);
    if (cell) {
        const uint16_t id = cell->linkID();
        if (id != 0) {
            const char* uri = Ubiquitty::Attributes::Hyperlinks::uri(term, id);
            if (uri && uri[0] != '\0') {
                int o = 0;
                for (; uri[o] != '\0' && o < outputCapacity - 1; ++o)
                    outputBuffer[o] = uri[o];
                outputBuffer[o] = '\0';
                return o > 0 ? LinkSource::Declared : LinkSource::None;
            }
        }
    }

    // No OSC 8 link: scan the row's codePoints for a bare URL covering `column`.
    const int paneColumns = activePane()->columns;
    if (column < 0 || column >= paneColumns)
        return LinkSource::None;
    std::vector<uint32_t> rowCodePoints(static_cast<std::size_t>(paneColumns));
    const int viewOffset = activePane()->viewOffset;
    for (int x = 0; x < paneColumns; ++x) {
        const Ubiquitty::Cell* rc = Ubiquitty::Screen::visibleCell(term, viewOffset, row, x);
        rowCodePoints[static_cast<std::size_t>(x)] = (rc != nullptr && rc->codePoint != 0) ? rc->codePoint : static_cast<uint32_t>(' ');
    }
    const bool isGuessed = Ubiquitty::Attributes::LinkRun::urlMatchSpanAtColumn(rowCodePoints.data(), paneColumns, column, { outputBuffer, static_cast<std::size_t>(outputCapacity) }).has_value();
    return isGuessed ? LinkSource::Guessed : LinkSource::None;
}

// Whether a primary click with these modifiers opens a link from this source.
// Ctrl opens any link, as Command does on macOS. A plain click opens only what
// the program declared, and only while [selection] osc8_click_opens is on: a
// guess is the terminal's reading of the text, and a plain click is how a
// reader focuses and selects, so acting on a guess there launches something
// nobody asked for. A connection to a host the program named (ssh, sftp, ftp,
// ftps) needs Ctrl even when declared (LinkRun::requiresLinkModifier).
bool linkClickOpens(LinkSource source, std::string_view uri, GdkModifierType state)
{
    if (source == LinkSource::None)
        return false;
    if ((state & GDK_CONTROL_MASK) != 0)
        return true;
    if (Ubiquitty::Attributes::LinkRun::requiresLinkModifier(uri))
        return false;
    return source == LinkSource::Declared && Ubiquitty::Preferences::Effective::osc8ClickOpens(Ubiquitty::Preferences::values());
}

// The URL-or-path token span covering (row, column), for smart double-click: tries a
// bare-URL match first, then a filesystem-path match, and reports the inclusive
// [column0,column1] span on a hit. Existence is not required (selecting a token never
// opens it) — pathMatchSpanAtColumn just rejects obvious non-paths. Mirrors the
// row-buffer build in linkURIAtCell.
std::optional<Ubiquitty::Attributes::LinkRun::ColumnSpan> smartTokenSpanAtCell(int row, int column)
{
    const Ubiquitty::Terminal* term = activePane()->session->terminal();
    const int paneColumns = activePane()->columns;
    if (!term || column < 0 || column >= paneColumns)
        return std::nullopt;
    const auto hold = holdPaneModel(*activePane());
    std::vector<uint32_t> rowCodePoints(static_cast<std::size_t>(paneColumns));
    const int viewOffset = activePane()->viewOffset;
    for (int x = 0; x < paneColumns; ++x) {
        const Ubiquitty::Cell* rc = Ubiquitty::Screen::visibleCell(term, viewOffset, row, x);
        rowCodePoints[static_cast<std::size_t>(x)] = (rc != nullptr && rc->codePoint != 0) ? rc->codePoint : static_cast<uint32_t>(' ');
    }
    char scratch[Ubiquitty::VT::maxLinkURILength];
    const std::span<char> into(scratch, sizeof(scratch));
    const auto span = Ubiquitty::Attributes::LinkRun::urlMatchSpanAtColumn(rowCodePoints.data(), paneColumns, column, into)
                          .or_else([&] { return Ubiquitty::Attributes::LinkRun::pathMatchSpanAtColumn(rowCodePoints.data(), paneColumns, column, into); });
    return span;
}

// GDK button number → the neutral Input::PointerButton identity. This is the
// native boundary; the xterm code mapping (left 0 / middle 1 / right 2) is the
// SHARED Input::xtermButtonCode. GDK orders the buttons primary/middle/secondary,
// unlike NSEvent's left/right/middle — hence the per-frontend switch. Buttons 8
// through 11 are the high buttons xterm numbers from 128; any other number is
// PointerButton::Other.
Ubiquitty::Input::PointerButton pointerButtonForGdk(guint gdkButton)
{
    using Ubiquitty::Input::PointerButton;
    switch (gdkButton) {
    case GDK_BUTTON_PRIMARY:
        return PointerButton::Left;
    case GDK_BUTTON_MIDDLE:
        return PointerButton::Middle;
    case GDK_BUTTON_SECONDARY:
        return PointerButton::Right;
    default:
        break;
    }
    static constexpr std::array<PointerButton, 4> highButtons { PointerButton::Button8, PointerButton::Button9, PointerButton::Button10, PointerButton::Button11 };
    constexpr guint firstHighButton = 8;
    if (gdkButton >= firstHighButton && gdkButton < firstHighButton + highButtons.size())
        return highButtons[gdkButton - firstHighButton];
    return PointerButton::Other;
}

// The xterm button code for a GDK button number, or -1 for one outside the
// identity set above: the shared Input::xtermButtonCode numbers whatever
// pointerButtonForGdk names.
int mouseButtonCode(guint gdkButton)
{
    const Ubiquitty::Input::PointerButton button = pointerButtonForGdk(gdkButton);
    if (button == Ubiquitty::Input::PointerButton::Other)
        return -1;
    return Ubiquitty::Input::xtermButtonCode(button);
}

// Resolve the SGR-pixel (DECSET 1016) device coordinate to report for a pointer
// at widget pixels (x, y): the 1-based grid-origin pixel when 1016 is active,
// else {-1, -1} so the encoder falls back to the cell-quantized pixel (and the
// cell-granular modes stay byte-identical to before). Mirrors the macOS gate
// (compute the device pixel only when mouseSGRPixelsActive).
void sgrPixelArgsForPoint(double x, double y, int& pixelX, int& pixelY)
{
    if (activePane()->mouseModes.mouseSGRPixelsActive) {
        devicePixelAtPoint(x, y, pixelX, pixelY);
    } else {
        pixelX = -1;
        pixelY = -1;
    }
}

// One pointer fact through the session's ladder — the macOS surface's route,
// so report-versus-selection ranking, the 1001 hilite gesture, motion dedup
// and copy-on-select are decided once in Core. This side contributes the
// facts only a frontend holds: geometry, modifiers, the click count.
bool forwardPointerFact(LinuxPane& pane, Ubiquitty::Runtime::TerminalSession::PointerFact::Kind kind,
    Ubiquitty::Input::PointerButton button, double x, double y, GdkModifierType state, int clickCount)
{
    int row = 0, column = 0;
    cellAtPoint(x, y, row, column);
    int pixelX = -1, pixelY = -1;
    sgrPixelArgsForPoint(x, y, pixelX, pixelY);
    Ubiquitty::Runtime::TerminalSession::PointerFact fact;
    fact.kind = kind;
    fact.button = button;
    fact.row = row;
    fact.column = column;
    fact.pixelX = pixelX;
    fact.pixelY = pixelY;
    // Where along the row the pointer is, unrounded, for the caret the ladder
    // resolves: on a row laid out as letters, the letter and the fraction of
    // it crossed.
    fact.xInCells = xInCellsAtPoint(x, y, row);
    fact.hasShift = (state & GDK_SHIFT_MASK) != 0;
    fact.hasAlternate = (state & GDK_ALT_MASK) != 0;
    fact.hasControl = (state & GDK_CONTROL_MASK) != 0;
    fact.hasCommand = (state & GDK_SUPER_MASK) != 0;
    // DECLRP Pb: the buttons held at this event, in DEC's bit order.
    if (state & GDK_BUTTON1_MASK)
        fact.heldButtonBits |= Ubiquitty::Mouse::Locator::buttonBit(0);
    if (state & GDK_BUTTON2_MASK)
        fact.heldButtonBits |= Ubiquitty::Mouse::Locator::buttonBit(1);
    if (state & GDK_BUTTON3_MASK)
        fact.heldButtonBits |= Ubiquitty::Mouse::Locator::buttonBit(2);
    fact.clickCount = clickCount;
    fact.viewOffset = pane.viewOffset;
    // A held button's motion extends a gesture; a button-less move is a hover.
    fact.isDragging = kind == Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion && button != Ubiquitty::Input::PointerButton::None;
    const Ubiquitty::Runtime::TerminalSession::PointerOutcome outcome = pane.session->pointerFact(fact, &pane.selection);
    if (outcome.needsDisplay)
        requestRepaint();
    return outcome.wasConsumed;
}

void onMousePressed(GtkGestureClick* gesture, gint nPress, gdouble x, gdouble y, gpointer userData)
{
    focusPaneFromEvent(userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane());
    noteCaretInteraction();
    const guint gdkButton = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    const Ubiquitty::Input::PointerButton button = pointerButtonForGdk(gdkButton);
    if (button != Ubiquitty::Input::PointerButton::Other)
        app().heldPointerButton = button;
    const GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));

    // The native fallbacks run before the ladder, and only while the
    // application has not grabbed the mouse — reporting hands the pointer to
    // the TUI, and the ladder below owns that ranking.
    if (!activePane()->mouseModes.mouseReportsActive) {
        // Middle-click pastes the PRIMARY selection (the X11 convention). The
        // read is async; onClipboardPasted feeds it (bracketed per the live mode).
        if (gdkButton == GDK_BUTTON_MIDDLE) {
            if (forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Press, button, x, y, state, nPress)) {
                gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
                return;
            }
            if (app().window)
                pasteClipboard(gtk_widget_get_primary_clipboard(app().window), Ubiquitty::ClipboardBuffer::Primary);
            gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
            return;
        }
        // Ctrl+click opens the link under the pointer (macOS's Cmd-click);
        // [selection] osc8_click_opens (default on, the same setting macOS
        // reads) lets a plain click open an OSC 8 link too (linkClickOpens).
        // A launched link claims the press so no selection begins.
        if (gdkButton == GDK_BUTTON_PRIMARY) {
            int row = 0, column = 0;
            cellAtPoint(x, y, row, column);
            if (openLinkAtCell(row, column, state, nPress)) {
                gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
                return;
            }
        }
    }

    if (button == Ubiquitty::Input::PointerButton::Other)
        return;
    if (forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Press, button, x, y, state, nPress))
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

void onMouseReleased(GtkGestureClick* gesture, gint, gdouble x, gdouble y, gpointer)
{
    const guint gdkButton = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    const Ubiquitty::Input::PointerButton button = pointerButtonForGdk(gdkButton);
    app().heldPointerButton = Ubiquitty::Input::PointerButton::Other;
    if (button == Ubiquitty::Input::PointerButton::Other)
        return;
    const GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    if (forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Release, button, x, y, state, 1))
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

// The CSS cursor name for a portable shape. GTK takes the CSS names, which the
// shape vocabulary was drawn from, so most map straight across; the ones without
// a CSS spelling fall back to the nearest that exists everywhere.
const char* cursorNameForShape(Ubiquitty::MousePointerShape shape)
{
    return Ubiquitty::OSC::pointerShapeWireName(shape);
}

// The shape last set on app().focusedPicture, so a pointer that moves without changing the
// answer does not re-issue the same set_cursor on every motion event.

// Resolve the pointer shape and apply it. Which shape ranks above which is
// Core's — Input::pointerShape — so this decides nothing beyond the facts only a
// frontend holds.
void updateHoverCursor(double x, double y, GdkModifierType state)
{
    if (!app().focusedPicture)
        return;
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    const auto hold = holdPaneModel(*activePane());

    int row = 0, column = 0;
    cellAtPoint(x, y, row, column);
    char uri[Ubiquitty::VT::maxLinkURILength];

    Ubiquitty::Input::PointerContext context;
    // The hand promises what a click would do, so it follows the same rule.
    const LinkSource source = linkURIAtCell(row, column, uri, static_cast<int>(sizeof(uri)));
    context.isOverLink = linkClickOpens(source, uri, state);
    // Which chord makes a drag rectangular is the reader's ([selection]
    // block_select_modifier) and Core matches it, so this arm reports what is
    // held and hard-codes no modifier. The same state answers whether such a
    // drag would reach through an application that is tracking the pointer,
    // which is why both come from one call.
    const Ubiquitty::Input::PointerMoment moment {
        .held = heldModifiers(state),
        .isMouseReporting = Ubiquitty::Mouse::tracksPointer(term),
    };
    const Ubiquitty::Input::PointerReportingState reporting = Ubiquitty::Input::pointerReportingState(
        moment, Ubiquitty::Input::pointerPolicyFromPreferences(Ubiquitty::Preferences::values()));
    context.isRectangularSelectArmed = Ubiquitty::Input::localDragIsRectangular(reporting);
    context.selectionBypassesMouseReporting = Ubiquitty::Input::allowsLocalDragSelect(reporting);
    // Read for completeness -- onMouseMotion already routes every X11-backend
    // locked event through reportPointerLockX11Motion and returns before this
    // runs, so this only matters if that ranking ever changes.
    context.isPointerLocked = app().isPointerLocked;
    // No chromeless window drag on this frontend yet, and no trailing-void
    // resolution — each stays false until the frontend can answer it, rather
    // than being answered wrongly here.

    const Ubiquitty::MousePointerShape shape = Ubiquitty::Input::pointerShape(term, context);
    if (shape == app().hoverCursorShape)
        return;
    gtk_widget_set_cursor_from_name(app().focusedPicture, cursorNameForShape(shape));
    app().hoverCursorShape = shape;
}

void onMouseMotion(GtkEventControllerMotion* motion, gdouble x, gdouble y, gpointer)
{
    const GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(motion));
    if (app().isPointerLocked && app().pointerLockOS.backend == Ubiquitty::Linux::PointerLockBackendKind::X11) {
        // The lock owns every event on this backend: no hover affordance, no
        // drag/report ladder -- GTK4's only relative-motion technique is this
        // recentre, so the ordinary motion path never runs while it is live.
        app().pointerLockLastModifiers = state;
        reportPointerLockX11Motion(x, y, state);
        return;
    }
    const bool isButtonDown = app().heldPointerButton != Ubiquitty::Input::PointerButton::Other;
    if (!isButtonDown) {
        // A button-less move: any-event tracking (1003) reports it, the
        // locator watches it, and a move nothing took is the hover
        // affordance's -- the hand cursor over a link. Under reporting the
        // application owns the pointer, so the cursor is left alone.
        const bool isReported = forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion,
            Ubiquitty::Input::PointerButton::None, x, y, state, 1);
        app().isHoverPointKnown = !isReported;
        app().hoverX = x;
        app().hoverY = y;
        if (!isReported)
            updateHoverCursor(x, y, state);
        return;
    }
    // A held button's motion is a drag fact: the ladder reports it under a
    // motion-tracking mode or extends the open local selection.
    forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion,
        app().heldPointerButton, x, y, state, 1);
}

// The pointer left a pane, so there is no hover for a modifier key to re-ask.
void onMouseLeave(GtkEventControllerMotion*, gpointer) { app().isHoverPointKnown = false; }

// The modifiers held once a key has gone down or up. Which of them a modifier
// key's own event carries differs between the X11 and Wayland backends, so the
// key's edge is applied here rather than read from the event.
GdkModifierType modifiersAfterKey(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge)
{
    if (keyval != GDK_KEY_Control_L && keyval != GDK_KEY_Control_R)
        return state;
    const unsigned held = edge == Ubiquitty::Keys::KeyEventType::Release ? (state & ~GDK_CONTROL_MASK) : (state | GDK_CONTROL_MASK);
    return static_cast<GdkModifierType>(held);
}

// Ctrl decides whether a click opens a guessed link (linkClickOpens), and the
// hand promises what a click would do, so it re-asks at the last hover point
// when Ctrl goes down or up. Pressing a key moves no pointer, so no motion
// event would, and macOS re-asks on flagsChanged for the same reason.
void updateHoverForModifierKey(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge)
{
    if (keyval != GDK_KEY_Control_L && keyval != GDK_KEY_Control_R)
        return;
    if (!app().isHoverPointKnown || app().isPointerLocked || app().heldPointerButton != Ubiquitty::Input::PointerButton::Other)
        return;
    updateHoverCursor(app().hoverX, app().hoverY, modifiersAfterKey(keyval, state, edge));
}

// The wheel-scroll policy from [mouse] config: wheel_lines (base lines per notch,
// Core's default when unset) × wheel_speed (multiplier). The delta ->
// line-count math is portable Core (ScrollTuning), shared with macOS. The trackpad
// knobs are not consulted here — GTK feeds the local-scrollback path discrete
// wheel notches, so this is always the (non-precise) wheel path.
Ubiquitty::Screen::ScrollTuning::Policy currentWheelPolicy()
{
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    Ubiquitty::Screen::ScrollTuning::Policy policy;
    policy.baseLinesPerTick = static_cast<double>(Ubiquitty::Preferences::Effective::wheelLines(config));
    policy.speed = Ubiquitty::Preferences::Effective::wheelSpeed(config);
    return policy;
}

gboolean onMouseScroll(GtkEventControllerScroll* scroll, gdouble deltaX, gdouble deltaY, gpointer userData)
{
    if (deltaX == 0.0 && deltaY == 0.0)
        return GDK_EVENT_PROPAGATE;
    focusPaneFromEvent(userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane());
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return GDK_EVENT_PROPAGATE;
    // GDK's deltas grow toward newer content; the fact's grow toward older,
    // which is the direction the wheel button codes and the view offset
    // share. The cell and pixel come from the controller's current event,
    // for a reported wheel press.
    Ubiquitty::Runtime::TerminalSession::ScrollFact fact;
    fact.deltaX = -deltaX;
    fact.deltaY = -deltaY;
    GtkEventController* ctrl = GTK_EVENT_CONTROLLER(scroll);
    double px = 0, py = 0;
    if (GdkEvent* event = gtk_event_controller_get_current_event(ctrl)) {
        // A smooth scroll is a continuous surface; a notched wheel arrives
        // with a direction.
        fact.isPrecise = gdk_scroll_event_get_direction(event) == GDK_SCROLL_SMOOTH;
        double ex = 0, ey = 0;
        if (gdk_event_get_position(event, &ex, &ey)) {
            px = ex;
            py = ey;
        }
    }
    int row = 0, column = 0;
    cellAtPoint(px, py, row, column);
    int pixelX = -1, pixelY = -1;
    sgrPixelArgsForPoint(px, py, pixelX, pixelY);
    fact.row = row;
    fact.column = column;
    fact.pixelX = pixelX;
    fact.pixelY = pixelY;
    const GdkModifierType state = gtk_event_controller_get_current_event_state(ctrl);
    fact.hasShift = (state & GDK_SHIFT_MASK) != 0;
    fact.hasAlternate = (state & GDK_ALT_MASK) != 0;
    fact.hasControl = (state & GDK_CONTROL_MASK) != 0;
    const Ubiquitty::Runtime::TerminalSession::ScrollOutcome outcome = activePane()->session->scrollFact(fact, currentWheelPolicy());
    if (outcome.linesToOffsetView != 0) {
        activePane()->viewOffset += static_cast<int>(outcome.linesToOffsetView);
        clampActivePaneViewOffset(term);
        requestRepaint();
    }
    if (outcome.wasConsumed) {
        armPTYWriteDrain(activePane());
        return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

// Mouse text selection.
//
// Selection is owned by the frontend (one Selection::Session per pane) and
// sequenced by Core: the session's pointer ladder opens, extends and closes
// the gesture, so a plain click clears, the first drag opens a CHAR
// selection, double grows to a WORD (or a smart token, config-gated), triple
// to a LINE — the same facade the macOS surface drives. Coordinates cross as
// VISIBLE-grid rows/columns with the viewOffset fact; the facade anchors them
// in absolute rows, so a selection holds still while the view scrolls.

// Serialize the current selection to UTF-8 through the facade's copy walk:
// wide glyphs whole, soft-wrapped rows joined, trailing blanks trimmed —
// byte-identical to what the macOS surface copies.
std::string selectionText()
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return std::string {};
    const auto hold = holdPaneModel(*activePane());
    return Ubiquitty::Selection::copiedText(activePane()->selection, *term);
}

// Copy the current selection (if any) to the clipboard via the PAL — the WHOLE
// buffer when Select All is active. Returns whether anything was written, so the
// caller can stay quiet on empty.
bool copySelectionToClipboard()
{
    const std::string text = selectionText();
    if (text.empty())
        return false;
    Ubiquitty::PAL::clipboardSetText(text);
    return true;
}

// Select All (Ctrl+Shift+A, macOS Edit > Select All / Cmd-A parity): the
// facade marks the whole buffer selected — oldest scrollback row through the
// live screen's last cell, the screen alone on the alternate screen. The copy
// is Ctrl+Shift+C's (or the copy-on-select option's), as on macOS.
void selectAll()
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    const auto hold = holdPaneModel(*activePane());
    Ubiquitty::Selection::selectAllText(activePane()->selection, *term);
    requestRepaint();
}

/// What a click on a link comes to, decided before anything is opened.
struct LinkDispatch {
    /// Whether the target is opened, shown in the file manager, or left alone.
    Ubiquitty::Attributes::LinkRun::LocalLinkAction action = Ubiquitty::Attributes::LinkRun::LocalLinkAction::Refuse;
    /// The URI to open, or the path to reveal; empty when refused.
    std::string target;
    /// The reader's `[links] line_handler` argv, run in place of the opener
    /// when it is not empty; `action` and `target` are what happens when it
    /// cannot be started.
    Ubiquitty::Attributes::LinkRun::HandlerArgv lineHandler;
};

/// What GIO's type for a file says about what the opener does with it.
struct ContentTypeFacts {
    /// A program: an executable, a shared object or a script, or a page a
    /// browser runs: HTML, XHTML or SVG.
    bool isLaunchable = false;
    /// Text, an image, audio or video, or a PDF, which the opener hands to a viewer.
    bool isDisplayOnly = false;
};

// GIO's type for a file, as the opener reads it: gtk_show_uri hands the file to
// the default application for this same type, so the type says what a click
// would run. Every script type is a subclass of application/x-executable, and
// every text type of text/plain. GIO types a file by its name when exactly one
// glob matches it, and reads the content only when no glob or several do
// (.conf, .cfg, .ini, .env, .swift, .m and .json, on shared-mime-info 2.x): a
// notes.txt holding a shell script is text/plain, and a notes.conf holding one
// is application/x-shellscript. Either way it is the opener's own reading. A
// page is revealed too, wherever its name came from: a report.conf holding
// HTML is text/html, and the browser that default opens runs its script. The
// name itself is isSafeToAutoOpenFileExtension's.
ContentTypeFacts contentTypeFacts(const char* path)
{
    ContentTypeFacts facts;
    GFile* file = g_file_new_for_path(path);
    GFileInfo* info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_CONTENT_TYPE, G_FILE_QUERY_INFO_NONE, nullptr, nullptr);
    if (info != nullptr) {
        if (const char* type = g_file_info_get_content_type(info); type != nullptr) {
            facts.isLaunchable = g_content_type_is_a(type, "application/x-executable") || g_content_type_is_a(type, "application/x-sharedlib")
                || g_content_type_is_a(type, "text/html") || g_content_type_is_a(type, "application/xhtml+xml")
                || g_content_type_is_a(type, "image/svg+xml");
            gchar* mime = g_content_type_get_mime_type(type);
            const bool isMedia = mime != nullptr && (g_str_has_prefix(mime, "image/") || g_str_has_prefix(mime, "audio/") || g_str_has_prefix(mime, "video/"));
            facts.isDisplayOnly = isMedia || g_content_type_is_a(type, "text/plain") || g_content_type_is_a(type, "application/pdf");
            g_free(mime);
        }
        g_object_unref(info);
    }
    g_object_unref(file);
    return facts;
}

// Whether a file sits on a volume that keeps no permissions. FAT, exFAT, NTFS
// and SMB report the mode their mount options chose, the execute bit set on
// every file, so the bit says nothing about the file there.
bool isOnVolumeWithoutPermissions(const char* path)
{
    // The NTFS drivers' magic numbers: the ntfs3 driver's ("ntfs"), and the
    // older read-only driver's ("NTFS").
    constexpr std::uint32_t ntfs3Magic = 0x7366746e;
    constexpr std::uint32_t ntfsMagic = 0x5346544e;
    struct statfs volume {};
    if (statfs(path, &volume) != 0)
        return false;
    switch (static_cast<std::uint32_t>(volume.f_type)) {
    case MSDOS_SUPER_MAGIC:
    case EXFAT_SUPER_MAGIC:
    case ntfs3Magic:
    case ntfsMagic:
    case CIFS_SUPER_MAGIC:
    case SMB2_SUPER_MAGIC:
    case SMB_SUPER_MAGIC:
        return true;
    default:
        return false;
    }
}

// What a click on one link target may do. The target is attacker-controllable
// output, so it is asked, in order: whether it reads as written
// (hasDeceptiveLinkCharacters, on the bytes as printed); whether its scheme is
// one the desktop handler may be handed at all (isLaunchableURLScheme); and,
// for a file: URI, whether it names a path on this machine
// (Session::localFileLinkPath, which refuses a query, a fragment and another
// machine's authority, and sets aside a fragment that names a line) and what
// is at that path once its symbolic links are resolved
// (LinkRun::localLinkAction). gtk_show_uri hands a file to whatever GIO maps
// its type to, which for a runner such as Wine or Java runs it, so an
// application, a script or an executable is only ever revealed. A link that
// names a line in a file LinkRun::lineHandlerTakes hands to the reader's
// `[links] line_handler` carries that argv too, built from the canonical path
// that was judged and never from the URI as printed.
LinkDispatch linkDispatchForURI(std::string_view uri)
{
    using Ubiquitty::Attributes::LinkRun::LocalLinkAction;
    if (Ubiquitty::Attributes::LinkRun::hasDeceptiveLinkCharacters(uri) || !Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme(uri))
        return {};
    if (!Ubiquitty::Session::isFileLinkURI(uri))
        return { LocalLinkAction::Open, std::string(uri), {} };
    // The name as it stands at the click. GLib's cached host name keeps the
    // first one it read for the life of the process, and ls --hyperlink writes
    // the current one after hostnamectl or DHCP renames the machine.
    const std::string localHost = Ubiquitty::PAL::systemHostName();
    const std::string path = Ubiquitty::Session::localFileLinkPath(uri, localHost, Ubiquitty::Session::FilePathEncoding::Bytes);
    if (path.empty())
        return {};
    std::array<char, PATH_MAX> resolved {};
    if (realpath(path.c_str(), resolved.data()) == nullptr)
        return {};
    const char* canonical = resolved.data();
    Ubiquitty::Attributes::LinkRun::LocalFileFacts facts;
    struct stat status {};
    if (stat(canonical, &status) == 0) {
        facts.isDirectory = S_ISDIR(status.st_mode);
        facts.isRegularFile = S_ISREG(status.st_mode);
        facts.isExecutable = facts.isRegularFile && access(canonical, X_OK) == 0;
        if (facts.isRegularFile) {
            const ContentTypeFacts type = contentTypeFacts(canonical);
            facts.isLaunchableType = type.isLaunchable;
            facts.isDisplayOnlyType = type.isDisplayOnly;
            facts.isOnVolumeWithoutPermissions = isOnVolumeWithoutPermissions(canonical);
        }
    }
    const LocalLinkAction action = Ubiquitty::Attributes::LinkRun::localLinkAction(canonical, facts);
    LinkDispatch dispatch { action, action == LocalLinkAction::Reveal ? std::string(canonical) : std::string {}, {} };
    if (action == LocalLinkAction::Open) {
        // The canonical path is what was classified, so it is what is opened.
        gchar* canonicalURI = g_filename_to_uri(canonical, nullptr, nullptr);
        if (canonicalURI == nullptr)
            return {};
        dispatch.target = canonicalURI;
        g_free(canonicalURI);
    }
    const Ubiquitty::Session::FileLinkLine line = Ubiquitty::Session::fileLinkLine(uri);
    if (line.line > 0 && Ubiquitty::Attributes::LinkRun::lineHandlerTakes(facts)) {
        const std::string command = Ubiquitty::Preferences::Effective::linkLineHandler(Ubiquitty::Preferences::values());
        dispatch.lineHandler = Ubiquitty::Attributes::LinkRun::lineHandlerArgv(command, canonical, line.line, line.column);
    }
    return dispatch;
}

// What a primary press on (row, column) asks of the link there. Only the first
// press of a multi-click opens anything, as on macOS: the second press of a
// double-click is selecting a word, and would otherwise open the link again.
LinkDispatch linkDispatchAtCell(int row, int column, GdkModifierType state, int pressCount)
{
    if (pressCount != 1)
        return {};
    std::array<char, Ubiquitty::VT::maxLinkURILength> uri {};
    const LinkSource source = linkURIAtCell(row, column, uri.data(), static_cast<int>(uri.size()));
    if (!linkClickOpens(source, uri.data(), state))
        return {};
    return linkDispatchForURI(uri.data());
}

// Open the link under (row, column) through the desktop URL handler, start the
// reader's line handler at the line it names, or show the file it names in the
// file manager, as linkDispatchAtCell decides. Returns true if anything was
// opened, started or shown.
bool openLinkAtCell(int row, int column, GdkModifierType state, int pressCount)
{
    using Ubiquitty::Attributes::LinkRun::LocalLinkAction;
    if (!app().window)
        return false;
    const LinkDispatch dispatch = linkDispatchAtCell(row, column, state, pressCount);
    // A line handler that cannot be started leaves the file to the rule it
    // would have met with none configured.
    if (!dispatch.lineHandler.empty() && spawnWithoutShell(dispatch.lineHandler, "line handler"))
        return true;
    switch (dispatch.action) {
    case LocalLinkAction::Open:
        // gtk_show_uri is the one-call, fire-and-forget opener — exactly what a
        // synchronous click handler wants. GTK 4.10 soft-deprecated it for the
        // async GtkUriLauncher; the launcher buys nothing here (no result to act
        // on), so keep the simple call and silence the deprecation locally.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        gtk_show_uri(GTK_WINDOW(app().window), dispatch.target.c_str(), GDK_CURRENT_TIME);
#pragma GCC diagnostic pop
        return true;
    case LocalLinkAction::Reveal: {
        // The task the launcher starts holds its own reference, so neither
        // object outlives this call on our account.
        GFile* file = g_file_new_for_path(dispatch.target.c_str());
        GtkFileLauncher* launcher = gtk_file_launcher_new(file);
        gtk_file_launcher_open_containing_folder(launcher, GTK_WINDOW(app().window), nullptr, nullptr, nullptr);
        g_object_unref(launcher);
        g_object_unref(file);
        return true;
    }
    case LocalLinkAction::Refuse:
        return false;
    }
    return false;
}

// Run loop.

// Execute a resolved bell: the audible cue through the PAL (gdk_display_beep,
// suppressed for a Visual-only mode), the visual flash via GTK's widget error
// bell, and — when Core flagged it (the window isn't focused) — an OS desktop
// notification so a background bell isn't missed. out.bell is the resolved
// BellMode (Off/Audio/Visual/Both), the same enum PAL::bellRing takes.
void ringBell(const Ubiquitty::BellCue& cue)
{
    Ubiquitty::PAL::bellRing(cue.mode);
    if (app().window)
        gtk_widget_error_bell(app().window);
    if (cue.shouldNotify && app().application) {
        GNotification* notification = g_notification_new("Ubiquitty");
        g_notification_set_body(notification, "The terminal bell rang.");
        g_application_send_notification(G_APPLICATION(app().application), "ubiquitty-bell", notification);
        g_object_unref(notification);
    }
}

// The PTY refused part of a send — a paste into a program that is not
// reading — and the queued bytes go nowhere until it drains. This watch fires
// when the PTY takes bytes again, drains, and removes itself the moment the
// queue is empty: a writability watch left armed on a writable fd is a busy
// spin of the whole main loop.
gboolean onPTYWritable(gint, GIOCondition, gpointer user)
{
    auto* pane = static_cast<LinuxPane*>(user);
    if (pane->session && pane->session->drainPendingWrite())
        return G_SOURCE_CONTINUE; // still queued — stay armed for the next window
    pane->ptyWriteSource = 0;
    return G_SOURCE_REMOVE;
}

// Arms the writability watch after a send that left bytes queued. Idempotent:
// an armed watch stays the one watch.
void armPTYWriteDrain(LinuxPane* pane)
{
    // The ingest loop flushes its own queued writes, on the thread that owns
    // the transport; a watch here would race it for the fd.
    if (!pane || pane->isIngesting || pane->ptyWriteSource != 0 || !pane->session || !pane->session->hasPendingWrite())
        return;
    const int fileDescriptor = pane->session->fileDescriptor();
    if (fileDescriptor < 0)
        return;
    pane->ptyWriteSource = g_unix_fd_add(fileDescriptor, G_IO_OUT, onPTYWritable, pane);
}

gboolean onPtyReadable(gint, GIOCondition, gpointer userData)
{
    // The pane is carried as user_data so each PTY fd drains its OWN runtime,
    // independent of which pane is focused (tabs run concurrently in the background).
    LinuxPane* pane = userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane();
    const Ubiquitty::Runtime::DrainOutcome outputBuffer = drainPane(*pane);
    if (outputBuffer.reachedEnd) {
        if (outputBuffer.fatal)
            g_printerr("ubiquitty-linux: PTY read error (errno %d); closing\n", outputBuffer.lastError);
        // The source self-removes via the G_SOURCE_REMOVE below; clear the tag FIRST
        // so closePaneTab's g_source_remove can't double-remove it. closePaneTab may
        // destroy `pane` (the unique_ptr) — never touch `pane` after this call.
        pane->ptySource = 0;
        closePaneTab(pane); // last tab → window close; else just this tab
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

// Walk the active tab's split tree, invoking `fn` for each LIVE leaf's LinuxPane.
// The model is the authority for which panes are visible. The L→R leaf walk is
// the shared Panes::forEachLeaf (Core/Panes/PaneTree.h) — both frontends use it so
// the traversal order can't drift.
template<typename Fn> void forEachVisibleLeaf(Fn fn)
{
    const Panes::Tree* tree = app().model->paneTree(app().model->activeSurface());
    if (!tree)
        return;
    Panes::forEachLeaf(*tree, [&](int paneID) {
        if (LinuxPane* pane = paneForID(static_cast<PaneID>(paneID)); pane)
            fn(*pane);
    });
}

// Per-frame advance of the indeterminate comet, wrapping at 1.0. ~1.4s/sweep at
// the ~60Hz frame clock; the exact rate is cosmetic (no gtkApplication-visible timing).
constexpr double indeterminateStep = 0.012;

constexpr double progressBarHeight = 3.0; // thin top-edge line, matches the macOS bar

// Paint one pane's progress bar within [x, x+width] at the pane's top edge.
// Core decides what the bar is drawn in (App::statusMarkInk): the colour the
// pane's theme names for the tint, or the platform's where the theme names
// none. GTK's own colour for a bar is the widget's foreground, dimmed for an
// inactive one; it has none for an error, so that is always the theme's.
// Normal/Paused fill from the left to value%; Error fills full width;
// Indeterminate slides a short comet segment, clipped to the pane so it can't
// bleed into a neighbour.
void paintProgressSegment(cairo_t* cr, GtkWidget* widget, double x, double y, double width, uint8_t state, uint8_t value, Ubiquitty::OSC::ProgressTint tint, const Ubiquitty::Themes::StatusColors& colors)
{
    using namespace Ubiquitty;
    using namespace Ubiquitty::OSC;
    const Ubiquitty::App::PlatformStatusColors platform { .hasProgress = true, .hasProgressInactive = true, .hasProgressError = false, .hasNotification = false };
    const Ubiquitty::App::StatusMark mark = Ubiquitty::App::progressStatusMark(tint);
    const Ubiquitty::App::StatusMarkInk ink = Ubiquitty::App::statusMarkInk(mark, colors, platform);
    double red = ink.color.red / 255.0, green = ink.color.green / 255.0, blue = ink.color.blue / 255.0, alpha = 1.0;
    if (ink.isPlatformColor) {
        GdkRGBA foreground;
        gtk_widget_get_color(widget, &foreground);
        red = foreground.red;
        green = foreground.green;
        blue = foreground.blue;
        alpha = mark == Ubiquitty::App::StatusMark::ProgressInactive ? 0.40 : 1.0;
    }
    cairo_set_source_rgba(cr, red, green, blue, alpha);
    const double height = progressBarHeight;
    if (state == Ubiquitty::OSC::ProgressIndeterminate) {
        const double segment = width * 0.30;
        const double segmentX = x + app().progressPhase * (width + segment) - segment;
        cairo_save(cr);
        cairo_rectangle(cr, x, y, width, height); // clip the comet to this pane
        cairo_clip(cr);
        cairo_rectangle(cr, segmentX, y, segment, height);
        cairo_fill(cr);
        cairo_restore(cr);
        return;
    }
    if (state == Ubiquitty::OSC::ProgressError)
        cairo_rectangle(cr, x, y, width, height);
    else { // Normal / Paused: determinate fill from the left
        const double fraction = (value > 100 ? 100 : value) / 100.0;
        cairo_rectangle(cr, x, y, width * fraction, height);
    }
    cairo_fill(cr);
}

// Draw a bar on the top edge of every visible pane that reports progress. Each
// pane's (kind, value) comes from its own Terminal; the tint role is the shared
// progressTint (focused pane = accent, unfocused split pane = gray, error
// = red, all dimmed when the window is inactive). The bar is positioned at the
// pane picture's bounds within this full-area overlay child.
void drawProgressBar(GtkDrawingArea* area, cairo_t* cr, int width, int height, gpointer)
{
    using namespace Ubiquitty;
    (void)width;
    (void)height;
    GtkWidget* widget = GTK_WIDGET(area);
    int leafCount = 0;
    forEachVisibleLeaf([&](LinuxPane&) { ++leafCount; });
    const bool multiPane = leafCount > 1;
    const bool isWindowActive = app().window && gtk_window_is_active(GTK_WINDOW(app().window));
    forEachVisibleLeaf([&](LinuxPane& pane) {
        if (!pane.picture)
            return;
        uint8_t state = Ubiquitty::OSC::ProgressNone, value = 0;
        if (Ubiquitty::Terminal* term = pane.session->terminal()) {
            const auto hold = holdPaneModel(pane);
            Ubiquitty::getProgress(term, &state, &value);
        }
        if (state == Ubiquitty::OSC::ProgressNone)
            return;
        graphene_rect_t bounds;
        if (!gtk_widget_compute_bounds(pane.picture, widget, &bounds))
            return;
        const bool isPaneFocused = (&pane == activePane());
        const Ubiquitty::OSC::ProgressTint tint = Ubiquitty::OSC::progressTint(state, isPaneFocused ? Ubiquitty::OSC::PaneFocusState::Focused : Ubiquitty::OSC::PaneFocusState::Unfocused, multiPane ? Ubiquitty::OSC::PaneLayout::MultiPane : Ubiquitty::OSC::PaneLayout::SinglePane,
            isWindowActive ? Ubiquitty::OSC::WindowActivityState::Active : Ubiquitty::OSC::WindowActivityState::Background);
        paintProgressSegment(cr, widget, bounds.origin.x, bounds.origin.y, bounds.size.width, state, value, tint, pane.session->statusColors());
    });
}

// Reconcile the per-pane bars: show the overlay when any visible pane reports
// progress (drawProgressBar reads each pane's own state), and advance the shared
// indeterminate comet while any pane spins. Called every frame from onTick —
// cheap (a few panes), and the comet needs a per-frame redraw anyway.
void updateProgressBar()
{
    using namespace Ubiquitty;
    if (!app().progressBar)
        return;
    bool anyProgress = false;
    bool anyIndeterminate = false;
    forEachVisibleLeaf([&](LinuxPane& pane) {
        uint8_t state = Ubiquitty::OSC::ProgressNone, value = 0;
        if (Ubiquitty::Terminal* term = pane.session->terminal()) {
            const auto hold = holdPaneModel(pane);
            Ubiquitty::getProgress(term, &state, &value);
        }
        if (state != Ubiquitty::OSC::ProgressNone)
            anyProgress = true;
        if (state == Ubiquitty::OSC::ProgressIndeterminate)
            anyIndeterminate = true;
    });
    gtk_widget_set_visible(app().progressBar, anyProgress);
    if (!anyProgress)
        return;
    if (anyIndeterminate)
        app().progressPhase = app().progressPhase + indeterminateStep >= 1.0 ? 0.0 : app().progressPhase + indeterminateStep;
    gtk_widget_queue_draw(app().progressBar);
}

// Hands the accessible object the active pane's current text and where its
// cells sit in the widget, in logical pixels, so a reader's caret and
// selection land where the glyphs are drawn.
// How often the accessible snapshot is republished while frames stream.
constexpr double accessiblePublishIntervalSeconds = 0.1;

void publishAccessibleTerminalNow();

gboolean onAccessiblePublishDue(gpointer)
{
    app().accessiblePublishSource = 0;
    publishAccessibleTerminalNow();
    return G_SOURCE_REMOVE;
}

// Publishes the accessible snapshot at the paced cadence, booking one
// trailing publish for the frame that ends a stream.
void publishAccessibleTerminal()
{
    if (!app().accessibleTerminal)
        return;
    const double now = static_cast<double>(Ubiquitty::PAL::monotonicMicros()) / 1e6;
    if (now - app().lastAccessiblePublishSeconds >= accessiblePublishIntervalSeconds) {
        publishAccessibleTerminalNow();
        return;
    }
    if (app().accessiblePublishSource == 0)
        app().accessiblePublishSource = g_timeout_add(static_cast<guint>(accessiblePublishIntervalSeconds * 1000.0), onAccessiblePublishDue, nullptr);
}

void publishAccessibleTerminalNow()
{
    GtkWidget* accessible = app().accessibleTerminal;
    LinuxPane* pane = activePane();
    if (!accessible || !pane || !pane->picture)
        return;
    app().lastAccessiblePublishSeconds = static_cast<double>(Ubiquitty::PAL::monotonicMicros()) / 1e6;
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(pane->picture, accessible, &bounds))
        return;
    const float scale = static_cast<float>(app().scale);
    const auto& presentation = pane->presentation;
    const auto hold = holdPaneModel(*pane);
    Ubiquitty::Linux::Accessibility::updateTerminal(accessible,
        Ubiquitty::Linux::Accessibility::snapshot(pane->session->terminal(), pane->viewOffset, &pane->selection.state),
        { bounds.origin.x + presentation.origin.x / scale, bounds.origin.y + presentation.origin.y / scale },
        { logicalCellWidth() * presentation.scale, logicalCellHeight() * presentation.scale });
}

gboolean onTick(GtkWidget*, GdkFrameClock*, gpointer)
{
    // Match each VISIBLE leaf's grid to its picture (its split sub-rectangle), and
    // resize Core + the PTY when it changes. The cell is the font-derived runtime
    // cell (Unifont 8×16 when forced); one font, so every pane shares the cell metric.
    // The whole-window grid (app().paneContainer) seeds new full-window tabs. Reserve
    // the window padding (left+right / top+bottom) the same way the per-pane math
    // does via the picture's margins, so the seed matches the realized grid.
    if (app().paneContainer) {
        const Ubiquitty::Preferences::Values::PaddingEdges pad = loadPreferences().resolvedPadding();
        // Shared viewport→grid resolver: the left/right inset eats the
        // columns axis, top+bottom is the rows reserve — the same split the per-pane
        // math gets from the picture's margins. clampToMinimumGrid=false keeps the Linux
        // "don't shrink to 1x1, keep the prior grid" semantic: raw dims below 1 fail
        // the `>= 1` gate below rather than collapsing the grid to a single cell.
        const Ubiquitty::Rendering::EdgeInsets insets { static_cast<float>(pad.left), static_cast<float>(pad.right), 0.0f, 0.0f };
        const Ubiquitty::GridSize dims
            = Ubiquitty::Rendering::gridFromViewport({ static_cast<float>(gtk_widget_get_width(app().paneContainer)), static_cast<float>(gtk_widget_get_height(app().paneContainer)) }, insets, static_cast<float>(pad.top + pad.bottom), { logicalCellWidth(), logicalCellHeight() }, Ubiquitty::Rendering::GridFloor::None);
        if (dims.columns >= 1 && dims.rows >= 1) {
            app().columns = dims.columns;
            app().rows = dims.rows;
        }
    }
    forEachVisibleLeaf([&](LinuxPane& pane) {
        if (!pane.picture)
            return;
        // Shared viewport→grid resolver: the picture's GTK margins
        // already carry the padding, so no insets/reserve here. clampToMinimumGrid=false
        // preserves the `>= 1` keep-prior-grid gate (see the app().paneContainer seed).
        const Ubiquitty::FloatSize viewport {
            static_cast<float>(gtk_widget_get_width(pane.picture) * app().scale),
            static_cast<float>(gtk_widget_get_height(pane.picture) * app().scale)
        };
        if (viewport.width != pane.presentationViewport.width || viewport.height != pane.presentationViewport.height)
            requestRepaint();
        const Ubiquitty::GridSize dims = Ubiquitty::Rendering::gridFromViewport({ static_cast<float>(gtk_widget_get_width(pane.picture)), static_cast<float>(gtk_widget_get_height(pane.picture)) }, {}, 0.0f, { logicalCellWidth(), logicalCellHeight() }, Ubiquitty::Rendering::GridFloor::None);
        const int c = dims.columns;
        const int r = dims.rows;
        const bool didResizeGrid = c >= 1 && r >= 1 && (c != pane.columns || r != pane.rows);
        if (didResizeGrid) {
            pane.columns = c;
            pane.rows = r;
            requestRepaint();
        }
        // Stages pixels before the owner sees the grid, so a local program
        // receives one complete winsize and a remote picture is never reflowed here.
        publishPanePixelGeometry(pane);
        // The renderer builds its proportional face on the first frame after a
        // font or zoom change, so a remote pane's host is told the faces once
        // that frame has drawn; outside the model hold taken below.
        if (pane.session)
            pane.session->publishOwedProportionalFaces();
    });
    // Wayland pointer lock: the surface gets no ordinary motion events while
    // locked, so this tick is what turns the relative-pointer listener's
    // deposits into the reports Core's ladder expects.
    drainPointerLockMotion();
    // Whether this present is withheld is Core's rule: a synchronized-output
    // block still open, the coherence rule holding a screen still being drawn,
    // an erase whose redraw is still arriving. A saturated drain is not
    // withheld -- its frames are the passes' own -- which is what keeps a flood
    // on screen rather than frozen until it ends. Asked before the hold below:
    // the rule stamps the block under the model lock itself.
    const bool shouldHoldForSync = activePane()->session->shouldWithholdFrame(Ubiquitty::PAL::monotonicTicks());
    // Core's drive recommends continuous presentation while the screen
    // changes at frame rate: the grid moves between any two ticks, so a frame
    // is owed on each whatever the delivery cadence, as the Swift arm's frame
    // clock resumes on the same recommendation. Only an ingesting pane: the
    // inline drain's own deliveries already ask per drain.
    if (activePane()->isIngesting && activePane()->session->isAdaptivePresentation()) {
        // GTK only exposes the panel interval after the picture is rooted.
        // Refresh the driver's rate before asking it whether output still
        // warrants a vblank frame. FrameDriver's interval is atomic because
        // the ingest thread reads it while the main thread updates it here.
        const double frameInterval = cursorPresentationInterval(activePane()->picture);
        if (frameInterval != activePane()->session->presentationFrameIntervalSeconds())
            activePane()->session->setPresentationFrameIntervalSeconds(frameInterval);
        if (activePane()->session->isPresentationRecommendedContinuous())
            requestRepaint();
    }
    ++app().perfWindow.ticks;
    if (shouldHoldForSync)
        ++app().perfWindow.withheldTicks;
    // The tick's own reads of the focused model, ended before the paint: each
    // pane's frame takes its own hold and hands it back at the renderer's
    // capture boundary, which a hold here would outlast. The pointer fact
    // and the rule above asked the session and so came first.
    const std::uint32_t holdStartMicros = Ubiquitty::PAL::monotonicMicros();
    auto hold = holdPaneModel(*activePane());
    const double holdWaitSeconds = static_cast<double>(static_cast<std::uint32_t>(Ubiquitty::PAL::monotonicMicros() - holdStartMicros)) / 1e6;
    app().perfWindow.holdWaitSeconds += holdWaitSeconds;
    app().perfWindow.maxHoldWaitSeconds = std::max(app().perfWindow.maxHoldWaitSeconds, holdWaitSeconds);
    // Keep the focused pane's scrollback viewport in range: a resize or trimmed
    // history can shrink scrollbackCount below the current offset.
    const int prevViewOffset = activePane()->viewOffset;
    clampActivePaneViewOffset(activePane()->session->terminal());
    if (activePane()->viewOffset != prevViewOffset)
        requestRepaint();
    // Cursor opacity changes only at the bounded GTK paint steps. A step can
    // arrive while another reason has the clock active, so reconcile it here
    // as well as through the sleeping caret timer.
    if (activePane()->viewOffset == 0) {
        const Ubiquitty::Linux::CursorOverlay cursor = resolveCursorOverlay(activePane()->session->terminal());
        if ((cursor.visible || activePane()->cursorPresentation.isHolding()) && cursor.blinkAlpha != activePane()->lastCursorBlinkAlpha) {
            requestRepaint(RepaintCause::CursorStep);
        }
    }
    // SGR 5/6 text blink: when any visible pane has blink cells, repaint on the
    // shared blink-phase step — the same Core gate macOS uses (needsAnimationRedraw),
    // so it honors [appearance] blink_animation and only fires on a step (not every
    // frame). The hint is sticky, so the live-screen reading beside it is what
    // lets a pane whose blink was erased go idle/quiet; a scrolled-back pane
    // keeps the step, since the rows it displays are outside that reading.
    const uint32_t nowBlinkTicks = Ubiquitty::PAL::monotonicTicks().count;
    bool doesBlinkOweFrame = false;
    forEachVisibleLeaf([&](LinuxPane& pane) {
        const auto paneHold = holdPaneModel(pane);
        Ubiquitty::Terminal* t = pane.session->terminal();
        if (t && t->grid && t->grid->hasBlinkHint()
            && (pane.viewOffset > 0 || Ubiquitty::Rendering::anyCellBlinks(*t))
            && Ubiquitty::needsAnimationRedraw(t->grid.get(), nowBlinkTicks, app().lastBlinkPaintTicks))
            doesBlinkOweFrame = true;
    });
    if (doesBlinkOweFrame)
        requestRepaint();
    // A withheld present keeps the flag: clearing it would discard a completed
    // frame already marked for paint, turning a delayed frame into a lost one.
    // The tick stays installed while the flag stands, so the frame the rule
    // releases is drawn on the next tick. This still only defers, which is
    // weaker than macOS -- that frontend captures the complete frame at the
    // sync-clear instant and presents it mid-block, so a continuous BSU/ESU
    // stream keeps delivering at the native rate rather than falling back to
    // the watchdog's cadence.
    if (app().isRepaintPending && !shouldHoldForSync) {
        // Repaint every visible leaf (a split tab shows N at once); each is still one
        // texture from one renderGrid/rasterizeTerm call keyed to its own term.
        // The frame's own reads of the focused model come first, under the
        // tick's hold, which the focused pane's frame then ends at its
        // capture boundary: the blink phase this frame paints and the
        // accessible snapshot of the grid it paints.
        const float paintedBlinkAlpha = resolveCursorOverlay(activePane()->session->terminal()).blinkAlpha;
        publishAccessibleTerminal();
        forEachVisibleLeaf([&](LinuxPane& pane) { renderPaneInto(pane, pane.picture, &pane == activePane() ? &hold : nullptr); });
        activePane()->lastCursorBlinkAlpha = paintedBlinkAlpha;
        app().lastBlinkPaintTicks = nowBlinkTicks; // advance the text-blink phase baseline
        app().isRepaintPending = false;
    }
    // The OSC 9;4 bar lives in its own GtkOverlay child (not the grid texture), so
    // it reconciles independently of app().isRepaintPending — progress changes and the comet
    // animation drive its own redraw.
    updateProgressBar();

    // Nothing to draw and no output for a while: stop asking the clock. GTK
    // calls back at the display rate for as long as a callback is installed,
    // and the body above is not free — it re-derives every visible pane's grid
    // and reconciles two blink phases. requestRepaint() brings it back, which
    // is why every path that wants a frame goes through it.
    //
    // The progress bar drives its own redraw through its own widget, so a
    // paused clock does not freeze it.
    const double tickSeconds = static_cast<double>(Ubiquitty::PAL::monotonicMicros()) / 1e6;
    if (!app().isRepaintPending && app().frameDriver.idleExpired(tickSeconds)) {
        app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::OnDemand);
        app().tickCallbackID = 0;
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

// Asks for a frame, and makes sure something will draw it.
//
// Every path that wants the screen repainted comes here rather than setting the
// flag: the frame clock's callback is removed when output goes idle, so a path
// that only set the flag would mark a frame nobody was left to paint. The
// driver's stamp is what the idle decision is measured from, so a request that
// skipped it would leave the clock reading the last stamp instead of this one.
void requestRepaint(RepaintCause cause)
{
    app().isRepaintPending = true;

    // Output activity extends continuous drive even without a widget. A
    // cursor-only step changes pixels but does not extend that drive.
    if (cause == RepaintCause::Activity) {
        const double now = static_cast<double>(Ubiquitty::PAL::monotonicMicros()) / 1e6;
        (void)app().frameDriver.noteActivity(now);
    }

    if (!app().paneContainer || !gtk_widget_get_mapped(app().paneContainer))
        return; // headless or unmapped: the next map requests its own frame
    if (app().tickCallbackID != 0)
        return;
    app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::Continuous);
    app().tickCallbackID = gtk_widget_add_tick_callback(app().paneContainer, onTick, nullptr, nullptr);
}

// Build this pane's GtkPicture + its OWN event controllers (each carrying &pane, so
// a click/scroll routes to the pane it landed on — the bodies then read the focused
// pane activePane(), which the press/scroll handlers re-point via focusPaneFromEvent).
// The pane owns a strong ref (ref_sink) so its picture survives re-parenting across
// GtkPaned rebuilds. GTK-only: callers guard on app().window (headless smokes have no
// display and never build widgets — renderPaneInto bails on a null picture).
// Apply the resolved window padding to a pane's grid picture as GTK margins.
// Re-applied on config reload so a [appearance] padding change reflows the grid.
void applyPanePadding(LinuxPane& pane)
{
    if (!pane.picture)
        return;
    const Ubiquitty::Preferences::Values::PaddingEdges p = loadPreferences().resolvedPadding();
    gtk_widget_set_margin_start(pane.picture, static_cast<int>(p.left + 0.5));
    gtk_widget_set_margin_end(pane.picture, static_cast<int>(p.right + 0.5));
    gtk_widget_set_margin_top(pane.picture, static_cast<int>(p.top + 0.5));
    gtk_widget_set_margin_bottom(pane.picture, static_cast<int>(p.bottom + 0.5));
    publishPanePixelGeometry(pane);
}

void attachPaneControllers(LinuxPane& pane)
{
    if (pane.picture)
        return; // already built
    pane.picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
    gtk_picture_set_content_fit(GTK_PICTURE(pane.picture), GTK_CONTENT_FIT_FILL);
    gtk_widget_set_hexpand(pane.picture, TRUE);
    gtk_widget_set_vexpand(pane.picture, TRUE);
    // Window padding: inset the grid picture by the resolved per-edge padding.
    // GTK margins sit OUTSIDE the widget's allocation, so they shrink the size
    // the resize→grid math (gtk_widget_get_width/cellWidth) divides — the same
    // effect macOS gets by reserving padding on the content box — and reveal the
    // window background in the inset band. Resolved through Settings's portable
    // single source of truth, so it can't drift from the macOS resolution.
    applyPanePadding(pane);

    GtkGesture* mouseClick = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(mouseClick), 0);
    g_signal_connect(mouseClick, "pressed", G_CALLBACK(onMousePressed), &pane);
    g_signal_connect(mouseClick, "released", G_CALLBACK(onMouseReleased), &pane);
    gtk_widget_add_controller(pane.picture, GTK_EVENT_CONTROLLER(mouseClick));

    GtkEventController* motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(onMouseMotion), &pane);
    g_signal_connect(motion, "leave", G_CALLBACK(onMouseLeave), &pane);
    gtk_widget_add_controller(pane.picture, motion);

    // File drop: a file dropped on this pane writes its escaped path(s) to the
    // prompt (the macOS file drag & drop, via the shared Input::shellEscapedPath).
    GtkDropTarget* fileDrop = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    g_signal_connect(fileDrop, "drop", G_CALLBACK(onFileDrop), &pane);
    gtk_widget_add_controller(pane.picture, GTK_EVENT_CONTROLLER(fileDrop));

    GtkEventController* scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(onMouseScroll), &pane);
    gtk_widget_add_controller(pane.picture, scroll);
}

// Launch one pane's login shell and register its own PTY drain source (carrying
// &pane), so every tab advances its Ubiquitty::Terminal concurrently. Headless smokes poll via
// drainBriefly and never dispatch the source; under GTK it drives onPtyReadable.
bool bindPane(LinuxPane& pane, PaneID paneID)
{
    Ubiquitty::Runtime::TerminalSession* session = app().model->session(paneID);
    if (!session)
        return false;
    pane.cursorPresentation.reset();
    if (pane.cursorPresentationSource != 0) {
        g_source_remove(pane.cursorPresentationSource);
        pane.cursorPresentationSource = 0;
    }
    pane.session = session;
    app().paneByID[paneID] = &pane;
    // The model started, launched and seeded the session from the config
    // fold; the launch report is the one diagnostic it hands back, and where
    // a diagnostic lands is this side's call.
    const std::string seedReport = app().model->lastLaunchReport();
    if (!seedReport.empty())
        Ubiquitty::PAL::logLine(stderr, "ubiquitty-linux: {}", seedReport);
    if (Ubiquitty::Terminal* term = session->terminal())
        wirePaneClients(pane, *term);
    const auto richShaper = pane.richText.shaper();
    session->setRichTextShaper(richShaper.function, richShaper.context);
    publishPaneTypography(pane);
    // The proportional-text measurer (Docs/proportional-text.md): the one
    // renderer's strip sheet answers a `q=1` query for every pane. The
    // renderer outlives every session, so the context is a plain pointer.
    session->setTextMeasurer(
        [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t weight,
            Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* cellAdvanceOut) {
            const auto* renderer = static_cast<const Ubiquitty::Linux::VulkanRenderer*>(context);
            if (cellAdvanceOut)
                *cellAdvanceOut = renderer->proportionalCellAdvanceInPixels();
            return renderer->shapeProportionalRun(
                std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                Ubiquitty::ProportionalRunStyle { .faceBits = faceBits, .weight = weight },
                std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
        },
        &app().vulkan);
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    const int launchRows = Ubiquitty::Preferences::Effective::launchRows(config);
    const int launchColumns = Ubiquitty::Preferences::Effective::launchColumns(config);
    pane.columns = launchColumns;
    pane.rows = launchRows;
    publishPanePixelGeometry(pane);
    // A window's pane parses on Core's ingest thread; a headless entry has no
    // main loop to post to, so it keeps the fd watch and drains inline.
    if (app().application)
        beginPaneIngest(pane);
    const int fileDescriptor = session->fileDescriptor();
    if (!pane.isIngesting && fileDescriptor >= 0)
        pane.ptySource = Ubiquitty::Linux::addPTYReadWatch(fileDescriptor, onPtyReadable, &pane);
    return true;
}

// The render settings that belong to the window rather than to a pane, applied
// together. Every entry point that renders reaches them — the GUI launch and the
// headless --snapshot both — and applied one call at a time, the snapshot can
// honour the background opacity and drop the link styling.
void applyWindowGlobalRenderSettings(const Ubiquitty::Preferences::Values& config)
{
    app().rasterContext.setRenderConfiguration(Ubiquitty::Preferences::Effective::renderConfiguration(config));
    // The background image is the file the configuration names, decoded by
    // Core when the path changes; the mode and opacity are read per frame.
    const std::string path = config.backgroundImage.value_or(std::string {});
    if (path == app().backgroundImagePath)
        return;
    app().backgroundImagePath = path;
    Ubiquitty::Rendering::BackgroundImagePixels pixels;
    if (!path.empty()) {
        if (const std::optional<std::string> bytes = readFeedFile(path.c_str()))
            pixels = Ubiquitty::Rendering::decodeBackgroundImage(std::span { reinterpret_cast<const std::uint8_t*>(bytes->data()), bytes->size() });
        if (pixels.isEmpty())
            g_warning("background image %s could not be read or decoded", path.c_str());
    }
    app().rasterContext.setBackgroundImage(std::move(pixels));
}

// Open the window's surface through the model: the root pane, its session and
// the launched shell arrive together; this side makes the view. The `-e`
// command is app policy — the first window runs it, and the model just takes
// whichever LaunchCommand this side resolves. setBackgroundOpacity is
// window-global — applied once here, not per pane.
bool launchShell()
{
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    // [appearance] background_opacity: <1 lets the desktop show through behind the
    // (opaque) text via the per-cell background alpha. Default 1.0 (opaque), like macOS.
    applyWindowGlobalRenderSettings(config);
    const bool shouldRunRequestedCommand = app().launchRequest != nullptr
        && app().launchRequest->status == Ubiquitty::Runtime::LaunchRequest::Status::Command
        && !app().didConsumeLaunchRequest;
    if (shouldRunRequestedCommand)
        app().didConsumeLaunchRequest = true;
    // A window with no command of its own opens a login session and is
    // recorded; one opened to run a named command is not a login and stays out
    // of the session table.
    const SurfaceID surface = app().model->addWindowSurface(shouldRunRequestedCommand
            ? Ubiquitty::Runtime::LaunchCommand::fromArguments(app().launchRequest->command)
            : Ubiquitty::Runtime::LaunchCommand::loginSession());
    if (surface == Layout::invalidSurface)
        return false;
    app().panes.push_back(std::make_unique<LinuxPane>());
    return bindPane(*app().panes.back(), app().model->focusedPane(surface));
}

// Tabs.

// Core composes the complete title; GTK elides its label to fit the strip.
std::string buildTabLabel(LinuxPane& pane, int index)
{
    const Ubiquitty::Preferences::Effective::TitleComposition composition = Ubiquitty::Preferences::Effective::tabTitleComposition(loadPreferences());
    std::string label = Ubiquitty::App::composeTitle(paneTitleFacts(pane, composition), titleViewerFacts("Tab " + std::to_string(index + 1)), composition, Ubiquitty::Session::TitleSurface::Tab).title;
    if (pane.hasUnheardBell) {
        label = "🔔 " + label;
    }
    return label;
}

void onTabButtonClicked(GtkToggleButton* button, gpointer)
{
    const TabID tab = static_cast<TabID>(GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "ubiquitty-tab-id")));
    switchToTab(tab);
}

void onNewTabClicked(GtkButton*, gpointer) { newTab(); }

// The model owns tab identity and selection. The label can elide on screen;
// the tooltip retains the complete title. Keep each surviving button alive:
// a title refresh can run while GTK is delivering focus to that button.
void rebuildTabStrip()
{
    if (!app().tabStrip)
        return;
    const SurfaceID surface = app().model->activeSurface();
    const int tabCount = app().model->tabCount(surface);
    for (GtkWidget* child = gtk_widget_get_first_child(app().tabStrip); child;) {
        GtkWidget* next = gtk_widget_get_next_sibling(child);
        const TabID tab = static_cast<TabID>(GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(child), "ubiquitty-tab-id")));
        bool isPresent = false;
        for (int i = 0; i < tabCount; ++i)
            isPresent |= app().model->tabAt(surface, i) == tab;
        if (!isPresent)
            gtk_box_remove(GTK_BOX(app().tabStrip), child);
        child = next;
    }
    if (tabCount <= 0)
        return;
    const TabID activeTab = app().model->activeTab(surface);
    GtkWidget* group = nullptr;
    GtkWidget* previous = nullptr;
    for (int i = 0; i < tabCount; ++i) {
        const TabID tab = app().model->tabAt(surface, i);
        const Panes::Tree* tree = app().model->paneTree(surface, tab);
        const PaneID paneID = tree != nullptr ? static_cast<PaneID>(tree->focusedPaneID()) : invalidPane;
        LinuxPane* pane = paneForID(paneID);
        const std::string label = pane != nullptr ? buildTabLabel(*pane, i) : ("Tab " + std::to_string(i + 1));
        GtkWidget* button = gtk_widget_get_first_child(app().tabStrip);
        while (button && static_cast<TabID>(GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "ubiquitty-tab-id"))) != tab)
            button = gtk_widget_get_next_sibling(button);
        if (!button) {
            button = gtk_toggle_button_new();
            gtk_widget_set_focus_on_click(button, FALSE);
            if (group)
                gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(button), GTK_TOGGLE_BUTTON(group));
            g_object_set_data(G_OBJECT(button), "ubiquitty-tab-id", GUINT_TO_POINTER(tab));
            // Programmatic selection emits toggled, not clicked.
            g_signal_connect(button, "clicked", G_CALLBACK(onTabButtonClicked), nullptr);
            gtk_box_append(GTK_BOX(app().tabStrip), button);
        }
        gtk_button_set_label(GTK_BUTTON(button), label.c_str());
        gtk_widget_set_tooltip_text(button, label.c_str());
        GtkWidget* text = gtk_button_get_child(GTK_BUTTON(button));
        gtk_label_set_ellipsize(GTK_LABEL(text), PANGO_ELLIPSIZE_MIDDLE);
        gtk_label_set_max_width_chars(GTK_LABEL(text), 28);
        if (!group)
            group = button;
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), tab == activeTab);
        gtk_box_reorder_child_after(GTK_BOX(app().tabStrip), button, previous);
        previous = button;
    }
}

// Make paneID's tab the active one: re-point activePane(), drop stale per-window
// chrome (IME preedit, find bar, pointer-gesture state), and force a title +
// frame repaint. app().columns/app().rows already track the window (onTick broadcasts resizes
// to every pane), so no per-pane grid re-sync is needed.
// Make `tab` the active one. The tab remembers which of its panes holds focus, so
// activating it is the whole focus change — naming a pane here instead would let a
// caller ask for a tab and a pane that disagree, and the model would have to pick.
void switchToTab(TabID tab)
{
    if (tab == invalidTab || !app().model->setActiveTab(app().model->activeSurface(), tab))
        return;
    LinuxPane* pane = activePane();
    if (!pane)
        return;
    if (app().window && gtk_window_is_active(GTK_WINDOW(app().window))) {
        pane->hasUnheardBell = false;
    }
    app().focusedPicture = pane->picture; // the focused-pane alias the render/hover/resize paths use
    // Mount this tab's pane tree in the container (one picture, or a GtkPaned tree if
    // the tab is split). The previous tab's pictures are unparented but kept alive by
    // their panes' refs, so switching back re-mounts them.
    rebuildPaneTree();
    if (app().imContext)
        gtk_im_context_reset(app().imContext); // drop a half-composed preedit
    hideSearchBar(); // the find bar was bound to the prior pane's Terminal
    app().heldPointerButton = Ubiquitty::Input::PointerButton::Other;
    app().hoverCursorShape = Ubiquitty::MousePointerShape::Default; // the new pane resolves its own
    app().lastTitle.clear(); // force the title to repaint for the new pane
    updateWindowTitle();
    // A tab switch moves the live input target: the grab a pane on the old
    // tab held is released, and one the new tab's pane asked for is taken.
    updatePointerLock();
    requestRepaint();
    renderGridFrame();
    rebuildTabStrip();
}

void switchTabRelative(int delta)
{
    const SurfaceID surface = app().model->activeSurface();
    const int tabCount = app().model->tabCount(surface);
    if (tabCount <= 1)
        return;
    const TabID active = app().model->activeTab(surface);
    int activeIndex = 0;
    for (int i = 0; i < tabCount; ++i)
        if (app().model->tabAt(surface, i) == active)
            activeIndex = i;
    int index = (activeIndex + delta) % tabCount;
    if (index < 0)
        index += tabCount;
    switchToTab(app().model->tabAt(surface, index));
}

// Open a new tab: a fresh Workspace tab (mints a PaneID, made active) + a launched
// LinuxPane mapped to it, sized to the current window, then switched to.
void newTab()
{
    const SurfaceID surface = app().model->activeSurface();
    const auto result = app().model->addTab(surface);
    if (result.outcome != Ubiquitty::Runtime::TerminalSession::PaneVerbOutcome::LocalActionRequired
        || result.createdPane == invalidPane)
        return; // at the per-surface tab cap, or the launch refused (the model rolled back)
    app().panes.push_back(std::make_unique<LinuxPane>());
    LinuxPane* pane = app().panes.back().get();
    if (!bindPane(*pane, result.createdPane)) {
        (void)app().model->closeTab(surface, app().model->activeTab(surface));
        app().panes.pop_back();
        rebuildTabStrip();
        return;
    }
    if (app().window)
        attachPaneControllers(*pane); // build its picture + controllers (GTK only)
    if (app().columns >= 1 && app().rows >= 1) {
        pane->columns = app().columns;
        pane->rows = app().rows;
        publishPanePixelGeometry(*pane);
    }
    switchToTab(app().model->activeTab(app().model->activeSurface()));
}

// Close pane's tab. The last tab closes the WINDOW (today's last-shell-exit
// behavior). Otherwise: remove the fd source, drop the Workspace tab (it reselects
// a neighbor), destroy the pane, and switch to the reselected neighbor if this was
// the focused pane. `pane` is dangling on return when a non-last tab closed.
void closePaneTab(LinuxPane* pane)
{
    if (!pane)
        return;
    // A pane that dies holding the grab must release it first: applyPointerLock's
    // release path reads pane->picture and pane->session below, neither of
    // which survives this function once the pane is torn down or the window
    // closes out from under it.
    if (pane == app().pointerLockPane)
        applyPointerLock(Ubiquitty::Input::PointerLockVerdict::Release);
    const SurfaceID surface = app().model->activeSurface();
    if (app().model->tabCount(surface) <= 1) {
        if (app().window)
            gtk_window_close(GTK_WINDOW(app().window));
        return;
    }
    const PaneID paneID = paneIDForPane(pane);
    const TabID tab = tabIDForPane(paneID);
    const bool wasActive = (pane == activePane());
    if (pane->ptySource != 0) {
        g_source_remove(pane->ptySource);
        pane->ptySource = 0;
    }
    if (pane->ptyWriteSource != 0) {
        g_source_remove(pane->ptyWriteSource);
        pane->ptyWriteSource = 0;
    }
    removeHeldFrameTimer(*pane);
    endPaneIngest(*pane);
    // Tear down the pane's picture before erasing the pane (its controllers close over
    // &pane): unparent it from the container, then drop the ref_sink ref so it's
    // destroyed. wasActive leaves the container empty for switchToTab to re-fill.
    if (pane->picture) {
        if (GtkWidget* parent = gtk_widget_get_parent(pane->picture); parent)
            gtk_box_remove(GTK_BOX(parent), pane->picture);
        g_object_unref(pane->picture);
        pane->picture = nullptr;
    }
    if (tab != invalidTab)
        (void)app().model->closeTab(surface, tab); // ends the tab's sessions; reselects a neighbor
    app().paneByID.erase(paneID);
    for (auto it = app().panes.begin(); it != app().panes.end(); ++it)
        if (it->get() == pane) {
            app().panes.erase(it); // destroys the runtime; `pane` is now dangling
            break;
        }
    if (wasActive) {
        switchToTab(app().model->activeTab(surface));
    } else {
        rebuildTabStrip();
    }
}

// Split panes.

// Detach a pane picture from its current parent (a GtkPaned slot or the container
// box) without destroying it — the pane keeps its ref so it survives across a tree
// rebuild. A no-op when unparented.
void unmountPicture(GtkWidget* picture)
{
    GtkWidget* parent = gtk_widget_get_parent(picture);
    if (!parent)
        return;
    if (GTK_IS_PANED(parent)) {
        if (gtk_paned_get_start_child(GTK_PANED(parent)) == picture)
            gtk_paned_set_start_child(GTK_PANED(parent), nullptr);
        else if (gtk_paned_get_end_child(GTK_PANED(parent)) == picture)
            gtk_paned_set_end_child(GTK_PANED(parent), nullptr);
    } else if (GTK_IS_BOX(parent)) {
        gtk_box_remove(GTK_BOX(parent), picture);
    }
}

void onDividerMoved(GObject* paned, GParamSpec*, gpointer)
{
    // Persist the user's divider drag into the model's ratio (first child's
    // fraction), so a rebuild (tab switch / further split) preserves it.
    const int nodeIndex = GPOINTER_TO_INT(g_object_get_data(paned, "ubiquitty-node"));
    GtkOrientation orientation = gtk_orientable_get_orientation(GTK_ORIENTABLE(paned));
    const int span = (orientation == GTK_ORIENTATION_HORIZONTAL) ? gtk_widget_get_width(GTK_WIDGET(paned)) : gtk_widget_get_height(GTK_WIDGET(paned));
    if (span <= 0)
        return;
    const int position = gtk_paned_get_position(GTK_PANED(paned));
    // GtkPaned overlays its divider rather than insetting it, so thickness 0
    // (the macOS NSSplitView path passes its dividerThickness).
    (void)app().model->setDividerRatio(app().model->activeSurface(), nodeIndex,
        Panes::ratioFromPosition(static_cast<float>(position), static_cast<float>(span), 0.0f));
}

// Build the GTK widget for a tree node: a leaf is its pane's GtkPicture; a split is
// a nested GtkPaned. AXIS INVERSION: Panes::Vertical = side-by-side columns = a GTK
// *horizontal* paned (vertical divider); Panes::Horizontal = stacked = GTK vertical.
GtkWidget* buildPaneWidget(const Panes::Tree& tree, int nodeIndex)
{
    if (tree.isLeaf(nodeIndex)) {
        LinuxPane* pane = paneForID(static_cast<PaneID>(tree.node(nodeIndex).paneID));
        return pane != nullptr ? pane->picture : nullptr;
    }
    const Panes::Node& node = tree.node(nodeIndex);
    const GtkOrientation orientation = (node.orientation == Panes::Orientation::Vertical) ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL;
    GtkWidget* paned = gtk_paned_new(orientation);
    gtk_paned_set_start_child(GTK_PANED(paned), buildPaneWidget(tree, node.first));
    gtk_paned_set_end_child(GTK_PANED(paned), buildPaneWidget(tree, node.second));
    gtk_paned_set_resize_start_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_resize_end_child(GTK_PANED(paned), TRUE);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
    gtk_widget_set_hexpand(paned, TRUE);
    gtk_widget_set_vexpand(paned, TRUE);
    g_object_set_data(G_OBJECT(paned), "ubiquitty-node", GINT_TO_POINTER(nodeIndex));
    g_signal_connect(paned, "notify::position", G_CALLBACK(onDividerMoved), nullptr);
    return paned;
}

// (Re)mount the active tab's split tree in the container. Destroying the old GtkPaned
// tree unparents the ref'd leaf pictures (they survive); buildPaneWidget re-parents
// them into the new tree. A one-leaf tree mounts the lone picture directly, with no
// paned wrapper. GTK-only.
void rebuildPaneTree()
{
    if (!app().paneContainer)
        return;
    const Panes::Tree* tree = app().model->paneTree(app().model->activeSurface());
    if (!tree)
        return;
    // Detach the live pictures before tearing down the old tree, so the old GtkPaned
    // disposal can't take them (belt-and-braces alongside their ref).
    for (auto& pane : app().panes)
        if (pane->picture)
            unmountPicture(pane->picture);
    if (GtkWidget* old = gtk_widget_get_first_child(app().paneContainer); old)
        gtk_box_remove(GTK_BOX(app().paneContainer), old);
    if (GtkWidget* root = buildPaneWidget(*tree, tree->root()); root)
        gtk_box_append(GTK_BOX(app().paneContainer), root);
}

// Split the focused pane: a fresh Workspace leaf (mints a PaneID, made focused) + a
// launched LinuxPane mapped to it, then re-mount the tree. orientation is the
// Panes:: axis (Vertical = side-by-side).
void splitFocusedPaneUX(Panes::Orientation orientation)
{
    const SurfaceID surface = app().model->activeSurface();
    const auto result = app().model->splitFocusedPane(surface, orientation);
    if (result.outcome != Ubiquitty::Runtime::TerminalSession::PaneVerbOutcome::LocalActionRequired
        || result.createdPane == invalidPane)
        return; // at the per-tab pane cap, or the launch refused (the model rolled back)
    app().panes.push_back(std::make_unique<LinuxPane>());
    LinuxPane* pane = app().panes.back().get();
    if (!bindPane(*pane, result.createdPane)) {
        (void)app().model->closePane(surface, result.createdPane);
        app().panes.pop_back();
        rebuildPaneTree();
        return;
    }
    if (app().window)
        attachPaneControllers(*pane);
    // Provisional size; onTick reconciles each pane to its real sub-rectangle once
    // GtkPaned has allocated, SIGWINCHing the shell to the true split size.
    if (app().columns >= 1 && app().rows >= 1) {
        pane->columns = app().columns;
        pane->rows = app().rows;
        publishPanePixelGeometry(*pane);
    }
    app().focusedPicture = pane->picture;
    rebuildPaneTree();
    requestRepaint();
}

// Close the focused pane. A multi-pane tab collapses one split level (focus moves to
// a neighbor leaf); the tab's last pane escalates to closePaneTab (close the tab, or
// the window on the last tab).
void closeFocusedPaneUX()
{
    const SurfaceID surface = app().model->activeSurface();
    const Panes::Tree* tree = app().model->paneTree(surface);
    if (!tree || tree->paneCount() <= 1) {
        closePaneTab(activePane());
        return;
    }
    LinuxPane* closing = activePane();
    const PaneID closingID = paneIDForPane(closing);
    // A pane that dies holding the grab releases it first: the release path
    // reads the pane's picture and session, neither of which survives this
    // function, and a grab nobody holds would leave the cursor hidden and
    // warped with no way out.
    if (closing == app().pointerLockPane)
        applyPointerLock(Ubiquitty::Input::PointerLockVerdict::Release);
    // The fd watch goes first: the model's close ends the session and with
    // it the descriptor, and a watch on a dead fd fires once more into a
    // pane this function is about to destroy.
    if (closing->ptySource != 0) {
        g_source_remove(closing->ptySource);
        closing->ptySource = 0;
    }
    removeHeldFrameTimer(*closing);
    (void)app().model->closePane(surface, closingID); // collapses; ends the session; focus moves
    if (closing->picture) {
        unmountPicture(closing->picture);
        g_object_unref(closing->picture);
        closing->picture = nullptr;
    }
    app().paneByID.erase(closingID);
    for (auto it = app().panes.begin(); it != app().panes.end(); ++it)
        if (it->get() == closing) {
            app().panes.erase(it); // `closing` dangles after this
            break;
        }
    const LinuxPane* focused = activePane();
    app().focusedPicture = focused != nullptr ? focused->picture : nullptr;
    rebuildPaneTree();
    // The pane that inherited focus may be the one whose program asked for
    // the grab the closed pane could not take.
    updatePointerLock();
    requestRepaint();
}

void moveFocusUX(Panes::Direction direction)
{
    const SurfaceID surface = app().model->activeSurface();
    if (!app().model->moveFocus(surface, direction))
        return;
    if (const LinuxPane* pane = paneForID(app().model->focusedPane(surface)); pane) {
        app().focusedPicture = pane->picture;
        // The grab follows the live input target: a pane the focus left
        // releases it, and a pane the focus reached takes it if its program
        // asked, without that program re-sending the mode.
        updatePointerLock();
        requestRepaint();
    }
}

// Update UI (AppImage self-update).

void showUpdateResult(Ubiquitty::Linux::Updater::Status status);

void onUpdateApplyExited(GPid processID, gint status, gpointer)
{
    g_spawn_close_pid(processID);
    showUpdateResult(Ubiquitty::Linux::Updater::statusForApplyExit(status));
}

void onUpdateNowChosen(GObject* source, GAsyncResult* result, gpointer)
{
    // Buttons: { "Later"=0, "Update Now"=1 }.
    const int index = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, nullptr);
    if (index != 1)
        return;
    // Watched, not fired and forgotten. The tool writes over the file this
    // process is running from, so a refusal or a failed download leaves the old
    // version in place and looks exactly like a success from here.
    std::vector<std::string> command;
    const Ubiquitty::Linux::Updater::Status plan = Ubiquitty::Linux::Updater::planUpdate(command);
    if (plan != Ubiquitty::Linux::Updater::Status::UpdateAvailable) {
        showUpdateResult(plan);
        return;
    }
    const int processID = Ubiquitty::Linux::spawnDetachedForWatch(command);
    if (processID < 0) {
        showUpdateResult(Ubiquitty::Linux::Updater::Status::UpdateFailed);
        return;
    }
    g_child_watch_add(processID, onUpdateApplyExited, nullptr);
}

// The dialog's heading for an update outcome; the updater's sentence is its
// detail, so the heading stays short and in header capitalization.
const char* updateResultHeading(Ubiquitty::Linux::Updater::Status status)
{
    using S = Ubiquitty::Linux::Updater::Status;
    switch (status) {
    case S::NotAnAppImage:
        return "Updates Unavailable";
    case S::ToolMissing:
        return "Updater Not Found";
    case S::UpToDate:
        return "No Updates Available";
    case S::UpdateAvailable:
        return "Update Available";
    case S::UpdateApplied:
        return "Update Installed";
    case S::UpdateFailed:
        return "Update Failed";
    case S::Error:
        return "Unable to Check for Updates";
    }
    return "Software Update";
}

void showUpdateResult(Ubiquitty::Linux::Updater::Status status)
{
    using S = Ubiquitty::Linux::Updater::Status;
    GtkWindow* parent = (app().window != nullptr) ? GTK_WINDOW(app().window) : nullptr;
    GtkAlertDialog* dialog = gtk_alert_dialog_new("%s", updateResultHeading(status));
    gtk_alert_dialog_set_detail(dialog, Ubiquitty::Linux::Updater::statusString(status));
    if (status == S::UpdateAvailable) {
        const char* buttons[] = { "Later", "Update Now", nullptr };
        gtk_alert_dialog_set_buttons(dialog, buttons);
        gtk_alert_dialog_set_default_button(dialog, 1);
        gtk_alert_dialog_set_cancel_button(dialog, 0);
        gtk_alert_dialog_choose(dialog, parent, nullptr, onUpdateNowChosen, nullptr);
    } else {
        gtk_alert_dialog_show(dialog, parent);
    }
    g_object_unref(dialog);
}

void onUpdateCheckExited(GPid processID, gint status, gpointer)
{
    g_spawn_close_pid(processID);
    // appimageupdatetool --check-for-update: exit 0 = up to date, 1 = update
    // available, anything else = error — the same reading the blocking check
    // applies.
    Ubiquitty::Linux::Updater::Status result = Ubiquitty::Linux::Updater::Status::Error;
    if (WIFEXITED(status)) {
        const int code = WEXITSTATUS(status);
        if (code == 0)
            result = Ubiquitty::Linux::Updater::Status::UpToDate;
        else if (code == 1)
            result = Ubiquitty::Linux::Updater::Status::UpdateAvailable;
    }
    showUpdateResult(result);
}

void onCheckUpdateAction(GSimpleAction*, GVariant*, gpointer)
{
    // The zsync-metadata fetch runs for as long as the network takes, so it
    // cannot run on the loop that paints every pane. Spawn it and let the
    // child watch deliver the verdict back here.
    std::vector<std::string> command;
    const Ubiquitty::Linux::Updater::Status plan = Ubiquitty::Linux::Updater::planCheck(command);
    if (plan != Ubiquitty::Linux::Updater::Status::UpdateAvailable) {
        showUpdateResult(plan);
        return;
    }
    const int processID = Ubiquitty::Linux::spawnForWatch(command);
    if (processID < 0) {
        showUpdateResult(Ubiquitty::Linux::Updater::Status::Error);
        return;
    }
    g_child_watch_add(processID, onUpdateCheckExited, nullptr);
}

void onAboutAction(GSimpleAction*, GVariant*, gpointer)
{
    gtk_show_about_dialog(app().window ? GTK_WINDOW(app().window) : nullptr,
        "program-name", "Ubiquitty",
        "version", Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str(),
        "comments", "A terminal emulator and persistent multiplexer",
        "website", "https://ubiquitty.org",
        "website-label", "ubiquitty.org",
        "copyright", "Copyright © 2026 Stanislav Yaglo",
        "license-type", GTK_LICENSE_APACHE_2_0,
        "logo-icon-name", "org.ubiquitty.linux",
        "modal", TRUE,
        nullptr);
}

void onSecondaryPress(GtkGestureClick* gesture, gint, gdouble, gdouble, gpointer)
{
    if (!app().menuButton)
        return;
    gtk_menu_button_popup(GTK_MENU_BUTTON(app().menuButton));
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

// The visible menu button and the context menu share the application's actions.
void installUpdateMenu(GtkApplication* gtkApplication)
{
    static const GActionEntry entries[] = {
        { "new-tab", +[](GSimpleAction*, GVariant*, gpointer) { newTab(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "close-pane", +[](GSimpleAction*, GVariant*, gpointer) { closeFocusedPaneUX(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "find", +[](GSimpleAction*, GVariant*, gpointer) { showSearchBar(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "check-update", onCheckUpdateAction, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "about", onAboutAction, nullptr, nullptr, nullptr, { 0, 0, 0 } },
    };
    g_action_map_add_action_entries(G_ACTION_MAP(gtkApplication), entries, G_N_ELEMENTS(entries), nullptr);
    GMenu* menu = g_menu_new();
    GMenu* session = g_menu_new();
    g_menu_append(session, "New Tab", "app.new-tab");
    g_menu_append(session, "Close Pane", "app.close-pane");
    g_menu_append(session, "Find…", "app.find");
    g_menu_append_section(menu, nullptr, G_MENU_MODEL(session));
    g_object_unref(session);
    GMenu* application = g_menu_new();
    g_menu_append(application, "Check for Updates…", "app.check-update");
    g_menu_append(application, "About Ubiquitty", "app.about");
    g_menu_append_section(menu, nullptr, G_MENU_MODEL(application));
    g_object_unref(application);
    if (app().menuButton) {
        gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(app().menuButton), G_MENU_MODEL(menu));
        g_signal_connect(gtk_menu_button_get_popover(GTK_MENU_BUTTON(app().menuButton)), "closed",
            G_CALLBACK(+[](GtkPopover*, gpointer) {
                GtkWidget* target = app().searchBar && gtk_search_bar_get_search_mode(GTK_SEARCH_BAR(app().searchBar))
                    ? app().searchEntry
                    : app().focusedPicture;
                if (target)
                    gtk_widget_grab_focus(target);
            }),
            nullptr);
    }
    g_object_unref(menu);

    GtkGesture* click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_SECONDARY);
    g_signal_connect(click, "pressed", G_CALLBACK(onSecondaryPress), nullptr);
    gtk_widget_add_controller(app().window, GTK_EVENT_CONTROLLER(click));
}

// OSC 52 clipboard read (the program asks to READ the clipboard).
//
// requestClipboardReadFromGTK is installed as the LinuxClipboardClient's read
// handler. It runs entirely on the GTK main thread (single-threaded frontend):
// under Prompt it asks the user, under Allow it auto-approves; on approve it
// async-reads the clipboard, stages the bytes on the client, and completes the
// Core query (which base64-encodes + frames the OSC 52 reply); on deny it
// completes with approved=false (Core replies with empty data).

// One pending OSC 52 read: carries the selection-set across the async dialog +
// clipboard-read hops. Heap-allocated; freed when the read completes or is denied.
//
// At most one of these exists per Terminal, because Core hands out one read query
// at a time and answers the rest empty (Terminal::isOSC52ClipboardReadInFlight).
// Without that ceiling, a program printing the query in a loop allocates one of
// these and stacks one dialog per repeat, faster than anyone can dismiss them.
struct PendingClipboardRead {
    Ubiquitty::Linux::LinuxClipboardClient* client;
    Ubiquitty::ClipboardBuffer buffer;
    char setSpec[16];
    int setLength;
    Ubiquitty::ClipboardReadConfirmation confirmation;
    // The pane that issued the OSC 52 read (captured at request time, on the
    // parser's thread). The reply must complete on its session — focus may
    // have moved before the async read/dialog finished — and a pane closed
    // meanwhile reads as null, so the reply is dropped.
    Ubiquitty::WeakPtr<LinuxPane> requester;
    // Captures at most 256 formats and maxExtendedClipboardReadBytes in total.
    std::string textCaptured;
    bool hasTextCaptured = false;
    std::vector<Ubiquitty::Linux::Clipboard::RecordedItem> itemsCaptured;
    std::vector<std::string> typesToCapture;
    std::size_t nextType = 0;
    std::size_t capturedBytes = 0;
    GdkClipboard* sourceClipboard = nullptr;
    GInputStream* itemStream = nullptr;
    std::string itemBytes;
    std::array<char, 32768> readChunk {};
};

// Route an OSC 52 read completion to the pane that issued it, if it is still alive.
// A closed requester drops the reply (the dangling-pane guard).
void completePendingClipboardRead(PendingClipboardRead* pending, bool approved)
{
    // Resolved through the session rather than completed on the Terminal:
    // the decision rides the command ring and applies on the thread that
    // owns the model, inline when this thread is it.
    if (LinuxPane* requester = pending->requester.get(); requester && requester->session)
        requester->session->resolveClipboardRead({ pending->setSpec, static_cast<std::size_t>(pending->setLength) },
            approved ? Ubiquitty::OSC::ClipboardReadDecision::Approved : Ubiquitty::OSC::ClipboardReadDecision::Refused);
}

// Stage an approved internal-buffer read + complete the query (defined below).
void approveInternalBufferRead(PendingClipboardRead* pending);

// Publishes the complete capture before resolving the pending read.
void stageCapturedClipboardAndComplete(PendingClipboardRead* pending)
{
    pending->client->provideClipboardReadBytes(pending->buffer,
        std::span<const char>(pending->textCaptured.data(), pending->textCaptured.size()));
    std::vector<Ubiquitty::ClipboardItem> items;
    if (pending->hasTextCaptured)
        items.push_back({ "text/plain", { pending->textCaptured.data(), pending->textCaptured.size() } });
    for (const auto& item : pending->itemsCaptured)
        items.push_back({ item.mime, { item.bytes.data(), item.bytes.size() } });
    pending->client->provideClipboardReadItems(pending->buffer, items);
    completePendingClipboardRead(pending, /*approved=*/true);
    if (pending->sourceClipboard)
        g_object_unref(pending->sourceClipboard);
    delete pending;
}

void captureNextClipboardItem(PendingClipboardRead* pending);

void onClipboardItemChunk(GObject* source, GAsyncResult* result, gpointer userData)
{
    auto* pending = static_cast<PendingClipboardRead*>(userData);
    const gssize count = g_input_stream_read_finish(G_INPUT_STREAM(source), result, nullptr);
    const std::size_t limit = Ubiquitty::VT::maxExtendedClipboardReadBytes;
    if (count > 0 && pending->capturedBytes + pending->itemBytes.size() + static_cast<std::size_t>(count) <= limit) {
        pending->itemBytes.append(pending->readChunk.data(), static_cast<std::size_t>(count));
        g_input_stream_read_async(pending->itemStream, pending->readChunk.data(), pending->readChunk.size(),
            G_PRIORITY_DEFAULT, nullptr, onClipboardItemChunk, pending);
        return;
    }
    if (count == 0) {
        pending->capturedBytes += pending->itemBytes.size();
        pending->itemsCaptured.push_back({ pending->typesToCapture[pending->nextType - 1], std::move(pending->itemBytes) });
    }
    g_input_stream_close(pending->itemStream, nullptr, nullptr);
    g_clear_object(&pending->itemStream);
    captureNextClipboardItem(pending);
}

void onClipboardItemOpened(GObject* source, GAsyncResult* result, gpointer userData)
{
    auto* pending = static_cast<PendingClipboardRead*>(userData);
    const char* mime = nullptr;
    pending->itemStream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, &mime, nullptr);
    if (!pending->itemStream) {
        captureNextClipboardItem(pending);
        return;
    }
    g_input_stream_read_async(pending->itemStream, pending->readChunk.data(), pending->readChunk.size(),
        G_PRIORITY_DEFAULT, nullptr, onClipboardItemChunk, pending);
}

void captureNextClipboardItem(PendingClipboardRead* pending)
{
    if (pending->nextType >= pending->typesToCapture.size()
        || pending->capturedBytes >= Ubiquitty::VT::maxExtendedClipboardReadBytes) {
        stageCapturedClipboardAndComplete(pending);
        return;
    }
    pending->itemBytes.clear();
    const char* types[] = { pending->typesToCapture[pending->nextType++].c_str(), nullptr };
    gdk_clipboard_read_async(pending->sourceClipboard, types, G_PRIORITY_DEFAULT, nullptr, onClipboardItemOpened, pending);
}

void onClipboardReadForOSC52(GObject* source, GAsyncResult* result, gpointer userData)
{
    auto* pending = static_cast<PendingClipboardRead*>(userData);
    char* text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, nullptr);
    if (text) {
        const std::size_t length = std::strlen(text);
        if (length <= Ubiquitty::VT::maxExtendedClipboardReadBytes) {
            pending->textCaptured.assign(text, length);
            pending->hasTextCaptured = true;
        }
        g_free(text);
    }
    pending->capturedBytes = pending->textCaptured.size();
    pending->sourceClipboard = GDK_CLIPBOARD(g_object_ref(source));
    gsize count = 0;
    const char* const* types = gdk_content_formats_get_mime_types(gdk_clipboard_get_formats(pending->sourceClipboard), &count);
    for (gsize index = 0; index < count && pending->typesToCapture.size() < 256; ++index) {
        const std::string_view type(types[index]);
        if (type.find('/') != std::string_view::npos && !Ubiquitty::mimeIsTextPlain(type))
            pending->typesToCapture.emplace_back(type);
    }
    captureNextClipboardItem(pending);
}

// The user answered the read-confirmation dialog. index: { "Deny"=0, "Allow"=1 }.
void onClipboardReadChosen(GObject* source, GAsyncResult* result, gpointer userData)
{
    auto* pending = static_cast<PendingClipboardRead*>(userData);
    const int index = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, nullptr);
    if (index == 1 && app().window) {
        if (pending->buffer == Ubiquitty::ClipboardBuffer::Clipboard || pending->buffer == Ubiquitty::ClipboardBuffer::Primary)
            gdk_clipboard_read_text_async(pending->buffer == Ubiquitty::ClipboardBuffer::Primary
                    ? gtk_widget_get_primary_clipboard(app().window)
                    : gtk_widget_get_clipboard(app().window),
                nullptr, onClipboardReadForOSC52, pending);
        else
            approveInternalBufferRead(pending);
        return; // pending freed in the read-completion path
    }
    completePendingClipboardRead(pending, /*approved=*/false);
    delete pending;
}

// Approve a read of an gtkApplication-internal (non-Clipboard) buffer: stage its current
// bytes and complete the query. The same read policy gate applies (Core only
// calls here for Allow/Prompt; Prompt asks first).
void approveInternalBufferRead(PendingClipboardRead* pending)
{
    const std::string bytes = pending->client->internalBuffer(pending->buffer);
    pending->client->provideClipboardReadBytes(pending->buffer, std::span<const char>(bytes.data(), bytes.size()));
    // No typed staging call: the client scopes its typed serves to the
    // system clipboard, so an internal buffer's read never consults it.
    completePendingClipboardRead(pending, /*approved=*/true);
    delete pending;
}

// The GTK side of an OSC 52 read, on the UI thread: the system clipboard is
// read asynchronously, an internal buffer is staged at once, and a read that
// needs consent asks first. Owns `pending` until a completion frees it.
void beginClipboardRead(PendingClipboardRead* pending)
{
    if (!app().window) {
        // The window went away between the parser's ask and this post; the
        // query still owes Core an answer, or the next read waits forever.
        completePendingClipboardRead(pending, false);
        delete pending;
        return;
    }
    const bool isSystemClipboard = pending->buffer == Ubiquitty::ClipboardBuffer::Clipboard || pending->buffer == Ubiquitty::ClipboardBuffer::Primary;
    if (pending->confirmation == Ubiquitty::ClipboardReadConfirmation::NotRequired) {
        if (isSystemClipboard)
            gdk_clipboard_read_text_async(pending->buffer == Ubiquitty::ClipboardBuffer::Primary
                    ? gtk_widget_get_primary_clipboard(app().window)
                    : gtk_widget_get_clipboard(app().window),
                nullptr, onClipboardReadForOSC52, pending);
        else
            approveInternalBufferRead(pending);
        return;
    }
    GtkAlertDialog* dialog = gtk_alert_dialog_new("Allow Clipboard Access?");
    gtk_alert_dialog_set_detail(dialog, "A program in the terminal wants to read the clipboard.");
    const char* buttons[] = { "Deny", "Allow", nullptr };
    gtk_alert_dialog_set_buttons(dialog, buttons);
    gtk_alert_dialog_set_default_button(dialog, 0);
    gtk_alert_dialog_set_cancel_button(dialog, 0);
    gtk_alert_dialog_choose(dialog, GTK_WINDOW(app().window), nullptr, onClipboardReadChosen, pending);
    g_object_unref(dialog);
}

gboolean onClipboardReadDue(gpointer data)
{
    beginClipboardRead(static_cast<PendingClipboardRead*>(data));
    return G_SOURCE_REMOVE;
}

// The parser's ask, on its own thread: the request is recorded with a weak
// reference to the asking pane and carried to the UI thread, where GTK may
// be called. Inline when this is that thread — the headless entries — where
// a run without a window declines so Core drops the query cleanly.
bool requestClipboardReadFromGTK(Ubiquitty::Linux::LinuxClipboardClient* client, void* requester, Ubiquitty::ClipboardBuffer buffer, std::string_view setSpec, Ubiquitty::ClipboardReadConfirmation confirmation)
{
    auto* pane = static_cast<LinuxPane*>(requester);
    if (!pane)
        return false;
    if (client->isOnUIThread() && !app().window)
        return false; // no window (headless) — Core drops the query cleanly
    auto* pending = new PendingClipboardRead();
    pending->client = client;
    pending->buffer = buffer;
    pending->confirmation = confirmation;
    pending->requester = pane->weakPtr();
    const std::size_t specLength = std::min<std::size_t>(setSpec.size(), 15);
    if (specLength > 0)
        std::memcpy(pending->setSpec, setSpec.data(), specLength);
    pending->setSpec[specLength] = 0;
    pending->setLength = static_cast<int>(specLength);
    if (client->isOnUIThread())
        beginClipboardRead(pending);
    else
        g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, onClipboardReadDue, pending, nullptr);
    return true;
}

void onActivate(GtkApplication* gtkApplication, gpointer)
{
    app().application = gtkApplication; // for g_application_send_notification (the unfocused-bell notify)
    app().fontDPI = displayFontDPI();
    readToolkitCaretSettings();
    if (!app().configurationWatcher.start()) {
        g_printerr("ubiquitty-linux: unable to watch config.toml for changes\n");
    }
    // Configuration FIRST: Core is configured from the stored document
    // (~/.config/ubiquitty/config.toml) here, so setupFonts (family/size),
    // launchShell (scrollback, cursor blink) and the clipboard gate below all
    // read the same resolved values.
    (void)Ubiquitty::Preferences::configureFromStoredDocument(Ubiquitty::Preferences::ParseMode::Permissive);
    applyProcessConfiguration(loadPreferences());
    app().appliedRenderConfiguration = Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences());
    // Adopt any user [[themes]] from config into the theme registry (built-ins
    // first, then customs) so the launch seed can resolve a theme by name —
    // built-in ("Rose Pine") or user-defined alike.
    Ubiquitty::Themes::registerThemesFromValues(loadPreferences());
    // Seed the [keys] binding table from the resolved config so a custom keymap,
    // leader/chord prefix, and the named action vocabulary take effect (parity
    // with the macOS rebuildKeyBindings). Runs before the key controller is
    // connected below.
    rebuildKeyBindings();
    // Font setup FIRST (before launchShell sizes the PTY window): the chosen
    // rasterizer (FreeType, or Unifont when forced/unavailable) is injected into
    // both the CPU path (by setupFonts) and the GPU atlas (the same instance —
    // keeps them byte-identical). This also sets the font-derived runtime cell the
    // grid + window are sized at; the menu can swap it live (applyFontMode).
    setupFonts();
    app().vulkan.setGlyphRasterizer(currentRasterizer());
    app().vulkan.setLigatureRasterizer(currentRasterizer());
    if (!launchShell()) {
        g_printerr("ubiquitty-linux: failed to launch shell\n");
        return;
    }
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    // Open on the theme Core says a launch opens on: the configured one when
    // there is one, the house default when there is not. The launch seed only
    // ever applied a configured theme, so a config with no [appearance] theme
    // left this window on the palette a fresh Terminal is constructed with — a
    // screen the macOS window never shows for the same config, and one nobody
    // chose.
    //
    // The pane just launched, not every pane: this is the launch rung of the
    // theme ladder, and a pane whose session carries a theme of its own — a
    // remote attach that themes itself the way a tmux session does — owns its
    // palette. A blanket re-apply here would take it back.
    {
        const int launchTheme = Ubiquitty::Runtime::launchThemeIndex(config);
        if (launchTheme >= 0) {
            app().liveThemeIndex = launchTheme;
            if (Ubiquitty::Terminal* term = activePane()->session->terminal()) {
                const auto hold = holdPaneModel(*activePane());
                (void)Ubiquitty::Themes::applyThemeToTerminal(*term, launchTheme);
            }
        }
    }
    Ubiquitty::Linux::Clipboard::setReadRequestHandler(requestClipboardReadFromGTK);
    app().isVulkanReady = app().vulkan.init();
    if (!app().isVulkanReady)
        g_printerr("ubiquitty-linux: Vulkan init failed — falling back to the CPU renderer\n");
    app().window = gtk_application_window_new(gtkApplication);
    gtk_window_set_title(GTK_WINDOW(app().window), "Ubiquitty (Linux)");
    // Initial geometry is pinned to exactly startupColumns x startupRows below by requesting
    // the focused pane picture's natural size — sizing the *window* here can't
    // account for the CSD titlebar or the padding margins, which is what made the
    // grid open smaller than 80x24.
    // The active tab's pane(s) live in app().paneContainer: today one pane fills it (a
    // single GtkPicture); split panes mount a GtkPaned tree of per-pane pictures
    // here. Each pane owns its picture + its own controllers (attachPaneControllers);
    // the picture stretches cell-quantized content to fill (CONTAIN would letterbox).
    attachPaneControllers(*activePane());
    app().focusedPicture = activePane()->picture; // the focused-pane alias
    app().paneContainer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(app().paneContainer, TRUE);
    gtk_widget_set_vexpand(app().paneContainer, TRUE);
    gtk_box_append(GTK_BOX(app().paneContainer), activePane()->picture);

    // Open at exactly the launch grid: pin the focused pane picture's natural
    // size to it so the window sizes itself around it (grid + padding
    // margins + CSD titlebar). The pin is relaxed on first map so the user can
    // still resize the window smaller afterward.
    gtk_widget_set_size_request(activePane()->picture,
        static_cast<int>(activePane()->columns * logicalCellWidth() + 0.5f),
        static_cast<int>(activePane()->rows * logicalCellHeight() + 0.5f));
    g_signal_connect(app().window, "map", G_CALLBACK(onWindowMappedRelaxSize), activePane()->picture);
    g_signal_connect(app().window, "unmap", G_CALLBACK(onWindowUnmapped), nullptr);
    g_signal_connect(app().window, "realize", G_CALLBACK(onWindowRealized), nullptr);
    // HiDPI: re-rasterize at the device cell when the window lands on (or moves to)
    // a scaled monitor — the initial map on a HiDPI display fires this 1 -> N.
    g_signal_connect(app().window, "notify::scale-factor", G_CALLBACK(onScaleFactorChanged), nullptr);
    if (GtkSettings* settings = gtk_widget_get_settings(app().window)) {
        g_signal_connect_object(settings, "notify::gtk-xft-dpi", G_CALLBACK(onScaleFactorChanged), app().window, G_CONNECT_DEFAULT);
        g_signal_connect_object(settings, "notify::gtk-fontconfig-timestamp", G_CALLBACK(+[](GObject*, GParamSpec*, gpointer) {
            for (const auto& pane : app().panes) {
                pane->richText.invalidateFonts();
                publishPaneTypography(*pane);
            }
            requestRepaint(); }), app().window, G_CONNECT_DEFAULT);
        // The caret's settings all share GtkSettings' gtk-cursor- prefix.
        g_signal_connect_object(settings, "notify", G_CALLBACK(+[](GObject*, GParamSpec* property, gpointer) {
            if (!std::string_view(g_param_spec_get_name(property)).starts_with("gtk-cursor-"))
                return;
            readToolkitCaretSettings();
            requestRepaint(); }), app().window, G_CONNECT_DEFAULT);
    }

    // The find bar sits above the terminal in a vertical box; GtkSearchBar reveals
    // it (Ctrl+Shift+F) and hides on Esc. The entry drives the Core search; the
    // label shows the match counter. Connect before the box so the handlers exist.
    app().searchBar = gtk_search_bar_new();
    app().searchEntry = gtk_search_entry_new();
    app().searchLabel = gtk_label_new("");
    GtkWidget* searchRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_hexpand(app().searchEntry, TRUE);
    gtk_box_append(GTK_BOX(searchRow), app().searchEntry);
    gtk_box_append(GTK_BOX(searchRow), app().searchLabel);
    gtk_search_bar_set_child(GTK_SEARCH_BAR(app().searchBar), searchRow);
    gtk_search_bar_connect_entry(GTK_SEARCH_BAR(app().searchBar), GTK_EDITABLE(app().searchEntry));
    g_signal_connect(app().searchEntry, "search-changed", G_CALLBACK(onSearchChanged), nullptr);
    g_signal_connect(app().searchEntry, "activate", G_CALLBACK(onSearchActivate), nullptr);
    g_signal_connect(app().searchEntry, "next-match", G_CALLBACK(onSearchNext), nullptr);
    g_signal_connect(app().searchEntry, "previous-match", G_CALLBACK(onSearchPrevious), nullptr);
    g_signal_connect(app().searchEntry, "stop-search", G_CALLBACK(onSearchStop), nullptr);

    app().tabStrip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget* tabScroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tabScroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tabScroll), app().tabStrip);
    gtk_widget_set_hexpand(tabScroll, TRUE);
    GtkWidget* tabBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(tabBar, "ubiquitty-tabs");
    gtk_box_append(GTK_BOX(tabBar), tabScroll);
    GtkWidget* plus = gtk_button_new_from_icon_name("list-add-symbolic");
    gtk_widget_set_tooltip_text(plus, "New Tab (Ctrl+Shift+T)");
    gtk_accessible_update_property(GTK_ACCESSIBLE(plus), GTK_ACCESSIBLE_PROPERTY_LABEL, "New Tab", -1);
    gtk_widget_set_focus_on_click(plus, FALSE);
    g_signal_connect(plus, "clicked", G_CALLBACK(onNewTabClicked), nullptr);
    gtk_box_append(GTK_BOX(tabBar), plus);
    app().menuButton = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(app().menuButton), "open-menu-symbolic");
    gtk_widget_set_tooltip_text(app().menuButton, "Menu");
    gtk_accessible_update_property(GTK_ACCESSIBLE(app().menuButton), GTK_ACCESSIBLE_PROPERTY_LABEL, "Menu", -1);
    gtk_box_append(GTK_BOX(tabBar), app().menuButton);
    rebuildTabStrip();
    GtkWidget* layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(layout), app().searchBar);
    gtk_box_append(GTK_BOX(layout), tabBar);
    // The pane area sits under a GtkOverlay so the OSC 9;4 progress bars draw
    // above the grid texture without disturbing the per-pane picture mounting
    // (the macOS per-pane bars are likewise overlaid siblings). One full-area
    // can't-target drawing area paints a thin bar at every visible pane's top
    // edge (input passes through to the grid); hidden until a pane reports
    // progress (updateProgressBar).
    GtkWidget* paneOverlay = gtk_overlay_new();
    gtk_widget_set_hexpand(paneOverlay, TRUE);
    gtk_widget_set_vexpand(paneOverlay, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(paneOverlay), app().paneContainer);
    app().accessibleTerminal = Ubiquitty::Linux::Accessibility::createTerminal();
    gtk_widget_set_can_target(app().accessibleTerminal, FALSE);
    gtk_widget_set_halign(app().accessibleTerminal, GTK_ALIGN_FILL);
    gtk_widget_set_valign(app().accessibleTerminal, GTK_ALIGN_FILL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(app().accessibleTerminal), GTK_ACCESSIBLE_PROPERTY_LABEL, "Terminal", -1);
    gtk_overlay_add_overlay(GTK_OVERLAY(paneOverlay), app().accessibleTerminal);
    gtk_overlay_set_measure_overlay(GTK_OVERLAY(paneOverlay), app().accessibleTerminal, FALSE);
    publishAccessibleTerminal();
    app().progressBar = gtk_drawing_area_new();
    // Fills the whole pane area: the draw func paints a thin bar at each pane's
    // top edge (per-pane bars), so it can't be a pinned top strip.
    gtk_widget_set_halign(app().progressBar, GTK_ALIGN_FILL);
    gtk_widget_set_valign(app().progressBar, GTK_ALIGN_FILL);
    gtk_widget_set_can_target(app().progressBar, FALSE); // clicks/scroll reach the grid
    gtk_widget_set_visible(app().progressBar, FALSE); // shown only with live progress
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(app().progressBar), drawProgressBar, nullptr, nullptr);
    gtk_overlay_add_overlay(GTK_OVERLAY(paneOverlay), app().progressBar);
    gtk_overlay_set_measure_overlay(GTK_OVERLAY(paneOverlay), app().progressBar, FALSE);
    gtk_box_append(GTK_BOX(layout), paneOverlay);
    // Under the panes, hidden until the configuration has a line to show; the
    // startup configure above has already left one if the file holds an error.
    gtk_box_append(GTK_BOX(layout), makeConfigurationBar());
    gtk_window_set_child(GTK_WINDOW(app().window), layout);

    // Window transparency for background_opacity < 1: the rendered texture already
    // carries the background alpha, so the window + its widgets just need a transparent
    // background-color for the compositor to blend the desktop through. Best-effort
    // — the see-through depends on a compositing WM (Wayland / X11 compositor).
    if (app().rasterContext.backgroundOpacity() < 1.0f) {
        GtkCssProvider* provider = gtk_css_provider_new();
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations" // load_from_data: 4.12 wants load_from_string
        gtk_css_provider_load_from_data(provider, "window.ubiquitty-translucent, window.ubiquitty-translucent * { background-color: transparent; }", -1);
#pragma GCC diagnostic pop
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        g_object_unref(provider);
        gtk_widget_add_css_class(app().window, "ubiquitty-translucent");
    } else {
        // Opaque + a configured theme: paint the window and the pane container with
        // the theme background so the padding (a GTK margin around the grid picture)
        // reads as the terminal background instead of the GTK/Adwaita window color.
        // Unless [appearance] titlebar_style = "native", also replace the system
        // title bar with a GtkHeaderBar painted the same, with the title and the
        // window controls (close/minimise/maximise) in the theme foreground so they
        // stay legible on the continuous background.
        const int themeIndex = Ubiquitty::Runtime::launchThemeIndex(config);
        if (Ubiquitty::Themes::get(themeIndex)) {
            // The colours through the shared painter, so a later theme change
            // reaches the chrome by the same route; the class and the header bar
            // are widget structure and are attached once.
            applyChromeTheme(themeIndex);
            gtk_widget_add_css_class(app().window, "ubiquitty-themed-bg");
            gtk_widget_add_css_class(app().paneContainer, "ubiquitty-themed-bg");
            if (config.titlebarStyle != Ubiquitty::Preferences::TitlebarStyle::Native) {
                GtkWidget* header = gtk_header_bar_new();
                gtk_widget_add_css_class(header, "ubiquitty-titlebar");
                gtk_window_set_titlebar(GTK_WINDOW(app().window), header);
            }
        }
    }

    GtkEventController* keys = gtk_event_controller_key_new();
    // Capture phase: the terminal sees a key before a focused chrome widget
    // can take Return or Space for itself. The input method is still filtered
    // explicitly inside the handler.
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(onKeyPressed), nullptr);
    // key-released forwards bare-modifier releases under Kitty REPORT_ALL +
    // REPORT_EVENTS (the shared symbol drops it otherwise); parity with macOS.
    g_signal_connect(keys, "key-released", G_CALLBACK(onKeyReleased), nullptr);
    gtk_widget_add_controller(app().window, keys);

    // Input method (dead keys / compose / CJK), parity with macOS. onKeyPressed
    // routes each key through filter_keypress; the IM emits the inline preedit
    // and the final "commit". Manual filtering (not set_im_context) so the gtkApplication
    // accelerators above keep priority and the commit path stays explicit.
    app().imContext = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(app().imContext, app().window);
    g_signal_connect(app().imContext, "commit", G_CALLBACK(onIMCommit), nullptr);
    g_signal_connect(app().imContext, "preedit-changed", G_CALLBACK(onIMPreeditChanged), nullptr);
    g_signal_connect(app().imContext, "preedit-end", G_CALLBACK(onIMPreeditEnd), nullptr);

    // Focus reporting (DECSET 1004): drive Core's windowFocused on every
    // window focus transition. setFocused always runs — Core gates the CSI I /
    // CSI O emission on the gtkApplication having enabled focus reporting, and otherwise
    // just records the state (read by bellWantsNotification for the unfocused
    // bell). The unfocused/hollow cursor look is an overlay concern.
    GtkEventController* focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(onFocusEnter), nullptr);
    g_signal_connect(focus, "leave", G_CALLBACK(onFocusLeave), nullptr);
    gtk_widget_add_controller(app().window, focus);
    // The pointer-lock focus fact's other half: window activation can change
    // with no focus-in/out edge of its own (another app's window comes
    // forward over this one).
    g_signal_connect(app().window, "notify::"
                                   "is-active",
        G_CALLBACK(onPointerLockWindowActiveNotify), nullptr);

    // Mouse reporting + text selection controllers are per-pane (each pane's picture
    // owns its own, carrying &pane), set up in attachPaneControllers — so a click
    // routes to the pane it landed on. Just seed the focused pane's selection state.
    Ubiquitty::Selection::init(activePane()->selection);

    // One frame tick on the persistent container (not a picture, which is swapped on
    // tab/split changes) drives resize + blink + the dirty render.
    // Through the same helper the rest of the frontend uses, so the handle has
    // one owner and the first frame is asked for the way every later one is.
    requestRepaint();
    // Poll the foreground process + working directory for the rich window title.
    g_timeout_add(750, onTitleRefresh, nullptr);
    // Refresh the process inspector's tree while it's open.
    g_timeout_add(1000, onInspectorRefresh, nullptr);

    installUpdateMenu(gtkApplication);

    gtk_window_present(GTK_WINDOW(app().window));
}

// Headless self-tests.

constexpr const char canned[] = "\x1b[1;31mhello\x1b[0m \x1b[4munderlined\x1b[0m \x1b[9mstruck\x1b[0m \x1b[7mreverse\x1b[0m\r\n"
                                "\x1b[34mubiquitty-linux\x1b[0m:~$ "; // no trailing newline → cursor sits at the prompt

void initTermCanned()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term)
        return;
    // The theme the configuration names, which the windowed path applies in
    // onActivate and a headless render otherwise never reaches — so a rendered
    // PNG carried the neutral-dark default however the config was written.
    // Registration first: a user [[themes]] name resolves through the registry
    // and is absent from it until this runs.
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    Ubiquitty::Themes::registerThemesFromValues(config);
    Ubiquitty::Runtime::seedConfiguredTheme(*term, config);
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));
}

// Poll the PTY and drain for a short window (no GTK loop / display).
void drainBriefly(int fileDescriptor, int iterations)
{
    for (int i = 0; i < iterations; ++i) {
        struct pollfd pollDescriptor { fileDescriptor, POLLIN, 0 };
        if (poll(&pollDescriptor, 1, 80) > 0 && (pollDescriptor.revents & POLLIN)) {
            if (drainPane(*activePane()).reachedEnd)
                return;
        }
    }
}

// `cursor` is forwarded to the render path; nullptr (the plain --dump-png) draws
// the static focused block at the live cursor — byte-stable across runs.
int writePNG(const char* path, const Ubiquitty::Linux::CursorOverlay* cursor = nullptr, int viewOffset = 0,
    Ubiquitty::Selection::Session* selection = nullptr)
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("dump-png: rasterize failed\n");
        return 1;
    }
    // The padding the window shows as margins on the picture widget. There is no
    // widget here, so a grid written straight out is a picture of this terminal
    // with the setting missing — and the comparison against another frontend's
    // render then differs by the padding on every case that names one. The
    // margin is drawn inside the frame, so a search pill reaching past the grid
    // overhangs it as it does on every other arm.
    const Ubiquitty::Preferences::Values::PaddingEdges padding = loadPreferences().resolvedPadding();
    const float scale = static_cast<float>(app().rasterContext.deviceScale());
    // The frame's default ground, which under DECSCNM is the configured
    // foreground: the swap the builder applies to every default cell reaches
    // the padding too, as it does on every other arm.
    const Ubiquitty::Rendering::RGB8 background = Ubiquitty::Rendering::resolvePaletteColor(term->palette, Ubiquitty::colorDefault, Ubiquitty::isReverseVideo(term));
    const Ubiquitty::Linux::PagePadding page {
        .insetsInPixels = { static_cast<float>(padding.left) * scale, static_cast<float>(padding.right) * scale,
            static_cast<float>(padding.top) * scale, static_cast<float>(padding.bottom) * scale },
        .color = { background.red, background.green, background.blue,
            static_cast<uint8_t>(app().rasterContext.backgroundOpacity() * 255.0f + 0.5f) },
    };
    const bool hasRichFrame = capturePaneRichText(*activePane(), cursor, viewOffset,
        { page.insetsInPixels.left, page.insetsInPixels.top });
    const bool drawsRichCaret = hasRichFrame && activePane()->richTextFrame.hasRichTextCaret();
    Ubiquitty::Linux::CursorOverlay hiddenCursor;
    hiddenCursor.presentation = Ubiquitty::Rendering::CursorRenderState {};
    std::vector<uint8_t> padded;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, padded, width, height, viewOffset, selection, drawsRichCaret ? &hiddenCursor : cursor, 0, &page)) {
        g_printerr("dump-png: rasterize failed\n");
        return 1;
    }
    if (hasRichFrame)
        activePane()->richText.composite(activePane()->richTextFrame, padded, width, height, {}, drawsRichCaret);
    // The prompt marks, composited after the padding exists because that is
    // where they go. Core's one derivation, so this arm's brackets are the
    // portable arm's brackets rather than a second placement that agrees by eye.
    Ubiquitty::Rendering::compositePromptMarksIntoPadding(
        Ubiquitty::Rendering::promptMarkParametersForPadding(term->palette, { term->columns, term->rows },
            { currentRasterizer().cellMetrics().cellWidth, currentRasterizer().cellMetrics().cellHeight },
            { static_cast<float>(std::lround(padding.left * scale)), static_cast<float>(std::lround(padding.top * scale)) },
            static_cast<float>(width), currentRasterizer().cellMetrics().cellHeight, currentRasterizer().faceMetrics()),
        *term, Ubiquitty::Screen::scrollbackCount(term) - std::clamp(viewOffset, 0, Ubiquitty::Screen::scrollbackCount(term)),
        padded, { width, height });
    const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(padded, { width, height });
    FILE* f = std::fopen(path, "wb");
    if (!f) {
        g_printerr("dump-png: cannot open %s\n", path);
        return 1;
    }
    std::fwrite(png.data(), 1, png.size(), f);
    std::fclose(f);
    g_print("dump-png: %dx%d, %zu bytes → %s\n", width, height, png.size(), path);
    return 0;
}

// Render the canned screen via the GPU grid path (the CPU<->GPU oracle's GPU
// half) and write it to a PNG — the --dump-png companion for the pixel compare.
// `cursor` is forwarded to renderGrid; nullptr draws the static focused block.
int writePNGVulkan(const char* path, const Ubiquitty::Linux::CursorOverlay* cursor = nullptr)
{
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("dump-png-vk: no term\n");
        return 1;
    }
    Ubiquitty::Linux::VulkanRenderer renderer;
    setupFonts();
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init()) {
        g_printerr("dump-png-vk: vulkan init failed\n");
        return 1;
    }
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    const bool ok = renderer.renderGrid(app().rasterContext, term, rgba, width, height, 0, nullptr, cursor);
    renderer.shutdown();
    if (!ok) {
        g_printerr("dump-png-vk: renderGrid failed\n");
        return 1;
    }
    const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { width, height });
    FILE* f = std::fopen(path, "wb");
    if (!f) {
        g_printerr("dump-png-vk: cannot open %s\n", path);
        return 1;
    }
    std::fwrite(png.data(), 1, png.size(), f);
    std::fclose(f);
    g_print("dump-png-vk: %dx%d, %zu bytes → %s\n", width, height, png.size(), path);
    return 0;
}

// A CPU<->GPU oracle on a box with no Vulkan device did not run, and must not
// report the verdict of one that ran and disagreed. Both spellings did: the
// early returns below exited 1 with "vulkan init failed", and --smoke-opacity
// folded `gpuOk` into its `identical` boolean, so a machine without a GPU — the
// container Scripts/run-linux.sh builds in, among others — produced FAIL from
// eight modes that never executed a comparison. An oracle that cannot pass where
// it cannot run gets read as broken-by-environment, and then not read at all.
//
// 77 is the conventional "skipped" status, so a runner can COUNT skips rather
// than infer them. That matters more than the exit code: a device that quietly
// stops being detected has to read as a skip, not as a suite that got shorter.
//
// --dump-png-vk is not on this list. It is a tool a human invokes
// by name to get a PNG, so asking for a Vulkan render on a machine without
// Vulkan is a real error and silence would be worse. The line is whether the
// mode runs as part of a suite or because someone typed it.
constexpr int smokeSkippedExitCode = 77;

int skipNoGPUFrame(const char* mode, const char* stage)
{
    g_print("%s: SKIP (%s — the CPU/GPU oracle produced no GPU frame to compare)\n", mode, stage);
    return smokeSkippedExitCode;
}

// The verdict of a CPU<->GPU comparison, which has three outcomes rather than
// two. NotCompared means no GPU frame existed to compare against — the oracle
// did not run, and must not report the verdict of one that did. It is a distinct
// state rather than a flag beside `identical`, because every place that folded
// the two into one boolean is what this exists to fix.
enum class OracleOutcome : std::uint8_t {
    Matched,
    Differed,
    NotCompared,
};

// Printed by every caller rather than a bare PASS/FAIL, so a skip is visible: a
// device that quietly stops being detected has to read as a skip, not as a suite
// that got shorter.
const char* oracleLabel(OracleOutcome outcome)
{
    switch (outcome) {
    case OracleOutcome::Matched:
        return "PASS";
    case OracleOutcome::Differed:
        return "FAIL";
    case OracleOutcome::NotCompared:
        return "skipped(no GPU frame)";
    }
    return "skipped(no GPU frame)";
}

// --smoke-cursor — the cursor-overlay CPU<->GPU oracle. For each cursor shape
// (block / bar / underline) plus an unfocused/hollow case, feed the canned
// screen with the matching DECSCUSR, build a DETERMINISTIC CursorOverlay (fixed
// opaque blinkAlpha so the result is stable + the overlay's lit pixels are fully
// opaque), render via both the CPU SoftwareRenderer and the GPU VulkanRenderer,
// and assert the two are byte-identical. Leaves /tmp/cursor_bar.png to eyeball.
// --smoke-buffer-growth — one renderer, two frames, the second on a grid the
// first's instance buffers cannot hold.
//
// The instance streams are mapped once when their buffers are created and stay
// mapped for the buffer's life, so the only moment those pointers change is a
// grow: the old buffers are freed and new ones made and mapped. No other smoke
// grows a buffer — every one of them renders a single geometry — so a grow that
// came back without a mapping would draw nothing here and be reported by
// nothing.
//
// Both frames are checked against the CPU rasterizer, and a frame that fails to
// render is a failure rather than a comparison that did not happen: past init,
// there is a device, so a refusal is the renderer's answer and not the
// machine's.
int smokeBufferGrowth()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-buffer-growth", "vulkan init failed");

    struct Step {
        const char* name;
        int rows;
        int columns;
    };
    // Small first, so the second frame's cell, glyph and decoration counts all
    // exceed the capacities the first frame's buffers were sized to.
    const Step steps[] = {
        { "small", 8, 20 },
        { "grown", 40, 120 },
    };

    bool didEveryStepMatch = true;
    int widestSoFar = 0;
    for (const Step& step : steps) {
        activePane()->session->start(step.rows, step.columns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            g_printerr("smoke-buffer-growth: no term\n");
            renderer.shutdown();
            return 1;
        }
        // start() does not resize a session that is already running, and the
        // render size is derived from the terminal — so without this the second
        // step renders the first step's grid and grows nothing.
        Ubiquitty::resize(*term, step.rows, step.columns);
        // Underlined, coloured text, so the decoration and glyph streams carry
        // instances too rather than only the cell stream.
        for (int row = 0; row < step.rows; ++row) {
            Ubiquitty::processBytes(term, "\x1b[4;33m");
            for (int column = 0; column < step.columns - 1; ++column)
                Ubiquitty::processBytes(term, "W");
            Ubiquitty::processBytes(term, "\x1b[0m\r\n");
        }

        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRasterizeCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRasterizeCPUFrame && didRenderGPUFrame;
        const bool same = didCompareGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        if (!didRenderGPUFrame)
            g_printerr("smoke-buffer-growth: FAIL: '%s' rendered no frame, on a device that initialised\n", step.name);
        g_print("smoke-buffer-growth: %-6s CPU==GPU %s (%dx%d)\n", step.name,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)),
            cpuWidth, cpuHeight);
        didEveryStepMatch = didEveryStepMatch && same;
        // The growth has to have happened, or this smoke passes by rendering the
        // same grid twice and never frees a buffer.
        if (gpuWidth > widestSoFar)
            widestSoFar = gpuWidth;
        else if (didRenderGPUFrame) {
            g_printerr("smoke-buffer-growth: FAIL: '%s' rendered %d wide, no wider than the step before it — nothing grew\n",
                step.name, gpuWidth);
            didEveryStepMatch = false;
        }
    }
    renderer.shutdown();
    g_print("smoke-buffer-growth: %s\n", didEveryStepMatch ? "PASS" : "FAIL");
    return didEveryStepMatch ? 0 : 1;
}

int smokeRichCapture()
{
    setupFonts();
    LinuxPane& pane = *activePane();
    pane.session->start(8, 24);
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term) {
        g_printerr("smoke-rich-capture: no term\n");
        return 1;
    }
    const auto shaper = pane.richText.shaper();
    pane.session->setRichTextShaper(shaper.function, shaper.context);
    publishPaneTypography(pane);
    bool didPass = true;
    const auto check = [&](const char* name, bool passed) {
        didPass = didPass && passed;
        g_print("smoke-rich-capture: %s -- %s\n", name, passed ? "PASS" : "FAIL");
    };
    Ubiquitty::Linux::CursorOverlay cursor;
    cursor.visible = true;
    cursor.blinkAlpha = 1.0f;
    cursor.focused = true;
    struct CursorCase {
        const char* name;
        const char* sequence;
        Ubiquitty::Cursor::Shape shape;
        bool shouldCapture;
    };
    const std::array<CursorCase, 3> cases { {
        { "ordinary block skips capture", "\x1b[2 q", Ubiquitty::Cursor::Shape::Block, false },
        { "ordinary underline skips capture", "\x1b[4 q", Ubiquitty::Cursor::Shape::Underline, false },
        { "ordinary bar skips capture", "\x1b[6 q", Ubiquitty::Cursor::Shape::Bar, false },
    } };
    for (const auto& testCase : cases) {
        Ubiquitty::processBytes(term, testCase.sequence);
        cursor.shape = testCase.shape;
        check(testCase.name, capturePaneRichText(pane, &cursor, 0) == testCase.shouldCapture);
    }
    cursor.visible = false;
    check("hidden bar skips capture", !capturePaneRichText(pane, &cursor, 0));

    // Keep an active-screen block in history while the ordinary bar remains on
    // the live screen. The block keeps the capture; the bar outside it stays
    // the grid's, GTK's caret drawn by the cursor tier.
    Ubiquitty::processBytes(term, "\x1b[H\x1b]7404;g=1:C=1:i=1:w=12:h=2;{\\rtf1 rich text}\x1b\\\x1b[8;1H");
    for (int row = 0; row < 8; ++row)
        Ubiquitty::processBytes(term, "\r\n");
    Ubiquitty::processBytes(term, "\x1b[8;4H");
    cursor.visible = true;
    const auto blocks = term->richTextBlocks.blocks(Ubiquitty::RichText::activeScreen(*term));
    check("active block is offscreen", blocks.size() == 1 && blocks.front().row + blocks.front().height <= 0);
    check("offscreen block keeps the ordinary bar the grid's", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && !pane.richTextFrame.hasRichTextCaret() && pane.richTextFrame.inputs().cursor.shape == Ubiquitty::Cursor::Shape::Bar && pane.richTextFrame.inputs().cursor.row == 7 && pane.richTextFrame.inputs().cursor.column == 3 && pane.richTextFrame.inputs().cursor.richTextOffset == 0);
    Ubiquitty::Linux::CursorOverlay hiddenCursor;
    std::vector<std::uint8_t> pixels;
    std::vector<std::uint8_t> barPixels;
    int width = 0;
    int height = 0;
    const bool didRasterize = app().rasterContext.rasterizeTerm(term, pixels, width, height, 0, nullptr, &hiddenCursor)
        && app().rasterContext.rasterizeTerm(term, barPixels, width, height, 0, nullptr, &cursor);
    auto compositedPixels = barPixels;
    pane.richText.composite(pane.richTextFrame, compositedPixels, width, height, {}, false);
    check("offscreen block leaves the ordinary caret to the grid", didRasterize && barPixels != pixels && compositedPixels == barPixels);
    cursor.visible = false;
    check("offscreen block retains hidden-cursor capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.inputs().cursor.row < 0);
    Ubiquitty::processBytes(term, "\x1b]7404;a=d:i=1;\x1b\\");
    check("removed offscreen block permits skip", !capturePaneRichText(pane, &cursor, 0));

    constexpr std::string_view placeBlock = "\x1b[H\x1b]7404;g=1:C=1:i=1:w=12:h=2;{\\rtf1 rich text}\x1b\\";
    Ubiquitty::processBytes(term, placeBlock);
    Ubiquitty::Selection::init(pane.selection);
    Ubiquitty::Selection::beginGesture(pane.selection, *term, 0, 0, 1, 0, {});
    Ubiquitty::Selection::dragGesture(pane.selection, *term, 2, 0, 0);
    check("visible selected block captures", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1 && !pane.richTextFrame.richTextHighlights().empty());
    // The grid's frames draw the shared translucent tint over a selection; a
    // block's bands take the same fill, or the two meet in different tones.
    const Ubiquitty::Rendering::OverlayColor tint = Ubiquitty::Rendering::selectionHighlightColor();
    check("a block's selection bands take the grid's tint",
        !pane.richTextFrame.inputs().isSelectionBehindText && !pane.richTextFrame.richTextHighlights().empty()
            && pane.richTextFrame.richTextHighlights().front().alpha == tint.alpha
            && pane.richTextFrame.richTextHighlights().front().red == tint.red);
    check("visible block grid renders", app().rasterContext.rasterizeTerm(term, pixels, width, height, 0, nullptr, &hiddenCursor));
    const auto rastersBefore = pane.richText.rasterCount();
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("visible block creates a retained raster", pane.richText.rasterCount() > rastersBefore);
    Ubiquitty::processBytes(term, "\x1b]7404;a=d:i=1;\x1b\\");
    check("removed visible block gets a cleanup capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.richTextHighlights().empty());
    const auto cleanedPixels = pixels;
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("cleanup composites no stale rich text", pixels == cleanedPixels);
    check("cleaned frame skips subsequent captures", !capturePaneRichText(pane, &cursor, 0));

    Ubiquitty::Selection::init(pane.selection);
    Ubiquitty::processBytes(term, placeBlock);
    check("primary block captures again", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1);
    Ubiquitty::processBytes(term, "\x1b[?1049h");
    check("screen switch clears previous rich frame", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.richTextHighlights().empty());
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("inactive-screen block does not force captures", !capturePaneRichText(pane, &cursor, 0));
    Ubiquitty::processBytes(term, "\x1b[?1049l");
    check("returning to primary restores rich capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1);
    return didPass ? 0 : 1;
}

// `[cursor] alpha` reaches the frame: a bar drawn at half alpha is not the bar
// drawn solid. The CPU raster is the witness; its cursor colour carries the
// configured alpha, which the palette's three channels cannot. A bar rather
// than a block, because the focused block is the cell tier and the alpha is
// the overlay's.
int smokeCursorAlpha()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-cursor-alpha: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));
    const auto renderBlock = [term](const char* document, std::vector<uint8_t>& out) {
        (void)Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict);
        Ubiquitty::Linux::CursorOverlay cursor;
        cursor.visible = true;
        cursor.shape = Ubiquitty::Cursor::Shape::Bar;
        cursor.blinkAlpha = 1.0f;
        cursor.focused = true;
        int width = 0;
        int height = 0;
        return app().rasterContext.rasterizeTerm(term, out, width, height, 0, nullptr, &cursor);
    };
    // The control first: the same document twice draws the same frame, so a
    // difference below is the alpha and nothing else.
    std::vector<uint8_t> solid;
    std::vector<uint8_t> solidAgain;
    std::vector<uint8_t> translucent;
    const bool didRender = renderBlock("[cursor]\nshape = \"bar\"\n", solid)
        && renderBlock("[cursor]\nshape = \"bar\"\n", solidAgain)
        && renderBlock("[cursor]\nshape = \"bar\"\nalpha = 128\n", translucent);
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
    const bool isControlStable = solid == solidAgain;
    const bool doesAlphaReachTheFrame = solid.size() == translucent.size() && solid != translucent;
    const bool didPass = didRender && isControlStable && doesAlphaReachTheFrame;
    g_print("smoke-cursor-alpha: rendered=%d control-stable=%d alpha-differs=%d -- %s\n", didRender ? 1 : 0, isControlStable ? 1 : 0,
        doesAlphaReachTheFrame ? 1 : 0, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

bool smokeCursorPresentation(Ubiquitty::Linux::VulkanRenderer& renderer)
{
    LinuxPane& pane = *activePane();
    pane.session->start(6, 24);
    pane.cursorPresentation.reset();
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term) {
        return false;
    }
    term->windowFocused = 1;
    Ubiquitty::processBytes(term, "\x1b[?25h\x1b[6 q\x1b]12;#ff0044\x07\x1b[2;7H");
    struct Step {
        const char* name;
        const char* bytes;
        double seconds;
        int expectedRow;
        int expectedColumn;
    };
    const Step steps[] = {
        { "visible", "", 10.000, 1, 6 },
        { "redraw-hide", "\x1b[?25l\x1b[5;19H\x1b[4 q\x1b]12;#00ff00\x07", 10.001, 1, 6 },
        { "hidden-repeat", "", 10.025, 1, 6 },
        { "redraw-show", "\x1b[2;7H\x1b[6 q\x1b]12;#ff0044\x07\x1b[?25h", 10.030, 1, 6 },
        { "persistent-hide", "\x1b[?25l\x1b[5;19H", 10.040, 1, 6 },
        { "persistent-repeat", "", 10.075, 1, 6 },
        { "hidden-expired", "", 10.091, -1, 0 },
        { "hidden-stays", "", 10.120, -1, 0 },
        { "visible-again", "\x1b[2;7H\x1b[?25h", 10.130, 1, 6 },
        { "move-held", "\x1b[2;13H", 10.140, 1, 6 },
        { "move-settled", "", 10.157, 1, 12 },
    };
    bool didPass = true;
    std::vector<uint8_t> baseline;
    for (const Step& step : steps) {
        Ubiquitty::processBytes(term, step.bytes);
        const Ubiquitty::Linux::CursorOverlay cursor = resolvePresentedCursorOverlay(pane, step.seconds, 1.0 / 60.0);
        const Ubiquitty::Rendering::CursorRenderState& presented = *cursor.presentation;
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRenderCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor);
        const bool didRenderGPU = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor);
        const bool isPositionCorrect = presented.row == step.expectedRow
            && (presented.row < 0 || presented.column == step.expectedColumn);
        const bool isSame = didRenderCPU && didRenderGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        if (baseline.empty()) {
            baseline = cpu;
        }
        const bool shouldMatchBaseline = step.expectedRow == 1 && step.expectedColumn == 6;
        const bool isAppearanceCorrect = shouldMatchBaseline ? cpu == baseline : cpu != baseline;
        const bool isStepCorrect = isPositionCorrect && isSame && isAppearanceCorrect;
        didPass = didPass && isStepCorrect;
        g_print("smoke-cursor: presentation %-17s position=%d CPU==GPU=%d appearance=%d -- %s\n", step.name,
            isPositionCorrect ? 1 : 0, isSame ? 1 : 0, isAppearanceCorrect ? 1 : 0, isStepCorrect ? "PASS" : "FAIL");
    }

    pane.cursorPresentation.reset();
    Ubiquitty::processBytes(term, "\x1b[2;7H\x1b[?25h");
    (void)resolvePresentedCursorOverlay(pane, 10.158, 1.0 / 60.0);
    Ubiquitty::processBytes(term, "\x1b[?25l\x1b[2;1H\x1b#6\x1b[5;19H");
    const auto doubledRow = resolvePresentedCursorOverlay(pane, 10.159, 1.0 / 60.0);
    const bool doesHeldRowFollowGeometry = doubledRow.presentation->row == 1
        && doubledRow.presentation->lineAttribute == Ubiquitty::Screen::rowLineAttribute(term, Ubiquitty::Screen::scrollbackCount(term) + 1)
        && doubledRow.presentation->lineAttribute != Ubiquitty::lineAttributeNormal;
    didPass = didPass && doesHeldRowFollowGeometry;
    g_print("smoke-cursor: presentation held-row-geometry -- %s\n", doesHeldRowFollowGeometry ? "PASS" : "FAIL");
    LinuxPane otherPane;
    otherPane.session = pane.session;
    const auto initiallyHidden = resolvePresentedCursorOverlay(otherPane, 10.160, 1.0 / 60.0);
    const bool isPaneIndependent = initiallyHidden.presentation->row < 0 && otherPane.cursorPresentation.deadlineSeconds() == 0;
    pane.viewOffset = 1;
    const auto scrolled = resolvePresentedCursorOverlay(pane, 10.161, 1.0 / 60.0);
    const bool doesScrollReset = scrolled.presentation->row < 0 && pane.cursorPresentation.deadlineSeconds() == 0;
    pane.viewOffset = 0;
    const auto returnedHidden = resolvePresentedCursorOverlay(pane, 10.162, 1.0 / 60.0);
    const bool doesHiddenStayHidden = returnedHidden.presentation->row < 0;
    didPass = didPass && isPaneIndependent && doesScrollReset && doesHiddenStayHidden;
    g_print("smoke-cursor: presentation pane-isolation=%d scroll-reset=%d hidden-return=%d -- %s\n",
        isPaneIndependent ? 1 : 0, doesScrollReset ? 1 : 0, doesHiddenStayHidden ? 1 : 0,
        isPaneIndependent && doesScrollReset && doesHiddenStayHidden ? "PASS" : "FAIL");

    const double nowSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
    Ubiquitty::processBytes(term, "\x1b[?25h");
    (void)resolvePresentedCursorOverlay(pane, nowSeconds, 1.0 / 60.0);
    Ubiquitty::processBytes(term, "\x1b[?25l");
    (void)resolvePresentedCursorOverlay(pane, nowSeconds, 1.0 / 60.0);
    scheduleCursorPresentation(pane, nowSeconds);
    const bool didArmDeadline = pane.cursorPresentationSource != 0;
    (void)app().frameDriver.noteActivity(nowSeconds);
    const bool doesClockCoverDeadline = !app().frameDriver.idleExpired(pane.cursorPresentation.deadlineSeconds());
    const gint64 waitUntil = g_get_monotonic_time() + 250000;
    while (pane.cursorPresentationSource != 0 && g_get_monotonic_time() < waitUntil) {
        (void)g_main_context_iteration(nullptr, FALSE);
        g_usleep(1000);
    }
    const auto expired = resolvePresentedCursorOverlay(pane, static_cast<double>(g_get_monotonic_time()) / 1e6, 1.0 / 60.0);
    const bool didDeadlineExpire = pane.cursorPresentationSource == 0 && expired.presentation->row < 0
        && pane.cursorPresentation.deadlineSeconds() == 0;
    didPass = didPass && didArmDeadline && didDeadlineExpire && doesClockCoverDeadline;
    g_print("smoke-cursor: presentation idle-deadline armed=%d expired=%d clock-covers=%d -- %s\n",
        didArmDeadline ? 1 : 0, didDeadlineExpire ? 1 : 0, doesClockCoverDeadline ? 1 : 0,
        didArmDeadline && didDeadlineExpire && doesClockCoverDeadline ? "PASS" : "FAIL");
    guint closedSource = 0;
    {
        LinuxPane closingPane;
        closingPane.session = pane.session;
        const double closeSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
        Ubiquitty::processBytes(term, "\x1b[?25h");
        (void)resolvePresentedCursorOverlay(closingPane, closeSeconds, 1.0 / 60.0);
        Ubiquitty::processBytes(term, "\x1b[?25l");
        (void)resolvePresentedCursorOverlay(closingPane, closeSeconds, 1.0 / 60.0);
        scheduleCursorPresentation(closingPane, closeSeconds);
        closedSource = closingPane.cursorPresentationSource;
    }
    const bool didCancelOnClose = closedSource != 0 && g_main_context_find_source_by_id(nullptr, closedSource) == nullptr;
    didPass = didPass && didCancelOnClose;
    g_print("smoke-cursor: presentation close-cancels-deadline -- %s\n", didCancelOnClose ? "PASS" : "FAIL");
    return didPass;
}

// --smoke-gtk-caret — the bar cursor against GTK's own insertion caret.
//
// GTK is the oracle, not a description of it: each case renders this arm's
// frame with the cursor hidden, hands that frame to GTK as a texture, and has
// GTK draw its caret over it with `gtk_snapshot_render_insertion_cursor` — the
// call GtkText's caret goes through — fading it the way GtkText does, with an
// opacity over the caret. GSK renders the result at the case's scale. The
// caret's line comes from a PangoLayout whose runs are shape attributes sized
// to the cell's line box, so GTK places it from the same geometry the terminal
// draws in, through its own rounding. The arm's frame with the bar showing,
// from the CPU raster and from Vulkan, must then equal GTK's byte for byte.
//
// A control proves the comparison can see a caret: the frame with no caret
// must differ from GTK's on every case where GTK drew one. Unfocused, GTK
// draws no caret and the terminal draws its steady hollow outline, so those
// cases compare the bar and the underline against the unfocused block's
// outline instead.
namespace {

struct GTKCaretGeometry {
    double leftInPixels = 0.0;
    double lineTopInPixels = 0.0;
    double lineBottomInPixels = 0.0;
};

// GTK's caret over `background`, rendered by `renderer` at `scale`. Empty when
// the renderer produced nothing.
std::vector<std::uint8_t> renderGTKCaret(GskRenderer* renderer, GtkWidget* probe, const std::vector<std::uint8_t>& background,
    int width, int height, int scale, const GTKCaretGeometry& geometry, float opacity)
{
    GBytes* bytes = g_bytes_new(background.data(), background.size());
    GdkTexture* texture = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, static_cast<gsize>(width) * 4);
    g_bytes_unref(bytes);
    GtkSnapshot* snapshot = gtk_snapshot_new();
    const float logicalScale = static_cast<float>(scale);
    gtk_snapshot_scale(snapshot, logicalScale, logicalScale);
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0.0f, 0.0f, static_cast<float>(width) / logicalScale, static_cast<float>(height) / logicalScale);
    gtk_snapshot_append_texture(snapshot, texture, &bounds);
    g_object_unref(texture);
    // One run per line, each a shape whose logical rectangle is exact in
    // Pango units: the first fills the rows above the caret's line, the
    // second is the line itself and ends at the insertion point.
    const auto units = [scale](double pixels) { return static_cast<int>(std::lround(pixels / scale * PANGO_SCALE)); };
    const int top = units(geometry.lineTopInPixels);
    const int lineHeight = units(geometry.lineBottomInPixels) - top;
    const int left = units(geometry.leftInPixels);
    const std::string object = "\xef\xbf\xbc";
    const std::string text = top > 0 ? object + "\n" + object : object;
    PangoLayout* layout = gtk_widget_create_pango_layout(probe, text.c_str());
    PangoFontDescription* font = pango_font_description_from_string(app().fontFamily.c_str());
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    PangoAttrList* attributes = pango_attr_list_new();
    const auto shape = [&](unsigned start, int y, int lineWidth, int heightInUnits) {
        PangoRectangle rectangle { 0, y, lineWidth, heightInUnits };
        PangoAttribute* attribute = pango_attr_shape_new(&rectangle, &rectangle);
        attribute->start_index = start;
        attribute->end_index = start + static_cast<unsigned>(object.size());
        pango_attr_list_insert(attributes, attribute);
    };
    if (top > 0)
        shape(0, -top, 0, top);
    shape(top > 0 ? static_cast<unsigned>(object.size()) + 1 : 0, -lineHeight, left, lineHeight);
    pango_layout_set_attributes(layout, attributes);
    pango_attr_list_unref(attributes);
    gtk_snapshot_push_opacity(snapshot, opacity);
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_snapshot_render_insertion_cursor(snapshot, gtk_widget_get_style_context(probe), 0.0, 0.0, layout,
        static_cast<int>(text.size()), PANGO_DIRECTION_LTR);
    G_GNUC_END_IGNORE_DEPRECATIONS
    gtk_snapshot_pop(snapshot);
    g_object_unref(layout);
    GskRenderNode* node = gtk_snapshot_free_to_node(snapshot);
    std::vector<std::uint8_t> pixels;
    if (!node)
        return pixels;
    graphene_rect_t viewport = GRAPHENE_RECT_INIT(0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height));
    GdkTexture* rendered = gsk_renderer_render_texture(renderer, node, &viewport);
    gsk_render_node_unref(node);
    if (!rendered)
        return pixels;
    if (gdk_texture_get_width(rendered) == width && gdk_texture_get_height(rendered) == height) {
        pixels.resize(static_cast<std::size_t>(width) * height * 4);
        GdkTextureDownloader* downloader = gdk_texture_downloader_new(rendered);
        gdk_texture_downloader_set_format(downloader, GDK_MEMORY_R8G8B8A8);
        gdk_texture_downloader_download_into(downloader, pixels.data(), static_cast<gsize>(width) * 4);
        gdk_texture_downloader_free(downloader);
    }
    g_object_unref(rendered);
    return pixels;
}

// The first differing pixel and how many differ, for a report a reader can act on.
std::string describeDifference(const std::vector<std::uint8_t>& expected, const std::vector<std::uint8_t>& actual, int width)
{
    if (expected.size() != actual.size())
        return "sizes differ";
    std::size_t count = 0;
    std::string first;
    int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
    for (std::size_t offset = 0; offset < expected.size(); offset += 4) {
        if (std::equal(expected.begin() + static_cast<std::ptrdiff_t>(offset), expected.begin() + static_cast<std::ptrdiff_t>(offset) + 4, actual.begin() + static_cast<std::ptrdiff_t>(offset)))
            continue;
        const int x = static_cast<int>(offset / 4) % width;
        const int y = static_cast<int>(offset / 4) / width;
        minX = std::min(minX, x);
        minY = std::min(minY, y);
        maxX = std::max(maxX, x);
        maxY = std::max(maxY, y);
        if (count++ == 0)
            first = std::format("({},{}) gtk {},{},{},{} ours {},{},{},{}", x, y, expected[offset], expected[offset + 1], expected[offset + 2], expected[offset + 3],
                actual[offset], actual[offset + 1], actual[offset + 2], actual[offset + 3]);
    }
    if (count == 0)
        return "identical";
    return std::format("{} px differ in x {}..{} y {}..{}, first {}", count, minX, maxX, minY, maxY, first);
}

} // namespace

int smokeGTKCaret()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-gtk-caret: GTK needs a display\n");
        return 1;
    }
    struct Renderer {
        const char* name;
        GskRenderer* renderer;
    };
    std::vector<Renderer> renderers;
    const auto addRenderer = [&](const char* name, GskRenderer* renderer) {
        GError* error = nullptr;
        if (renderer && gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), &error)) {
            renderers.push_back({ name, renderer });
            return;
        }
        g_print("smoke-gtk-caret: GSK %s renderer unavailable (%s)\n", name, error ? error->message : "not built");
        if (error)
            g_error_free(error);
        if (renderer)
            g_object_unref(renderer);
    };
    addRenderer("cairo", gsk_cairo_renderer_new());
    addRenderer("gl", gsk_gl_renderer_new());
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    addRenderer("vulkan", gsk_vulkan_renderer_new());
    G_GNUC_END_IGNORE_DEPRECATIONS
    if (renderers.empty()) {
        g_printerr("smoke-gtk-caret: FAIL: no GSK renderer realized\n");
        return 1;
    }

    // The caret colour is GtkText's `caret-color`, which a terminal's is.
    GtkWidget* probe = g_object_ref_sink(gtk_text_new());
    GtkCssProvider* provider = gtk_css_provider_new();
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_style_context_add_provider(gtk_widget_get_style_context(probe), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_USER);
    G_GNUC_END_IGNORE_DEPRECATIONS

    struct Configuration {
        const char* name;
        int scale;
        int fontSize;
        int lineSpacing;
        double aspectRatio;
    };
    const Configuration configurations[] = {
        { "scale1", 1, 13, 0, 0.0 },
        { "scale2", 2, 13, 0, 0.0 },
        { "scale1-spaced", 1, 13, 3, 0.0 },
        { "scale2-spaced", 2, 13, 3, 0.0 },
        { "scale1-large", 1, 40, 0, 0.0 },
        { "scale2-large", 2, 40, 0, 0.0 },
        { "scale1-aspect", 1, 13, 0, 0.12 },
        { "scale2-aspect", 2, 13, 0, 0.12 },
    };
    struct Case {
        const char* name;
        const char* bytes;
        int anchorRow;
        int anchorColumn;
        float blinkAlpha;
        bool focused;
    };
    const Case cases[] = {
        { "prompt", "$ typed\x1b[1;8H", 0, 7, 1.0f, true },
        { "column-0", "first\x1b[2;1H", 1, 0, 1.0f, true },
        { "last-column", "\x1b[3;20Hz\x1b[3;20H", 2, 19, 1.0f, true },
        { "wide-lead", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;3H", 0, 2, 1.0f, true },
        { "wide-trail", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;4H", 0, 2, 1.0f, true },
        { "custom-colour", "\x1b]12;#ff0044\x07$ custom\x1b[1;4H", 0, 3, 1.0f, true },
        { "fade-0.75", "$ fade\x1b[1;3H", 0, 2, 0.75f, true },
        { "fade-0.5", "$ fade\x1b[1;3H", 0, 2, 0.5f, true },
        { "fade-0.25", "$ fade\x1b[1;3H", 0, 2, 0.25f, true },
        { "fade-0.9", "$ fade\x1b[1;3H", 0, 2, 0.9f, true },
        { "fade-0.62", "$ fade\x1b[1;3H", 0, 2, 0.62f, true },
        { "fade-0.3", "$ fade\x1b[1;3H", 0, 2, 0.3f, true },
        { "fade-0.1", "$ fade\x1b[1;3H", 0, 2, 0.1f, true },
        { "fade-off", "$ fade\x1b[1;3H", 0, 2, 0.0f, true },
        { "unfocused", "$ unfocused\x1b[1;5H", 0, 4, 1.0f, false },
        { "unfocused-wide", "\xe4\xb8\x80\xe4\xba\x8c wide\x1b[1;3H", 0, 2, 1.0f, false },
    };

    bool didPass = true;
    int compared = 0;
    for (const Configuration& configuration : configurations) {
        const std::string document = std::format("[font]\nsize = {}\nline_spacing = {}\n", configuration.fontSize, configuration.lineSpacing);
        if (!Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
            g_printerr("smoke-gtk-caret: FAIL: configuration refused\n");
            return 1;
        }
        app().scale = configuration.scale;
        app().fontDPI = 72.0;
        app().fontSizePoints = configuration.fontSize;
        app().rasterContext.setDeviceScale(configuration.scale);
        setupFonts();
        applyWindowGlobalRenderSettings(Ubiquitty::Preferences::values());
        rebuildFontsFromPreferences();
        GtkSettings* settings = gtk_settings_get_default();
        if (configuration.aspectRatio > 0.0)
            g_object_set(settings, "gtk-cursor-aspect-ratio", configuration.aspectRatio, nullptr);
        else
            gtk_settings_reset_property(settings, "gtk-cursor-aspect-ratio");
        // The arm reads the setting exactly as the window does.
        readToolkitCaretSettings();

        Ubiquitty::Linux::VulkanRenderer vulkan;
        vulkan.setGlyphRasterizer(currentRasterizer());
        vulkan.setLigatureRasterizer(currentRasterizer());
        const bool hasVulkan = vulkan.init();

        const Ubiquitty::Rendering::CellMetrics metrics = currentRasterizer().cellMetrics();
        const double lineSpacingPixels = app().rasterContext.renderConfiguration().lineSpacingPoints * 0.5 * configuration.scale;
        g_print("smoke-gtk-caret: %s: cell %gx%g device px, line spacing %g pt, gtk-cursor-aspect-ratio %g\n", configuration.name, metrics.cellWidth,
            metrics.cellHeight, app().rasterContext.renderConfiguration().lineSpacingPoints, app().rasterContext.toolkitCaret().aspectRatio);
        for (const Case& testCase : cases) {
            activePane()->session->start(4, 20);
            Ubiquitty::Terminal* term = activePane()->session->terminal();
            if (!term) {
                g_printerr("smoke-gtk-caret: FAIL: no terminal\n");
                return 1;
            }
            // A clean screen per case, so each case's text is the only text.
            Ubiquitty::processBytes(term, "\033c\033[5 q");
            Ubiquitty::processBytes(term, testCase.bytes);
            // GTK owns the caret's geometry and fade; its colour is the theme's
            // cursor colour as Core resolves it, so GTK is handed that colour.
            const Ubiquitty::PaletteRGB caret = term->palette.cursor;
            const std::string css = std::format("text {{ caret-color: rgb({},{},{}); }}", Ubiquitty::channel16To8(caret.red),
                Ubiquitty::channel16To8(caret.green), Ubiquitty::channel16To8(caret.blue));
            gtk_css_provider_load_from_string(provider, css.c_str());

            Ubiquitty::Linux::CursorOverlay hidden;
            Ubiquitty::Linux::CursorOverlay bar;
            bar.visible = true;
            bar.shape = Ubiquitty::Cursor::Shape::Bar;
            bar.blinkAlpha = testCase.blinkAlpha;
            bar.focused = testCase.focused;
            const GTKCaretGeometry geometry {
                .leftInPixels = testCase.anchorColumn * static_cast<double>(metrics.cellWidth),
                .lineTopInPixels = testCase.anchorRow * static_cast<double>(metrics.cellHeight) + lineSpacingPixels,
                .lineBottomInPixels = (testCase.anchorRow + 1) * static_cast<double>(metrics.cellHeight) - lineSpacingPixels,
            };
            // Each path against GTK's caret over that path's own caretless
            // frame, so the comparison sees the caret and nothing else.
            struct Path {
                const char* name = "";
                bool didRender = false;
                int width = 0;
                int height = 0;
                std::vector<std::uint8_t> background;
                std::vector<std::uint8_t> withBar;
            };
            std::array<Path, 2> paths;
            paths[0].name = "cpu";
            paths[1].name = "vulkan";
            {
                int width = 0, height = 0;
                paths[0].didRender = app().rasterContext.rasterizeTerm(term, paths[0].background, paths[0].width, paths[0].height, 0, nullptr, &hidden)
                    && app().rasterContext.rasterizeTerm(term, paths[0].withBar, width, height, 0, nullptr, &bar)
                    && width == paths[0].width && height == paths[0].height;
                paths[1].didRender = hasVulkan
                    && vulkan.renderGrid(app().rasterContext, term, paths[1].background, paths[1].width, paths[1].height, 0, nullptr, &hidden)
                    && vulkan.renderGrid(app().rasterContext, term, paths[1].withBar, width, height, 0, nullptr, &bar)
                    && width == paths[1].width && height == paths[1].height;
            }
            // Unfocused, GTK draws no caret but the terminal draws its steady
            // hollow outline (Docs/cursor-blink-design.md): the bar and the
            // underline must be the unfocused block's outline on both paths,
            // and visible.
            if (!testCase.focused) {
                Ubiquitty::Linux::CursorOverlay block = bar;
                block.shape = Ubiquitty::Cursor::Shape::Block;
                Ubiquitty::Linux::CursorOverlay underline = bar;
                underline.shape = Ubiquitty::Cursor::Shape::Underline;
                const auto render = [&](const Path& path, const Ubiquitty::Linux::CursorOverlay& cursor, std::vector<std::uint8_t>& out) {
                    int width = 0, height = 0;
                    const bool didRender = path.name == std::string_view("cpu")
                        ? app().rasterContext.rasterizeTerm(term, out, width, height, 0, nullptr, &cursor)
                        : vulkan.renderGrid(app().rasterContext, term, out, width, height, 0, nullptr, &cursor);
                    return didRender && width == path.width && height == path.height;
                };
                for (const Path& path : paths) {
                    if (!path.didRender)
                        continue;
                    std::vector<std::uint8_t> outline;
                    std::vector<std::uint8_t> underlined;
                    const bool didRenderOutline = render(path, block, outline);
                    const bool didRenderUnderline = render(path, underline, underlined);
                    for (const auto& [shapeName, frame] : { std::pair<const char*, const std::vector<std::uint8_t>*> { "bar", &path.withBar }, { "underline", &underlined } }) {
                        const bool isOutline = didRenderOutline && didRenderUnderline && *frame == outline;
                        const bool isVisible = *frame != path.background;
                        ++compared;
                        didPass = didPass && isOutline && isVisible;
                        g_print("smoke-gtk-caret: %s %-14s outline %-6s %s==unfocused-block %s visible %s -- %s\n", configuration.name, testCase.name,
                            path.name, shapeName, isOutline ? "identical" : "DIFFERS", isVisible ? "yes" : "NO", isOutline && isVisible ? "PASS" : "FAIL");
                        if (!isOutline && didRenderOutline && didRenderUnderline)
                            g_print("smoke-gtk-caret:   %s\n", describeDifference(outline, *frame, path.width).c_str());
                    }
                }
                continue;
            }
            const bool isFractional = testCase.blinkAlpha > 0.0f && testCase.blinkAlpha < 1.0f;
            for (const Renderer& renderer : renderers) {
                // Cairo is GTK's software renderer and blends in integers, so
                // its bytes are the same on every machine: the gate. GSK's GL
                // and Vulkan renderers blend in floats on the GPU; on a
                // half-transparent caret they round a channel either way of a
                // half, so there they are held to one level, and to every byte
                // wherever the caret is opaque or absent.
                const bool isExactRenderer = std::string_view(renderer.name) == "cairo";
                for (const Path& path : paths) {
                    if (!path.didRender) {
                        if (path.name == std::string_view("cpu")) {
                            didPass = false;
                            g_print("smoke-gtk-caret: %s %-14s %-6s cpu did not render -- FAIL\n", configuration.name, testCase.name, renderer.name);
                        }
                        continue;
                    }
                    const std::vector<std::uint8_t> gtk = renderGTKCaret(renderer.renderer, probe, path.background, path.width, path.height,
                        configuration.scale, geometry, testCase.blinkAlpha);
                    int largestDifference = gtk.size() == path.withBar.size() ? 0 : 256;
                    for (std::size_t index = 0; largestDifference < 256 && index < gtk.size(); ++index)
                        largestDifference = std::max(largestDifference, std::abs(static_cast<int>(gtk[index]) - static_cast<int>(path.withBar[index])));
                    const bool isIdentical = !gtk.empty() && largestDifference == 0;
                    const bool isWithinRenderer = isIdentical || (!gtk.empty() && !isExactRenderer && isFractional && largestDifference <= 1);
                    // The control: wherever GTK drew a caret, the caretless
                    // frame must not pass for GTK's.
                    const bool doesControlDiffer = gtk.empty() || testCase.blinkAlpha <= 0.0f || path.background != gtk;
                    const bool passed = isWithinRenderer && doesControlDiffer;
                    ++compared;
                    didPass = didPass && passed;
                    g_print("smoke-gtk-caret: %s %-14s %-6s gtk==%-6s %s control %s -- %s\n", configuration.name, testCase.name, renderer.name, path.name,
                        isIdentical ? "identical" : (isWithinRenderer ? "within-1" : "DIFFERS"), doesControlDiffer ? "differs" : "SAME", passed ? "PASS" : "FAIL");
                    if (!isIdentical && !gtk.empty())
                        g_print("smoke-gtk-caret:   %s\n", describeDifference(gtk, path.withBar, path.width).c_str());
                }
            }
        }
        if (hasVulkan)
            vulkan.shutdown();
    }
    gtk_settings_reset_property(gtk_settings_get_default(), "gtk-cursor-aspect-ratio");
    g_object_unref(provider);
    g_object_unref(probe);
    for (const Renderer& renderer : renderers) {
        gsk_renderer_unrealize(renderer.renderer);
        g_object_unref(renderer.renderer);
    }
    g_print("smoke-gtk-caret: %d comparisons -- %s\n", compared, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

int smokeCursor()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-cursor", "vulkan init failed");

    struct Case {
        const char* name;
        const char* decscusr; // DECSCUSR escape, "" = leave default (block)
        Ubiquitty::Cursor::Shape shape;
        bool focused;
    };
    const Case cases[] = {
        { "block", "", Ubiquitty::Cursor::Shape::Block, true },
        { "bar", "\x1b[5 q", Ubiquitty::Cursor::Shape::Bar, true },
        { "underline", "\x1b[3 q", Ubiquitty::Cursor::Shape::Underline, true },
        { "hollow", "", Ubiquitty::Cursor::Shape::Block, false }, // unfocused block → hollow outline
    };

    bool allPass = true;
    for (const Case& testCase : cases) {
        // Fresh canned screen per case (the cursor sits at the prompt).
        activePane()->session->start(startupRows, startupColumns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            g_printerr("smoke-cursor: no term\n");
            renderer.shutdown();
            return 1;
        }
        Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));
        if (testCase.decscusr[0] != '\0')
            Ubiquitty::processBytes(term, testCase.decscusr);

        // Deterministic overlay: opaque blink (the lit pixels are fully opaque,
        // so CPU integer-blend == GPU hardware-blend exactly) at the resolved shape.
        Ubiquitty::Linux::CursorOverlay cursor;
        cursor.visible = true;
        cursor.shape = testCase.shape;
        cursor.blinkAlpha = 1.0f;
        cursor.focused = testCase.focused;

        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool cpuOk = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor);
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor);
        const bool didCompareGPU = cpuOk && didRenderGPUFrame;
        const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);

        // The frame split the perf log reports. Checked here because this is a
        // real renderGrid: the counters are read from a wrapping microsecond
        // clock, and a delta taken after the conversion to seconds rather than
        // before turns a wrap into a negative interval that reads as a fast
        // frame. A frame that rendered has to have spent time in both halves.
        if (didRenderGPUFrame) {
            const double waitSeconds = renderer.lastFrameWaitSeconds();
            const double readbackSeconds = renderer.lastFrameReadbackSeconds();
            const bool areTimingsSane = waitSeconds >= 0.0 && readbackSeconds >= 0.0
                && waitSeconds < 60.0 && readbackSeconds < 60.0
                && (waitSeconds + readbackSeconds) > 0.0;
            if (!areTimingsSane) {
                g_printerr("smoke-cursor: FAIL: frame split is not a time (wait=%f readback=%f)\n",
                    waitSeconds, readbackSeconds);
                allPass = false;
            }
        }
        g_print("smoke-cursor: %-9s CPU==GPU %s (%dx%d)\n", testCase.name, oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), cpuWidth, cpuHeight);
        allPass = allPass && same;

        // Leave the bar PNG on disk for an eyeball check.
        if (std::string_view(testCase.name) == "bar" && cpuOk) {
            const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
            FILE* f = std::fopen("/tmp/cursor_bar.png", "wb");
            if (f) {
                std::fwrite(png.data(), 1, png.size(), f);
                std::fclose(f);
                g_print("smoke-cursor: wrote /tmp/cursor_bar.png (%dx%d)\n", cpuWidth, cpuHeight);
            }
        }
    }
    allPass = smokeCursorPresentation(renderer) && allPass;
    renderer.shutdown();
    g_print("smoke-cursor: %s\n", allPass ? "PASS" : "FAIL");
    return allPass ? 0 : 1;
}

// --smoke-ligature-sheet — a distilled row becomes strips on the sheet.
//
// The layer between the shaper and the renderer: Core walks the row into run
// candidates, this sheet keys each one, shapes it, draws it into a slot, and
// reports the rect plus the extents the builder maps cell slices against.
//
// Checked against the host mirror rather than a rendering, which is what makes
// it answerable with no GPU: the upload copies the mirror verbatim, so where a
// strip landed and whether drawing one disturbed its neighbours are questions
// the bytes answer. A rendering could not show the second one at all.
// --smoke-font-settings — character spacing moves the COLUMN and leaves the INK.
//
// The invariant is the one macOS states at its tracking fold: tracking lands on
// the layout pitch and nowhere else, because the slot describes the glyph
// rather than the column it sits in. A slot that followed the pitch would
// stretch a glyph under positive tracking and clip one under negative, and both
// draw something — so a check that only asked "did the cell change" would pass
// on the implementation this exists to reject.
//
// Three rasterizers over one face, differing only in tracking. The pitch must
// move by the tracking in both directions; the face's own advance must not move
// at all.
int smokeFontSettings()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-font-settings: FAILED - no bundled primary face beside the binary\n");
        return 1;
    }

    const int pixelSize = deviceFontPixelSize();
    auto build = [&](int tracking) {
        return Ubiquitty::Linux::FreeTypeRasterizer(pixelSize, "JetBrains Mono", std::string(), std::string(),
            bundledPath, app().scale, app().lineSpacingPixels, tracking);
    };

    const Ubiquitty::Linux::FreeTypeRasterizer plain = build(0);
    if (!plain.ready()) {
        g_printerr("smoke-font-settings: FAILED - the bundled face did not load\n");
        return 1;
    }
    // Wide enough that a rounding difference cannot be mistaken for the effect,
    // and small enough that the tightened cell stays well clear of Core's floor.
    const int tracking = 3;
    const Ubiquitty::Linux::FreeTypeRasterizer wider = build(tracking);
    const Ubiquitty::Linux::FreeTypeRasterizer tighter = build(-tracking);

    const float basePitch = plain.cellMetrics().cellWidth;
    const double baseInk = plain.glyphOverhang().advanceWidth;
    g_print("  pitch %.1f px, ink advance %.1f px, tracking +/-%d\n", static_cast<double>(basePitch), baseInk, tracking);

    int failures = 0;
    // Ink first: a face measuring nothing would satisfy every equality below
    // while answering no question at all.
    if (!(baseInk > 0.0) || !(basePitch > 0.0f)) {
        g_printerr("smoke-font-settings: FAILED - the face reports no advance, so nothing here is a measurement\n");
        return 1;
    }

    if (wider.cellMetrics().cellWidth != basePitch + static_cast<float>(tracking)) {
        g_printerr("smoke-font-settings: FAILED - positive tracking moved the pitch to %.1f, expected %.1f\n",
            static_cast<double>(wider.cellMetrics().cellWidth), static_cast<double>(basePitch + static_cast<float>(tracking)));
        ++failures;
    }
    if (tighter.cellMetrics().cellWidth != basePitch - static_cast<float>(tracking)) {
        g_printerr("smoke-font-settings: FAILED - negative tracking moved the pitch to %.1f, expected %.1f\n",
            static_cast<double>(tighter.cellMetrics().cellWidth), static_cast<double>(basePitch - static_cast<float>(tracking)));
        ++failures;
    }
    // The half the pitch assertions cannot see: a slot that followed the pitch
    // passes both of them.
    if (wider.glyphOverhang().advanceWidth != baseInk || tighter.glyphOverhang().advanceWidth != baseInk) {
        g_printerr("smoke-font-settings: FAILED - tracking moved the ink advance (%.1f / %.1f, expected %.1f both)\n",
            wider.glyphOverhang().advanceWidth, tighter.glyphOverhang().advanceWidth, baseInk);
        ++failures;
    }

    // The bundled primary is the variable JetBrains Mono, so the wght axis is a
    // contract here rather than a capability to report: a static build put back
    // in its place would leave every weight setting resolving to one coordinate
    // while still rendering perfectly, which is the substitution nothing else
    // notices.
    if (!plain.hasWeightAxis()) {
        g_printerr("smoke-font-settings: FAILED - the bundled primary carries no wght axis,"
                   " so every weight setting resolves to one coordinate\n");
        return 1;
    }

    // Bold with `font.bold_weight` UNSET. Zero means "the face's own bold", and
    // a variable face has no bold member to fall back to — unplaced, the axis
    // stays where the upright sits and bold text draws identically to regular.
    // Counted in pixels rather than read off the resolved coordinate: the
    // question is whether the run came out bolder, and a coordinate can be
    // right while nothing places it on the face that draws.
    const int cellWidth = static_cast<int>(plain.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(plain.cellMetrics().cellHeight);
    std::vector<std::uint8_t> uprightCoverage(static_cast<std::size_t>(cellWidth) * cellHeight);
    std::vector<std::uint8_t> boldCoverage(uprightCoverage.size());
    auto inked = [](const std::vector<std::uint8_t>& coverage) {
        long total = 0;
        for (const std::uint8_t sample : coverage)
            total += sample;
        return total;
    };
    // A plain rectangle, so the difference is stem weight and not a serif
    // moving: 'l' carries a tail and 'M' carries diagonals.
    constexpr std::uint32_t bar = U'|';
    Ubiquitty::Linux::FreeTypeRasterizer weightProbe = build(0); // rasterizing mutates the face
    const bool didDrawUpright = weightProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, uprightCoverage.data());
    const bool didDrawBold = weightProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, boldCoverage.data());
    const long uprightInk = inked(uprightCoverage);
    const long boldInk = inked(boldCoverage);
    g_print("  '|' ink upright %ld, bold %ld (bold_weight unset)\n", uprightInk, boldInk);
    if (!didDrawUpright || !didDrawBold || uprightInk == 0) {
        g_printerr("smoke-font-settings: FAILED - the weight probe drew nothing, so it compares nothing\n");
        ++failures;
    } else if (boldInk <= uprightInk) {
        g_printerr("smoke-font-settings: FAILED - bold drew %ld ink against upright %ld,"
                   " so an unset bold_weight left the axis at the upright coordinate\n",
            boldInk, uprightInk);
        ++failures;
    }

    // `font.variations`, the axis list. Two questions, and the second is the
    // one a wiring can pass without answering.
    //
    // Only `wght` is exercised, because that is the only axis the bundled face
    // carries — its fvar has one. So a pass here says the parse, the fold over
    // the derived pair, the tag lookup and the clamp all work on ONE axis; it
    // says nothing about a face with several, where a per-axis range matters.
    auto buildVaried = [&](const char* variations) {
        return Ubiquitty::Linux::FreeTypeRasterizer(pixelSize, "JetBrains Mono", std::string(), std::string(),
            bundledPath, app().scale, app().lineSpacingPixels, 0, 0, 0, 0.0, variations);
    };
    std::vector<std::uint8_t> variedCoverage(uprightCoverage.size());
    std::vector<std::uint8_t> variedBoldCoverage(uprightCoverage.size());
    Ubiquitty::Linux::FreeTypeRasterizer variedProbe = buildVaried("wght=200");
    const bool didDrawVaried = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, variedCoverage.data());
    const bool didDrawVariedBold = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, variedBoldCoverage.data());
    const long variedInk = inked(variedCoverage);
    const long variedBoldInk = inked(variedBoldCoverage);
    Ubiquitty::Linux::FreeTypeRasterizer heavyProbe = buildVaried("wght=800");
    std::vector<std::uint8_t> heavyCoverage(uprightCoverage.size());
    std::vector<std::uint8_t> heavyBoldCoverage(uprightCoverage.size());
    const bool didDrawHeavy = heavyProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, heavyCoverage.data());
    const bool didDrawHeavyBold = heavyProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, heavyBoldCoverage.data());
    g_print("  '|' ink at variations \"wght=800\": upright %ld, bold %ld\n", inked(heavyCoverage), inked(heavyBoldCoverage));
    if (!didDrawHeavy || !didDrawHeavyBold || inked(heavyCoverage) == 0 || heavyCoverage != heavyBoldCoverage) {
        g_printerr("smoke-font-settings: FAILED - an unset bold weight did not draw at the body's heavy wght coordinate\n");
        ++failures;
    }
    g_print("  '|' ink at variations \"wght=200\": upright %ld, bold %ld\n", variedInk, variedBoldInk);
    if (!didDrawVaried || !didDrawVariedBold || variedInk == 0) {
        g_printerr("smoke-font-settings: FAILED - the variations probe drew nothing, so it compares nothing\n");
        ++failures;
    } else {
        // The axis reached the face: 200 is below the face's 400 default, so
        // the upright run is LIGHTER than the same run without a specification.
        // Compared against that run rather than against a constant, because a
        // specification that never arrived draws exactly it.
        if (variedInk >= uprightInk) {
            g_printerr("smoke-font-settings: FAILED - \"wght=200\" drew %ld ink against %ld unspecified,"
                       " so the axis list did not reach the face\n",
                variedInk, uprightInk);
            ++failures;
        }
        // The bold face drops a user `wght`. Its weight is what makes it bold,
        // and a specification naming the body's weight would otherwise pull it
        // down onto the body — leaving bold and regular one colour on a face
        // that can draw both. This is the half a wiring passes without: erase
        // nothing and the assertion above still holds.
        if (variedBoldInk <= variedInk) {
            g_printerr("smoke-font-settings: FAILED - bold drew %ld ink against upright %ld under"
                       " \"wght=200\", so the user axis reached the bold face and collapsed it\n",
                variedBoldInk, variedInk);
            ++failures;
        }
        // An SGR weight is the running program naming the weight of one run, and
        // it outranks a configured axis. The same specification is in force, so
        // a drop that only covered the bold face leaves this run drawn at 200.
        std::vector<std::uint8_t> sgrCoverage(uprightCoverage.size());
        const bool didDrawSGR = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 7, cellWidth, cellHeight, sgrCoverage.data());
        const long sgrInk = inked(sgrCoverage);
        g_print("  '|' ink at SGR weight 7 under the same \"wght=200\": %ld\n", sgrInk);
        if (!didDrawSGR || sgrInk <= variedInk) {
            g_printerr("smoke-font-settings: FAILED - SGR weight 7 drew %ld ink against %ld at the"
                       " configured axis, so a user wght outranked the running program\n",
                sgrInk, variedInk);
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-font-settings: FAILED - %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-font-settings: PASS (tracking moves the pitch both ways and leaves the ink advance alone;"
            " the body variation sets the unset bold floor and an SGR weight still overrides it)\n");
    return 0;
}

int smokeLigatureSheet()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-ligature-sheet: FAILED — no bundled primary face beside the binary\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        g_printerr("smoke-ligature-sheet: FAILED — the bundled face did not load a shaper\n");
        return 1;
    }

    const int cellWidth = static_cast<int>(bundled.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(bundled.cellMetrics().cellHeight);
    Ubiquitty::Rendering::LigatureSheet sheet(cellWidth, cellHeight, 0, 0, &bundled);
    if (!sheet.isUsable()) {
        g_printerr("smoke-ligature-sheet: FAILED — the sheet reports itself unusable\n");
        return 1;
    }
    g_print("  sheet %dx%d px, slot %dx%d, %d strip(s)\n", sheet.widthInPixels(), sheet.heightInPixels(),
        sheet.slotWidthInPixels(), sheet.slotHeightInPixels(), sheet.slotCapacity());

    int failures = 0;

    // A row Core's walk finds one run in — all four cells, not just the operator
    // pair. A run is a maximal stretch of same-shape eligible cells holding at
    // least one operator, so the letters join it rather than bracketing it;
    // context cells are what a stretch longer than ligatureMaxCells gets when it
    // is chunked, and nothing this short is chunked. Written here expecting the
    // other answer, and the run length said otherwise.
    const char* text = "x=>x";
    const int columns = static_cast<int>(std::strlen(text));
    std::vector<Ubiquitty::Rendering::LigatureCell> cells(static_cast<std::size_t>(columns));
    for (int i = 0; i < columns; ++i)
        cells[static_cast<std::size_t>(i)].codePoint = static_cast<std::uint32_t>(text[i]);
    std::vector<Ubiquitty::Rendering::LigatureRun> runs(static_cast<std::size_t>(columns));
    // Pre-dirtied so a sheet that failed to reset an uncovered column is caught:
    // the contract is that every entry is written, not only the covered ones.
    for (auto& run : runs)
        run.length = 99;

    sheet.beginFrame();
    sheet.shapeRow(cells, static_cast<float>(cellWidth), runs);

    // Two counts, because they answer different questions and only one of them
    // is "how many ligatures are in this row". A run is published into each
    // column it covers — the consumer indexes by column and takes its slice from
    // `column - startColumn` — so the number of non-empty entries is the number
    // of covered cells. The runs themselves are the entries that begin at their
    // own column. Counting cells and calling them runs is the reading this smoke
    // started with, and it made a working four-cell run look like four runs.
    int coveredCells = 0;
    int distinctRuns = 0;
    for (int column = 0; column < columns; ++column) {
        const auto& run = runs[static_cast<std::size_t>(column)];
        if (run.length == 99) {
            g_printerr("smoke-ligature-sheet: FAILED — column %d was left holding a previous run\n", column);
            ++failures;
        }
        if (run.length > 0) {
            ++coveredCells;
            if (run.startColumn == column) {
                ++distinctRuns;
                g_print("  run at column %d, %d cell(s), used %.0f of slot %.0f\n", run.startColumn, run.length,
                    static_cast<double>(run.usedWidthInAtlasPixels), static_cast<double>(run.slotWidthInAtlasPixels));
            }
            if (!run.strip.present) {
                g_printerr("smoke-ligature-sheet: FAILED — a covered run carries no strip\n");
                ++failures;
            }
            if (run.usedWidthInAtlasPixels <= 0.0f || run.usedWidthInAtlasPixels > run.slotWidthInAtlasPixels) {
                g_printerr("smoke-ligature-sheet: FAILED — the inked extent is not inside its slot\n");
                ++failures;
            }
        }
    }
    if (distinctRuns != 1) {
        g_printerr("smoke-ligature-sheet: FAILED — expected one run in \"%s\", found %d\n", text, distinctRuns);
        ++failures;
    }
    // The run covers every cell it claims. A run published only at its start
    // column passes every check above and still renders as one strip cell beside
    // three unligatured ones, which is the defect this line exists to catch.
    if (distinctRuns == 1 && coveredCells != runs[0].length) {
        g_printerr("smoke-ligature-sheet: FAILED — a %d-cell run reached %d column(s)\n",
            runs[0].length, coveredCells);
        ++failures;
    }

    // The strip carries ink, and it carries it in the slot the rect names. A run
    // reported with an empty slot would satisfy every field above.
    std::size_t inked = 0;
    for (std::uint8_t coverage : sheet.coverage())
        inked += coverage != 0 ? 1 : 0;
    const std::size_t sheetPixels = sheet.coverage().size();
    g_print("  %zu inked px of %zu across the sheet\n", inked, sheetPixels);
    if (inked == 0) {
        g_printerr("smoke-ligature-sheet: FAILED — the sheet holds no ink\n");
        ++failures;
    }
    // One strip drawn, so the rest of the sheet stays clear: writing a slot must
    // not reach into its neighbours, which a rendering of one run cannot show.
    const std::size_t slotPixels = static_cast<std::size_t>(sheet.slotWidthInPixels()) * static_cast<std::size_t>(sheet.slotHeightInPixels());
    if (inked >= slotPixels) {
        g_printerr("smoke-ligature-sheet: FAILED — %zu inked px exceeds one slot's %zu; a strip reached past its own\n",
            inked, slotPixels);
        ++failures;
    }

    // A stretch longer than ligatureMaxCells, which is the case the short row
    // above cannot reach: it chunks, the chunks carry context, and a chunk
    // reaches the cap. Three pieces of the contract that a four-cell run leaves
    // entirely unexercised: with only that row, every mutation to the chunk
    // seam passes.
    const int longColumns = Ubiquitty::Rendering::ligatureMaxCells + 8;
    std::vector<Ubiquitty::Rendering::LigatureCell> longCells(static_cast<std::size_t>(longColumns));
    for (int i = 0; i < longColumns; ++i)
        longCells[static_cast<std::size_t>(i)].codePoint = static_cast<std::uint32_t>((i % 2) == 0 ? '=' : '>');
    std::vector<Ubiquitty::Rendering::LigatureRun> longRuns(static_cast<std::size_t>(longColumns));

    sheet.beginFrame();
    sheet.shapeRow(longCells, static_cast<float>(cellWidth), longRuns);

    int chunks = 0;
    int longestChunk = 0;
    bool sawFullChunk = false;
    bool doesSlotSumHold = true;
    bool doesExtentSumHold = true;
    bool sawContextInset = false;
    // The two sums, spelled out here rather than read back through the helpers
    // that produce them, so this is a second witness and not the same
    // arithmetic agreeing with itself. The sheet was built with no margin.
    const float expectedSlotWidth = static_cast<float>(Ubiquitty::Rendering::stripSlotCells * cellWidth + 1);
    for (int column = 0; column < longColumns; ++column) {
        const auto& run = longRuns[static_cast<std::size_t>(column)];
        if (run.length <= 0 || run.startColumn != column)
            continue; // count the runs, not the cells each one covers
        ++chunks;
        longestChunk = std::max(longestChunk, run.length);
        if (run.length == Ubiquitty::Rendering::ligatureMaxCells)
            sawFullChunk = true;
        if (run.slotWidthInAtlasPixels != expectedSlotWidth)
            doesSlotSumHold = false;
        const float expectedExtent = static_cast<float>(std::ceil(run.length * static_cast<double>(cellWidth) + 1.0));
        if (run.usedWidthInAtlasPixels != expectedExtent)
            doesExtentSumHold = false;
        if (run.contextInsetLeftInAtlasPixels > 0.0f || run.contextInsetRightInAtlasPixels > 0.0f)
            sawContextInset = true;
    }
    g_print("  %d column(s) → %d chunk(s), longest %d, full chunk=%d, slot sum=%d, extent sum=%d, context inset=%d\n",
        longColumns, chunks, longestChunk, static_cast<int>(sawFullChunk), static_cast<int>(doesSlotSumHold),
        static_cast<int>(doesExtentSumHold), static_cast<int>(sawContextInset));
    if (chunks < 2) {
        g_printerr("smoke-ligature-sheet: FAILED — a %d-cell stretch produced %d chunk(s); it must split\n",
            longColumns, chunks);
        ++failures;
    }
    if (longestChunk > Ubiquitty::Rendering::ligatureMaxCells) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk of %d cells exceeds the %d-cell cap\n",
            longestChunk, Ubiquitty::Rendering::ligatureMaxCells);
        ++failures;
    }
    // The slot and the extent are two derivations of one geometry, and each is
    // held to its own sum. The slot is stripSlotCells cells plus the margins
    // plus one pixel, cut for the widest proportional run rather than for a
    // ligature chunk, which is capped at ligatureMaxCells and so fills half of
    // it at most. A chunk's extent is its own cells plus the margins plus one
    // pixel; Core clamps that to the slot, and the clamp cannot bind for a
    // ligature run — only a proportional run reaches the slot's edge. Either
    // sum drifting resamples every long run, which is what these catch. A
    // stretch of ligatureMaxCells + 8 cells must yield at least one full
    // chunk, or the extent sum was never checked at the cap.
    if (!sawFullChunk) {
        g_printerr("smoke-ligature-sheet: FAILED — no chunk reached the %d-cell cap, so the extent sum"
                   " was not checked at full length\n",
            Ubiquitty::Rendering::ligatureMaxCells);
        ++failures;
    }
    if (!doesSlotSumHold) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk's slot is not %d cells plus one pixel;"
                   " the slot derivation has drifted\n",
            Ubiquitty::Rendering::stripSlotCells);
        ++failures;
    }
    if (!doesExtentSumHold) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk's extent is not its cells plus one pixel;"
                   " the extent derivation has drifted\n");
        ++failures;
    }
    // A chunk seam has a neighbour on one side, so at least one chunk holds back
    // the margin the neighbour's context glyphs were drawn into. Without this the
    // seam paints those glyphs twice and reads bolder than the text around it.
    if (!sawContextInset) {
        g_printerr("smoke-ligature-sheet: FAILED — no chunk reported a context inset at its seam\n");
        ++failures;
    }

    if (failures) {
        g_printerr("smoke-ligature-sheet: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-ligature-sheet: PASS (one short run, a long stretch chunked with insets, each chunk's slot and extent their own sums,"
            " strips inside their own slots, uncovered columns reset)\n");
    return 0;
}

// --smoke-proportional-strip — a proportional run (Docs/proportional-text.md)
// shapes in fontconfig's sans-serif face through the Core strip sheet: the
// measurement answers, the strip draws ink inside its clip, a repeat hits the
// slot it drew, and an overflowing run is cut at its cells. What this image
// resolves `sans-serif` to is fontconfig's business — a proportional face
// where one is installed, the bundled mono face where not — so the smoke
// asserts the mechanism and not the metrics.
int smokeProportionalStrip()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-proportional-strip: FAILED — no bundled primary face beside the binary\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        g_printerr("smoke-proportional-strip: FAILED — the bundled face did not load a shaper\n");
        return 1;
    }
    const int cellWidth = static_cast<int>(bundled.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(bundled.cellMetrics().cellHeight);
    Ubiquitty::Rendering::LigatureSheet sheet(cellWidth, cellHeight, 2, 2, &bundled);
    if (!sheet.isUsable()) {
        g_printerr("smoke-proportional-strip: FAILED — the sheet reports itself unusable\n");
        return 1;
    }
    if (!sheet.hasProportionalFace()) {
        g_printerr("smoke-proportional-strip: FAILED — fontconfig resolved no sans-serif face\n");
        return 1;
    }
    int failures = 0;

    const std::uint32_t label[] = { 'R', 'e', 'm', 'i', 'n', 'd', ' ', 'm', 'e' };
    const std::span<const std::uint32_t> text(label);
    const int cells = sheet.proportionalRunCells(text, static_cast<float>(cellWidth));
    g_print("  \"Remind me\" measures %d cell(s) at a %dpx cell\n", cells, cellWidth);
    if (cells < 1) {
        g_printerr("smoke-proportional-strip: FAILED — the measurement answered %d\n", cells);
        ++failures;
    }

    sheet.beginFrame();
    const auto placement = sheet.proportionalStrip(text, cells + 2, 1, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    if (!placement.strip.present) {
        g_printerr("smoke-proportional-strip: FAILED — the strip is absent\n");
        return 1;
    }
    g_print("  strip %.0f px wide, quad from %.0f px past the pen\n",
        static_cast<double>(placement.widthInPixels), static_cast<double>(placement.leftInPixels));
    if (placement.widthInPixels <= 0.0f || placement.widthInPixels > static_cast<float>(sheet.slotWidthInPixels())) {
        g_printerr("smoke-proportional-strip: FAILED — the strip's width is outside its slot\n");
        ++failures;
    }
    // Right-aligned in two cells more than it needs, the quad moves right.
    if (placement.leftInPixels < 0.0f) {
        g_printerr("smoke-proportional-strip: FAILED — a right-aligned run with slack did not move right (%.0f)\n",
            static_cast<double>(placement.leftInPixels));
        ++failures;
    }
    std::size_t inked = 0;
    for (std::uint8_t coverage : sheet.coverage())
        inked += coverage != 0 ? 1 : 0;
    g_print("  %zu inked px across the sheet\n", inked);
    if (inked == 0) {
        g_printerr("smoke-proportional-strip: FAILED — the sheet holds no ink\n");
        ++failures;
    }
    // The same run again is the same slot, drawn once.
    sheet.clearDirty();
    const auto repeat = sheet.proportionalStrip(text, cells + 2, 1, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    if (!repeat.strip.present || repeat.strip.minUV.x != placement.strip.minUV.x || repeat.strip.minUV.y != placement.strip.minUV.y
        || sheet.isDirty()) {
        g_printerr("smoke-proportional-strip: FAILED — a repeated run did not hit its slot\n");
        ++failures;
    }
    // Overflow: one cell cannot hold the label, so the strip ends at that
    // cell — no margin — and the ink stays inside it.
    const auto cut = sheet.proportionalStrip(text, 1, 0, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    const float cutWidth = static_cast<float>(std::ceil(2 + cellWidth)) + 2.0f;
    if (!cut.strip.present || cut.widthInPixels != cutWidth) {
        g_printerr("smoke-proportional-strip: FAILED — an overflowing run's strip is %.0f px, not %.0f\n",
            static_cast<double>(cut.widthInPixels), static_cast<double>(cutWidth));
        ++failures;
    }
    if (cut.strip.present) {
        // Every texel of the cut strip's slot right of the clip is clear.
        const int slotColumn = static_cast<int>(cut.strip.minUV.x);
        const int slotRow = static_cast<int>(cut.strip.minUV.y);
        std::size_t spilled = 0;
        for (int y = 0; y < sheet.slotHeightInPixels(); ++y) {
            for (int x = 2 + cellWidth; x < sheet.slotWidthInPixels(); ++x) {
                const std::size_t index = static_cast<std::size_t>(slotRow + y) * static_cast<std::size_t>(sheet.widthInPixels())
                    + static_cast<std::size_t>(slotColumn + x);
                spilled += sheet.coverage()[index] != 0 ? 1 : 0;
            }
        }
        if (spilled != 0) {
            g_printerr("smoke-proportional-strip: FAILED — %zu texel(s) of an overflowing run reached past its cell\n", spilled);
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-proportional-strip: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-proportional-strip: PASS (measured, drawn with ink, cached on repeat, cut at the cell on overflow)\n");
    return 0;
}

// --smoke-oversized-grid — a grid past the device's largest frame is declined,
// not failed.
//
// The Vulkan frame is the model's grid at the renderer's cell, and a program
// sets the model's page length with DECSLPP: a page as tall as the model allows
// is seven bytes. At a large cell that frame is past the largest image any
// device makes, where creating one is invalid usage a driver need not report,
// and a frame the renderer fails costs the frontend its GPU for the rest of the
// run. So the renderer declines such a frame before making anything, the
// frontend draws it on the CPU raster, and the GPU draws the next grid that
// fits.
//
// On whatever device is present, it checks that a grid that fits draws and is
// not reported declined; that the page DECSLPP asks for past the device's limit
// is declined and reported so; that the CPU raster draws that same grid at its
// full height; that the next grid that fits draws on the same renderer; and
// that an export asked of the declined frame does not carry over to it.
int smokeOversizedGrid()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-oversized-grid: FAIL: {}", what);
            ok = false;
        }
    };
    setupFonts();
    constexpr int fittingRows = 24;
    activePane()->session->start(fittingRows, 4);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-oversized-grid: FAIL: no term\n");
        return 1;
    }
    // A cell large enough that a page past every device's limit is still a
    // page the model holds.
    Ubiquitty::Rendering::UnifontRasterizer rasterizer(8);
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasterizer);
    if (!renderer.init()) {
        g_print("smoke-oversized-grid: SKIP (Vulkan init failed: no device to decline a grid)\n");
        return smokeSkippedExitCode;
    }
    std::vector<std::uint8_t> frame;
    int width = 0;
    int height = 0;
    const bool didDrawFittingGrid = renderer.renderGrid(app().rasterContext, term, frame, width, height);
    check(didDrawFittingGrid, "a 24-row grid did not draw");
    check(!renderer.didDeclineOversizedGrid(), "a grid that fits was reported declined");
    const int cellHeight = didDrawFittingGrid ? height / fittingRows : 0;
    const std::uint32_t maxHeight = renderer.maxTargetExtent().height;
    const int oversizedRows = cellHeight > 0 ? static_cast<int>(maxHeight / static_cast<std::uint32_t>(cellHeight)) + 1 : 0;
    if (cellHeight <= 0 || oversizedRows > Ubiquitty::maxRows) {
        renderer.shutdown();
        g_printerr("smoke-oversized-grid: FAIL: no page the model holds is past this device's %u-pixel frame at this cell\n", maxHeight);
        return 1;
    }

    // Asked for as a program asks for it.
    Ubiquitty::processBytes(term, "\x1b[" + std::to_string(oversizedRows) + "t");
    check(term->rows == oversizedRows, "DECSLPP did not set the page length");
    if (renderer.canExportFrames())
        renderer.requestFrameExport();
    check(!renderer.renderGrid(app().rasterContext, term, frame, width, height), "a grid past the device's largest frame was drawn");
    check(renderer.didDeclineOversizedGrid(), "a grid past the device's largest frame was reported as a failure, which gives up the GPU for good");
    std::vector<std::uint8_t> cpuFrame;
    int cpuWidth = 0;
    int cpuHeight = 0;
    const bool didRasterize = app().rasterContext.rasterizeTerm(term, cpuFrame, cpuWidth, cpuHeight);
    check(didRasterize && cpuHeight == oversizedRows * cellHeight, "the CPU raster did not draw the declined grid at its full height");

    Ubiquitty::processBytes(term, "\x1b[" + std::to_string(fittingRows) + "t");
    const bool didDrawAfterDecline = renderer.renderGrid(app().rasterContext, term, frame, width, height);
    check(didDrawAfterDecline && height == fittingRows * cellHeight, "the renderer did not draw the next grid that fits");
    check(!renderer.didDeclineOversizedGrid(), "a frame that fits was reported declined after one that did not");
    if (const std::optional<Ubiquitty::Linux::VulkanRenderer::ExportedFrame> carried = renderer.takeExportedFrame()) {
        check(false, "the export asked of the declined frame carried over to the next one");
        ::close(carried->fileDescriptor);
        renderer.releaseExportedFrame(carried->releaseToken);
    }
    renderer.shutdown();
    Ubiquitty::PAL::logLine(stdout, "smoke-oversized-grid: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

int smokeDmabufImportFailure()
{
    bool didPass = true;
    const auto check = [&](bool didHold, std::string_view reason) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-dmabuf-import-failure: FAIL: {}", reason);
            didPass = false;
        }
    };
    setupFonts();
    activePane()->session->start(4, 16);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-dmabuf-import-failure: FAIL: no terminal\n");
        return 1;
    }
    Ubiquitty::Rendering::UnifontRasterizer rasterizer(1);
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    for (const int refusalIndex : { 1, 2, 3 }) {
        Ubiquitty::processBytes(term, "\x1b[?25l\x1b[2J\x1b[H\x1b[31mImport fallback");
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        if (!renderer.init() || !renderer.canExportFrames()) {
            renderer.shutdown();
            g_print("smoke-dmabuf-import-failure: SKIP (no Vulkan dma-buf exporter)\n");
            return smokeSkippedExitCode;
        }
        struct ImportProbe {
            int refusalIndex;
            int calls = 0;
            bool hasValidBuffer = true;
        } probe { .refusalIndex = refusalIndex };
        renderer.setFrameImportProbe([](void* context, int fileDescriptor, std::size_t length) {
            auto& probe = *static_cast<ImportProbe*>(context);
            probe.hasValidBuffer &= fileDescriptor >= 0 && length > 0;
            return ++probe.calls < probe.refusalIndex;
        },
            &probe);
        std::vector<std::uint8_t> reference;
        int referenceWidth = 0;
        int referenceHeight = 0;
        check(renderer.renderGrid(app().rasterContext, term, reference, referenceWidth, referenceHeight), "baseline readback failed");
        check(!reference.empty(), "baseline has no pixels");
        renderer.requestFrameExport();
        std::vector<std::uint8_t> frame;
        int width = 0;
        int height = 0;
        check(renderer.renderGrid(app().rasterContext, term, frame, width, height), "the refused frame did not draw");
        check(probe.calls == refusalIndex && probe.hasValidBuffer, "the requested import refusal was not exercised");
        check(!renderer.canExportFrames(), "export was not disabled after refusal");
        check(width == referenceWidth && height == referenceHeight && frame == reference, "the refused frame lost its pixels instead of reading back");
        const auto checkNoExport = [&] {
            if (const auto exported = renderer.takeExportedFrame()) {
                check(false, "an export escaped after import refusal");
                ::close(exported->fileDescriptor);
                renderer.releaseExportedFrame(exported->releaseToken);
            }
        };
        checkNoExport();
        Ubiquitty::processBytes(term, "\r\x1b[32mStill drawing!");
        renderer.requestFrameExport();
        check(renderer.renderGrid(app().rasterContext, term, frame, width, height), "the following frame did not draw");
        check(frame.size() == reference.size() && frame != reference, "the following frame did not show changed content");
        check(probe.calls == refusalIndex, "a later frame retried the refused import");
        checkNoExport();
        renderer.shutdown();
    }
    Ubiquitty::PAL::logLine(stdout, "smoke-dmabuf-import-failure: {} (refusal at each ring slot, same-frame readback, subsequent rendering)", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// A mixed grid/proportional frame through the dedicated Vulkan sheet. The
// instance count proves the per-glyph route was taken; byte equality against
// the software renderer proves its placement, phase, and coverage agree.
int smokeProportionalAtlas()
{
    setupFonts();
    activePane()->session->start(4, 48);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-proportional-atlas: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready() || !nativeRasterizer.hasProportionalFace()) {
        g_printerr("smoke-proportional-atlas: FAILED — no native proportional face\n");
        return 1;
    }
    int pixelFailures = 0;
    int modelFailures = 0;
    for (int arm = 0; arm < 2; ++arm) {
        bool hasDedicatedRoute = false;
        Ubiquitty::Rendering::GlyphRasterizer& rasterizer = arm == 0
            ? static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(nativeRasterizer)
            : static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(bitmapRasterizer);
        const char* armName = arm == 0 ? "native" : "bitmap";
        app().rasterContext.setGlyphRasterizer(rasterizer);
        app().rasterContext.setEmbeddedBitmapScale(arm);
        app().rasterContext.resetSoftwareRenderer();
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!renderer.init()) {
            g_printerr("smoke-proportional-atlas: FAILED — Vulkan init failed\n");
            return 1;
        }
        const float cellAdvance = static_cast<float>(Ubiquitty::Rendering::cellDimension(rasterizer.cellMetrics().cellWidth));
        const std::array<std::uint32_t, 7> pattern { 'W', 'W', 'i', 'i', ' ', 'j', ' ' };
        std::vector<Ubiquitty::ProportionalShapedGlyph> patternShape(pattern.size() * 2);
        const int patternCount = rasterizer.shapeProportionalRun(pattern,
            Ubiquitty::Rendering::FontFace::Regular, patternShape);
        float patternAdvance = 0.0f;
        for (int index = 0; index < patternCount; ++index) {
            patternAdvance += patternShape[static_cast<std::size_t>(index)].advanceInPixels;
        }
        if (patternAdvance <= 0.0f) {
            renderer.shutdown();
            g_printerr("smoke-proportional-atlas: FAILED — no proportional advances\n");
            return 1;
        }
        for (const int columns : { 48, 1024 }) {
            Ubiquitty::resize(*term, 4, columns);
            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            // The measurer reads the same sheet the frame uses, after its
            // geometry exists; the test never substitutes cell ownership.
            if (!renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight)) {
                renderer.shutdown();
                g_printerr("smoke-proportional-atlas: FAILED — initial frame failed\n");
                return 1;
            }
            activePane()->session->setTextMeasurer(
                [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t weight,
                    Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* advanceOut) {
                    auto& source = *static_cast<Ubiquitty::Linux::VulkanRenderer*>(context);
                    *advanceOut = source.proportionalCellAdvanceInPixels();
                    return source.shapeProportionalRun(
                        std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                        Ubiquitty::ProportionalRunStyle { .faceBits = faceBits, .weight = weight },
                        std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
                },
                &renderer);
            const int repetitions = std::max(1, static_cast<int>(0.85f * columns * cellAdvance / patternAdvance));
            std::string text;
            for (int index = 0; index < repetitions; ++index) {
                text += "WWii j ";
            }
            text += 'W';
            const std::vector<std::uint32_t> codePoints(text.begin(), text.end());
            std::vector<Ubiquitty::ProportionalShapedGlyph> shaped(codePoints.size() * 2);
            const int shapedCount = rasterizer.shapeProportionalRun(codePoints,
                Ubiquitty::Rendering::FontFace::Regular, shaped);
            shaped.resize(static_cast<std::size_t>(std::max(0, shapedCount)));
            std::vector<Ubiquitty::Rendering::ProportionalGlyphPlacement> placements(shaped.size());
            for (const std::uint8_t alignment : { 0, 2, 3 }) {
                Ubiquitty::processBytes(term, "\x1b[2J\x1b[H\x1b[0m\x1b[?25l");
                term->drawsSizedText = true;
                term->drawsProportionalText = true;
                const std::string content = "mono grid stays fixed\r\n\x1b]66;p=1:c=20;"
                    + std::string(48, 'i') + "\x07\r\n\x1b[38;2;237;157;43m\x1b]66;p=1:c="
                    + std::to_string(columns) + ":h=" + std::to_string(alignment) + ";" + text + "\x07";
                Ubiquitty::processBytes(term, content);
                const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
                const std::uint32_t proportionalInstances = renderer.lastFrameProportionalInstanceCount();
                hasDedicatedRoute |= proportionalInstances >= 48;
                const std::uint32_t stripInstances = renderer.lastFrameProportionalStripInstanceCount();
                std::vector<std::uint8_t> cpu;
                int cpuWidth = 0;
                int cpuHeight = 0;
                const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
                std::size_t differingPixels = 0;
                const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                    && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
                if (hasMatchingDimensions) {
                    for (std::size_t index = 0; index < cpu.size(); index += 4) {
                        differingPixels += std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    }
                }
                const auto layout = Ubiquitty::Rendering::layoutProportionalRun(shaped, codePoints,
                    columns, alignment, cellAdvance, placements);
                const bool hasLayout = layout.glyphCount > 0;
                const float tailX = hasLayout ? placements.back().xInPixels : 0.0f;
                const int expectedTailColumn = std::clamp(static_cast<int>(std::floor(tailX / cellAdvance)), 0, columns - 1);
                const bool hasCorrectCaret = hasLayout
                    && Ubiquitty::Rendering::proportionalRunCodePointAt(placements, layout,
                           static_cast<int>(codePoints.size()), tailX + 0.01)
                        == static_cast<int>(codePoints.size()) - 1;
                bool hasTailInk = false;
                if (hasMatchingDimensions && hasLayout && cpu.size() >= 4) {
                    const int firstX = std::clamp(static_cast<int>(std::floor(tailX)) - 2, 0, cpuWidth);
                    const int lastX = std::clamp(static_cast<int>(std::ceil(tailX + shaped.back().advanceInPixels)) + 2, 0, cpuWidth);
                    const int rowHeight = cpuHeight / 4;
                    const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                    for (int y = rowHeight * 2; y < rowHeight * 3; ++y) {
                        for (int x = firstX; x < lastX; ++x) {
                            const std::size_t pixel = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
                            hasTailInk |= std::memcmp(cpu.data() + pixel, background, 3) != 0;
                        }
                    }
                }
                bool hasFractionalPlacement = false;
                for (const auto& placement : placements) {
                    hasFractionalPlacement |= placement.xInPixels != std::floor(placement.xInPixels);
                }
                // The run's text rides its anchor, so the source reads back from one
                // cell; which cell the tail letter belongs to is the layout's answer
                // because the cells carry only the claim.
                const Ubiquitty::Cell& runAnchor = *term->grid->cellAt(Ubiquitty::Row(2), Ubiquitty::Column(0));
                const auto anchorText = Ubiquitty::runTextCodePoints(term, runAnchor);
                const std::vector<std::uint32_t> stored(anchorText.begin(), anchorText.end());
                std::vector<std::uint16_t> owners(codePoints.size());
                if (hasLayout) {
                    Ubiquitty::Rendering::proportionalRunCellOwners(shaped.empty()
                            ? std::span<const Ubiquitty::Rendering::ProportionalGlyphPlacement> {}
                            : std::span<const Ubiquitty::Rendering::ProportionalGlyphPlacement>(placements.data(), shaped.size()),
                        layout, static_cast<int>(codePoints.size()), columns, cellAdvance, owners);
                }
                const int storedTailColumn = (hasLayout && !owners.empty()) ? static_cast<int>(owners.back()) : -1;
                Ubiquitty::Selection::Session selection {};
                Ubiquitty::Selection::init(selection);
                Ubiquitty::Selection::selectAllText(selection, *term);
                const bool hasCompleteStoredSource = stored == codePoints;
                const std::string copied = Ubiquitty::Selection::copiedText(selection, *term);
                const bool hasCompleteCopy = copied.find(text) != std::string::npos;
                const bool hasCorrectOwner = storedTailColumn == expectedTailColumn;
                // The claim fills the row: the cursor stands on its last cell
                // with the wrap pending.
                const bool hasFixedGrid = term->screens.active->cursorX == columns - 1 && term->screens.active->wrapPending
                    && term->grid->rowMeta(2).has(Ubiquitty::RowFlag::Flowed)
                    && !term->grid->rowMeta(0).has(Ubiquitty::RowFlag::Flowed);
                const bool didPixelsPass = hasMatchingDimensions && differingPixels == 0
                    && stripInstances > 1 && hasFractionalPlacement && hasTailInk;
                pixelFailures += !didPixelsPass;
                modelFailures += !(hasCompleteStoredSource && hasCompleteCopy && hasCorrectCaret && hasCorrectOwner && hasFixedGrid);
                g_print("  %s columns=%d h=%u characters=%zu dedicated=%u tiles=%u differing=%zu fractional=%d"
                        " tail-ink=%d stored=%d copied=%d caret=%d owner=%d/%d grid=%d pixels=%s\n",
                    armName, columns, static_cast<unsigned>(alignment), codePoints.size(), proportionalInstances,
                    stripInstances, differingPixels, hasFractionalPlacement, hasTailInk, hasCompleteStoredSource, hasCompleteCopy, hasCorrectCaret,
                    storedTailColumn, expectedTailColumn, hasFixedGrid, didPixelsPass ? "PASS" : "FAIL");
                if (!hasCompleteCopy) {
                    const std::size_t rowStart = copied.find("\n", copied.find("\n") + 1) + 1;
                    const std::string copiedRow = copied.substr(rowStart);
                    std::size_t mismatch = 0;
                    while (mismatch < text.size() && mismatch < copiedRow.size() && text[mismatch] == copiedRow[mismatch]) {
                        ++mismatch;
                    }
                    g_print("    copied-row length=%zu first-mismatch=%zu expected-byte=%d actual-byte=%d\n",
                        copiedRow.size(), mismatch,
                        mismatch < text.size() ? static_cast<unsigned char>(text[mismatch]) : -1,
                        mismatch < copiedRow.size() ? static_cast<unsigned char>(copiedRow[mismatch]) : -1);
                }
            }
        }
        activePane()->session->setTextMeasurer(nullptr, nullptr);
        pixelFailures += !hasDedicatedRoute;
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-proportional-atlas: pixel failures=%d, source/caret/owner failures=%d -- %s\n",
        pixelFailures, modelFailures, pixelFailures == 0 && modelFailures == 0 ? "PASS" : "FAIL");
    return pixelFailures == 0 && modelFailures == 0 ? 0 : 1;
}

// Mono and proportional text on double-width and double-height rows, through
// Vulkan and software rendering, held to byte equality. Each arm includes
// native and fixed-raster faces so scaling samples the complete source rect
// while retaining the rasterizer's filtering policy.
int smokeDoubledRun()
{
    setupFonts();
    activePane()->session->start(3, 32);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-doubled-run: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready() || !nativeRasterizer.hasProportionalFace()) {
        g_printerr("smoke-doubled-run: FAILED — no native proportional face\n");
        return 1;
    }
    int failures = 0;
    for (int arm = 0; arm < 2; ++arm) {
        Ubiquitty::Rendering::GlyphRasterizer& rasterizer = arm == 0
            ? static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(nativeRasterizer)
            : static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(bitmapRasterizer);
        const char* armName = arm == 0 ? "native" : "bitmap";
        app().rasterContext.setGlyphRasterizer(rasterizer);
        app().rasterContext.setEmbeddedBitmapScale(arm);
        app().rasterContext.resetSoftwareRenderer();
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!renderer.init()) {
            g_printerr("smoke-doubled-run: FAILED — Vulkan init failed\n");
            return 1;
        }
        Ubiquitty::resize(*term, 3, 32);
        struct RunScene {
            std::uint8_t alignment;
            std::uint8_t rowAttribute;
            bool isProportional;
        };
        for (const RunScene scene : { RunScene { 0, 6, true }, RunScene { 2, 6, true }, RunScene { 0, 3, true },
                 RunScene { 2, 3, true }, RunScene { 0, 6, false }, RunScene { 0, 3, false } }) {
            const std::uint8_t alignment = scene.alignment;
            Ubiquitty::hardReset(*term);
            Ubiquitty::resize(*term, 3, 32);
            Ubiquitty::processBytes(term, "\x1b[?25l");
            term->drawsSizedText = true;
            term->drawsProportionalText = true;
            const std::string run = scene.isProportional
                ? "\x1b[38;2;237;157;43m\x1b]66;p=1:c=8:h=" + std::to_string(alignment) + ";Wiggle jA\x07\x1b[39m"
                : "\x1b[38;2;237;157;43mWgM8 jA\x1b[39m";
            std::string content = "\x1b#" + std::to_string(scene.rowAttribute) + run;
            if (scene.rowAttribute == 3) {
                content += "\r\n\x1b#4" + run;
            }
            content += scene.isProportional ? "\r\nplain \x1b]66;p=1:c=8;Wiggle jA\x07 ok" : "\r\nplain WgM8 jA";
            Ubiquitty::processBytes(term, content);
            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
            const std::uint32_t glyphInstances = renderer.lastFrameProportionalInstanceCount();
            const std::uint32_t stripInstances = renderer.lastFrameProportionalStripInstanceCount();
            // Which letters of a doubled row are a quad wider than the rect it
            // samples. Both faces cut each letter from the windows of its
            // doubled master, mapped 1:1 — the native face at the doubled em,
            // the bitmap tier from the strike the doubled size draws from —
            // and only the run's one space, which has no ink to window, is
            // still a stretched cell. Counted exactly, so a letter falling back
            // to the stretch fails here.
            const std::uint32_t stretchedInstances = renderer.lastFrameStretchedProportionalInstanceCount();
            const std::uint32_t doubledRows = scene.rowAttribute == 3 ? 2u : 1u;
            const std::uint32_t expectedStretched = doubledRows;
            std::vector<std::uint8_t> cpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
            const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
            std::size_t differingPixels = 0;
            std::size_t inkedPixelsOnTheDoubledRow = 0;
            if (hasMatchingDimensions) {
                const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                for (std::size_t index = 0; index < cpu.size(); index += 4) {
                    differingPixels += std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    if (index < cpu.size() / 3)
                        inkedPixelsOnTheDoubledRow += std::memcmp(cpu.data() + index, background, 3) != 0;
                }
            }
            const bool hasExpectedPopulation = scene.isProportional ? stretchedInstances == expectedStretched : glyphInstances == 0 && stripInstances == 0;
            const bool didPass = hasMatchingDimensions && differingPixels == 0
                && hasExpectedPopulation && inkedPixelsOnTheDoubledRow > 0;
            failures += !didPass;
            g_print("  %s %s row-attribute=%u h=%u glyphs=%u strips=%u stretched=%u doubled-row-ink=%zu differing=%zu %s\n", armName,
                scene.isProportional ? "proportional" : "mono", static_cast<unsigned>(scene.rowAttribute), static_cast<unsigned>(alignment), glyphInstances, stripInstances, stretchedInstances,
                inkedPixelsOnTheDoubledRow, differingPixels, didPass ? "PASS" : "FAIL");
        }
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-doubled-run: %d failure(s) -- %s\n", failures, failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}

// Scripted native glyphs shrink their quads while retaining the whole source
// rect. The software oracle checks both axes, and the bitmap arm requires its
// fixed raster geometry to stay unchanged.
int smokeScriptGlyphs()
{
    setupFonts();
    activePane()->session->start(6, 24);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-script-glyphs: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready()) {
        g_printerr("smoke-script-glyphs: no native face\n");
        return 1;
    }
    int failures = 0;
    for (int arm = 0; arm < 2; ++arm) {
        Ubiquitty::Rendering::GlyphRasterizer& rasterizer = arm == 0
            ? static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(nativeRasterizer)
            : static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(bitmapRasterizer);
        const char* armName = arm == 0 ? "native" : "bitmap";
        app().rasterContext.setGlyphRasterizer(rasterizer);
        app().rasterContext.setEmbeddedBitmapScale(arm);
        app().rasterContext.resetSoftwareRenderer();
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!renderer.init()) {
            g_printerr("smoke-script-glyphs: Vulkan init failed\n");
            return 1;
        }
        for (const int script : { 73, 74 }) {
            Ubiquitty::hardReset(*term);
            Ubiquitty::resize(*term, 6, 24);
            const std::string content = "\x1b[?25lplain WgM8\x1b[3;2H\x1b[38;2;237;157;43m\x1b["
                + std::to_string(script) + "mWgM8\x1b[5;2H漢界\x1b[75m\x1b[39m";
            Ubiquitty::processBytes(term, content);

            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
            const std::uint32_t scaledInstances = renderer.lastFrameScaledGlyphInstanceCount();
            std::vector<std::uint8_t> cpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
            const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
            std::size_t differingPixels = 0;
            std::size_t scriptedInkPixels = 0;
            if (hasMatchingDimensions && !cpu.empty()) {
                const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                for (std::size_t index = 0; index < cpu.size(); index += 4) {
                    const bool isDiffering = std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    // The first few differing pixels by position and both colours, so
                    // a failure names the arm that departs rather than a count.
                    if (isDiffering && differingPixels < 4) {
                        const std::size_t pixel = index / 4;
                        g_print("    differs at (%zu,%zu): cpu %u,%u,%u,%u gpu %u,%u,%u,%u\n", pixel % static_cast<std::size_t>(cpuWidth), pixel / static_cast<std::size_t>(cpuWidth),
                            cpu[index], cpu[index + 1], cpu[index + 2], cpu[index + 3], gpu[index], gpu[index + 1], gpu[index + 2], gpu[index + 3]);
                    }
                    differingPixels += isDiffering;
                    if (index >= cpu.size() / 6) {
                        scriptedInkPixels += std::memcmp(cpu.data() + index, background, 3) != 0;
                    }
                }
            }
            const bool hasExpectedGeometry = arm == 0 ? scaledInstances > 0 : scaledInstances == 0;
            const bool didPass = hasMatchingDimensions && differingPixels == 0
                && hasExpectedGeometry && scriptedInkPixels > 0;
            failures += !didPass;
            g_print("  %s SGR%d scaled=%u scripted-ink=%zu differing=%zu %s\n", armName, script,
                scaledInstances, scriptedInkPixels, differingPixels, didPass ? "PASS" : "FAIL");
        }
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-script-glyphs: %d failure(s) -- %s\n", failures, failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}

// --smoke-fileread — the kitty t=f reader is wired, gated, and hardened.
//
// The hardening itself is asserted portably by Tests/Platform/test_gated_file_read.cpp,
// which runs under ctest. It cannot run here: linking it needs Core's Terminal,
// and the container build leaves object files rather than an archive. So this
// asserts the part that is this frontend's — that the client is wired at all,
// that it obeys the pane's policy, and that the rules reach it through the
// shared implementation rather than being absent on this arm.
int smokeFileRead()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-fileread: FAILED — no term\n");
        return 1;
    }
    // Through the production wiring, not its own. A smoke that wired the client
    // itself would pass with the real path removed, which is exactly the state
    // this exists to keep out.
    wirePaneClients(*activePane(), *term);
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    if (!term->fileReadClient) {
        g_printerr("smoke-fileread: FAILED — wirePaneClients left no file-read client\n");
        return 1;
    }

    int failures = 0;
    const std::string directory = std::string(g_get_tmp_dir());
    // Named with the kitty t=t marker, which the delete below needs.
    const std::string path = directory + "/ubq-smoke-fileread-tty-graphics-protocol";
    const std::string payload = "PIXELS";
    ::unlink(path.c_str());
    if (!g_file_set_contents(path.c_str(), payload.c_str(), static_cast<gssize>(payload.size()), nullptr)) {
        g_printerr("smoke-fileread: FAILED — could not write the fixture at %s\n", path.c_str());
        return 1;
    }

    std::array<unsigned char, 64> buffer {};
    const int count = term->fileReadClient->readFile(path.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
    g_print("  local origin, t=f: %d byte(s)\n", count);
    if (count != static_cast<int>(payload.size()) || std::memcmp(buffer.data(), payload.data(), payload.size()) != 0) {
        g_printerr("smoke-fileread: FAILED — the wired client did not return the file's bytes\n");
        ++failures;
    }

    // The pane's policy denies a Remote principal, and the reader asks it. A
    // client wired but ungated would read this exactly as it read the line above.
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
    const int denied = term->fileReadClient->readFile(path.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
    g_print("  remote origin:     %d\n", denied);
    if (denied >= 0) {
        g_printerr("smoke-fileread: FAILED — a Remote origin was served\n");
        ++failures;
    }
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;

    // A symlink at the name is refused rather than followed: this is the shared
    // O_NOFOLLOW open answering, and it is here to show the rules reached this
    // arm rather than to re-test them.
    const std::string link = path + "-link";
    ::unlink(link.c_str());
    if (::symlink(path.c_str(), link.c_str()) == 0) {
        const int throughLink = term->fileReadClient->readFile(link.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
        g_print("  through a symlink: %d\n", throughLink);
        if (throughLink >= 0) {
            g_printerr("smoke-fileread: FAILED — a symlinked name was followed\n");
            ++failures;
        }
        ::unlink(link.c_str());
    } else {
        g_printerr("smoke-fileread: FAILED — could not plant the symlink fixture\n");
        ++failures;
    }

    // t=t deletes what it read, and only inside a temporary directory with the
    // marker in its name. The fixture is both, so this is the deleting arm.
    const int consumed = term->fileReadClient->readFile(path.c_str(), true, buffer.data(), static_cast<int>(buffer.size()));
    const bool isStillPresent = ::access(path.c_str(), F_OK) == 0;
    g_print("  t=t: %d byte(s), file %s\n", consumed, isStillPresent ? "kept" : "removed");
    if (consumed != static_cast<int>(payload.size()) || isStillPresent) {
        g_printerr("smoke-fileread: FAILED — t=t did not read then remove its temp file\n");
        ++failures;
    }
    ::unlink(path.c_str());

    // t=s, the shared-memory transport. Declared supported here, so the dispatch
    // will use it; the read primitive differs from the macOS arm's on purpose,
    // because a Linux shm object can shrink under a mapped copy and take SIGBUS
    // while a Darwin one cannot.
    if (!term->fileReadClient->supportsSharedMemoryTransport()) {
        g_printerr("smoke-fileread: FAILED — the shared-memory transport reports itself unsupported\n");
        ++failures;
    }
    const char* shmName = "/ubq-smoke-shm";
    ::shm_unlink(shmName);
    const int shmDescriptor = ::shm_open(shmName, O_CREAT | O_RDWR, 0600);
    if (shmDescriptor < 0 || ::ftruncate(shmDescriptor, static_cast<off_t>(payload.size())) != 0) {
        g_printerr("smoke-fileread: FAILED — could not stage a shared-memory fixture\n");
        ++failures;
    } else {
        void* mapping = ::mmap(nullptr, payload.size(), PROT_READ | PROT_WRITE, MAP_SHARED, shmDescriptor, 0);
        if (mapping != MAP_FAILED) {
            std::memcpy(mapping, payload.data(), payload.size());
            ::munmap(mapping, payload.size());
        }
        ::close(shmDescriptor);

        // Sized to the payload, the way the sequence calls it: an oversized
        // buffer would return the object's rounded size on one platform and its
        // exact size on the other.
        std::array<unsigned char, 6> shmBuffer {};
        const int shmCount = term->fileReadClient->readSharedMemory(shmName, false, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        g_print("  t=s: %d byte(s)\n", shmCount);
        if (shmCount != static_cast<int>(payload.size()) || std::memcmp(shmBuffer.data(), payload.data(), payload.size()) != 0) {
            g_printerr("smoke-fileread: FAILED — the shared-memory read did not return the object's bytes\n");
            ++failures;
        }

        // A buffer SMALLER than the object, which is what exercises the bound.
        // Without this the fixture and the buffer are the same size and a copy
        // bounded by the object rather than by the caller reads identically —
        // the mutation that removes the bound survived here until this case
        // existed, and on the other arm it only failed by overflowing a heap
        // buffer, which is a crash rather than a verdict.
        std::array<unsigned char, 3> shortBuffer {};
        const int shortCount = term->fileReadClient->readSharedMemory(shmName, false, shortBuffer.data(),
            static_cast<int>(shortBuffer.size()));
        g_print("  t=s into a 3-byte buffer: %d\n", shortCount);
        if (shortCount != 3 || std::memcmp(shortBuffer.data(), payload.data(), 3) != 0) {
            g_printerr("smoke-fileread: FAILED — the shared-memory read was not bounded by the buffer\n");
            ++failures;
        }

        // The same gate as the file transport, on the name rather than a
        // descriptor path — an shm object has none.
        term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
        const int shmDenied = term->fileReadClient->readSharedMemory(shmName, false, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        g_print("  t=s remote origin: %d\n", shmDenied);
        if (shmDenied >= 0) {
            g_printerr("smoke-fileread: FAILED — a Remote origin was served over shared memory\n");
            ++failures;
        }
        term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;

        // The delete flag removes the name, so a second open finds nothing.
        const int shmConsumed = term->fileReadClient->readSharedMemory(shmName, true, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        const int reopened = ::shm_open(shmName, O_RDONLY, 0);
        if (reopened >= 0)
            ::close(reopened);
        g_print("  t=s with unlink: %d byte(s), object %s\n", shmConsumed, reopened >= 0 ? "kept" : "removed");
        if (shmConsumed != static_cast<int>(payload.size()) || reopened >= 0) {
            g_printerr("smoke-fileread: FAILED — the unlink flag did not remove the object\n");
            ++failures;
        }
    }
    ::shm_unlink(shmName);

    term->fileReadClient = nullptr; // detach before the Ubiquitty::Terminal is disposed
    term->capabilityPolicy = nullptr;
    if (failures) {
        g_printerr("smoke-fileread: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-fileread: PASS (t=f wired and gated, symlink refused, t=t and t=s each read then removed)\n");
    return 0;
}

// --smoke-trigger — a configured trigger's action reaches the frontend and runs.
//
// Core's engine classifies a match and hands the action to Terminal::triggerClient;
// an unset client makes it drop the action silently. That was this frontend's
// state, and it is the shape a test has to be able to see: the rules parsed, the
// startup line said how many were installed, and nothing happened.
//
// Copy is the action asserted because it is the one observable headlessly —
// Clipboard::lastSetText is the same capture seam smoke-osc52 reads. Notify and
// set_title need a live GApplication and window; run_command and webhook are
// gated shut by default and are checked here for that rather than for firing.
int smokeTrigger()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-trigger: FAILED — no term\n");
        return 1;
    }
    // The fixture text carries no FAIL token on purpose: this smoke prints the
    // clipboard it captured, and check-linux-smokes reads a printed FAIL as a
    // verdict contradicting a zero exit. Test data that spells a verdict word
    // becomes one by the time it reaches the log.
    if (!Ubiquitty::Triggers::addRuleSpec(term, "BUILD BROKE: [a-z]+", "copy", Ubiquitty::CaseSensitivity::Sensitive)) {
        g_printerr("smoke-trigger: FAILED — the rule did not install\n");
        return 1;
    }
    (void)activePane()->session->installTriggerQueue();
    PaneDelivery triggerDelivery;
    triggerDelivery.hasTriggerMatches = true;

    int failures = 0;

    // A line the rule does not match, fed first: it establishes that what the
    // matching line writes came from the match rather than from any line
    // arriving at all.
    Ubiquitty::processBytes(term, std::string_view("all tests passed\r\n"));
    servicePaneQueues(*activePane(), triggerDelivery);
    const std::string afterMiss = Ubiquitty::Linux::Clipboard::lastSetText();
    g_print("  non-matching line -> clipboard \"%s\"\n", afterMiss.c_str());
    if (!afterMiss.empty()) {
        g_printerr("smoke-trigger: FAILED — a line matching no rule wrote the clipboard\n");
        ++failures;
    }

    Ubiquitty::processBytes(term, std::string_view("BUILD BROKE: linker\r\n"));
    servicePaneQueues(*activePane(), triggerDelivery);
    const std::string afterMatch = Ubiquitty::Linux::Clipboard::lastSetText();
    g_print("  matching line     -> clipboard \"%s\"\n", afterMatch.c_str());
    if (afterMatch.find("BUILD BROKE: linker") == std::string::npos) {
        g_printerr("smoke-trigger: FAILED — the copy action did not reach the clipboard\n");
        ++failures;
    }

    // The two gated actions, asserted closed rather than asserted firing. Both
    // default to false in Core, and a frontend that spawned or posted without
    // asking would pass every other check here.
    const bool didAllowRun = Ubiquitty::Preferences::Effective::allowRunCommand(Ubiquitty::Preferences::values());
    const bool didAllowWebhook = Ubiquitty::Preferences::Effective::allowWebhook(Ubiquitty::Preferences::values());
    g_print("  gates: allow_run_command=%s allow_webhook=%s\n",
        didAllowRun ? "true" : "false", didAllowWebhook ? "true" : "false");
    if (didAllowRun || didAllowWebhook) {
        g_printerr("smoke-trigger: FAILED — a gated action is open by default\n");
        ++failures;
    }

    if (failures) {
        g_printerr("smoke-trigger: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-trigger: PASS (copy reached the clipboard, a non-matching line did not,"
            " both gated actions closed)\n");
    return 0;
}

// --smoke-ligature-shaping — the text face shapes programming ligatures, and the
// oracle is substitution rather than glyph count.
//
// Counting glyphs is the wrong test and reports the wrong answer on the face
// this frontend actually ships. A monospace programming face keeps one glyph per
// cell so the grid keeps its columns: `=>` shapes to a blank plus one wide glyph
// anchored at the last cell, which is two glyphs from two cells, exactly as `ab`
// is. Measured on the bundled JetBrains Mono here: `=>` → [1751 blank][1006],
// `!==` → [1751][1751][873], and glyph 1751 has an empty `glyf` record.
//
// Those indices belong to the file, not to the family: the variable build that
// replaced the v2.304 statics renumbered them, and the previous three quoted
// here had gone stale without anything noticing — the assertion below is
// substitution against the character map, which survives a renumbering.
//
// So the question is whether shaping moved a glyph off what the character map
// alone would have given, and `ab` is the control: a run of letters no face
// ligates must come back untouched, or whatever the operators showed came from
// something other than the ligature table.
int smokeLigatureShaping()
{
    setupFonts();

    // Shaped against the bundled face rather than whatever fontconfig resolved
    // for "monospace". Those are different questions and only one of them is a
    // fact about this repository. Whether the machine has a ligature face
    // installed is a capability — this container answers DejaVu Sans Mono, which
    // ligates nothing, and that is not a defect. Whether the face shipped in
    // Resources/fonts carries the tables it is bundled to provide is a contract,
    // and it holds or it does not wherever this runs.
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-ligature-shaping: FAILED — no bundled primary face beside the binary,"
                   " so nothing was shaped\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready()) {
        g_printerr("smoke-ligature-shaping: FAILED — the bundled face at %s did not load\n",
            bundledPath.c_str());
        return 1;
    }
    auto& rasterizer = bundled;
    if (!rasterizer.canShapeText()) {
        g_printerr("smoke-ligature-shaping: FAILED — the bundled face loaded but carries no shaper\n");
        return 1;
    }

    struct Case {
        const char* text;
        bool expectSubstitution;
    };
    // The operators are the ones a programming face is bought for; the letters
    // are the control. A face without ligature tables fails the first four and
    // passes the last two, which is a different verdict from failing everything.
    const std::array<Case, 6> cases {
        Case { "=>", true },
        Case { "!==", true },
        Case { "->", true },
        Case { "===", true },
        Case { "ab", false },
        Case { "xy", false },
    };

    int failures = 0;
    for (const Case& probe : cases) {
        std::array<std::uint32_t, 8> codePoints {};
        const int count = static_cast<int>(std::strlen(probe.text));
        for (int i = 0; i < count; ++i)
            codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);

        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
        const int glyphs = rasterizer.shapeTextRun(
            std::span(codePoints).first(static_cast<std::size_t>(count)), 0, shaped);
        if (glyphs != count) {
            // Not a ligature verdict either way: this face maps a run of ASCII
            // one glyph per cell, so a different count means the run did not
            // shape the way every case here assumes.
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" shaped to %d glyphs from %d cells\n",
                probe.text, glyphs, count);
            ++failures;
            continue;
        }

        int substituted = 0;
        for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
            if (shaped[i].glyph != rasterizer.glyphIndexForCodePoint(codePoints[i]))
                ++substituted;
        }
        const bool sawSubstitution = substituted > 0;
        g_print("  %-4s %d glyph(s), %d substituted — %s\n", probe.text, glyphs, substituted,
            sawSubstitution ? "shaped" : "character map");
        if (sawSubstitution != probe.expectSubstitution) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" expected %s\n", probe.text,
                probe.expectSubstitution ? "a substitution" : "no substitution");
            ++failures;
        }
    }

    // The settings that reach the shaper, as a DIFFERENTIAL against the same
    // face. Everything above proves substitution happens; this pair proves the
    // configuration can stop it, which is a different claim and the one that
    // was false — all three `hb_shape` calls passed `nullptr, 0`, so
    // `[font] ligatures = false` and every `font.features` token were inert.
    //
    // A lone negative arm would be vacuous here: "no substitution" is also what
    // a face with no ligature tables answers, what a shaper that never ran
    // answers, and what a broken run answers. Only the difference between two
    // rasterizers one setting apart says the setting did it, and the arms above
    // are what make the positive half of that pair mean anything.
    {
        Ubiquitty::Linux::FreeTypeRasterizer suppressed(deviceFontPixelSize(), "JetBrains Mono",
            std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels,
            0, 0, 0, 0.0, std::string(), std::string(), Ubiquitty::Linux::Ligatures::Disabled);
        if (!suppressed.ready() || !suppressed.canShapeText()) {
            g_printerr("smoke-ligature-shaping: FAILED — the suppressed face did not load\n");
            ++failures;
        } else {
            int stillLigating = 0;
            for (const Case& probe : cases) {
                if (!probe.expectSubstitution)
                    continue; // the letters substitute under neither setting
                std::array<std::uint32_t, 8> codePoints {};
                const int count = static_cast<int>(std::strlen(probe.text));
                for (int i = 0; i < count; ++i)
                    codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);
                std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
                const int glyphs = suppressed.shapeTextRun(
                    std::span(codePoints).first(static_cast<std::size_t>(count)), 0, shaped);
                int substituted = 0;
                for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                    if (shaped[i].glyph != suppressed.glyphIndexForCodePoint(codePoints[i]))
                        ++substituted;
                }
                if (substituted > 0) {
                    g_printerr("smoke-ligature-shaping: FAILED — \"%s\" still ligated with ligatures off\n",
                        probe.text);
                    ++stillLigating;
                }
            }
            g_print("  ligatures=off: %d of 4 operator(s) still ligating\n", stillLigating);
            failures += stillLigating;
        }

        // A `font.features` token reaches the shaper too, and beats the toggle
        // rather than losing to it: the specification is the finer control and
        // is appended after the suppression, so a later entry wins in HarfBuzz.
        // Asserted rather than left to the ordering comment, because reversing
        // those two lines is a silent change nothing else here would notice.
        //
        // `+calt` rather than `+liga`, and the difference is measured rather
        // than assumed: against this face `+liga` and `+clig` each restore no
        // operator at all and `+calt` restores the arrow, so JetBrains Mono
        // carries `=>` in
        // `calt` alone. That is the whole reason the suppression above lists
        // three tags — turning off `liga` would have left every operator
        // drawing and looked like a fix.
        Ubiquitty::Linux::FreeTypeRasterizer overridden(deviceFontPixelSize(), "JetBrains Mono",
            std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels,
            0, 0, 0, 0.0, std::string(), std::string("+calt"), Ubiquitty::Linux::Ligatures::Disabled);
        if (overridden.ready() && overridden.canShapeText()) {
            const std::array<std::uint32_t, 2> arrow { '=', '>' };
            std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> shaped {};
            const int glyphs = overridden.shapeTextRun(arrow, 0, shaped);
            int substituted = 0;
            for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                if (shaped[i].glyph != overridden.glyphIndexForCodePoint(arrow[i]))
                    ++substituted;
            }
            g_print("  ligatures=off features=+calt: %d substituted (expect > 0)\n", substituted);
            if (substituted == 0) {
                g_printerr("smoke-ligature-shaping: FAILED — an explicit +calt lost to the toggle\n");
                ++failures;
            }
        }
    }

    // Shaping at a weight, which a bold run does. What this proves depends on
    // the face and the smoke says which: with a 'wght' axis it exercises the
    // re-shape after the axis moves, and without one applyWeightAxis returns
    // immediately, so it only asserts that asking for bold does not lose the
    // ligature. Neither font reachable in the CI container is variable —
    // JetBrains Mono Regular and DejaVu Sans Mono both report no axes — so this
    // is the second case here and the first only wherever a variable face is
    // installed. Stated rather than left for a reader to assume from a pass.
    const std::array<std::uint32_t, 2> arrow { '=', '>' };
    std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> bold {};
    const int boldGlyphs = rasterizer.shapeTextRun(arrow, 7, bold);
    int boldSubstituted = 0;
    for (std::size_t i = 0; i < static_cast<std::size_t>(boldGlyphs); ++i) {
        if (bold[i].glyph != rasterizer.glyphIndexForCodePoint(arrow[i]))
            ++boldSubstituted;
    }
    g_print("  => at weight 7: %d glyph(s), %d substituted (face %s a wght axis)\n",
        boldGlyphs, boldSubstituted, rasterizer.hasWeightAxis() ? "has" : "lacks");
    if (boldGlyphs != 2 || boldSubstituted == 0) {
        g_printerr("smoke-ligature-shaping: FAILED — \"=>\" lost its ligature when shaped bold\n");
        ++failures;
    }

    // A run longer than the caller's buffer shapes to nothing rather than to a
    // prefix. A prefix would be drawn as though it were the whole run, so the
    // cells past it would carry the wrong glyphs instead of no glyphs.
    std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 1> one {};
    const int refused = rasterizer.shapeTextRun(arrow, 0, one);
    g_print("  room for 1 glyph on a 2-cell run → %d\n", refused);
    if (refused != 0) {
        g_printerr("smoke-ligature-shaping: FAILED — a run too long for its output span returned %d rather than 0\n", refused);
        ++failures;
    }

    // The strip a run actually draws, against the same run drawn unligated.
    //
    // Both images come out of rasteriseShapedRun, so the drawing path, the
    // baseline, the pen walk and the clipping are identical and the only
    // difference between them is which glyph ids went in: the shaper's, or the
    // character map's for the same characters. That makes an inequality mean the
    // ligature and nothing else — a strip compared against per-cell rasters
    // would also differ wherever a font's bearings do not centre a glyph in its
    // advance, which is most of them.
    //
    // `ab` is the control on the pixels as well as on the glyph ids: a run that
    // substitutes nothing must draw the identical image both ways, or the
    // comparison is reporting something other than shaping.
    const int cellWidth = static_cast<int>(rasterizer.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(rasterizer.cellMetrics().cellHeight);
    struct StripCase {
        const char* text;
        bool shouldDifferInPixels;
    };
    const std::array<StripCase, 3> stripCases {
        StripCase { "=>", true },
        StripCase { "!==", true },
        StripCase { "ab", false },
    };
    for (const StripCase& probe : stripCases) {
        const int cells = static_cast<int>(std::strlen(probe.text));
        const int stripWidth = cellWidth * cells;
        std::array<std::uint32_t, 8> codePoints {};
        for (int i = 0; i < cells; ++i)
            codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);
        const auto run = std::span(codePoints).first(static_cast<std::size_t>(cells));

        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
        const int glyphs = rasterizer.shapeTextRun(run, 0, shaped);

        // The same run as the character map alone would draw it: same advances,
        // same pen, unsubstituted glyphs.
        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> unligated {};
        for (int i = 0; i < glyphs; ++i) {
            unligated[static_cast<std::size_t>(i)] = shaped[static_cast<std::size_t>(i)];
            unligated[static_cast<std::size_t>(i)].glyph = rasterizer.glyphIndexForCodePoint(run[static_cast<std::size_t>(i)]);
        }

        // Handed over dirty, on purpose. A fresh vector arrives zeroed, so a
        // rasteriser that never cleared its output would draw the right picture
        // on top of zeros and pass — and then leak the previous strip's pixels
        // in the atlas, which reuses one buffer across runs. Pre-filling means a
        // rasteriser that skips its clear fails here, which is what it will do
        // there. 0xFF rather than a random byte so a survivor reads as ink
        // everywhere rather than as noise.
        std::vector<std::uint8_t> ligatedPixels(static_cast<std::size_t>(stripWidth) * static_cast<std::size_t>(cellHeight), 0xFF);
        std::vector<std::uint8_t> plainPixels(ligatedPixels.size(), 0xFF);
        const bool didDrawLigated = rasterizer.rasteriseShapedRun(
            std::span(shaped).first(static_cast<std::size_t>(glyphs)), stripWidth, cellHeight, ligatedPixels);
        const bool didDrawPlain = rasterizer.rasteriseShapedRun(
            std::span(unligated).first(static_cast<std::size_t>(glyphs)), stripWidth, cellHeight, plainPixels);
        if (!didDrawLigated || !didDrawPlain) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" did not draw a %dx%d strip\n",
                probe.text, stripWidth, cellHeight);
            ++failures;
            continue;
        }

        const bool isDifferent = ligatedPixels != plainPixels;
        // Per cell, not just per strip. The comparison above holds the two
        // draws against each other, so anything wrong in the path they SHARE
        // cancels out and passes — a pen that never advanced would stack every
        // glyph on column zero in both images and still report them equal for
        // `ab` and different for `=>`. Counting ink per cell is the absolute
        // check that the run was laid out across its columns at all.
        std::size_t inked = 0;
        int emptyCells = 0;
        for (int cell = 0; cell < cells; ++cell) {
            std::size_t cellInk = 0;
            for (int y = 0; y < cellHeight; ++y) {
                for (int x = 0; x < cellWidth; ++x) {
                    const std::size_t at = static_cast<std::size_t>(y) * static_cast<std::size_t>(stripWidth)
                        + static_cast<std::size_t>(cell * cellWidth + x);
                    if (ligatedPixels[at] != 0)
                        ++cellInk;
                }
            }
            inked += cellInk;
            if (cellInk == 0)
                ++emptyCells;
        }
        g_print("  %-4s strip %dx%d: %zu inked px across %d cell(s), %d empty, %s the unligated draw\n",
            probe.text, stripWidth, cellHeight, inked, cells, emptyCells,
            isDifferent ? "differs from" : "matches");
        // Every case here draws visible ink in every one of its cells: the
        // letters because each inks its own, and the operators because the wide
        // ligature glyph reaches back across the cells its blanks left empty.
        // A blank strip would otherwise compare equal to a blank control and
        // pass the `ab` case having drawn nothing at all.
        if (emptyCells != 0) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" left %d of %d cell(s) with no ink\n",
                probe.text, emptyCells, cells);
            ++failures;
        }
        // And a strip is mostly background: glyphs are ink on empty space, and
        // no run of operators or letters covers even half of its box. Without
        // this a rasteriser that skipped its clear passed everything above —
        // the buffer arrives dirty, the stale content is UNIFORM, so the two
        // draws still differed for `=>` and still matched for `ab`, and every
        // cell still had ink. Saturation is what a leaked buffer looks like and
        // nothing else here could see it.
        const std::size_t stripPixels = ligatedPixels.size();
        if (inked * 2 >= stripPixels) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" inked %zu of %zu strip pixels;"
                       " a strip that is more ink than background was not cleared\n",
                probe.text, inked, stripPixels);
            ++failures;
        }
        if (isDifferent != probe.shouldDifferInPixels) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" expected the strip to %s\n", probe.text,
                probe.shouldDifferInPixels ? "differ from the unligated draw" : "match the unligated draw");
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-ligature-shaping: FAILED — %d case(s), face \"%s\"\n",
            failures, rasterizer.faceName());
        return 1;
    }
    g_print("smoke-ligature-shaping: PASS (%zu case(s) shaped against \"%s\", letters unshaped, an oversized run refused)\n",
        sizeof(cases) / sizeof(cases[0]), rasterizer.faceName());
    return 0;
}

// --smoke-ligature-render — the strip pass reaches the screen, and the picture
// it changes is the one it should.
//
// Two arms of the same renderer over the same terminal, differing only in
// whether a shaping face was injected. Byte equality between them is the wrong
// verdict either way, so this asserts three things one frame cannot:
//
//   1. the shaping arm drew strip instances at all — a pass that builds an
//      empty stream every frame is invisible in any comparison of pictures;
//   2. the two arms DIFFER on a row holding `!=` and `->`, which is the whole
//      claim: the strips are not merely drawn, they changed the glyphs;
//   3. the two arms AGREE on a row with no ligature in it. Without this the
//      difference in (2) is unattributed — two renderer instances can differ
//      for reasons that have nothing to do with shaping, and a test that only
//      demands "not equal" passes just as well when everything is wrong.
int smokeLigatureRender()
{
    setupFonts();
    // The BUNDLED face, not the host's. The default font on this container is
    // DejaVu Sans Mono, which has no programming ligatures: over it the strip
    // path and the per-glyph path agree by construction, and check (2) below
    // would be asserting something the font cannot do. JetBrains Mono ships
    // beside the binary and ligates, which is what makes the assertion real.
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: SKIP - no bundled primary face beside the binary");
        return 0;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: SKIP - the bundled face loaded no shaper");
        return 0;
    }

    // Row 0 ligates in a programming face; row 1 cannot ligate at all, and is
    // the control. Each row is one pen, so each is a single run.
    // Cleared and homed first. The arms share one pane, and `runtime.init` does
    // not empty the screen: without this each arm renders over the last one's
    // text, the arms differ everywhere, and the null control below is what says
    // so rather than the difference passing as a result about ligatures.
    const char content[] = "\x1b[2J\x1b[Ha != b -> c\r\nplain text row";

    // Which arm this is, named rather than passed as a bare true. The two calls
    // sit next to each other and differ in one argument; a bool there reads as
    // `renderOneArm(true, ...)` at the point where the reader most needs to know
    // which of the two they are looking at.
    enum class LigatureArm {
        Shaping,
        Control
    };
    auto renderOneArm = [&](LigatureArm arm, std::vector<uint8_t>& outRGBA, int& outWidth,
                            int& outHeight, std::uint32_t& outLigatureInstances) -> bool {
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(bundled);
        if (arm == LigatureArm::Shaping)
            renderer.setLigatureRasterizer(bundled);
        if (!renderer.init())
            return false;
        activePane()->session->start(startupRows, startupColumns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            renderer.shutdown();
            return false;
        }
        Ubiquitty::processBytes(term, std::string_view(content, sizeof(content) - 1));
        const bool didRender = renderer.renderGrid(app().rasterContext, term, outRGBA, outWidth, outHeight, 0, nullptr, nullptr);
        outLigatureInstances = renderer.lastFrameLigatureInstanceCount();
        renderer.shutdown();
        return didRender;
    };

    std::vector<uint8_t> shapedRGBA;
    std::vector<uint8_t> unshapedRGBA;
    int shapedWidth = 0, shapedHeight = 0, unshapedWidth = 0, unshapedHeight = 0;
    std::uint32_t shapedInstances = 0, unshapedInstances = 0;
    if (!renderOneArm(LigatureArm::Shaping, shapedRGBA, shapedWidth, shapedHeight, shapedInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the shaping arm rendered no frame");
    if (!renderOneArm(LigatureArm::Control, unshapedRGBA, unshapedWidth, unshapedHeight, unshapedInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the control arm rendered no frame");

    // The null: a third arm, identical to the second. Two renderer instances
    // over one shared rasterizer and one shared pane can differ for reasons that
    // have nothing to do with shaping — they take turns faulting glyphs into a
    // cache the rasterizer owns, and the pane carries whatever the previous arm
    // left on screen. Any difference this pair shows is the harness's, and it is
    // read as that rather than as evidence about ligatures.
    std::vector<uint8_t> nullRGBA;
    int nullWidth = 0, nullHeight = 0;
    std::uint32_t nullInstances = 0;
    if (!renderOneArm(LigatureArm::Control, nullRGBA, nullWidth, nullHeight, nullInstances))
        return skipNoGPUFrame("smoke-ligature-render", "the null arm rendered no frame");
    if (shapedWidth != unshapedWidth || shapedHeight != unshapedHeight) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the arms rendered different sizes ({}x{} vs {}x{})",
            shapedWidth, shapedHeight, unshapedWidth, unshapedHeight);
        return 1;
    }

    bool didEveryCheckPass = true;

    // (0) The null must be silent before anything else here means a thing.
    if (nullRGBA.size() == unshapedRGBA.size()) {
        int nullDifferences = 0;
        for (std::size_t i = 0; i < nullRGBA.size(); i += 4) {
            if (std::memcmp(nullRGBA.data() + i, unshapedRGBA.data() + i, 4) != 0)
                ++nullDifferences;
        }
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: null (control vs control) differs in {} pixel(s)", nullDifferences);
        if (nullDifferences != 0) {
            Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - two identical arms disagree, so no comparison below "
                                            "can be attributed to shaping");
            didEveryCheckPass = false;
        }
    }

    // (1) The pass ran.
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: strip instances shaped={} control={}", shapedInstances, unshapedInstances);
    if (shapedInstances == 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the shaping arm drew no strip instances");
        didEveryCheckPass = false;
    }
    if (unshapedInstances != 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the control arm drew {} strip instance(s) with no shaper",
            unshapedInstances);
        didEveryCheckPass = false;
    }

    // Rows in pixels. Row 0 holds the ligatures; row 1 is the control.
    const int cellHeight = shapedHeight / startupRows;
    auto countDifferingPixelsInRow = [&](int row) {
        int differing = 0;
        for (int y = row * cellHeight; y < (row + 1) * cellHeight && y < shapedHeight; ++y) {
            for (int x = 0; x < shapedWidth; ++x) {
                const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                               + static_cast<std::size_t>(x))
                    * 4;
                if (std::memcmp(shapedRGBA.data() + offset, unshapedRGBA.data() + offset, 4) != 0)
                    ++differing;
            }
        }
        return differing;
    };

    // (2) The ligature row changed.
    const int ligatureRowDifferences = countDifferingPixelsInRow(0);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: ligature row differs in {} pixel(s)", ligatureRowDifferences);
    if (ligatureRowDifferences == 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - `!=` and `->` drew identically with and without a shaper");
        didEveryCheckPass = false;
    }

    // (2b) The strips were DRAWN, not merely routed away from the mono path.
    //
    // This is the check that (2) cannot make, and the reason it exists is a
    // mutation that survived without it: deleting the ligature draw call
    // entirely still moved 443 pixels on the ligature row and still passed. A
    // covered cell carries no UV of its own — Core routes its glyph into the
    // strip stream — so a pass that builds instances and never draws them empties
    // those cells, and "the row changed" is just as true of a row that went
    // blank. Ink is what tells the two apart: the strips carry roughly the ink
    // the glyphs did, and a missing draw leaves the run's cells background.
    auto countInkedPixelsInRow = [&](const std::vector<uint8_t>& image, int row) {
        int inked = 0;
        for (int y = row * cellHeight; y < (row + 1) * cellHeight && y < shapedHeight; ++y) {
            // The row's own background, read from its last column, which no
            // text reaches. Sampled per row rather than fixed as a constant,
            // because a theme or a selection changes it per row and a constant
            // would count a recoloured background as ink.
            const std::size_t backgroundOffset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                                     + static_cast<std::size_t>(shapedWidth - 1))
                * 4;
            for (int x = 0; x < shapedWidth; ++x) {
                const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(shapedWidth)
                                               + static_cast<std::size_t>(x))
                    * 4;
                if (std::memcmp(image.data() + offset, image.data() + backgroundOffset, 4) != 0)
                    ++inked;
            }
        }
        return inked;
    };
    const int shapedInk = countInkedPixelsInRow(shapedRGBA, 0);
    const int controlInk = countInkedPixelsInRow(unshapedRGBA, 0);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: ligature row ink shaped={} control={}", shapedInk, controlInk);
    // Half the control's ink is a floor, not a target: a ligature is a different
    // drawing and legitimately carries somewhat more or less ink than the
    // characters it replaced. What it cannot do is approach zero, which is what
    // the run's cells hold when nothing draws them.
    if (shapedInk * 2 < controlInk) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - the ligature row lost its ink ({} vs {}), so the "
                                        "strips were routed off the mono path and never drawn",
            shapedInk, controlInk);
        didEveryCheckPass = false;
    }

    // (3) The control row did not.
    const int plainRowDifferences = countDifferingPixelsInRow(1);
    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: plain row differs in {} pixel(s)", plainRowDifferences);
    if (plainRowDifferences != 0) {
        Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: FAILED - a row with no ligature in it changed too, so the "
                                        "difference above is not attributable to shaping");
        didEveryCheckPass = false;
    }

    Ubiquitty::PAL::logLine(stdout, "smoke-ligature-render: {}", didEveryCheckPass ? "PASS" : "FAILED");
    return didEveryCheckPass ? 0 : 1;
}

// --smoke-gridcache — the retained-grid CPU<->GPU oracle, across frames. The
// single-frame smokes cannot see the reuse lane: the first frame over any
// terminal is full by construction, and only a second render of one grid
// — after a small edit, then after a scroll — takes the Load path and the
// scroll band copies. The CPU rasterizer re-reads the whole screen on every
// call, so byte-equality against it holds the retained target to its
// invariant: reuse changes the work, never the result. partialFrameCount() is
// the coverage bound — without it a verdict that rots to never-reuse turns
// this into a copy test that cannot fail.
int smokeGridCache()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-gridcache", "vulkan init failed");

    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-gridcache: no term\n");
        renderer.shutdown();
        return 1;
    }
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));

    struct Phase {
        const char* name;
        const char* bytes; // fed before the frame; "" feeds nothing
        std::uint64_t partialFramesAfter; // the coverage bound after this frame
    };
    const Phase phases[] = {
        { "full", "", 0 },
        // Two edits dirty two rows apart, one carrying an underline, so the
        // Load frame repaints rules as well as glyphs.
        { "edit", "\x1b[5;10Hedited \x1b[4mrow\x1b[0m\x1b[12;1Hsecond edited row", 1 },
        // No input at all: the frame Loads and repaints only the cursor rows.
        // What this frame shows is what the PAIR holds — a defect visible
        // here survived into the retained image; one visible only in the
        // frame before was transient to that encode.
        { "idle", "", 2 },
        // Newlines at the bottom row scroll the screen: the frame must copy
        // the band plan between the pair and repaint the exposed rows.
        { "scroll", "\x1b[24;1Hbottom\r\ntail one\r\ntail two", 3 },
    };

    bool didAllPhasesPass = true;
    std::string failedPhases;
    for (const Phase& phase : phases) {
        if (phase.bytes[0] != '\0')
            Ubiquitty::processBytes(term, phase.bytes);
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        // GPU first: the two arms share the injected rasterizer, and the CPU
        // render faulting a glyph first must not be able to change what the
        // GPU arm builds — running the subject before the oracle is what
        // makes a shared-cache contamination visible as a phase difference.
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRenderCPUFrame && didRenderGPUFrame;
        const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
        const bool didTakeExpectedLane = !didCompareGPU || renderer.partialFrameCount() == phase.partialFramesAfter;
        g_print("smoke-gridcache: %-6s CPU==GPU %s, partial frames %llu (want %llu)\n", phase.name,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)),
            static_cast<unsigned long long>(renderer.partialFrameCount()),
            static_cast<unsigned long long>(phase.partialFramesAfter));
        if (didCompareGPU && !same) {
            // Name the disagreement in cells, not just bytes: the first
            // differing pixel's row is usually the whole diagnosis for a
            // damage-tracking defect, and the PNG pair is the eyeball check.
            std::size_t firstDiffer = 0;
            while (firstDiffer < cpu.size() && firstDiffer < gpu.size() && cpu[firstDiffer] == gpu[firstDiffer])
                ++firstDiffer;
            const int pixelX = cpuWidth > 0 ? static_cast<int>((firstDiffer / 4) % static_cast<std::size_t>(cpuWidth)) : 0;
            const int pixelY = cpuWidth > 0 ? static_cast<int>((firstDiffer / 4) / static_cast<std::size_t>(cpuWidth)) : 0;
            int differingPixels = 0;
            for (std::size_t i = 0; i + 3 < cpu.size() && i + 3 < gpu.size(); i += 4)
                differingPixels += std::memcmp(cpu.data() + i, gpu.data() + i, 4) != 0 ? 1 : 0;
            g_print("smoke-gridcache: %s first differing pixel (%d,%d), %d pixel(s) differ\n", phase.name, pixelX, pixelY, differingPixels);
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", cpu), { "gpu", gpu } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { cpuWidth, cpuHeight });
                const std::string path = std::string("/tmp/gridcache_") + phase.name + "_" + label + ".png";
                if (FILE* f = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), f);
                    std::fclose(f);
                    g_print("smoke-gridcache: wrote %s\n", path.c_str());
                }
            }
        }
        if (!(same && didTakeExpectedLane)) {
            didAllPhasesPass = false;
            failedPhases += failedPhases.empty() ? phase.name : std::string(", ") + phase.name;
        }
    }
    renderer.shutdown();

    // The control that separates "the retained encode broke it" from "this
    // content never rendered right": the same final terminal through a FRESH
    // renderer is a first frame — full build, no pair, no Load — over the
    // same glyph population the partial frames just failed on.
    {
        Ubiquitty::Linux::VulkanRenderer freshRenderer;
        freshRenderer.setGlyphRasterizer(currentRasterizer());
        freshRenderer.setLigatureRasterizer(currentRasterizer());
        if (freshRenderer.init()) {
            std::vector<uint8_t> cpu;
            std::vector<uint8_t> gpu;
            int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
            const bool didRenderGPUFrame = freshRenderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
            const bool didCompareGPU = didRenderCPUFrame && didRenderGPUFrame;
            const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
            g_print("smoke-gridcache: fresh-full control CPU==GPU %s\n",
                oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)));
            if (didCompareGPU && !same) {
                didAllPhasesPass = false;
                failedPhases += failedPhases.empty() ? "fresh-full" : std::string(", ") + "fresh-full";
            }
            freshRenderer.shutdown();
        }
    }

    if (didAllPhasesPass)
        g_print("smoke-gridcache: PASS\n");
    else
        g_print("smoke-gridcache: FAILED phase(s): %s\n", failedPhases.c_str());
    return didAllPhasesPass ? 0 : 1;
}

// --smoke-gridcache-stress — the retained grid against a full re-render, over
// every event that changes pixels without necessarily changing a cell.
//
// The single-feed smoke above holds three frames to the CPU oracle; this one
// holds a long feed, a moving search match, a selection drawn behind the text,
// and two terminals of one size taking turns on one renderer, which is how the
// window renders a split. Each frame is held to the same frame from a fresh
// renderer, which has no target to keep and builds every row: the cache-off
// picture, from the same encode, so a difference is the retained lane's and
// nothing else's. Run under UBIQUITTY_GRID_CACHE=0 as well: the same frames
// must match with no partial frame taken, which is the switch reaching this arm.
int smokeGridCacheStress()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-gridcache-stress", "vulkan init failed");
    constexpr int rows = 10;
    constexpr int columns = 40;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    auto other = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*other, rows, columns);
    if (!term) {
        g_printerr("smoke-gridcache-stress: no term\n");
        renderer.shutdown();
        return 1;
    }
    const auto screenOfText = [](const char* label) {
        std::string text;
        for (int row = 1; row <= rows; ++row)
            text += std::format("\x1b[{};1H{} {} \x1b[31mred\x1b[0m \x1b[44mblue\x1b[0m gjpqy -> != ===", row, label, row);
        return text;
    };

    bool didEveryFramePass = true;
    std::string failedFrames;
    int frameCount = 0;
    // One frame: the subject, then the oracle. The oracle drains nothing the
    // subject has not, so it cannot move the subject's baseline.
    const auto frame = [&](const char* name, Ubiquitty::Terminal* subject, int viewOffset, Ubiquitty::Selection::Session* selection) {
        std::vector<uint8_t> retained;
        std::vector<uint8_t> full;
        int retainedWidth = 0, retainedHeight = 0, fullWidth = 0, fullHeight = 0;
        const bool didRenderRetained = renderer.renderGrid(app().rasterContext, subject, retained, retainedWidth, retainedHeight, viewOffset, selection, nullptr);
        Ubiquitty::Linux::VulkanRenderer fresh;
        fresh.setGlyphRasterizer(currentRasterizer());
        fresh.setLigatureRasterizer(currentRasterizer());
        const bool didRenderFull = fresh.init()
            && fresh.renderGrid(app().rasterContext, subject, full, fullWidth, fullHeight, viewOffset, selection, nullptr);
        fresh.shutdown();
        ++frameCount;
        const bool same = didRenderRetained && didRenderFull && retainedWidth == fullWidth && retainedHeight == fullHeight && retained == full;
        if (same)
            return;
        int differingPixels = 0;
        int firstRow = -1;
        for (std::size_t i = 0; i + 3 < retained.size() && i + 3 < full.size(); i += 4) {
            if (std::memcmp(retained.data() + i, full.data() + i, 4) == 0)
                continue;
            if (firstRow < 0 && fullWidth > 0)
                firstRow = static_cast<int>((i / 4) / static_cast<std::size_t>(fullWidth));
            ++differingPixels;
        }
        g_print("smoke-gridcache-stress: %-28s retained!=full, %d pixel(s) differ from y %d (partial frames so far %llu)\n", name,
            differingPixels, firstRow, static_cast<unsigned long long>(renderer.partialFrameCount()));
        // The pair for the eye, named by frame number, as the smoke above
        // writes its own.
        if (retainedWidth == fullWidth && retainedHeight == fullHeight && !full.empty()) {
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("retained", retained), { "full", full } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { fullWidth, fullHeight });
                const std::string path = std::format("/tmp/gridcache_stress_{:02}_{}.png", frameCount, label);
                if (FILE* file = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), file);
                    std::fclose(file);
                }
            }
        }
        didEveryFramePass = false;
        failedFrames += failedFrames.empty() ? name : std::string(", ") + name;
    };

    struct Step {
        const char* name;
        std::string bytes;
        int viewOffset = 0;
    };
    const Step steps[] = {
        { "first", screenOfText("row") },
        { "settle", "" },
        { "edit", "\x1b[3;5Hedited" },
        { "scroll", std::format("\x1b[{};1H\r\nscrolled one\r\nscrolled two", rows) },
        { "margined scroll up", "\x1b[3;6r\x1b[6;1H\r\nin region\r\nagain\x1b[r" },
        { "margined scroll down", "\x1b[2;5r\x1b[2;1H\x1bM\x1bMdown\x1b[r" },
        { "SU", "\x1b[2S" },
        { "SD", "\x1b[1T" },
        { "IL", "\x1b[4;1H\x1b[2L" },
        { "DL", "\x1b[3;1H\x1b[1M" },
        { "EL", "\x1b[2;3H\x1b[K" },
        { "ICH DCH", "\x1b[6;2H\x1b[3@\x1b[7;2H\x1b[2P" },
        { "combining above", "\x1b[9;1He\xcc\x81\xcc\x82\xcc\x83\xcc\x84 a\xcc\x8a\xcc\x8b" },
        { "combining cleared", "\x1b[9;1H\x1b[2K" },
        { "OSC 4", "\x1b]4;1;rgb:00/ff/00\x07" },
        { "OSC 10", "\x1b]10;rgb:ff/ff/00\x07" },
        { "OSC 11", "\x1b]11;rgb:20/00/40\x07" },
        { "OSC reset", "\x1b]104\x07\x1b]110\x07\x1b]111\x07" },
        { "DECSCNM on", "\x1b[?5h" },
        { "DECSCNM off", "\x1b[?5l" },
        { "DECDWL", "\x1b[2;1H\x1b#6" },
        { "DECDHL", "\x1b[4;1H\x1b#3\x1b[5;1H\x1b#4" },
        { "DECSWL", "\x1b[2;1H\x1b#5\x1b[4;1H\x1b#5\x1b[5;1H\x1b#5" },
        { "DECALN", "\x1b#8" },
        { "refill", screenOfText("row") },
        { "alternate", "\x1b[?1049h\x1b[H\x1b[2Jalternate" },
        { "primary", "\x1b[?1049l" },
        { "wide", "\x1b[6;1H\xe4\xb8\x96\xe7\x95\x8c x" },
        { "sync", "\x1b[?2026h\x1b[2;1Hsync body\x1b[?2026l" },
        { "RIS", "\x1b"
                 "c" },
        { "refill after RIS", screenOfText("row") },
        { "red background", "\x1b]11;rgb:80/00/00\x07" },
        { "RIS to blue", "\x1b"
                         "c"
                         "\x1b]11;rgb:00/00/80\x07" },
        { "refill on blue", screenOfText("row") },
        { "scrolled back", "\r\nmore\r\nlines\r\nhistory", 2 },
        { "tail", "", 0 },
        { "idle", "" },
    };
    for (const Step& step : steps) {
        if (!step.bytes.empty())
            Ubiquitty::processBytes(term, step.bytes);
        frame(step.name, term, step.viewOffset, nullptr);
    }
    const std::uint64_t partialAfterFeed = renderer.partialFrameCount();

    // The focused search match is drawn into the cells it covers. Moving it
    // to the next match changes no cell, so only the plan can owe its rows.
    Ubiquitty::processBytes(term, screenOfText("find"));
    frame("find text", term, 0, nullptr);
    frame("find settle", term, 0, nullptr);
    const auto search = activePane()->session->searchScrollbackAndWait("blue", Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Literal, Ubiquitty::CaseSensitivity::Insensitive);
    if (search.isComplete && !search.isPatternInvalid) {
        frame("search opened", term, 0, nullptr);
        for (const char* name : { "search next 1", "search next 2", "search next 3" }) {
            (void)activePane()->session->stepSearchMatch(Ubiquitty::Runtime::TerminalSession::SearchStep::Forward);
            frame(name, term, 0, nullptr);
        }
        activePane()->session->clearScrollbackSearch();
        frame("search closed", term, 0, nullptr);
    } else
        didEveryFramePass = false;

    // A selection drawn behind the text: the host named its colour (OSC 17),
    // so the fill is each selected cell's background rather than an overlay.
    Ubiquitty::processBytes(term, "\x1b]17;rgb:00/80/ff\x07");
    frame("selection colour", term, 0, nullptr);
    Ubiquitty::Selection::Session selection;
    Ubiquitty::Selection::init(selection);
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(selection, *term, 2, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(selection, *term, 4, 6, 0);
    frame("selection drawn", term, 0, &selection);
    Ubiquitty::Selection::dragGesture(selection, *term, 6, 12, 0);
    frame("selection grown", term, 0, &selection);
    Ubiquitty::Selection::dragGesture(selection, *term, 3, 2, 0);
    frame("selection shrunk", term, 0, &selection);
    Ubiquitty::Selection::init(selection);
    frame("selection cleared", term, 0, &selection);

    // Two panes of one size on the window's one renderer, in turns. Each has
    // its own grid and its own damage; the target holds whichever drew last.
    // Two fresh panes fed alike count their damage alike, so each one's
    // generation meets the one the other's last frame left in the baseline.
    auto left = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*left, rows, columns);
    Ubiquitty::processBytes(left.get(), screenOfText("left"));
    Ubiquitty::processBytes(other.get(), screenOfText("right"));
    frame("pane A", left.get(), 0, nullptr);
    frame("pane B", other.get(), 0, nullptr);
    for (int turn = 0; turn < 3; ++turn) {
        Ubiquitty::processBytes(left.get(), std::format("\x1b[{};1Hleft turn {}", turn + 2, turn));
        frame("pane A turn", left.get(), 0, nullptr);
        Ubiquitty::processBytes(other.get(), std::format("\x1b[{};1Hright turn {}", turn + 5, turn));
        frame("pane B turn", other.get(), 0, nullptr);
        frame("pane A idle", left.get(), 0, nullptr);
        frame("pane B idle", other.get(), 0, nullptr);
    }
    renderer.shutdown();

    // The coverage bound, and the switch: with the cache on the feed took the
    // partial lane, with it off no frame did.
    const bool isCacheEnabled = Ubiquitty::Rendering::isRetainedGridCacheEnabled();
    const bool didTakeExpectedLane = isCacheEnabled ? partialAfterFeed > 0 : renderer.partialFrameCount() == 0;
    g_print("smoke-gridcache-stress: %d frames, cache %s, partial frames %llu (after the feed %llu)\n", frameCount,
        isCacheEnabled ? "on" : "off", static_cast<unsigned long long>(renderer.partialFrameCount()),
        static_cast<unsigned long long>(partialAfterFeed));
    if (!didTakeExpectedLane) {
        g_print("smoke-gridcache-stress: FAILED - the partial lane %s\n", isCacheEnabled ? "was never taken" : "was taken with the cache off");
        didEveryFramePass = false;
    }
    if (didEveryFramePass)
        g_print("smoke-gridcache-stress: PASS\n");
    else
        g_print("smoke-gridcache-stress: FAILED frame(s): %s\n", failedFrames.c_str());
    return didEveryFramePass ? 0 : 1;
}

// --bench-gridcache-scroll [frames] — what the retained grid keeps while
// ligature-heavy source code scrolls.
//
// One line is written at the bottom row per frame, so every frame scrolls the
// screen by one row and repaints the exposed one: the band-scroll lane, over
// rows full of ligature strips. Prints the share of frames that took the
// partial lane and the GPU arm's frame time, with the machine it ran on, so a
// before/after pair of runs can be laid side by side. The workload is Core's
// (RenderProfile::ligatureCodeLine), the same lines the macOS bench writes.
int benchGridCacheScroll(int frames)
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("bench-gridcache-scroll", "vulkan init failed");
    constexpr int rows = 40;
    constexpr int columns = 120;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        renderer.shutdown();
        return 1;
    }
    std::string fill;
    for (int line = 0; line < rows; ++line)
        fill += Ubiquitty::Diagnostics::RenderProfile::ligatureCodeLine(line) + "\r\n";
    Ubiquitty::processBytes(term, fill);
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    // Two warm frames: the first builds whole and the second settles the atlas.
    for (int warm = 0; warm < 2; ++warm)
        (void)renderer.renderGrid(app().rasterContext, term, rgba, width, height, 0, nullptr, nullptr);
    const std::uint64_t partialBefore = renderer.partialFrameCount();
    std::vector<double> milliseconds;
    milliseconds.reserve(static_cast<std::size_t>(frames));
    for (int frame = 0; frame < frames; ++frame) {
        Ubiquitty::processBytes(term, Ubiquitty::Diagnostics::RenderProfile::ligatureCodeLine(rows + frame) + "\r\n");
        const auto start = std::chrono::steady_clock::now();
        if (!renderer.renderGrid(app().rasterContext, term, rgba, width, height, 0, nullptr, nullptr)) {
            renderer.shutdown();
            return 1;
        }
        milliseconds.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
    }
    const std::uint64_t partialFrames = renderer.partialFrameCount() - partialBefore;
    renderer.shutdown();
    std::vector<double> sorted = milliseconds;
    std::ranges::sort(sorted);
    const auto percentile = [&](double fraction) {
        return sorted.empty() ? 0.0 : sorted[std::min(sorted.size() - 1, static_cast<std::size_t>(fraction * static_cast<double>(sorted.size())))];
    };
    double total = 0.0;
    for (const double value : milliseconds)
        total += value;
    utsname host {};
    (void)uname(&host);
    std::string cpu = "unknown";
    if (std::FILE* info = std::fopen("/proc/cpuinfo", "r")) {
        std::array<char, 512> line {};
        while (std::fgets(line.data(), static_cast<int>(line.size()), info)) {
            const std::string_view text(line.data());
            if (text.starts_with("model name")) {
                const std::size_t colon = text.find(':');
                cpu = std::string(text.substr(colon == std::string_view::npos ? 0 : colon + 2));
                if (!cpu.empty() && cpu.back() == '\n')
                    cpu.pop_back();
                break;
            }
        }
        std::fclose(info);
    }
    g_print("bench-gridcache-scroll: machine=\"%s %s %s\" cpu=\"%s\" grid=%dx%d frames=%d partial=%llu (%.1f%%) "
            "frame_ms mean=%.3f p50=%.3f p95=%.3f cache=%s\n",
        host.nodename, host.sysname, host.release, cpu.c_str(), columns, rows, frames,
        static_cast<unsigned long long>(partialFrames), frames > 0 ? 100.0 * static_cast<double>(partialFrames) / frames : 0.0,
        frames > 0 ? total / frames : 0.0, percentile(0.5), percentile(0.95),
        Ubiquitty::Rendering::isRetainedGridCacheEnabled() ? "on" : "off");
    return 0;
}

// --smoke-nf — probe which Nerd-Font icons are wider than one cell (the glyphs
// the cell-baked path CLIPS, that the subpixel overflow pass exists to fix).
// Rasterise each codepoint CENTERED in a scratch slot 3 cells wide (one cell of
// headroom each side, no clamp) and measure the ink's horizontal extent: ink
// reaching outside the central cell [cw, 2cw) means the glyph would be clipped
// in a one-cell slot. Read-only — renders to a scratch buffer, never the live
// path. After the overflow pass lands, the same wide glyphs must survive into
// the neighbour columns of a real render (see --smoke-nf-render).
int smokeNerdFont()
{
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int cellWidth = static_cast<int>(metrics.cellWidth);
    const int cellHeight = static_cast<int>(metrics.cellHeight);
    const Ubiquitty::Rendering::GlyphSlot policySlot = Ubiquitty::Rendering::computeGlyphSlot(rasteriser.glyphOverhang());
    g_print("smoke-nf: policy marginInPixels.width=%d marginInPixels.height=%d slot=%dx%d (cell=%dx%d)\n", policySlot.marginInPixels.width, policySlot.marginInPixels.height, policySlot.slotWidthInPixels, policySlot.slotHeightInPixels, cellWidth, cellHeight);
    const int slotWidthInPixels = cellWidth * 3; // central cell + a cell of headroom each side
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(slotWidthInPixels) * cellHeight);

    struct Probe {
        std::uint32_t codePoint;
        const char* name;
    };
    const Probe probes[] = {
        { 0xE0B0, "pl-arrow-r" },
        { 0xE0B2, "pl-arrow-l" },
        { 0xE0A0, "pl-branch" },
        { 0xE5FB, "seti-folder" },
        { 0xE628, "seti-go" },
        { 0xE706, "dev-python" },
        { 0xF001, "fa-music" },
        { 0xF015, "fa-home" },
        { 0xF09B, "fa-github" },
        { 0xF0E7, "fa-bolt" },
        { 0xF121, "fa-code" },
        { 0xF073, "fa-calendar" },
        { 0xF0249, "md-shield" },
        { 0xF02D1, "md-book" },
        { 0xF0594, "md-weather" },
        { 0xE315, "weather" },
        { 0xF300, "linux-logo" },
        { 0xF31B, "fl-ubuntu" },
    };

    int clipped = 0;
    int present = 0;
    for (const Probe& probe : probes) {
        coverage.assign(coverage.size(), std::uint8_t { 0 });
        rasteriser.rasterizeGlyph(probe.codePoint, Ubiquitty::Rendering::FontFace::Regular, 0, slotWidthInPixels, cellHeight, coverage.data());
        int minX = slotWidthInPixels;
        int maxX = -1;
        for (int y = 0; y < cellHeight; ++y)
            for (int x = 0; x < slotWidthInPixels; ++x)
                if (coverage[static_cast<std::size_t>(y) * slotWidthInPixels + x] >= 24) {
                    minX = std::min(minX, x);
                    maxX = std::max(maxX, x);
                }
        if (maxX < 0) {
            g_print("smoke-nf: U+%05X %-12s — no ink (font lacks glyph)\n", probe.codePoint, probe.name);
            continue;
        }
        ++present;
        const int inkWidth = maxX - minX + 1;
        const bool overflow = (minX < cellWidth) || (maxX >= 2 * cellWidth);
        g_print("smoke-nf: U+%05X %-12s inkW=%2d (cell=%d) ink[%2d..%2d] %s\n", probe.codePoint, probe.name, inkWidth, cellWidth, minX, maxX, overflow ? "OVERFLOWS cell -> clipped" : "fits");
        if (overflow)
            ++clipped;
    }
    // The overflow count is a measurement and not a verdict — a glyph wider than
    // its cell is what the subpixel pass exists to draw, so a high count is the
    // expected reading rather than a fault. The failure available here is the
    // measurement saying nothing: no probe glyph present means the bundled font
    // did not load, and every line above reports on an empty raster while the run
    // still exits 0. That is the state this case exists to catch.
    // What this backend's null entries give up, from Core's own predicate. It
    // had no callers: a frontend leaving `colorGlyph` null draws an emoji
    // monochrome, and the cell is inked with every count right, so nothing
    // downstream can tell. Reported rather than gated — the CPU path has no
    // colour atlas at all, so a gate would fail every run and teach the reader
    // to skip it. Naming it is what makes the omission visible.
    const bool isLossy = app().rasterContext.softwareBackendIsLossy();
    Ubiquitty::PAL::logLine(stdout, "smoke-nf: software backend lossy={} ({})", isLossy ? 1 : 0,
        isLossy ? "colour glyphs and/or clusters fall back" : "every optional entry filled");

    const bool didMeasure = present > 0;
    Ubiquitty::PAL::logLine(stdout, "smoke-nf: {}/{} present glyphs overflow a single cell (cell={}x{}) -- {}",
        clipped, present, cellWidth, cellHeight, didMeasure ? "PASS" : "FAIL: no probe glyph present");
    return didMeasure ? 0 : 1;
}

// --smoke-nf-render — render a lone wide Nerd-Font icon and PROVE the overflow
// pass un-clipped it: its ink must reach OUTSIDE its own cell (into the neighbour
// columns), and the CPU + GPU renders must be byte-identical. Renders a row with
// one icon (fa-home, U+F015 — smoke-nf measured inkW 16 in a 10px cell) at a known
// column surrounded by spaces, with a newline after so the cursor block lands on
// the NEXT row (out of the scanned band).
// --smoke-sized-gpu — OSC 66 sized text drawn by the Vulkan pipeline is the
// picture the CPU rasteriser draws. Both arms take the builder's sharp sized
// windows from their glyph backend; a backend that offers none falls back to the
// cell raster magnified over the block, which differs from the sharp windows in
// every edge pixel, so the byte comparison is the sharpness check. Whole scales
// and an n/d fraction are both on the screen, because they ask for different
// rasters, and so are one-cell and two-cell glyphs, because they are cut on
// different pages. Skips, by name, where no FreeType face is configured: Unifont is a
// bitmap, and both arms correctly magnify it.
int smokeSizedGPU()
{
    // A face that draws CJK from outlines: the primary's own fallback chain
    // ends in Unifont, whose two-cell glyphs are bitmaps on every arm, and a
    // bitmap shows nothing about whether a window was cut from a raster drawn
    // at the block's size.
    constexpr std::string_view configuration = "[font]\nfamily = \"Noto Sans Mono CJK JP\"\nsize = 12\n";
    if (!Ubiquitty::Preferences::configure(std::string(configuration), Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
        g_printerr("smoke-sized-gpu: configuration failed\n");
        return 1;
    }
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    if (!rasteriser.rasterisesScaledGlyphsSharply()) {
        g_print("smoke-sized-gpu: SKIPPED — the configured face is a bitmap, so a sized glyph is the magnified cell on every arm\n");
        return 0;
    }
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-sized-gpu: no term\n");
        return 1;
    }
    term->drawsSizedText = true;
    Ubiquitty::processBytes(term, "\x1b[?25l\x1b]66;s=2;Hg\x07 \x1b]66;s=3;E\x07 \x1b]66;s=3:n=1:d=2;A\x07 \x1b]66;s=2:n=3:d=4:v=2:h=2;b\x07\r\n");
    // Two-cell glyphs, whose windows are two cells wide on both arms' wide pages.
    Ubiquitty::processBytes(term, "\r\n\r\n\x1b]66;s=2;\xe6\x9d\xb1\x07 \x1b]66;s=3;\xe6\x9d\xb1\x07 \x1b]66;s=3:n=1:d=2;\xe6\x9d\xb1\x07\r\n");

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasteriser);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-sized-gpu", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
    renderer.shutdown();
    if (!didRenderCPUFrame) {
        g_printerr("smoke-sized-gpu: the CPU arm drew nothing\n");
        return 1;
    }
    if (!didRenderGPUFrame)
        return skipNoGPUFrame("smoke-sized-gpu", "no GPU frame");
    // The fractional two-cell block, columns 12-17 of rows 3-5, draws the 1x
    // wide raster mapped into its smaller area — a scaled quad both arms
    // sample bilinearly from sheets laid out differently, so its interior may
    // differ by a unit of coverage, as `--smoke-script-glyphs`' scaled scripts
    // do. What the block must agree on is where it is drawn: the same ink box
    // on both arms. Every other pixel of the frame must be identical.
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int blockLeft = static_cast<int>(std::lround(12.0f * metrics.cellWidth));
    const int blockRight = static_cast<int>(std::lround(18.0f * metrics.cellWidth));
    const int blockTop = static_cast<int>(std::lround(3.0f * metrics.cellHeight));
    const int blockBottom = static_cast<int>(std::lround(6.0f * metrics.cellHeight));
    const bool isSameSize = cpuWidth == gpuWidth && cpuHeight == gpuHeight;
    struct InkBox {
        int left = INT_MAX;
        int top = INT_MAX;
        int right = -1;
        int bottom = -1;
        bool operator==(const InkBox&) const = default;
    };
    InkBox cpuBlockInk;
    InkBox gpuBlockInk;
    int differingPixels = 0;
    int differingBlockPixels = 0;
    const auto widen = [](InkBox& box, int x, int y) {
        box.left = std::min(box.left, x);
        box.top = std::min(box.top, y);
        box.right = std::max(box.right, x);
        box.bottom = std::max(box.bottom, y);
    };
    for (int y = 0; isSameSize && y < cpuHeight; ++y) {
        for (int x = 0; x < cpuWidth; ++x) {
            const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(cpuWidth) + static_cast<std::size_t>(x)) * 4;
            const bool isInBlock = x >= blockLeft && x < blockRight && y >= blockTop && y < blockBottom;
            const bool differs = std::memcmp(cpu.data() + offset, gpu.data() + offset, 4) != 0;
            if (!isInBlock) {
                differingPixels += differs ? 1 : 0;
                continue;
            }
            differingBlockPixels += differs ? 1 : 0;
            if (std::memcmp(cpu.data() + offset, cpu.data(), 4) != 0)
                widen(cpuBlockInk, x, y);
            if (std::memcmp(gpu.data() + offset, gpu.data(), 4) != 0)
                widen(gpuBlockInk, x, y);
        }
    }
    const bool didPass = isSameSize && differingPixels == 0 && cpuBlockInk == gpuBlockInk && cpuBlockInk.right >= 0;
    if (!didPass) {
        for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", cpu), { "gpu", gpu } }) {
            const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { label == std::string_view("cpu") ? cpuWidth : gpuWidth, label == std::string_view("cpu") ? cpuHeight : gpuHeight });
            const std::string path = std::string("/tmp/sized_gpu_") + label + ".png";
            if (FILE* file = std::fopen(path.c_str(), "wb")) {
                std::fwrite(png.data(), 1, png.size(), file);
                std::fclose(file);
                g_print("smoke-sized-gpu: wrote %s\n", path.c_str());
            }
        }
    }
    Ubiquitty::PAL::logLine(stdout, "smoke-sized-gpu: fractional wide block ink CPU [{},{}..{},{}] GPU [{},{}..{},{}], {} interior pixel(s) differ",
        cpuBlockInk.left, cpuBlockInk.top, cpuBlockInk.right, cpuBlockInk.bottom,
        gpuBlockInk.left, gpuBlockInk.top, gpuBlockInk.right, gpuBlockInk.bottom, differingBlockPixels);
    Ubiquitty::PAL::logLine(stdout, "smoke-sized-gpu: CPU {}x{} GPU {}x{}, {} pixel(s) differ outside it -- {}",
        cpuWidth, cpuHeight, gpuWidth, gpuHeight, differingPixels, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Runs of ░ ▒ ▓ through the Vulkan arm at cells 9, 10 and 11 pixels wide and
// 17 tall — widths the shade field's period of four does not divide, which is
// where a pattern restarted per cell opens a seam. Every pixel of each run must
// be Core's grid-anchored field (ShadeStyle.h), so no background column opens
// at a cell edge; the medium and dark shades must ink every column and the
// light one never leave two adjacent columns empty.
int smokeShadeGPU()
{
    setupFonts();
    constexpr int columns = 8;
    constexpr int rows = 6;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-shade-gpu: no term\n");
        return 1;
    }
    const std::string_view canned = "\x1b[?25l\x1b[H"
                                    " \u2591\u2591\u2591\u2591\u2591\u2591\r\n"
                                    " \u2591\u2591\u2591\u2591\u2591\u2591\r\n"
                                    " \u2592\u2592\u2592\u2592\u2592\u2592\r\n"
                                    " \u2592\u2592\u2592\u2592\u2592\u2592\r\n"
                                    " \u2593\u2593\u2593\u2593\u2593\u2593\r\n"
                                    " \u2593\u2593\u2593\u2593\u2593\u2593";
    Ubiquitty::processBytes(term, canned);

    bool didPass = true;
    for (const int characterSpacing : { 1, 2, 3 }) {
        Ubiquitty::Rendering::UnifontRasterizer face(1, 1, characterSpacing);
        Ubiquitty::Rendering::BoxDrawingRasterizer boxes(face);
        const Ubiquitty::Rendering::CellMetrics metrics = boxes.cellMetrics();
        const int cellWidth = static_cast<int>(metrics.cellWidth + 0.5f);
        const int cellHeight = static_cast<int>(metrics.cellHeight + 0.5f);
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(boxes);
        if (!renderer.init())
            return skipNoGPUFrame("smoke-shade-gpu", "vulkan init failed");
        std::vector<uint8_t> gpu;
        int width = 0, height = 0;
        const bool didRender = renderer.renderGrid(app().rasterContext, term, gpu, width, height, 0, nullptr, nullptr);
        renderer.shutdown();
        if (!didRender)
            return skipNoGPUFrame("smoke-shade-gpu", "no GPU frame");
        if (width < columns * cellWidth || height < rows * cellHeight) {
            g_printerr("smoke-shade-gpu: frame %dx%d smaller than the %dx%d grid\n", width, height, columns * cellWidth, rows * cellHeight);
            return 1;
        }
        const auto pixelAt = [&](int x, int y) { return &gpu[(static_cast<std::size_t>(y) * width + x) * 4]; };
        // Column 0 is a space: the ground the unlit pixels must keep.
        const std::uint8_t* ground = pixelAt(1, 1);
        const auto isInked = [&](int x, int y) {
            const std::uint8_t* pixel = pixelAt(x, y);
            return pixel[0] != ground[0] || pixel[1] != ground[1] || pixel[2] != ground[2];
        };
        const int phase = Ubiquitty::Rendering::shadePhase(0, 0);
        for (int shade = 0; shade < 3; ++shade) {
            const int lit = shade + 1;
            const int top = shade * 2 * cellHeight;
            const int bottom = top + 2 * cellHeight;
            int mismatches = 0;
            int emptyRun = 0;
            int widestEmptyRun = 0;
            for (int x = cellWidth; x < 7 * cellWidth; ++x) {
                bool isColumnInked = false;
                for (int y = top; y < bottom; ++y) {
                    const bool inked = isInked(x, y);
                    isColumnInked |= inked;
                    mismatches += inked != Ubiquitty::Rendering::isShadePixelLit(x, y, lit, phase) ? 1 : 0;
                }
                emptyRun = isColumnInked ? 0 : emptyRun + 1;
                widestEmptyRun = std::max(widestEmptyRun, emptyRun);
            }
            const int allowedEmptyRun = lit == 1 ? 1 : 0;
            const bool isSeamless = mismatches == 0 && widestEmptyRun <= allowedEmptyRun;
            didPass &= isSeamless;
            Ubiquitty::PAL::logLine(stdout, "smoke-shade-gpu: cell {}x{} U+{:04X} field mismatches={} widest background run={} -- {}",
                cellWidth, cellHeight, 0x2591 + shade, mismatches, widestEmptyRun, isSeamless ? "PASS" : "FAIL");
        }
    }
    return didPass ? 0 : 1;
}

int smokeNerdFontRender()
{
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int cellWidth = static_cast<int>(metrics.cellWidth);
    const int cellHeight = static_cast<int>(metrics.cellHeight);
    const int glyphCol = 3; // 0-based; the icon's cell

    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-nf-render: no term\n");
        return 1;
    }
    const char canned[] = "   \xef\x80\x95   \r\n"; // 3 spaces, U+F015, spaces, newline
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasteriser);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-nf-render", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool cpuOk = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
    renderer.shutdown();
    const bool didCompareGPU = cpuOk && didRenderGPUFrame;
    const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
    g_print("smoke-nf-render: CPU==GPU %s (%dx%d)\n", oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), cpuWidth, cpuHeight);
    if (cpuOk) {
        const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
        FILE* f = std::fopen("/tmp/nf_render.png", "wb");
        if (f) {
            std::fwrite(png.data(), 1, png.size(), f);
            std::fclose(f);
            g_print("smoke-nf-render: wrote /tmp/nf_render.png\n");
        }
    }
    if (!cpuOk)
        return 1;

    // The only ink in row 0 is the icon (spaces are blank, the cursor is on row 1).
    // Find its horizontal extent vs its own cell [glyphCol*cellWidth, (glyphCol+1)*cellWidth):
    // ink reaching outside it means the overflow pass un-clipped the glyph.
    const std::uint8_t backgroundRed = cpu[0], backgroundGreen = cpu[1], backgroundBlue = cpu[2];
    int minX = cpuWidth;
    int maxX = -1;
    for (int y = 0; y < cellHeight; ++y)
        for (int x = 0; x < cpuWidth; ++x) {
            const std::size_t o = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
            if (cpu[o] != backgroundRed || cpu[o + 1] != backgroundGreen || cpu[o + 2] != backgroundBlue) {
                minX = std::min(minX, x);
                maxX = std::max(maxX, x);
            }
        }
    const int cellLeft = glyphCol * cellWidth;
    const int cellRight = (glyphCol + 1) * cellWidth;
    const bool overflows = maxX >= 0 && (minX < cellLeft || maxX >= cellRight);
    // The verdict is printed as well as returned. It was in the exit code alone,
    // and the line above reads the same whether the run proved what it set out to
    // or not: "OVERFLOWS cell" is the PASSING reading here, which is the opposite
    // of how it scans.
    const bool didPass = same && overflows;
    Ubiquitty::PAL::logLine(stdout, "smoke-nf-render: ink[{}..{}] cell[{}..{}] cellWidth={} — {} -- {}",
        minX, maxX, cellLeft, cellRight, cellWidth,
        overflows ? "reaches outside its cell (un-clipped)" : "clipped to its cell",
        didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

int smokeVulkanClear()
{
    Ubiquitty::Linux::VulkanRenderer renderer;
    if (!renderer.init())
        return skipNoGPUFrame("smoke(vulkan)", "vulkan init failed");
    std::vector<uint8_t> rgba;
    const bool ok = renderer.renderClear(640, 384, 0.05f, 0.45f, 0.5f, rgba);
    renderer.shutdown();
    if (!ok || rgba.size() < 4) {
        g_printerr("smoke(vulkan): render failed\n");
        return 1;
    }
    const size_t c = (static_cast<size_t>(192) * 640 + 320) * 4;
    const bool didPass = rgba[c + 3] == 255 && rgba[c + 1] > rgba[c] && rgba[c + 2] > rgba[c];
    g_print("smoke(vulkan): center RGBA = %u %u %u %u — %s\n", static_cast<unsigned>(rgba[c]), static_cast<unsigned>(rgba[c + 1]), static_cast<unsigned>(rgba[c + 2]), static_cast<unsigned>(rgba[c + 3]), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

int smokeGrid()
{
    setupFonts();
    initTermCanned();
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!term || !app().rasterContext.rasterizeTerm(term, rgba, width, height) || rgba.empty()) {
        g_printerr("smoke(grid): rasterize failed\n");
        return 1;
    }
    bool uniform = true;
    for (size_t i = 4; i + 3 < rgba.size(); i += 4)
        if (rgba[i] != rgba[0] || rgba[i + 1] != rgba[1] || rgba[i + 2] != rgba[2]) {
            uniform = false;
            break;
        }
    g_print("smoke(grid): %dx%d — %s\n", width, height, uniform ? "FAIL (blank)" : "PASS (has text)");
    return uniform ? 1 : 0;
}

int dumpPNGLive(const char* path)
{
    setupFonts();
    if (!launchShell()) {
        g_printerr("dump-png-live: failed to launch shell\n");
        return 1;
    }
    drainBriefly(activePane()->session->fileDescriptor(), 12);
    return writePNG(path);
}

// Launch a shell and type "ls\n" through the real key path, then dump the
// screen — exercises the key seam + sendInputBytes end to end.
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

// Self-test the runtime font swap on the GPU path: render the canned screen with
// FreeType, then re-inject Unifont + rebuildAtlas() and render again, asserting
// both renders succeed and the cell geometry actually changes. Exercises
// VulkanRenderer::rebuildAtlas — the live Unifont↔FreeType toggle — headlessly.
int selftestFontToggle()
{
    initTermCanned();
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("selftest-font-toggle: no term\n");
        return 1;
    }
    setupFonts();
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap || !app().glyphRasterizer || !app().glyphRasterizer->ready()) {
        g_printerr("selftest-font-toggle: FreeType unavailable; cannot test the swap\n");
        return 1;
    }
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(*app().glyphRasterizer); // start on FreeType
    if (!renderer.init())
        return skipNoGPUFrame("selftest-font-toggle", "vulkan init failed");
    std::vector<uint8_t> rgba;
    int ftWidth = 0, ftHeight = 0;
    const bool ftOk = renderer.renderGrid(app().rasterContext, term, rgba, ftWidth, ftHeight);

    // Swap to Unifont at runtime (the same sequence applyFontMode runs on app().vulkan):
    // re-inject, rebuild the atlas, render again.
    renderer.setGlyphRasterizer(*app().unifontRasterizer);
    renderer.rebuildAtlas();
    int uniWidth = 0, uniHeight = 0;
    const bool uniOk = renderer.renderGrid(app().rasterContext, term, rgba, uniWidth, uniHeight);
    renderer.shutdown();

    g_print("selftest-font-toggle: freetype %dx%d (ok=%d) -> unifont %dx%d (ok=%d)\n", ftWidth, ftHeight, ftOk, uniWidth, uniHeight, uniOk);
    if (!ftOk || !uniOk) {
        g_printerr("selftest-font-toggle: FAIL (a renderGrid failed)\n");
        return 1;
    }
    if (ftWidth == uniWidth && ftHeight == uniHeight) {
        g_printerr("selftest-font-toggle: FAIL (cell geometry unchanged across the swap)\n");
        return 1;
    }
    g_print("selftest-font-toggle: PASS\n");
    return 0;
}

// SGR mouse (DECSET 1000 + 1006) reports pinned at one cell: the Linux-native
// button identities, the four wheel directions, and two numbers outside the
// set, which must encode as nothing.
int smokeMouse()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-mouse: no term\n");
        return 1;
    }
    const char enableSGR[] = "\x1b[?1000h\x1b[?1006h";
    Ubiquitty::processBytes(term, std::string_view(enableSGR, sizeof(enableSGR) - 1));

    const int row = 2, column = 5;
    struct Expectation {
        std::string_view label;
        int buttonCode;
        std::string_view report;
    };
    using Ubiquitty::Input::WheelDirection;
    using Ubiquitty::Input::xtermWheelButtonCode;
    const std::array<Expectation, 9> expectations { {
        { "left", mouseButtonCode(GDK_BUTTON_PRIMARY), "\x1b[<0;6;3M" },
        { "wheel-up", xtermWheelButtonCode(WheelDirection::Up), "\x1b[<64;6;3M" },
        { "wheel-down", xtermWheelButtonCode(WheelDirection::Down), "\x1b[<65;6;3M" },
        { "wheel-left", xtermWheelButtonCode(WheelDirection::Left), "\x1b[<66;6;3M" },
        { "wheel-right", xtermWheelButtonCode(WheelDirection::Right), "\x1b[<67;6;3M" },
        { "button-8", mouseButtonCode(8), "\x1b[<128;6;3M" },
        { "button-9", mouseButtonCode(9), "\x1b[<129;6;3M" },
        { "button-10", mouseButtonCode(10), "\x1b[<130;6;3M" },
        { "button-11", mouseButtonCode(11), "\x1b[<131;6;3M" },
    } };
    const bool unsupportedRefused = mouseButtonCode(4) == -1 && mouseButtonCode(12) == -1;
    bool didPass = unsupportedRefused;
    for (const Expectation& expectation : expectations) {
        std::array<char, 32> report {};
        const int length = Ubiquitty::encodeMouseReport(*term, Ubiquitty::Mouse::EventType::Press, expectation.buttonCode, row, column, 0, report, -1, -1);
        const bool matches = length >= 0 && std::string_view(report.data(), static_cast<std::size_t>(length)) == expectation.report;
        g_print("smoke-mouse: %-11.*s Cb=%d %s\n", static_cast<int>(expectation.label.size()), expectation.label.data(), expectation.buttonCode, matches ? "PASS" : "FAIL");
        didPass = didPass && matches;
    }
    g_print("smoke-mouse: unsupported-buttons=%s overall=%s\n", unsupportedRefused ? "PASS" : "FAIL", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Feed OSC 0 (set icon + window title) and assert Core flagged the change and
// stored the UTF-8 title — the dynamic-title wiring's Core half.
int smokeTitle()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-title: no term\n");
        return 1;
    }
    const char osc[] = "\x1b]0;hello\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    const bool didPass = term->titleChanged && term->titleUTF8 == "hello";
    g_print("smoke-title: titleChanged=%d titleUTF8=\"%s\" -- %s\n", static_cast<int>(term->titleChanged), term->titleUTF8.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Read columns [0, count) of one visible row at a viewOffset into an ASCII string
// (a scrollback content probe; non-ASCII glyphs map to '?'). count <= 16.
std::string visibleRowText(const Ubiquitty::Terminal& term, int viewOffset, int row, int count)
{
    std::string text;
    for (int column = 0; column < count; ++column) {
        const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(&term, viewOffset, row, column);
        const uint32_t codePoint = (cell != nullptr) ? cell->codePoint : static_cast<uint32_t>(' ');
        text.push_back((codePoint >= 0x20 && codePoint < 0x7F) ? static_cast<char>(codePoint) : '?');
    }
    return text;
}

// Feed 40 numbered lines, then assert a scrolled-back view shows an OLDER top row
// than the live tail. Pure Core content assertion — no display / renderer needed.
// 40 lines into a 24-row screen pushes the older ones into history; scrolling up
// by N reveals a top row N lines older than the live-tail top row.
int smokeScrollback()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-scrollback: no term\n");
        return 1;
    }
    std::string feed;
    for (int i = 0; i < 40; ++i) {
        char line[16];
        std::snprintf(line, sizeof(line), "line%02d\r\n", i);
        feed += line;
    }
    Ubiquitty::processBytes(term, feed);

    const int historyDepth = Ubiquitty::Screen::scrollbackCount(term);
    if (historyDepth <= 0) {
        g_printerr("smoke-scrollback: FAIL (scrollbackCount=%d, expected > 0)\n", historyDepth);
        return 1;
    }

    constexpr int probeOffsetLines = 4; // scroll 4 lines up into history
    const int probeOffset = probeOffsetLines <= historyDepth ? probeOffsetLines : historyDepth;
    const std::string topAtTail = visibleRowText(*term, 0, 0, 6);
    const std::string topAtHistory = visibleRowText(*term, probeOffset, 0, 6);

    // The lines are numbered, so the history top row must read exactly probeOffset
    // lines older than the live-tail top row ("lineNN" - probeOffset).
    const int tailLineNumber = std::atoi(topAtTail.c_str() + 4); // skip "line"
    char expectedHistory[16];
    std::snprintf(expectedHistory, sizeof(expectedHistory), "line%02d", tailLineNumber - probeOffset);

    const bool didPass = topAtTail != topAtHistory && topAtTail.starts_with("line") && topAtHistory == expectedHistory;
    g_print("smoke-scrollback: scrollbackCount=%d, top row offset 0 = \"%s\", offset %d = \"%s\" -- %s\n", historyDepth, topAtTail.c_str(), probeOffset, topAtHistory.c_str(), didPass ? "PASS" : "FAIL");
    if (!didPass)
        g_printerr("smoke-scrollback: offset %d expected \"%s\" (%d lines older than the tail)\n", probeOffset, expectedHistory, probeOffset);
    return didPass ? 0 : 1;
}

// Selection + copy-to-clipboard self-test. Feeds a known two-line screen,
// CHAR-selects row 0 columns 1..3 (= "BCD"), asserts getBounds + the extracted
// UTF-8 + the clipboard capture all read "BCD", renders the canned screen WITH
// the selection to /tmp/sel_overlay.png so the TRANSLUCENT highlight can be
// eyeballed (the selected cells are not inverted in the grid — they carry a
// translucent overlay quad, so the glyph reads through), and asserts the CPU
// SoftwareRenderer and GPU VulkanRenderer composite that overlay byte-identically
// WITH the selection set (the key CPU<->GPU oracle for the selection overlay).
int smokeSelection()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-selection: no term\n");
        return 1;
    }
    const char screen[] = "ABCDE\r\nFGHIJ\r\n";
    Ubiquitty::processBytes(term, std::string_view(screen, sizeof(screen) - 1));

    // CHAR-select row 0, columns 1..3 ("BCD") through the facade — the same
    // beginGesture/dragGesture pair the pointer ladder drives.
    activePane()->viewOffset = 0;
    Ubiquitty::Selection::init(activePane()->selection);
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 0, 3, 0);

    const std::string extracted = selectionText();

    // Drive the real copy path and read back what the PAL was handed.
    const bool copied = copySelectionToClipboard();
    const std::string captured = Ubiquitty::Linux::Clipboard::lastSetText();

    // An endpoint on the trailing half of a wide glyph. A continuation cell
    // repeats its lead's code point and the emission walk skips continuations,
    // so bounds that start on that half begin one column past the only cell that
    // produces the character: the copy loses it entirely rather than clipping it,
    // and the result is still well-formed UTF-8 of the right shape, which is why
    // a length or a row count cannot catch this and the bytes have to be named.
    Ubiquitty::processBytes(term, std::string_view("\xe4\xb8\x96\xe7\x95\x8c\r\n"));
    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 2, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const bool didCopyWide = copySelectionToClipboard();
    const std::string capturedWide = Ubiquitty::Linux::Clipboard::lastSetText();
    const bool didWidePass = didCopyWide && capturedWide == "\xe4\xb8\x96\xe7\x95\x8c";

    // The facade resolves the anchor wide-aware, so an endpoint on the glyph's
    // trailing half still copies the whole character — the bytes are the check.
    g_print("smoke-selection: wide clipboard=\"%s\" (%zu bytes) -- %s\n",
        capturedWide.c_str(), capturedWide.size(), didWidePass ? "PASS" : "FAIL");

    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 0, 3, 0);

    // CPU==GPU oracle WITH the selection set: the translucent overlay quad must
    // composite identically on both backends (the key check this stage adds).
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-selection", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
    const bool didOracleAgree = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);

    // The same selection under a colour the host named (OSC 17): the native
    // style draws it behind the text, as each selected cell's background
    // washed by the native opacity. Both backends take that fill from Core's
    // capture; a backend that substitutes its own tint draws another colour at
    // another weight while the cell-pass bake still reads as behind the text.
    Ubiquitty::processBytes(term, std::string_view("\x1b]17;rgb:00/80/ff\x07"));
    std::vector<uint8_t> hostCPU;
    std::vector<uint8_t> hostGPU;
    int hostCPUWidth = 0, hostCPUHeight = 0, hostGPUWidth = 0, hostGPUHeight = 0;
    const bool didRasterizeHostCPU = app().rasterContext.rasterizeTerm(term, hostCPU, hostCPUWidth, hostCPUHeight, activePane()->viewOffset, &activePane()->selection);
    const bool didRenderHostGPU = renderer.renderGrid(app().rasterContext, term, hostGPU, hostGPUWidth, hostGPUHeight, activePane()->viewOffset, &activePane()->selection);
    renderer.shutdown();
    const bool didCompareHost = didRasterizeHostCPU && didRenderHostGPU;
    const bool didHostOracleAgree = !didCompareHost
        || (hostCPUWidth == hostGPUWidth && hostCPUHeight == hostGPUHeight && hostCPU == hostGPU);

    // Render the canned screen WITH the selection to a PNG (eyeball the
    // translucent highlight — text readable through it).
    if (didRasterizeCPU) {
        const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
        if (FILE* f = std::fopen("/tmp/sel_overlay.png", "wb")) {
            std::fwrite(png.data(), 1, png.size(), f);
            std::fclose(f);
            g_print("smoke-selection: wrote /tmp/sel_overlay.png (%dx%d)\n", cpuWidth, cpuHeight);
        }
    }

    const bool didPass = extracted == "BCD" && copied && captured == "BCD" && didWidePass && didOracleAgree && didHostOracleAgree;
    g_print("smoke-selection: extracted=\"%s\" clipboard=\"%s\" "
            "CPU==GPU(with selection)=%s CPU==GPU(behind the text, OSC 17)=%s -- %s\n",
        extracted.c_str(), captured.c_str(), oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (didOracleAgree ? OracleOutcome::Matched : OracleOutcome::Differed)),
        oracleLabel(!didCompareHost ? OracleOutcome::NotCompared : (didHostOracleAgree ? OracleOutcome::Matched : OracleOutcome::Differed)), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-scaled-run-selection — a selection over a scaled proportional run
// lights the letters it holds through their ink, on every band row, on both
// arms. The run is "Hello" at c=6:s=3 in the bundled JetBrains Mono's
// proportional face, whose o begins in one of the run's cells and runs on
// into the next; a rectangle selection on the middle band alone, as the
// snapshot's --select-rect sets it, from the run's third column to the last
// column the text reaches, must tint every background pixel between the H's
// ink and the o's on all three band rows — the o's ink included, which a
// highlight stopping at the cell the o begins in leaves bare — and a
// selection ending two cells short must tint none of the o's. The copy is the
// word for the first and "He" for the second. The CPU and Vulkan frames agree
// byte for byte with the selection set.
int smokeScaledRunSelection()
{
    setupFonts();
    constexpr int rows = 6;
    constexpr int columns = 30;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-scaled-run-selection: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer(26, "JetBrains Mono", std::string(), std::string(), bundledPath, 1, 0);
    if (!rasterizer.ready() || !rasterizer.hasProportionalFace()) {
        g_printerr("smoke-scaled-run-selection: FAILED — no native proportional face\n");
        return 1;
    }
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    // The measurer the snapshot installs: the face the frame draws in, at the
    // grid's pitch, so Core's owner map and the frame's layout are one.
    activePane()->session->setTextMeasurer(
        [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t,
            Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* cellAdvanceOut) {
            auto& face = *static_cast<Ubiquitty::Linux::FreeTypeRasterizer*>(context);
            if (cellAdvanceOut)
                *cellAdvanceOut = static_cast<float>(face.cellMetrics().cellWidth);
            return face.shapeProportionalRun(std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                static_cast<Ubiquitty::Rendering::FontFace>(faceBits), std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
        },
        &rasterizer);
    term->drawsSizedText = true;
    term->drawsProportionalText = true;
    Ubiquitty::processBytes(term, std::string_view("\x1b[?25lAx\x1b]66;s=2;X\x1b\\yz \x1b]66;p=1:c=6:s=2;Hello\x1b\\|\r\n\r\n\x1b]66;p=1:c=6:s=3;Hello\x1b\\|"));
    constexpr int runRow = 2;
    constexpr int runScale = 3;
    constexpr int runCells = 6;
    const Ubiquitty::Cell* anchor = Ubiquitty::Screen::visibleCell(term, 0, runRow, 0);
    if (!anchor || !Ubiquitty::isProportionalRunAnchor(term, *anchor)) {
        g_printerr("smoke-scaled-run-selection: FAILED — no scaled run anchored at row %d\n", runRow);
        return 1;
    }
    // Where the run's letters stand, by Core's own layout: the cell the o
    // begins in and the cells the text reaches.
    const std::span<const std::uint32_t> text = Ubiquitty::runTextCodePoints(term, *anchor);
    std::vector<std::uint16_t> owners(text.size());
    int textCells = 0;
    if (text.size() != 5 || !Ubiquitty::OSC::TextSizing::proportionalRunCellOwners(*term, text, runCells, 0, Ubiquitty::OSC::TextSizing::runStyleOf(Ubiquitty::cellPen(*anchor)), owners, &textCells)) {
        g_printerr("smoke-scaled-run-selection: FAILED — the run did not measure\n");
        return 1;
    }
    const int lastLetterCell = owners.back();
    const int textLastColumn = textCells * runScale - 1;
    const bool doesInkRunOn = textCells - 1 > lastLetterCell;
    Ubiquitty::PAL::logLine(stdout, "smoke-scaled-run-selection: o begins in cell {}, the text reaches cell {} ({} columns){}", lastLetterCell, textCells - 1,
        textCells * runScale, doesInkRunOn ? "" : " -- the face keeps the o inside its cell, so the ink past it is not exercised");

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasterizer);
    renderer.setLigatureRasterizer(rasterizer);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-scaled-run-selection", "vulkan init failed");
    struct Frame {
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int width = 0;
        int height = 0;
        bool isRendered = false;
        bool isSame = false;
    };
    const auto render = [&](Ubiquitty::Selection::Session* selection) {
        Frame frame;
        int gpuWidth = 0;
        int gpuHeight = 0;
        const bool didRenderCPU = app().rasterContext.rasterizeTerm(term, frame.cpu, frame.width, frame.height, 0, selection);
        const bool didRenderGPU = renderer.renderGrid(app().rasterContext, term, frame.gpu, gpuWidth, gpuHeight, 0, selection);
        frame.isRendered = didRenderCPU && didRenderGPU && frame.width > 0 && frame.height > 0;
        frame.isSame = frame.isRendered && gpuWidth == frame.width && gpuHeight == frame.height && frame.cpu == frame.gpu;
        return frame;
    };
    const Frame bare = render(nullptr);
    // The rectangle the snapshot's --select-rect sets: the middle band row
    // alone, from the run's third column to the text's last column, and the
    // same rectangle backwards; then one ending in the run's second cell.
    struct Drag {
        const char* name;
        Ubiquitty::SelectionBounds rectangle;
        const char* copy;
        bool isLastLetterHeld;
    };
    const Drag drags[] = {
        { "F", { runRow + 1, 2, runRow + 1, textLastColumn - 1 }, "Hello", true },
        { "F-mirror", { runRow + 1, textLastColumn - 1, runRow + 1, 2 }, "Hello", true },
        { "short", { runRow + 1, 0, runRow + 1, 2 * runScale - 1 }, "He", false },
    };
    const Ubiquitty::Rendering::CellMetrics metrics = rasterizer.cellMetrics();
    const int scale = app().rasterContext.deviceScale();
    const int cellWidth = Ubiquitty::Rendering::cellDimension(metrics.cellWidth) * scale;
    const int cellHeight = Ubiquitty::Rendering::cellDimension(metrics.cellHeight) * scale;
    // The o's ink past the cell it begins in, or its own cell where the face
    // keeps it inside: the columns of the claim whose background the
    // selection must tint when it holds the o and leave when it does not.
    const int inkFirstColumn = (doesInkRunOn ? lastLetterCell + 1 : lastLetterCell) * runScale;
    const int inkLeft = inkFirstColumn * cellWidth;
    const int inkRight = (textLastColumn + 1) * cellWidth;
    const int bandTop = runRow * cellHeight;
    const int bandBottom = (runRow + runScale) * cellHeight;
    bool didPass = bare.isRendered && bare.isSame;
    if (!bare.isRendered)
        g_print("smoke-scaled-run-selection: the arms drew no frame\n");
    for (const Drag& drag : drags) {
        activePane()->viewOffset = 0;
        Ubiquitty::Selection::init(activePane()->selection);
        activePane()->selection.state = Ubiquitty::Selection::characterSelectionOverVisibleRows(*term, drag.rectangle);
        const std::string copied = selectionText();
        const Frame lit = render(&activePane()->selection);
        // Every pixel of the o's columns that is background in the bare frame:
        // tinted in the lit one where the o is held, untouched where not.
        int backgroundPixels = 0;
        int tintedCPU = 0;
        int tintedGPU = 0;
        if (bare.isRendered && lit.isRendered && lit.width == bare.width && lit.height == bare.height) {
            for (int y = bandTop; y < std::min(bandBottom, bare.height); ++y) {
                for (int x = inkLeft; x < std::min(inkRight, bare.width); ++x) {
                    const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(bare.width) + static_cast<std::size_t>(x)) * 4;
                    if (std::memcmp(bare.cpu.data() + offset, bare.cpu.data(), 4) != 0)
                        continue;
                    ++backgroundPixels;
                    tintedCPU += std::memcmp(lit.cpu.data() + offset, bare.cpu.data() + offset, 4) != 0 ? 1 : 0;
                    tintedGPU += std::memcmp(lit.gpu.data() + offset, bare.gpu.data() + offset, 4) != 0 ? 1 : 0;
                }
            }
        }
        const int wanted = drag.isLastLetterHeld ? backgroundPixels : 0;
        const bool isCopyRight = copied == drag.copy;
        const bool isLit = backgroundPixels > 0 && tintedCPU == wanted && tintedGPU == wanted;
        const bool didDragPass = isCopyRight && isLit && lit.isSame;
        didPass = didPass && didDragPass;
        Ubiquitty::PAL::logLine(stdout, "smoke-scaled-run-selection: {} rect {},{},{},{} copied \"{}\" (want \"{}\"), o's columns {}-{}: {} of {} background pixel(s) tinted on CPU, {} on GPU (want {}), CPU==GPU {} -- {}",
            drag.name, drag.rectangle.row0, drag.rectangle.column0, drag.rectangle.row1, drag.rectangle.column1, copied, drag.copy, inkFirstColumn, textLastColumn,
            tintedCPU, backgroundPixels, tintedGPU, wanted, oracleLabel(!lit.isRendered ? OracleOutcome::NotCompared : (lit.isSame ? OracleOutcome::Matched : OracleOutcome::Differed)),
            didDragPass ? "ok" : "WRONG");
        if (!didDragPass && lit.isRendered) {
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", lit.cpu), { "gpu", lit.gpu } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { lit.width, lit.height });
                const std::string path = std::string("/tmp/scaled_run_selection_") + drag.name + "_" + label + ".png";
                if (FILE* file = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), file);
                    std::fclose(file);
                    g_print("smoke-scaled-run-selection: wrote %s\n", path.c_str());
                }
            }
        }
    }
    renderer.shutdown();
    activePane()->session->setTextMeasurer(nullptr, nullptr);
    g_print("smoke-scaled-run-selection: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Print a byte string with control characters shown as \xNN (shared by the
// paste/OSC52 self-tests).
void printEscaped(std::string_view bytes)
{
    for (const char raw : bytes) {
        const unsigned char c = static_cast<unsigned char>(raw);
        if (c >= 0x20 && c < 0x7F)
            g_print("%c", c);
        else
            g_print("\\x%02x", c);
    }
}

// Assert wrapPaste brackets text under DECSET-2004 and passes it through
// otherwise — the pure paste-wrapping helper, no display / Ubiquitty::Terminal needed.
int smokePaste()
{
    const std::string bracketed = Ubiquitty::Input::wrapPaste("hi", Ubiquitty::Input::BracketedPaste::Enabled);
    const std::string plain = Ubiquitty::Input::wrapPaste("hi", Ubiquitty::Input::BracketedPaste::Disabled);
    const bool bracketedOk = bracketed == "\x1b[200~hi\x1b[201~";
    const bool plainOk = plain == "hi";
    g_print("smoke-paste: bracketed=\"");
    printEscaped(bracketed);
    g_print("\" plain=\"");
    printEscaped(plain);
    g_print("\" -- %s\n", (bracketedOk && plainOk) ? "PASS" : "FAIL");
    return (bracketedOk && plainOk) ? 0 : 1;
}

// Feed an OSC 52 SET whose payload base64-encodes "PASTED" and assert the
// ClipboardClient recorded the decoded bytes — the OSC 52 copy path (Core does
// the base64 decode + routes to ClipboardClient::writeClipboard).
int smokeOSC52()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-osc52: no GTK display; run under xvfb-run\n");
        return 1;
    }
    app().window = gtk_window_new();
    Ubiquitty::Linux::Clipboard::setReadRequestHandler(requestClipboardReadFromGTK);
    activePane()->clipboardClient.setRequester(activePane());
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-osc52: no term\n");
        return 1;
    }
    term->clipboardClient = &activePane()->clipboardClient;
    term->capabilityPolicy = &app().capabilityPolicy; // a null policy answers PAL's defaults, not this frontend's
    // OSC 52 ; c ; <base64> BEL — "UEFTVEVE" is base64("PASTED").
    const char osc[] = "\x1b]52;c;UEFTVEVE\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    const std::string captured = Ubiquitty::Linux::Clipboard::lastSetText();
    const bool didWrite = captured == "PASTED";
    term->capabilityPolicy = nullptr;
    term->osc52ClipboardReadPolicy = Ubiquitty::OSC::ClipboardReadPolicy::Allow;
    const std::array<Ubiquitty::ClipboardItem, 2> items {
        Ubiquitty::ClipboardItem { "text/plain", std::span<const char>("P", 1) },
        Ubiquitty::ClipboardItem { "text/html", std::span<const char>("<b>P</b>", 8) },
    };
    activePane()->clipboardClient.writeClipboardItems(Ubiquitty::ClipboardBuffer::Primary, items);
    std::string reply;
    activePane()->session->setReplySink([](void* context, std::string_view bytes) {
        static_cast<std::string*>(context)->append(bytes);
    },
        &reply);
    const std::string enable = "\033[?2004;5522h";
    activePane()->session->feedBytes({ enable.data(), enable.size() });
    pasteClipboard(gtk_widget_get_primary_clipboard(app().window), Ubiquitty::ClipboardBuffer::Primary);
    const bool didNotify = reply.starts_with("\033]5522;type=read:status=OK:loc=primary\033\\")
        && reply.find("\033[200~") == std::string::npos;
    reply.clear();
    const std::string read = "\033]5522;type=read:loc=primary;dGV4dC9odG1s\033\\";
    activePane()->session->feedBytes({ read.data(), read.size() });
    const gint64 deadline = g_get_monotonic_time() + 2000000;
    while (term->isOSC52ClipboardReadInFlight && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(nullptr, false)) {
        }
        g_usleep(1000);
    }
    const bool didRead = reply.find("mime=dGV4dC9odG1s;PGI+UDwvYj4=") != std::string::npos
        && reply.ends_with("status=DONE\033\\");
    activePane()->session->setReplySink(nullptr, nullptr);
    term->clipboardClient = nullptr;
    const bool didPass = didWrite && didNotify && didRead;
    g_print("smoke-osc52: primary notification=%s, HTML read=%s\n", didNotify ? "PASS" : "FAIL", didRead ? "PASS" : "FAIL");
    g_print("smoke-osc52: clipboard write = \"%s\" -- %s (expected \"PASTED\")\n", captured.c_str(), didPass ? "PASS" : "FAIL");
    Ubiquitty::Linux::Clipboard::setReadRequestHandler(nullptr);
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    return didPass ? 0 : 1;
}

// Feed an OSC 7 and assert the pane recorded the directory the shell named.
//
// The wiring this covers fails silently when it is wrong: a Terminal that
// drops OSC 7 leaves the title to the /proc read, which answers something
// plausible for the wrong process. So the assertion is that the ANNOUNCED
// directory arrived in the session's answer, not that a directory exists.
int smokeOSC7()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-osc7: no term\n");
        return 1;
    }
    const char osc[] = "\x1b]7;file://host/tmp/announced\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    term->capabilityPolicy = nullptr;

    const std::string announced = activePane()->session->currentDirectory();
    const bool didPass = announced.find("/tmp/announced") != std::string::npos;
    g_print("smoke-osc7: announced directory = \"%s\" -- %s (expected to contain \"/tmp/announced\")\n",
        announced.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Assert the capability gate refuses an exfiltrating read to a non-Local
// origin and serves it to a Local one, and answers a feature query for both.
//
// Both arms of the read, because either alone passes against a defect: a policy
// that denies everything looks correct if you only test the refusal, and a
// policy that allows everything looks correct if you only test the allow. The
// feature query is the third arm: programs block on DA for capability
// detection, so a policy that refused it to a Remote peer would stall the
// peer's programs while reading as strict.
//
// Replies are the observable because Core queues them on the terminal, where
// this reads exactly what the gate let through. DECRQCRA checksums cells, which
// is exfiltration; DA reveals nothing past the screen the peer already sees.
int smokeCapabilityOrigin()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-capability-origin: no term\n");
        return 1;
    }
    term->capabilityPolicy = &app().capabilityPolicy;

    const auto replyTo = [term](Ubiquitty::CapabilityOrigin origin, std::string_view query) {
        term->outputLength = 0;
        term->currentCapabilityOrigin = origin;
        Ubiquitty::processBytes(term, query);
        std::string reply(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
        term->outputLength = 0;
        return reply;
    };
    constexpr std::string_view checksumQuery = "\x1b[1;0;1;1;1;1*y";
    constexpr std::string_view attributesQuery = "\x1b[c";
    const std::string remoteChecksum = replyTo(Ubiquitty::CapabilityOrigin::Remote, checksumQuery);
    const std::string localChecksum = replyTo(Ubiquitty::CapabilityOrigin::Local, checksumQuery);
    const std::string remoteAttributes = replyTo(Ubiquitty::CapabilityOrigin::Remote, attributesQuery);

    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    term->capabilityPolicy = nullptr;

    const bool didPass = remoteChecksum.empty() && localChecksum.starts_with("\x1bP1!~") && remoteAttributes.starts_with("\x1b[?");
    g_print("smoke-capability-origin: remote checksum = \"");
    printEscaped(remoteChecksum);
    g_print("\" (expected empty), local checksum = \"");
    printEscaped(localChecksum);
    g_print("\", remote DA = \"");
    printEscaped(remoteAttributes);
    g_print("\" -- %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Focus reporting (DECSET 1004) self-test. Core writes focus reports into the
// Terminal's gtkApplication-bound reply buffer (outputBuffer), so this asserts directly on
// Core: with 1004 ON, setFocused(true)/false must emit CSI I then CSI O; with
// 1004 OFF, no focus bytes are emitted (Core still records windowFocused).
int smokeFocus()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-focus: no term\n");
        return 1;
    }

    // 1004 ON: drive focus in then out, capturing the gtkApplication-bound bytes each time.
    const char enable1004[] = "\x1b[?1004h";
    Ubiquitty::processBytes(term, std::string_view(enable1004, sizeof(enable1004) - 1));
    term->outputLength = 0; // discard any DECSET ack; isolate the focus bytes
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Focused);
    const std::string focusIn(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
    term->outputLength = 0;
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::string focusOut(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
    term->outputLength = 0;

    // 1004 OFF: focus transitions must emit nothing.
    const char disable1004[] = "\x1b[?1004l";
    Ubiquitty::processBytes(term, std::string_view(disable1004, sizeof(disable1004) - 1));
    term->outputLength = 0;
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Focused);
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::string focusOff(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));

    const bool onOk = focusIn == "\x1b[I" && focusOut == "\x1b[O";
    const bool offOk = focusOff.empty();
    g_print("smoke-focus: 1004 ON  focus-in=\"");
    printEscaped(focusIn);
    g_print("\" focus-out=\"");
    printEscaped(focusOut);
    g_print("\"\n");
    g_print("smoke-focus: 1004 OFF focus-in+out=\"");
    printEscaped(focusOff);
    g_print("\" (expected empty)\n");
    const bool didPass = onOk && offOk;
    g_print("smoke-focus: %s (expected ESC[I then ESC[O on; nothing off)\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Relative pointer lock (DECSET 7403) self-test. Headless, through the same
// TerminalSession wrappers main.cpp's PointerLock.cpp wiring calls -- not
// through a real GTK window, which would hide and warp the real cursor of
// whoever is running it. Four legs: the verdict follows mode + focus, a grab
// report reaches the ladder's release lesson, a motion delta is routed as an
// SGR report while a zero delta is swallowed, and the break-out chord held for
// the pinned tick threshold clears the mode.
int smokePointerLock()
{
    // Legs 6 and 7 split panes, and binding a pane publishes its typography
    // from the selected face; the live window sets the faces up before any
    // pane exists, so this smoke does too.
    setupFonts();
    // Pinned for the whole test, not just the chord leg: the ladder captures
    // the chord's armedAtTicks on the REAL clock otherwise, and a later pin
    // to a small tick value then underflows the unsigned subtraction against
    // that large real tick and reads as an already-elapsed hold.
    setenv("UBIQUITTY_FAKE_TICKS", "0", 1);
    Ubiquitty::Runtime::TerminalSession* session = activePane()->session;
    session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = session->terminal();
    if (!term) {
        g_printerr("smoke-pointer-lock: no term\n");
        unsetenv("UBIQUITTY_FAKE_TICKS");
        return 1;
    }

    const char enableModes[] = "\x1b[?1016h\x1b[?7403h";
    Ubiquitty::processBytes(term, std::string_view(enableModes, sizeof(enableModes) - 1));
    bool didPass = term->modes.mouseRelativePointerLock;
    g_print("smoke-pointer-lock: mode-set %s\n", didPass ? "PASS" : "FAIL");

    // Leg 1: the verdict follows mode + focus, not either alone.
    Ubiquitty::Input::PointerLockFacts focused;
    focused.isSurfaceFocused = true;
    Ubiquitty::Input::PointerLockFacts unfocused;
    unfocused.isSurfaceFocused = false;
    const bool didVerdictFollowFocus = session->pointerLockVerdict(focused) == Ubiquitty::Input::PointerLockVerdict::Hold
        && session->pointerLockVerdict(unfocused) == Ubiquitty::Input::PointerLockVerdict::Release;
    g_print("smoke-pointer-lock: verdict-follows-focus %s\n", didVerdictFollowFocus ? "PASS" : "FAIL");
    didPass = didPass && didVerdictFollowFocus;

    // Leg 2: the grab report reaches the ladder's release lesson, and the
    // lesson withdraws with the grab -- through notePointerLockGrab exactly
    // as PointerLock.cpp's applyPointerLock calls it, never the report bytes
    // (an OS grab in a smoke would hide and warp the real cursor).
    const bool isHintNoneAtStart = session->hintShowing() == Ubiquitty::Input::Hint::None;
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    const bool isHintShowingRelease = session->hintShowing() == Ubiquitty::Input::Hint::PointerLockRelease
        && session->hintTicksUntilExpiry() == 0; // a standing lock lesson has no clock; it ends with the grab
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Released);
    const bool didHintWithdraw = session->hintShowing() == Ubiquitty::Input::Hint::None;
    const bool didGrabTeachRelease = isHintNoneAtStart && isHintShowingRelease && didHintWithdraw;
    g_print("smoke-pointer-lock: grab-report-teaches-release %s\n", didGrabTeachRelease ? "PASS" : "FAIL");
    didPass = didPass && didGrabTeachRelease;

    // Leg 3: a motion delta is routed as an SGR report; a sample with no
    // motion is swallowed rather than flooding the host with a zero delta.
    // Through Input::routePointer directly (Core's own function) rather than
    // session->pointerFact: the session's wrapper sends a routed report
    // through the real PTY this headless run has no deterministic way to read
    // back, while a throwaway ladder is equivalent for this assertion -- the
    // locked branch touches no ladder state.
    Ubiquitty::Input::PointerLadder scratchLadder;
    const Ubiquitty::Input::PointerPolicy policy;
    Ubiquitty::Input::PointerFact motion;
    motion.kind = Ubiquitty::Input::PointerFact::Kind::Motion;
    motion.button = Ubiquitty::Input::PointerButton::None;
    motion.deltaX = 5;
    motion.deltaY = -7;
    const Ubiquitty::Input::PointerRoute movedRoute = Ubiquitty::Input::routePointer(scratchLadder, *term, &activePane()->selection, motion, policy, 0);
    const std::string movedReport(movedRoute.report.data(), static_cast<std::size_t>(movedRoute.reportLength));
    const bool isMotionReported = movedRoute.wasConsumed && movedReport.size() >= 3 && movedReport.compare(0, 3, "\x1b[<") == 0;
    motion.deltaX = 0;
    motion.deltaY = 0;
    const Ubiquitty::Input::PointerRoute stillRoute = Ubiquitty::Input::routePointer(scratchLadder, *term, &activePane()->selection, motion, policy, 0);
    const bool isZeroDeltaSwallowed = stillRoute.wasConsumed && stillRoute.reportLength == 0;
    g_print("smoke-pointer-lock: motion-delta-reports \"");
    printEscaped(movedReport);
    g_print("\" zero-delta-swallowed=%d -- %s\n", static_cast<int>(isZeroDeltaSwallowed), (isMotionReported && isZeroDeltaSwallowed) ? "PASS" : "FAIL");
    didPass = didPass && isMotionReported && isZeroDeltaSwallowed;

    // Leg 4: the break-out chord, through Core's pinned clock. Without a
    // grab a bare Control+Command is a real shortcut and must not arm.
    Ubiquitty::Input::PointerLockKeyState chord;
    chord.isControlHeld = true;
    chord.isCommandHeld = true;
    session->notePointerLockChord(chord);
    const bool isUnarmedWithNoGrab = session->pointerLockChordTicksUntilDeadline() == 0;
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    session->notePointerLockChord(chord);
    const std::uint32_t hold = Ubiquitty::Input::pointerLockBreakoutHoldTicks;
    const bool isArmedAtHold = session->pointerLockChordTicksUntilDeadline() == hold;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold - 1).c_str(), 1);
    const bool didKeepShortOfHold = session->tickPointerLockChord(chord) == Ubiquitty::Input::PointerLockChordVerdict::Keep;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold).c_str(), 1);
    const bool didBreakOutAtHold = session->tickPointerLockChord(chord) == Ubiquitty::Input::PointerLockChordVerdict::BreakOut;
    const bool isModeCleared = !term->modes.mouseRelativePointerLock;
    unsetenv("UBIQUITTY_FAKE_TICKS");
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Released); // leave the ladder as this smoke found it
    const bool didChordBreakOut = isUnarmedWithNoGrab && isArmedAtHold && didKeepShortOfHold && didBreakOutAtHold && isModeCleared;
    g_print("smoke-pointer-lock: chord-breaks-out-at-hold(%u) %s\n", hold, didChordBreakOut ? "PASS" : "FAIL");
    didPass = didPass && didChordBreakOut;

    // Legs 5-7 drive this arm's own wiring rather than Core's seams. A
    // headless run has no realized widget, so the OS grab itself is stood in
    // for -- the fields applyPointerLock sets on engage are set by hand and
    // the grab reported -- and what is asserted is everything around it:
    // the key handler's chord report and its wake-up, and the two edges the
    // grab must not survive.
    const auto holdGrabByHand = [&](LinuxPane* pane) {
        app().isPointerLocked = true;
        app().pointerLockPane = pane;
        pane->session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    };
    setenv("UBIQUITTY_FAKE_TICKS", "0", 1);
    Ubiquitty::processBytes(term, std::string_view(enableModes, sizeof(enableModes) - 1));
    holdGrabByHand(activePane());
    const auto pair = static_cast<GdkModifierType>(GDK_CONTROL_MASK | GDK_META_MASK | GDK_SUPER_MASK);
    notePointerLockChordFromKeyEvent(GDK_KEY_Control_L, pair, Ubiquitty::Keys::KeyEventType::Press);
    const bool didKeyHandlerArm = session->pointerLockChordTicksUntilDeadline() == hold && app().pointerLockChordTimerID != 0;
    // A key joining the pair is a shortcut; its release lets the pair arm again.
    notePointerLockChordFromKeyEvent(GDK_KEY_x, pair, Ubiquitty::Keys::KeyEventType::Press);
    const bool didKeyJoiningDisarm = session->pointerLockChordTicksUntilDeadline() == 0;
    notePointerLockChordFromKeyEvent(GDK_KEY_x, pair, Ubiquitty::Keys::KeyEventType::Release);
    const bool didReleaseRearm = session->pointerLockChordTicksUntilDeadline() == hold;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold).c_str(), 1);
    app().pointerLockLastModifiers = pair;
    (void)onPointerLockChordTick(nullptr);
    const bool didTickRelease = !app().isPointerLocked && app().pointerLockPane == nullptr && !term->modes.mouseRelativePointerLock;
    unsetenv("UBIQUITTY_FAKE_TICKS");
    const bool didChordWireThrough = didKeyHandlerArm && didKeyJoiningDisarm && didReleaseRearm && didTickRelease;
    g_print("smoke-pointer-lock: chord-through-key-handler arm=%d joined-disarms=%d release-rearms=%d tick-releases=%d -- %s\n",
        static_cast<int>(didKeyHandlerArm), static_cast<int>(didKeyJoiningDisarm), static_cast<int>(didReleaseRearm),
        static_cast<int>(didTickRelease), didChordWireThrough ? "PASS" : "FAIL");
    didPass = didPass && didChordWireThrough;

    // Leg 6: closing the pane that holds the grab releases it first, so
    // nothing reads a destroyed pane and no cursor is left hidden.
    const SurfaceID surface = app().model->activeSurface();
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const Panes::Tree* tree = app().model->paneTree(surface);
    const bool didSplit = tree != nullptr && tree->paneCount() == 2 && activePane() != nullptr && activePane()->session != nullptr;
    bool didCloseRelease = false;
    // A release that reads the destroyed pane is a use after free that may
    // well look like a release; applyPointerLock says so as a critical, and
    // this leg counts them, so the order of teardown is what is asserted.
    static int criticalCount = 0;
    criticalCount = 0;
    const guint criticalHandler = g_log_set_handler(nullptr, G_LOG_LEVEL_CRITICAL, [](const gchar*, GLogLevelFlags, const gchar* message, gpointer) { ++criticalCount; g_printerr("smoke-pointer-lock: critical: %s\n", message); }, nullptr);
    if (didSplit) {
        holdGrabByHand(activePane());
        closeFocusedPaneUX();
        const Panes::Tree* after = app().model->paneTree(surface);
        didCloseRelease = !app().isPointerLocked && app().pointerLockPane == nullptr && after != nullptr && after->paneCount() == 1 && criticalCount == 0;
    }
    g_log_remove_handler(nullptr, criticalHandler);
    g_print("smoke-pointer-lock: pane-close-releases split=%d criticals=%d -- %s\n", static_cast<int>(didSplit), criticalCount, didCloseRelease ? "PASS" : "FAIL");
    didPass = didPass && didCloseRelease;

    // Leg 7: a focus move to a pane whose program never asked releases the
    // grab the pane the focus left was holding.
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const Panes::Tree* tree2 = app().model->paneTree(surface);
    bool didFocusMoveRelease = false;
    if (tree2 != nullptr && tree2->paneCount() == 2 && activePane() != nullptr && activePane()->session != nullptr) {
        LinuxPane* holder = activePane();
        holdGrabByHand(holder);
        moveFocusUX(Panes::Direction::Left);
        if (activePane() == holder)
            moveFocusUX(Panes::Direction::Right);
        didFocusMoveRelease = activePane() != holder && !app().isPointerLocked && app().pointerLockPane == nullptr;
    }
    g_print("smoke-pointer-lock: focus-move-releases -- %s\n", didFocusMoveRelease ? "PASS" : "FAIL");
    didPass = didPass && didFocusMoveRelease;

    g_print("smoke-pointer-lock: overall %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Clickable-hyperlink self-test. Feeds an OSC 8 hyperlink around some text,
// finds the stamped cell, and asserts its link id resolves back to the URI
// through the Terminal's link table — the OSC 8 resolve path the click/hover use.
// Then asserts the portable launch allowlist (the gate the click applies before
// gtk_show_uri): safe network schemes and file accepted, javascript rejected.
// Then what a press does with what it finds (linkDispatchAtCell): a plain click
// opens a declared link and not a guessed one, Ctrl opens either, and a second
// press opens nothing. Then what a click may do with a file link
// (linkDispatchForURI), over real files in a scratch directory: a document, a
// directory, text with a stray execute bit, extensionless names a repository
// holds, media, a Latin-1 name and file:/path open, a script, a desktop entry
// and a symbolic link to a script are only revealed, and a pipe, a missing
// path, a query, a
// fragment that names no line, another machine's authority and a hidden
// character are refused, while a name spelled with a joiner opens. Then a link
// that names a line: the ordinary rule with no line handler, and with one the
// handler's argv, built from the canonical path, which it is started with.
// Nothing is opened: each decision is asked for and not acted on, but for the
// line handler, which is `ln -s` recording the argument it receives.
int smokeLink()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-link: no term\n");
        return 1;
    }

    // OSC 8 open (uri https://example.com) → "link" → OSC 8 close. The stamped
    // cells carry the interned link id; the closing sequence clears it.
    const char osc8[] = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(osc8, sizeof(osc8) - 1));

    // Cell (0, 0) is the 'l' of "link"; it must carry a non-zero link id that
    // resolves to the OSC 8 URI.
    const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const uint16_t id = (cell != nullptr) ? cell->linkID() : 0;
    const char* resolved = (id != 0) ? Ubiquitty::Attributes::Hyperlinks::uri(term, id) : nullptr;
    const std::string uri = (resolved != nullptr) ? resolved : "";
    const bool osc8Ok = uri == "https://example.com";

    // Allowlist gate — the one portable helper both frontends share.
    const bool acceptHttps = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("https://x");
    const bool acceptHttp = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("http://x");
    const bool acceptFile = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("file:///etc/passwd");
    const bool didRejectJavaScript = !Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("javascript:alert(1)");

    g_print("smoke-link: OSC 8 cell linkID=%u resolved=\"%s\" -- %s\n", static_cast<unsigned>(id), uri.c_str(), osc8Ok ? "PASS" : "FAIL");
    g_print("smoke-link: allowlist https://x=%s http://x=%s "
            "file:///etc/passwd=%s javascript:alert(1)=%s\n",
        acceptHttps ? "accept" : "reject", acceptHttp ? "accept" : "reject", acceptFile ? "accept" : "reject", didRejectJavaScript ? "reject" : "accept");

    bool didPass = osc8Ok && acceptHttps && acceptHttp && acceptFile && didRejectJavaScript;
    using Ubiquitty::Attributes::LinkRun::LocalLinkAction;
    const auto expect = [&](bool isMet, const char* what) {
        g_print("smoke-link: %s -- %s\n", what, isMet ? "PASS" : "FAIL");
        didPass = didPass && isMet;
    };

    // Row 1 carries a URL the program never declared.
    Ubiquitty::processBytes(term, "\r\nsee https://example.com/guess here");
    const GdkModifierType plain = static_cast<GdkModifierType>(0);
    expect(linkDispatchAtCell(0, 1, plain, 1).action == LocalLinkAction::Open, "a plain click opens a declared link");
    expect(linkDispatchAtCell(1, 8, plain, 1).action == LocalLinkAction::Refuse, "a plain click leaves a guessed link alone");
    expect(linkDispatchAtCell(1, 8, GDK_CONTROL_MASK, 1).target == "https://example.com/guess", "Ctrl opens a guessed link");
    expect(linkDispatchAtCell(0, 1, plain, 2).action == LocalLinkAction::Refuse, "the second press of a double-click opens nothing");
    // The hand over the guess follows Ctrl as it goes down and up, as the
    // click does: the hover re-asks with the key's edge applied.
    std::array<char, Ubiquitty::VT::maxLinkURILength> guessed {};
    const LinkSource guess = linkURIAtCell(1, 8, guessed.data(), static_cast<int>(guessed.size()));
    using Ubiquitty::Keys::KeyEventType;
    expect(linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Control_L, plain, KeyEventType::Press)),
        "pressing Ctrl over a guess raises the hand");
    expect(!linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Control_R, GDK_CONTROL_MASK, KeyEventType::Release)),
        "and letting it go lowers it");
    expect(!linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Shift_L, plain, KeyEventType::Press)), "while Shift is not Ctrl");
    // And through the key handlers GTK calls, which is where the re-ask is
    // wired: a pointer resting over the guess, then Ctrl down and up as the
    // key controller delivers them. A picture with no window takes the cursor,
    // and making one takes GTK, which takes a display.
    if (!gtk_init_check()) {
        expect(false, "GTK has a display for the key handlers; run under xvfb-run");
    } else {
        GtkWidget* picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
        app().focusedPicture = picture;
        app().hoverX = (8.5 * app().rasterContext.cellWidth()) / app().scale;
        app().hoverY = (1.5 * app().rasterContext.cellHeight()) / app().scale;
        app().isHoverPointKnown = true;
        app().hoverCursorShape = Ubiquitty::MousePointerShape::Default;
        int hoverRow = -1;
        int hoverColumn = -1;
        cellAtPoint(app().hoverX, app().hoverY, hoverRow, hoverColumn);
        expect(hoverRow == 1 && hoverColumn == 8, "the resting pointer is over the guess");
        onKeyPressed(nullptr, GDK_KEY_Control_L, 0, plain, nullptr);
        expect(app().hoverCursorShape == Ubiquitty::MousePointerShape::Pointer, "Ctrl going down over a guess raises the hand");
        onKeyReleased(nullptr, GDK_KEY_Control_L, 0, GDK_CONTROL_MASK, nullptr);
        expect(app().hoverCursorShape != Ubiquitty::MousePointerShape::Pointer, "and Ctrl coming up lowers it");
        app().isHoverPointKnown = false;
        app().focusedPicture = nullptr;
        g_object_unref(picture);
    }
    // A declared connection to a host waits for Ctrl.
    Ubiquitty::processBytes(term, "\r\n\x1b]8;;ssh://build.example\x1b\\SSH\x1b]8;;\x1b\\");
    expect(linkDispatchAtCell(2, 1, plain, 1).action == LocalLinkAction::Refuse, "a plain click leaves a declared ssh link alone");
    expect(linkDispatchAtCell(2, 1, GDK_CONTROL_MASK, 1).target == "ssh://build.example", "Ctrl opens it");

    // Real files, so the stat and the content type are the ones a click reads.
    GError* error = nullptr;
    gchar* scratch = g_dir_make_tmp("ubq-smoke-link-XXXXXX", &error);
    if (scratch == nullptr) {
        g_printerr("smoke-link: no scratch directory: %s\n", error != nullptr ? error->message : "unknown");
        g_clear_error(&error);
        g_print("smoke-link: FAIL\n");
        return 1;
    }
    std::array<char, PATH_MAX> canonicalScratch {};
    const bool hasCanonicalScratch = realpath(scratch, canonicalScratch.data()) != nullptr;
    const std::string directory = hasCanonicalScratch ? canonicalScratch.data() : scratch;
    const auto writeFile = [&](const char* name, const char* contents, mode_t mode) {
        const std::string path = directory + "/" + name;
        g_file_set_contents(path.c_str(), contents, -1, nullptr);
        chmod(path.c_str(), mode);
        return path;
    };
    const auto uriFor = [](const std::string& path) {
        gchar* uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
        std::string result = uri != nullptr ? uri : "";
        g_free(uri);
        return result;
    };
    const std::string notes = writeFile("notes.txt", "notes\n", 0644);
    const std::string runnable = writeFile("run.txt", "notes\n", 0755);
    const std::string launcher = writeFile("launch", "#!/bin/sh\necho launched\n", 0755);
    const std::string entry = writeFile("tool.desktop", "[Desktop Entry]\nType=Application\nExec=true\n", 0644);
    const std::string folder = directory + "/folder";
    const std::string disguise = directory + "/innocent.txt";
    const std::string pipe = directory + "/pipe.txt";
    const bool isScratchReady = hasCanonicalScratch && mkdir(folder.c_str(), 0755) == 0
        && symlink(launcher.c_str(), disguise.c_str()) == 0 && mkfifo(pipe.c_str(), 0644) == 0;
    expect(isScratchReady, "the scratch files are in place");

    const LinkDispatch document = linkDispatchForURI(uriFor(notes));
    expect(document.action == LocalLinkAction::Open && document.target == uriFor(notes), "a document opens");
    expect(linkDispatchForURI(uriFor(folder)).action == LocalLinkAction::Open, "a directory opens");
    const LinkDispatch strayBit = linkDispatchForURI(uriFor(runnable));
    expect(strayBit.action == LocalLinkAction::Open && strayBit.target == uriFor(runnable),
        "a stray execute bit on a file GIO types as text does not make it reveal-only");
    const LinkDispatch executable = linkDispatchForURI(uriFor(launcher));
    expect(executable.action == LocalLinkAction::Reveal && executable.target == launcher, "a script with no extension is revealed");
    expect(linkDispatchForURI(uriFor(entry)).action == LocalLinkAction::Reveal, "a desktop entry is revealed");
    const LinkDispatch followed = linkDispatchForURI(uriFor(disguise));
    expect(followed.action == LocalLinkAction::Reveal && followed.target == launcher, "a link is judged by what it points at");
    expect(linkDispatchForURI(uriFor(pipe)).action == LocalLinkAction::Refuse, "a pipe is refused");
    expect(linkDispatchForURI(uriFor(directory + "/missing.txt")).action == LocalLinkAction::Refuse, "a missing path is refused");
    expect(linkDispatchForURI(uriFor(notes) + "?open").action == LocalLinkAction::Refuse, "a query is refused");
    expect(linkDispatchForURI(uriFor(notes) + "#run").action == LocalLinkAction::Refuse, "a fragment is refused");
    const std::string own = "file://" + Ubiquitty::PAL::systemHostName() + notes;
    expect(linkDispatchForURI(own).action == LocalLinkAction::Open, "this machine's name in the authority opens");
    expect(linkDispatchForURI("file://elsewhere.invalid" + notes).action == LocalLinkAction::Refuse, "another machine's name is refused");
    expect(linkDispatchForURI("https://example.com/\xE2\x80\xAEtxt.exe").action == LocalLinkAction::Refuse, "a hidden character is refused");
    expect(linkDispatchForURI("javascript:alert(1)").action == LocalLinkAction::Refuse, "an unlisted scheme is refused");
    // A joiner spells a name rather than hiding part of one: an emoji ZWJ
    // file name, linked raw as a program prints it, opens.
    const std::string joined = writeFile("\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x92\xBB notes.txt", "notes\n", 0644);
    const LinkDispatch joinedDispatch = linkDispatchForURI("file://" + joined);
    expect(joinedDispatch.action == LocalLinkAction::Open && joinedDispatch.target == uriFor(joined), "an emoji ZWJ file name opens");
    // U+0645 U+06CC U+200C U+062E U+0648 U+0627 U+0647 U+0645, a Persian word.
    expect(linkDispatchForURI("https://fa.wikipedia.org/wiki/\xD9\x85\xDB\x8C\xE2\x80\x8C\xD8\xAE\xD9\x88\xD8\xA7\xD9\x87\xD9\x85").action
            == LocalLinkAction::Open,
        "a Persian page written with a non-joiner opens");

    // Ordinary files the display-only rule reaches: names a repository holds
    // with no extension, video, a name that is Latin-1 rather than UTF-8, and
    // the file:/path form Java writes.
    std::vector<std::string> ordinary;
    for (const char* name : { "README", "Makefile", ".gitignore", ".env", "clip.mp4", "caf\xE9.txt" })
        ordinary.push_back(writeFile(name, "plain\n", 0644));
    for (const std::string& path : ordinary) {
        const LinkDispatch dispatch = linkDispatchForURI(uriFor(path));
        const std::string what = "an ordinary " + Ubiquitty::Attributes::LinkRun::escapedDeceptiveLinkCharacters(path.substr(directory.size() + 1)) + " opens";
        expect(dispatch.action == LocalLinkAction::Open && dispatch.target == uriFor(path), what.c_str());
    }
    // Audio is revealed: the rule is Core's, and a Mac's handler for it
    // imports what it opens into the reader's library.
    const std::string song = writeFile("song.mp3", "plain\n", 0644);
    expect(linkDispatchForURI(uriFor(song)).action == LocalLinkAction::Reveal, "an mp3 is revealed");
    expect(linkDispatchForURI("file:" + notes).target == uriFor(notes), "file:/path with no authority opens");
    // A page is revealed wherever its name came from: GIO reads a .conf
    // holding HTML as text/html, and the browser that type opens in runs it.
    const std::string page = writeFile("report.conf", "<html><script>alert(1)</script></html>\n", 0644);
    const std::string feed = writeFile("pom.xml", "<project/>\n", 0644);
    expect(linkDispatchForURI(uriFor(page)).action == LocalLinkAction::Reveal, "HTML under a configuration name is revealed");
    expect(linkDispatchForURI(uriFor(feed)).action == LocalLinkAction::Reveal, "XML, which a browser runs as XHTML, is revealed");
    // The volume rule: a scratch directory keeps permissions, and the EFI
    // system partition, where a machine mounts one, is FAT and keeps none.
    expect(!isOnVolumeWithoutPermissions(directory.c_str()), "the scratch volume keeps permissions");
    struct statfs efi {};
    if (statfs("/boot/efi", &efi) == 0 && efi.f_type == MSDOS_SUPER_MAGIC)
        expect(isOnVolumeWithoutPermissions("/boot/efi"), "a FAT volume keeps none");

    // A link that names a line. With no line handler it meets the ordinary
    // rule; with one, the handler is handed the canonical path the click
    // judged and the line, never the URI as printed.
    const LinkDispatch plainLine = linkDispatchForURI(uriFor(notes) + "#L12-L20");
    expect(plainLine.action == LocalLinkAction::Open && plainLine.target == uriFor(notes) && plainLine.lineHandler.empty(),
        "a line link opens the file when no line handler is configured");
    const std::string script = writeFile("build.sh", "#!/bin/sh\necho built\n", 0755);
    const std::string scriptLink = directory + "/latest.sh";
    const std::string recorded = directory + "/received";
    const bool isScriptLinked = symlink(script.c_str(), scriptLink.c_str()) == 0;
    (void)Ubiquitty::Preferences::configure("[links]\nline_handler = \"/bin/ln -s {path}:{line}:{column} " + recorded + "\"\n",
        Ubiquitty::Preferences::ParseMode::Strict);
    const LinkDispatch atLine = linkDispatchForURI(uriFor(scriptLink) + "#12:5");
    const Ubiquitty::Attributes::LinkRun::HandlerArgv expectedHandler { "/bin/ln", "-s", script + ":12:5", recorded };
    expect(isScriptLinked && atLine.lineHandler == expectedHandler && atLine.action == LocalLinkAction::Reveal && atLine.target == script,
        "a script a search found goes to the line handler at its canonical path, which the opener would only reveal");
    expect(linkDispatchForURI(uriFor(folder) + "#12").lineHandler.empty(), "a line names nothing in a directory");
    expect(linkDispatchForURI(uriFor(script) + "#run").action == LocalLinkAction::Refuse, "a fragment that is not a line is refused");
    // The handler runs through no shell, and `ln -s` records the one argument
    // it was handed as the link's destination.
    expect(spawnWithoutShell(atLine.lineHandler, "line handler"), "the line handler starts");
    std::array<char, PATH_MAX> received {};
    for (int attempt = 0; attempt < 100 && readlink(recorded.c_str(), received.data(), received.size() - 1) < 0; ++attempt)
        g_usleep(20'000);
    expect(std::string(received.data()) == script + ":12:5", "the line handler received the checked path and the line as one argument");
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);

    for (const std::string& path : { notes, runnable, launcher, entry, disguise, pipe, joined, script, scriptLink, recorded, page, feed })
        unlink(path.c_str());
    for (const std::string& path : ordinary)
        unlink(path.c_str());
    rmdir(folder.c_str());
    rmdir(scratch);
    g_free(scratch);

    g_print("smoke-link: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-ime — the IME inline-preedit plumbing (Stage 12). Feeds "abc" (cursor →
// column 3), sets a pre-edit, and asserts the shared snapshotVisibleGrid overlays the
// composing codepoints underlined at the cursor (the path both render backends
// take), that clearing restores the cells, and that the UTF-8 → codepoint decode
// the commit/preedit handlers use round-trips a multibyte string. The live IM
// (ibus/fcitx) interaction needs a display + IM module and is verified by hand.
int smokeIME()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-ime: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "abc"); // cursor now at row 0, column 3
    const int cursorColumn = term->screens.active->cursorX;

    // Inline preedit: two ASCII codepoints injected at the cursor, underlined.
    const std::uint32_t preedit[] = { 'n', 'i' };
    app().rasterContext.setPreedit(preedit, 2);
    std::vector<Ubiquitty::Cell> grid;
    app().rasterContext.snapshotVisibleGrid(term, 0, grid);
    const Ubiquitty::Cell& c0 = grid[static_cast<size_t>(cursorColumn)];
    const Ubiquitty::Cell& c1 = grid[static_cast<size_t>(cursorColumn) + 1];
    const bool isInjected = c0.codePoint == 'n' && Ubiquitty::cellPen(c0).attributes.contains(Ubiquitty::VT::Attribute::Underline) && c1.codePoint == 'i' && Ubiquitty::cellPen(c1).attributes.contains(Ubiquitty::VT::Attribute::Underline);

    // Clearing the preedit restores the (blank) cells under it.
    app().rasterContext.setPreedit(nullptr, 0);
    app().rasterContext.snapshotVisibleGrid(term, 0, grid);
    const bool cleared = grid[static_cast<size_t>(cursorColumn)].codePoint == 0;

    // The UTF-8 decode the handlers use: "ní好" → 'n', U+00ED, U+597D.
    const std::vector<std::uint32_t> decoded = codePointsFromUTF8("n\xC3\xAD\xE5\xA5\xBD");
    const bool decodeOk = decoded.size() == 3 && decoded[0] == 'n' && decoded[1] == 0x00ED && decoded[2] == 0x597D;

    const bool didPass = isInjected && cleared && decodeOk;
    g_print("smoke-ime: preedit injected=%d cleared=%d utf8-decode=%d (n=%zu) -- %s\n", static_cast<int>(isInjected), static_cast<int>(cleared), static_cast<int>(decodeOk), decoded.size(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// The compose engine, driven as the key handler drives it: a sequence it
// finishes and encodes, one it refuses at the first key, and one given up
// before its end.
int smokeCompose()
{
    using Ubiquitty::Input::ComposeResult;
    Ubiquitty::Input::ComposeEngine engine;

    // Acute then e: pending after the first key, é after the second.
    engine.begin();
    const bool awaitsSecondKey = engine.feed('\'') == ComposeResult::Pending;
    const bool composesAcuteE = engine.feed('e') == ComposeResult::Composed && engine.result() == 0x00E9u;
    std::string encoded;
    Ubiquitty::Unicode::appendUTF8(encoded, engine.result());
    const bool encodesAsUTF8 = encoded == "\xC3\xA9";

    // A key no sequence starts with ends the attempt at once.
    engine.begin();
    const bool refusesUnknownStart = engine.feed('q') == ComposeResult::Invalid && !engine.active();

    // A reset mid-sequence leaves the engine inactive, so the next key is not taken.
    engine.begin();
    (void)engine.feed('~');
    engine.reset();
    const bool cancelsCleanly = !engine.active() && engine.feed('n') == ComposeResult::Inactive;

    const bool didPass = awaitsSecondKey && composesAcuteE && encodesAsUTF8 && refusesUnknownStart && cancelsCleanly;
    g_print("smoke-compose: pending=%d composed=%d utf8=%d invalid=%d cancelled=%d -- %s\n",
        static_cast<int>(awaitsSecondKey), static_cast<int>(composesAcuteE), static_cast<int>(encodesAsUTF8),
        static_cast<int>(refusesUnknownStart), static_cast<int>(cancelsCleanly), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-find — the find-bar search path (Stage 13). Feeds 40 numbered lines,
// then drives the same runSearch / step logic the GtkSearchEntry signals use
// (no GTK widgets needed — showSearchOutcome skips a null label), and
// asserts: a unique pattern yields 1 match whose highlighted visible row actually
// reads that text (scroll-to + selection landed right); a shared prefix yields the
// right count; next/prev step + wrap the active index; a bad pattern returns -1;
// an empty pattern clears the search + highlight.
int smokeFind()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-find: no term\n");
        return 1;
    }
    std::string feed;
    for (int i = 0; i < 40; ++i) {
        char line[16];
        std::snprintf(line, sizeof(line), "line%02d\r\n", i);
        feed += line;
    }
    Ubiquitty::processBytes(term, feed);

    // A selection the user made before searching. It must survive every search
    // below: the match's emphasis is its own bake, so nothing here has cause to
    // touch the selection, and a find bar that clears it destroys work.
    activePane()->selection.state.active = true;
    activePane()->selection.state.mode = Ubiquitty::SelectionMode::Character;
    activePane()->selection.state.anchorRow = 0;
    activePane()->selection.state.anchorColumn = 0;
    activePane()->selection.state.headRow = 0;
    activePane()->selection.state.headColumn = 3;

    // Unique match: count 1, and the row the builder is told to bake reads
    // "line05". Asserted on the spans themselves rather than on the selection —
    // the spans are what reaches the renderer, so a proxy that stopped tracking
    // them would pass while nothing was emphasised.
    Ubiquitty::Runtime::TerminalSession* session = activePane()->session;
    const auto unique = runSearchAndWait(session, "line05");
    std::vector<Ubiquitty::Rendering::SelectionRowSpan> searchSpans;
    const auto collectSpans = [&] {
        const auto hold = holdPaneModel(*activePane());
        Ubiquitty::Rendering::collectSearchMatchRowSpans(*term, activePane()->viewOffset, searchSpans);
    };
    collectSpans();
    const std::string highlighted = searchSpans.empty() ? std::string() : visibleRowText(*term, activePane()->viewOffset, searchSpans[0].visibleRow, 6);
    const bool didFindUniqueMatch = unique.foundCount == 1 && searchSpans.size() == 1 && highlighted == "line05";

    // Shared prefix "line0" → line00..line09 = 10 matches, active starts at 0.
    const auto prefix = runSearchAndWait(session, "line0");
    const bool didCountPrefixMatches = prefix.foundCount == 10 && prefix.activeIndex == 0;

    // next steps forward; prev steps back, and from index 0 wraps to the last
    // (9). The same pattern again would not reset the active index: a repeated
    // request does not restart the search, so the walk back goes through 0.
    const bool didStepToNext = onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Forward).activeIndex == 1;
    const bool didStepBack = onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Backward).activeIndex == 0;
    const bool didWrapToLast = didStepBack && onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Backward).activeIndex == 9;

    const auto bad = runSearchAndWait(session, "[unterminated");
    collectSpans();
    const bool didRejectBadPattern = bad.isPatternInvalid && searchSpans.empty();

    const auto empty = runSearchAndWait(session, "");
    collectSpans();
    const bool didClearOnEmpty = empty.foundCount == 0 && searchSpans.empty();

    // The selection set before the first search is still exactly where it was.
    const bool didKeepSelection = activePane()->selection.state.active && activePane()->selection.state.headColumn == 3;

    const bool didPass = didFindUniqueMatch && didCountPrefixMatches && didStepToNext && didWrapToLast && didRejectBadPattern && didClearOnEmpty && didKeepSelection;
    g_print("smoke-find: unique=%d(\"%s\") prefix=%d next=%d wrap=%d bad=%d empty=%d selection-kept=%d -- %s\n", static_cast<int>(didFindUniqueMatch), highlighted.c_str(), static_cast<int>(didCountPrefixMatches), static_cast<int>(didStepToNext), static_cast<int>(didWrapToLast), static_cast<int>(didRejectBadPattern), static_cast<int>(didClearOnEmpty), static_cast<int>(didKeepSelection), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-rectsel — rectangular (column-block) selection (Stage 13). Feeds a 3x5
// grid, drives the same gesture path the Alternate-drag uses (hasAlternate → RECT), and
// asserts the extraction is the column block "BCD/GHI/LMN" (not the linear span a
// plain char-drag of the same endpoints would yield). The portable Selection model
// owns the RECT clip; this verifies the Linux frontend opts into it.
int smokeRectSelection()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-rectsel: no term\n");
        return 1;
    }
    const char* screen = "ABCDE\r\nFGHIJ\r\nKLMNO";
    Ubiquitty::processBytes(term, screen);

    // Alternate-drag from (0,1) to (2,3) through the facade: a rectangular
    // column-block selection, the style the ladder builds from hasAlternate.
    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::GestureStyle rectStyle;
    rectStyle.isRectangular = true;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, rectStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const bool isRect = Ubiquitty::Selection::isRectangular(&activePane()->selection.state);
    const std::string rectText = selectionText();

    // Same endpoints, plain char-drag (Alternate off) for contrast — a linear span.
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const std::string charText = selectionText();

    std::string rectShown = rectText;
    for (char& c : rectShown)
        if (c == '\n')
            c = '/';
    const bool didPass = isRect && rectText == "BCD\nGHI\nLMN" && charText != rectText;
    g_print("smoke-rectsel: isRect=%d rect=\"%s\" differs-from-linear=%d -- %s\n", static_cast<int>(isRect), rectShown.c_str(), static_cast<int>(charText != rectText), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-smartclick — smart double-click token detection (the gate selectionOperationBeginWord
// uses when config.smart_double_click is on). Feeds a line with a URL, a path, and
// plain words, and asserts smartTokenSpanAtCell selects the WHOLE URL / path token
// when the click lands inside it, and reports no token on a plain word.
int smokeSmartClick()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-smartclick: no term\n");
        return 1;
    }
    const char* line = "see https://example.com/x now and /usr/local/bin too";
    Ubiquitty::processBytes(term, line);

    auto spanText = [&](int column0, int column1) {
        std::string outputBuffer;
        for (int column = column0; column <= column1; ++column) {
            const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, column);
            const uint32_t codePoint = (cell != nullptr) ? cell->codePoint : static_cast<uint32_t>(' ');
            outputBuffer.push_back((codePoint >= 0x20 && codePoint < 0x7F) ? static_cast<char>(codePoint) : '?');
        }
        return outputBuffer;
    };

    const auto urlSpan = smartTokenSpanAtCell(0, 10); // column 10 is inside the URL
    const std::string urlText = urlSpan ? spanText(urlSpan->first, urlSpan->last) : std::string();
    const auto pathSpan = smartTokenSpanAtCell(0, 40); // column 40 is inside the path
    const std::string pathText = pathSpan ? spanText(pathSpan->first, pathSpan->last) : std::string();
    const bool hasNoTokenOnAPlainWord = !smartTokenSpanAtCell(0, 1); // column 1 = 'e' of "see"

    const bool didPass = urlSpan && urlText == "https://example.com/x" && pathSpan && pathText == "/usr/local/bin" && hasNoTokenOnAPlainWord;
    g_print("smoke-smartclick: url=\"%s\" path=\"%s\" word-has-no-token=%d -- %s\n", urlText.c_str(), pathText.c_str(), static_cast<int>(hasNoTokenOnAPlainWord), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-titlebuild — the rich window title's platform-resolved leading directory
// segment (the only non-portable bit; formatChain/formatTitle are host-tested Core),
// plus a sanity check that formatTitle assembles the segments. The live process
// chain needs a real PTY and is verified by hand.
int smokeStatusTitle()
{
    activePane()->session->start(startupRows, startupColumns);
    auto* terminal = activePane()->session->terminal();
    if (!terminal) {
        return 1;
    }
    (void)Ubiquitty::Preferences::configure("[title]\ntab_dimensions = false\ntab_program_status = true\n", Ubiquitty::Preferences::ParseMode::Strict);
    Ubiquitty::processBytes(terminal, "\x1b]2;Build\x07\x1b]21337;indicator=#5f87ff;status=Waiting\x07");
    bool didPass = buildTabLabel(*activePane(), 0).find("Waiting") != std::string::npos;
    activePane()->hasUnheardBell = true;
    didPass = didPass && buildTabLabel(*activePane(), 0).starts_with("🔔 ");
    (void)Ubiquitty::Preferences::configure("[title]\ntab_dimensions = false\ntab_program_status = false\n", Ubiquitty::Preferences::ParseMode::Strict);
    didPass = didPass && buildTabLabel(*activePane(), 0).find("Waiting") == std::string::npos;
    onFocusEnter(nullptr, nullptr);
    didPass = didPass && !activePane()->hasUnheardBell && !buildTabLabel(*activePane(), 0).starts_with("🔔 ");
    g_print("smoke-status-title: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

int smokeTitleBuild()
{
    struct Case {
        const char* cwd;
        const char* home;
        bool fullPath;
        const char* want;
    };
    const Case cases[] = {
        { "/home/user/Projects/ubiquitty", "/home/user", false, "ubiquitty" }, // basename
        { "/home/user", "/home/user", false, "~" }, // exactly home → ~
        { "/home/user/Projects", "/home/user", true, "~/Projects" }, // full ~-path
        { "/var/log/", "/home/user", false, "log" }, // trailing slash trimmed
        { "", "/home/user", false, "" }, // no directory
    };
    bool leadOk = true;
    std::string detail;
    for (const Case& testCase : cases) {
        const std::string got = titleDirectorySegment(testCase.cwd, testCase.home, testCase.fullPath ? Ubiquitty::Title::PathFormat::FullPath : Ubiquitty::Title::PathFormat::BasenameOnly);
        if (got != testCase.want)
            leadOk = false;
        detail += "[" + std::string(testCase.cwd) + "→" + got + "]";
    }

    // Integration sanity: formatTitle weaves the segments together (exact glyphs +
    // empty-segment dropping are host-tested in Core); here just confirm each
    // non-empty segment survives.
    const std::string title = Ubiquitty::PAL::Process::formatTitle("ubiquitty", "vim", "zsh", 80, 24, Ubiquitty::PAL::Process::DimensionFormat::IncludeDimensions, Ubiquitty::PAL::Process::TitleSeparator::Spaced);
    const bool titleOk = title.find("ubiquitty") != std::string::npos && title.find("vim") != std::string::npos && title.find("zsh") != std::string::npos && title.find("80") != std::string::npos && title.find("24") != std::string::npos;

    const bool didPass = leadOk && titleOk;
    g_print("smoke-titlebuild: lead=%d %s title=\"%s\" -- %s\n", static_cast<int>(leadOk), detail.c_str(), title.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-inspector — the process-inspector row format over the portable
// PAL::Process::marker policy. The live tree needs a real PTY (verified by hand);
// here, synthetic records assert the marker column: "$"/"#" (root) login shell,
// "•" for not-safe-to-close, none for an allowlisted process.
int smokeInspector()
{
    auto record = [](const char* name, std::uint32_t processID, bool leader, const char* user) {
        Ubiquitty::PAL::Process::Record r {};
        r.name = name;
        r.user = user;
        r.processID = processID;
        r.isSessionLeader = leader ? 1 : 0;
        return r;
    };
    const std::string loginRow = formatProcessRow(record("-zsh", 100, true, "user"));
    const std::string rootRow = formatProcessRow(record("-bash", 1, true, "root"));
    const std::string vimRow = formatProcessRow(record("vim", 200, false, "user"));
    const std::string sshRow = formatProcessRow(record("ssh", 300, false, "user"));

    const bool hasLoginRow = loginRow == "$ -zsh (100)";
    const bool hasRootRow = rootRow == "# -bash (1)";
    // "vim" isn't safe-to-close → a "•" marker precedes the name (multibyte; just
    // assert a marker prefix + the name/processID tail).
    const bool hasVimMarker = vimRow.find("vim (200)") != std::string::npos && !vimRow.starts_with("vim");
    const bool hasWhitelistedSSH = sshRow == "ssh (300)"; // whitelisted → no marker

    const bool didPass = hasLoginRow && hasRootRow && hasVimMarker && hasWhitelistedSSH;
    g_print("smoke-inspector: login=\"%s\" root=\"%s\" vim=\"%s\" ssh=\"%s\" -- %s\n", loginRow.c_str(), rootRow.c_str(), vimRow.c_str(), sshRow.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-image — the inline-image draw path (Stage 11a, CPU half). Feeds a tiny
// solid-red DEC sixel at home, renders the screen via the CPU SoftwareRenderer to
// /tmp/image.png, then asserts the image region is RED (the sixel pixels) rather
// than the terminal background. Prints the resolved placement rect + a sampled
// pixel + PASS/FAIL. Leaves /tmp/image.png on disk.
int smokeImage()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image: no term\n");
        return 1;
    }

    // DEC sixel: P1;P2;P3 q  #1;2;100;0;0  (reg 1 = 100% red)  #1  !16~  ST.
    // #1 selects reg 1; "!16~" repeats the all-six-bits column 16 times, so the
    // image is 16px wide x 6px tall (one cell row) of solid red. P2=0 (opaque
    // background) so unpainted pixels would be color 0, but every pixel here is
    // painted red.
    const char sixel[] = "\x1bP0;0;0q#1;2;100;0;0#1!16~\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(sixel, sizeof(sixel) - 1));

    // An image shorter than a cell leaves the cursor on the cell it was
    // placed from, and the block cursor draws over the over-text images. The
    // cursor is hidden so the sample reads the image the pass composited.
    Ubiquitty::processBytes(term, "\x1b[?25l");

    const int placements = Ubiquitty::Image::placementCount(term);
    const Ubiquitty::Image::TerminalImage* img = Ubiquitty::Image::stored(term, 0);
    if (placements < 1 || !img) {
        g_printerr("smoke-image: sixel did not produce a placement (count=%d)\n", placements);
        return 1;
    }
    g_print("smoke-image: decoded image %dx%d format=%u, placements=%d\n", static_cast<int>(img->width), static_cast<int>(img->height), static_cast<unsigned>(img->format), placements);

    // Resolve the placement to a device-pixel rect the same way the renderer
    // does (origin 0,0, scale 1, the runtime cell), for the report + the sample
    // location.
    const int cellWidth = app().rasterContext.cellWidth();
    const int cellHeight = app().rasterContext.cellHeight();
    Ubiquitty::Image::ImageQuad quad[Ubiquitty::Image::maxTerminalImagePlacementCount];
    const int resolved = Ubiquitty::Rendering::collectImageQuads(term, { static_cast<float>(cellWidth), static_cast<float>(cellHeight) }, { 0.0f, 0.0f }, 1.0f, 0, { quad, static_cast<std::size_t>(Ubiquitty::Image::maxTerminalImagePlacementCount) });
    if (resolved < 1) {
        g_printerr("smoke-image: resolveImagePlacements returned 0\n");
        return 1;
    }
    g_print("smoke-image: placement rect = [%.1f,%.1f .. %.1f,%.1f] (cell %dx%d)\n", quad[0].minXInPixels, quad[0].minYInPixels, quad[0].maxXInPixels, quad[0].maxYInPixels, cellWidth, cellHeight);

    // Render via the CPU path (no cursor override -> static block; the image is
    // composited last, over the grid).
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image: rasterize failed\n");
        return 1;
    }
    const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { width, height });
    if (FILE* f = std::fopen("/tmp/image.png", "wb")) {
        std::fwrite(png.data(), 1, png.size(), f);
        std::fclose(f);
        g_print("smoke-image: wrote /tmp/image.png (%dx%d)\n", width, height);
    }

    // Sample a pixel near the center of the resolved rect — it must be red, not
    // the terminal background (default background is dark, R ~0x10). Red = R high, G/B low.
    const int sampleX = static_cast<int>((quad[0].minXInPixels + quad[0].maxXInPixels) * 0.5f);
    const int sampleY = static_cast<int>((quad[0].minYInPixels + quad[0].maxYInPixels) * 0.5f);
    const std::size_t o = (static_cast<std::size_t>(sampleY) * width + sampleX) * 4;
    const int sr = rgba[o], sg = rgba[o + 1], sb = rgba[o + 2], sa = rgba[o + 3];
    g_print("smoke-image: sampled (%d,%d) = rgba(%d,%d,%d,%d)\n", sampleX, sampleY, sr, sg, sb, sa);

    const bool isRed = sr > 200 && sg < 60 && sb < 60 && sa == 255;
    g_print("smoke-image: %s\n", isRed ? "PASS" : "FAIL");
    return isRed ? 0 : 1;
}

// --smoke-image-stamp — a same-id, same-geometry re-transmit reaches the screen.
//
// The Vulkan texture cache keys on Image::imageContentStamp, which folds the
// generation Core bumps whenever a same-id transmit replaces pixels. Keying on
// geometry instead compiles, passes every existing image oracle, and freezes an
// animation on frame one: the id and the size are unchanged, so the cache hands
// back the first upload forever.
//
// Nothing covered that. The Core primitive is pinned by test_kitty_placeholders
// and the neutral helpers by test_terminalimage_widen; both stop short of the
// cache that consumes them. This renders the re-transmit and looks at pixels.
//
// Kitty rather than sixel, because the aliasing needs an EXPLICIT id: each sixel
// transmission is a new image and would never collide. `a=T,i=1` transmits and
// displays under an id the second feed reuses.
//
// One renderer across both frames, or the cache under test is thrown away
// between them and the smoke proves nothing.
int smokeImageStamp()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-stamp: no term\n");
        return 1;
    }

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-image-stamp", "vulkan init failed");

    // 2x2 24-bit RGB, transmitted and displayed under id 1. The second carries
    // the same id and the same geometry and different pixels, which is the whole
    // point: everything a geometry key can see is identical.
    const char redImage[] = "\x1b_Ga=T,f=24,s=2,v=2,i=1;/wAA/wAA/wAA/wAA\x1b\\";
    const char blueImage[] = "\x1b_Ga=T,f=24,s=2,v=2,i=1;AAD/AAD/AAD/AAD/\x1b\\";

    // Home first, and again before the second transmit. `a=T` displays at the
    // cursor, and a transmit moves it -- so without this the two images land on
    // different cells and the frames differ because the picture moved rather
    // than because its pixels were replaced. The cursor is hidden: a one-cell
    // image leaves it on the image's cell, and the block cursor draws over the
    // over-text images, so a visible cursor would cover the pixel under test.
    Ubiquitty::processBytes(term, "\x1b[?25l");
    Ubiquitty::processBytes(term, "\x1b[H");
    Ubiquitty::processBytes(term, std::string_view(redImage, sizeof(redImage) - 1));
    if (Ubiquitty::Image::placementCount(term) < 1) {
        g_printerr("smoke-image-stamp: the first transmit produced no placement — nothing to re-transmit over\n");
        renderer.shutdown();
        return 1;
    }

    std::vector<uint8_t> first;
    int firstWidth = 0, firstHeight = 0;
    if (!renderer.renderGrid(app().rasterContext, term, first, firstWidth, firstHeight, 0, nullptr, nullptr)) {
        renderer.shutdown();
        return skipNoGPUFrame("smoke-image-stamp", "the first renderGrid failed");
    }

    Ubiquitty::processBytes(term, "\x1b[H");
    Ubiquitty::processBytes(term, std::string_view(blueImage, sizeof(blueImage) - 1));
    std::vector<uint8_t> second;
    int secondWidth = 0, secondHeight = 0;
    if (!renderer.renderGrid(app().rasterContext, term, second, secondWidth, secondHeight, 0, nullptr, nullptr)) {
        renderer.shutdown();
        return skipNoGPUFrame("smoke-image-stamp", "the second renderGrid failed");
    }
    renderer.shutdown();

    // The frames have to be comparable before a difference between them means
    // anything: a geometry change would make them differ for the wrong reason.
    if (firstWidth != secondWidth || firstHeight != secondHeight) {
        g_printerr("smoke-image-stamp: FAIL: the two frames are different sizes (%dx%d vs %dx%d)\n",
            firstWidth, firstHeight, secondWidth, secondHeight);
        return 1;
    }
    // The image's own top-left pixel, not the whole frame: anything else that
    // differs between the two frames would report a difference whether or not
    // the picture changed, which is a check that cannot fail.
    const auto redAt = [](const std::vector<uint8_t>& frame) -> int {
        return frame.size() >= 4 ? static_cast<int>(frame[0]) : -1;
    };
    const auto blueAt = [](const std::vector<uint8_t>& frame) -> int {
        return frame.size() >= 4 ? static_cast<int>(frame[2]) : -1;
    };
    const int firstRed = redAt(first), firstBlue = blueAt(first);
    const int secondRed = redAt(second), secondBlue = blueAt(second);

    // The first frame has to actually be the red image, or the comparison below
    // is between two things neither of which is the picture under test.
    if (!(firstRed > 200 && firstBlue < 60)) {
        g_printerr("smoke-image-stamp: FAIL: the first frame's top-left is not the red image (r=%d b=%d)\n",
            firstRed, firstBlue);
        return 1;
    }
    if (!(secondBlue > 200 && secondRed < 60)) {
        g_printerr("smoke-image-stamp: FAIL: the re-transmitted image did not reach the screen — "
                   "top-left is still r=%d b=%d, so the texture cache returned the first upload "
                   "for a new one under the same id and size\n",
            secondRed, secondBlue);
        return 1;
    }
    g_print("smoke-image-stamp: the image's own pixel went red(%d,%d) -> blue(%d,%d) on a same-id, same-geometry re-transmit\n",
        firstRed, firstBlue, secondRed, secondBlue);
    g_print("smoke-image-stamp: PASS\n");
    return 0;
}

// The inline-image CPU<->GPU oracle: renders `term` through the CPU
// SoftwareRenderer and through the Vulkan image pass and asserts the two PNGs
// are BYTE-IDENTICAL (sha256), or that no channel of any pixel differs by more
// than `toleratedChannelDelta` when that is above zero. Leaves /tmp/<name>.png
// (GPU) and /tmp/<name>-cpu.png on disk; prints both shas + PASS/FAIL (and the
// pixel-diff magnitude on a mismatch).
static int compareImageOracle(const char* name, Ubiquitty::Terminal* term, int toleratedChannelDelta = 0)
{
    std::vector<uint8_t> rgbaCpu;
    int widthCpu = 0, heightCpu = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgbaCpu, widthCpu, heightCpu, 0, nullptr, nullptr)) {
        g_printerr("%s: CPU rasterize failed\n", name);
        return 1;
    }

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame(name, "vulkan init failed");
    std::vector<uint8_t> rgbaVk;
    int widthVk = 0, heightVk = 0;
    const bool ok = renderer.renderGrid(app().rasterContext, term, rgbaVk, widthVk, heightVk, 0, nullptr, nullptr);
    renderer.shutdown();
    if (!ok)
        return skipNoGPUFrame(name, "renderGrid failed");

    if (widthCpu != widthVk || heightCpu != heightVk) {
        g_printerr("%s: size mismatch CPU %dx%d vs GPU %dx%d\n", name, widthCpu, heightCpu, widthVk, heightVk);
        return 1;
    }

    const std::vector<uint8_t> pngCpu = Ubiquitty::Rendering::encodePNG(rgbaCpu, { widthCpu, heightCpu });
    const std::vector<uint8_t> pngVk = Ubiquitty::Rendering::encodePNG(rgbaVk, { widthVk, heightVk });
    const std::string gpuPath = std::string("/tmp/") + name + ".png";
    const std::string cpuPath = std::string("/tmp/") + name + "-cpu.png";
    if (FILE* f = std::fopen(gpuPath.c_str(), "wb")) {
        std::fwrite(pngVk.data(), 1, pngVk.size(), f);
        std::fclose(f);
        g_print("%s: wrote %s (%dx%d)\n", name, gpuPath.c_str(), widthVk, heightVk);
    }
    if (FILE* f = std::fopen(cpuPath.c_str(), "wb")) {
        std::fwrite(pngCpu.data(), 1, pngCpu.size(), f);
        std::fclose(f);
    }

    char* shaCpu = g_compute_checksum_for_data(G_CHECKSUM_SHA256, pngCpu.data(), pngCpu.size());
    char* shaVk = g_compute_checksum_for_data(G_CHECKSUM_SHA256, pngVk.data(), pngVk.size());
    g_print("%s: CPU sha256 = %s\n", name, shaCpu);
    g_print("%s: GPU sha256 = %s\n", name, shaVk);
    const bool identical = (pngCpu.size() == pngVk.size()) && g_strcmp0(shaCpu, shaVk) == 0;
    g_free(shaCpu);
    g_free(shaVk);

    bool isWithinTolerance = identical;
    if (!identical) {
        // Report the magnitude of the RGBA divergence to aid diagnosis.
        std::size_t differing = 0;
        int maxDelta = 0;
        const std::size_t n = (rgbaCpu.size() < rgbaVk.size()) ? rgbaCpu.size() : rgbaVk.size();
        for (std::size_t i = 0; i < n; ++i) {
            const int delta = std::abs(static_cast<int>(rgbaCpu[i]) - static_cast<int>(rgbaVk[i]));
            if (delta != 0) {
                ++differing;
                if (delta > maxDelta)
                    maxDelta = delta;
            }
        }
        g_print("%s: %zu / %zu RGBA bytes differ, max |delta| = %d\n", name, differing, n, maxDelta);
        // The sizes were held equal above, so every byte was compared.
        isWithinTolerance = toleratedChannelDelta > 0 && maxDelta <= toleratedChannelDelta;
        if (toleratedChannelDelta > 0)
            g_print("%s: the frames may differ by %d a channel\n", name, toleratedChannelDelta);
    }
    g_print("%s: %s\n", name, isWithinTolerance ? "PASS" : "FAIL");
    return isWithinTolerance ? 0 : 1;
}

// --smoke-image-vk — the inline-image CPU<->GPU oracle (Stage 11b) for a
// nearest draw: the same solid-red DEC sixel as --smoke-image, whose texels the
// GPU shader picks and over-blends exactly as the CPU does.
int smokeImageVulkan()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk: no term\n");
        return 1;
    }

    // Same sixel as smokeImage: reg 1 = 100% red, repeated 16 px wide x 6 px tall.
    const char sixel[] = "\x1bP0;0;0q#1;2;100;0;0#1!16~\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(sixel, sizeof(sixel) - 1));

    const int placements = Ubiquitty::Image::placementCount(term);
    if (placements < 1) {
        g_printerr("smoke-image-vk: sixel did not produce a placement (count=%d)\n", placements);
        return 1;
    }
    return compareImageOracle("smoke-image-vk", term);
}

// --smoke-image-vk-filtered — the same oracle for filtered draws: a 32x32
// RGBA gradient with a transparent half, placed in a five-cell box (enlarged
// by a fraction) and a two-cell one (reduced, across two mip levels), so Core
// marks both Image::ImageFilter::Smooth. The GPU
// shader reads the CPU's mip chain with the CPU's own bilinear and level
// blend, so the frames must still match to the byte.
int smokeImageVulkanFiltered()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-filtered: no term\n");
        return 1;
    }
    constexpr int side = 32;
    std::string pixels;
    pixels.reserve(side * side * 4);
    for (int y = 0; y < side; ++y) {
        for (int x = 0; x < side; ++x) {
            pixels.push_back(static_cast<char>(x * 8));
            pixels.push_back(static_cast<char>(y * 8));
            pixels.push_back(static_cast<char>((x + y) * 4));
            pixels.push_back(static_cast<char>(x < side / 2 ? 255 : (x - side / 2) * 16));
        }
    }
    std::string base64;
    base64.resize(Ubiquitty::Codec::base64EncodedLength(pixels.size()));
    const auto encoded = Ubiquitty::Codec::base64Encode({ pixels.data(), pixels.size() }, { base64.data(), base64.size() });
    if (!encoded)
        return 1;
    base64.resize(encoded->size());
    const std::string transfer = "\x1b_Ga=T,f=32,s=32,v=32,c=5,q=2;" + base64 + "\x1b\\"
        + "\x1b[8;1H\x1b_Ga=T,f=32,s=32,v=32,c=2,q=2;" + base64 + "\x1b\\";
    Ubiquitty::processBytes(term, transfer);
    Ubiquitty::drainAsyncDecodes(*term);
    if (Ubiquitty::Image::placementCount(term) < 2) {
        g_printerr("smoke-image-vk-filtered: the transfers did not produce two placements\n");
        return 1;
    }
    return compareImageOracle("smoke-image-vk-filtered", term);
}

// --smoke-image-vk-placeholders — the oracle for kitty Unicode placeholders. A
// virtual placement (U=1) draws nothing by itself; each U+10EEEE cell shows the
// tile of the image its row and column marks name, with the image id in its
// foreground. Image 7 is a 2x2 grid of red, green, blue and yellow texels, and
// its 2x2 block of cells is printed twice. Both arms resolve the tiles from the
// cells the frame captured, so they must agree to the byte; the CPU frame must
// also show the red tile where the first block starts, or the two would agree
// about a frame with no picture in it.
int smokeImageVulkanPlaceholders()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-placeholders: no term\n");
        return 1;
    }
    // FF0000 00FF00 / 0000FF FFFF00, transmitted and placed virtually.
    Ubiquitty::processBytes(term, "\x1b_Ga=T,U=1,i=7,f=24,s=2,v=2,c=2,r=2,q=2;/wAAAP8AAAD///8A\x1b\\");
    Ubiquitty::drainAsyncDecodes(*term);
    // U+10EEEE and its row then column mark: U+0305 is 0, U+030D is 1.
    const std::string topRow = "\xF4\x8E\xBB\xAE\xCC\x85\xCC\x85\xF4\x8E\xBB\xAE\xCC\x85\xCC\x8D";
    const std::string bottomRow = "\xF4\x8E\xBB\xAE\xCC\x8D\xCC\x85\xF4\x8E\xBB\xAE\xCC\x8D\xCC\x8D";
    Ubiquitty::processBytes(term, "\x1b[38;5;7m\x1b[2;3H" + topRow + "\x1b[3;3H" + bottomRow + "\x1b[2;9H" + topRow + "\x1b[3;9H" + bottomRow + "\x1b[0m");
    if (!Ubiquitty::Kitty::hasPlaceholders(term, 0)) {
        g_printerr("smoke-image-vk-placeholders: the cells did not land as placeholders\n");
        return 1;
    }

    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image-vk-placeholders: CPU rasterize failed\n");
        return 1;
    }
    // The centre of the red tile, the image's top-left quarter, in the first
    // block, whose box starts at row 2, column 3. The square image is fitted
    // into its 2x2 box of cells with its aspect kept and centred on the axis
    // it does not fill, so in a cell that is not square the tile is off the
    // first cell's centre.
    const int cellWidth = app().rasterContext.cellWidth();
    const int cellHeight = app().rasterContext.cellHeight();
    const int imageSide = 2 * std::min(cellWidth, cellHeight);
    const int sampleX = 2 * cellWidth + (2 * cellWidth - imageSide) / 2 + imageSide / 4;
    const int sampleY = 1 * cellHeight + (2 * cellHeight - imageSide) / 2 + imageSide / 4;
    if (sampleX >= width || sampleY >= height) {
        g_printerr("smoke-image-vk-placeholders: the frame is smaller than the block\n");
        return 1;
    }
    const std::size_t at = (static_cast<std::size_t>(sampleY) * static_cast<std::size_t>(width) + static_cast<std::size_t>(sampleX)) * 4;
    if (!(rgba[at] > 200 && rgba[at + 1] < 60 && rgba[at + 2] < 60)) {
        g_printerr("smoke-image-vk-placeholders: FAIL: the first placeholder cell is rgb(%d,%d,%d), not the red tile\n",
            rgba[at], rgba[at + 1], rgba[at + 2]);
        return 1;
    }
    return compareImageOracle("smoke-image-vk-placeholders", term);
}

// --smoke-image-vk-under-text — a picture placed at z<0 under the text on both
// arms. Each draws the cells' ground, then the picture, then the ink over it.
// The CPU frame is checked first: inside the picture's cells it must hold both
// the picture's red and pixels that are not red, which is the text reading on
// top. The GPU frame then has to match it to within one level a channel: the
// Vulkan arm blends that ink in the fixed-function unit, and a blender that
// rounds each product can land a partly covered pixel one level from the CPU's
// integer mix.
int smokeImageVulkanUnderText()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-under-text: no term\n");
        return 1;
    }
    constexpr int pictureColumns = 12;
    constexpr int pictureRows = 2;
    // One opaque red texel stretched over twelve cells of two rows, placed
    // without moving the cursor, then text printed over the same cells.
    Ubiquitty::processBytes(term, "\x1b[H\x1b_Ga=T,f=24,s=1,v=1,c=12,r=2,z=-1,C=1,q=2;/wAA\x1b\\");
    Ubiquitty::drainAsyncDecodes(*term);
    Ubiquitty::processBytes(term, "\x1b[1;1HText on red,\x1b[2;1Hstill legible");
    if (Ubiquitty::Image::placementCount(term) < 1) {
        g_printerr("smoke-image-vk-under-text: the picture did not produce a placement\n");
        return 1;
    }

    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image-vk-under-text: CPU rasterize failed\n");
        return 1;
    }
    const int pictureWidth = std::min(pictureColumns * app().rasterContext.cellWidth(), width);
    const int pictureHeight = std::min(pictureRows * app().rasterContext.cellHeight(), height);
    std::size_t pictured = 0;
    std::size_t inked = 0;
    for (int y = 0; y < pictureHeight; ++y) {
        for (int x = 0; x < pictureWidth; ++x) {
            const std::size_t at = (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4;
            if (rgba[at] == 255 && rgba[at + 1] == 0 && rgba[at + 2] == 0)
                ++pictured;
            else
                ++inked;
        }
    }
    g_print("smoke-image-vk-under-text: CPU picture cells hold %zu picture pixels and %zu ink pixels\n", pictured, inked);
    if (pictured == 0 || inked == 0) {
        g_printerr("smoke-image-vk-under-text: FAIL: the CPU frame does not show text over the picture\n");
        return 1;
    }
    return compareImageOracle("smoke-image-vk-under-text", term, /*toleratedChannelDelta=*/1);
}

// --smoke-weight — SGR 1:n variable font weight. Asserts (1) the Core parses 1:5
// into the cell's extendedAttributes weight bits, and (2) the builder threads that weight to
// the glyph atlas so a weighted run renders byte-identically on the CPU + GPU (the
// oracle holds for weighted text — a different atlas glyph, sampled the same by
// both). The visible weight change needs a variable font + is checked by hand; this
// pins the parse + the CPU<->GPU path that were the Linux gap (builder hardcoded 0).
int smokeWeight()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-weight: no term\n");
        return 1;
    }
    // SGR 1:5 selects variable weight 5, then a short run; SGR 0 resets.
    const char feed[] = "\x1b[1:5mWWWW\x1b[0m";
    Ubiquitty::processBytes(term, std::string_view(feed, sizeof(feed) - 1));

    const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const unsigned parsedWeight = cell != nullptr ? static_cast<unsigned>(Ubiquitty::cellPen(*cell).extendedAttributes.weight()) : 0u;
    const bool parseOk = parsedWeight == 5;

    std::vector<uint8_t> rgbaCpu;
    int wCpu = 0, hCpu = 0;
    const bool cpuOk = app().rasterContext.rasterizeTerm(term, rgbaCpu, wCpu, hCpu, 0, nullptr, nullptr);

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-weight", "vulkan init failed");
    std::vector<uint8_t> rgbaVk;
    int wVk = 0, hVk = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, rgbaVk, wVk, hVk, 0, nullptr, nullptr);
    renderer.shutdown();

    const bool didCompareGPU = cpuOk && didRenderGPUFrame;
    const bool isIdentical = !didCompareGPU || (wCpu == wVk && hCpu == hVk && rgbaCpu == rgbaVk);
    const bool didPass = parseOk && isIdentical;
    g_print("smoke-weight: parsed-weight=%u (want 5) CPU==GPU(weighted run)=%s -- %s\n", parsedWeight, oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (isIdentical ? OracleOutcome::Matched : OracleOutcome::Differed)), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-opacity — window background opacity. With opacity 0.5, asserts (1) a
// blank background pixel's alpha is ~128 (the background shows through behind opaque text)
// and (2) the screen renders byte-identically on the CPU + GPU at <1 opacity (the
// alpha is composited in the same integer domain as the colors — the oracle holds
// for translucent backgrounds too). The actual desktop see-through is a transparent
// GTK window over a compositor and is checked by hand.
int smokeOpacity()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-opacity: no term\n");
        return 1;
    }
    (void)Ubiquitty::Preferences::configure("[appearance]\nbackground_opacity = 0.5\n", Ubiquitty::Preferences::ParseMode::Strict);
    Ubiquitty::processBytes(term, "opacity"); // text on row 0; mid-screen stays blank background

    std::vector<uint8_t> rgbaCpu;
    int wCpu = 0, hCpu = 0;
    const bool cpuOk = app().rasterContext.rasterizeTerm(term, rgbaCpu, wCpu, hCpu, 0, nullptr, nullptr);

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-opacity", "vulkan init failed");
    std::vector<uint8_t> rgbaVk;
    int wVk = 0, hVk = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, rgbaVk, wVk, hVk, 0, nullptr, nullptr);
    renderer.shutdown();

    const bool didCompareGPU = cpuOk && didRenderGPUFrame;
    const bool isIdentical = !didCompareGPU || (wCpu == wVk && hCpu == hVk && rgbaCpu == rgbaVk);
    // A blank background pixel mid-screen (away from row 0's text): alpha ≈ 0.5*255.
    int backgroundAlpha = -1;
    if (cpuOk && wCpu > 0 && hCpu > 0) {
        const std::size_t mid = (static_cast<std::size_t>(hCpu / 2) * wCpu + wCpu / 2) * 4;
        backgroundAlpha = rgbaCpu[mid + 3];
    }
    const bool alphaOk = backgroundAlpha >= 126 && backgroundAlpha <= 130;
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict); // restore (defensive; smokes are separate processes)

    const bool didPass = isIdentical && alphaOk;
    g_print("smoke-opacity: CPU==GPU(@0.5)=%s bg-alpha=%d (want ~128) -- %s\n", oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (isIdentical ? OracleOutcome::Matched : OracleOutcome::Differed)), backgroundAlpha, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-background-image — the window's background image on both render
// paths. A gradient with translucent texels, under a theme at opacity 0.85, in
// every placement mode and at an image opacity below one: each frame is
// rendered by the CPU raster and by the Vulkan pass and the two must be the same
// bytes, and the image must show — a blank background pixel's alpha rises past
// the theme's.
int smokeBackgroundImage()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-background-image: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "backdrop");
    // 37 x 23, so neither axis divides the frame and every mode samples
    // between texels; the corner column is translucent.
    Ubiquitty::Rendering::BackgroundImagePixels gradient;
    gradient.width = 37;
    gradient.height = 23;
    gradient.rgba.resize(static_cast<std::size_t>(gradient.width) * gradient.height * 4);
    for (int y = 0; y < gradient.height; ++y) {
        for (int x = 0; x < gradient.width; ++x) {
            const std::size_t offset = (static_cast<std::size_t>(y) * gradient.width + x) * 4;
            gradient.rgba[offset] = static_cast<std::uint8_t>(x * 7);
            gradient.rgba[offset + 1] = static_cast<std::uint8_t>(y * 11);
            gradient.rgba[offset + 2] = static_cast<std::uint8_t>((x + y) * 4);
            gradient.rgba[offset + 3] = x == 0 ? 96 : 255;
        }
    }

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    const bool hasGPU = renderer.init();
    bool didEveryModeMatch = true;
    bool didImageShow = true;
    for (const char* mode : { "fill", "fit", "stretch", "tile", "center" }) {
        const std::string document = std::string("[appearance]\nbackground_opacity = 0.85\nbackground_image = \"/smoke\"\n")
            + "background_image_opacity = 0.6\nbackground_image_mode = \"" + mode + "\"\n";
        (void)Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict);
        app().rasterContext.setRenderConfiguration(Ubiquitty::Preferences::Effective::renderConfiguration(Ubiquitty::Preferences::values()));
        // After the configure, whose subscriber loads the named path and finds
        // nothing there: the smoke's image stands in for the file.
        app().rasterContext.setBackgroundImage(gradient);
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRasterizeCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didRenderGPUFrame = hasGPU && renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRasterizeCPUFrame && didRenderGPUFrame;
        const bool same = didCompareGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        std::size_t differing = 0;
        if (didCompareGPU && cpu.size() == gpu.size()) {
            for (std::size_t index = 0; index < cpu.size(); index += 4) {
                if (cpu[index] == gpu[index] && cpu[index + 1] == gpu[index + 1] && cpu[index + 2] == gpu[index + 2] && cpu[index + 3] == gpu[index + 3])
                    continue;
                // The first few, so a disagreement names where and by how much.
                if (differing < 3) {
                    const std::size_t pixel = index / 4;
                    g_printerr("smoke-background-image: %s (%zu,%zu) CPU %d,%d,%d,%d GPU %d,%d,%d,%d\n", mode,
                        pixel % static_cast<std::size_t>(cpuWidth), pixel / static_cast<std::size_t>(cpuWidth),
                        cpu[index], cpu[index + 1], cpu[index + 2], cpu[index + 3], gpu[index], gpu[index + 1], gpu[index + 2], gpu[index + 3]);
                }
                ++differing;
            }
        }
        int backgroundAlpha = -1;
        if (didRasterizeCPUFrame && cpuWidth > 0 && cpuHeight > 0) {
            const std::size_t middle = (static_cast<std::size_t>(cpuHeight / 2) * cpuWidth + cpuWidth / 2) * 4;
            backgroundAlpha = cpu[middle + 3];
        }
        // 0.85 alone is 217; the image adds 0.6 of the 0.15 left open.
        const bool shows = backgroundAlpha > 230;
        if (hasGPU && !didRenderGPUFrame)
            g_printerr("smoke-background-image: FAIL: '%s' rendered no GPU frame, on a device that initialised\n", mode);
        g_print("smoke-background-image: %-7s CPU==GPU %s (%zu px differ) bg-alpha=%d\n", mode,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), differing, backgroundAlpha);
        didEveryModeMatch = didEveryModeMatch && (same || !hasGPU);
        didImageShow = didImageShow && shows;
    }
    if (hasGPU)
        renderer.shutdown();
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
    const bool didPass = didEveryModeMatch && didImageShow;
    g_print("smoke-background-image: %s\n", didPass ? "PASS" : "FAIL");
    if (!hasGPU && didImageShow)
        return skipNoGPUFrame("smoke-background-image", "vulkan init failed");
    return didPass ? 0 : 1;
}

// How many executed command blocks --smoke-beam runs before opening the palette.
//
// More than the 24-row screen holds, so the oldest of them sits in scrollback: a
// block still on the live screen is revealed by a viewport offset of zero, and a
// jump to one cannot be told from no jump at all.
constexpr int smokeBeamBlockCount = 30;

// Which block --smoke-beam jumps to, counted from the OLDEST.
//
// Neither end of the list can carry the check. The newest block sits at the
// live tail, where the reveal offset is zero and a jump that never happened
// looks exactly like one that did. The oldest saturates the reveal's clamp at
// the retained line count, where an offset a row out is clamped back onto the
// right answer — the case passes on arithmetic it cannot read. A block a few
// from the end sits between both.
constexpr int smokeBeamTargetFromOldest = 6;

// The token --smoke-beam straddles a soft wrap with, and its length. Padded to
// start half a token before the right margin, so the terminal wraps it across
// two rows and one logical match arrives as two highlight segments.
constexpr const char* smokeBeamWrappedToken = "BOUNDARYCROSSER";
constexpr int smokeBeamWrappedTokenLength = 15;

// Feed a NUL-terminated escape sequence to the model, so a case spells the bytes
// instead of counting them.
void feedBeamSmokeBytes(Ubiquitty::Terminal& term, const char* bytes)
{
    Ubiquitty::processBytes(&term, bytes);
}

// The label a key's vocabulary gives `token`, or the token when it names no
// term. Used by --smoke-beam to state an expected row value in terms of the
// default rather than as a literal that rots when the default moves.
std::string beamSettingDefaultLabel(Ubiquitty::Preferences::Key key, const char* token)
{
    const int index = Ubiquitty::Preferences::vocabularyIndexOf(key, token);
    if (index < 0)
        return token != nullptr ? token : "";
    return Ubiquitty::Preferences::vocabularyFor(key)[static_cast<std::size_t>(index)].label;
}

// One executed OSC 133 command block, in the byte order a shell integration
// emits it: the exit status of the command that just ended, the prompt, the
// echoed command line, then a row of output.
//
// The status closes the PREVIOUS block, which is what OSC 133 D reports, so a
// failure is spelled by the block that follows the failing one.
void feedBeamSmokeCommandBlock(Ubiquitty::Terminal& term, const char* commandLine, int previousExitStatus)
{
    std::array<char, 128> bytes {};
    std::snprintf(bytes.data(), bytes.size(), "\033]133;D;%d\007\033]133;A\007%s\r\n\033]133;C\007out\r\n", previousExitStatus, commandLine);
    feedBeamSmokeBytes(term, bytes.data());
}

// One row of a snapshotted grid as text, trailing blanks trimmed the way
// absoluteRowText trims them so the two compare. A cell holding nothing reads as
// a space rather than a NUL, which would survive the trim and never match.
std::string beamSmokeGridRowText(const std::vector<Ubiquitty::Cell>& grid, int columns, int row)
{
    std::string text;
    for (int column = 0; column < columns; ++column) {
        const std::size_t index = static_cast<std::size_t>(row) * static_cast<std::size_t>(columns) + static_cast<std::size_t>(column);
        if (index >= grid.size())
            break;
        const std::uint32_t codePoint = grid[index].codePoint;
        Ubiquitty::Unicode::appendUTF8(text, codePoint == 0 ? ' ' : codePoint);
    }
    const std::size_t lastGlyph = text.find_last_not_of(' ');
    if (lastGlyph == std::string::npos)
        text.clear();
    else
        text.resize(lastGlyph + 1);
    return text;
}

// --smoke-beam — the command palette headlessly. Beam is portable Core (rank,
// layout, key classification); what this frontend supplies is the composite into
// the grid snapshot, the key routing, the per-scope command lists and what an
// accepted row does, so those are what this asserts.
//
// Every check is written to fail if its subject is removed, because a palette
// bug is invisible to every other smoke here: the grid still renders, the
// terminal still works, and the only symptom is a popover nobody sees. Deleting
// the composite in Raster.cpp turns `differs` false; deleting the layout call
// turns `drew` false; routing keys to the terminal instead of the palette leaves
// `narrowed` false; dropping the Blocks registration or the availability
// declaration leaves `didEnterScope` false, and dropping the jump leaves `didJump`
// false.
int smokeBeam()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-beam: no term\n");
        return 1;
    }
    // A history of executed blocks, so the '@' scope has something to fill with
    // and the buffer has scrollback for a jump to move through.
    for (int i = 0; i < smokeBeamBlockCount - 1; ++i) {
        std::array<char, 32> commandLine {};
        std::snprintf(commandLine.data(), commandLine.size(), "$ echo %d", i);
        feedBeamSmokeCommandBlock(*term, commandLine.data(), 0);
    }
    feedBeamSmokeCommandBlock(*term, "$ false", 0);
    // The non-zero status lands on "$ false"; the prompt printed after it never
    // executes a command, so it is not a block of its own.
    feedBeamSmokeBytes(*term, "\033]133;D;1\007\033]133;A\007$ ");
    // A token wider than the terminal, so ONE logical match arrives as several
    // highlight segments. Without it the '/' assertions below are all
    // single-row matches, segments equal logical matches, and a walk that
    // listed segments would produce the same count as one that did not — the
    // dedupe would be asserted by a case that cannot see it.
    //
    // Fed as raw output rather than through `feedBeamSmokeCommandBlock`, whose
    // 128-byte frame would truncate it, and which would make it a thirty-first
    // block that the count above states there are thirty of.
    const std::string wrappedToken
        = std::string(startupColumns - smokeBeamWrappedTokenLength / 2, 'Q') + smokeBeamWrappedToken + "\r\n";
    feedBeamSmokeBytes(*term, wrappedToken.c_str());

    // The composite is asserted on the GRID, not on rendered pixels. Two
    // rasterizeTerm calls of the same screen are not byte-identical — the
    // renderer carries a glyph cache across calls — so a pixel diff between a
    // closed frame and an open one is true whether or not the palette was
    // composited. Written that way first, and it passed with the composite
    // disabled. snapshotVisibleGrid is the seam this feature changed and it is a
    // pure function of the terminal plus the chrome.
    app().rasterContext.setBeamChrome(nullptr);
    std::vector<Ubiquitty::Cell> closedGrid;
    app().rasterContext.snapshotVisibleGrid(term, 0, closedGrid);

    // The same registration a summon performs, rather than a list assembled for
    // the smoke: a scope this frontend forgets to fill is exactly the defect
    // being checked, and a smoke that fills it itself cannot see that.
    fillBeamScopes(term);
    app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
    const bool opened = app().beamSession.isOpen();

    const Ubiquitty::Rendering::BeamGeometry geometry = layoutBeamForFrame(*term);
    const bool drew = geometry.canvas.rows > 0 && geometry.bodyRows > 0;
    app().rasterContext.setBeamChrome(&geometry);

    int canvasInk = 0;
    for (const Ubiquitty::Cell& c : geometry.canvas.cells)
        if (c.codePoint != 0 && c.codePoint != 0x20)
            ++canvasInk;
    std::vector<Ubiquitty::Cell> openGrid;
    app().rasterContext.snapshotVisibleGrid(term, 0, openGrid);
    // Same size, different contents, and the difference has to lie INSIDE the
    // rectangle the layout named — a composite writing anywhere else is a bug
    // that "the grids differ" would happily accept.
    bool differsInside = false;
    bool differsOutside = false;
    const int columns = term->columns;
    for (std::size_t i = 0; i < closedGrid.size() && i < openGrid.size(); ++i) {
        if (closedGrid[i].codePoint == openGrid[i].codePoint)
            continue;
        const int row = static_cast<int>(i) / columns;
        const int column = static_cast<int>(i) % columns;
        const bool inside = row >= geometry.originRow && row < geometry.originRow + geometry.canvas.rows
            && column >= geometry.originColumn && column < geometry.originColumn + geometry.canvas.columns;
        (inside ? differsInside : differsOutside) = true;
    }
    const bool differs = !closedGrid.empty() && closedGrid.size() == openGrid.size() && differsInside && !differsOutside;

    std::vector<uint8_t> openRGBA;
    int openWidth = 0, openHeight = 0;
    const bool openOk = app().rasterContext.rasterizeTerm(term, openRGBA, openWidth, openHeight, 0, nullptr, nullptr);

    // The same frame through the GPU path. Both composite inside
    // snapshotVisibleGrid, so this is the oracle covering the palette — a second
    // composite added to one path only would show up here and nowhere else.
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-beam", "vulkan init failed");
    std::vector<uint8_t> vulkanRGBA;
    int vulkanWidth = 0, vulkanHeight = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, vulkanRGBA, vulkanWidth, vulkanHeight, 0, nullptr, nullptr);
    renderer.shutdown();

    // Only the CPU<->GPU COMPARISON depends on a GPU frame; the composite, the
    // query routing and the close all run without one. So a box that cannot
    // produce a GPU frame skips that one check and still reports the rest —
    // skipping the whole mode would lose the composite assertion on exactly the
    // machine this is usually built on, which is where it most needs running.
    const bool didCompareGPU = didRenderGPUFrame && openOk;
    const bool isIdentical = !didCompareGPU || (openWidth == vulkanWidth && openHeight == vulkanHeight && openRGBA == vulkanRGBA);

    // A query has to reach the palette through the same classifier the key
    // handler uses. The probe is a string that matches nothing, checked against
    // the empty set rather than "fewer rows than before": a single letter is not
    // discriminating, because the matcher is a subsequence over title +
    // keywords, so a common letter keeps nearly the whole catalog and the check
    // would pass on a routing path that is only half working. Backspacing back
    // to the full list is what separates a filter from a cleared command set.
    const std::size_t unfilteredRows = app().beamSession.state().rows.size();
    bool routed = true;
    for (const std::uint32_t letter : { 'q', 'z', 'q', 'z' }) {
        const Ubiquitty::Input::BeamKeyOutcome typed
            = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Input::resolveChordKey(letter, 0, 0), 0, letter);
        routed = routed && typed.handled;
        if (typed.handled)
            app().beamSession.apply(typed.event, typed.codePoint);
    }
    const std::size_t narrowedRows = app().beamSession.state().rows.size();
    for (int i = 0; i < 4; ++i) {
        const Ubiquitty::Input::BeamKeyOutcome erased
            = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyBackspace, 0, 0);
        routed = routed && erased.handled;
        if (erased.handled)
            app().beamSession.apply(erased.event, erased.codePoint);
    }
    const std::size_t restoredRows = app().beamSession.state().rows.size();
    const bool narrowed = routed && unfilteredRows > 0 && narrowedRows == 0 && restoredRows == unfilteredRows;

    // The '@' scope. What this frontend owns of it is the registration — the
    // walk, the prefix strip and the terminal gate are all Core's — so the
    // prefix goes through the same classifier a keystroke takes and the scope is
    // read for what the frontend put in it. A palette that opens and never
    // enters a scope cannot see any of this.
    const Ubiquitty::Input::BeamKeyOutcome prefix
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Input::resolveChordKey('@', 0, 0), 0, '@');
    routed = routed && prefix.handled;
    if (prefix.handled)
        app().beamSession.apply(prefix.event, prefix.codePoint);
    // The query has to come back EMPTY: an undeclared terminal refuses the
    // retarget and leaves the '@' in the field, which ranks every block against a
    // character none of them carry — an empty scope for a reason that is not the
    // registration.
    const bool didEnterScope = app().beamSession.state().scope == Ubiquitty::CommandPalette::Scope::Blocks && app().beamSession.state().query.empty();
    const std::size_t blockRows = app().beamSession.state().rows.size();
    // Newest first, the failed one wearing the glyph this frontend chose for
    // Core's bool, the oldest last. A list built by walking the buffer forwards
    // holds the same rows and fails this.
    const bool didListBlocks = blockRows == static_cast<std::size_t>(smokeBeamBlockCount)
        && app().beamSession.state().rows.front().title == "$ false"
        && app().beamSession.state().rows.front().detail == "✗"
        && app().beamSession.state().rows.back().title == "$ echo 0";

    // The '/' scope, over the same buffer the blocks above filled. Asserted on
    // the builder rather than by typing a query through the session, because
    // what can be wrong here is the walk and the dedupe, and driving eight
    // keystrokes to reach them would test the key classifier a second time.
    //
    // "echo 1" matches `$ echo 1` and `$ echo 10`..`$ echo 19` — eleven of the
    // thirty blocks. A count rather than a spot check, because a walk that
    // dropped or doubled rows reads as a number and not as a wrong row. Every
    // one of these matches sits on a single row, so this says nothing about the
    // segment dedupe; the wrapping token below is what asks that.
    const auto find = [](const std::string& pattern) {
        Ubiquitty::Search::Request request { .pattern = pattern, .form = Ubiquitty::Search::PatternForm::Regex, .labelLimit = Ubiquitty::Search::maxStoredLabels };
        (void)activePane()->session->searchScrollbackAndWait(request);
        return beamFindCommands(activePane());
    };
    const Ubiquitty::CommandPalette::PaletteCommandList findRows = find("echo 1");
    bool doRowsReadTheirLine = !findRows.empty();
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : findRows) {
        if (row.title.find("echo 1") == std::string::npos)
            doRowsReadTheirLine = false;
    }
    const bool didListFind = findRows.size() == 11 && doRowsReadTheirLine;

    // Both a query with no matches and a cleared query leave the list empty.
    const bool isEmptyOnMiss = find("zzzznotpresent").empty() && find("").empty();

    // Every prefix of a regex is typed on the way to it, so a half-written one
    // is the normal state of this scope and must not throw or match wildly.
    const bool didSurviveBadPattern = find("[").empty() && find("*").empty();

    // One row for the straddling token, not one per visual row it touches.
    // `matchAt` counts logical matches and `segmentAt` counts highlight runs, so
    // this is the case that pins which of the two walks the scope uses —
    // swapping to the segment walk turns this row count into two.
    const Ubiquitty::CommandPalette::PaletteCommandList wrappedRows
        = find(smokeBeamWrappedToken);
    const bool isOneRowPerMatch = wrappedRows.size() == 1;

    // Accepting a row scrolls to it, through the same reveal the block jump
    // below uses. Checked here rather than at the end because that jump owns
    // the final viewOffset, and it resets the offset before it runs.
    activePane()->viewOffset = 0;
    const auto acceptedRows = find("echo 1");
    Ubiquitty::CommandPalette::BeamAction findAccept;
    findAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    findAccept.commandID = acceptedRows.empty() ? std::string("beam.find.0") : acceptedRows.front().id;
    runBeamAction(findAccept);
    const bool didJumpToMatch = !findRows.empty() && activePane()->viewOffset > 0;
    activePane()->session->clearScrollbackSearch();

    // The '#' scope. Asserted against Core's compiled defaults rather than the
    // machine's config.toml, because a row's VALUE is what the file decides and
    // this case would otherwise be about whoever ran it. The counts below do
    // not depend on the file — a row exists per descriptor, and which control
    // it gets comes from the static schema and vocabulary tables — but the
    // three value checks do.
    const std::string savedDocument = Ubiquitty::Preferences::liveDocument();
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Permissive);
    const Ubiquitty::CommandPalette::PaletteCommandList settingRows = beamSettingsCommands();

    std::size_t settingToggles = 0;
    std::size_t settingOptionDrills = 0;
    std::size_t settingNumberDrills = 0;
    bool doSettingRowsResolve = !settingRows.empty();
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : settingRows) {
        // Every id the scope offers has to resolve back to the key it names, or
        // accepting it reaches `runBeamAction` and falls through to the action
        // parse, which has no spelling for it.
        if (beamSettingDescriptorFor(row.id) == nullptr)
            doSettingRowsResolve = false;
        switch (row.kind) {
        case Ubiquitty::CommandPalette::CommandKind::Action:
            ++settingToggles;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillOptions:
            ++settingOptionDrills;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillNumber:
            ++settingNumberDrills;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillText:
            break;
        }
    }
    // Each editable Core descriptor has exactly one row of the right kind.
    // Counting by identity catches an omitted row even when a duplicate keeps
    // the total unchanged; future descriptors need no frontend census update.
    auto settingRowsMismatch = [](std::span<const Ubiquitty::CommandPalette::PaletteCommand> rows) -> std::string {
        namespace Configuration = Ubiquitty::Preferences;
        using Ubiquitty::CommandPalette::CommandKind;
        std::size_t expectedRows = 0;
        for (const Configuration::WriteDescriptor& descriptor : Configuration::writeDescriptors) {
            const std::optional<Configuration::Value> value = Configuration::effectiveValue(descriptor.id, Configuration::values());
            std::optional<CommandKind> expectedKind;
            if (value) {
                switch (value->kind) {
                case Configuration::SerializeKind::Bool:
                    expectedKind = CommandKind::Action;
                    break;
                case Configuration::SerializeKind::EnumToken:
                    if (!Configuration::vocabularyFor(descriptor.id).empty()) {
                        expectedKind = CommandKind::DrillOptions;
                    }
                    break;
                case Configuration::SerializeKind::Int:
                case Configuration::SerializeKind::Double:
                    if (Configuration::Schema::rangeFor(descriptor.section, descriptor.key)) {
                        expectedKind = CommandKind::DrillNumber;
                    }
                    break;
                case Configuration::SerializeKind::String:
                case Configuration::SerializeKind::LegacyBoolOrToken:
                    break;
                }
            }
            const std::string commandID = std::format("beam.setting.{}.{}", descriptor.section, descriptor.key);
            std::size_t matches = 0;
            std::optional<CommandKind> actualKind;
            for (const Ubiquitty::CommandPalette::PaletteCommand& row : rows) {
                if (row.id == commandID) {
                    ++matches;
                    actualKind = row.kind;
                }
            }
            if (!expectedKind) {
                if (matches) {
                    return std::format("{} is not editable but has {} row(s)", commandID, matches);
                }
                continue;
            }
            ++expectedRows;
            if (matches != 1) {
                return std::format("{} requires one row, found {}", commandID, matches);
            }
            if (actualKind != expectedKind) {
                return std::format("{} has the wrong control kind", commandID);
            }
        }
        if (rows.size() != expectedRows) {
            return std::format("expected {} editable descriptors, found {} rows", expectedRows, rows.size());
        }
        return {};
    };
    const std::string settingsMismatch = settingRowsMismatch(settingRows);
    const bool didListSettings = settingsMismatch.empty() && doSettingRowsResolve;
    if (!settingsMismatch.empty()) {
        g_printerr("smoke-beam: settings mismatch: %s\n", settingsMismatch.c_str());
    }

    bool doesRejectSettingsDefects = false;
    if (!settingRows.empty()) {
        auto brokenRows = settingRows;
        brokenRows.pop_back();
        const bool doesRejectMissingRow = !settingRowsMismatch(brokenRows).empty();
        bool doesRejectDuplicateRow = false;
        bool doesRejectWrongControl = false;
        for (std::size_t index = 1; index < settingRows.size(); ++index) {
            if (!doesRejectDuplicateRow && settingRows[index].kind == settingRows.front().kind) {
                brokenRows = settingRows;
                brokenRows[index] = brokenRows.front();
                doesRejectDuplicateRow = !settingRowsMismatch(brokenRows).empty();
            }
            if (!doesRejectWrongControl && settingRows[index].kind != settingRows.front().kind) {
                brokenRows = settingRows;
                brokenRows.front().kind = settingRows[index].kind;
                brokenRows[index].kind = settingRows.front().kind;
                doesRejectWrongControl = !settingRowsMismatch(brokenRows).empty();
            }
            if (doesRejectDuplicateRow && doesRejectWrongControl) {
                break;
            }
        }
        doesRejectSettingsDefects = doesRejectMissingRow && doesRejectDuplicateRow && doesRejectWrongControl;
    }

    // Three representative rows, one per control, checked by id so the walk
    // order cannot satisfy them by accident.
    auto rowFor = [&settingRows](const char* id) -> const Ubiquitty::CommandPalette::PaletteCommand* {
        for (const Ubiquitty::CommandPalette::PaletteCommand& row : settingRows) {
            if (row.id == id)
                return &row;
        }
        return nullptr;
    };
    const Ubiquitty::CommandPalette::PaletteCommand* ligatures = rowFor("beam.setting.font.ligatures");
    const Ubiquitty::CommandPalette::PaletteCommand* shape = rowFor("beam.setting.cursor.shape");
    const Ubiquitty::CommandPalette::PaletteCommand* fontSize = rowFor("beam.setting.font.size");
    const auto* brailleStyle = rowFor("beam.setting.font.braille_style");
    const bool areControlsRight = ligatures != nullptr && shape != nullptr && fontSize != nullptr && brailleStyle != nullptr
        && brailleStyle->kind == Ubiquitty::CommandPalette::CommandKind::DrillOptions
        && brailleStyle->value == beamSettingDefaultLabel(Ubiquitty::Preferences::Key::FontBrailleStyle, Ubiquitty::Rendering::brailleStyleToString(Ubiquitty::Rendering::defaultBrailleStyle).data())
        && ligatures->kind == Ubiquitty::CommandPalette::CommandKind::Action
        && shape->kind == Ubiquitty::CommandPalette::CommandKind::DrillOptions
        // [font] size carries an Int write descriptor and resolves as a DOUBLE.
        // Its CONTROL is DrillNumber under either reading, so the kind alone
        // says nothing; what separates them is which slot the preview came
        // from. A row that trusted the descriptor would read the `integer`
        // slot, which a double-valued key leaves at its zero, and show "0 pt".
        && fontSize->kind == Ubiquitty::CommandPalette::CommandKind::DrillNumber
        && fontSize->value
            == Ubiquitty::CommandPalette::Settings::valuePreview(Ubiquitty::Preferences::Defaults::fontSize,
                Ubiquitty::Preferences::Schema::rangeFor("font", "size")->step,
                Ubiquitty::Preferences::Schema::rangeFor("font", "size")->unit)
        // The row shows the LIVE value, so the expectation is derived from the
        // default rather than written as a literal — `cursor.shape` defaults to
        // Bar, not to the first term, and a case naming "Block" would be
        // asserting the walk order instead of the value. A literal here would
        // also rot silently the day a default moves.
        && shape->value == beamSettingDefaultLabel(Ubiquitty::Preferences::Key::CursorShape, Ubiquitty::Preferences::cursorShapeToString(Ubiquitty::Preferences::Defaults::cursorShape))
        && ligatures->value == (Ubiquitty::Preferences::Defaults::ligatures ? "On" : "Off");

    // A key the palette cannot edit is absent rather than listed and inert:
    // [font] family needs a text editor the session has no payload for, and
    // [window] drag_modifier is a chord rather than a closed list.
    const bool areUneditableAbsent = rowFor("beam.setting.font.family") == nullptr
        && rowFor("beam.setting.window.drag_modifier") == nullptr;

    // Accepting a row has to reach the FILE, not just the list. Pointed at a
    // private store so the case never writes the developer's config.toml, and
    // so what it reads back is only what it wrote.
    //
    // `[font] ligatures` is the subject because it defaults ON: a toggle that
    // did nothing would leave the file without the key and the value at the
    // default, and both halves of the check would pass on absence. Writing the
    // non-default is the only edit whose success and failure look different.
    std::string settingsStoreRoot = std::format("/tmp/ubiquitty-smoke-beam-settings-{}", getpid());
    setenv("XDG_CONFIG_HOME", settingsStoreRoot.c_str(), 1);
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Permissive);

    Ubiquitty::CommandPalette::BeamAction settingAccept;
    settingAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    settingAccept.commandID = "beam.setting.font.ligatures";
    runBeamAction(settingAccept);

    const std::string writtenStore = readPreferencesStore();
    const bool didPersistSetting = writtenStore.find("[font]") != std::string::npos
        && writtenStore.find("ligatures = false") != std::string::npos;
    // And the live values followed the file, which is what makes the change
    // visible in this window rather than at the next launch.
    const bool didApplySetting = didPersistSetting
        && Ubiquitty::Preferences::Effective::ligatures(loadPreferences()) == false;

    // Toggling back returns it, so the row reads the live value rather than a
    // latched one — a setter that always wrote `false` would pass the two above.
    runBeamAction(settingAccept);
    const bool didToggleBack = readPreferencesStore().find("ligatures = true") != std::string::npos
        && Ubiquitty::Preferences::Effective::ligatures(loadPreferences());

    Ubiquitty::CommandPalette::BeamAction brailleAccept;
    brailleAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    brailleAccept.commandID = "beam.setting.font.braille_style";
    const auto brailleTerms = Ubiquitty::Preferences::vocabularyFor(Ubiquitty::Preferences::Key::FontBrailleStyle);
    bool didApplyBraille = brailleTerms.size() == 7;
    for (std::size_t index = 0; index < brailleTerms.size(); ++index) {
        brailleAccept.optionIndex = static_cast<int>(index);
        runBeamAction(brailleAccept);
        const auto style = Ubiquitty::Preferences::Effective::brailleStyle(loadPreferences());
        const auto rows = beamSettingsCommands();
        bool hasLiveLabel = false;
        for (const auto& row : rows) {
            if (row.id == brailleAccept.commandID) {
                hasLiveLabel = row.value == brailleTerms[index].label;
            }
        }
        didApplyBraille = didApplyBraille && hasLiveLabel
            && static_cast<std::size_t>(style) == index
            && readPreferencesStore().find(std::format("braille_style = \"{}\"", brailleTerms[index].token)) != std::string::npos;
    }
    g_print("smoke-beam: braille styles=%zu persisted/live/label=%d\n", brailleTerms.size(), static_cast<int>(didApplyBraille));

    // The toggle has to reach the SHAPER, not only the file and the live values.
    //
    // The two checks above are what this case had before, and they pass while
    // the setting does nothing: the shaping inputs are resolved in the
    // rasterizer's constructor, so reloading preferences and repainting draws
    // the same glyphs through the same shaper. A row that writes the file and
    // changes no pixel is the exact defect the settings scope exists to remove,
    // and asserting the file is how it hides.
    //
    // Read off the live rasterizer rather than a fresh one built with the
    // setting: a fresh one proves the constructor honours its argument, which
    // was never in doubt, and says nothing about whether the running terminal
    // was rebuilt.
    // Pointed at the bundled ligating face first, for the reason
    // --smoke-ligature-shaping gives: fontconfig answers DejaVu Sans Mono for
    // "monospace" in this container and it substitutes nothing, so the check
    // below would be vacuous against whatever the host happens to install.
    // Whether the machine has a ligature face is a capability; whether the
    // toggle reaches the shaper is the contract, and the bundled face is how
    // this asks about the contract.
    const std::string bundledLigatingPath = bundledFontPathForFamily("JetBrains Mono");
    if (!bundledLigatingPath.empty() && app().fontRasterizerKind != Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        app().fontFamily = "JetBrains Mono";
        rebuildFontsFromPreferences();
    }
    bool didShaperFollow = false;
    if (app().glyphRasterizer.has_value()) {
        const std::array<std::uint32_t, 2> arrow { '=', '>' };
        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> shaped {};
        auto substitutions = [&]() {
            const int glyphs = app().glyphRasterizer->shapeTextRun(arrow, 0, shaped);
            int n = 0;
            for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                if (shaped[i].glyph != app().glyphRasterizer->glyphIndexForCodePoint(arrow[i]))
                    ++n;
            }
            return n;
        };
        // Only meaningful where the live face ligates at all — the container
        // resolves DejaVu Sans Mono for "monospace", which substitutes nothing,
        // and a case that demanded a difference there would fail on the font
        // rather than on the code.
        settingAccept.commandID = "beam.setting.font.ligatures";
        const int before = substitutions();
        if (before > 0) {
            runBeamAction(settingAccept); // ligatures -> off
            const int suppressed = substitutions();
            runBeamAction(settingAccept); // and back on
            const int restored = substitutions();
            didShaperFollow = suppressed == 0 && restored == before;
        } else {
            // Stated rather than passed silently: a face that ligates nothing
            // cannot answer this, and a green here would be about the font.
            g_print("  (live face ligates nothing; the shaper-follows check is vacuous here)\n");
            didShaperFollow = true;
        }
    }

    unsetenv("XDG_CONFIG_HOME");
    (void)Ubiquitty::Preferences::configure(savedDocument, Ubiquitty::Preferences::ParseMode::Permissive);

    // Escape leaves the scope before it closes anything: a scope is a place the
    // user navigated to, and one Escape giving up both would throw the palette
    // away over a mistyped prefix.
    const Ubiquitty::Input::BeamKeyOutcome escape
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0);
    if (escape.handled)
        app().beamSession.apply(escape.event, escape.codePoint);
    const bool didLeaveScope
        = escape.handled && app().beamSession.isOpen() && app().beamSession.state().scope == Ubiquitty::CommandPalette::Scope::Actions;

    // The second Escape closes, so the palette cannot strand the keyboard.
    if (escape.handled)
        app().beamSession.apply(escape.event, escape.codePoint);
    const bool didClose = escape.handled && !app().beamSession.isOpen();

    // Accepting a block scrolls to it. End selects the oldest row and the steps
    // back up land on `smokeBeamTargetFromOldest`, which is the block the Core
    // list holds at the same distance from its end — the rows carry the walk's
    // order, so the two agree by construction.
    fillBeamScopes(term); // a summon registers, and this is the second summon
    app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
    if (prefix.handled)
        app().beamSession.apply(prefix.event, prefix.codePoint);
    const Ubiquitty::Input::BeamKeyOutcome toOldest
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEnd, 0, 0);
    if (toOldest.handled)
        app().beamSession.apply(toOldest.event, toOldest.codePoint);
    const Ubiquitty::Input::BeamKeyOutcome stepUp
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyUp, 0, 0);
    for (int i = 1; i < smokeBeamTargetFromOldest && stepUp.handled; ++i)
        app().beamSession.apply(stepUp.event, stepUp.codePoint);
    const Ubiquitty::Screen::CommandBlockList blocks
        = Ubiquitty::Screen::commandBlocks(term, Ubiquitty::Screen::maxCommandBlocks);
    const int targetPromptRow = static_cast<int>(blocks.size()) >= smokeBeamTargetFromOldest
        ? blocks[blocks.size() - static_cast<std::size_t>(smokeBeamTargetFromOldest)].promptRow
        : -1;
    activePane()->viewOffset = 0;
    const Ubiquitty::Input::BeamKeyOutcome accept
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEnter, 0, 0);
    if (accept.handled)
        runBeamAction(app().beamSession.apply(accept.event, accept.codePoint));

    app().rasterContext.setBeamChrome(nullptr); // restore (defensive; smokes are separate processes)

    // The block has to be at the row the reveal policy places it on. Which row
    // that is comes from Core rather than from a constant here: a copy of the
    // rule in the check would agree with a frontend that had drifted from every
    // other one, which is the state this case exists to catch. That row is
    // fixed by the policy, not by the offset, which is what makes it readable:
    // the row the offset itself points at holds the block whatever offset was
    // applied, because the address map (absolute = history - offset + visible)
    // cancels the offset out. A case read at that row agrees with itself under
    // a reveal sent one row off, and reports a jump it has not measured.
    //
    // The offset has to sit strictly INSIDE [0, history] for the same reason: at
    // either bound the reveal is clamped, and a clamped offset is the same value
    // whatever arithmetic produced it.
    std::vector<Ubiquitty::Cell> jumpedGrid;
    app().rasterContext.snapshotVisibleGrid(term, activePane()->viewOffset, jumpedGrid);
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    const int placedRow = Ubiquitty::Screen::landingRowFor(term->rows, Ubiquitty::Screen::RevealPlacement::CommandBlock);
    const bool didJump = accept.handled && !app().beamSession.isOpen() && targetPromptRow >= 0
        && activePane()->viewOffset > 0 && activePane()->viewOffset < history
        && beamSmokeGridRowText(jumpedGrid, term->columns, placedRow)
            == Ubiquitty::Screen::absoluteRowText(*term, targetPromptRow, term->columns);

    const bool didPass = opened && drew && differs && isIdentical && narrowed && didEnterScope && didListBlocks
        && didListFind && isEmptyOnMiss && didSurviveBadPattern && isOneRowPerMatch && didJumpToMatch
        && didListSettings && doesRejectSettingsDefects && areControlsRight && areUneditableAbsent
        && didPersistSetting && didApplySetting && didToggleBack && didApplyBraille && didShaperFollow && didLeaveScope && didClose && didJump;
    g_print("smoke-beam: opened=%d drew=%dx%d@%d,%d body=%d canvasInk=%d/%zu composited=%d(in=%d out=%d) CPU==GPU=%s rows=%zu->%zu->%zu scoped=%d blocks=%zu listed=%d find=%zu(listed=%d miss=%d badpattern=%d wrapped=%zu/dedup=%d jumped=%d) settings=%zu(t=%zu/o=%zu/n=%zu listed=%d oracle=%d controls=%d hidden=%d wrote=%d applied=%d back=%d braille=%d shaper=%d) leaves-scope=%d closes=%d jumped=%d(row=%d at=%d offset=%d/%d) -- %s\n",
        static_cast<int>(opened), geometry.canvas.rows, geometry.canvas.columns, geometry.originRow, geometry.originColumn,
        geometry.bodyRows, canvasInk, geometry.canvas.cells.size(), static_cast<int>(differs), static_cast<int>(differsInside), static_cast<int>(differsOutside), didCompareGPU ? (isIdentical ? "1" : "0") : "skipped(no GPU frame)",
        unfilteredRows, narrowedRows, restoredRows,
        static_cast<int>(didEnterScope), blockRows, static_cast<int>(didListBlocks),
        findRows.size(), static_cast<int>(didListFind), static_cast<int>(isEmptyOnMiss),
        static_cast<int>(didSurviveBadPattern), wrappedRows.size(), static_cast<int>(isOneRowPerMatch), static_cast<int>(didJumpToMatch),
        settingRows.size(), settingToggles, settingOptionDrills, settingNumberDrills,
        static_cast<int>(didListSettings), static_cast<int>(doesRejectSettingsDefects), static_cast<int>(areControlsRight), static_cast<int>(areUneditableAbsent),
        static_cast<int>(didPersistSetting), static_cast<int>(didApplySetting), static_cast<int>(didToggleBack),
        static_cast<int>(didApplyBraille), static_cast<int>(didShaperFollow),
        static_cast<int>(didLeaveScope), static_cast<int>(didClose),
        static_cast<int>(didJump), targetPromptRow, placedRow, activePane()->viewOffset, history,
        didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// Exercises the real application actions and captures the GTK window content.
int smokeWindowChrome(const char* outputDirectory)
{
    if (!gtk_init_check()) {
        g_printerr("smoke-window-chrome: GTK needs a display\n");
        return 1;
    }
    bool didPass = true;
    const auto check = [&](bool condition, const char* message) {
        if (!condition) {
            g_printerr("smoke-window-chrome: FAIL: %s\n", message);
            didPass = false;
        }
    };
    const auto settle = [] {
        const gint64 deadline = g_get_monotonic_time() + 300000;
        do {
            g_main_context_iteration(nullptr, FALSE);
            g_usleep(1000);
        } while (g_get_monotonic_time() < deadline);
    };
    const auto capture = [&](GtkWidget* widget, const char* name) {
        const int width = gtk_widget_get_width(widget);
        const int height = gtk_widget_get_height(widget);
        if (width <= 0 || height <= 0)
            return false;
        GdkPaintable* paintable = gtk_widget_paintable_new(widget);
        GtkSnapshot* snapshot = gtk_snapshot_new();
        gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
        g_object_unref(paintable);
        GskRenderNode* node = gtk_snapshot_free_to_node(snapshot);
        if (!node)
            return false;
        const graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, static_cast<float>(width), static_cast<float>(height));
        GdkTexture* texture = gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(widget)), node, &bounds);
        gsk_render_node_unref(node);
        if (!texture)
            return false;
        bool didSave = true;
        if (outputDirectory) {
            const std::string path = std::string(outputDirectory) + "/" + name + ".png";
            didSave = gdk_texture_save_to_png(texture, path.c_str());
        }
        g_object_unref(texture);
        return didSave;
    };
    GtkApplication* application = gtk_application_new("org.ubiquitty.chrome-test", G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(G_APPLICATION(application), nullptr, nullptr)) {
        g_object_unref(application);
        return 1;
    }
    onActivate(application, nullptr);
    settle();
    check(app().tabStrip && gtk_widget_get_mapped(app().tabStrip), "a single tab has visible navigation");
    check(app().menuButton && gtk_widget_get_mapped(app().menuButton), "the application menu is visible");
    gtk_menu_button_popup(GTK_MENU_BUTTON(app().menuButton));
    settle();
    check(onKeyPressed(nullptr, GDK_KEY_Down, 0, static_cast<GdkModifierType>(0), nullptr) == GDK_EVENT_PROPAGATE,
        "menu navigation reaches GTK instead of the terminal");
    gtk_menu_button_popdown(GTK_MENU_BUTTON(app().menuButton));
    const SurfaceID surface = app().model->activeSurface();
    const TabID firstTab = app().model->activeTab(surface);
    g_action_group_activate_action(G_ACTION_GROUP(application), "new-tab", nullptr);
    settle();
    check(app().model->tabCount(surface) == 2, "the menu opens a second tab");
    GtkWidget* firstButton = gtk_widget_get_first_child(app().tabStrip);
    if (firstButton) {
        g_signal_emit_by_name(firstButton, "clicked");
        settle();
        check(app().model->activeTab(surface) == firstTab, "clicking a tab changes the focused session");
        firstButton = gtk_widget_get_first_child(app().tabStrip);
        check(gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(firstButton)), "the selected tab follows the model");
    } else
        check(false, "the strip contains a tab button");
    check(capture(app().window, "tabs"), "the window produces a rendered frame");
    g_action_group_activate_action(G_ACTION_GROUP(application), "about", nullptr);
    settle();
    GListModel* windows = gtk_window_get_toplevels();
    GtkWidget* about = nullptr;
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GObject* window = G_OBJECT(g_list_model_get_item(windows, i));
        if (GTK_IS_ABOUT_DIALOG(window)) {
            about = GTK_WIDGET(window);
            break;
        }
        g_object_unref(window);
    }
    check(about != nullptr, "About opens an application information window");
    if (about) {
        check(gtk_widget_get_mapped(about), "About is mapped");
        check(g_strcmp0(gtk_about_dialog_get_program_name(GTK_ABOUT_DIALOG(about)), "Ubiquitty") == 0,
            "About names the application");
        check(g_strcmp0(gtk_about_dialog_get_version(GTK_ABOUT_DIALOG(about)), Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str()) == 0,
            "About shows the running build identity");
        check(gtk_about_dialog_get_license_type(GTK_ABOUT_DIALOG(about)) == GTK_LICENSE_APACHE_2_0,
            "About identifies the application license");
        check(capture(about, "about"), "About produces a rendered frame");
        gtk_window_close(GTK_WINDOW(about));
        g_object_unref(about);
    }
    app().configurationWatcher.stop();
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    if (app().isVulkanReady)
        app().vulkan.shutdown();
    g_object_unref(application);
    g_print("smoke-window-chrome: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// The headless tab lifecycle uses real PTYs without creating a GTK window.
int smokeTabs()
{
    setupFonts(); // valid cell dims for the per-pane setWindowSize
    bool ok = true;
    auto check = [&](bool cond, const char* what) {
        if (!cond) {
            g_printerr("smoke-tabs: FAIL: %s\n", what);
            ok = false;
        }
    };
    // (1) Open the window's surface through the model: one tab, a launched
    // root pane, a live PTY fd, a registered drain source.
    if (!launchShell()) {
        g_printerr("smoke-tabs: FAIL: launch default pane\n");
        return 1;
    }
    const SurfaceID surface = app().model->activeSurface();
    const PaneID firstPane = app().model->focusedPane(surface);
    const TabID firstTab = app().model->activeTab(surface);
    const LinuxPane* firstPaneAddress = activePane();
    const int firstFileDescriptor = activePane()->session->fileDescriptor();
    check(app().model->tabCount(surface) == 1, "one tab after default");
    check(paneForID(firstPane) == activePane(), "default pane mapped to its PaneID");
    check(firstFileDescriptor >= 0, "default pane has a live PTY descriptor");
    check(activePane()->ptySource != 0, "default pane registered its drain source");

    // (2) newTab twice: real launches, distinct descriptors + sources, the model +
    // registry grow in lockstep, PaneIDs are distinct + monotonic, and the first
    // pane's heap address is STABLE across the vector growth (non-movable invariant).
    newTab();
    const PaneID pane2 = app().model->focusedPane(surface);
    const TabID tab2 = app().model->activeTab(surface);
    const LinuxPane* pane2Ptr = activePane();
    newTab();
    const PaneID pane3 = app().model->focusedPane(surface);
    check(app().model->tabCount(surface) == 3, "three tabs after two newTab");
    check(app().panes.size() == 3 && app().paneByID.size() == 3, "three live panes tracked");
    check(firstPane != pane2 && pane2 != pane3 && firstPane != pane3, "distinct PaneIDs");
    check(pane2 < pane3, "monotonic PaneIDs");
    check(activePane() == paneForID(pane3), "newTab focused the new pane");
    check(activePane()->session->fileDescriptor() >= 0 && activePane()->ptySource != 0, "new pane has its own live descriptor + source");
    check(paneForID(firstPane) == firstPaneAddress, "first pane address stable across growth");

    // (3) Switching moves the model's focus, which is what activePane() reads.
    switchToTab(firstTab);
    check(activePane() == paneForID(app().model->focusedPane(surface)) && activePane() == firstPaneAddress, "switch to tab 1 follows the model");
    switchTabRelative(+1); // -> tab 2
    check(activePane() == paneForID(pane2) && activePane() == pane2Ptr, "relative switch +1 -> tab 2");
    switchTabRelative(-1); // wrap/back -> tab 1
    check(activePane() == paneForID(firstPane), "relative switch -1 -> tab 1");

    // Fractional points survive both the DPI conversion and backing scale.
    const double savedPoints = app().fontSizePoints;
    const double savedDPI = app().fontDPI;
    const int savedScale = app().scale;
    app().fontDPI = 96;
    app().fontSizePoints = 15.5;
    app().scale = 2;
    const int halfPointAtTwo = deviceFontPixelSize();
    app().fontSizePoints = 16.0;
    const int wholePointAtTwo = deviceFontPixelSize();
    app().fontSizePoints = 15.0;
    const int belowAtTwo = deviceFontPixelSize();
    app().fontSizePoints = savedPoints;
    app().fontDPI = savedDPI;
    app().scale = savedScale;
    check(halfPointAtTwo == 41, "15.5pt at 96 DPI and 2x is 41 device pixels");
    check(belowAtTwo == 40 && wholePointAtTwo == 43, "whole points include both DPI and backing scale");

    // (3b) The ':' scope is a projection of the model above, so it is asserted
    // here where three real tabs exist rather than against a constructed one.
    //
    // Written to fail if the feature is removed: dropping `beamGoToCommands`
    // leaves `gotoRows` at zero, dropping the current-marker leaves
    // `gotoMarksOne` false, and dropping the accept arm in `runBeamAction`
    // leaves `gotoSwitched` false with the tab unmoved.
    switchToTab(firstTab);
    const Ubiquitty::CommandPalette::PaletteCommandList gotoRows = beamGoToCommands();
    check(gotoRows.size() == 3, "the goto scope lists all three tabs");
    // One pane per tab here, and a single pane is not a destination, so the
    // list is tabs alone — a pane row appearing would mean the suppression that
    // keeps a lone pane out of the list has gone.
    std::size_t gotoPaneRows = 0;
    std::size_t gotoCurrentRows = 0;
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : gotoRows) {
        if (row.id.starts_with(beamGoToPaneIDPrefix))
            ++gotoPaneRows;
        if (row.group.find("current") != std::string::npos)
            ++gotoCurrentRows;
    }
    check(gotoPaneRows == 0, "a lone pane is not offered as a destination");
    check(gotoCurrentRows == 1, "exactly one row is marked current");
    // And it is the ACTIVE tab that carries the marker, not merely some row —
    // a marker on a fixed position would satisfy the count above.
    const std::string firstTabRowID = beamGoToTabIDPrefix + std::to_string(static_cast<std::uint32_t>(firstTab));
    bool isActiveTabMarked = false;
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : gotoRows) {
        if (row.id == firstTabRowID)
            isActiveTabMarked = row.group.find("current") != std::string::npos;
    }
    check(isActiveTabMarked, "the marked row is the active tab");

    // Accepting a row moves there. Driven through `runBeamAction` because that
    // is what the palette calls, so a dispatch that stopped recognising the
    // prefix fails here rather than only in a live window.
    using BeamActionKind = Ubiquitty::CommandPalette::BeamAction::Kind;
    Ubiquitty::CommandPalette::BeamAction gotoAccept;
    gotoAccept.kind = BeamActionKind::Run;
    gotoAccept.commandID = beamGoToTabIDPrefix + std::to_string(static_cast<std::uint32_t>(tab2));
    runBeamAction(gotoAccept);
    check(app().model->activeTab(surface) == tab2 && activePane() == pane2Ptr, "accepting a goto row switches to that tab");

    // An id no tab holds leaves the focus alone rather than moving somewhere.
    // `switchToTab` refuses an unknown handle, and this is the case that says so
    // through the palette's own path.
    gotoAccept.commandID = beamGoToTabIDPrefix + std::string("999999");
    runBeamAction(gotoAccept);
    check(app().model->activeTab(surface) == tab2, "an unknown goto id moves nothing");
    switchToTab(firstTab);

    // (4) Close the active tab: the source is torn down, the model + registry shrink,
    // and a neighbor is reselected.
    switchToTab(tab2);
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 2, "two tabs after close");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "two live panes after close");
    check(paneForID(pane2) == nullptr, "closed pane dropped from the registry");
    check(activePane() != nullptr && activePane() == paneForID(app().model->focusedPane(surface)), "active reselected to a neighbor after close");

    // (5) Close down to one; the last tab is the window-close path (app().window is null
    // here, so closePaneTab is a no-op on the model — it must not drop below one tab).
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 1, "one tab after second close");
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 1 && app().panes.size() == 1, "last tab survives closePaneTab");

    // Tear down the surviving pane's source, then end the surface's sessions
    // through the model before the pane views die — a Terminal must never
    // outlive the pane clients it references.
    if (activePane() && activePane()->ptySource != 0) {
        g_source_remove(activePane()->ptySource);
        activePane()->ptySource = 0;
    }
    app().model->closeWindowSurface(surface);
    app().panes.clear();
    app().paneByID.clear();
    g_print("smoke-tabs: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// --smoke-pacing — that a repaint request reaches the pacing policy.
//
// The frontend asks the frame clock to stop calling back once output has been
// idle for the driver's timeout, so what brings the clock back is the driver
// hearing about new activity. Every path that wants a frame goes through
// requestRepaint() for exactly that reason, and a path that set the flag
// directly would mark a frame with nothing left installed to paint it.
//
// Headless, so there is no widget and no callback to install. What is checked
// is the half that decides: the flag, and the driver's answer to whether output
// has gone quiet. The callback bookkeeping needs a display and belongs to the
// windowed smokes.
int smokePacing()
{
    bool ok = true;
    auto check = [&](bool isSatisfied, const char* what) {
        if (!isSatisfied) {
            g_printerr("smoke-pacing: FAIL: %s\n", what);
            ok = false;
        }
    };

    const auto nowSeconds = [] { return static_cast<double>(Ubiquitty::PAL::monotonicMicros()) / 1e6; };
    const double idleTimeout = app().frameDriver.idleTimeoutSeconds();
    check(idleTimeout > 0.0, "the driver has no idle timeout, so the clock would never pause");

    // A request marks the frame and tells the driver output just flowed.
    app().isRepaintPending = false;
    requestRepaint();
    check(app().isRepaintPending, "requestRepaint did not mark a frame pending");
    check(!app().frameDriver.idleExpired(nowSeconds()),
        "the driver called output idle immediately after a repaint request — requestRepaint is not stamping it");

    // And that it is a stamp rather than a latch: the same driver has to report
    // idle once the timeout has passed with nothing asking for a frame.
    check(app().frameDriver.idleExpired(nowSeconds() + idleTimeout + 1.0),
        "the driver never reports idle, so the clock would keep calling back on a terminal nobody is watching");

    // Cursor-only opacity steps request a frame without making output look
    // active. Once the toolkit blink times out, no such step is scheduled and
    // the frame clock can remain uninstalled.
    (void)app().frameDriver.noteActivity(1.0);
    app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::OnDemand);
    app().isRepaintPending = false;
    requestRepaint(RepaintCause::CursorStep);
    check(app().isRepaintPending && app().frameDriver.idleExpired(nowSeconds()),
        "a cursor-only repaint kept the idle frame clock alive");

    // A pane starts ingesting before its picture is rooted. Its fallback
    // interval must turn the adaptive recommendation on-demand after output
    // stops; an unset interval makes onTick request another frame forever.
    Ubiquitty::Runtime::FrameDriver adaptive;
    adaptive.setAdaptiveDrive(Ubiquitty::Runtime::AdaptiveDrive::On);
    check(adaptive.recommendedMode(1.0) == Ubiquitty::Runtime::FrameMode::Continuous,
        "an unset pane rate should expose the continuous-drive failure mode");
    adaptive.setFrameIntervalSeconds(cursorPresentationInterval(nullptr));
    check(adaptive.recommendedMode(1.0) == Ubiquitty::Runtime::FrameMode::OnDemand,
        "an unrooted pane has no fallback rate, so an idle pane would repaint at vblank");

    g_print("smoke-pacing: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// --smoke-splits — the split lifecycle headlessly (app().window/app().paneContainer null, so
// attachPaneControllers + rebuildPaneTree are no-operations and renderPaneInto bails): the
// real splitFocusedPaneUX / moveFocusUX / closeFocusedPaneUX with LAUNCHED panes.
// Verifies per-pane PTY launch + fd-source registration, registry stability across
// growth (the non-movable invariant), Workspace<->registry lockstep on split, spatial
// moveFocus, the collapse + source teardown on close, and the last-pane escalation.
int smokeSplits()
{
    setupFonts();
    bool ok = true;
    auto check = [&](bool cond, const char* what) {
        if (!cond) {
            g_printerr("smoke-splits: FAIL: %s\n", what);
            ok = false;
        }
    };
    if (!launchShell()) {
        g_printerr("smoke-splits: FAIL: launch default pane\n");
        return 1;
    }
    const SurfaceID surface = app().model->activeSurface();
    auto paneCount = [&]() {
        const Panes::Tree* tree = app().model->paneTree(surface);
        return tree != nullptr ? tree->paneCount() : 0;
    };
    const PaneID firstPane = app().model->focusedPane(surface);
    const LinuxPane* firstPaneAddress = activePane();
    check(paneCount() == 1, "one pane initially");

    // (1) Split side-by-side: a new launched pane, focused, distinct + monotonic id,
    // its own live descriptor + drain source, and the first pane's address STABLE.
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const PaneID pane2 = app().model->focusedPane(surface);
    check(paneCount() == 2, "two panes after split");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "two live panes tracked");
    check(pane2 != invalidPane && pane2 != firstPane && pane2 > firstPane, "new PaneID distinct + monotonic");
    check(activePane() == paneForID(pane2), "split focuses the new pane");
    check(activePane()->session->fileDescriptor() >= 0 && activePane()->ptySource != 0, "new pane has its own live descriptor + source");
    check(paneForID(firstPane) == firstPaneAddress, "first pane address stable across growth");

    // (2) moveFocus across the vertical divider returns to the original (left) pane.
    moveFocusUX(Panes::Direction::Left);
    check(activePane() == paneForID(app().model->focusedPane(surface)), "moveFocus follows the model");
    check(activePane() == firstPaneAddress, "moveFocus Left reaches the original pane");

    // (3) A split tab remembers which of its panes had focus across a tab
    // round-trip. Focus is left on the first pane above, so a switch away and back
    // must land there and not on the split's newer pane — the case that
    // distinguishes activating a tab from naming a pane inside it.
    const TabID splitTab = app().model->activeTab(surface);
    newTab();
    const TabID extraTab = app().model->activeTab(surface);
    check(extraTab != splitTab, "newTab left the split tab");
    switchToTab(splitTab);
    check(activePane() == firstPaneAddress, "the split tab restored ITS focused pane");
    check(paneCount() == 2, "back to the split tab with both panes");
    switchToTab(extraTab);
    closePaneTab(activePane());
    check(app().model->activeTab(surface) == splitTab && paneCount() == 2, "closing the extra tab returns to the split one");

    // (4) Split again to three panes.
    splitFocusedPaneUX(Panes::Orientation::Horizontal);
    const PaneID pane3 = app().model->focusedPane(surface);
    check(paneCount() == 3, "three panes after second split");
    check(app().panes.size() == 3 && pane3 != firstPane && pane3 != pane2 && pane3 > pane2, "third pane distinct + monotonic");

    // (5) Close the focused pane: collapse one level, registry shrinks, the closed
    // pane is gone, and focus moves to a neighbor leaf.
    const PaneID closed = app().model->focusedPane(surface);
    closeFocusedPaneUX();
    check(paneCount() == 2, "two panes after close");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "registry shrank on close");
    check(paneForID(closed) == nullptr, "closed pane dropped from the registry");
    check(activePane() != nullptr && activePane() == paneForID(app().model->focusedPane(surface)), "focus moved to a neighbor leaf");

    // (6) Close down to one pane; the last pane escalates to the tab/window-close path
    // (app().window null → a model no-op, must not drop below one pane).
    closeFocusedPaneUX();
    check(paneCount() == 1, "one pane after second close");
    closeFocusedPaneUX();
    check(paneCount() == 1 && app().panes.size() == 1, "last pane survives close (window-close path)");

    // End the surface's sessions through the model before the pane views die
    // — a Terminal must never outlive the pane clients it references.
    if (activePane() && activePane()->ptySource != 0) {
        g_source_remove(activePane()->ptySource);
        activePane()->ptySource = 0;
    }
    app().model->closeWindowSurface(surface);
    app().panes.clear();
    app().paneByID.clear();
    g_print("smoke-splits: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// --smoke-clear — Ctrl+Shift+K clear-buffer: print a line, clear, assert the row is
// blank afterward (the cursor row is preserved; the screen above it is wiped).
int smokeClear()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-clear: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "ABC\n"); // row 0 = "ABC", cursor moves to row 1
    const Ubiquitty::Cell* before = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const bool hadText = before != nullptr && before->codePoint == static_cast<uint32_t>('A');
    Ubiquitty::clearBufferPreserveInput(term);
    const Ubiquitty::Cell* after = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const bool cleared = after == nullptr || after->codePoint == 0 || after->codePoint == static_cast<uint32_t>(' ');
    const bool didPass = hadText && cleared;
    g_print("smoke-clear: had-text=%d cleared=%d -- %s\n", static_cast<int>(hadText), static_cast<int>(cleared), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-font-zoom — Ctrl++/−/0 runtime font zoom: assert the derived cell grows on
// zoom-in and restores on reset. No-op (auto-PASS) in Unifont mode (a fixed bitmap).
int smokeFontZoom()
{
    setupFonts();
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        g_print("smoke-font-zoom: PASS (Unifont — zoom not applicable)\n");
        return 0;
    }
    const int width0 = app().rasterContext.cellWidth();
    const int height0 = app().rasterContext.cellHeight();
    applyFontZoom(app().fontPixelSize + 8);
    const int width1 = app().rasterContext.cellWidth();
    const int height1 = app().rasterContext.cellHeight();
    const bool grew = width1 > width0 && height1 > height0;
    applyFontZoom(app().defaultFontPixelSize);
    const bool restored = app().rasterContext.cellWidth() == width0 && app().rasterContext.cellHeight() == height0;
    const bool didPass = grew && restored;
    g_print("smoke-font-zoom: %dx%d -> %dx%d (grew=%d), reset restored=%d -- %s\n", width0, height0, width1, height1, static_cast<int>(grew), static_cast<int>(restored), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-prompt-navigation — Ctrl+Shift+Up/Down jump-to-prompt: build scrollback, mark a
// history row as a command-executed prompt, assert jump-previous scrolls to it and
// jump-next (no prompt below) snaps back to the live tail.
int smokePromptNavigation()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-prompt-navigation: no term\n");
        return 1;
    }
    for (int i = 0; i < startupRows + 10; ++i) // push lines into scrollback
        Ubiquitty::processBytes(term, "line\n");
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    if (history < 2) {
        g_printerr("smoke-prompt-navigation: FAIL (no scrollback: %d)\n", history);
        return 1;
    }
    const int markRow = 1; // an early history row
    Ubiquitty::Screen::addRowMark(term, markRow, Ubiquitty::Screen::osc133MarkCmdExecuted);
    activePane()->viewOffset = 0; // live tail
    activePane()->promptNavigationRow = -1;
    jumpToPrompt(-1); // previous prompt → scroll to markRow
    const bool didJump = activePane()->viewOffset > 0 && activePane()->promptNavigationRow == markRow;
    jumpToPrompt(+1); // none below → snap to the live tail
    const bool didSnap = activePane()->viewOffset == 0;
    const bool didPass = didJump && didSnap;
    g_print("smoke-prompt-navigation: jumped=%d snapped=%d -- %s\n", static_cast<int>(didJump), static_cast<int>(didSnap), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --smoke-select-all — Ctrl+Shift+A select-all: a distinctive first line is pushed
// into SCROLLBACK and a distinctive last line stays on screen; assert the facade's
// whole-buffer selection copies both (proving it reaches past the visible grid).
int smokeSelectAll()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-select-all: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "FIRSTLINE\n"); // scrolls into history
    for (int i = 0; i < startupRows + 5; ++i)
        Ubiquitty::processBytes(term, "filler\n");
    Ubiquitty::processBytes(term, "LASTLINE"); // on the live screen
    selectAll();
    const std::string all = selectionText();
    const bool hasFirst = all.find("FIRSTLINE") != std::string::npos; // from scrollback
    const bool hasLast = all.find("LASTLINE") != std::string::npos; // from the screen
    const bool didPass = hasFirst && hasLast;
    g_print("smoke-select-all: first=%d last=%d -- %s\n", static_cast<int>(hasFirst), static_cast<int>(hasLast), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}

// --print-config [path] — parse a config file via the portable Settings loader and
// print the fields the Linux frontend applies, proving the load + the field
// mapping without a display. With no path, write a temp config with KNOWN values
// (the real TOML keys from Preferences.cpp: [font] family/size, [terminal]
// scrollback_lines, [cursor] blink, [security] clipboard_read), load it back, and
// assert the parsed fields round-trip. PASS/FAIL.
int printConfig(const char* path)
{
    std::string usedPath;
    bool wroteTemp = false;

    if (path) {
        usedPath = path;
    } else {
        usedPath = "/tmp/ubiquitty-print-config.toml";
        {
            std::ofstream outputBuffer(usedPath.c_str(), std::ios::trunc);
            outputBuffer << "[font]\n"
                         << "family = \"GNU Unifont\"\n"
                         << "size = 20\n"
                         << "\n"
                         << "[cursor]\n"
                         << "blink = false\n"
                         << "\n"
                         << "[terminal]\n"
                         << "scrollback_lines = 5000\n"
                         << "\n"
                         << "[security]\n"
                         << "clipboard_read = \"deny\"\n";
        }
        wroteTemp = true;
    }
    // Through the door every other caller takes: the file's document becomes
    // the live configuration, and the dump reads what Core resolved.
    (void)Ubiquitty::Preferences::configureFromFile(usedPath, Ubiquitty::Preferences::ParseMode::Permissive);
    const Ubiquitty::Preferences::Values& config = Ubiquitty::Preferences::values();

    g_print("print-config: source = %s\n", usedPath.c_str());
    // `<unset>` where a key is absent, so the dump distinguishes a value a
    // person chose from one this build would have used anyway.
    const auto stated = [](const auto& field, auto&& render) {
        return field.has_value() ? render(*field) : std::string("<unset>");
    };
    g_print("  [font] family        = %s\n", stated(config.fontFamily, [](const std::string& v) { return v; }).c_str());
    g_print("  [font] size          = %s\n", stated(config.fontSize, [](double v) { return std::format("{:g}", v); }).c_str());
    g_print("  [cursor] blink       = %s\n", stated(config.cursorBlink, [](bool isOn) { return std::string(isOn ? "true" : "false"); }).c_str());
    g_print("  [terminal] scrollback_lines = %s\n", stated(config.scrollbackLines, [](int v) { return std::to_string(v); }).c_str());
    g_print("  [security] clipboard_read  = %s\n", stated(config.clipboardRead, [](const std::string& v) { return v; }).c_str());

    // Round-trip assertion only when we wrote the temp config (known values).
    if (!wroteTemp) {
        g_print("print-config: PASS (loaded %s; no round-trip assertion for an external file)\n", usedPath.c_str());
        return 0;
    }

    const bool ok = config.fontFamily == "GNU Unifont" && config.fontSize == 20.0 && config.cursorBlink == false && config.scrollbackLines == 5000
        && config.clipboardRead == "deny";
    g_print("print-config: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// What `--snapshot` takes: an output path and a configuration, which are
// required, and a grid, a feed and a view that otherwise have the values a
// window opened by hand would.
struct SnapshotArguments {
    const char* outputPath = nullptr; // --snapshot <png>
    const char* configPath = nullptr; // --config <toml>, read strictly
    const char* feedFile = nullptr; // --feed-file <path>, whose bytes stand in for --feed
    std::string feed; // --feed <text>, with its escapes decoded
    int columns = 80; // --columns
    int rows = 24; // --rows
    // The backing scale a comparison renders at. 2 because a Retina macOS
    // surface reports that, and two arms' images mean nothing to each other
    // until they are the same size.
    double scale = 2.0;
    int viewOffset = 0; // --view-offset, rows scrolled back into history
    // The OSC 66 sizing gate a window declares at session start; the macOS
    // driver takes the same flag, and a case that renders sized text asks for
    // it rather than every case rendering it.
    bool drawsSizedText = false;
    // A literal to run through the find bar's own search before the render, so
    // the snapshot can exercise the match emphasis. The active match sets the
    // view offset, which is why it overrides --view-offset rather than adding
    // to it: a caller cannot ask for a match and a scroll position at once.
    const char* searchLiteral = nullptr;
    // The backing scale to render at. One by default because the cross-arm
    // agreement goldens are compared byte for byte against the portable and
    // browser arms, which rasterize at device resolution — this arm alone at 2
    // would disagree with both on every shared case. A case that shows the
    // NATIVE face asks for 2 and gets the density macOS's snapshot renders at.
    // 2, matching every other arm: a comparison is rendered at one backing scale
    // or its images are different sizes before a pixel is read.
    int deviceScale = 2;
    // --select-rect r0,c0,r1,c1: a character selection over visible cells,
    // the pane's own selection state as a drag would leave it.
    std::optional<Ubiquitty::SelectionBounds> selection;
    // --select-points x0,y0,x1,y1: a plain drag between two points, in cells
    // across and rows down, unrounded, run through the pointer ladder's caret
    // gesture, so a selection can start and end inside a rich text block.
    std::optional<std::array<double, 4>> selectionPoints;
    // --reflow-from-columns N: the feed is written at N columns, then the grid
    // is resized to `columns` and rewrapped before the frame; 0 writes it at
    // `columns`.
    int reflowFromColumns = 0;
    // --unfocused: the frame of a window without keyboard focus. Focus is a
    // fact the window reports and Core decides the cursor's look from it.
    bool isUnfocused = false;
    // --clear-to-mark and --clear-preserve-input: the two clear gestures,
    // run on the fed terminal before the render.
    bool shouldClearToMark = false;
    bool shouldClearPreservingInput = false;
    // The flags that are configuration keys, written into the case's document.
    Ubiquitty::Preferences::SnapshotConfigurationFlags configurationFlags;
};

// Reads a feed file whole, as bytes. A file that cannot be opened, or that
// fails before its end, is refused rather than fed short: a truncated feed
// renders a frame that looks finished.
std::optional<std::string> readFeedFile(const char* path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
        return std::nullopt;
    std::string bytes { std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>() };
    if (input.bad())
        return std::nullopt;
    return bytes;
}

// Parses `--snapshot` and what follows it. A flag that takes a value takes
// exactly one; a flag missing its value, a flag nobody defined, or a backend
// other than this arm's refuses the whole command line, and so does a grid
// too small to draw.
bool parseSnapshotArguments(int argc, char** argv, SnapshotArguments& arguments)
{
    const std::span<char*> words(argv, static_cast<std::size_t>(argc));
    std::size_t index = 1;
    // The value after the current flag, consumed, or null at the line's end.
    const auto value = [&]() -> const char* { return index + 1 < words.size() ? words[++index] : nullptr; };
    const auto integer = [&](int& into) {
        const char* text = value();
        if (text)
            into = std::atoi(text);
        return text != nullptr;
    };
    for (; index < words.size(); ++index) {
        const std::string_view flag(words[index]);
        if (flag == "--snapshot") {
            arguments.outputPath = value();
        } else if (flag == "--config") {
            arguments.configPath = value();
        } else if (flag == "--feed-file") {
            arguments.feedFile = value();
        } else if (flag == "--search") {
            arguments.searchLiteral = value();
        } else if (flag == "--draws-sized-text") {
            arguments.drawsSizedText = true;
        } else if (flag == "--snapshot-backend") {
            const char* backend = value();
            if (!backend || std::string_view(backend) != "linux")
                return false;
        } else if (flag == "--feed") {
            const char* text = value();
            if (!text)
                return false;
            arguments.feed = Ubiquitty::Diagnostics::decodeEscapes(text);
        } else if (flag == "--scale") {
            const char* text = value();
            if (!text)
                return false;
            arguments.scale = std::atof(text);
        } else if (flag == "--columns") {
            if (!integer(arguments.columns))
                return false;
        } else if (flag == "--rows") {
            if (!integer(arguments.rows))
                return false;
        } else if (flag == "--view-offset") {
            if (!integer(arguments.viewOffset))
                return false;
        } else if (flag == "--device-scale") {
            int requested = 0;
            if (!integer(requested))
                return false;
            arguments.deviceScale = std::clamp(requested, 1, 4);
        } else if (flag == "--select-rect") {
            const char* text = value();
            Ubiquitty::SelectionBounds bounds {};
            if (!text || std::sscanf(text, "%d,%d,%d,%d", &bounds.row0, &bounds.column0, &bounds.row1, &bounds.column1) != 4)
                return false;
            arguments.selection = bounds;
        } else if (flag == "--select-points") {
            const char* text = value();
            std::array<double, 4> points {};
            if (!text || std::sscanf(text, "%lf,%lf,%lf,%lf", &points[0], &points[1], &points[2], &points[3]) != 4)
                return false;
            arguments.selectionPoints = points;
        } else if (flag == "--reflow-from-columns") {
            if (!integer(arguments.reflowFromColumns) || arguments.reflowFromColumns < 0)
                return false;
        } else if (flag == "--unfocused") {
            arguments.isUnfocused = true;
        } else if (flag == "--clear-to-mark") {
            arguments.shouldClearToMark = true;
        } else if (flag == "--clear-preserve-input") {
            arguments.shouldClearPreservingInput = true;
        } else {
            using Ubiquitty::Preferences::SnapshotFlagParse;
            const SnapshotFlagParse parsed = Ubiquitty::Preferences::parseSnapshotConfigurationFlag(flag, value, arguments.configurationFlags);
            if (parsed != SnapshotFlagParse::Consumed)
                return false;
        }
    }
    return arguments.outputPath && arguments.configPath && arguments.columns >= 2 && arguments.rows >= 2;
}

// --snapshot: one frame of a fed terminal, rendered through the CPU
// compositor under the configuration the case names, written as a PNG. Exit
// 2 is a refused command line or configuration; otherwise the render's own
// status.
int runSnapshot(int argc, char** argv)
{
    constexpr int refused = 2;
    SnapshotArguments arguments;
    if (!parseSnapshotArguments(argc, argv, arguments)) {
        g_printerr("snapshot: invalid or incomplete arguments\n");
        return refused;
    }

    // The case's document is the live configuration, wholesale. The render
    // path reads settings from `Preferences::values()` — a snapshot that parsed
    // a file into a local would draw the case's font at the case's size with the
    // machine's underline settings, and report success. Strict: a misspelt key
    // fails the case rather than drawing without it. The flags that are the
    // configuration's own keys are written into the document first, as the
    // macOS driver writes them, so the fold reads them with the rest.
    const std::optional<std::string> document = readFeedFile(arguments.configPath);
    if (!document) {
        g_printerr("snapshot: config could not be read\n");
        return refused;
    }
    const std::optional<std::string> stated = Ubiquitty::Preferences::stateSnapshotConfigurationFlags(arguments.configurationFlags, *document);
    if (!stated) {
        g_printerr("snapshot: a configuration flag could not be written into the document\n");
        return refused;
    }
    const Ubiquitty::Preferences::ConfigureResult configured
        = Ubiquitty::Preferences::configure(*stated, Ubiquitty::Preferences::ParseMode::Strict);
    if (!configured.isApplied) {
        for (const Ubiquitty::Preferences::SkippedKey& skipped : configured.diagnostics)
            g_printerr("snapshot: %s: %s\n", arguments.configPath, Ubiquitty::Preferences::diagnosticSentence(skipped).c_str());
        g_printerr("snapshot: config contains an invalid setting\n");
        return refused;
    }
    const Ubiquitty::Preferences::Values& configuration = Ubiquitty::Preferences::values();
    if (arguments.feedFile) {
        std::optional<std::string> fileFeed = readFeedFile(arguments.feedFile);
        if (!fileFeed) {
            g_printerr("snapshot: feed file could not be read\n");
            return refused;
        }
        arguments.feed = std::move(*fileFeed);
    }

    // Before setupFonts, because the rasterizer is sized at construction: the
    // font pixel size is the point size times this scale, and a scale applied
    // afterwards would leave a 1x face inside a 2x grid.
    app().scale = arguments.deviceScale;
    // Snapshot device-scale is defined as pixels per point across platforms;
    // its fixed 72-DPI coordinate system must not inherit desktop preferences.
    app().fontDPI = 72.0;
    app().rasterContext.setDeviceScale(arguments.deviceScale);
    Ubiquitty::Themes::registerThemesFromValues(configuration);
    setupFonts();
    applyWindowGlobalRenderSettings(configuration);
    // A case naming a background image that does not load fails rather than
    // drawing the window without it.
    if (!app().backgroundImagePath.empty() && !app().rasterContext.backgroundImageLayer().pixels) {
        g_printerr("snapshot: the configured background image could not be read or decoded\n");
        return refused;
    }
    // What the window declares, so a golden shows what a window shows.
    activePane()->session->start(arguments.rows, arguments.reflowFromColumns > 0 ? arguments.reflowFromColumns : arguments.columns,
        arguments.drawsSizedText ? Ubiquitty::Runtime::DrawnText::SizedAndProportional : Ubiquitty::Runtime::DrawnText::GridOnly);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("snapshot: terminal initialization failed\n");
        return refused;
    }
    if (!Ubiquitty::Runtime::seedConfiguredTheme(*term, configuration)) {
        g_printerr("snapshot: configured theme was not found\n");
        return refused;
    }
    // The config's [triggers] block, installed the same way the live path does
    // at startup. Without it a snapshot loads a config carrying trigger rules
    // and renders a terminal that has none, so a case written to exercise a
    // `highlight` rule captures a frame where the rule never fired.
    //
    // The refusals are reported for the reason the return is [[nodiscard]]: a
    // rule the parser rejected renders identically to one nobody wrote. A case
    // whose trigger failed to install would mint a golden with no highlight in
    // it, and every later run would agree with that golden.
    const std::string triggerRejections
        = Ubiquitty::Runtime::describeTriggerConfig(Ubiquitty::Runtime::applyTriggerConfig(*term, configuration));
    if (!triggerRejections.empty())
        g_printerr("snapshot: %s\n", triggerRejections.c_str());
    const Ubiquitty::Rendering::CellMetrics metrics = currentRasterizer().cellMetrics();
    const Ubiquitty::IntSize cell { Ubiquitty::Rendering::cellDimension(metrics.cellWidth), Ubiquitty::Rendering::cellDimension(metrics.cellHeight) };
    const Ubiquitty::IntSize textArea { cell.width * term->columns, cell.height * term->rows };
    Ubiquitty::publishPixelGeometry(*term, { cell, textArea, textArea });
    // The heuristic behind the password badge is a per-terminal capability the
    // live path gets from seedTerminalConfiguration. Applied before the feed,
    // because it decides what the feed's settled prompt row means: without it a
    // case written to show the badge renders a terminal that has no heuristic,
    // and every later run agrees with that golden.
    Ubiquitty::setPasswordDetect(term, Ubiquitty::Preferences::Effective::passwordDetect(configuration));
    // The `[cursor]` block is terminal state the live path gets from the same
    // seed: what Cursor::resolve falls back to while no program has sent
    // DECSCUSR. A terminal built here starts on the struct's zero — a block —
    // whatever shape the configuration names, so it is seeded before the feed,
    // which may itself set a style that outranks it.
    Ubiquitty::Preferences::Effective::applyCursorPreferences(*term, configuration);
    const auto richShaper = activePane()->richText.shaper();
    activePane()->session->setRichTextShaper(richShaper.function, richShaper.context);
    publishPaneTypography(*activePane());
    // A window measures proportional runs through its GPU renderer's strip
    // sheet, which a headless snapshot never builds; the snapshot measures in
    // the face its CPU frame draws them in, so a query and a rewrap agree with
    // the picture.
    activePane()->session->setTextMeasurer(
        [](void*, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t,
            Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* cellAdvanceOut) {
            Ubiquitty::Rendering::GlyphRasterizer& rasterizer = currentRasterizer();
            if (cellAdvanceOut)
                *cellAdvanceOut = static_cast<float>(rasterizer.cellMetrics().cellWidth);
            return rasterizer.shapeProportionalRun(std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                static_cast<Ubiquitty::Rendering::FontFace>(faceBits),
                std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
        },
        nullptr);
    if (!arguments.feed.empty())
        Ubiquitty::processBytes(term, arguments.feed);
    if (arguments.reflowFromColumns > 0) {
        activePane()->session->resize(arguments.rows, arguments.columns, Ubiquitty::Runtime::TerminalSession::ResizeGesture::Settled, Ubiquitty::Modes::AnchorMode::Top);
        const Ubiquitty::IntSize resizedArea { cell.width * term->columns, cell.height * term->rows };
        Ubiquitty::publishPixelGeometry(*term, { cell, resizedArea, resizedArea });
    }
    // A snapshot has no program to read what the terminal answered, so the
    // replies are printed for a case's stdout contract.
    if (const std::string replies = Ubiquitty::Diagnostics::drainRepliesForReport(*term); !replies.empty())
        Ubiquitty::PAL::logLine(stdout, "snapshot: replies {}", replies);
    // Through the find bar's own entry point rather than ScrollSearch directly,
    // so the snapshot renders what Ctrl+F produces — including the reveal that
    // moves the viewport onto the match.
    // The clear gestures, through the Core entries the macOS driver calls.
    if (arguments.shouldClearToMark)
        (void)Ubiquitty::Screen::clearToMarkOrFull(term);
    else if (arguments.shouldClearPreservingInput)
        Ubiquitty::clearBufferPreserveInput(term);
    if (arguments.selection)
        activePane()->selection.state = Ubiquitty::Selection::characterSelectionOverVisibleRows(*term, *arguments.selection);
    if (arguments.selectionPoints) {
        const std::array<double, 4>& points = *arguments.selectionPoints;
        Ubiquitty::Selection::selectBetweenPoints(activePane()->selection, *term, points[0], points[1], points[2], points[3]);
    }
    int viewOffset = arguments.viewOffset;
    if (arguments.searchLiteral) {
        activePane()->viewOffset = arguments.viewOffset;
        const auto status = runSearchAndWait(activePane()->session, arguments.searchLiteral, Ubiquitty::Runtime::TerminalSession::SearchPatternForm::Literal);
        if (!status.isComplete || status.isPatternInvalid)
            return 1;
        viewOffset = activePane()->viewOffset;
    }
    // The window's focus is the one fact a headless frame has to be told: the
    // shape is the program's request as Core resolves it at tick 0, and the
    // look an unfocused cursor takes is the builder's decision.
    Ubiquitty::Linux::CursorOverlay cursor;
    cursor.visible = term->modes.isCursorVisible != 0;
    cursor.shape = Ubiquitty::Cursor::resolve(term, 0).shape;
    cursor.focused = !arguments.isUnfocused;
    const int status = writePNG(arguments.outputPath, &cursor, viewOffset, &activePane()->selection);
    if (status == 0) {
        // The snapshot draws through the CPU rasteriser, not the Vulkan
        // pipeline the live frontend uses, so the arm names what it actually
        // ran: a reader comparing this arm against macOS is comparing two
        // compositors, and against portable is comparing one.
        Ubiquitty::PAL::logLine(stdout, "{}",
            Ubiquitty::Rendering::renderPathMarkerLine(Ubiquitty::Rendering::CellBuilder::Core,
                Ubiquitty::Rendering::FrameCompositor::Software,
                Ubiquitty::Rendering::FrameEncoder::Native));
    }
    return status;
}

int smokePixelGeometry()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-pixel-geometry: GTK needs a display\n");
        return 1;
    }
    constexpr std::string_view configuration = "[font]\nfamily = \"GNU Unifont\"\nsize = 10\nline_spacing = 0\n"
                                               "[appearance]\npadding_left = 3\npadding_right = 5\npadding_top = 7\npadding_bottom = 11\n";
    if (!Ubiquitty::Preferences::configure(std::string(configuration), Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
        g_printerr("smoke-pixel-geometry: configuration failed\n");
        return 1;
    }
    setupFonts();
    LinuxPane& pane = *activePane();
    pane.session->start(3, 5);
    pane.rows = 3;
    pane.columns = 5;
    Ubiquitty::Terminal* terminal = pane.session->terminal();
    if (!terminal) {
        g_printerr("smoke-pixel-geometry: no terminal\n");
        return 1;
    }
    pane.picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
    int failures = 0;
    const auto check = [&](bool condition, const char* message) {
        if (!condition) {
            g_printerr("smoke-pixel-geometry: %s\n", message);
            ++failures;
        }
    };
    const auto checkReply = [&](std::string_view query, std::string_view expected) {
        Ubiquitty::processBytes(terminal, query);
        std::array<char, 128> reply;
        const int length = Ubiquitty::drainOutput(terminal, reply);
        check(std::string_view(reply.data(), static_cast<std::size_t>(length)) == expected, "pixel size report differs");
    };
    applyPanePadding(pane);
    checkReply("\033[16t\033[14t\033[?7402h\033[14t", "\033[6;16;8t\033[4;48;40t\033[4;66;48t");

    gtk_widget_allocate(pane.picture, 64, 80, -1, nullptr);
    check(publishPanePixelGeometry(pane), "allocated drawable was not published");
    checkReply("\033[14t", "\033[4;80;64t");
    check(!publishPanePixelGeometry(pane), "unchanged geometry was published again");

    gtk_widget_allocate(pane.picture, 65, 81, -1, nullptr);
    check(publishPanePixelGeometry(pane), "sub-cell drawable resize was not published");
    check(terminal->columns == 5 && terminal->rows == 3, "drawable resize changed the grid");
    checkReply("\033[14t", "\033[4;81;65t");

    pane.rows = 4;
    pane.columns = 6;
    check(publishPanePixelGeometry(pane), "grid resize was not published");
    checkReply("\033[?7402l\033[14t", "\033[4;64;48t");

    app().scale = 2;
    app().rasterContext.setDeviceScale(2);
    rebuildFontsFromPreferences();
    check(!publishPanePixelGeometry(pane), "font rebuild did not publish geometry");
    // The window size a program reads follows mode 7402: the text area while
    // it is reset, the drawable while it is set. Turning it on owes the PTY a
    // new winsize, which the next publication delivers.
    checkReply("\033[16t\033[14t\033[?7402h\033[14t", "\033[6;32;16t\033[4;128;96t\033[4;162;130t");
    check(publishPanePixelGeometry(pane), "a fullscreen-content toggle did not republish the reported size");

    constexpr std::string_view changedPadding = "[font]\nfamily = \"GNU Unifont\"\nsize = 10\nline_spacing = 0\n"
                                                "[appearance]\npadding_left = 4\npadding_right = 6\npadding_top = 8\npadding_bottom = 12\n";
    check(Ubiquitty::Preferences::configure(std::string(changedPadding), Ubiquitty::Preferences::ParseMode::Strict).isApplied, "padding configuration failed");
    check(gtk_widget_get_margin_start(pane.picture) == 4 && gtk_widget_get_margin_end(pane.picture) == 6
            && gtk_widget_get_margin_top(pane.picture) == 8 && gtk_widget_get_margin_bottom(pane.picture) == 12,
        "live padding change did not reach the picture");
    check(!publishPanePixelGeometry(pane), "live padding change did not publish geometry");
    int pixelX = 0;
    int pixelY = 0;
    Ubiquitty::processBytes(terminal, "\033[?7402l");
    devicePixelAtPoint(10000, 10000, pixelX, pixelY);
    check(pixelX == 96 && pixelY == 128, "pixel mouse coordinates exceed the published grid");

    app().scale = 1;
    app().rasterContext.setDeviceScale(1);
    rebuildFontsFromPreferences();
    Ubiquitty::processBytes(terminal, "\033[?25l");
    app().window = gtk_window_new();
    app().paneContainer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(pane.picture, TRUE);
    gtk_widget_set_vexpand(pane.picture, TRUE);
    gtk_picture_set_content_fit(GTK_PICTURE(pane.picture), GTK_CONTENT_FIT_FILL);
    gtk_box_append(GTK_BOX(app().paneContainer), pane.picture);
    gtk_window_set_child(GTK_WINDOW(app().window), app().paneContainer);
    g_signal_connect(app().window, "realize", G_CALLBACK(onWindowRealized), nullptr);
    gtk_window_set_default_size(GTK_WINDOW(app().window), 160, 120);
    const auto waitUntil = [](const auto& predicate) {
        const gint64 deadline = g_get_monotonic_time() + 5000000;
        while (!predicate() && g_get_monotonic_time() < deadline) {
            while (g_main_context_iteration(nullptr, FALSE)) {
            }
            g_usleep(1000);
        }
        return predicate();
    };
    const int initialWidth = terminal->drawablePixelWidth;
    gtk_window_present(GTK_WINDOW(app().window));
    check(waitUntil([&] {
        return gtk_widget_get_mapped(app().window) && terminal->drawablePixelWidth != initialWidth && app().tickCallbackID == 0;
    }),
        "initial window layout did not publish and return to idle");
    const int idleColumns = terminal->columns;
    const int idleRows = terminal->rows;
    gtk_window_set_default_size(GTK_WINDOW(app().window), 240, 184);
    check(waitUntil([&] {
        return terminal->columns > idleColumns && terminal->rows > idleRows && app().tickCallbackID == 0;
    }),
        "native resize did not wake the idle clock, publish, and return to idle");
    check(!app().frameDriver.active(), "resize left the frame clock running");
    gtk_window_destroy(GTK_WINDOW(app().window));
    app().window = nullptr;
    app().paneContainer = nullptr;

    if (pane.session->launchShellCommand("while IFS= read -r line; do :; done")) {
        app().scale = 2;
        app().fontSizePoints = 96;
        app().rasterContext.setDeviceScale(2);
        rebuildFontsFromPreferences();
        const int cellWidth = static_cast<int>(std::lround(logicalCellWidth()));
        const int cellHeight = static_cast<int>(std::lround(logicalCellHeight()));
        pane.columns = 1023;
        pane.rows = 2;
        pane.session->resizeGrid(2, 1023, Ubiquitty::Modes::ReflowMode::Fixed);
        gtk_widget_allocate(pane.picture, 1023 * cellWidth + 10, 2 * cellHeight + 20, -1, nullptr);
        publishPanePixelGeometry(pane);
        check(terminal->textAreaPixelWidth == 65535 && terminal->drawablePixelWidth == 65535, "wide grid did not saturate");
        const std::uint64_t deliveries = pane.session->windowSizeDeliveryCount();
        gtk_widget_allocate(pane.picture, 1024 * cellWidth + 10, 2 * cellHeight + 20, -1, nullptr);
        // A held frame exercises resize delivery without allocating a texture
        // for a nearly hundred-thousand-pixel-wide test grid.
        Ubiquitty::processBytes(terminal, "\033[?2026h");
        onTick(nullptr, nullptr, nullptr);
        struct winsize windowSize {};
        check(::ioctl(pane.session->fileDescriptor(), TIOCGWINSZ, &windowSize) == 0
                && windowSize.ws_col == 1024 && windowSize.ws_row == 2 && windowSize.ws_xpixel == 65535,
            "unchanged saturated pixels suppressed the PTY grid resize");
        check(pane.session->windowSizeDeliveryCount() == deliveries + 1, "grid resize was not delivered exactly once");
        pane.session->close();
    } else {
        check(false, "could not open the grid-resize test PTY");
    }
    g_object_unref(pane.picture);
    pane.picture = nullptr;
    g_print("smoke-pixel-geometry: %s (%d failures)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}

// Both halves of the configuration land: the process-wide settings and the
// per-terminal ones. A terminal seeded from a document asking for a wide
// ambiguous width, NFC search, dropped invalid UTF-8 and a named built-in
// theme reads all four back.
int smokeConfigurationWiring()
{
    const Ubiquitty::Themes::Theme* theme = Ubiquitty::Themes::builtInGet(0);
    if (!theme) {
        g_printerr("smoke-config-wiring: no built-in theme\n");
        return 1;
    }
    Ubiquitty::Preferences::Values document;
    document.ambiguousWidth = 2;
    document.normalization = "nfc";
    document.invalidUTF8 = "drop";
    document.themeName = theme->name;

    Ubiquitty::Runtime::TerminalRuntime runtime;
    runtime.init(Ubiquitty::Runtime::RuntimeInitParameters { startupRows, startupColumns, false });
    Ubiquitty::Terminal* term = runtime.borrowTermForRender();
    if (!term) {
        g_printerr("smoke-config-wiring: no term\n");
        return 1;
    }
    applyProcessConfiguration(document);
    (void)Ubiquitty::Runtime::seedTerminalConfiguration(*term, document);

    const auto sameChannel = [](auto terminalChannel, auto themeChannel) { return terminalChannel == Ubiquitty::channel8To16(themeChannel); };
    const bool isAmbiguousWidthApplied = term->ambiguousWidth == Ubiquitty::Unicode::Width::AmbiguousWidth::Wide;
    const bool isNormalizationNFC = Ubiquitty::Screen::ScrollSearch::normalizationForm() == Ubiquitty::Unicode::NormalizationForm::NFC;
    const bool invalidUTF8Matches = Ubiquitty::Modes::invalidUTF8Policy(term) == Ubiquitty::Unicode::InvalidUTF8Policy::Drop;
    const bool themeMatches = sameChannel(term->palette.defaultBackground.red, theme->defaultBackground.red)
        && sameChannel(term->palette.defaultBackground.green, theme->defaultBackground.green)
        && sameChannel(term->palette.defaultBackground.blue, theme->defaultBackground.blue)
        && sameChannel(term->palette.indexed[0].red, theme->ansi[0].red);
    const bool isWired = isAmbiguousWidthApplied && isNormalizationNFC && invalidUTF8Matches && themeMatches;

    // Back to the defaults, so the process the smoke ran in is left as found.
    applyProcessConfiguration(Ubiquitty::Preferences::Values {});
    g_print("smoke-config-wiring: width=%d normalization=%d invalid-utf8=%d theme=%d -- %s\n",
        static_cast<int>(isAmbiguousWidthApplied), static_cast<int>(isNormalizationNFC), static_cast<int>(invalidUTF8Matches), static_cast<int>(themeMatches), isWired ? "PASS" : "FAIL");
    return isWired ? 0 : 1;
}

// A document saved with an error is said in the window, not only on standard
// error. The bar under the panes names the line through the same subscription
// a live reload reaches; a dismissed line stays quiet while the document
// repeats it, another line is heard, and a document that applies whole
// withdraws it. The setting on the refused line keeps the value it had.
int smokeConfigurationError()
{
    if (!gtk_init_check()) {
        g_printerr("smoke-config-error: GTK needs a display\n");
        return 1;
    }
    int failures = 0;
    const auto check = [&](bool isMet, const char* message) {
        if (!isMet) {
            g_printerr("smoke-config-error: FAIL %s\n", message);
            ++failures;
        }
    };
    const auto save = [](const char* document) {
        (void)Ubiquitty::Preferences::configure(std::string(document), Ubiquitty::Preferences::ParseMode::Permissive);
    };
    const auto isBarShown = [] { return gtk_action_bar_get_revealed(GTK_ACTION_BAR(app().configurationBar)) != FALSE; };
    const auto shownLine = [] { return std::string(gtk_label_get_text(GTK_LABEL(app().configurationLabel))); };

    // The startup order: a configure before the bar exists leaves the line,
    // and the bar shows it when it is built.
    save("[font]\nsize = 15\n");
    save("[font]\nsize = \"large\"\n");
    GtkWidget* bar = GTK_WIDGET(g_object_ref_sink(makeConfigurationBar()));
    const std::string wrongKind = "config.toml line 2: font.size takes a number \xE2\x80\x94 ignored";
    check(isBarShown(), "a line refused before the window existed is not shown when the bar is built");
    check(shownLine() == wrongKind, "the bar does not name the refused line");
    check(Ubiquitty::Preferences::Effective::fontSize(Ubiquitty::Preferences::values()) == 15.0, "the refused line did not keep the size it had");

    onConfigurationBarDismissed(nullptr, nullptr);
    check(!isBarShown(), "a dismissed line is still shown");
    save("[font]\nsize = \"large\"\n");
    check(!isBarShown(), "a dismissed line came back when the same document was saved again");

    save("[font]\nsize = 16\n[cursor]\nblink = \"yes\"\n");
    check(isBarShown(), "a different refused line is not shown after another was dismissed");
    check(shownLine() == "config.toml line 4: cursor.blink takes true or false \xE2\x80\x94 ignored", "the bar does not name the new line");

    save("[font]\nsize = 16\n");
    check(!isBarShown(), "a document that applied whole left the bar shown");
    check(shownLine().empty(), "a document that applied whole left the line in the bar");

    // Back to the defaults, so the process the smoke ran in is left as found.
    save("");
    g_object_unref(bar);
    app().configurationBar = nullptr;
    app().configurationLabel = nullptr;
    g_print("smoke-config-error: %s (%d failures)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv)
{
    // Install the process-wide platform-service context before anything
    // runs. This frontend supplies only the required monotonic clock; the image
    // decoder / DECPS synth / selection-color hooks stay absent (optional no-ops).
    Ubiquitty::PAL::Context palContext;
    palContext.monotonicClock = &Ubiquitty::PAL::monotonicTicks;
    Ubiquitty::PAL::installContext(palContext);
    // `-e cmd args…` / `-- cmd args…`, split by the same Core parser macOS
    // reads, so the two frontends divide a command line identically rather than
    // each deciding what counts as the terminal's own argument. Every scanner
    // below reads terminalArgc and not argc: reading argc parses the CHILD's
    // flags as this terminal's, and `-e env --title=x` would set a title nobody
    // asked for.
    const Ubiquitty::Runtime::LaunchRequest launchRequest = Ubiquitty::Runtime::parseLaunchArguments(argc, argv);
    if (launchRequest.status == Ubiquitty::Runtime::LaunchRequest::Status::Error) {
        Ubiquitty::PAL::logLine(stderr, "ubiquitty-linux: {}", launchRequest.error);
        return 2;
    }
    const int terminalArgc = launchRequest.terminalArgumentCount;
    app().launchRequest = &launchRequest;

    std::string_view mode = (terminalArgc > 1) ? std::string_view(argv[1]) : std::string_view {};
    const char* arg2 = (terminalArgc > 2) ? argv[2] : nullptr;

    // Every configure reaches the window, or the headless pane a mode drives,
    // through this one subscription.
    app().configurationSubscription.emplace(Ubiquitty::Preferences::ConfigurationSubscription::notifying(applyLiveConfiguration));

    // `--config <path> <mode> [arg]` names the configuration the mode runs
    // under, so a headless render is reproducible without writing to the user's
    // own file. The file's document replaces the machine's wholesale, Strict, so
    // a misspelt key fails the run rather than rendering without it.
    int cursor = 1;
    while (cursor < terminalArgc) {
        const std::string_view option(argv[cursor]);
        if (option == "--config") {
            if (cursor + 1 >= terminalArgc) {
                g_printerr("--config needs a path\n");
                return 2;
            }
            const Ubiquitty::Preferences::ConfigureResult configured
                = Ubiquitty::Preferences::configureFromFile(argv[cursor + 1], Ubiquitty::Preferences::ParseMode::Strict);
            if (!configured.isApplied) {
                g_printerr("--config: %s is not a configuration this build applies whole\n", argv[cursor + 1]);
                return 2;
            }
            cursor += 2;
            continue;
        }
        break;
    }
    mode = (cursor < terminalArgc) ? std::string_view(argv[cursor]) : std::string_view {};
    arg2 = (cursor + 1 < terminalArgc) ? argv[cursor + 1] : nullptr;
    // Create the lone passive pane up front so a headless --smoke-* / --dump-*
    // path that reaches activePane()->session directly has a valid focused
    // pane. The tab and split smokes are the exception: they open their
    // window through the model like the GUI, and a pre-made pane would
    // double-count in the registries they assert over.
    if (mode != "--smoke-tabs" && mode != "--smoke-splits")
        ensureDefaultPane();
    if (mode == "--snapshot")
        return runSnapshot(argc, argv);
    if (mode == "--version") {
        g_print("ubiquitty-linux %s\n", Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str());
        return 0;
    }
    if (mode == "--check-update") {
        // Headless seam for the AppImage self-update — same path as the in-gtkApplication
        // menu action. Exit: 0 up-to-date / N-A, 1 update available, 2 error.
        using S = Ubiquitty::Linux::Updater::Status;
        const S status = Ubiquitty::Linux::Updater::check();
        g_print("%s\n", Ubiquitty::Linux::Updater::statusString(status));
        if (status == S::UpdateAvailable)
            return 1;
        return (status == S::UpToDate || status == S::NotAnAppImage) ? 0 : 2;
    }
    if (mode == "--smoke")
        return smokeVulkanClear();
    if (mode == "--smoke-grid")
        return smokeGrid();
    if (mode == "--dump-png") {
        setupFonts(); // real-font CPU raster
        initTermCanned();
        return writePNG(arg2 != nullptr ? arg2 : "/tmp/ubiquitty-grid.png");
    }
    if (mode == "--dump-png-vk") {
        setupFonts(); // real-font GPU raster (injected in writePNGVulkan)
        initTermCanned();
        return writePNGVulkan(arg2 != nullptr ? arg2 : "/tmp/ubiquitty-grid-vk.png");
    }
    if (mode == "--selftest-font-toggle")
        return selftestFontToggle();
    if (mode == "--smoke-mouse")
        return smokeMouse();
    if (mode == "--smoke-title")
        return smokeTitle();
    if (mode == "--smoke-scrollback")
        return smokeScrollback();
    if (mode == "--smoke-selection")
        return smokeSelection();
    if (mode == "--smoke-scaled-run-selection")
        return smokeScaledRunSelection();
    if (mode == "--smoke-paste")
        return smokePaste();
    if (mode == "--smoke-osc52")
        return smokeOSC52();
    if (mode == "--smoke-osc7")
        return smokeOSC7();
    if (mode == "--smoke-capability-origin")
        return smokeCapabilityOrigin();
    if (mode == "--smoke-focus")
        return smokeFocus();
    if (mode == "--smoke-pointer-lock")
        return smokePointerLock();
    if (mode == "--smoke-link")
        return smokeLink();
    if (mode == "--smoke-ime")
        return smokeIME();
    if (mode == "--smoke-compose")
        return smokeCompose();
    if (mode == "--smoke-find")
        return smokeFind();
    if (mode == "--smoke-rectsel")
        return smokeRectSelection();
    if (mode == "--smoke-smartclick")
        return smokeSmartClick();
    if (mode == "--smoke-status-title")
        return smokeStatusTitle();
    if (mode == "--smoke-titlebuild")
        return smokeTitleBuild();
    if (mode == "--smoke-inspector")
        return smokeInspector();
    if (mode == "--smoke-buffer-growth") {
        setupFonts();
        return smokeBufferGrowth();
    }
    if (mode == "--smoke-image-stamp") {
        setupFonts();
        return smokeImageStamp();
    }
    if (mode == "--smoke-cursor-alpha")
        return smokeCursorAlpha();
    if (mode == "--smoke-rich-capture")
        return smokeRichCapture();
    if (mode == "--smoke-gtk-caret")
        return smokeGTKCaret();
    if (mode == "--smoke-cursor") {
        setupFonts();
        return smokeCursor();
    }
    if (mode == "--smoke-font-settings")
        return smokeFontSettings();
    if (mode == "--smoke-ligature-sheet")
        return smokeLigatureSheet();
    if (mode == "--smoke-proportional-strip")
        return smokeProportionalStrip();
    if (mode == "--smoke-proportional-atlas")
        return smokeProportionalAtlas();
    if (mode == "--smoke-doubled-run")
        return smokeDoubledRun();
    if (mode == "--smoke-script-glyphs")
        return smokeScriptGlyphs();
    if (mode == "--smoke-fileread")
        return smokeFileRead();
    if (mode == "--smoke-trigger")
        return smokeTrigger();
    if (mode == "--smoke-ligature-shaping")
        return smokeLigatureShaping();
    if (mode == "--smoke-ligature-render")
        return smokeLigatureRender();
    if (mode == "--smoke-gridcache")
        return smokeGridCache();
    if (mode == "--smoke-gridcache-stress")
        return smokeGridCacheStress();
    if (mode == "--bench-gridcache-scroll")
        return benchGridCacheScroll(argc > 2 ? std::max(std::atoi(argv[2]), 1) : 600);
    if (mode == "--smoke-nf")
        return smokeNerdFont();
    if (mode == "--smoke-nf-render")
        return smokeNerdFontRender();
    if (mode == "--smoke-shade-gpu")
        return smokeShadeGPU();
    if (mode == "--smoke-sized-gpu")
        return smokeSizedGPU();
    if (mode == "--smoke-softfont")
        return smokeSoftFont();
    if (mode == "--smoke-keypad")
        return smokeKeypad();
    if (mode == "--smoke-drop")
        return smokeDrop();
    if (mode == "--smoke-image")
        return smokeImage();
    if (mode == "--smoke-image-vk")
        return smokeImageVulkan();
    if (mode == "--smoke-image-vk-filtered")
        return smokeImageVulkanFiltered();
    if (mode == "--smoke-image-vk-placeholders")
        return smokeImageVulkanPlaceholders();
    if (mode == "--smoke-image-vk-under-text")
        return smokeImageVulkanUnderText();
    if (mode == "--smoke-weight")
        return smokeWeight();
    if (mode == "--smoke-opacity")
        return smokeOpacity();
    if (mode == "--smoke-background-image")
        return smokeBackgroundImage();
    if (mode == "--smoke-beam")
        return smokeBeam();
    if (mode == "--smoke-tabs")
        return smokeTabs();
    if (mode == "--smoke-window-chrome")
        return smokeWindowChrome(arg2);
    if (mode == "--smoke-splits")
        return smokeSplits();
    if (mode == "--smoke-pacing")
        return smokePacing();
    if (mode == "--smoke-atlas-capacity")
        return smokeAtlasCapacity();
    if (mode == "--smoke-coverage-sheet")
        return smokeCoverageSheet();
    if (mode == "--smoke-readback-memory")
        return smokeReadbackMemory();
    if (mode == "--smoke-dmabuf-import-failure")
        return smokeDmabufImportFailure();
    if (mode == "--smoke-oversized-grid")
        return smokeOversizedGrid();
    if (mode == "--smoke-clear")
        return smokeClear();
    if (mode == "--smoke-font-zoom")
        return smokeFontZoom();
    if (mode == "--smoke-prompt-navigation")
        return smokePromptNavigation();
    if (mode == "--smoke-select-all")
        return smokeSelectAll();
    if (mode == "--dump-png-live")
        return dumpPNGLive(arg2 != nullptr ? arg2 : "/tmp/ubiquitty-live.png");
    if (mode == "--smoke-input")
        return smokeInput(arg2 != nullptr ? arg2 : "/tmp/ubiquitty-input.png");
    if (mode == "--print-config")
        return printConfig(arg2);
    if (mode == "--smoke-config-wiring")
        return smokeConfigurationWiring();
    if (mode == "--smoke-config-error")
        return smokeConfigurationError();
    if (mode == "--smoke-pixel-geometry") {
        return smokePixelGeometry();
    }

    GtkApplication* gtkApplication = gtk_application_new("org.ubiquitty.linux", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(gtkApplication, "activate", G_CALLBACK(onActivate), nullptr);
    // GTK is handed terminalArgc, not argc: GApplication parses the command line
    // itself and rejects anything it does not recognise, so the child's own
    // options reach it as unknown ones and `-e sh -c …` exits before a pane is
    // ever created. What follows the marker was never this terminal's to parse.
    const int status = g_application_run(G_APPLICATION(gtkApplication), terminalArgc, argv);
    app().configurationWatcher.stop();
    if (app().isVulkanReady)
        app().vulkan.shutdown();
    g_object_unref(gtkApplication);
    return status;
}
