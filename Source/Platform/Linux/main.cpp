// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GTK4 entry for the Linux frontend. A login shell runs on a PTY (Core runs
// locally); its master fd is polled by the GLib main loop, host bytes drain into
// Core via TerminalSession::drain, the grid repaints on the widget frame
// clock, and key events are encoded by the portable Keymap and written to the PTY.
// The grid is CPU-rasterized (Unifont) as a GdkMemoryTexture; the Vulkan path
// swaps the raster for a GPU grid.
//
// GUI panes use TerminalSession's ingest thread, as the macOS drive does.
// GTK presents owned boundary captures and locks the model for live reads and
// input integration. Headless smokes drain inline.
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
#include "Core/Themes/ThemeApply.h"
#include "Core/Title/ProcessIcons.h"
#include "Platform/Linux/AccessibleTerminal.h"
#include "Platform/Linux/BitmapFace.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/CapabilityPolicy.h"
#include "Platform/Linux/Clipboard.h"
#include "Platform/Linux/ConfigurationWatcher.h"
#include "Platform/Linux/FontRouting.h"
#include "Platform/Linux/FontSizing.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/GTK/Alerts.h"
#include "Platform/Linux/GTK/ApplicationIcon.h"
#include "Platform/Linux/GTK/DesktopIntegrationHook.h"
#include "Platform/Linux/GTK/WindowAppearance.h"
#include "Platform/Linux/GTK/WindowChrome.h"
#include "Platform/Linux/Input/LinkInteraction.h"
#include "Platform/Linux/Input/LinkTarget.h"
#include "Platform/Linux/OmarchyAccent.h"
#include "Platform/Linux/PTYWatch.h"
#include "Platform/Linux/PaneViewport.h"
#include "Platform/Linux/PangoRichText.h"
#include "Platform/Linux/PointerLock.h"
#include "Platform/Linux/Presentation/ChromeContent.h"
#include "Platform/Linux/Presentation/PaneGeometry.h"
#include "Platform/Linux/Presentation/SelectionColor.h"
#include "Platform/Linux/Presentation/StatusSymbol.h"
#include "Platform/Linux/Presentation/WindowTitleContent.h"
#include "Platform/Linux/Raster.h"
#include "Platform/Linux/SharedFontResources.h"
#include "Platform/Linux/Smokes/PaddingSmoke.h"
#include "Platform/Linux/Smokes/SkipInkSmoke.h"
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
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <expected>
#include <filesystem>
#include <format>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <thread>
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

#include <adwaita.h>
#include <gdk/gdkkeysyms.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

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

struct App;

struct LinuxPane : Ubiquitty::CanMakeWeakPtr {
    Ubiquitty::Rendering::FrameHoverLink hoveredLink;
    std::uint64_t hoverModelGeneration = 0;
    int hoverViewOffset = -1;
    GdkModifierType hoverModifiers = static_cast<GdkModifierType>(0);
    Ubiquitty::MousePointerShape hoverCursorShape = Ubiquitty::MousePointerShape::Default;
    App* ownerApp = nullptr;
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
    struct FrameRelease {
        void operator()(Ubiquitty::Rendering::FrameCapture* frame) const { ::releaseFrameCapture(frame); }
    };
    std::unique_ptr<Ubiquitty::Rendering::FrameCapture, FrameRelease> pendingCapture;
    std::vector<Ubiquitty::Rendering::SelectionRowSpan> capturedSelectionSpans;
    int capturedSelectionSpanCount = 0;
    std::optional<Ubiquitty::Rendering::RenderConfiguration> captureConfiguration;
    int captureCellWidth = 0;
    int captureCellHeight = 0;
    Ubiquitty::FloatPoint captureRasterOrigin;
    Ubiquitty::FloatSize captureRasterSize;
    int captureViewOffset = -1;
    Ubiquitty::Screen::HistoryFacts captureViewHistory;
    bool isCaptureViewOffsetHeld = false;
    bool isCaptureFocused = true;
    // The selection colour the registered capture geometry carries.
    Ubiquitty::Rendering::Vec4 captureSelectionColor {};
    bool isFrameDeclined = false;
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
    double pointerX = 0;
    double pointerY = 0;
    bool isPointerPositionKnown = false;
    std::uint64_t searchRevealGeneration = 0;
    std::uint32_t searchRevealEpoch = 0;
    // Portable mouse text selection through Core's Terminal-bound facade —
    // the same Session the macOS surface owns, so gesture sequencing, word
    // and line growth, wide bounds and the copy walk are answered once.
    Ubiquitty::Selection::Session selection;
    float lastCursorBlinkAlpha = 1.0f; // last painted blink phase (onTick repaint gate)
    Ubiquitty::Rendering::CursorPresentation cursorPresentation;
    double cursorPresentationBypassUntil = 0;
    std::uint32_t lastScrollIndicatorTick = 0;
    Ubiquitty::Linux::Presentation::PaneGeometry presentation;
    // The picture's last laid-out size, in device pixels. An unmounted picture
    // (a background tab's) reports none, and a frame drawn for it then must
    // still be drawn at the size it will be shown at.
    Ubiquitty::FloatSize lastViewport {};
    // The layout belongs to the frame this pane presents, not the renderer's
    // last pane. Row vectors retain capacity and only shaped rows hold extents.
    std::vector<std::vector<Ubiquitty::Rendering::LetterExtent>> presentedLetters;
    Ubiquitty::GridSize presentedGridSize {};
    Ubiquitty::FloatSize presentedCellPixels {};

    [[nodiscard]] std::span<const Ubiquitty::Rendering::LetterExtent> presentedRowLetters(int row) const
    {
        return row >= 0 && row < static_cast<int>(presentedLetters.size())
            ? std::span<const Ubiquitty::Rendering::LetterExtent>(presentedLetters[static_cast<std::size_t>(row)])
            : std::span<const Ubiquitty::Rendering::LetterExtent> {};
    }
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

// A write hold on a pane's model, for a path that feeds or edits the Terminal
// directly instead of through the session: the parser calls back into the
// session's trigger, notification and window-request queues under the model
// lock, and a Debug build asserts that. The release publishes what was written.
class PaneModelWrite {
public:
    explicit PaneModelWrite(Ubiquitty::Runtime::TerminalSession& session) UBIQUITTY_NO_THREAD_SAFETY_ANALYSIS
        : m_session(session)
    {
        m_session.lockForWrite();
    }
    ~PaneModelWrite() UBIQUITTY_NO_THREAD_SAFETY_ANALYSIS { m_session.unlockAfterWrite(); }
    PaneModelWrite(const PaneModelWrite&) = delete;
    PaneModelWrite& operator=(const PaneModelWrite&) = delete;

private:
    Ubiquitty::Runtime::TerminalSession& m_session;
};

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

struct App : PaneReferents, std::enable_shared_from_this<App> {
    std::atomic<bool> isClosing { false };
    std::mutex sourcesLock;
    std::set<GSource*> sources;
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
    Ubiquitty::Linux::GTK::WindowAppearance windowAppearance;
    std::optional<std::uint32_t> omarchyAccent;
    GtkWidget* paneContainer = nullptr; // holds the active tab's pane widget tree (one leaf, or GtkPaned)
    // The header bar and tab bar; absent in a chromeless build.
    std::unique_ptr<Ubiquitty::Linux::GTK::WindowChrome> chrome;
    // The terminal's context menu, parented to the window; unparented with it.
    GtkWidget* contextMenu = nullptr;
    // Set once the reader has agreed to end what the window runs, so the
    // close that answer starts is not asked about again.
    bool isCloseConfirmed = false;
    GtkWidget* scrollIndicator = nullptr;
    guint scrollIndicatorSource = 0;
    GtkWidget* progressBar = nullptr; // GtkDrawingArea, can't-target so input passes through
    GtkWidget* searchBar = nullptr;
    GtkWidget* searchEntry = nullptr;
    GtkWidget* searchLabel = nullptr; // "k of n" match counter
    GtkWidget* inspectorWindow = nullptr;
    GtkWidget* inspectorLabel = nullptr;
    GtkWidget* accessibleTerminal = nullptr;
    GtkIMContext* imContext = nullptr; // input method (dead keys / compose / CJK)
    bool hasInputMethodPreedit = false;
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
    std::shared_ptr<Ubiquitty::Linux::SharedFontResources> sharedFonts;
    std::shared_ptr<Ubiquitty::Linux::FreeTypeRasterizer> glyphRasterizer;
    // The bitmap font and the toggle target. Optional so it can be built with the
    // configured line spacing once that is known: default-constructed it carries
    // none, and switching to it would change the row height under the user.
    std::optional<Ubiquitty::Rendering::UnifontRasterizer> unifontRasterizer;
    bool areFontsSetUp = false;
    Ubiquitty::Rendering::FontRasterizerKind fontRasterizerKind = Ubiquitty::Rendering::FontRasterizerKind::Native;
    int fontPixelSize = 16; // live FreeType pixel size (zoomed at runtime); seeded in setupFonts
    // The configured size in POINTS, which is what `[font] size` is written in
    // and what the double-valued field holds. Kept beside the integer above
    // rather than replacing it, because the zoom steps name whole sizes;
    // this is what the rasterizer is sized from.
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
    bool isLinkPressClaimed = false;
    Ubiquitty::MousePointerShape hoverCursorShape = Ubiquitty::MousePointerShape::Default;
    // Where the pointer last hovered with nothing reporting it, so a modifier
    // key, which moves no pointer, can re-ask what the hand shows there.
    double hoverX = 0;
    double hoverY = 0;
    bool isHoverPointKnown = false;
    GdkModifierType hoverModifiers = static_cast<GdkModifierType>(0);

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
    std::optional<std::string> configuredThemeName;
    std::string liveThemeName;
    std::string appliedThemePalette;
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
    // The invocation this window owns, and whether a pane has taken its
    // command. The first pane runs it; a new tab or split is the user asking
    // for another shell, and re-running the
    // child there is behaviour a `-e` script cannot undo.
    std::optional<Ubiquitty::Runtime::LaunchRequest> launchRequest;
    std::string windowApplicationID;
    std::string launchDirectory;
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

// GTK dispatch and worker posts carry the window they belong to. Nesting a
// callback from another window temporarily changes that context, then restores it.
struct WindowApps {
    std::shared_ptr<App> headless;
    std::vector<std::shared_ptr<App>> windows;
};

WindowApps& windowApps()
{
    static WindowApps instances;
    return instances;
}

App*& currentWindowApp()
{
    static thread_local App* current = nullptr;
    return current;
}

class AppScope {
public:
    explicit AppScope(App& owner)
        : m_owner(owner.shared_from_this())
        , m_previous(currentWindowApp())
    {
        currentWindowApp() = &owner;
    }
    ~AppScope() { currentWindowApp() = m_previous; }
    AppScope(const AppScope&) = delete;
    AppScope& operator=(const AppScope&) = delete;

private:
    std::shared_ptr<App> m_owner;
    App* m_previous;
};

App& defaultApp()
{
    auto& owner = windowApps().headless;
    if (!owner)
        owner = std::make_shared<App>();
    return *owner;
}

App& app()
{
    return currentWindowApp() ? *currentWindowApp() : defaultApp();
}

App& createWindowApp()
{
    auto instance = std::make_shared<App>();
    App& result = *instance;
    windowApps().windows.push_back(std::move(instance));
    return result;
}

App* appForWindow(GtkWindow* window)
{
    return static_cast<App*>(g_object_get_data(G_OBJECT(window), "ubiquitty-window-state"));
}

struct WindowSourceCallback {
    std::shared_ptr<App> owner;
    GSource* source;
    GSourceFunc callback;
    gpointer data;
    GDestroyNotify destroy;
};

gboolean dispatchWindowSource(gpointer data)
{
    auto& call = *static_cast<WindowSourceCallback*>(data);
    AppScope scope(*call.owner);
    return call.owner->isClosing ? G_SOURCE_REMOVE : call.callback(call.data);
}

void destroyWindowSource(gpointer data)
{
    std::unique_ptr<WindowSourceCallback> call(static_cast<WindowSourceCallback*>(data));
    AppScope scope(*call->owner);
    if (call->destroy)
        call->destroy(call->data);
    {
        const std::scoped_lock lock(call->owner->sourcesLock);
        call->owner->sources.erase(call->source);
    }
    g_source_unref(call->source);
}

guint attachWindowSource(GSource* source, GSourceFunc callback, gpointer data, GDestroyNotify destroy)
{
    auto call = std::make_unique<WindowSourceCallback>(WindowSourceCallback { app().shared_from_this(), source, callback, data, destroy });
    g_source_set_callback(source, dispatchWindowSource, call.release(), destroyWindowSource);
    {
        const std::scoped_lock lock(app().sourcesLock);
        app().sources.insert(source); // owns the source's initial reference
    }
    return g_source_attach(source, nullptr);
}

guint windowTimeoutAdd(guint milliseconds, GSourceFunc callback, gpointer data)
{
    return attachWindowSource(g_timeout_source_new(milliseconds), callback, data, nullptr);
}

guint windowIdleAddFull(gint priority, GSourceFunc callback, gpointer data, GDestroyNotify destroy)
{
    GSource* source = g_idle_source_new();
    g_source_set_priority(source, priority);
    return attachWindowSource(source, callback, data, destroy);
}

struct WindowFDCallback {
    GUnixFDSourceFunc callback;
    gpointer data;
};

gboolean dispatchWindowFD(gint descriptor, GIOCondition condition, gpointer data)
{
    auto& call = *static_cast<WindowSourceCallback*>(data);
    AppScope scope(*call.owner);
    auto& file = *static_cast<WindowFDCallback*>(call.data);
    return call.owner->isClosing ? G_SOURCE_REMOVE : file.callback(descriptor, condition, file.data);
}

guint windowUnixFDAdd(gint descriptor, GIOCondition condition, GUnixFDSourceFunc callback, gpointer data, gint priority = G_PRIORITY_DEFAULT)
{
    GSource* source = g_unix_fd_source_new(descriptor, condition);
    g_source_set_priority(source, priority);
    auto file = std::make_unique<WindowFDCallback>(WindowFDCallback { callback, data });
    auto call = std::make_unique<WindowSourceCallback>(WindowSourceCallback { app().shared_from_this(), source, nullptr, file.release(),
        +[](gpointer value) { delete static_cast<WindowFDCallback*>(value); } });
    g_source_set_callback(source, G_SOURCE_FUNC(dispatchWindowFD), call.release(), destroyWindowSource);
    {
        const std::scoped_lock lock(app().sourcesLock);
        app().sources.insert(source);
    }
    return g_source_attach(source, nullptr);
}

struct WindowChildCallback {
    GChildWatchFunc callback;
    gpointer data;
};

guint windowChildWatchAdd(GPid pid, GChildWatchFunc callback, gpointer data)
{
    GSource* source = g_child_watch_source_new(pid);
    auto child = std::make_unique<WindowChildCallback>(WindowChildCallback { callback, data });
    auto call = std::make_unique<WindowSourceCallback>(WindowSourceCallback { app().shared_from_this(), source, nullptr, child.release(),
        +[](gpointer value) { delete static_cast<WindowChildCallback*>(value); } });
    g_source_set_callback(source, G_SOURCE_FUNC(+[](GPid pid, gint status, gpointer value) {
        auto& call = *static_cast<WindowSourceCallback*>(value);
        AppScope scope(*call.owner);
        auto& child = *static_cast<WindowChildCallback*>(call.data);
        if (call.owner->isClosing)
            g_spawn_close_pid(pid);
        else
            child.callback(pid, status, child.data);
    }),
        call.release(), destroyWindowSource);
    // Reaping belongs to the process: closing its initiating window only
    // suppresses UI completion, not the watch which must collect the child.
    return g_source_attach(source, nullptr);
}

struct WindowTickCallback {
    std::shared_ptr<App> owner;
    GtkTickCallback callback;
    gpointer data;
    GDestroyNotify destroy;
};

guint windowTickAdd(GtkWidget* widget, GtkTickCallback callback, gpointer data, GDestroyNotify destroy)
{
    auto call = std::make_unique<WindowTickCallback>(WindowTickCallback { app().shared_from_this(), callback, data, destroy });
    return gtk_widget_add_tick_callback(widget, +[](GtkWidget* target, GdkFrameClock* clock, gpointer value) -> gboolean {
            auto& tick = *static_cast<WindowTickCallback*>(value);
            AppScope scope(*tick.owner);
            return tick.owner->isClosing ? G_SOURCE_REMOVE : tick.callback(target, clock, tick.data); }, call.release(), +[](gpointer value) {
            std::unique_ptr<WindowTickCallback> tick(static_cast<WindowTickCallback*>(value));
            if (tick->destroy)
                tick->destroy(tick->data); });
}

void cancelWindowSources(App& owner)
{
    std::vector<GSource*> pending;
    {
        const std::scoped_lock lock(owner.sourcesLock);
        for (GSource* source : owner.sources)
            pending.push_back(g_source_ref(source));
    }
    for (GSource* source : pending) {
        g_source_destroy(source);
        g_source_unref(source);
    }
}

// GTK closures retain their window context as well as their original user
// data. Background windows keep routing input and paint into their own model.
struct WindowSignalClosure {
    GCClosure closure;
    App* owner;
    bool allowsClosing;
};

enum class WindowSignalLifetime {
    OpenWindowOnly,
    IncludesClosing,
};

GClosure* makeWindowSignalClosure(GCallback callback, gpointer userData, GConnectFlags flags, WindowSignalLifetime lifetime = WindowSignalLifetime::OpenWindowOnly)
{
    auto* context = reinterpret_cast<WindowSignalClosure*>(g_closure_new_simple(sizeof(WindowSignalClosure), userData));
    context->owner = &app();
    context->allowsClosing = lifetime == WindowSignalLifetime::IncludesClosing;
    auto* retainedOwner = new std::shared_ptr<App>(app().shared_from_this());
    g_closure_add_finalize_notifier(&context->closure.closure, retainedOwner, +[](gpointer data, GClosure*) { delete static_cast<std::shared_ptr<App>*>(data); });
    context->closure.callback = reinterpret_cast<gpointer>(callback);
    context->closure.closure.derivative_flag = (flags & G_CONNECT_SWAPPED) != 0;
    g_closure_set_marshal(&context->closure.closure, +[](GClosure* closure, GValue* result, guint count, const GValue* parameters, gpointer hint, gpointer marshalData) {
            auto* context = reinterpret_cast<WindowSignalClosure*>(closure);
            AppScope scope(*context->owner);
            if (context->owner->isClosing && !context->allowsClosing)
                return;
            g_cclosure_marshal_generic(closure, result, count, parameters, hint, marshalData); });
    return &context->closure.closure;
}

gulong windowSignalConnect(gpointer instance, const gchar* signal, GCallback callback, gpointer userData)
{
    return g_signal_connect_closure(instance, signal, makeWindowSignalClosure(callback, userData, G_CONNECT_DEFAULT), FALSE);
}

gulong windowLifecycleSignalConnect(gpointer instance, const gchar* signal, GCallback callback, gpointer userData)
{
    return g_signal_connect_closure(instance, signal, makeWindowSignalClosure(callback, userData, G_CONNECT_DEFAULT, WindowSignalLifetime::IncludesClosing), FALSE);
}

gulong windowSignalConnectObject(gpointer instance, const gchar* signal, GCallback callback, gpointer object, GConnectFlags flags)
{
    GClosure* closure = makeWindowSignalClosure(callback, object, flags);
    g_object_watch_closure(G_OBJECT(object), closure);
    return g_signal_connect_closure(instance, signal, closure, (flags & G_CONNECT_AFTER) != 0);
}

struct WindowDrawContext {
    std::shared_ptr<App> owner;
    GtkDrawingAreaDrawFunc function;
    gpointer data;
    GDestroyNotify destroy;
};

void windowDrawingAreaSetDrawFunc(GtkDrawingArea* area, GtkDrawingAreaDrawFunc function, gpointer data, GDestroyNotify destroy)
{
    auto* context = new WindowDrawContext { app().shared_from_this(), function, data, destroy };
    gtk_drawing_area_set_draw_func(area, +[](GtkDrawingArea* area, cairo_t* cr, int width, int height, gpointer data) {
            auto& context = *static_cast<WindowDrawContext*>(data);
            AppScope scope(*context.owner);
            if (!context.owner->isClosing)
                context.function(area, cr, width, height, context.data); }, context, +[](gpointer data) {
            std::unique_ptr<WindowDrawContext> context(static_cast<WindowDrawContext*>(data));
            if (context->destroy)
                context->destroy(context->data); });
}

struct WindowAsyncContext {
    std::shared_ptr<App> owner;
    GAsyncReadyCallback function;
    gpointer data;
    GDestroyNotify discard;
};

void discardPendingClipboardRead(gpointer);

gpointer windowAsyncData(GAsyncReadyCallback function, gpointer data, GDestroyNotify discard = nullptr)
{
    return new WindowAsyncContext { app().shared_from_this(), function, data, discard };
}

void onWindowAsyncReady(GObject* source, GAsyncResult* result, gpointer data)
{
    std::unique_ptr<WindowAsyncContext> context(static_cast<WindowAsyncContext*>(data));
    AppScope scope(*context->owner);
    if (context->owner->isClosing) {
        if (context->discard)
            context->discard(context->data);
        return;
    }
    context->function(source, result, context->data);
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
Ubiquitty::Rendering::Vec4 paneSelectionColor(const Ubiquitty::Terminal& terminal, Ubiquitty::Linux::Presentation::SelectionFocus focus);
Ubiquitty::Linux::Presentation::SelectionFocus selectionFocus(bool isFocusedInActiveWindow); // bool-ok: converts the frame's one focus fact into the policy's enum
void installTabActions();
Ubiquitty::Linux::Presentation::PaneMarks paneMarks(LinuxPane& pane);
void updateWindowTitle();
const Ubiquitty::Preferences::Values& loadPreferences();
Ubiquitty::App::PaneTitleFacts paneTitleFacts(LinuxPane& pane, const Ubiquitty::Preferences::Effective::TitleComposition& composition);
Ubiquitty::App::TitleViewerFacts titleViewerFacts(std::string fallbackName);
void rebuildPaneTree();
void splitFocusedPaneUX(Panes::Orientation orientation);
void closeFocusedPaneUX();
void newWindow();
void pasteTextUX(std::string_view text);
void closeFocusedPaneNow();
void closeTabUX(TabID tab);
void confirmClose(Ubiquitty::Session::CloseScope scope, const std::vector<PaneID>& panes, std::function<void()> proceed);
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
void updateHoverCursor(double x, double y, GdkModifierType state);
void updatePaneHoverCursor(LinuxPane&, double x, double y, GdkModifierType state);
void publishHoveredLink(LinuxPane&, const Ubiquitty::Rendering::FrameHoverLink&);

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
        pane->ownerApp = &app();
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
        windowSignalConnectObject(surface, "notify::width", G_CALLBACK(onWindowSurfaceSizeChanged), window, G_CONNECT_DEFAULT);
        windowSignalConnectObject(surface, "notify::height", G_CALLBACK(onWindowSurfaceSizeChanged), window, G_CONNECT_DEFAULT);
    }
}

void preserveLaunchSize(GtkWindow* window, GtkWidget* picture)
{
    int minWidth = -1;
    int minHeight = -1;
    gtk_widget_get_size_request(picture, &minWidth, &minHeight);
    if (minWidth < 0 && minHeight < 0)
        return; // A remap keeps the size the user chose after launch.

    // Mapping can precede the first allocation. Measure while the grid pin
    // still contributes to the window's natural size, including its chrome and
    // margins, then preserve that size before the empty picture loses its pin.
    int width = 0;
    int height = 0;
    GtkWidget* widget = GTK_WIDGET(window);
    if (gtk_widget_get_request_mode(widget) == GTK_SIZE_REQUEST_WIDTH_FOR_HEIGHT) {
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, -1, nullptr, &height, nullptr, nullptr);
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, height, nullptr, &width, nullptr, nullptr);
    } else {
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nullptr, &width, nullptr, nullptr);
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, width, nullptr, &height, nullptr, nullptr);
    }
    if (width <= 0 || height <= 0)
        return;
    gtk_window_set_default_size(window, width, height);
    gtk_widget_set_size_request(picture, -1, -1);
}

// On first map: preserve the launch grid before relaxing its temporary minimum,
// and apply the now-resolved display scale — the map is the first point the
// window's scale_factor reflects its monitor.
void onWindowMappedRelaxSize(GtkWidget* window, gpointer)
{
#ifdef GDK_WINDOWING_WAYLAND
    // GDK creates the Wayland toplevel during its map handler. Its application
    // ID setter is a no-op at GtkWidget::realize; set it here before the first
    // content buffer commits, so compositor launch rules see the requested ID.
    if (GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(window)); surface && GDK_IS_WAYLAND_TOPLEVEL(surface)
        && !app().windowApplicationID.empty())
        gdk_wayland_toplevel_set_application_id(GDK_TOPLEVEL(surface), app().windowApplicationID.c_str());
#endif
    if (LinuxPane* pane = activePane(); pane && pane->picture)
        preserveLaunchSize(GTK_WINDOW(window), pane->picture);
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
    gdk_clipboard_read_text_async(clipboard, nullptr, onWindowAsyncReady, windowAsyncData(onClipboardPasted, nullptr));
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
void copySelectionUX();
void selectAll(); // Ctrl+Shift+A — select the whole buffer (defined below)
bool openLinkAtCell(int row, int column, GdkModifierType state, int pressCount); // the press handler's link fallback (defined below)

// Clamp the ACTIVE PANE's viewport offset in place. The bound itself is
// `Screen::clampViewOffset`; distinct name because this one mutates a pane
// rather than returning a value, and a shared name makes the two
// indistinguishable to any tree-wide rename.
void noteScrollIndicatorActivity(LinuxPane&);

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

// The model publishes Core's edge-to-edge decision; presentation only converts
// the configured point insets to the geometry's device-pixel unit.
Ubiquitty::Rendering::EdgeInsets paneInsets(const LinuxPane& pane, float scale)
{
    if (pane.session && pane.session->readSnapshot().isEdgeToEdge)
        return {};
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    auto padding = config.resolvedPadding();
    // Core's desktop default leaves the top edge bare because a solid title bar
    // separates the text from it. libadwaita's raised top bar casts a shadow
    // over the content instead, so an unstated top edge takes the inset a window
    // without a title bar gets.
    // Keyed to the build, not to app().chrome: the window is sized for its
    // launch grid before the chrome is built, and that size must already hold
    // this inset or the grid opens a row short.
    if (!UBIQUITTY_LINUX_CHROMELESS && !config.paddingTop.has_value())
        padding.top = Ubiquitty::Preferences::Effective::titlelessPaddingTop(config);
    return { static_cast<float>(padding.left) * scale, static_cast<float>(padding.right) * scale,
        static_cast<float>(padding.top) * scale, static_cast<float>(padding.bottom) * scale };
}

// The size a pane's frame is drawn at, in device pixels: its picture's
// allocation, else the last one it had, else the pane area's. A background
// tab's picture is unmounted and reports 0x0, and a frame drawn for it at that
// size has no room for its padding — shown when the tab is switched to, it
// puts the grid at the pane's edge until the next frame moves it into place.
Ubiquitty::FloatSize paneViewport(LinuxPane& pane)
{
    const auto deviceSize = [](GtkWidget* widget) {
        return Ubiquitty::FloatSize { static_cast<float>(gtk_widget_get_width(widget) * app().scale),
            static_cast<float>(gtk_widget_get_height(widget) * app().scale) };
    };
    if (pane.picture) {
        const Ubiquitty::FloatSize allocated = deviceSize(pane.picture);
        if (allocated.width > 0 && allocated.height > 0) {
            pane.lastViewport = allocated;
            return allocated;
        }
    }
    if (pane.lastViewport.width > 0 && pane.lastViewport.height > 0)
        return pane.lastViewport;
    return app().paneContainer ? deviceSize(app().paneContainer) : Ubiquitty::FloatSize {};
}

Ubiquitty::Linux::Presentation::PaneGeometry paneGeometry(LinuxPane& pane, Ubiquitty::GridSize grid,
    Ubiquitty::Rendering::RemoteViewportRequest request = {})
{
    const Ubiquitty::FloatSize viewport = paneViewport(pane);
    return Ubiquitty::Linux::Presentation::PaneGeometry::resolve(viewport, paneInsets(pane, static_cast<float>(app().scale)),
        { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) }, grid, request);
}

// Resolve the whole grid before publishing pixels. Font changes alter the
// cell metrics without changing GTK's allocation, and the program must see
// those two changes in one winsize rather than a pixel report for the old grid.
bool updatePaneGridFromAllocation(LinuxPane& pane)
{
    if (!pane.picture)
        return false;
    const Ubiquitty::GridSize grid = Ubiquitty::Linux::Presentation::PaneGeometry::gridForAllocation(
        { static_cast<float>(gtk_widget_get_width(pane.picture) * app().scale), static_cast<float>(gtk_widget_get_height(pane.picture) * app().scale) },
        paneInsets(pane, static_cast<float>(app().scale)),
        { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) });
    if (grid.columns < 1 || grid.rows < 1 || (grid.columns == pane.columns && grid.rows == pane.rows))
        return false;
    pane.columns = grid.columns;
    pane.rows = grid.rows;
    return true;
}

bool publishPanePixelGeometry(LinuxPane& pane)
{
    Ubiquitty::Terminal* terminal = pane.session ? pane.session->terminal() : nullptr;
    if (!terminal) {
        return false;
    }
    const Ubiquitty::IntSize cell { app().rasterContext.cellWidth(), app().rasterContext.cellHeight() };
    const Ubiquitty::IntSize textArea { cell.width * pane.columns, cell.height * pane.rows };
    const auto unallocated = Ubiquitty::Rendering::viewportForGrid({ pane.columns, pane.rows },
        { static_cast<float>(cell.width), static_cast<float>(cell.height) }, paneInsets(pane, static_cast<float>(app().scale)), 0);
    Ubiquitty::IntSize drawable { static_cast<int>(std::ceil(unallocated.width)), static_cast<int>(std::ceil(unallocated.height)) };
    if (pane.picture) {
        const int width = gtk_widget_get_width(pane.picture);
        const int height = gtk_widget_get_height(pane.picture);
        if (width > 0 && height > 0) {
            drawable = { width * app().scale, height * app().scale };
        }
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
    return *app().sharedFonts->rasterizer(app().fontRasterizerKind);
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
double deviceFontPixelSize()
{
    return Ubiquitty::Linux::fontPixelSize(app().fontSizePoints, app().fontDPI, app().scale);
}

double deviceFontPixelsPerPoint()
{
    return Ubiquitty::Linux::fontPixelsPerPoint(app().fontDPI, app().scale);
}

Ubiquitty::Linux::SharedFontRequest sharedFontRequest()
{
    Ubiquitty::Linux::SharedFontRequest request;
    request.pixelSize = deviceFontPixelSize();
    request.pointSize = app().fontSizePoints;
    request.pixelsPerPoint = deviceFontPixelsPerPoint();
    request.deviceScale = app().scale;
    request.lineSpacing = app().lineSpacingPixels;
    request.tracking = app().trackingPixels;
    request.uprightWeight = app().uprightWeight;
    request.boldWeight = app().boldWeight;
    request.widthPercent = app().widthPercent;
    request.bitmapScale = Ubiquitty::Rendering::unifontScaleForRequestedSize(app().fontSizePoints, request.pixelsPerPoint);
    guint generation = 0;
    if (GtkSettings* settings = gtk_settings_get_default())
        g_object_get(settings, "gtk-fontconfig-timestamp", &generation, nullptr);
    request.catalogGeneration = generation;
    request.family = app().fontFamily;
    request.fallbackFamily = app().fallbackFontName;
    request.fallbackPath = app().bundledFallbackPath;
    request.primaryPath = bundledFontPathForFamily(app().fontFamily);
    request.variations = app().fontVariations;
    request.features = app().fontFeatures;
    request.ligatures = app().ligatures;
    request.preferences = loadPreferences();
    return request;
}

void acquireSharedFonts()
{
    app().sharedFonts = Ubiquitty::Linux::SharedFontResources::acquire(sharedFontRequest());
    app().glyphRasterizer = app().sharedFonts->nativeFace();
}

int largestMonitorCellBudget()
{
    GdkDisplay* display = gdk_display_get_default();
    if (!display)
        return 0;
    const auto metrics = currentRasterizer().cellMetrics();
    if (metrics.cellWidth <= 0 || metrics.cellHeight <= 0)
        return 0;
    GListModel* monitors = gdk_display_get_monitors(display);
    std::uint64_t largest = 0;
    for (guint index = 0; index < g_list_model_get_n_items(monitors); ++index) {
        auto* monitor = GDK_MONITOR(g_list_model_get_item(monitors, index));
        GdkRectangle geometry {};
        gdk_monitor_get_geometry(monitor, &geometry);
        g_object_unref(monitor);
        // Capacity follows the largest display at this font configuration,
        // rather than each window's viewport, so compatible windows share it.
        const auto columns = static_cast<std::uint64_t>(std::max(0.0, std::floor(static_cast<double>(geometry.width) * app().scale / metrics.cellWidth)));
        const auto rows = static_cast<std::uint64_t>(std::max(0.0, std::floor(static_cast<double>(geometry.height) * app().scale / metrics.cellHeight)));
        largest = std::max(largest, columns * rows);
    }
    return static_cast<int>(std::min<std::uint64_t>(largest, std::numeric_limits<int>::max()));
}

void configureSharedGlyphRenderer(Ubiquitty::Linux::VulkanRenderer& renderer)
{
    renderer.setSharedGlyphRasterizer(app().sharedFonts->rasterizer(app().fontRasterizerKind),
        app().sharedFonts->configuration(app().fontRasterizerKind), largestMonitorCellBudget());
}

void publishPaneTypography(LinuxPane& pane)
{
    if (!pane.session)
        return;
    const std::string actualFamily = app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::Native
            && app().glyphRasterizer && app().glyphRasterizer->ready()
        ? app().glyphRasterizer->familyName()
        : "GNU Unifont";
    (void)pane.session->publishActualFont(actualFamily, app().fontSizePoints);
    const auto& configuration = app().rasterContext.renderConfiguration();
    const double zoom = configuration.fontSizePoints > 0 ? app().fontSizePoints / configuration.fontSizePoints : 1;
    const double size = Ubiquitty::Rendering::proportionalFacePointSize(app().fontSizePoints, configuration.proportionalFontSizePoints * zoom);
    const auto catalog = pane.richText.fontCatalog();
    pane.session->setFontCatalogProvider(catalog.function, catalog.context);
    pane.session->publishTypography(pane.richText.configure(actualFamily, configuration.proportionalFontFamily.string(),
        currentRasterizer().cellMetrics(), size, deviceFontPixelSize() / deviceFontPixelsPerPoint(), deviceFontPixelsPerPoint()));
}

bool capturePaneRichText(LinuxPane& pane, const Ubiquitty::Linux::CursorOverlay* cursor, int viewOffset,
    Ubiquitty::FloatPoint origin = {}, Ubiquitty::FloatSize viewport = {})
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
    options.viewportSizeInPixels = viewport;
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

/// Resolves a configured point size with the Linux launch override.
///
/// - Parameter configuration: The effective font configuration for the window.
/// - Returns: The unrounded configured size, or the valid environment override.
double configuredFontSizePoints(const Ubiquitty::Rendering::RenderConfiguration& configuration)
{
    double points = configuration.fontSizePoints >= 4.0 && configuration.fontSizePoints <= 256.0 ? configuration.fontSizePoints : 12.0;
    if (const char* environment = std::getenv("UBIQUITTY_FONT_SIZE")) {
        const double parsed = std::strtod(environment, nullptr);
        if (parsed >= 4.0 && parsed <= 256.0)
            points = parsed;
    }
    return points;
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

    // Font point size — 12pt (16px at 96 DPI) by default; config [font] size overrides it, and the
    // UBIQUITTY_FONT_SIZE env overrides config. The cell is DERIVED from the face at
    // this size (FreeTypeRasterizer::cellMetrics), so a larger size gives a
    // proportionally larger cell.
    // Held as points, not rounded here: the rounding belongs where the scale is
    // applied (`deviceFontPixelSize`), and doing it now would spend the
    // fraction before the display could express it.
    const double fontSizePoints = configuredFontSizePoints(configuration);
    app().fontSizePoints = fontSizePoints;
    // Whole-size zoom steps use the integer twin; reset retains the configured
    // point size and reaches the rasterizer without that rounding.
    const int fontPixelSize = static_cast<int>(std::lround(fontSizePoints));
    app().fontPixelSize = fontPixelSize;
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
    acquireSharedFonts();
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
        g_print("ubiquitty-linux: glyph font = %s (FreeType AA, %gpt, %g DPI, %gpx, cell %dx%d)\n", app().glyphRasterizer->faceName(), app().fontSizePoints, app().fontDPI, deviceFontPixelSize(), static_cast<int>(m.cellWidth + 0.5f), static_cast<int>(m.cellHeight + 0.5f));
    }
}

// Re-inject the current-mode rasterizer into both backends and rebuild their glyph
// atlas / CPU renderer so a runtime font swap takes effect. A mounted pane's
// allocated grid is resolved before publishing the new metrics to its program.
void applyFontMode()
{
    Ubiquitty::Rendering::GlyphRasterizer& chosen = currentRasterizer();
    app().rasterContext.setGlyphRasterizer(chosen);
    configureSharedGlyphRenderer(app().vulkan);
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    for (const auto& pane : app().panes) {
        pane->captureConfiguration.reset();
        pane->pendingCapture.reset();
        publishPaneTypography(*pane);
        if (pane->picture && gtk_widget_get_parent(pane->picture))
            updatePaneGridFromAllocation(*pane);
        publishPanePixelGeometry(*pane);
    }
    requestRepaint();
}

// Runtime font-size zoom (View menu Cmd+/Cmd-/Cmd-0 parity): re-emplace the FreeType
// rasterizer at the new pixel size and rebuild both backends; the next onTick
// re-derives each pane's grid from the new cell metrics. No-op in Unifont mode (a
// fixed bitmap) or when the size is unchanged. The clamp is single-sourced with
// macOS via Zoom::clampFontZoom (the shared font.size range).
void applyFontSizePoints(double points)
{
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap)
        return;
    points = Ubiquitty::Preferences::Zoom::clampFontZoom(points);
    if (points == app().fontSizePoints)
        return;
    app().fontPixelSize = static_cast<int>(std::lround(points));
    app().fontSizePoints = points;
    // Release every borrowed-face cache before replacing its owner.
    app().rasterContext.resetSoftwareRenderer();
    app().vulkan.rebuildAtlas();
    acquireSharedFonts();
    applyFontMode();
}

void applyFontZoom(int newPixelSize)
{
    applyFontSizePoints(newPixelSize);
}

void resetFontZoom()
{
    const auto configuration = Ubiquitty::Preferences::Effective::renderConfiguration(loadPreferences());
    applyFontSizePoints(configuredFontSizePoints(configuration));
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
        g_print("ubiquitty-linux: display scale = %dx → rasterizing at %gpx (device cell %dx%d)\n", app().scale, deviceFontPixelSize(), static_cast<int>(m.cellWidth + 0.5f), static_cast<int>(m.cellHeight + 0.5f));
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

// What a program said about its work, for the header's subtitle and the tab:
// its status record's title and message, else its indicator's label. Core's
// "app: state" label is not used: the program's icon names the app and the
// status mark draws the state. Empty when the program gave no words.
std::string programStatusWords(LinuxPane& pane)
{
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term)
        return {};
    const auto hold = holdPaneModel(pane);
    if (term->programStatus.primary())
        return Ubiquitty::App::programActivityText(term->programStatus);
    return std::string(Ubiquitty::tabStatusText(term));
}

// What a pane shows beside its title in the header and its tab: the program
// it runs, by Core's process-icon catalog, and the status that program
// reported, as Core's roll-up kinds it.
Ubiquitty::Linux::Presentation::PaneMarks paneMarks(LinuxPane& pane)
{
    Ubiquitty::Linux::Presentation::PaneMarks marks;
    marks.hasUnheardBell = pane.hasUnheardBell;
    std::uint8_t reportedProcessIcon = 0;
    if (Ubiquitty::Terminal* term = pane.session->terminal()) {
        const auto hold = holdPaneModel(pane);
        if (const auto* record = term->programStatus.primary()) {
            Ubiquitty::App::PaneStatusFacts facts;
            facts.programState = record->state;
            marks.status = Ubiquitty::Linux::Presentation::statusSymbol(Ubiquitty::App::paneStatusKind(facts),
                record->state == Ubiquitty::OSC::ProgramState::Blocked ? record->kind : Ubiquitty::OSC::ProgramBlockKind::None);
        }
        reportedProcessIcon = Ubiquitty::Title::processIconOrdinal(Ubiquitty::Title::processIconReported(term->programStatus));
    }
    if (Ubiquitty::Preferences::Effective::processIcons(loadPreferences())) {
        marks.processIconKey = pane.session->processIconKey(reportedProcessIcon);
        marks.processIconTitle = Ubiquitty::Title::processIconTitle(marks.processIconKey);
    }
    return marks;
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
    const Ubiquitty::App::PaneTitleFacts facts = paneTitleFacts(*activePane(), composition);
    if (app().chrome) {
        Ubiquitty::App::PaneTitleFacts headerFacts = facts;
        headerFacts.programStatus = programStatusWords(*activePane());
        app().chrome->showTitle(Ubiquitty::Linux::Presentation::windowTitleContent(headerFacts, titleViewerFacts("Ubiquitty"), composition), paneMarks(*activePane()));
    }
    std::string title = Ubiquitty::App::composeTitle(facts, titleViewerFacts("Ubiquitty (Linux)"), composition, Ubiquitty::Session::TitleSurface::Window).title;
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

// The offset a frame of the pane shows it at, read under the hold the frame is
// read under. The ingest thread appends history before the delivery that
// hands it to followTailOrHoldViewport, so a pane held back over its history
// stands over the appended rows (Selection::frameViewOffset), where its own
// offset would show its rows moved by them.
int paneFrameViewOffset(const LinuxPane& pane, const Ubiquitty::Terminal& term)
{
    return Ubiquitty::Selection::frameViewOffset(pane.selection, term, pane.viewOffset);
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
        pane.heldFrameSource = windowTimeoutAdd(milliseconds, onHeldFrameDue, &pane);
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
    const auto* shown = app().model->paneTree(app().model->activeSurface());
    const bool isPaneVisible = &pane == activePane() || (shown && shown->holdsPane(static_cast<int>(paneIDForPane(&pane))));
    if (delivery.didOutputArrive && isPaneVisible)
        requestRepaint();
    if (&pane == activePane()) {
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
    AppScope scope(*pane->ownerApp);
    auto hop = std::make_unique<Ubiquitty::WeakPtr<LinuxPane>>(pane->weakPtr());
    windowIdleAddFull(G_PRIORITY_DEFAULT, onIngestEventsDue, hop.release(),
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
    pane.ownerApp = &app();
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

void closeWindowApp(App& owner)
{
    AppScope scope(owner);
    if (owner.isClosing.exchange(true))
        return;
    if (owner.pointerLockPane)
        applyPointerLock(Ubiquitty::Input::PointerLockVerdict::Release);
    if (owner.tickCallbackID && owner.paneContainer) {
        gtk_widget_remove_tick_callback(owner.paneContainer, owner.tickCallbackID);
        owner.tickCallbackID = 0;
    }
    for (const auto& pane : owner.panes)
        endPaneIngest(*pane);
    cancelWindowSources(owner);
    owner.caretBlinkSource = 0;
    owner.scrollIndicatorSource = 0;
    owner.accessiblePublishSource = 0;
    owner.pointerLockChordTimerID = 0;
    for (const auto& pane : owner.panes) {
        pane->pendingCapture.reset();
        pane->cursorPresentationSource = 0;
        pane->ptySource = 0;
        pane->ptyWriteSource = 0;
        pane->heldFrameSource = 0;
        if (pane->picture) {
            gtk_picture_set_paintable(GTK_PICTURE(pane->picture), nullptr);
            g_object_unref(pane->picture); // release the pane's ref_sink ownership
            pane->picture = nullptr;
        }
    }
    // GTK can retain an App and its private export image through the last frame.
    // A closed view releases CPU caches and shared glyph leases independently.
    owner.rasterContext.resetSoftwareRenderer();
    owner.vulkan.rebuildAtlas();
    const SurfaceID surface = owner.model->activeSurface();
    if (surface != Layout::invalidSurface)
        owner.model->closeWindowSurface(surface);
    for (const auto& pane : owner.panes)
        pane->session = nullptr;
    owner.vulkan.releaseFontResources();
    // GDK can retain the last frame's App after the view is gone. Frame pixels
    // need the device, not a lease on its former native fonts and glyph masks.
    if (owner.unifontRasterizer)
        owner.rasterContext.setGlyphRasterizer(*owner.unifontRasterizer);
    owner.glyphRasterizer.reset();
    owner.sharedFonts.reset();
    owner.paneByID.clear();
    if (owner.inspectorWindow)
        gtk_window_destroy(GTK_WINDOW(owner.inspectorWindow));
    owner.inspectorWindow = nullptr;
    owner.focusedPicture = nullptr;
    owner.windowAppearance.reset();
    if (owner.imContext) {
        gtk_im_context_set_client_widget(owner.imContext, nullptr);
        g_clear_object(&owner.imContext);
    }
    owner.configurationSubscription.reset();
}

// A callback that runs in this window's scope later — after a dialog is
// answered — and not at all once the window's state has gone. A closing window
// still hears it, so a question it asked on Core's behalf is still answered.
std::function<void()> inThisWindow(std::function<void()> body)
{
    return [owner = app().weak_from_this(), body = std::move(body)] {
        const std::shared_ptr<App> window = owner.lock();
        if (!window)
            return;
        AppScope scope(*window);
        body();
    };
}

// Ends panes after asking, when any of them runs a job the reader would miss:
// the question and what it lists are Core's (`Session::closeConfirmationTitle`
// and `closeConfirmationBody`), the same macOS asks. Panes that run nothing
// end without a question. The panes are named by identifier, since the
// answer may come after some of them have ended on their own.
void confirmClose(Ubiquitty::Session::CloseScope scope, const std::vector<PaneID>& panes, std::function<void()> proceed)
{
    std::vector<std::string> names;
    bool isSafe = true;
    for (const PaneID id : panes) {
        if (app().model->isPaneSafeToClose(id))
            continue;
        isSafe = false;
        if (LinuxPane* pane = paneForID(id)) {
            for (std::string& name : pane->session->runningProcessNamesForClose())
                names.push_back(std::move(name));
        }
    }
    if (isSafe || !app().window) {
        proceed();
        return;
    }
    if (Ubiquitty::Linux::GTK::isShowingDialog(app().window))
        return; // one question at a time
    Ubiquitty::Linux::GTK::ask(app().window,
        { .heading = Ubiquitty::Session::closeConfirmationTitle(scope),
            .body = Ubiquitty::Session::closeConfirmationBody(scope, names),
            .acceptLabel = "_Terminate",
            .acceptStyle = Ubiquitty::Linux::GTK::AcceptStyle::Destructive },
        inThisWindow(std::move(proceed)));
}

gboolean onWindowCloseRequested(GtkWindow*, gpointer)
{
    // A window whose panes run a job asks first, as macOS does: what ends is
    // Core's to say. The answer closes the window again, confirmed.
    if (!app().isCloseConfirmed && !app().model->isSurfaceSafeToClose(app().model->activeSurface())) {
        std::vector<PaneID> panes;
        for (const auto& pane : app().panes)
            panes.push_back(paneIDForPane(pane.get()));
        confirmClose(Ubiquitty::Session::CloseScope::Window, panes, [] {
            app().isCloseConfirmed = true;
            if (app().window)
                gtk_window_close(GTK_WINDOW(app().window));
        });
        return TRUE;
    }
    closeWindowApp(app());
    return FALSE;
}

void onWindowUnrealized(GtkWidget* widget, gpointer)
{
    auto retained = app().shared_from_this();
    if (retained->contextMenu) {
        gtk_widget_unparent(retained->contextMenu);
        retained->contextMenu = nullptr;
    }
    closeWindowApp(*retained);
    retained->window = nullptr;
    retained->paneContainer = nullptr;
    g_object_set_data(G_OBJECT(widget), "ubiquitty-window-state", nullptr);
    std::erase_if(windowApps().windows, [&](const auto& owner) { return owner.get() == retained.get(); });
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
    if (app().window && !gtk_window_is_active(GTK_WINDOW(app().window))) {
        cursor.focused = false;
        cursor.blinkAlpha = 1.0f;
    }
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
    app().caretBlinkSource = windowTimeoutAdd(milliseconds, [](gpointer) -> gboolean {
        app().caretBlinkSource = 0;
        requestRepaint(RepaintCause::CursorStep);
        return G_SOURCE_REMOVE; }, nullptr);
}

// Input feedback must not wait behind the redraw filter: the cell just typed
// belongs behind the caret, not inside the previous held block cursor.
void noteCursorInput(LinuxPane& pane, double nowSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6)
{
    pane.cursorPresentationBypassUntil = nowSeconds + Ubiquitty::Rendering::cursorPresentationInputBypassSeconds;
}

// One pane's cursor. Only the focused pane's is live: every other pane of a
// split draws its cursor unfocused and steady, as an inactive window does, so
// the one that takes the keys is the one that blinks.
Ubiquitty::Linux::CursorOverlay resolvePaneCursorOverlay(const LinuxPane& pane, const Ubiquitty::Terminal* term)
{
    Ubiquitty::Linux::CursorOverlay cursor = resolveCursorOverlay(term);
    if (&pane != activePane()) {
        cursor.focused = false;
        cursor.blinkAlpha = 1.0f;
    }
    return cursor;
}

Ubiquitty::Linux::CursorOverlay resolvePresentedCursorOverlay(LinuxPane& pane, double nowSeconds, double intervalSeconds)
{
    const Ubiquitty::Terminal* term = pane.session ? pane.session->terminal() : nullptr;
    const auto hold = holdPaneModel(pane);
    Ubiquitty::Linux::CursorOverlay cursor = resolvePaneCursorOverlay(pane, term);
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
    Ubiquitty::Rendering::CursorRenderState presented = pane.cursorPresentation.update(frame, nowSeconds, intervalSeconds,
        nowSeconds < pane.cursorPresentationBypassUntil);
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
    pane.cursorPresentationSource = windowTimeoutAdd(milliseconds, onCursorPresentationDue, &pane);
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

void refreshOmarchyAccent(int index)
{
    const auto read = [index]() -> std::optional<std::uint32_t> {
        const auto* theme = index >= 0 ? Ubiquitty::Themes::get(index) : nullptr;
        if (!theme || !theme->name || std::string_view(theme->name) != "Omarchy")
            return std::nullopt;
        const std::string path = std::string(g_get_user_state_dir()) + "/omarchy/current/theme/colors.toml";
        const auto closeFile = [](FILE* file) { std::fclose(file); };
        std::unique_ptr<FILE, decltype(closeFile)> input(std::fopen(path.c_str(), "rb"), closeFile);
        if (!input)
            return std::nullopt;
        constexpr std::size_t maximum = 64 * 1024;
        std::array<char, maximum + 1> bytes {};
        const auto count = std::fread(bytes.data(), 1, bytes.size(), input.get());
        return std::ferror(input.get()) || count > maximum ? std::nullopt
                                                           : Ubiquitty::Linux::parseOmarchyAccent(std::string_view(bytes.data(), count));
    };
    const auto accent = read();
    if (app().omarchyAccent != accent) {
        app().omarchyAccent = accent;
        if (app().scrollIndicator)
            gtk_widget_queue_draw(app().scrollIndicator);
    }
}

void refreshNativeLinkAccentColor()
{
    const GdkRGBA nativeColor = Ubiquitty::Linux::GTK::WindowAppearance::nativeLinkColor();
    const Ubiquitty::Rendering::Vec4 color { nativeColor.red, nativeColor.green, nativeColor.blue, nativeColor.alpha };
    const auto& previous = app().rasterContext.frameLinkAccentColor();
    if (previous.x == color.x && previous.y == color.y && previous.z == color.z && previous.w == color.w)
        return;
    app().rasterContext.setFrameLinkAccentColor(color);
    for (const auto& pane : app().panes) {
        const auto hold = holdPaneModel(*pane);
        if (auto* terminal = pane->session->terminal(); terminal && terminal->grid)
            terminal->grid->requestFullRedraw();
        pane->pendingCapture.reset();
        pane->captureConfiguration.reset();
        pane->isFrameDeclined = false;
    }
    requestRepaint();
}

// The theme a configuration selects: the one for the desktop's light or dark
// style when the reader follows it (`[appearance] follow_system`, with its
// `system_light_theme` and `system_dark_theme`), else the configured one.
// libadwaita's style manager is the system's style because this frontend never
// forces a colour scheme on it.
// Whether the theme follows the desktop's light or dark style. Set, the switch
// decides; unset, it follows only while no theme is named, so a theme a
// configuration names — Omarchy's, say — is kept as this frontend always kept it.
bool doesThemeFollowSystem(const Ubiquitty::Preferences::Values& config)
{
    if (config.followSystemAppearance.has_value())
        return *config.followSystemAppearance;
    return Ubiquitty::Preferences::Effective::followSystemAppearance(config) && Ubiquitty::Runtime::configuredThemeIndex(config) < 0;
}

int selectedThemeIndex(const Ubiquitty::Preferences::Values& config)
{
    if (doesThemeFollowSystem(config)) {
        adw_init();
        const bool isDark = adw_style_manager_get_dark(adw_style_manager_get_default());
        const int index = Ubiquitty::Themes::resolvedAutomaticThemeIndex(isDark ? Ubiquitty::Themes::AutomaticAppearance::Dark : Ubiquitty::Themes::AutomaticAppearance::Light);
        if (index >= 0)
            return index;
    }
    return Ubiquitty::Runtime::launchThemeIndex(config);
}

void applyChromeTheme(int index)
{
    refreshOmarchyAccent(index);
    const Ubiquitty::Themes::Theme* theme = index >= 0 ? Ubiquitty::Themes::get(index) : nullptr;
    if (!theme || !app().window)
        return;
    refreshNativeLinkAccentColor();
    const Ubiquitty::Preferences::TitlebarStyle titlebarStyle = Ubiquitty::Preferences::Effective::titlebarStyle(loadPreferences());
    app().windowAppearance.apply(app().window, app().paneContainer, *theme, app().rasterContext.backgroundOpacity(), titlebarStyle);
    if (app().chrome) {
        const auto& ground = theme->defaultBackground;
        app().chrome->setStyle(titlebarStyle, (std::uint32_t { ground.red } << 16) | (std::uint32_t { ground.green } << 8) | ground.blue);
    }
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
    app().liveThemeName = theme->name;
    app().appliedThemePalette = theme->serializeTOML();
    applyChromeTheme(index);
    for (const std::unique_ptr<LinuxPane>& pane : app().panes) {
        if (!pane)
            continue;
        if (Ubiquitty::Terminal* term = pane->session->terminal()) {
            const auto hold = holdPaneModel(*pane);
            (void)Ubiquitty::Themes::applyThemeToTerminal(*term, index);
            if (term->grid)
                term->grid->requestFullRedraw();
            pane->pendingCapture.reset();
            pane->captureConfiguration.reset();
            pane->isFrameDeclined = false;
        }
    }
}

// The desktop switched between its light and dark style.
void onSystemAppearanceChanged(AdwStyleManager*, GParamSpec*, gpointer)
{
    // A stock chrome's ground follows the system style.
    if (app().chrome)
        app().chrome->refreshGround();
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    if (!doesThemeFollowSystem(config))
        return;
    const int index = selectedThemeIndex(config);
    const auto* theme = Ubiquitty::Themes::get(index);
    if (!theme || index == app().liveThemeIndex)
        return;
    // Recorded as the configuration's choice, so the next reload keeps it.
    app().configuredThemeName = theme->name;
    applyThemeToAllPanes(index);
    rebuildTabStrip();
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
        windowTimeoutAdd(static_cast<guint>((left + 1) * 1000 / 60), [](gpointer) -> gboolean {
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

// A presented frame. A GtkPicture stretches a paintable to its allocation, so a
// stale frame would be squeezed or stretched for as long as a resize waits for
// its next frame. This paintable ignores the size it is asked to draw at: the
// texture stays at its own size and origin, clipped to the allocation, until a
// frame laid out for the new size replaces it.
struct UbiquittyFramePaintable {
    GObject parent;
    GdkTexture* texture;
    graphene_rect_t bounds; // device pixels
    graphene_rect_t contentClip; // device pixels
    bool hasContentClip;
    int intrinsicWidth;
    int intrinsicHeight;
    float deviceScale; // device pixels per logical pixel
};

struct UbiquittyFramePaintableClass {
    GObjectClass parentClass;
};

void initializeFramePaintableInterface(GdkPaintableInterface*);

G_DEFINE_TYPE_WITH_CODE(UbiquittyFramePaintable, ubiquitty_frame_paintable, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(GDK_TYPE_PAINTABLE, initializeFramePaintableInterface))

void finalizeFramePaintable(GObject* object)
{
    g_clear_object(&static_cast<UbiquittyFramePaintable*>(static_cast<void*>(object))->texture);
    G_OBJECT_CLASS(ubiquitty_frame_paintable_parent_class)->finalize(object);
}

void ubiquitty_frame_paintable_class_init(UbiquittyFramePaintableClass* frameClass)
{
    G_OBJECT_CLASS(frameClass)->finalize = finalizeFramePaintable;
}

void ubiquitty_frame_paintable_init(UbiquittyFramePaintable*) { }

void snapshotFramePaintable(GdkPaintable* paintable, GdkSnapshot* snapshot, double width, double height)
{
    const auto* frame = static_cast<const UbiquittyFramePaintable*>(static_cast<const void*>(paintable));
    const graphene_rect_t clip = GRAPHENE_RECT_INIT(0, 0, static_cast<float>(width), static_cast<float>(height));
    gtk_snapshot_push_clip(GTK_SNAPSHOT(snapshot), &clip);
    if (frame->hasContentClip) {
        const graphene_rect_t content = GRAPHENE_RECT_INIT(frame->contentClip.origin.x / frame->deviceScale,
            frame->contentClip.origin.y / frame->deviceScale, frame->contentClip.size.width / frame->deviceScale,
            frame->contentClip.size.height / frame->deviceScale);
        gtk_snapshot_push_clip(GTK_SNAPSHOT(snapshot), &content);
    }
    // The frame is laid out in device pixels, the allocation is in logical
    // ones: converting by the display scale is the only scaling applied.
    gtk_snapshot_save(GTK_SNAPSHOT(snapshot));
    gtk_snapshot_scale(GTK_SNAPSHOT(snapshot), 1.0f / frame->deviceScale, 1.0f / frame->deviceScale);
    gtk_snapshot_append_texture(GTK_SNAPSHOT(snapshot), frame->texture, &frame->bounds);
    gtk_snapshot_restore(GTK_SNAPSHOT(snapshot));
    if (frame->hasContentClip)
        gtk_snapshot_pop(GTK_SNAPSHOT(snapshot));
    gtk_snapshot_pop(GTK_SNAPSHOT(snapshot));
}

GdkPaintableFlags framePaintableFlags(GdkPaintable*)
{
    return static_cast<GdkPaintableFlags>(GDK_PAINTABLE_STATIC_SIZE | GDK_PAINTABLE_STATIC_CONTENTS);
}

int framePaintableWidth(GdkPaintable* paintable)
{
    return static_cast<const UbiquittyFramePaintable*>(static_cast<const void*>(paintable))->intrinsicWidth;
}

int framePaintableHeight(GdkPaintable* paintable)
{
    return static_cast<const UbiquittyFramePaintable*>(static_cast<const void*>(paintable))->intrinsicHeight;
}

void initializeFramePaintableInterface(GdkPaintableInterface* paintableInterface)
{
    paintableInterface->snapshot = snapshotFramePaintable;
    paintableInterface->get_flags = framePaintableFlags;
    paintableInterface->get_intrinsic_width = framePaintableWidth;
    paintableInterface->get_intrinsic_height = framePaintableHeight;
}

// The frame as a paintable that owns a reference to its texture. Intrinsic
// dimensions are logical pixels; the texture's bounds are device pixels.
GdkPaintable* makeFramePaintable(GdkTexture* texture, const graphene_rect_t& bounds, int intrinsicWidth, int intrinsicHeight, float deviceScale,
    std::optional<Ubiquitty::FloatRect> contentClip = std::nullopt)
{
    auto* frame = static_cast<UbiquittyFramePaintable*>(g_object_new(ubiquitty_frame_paintable_get_type(), nullptr));
    frame->texture = GDK_TEXTURE(g_object_ref(texture));
    frame->bounds = bounds;
    frame->intrinsicWidth = intrinsicWidth;
    frame->intrinsicHeight = intrinsicHeight;
    frame->deviceScale = deviceScale;
    frame->hasContentClip = contentClip.has_value();
    if (contentClip)
        frame->contentClip = GRAPHENE_RECT_INIT(contentClip->origin.x, contentClip->origin.y, contentClip->size.width, contentClip->size.height);
    return GDK_PAINTABLE(frame);
}

GdkTexture* makeMemoryFrameTexture(std::shared_ptr<App>, std::unique_ptr<std::vector<uint8_t>>, int width, int height);

#include "Platform/Linux/Smokes/FramePaintableSmoke.h"

// A texture over the frame's host pixels. GTK reads the bytes lazily, so they
// outlive this frame: the pooled buffer rides inside the GBytes and comes back
// to the pool when GTK lets the bytes go.
struct MemoryFrameRelease {
    std::shared_ptr<App> owner;
    std::unique_ptr<std::vector<uint8_t>> buffer;
};

GdkTexture* makeMemoryFrameTexture(std::shared_ptr<App> owner, std::unique_ptr<std::vector<uint8_t>> frameBuffer, int width, int height)
{
    auto* release = new MemoryFrameRelease { std::move(owner), std::move(frameBuffer) };
    GBytes* bytes = g_bytes_new_with_free_func(release->buffer->data(), release->buffer->size(), [](gpointer pointer) {
        std::unique_ptr<MemoryFrameRelease> owned(static_cast<MemoryFrameRelease*>(pointer));
        owned->owner->framePool.give(std::move(owned->buffer)); }, release);
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
    std::shared_ptr<App> owner;
    int fileDescriptor;
    std::uint64_t releaseToken;
};

// A texture over an exported frame's dma-buf. The bytes stay in GPU memory and
// reach the compositor without a host copy. GTK does not take the descriptor;
// the destroy notify closes it and returns the slot when GTK lets it go.
// Null when GTK refuses the import, with the descriptor closed and the slot
// returned.
GdkTexture* makeExportedFrameTexture(std::shared_ptr<App> owner, GtkWidget* picture, const Ubiquitty::Linux::VulkanRenderer::ExportedFrame& frame)
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
    auto* release = new ExportedFrameRelease { std::move(owner), frame.fileDescriptor, frame.releaseToken };
    GError* error = nullptr;
    GdkTexture* texture = gdk_dmabuf_texture_builder_build(builder, [](gpointer data) {
        std::unique_ptr<ExportedFrameRelease> owned(static_cast<ExportedFrameRelease*>(data));
        ::close(owned->fileDescriptor);
        owned->owner->vulkan.releaseExportedFrame(owned->releaseToken); }, release, &error);
    g_object_unref(builder);
    if (!texture) {
        g_warning("dma-buf import refused (%s); frames read back for this run", error ? error->message : "no reason given");
        if (error)
            g_error_free(error);
        ::close(release->fileDescriptor);
        release->owner->vulkan.releaseExportedFrame(release->releaseToken);
        delete release;
    }
    return texture;
}

// Draws the pane's frame, unless Core's check under the frame's hold declines
// it: an update the parser opened, or a screen it erased, after the tick's
// published check. Returns false only then, so the caller keeps the frame owed.
bool renderPaneInto(LinuxPane& pane, GtkWidget* picture, std::optional<Ubiquitty::Runtime::TerminalSession::ModelReadScope>* outerHold)
{
    if (!picture)
        return true; // headless (no window) — the smoke paths render via rasterizeTerm directly
    const std::uint32_t frameStartMicros = Ubiquitty::PAL::monotonicMicros();
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term)
        return true;
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
    Ubiquitty::Runtime::FrameDemand demand;
    demand.nowTicks = Ubiquitty::PAL::monotonicTicks();
    if (pane.isFrameDeclined || (!pane.pendingCapture && pane.session->liveReadDecline(*term, demand).decline != Ubiquitty::Runtime::FrameDecline::None))
        return false;
    const int frameViewOffset = paneFrameViewOffset(pane, *term);
    std::unique_ptr<std::vector<uint8_t>> frameBuffer = app().framePool.take();
    std::vector<uint8_t>& rgba = *frameBuffer;
    int width = 0, height = 0;
    const double nowSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
    Ubiquitty::Linux::CursorOverlay cursor = pane.pendingCapture ? resolvePaneCursorOverlay(pane, term)
                                                                 : resolvePresentedCursorOverlay(pane, nowSeconds, cursorPresentationInterval(picture));
    if (pane.pendingCapture) {
        pane.pendingCapture->setCursorMixAlpha(cursor.blinkAlpha);
        pane.pendingCapture->applyCursorPresentation(pane.cursorPresentation, nowSeconds, cursorPresentationInterval(picture),
            nowSeconds < pane.cursorPresentationBypassUntil);
    }
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
    const Ubiquitty::GridSize gridSize = pane.pendingCapture
        ? Ubiquitty::GridSize { pane.pendingCapture->columns(), pane.pendingCapture->rows() }
        : Ubiquitty::GridSize { term->columns, term->rows };
    const Ubiquitty::CellPosition cursorPosition = pane.pendingCapture
        ? Ubiquitty::CellPosition { pane.pendingCapture->cursorRow(), pane.pendingCapture->cursorColumn() }
        : Ubiquitty::CellPosition { term->screens.active->cursorY, term->screens.active->cursorX };
    const bool isProgramViewport = term->isTekModeActive || term->modes.fullscreenContent;
    const bool shouldFollowCursor = frameViewOffset == 0 && term->modes.isCursorVisible != 0;
    const auto framePresentation = paneGeometry(pane, gridSize, {
                                                                    .policy = app().rasterContext.renderConfiguration().nonOwnerPresentation,
                                                                    .cursor = cursorPosition,
                                                                    .previousPanOffset = pane.presentation.placement.panOffset,
                                                                    .minimumScale = static_cast<float>(std::min(1.0, Ubiquitty::Preferences::Zoom::clampFontZoom(0.0) / app().fontSizePoints)),
                                                                    .isGeometryOwnedElsewhere = pane.session->isRemoteGeometryOwnedElsewhere(),
                                                                    .isProgramViewport = isProgramViewport,
                                                                    .shouldFollowCursor = shouldFollowCursor,
                                                                });
    const bool isPaneFocused = &pane == activePane() && app().window && gtk_window_is_active(GTK_WINDOW(app().window));
    app().rasterContext.setFrameSelectionColor(paneSelectionColor(*term, selectionFocus(isPaneFocused)));
    const auto frameGeometry = app().rasterContext.frameCaptureGeometry(framePresentation.rasterOrigin, framePresentation.rasterSize);
    app().rasterContext.setFrameHoverLink(pane.hoveredLink);
    app().rasterContext.setBeamChrome(&chrome);
    app().rasterContext.setHintChrome(&hint);
    const bool hasRichFrame = capturePaneRichText(pane, &cursor, frameViewOffset, framePresentation.rasterOrigin, framePresentation.rasterSize);
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
    Ubiquitty::Rendering::FrameCapture::ViewTierOverrides capturedView;
    if (pane.pendingCapture && pane.capturedSelectionSpanCount > 0) {
        capturedView.selectionSpans = pane.capturedSelectionSpans.data();
        capturedView.selectionSpanCount = pane.capturedSelectionSpanCount;
        capturedView.selectionColor = pane.pendingCapture->selectionFillColor();
        capturedView.isSelectionBehindText = pane.pendingCapture->isSelectionFillBehindText();
        capturedView.hasSelectionForegroundOverride = pane.pendingCapture->hasSelectionForegroundOverride();
        capturedView.selectionForeground = pane.pendingCapture->selectionForeground();
    }
    // Boundary frames own every byte the builder and image upload consume.
    // Their CPU instance build must not block the next parser pass.
    if (shouldRenderOnGPU && pane.pendingCapture && *hold)
        (*hold)->release();
    bool ok = shouldRenderOnGPU ? app().vulkan.renderGrid(app().rasterContext, term, rgba, width, height, frameViewOffset, &pane.selection, &cursor, blinkTicks, handoff, pane.pendingCapture.get(), &capturedView, &frameGeometry) : app().rasterContext.rasterizeTerm(term, rgba, width, height, frameViewOffset, &pane.selection, &cursor, blinkTicks, nullptr, &frameGeometry);
    const bool didDrawOnGPU = ok && shouldRenderOnGPU;
    const std::optional<Ubiquitty::Linux::VulkanRenderer::ExportedFrame> exportedFrame = didDrawOnGPU ? app().vulkan.takeExportedFrame() : std::nullopt;
    if (exportedFrame)
        ++app().perfWindow.exportedFrames;
    if (!ok && shouldRenderOnGPU) {
        // A grid larger than any frame the device can draw is this frame's
        // size, not a failed GPU: a program's page length, a remote owner's
        // geometry or a large font put the model there, and the next grid that
        // fits goes back to the GPU. Any other failure — device lost, a
        // missing shader — must not freeze the window: the pane keeps its last
        // texture and every later frame fails the same way. That demotes to
        // the CPU raster once, for good; the exit path's teardown is gated on
        // the same flag, so a lost device is not torn down twice. Either way
        // this same frame is painted through the CPU raster.
        if (!app().vulkan.didDeclineOversizedGrid()) {
            g_warning("Vulkan render failed; demoting to the CPU raster for this run");
            app().isVulkanReady = false;
        }
        // The GPU may have handed the model back before failing. The CPU
        // fallback reads the current model throughout its raster pass.
        hold->emplace(*pane.session);
        ok = app().rasterContext.rasterizeTerm(term, rgba, width, height, frameViewOffset, &pane.selection, &cursor, blinkTicks, nullptr, &frameGeometry);
    }
    if (!ok)
        return true;
    pane.presentedGridSize = gridSize;
    pane.presentedCellPixels = { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) };
    pane.presentedLetters.resize(static_cast<std::size_t>(gridSize.rows));
    for (int row = 0; row < gridSize.rows; ++row) {
        const auto letters = didDrawOnGPU ? app().vulkan.rowLetters(row) : app().rasterContext.rowLetters(row);
        auto& saved = pane.presentedLetters[static_cast<std::size_t>(row)];
        saved.assign(letters.begin(), letters.end());
    }
    if (hasRichFrame) {
        const auto overlayHold = holdPaneModel(pane);
        pane.richText.composite(pane.richTextFrame, rgba, width, height,
            app().rasterContext.snapshotOverlayRegions(*term, frameViewOffset, framePresentation.rasterOrigin), drawsRichCaret);
    }
    pane.presentation = framePresentation;
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

    GdkTexture* texture = exportedFrame ? makeExportedFrameTexture(app().shared_from_this(), picture, *exportedFrame) : nullptr;
    if (exportedFrame && !texture) {
        // GTK refused the import: the frame exists only in GPU memory, so this
        // one is dropped, the export is switched off for the run, and the next
        // frame reads back.
        app().vulkan.disableFrameExport();
        requestRepaint();
        return true;
    }
    if (!texture)
        texture = makeMemoryFrameTexture(app().shared_from_this(), std::move(frameBuffer), width, height);
    // The frame is drawn at its own size and clipped to the picture's
    // allocation, so a resize that has not yet produced its next frame shows the
    // old one unscaled instead of stretched to a different owner's grid. No
    // resampling/readback pass is added to either renderer.
    const graphene_rect_t bounds = GRAPHENE_RECT_INIT(pane.presentation.textureOrigin.x, pane.presentation.textureOrigin.y,
        width * pane.presentation.placement.scale, height * pane.presentation.placement.scale);
    GdkPaintable* paintable = makeFramePaintable(texture, bounds, gtk_widget_get_width(picture), gtk_widget_get_height(picture), static_cast<float>(app().scale), pane.presentation.contentClip);
    gtk_picture_set_paintable(GTK_PICTURE(picture), paintable);
    g_object_unref(paintable);
    g_object_unref(texture);
    return true;
}

// Paint the focused pane into the shared picture. (Split panes render each visible
// leaf into its own picture; today there is one, app().focusedPicture.)
void renderGridFrame() { static_cast<void>(renderPaneInto(*activePane(), app().focusedPicture, nullptr)); }

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
    if (Ubiquitty::Runtime::keyPressCountsAsUserActivity(press)) {
        noteCursorInput(*activePane());
        const auto hold = holdPaneModel(*activePane());
        if (Ubiquitty::Modes::shouldSnapToTail(activePane()->session->terminal(), Ubiquitty::Modes::SnapTrigger::Keypress))
            activePane()->viewOffset = 0;
    }
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
    noteCursorInput(*activePane());
    activePane()->session->sendPaste(std::string(text));
    armPTYWriteDrain(activePane());
}

// A paste the reader asked for. One that would type more lines than the
// reader allows (`[paste] confirm_multiline`, Core's line count) is shown
// first and sent only if they agree, as macOS asks; the pane it was asked for
// gets it, or nothing if that pane has gone.
void pasteTextUX(std::string_view text)
{
    if (text.empty())
        return;
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    const int lines = Ubiquitty::Input::pasteLineCount(text);
    if (!app().window || !Ubiquitty::Preferences::Effective::confirmMultilinePaste(config)
        || lines <= Ubiquitty::Preferences::Effective::confirmMultilinePasteThreshold(config)) {
        pasteText(text);
        return;
    }
    if (Ubiquitty::Linux::GTK::isShowingDialog(app().window))
        return;
    // The preview is bounded; the paste is not.
    constexpr std::size_t previewBytes = 16 * 1024;
    std::string preview(Ubiquitty::Title::titleBytePrefix(text, previewBytes));
    if (preview.size() < text.size())
        preview += "\n… (preview truncated)";
    const PaneID pane = paneIDForPane(activePane());
    Ubiquitty::Linux::GTK::ask(app().window,
        { .heading = "Paste " + std::to_string(lines) + " Lines?",
            .body = "Pasting multiple lines may run several shell commands.",
            .acceptLabel = "_Paste",
            .acceptStyle = Ubiquitty::Linux::GTK::AcceptStyle::Destructive,
            .preview = std::move(preview) },
        inThisWindow([pane, payload = std::string(text)] {
            if (paneIDForPane(activePane()) == pane)
                pasteText(payload);
        }));
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
    noteCursorInput(*pane);
    pane->session->sendInput(outputBuffer);
    armPTYWriteDrain(pane);
    return TRUE;
}

#include "Platform/Linux/Smokes/ReadbackMemorySmoke.h"

#include "Platform/Linux/Smokes/CoverageSheetSmoke.h"

#include "Platform/Linux/Smokes/AtlasCapacitySmoke.h"

#include "Platform/Linux/Smokes/SoftFontSmoke.h"

#include "Platform/Linux/Smokes/KeypadSmoke.h"

#include "Platform/Linux/Smokes/DropSmoke.h"

// GTK clipboard reads are async; the read completes here on the main thread.
// `source` is the GdkClipboard the read was started on (the system clipboard for
// Ctrl+Shift+V, the PRIMARY selection for middle-click). NULL text = empty /
// non-text clipboard → nothing to paste.
void onClipboardPasted(GObject* source, GAsyncResult* result, gpointer)
{
    char* text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, nullptr);
    if (text) {
        if (app().window && activePane())
            pasteTextUX(text);
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
        gtk_window_set_focus(GTK_WINDOW(app().window), nullptr); // the terminal has the keys while nothing else does
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
    noteCursorInput(*activePane());
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
    const int previousOffset = activePane()->viewOffset;
    activePane()->viewOffset += lines;
    clampActivePaneViewOffset(activePane()->session->terminal());
    if (activePane()->viewOffset != previousOffset)
        noteScrollIndicatorActivity(*activePane());
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
            noteCursorInput(*activePane());
            activePane()->session->sendInput({ action.bytes.data(), action.bytes.size() });
            armPTYWriteDrain(activePane());
            activePane()->viewOffset = 0; // typing snaps to the live tail
            requestRepaint();
        }
        break;

    case ActionKind::Copy:
        copySelectionUX();
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
        offsetViewByLines(INT_MAX - activePane()->viewOffset);
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
        resetFontZoom();
        break;
    case ActionKind::IncreaseLineSpacing:
    case ActionKind::DecreaseLineSpacing: {
        const double points = Ubiquitty::Preferences::Zoom::lineSpacingAfterPixelStep(app().lineSpacingPixels,
            deviceFontPixelsPerPoint(), action.kind == ActionKind::IncreaseLineSpacing ? 1 : -1);
        (void)Ubiquitty::Preferences::configureOwnKey(Ubiquitty::Preferences::Key::FontLineSpacing,
            Ubiquitty::Preferences::Value::ofNumber(Ubiquitty::Preferences::SerializeKind::Double, points));
        break;
    }

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
            noteCursorInput(*activePane());
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
                app().liveThemeIndex = selectedThemeIndex(Ubiquitty::Preferences::values());
            const auto hold = holdPaneModel(*activePane());
            fillBeamScopes(activePane()->session->terminal());
        }
        app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
        requestRepaint();
        break;

    case ActionKind::NewWindow:
        newWindow();
        break;
    // No named-command frontend dispatch on Linux yet; left cleanly unhandled
    // rather than inventing a half-feature (matches macOS).
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
    // The resolved family may change while a missing native face has left the
    // window on its bitmap fallback. A manual bitmap toggle, in contrast,
    // keeps a loaded native face and should survive unrelated typography edits.
    const auto oldFamilyKind = Ubiquitty::Rendering::selectFontFamily(app().fontFamily).rasterizerKind;
    const bool hasManualMode = app().glyphRasterizer && app().glyphRasterizer->ready()
        && app().fontRasterizerKind != oldFamilyKind;
    std::string family = configuration.fontFamily.string();
    if (const char* environment = std::getenv("UBIQUITTY_FONT"))
        family = environment;
    const bool didFamilyChange = family != app().fontFamily;
    app().fontFamily = std::move(family);
    app().fallbackFontName = linuxSymbolFallbackName(configuration);
    const auto selectedKind = Ubiquitty::Rendering::selectFontFamily(app().fontFamily).rasterizerKind;

    // Compare configured sizes, not the zoomed size on the window. A save of
    // another setting keeps a zoom, while an actual size edit updates both the
    // live size and the reset target. An environment override wins on either
    // side of the comparison just as it does at startup.
    if (configuredFontSizePoints(configuration) != configuredFontSizePoints(app().appliedRenderConfiguration)) {
        app().fontSizePoints = configuredFontSizePoints(configuration);
        app().fontPixelSize = static_cast<int>(std::lround(app().fontSizePoints));
    }
    // Spacing is configured in points and reaches both faces in device pixels,
    // so it scales with the display exactly as it does at startup. The bitmap
    // face is rebuilt with it in either mode: its cell carries the spacing.
    const Ubiquitty::Linux::FaceSpacing spacing = Ubiquitty::Linux::faceSpacing(configuration, deviceFontPixelsPerPoint());
    app().lineSpacingPixels = spacing.lineSpacingInPixels;
    app().trackingPixels = spacing.characterSpacingInPixels;
    Ubiquitty::Linux::emplaceBitmapFace(app().unifontRasterizer, app().fontSizePoints, deviceFontPixelsPerPoint(), spacing);
    Ubiquitty::Linux::configureFontRouting(deviceFontPixelSize(), loadPreferences());
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
    acquireSharedFonts();
    const auto desiredKind = !didFamilyChange && hasManualMode ? app().fontRasterizerKind : selectedKind;
    app().fontRasterizerKind = desiredKind == Ubiquitty::Rendering::FontRasterizerKind::Native && app().glyphRasterizer->ready()
        ? Ubiquitty::Rendering::FontRasterizerKind::Native
        : Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap;
    app().rasterContext.setEmbeddedBitmapScale(app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap
            ? Ubiquitty::Rendering::unifontScaleForRequestedSize(app().fontSizePoints, deviceFontPixelsPerPoint())
            : 0);
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
    windowSignalConnect(dismiss, "clicked", G_CALLBACK(onConfigurationBarDismissed), nullptr);
    gtk_action_bar_pack_end(GTK_ACTION_BAR(app().configurationBar), dismiss);
    updateConfigurationBar();
    return app().configurationBar;
}

// What a configure owes the open window: the process and per-terminal state,
// the window's render configuration, new faces when the typography moved, and
// a redraw of everything — the frontend reads most keys where it uses them.
void applyLiveConfiguration()
{
    refreshOmarchyAccent(app().liveThemeIndex);
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
    const int configuredTheme = selectedThemeIndex(config);
    const auto* configuredPalette = Ubiquitty::Themes::get(configuredTheme);
    const std::string configuredName = configuredPalette ? configuredPalette->name : "";
    const bool didConfiguredThemeChange = !app().configuredThemeName || *app().configuredThemeName != configuredName;
    app().configuredThemeName = configuredName;
    const int previousTheme = Ubiquitty::Themes::indexForName(app().liveThemeName.c_str());
    const int selectedTheme = didConfiguredThemeChange || previousTheme < 0 ? configuredTheme : previousTheme;
    const auto* theme = Ubiquitty::Themes::get(selectedTheme);
    // A custom palette can change under the same name and index. An unrelated
    // edit retains the user's live picker choice and application OSC colors.
    if (theme && (selectedTheme != app().liveThemeIndex || app().appliedThemePalette != theme->serializeTOML()))
        applyThemeToAllPanes(selectedTheme);
    else
        applyChromeTheme(selectedTheme);
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
    // An open dialog — a close confirmation, say — answers its own keys: the
    // terminal's capture-phase handler would otherwise take Return from it.
    if (Ubiquitty::Linux::GTK::isShowingDialog(app().window))
        return true;
    if (app().chrome) {
        GtkWidget* menuButton = GTK_WIDGET(app().chrome->menuButton());
        GtkPopover* popover = gtk_menu_button_get_popover(GTK_MENU_BUTTON(menuButton));
        if ((popover && gtk_widget_get_visible(GTK_WIDGET(popover))) || focus == menuButton
            || (focus && gtk_widget_is_ancestor(focus, menuButton)))
            return true;
    }
    return false;
}

gboolean onKeyPressed(GtkEventControllerKey* controller, guint keyval, guint keycode, GdkModifierType state, gpointer)
{
    if (doesMenuOwnKeys())
        return GDK_EVENT_PROPAGATE;
    if (modifierVirtualKeyFor(keyval) == Ubiquitty::Keys::VirtualKey::None
        && keyval != GDK_KEY_ISO_Level3_Shift && keyval != GDK_KEY_ISO_Level5_Shift
        && keyval != GDK_KEY_Num_Lock && keyval != GDK_KEY_Scroll_Lock)
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
            noteCursorInput(*activePane());
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
        copySelectionUX();
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

    Ubiquitty::Input::KeyChord defaultChord;
    Ubiquitty::Input::BindingAction defaultAction;
    if (mapKeyvalToChord(keyval, state, defaultChord)
        && Ubiquitty::Input::resolveDefaultBinding(app().bindingTable, defaultChord, defaultAction)) {
        executeBindingAction(defaultAction);
        return GDK_EVENT_STOP;
    }

    // Ctrl++ / Ctrl+= zoom the font in, Ctrl+- out, Ctrl+0 resets (View > Zoom
    // parity). No-op in Unifont mode. Consumed here.
    if ((state & GDK_CONTROL_MASK)
        && (((state & GDK_SHIFT_MASK) == 0 && (keyval == GDK_KEY_plus || keyval == GDK_KEY_equal)) || keyval == GDK_KEY_KP_Add)) {
        applyFontZoom(app().fontPixelSize + 1);
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK)
        && (((state & GDK_SHIFT_MASK) == 0 && keyval == GDK_KEY_minus) || keyval == GDK_KEY_KP_Subtract)) {
        applyFontZoom(app().fontPixelSize - 1);
        return GDK_EVENT_STOP;
    }
    if ((state & GDK_CONTROL_MASK) && (keyval == GDK_KEY_0 || keyval == GDK_KEY_KP_0)) {
        resetFontZoom();
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
            offsetViewByLines(keyval == GDK_KEY_Page_Up ? page : -page);
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

    // sendKey snaps only input it actually encodes and classifies as user
    // activity. A desktop shortcut's bare modifier must preserve scrollback.
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
    for (const auto& pane : app().panes) {
        if (pane->isPointerPositionKnown)
            updatePaneHoverCursor(*pane, pane->pointerX, pane->pointerY, static_cast<GdkModifierType>(0));
    }
    // A backgrounded lock would trap a pointer no window owns; regaining
    // focus re-takes it without the program re-sending the mode.
    updatePointerLock();
}

void onFocusLeave(GtkEventControllerFocus*, gpointer)
{
    scheduleCaretBlink(nullptr);
    app().hoverModifiers = static_cast<GdkModifierType>(0);
    for (const auto& pane : app().panes) {
        pane->hoverModifiers = static_cast<GdkModifierType>(0);
        publishHoveredLink(*pane, {});
    }
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
    app().pointerLockChordTimerID = windowTimeoutAdd(static_cast<guint>((ticks + 1) * 1000 / 60), onPointerLockChordTick, nullptr);
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
    if (app().window) {
        const bool isActive = gtk_window_is_active(GTK_WINDOW(app().window));
        activePane()->session->setDesiredFocus(isActive ? Ubiquitty::Modes::FocusState::Focused : Ubiquitty::Modes::FocusState::Unfocused);
        if (isActive)
            restartCaretBlink(false);
        else
            scheduleCaretBlink(nullptr);
    }
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
    noteCursorInput(*activePane());
    activePane()->viewOffset = 0;
    activePane()->session->sendInput({ text, std::strlen(text) });
    armPTYWriteDrain(activePane());
    app().rasterContext.setPreedit(nullptr, 0);
    app().hasInputMethodPreedit = false;
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
    app().hasInputMethodPreedit = !codePoints.empty();
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
    app().hasInputMethodPreedit = false;
    requestRepaint();
}

// Tell the IM where the cursor is (client-widget pixels) so the candidate window
// tracks it instead of pinning to the window origin.
void updateIMCursorLocation(Ubiquitty::CellPosition cursor)
{
    if (!app().imContext || !app().window || !activePane()->picture)
        return;
    const int cw = app().rasterContext.cellWidth();
    const int ch = app().rasterContext.cellHeight();
    // The IME anchor uses the same complete-picture map as the drawn cursor.
    const Ubiquitty::FloatRect cell = Ubiquitty::Rendering::cellRect(cursor, { static_cast<float>(cw), static_cast<float>(ch) }, Ubiquitty::Rendering::EdgeInsets {}, /*extraTop*/ 0.0f);
    GdkRectangle rect;
    const auto origin = activePane()->presentation.viewportPoint(cell.origin);
    // GTK's client widget is the toplevel window. The picture can be below
    // chrome or inside a split, so its local anchor must cross that boundary.
    const graphene_point_t picturePoint { origin.x / app().scale, origin.y / app().scale };
    graphene_point_t clientPoint;
    if (!gtk_widget_compute_point(activePane()->picture, app().window, &picturePoint, &clientPoint))
        return;
    rect.x = static_cast<int>(clientPoint.x);
    rect.y = static_cast<int>(clientPoint.y);
    rect.width = std::max(1, static_cast<int>(cw * activePane()->presentation.placement.scale / app().scale));
    rect.height = std::max(1, static_cast<int>(ch * activePane()->presentation.placement.scale / app().scale));
    gtk_im_context_set_cursor_location(app().imContext, &rect);
}

// Mouse reporting.

// Each pane keeps the letter positions of its own displayed frame. The shared
// renderer may have built another pane since that picture was presented.
double xInCellsAtPanePoint(const LinuxPane& pane, double x, double y, int row)
{
    const auto hold = holdPaneModel(pane);
    const auto point = pane.presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
    const auto letters = pane.presentedRowLetters(row);
    if (!letters.empty())
        return Ubiquitty::Rendering::letterXInCells(letters, point.x);
    const double pitch = pane.presentedCellPixels.width > 0 ? pane.presentedCellPixels.width : app().rasterContext.cellWidth();
    const int columns = pane.presentedGridSize.columns > 0 ? pane.presentedGridSize.columns : pane.session->terminal()->columns;
    return pitch > 0 ? std::clamp(point.x / pitch, 0.0, static_cast<double>(columns)) : 0;
}

void cellAtPanePoint(const LinuxPane& pane, double x, double y, int& row, int& column)
{
    // Convert widget points to device pixels, then undo the picture placement
    // once. Hit testing always addresses the host's actual grid.
    const auto* terminal = pane.session->terminal();
    const auto hold = holdPaneModel(pane);
    const auto point = pane.presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
    const Ubiquitty::CellPosition cell = Ubiquitty::Rendering::pointToCell(point, {},
        pane.presentedCellPixels.width > 0 ? pane.presentedCellPixels : Ubiquitty::FloatSize { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) },
        pane.presentedGridSize.columns > 0 ? pane.presentedGridSize : terminal ? Ubiquitty::GridSize { terminal->columns, terminal->rows }
                                                                               : Ubiquitty::GridSize {},
        Ubiquitty::Rendering::RowClamp::Clamped);
    row = cell.row;
    // The row is the grid's; the column along it is the frame's, which on a
    // proportional face's row is the letter under the point.
    const auto letters = pane.presentedRowLetters(cell.row);
    column = !letters.empty() ? Ubiquitty::Rendering::letterColumnAt(letters, point.x) : cell.column;
    if (terminal) {
        row = std::clamp(row, 0, std::max(terminal->rows - 1, 0));
        column = std::clamp(column, 0, std::max(terminal->columns - 1, 0));
    }
}

// A link hit addresses actual displayed content, unlike a report or a drag
// whose coordinates clamp to an existing cell.
std::optional<Ubiquitty::CellPosition> strictCellAtPanePoint(const LinuxPane& pane, double x, double y)
{
    const auto hold = holdPaneModel(pane);
    const auto* terminal = pane.session->terminal();
    const auto cell = pane.presentedCellPixels.width > 0 ? pane.presentedCellPixels
                                                         : Ubiquitty::FloatSize { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) };
    const auto grid = pane.presentedGridSize.columns > 0 ? pane.presentedGridSize
        : terminal                                       ? Ubiquitty::GridSize { terminal->columns, terminal->rows }
                                                         : Ubiquitty::GridSize {};
    auto position = pane.presentation.cellAtPointIfInside({ x * app().scale, y * app().scale }, cell, grid);
    if (!position)
        return std::nullopt;
    const auto letters = pane.presentedRowLetters(position->row);
    if (!letters.empty()) {
        const auto point = pane.presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
        position->column = Ubiquitty::Rendering::letterColumnAt(letters, point.x);
    }
    return position;
}

void cellAtPoint(double x, double y, int& row, int& column)
{
    cellAtPanePoint(*activePane(), x, y, row, column);
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
    if (!activePane()->session->resolveLinkAtVisibleCell(activePane()->viewOffset, row, column, Ubiquitty::Screen::LinkScanScope::Any))
        return LinkSource::None;
    const std::string uri = activePane()->session->resolvedLinkURI();
    g_strlcpy(outputBuffer, uri.c_str(), static_cast<std::size_t>(outputCapacity));
    return activePane()->session->resolvedLinkIsHyperlink() ? LinkSource::Declared : LinkSource::Guessed;
}

// The same native policy serves clicking and hovering, including a TUI that
// enabled mouse reporting. Control reaches links; Super belongs to the WM.
bool linkClickOpens(LinkSource source, std::string_view uri, GdkModifierType state)
{
    if (source == LinkSource::None)
        return false;
    const Ubiquitty::Input::PointerMoment moment {
        .held = heldModifiers(state),
        .isMouseReporting = activePane()->session->readSnapshot().mouseReportsActive,
    };
    const Ubiquitty::Linux::LinkInteraction interaction(moment, Ubiquitty::Preferences::values());
    return interaction.canOpen({ source == LinkSource::Declared, activePane()->session->resolvedLinkIsFilePath(), uri });
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
    cellAtPanePoint(pane, x, y, row, column);
    int pixelX = -1, pixelY = -1;
    if (&pane == activePane()) {
        sgrPixelArgsForPoint(x, y, pixelX, pixelY);
    } else if (pane.mouseModes.mouseSGRPixelsActive) {
        const auto point = pane.presentation.picturePoint({ static_cast<float>(x * app().scale), static_cast<float>(y * app().scale) });
        pixelX = std::max(1, static_cast<int>(point.x) + 1);
        pixelY = std::max(1, static_cast<int>(point.y) + 1);
    }
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
    fact.xInCells = xInCellsAtPanePoint(pane, x, y, row);
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

    if (gdkButton == GDK_BUTTON_PRIMARY) {
        app().isLinkPressClaimed = false;
        const auto cell = strictCellAtPanePoint(*activePane(), x, y);
        if (cell && openLinkAtCell(cell->row, cell->column, state, nPress)) {
            app().isLinkPressClaimed = true;
            gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
            return;
        }
    }
    // PRIMARY paste remains the terminal's fallback only when the application
    // has not claimed mouse reporting. Link ownership above uses Core's policy.
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
    }

    if (button == Ubiquitty::Input::PointerButton::Other)
        return;
    if (forwardPointerFact(*activePane(), Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Press, button, x, y, state, nPress))
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

void onMouseGestureCancelled(GtkGesture*, GdkEventSequence*, gpointer)
{
    // A cancelled sequence has no release to route. GtkGestureClick::stopped
    // can also fire during a drag, which must retain its claimed release.
    app().isLinkPressClaimed = false;
    app().heldPointerButton = Ubiquitty::Input::PointerButton::Other;
}

void onMouseReleased(GtkGestureClick* gesture, gint, gdouble x, gdouble y, gpointer)
{
    const guint gdkButton = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    const Ubiquitty::Input::PointerButton button = pointerButtonForGdk(gdkButton);
    app().heldPointerButton = Ubiquitty::Input::PointerButton::Other;
    if (button == Ubiquitty::Input::PointerButton::Left && app().isLinkPressClaimed) {
        app().isLinkPressClaimed = false;
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
        return;
    }
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
void publishHoveredLink(LinuxPane& pane, const Ubiquitty::Rendering::FrameHoverLink& next)
{
    const auto& previous = pane.hoveredLink;
    const bool didChange = previous.isActive != next.isActive || previous.linkID != next.linkID
        || previous.rowAbsoluteFirst != next.rowAbsoluteFirst || previous.rowAbsoluteLast != next.rowAbsoluteLast
        || previous.columnFirst != next.columnFirst || previous.columnLast != next.columnLast
        || previous.spanColumnFirst != next.spanColumnFirst || previous.spanColumnLast != next.spanColumnLast
        || previous.textDigest != next.textDigest;
    if (!didChange)
        return;
    pane.hoveredLink = next;
    pane.session->setSyncFrameHoverLink(next);
    pane.pendingCapture.reset();
    pane.captureConfiguration.reset();
    pane.isFrameDeclined = false;
    requestRepaint();
}

void updatePaneHoverCursor(LinuxPane& pane, double x, double y, GdkModifierType state)
{
    if (!pane.picture && (&pane != activePane() || !app().focusedPicture))
        return;
    Ubiquitty::Terminal* term = pane.session->terminal();
    pane.hoverModifiers = state;
    if (&pane == activePane())
        app().hoverModifiers = state;
    pane.hoverModelGeneration = pane.session->readSnapshot().modelGeneration;
    pane.hoverViewOffset = pane.viewOffset;
    const auto cell = strictCellAtPanePoint(pane, x, y);
    const Ubiquitty::Input::PointerMoment moment {
        .held = heldModifiers(state),
        .isMouseReporting = pane.session->readSnapshot().mouseReportsActive,
    };
    const Ubiquitty::Linux::LinkInteraction interaction(moment, Ubiquitty::Preferences::values());
    const auto probe = interaction.probe();
    const bool found = cell && probe != Ubiquitty::Input::LinkProbe::None
        && pane.session->resolveLinkAtVisibleCell(pane.viewOffset, cell->row, cell->column,
            probe == Ubiquitty::Input::LinkProbe::Any ? Ubiquitty::Screen::LinkScanScope::Any : Ubiquitty::Screen::LinkScanScope::Declared);
    Ubiquitty::Input::PointerContext context;
    context.isOverTextVoid = !cell;
    const LinkSource source = !found              ? LinkSource::None
        : pane.session->resolvedLinkIsHyperlink() ? LinkSource::Declared
                                                  : LinkSource::Guessed;
    context.isOverLink = found && interaction.canOpen({ source == LinkSource::Declared, pane.session->resolvedLinkIsFilePath(), pane.session->resolvedLinkURI() });
    Ubiquitty::Rendering::FrameHoverLink hover;
    if (context.isOverLink) {
        hover.isActive = true;
        hover.linkID = pane.session->resolvedLinkID();
        hover.rowAbsoluteFirst = pane.session->resolvedLinkRowFirst();
        hover.rowAbsoluteLast = pane.session->resolvedLinkRowLast();
        hover.columnFirst = pane.session->resolvedLinkColumnFirst();
        hover.columnLast = pane.session->resolvedLinkColumnLast();
        hover.spanColumnFirst = pane.session->resolvedLinkSpanColumnFirst();
        hover.spanColumnLast = pane.session->resolvedLinkSpanColumnLast();
        hover.textDigest = pane.session->resolvedLinkTextDigest();
    }
    publishHoveredLink(pane, hover);
    const auto hold = holdPaneModel(pane);
    const auto& reporting = interaction.reportingState();
    context.isRectangularSelectArmed = Ubiquitty::Input::localDragIsRectangular(reporting);
    context.selectionBypassesMouseReporting = Ubiquitty::Input::allowsLocalDragSelect(reporting);
    if (context.isRectangularSelectArmed) {
        context.isOverLink = false;
        publishHoveredLink(pane, {});
    }
    // Read for completeness -- onMouseMotion already routes every X11-backend
    // locked event through reportPointerLockX11Motion and returns before this
    // runs, so this only matters if that ranking ever changes.
    context.isPointerLocked = app().isPointerLocked;
    // No chromeless window drag on this frontend yet, and no trailing-void
    // resolution — each stays false until the frontend can answer it, rather
    // than being answered wrongly here.

    const Ubiquitty::MousePointerShape shape = Ubiquitty::Input::pointerShape(term, context);
    if (shape == pane.hoverCursorShape)
        return;
    gtk_widget_set_cursor_from_name(pane.picture ? pane.picture : app().focusedPicture, cursorNameForShape(shape));
    pane.hoverCursorShape = shape;
    if (&pane == activePane())
        app().hoverCursorShape = shape;
}

void updateHoverCursor(double x, double y, GdkModifierType state)
{
    updatePaneHoverCursor(*activePane(), x, y, state);
}

void onMouseMotion(GtkEventControllerMotion* motion, gdouble x, gdouble y, gpointer userData)
{
    LinuxPane* pane = userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane();
    pane->pointerX = x;
    pane->pointerY = y;
    pane->isPointerPositionKnown = true;
    const GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(motion));
    if (app().isPointerLocked && app().pointerLockOS.backend == Ubiquitty::Linux::PointerLockBackendKind::X11) {
        // The lock owns every event on this backend: no hover affordance, no
        // drag/report ladder -- GTK4's only relative-motion technique is this
        // recentre, so the ordinary motion path never runs while it is live.
        app().pointerLockLastModifiers = state;
        reportPointerLockX11Motion(x, y, state);
        return;
    }
    if (app().isLinkPressClaimed)
        return;
    const bool isButtonDown = app().heldPointerButton != Ubiquitty::Input::PointerButton::Other;
    if (!isButtonDown) {
        updatePaneHoverCursor(*pane, x, y, state);
        // A locally activatable link keeps its hover even under any-event
        // reporting. Away from a link the application's motion path is intact.
        const bool isReported = !pane->hoveredLink.isActive
            && forwardPointerFact(*pane, Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion,
                Ubiquitty::Input::PointerButton::None, x, y, state, 1);
        app().isHoverPointKnown = !isReported;
        app().hoverX = x;
        app().hoverY = y;
        if (isReported)
            publishHoveredLink(*pane, {});
        return;
    }
    // A held button's motion is a drag fact: the ladder reports it under a
    // motion-tracking mode or extends the open local selection.
    forwardPointerFact(*pane, Ubiquitty::Runtime::TerminalSession::PointerFact::Kind::Motion,
        app().heldPointerButton, x, y, state, 1);
}

// The pointer left a pane, so there is no hover for a modifier key to re-ask.
void onMouseEnter(GtkEventControllerMotion* motion, gdouble x, gdouble y, gpointer userData)
{
    LinuxPane* pane = userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane();
    pane->pointerX = x;
    pane->pointerY = y;
    pane->isPointerPositionKnown = true;
    if (!app().isPointerLocked) {
        app().hoverX = x;
        app().hoverY = y;
        app().isHoverPointKnown = true;
        const auto state = motion ? gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(motion)) : static_cast<GdkModifierType>(0);
        updatePaneHoverCursor(*pane, x, y, state);
    }
}

void onMouseLeave(GtkEventControllerMotion*, gpointer userData)
{
    LinuxPane* pane = userData != nullptr ? static_cast<LinuxPane*>(userData) : activePane();
    pane->isPointerPositionKnown = false;
    app().isHoverPointKnown = false;
    publishHoveredLink(*pane, {});
}

// The modifiers held once a key has gone down or up. Which of them a modifier
// key's own event carries differs between the X11 and Wayland backends, so the
// key's edge is applied here rather than read from the event.
GdkModifierType modifiersAfterKey(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge)
{
    const auto modifier = keyval == GDK_KEY_Control_L || keyval == GDK_KEY_Control_R                                 ? GDK_CONTROL_MASK
        : keyval == GDK_KEY_Super_L || keyval == GDK_KEY_Super_R                                                     ? GDK_SUPER_MASK
        : keyval == GDK_KEY_Shift_L || keyval == GDK_KEY_Shift_R                                                     ? GDK_SHIFT_MASK
        : keyval == GDK_KEY_Alt_L || keyval == GDK_KEY_Alt_R || keyval == GDK_KEY_Meta_L || keyval == GDK_KEY_Meta_R ? GDK_ALT_MASK
                                                                                                                     : static_cast<GdkModifierType>(0);
    const unsigned held = edge == Ubiquitty::Keys::KeyEventType::Release ? (state & ~modifier) : (state | modifier);
    return static_cast<GdkModifierType>(held);
}

// The exact Control chord decides whether a click opens a guessed link, and the
// hand promises what a click would do, so it re-asks at the last hover point
// when Ctrl goes down or up. Pressing a key moves no pointer, so no motion
// event would, and macOS re-asks on flagsChanged for the same reason.
void updateHoverForModifierKey(guint keyval, GdkModifierType state, Ubiquitty::Keys::KeyEventType edge)
{
    if (modifierVirtualKeyFor(keyval) == Ubiquitty::Keys::VirtualKey::None)
        return;
    if (app().isPointerLocked || app().heldPointerButton != Ubiquitty::Input::PointerButton::Other)
        return;
    const auto held = modifiersAfterKey(keyval, state, edge);
    for (const auto& pane : app().panes) {
        if (pane->isPointerPositionKnown)
            updatePaneHoverCursor(*pane, pane->pointerX, pane->pointerY, held);
    }
}

// The wheel-scroll policy from [mouse] config: wheel_lines (base lines per notch,
// Core's default when unset) × wheel_speed (multiplier). The delta ->
// line-count math is portable Core (ScrollTuning), shared with macOS. Surface
// deltas arrive in logical pixels, so precise scrolling also supplies the
// logical cell height and the independent trackpad speed.
Ubiquitty::Screen::ScrollTuning::Policy currentWheelPolicy()
{
    const Ubiquitty::Preferences::Values& config = loadPreferences();
    Ubiquitty::Screen::ScrollTuning::Policy policy;
    policy.baseLinesPerTick = static_cast<double>(Ubiquitty::Preferences::Effective::wheelLines(config));
    policy.speed = Ubiquitty::Preferences::Effective::wheelSpeed(config);
    policy.trackpadSpeed = Ubiquitty::Preferences::Effective::trackpadSpeed(config);
    policy.pointsPerLine = app().rasterContext.cellHeight() / app().scale;
    return policy;
}

graphene_point_t pointerPointForScroll(const LinuxPane& pane, GtkEventController* ctrl)
{
    // Scroll events may omit position (Broadway does), and native event
    // positions are surface-relative rather than picture-relative. Enter and
    // motion already provide the correct pane-local point, including when a
    // TUI owns pointer reporting, so use that point for the wheel as well.
    double px = pane.pointerX, py = pane.pointerY;
    if (!pane.isPointerPositionKnown) {
        if (GdkEvent* event = gtk_event_controller_get_current_event(ctrl)) {
            double ex = 0, ey = 0;
            if (gdk_event_get_position(event, &ex, &ey)) {
                GtkWidget* picture = gtk_event_controller_get_widget(ctrl);
                GtkNative* native = gtk_widget_get_native(picture);
                double offsetX = 0, offsetY = 0;
                gtk_native_get_surface_transform(native, &offsetX, &offsetY);
                const graphene_point_t surfacePoint { static_cast<float>(ex - offsetX), static_cast<float>(ey - offsetY) };
                graphene_point_t picturePoint;
                if (gtk_widget_compute_point(GTK_WIDGET(native), picture, &surfacePoint, &picturePoint)) {
                    px = picturePoint.x;
                    py = picturePoint.y;
                }
            }
        }
    }
    return { static_cast<float>(px), static_cast<float>(py) };
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
    fact.isPrecise = gtk_event_controller_scroll_get_unit(scroll) == GDK_SCROLL_UNIT_SURFACE;
    const graphene_point_t point = pointerPointForScroll(*activePane(), ctrl);
    const double px = point.x, py = point.y;
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
        const int previousOffset = activePane()->viewOffset;
        activePane()->viewOffset += static_cast<int>(outcome.linesToOffsetView);
        clampActivePaneViewOffset(term);
        if (activePane()->viewOffset != previousOffset)
            noteScrollIndicatorActivity(*activePane());
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

// A copy the reader asked for — the Copy action, Ctrl+Shift+C — says so with
// a toast, as GNOME apps confirm a copy. Copy-on-select does not: it would
// toast on every drag.
void copySelectionUX()
{
    if (copySelectionToClipboard() && app().chrome)
        app().chrome->showToast("Copied to clipboard");
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
    LinuxPane& pane = *activePane();
    const bool isFilePath = pane.session->resolvedLinkIsFilePath();
    std::string directory;
    if (isFilePath) {
        const auto hold = holdPaneModel(pane);
        directory = pane.session->currentDirectory();
    }
    const char* home = g_get_home_dir();
    const std::string target = Ubiquitty::Linux::linkTargetURI(
        { source == LinkSource::Declared, isFilePath, uri.data() },
        pane.session->isFilesystemLocal() ? Ubiquitty::Runtime::FilesystemLocation::ThisMachine : Ubiquitty::Runtime::FilesystemLocation::Unknown,
        directory, home ? home : "");
    return linkDispatchForURI(target);
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
    pane->ptyWriteSource = windowUnixFDAdd(fileDescriptor, G_IO_OUT, onPTYWritable, pane);
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

// A transient, noninteractive rectangle: Core owns its geometry and fade.
// The one-shot timer sleeps through the hold, then runs only during the fade.
gboolean onScrollIndicatorDue(gpointer)
{
    app().scrollIndicatorSource = 0;
    const auto now = Ubiquitty::PAL::monotonicTicks().count;
    bool isVisible = false;
    forEachVisibleLeaf([&](LinuxPane& pane) {
        isVisible = isVisible || Ubiquitty::scrollIndicatorAlpha(pane.lastScrollIndicatorTick, now) > 0;
    });
    if (app().scrollIndicator) {
        gtk_widget_set_visible(app().scrollIndicator, isVisible);
        gtk_widget_queue_draw(app().scrollIndicator);
    }
    if (isVisible)
        app().scrollIndicatorSource = windowTimeoutAdd(16, onScrollIndicatorDue, nullptr);
    return G_SOURCE_REMOVE;
}

void noteScrollIndicatorActivity(LinuxPane& pane)
{
    pane.lastScrollIndicatorTick = std::max(std::uint32_t { 1 }, Ubiquitty::PAL::monotonicTicks().count);
    if (!app().scrollIndicator)
        return;
    gtk_widget_set_visible(app().scrollIndicator, TRUE);
    gtk_widget_queue_draw(app().scrollIndicator);
    if (app().scrollIndicatorSource != 0)
        g_source_remove(app().scrollIndicatorSource);
    app().scrollIndicatorSource = windowTimeoutAdd(1000, onScrollIndicatorDue, nullptr);
}

void drawScrollIndicator(GtkDrawingArea* area, cairo_t* cr, int, int, gpointer)
{
    const auto now = Ubiquitty::PAL::monotonicTicks().count;
    forEachVisibleLeaf([&](LinuxPane& pane) {
        graphene_rect_t bounds;
        if (!pane.picture || !gtk_widget_compute_bounds(pane.picture, GTK_WIDGET(area), &bounds))
            return;
        const auto hold = holdPaneModel(pane);
        const auto* term = pane.session->terminal();
        if (!term)
            return;
        Ubiquitty::Rendering::ScrollIndicatorParameters parameters;
        parameters.alpha = Ubiquitty::scrollIndicatorAlpha(pane.lastScrollIndicatorTick, now);
        parameters.scrollbackCount = Ubiquitty::Screen::scrollbackCount(term);
        parameters.rows = term->rows;
        parameters.viewOffset = pane.viewOffset;
        // The picture includes padding, so its outer edge is also the shared
        // thumb's reference edge.
        parameters.viewportSizeInPixels = { bounds.size.width, bounds.size.height };
        parameters.isFullScreen = true; // square Omarchy window corners
        Ubiquitty::Rendering::OverlayQuad quad;
        if (!Ubiquitty::Rendering::buildScrollIndicatorQuad(parameters, quad))
            return;
        const auto color = term->palette.indexed[4];
        const auto* theme = app().liveThemeIndex >= 0 ? Ubiquitty::Themes::get(app().liveThemeIndex) : nullptr;
        if (app().omarchyAccent && theme && theme->name && std::string_view(theme->name) == "Omarchy") {
            const auto accent = *app().omarchyAccent;
            cairo_set_source_rgba(cr, ((accent >> 16) & 255) / 255.0, ((accent >> 8) & 255) / 255.0, (accent & 255) / 255.0, quad.alpha);
        } else {
            cairo_set_source_rgba(cr, color.red / 65535.0, color.green / 65535.0, color.blue / 65535.0, quad.alpha);
        }
        cairo_rectangle(cr, bounds.origin.x + quad.minX, bounds.origin.y + quad.minY, quad.maxX - quad.minX, quad.maxY - quad.minY);
        cairo_fill(cr);
    });
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
    const double now = static_cast<double>(g_get_monotonic_time()) / 1e6;
    if (now - app().lastAccessiblePublishSeconds >= accessiblePublishIntervalSeconds) {
        publishAccessibleTerminalNow();
        return;
    }
    if (app().accessiblePublishSource == 0)
        app().accessiblePublishSource = windowTimeoutAdd(static_cast<guint>(accessiblePublishIntervalSeconds * 1000.0), onAccessiblePublishDue, nullptr);
}

void publishAccessibleTerminalNow()
{
    GtkWidget* accessible = app().accessibleTerminal;
    LinuxPane* pane = activePane();
    if (!accessible || !pane || !pane->picture)
        return;
    app().lastAccessiblePublishSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(pane->picture, accessible, &bounds))
        return;
    const float scale = static_cast<float>(app().scale);
    const auto& presentation = pane->presentation;
    const auto hold = holdPaneModel(*pane);
    Ubiquitty::Linux::Accessibility::updateTerminal(accessible,
        Ubiquitty::Linux::Accessibility::snapshot(pane->session->terminal(), pane->viewOffset, &pane->selection.state),
        { bounds.origin.x + presentation.placement.origin.x / scale, bounds.origin.y + presentation.placement.origin.y / scale },
        { logicalCellWidth() * presentation.placement.scale, logicalCellHeight() * presentation.placement.scale });
}

Ubiquitty::Linux::Presentation::SelectionFocus selectionFocus(bool isFocusedInActiveWindow) // bool-ok: converts the frame's one focus fact into the policy's enum
{
    return isFocusedInActiveWindow ? Ubiquitty::Linux::Presentation::SelectionFocus::Focused : Ubiquitty::Linux::Presentation::SelectionFocus::Unfocused;
}

bool isSameColor(const Ubiquitty::Rendering::Vec4& left, const Ubiquitty::Rendering::Vec4& right)
{
    return left.x == right.x && left.y == right.y && left.z == right.z && left.w == right.w;
}

// The colour GNOME selects text in, for one pane: the desktop's accent while
// the pane holds the keyboard in an active window, the view's grey otherwise,
// as libadwaita and GNOME's text views draw it. The terminal's own default
// background is the ground both are mixed against. The caller holds the model.
Ubiquitty::Rendering::Vec4 paneSelectionColor(const Ubiquitty::Terminal& terminal, Ubiquitty::Linux::Presentation::SelectionFocus focus)
{
    const auto channel = [](std::uint16_t value) { return static_cast<float>(Ubiquitty::channel16To8(value)) / 255.0f; };
    const Ubiquitty::PaletteRGB background = terminal.palette.defaultBackground;
    const Ubiquitty::Rendering::Vec4 ground { channel(background.red), channel(background.green), channel(background.blue), 1.0f };
    GdkRGBA accent { 0.21f, 0.52f, 0.89f, 1.0f };
    adw_accent_color_to_rgba(adw_style_manager_get_accent_color(adw_style_manager_get_default()), &accent);
    return Ubiquitty::Linux::Presentation::desktopSelectionColor(ground,
        { static_cast<float>(accent.red), static_cast<float>(accent.green), static_cast<float>(accent.blue), 1.0f }, focus);
}

// Keep frames admitted at parser boundaries instead of looking for the same
// boundary again after the parser has already started the next redraw.
void preparePaneFrame(LinuxPane& pane)
{
    const auto hoverSnapshot = pane.session->readSnapshot();
    if (pane.isPointerPositionKnown && !app().isPointerLocked
        && (pane.hoverModelGeneration != hoverSnapshot.modelGeneration || pane.hoverViewOffset != pane.viewOffset))
        updatePaneHoverCursor(pane, pane.pointerX, pane.pointerY, pane.hoverModifiers);
    const auto& configuration = app().rasterContext.renderConfiguration();
    const int cellWidth = app().rasterContext.cellWidth();
    const int cellHeight = app().rasterContext.cellHeight();
    const bool isFocused = &pane == activePane() && app().window && gtk_window_is_active(GTK_WINDOW(app().window));
    bool canUseBoundaryFrames = app().isVulkanReady;
    Ubiquitty::Rendering::Vec4 selectionColor {};
    {
        const auto hold = holdPaneModel(pane);
        const auto* terminal = pane.session->terminal();
        if (terminal)
            selectionColor = paneSelectionColor(*terminal, selectionFocus(isFocused));
        canUseBoundaryFrames = canUseBoundaryFrames && terminal && !terminal->isTekModeActive
            && terminal->richTextBlocks.blocks(Ubiquitty::RichText::activeScreen(*terminal)).empty()
            && pane.richTextFrame.richTextQuads().empty();
    }
    const auto authored = paneGeometry(pane, { hoverSnapshot.columns, hoverSnapshot.rows });
    if (app().isVulkanReady && (!pane.captureConfiguration || *pane.captureConfiguration != configuration || pane.captureCellWidth != cellWidth || pane.captureCellHeight != cellHeight || pane.isCaptureFocused != isFocused || !isSameColor(pane.captureSelectionColor, selectionColor) || pane.captureRasterOrigin.x != authored.rasterOrigin.x || pane.captureRasterOrigin.y != authored.rasterOrigin.y || pane.captureRasterSize.width != authored.rasterSize.width || pane.captureRasterSize.height != authored.rasterSize.height)) {
        app().rasterContext.setFrameSelectionColor(selectionColor);
        auto geometry = app().rasterContext.frameCaptureGeometry(authored.rasterOrigin, authored.rasterSize);
        geometry.isFocused = isFocused;
        pane.session->setSyncFrameCaptureGeometry(geometry);
        pane.captureConfiguration = configuration;
        pane.captureCellWidth = cellWidth;
        pane.captureCellHeight = cellHeight;
        pane.captureRasterOrigin = authored.rasterOrigin;
        pane.captureRasterSize = authored.rasterSize;
        pane.isCaptureFocused = isFocused;
        pane.captureSelectionColor = selectionColor;
        pane.captureViewOffset = -1;
    }
    pane.session->setSyncFramePresentation(canUseBoundaryFrames
            ? Ubiquitty::Runtime::PanePresentation::Presented
            : Ubiquitty::Runtime::PanePresentation::Hidden);
    const auto viewHistory = pane.selection.viewportObservedHistory;
    const bool isViewOffsetHeld = Ubiquitty::Selection::isViewOffsetHeldByHistory(pane.selection);
    const int registeredViewOffset = pane.captureViewOffset >= 0 && pane.isCaptureViewOffsetHeld
        ? Ubiquitty::Selection::heldViewOffset(pane.captureViewOffset, pane.captureViewHistory, viewHistory)
        : pane.captureViewOffset;
    if (registeredViewOffset != pane.viewOffset || pane.isCaptureViewOffsetHeld != isViewOffsetHeld) {
        pane.session->setSyncFrameViewOffset(pane.viewOffset,
            isViewOffsetHeld ? Ubiquitty::Input::ViewportHold::Hold : Ubiquitty::Input::ViewportHold::Follow, viewHistory);
        pane.captureViewOffset = pane.viewOffset;
        pane.captureViewHistory = viewHistory;
        pane.isCaptureViewOffsetHeld = isViewOffsetHeld;
    }
    Ubiquitty::Runtime::FrameDemand demand;
    demand.nowTicks = Ubiquitty::PAL::monotonicTicks();
    demand.selection = &pane.selection;
    const auto snapshot = pane.session->readSnapshot();
    pane.capturedSelectionSpans.resize(static_cast<std::size_t>(Ubiquitty::Selection::viewportSpanCapacity(snapshot.rows, snapshot.columns)));
    demand.selectionSpans = { pane.capturedSelectionSpans.data(), pane.capturedSelectionSpans.size() };
    const bool isPaneFocused = &pane == activePane();
    const bool hasPaneOverlay = isPaneFocused && (app().beamSession.isOpen() || app().hasInputMethodPreedit || *Ubiquitty::Input::hintText(pane.session->hintShowing(), Ubiquitty::Input::ModifierVocabulary::Words) != '\0');
    demand.keepsSearchLive = !canUseBoundaryFrames || hasPaneOverlay || app().beamFindPane.get() == &pane;
    Ubiquitty::Runtime::FrameSupply supply;
    pane.pendingCapture.reset(pane.session->takeFrame(demand, supply));
    if (pane.pendingCapture && supply.selection.needed > supply.selection.count) {
        pane.capturedSelectionSpans.resize(static_cast<std::size_t>(supply.selection.needed));
        supply.selection = pane.session->selectionForTakenFrame(&pane.selection, *pane.pendingCapture,
            { pane.capturedSelectionSpans.data(), pane.capturedSelectionSpans.size() }, supply.selectionEnds);
    }
    pane.capturedSelectionSpanCount = supply.selection.count;
    pane.isFrameDeclined = supply.route == Ubiquitty::Runtime::FrameRoute::Declined;
    if (pane.isFrameDeclined)
        ++app().perfWindow.withheldTicks;
}

gboolean onTick(GtkWidget*, GdkFrameClock*, gpointer)
{
    // Match each VISIBLE leaf's grid to its picture (its split sub-rectangle), and
    // resize Core + the PTY when it changes. The cell is the font-derived runtime
    // cell (Unifont 8×16 when forced); one font, so every pane shares the cell metric.
    // The whole-window grid (app().paneContainer) seeds new full-window tabs.
    // Both that seed and each pane subtract their internal content padding.
    if (app().paneContainer) {
        const Ubiquitty::GridSize dims = Ubiquitty::Linux::Presentation::PaneGeometry::gridForAllocation(
            { static_cast<float>(gtk_widget_get_width(app().paneContainer) * app().scale), static_cast<float>(gtk_widget_get_height(app().paneContainer) * app().scale) },
            paneInsets(*activePane(), static_cast<float>(app().scale)),
            { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) });
        if (dims.columns >= 1 && dims.rows >= 1) {
            app().columns = dims.columns;
            app().rows = dims.rows;
        }
    }
    forEachVisibleLeaf([&](LinuxPane& pane) {
        if (!pane.picture)
            return;
        // Allocation changes invalidate the presented viewport. Grid sizing
        // subtracts internal padding through the same Core geometry resolver.
        const Ubiquitty::FloatSize viewport {
            static_cast<float>(gtk_widget_get_width(pane.picture) * app().scale),
            static_cast<float>(gtk_widget_get_height(pane.picture) * app().scale)
        };
        if (viewport.width != pane.presentation.viewport.width || viewport.height != pane.presentation.viewport.height)
            requestRepaint();
        if (updatePaneGridFromAllocation(pane))
            requestRepaint();
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
    //
    // Every visible leaf takes its admitted boundary frame, or the live read
    // Core permits when native overlays need the current model.
    forEachVisibleLeaf([](LinuxPane& pane) { preparePaneFrame(pane); });
    // Core's drive recommends continuous presentation while the screen
    // changes at frame rate: the grid moves between any two ticks, so a frame
    // is owed on each whatever the delivery cadence, as the Swift arm's frame
    // clock resumes on the same recommendation. Only an ingesting pane: the
    // inline drain's own deliveries already ask per drain.
    forEachVisibleLeaf([](LinuxPane& pane) {
        if (!pane.isIngesting || !pane.session->isAdaptivePresentation())
            return;
        // GTK only exposes the panel interval after the picture is rooted.
        // Refresh the driver's rate before asking it whether output still
        // warrants a vblank frame. FrameDriver's interval is atomic because
        // the ingest thread reads it while the main thread updates it here.
        const double frameInterval = cursorPresentationInterval(pane.picture);
        if (frameInterval != pane.session->presentationFrameIntervalSeconds())
            pane.session->setPresentationFrameIntervalSeconds(frameInterval);
        if (pane.session->isPresentationRecommendedContinuous())
            requestRepaint();
    });
    ++app().perfWindow.ticks;
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
    // Keep a withheld present pending until a tick can draw it. A pane's
    // captured sync-clear frame remains available across the next update
    // block, so continuous BSU/ESU output can present completed frames at
    // native cadence without waiting for the watchdog.
    if (app().isRepaintPending) {
        // Repaint every visible leaf (a split tab shows N at once); each is still one
        // texture from one renderGrid/rasterizeTerm call keyed to its own term.
        // The frame's own reads of the focused model come first, under the
        // tick's hold, which the focused pane's frame then ends at its
        // capture boundary: the blink phase this frame paints and the
        // accessible snapshot of the grid it paints.
        const float paintedBlinkAlpha = resolveCursorOverlay(activePane()->session->terminal()).blinkAlpha;
        publishAccessibleTerminal();
        if (hold)
            hold->release();
        bool didDrawEveryLeaf = true;
        forEachVisibleLeaf([&](LinuxPane& pane) {
            didDrawEveryLeaf = renderPaneInto(pane, pane.picture, nullptr) && didDrawEveryLeaf;
            if (pane.pendingCapture && pane.session->hasFrameChangesAfter(*pane.pendingCapture))
                didDrawEveryLeaf = false;
            pane.pendingCapture.reset();
        });
        activePane()->lastCursorBlinkAlpha = paintedBlinkAlpha;
        app().lastBlinkPaintTicks = nowBlinkTicks; // advance the text-blink phase baseline
        app().isRepaintPending = !didDrawEveryLeaf;
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
    const double tickSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
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
        const double now = static_cast<double>(g_get_monotonic_time()) / 1e6;
        (void)app().frameDriver.noteActivity(now);
    }

    if (!app().paneContainer || !gtk_widget_get_mapped(app().paneContainer))
        return; // headless or unmapped: the next map requests its own frame
    if (app().tickCallbackID != 0)
        return;
    app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::Continuous);
    app().tickCallbackID = windowTickAdd(app().paneContainer, onTick, nullptr, nullptr);
}

// Build this pane's GtkPicture + its OWN event controllers (each carrying &pane, so
// a click/scroll routes to the pane it landed on — the bodies then read the focused
// pane activePane(), which the press/scroll handlers re-point via focusPaneFromEvent).
// The pane owns a strong ref (ref_sink) so its picture survives re-parenting across
// GtkPaned rebuilds. GTK-only: callers guard on app().window (headless smokes have no
// display and never build widgets — renderPaneInto bails on a null picture).
// Keep padding inside the frame's drawable, where overhanging text may draw.
// Reload invalidates capture geometry; the next tick resolves the new insets.
void applyPanePadding(LinuxPane& pane)
{
    if (!pane.picture)
        return;
    gtk_widget_set_margin_start(pane.picture, 0);
    gtk_widget_set_margin_end(pane.picture, 0);
    gtk_widget_set_margin_top(pane.picture, 0);
    gtk_widget_set_margin_bottom(pane.picture, 0);
    pane.captureConfiguration.reset();
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
    // The picture covers the whole pane. Core reserves internal padding for
    // grid sizing and raster origins, preserving native text overhang.
    applyPanePadding(pane);

    GtkGesture* mouseClick = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(mouseClick), 0);
    windowSignalConnect(mouseClick, "pressed", G_CALLBACK(onMousePressed), &pane);
    windowSignalConnect(mouseClick, "released", G_CALLBACK(onMouseReleased), &pane);
    windowSignalConnect(mouseClick, "cancel", G_CALLBACK(onMouseGestureCancelled), &pane);
    gtk_widget_add_controller(pane.picture, GTK_EVENT_CONTROLLER(mouseClick));

    GtkEventController* motion = gtk_event_controller_motion_new();
    windowSignalConnect(motion, "enter", G_CALLBACK(onMouseEnter), &pane);
    windowSignalConnect(motion, "motion", G_CALLBACK(onMouseMotion), &pane);
    windowSignalConnect(motion, "leave", G_CALLBACK(onMouseLeave), &pane);
    gtk_widget_add_controller(pane.picture, motion);

    // File drop: a file dropped on this pane writes its escaped path(s) to the
    // prompt (the macOS file drag & drop, via the shared Input::shellEscapedPath).
    GtkDropTarget* fileDrop = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    windowSignalConnect(fileDrop, "drop", G_CALLBACK(onFileDrop), &pane);
    gtk_widget_add_controller(pane.picture, GTK_EVENT_CONTROLLER(fileDrop));

    GtkEventController* scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    windowSignalConnect(scroll, "scroll", G_CALLBACK(onMouseScroll), &pane);
    gtk_widget_add_controller(pane.picture, scroll);
}

// Launch one pane's login shell and register its own PTY drain source (carrying
// &pane), so every tab advances its Ubiquitty::Terminal concurrently. Headless smokes poll via
// drainBriefly and never dispatch the source; under GTK it drives onPtyReadable.
bool bindPane(LinuxPane& pane, PaneID paneID)
{
    pane.ownerApp = &app();
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
        pane.ptySource = windowUnixFDAdd(fileDescriptor, static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR), onPtyReadable, &pane, G_PRIORITY_HIGH_IDLE + 20);
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
    const bool shouldRunRequestedCommand = app().launchRequest.has_value()
        && app().launchRequest->status == Ubiquitty::Runtime::LaunchRequest::Status::Command
        && !app().didConsumeLaunchRequest;
    if (shouldRunRequestedCommand)
        app().didConsumeLaunchRequest = true;
    // A window with no command of its own opens a login session and is
    // recorded; one opened to run a named command is not a login and stays out
    // of the session table.
    Ubiquitty::Runtime::LaunchCommand command = shouldRunRequestedCommand
        ? Ubiquitty::Runtime::LaunchCommand::fromArguments(app().launchRequest->command)
        : Ubiquitty::Runtime::LaunchCommand::loginSession();
    if (!app().launchDirectory.empty())
        command.setInitialDirectory(app().launchDirectory);
    const SurfaceID surface = app().model->addWindowSurface(command);
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
    Ubiquitty::App::PaneTitleFacts facts = paneTitleFacts(pane, composition);
    // The tab's status mark shows the program and its state; the label carries
    // only what the program itself said.
    facts.programStatus = programStatusWords(pane);
    return Ubiquitty::App::composeTitle(facts, titleViewerFacts("Tab " + std::to_string(index + 1)), composition, Ubiquitty::Session::TitleSurface::Tab).title;
}

// The model owns tab identity and selection; the chrome's tab bar shows them
// and keeps each tab's widgets across refreshes, so a title refresh never
// takes focus or a press from a tab.
void rebuildTabStrip()
{
    if (!app().chrome)
        return;
    const SurfaceID surface = app().model->activeSurface();
    const int tabCount = app().model->tabCount(surface);
    const TabID activeTab = app().model->activeTab(surface);
    std::vector<Ubiquitty::Linux::Presentation::TabItem> tabs;
    tabs.reserve(static_cast<std::size_t>(std::max(tabCount, 0)));
    for (int i = 0; i < tabCount; ++i) {
        const TabID tab = app().model->tabAt(surface, i);
        const Panes::Tree* tree = app().model->paneTree(surface, tab);
        const PaneID paneID = tree != nullptr ? static_cast<PaneID>(tree->focusedPaneID()) : invalidPane;
        LinuxPane* pane = paneForID(paneID);
        tabs.push_back({
            .identifier = static_cast<std::uint32_t>(tab),
            .label = pane != nullptr ? buildTabLabel(*pane, i) : ("Tab " + std::to_string(i + 1)),
            .isActive = tab == activeTab,
            .marks = pane != nullptr ? paneMarks(*pane) : Ubiquitty::Linux::Presentation::PaneMarks {},
        });
    }
    app().chrome->showTabs(tabs);
    // The tab buttons are checked by the action's state.
    if (GAction* action = g_action_map_lookup_action(G_ACTION_MAP(app().window), "active-tab"))
        g_simple_action_set_state(G_SIMPLE_ACTION(action), g_variant_new_uint32(static_cast<std::uint32_t>(activeTab)));
}

// The tab bar's actions: selecting a tab and closing one, each naming the tab
// by its model identifier.
void installTabActions()
{
    GSimpleAction* activeTab = g_simple_action_new_stateful("active-tab", G_VARIANT_TYPE_UINT32,
        g_variant_new_uint32(static_cast<std::uint32_t>(app().model->activeTab(app().model->activeSurface()))));
    windowSignalConnect(activeTab, "change-state", G_CALLBACK(+[](GSimpleAction*, GVariant* value, gpointer) {
        switchToTab(static_cast<TabID>(g_variant_get_uint32(value)));
        // Re-assert the model's selection: a refused switch leaves it unchanged.
        rebuildTabStrip();
    }),
        nullptr);
    g_action_map_add_action(G_ACTION_MAP(app().window), G_ACTION(activeTab));
    g_object_unref(activeTab);

    GSimpleAction* closeTab = g_simple_action_new("close-tab", G_VARIANT_TYPE_UINT32);
    windowSignalConnect(closeTab, "activate", G_CALLBACK(+[](GSimpleAction*, GVariant* value, gpointer) {
        closeTabUX(static_cast<TabID>(g_variant_get_uint32(value)));
    }),
        nullptr);
    g_action_map_add_action(G_ACTION_MAP(app().window), G_ACTION(closeTab));
    g_object_unref(closeTab);
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
    windowSignalConnect(paned, "notify::position", G_CALLBACK(onDividerMoved), nullptr);
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
    for (auto& pane : app().panes) {
        pane->session->setSyncFramePresentation(Ubiquitty::Runtime::PanePresentation::Hidden);
        pane->pendingCapture.reset();
        if (pane->picture)
            unmountPicture(pane->picture);
    }
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
// Closes a tab the reader asked to close, asking first if it runs a job. The
// last tab is the window, and is asked about as one.
void closeTabUX(TabID tab)
{
    const SurfaceID surface = app().model->activeSurface();
    const Panes::Tree* tree = app().model->paneTree(surface, tab);
    if (!tree)
        return;
    std::vector<PaneID> panes;
    for (const auto& pane : app().panes) {
        const PaneID id = paneIDForPane(pane.get());
        if (tree->holdsPane(static_cast<int>(id)))
            panes.push_back(id);
    }
    const bool isLastTab = app().model->tabCount(surface) <= 1;
    confirmClose(isLastTab ? Ubiquitty::Session::CloseScope::Window : Ubiquitty::Session::CloseScope::Tab, panes, [tab, isLastTab] {
        const Panes::Tree* closing = app().model->paneTree(app().model->activeSurface(), tab);
        if (!closing)
            return; // it ended on its own while the question was open
        if (isLastTab)
            app().isCloseConfirmed = true;
        closePaneTab(paneForID(static_cast<PaneID>(closing->focusedPaneID())));
    });
}

// Closes the focused pane the reader asked to close, asking first if it runs a
// job; a lone pane is its tab.
void closeFocusedPaneUX()
{
    const SurfaceID surface = app().model->activeSurface();
    const Panes::Tree* tree = app().model->paneTree(surface);
    if (!tree || tree->paneCount() <= 1) {
        closeTabUX(app().model->activeTab(surface));
        return;
    }
    const PaneID pane = paneIDForPane(activePane());
    confirmClose(Ubiquitty::Session::CloseScope::Pane, { pane }, [pane] {
        // The answer may come after focus has moved: the pane asked about is
        // the one closed, and only while it still is the focused one.
        if (paneIDForPane(activePane()) == pane)
            closeFocusedPaneNow();
    });
}

void closeFocusedPaneNow()
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

void updateNow()
{
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
    windowChildWatchAdd(processID, onUpdateApplyExited, nullptr);
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
    if (!app().window)
        return;
    if (status == S::UpdateAvailable) {
        Ubiquitty::Linux::GTK::ask(app().window,
            { .heading = updateResultHeading(status),
                .body = Ubiquitty::Linux::Updater::statusString(status),
                .acceptLabel = "_Update Now",
                .declineLabel = "_Later",
                .isAcceptTheDefault = true },
            inThisWindow(updateNow));
    } else {
        Ubiquitty::Linux::GTK::tell(app().window, updateResultHeading(status), Ubiquitty::Linux::Updater::statusString(status));
    }
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
    windowChildWatchAdd(processID, onUpdateCheckExited, nullptr);
}

void onAboutAction(GSimpleAction*, GVariant*, gpointer)
{
    if (!app().window)
        return;
    // libadwaita's About dialog, as every GNOME app shows its own.
    AdwDialog* about = adw_about_dialog_new();
    AdwAboutDialog* dialog = ADW_ABOUT_DIALOG(about);
    adw_about_dialog_set_application_name(dialog, "Ubiquitty");
    adw_about_dialog_set_application_icon(dialog, Ubiquitty::Linux::GTK::applicationIconName);
    adw_about_dialog_set_version(dialog, Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str());
    adw_about_dialog_set_comments(dialog, "A terminal emulator and persistent multiplexer");
    adw_about_dialog_set_developer_name(dialog, "Stanislav Yaglo");
    adw_about_dialog_set_website(dialog, "https://ubiquitty.org");
    adw_about_dialog_set_copyright(dialog, "Copyright © 2026 Stanislav Yaglo");
    adw_about_dialog_set_license_type(dialog, GTK_LICENSE_APACHE_2_0);
    adw_dialog_present(about, app().window);
}

// A new window of its own: the activation the desktop sends opens the same.
void openWindowApp(GtkApplication* gtkApplication, std::optional<Ubiquitty::Runtime::LaunchRequest> request, std::string directory, std::string windowApplicationID);

void newWindow()
{
    if (app().application)
        openWindowApp(app().application, std::nullopt, {}, {});
}

// A secondary click on the terminal opens its context menu where it was made.
// Copy is offered only while something is selected.
void onSecondaryPress(GtkGestureClick* gesture, gint, gdouble x, gdouble y, gpointer)
{
    if (!app().contextMenu || !app().window)
        return;
    if (GAction* copy = g_action_map_lookup_action(G_ACTION_MAP(app().window), "copy"))
        g_simple_action_set_enabled(G_SIMPLE_ACTION(copy), !selectionText().empty());
    const GdkRectangle point { static_cast<int>(x), static_cast<int>(y), 1, 1 };
    gtk_popover_set_pointing_to(GTK_POPOVER(app().contextMenu), &point);
    gtk_popover_popup(GTK_POPOVER(app().contextMenu));
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

// One menu item, with the built-in chord it answers to shown beside it. The
// chord is shown only: the terminal's key handler owns the keyboard.
void appendMenuItem(GMenu* menu, const char* label, const char* action, const char* shownAccelerator = nullptr)
{
    GMenuItem* item = g_menu_item_new(label, action);
    if (shownAccelerator)
        g_menu_item_set_attribute(item, "accel", "s", shownAccelerator);
    g_menu_append_item(menu, item);
    g_object_unref(item);
}

void appendMenuSection(GMenu* menu, GMenu* section)
{
    g_menu_append_section(menu, nullptr, G_MENU_MODEL(section));
    g_object_unref(section);
}

// The window's actions and the two menus that show them: the primary menu, laid
// out as the GNOME HIG lays one out (new things, the window's own commands, then
// the application's), and the terminal's context menu.
void installWindowMenus(GtkApplication*)
{
    static const GActionEntry entries[] = {
        { "new-window", +[](GSimpleAction*, GVariant*, gpointer) { newWindow(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "new-tab", +[](GSimpleAction*, GVariant*, gpointer) { newTab(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "split-right", +[](GSimpleAction*, GVariant*, gpointer) { splitFocusedPaneUX(Panes::Orientation::Vertical); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "split-down", +[](GSimpleAction*, GVariant*, gpointer) { splitFocusedPaneUX(Panes::Orientation::Horizontal); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "close-pane", +[](GSimpleAction*, GVariant*, gpointer) { closeFocusedPaneUX(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "copy", +[](GSimpleAction*, GVariant*, gpointer) { copySelectionUX(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "paste", +[](GSimpleAction*, GVariant*, gpointer) {
             if (app().window)
                 pasteClipboard(gtk_widget_get_clipboard(app().window), Ubiquitty::ClipboardBuffer::Clipboard); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "select-all", +[](GSimpleAction*, GVariant*, gpointer) { selectAll(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "find", +[](GSimpleAction*, GVariant*, gpointer) { showSearchBar(); }, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "check-update", onCheckUpdateAction, nullptr, nullptr, nullptr, { 0, 0, 0 } },
        { "about", onAboutAction, nullptr, nullptr, nullptr, { 0, 0, 0 } },
    };
    for (const auto& entry : entries) {
        GSimpleAction* action = g_simple_action_new(entry.name, nullptr);
        windowSignalConnect(action, "activate", G_CALLBACK(entry.activate), nullptr);
        g_action_map_add_action(G_ACTION_MAP(app().window), G_ACTION(action));
        g_object_unref(action);
    }
    installTabActions();

    GMenu* primary = g_menu_new();
    GMenu* create = g_menu_new();
    appendMenuItem(create, "_New Window", "win.new-window");
    appendMenuItem(create, "New _Tab", "win.new-tab", "<Control><Shift>t");
    appendMenuSection(primary, create);
    GMenu* panes = g_menu_new();
    appendMenuItem(panes, "Split _Right", "win.split-right", "<Control><Shift>e");
    appendMenuItem(panes, "Split _Down", "win.split-down", "<Control><Shift>d");
    appendMenuItem(panes, "C_lose Pane", "win.close-pane", "<Control><Shift>w");
    appendMenuSection(primary, panes);
    GMenu* find = g_menu_new();
    appendMenuItem(find, "_Find…", "win.find", "<Control><Shift>f");
    appendMenuSection(primary, find);
    GMenu* application = g_menu_new();
    appendMenuItem(application, "Check for _Updates…", "win.check-update");
    appendMenuItem(application, "_About Ubiquitty", "win.about");
    appendMenuSection(primary, application);

    GMenu* context = g_menu_new();
    GMenu* edit = g_menu_new();
    appendMenuItem(edit, "_Copy", "win.copy", "<Control><Shift>c");
    appendMenuItem(edit, "_Paste", "win.paste", "<Control><Shift>v");
    appendMenuItem(edit, "Select _All", "win.select-all", "<Control><Shift>a");
    appendMenuSection(context, edit);
    GMenu* contextPanes = g_menu_new();
    appendMenuItem(contextPanes, "Split _Right", "win.split-right", "<Control><Shift>e");
    appendMenuItem(contextPanes, "Split _Down", "win.split-down", "<Control><Shift>d");
    appendMenuSection(context, contextPanes);
    GMenu* contextFind = g_menu_new();
    appendMenuItem(contextFind, "_Find…", "win.find", "<Control><Shift>f");
    appendMenuSection(context, contextFind);
    GMenu* contextClose = g_menu_new();
    appendMenuItem(contextClose, "C_lose Pane", "win.close-pane", "<Control><Shift>w");
    appendMenuSection(context, contextClose);

    // A closed menu gives the keyboard back to the find bar when it is open,
    // and to the terminal otherwise.
    const auto refocus = G_CALLBACK(+[](GtkPopover*, gpointer) {
        if (app().searchBar && gtk_search_bar_get_search_mode(GTK_SEARCH_BAR(app().searchBar)))
            gtk_widget_grab_focus(app().searchEntry);
        else if (app().window)
            gtk_window_set_focus(GTK_WINDOW(app().window), nullptr); // the terminal has the keys while nothing else does
    });
    if (app().chrome) {
        app().chrome->setMenuModel(G_MENU_MODEL(primary));
        windowSignalConnect(gtk_menu_button_get_popover(app().chrome->menuButton()), "closed", refocus, nullptr);
    }
    g_object_unref(primary);

    app().contextMenu = gtk_popover_menu_new_from_model(G_MENU_MODEL(context));
    g_object_unref(context);
    gtk_popover_set_has_arrow(GTK_POPOVER(app().contextMenu), FALSE);
    gtk_widget_set_halign(app().contextMenu, GTK_ALIGN_START);
    gtk_widget_set_parent(app().contextMenu, app().window);
    windowSignalConnect(app().contextMenu, "closed", refocus, nullptr);

    GtkGesture* click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_SECONDARY);
    windowSignalConnect(click, "pressed", G_CALLBACK(onSecondaryPress), nullptr);
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

void discardPendingClipboardRead(gpointer data)
{
    std::unique_ptr<PendingClipboardRead> pending(static_cast<PendingClipboardRead*>(data));
    completePendingClipboardRead(pending.get(), false);
    if (pending->itemStream)
        g_input_stream_close(pending->itemStream, nullptr, nullptr);
    g_clear_object(&pending->itemStream);
    g_clear_object(&pending->sourceClipboard);
}

// Stage an approved internal-buffer read + complete the query (defined below).
void approveInternalBufferRead(PendingClipboardRead* pending);

// Publishes the complete capture before resolving the pending read.
void stageCapturedClipboardAndComplete(PendingClipboardRead* pending)
{
    if (!pending->requester.get()) {
        g_clear_object(&pending->sourceClipboard);
        delete pending;
        return;
    }
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
            G_PRIORITY_DEFAULT, nullptr, onWindowAsyncReady, windowAsyncData(onClipboardItemChunk, pending, discardPendingClipboardRead));
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
        G_PRIORITY_DEFAULT, nullptr, onWindowAsyncReady, windowAsyncData(onClipboardItemChunk, pending, discardPendingClipboardRead));
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
    gdk_clipboard_read_async(pending->sourceClipboard, types, G_PRIORITY_DEFAULT, nullptr, onWindowAsyncReady, windowAsyncData(onClipboardItemOpened, pending, discardPendingClipboardRead));
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
void clipboardReadAnswered(PendingClipboardRead* pending, bool isAllowed) // bool-ok: the reader's one answer
{
    if (isAllowed && app().window) {
        if (pending->buffer == Ubiquitty::ClipboardBuffer::Clipboard || pending->buffer == Ubiquitty::ClipboardBuffer::Primary)
            gdk_clipboard_read_text_async(pending->buffer == Ubiquitty::ClipboardBuffer::Primary
                    ? gtk_widget_get_primary_clipboard(app().window)
                    : gtk_widget_get_clipboard(app().window),
                nullptr, onWindowAsyncReady, windowAsyncData(onClipboardReadForOSC52, pending, discardPendingClipboardRead));
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
    if (!pending->requester.get()) {
        delete pending;
        return;
    }
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
                nullptr, onWindowAsyncReady, windowAsyncData(onClipboardReadForOSC52, pending, discardPendingClipboardRead));
        else
            approveInternalBufferRead(pending);
        return;
    }
    // Deny is the default and what Escape picks: the program asked, the reader
    // did not, and a dismissed question gives nothing away.
    Ubiquitty::Linux::GTK::ask(app().window,
        { .heading = "Allow Clipboard Access?",
            .body = "A program in the terminal wants to read the clipboard.",
            .acceptLabel = "_Allow",
            .declineLabel = "_Deny" },
        inThisWindow([pending] { clipboardReadAnswered(pending, true); }),
        inThisWindow([pending] { clipboardReadAnswered(pending, false); }));
}

struct PendingClipboardPost {
    std::shared_ptr<App> owner;
    PendingClipboardRead* read;
};

gboolean onClipboardReadDue(gpointer data)
{
    auto& post = *static_cast<PendingClipboardPost*>(data);
    AppScope scope(*post.owner);
    PendingClipboardRead* read = std::exchange(post.read, nullptr);
    if (app().isClosing)
        discardPendingClipboardRead(read);
    else
        beginClipboardRead(read);
    return G_SOURCE_REMOVE;
}

void discardClipboardPost(gpointer data)
{
    std::unique_ptr<PendingClipboardPost> post(static_cast<PendingClipboardPost*>(data));
    AppScope scope(*post->owner);
    if (post->read)
        discardPendingClipboardRead(post->read);
}

// The parser's ask, on its own thread: the request is recorded with a weak
// reference to the asking pane and carried to the UI thread, where GTK may
// be called. Inline when this is that thread — the headless entries — where
// a run without a window declines so Core drops the query cleanly.
bool requestClipboardReadFromGTK(Ubiquitty::Linux::LinuxClipboardClient* client, void* requester, Ubiquitty::ClipboardBuffer buffer, std::string_view setSpec, Ubiquitty::ClipboardReadConfirmation confirmation)
{
    auto* pane = static_cast<LinuxPane*>(requester);
    if (!pane || !pane->ownerApp)
        return false;
    AppScope scope(*pane->ownerApp);
    if (client->isOnUIThread() && (app().isClosing || !app().window))
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
        g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, onClipboardReadDue,
            new PendingClipboardPost { app().shared_from_this(), pending }, discardClipboardPost);
    return true;
}

void openWindowApp(GtkApplication* gtkApplication, std::optional<Ubiquitty::Runtime::LaunchRequest> request, std::string directory, std::string windowApplicationID = {})
{
    App& owner = createWindowApp();
    AppScope scope(owner);
    owner.launchRequest = std::move(request);
    owner.launchDirectory = std::move(directory);
    owner.windowApplicationID = std::move(windowApplicationID);
    app().application = gtkApplication; // for g_application_send_notification (the unfocused-bell notify)
    app().fontDPI = displayFontDPI();
    readToolkitCaretSettings();
    if (!defaultApp().configurationWatcher.start()) {
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
    configureSharedGlyphRenderer(app().vulkan);
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
        const int launchTheme = selectedThemeIndex(config);
        if (launchTheme >= 0) {
            app().liveThemeIndex = launchTheme;
            app().liveThemeName = Ubiquitty::Themes::get(launchTheme)->name;
            app().configuredThemeName = app().liveThemeName;
            app().appliedThemePalette = Ubiquitty::Themes::get(launchTheme)->serializeTOML();
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
    // libadwaita styles every window this process opens; adw_init is idempotent.
    adw_init();
    Ubiquitty::Linux::GTK::registerApplicationIcon(gdk_display_get_default());
    app().window = adw_application_window_new(gtkApplication);
    g_object_set_data(G_OBJECT(app().window), "ubiquitty-window-state", &app());
    windowLifecycleSignalConnect(app().window, "close-request", G_CALLBACK(onWindowCloseRequested), nullptr);
    windowLifecycleSignalConnect(app().window, "unrealize", G_CALLBACK(onWindowUnrealized), nullptr);
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
    // The toplevel maps before its children. Its map callback cannot install
    // our clock until this container maps, including when the child program
    // is silent and never supplies an output delivery to wake the first tick.
    windowSignalConnect(app().paneContainer, "map", G_CALLBACK(+[](GtkWidget*, gpointer) {
        requestRepaint();
    }),
        nullptr);
    gtk_box_append(GTK_BOX(app().paneContainer), activePane()->picture);

    // Open at exactly the launch grid: pin the focused pane picture's natural
    // size to it so the window sizes itself around its internally padded
    // drawable and CSD titlebar. The pin is relaxed on first map so the user can
    // still resize the window smaller afterward.
    const auto launchExtent = Ubiquitty::Rendering::viewportForGrid(
        { activePane()->columns, activePane()->rows },
        { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) },
        paneInsets(*activePane(), static_cast<float>(app().scale)), 0);
    gtk_widget_set_size_request(activePane()->picture,
        static_cast<int>(std::ceil(launchExtent.width / app().scale)), static_cast<int>(std::ceil(launchExtent.height / app().scale)));
    windowSignalConnect(app().window, "map", G_CALLBACK(onWindowMappedRelaxSize), nullptr);
    windowSignalConnect(app().window, "unmap", G_CALLBACK(onWindowUnmapped), nullptr);
    windowSignalConnect(app().window, "realize", G_CALLBACK(onWindowRealized), nullptr);
    // HiDPI: re-rasterize at the device cell when the window lands on (or moves to)
    // a scaled monitor — the initial map on a HiDPI display fires this 1 -> N.
    windowSignalConnect(app().window, "notify::scale-factor", G_CALLBACK(onScaleFactorChanged), nullptr);
    if (GtkSettings* settings = gtk_widget_get_settings(app().window)) {
        windowSignalConnectObject(settings, "notify::gtk-xft-dpi", G_CALLBACK(onScaleFactorChanged), app().window, G_CONNECT_DEFAULT);
        windowSignalConnectObject(settings, "notify::gtk-fontconfig-timestamp", G_CALLBACK(+[](GObject*, GParamSpec*, gpointer) {
            rebuildFontsFromPreferences();
            for (const auto& pane : app().panes) {
                pane->richText.invalidateFonts();
                publishPaneTypography(*pane);
            }
            requestRepaint(); }), app().window, G_CONNECT_DEFAULT);
        windowSignalConnectObject(settings, "notify", G_CALLBACK(+[](GObject*, GParamSpec* property, gpointer) {
            const std::string_view name(g_param_spec_get_name(property));
            if (name == "gtk-theme-name" || name == "gtk-application-prefer-dark-theme") {
                windowIdleAddFull(G_PRIORITY_DEFAULT_IDLE, +[](gpointer) -> gboolean {
                    refreshNativeLinkAccentColor();
                    // A stock titlebar's ground follows the toolkit theme.
                    if (app().chrome)
                        app().chrome->refreshGround();
                    return G_SOURCE_REMOVE;
                }, nullptr, nullptr);
            }
            // The caret's settings all share GtkSettings' gtk-cursor- prefix.
            if (!name.starts_with("gtk-cursor-"))
                return;
            readToolkitCaretSettings();
            for (const auto& pane : app().panes)
                pane->captureConfiguration.reset();
            restartCaretBlink(false); }), app().window, G_CONNECT_DEFAULT);
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
    windowSignalConnect(app().searchEntry, "search-changed", G_CALLBACK(onSearchChanged), nullptr);
    windowSignalConnect(app().searchEntry, "activate", G_CALLBACK(onSearchActivate), nullptr);
    windowSignalConnect(app().searchEntry, "next-match", G_CALLBACK(onSearchNext), nullptr);
    windowSignalConnect(app().searchEntry, "previous-match", G_CALLBACK(onSearchPrevious), nullptr);
    windowSignalConnect(app().searchEntry, "stop-search", G_CALLBACK(onSearchStop), nullptr);

    rebuildTabStrip();
    GtkWidget* layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    // The find bar sits in the chrome's top bar, under the tabs; a chromeless
    // window keeps it over the panes.
    if (UBIQUITTY_LINUX_CHROMELESS)
        gtk_box_append(GTK_BOX(layout), app().searchBar);
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
    windowDrawingAreaSetDrawFunc(GTK_DRAWING_AREA(app().progressBar), drawProgressBar, nullptr, nullptr);
    gtk_overlay_add_overlay(GTK_OVERLAY(paneOverlay), app().progressBar);
    gtk_overlay_set_measure_overlay(GTK_OVERLAY(paneOverlay), app().progressBar, FALSE);
    app().scrollIndicator = gtk_drawing_area_new();
    gtk_widget_set_halign(app().scrollIndicator, GTK_ALIGN_FILL);
    gtk_widget_set_valign(app().scrollIndicator, GTK_ALIGN_FILL);
    gtk_widget_set_can_target(app().scrollIndicator, FALSE);
    gtk_widget_set_visible(app().scrollIndicator, FALSE);
    windowDrawingAreaSetDrawFunc(GTK_DRAWING_AREA(app().scrollIndicator), drawScrollIndicator, nullptr, nullptr);
    gtk_overlay_add_overlay(GTK_OVERLAY(paneOverlay), app().scrollIndicator);
    gtk_overlay_set_measure_overlay(GTK_OVERLAY(paneOverlay), app().scrollIndicator, FALSE);
    gtk_box_append(GTK_BOX(layout), paneOverlay);
    // Under the panes, hidden until the configuration has a line to show; the
    // startup configure above has already left one if the file holds an error.
    gtk_box_append(GTK_BOX(layout), makeConfigurationBar());
    // GNOME's chrome, from libadwaita: the header, the tabs and the find bar in
    // a raised top bar over the panes. A chromeless build draws none of it.
    if (UBIQUITTY_LINUX_CHROMELESS) {
        adw_application_window_set_content(ADW_APPLICATION_WINDOW(app().window), layout);
    } else {
        app().chrome = std::make_unique<Ubiquitty::Linux::GTK::WindowChrome>(layout, app().searchBar);
        app().chrome->attach(GTK_WINDOW(app().window));
        adw_application_window_set_content(ADW_APPLICATION_WINDOW(app().window), app().chrome->widget());
    }

    // Window transparency for background_opacity < 1: the rendered texture already
    // carries the background alpha, so the window + its widgets just need a transparent
    // background-color for the compositor to blend the desktop through. Best-effort
    // — the see-through depends on a compositing WM (Wayland / X11 compositor).
    const int themeIndex = selectedThemeIndex(config);
    applyChromeTheme(themeIndex);
    // The desktop's light or dark style, as libadwaita reads it from the
    // settings portal: the reader who follows it gets the theme for it.
    windowSignalConnectObject(adw_style_manager_get_default(), "notify::dark", G_CALLBACK(onSystemAppearanceChanged), app().window, G_CONNECT_DEFAULT);
    // A new accent recolours the focused selection: every pane's next frame
    // re-registers its capture geometry with it.
    windowSignalConnectObject(adw_style_manager_get_default(), "notify::accent-color", G_CALLBACK(+[](AdwStyleManager*, GParamSpec*, gpointer) {
        requestRepaint();
    }),
        app().window, G_CONNECT_DEFAULT);

    GtkEventController* keys = gtk_event_controller_key_new();
    // Capture phase: the terminal sees a key before a focused chrome widget
    // can take Return or Space for itself. The input method is still filtered
    // explicitly inside the handler.
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    windowSignalConnect(keys, "key-pressed", G_CALLBACK(onKeyPressed), nullptr);
    // key-released forwards bare-modifier releases under Kitty REPORT_ALL +
    // REPORT_EVENTS (the shared symbol drops it otherwise); parity with macOS.
    windowSignalConnect(keys, "key-released", G_CALLBACK(onKeyReleased), nullptr);
    gtk_widget_add_controller(app().window, keys);

    // Input method (dead keys / compose / CJK), parity with macOS. onKeyPressed
    // routes each key through filter_keypress; the IM emits the inline preedit
    // and the final "commit". Manual filtering (not set_im_context) so the gtkApplication
    // accelerators above keep priority and the commit path stays explicit.
    app().imContext = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(app().imContext, app().window);
    windowSignalConnect(app().imContext, "commit", G_CALLBACK(onIMCommit), nullptr);
    windowSignalConnect(app().imContext, "preedit-changed", G_CALLBACK(onIMPreeditChanged), nullptr);
    windowSignalConnect(app().imContext, "preedit-end", G_CALLBACK(onIMPreeditEnd), nullptr);

    // Focus reporting (DECSET 1004): drive Core's windowFocused on every
    // window focus transition. setFocused always runs — Core gates the CSI I /
    // CSI O emission on the gtkApplication having enabled focus reporting, and otherwise
    // just records the state (read by bellWantsNotification for the unfocused
    // bell). The unfocused/hollow cursor look is an overlay concern.
    GtkEventController* focus = gtk_event_controller_focus_new();
    windowSignalConnect(focus, "enter", G_CALLBACK(onFocusEnter), nullptr);
    windowSignalConnect(focus, "leave", G_CALLBACK(onFocusLeave), nullptr);
    gtk_widget_add_controller(app().window, focus);
    // The pointer-lock focus fact's other half: window activation can change
    // with no focus-in/out edge of its own (another app's window comes
    // forward over this one).
    windowSignalConnect(app().window, "notify::"
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
    windowTimeoutAdd(750, onTitleRefresh, nullptr);
    // Refresh the process inspector's tree while it's open.
    windowTimeoutAdd(1000, onInspectorRefresh, nullptr);

    installWindowMenus(gtkApplication);
    rebuildTabStrip();
    updateWindowTitle();

    gtk_window_set_decorated(GTK_WINDOW(app().window), !UBIQUITTY_LINUX_CHROMELESS);
    gtk_window_present(GTK_WINDOW(app().window));
    // An AppImage run lists itself among the desktop's apps, with its icon.
    Ubiquitty::Linux::GTK::integrateWithDesktop(app().window);
}

// Activations from app actions and the desktop open a normal login window;
// commands belong only to the invocation that explicitly supplied them.
void onActivate(GtkApplication* application, gpointer)
{
    openWindowApp(application, std::nullopt, {});
}

int openWindowFromArguments(GtkApplication* application, int argc, const char* const* argv, const char* directory)
{
    auto request = Ubiquitty::Runtime::parseLaunchArguments(argc, argv);
    if (request.status == Ubiquitty::Runtime::LaunchRequest::Status::Error)
        return 2;
    openWindowApp(application, std::move(request), directory ? directory : "");
    return 0;
}

Ubiquitty::Runtime::LaunchRequest launchRequestFromCommandLine(GApplicationCommandLine* commandLine)
{
    int argc = 0;
    char** arguments = g_application_command_line_get_arguments(commandLine, &argc);
    // GtkApplication consumes its separator while parsing its own options.
    // Carry child argv in a typed option array, so literal child --/-e/options
    // remain data and cannot be confused with that consumed separator.
    GVariant* child = g_variant_dict_lookup_value(g_application_command_line_get_options_dict(commandLine),
        "ubiquitty-exec", G_VARIANT_TYPE_STRING_ARRAY);
    std::vector<const char*> launchArguments;
    const gchar** childArguments = nullptr;
    if (child) {
        gsize count = 0;
        childArguments = g_variant_get_strv(child, &count);
        launchArguments = { argc > 0 ? arguments[0] : "ubiquitty", "--" };
        for (gsize index = 0; index < count; ++index)
            launchArguments.push_back(childArguments[index]);
    } else {
        for (int index = 0; index < argc; ++index)
            launchArguments.push_back(arguments[index]);
    }
    auto request = Ubiquitty::Runtime::parseLaunchArguments(static_cast<int>(launchArguments.size()), launchArguments.data());
    g_free(childArguments);
    if (child)
        g_variant_unref(child);
    g_strfreev(arguments);
    return request;
}

// Wayland app IDs are window metadata; the process keeps its fixed D-Bus ID.
bool isValidWindowApplicationID(std::string_view value)
{
    return !value.empty() && value.size() <= 255 && std::ranges::all_of(value, [](unsigned char character) {
        return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
            || (character >= '0' && character <= '9') || character == '.' || character == '_' || character == '-';
    });
}

std::expected<std::string, std::string> windowApplicationIDFromArguments(int argc, const char* const* argv)
{
    std::string result;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--app-id") {
            if (++index >= argc)
                return std::unexpected("--app-id needs a value");
            result = argv[index];
        } else if (argument.starts_with("--app-id=")) {
            result = argument.substr(9);
        } else {
            continue;
        }
        if (!isValidWindowApplicationID(result))
            return std::unexpected("--app-id needs a nonempty identifier using letters, digits, dots, underscores or hyphens");
    }
    return result;
}

void registerLaunchOptions(GApplication* application)
{
    g_application_add_main_option(application, "app-id", 0, G_OPTION_FLAG_NONE, G_OPTION_ARG_STRING, "Window application ID", "ID");
    g_application_add_main_option(application, "ubiquitty-exec", 0,
        G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_STRING_ARRAY, "Child argument", nullptr);
}

int onApplicationCommandLine(GApplication* application, GApplicationCommandLine* commandLine, gpointer)
{
    auto request = launchRequestFromCommandLine(commandLine);
    if (request.status == Ubiquitty::Runtime::LaunchRequest::Status::Error) {
        g_application_command_line_printerr(commandLine, "ubiquitty: %s\n", request.error.c_str());
        return 2;
    }
    const char* directory = g_application_command_line_get_cwd(commandLine);
    const char* windowApplicationID = nullptr;
    g_variant_dict_lookup(g_application_command_line_get_options_dict(commandLine), "app-id", "&s", &windowApplicationID);
    if (windowApplicationID && !isValidWindowApplicationID(windowApplicationID)) {
        g_application_command_line_printerr(commandLine, "ubiquitty: invalid --app-id\n");
        return 2;
    }
    openWindowApp(GTK_APPLICATION(application), std::move(request), directory ? directory : "", windowApplicationID ? windowApplicationID : "");
    return 0;
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

#include "Platform/Linux/Smokes/BufferGrowthSmoke.h"

#include "Platform/Linux/Smokes/RichCaptureSmoke.h"

#include "Platform/Linux/Smokes/CursorAlphaSmoke.h"

#include "Platform/Linux/Smokes/ScrollIndicatorSmoke.h"

#include "Platform/Linux/Smokes/CursorPresentationSmoke.h"

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

#include "Platform/Linux/Smokes/GTKCaretSmoke.h"

#include "Platform/Linux/Smokes/GlyphPrefixStabilitySmoke.h"

#include "Platform/Linux/Smokes/CapturedRetainedFramesSmoke.h"

#include "Platform/Linux/Smokes/TrackedGlyphPrefixesSmoke.h"

#include "Platform/Linux/Smokes/CursorSmoke.h"

#include "Platform/Linux/Smokes/FontSettingsSmoke.h"

#include "Platform/Linux/Smokes/LigatureSheetSmoke.h"

#include "Platform/Linux/Smokes/ProportionalStripSmoke.h"

#include "Platform/Linux/Smokes/OversizedGridSmoke.h"

#include "Platform/Linux/Smokes/DmabufImportFailureSmoke.h"

#include "Platform/Linux/Smokes/ProportionalAtlasSmoke.h"

#include "Platform/Linux/Smokes/DoubledRunSmoke.h"

#include "Platform/Linux/Smokes/ScriptGlyphsSmoke.h"

#include "Platform/Linux/Smokes/FileReadSmoke.h"

#include "Platform/Linux/Smokes/TriggerSmoke.h"

#include "Platform/Linux/Smokes/LigatureShapingSmoke.h"

#include "Platform/Linux/Smokes/LigatureRenderSmoke.h"

#include "Platform/Linux/Smokes/GridCacheSmoke.h"

#include "Platform/Linux/Smokes/GridCacheStressSmoke.h"

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

#include "Platform/Linux/Smokes/NerdFontSmoke.h"

#include "Platform/Linux/Smokes/SizedGPUSmoke.h"

#include "Platform/Linux/Smokes/ShadeGPUSmoke.h"

#include "Platform/Linux/Smokes/NerdFontRenderSmoke.h"

#include "Platform/Linux/Smokes/VulkanClearSmoke.h"

#include "Platform/Linux/Smokes/GridSmoke.h"

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

#include "Platform/Linux/Smokes/InputSmoke.h"

#include "Platform/Linux/Smokes/FontToggleSmoke.h"

#include "Platform/Linux/Smokes/MouseSmoke.h"

#include "Platform/Linux/Smokes/TitleSmoke.h"

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

#include "Platform/Linux/Smokes/ScrollbackSmoke.h"

#include "Platform/Linux/Smokes/SelectionSmoke.h"

#include "Platform/Linux/Smokes/ScaledRunSelectionSmoke.h"

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

#include "Platform/Linux/Smokes/PasteSmoke.h"

#include "Platform/Linux/Smokes/OSC52Smoke.h"

#include "Platform/Linux/Smokes/OSC7Smoke.h"

#include "Platform/Linux/Smokes/CapabilityOriginSmoke.h"

#include "Platform/Linux/Smokes/FocusSmoke.h"

#include "Platform/Linux/Smokes/PointerLockSmoke.h"

#include "Platform/Linux/Smokes/LinkSmoke.h"

#include "Platform/Linux/Smokes/IMESmoke.h"

#include "Platform/Linux/Smokes/ComposeSmoke.h"

#include "Platform/Linux/Smokes/FindSmoke.h"

#include "Platform/Linux/Smokes/RectSelectionSmoke.h"

#include "Platform/Linux/Smokes/SmartClickSmoke.h"

#include "Platform/Linux/Smokes/StatusTitleSmoke.h"

#include "Platform/Linux/Smokes/TitleBuildSmoke.h"

#include "Platform/Linux/Smokes/InspectorSmoke.h"

#include "Platform/Linux/Smokes/ImageSmoke.h"

#include "Platform/Linux/Smokes/ImageStampSmoke.h"

// The inline-image CPU<->GPU oracle: renders `term` through the CPU
// SoftwareRenderer and through the Vulkan image pass and asserts the two PNGs
// are BYTE-IDENTICAL (sha256), or that no channel of any pixel differs by more
// than `toleratedChannelDelta` when that is above zero. Leaves /tmp/<name>.png
// (GPU) and /tmp/<name>-cpu.png on disk; prints both shas + PASS/FAIL (and the
// pixel-diff magnitude on a mismatch).
static int compareImageOracle(const char* name, Ubiquitty::Terminal* term, int toleratedChannelDelta = 0)
{
    std::vector<uint8_t> cpuRGBA;
    int cpuWidth = 0, cpuHeight = 0;
    if (!app().rasterContext.rasterizeTerm(term, cpuRGBA, cpuWidth, cpuHeight, 0, nullptr, nullptr)) {
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

    if (cpuWidth != widthVk || cpuHeight != heightVk) {
        g_printerr("%s: size mismatch CPU %dx%d vs GPU %dx%d\n", name, cpuWidth, cpuHeight, widthVk, heightVk);
        return 1;
    }

    const std::vector<uint8_t> cpuPNG = Ubiquitty::Rendering::encodePNG(cpuRGBA, { cpuWidth, cpuHeight });
    const std::vector<uint8_t> pngVk = Ubiquitty::Rendering::encodePNG(rgbaVk, { widthVk, heightVk });
    const std::string gpuPath = std::string("/tmp/") + name + ".png";
    const std::string cpuPath = std::string("/tmp/") + name + "-cpu.png";
    if (FILE* f = std::fopen(gpuPath.c_str(), "wb")) {
        std::fwrite(pngVk.data(), 1, pngVk.size(), f);
        std::fclose(f);
        g_print("%s: wrote %s (%dx%d)\n", name, gpuPath.c_str(), widthVk, heightVk);
    }
    if (FILE* f = std::fopen(cpuPath.c_str(), "wb")) {
        std::fwrite(cpuPNG.data(), 1, cpuPNG.size(), f);
        std::fclose(f);
    }

    char* cpuSHA256 = g_compute_checksum_for_data(G_CHECKSUM_SHA256, cpuPNG.data(), cpuPNG.size());
    char* shaVk = g_compute_checksum_for_data(G_CHECKSUM_SHA256, pngVk.data(), pngVk.size());
    g_print("%s: CPU sha256 = %s\n", name, cpuSHA256);
    g_print("%s: GPU sha256 = %s\n", name, shaVk);
    const bool identical = (cpuPNG.size() == pngVk.size()) && g_strcmp0(cpuSHA256, shaVk) == 0;
    g_free(cpuSHA256);
    g_free(shaVk);

    bool isWithinTolerance = identical;
    if (!identical) {
        // Report the magnitude of the RGBA divergence to aid diagnosis.
        std::size_t differing = 0;
        int maxDelta = 0;
        const std::size_t n = (cpuRGBA.size() < rgbaVk.size()) ? cpuRGBA.size() : rgbaVk.size();
        for (std::size_t i = 0; i < n; ++i) {
            const int delta = std::abs(static_cast<int>(cpuRGBA[i]) - static_cast<int>(rgbaVk[i]));
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

#include "Platform/Linux/Smokes/ImageVulkanSmoke.h"

#include "Platform/Linux/Smokes/ImageVulkanFilteredSmoke.h"

#include "Platform/Linux/Smokes/ImageVulkanPlaceholdersSmoke.h"

#include "Platform/Linux/Smokes/ImageVulkanUnderTextSmoke.h"

#include "Platform/Linux/Smokes/WeightSmoke.h"

#include "Platform/Linux/Smokes/OpacitySmoke.h"

#include "Platform/Linux/Smokes/BackgroundImageSmoke.h"

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

#include "Platform/Linux/Smokes/BeamSmoke.h"

#include "Platform/Linux/Smokes/LaunchForwardingSmoke.h"

#include "Platform/Linux/Smokes/MultiwindowSmoke.h"

#include "Platform/Linux/Smokes/SharedGlyphCacheSmoke.h"

#include "Platform/Linux/Smokes/WindowChromeSmoke.h"

#include "Platform/Linux/Smokes/TabsSmoke.h"

#include "Platform/Linux/Smokes/PacingSmoke.h"

#include "Platform/Linux/Smokes/SplitsSmoke.h"

#include "Platform/Linux/Smokes/ClearSmoke.h"

#include "Platform/Linux/Smokes/FontZoomSmoke.h"

#include "Platform/Linux/Smokes/PromptNavigationSmoke.h"

#include "Platform/Linux/Smokes/SelectAllSmoke.h"

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

#include "Platform/Linux/Smokes/PixelGeometrySmoke.h"

#include "Platform/Linux/Smokes/ConfigurationWiringSmoke.h"

#include "Platform/Linux/Smokes/ConfigurationErrorSmoke.h"

void applyConfigurationToWindows()
{
    // Custom indices can move when a document adds or removes palettes. Each
    // window retains names, so rebuilding once cannot change its chosen theme.
    Ubiquitty::Themes::registerThemesFromValues(Ubiquitty::Preferences::values());
    if (windowApps().windows.empty()) {
        AppScope scope(defaultApp());
        applyLiveConfiguration();
        return;
    }
    const auto windows = windowApps().windows;
    for (const auto& owner : windows) {
        if (owner->isClosing)
            continue;
        AppScope scope(*owner);
        applyLiveConfiguration();
    }
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
    const auto windowApplicationID = windowApplicationIDFromArguments(terminalArgc, argv);
    if (!windowApplicationID) {
        g_printerr("ubiquitty: %s\n", windowApplicationID.error().c_str());
        return 2;
    }
    app().launchRequest = launchRequest;

    std::string_view mode = (terminalArgc > 1) ? std::string_view(argv[1]) : std::string_view {};
    const char* arg2 = (terminalArgc > 2) ? argv[2] : nullptr;

    // Every configure reaches the window, or the headless pane a mode drives,
    // through this one subscription.
    app().configurationSubscription.emplace(Ubiquitty::Preferences::ConfigurationSubscription::notifying(applyConfigurationToWindows));

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
    if (mode == "--smoke-frame-paintable")
        return smokeFramePaintable();
    if (mode == "--snapshot")
        return runSnapshot(argc, argv);
    if (mode == "--version") {
        g_print("ubiquitty %s\n", Ubiquitty::Protocol::Sync::appVersionWithIdentity().c_str());
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
    if (mode == "--smoke-padding")
        return Ubiquitty::Linux::Diagnostics::smokePadding();
    if (mode == "--smoke-skip-ink")
        return Ubiquitty::Linux::Diagnostics::smokeSkipInk();
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
    if (mode == "--smoke-launch-forwarding")
        return smokeLaunchForwarding();
    if (mode == "--smoke-shared-glyph-cache")
        return smokeSharedGlyphCache();
    if (mode == "--smoke-multiwindow")
        return smokeMultiwindow();
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

    GtkApplication* gtkApplication = gtk_application_new("org.ubiquitty.linux", G_APPLICATION_HANDLES_COMMAND_LINE);
    registerLaunchOptions(G_APPLICATION(gtkApplication));
    windowSignalConnect(gtkApplication, "activate", G_CALLBACK(onActivate), nullptr);
    g_signal_connect(gtkApplication, "command-line", G_CALLBACK(onApplicationCommandLine), nullptr);
    // GApplication forwards the typed child-argument array and this caller's
    // working directory to the primary. Equals keeps even an option-looking
    // child argument inside its value, independently of GTK option parsing.
    std::vector<std::string> forwardedArguments { argv[0] };
    if (!windowApplicationID->empty())
        forwardedArguments.push_back("--app-id=" + *windowApplicationID);
    if (launchRequest.status == Ubiquitty::Runtime::LaunchRequest::Status::Command) {
        for (const auto& argument : launchRequest.command)
            forwardedArguments.push_back("--ubiquitty-exec=" + argument);
    }
    std::vector<char*> forwardedArgv;
    for (auto& argument : forwardedArguments)
        forwardedArgv.push_back(argument.data());
    forwardedArgv.push_back(nullptr);
    const int status = g_application_run(G_APPLICATION(gtkApplication), static_cast<int>(forwardedArguments.size()), forwardedArgv.data());
    defaultApp().configurationWatcher.stop();
    const auto windows = windowApps().windows;
    for (const auto& owner : windows) {
        GtkWidget* window = owner->window;
        closeWindowApp(*owner);
        if (window)
            gtk_window_destroy(GTK_WINDOW(window));
    }
    windowApps().windows.clear();
    g_object_unref(gtkApplication);
    return status;
}
