// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once
//
// Source/Platform/Web/WebTerminal.h — the browser frontend's terminal, in
// portable C++ carrying no emscripten type.
//
// Every decision the browser frontend makes lives here; the wasm export shim
// converts pointers and lengths and nothing else. That split is what lets a
// ctest drive the whole frontend without a browser, which is the only way its
// behaviour is checked before a user meets it.
//
// Nothing here computes colour, coverage or layout. Pixels come from
// `Rendering::renderTerminalSnapshotRGBA` and instances from
// `buildCellInstances`, both shared with every other frontend; a second paint
// model in JavaScript would drift from them the first time either changed.

#include "Core/Clipboard/Scope.h"
#include "Core/Codec/JSON.h"
#include "Core/CommandPalette/BeamSession.h"
#include "Core/Input/Keybindings.h"
#include "Core/Input/PointerInput.h"
#include "Core/Input/PointerLadder.h"
#include "Core/Input/PointerShape.h"
#include "Core/Keys/KeyEvent.h"
#include "Core/ModelLock.h"
#include "Core/OSC/Notification.h"
#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Preferences/PreferencesDefaults.h"
#include "Core/Protocol/Control/PasteUpload.h"
#include "Core/Protocol/Sync/AttachVerdictText.h"
#include "Core/Protocol/Sync/HistoryPull.h"
#include "Core/Protocol/Sync/SyncClientCore.h"
#include "Core/Rendering/BackgroundImage.h"
#include "Core/Rendering/BeamLayout.h"
#include "Core/Rendering/BoxDrawingRasterizer.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Rendering/HintToastLayout.h"
#include "Core/Rendering/PaddingGeometry.h"
#include "Core/Rendering/RemoteViewport.h"
#include "Core/Rendering/RenderConfiguration.h"
#include "Core/Rendering/SoftwareRenderer.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/Rendering/TerminalSnapshot.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Core/Runtime/HostOutline.h"
#include "Core/Runtime/RemoteInput.h"
#include "Core/Runtime/StructureCalls.h"
#include "Core/Runtime/TerminalSnapshots.h"
#include "Core/Screen/ScrollTuning.h"
#include "Core/Screen/VisibleLink.h"
#include "Core/Search/SearchController.h"
#include "Core/Search/SearchExecutor.h"
#include "Core/Selection/Selection.h"
#include "Core/Selection/TerminalSelection.h"
#include "Core/Session/HostListing.h"
#include "Core/Session/InputInDoubtNotice.h"
#include "Core/Session/RememberedSessions.h"
#include "Core/Session/ResumeRecordFormat.h"
#include "Core/TerminalOperations.h"
#include "PAL/TerminalClients.h"
#include "Platform/Web/WebCapabilityPolicy.h"
#include "Platform/Web/WebFontRasterizer.h"
#include "Platform/Web/WebRichText.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Ubiquitty::Web {

/// A terminal sized in cells, rendered to an RGBA8 image the embedder blits.
/// All methods run on its owning event loop, including pumped search slices.
class WebTerminal {
public:
    /// The smallest grid a browser window is fitted to.
    ///
    /// A browser window is dragged to a sliver far more easily than a native one
    /// is, and a shell handed a 1x1 terminal rewraps its scrollback into it — so
    /// the floor is a grid a prompt still reads in rather than the single cell
    /// `gridFromViewport` guarantees.
    static constexpr int minColumns = 20;
    static constexpr int minRows = 6;

    /// Whether this view owns one session or carries a whole workspace.
    enum class ConnectionMode {
        Session,
        Workspace
    };

    /// Creates a terminal of `rows` by `columns` cells.
    ///
    /// - Parameter glyphScale: Multiplies the raster; 1 is Unifont's native 8x16
    ///   device pixels. Integer, because a fractional scale resamples glyphs the
    ///   rasterizer drew crisp.
    /// - Parameter mode: Whether the owner attaches a whole workspace.
    /// - Parameter workspace: Borrowed carrier, which outlives this pane; null for an owner.
    /// - Parameter sessionID: The bound session a borrowed carrier renders here.
    WebTerminal(int rows, int columns, int glyphScale, ConnectionMode mode = ConnectionMode::Session, WebTerminal* workspace = nullptr, std::uint32_t sessionID = 0);
    ~WebTerminal();

    WebTerminal(const WebTerminal&) = delete;
    WebTerminal& operator=(const WebTerminal&) = delete;

    /// Resizes a standalone grid; a host mirror changes only through host frames.
    ///
    /// - Parameters:
    ///   - rows: The requested local row count.
    ///   - columns: The requested local column count.
    void resize(int rows, int columns);

    /// Sets the visible content extent in device pixels, excluding page padding.
    void setPresentationViewport(float width, float height) { m_presentationViewport = { width, height }; }
    /// The complete picture's transform, resolved by the most recent frame.
    [[nodiscard]] const Rendering::RemoteViewportPlacement& presentation() const { return m_presentation; }

    /// Feeds bytes through the VT parser.
    ///
    /// - Parameter bytes: Host output, at no framing boundary in
    ///   particular — the parser carries its state across calls.
    void feed(std::string_view bytes);

    /// Renders the current grid and returns the image, tightly packed RGBA8
    /// with row stride `4 * imageWidth()`.
    ///
    /// The span stays valid until the next call. Empty when the grid is
    /// degenerate or the raster failed, with both dimensions left 0.
    const std::vector<std::uint8_t>& render();

    [[nodiscard]] int imageWidth() const { return m_imageWidth; }
    [[nodiscard]] int imageHeight() const { return m_imageHeight; }
    /// Rows of scrollback behind the visible grid.
    [[nodiscard]] int scrollbackRows() const;

    [[nodiscard]] int rows() const { return m_terminal.rows; }
    [[nodiscard]] int columns() const { return m_terminal.columns; }

    // --- Attached mode: the page owns a socket, this owns the protocol -------
    //
    // `SyncClientCore` is transport-free, so the browser needs no carrier
    // implementation: JavaScript hands over what the socket delivered and sends
    // what these build. The whole shell path is a handshake and two byte queues.

    /// The frames this client owes the host, or empty when it owes none.
    ///
    /// The screen plane's acknowledgements, and the resync it asks for when an
    /// update cannot apply. The host paces this client by what it acknowledged,
    /// so the caller sends these after feeding host bytes and again when
    /// `screenTickDelayMilliseconds` says the next acknowledgement is due;
    /// left unsent, the host stops sending once its window fills.
    ///
    /// - Parameter pendingOutboundBytes: Bytes still buffered by the page's
    ///   socket; upload chunks wait until the carrier has bounded headroom.
    /// - Returns: Borrowed complete canonical envelopes, or empty when none are owed.
    const std::vector<std::uint8_t>& takePendingHostFrame(std::size_t pendingOutboundBytes = 0);

    /// How long until the screen plane owes the host an acknowledgement.
    ///
    /// - Returns: Milliseconds, rounded up, or -1 when nothing is owed.
    [[nodiscard]] int screenTickDelayMilliseconds() const;

    /// Feeds bytes received from the host, decoding whole frames.
    /// Returns false once the decoder faults, which means drop the connection.
    [[nodiscard]] bool feedFromHost(std::string_view bytes);

    /// Whether the page will answer a host that asks for its clipboard.
    ///
    /// A page's decision and not a default, because claiming it exposes this
    /// browser's clipboard to every process on the host: any of them can run
    /// xclip while the session is open. A page claims it only once it holds
    /// the browser's clipboard-read permission — the bit is a promise to
    /// answer, and a page that claims without permission leaves a program
    /// waiting for a reply it cannot produce.
    ///
    /// Core's spelling under this file's name. Every client asks itself the
    /// same question before claiming, so the two states are declared once;
    /// what stays here is the name a page's caller already writes.
    using ClipboardServing = Ubiquitty::Clipboard::Serving;

    /// Whether a session this Greet creates outlives the client that opened it.
    ///
    /// Which default a page picks is the page's: an unnamed session opened from
    /// a row is a one-off, and a named workspace is the thing the person came
    /// back for. The host reads it only when the Greet creates — a reattach
    /// observes what the session already is.
    enum class SessionLifetime {
        /// The session stays when the last client leaves, the daemon's default.
        Persists,
        /// The session ends when its last human detaches cleanly.
        EndsWhenDetached
    };

    /// Builds the Greet that opens a session at the current geometry.
    ///
    /// `sessionID` is 0 to start a session and otherwise the id a previous
    /// Welcome selected, which reattaches that session — a page that persists
    /// the id across a reload returns to its shell instead of to a new one. The
    /// host refuses a missing saved ID rather than creating a replacement.
    ///
    /// A `workspaceName` attaches to the session bearing that name and creates
    /// one under it when nothing does — one ask, either outcome, the way
    /// `tmux new-session -A -s` behaves. Empty is the unnamed create-or-reattach
    /// by `sessionID`.
    ///
    /// Building one ends the previous connection's decode state: the frame
    /// decoder's fault latch and partial-frame residue, the handshake flags, and
    /// the screen plane, whose generations are the connection's own. The grid
    /// stays — it is what a reconnecting page draws until the next checkpoint
    /// lands — and so does the session id,
    /// which is the host's answer to the previous handshake and stands until
    /// this one is answered. A reattach names its session from what the caller
    /// persisted and passes in, not from that accessor.
    ///
    /// - Parameters:
    ///   - authToken: The capability token, empty when the page holds none.
    ///   - sessionID: 0 to create, otherwise the session to reattach.
    ///   - clipboardServing: Whether this page answers a host asking for its
    ///     clipboard.
    ///   - workspaceName: The workspace to attach to or create under, null for
    ///     an unnamed session.
    ///   - lifetime: What becomes of a session this Greet creates.
    const std::vector<std::uint8_t>& buildHello(const char* authToken, std::uint32_t sessionID = 0,
        ClipboardServing clipboardServing = ClipboardServing::Disabled,
        const char* workspaceName = nullptr,
        SessionLifetime lifetime = SessionLifetime::Persists);

    /// Builds the canonical envelope the page sends for pasted text: one Sync `Paste`.
    ///
    /// Pasted text is sent as a paste and never as typed bytes. The host
    /// applies Core's paste policy when it writes the text to the program,
    /// under the modes live at that moment: it neutralises any ESC[200~ or
    /// ESC[201~ already inside the content, so pasted text cannot close a fence
    /// it did not open; it strips control characters when the application has
    /// not enabled bracketed paste; and when the application has enabled it, it
    /// wraps the body in one balanced fence so a shell treats embedded newlines
    /// as text rather than executing each line.
    ///
    /// - Parameter text: The clipboard text, as the page read it.
    /// - Returns: The frame, owned by this Terminal and valid until the next
    ///   build call. Empty when the text is, or while the paste is kept for
    ///   the pane's bind.
    const std::vector<std::uint8_t>& buildPaste(std::string_view text);

    /// Whether native keys bypass the input method for DEC position reports.
    /// - Returns: True when DEC private mode 81 is set.
    [[nodiscard]] bool reportsKeyPositions() const { return m_terminal.modes.shouldReportKeyPositions; }

    /// Whether clipboard gestures send MIME notifications instead of text.
    [[nodiscard]] bool reportsPasteEvents() const { return m_terminal.modes.shouldReportPasteEvents; }

    /// Builds the notification for MIME names captured by a user paste gesture.
    /// - Parameter types: Space-separated MIME names; no clipboard payload data.
    /// - Returns: The input frame, or empty when mode 5522 is reset.
    const std::vector<std::uint8_t>& buildPasteNotification(std::string_view types);

    /// Builds the Sync semantic key event the host's Core keymap encodes.
    ///
    /// Which bytes an Escape, a Ctrl-C, an arrow under DECCKM or an F5 under the
    /// kitty protocol become depends on the host's live modes, so the caller
    /// supplies an event's shape and never its encoding.
    ///
    /// A modifier folds into the *key*, never into the character: a host that
    /// has already applied one reports Option+F as U+0192, and encoding that
    /// sends a character no binding matches. `keyCode` therefore carries what the
    /// key types unmodified in the active layout, and `text` carries whatever
    /// character actually resulted.
    ///
    /// - Parameters:
    ///   - keyCode: A Kitty functional key code, or the code point the key types
    ///     in the active layout.
    ///   - baseLayoutKey: The code point the same physical key carries in the
    ///     standard layout, or 0.
    ///   - modifiers: The ``Keys::Keymap::keymapModifier`` bits.
    ///   - text: The code point produced, or 0 when the key produced none.
    /// Encodes a key event into the canonical envelope the page sends.
    ///
    /// `eventType` distinguishes press from release and repeat. The page reports
    /// what the browser gave it; whether a non-press produces any bytes is
    /// host Core's decision. A release is not dropped because this replica has
    /// not seen REPORT_EVENTS yet; the host may have enabled it meanwhile.
    /// `physicalKey` carries the layout-independent keyboard position.
    /// An empty frame means no key identity or no input ready for transport,
    /// not that this replica's modes suppressed the event.
    const std::vector<std::uint8_t>& buildKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text,
        Keys::KeyEventType eventType = Keys::KeyEventType::Press, Keys::VirtualKey physicalKey = {});

    /// Clears the screen and the scrollback, keeping the line being typed, and
    /// returns the frame the caller sends so the process redraws.
    ///
    /// Sending it is required, not advisory — see `Core/Screen/ClearBuffer.h`.
    /// While attached, returns a `pane.clear` Call without changing the local
    /// replica. Empty when the request cannot be queued.
    const std::vector<std::uint8_t>& buildClearBuffer();

    /// Scrolls the current prompt to the top of the screen.
    ///
    /// Nothing is destroyed: the rows above the prompt move into scrollback the
    /// way ordinary output would have put them there. Where a program owns the
    /// layout Core forwards the redraw request rather than guessing which rows
    /// are dead — see `Core/Screen/ClearBuffer.h`.
    ///
    /// - Returns: While attached, a `pane.clear` Call without local mutation.
    ///   Standalone, a redraw frame only when the program owns the layout.
    const std::vector<std::uint8_t>& buildClearScreen();

    /// Drops the scrollback and leaves the visible grid untouched. While
    /// attached, queues a `pane.clear` Call for the normal output pump instead.
    ///
    /// History is not the screen, so a caller expecting the display to change
    /// wants ``buildClearScreen`` instead.
    void clearScrollback();

    // --- OSC 52: the clipboard, as a program reaches it ----------------------
    //
    // Both directions are asynchronous in a browser and synchronous in Core, so
    // neither crosses directly. A write is staged here and pulled out; a read is
    // requested, answered later, and only then served. `ClipboardClient` already
    // has that shape — `requiresAsynchronousClipboardRead` exists for exactly a
    // platform whose clipboard read is a promise.

    /// Text a program asked to put on the clipboard, possibly an empty clear.
    /// ``hasPendingClipboardWrite`` distinguishes no operation from a clear.
    ///
    /// The caller writes it to the system clipboard and calls
    /// ``takeClipboardWrite`` to clear it; leaving it uncleared re-offers the
    /// same text on the next frame.
    [[nodiscard]] const char* pendingClipboardWrite() const;

    /// Distinguishes an exact empty clear from no pending text operation.
    ///
    /// - Returns: Whether the page must consume a text write, even when empty.
    [[nodiscard]] bool hasPendingClipboardWrite() const;

    /// How many typed payloads wait for the page's clipboard write.
    [[nodiscard]] int pendingClipboardItemCount() const;
    /// One waiting payload's MIME name; empty outside the count.
    ///
    /// - Parameter index: The payload's position.
    [[nodiscard]] const char* pendingClipboardItemMime(int index) const;
    /// One waiting payload's bytes; empty outside the count.
    ///
    /// - Parameter index: The payload's position.
    [[nodiscard]] const char* pendingClipboardItemBytes(int index) const;
    /// One waiting payload's byte count; 0 outside the count.
    ///
    /// - Parameter index: The payload's position.
    [[nodiscard]] int pendingClipboardItemLength(int index) const;
    /// Drops the waiting typed payloads — the page has written them.
    void takeClipboardItems();

    /// Opens the typed half of a read answer; items follow, then the text.
    void beginClipboardReadItems();
    /// Adds one payload the page read, owned here until the answer lands.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name.
    ///   - bytes: The payload, copied.
    void addClipboardReadItem(std::string_view mime, std::span<const char> bytes);

    /// Clears the pending write, after the caller has placed it.
    void takeClipboardWrite();

    /// Whether a program is waiting on a clipboard read.
    ///
    /// The caller reads the system clipboard and answers with
    /// ``provideClipboardRead``. A program that asks and is never answered waits
    /// forever, so an unanswerable request is answered with an empty string.
    [[nodiscard]] bool wantsClipboardRead() const;

    /// Reports whether the pending read must be confirmed by the user first.
    ///
    /// True when Core's read policy is Prompt, which is its default. The page
    /// must ask before it reads: reading and then answering would hand the
    /// program the clipboard and leave the confirmation as a formality after the
    /// fact. A refusal is still an answer — call ``provideClipboardRead("")``, so
    /// the program that asked gets an empty reply rather than waiting.
    ///
    /// - Returns: True while a read is pending and needs confirmation.
    [[nodiscard]] bool clipboardReadNeedsConfirmation() const;

    /// Answers a pending read with `text`, or with nothing when the caller
    /// declined or the browser refused permission.
    void provideClipboardRead(const char* text);

    // --- CLIPBOARD_SERVE: the clipboard a remote host does not have ----------
    //
    // The other direction from OSC 52. There a program on this page's own
    // terminal asks; here the HOST asks, because a program running on it
    // shelled out for a clipboard and a headless machine has none. Same
    // asynchronous shape — the page reads, and answers when the browser lets
    // it — and a different destination for the answer: a Sync frame rather
    // than an escape reply.

    /// The request the host is waiting on, or zero when there is none.
    ///
    /// Polled rather than pushed because the page drives its own frame loop
    /// and a callback into JavaScript from here would run inside the parse.
    [[nodiscard]] std::uint32_t pendingClipboardServeID() const;

    /// Whether the pending request wants the type list rather than one item.
    ///
    /// The list is the cheap question: a shell prompt can ask it once per
    /// keystroke, and answering with a screenshot's bytes to learn a name
    /// would move megabytes.
    [[nodiscard]] bool pendingClipboardServeWantsTypes() const;

    /// The MIME the pending request wants, empty for a type list.
    [[nodiscard]] const char* pendingClipboardServeMime() const;

    /// Opens the answer to the pending serve request; items follow.
    void beginClipboardServeItems();

    /// Adds one payload, or one type name with no bytes for a list answer.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name.
    ///   - bytes: The payload, copied. Empty for a type-list entry.
    void addClipboardServeItem(std::string_view mime, std::span<const char> bytes);

    /// Frames the answer and clears the pending request.
    ///
    /// A page that never answers sends nothing and the host's tool reports an
    /// empty clipboard, which is what a page without permission should look
    /// like — so declining is answering with `status` refused rather than
    /// staying silent, and silence is reserved for a page that closed.
    ///
    /// - Parameter status: The wire's `ClipboardServeStatus` value: 0 OK,
    ///   1 empty, 2 refused, 3 too large.
    /// - Returns: The framed bytes to send, empty when nothing was pending.
    [[nodiscard]] const std::vector<std::uint8_t>& buildClipboardServeAnswer(int status);

private:
    // The typed half of a read answer while the page accumulates it:
    // owned strings, viewed by the staging call when the answer lands.
    std::vector<std::string> m_readItemMimes;
    std::vector<std::string> m_readItemBytes;
    // One physical browser connection owns one metadata-inclusive upload.
    std::uint32_t m_nextPastePushID = 0;
    Protocol::Control::PasteUploadSource m_pasteSource;

public:
    /// Adds a keybinding in the form a config `[keys]` line carries.
    ///
    /// - Parameters:
    ///   - spec: A key spec such as `cmd+k`.
    ///   - action: An action token such as `clear` or `send:\\x01`.
    /// - Returns: False when either half fails to parse.
    [[nodiscard]] bool addKeybinding(const char* spec, const char* action);

    /// Resolves a key against the bindings, before any encoding.
    ///
    /// A pending chord must be swallowed rather than encoded: a leader key is
    /// not input, and sending it puts a stray character in the shell before the
    /// chord completes.
    ///
    /// - Returns: The matched ``Input::ActionKind`` as an int, 0 when nothing
    ///   matched, or -1 while a multi-key chord is still being collected.
    [[nodiscard]] int resolveBinding(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers);

    /// The payload of the last ``resolveBinding`` that matched a `send:` action,
    /// empty otherwise.
    [[nodiscard]] const std::vector<std::uint8_t>& bindingBytes() const { return m_bindingBytes; }

    /// Encodes a key and feeds it back into this terminal, for a detached caller
    /// with no host to echo it.
    ///
    /// Distinct from ``buildKey`` so a caller never opens a sync frame to reach
    /// the bytes inside it; the envelope is the protocol's business.
    ///
    /// - Returns: False when the key encoded to nothing.
    [[nodiscard]] bool feedKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text,
        Keys::KeyEventType eventType = Keys::KeyEventType::Press, Keys::VirtualKey physicalKey = {});

    /// Builds the canonical envelope carrying bytes for the host's PTY as Sync `Raw` events.
    ///
    /// - Parameter bytes: Already encoded for the wire.
    /// - Returns: The frame, owned by this Terminal and valid until the next
    ///   build call. Empty when the input is, or while it is kept for the
    ///   pane's bind.
    const std::vector<std::uint8_t>& buildInput(std::string_view bytes);

    /// Frames a paste.push Call, retaining one immutable upload until the
    /// host grants exact credit and answers where it landed.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name.
    ///   - bytes: The payload; empty or past the upload cap builds nothing.
    /// - Returns: The framed bytes, empty when nothing was built.
    [[nodiscard]] const std::vector<std::uint8_t>& buildPastePush(std::string_view mime, std::span<const std::uint8_t> bytes);

    /// Reports window facts and requests geometry under the host-granted role.
    /// Drivers send a viewport; agents use the Drive-scoped geometry call;
    /// viewers do not request a pane resize. Host pictures own the cell reflow.
    ///
    /// - Parameters:
    ///   - rows: Requested positive row count, at most ``maxRows``.
    ///   - columns: Requested positive column count, at most ``maxColumns``.
    /// - Returns: Queued frames, empty before binding or while a call is pending.
    const std::vector<std::uint8_t>& buildResize(int rows, int columns);

    /// What ``pointer`` and ``scroll`` settled, packed for the page.
    enum PointerVerdict : int {
        /// The event was taken -- reported, gestured or swallowed; the page
        /// prevents the browser's default. Clear leaves the page's own
        /// fallback (a context menu, a link click).
        PointerVerdictConsumed = 1,
        /// The selection or a highlight changed; repaint.
        PointerVerdictNeedsDisplay = 2,
        /// A press opened a local selection gesture: motion now extends it.
        PointerVerdictOpenedGesture = 4,
        /// A release ended a local selection gesture.
        PointerVerdictFinishedGesture = 8,
    };

    /// Runs one pointer fact through Core's ladder: relative pointer lock,
    /// the DEC locator, the mode-1001 gesture, the mouse report with its
    /// dedup, or the local selection, in the order the terminal's modes rank
    /// them -- the same ladder every other frontend runs. The page
    /// contributes the pixel-to-cell division and the event's facts, and
    /// applies the verdict ``pointerVerdict`` reports. The view offset is
    /// this terminal's; the fact's is overwritten.
    ///
    /// - Parameter fact: The event's facts, as the page saw them.
    /// - Returns: The bytes for the host -- the locator report, the mouse
    ///   report or the hilite end report, framed for the sync channel --
    ///   empty when the ladder sent nothing.
    const std::vector<std::uint8_t>& pointer(Input::PointerFact fact);

    /// Runs one scroll gesture through Core's wheel ladder: a report to a
    /// tracking host, alternate-scroll keys on the alternate screen, or the
    /// local view, which moves here. The fold from the browser's deltas to
    /// lines and the report count a trackpad flick is worth are Core's.
    ///
    /// - Parameter fact: The gesture's facts; positive deltas bring older
    ///   content in.
    /// - Returns: The bytes for the host, framed; empty when the view moved
    ///   or nothing happened. ``pointerVerdict`` says which.
    const std::vector<std::uint8_t>& scroll(const Input::ScrollFact& fact);

    /// The ``PointerVerdict`` bits of the last ``pointer`` or ``scroll``.
    [[nodiscard]] int pointerVerdict() const { return m_pointerVerdict; }

    /// Whether DECSET 7403 (relative pointer lock) is set.
    ///
    /// The page answers it with the Pointer Lock API, which is the same
    /// arrangement macOS uses with CGAssociateMouseAndMouseCursorPosition: the
    /// cursor is hidden and captured, and motion arrives as a signed per-report
    /// DELTA rather than a position. Core's encoder wants exactly that delta as
    /// pixelX/pixelY and applies the 0x8000 bias itself, so the page passes
    /// event.movementX/movementY through untouched.
    [[nodiscard]] bool pointerLockActive() const { return m_terminal.modes.mouseRelativePointerLock; }

    /// Whether the page should hold the Pointer Lock API grab: the
    /// application's ask and the page's standing to answer it, decided in
    /// Core.
    ///
    /// - Parameter facts: What the page sees.
    /// - Returns: Whether to hold the grab.
    [[nodiscard]] Input::PointerLockVerdict pointerLockVerdict(const Input::PointerLockFacts& facts) const;

    /// Reports the page's grab, so the lesson naming the way out stands for
    /// exactly as long as the trap does.
    ///
    /// - Parameter grab: Whether the grab is held.
    void notePointerLockGrab(Input::PointerLockGrab grab);

    /// Reports the modifier state the page saw, for the break-out chord.
    ///
    /// - Parameter keys: The modifiers and whether any other key is down.
    void notePointerLockChord(const Input::PointerLockKeyState& keys);

    /// Asks whether the armed chord has been held for its threshold, and on
    /// a break-out clears the mode so a hung application cannot re-trap the
    /// pointer.
    ///
    /// - Parameter keysNow: The modifiers as they are now.
    /// - Returns: Whether the page releases its grab.
    [[nodiscard]] Input::PointerLockChordVerdict tickPointerLockChord(const Input::PointerLockKeyState& keysNow);

    /// How long until the armed chord's hold elapses, in 60 Hz ticks, or 0
    /// when it is not armed: the one wake-up the page books for the chord.
    ///
    /// - Returns: Ticks until the deadline, or 0.
    [[nodiscard]] std::uint32_t pointerLockChordTicksUntilDeadline() const;

    /// Records how the reader's keyboard names its modifiers, as the page
    /// reports it from the platform it runs on.
    ///
    /// - Parameter vocabulary: Glyphs on a Mac, words elsewhere.
    void setModifierVocabulary(Input::ModifierVocabulary vocabulary) { m_modifierVocabulary = vocabulary; }

    /// How long the standing hint has left, in 60 Hz ticks, or 0 when it will
    /// not withdraw itself.
    ///
    /// The one wake-up the page books: it paints again that many ticks from
    /// now, so a lesson fades without a frame of its own.
    ///
    /// - Returns: Ticks until the lesson fades, or 0.
    [[nodiscard]] std::uint32_t hintTicksUntilExpiry() const;

    /// Services the local CRT saver; host mirrors use the host's display state.
    /// - Parameter now: The browser's current monotonic tick.
    /// - Returns: Ticks until service is due, or -1 when no timer is needed.
    [[nodiscard]] int serviceDisplayIdle(Ticks now);

    /// Whether the password-prompt heuristic is running on this terminal.
    ///
    /// Seeded once at construction from `[security] password_detect`, so this
    /// reports what the page's configuration asked for rather than whether a
    /// prompt is currently detected. The heuristic drives the lock badge and
    /// the echo mask, which means a frontend that seeds it from anything but
    /// the live preferences masks input a person asked it not to mask.
    ///
    /// - Returns: True when the heuristic is enabled.
    [[nodiscard]] bool passwordDetectEnabled() const { return m_terminal.passwordDetect; }

    /// Whether the reader holds the link modifier for a click: Command, or
    /// Ctrl on a keyboard that has none.
    enum class LinkModifier : std::uint8_t {
        Up,
        Held,
    };

    /// The link a primary click on a cell opens, empty when there is none.
    ///
    /// The pointer over a link is a fact only the frontend can act on — the
    /// shape it shows, the page it opens — so the answer stays a string the
    /// caller reads rather than an action Core takes.
    ///
    /// An OSC 8 hyperlink and a bare URL both resolve here. A filesystem path
    /// does not, because a browser has no working directory to resolve one
    /// against, and neither does any scheme a page cannot open: the program
    /// writes the escape, so the URI is attacker-controlled, and a link that
    /// will not open must not display the affordance saying it will. An
    /// `ssh`, `sftp`, `ftp` or `ftps` link resolves only with the link
    /// modifier held (`LinkRun::requiresLinkModifier`), as on every other
    /// frontend: it hands a connection to a host the program named to
    /// whichever program the browser launches for the scheme.
    ///
    /// The span stays valid until the next call.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - column: The column.
    ///   - modifier: Whether the click holds the link modifier.
    /// - Returns: The URI, or the empty string.
    [[nodiscard]] const char* linkAtCell(int row, int column, LinkModifier modifier);

    /// The pointer shape, as ``Input::MousePointerShape``.
    ///
    /// Takes no coordinates: the decision reads terminal state and the facts
    /// only a frontend knows. Whether the cell under the pointer holds a link
    /// or lies past the end of its row are two of those facts, and the caller
    /// has already resolved both.
    ///
    /// The caller supplies what only it knows — whether a rectangular select is
    /// armed, whether a drag would bypass mouse reporting — and the terminal's
    /// own state is read here, so the browser and the native frontends cannot
    /// answer the same question two ways.
    [[nodiscard]] int pointerShape(bool isOverLink, bool isRectangularSelectArmed, bool selectionBypassesMouseReporting, bool isOverTextVoid);

    /// The cell at a viewport point, through the drawn picture's inverse map.
    ///
    /// - Parameters:
    ///   - xInPixels: Device pixels right of the clipped viewport's origin.
    ///   - yInPixels: Device pixels below the clipped viewport's origin.
    /// - Returns: The clamped cell.
    [[nodiscard]] CellPosition pointerCell(float xInPixels, float yInPixels) const
    {
        const FloatSize cell { static_cast<float>(cellWidth()), static_cast<float>(cellHeight()) };
        const GridSize grid { columns(), rows() };
        const FloatPoint point = m_presentation.picturePoint({ xInPixels, yInPixels });
        CellPosition at = Rendering::pointToCell(point, {}, cell, grid, Rendering::RowClamp::Clamped);
        // The row is the grid's; the column along it is the frame's, which on
        // a row the primary face laid out as proportional runs is the letter
        // under the point (LetterLayout.h).
        if (m_fonts && grid.columns > 0)
            at.column = std::clamp(m_fonts->renderer.columnAt(at.row, static_cast<double>(point.x)), 0, grid.columns - 1);
        return at;
    }

    /// Where a viewport point stands along its row, in cells, for the caret
    /// the pointer ladder resolves: on a row laid out as letters, the letter
    /// under the point plus the fraction of it crossed.
    ///
    /// - Parameters:
    ///   - xInPixels: Device pixels right of the clipped viewport's origin.
    ///   - yInPixels: Device pixels below the clipped viewport's origin.
    /// - Returns: The position, 0 through the column count.
    [[nodiscard]] double pointerXInCells(float xInPixels, float yInPixels) const
    {
        const FloatPoint point = m_presentation.picturePoint({ xInPixels, yInPixels });
        const int row = pointerCell(xInPixels, yInPixels).row;
        if (m_fonts)
            return m_fonts->renderer.xInCellsAt(row, static_cast<double>(point.x));
        const int pitch = cellWidth();
        return pitch > 0 ? std::clamp(static_cast<double>(point.x) / pitch, 0.0, static_cast<double>(std::max(columns(), 0))) : 0.0;
    }

    /// The drawn cursor cell's box in viewport device pixels.
    ///
    /// - Returns: The cursor cell's transformed rectangle.
    [[nodiscard]] FloatRect cursorCellRect() const
    {
        const CellPosition at { cursorRow(), cursorColumn() };
        const FloatSize cell { static_cast<float>(cellWidth()), static_cast<float>(cellHeight()) };
        FloatRect rect = Rendering::cellRect(at, cell, {}, 0.0f);
        rect.origin = m_presentation.viewportPoint(rect.origin);
        rect.size.width *= m_presentation.scale;
        rect.size.height *= m_presentation.scale;
        return rect;
    }

    /// The unscaled host pixel a viewport point reports as, for DECSET 1016.
    ///
    /// - Parameters:
    ///   - xInPixels: Device pixels right of the clipped viewport's origin.
    ///   - yInPixels: Device pixels below the clipped viewport's origin.
    /// - Returns: The 1-based pixel, clamped into the text area.
    [[nodiscard]] IntPoint pointerPixel(float xInPixels, float yInPixels) const
    {
        const IntSize textArea { columns() * cellWidth(), rows() * cellHeight() };
        return Rendering::pointToDevicePixel(m_presentation.picturePoint({ xInPixels, yInPixels }), {}, 1.0f, textArea);
    }

    // --- Selection and the scrollback viewport -------------------------------
    //
    // Both are frontend state over one shared model: Core's selection is in
    // VISIBLE-grid coordinates read at the current view offset, so scrolling
    // while a drag is live would slide the selection over the text. The offset
    // is therefore held for the duration of a drag, as the native frontends
    // hold theirs.

    /// Drops the selection.
    void clearSelection();

    [[nodiscard]] bool hasSelection() const;

    /// The selected text as UTF-8, empty when nothing is selected.
    ///
    /// Rows join with a newline except across a soft wrap, so a reflowed
    /// logical line copies back as one line. The span stays valid until the
    /// next call.
    [[nodiscard]] const char* selectionText();

    /// Scrolls the viewport by `rows`, positive into history.
    ///
    /// Clamped to the scrollback that exists, so a caller may over-scroll
    /// freely; ``viewOffset`` reports where it landed. Attached, a view that
    /// reaches the oldest row held asks the host for older lines; the want
    /// waits for ``takePendingHostFrame``.
    void scrollBy(int rows);

    /// Selects the whole buffer, scrollback included.
    void selectAll();

    /// Selects the characters a drag over a rectangle of visible cells covers.
    ///
    /// - Parameter visible: The rectangle, in visible rows and columns.
    void selectVisibleRectangle(const SelectionBounds& visible);

    /// Selects what a plain drag between two points selects, through the
    /// pointer ladder's caret gesture, so a selection can start and end inside
    /// a rich text block's lines.
    ///
    /// - Parameters:
    ///   - fromX: The press, in cells across, unrounded.
    ///   - fromY: The press, in rows down, unrounded.
    ///   - toX: The release, in cells across, unrounded.
    ///   - toY: The release, in rows down, unrounded.
    void selectBetweenPoints(double fromX, double fromY, double toX, double toY);

    /// Queues a literal search, advanced by pumpSearch on the event loop.
    ///
    /// - Parameter literal: The text to find, matched case-sensitively.
    /// - Returns: Whether the request was accepted.
    bool searchLiteral(const char* literal);

    /// Runs queued search slices within the event loop's idle budget.
    ///
    /// - Returns: Whether more work remains.
    bool pumpSearch();

    /// Returns the current query's progress and active match.
    ///
    /// - Returns: Pending status until the current generation publishes.
    [[nodiscard]] Search::Status searchStatus() const;

    /// Encodes searchStatus as JSON.
    ///
    /// - Returns: The encoded status, valid until the next call.
    const char* searchStatusJSON();

    /// Steps among the published matches and reveals the active one.
    ///
    /// - Parameter direction: Toward older or newer text.
    /// - Returns: Whether a match became active.
    bool stepSearch(Search::StepDirection direction);

    /// Runs a literal search to completion for snapshot automation.
    ///
    /// - Parameter literal: The text to find, matched case-sensitively.
    /// - Returns: Whether the search completed successfully within its limit.
    bool searchLiteralAndWait(const char* literal);

    /// Drops the rows above the previous executed prompt, or clears the
    /// screen keeping the input row when there is none.
    void clearToPreviousMark();

    /// Clears the screen and its history, keeping the row being typed.
    void clearPreservingInput();

    /// Drops a selection because the user is sending input, as every frontend
    /// does on a keystroke or a paste. Returns whether the display changed.
    bool clearSelectionForUserInput();

    /// The cursor's visible row and column, clamped to the grid.
    ///
    /// Where an input method's candidate window belongs: it is placed at the
    /// element it composes into, so that element has to follow the caret or the
    /// popup reads as belonging to some other application.
    [[nodiscard]] int cursorRow() const;
    [[nodiscard]] int cursorColumn() const;

    /// Records a focus change from the browser.
    ///
    /// - Parameter focus: The new state.
    void setFocus(Modes::FocusState focus);

    /// Builds the frame that tells the host the current focus state: the
    /// screen plane's facts.
    ///
    /// Attached, the program that enabled DEC 1004 is running against the HOST's
    /// Terminal, so telling this mirror is not telling it — the state has to go
    /// over the wire. The caller sends this whenever focus changes, and once
    /// after the handshake, because a page can open in a background tab and the
    /// first thing the program hears must not be wrong. Empty when the host
    /// already holds this state.
    const std::vector<std::uint8_t>& buildFocusChanged();

    /// Whether the surface currently has focus.
    [[nodiscard]] bool isFocused() const { return m_isFocused; }

    /// A notification a program raised with OSC 9, OSC 99 or OSC 777, as Core
    /// composed it for a notification with a heading and running text, or
    /// empty when none is pending or the page already has the focus.
    ///
    /// Staged rather than delivered: a browser notification needs permission and
    /// a page-owned API, and this object holds no emscripten type. The caller
    /// shows it and calls ``takeNotification``.
    [[nodiscard]] const char* pendingNotificationTitle() const;
    [[nodiscard]] const char* pendingNotificationBody() const;

    /// The tag the staged notification is shown under, or empty when none is
    /// pending. Core's identifier: a notification shown under a tag a standing
    /// one holds replaces that one.
    [[nodiscard]] const char* pendingNotificationTag() const;

    /// Clears the staged notification, after the caller has shown it.
    void takeNotification();

    /// Stages the notification Core composes for a program's request, unless
    /// Core withholds it from a page that has the focus.
    ///
    /// - Parameter request: The notification as parsed.
    void stageNotification(const NotificationRequest& request);

    /// The working directory a shell last reported with OSC 7, or empty.
    [[nodiscard]] const char* currentDirectory() const;

    /// A font family a program asked for with OSC 50, or empty when none is
    /// pending.
    ///
    /// The family reaches the rasterizer through a JavaScript global the page
    /// owns, and this object holds no emscripten type, so the request is staged
    /// here and the page applies it — the shape the clipboard already uses. The
    /// size axes need no staging: this owns the font stack and applies them.
    [[nodiscard]] const char* pendingFontFamily() const;

    /// Clears the staged family, after the caller has applied it and rebuilt.
    void takeFontFamily();

    /// The terminal's title, as OSC 0 or 2 last set it.
    ///
    /// Attached, the host owns the title and sends it — a program's OSC lands on
    /// the host's Terminal, not this one, so the local field would stay empty
    /// while the shell renamed itself. Detached, the local field is the only
    /// one there is. Empty when nothing has set one.
    [[nodiscard]] const char* title() const;

    /// Records a bell for presentation when this page is not foreground.
    void noteBell();

    /// The program-observable state of the visible grid, as one JSON document.
    ///
    /// Every visible cell's text, style and wide half, the cursor with its
    /// pending wrap and visibility, the live palette, and the title, working
    /// directory and pointer shape the program set — what a harness judging Core's terminal behaviour reads back after
    /// feeding it a sequence. Rows are read through `resolveVisibleRow`, in the
    /// logical order the program wrote them, not the shaped display order.
    ///
    /// - Returns: A NUL-terminated document in storage this owns, valid until
    ///   the next call.
    [[nodiscard]] const char* captureProgramState();

    /// Reads program metadata without capturing the grid or draining events.
    ///
    /// Raw title and directory, decoded OSC 7501 records with their inherited
    /// application, Core's primary record index, OSC 9;4 progress, and shell
    /// integration facts. Records are ordered from oldest to newest update.
    /// `isReadingCommand` is an OSC 133 fact, not a sampled process identity.
    ///
    /// - Returns: JSON owned by this terminal, valid until the next call.
    [[nodiscard]] const char* programMetadataJSON();

    /// Encodes local input for an embedder-owned byte sink without echoing it.
    ///
    /// Uses the same local mode-aware encoder as `feedKey`. Remote attachments
    /// send `buildKey` intents instead, for the host to encode under its modes.
    ///
    /// - Parameters:
    ///   - keyCode: The functional key or produced code point.
    ///   - baseLayoutKey: The unmodified physical position's code point.
    ///   - modifiers: Core's keymap modifier bits.
    ///   - text: The produced code point, or zero.
    ///   - eventType: Press, repeat, or release.
    ///   - output: Storage for the binary sequence, including possible NULs.
    ///   - physicalKey: The layout-independent key position.
    /// - Returns: The byte count; zero when suppressed or storage is too small.
    [[nodiscard]] int encodeLocalKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, std::span<char> output, Keys::VirtualKey physicalKey = {})
    {
        return encodeKey(keyCode, baseLayoutKey, modifiers, text, eventType, output, physicalKey);
    }

    /// Takes decoded OSC 9;4 reports as JSON, retaining their order within a feed.
    ///
    /// At most 256 reports wait; `overflow` flags any omitted reports.
    ///
    /// - Returns: A document owned by this terminal, valid until the next take.
    [[nodiscard]] const char* takeProgressReports();

    /// Moves the replies Core queued for the program into `output`.
    ///
    /// Detached, no program reads them, so they wait here until taken.
    ///
    /// - Parameter output: Receives the replies, in the order Core queued them.
    /// - Returns: The bytes written; 0 once nothing is queued.
    int takeReplies(std::span<char> output);

    /// Takes the bells the program rang since the last take.
    ///
    /// - Returns: How many, counted one per bell rather than per feed.
    [[nodiscard]] std::uint32_t takeBellsRung() { return m_bellRoute.take(); }

    /// The font's em size, in CSS pixels before the device scale.
    [[nodiscard]] double fontSize() const { return m_fontSize; }

    /// The size in DEVICE pixels the glyph stack was built at.
    ///
    /// `fontSize` above is the size in CSS pixels a person configured, which
    /// may be fractional; this is that taken to the device scale and rounded
    /// once. The two are separate reads because the rounding between them is
    /// where a fractional size is lost if the multiply and the round are
    /// ordered the other way about.
    ///
    /// - Returns: The device pixel size, zero before the stack is built.
    [[nodiscard]] int fontPixelSize() const { return m_fontPixelSize; }

    /// Sets the font's em size, clamped to the range Core publishes for zoom.
    ///
    /// Rebuilds the rasterizers and the renderer, so the caller re-fits its grid
    /// to the new cell afterwards — the cell size changes and the row and column
    /// counts that fit a window change with it.
    ///
    /// - Parameter cssPixels: The requested em size; out-of-range values clamp
    ///   rather than being refused, as they do on the other frontends.
    void setFontSize(double cssPixels);

    /// Rebuilds the font stack at the current size.
    ///
    /// A family change alters no size, so `setFontSize` would decline it — and
    /// the family reaches the rasterizer through a page-owned global that this
    /// object cannot read. The caller sets the family, then asks for this.
    void rebuildFontStack();
    /// Applies a newly published browser preference document.
    void refreshConfiguration();

    /// Publishes the cell, grid and page sizes to Core, in device pixels.
    ///
    /// Called wherever one of them moves: construction, a resize, a font
    /// stack rebuild and a padding change. Core places an inline image sized in
    /// pixels and answers the pixel-size reports from what is published here.
    void publishPixelGeometry();

    /// Tells the host the faces this page draws proportional runs in, as its
    /// measurer counts them, so a hosted pane is answered in them
    /// (Docs/proportional-text.md).
    ///
    /// Called where the faces or the declaration move: a font stack rebuild
    /// and ``setDrawnText``. A page that draws no runs publishes nothing.
    void publishProportionalFaces();

    /// Rebuilds the `font-feature-settings` descriptor value.
    ///
    /// Called by both inputs it depends on — the specification and the ligature
    /// policy — because either alone is half of what the descriptor says, and a
    /// composition that ran on only one of them would publish a value the other
    /// had not been folded into yet.
    void recomposeFontFeatureSettingsCSS();

    /// The terminal's default background, packed 0xRRGGBB.
    ///
    /// What the frontend paints everywhere the grid is not — the padding, and
    /// the sub-cell remainder a window that is not a whole number of cells
    /// leaves. Follows the applied theme, so a frontend reading it per frame
    /// never disagrees with the cells beside it.
    [[nodiscard]] int backgroundColor() const;

    /// The window padding, in CSS pixels before the device scale.
    ///
    /// The shorthand's value: what a palette stepper shows and sets. A page
    /// that has set the edges separately still gets one number here, so this is
    /// the left inset rather than a claim that all four agree.
    [[nodiscard]] double padding() const { return m_paddingInsets.left; }

    /// The four insets, in CSS pixels before the device scale.
    ///
    /// Four rather than one because Core resolves four and they do not default
    /// to the same value — the built-in top is zero and the other three are
    /// six. Held as a single number, the browser drew a top inset every other
    /// frontend does not, and no per-edge setting could reach it at all.
    [[nodiscard]] Rendering::EdgeInsets paddingInsets() const { return m_paddingInsets; }

    /// Sets the window padding, clamped to the range Core's settings schema
    /// publishes for `[appearance] padding`.
    ///
    /// Changes what fits the window rather than what a cell measures, so the
    /// caller re-fits its grid afterwards exactly as it does after a zoom.
    ///
    /// - Parameter cssPixels: The requested inset; out-of-range values clamp
    ///   rather than being refused, as the TOML parse does.
    void setPadding(double cssPixels);

    /// Sets the four insets independently, each clamped to the schema's range
    /// for `[appearance] padding`.
    ///
    /// - Parameter insets: The requested insets, in CSS pixels.
    void setPaddingInsets(Rendering::EdgeInsets insets);

    /// Whether the glyph under a block cursor takes a contrasting colour.
    ///
    /// - Returns: `[cursor] invert_text`, as the live configuration says.
    [[nodiscard]] bool shouldCursorInvertText() const;

    /// What the glyph under a block cursor is drawn in.
    enum class CursorTextContrast {
        /// The glyph keeps its own colour — `[cursor] invert_text = false`.
        Keep,
        /// The glyph takes a contrasting colour, which is the default.
        Invert,
    };

    /// Sets what the glyph under a block cursor is drawn in: one key edited in
    /// the live configuration document, which every frame then reads.
    ///
    /// - Parameter contrast: What `[cursor] invert_text` is to say.
    void setCursorTextContrast(CursorTextContrast contrast);

    /// Declares which OSC 66 text the renderer draws, the gate a window
    /// declares at session start on the other frontends.
    ///
    /// `GridOnly` by default, the answer for an embedder bringing its own
    /// grid renderer: sized runs print at the ordinary size, a proportional
    /// measure query goes unanswered and a placed run prints as ordinary text
    /// (Docs/proportional-text.md). The bundled page renderer, whose
    /// proportional atlas draws runs, declares both.
    ///
    /// - Parameter drawnText: What the renderer draws.
    void setDrawnText(Runtime::DrawnText drawnText)
    {
        m_terminal.drawsSizedText = Runtime::drawsSizedText(drawnText);
        m_terminal.drawsProportionalText = Runtime::drawsProportionalText(drawnText);
        publishProportionalFaces();
    }

    /// Returns which OSC 66 text the renderer declared it draws.
    ///
    /// - Returns: The declaration ``setDrawnText`` last made.
    [[nodiscard]] Runtime::DrawnText drawnText() const
    {
        if (m_terminal.drawsSizedText)
            return m_terminal.drawsProportionalText ? Runtime::DrawnText::SizedAndProportional : Runtime::DrawnText::Sized;
        return m_terminal.drawsProportionalText ? Runtime::DrawnText::Proportional : Runtime::DrawnText::GridOnly;
    }

    /// Extra space between rows, in CSS pixels before the device scale.
    [[nodiscard]] double lineSpacing() const { return m_lineSpacing; }

    /// Sets the line spacing, clamped to the schema's range for
    /// `[font] line_spacing`, and rebuilds the font stack at the new cell.
    ///
    /// Changes what a cell measures, so the caller re-fits its grid afterwards
    /// exactly as it does after a zoom.
    ///
    /// - Parameter cssPixels: The requested spacing.
    void setLineSpacing(double cssPixels);

    /// Sets the `font.variations` axis list.
    ///
    /// The axes reach the face two ways, because a canvas font shorthand can
    /// name a weight and a slant and no other axis. A `wght` here reaches the
    /// upright cell through the rasterizer, below an SGR weight and below the
    /// bold face; every other tag is the page's to bake into a registered face.
    ///
    /// - Parameter specification: The list, in the grammar
    ///   ``Rendering::parseFontVariationSpecification`` reads.
    void setFontVariations(const std::string& specification);

    /// The `font-feature-settings` value for `[font] features`.
    ///
    /// Composed from Core's parse rather than from the reader's text, so the
    /// page pastes a descriptor value and never learns the grammar. Empty when
    /// the specification names no feature.
    ///
    /// - Returns: The descriptor value, valid until the specification changes.
    [[nodiscard]] const char* fontFeatureSettingsCSS() const;

    /// Sets `[font] features`, recomposing the descriptor value.
    ///
    /// - Parameter specification: The specification, in the grammar
    ///   `Core/Rendering/FontFeatureSpecification.h` parses.
    void setFontFeatures(const std::string& specification);

    /// Sets whether the face's own ligatures may apply.
    ///
    /// The browser is this arm's shaper and enables `liga`, `clig` and `calt` by
    /// default, so the policy reaches its drawing only as a suppression inside
    /// the feature descriptor. The font stack reads the same pair when it is
    /// built, which the page does after registering the face that carries the
    /// descriptor, and shapes no run of grid text when the pair turns nothing
    /// on.
    ///
    /// - Parameter ligatures: The policy.
    void setLigatures(Rendering::Ligatures ligatures);

    /// The `font-variation-settings` value for the axes a canvas cannot name.
    ///
    /// Every tag in the specification except `wght`, formatted for a CSS
    /// descriptor. The page registers a face carrying this and draws with it;
    /// weight is left out because a descriptor naming it outranks `font-weight`
    /// and would pin every cell to one weight.
    ///
    /// - Returns: The value, empty when no such axis was named.
    [[nodiscard]] const char* fontVariationSettingsCSS() const;

    /// How a rule is drawn — `[underline]`'s four tuning keys.
    ///
    /// One struct because they are set together and read together, and because
    /// four separate setters is four places for a caller to apply three of them.
    /// The units match the config file's: the thickness is a multiplier on what
    /// the face reports, and the two lengths are CSS pixels before the device
    /// scale, exactly as `padding` is.

    /// Sets how a rule is drawn, each value clamped to the range Core's settings
    /// schema publishes for its key.
    ///
    /// Nothing measured changes, so the caller does not re-fit its grid: a rule
    /// is drawn inside a cell whose size it does not affect.
    ///
    /// - Parameter settings: The requested values; out-of-range values clamp
    ///   rather than being refused, as the TOML parse does.

    /// The rendered grid on a page, with the padding drawn around it.
    ///
    /// `render` returns the grid alone, because the page insets its canvas with
    /// CSS and would show the padding twice. Something capturing what a viewer
    /// sees has no stylesheet, so the inset has to be in the pixels — and a
    /// capture without it is a picture of this terminal with the setting
    /// missing, which reads as a rendering difference against a frontend that
    /// drew it.
    ///
    /// - Returns: Tightly packed RGBA8, `pageWidth() * pageHeight() * 4` bytes,
    ///   or empty when the frame could not be rendered.
    [[nodiscard]] const std::vector<std::uint8_t>& renderPage();

    /// The last `renderPage` image's width in device pixels.
    [[nodiscard]] int pageWidth() const { return m_pageWidth; }

    /// The last `renderPage` image's height in device pixels.
    [[nodiscard]] int pageHeight() const { return m_pageHeight; }

    /// The columns and rows that fit a viewport, with the padding removed.
    ///
    /// Routed through `Rendering::gridFromViewport` so the browser divides the
    /// window the same way macOS and the GTK frontend do. Floored at a grid a
    /// program can still draw something in, rather than at one cell: a browser
    /// window can be dragged to a sliver, and a 1x1 terminal is not a state any
    /// shell recovers from gracefully.
    ///
    /// - Parameters:
    ///   - viewportWidth: The window's width in DEVICE pixels.
    ///   - viewportHeight: The window's height in device pixels.
    ///   - scale: Device pixels per CSS pixel, which the padding is stated in.
    /// - Returns: The grid dimensions that fit.
    [[nodiscard]] Ubiquitty::GridSize gridForViewport(double viewportWidth, double viewportHeight, double scale) const;

    /// Steps the font size by the schema's step, in either direction.
    void stepFontSize(int steps);

    /// Returns the font to the size this terminal was created at.
    void resetFontSize();

    /// Scrolls to the oldest row the buffer still holds.
    void scrollToTop();

    /// Returns to the live grid.
    void scrollToBottom();

    /// Rows scrolled back from the live grid; 0 is the bottom.
    [[nodiscard]] int viewOffset() const { return m_viewOffset; }

    /// Whether this connection has been granted its current screen authority.
    /// A selected session identity or an awaiting-consent Welcome is not enough.
    [[nodiscard]] bool isAttached() const { return m_sync.isScreenAttached(); }

    /// The host's standing verdict on this attach, or empty when it raised none.
    ///
    /// A held or refused attach carries no screen, so without this the page
    /// shows an empty grid that looks exactly like a host which is down or a
    /// shell that has printed nothing — and the consent gate that produced it is
    /// answered by a human somewhere else, who may never be told to look. The
    /// wording is Core's (``Protocol::Sync::attachHeldNotice`` and the two
    /// reason mappings beside it) so every frontend explains a refusal the same
    /// way rather than each keeping a table of reason codes.
    ///
    /// Standing rather than one-shot: the verdict stays true until the host
    /// replaces it or `buildHello` begins another connection, and a status line
    /// that has to be repainted from a value it consumed cannot show it again.
    ///
    /// - Returns: A phrase for a status line, owned by this object.
    [[nodiscard]] const char* hostNotice() const { return m_hostNotice.c_str(); }

    /// Core's notice while some of what was typed may not have reached the
    /// host: a resume could not learn whether the host wrote what a dead
    /// connection carried. Every field is empty while nothing awaits the
    /// person's decision. What the person types meanwhile waits behind the
    /// input in doubt, so the page shows this whenever it is not empty.
    ///
    /// - Returns: The notice as it stands, owned by this object and valid
    ///   until the next call.
    [[nodiscard]] const Session::InputInDoubtNotice& inputInDoubtNotice();

    /// Sends the input in doubt again, at the person's word, ahead of what
    /// waited behind it; the host writes none of it twice. Never called
    /// unasked: sending again can run a command twice.
    ///
    /// - Returns: The frame, owned by this Terminal and valid until the next
    ///   build call; empty when nothing was in doubt or no connection carries
    ///   the pane.
    const std::vector<std::uint8_t>& resendInputInDoubt();

    /// Drops the input in doubt, at the person's word, and lets what waited
    /// behind it go.
    ///
    /// - Returns: The frame, as ``resendInputInDoubt`` returns it.
    const std::vector<std::uint8_t>& discardInputInDoubt();

    /// Whether the screen holds a checkpoint from the host yet.
    [[nodiscard]] bool hasScreen() const { return m_sync.hasScreen(); }

    /// Whether Core can reach the sync client when it moves rows out from under
    /// a mirrored grid. Wired once, at construction.
    [[nodiscard]] bool hasMirrorClient() const { return m_terminal.mirrorClient.get() == &m_sync; }

    /// The session ID selected by a validated Welcome, or 0 before any selection.
    /// A reconnect leaves the previous answer standing until its Welcome arrives.
    /// Callers must gate persistence on isAttached(), not this accessor alone.
    /// Persisting it is what lets a later `buildHello` reattach rather than start over.
    [[nodiscard]] std::uint32_t sessionID() const { return m_workspaceSessionID ? m_workspaceSessionID : m_sync.sessionID(); }
    /// Serializes the host's authoritative workspace layout, with exact revision strings.
    /// - Returns: Borrowed JSON, valid until the next call.
    [[nodiscard]] const char* hostWorkspaceJSON();
    /// Queues a registry-validated host call on this attachment.
    /// - Parameters:
    ///   - method: The Sync method name.
    ///   - parameters: JSON parameters matching the registered schema.
    ///   - requestID: A nonzero identity unique among outstanding web calls.
    /// - Returns: Encoded frames, or none when validation or admission failed.
    [[nodiscard]] const std::vector<std::uint8_t>& buildHostCall(const char* method, const char* parameters, std::uint32_t requestID);
    /// Takes one correlated host answer; empty when none is ready.
    /// - Returns: Borrowed JSON, valid until the next take.
    [[nodiscard]] const char* takeHostCallResultJSON();
    /// Explains why the most recent host call was not sent.
    /// - Returns: Borrowed text, valid until the next host call.
    [[nodiscard]] const char* hostCallRefusal() const { return m_hostCallRefusal.c_str(); }
    /// Selects the workspace the carrier's next greeting attaches.
    /// - Parameter workspaceID: The host's stable workspace number; zero selects by name.
    void setWorkspaceID(std::uint32_t workspaceID) { m_requestedWorkspaceID = workspaceID; }
    /// Sets whether the host sends this pane's picture.
    /// - Parameter state: Live for a displayed pane, Dormant for a retained hidden pane.
    void setWorkspacePaneView(Protocol::Sync::ViewState state) { m_sync.setPaneView(sessionID(), state); }

    /// Drops this viewer's theme override and asks for the host's palette.
    void followHostTheme();

    // --- The host's sessions (capabilityControl) -----------------------------
    //
    // The daemon admits each typed termination under its original authority
    // and any required one-use consent. Only its exact Result settles success.
    //
    // Listing is a typed Control-scoped subscription: the host's tree, which
    // the outline is drawn from and the connect rule decides on.

    /// Builds a typed subscription asking the host to enumerate its sessions.
    ///
    /// Allocates the request id, so the reply this client accepts is the one
    /// answering its most recent ask. Nothing is applied until that reply
    /// arrives: the frame is a query, and the previous list stands until a newer
    /// one lands.
    ///
    /// - Returns: The encoded carrier frames, or empty before Welcome. Owned
    ///   by this object and valid until the next `build*` call reuses the buffer.
    const std::vector<std::uint8_t>& buildListSessions();

    /// A counter each whole answer of the host's listing advances, starting
    /// at 0.
    ///
    /// The signal a caller polls to learn the host has described itself. A
    /// counter and not a flag, because a host holding nothing is an answer,
    /// and a tree with no workspace cannot be told from one that has not
    /// arrived by looking at it.
    [[nodiscard]] std::uint32_t hostAnswerGeneration() const { return m_hostAnswerGeneration; }

    // The host's outline. A page subscribes to the host's listing on the
    // connection it already has: the host then
    // sends every workspace's structure and every pane's records, Core
    // assembles the tree (`Session::HostListing`) and decides the rows
    // (`Runtime::buildHostOutline`), and the page draws them. The page
    // chooses only which rows are closed and what is searched for.

    /// Calls for the host's listing; ``takePendingHostFrame`` carries the
    /// call. The outline follows the host from the answer on, for as long as
    /// the connection stands, and a new connection subscribes again.
    ///
    /// - Returns: False, calling for nothing, before the host has welcomed
    ///   the connection.
    [[nodiscard]] bool subscribeHostListing();

    /// Asks the host for one change to its structure
    /// (`Runtime::StructureCalls`): a label, tags, a workspace's or a tab's
    /// name, a tab's place, a window closed. The page's typed wrappers are
    /// the only callers; no page code writes a method or its parameters.
    ///
    /// Checked against the outline's tree and refused here, in Core's words,
    /// or sent as one call on this connection. Either way it ends as a new
    /// ``hostStructureGeneration`` with ``hostStructureResultJSON`` naming
    /// the number returned here.
    ///
    /// - Parameters:
    ///   - operation: A `Runtime::StructureOperation`.
    ///   - target: The row's identity as the outline writes it, `tab:7`.
    ///   - text: The label or the name, where the operation takes one.
    ///   - tags: The tags, one a line, for the operation that sets them.
    ///   - window: The window a moved tab is to stand in, `window:2`.
    ///   - index: The place it takes there.
    /// - Returns: The request's number; zero for an operation or an
    ///   identity that is none.
    [[nodiscard]] std::uint32_t requestHostStructureChange(int operation, const char* target, const char* text, const char* tags, const char* window, int index);

    /// Words the question a request that ends sessions is asked with, from
    /// the outline's tree, and gives it the token the request is sent with
    /// (`Runtime::DestructiveConfirmations`).
    ///
    /// The page shows the title, the body and the two buttons as they are
    /// and makes the safe button the default.
    ///
    /// - Parameters:
    ///   - request: A `Runtime::DestructiveRequest`.
    ///   - target: A window to close, `window:2`; a session, the pane it
    ///     draws into, or a workspace to terminate.
    ///   - hostName: What the host is called in the question.
    /// - Returns: `{token, title, body, safeButton, destructiveButton,
    ///   sessionCount, whyNot}` as JSON text, owned by this object and valid
    ///   until the next call. The token is zero and `whyNot` a sentence when
    ///   there is nothing to ask.
    [[nodiscard]] const char* hostDestructiveConfirmationJSON(int request, const char* target, const char* hostName);

    /// Closes a window and ends the sessions in its panes; asked and
    /// answered as ``requestHostStructureChange``, which itself always
    /// refuses to close one.
    ///
    /// - Parameters:
    ///   - window: The window, `window:2`.
    ///   - confirmationToken: The token of the question that was answered.
    /// - Returns: The request's number; zero for an identity that is none.
    [[nodiscard]] std::uint32_t closeHostWindow(const char* window, std::uint32_t confirmationToken);

    /// Builds the terminate of a session, or the first of a workspace's,
    /// once its question was answered.
    ///
    /// Built only with the token ``hostDestructiveConfirmationJSON``
    /// returned for terminating this target, and only while it would end the
    /// sessions the question named. A workspace's other sessions are owed:
    /// the page builds each with ``buildOwedTerminate`` as the one before it
    /// settles.
    ///
    /// - Parameters:
    ///   - request: `Runtime::DestructiveRequest::TerminateSession` or
    ///     `TerminateWorkspace`.
    ///   - target: The session or its pane, or the workspace.
    ///   - confirmationToken: The token of the question that was answered.
    /// - Returns: The frame, as ``buildTerminateSession`` returns it; empty
    ///   when nothing is sent, and ``hostTerminateRefusal`` says why.
    const std::vector<std::uint8_t>& buildConfirmedTerminate(int request, const char* target, std::uint32_t confirmationToken);

    /// How many sessions a confirmed terminate has still to ask for.
    [[nodiscard]] std::uint32_t owedTerminateCount() const { return static_cast<std::uint32_t>(m_owedTerminations.size()); }

    /// Builds the terminate of the next session a confirmed terminate owes.
    ///
    /// - Returns: The frame; empty when none is owed.
    const std::vector<std::uint8_t>& buildOwedTerminate();

    /// Why ``buildConfirmedTerminate`` last built nothing, as a sentence;
    /// empty when it built.
    [[nodiscard]] const char* hostTerminateRefusal() const { return m_hostTerminateRefusal.c_str(); }

    /// A counter that advances whenever a change settles.
    [[nodiscard]] std::uint32_t hostStructureGeneration() const { return m_hostStructureGeneration; }

    /// How the change that settled last ended:
    /// `{requestID, operation, target, outcome, reason}`, the outcome one of
    /// `served`, `refusedByHost`, `refusedHere` and `unanswered`, the reason
    /// a sentence shown as it is. `{"requestID":0}` before any has settled.
    ///
    /// - Returns: The JSON text, owned by this object and valid until the
    ///   next call.
    [[nodiscard]] const char* hostStructureResultJSON();

    /// A counter that advances whenever the rows ``hostOutlineJSON`` returns
    /// may have changed: the host answered, or anything its tree is built
    /// from moved. Zero before any answer.
    [[nodiscard]] std::uint32_t hostOutlineGeneration() const { return m_hostOutlineGeneration; }

    /// Whether the host answered that it lists nothing to this connection.
    [[nodiscard]] bool isHostListingRefused() const { return m_hostListing.isRefused(); }

    /// The host's outline as JSON (`App::outlineJSON`): the rows to draw, in
    /// order, with every decision already made.
    ///
    /// - Parameter query: What the person is searching for; empty or null
    ///   for no search.
    /// - Returns: The JSON text, owned by this object and valid until the
    ///   next call; an outline of no rows before the host answered.
    [[nodiscard]] const char* hostOutlineJSON(const char* query);

    /// Closes a row of the outline, so the rows under it are not listed.
    ///
    /// - Parameter id: The row's identity as its JSON spells it, `kind:number`.
    /// - Returns: False for text that is no identity.
    [[nodiscard]] bool collapseHostOutlineRow(const char* id);

    /// Opens a row ``collapseHostOutlineRow`` closed.
    ///
    /// - Parameter id: The row's identity.
    /// - Returns: False for text that is no identity.
    [[nodiscard]] bool expandHostOutlineRow(const char* id);

    /// Closes a row that has no identity: a window or a tab of a workspace
    /// nothing runs in, named as the row's `recorded` member names it.
    ///
    /// - Parameters:
    ///   - workspaceID: The restorable workspace.
    ///   - level: 1 for a window's row, 2 for a tab's.
    ///   - window: The window's index in the record.
    ///   - tab: The tab's index in that window; zero on a window's row.
    /// - Returns: False for a level that is neither.
    [[nodiscard]] bool collapseRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab);

    /// Opens a row ``collapseRecordedHostOutlineRow`` closed.
    ///
    /// - Parameters:
    ///   - workspaceID: The restorable workspace.
    ///   - level: 1 for a window's row, 2 for a tab's.
    ///   - window: The window's index in the record.
    ///   - tab: The tab's index in that window.
    /// - Returns: False for a level that is neither.
    [[nodiscard]] bool expandRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab);

    /// Opens a row and every row under it, whatever was closed.
    ///
    /// - Parameter id: The row's identity as the outline writes it.
    /// - Returns: Whether the outline's tree holds the row.
    [[nodiscard]] bool expandAllUnderHostOutlineRow(const char* id);

    /// ``expandAllUnderHostOutlineRow`` for a row that has no identity.
    ///
    /// - Parameters:
    ///   - workspaceID: The restorable workspace.
    ///   - level: 1 for a window's row, 2 for a tab's.
    ///   - window: The window's index in the record.
    ///   - tab: The tab's index in that window.
    /// - Returns: Whether the outline's tree holds the row.
    [[nodiscard]] bool expandAllUnderRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab);

    /// How the exact typed termination settled.
    ///
    /// The five answers `Session::TerminateOutcome` names, mirrored here rather
    /// than shared because that type reaches its own transport and this client
    /// classifies the frames arriving on the page's socket. The mapping is
    /// `SessionDirectoryCore`'s, so a browser and a desktop cannot report the
    /// same exchange two ways.
    ///
    /// The five carry Core's numbers, so the ordinal this page reads over the
    /// ABI means the same thing an agent CLI or a Swift mirror reads. `Pending`
    /// is this arm's alone — the desktop's errand object exists only while one
    /// is outstanding, where a page holds a row before it asks anything — so it
    /// takes a value no Core outcome can ever occupy rather than a sixth
    /// position that would shift the rest by one.
    enum class TerminateOutcome : std::uint8_t {
        /// The session is gone.
        Terminated = 0,
        /// A person on the session said no.
        Denied = 1,
        /// A person on the session never answered.
        TimedOut = 2,
        /// The host's result was not confirmed; transport loss is not success.
        Failed = 3,
        /// The host refused the request itself, on the token or its scope.
        Refused = 4,
        /// Nothing has been asked, or the ask is still outstanding.
        Pending = 255
    };

    /// Builds a correlated typed call asking the host to end a session.
    ///
    /// Destructive and answered asynchronously by its exact typed result.
    /// A second request is refused while the first remains outstanding.
    ///
    /// - Parameter sessionID: The session to end; 0 builds nothing.
    /// - Returns: The encoded frame, owned by this object and valid until the
    ///   next `build*` call reuses the buffer.
    const std::vector<std::uint8_t>& buildTerminateSession(std::uint32_t sessionID);

    /// A counter the settled terminates advance, starting at 0.
    ///
    /// Polled the way ``hostAnswerGeneration`` is, and for the same reason: an
    /// outcome lands on frames carrying nothing else, and a repeated outcome —
    /// two rows both refused — is two answers rather than one.
    [[nodiscard]] std::uint32_t terminateGeneration() const { return m_terminateGeneration; }

    /// How the last terminate settled, ``TerminateOutcome::Pending`` while one
    /// is outstanding and before any has been asked.
    [[nodiscard]] TerminateOutcome terminateOutcome() const { return m_terminateOutcome; }

    /// The session the last terminate named, 0 before any has been asked.
    [[nodiscard]] std::uint32_t terminateSessionID() const { return m_terminateSessionID; }

    /// The page's short liveness interval; it never establishes success.
    static constexpr double terminateGraceSeconds = 0.5;

    /// How long an operation waits for an explicit result, including consent.
    static constexpr double terminateConsentSeconds = 35.0;

    /// Reports that ``terminateGraceSeconds`` have passed with the request
    /// unanswered.
    ///
    /// The clock is the page's. An unanswered operation remains pending.
    void noteTerminateGraceElapsed();

    /// Reports that ``terminateConsentSeconds`` have passed with a held request
    /// still unanswered, which settles it as timed out.
    void noteTerminateDeadlineElapsed();

    /// Reports that the socket carrying an outstanding terminate went away.
    ///
    /// Settles as ``TerminateOutcome::Failed``: no correlated result was read.
    /// A connection closing cannot establish that the named target ended.
    void noteTerminateTransportLost();

    // --- The connect rule, and the pairing it reads --------------------------
    //
    // Which session a connect lands on is one rule and it is Core's
    // (`Session::RememberedSessions`), so the page spells none of it: it hands
    // over the bytes it kept for the host, asks, and keeps whatever the ask
    // leaves. The bytes are opaque — a browser store is somewhere to keep a
    // record, not somewhere to read one — which is what stops the rule being
    // half-restated in JavaScript the first time a field is added.

    /// Hands over the record the page has stored for a host.
    ///
    /// Called before ``decideAttach`` for that host. A host with nothing stored
    /// needs no call: an absent record is what a first connect looks like.
    ///
    /// - Parameters:
    ///   - hostKey: The page's name for the host — whatever already tells one
    ///     saved connection from another.
    ///   - bytes: The record as ``hostRecordBytes`` last produced it.
    ///   - length: Its byte count; a negative or null pair stores nothing.
    void loadHostRecord(const char* hostKey, const char* bytes, int length);

    /// The connect Core's rule makes for this host.
    ///
    /// Reads the record loaded above, the workspace name a saved host
    /// predefines, and the host's last answered session list — the three inputs
    /// the rule takes, none of them re-derived here.
    ///
    /// - Parameters:
    ///   - hostKey: The page's name for the host.
    ///   - predefinedWorkspaceName: The name the saved host carries, null when
    ///     it names none.
    /// - Returns: The plan; ``decidedSessionID`` and ``decidedWorkspaceName``
    ///   carry what it names.
    Session::AttachPlan decideAttach(const char* hostKey, const char* predefinedWorkspaceName);

    /// The session the last ``decideAttach`` named, 0 when it named none.
    [[nodiscard]] std::uint32_t decidedSessionID() const { return m_decision.sessionID; }

    /// The workspace the last ``decideAttach`` named, empty when it named none.
    [[nodiscard]] const char* decidedWorkspaceName() const { return m_decision.workspaceName.c_str(); }

    /// Pairs a host with the session it is attached on.
    ///
    /// Called only after the validated Welcome and exact consent grant, never
    /// from the ask. A saved numeric selection cannot silently be replaced.
    ///
    /// - Parameters:
    ///   - hostKey: The page's name for the host.
    ///   - sessionID: The session the host pinned.
    ///   - workspaceName: The workspace it is attached under, null for an
    ///     unnamed session.
    void rememberHostSession(const char* hostKey, std::uint32_t sessionID, const char* workspaceName);

    /// Drops a host's pairing, so the next connect decides as a first one.
    ///
    /// What a refused reattach and a terminated session both leave behind: an
    /// id the host no longer honours must not be asked for twice.
    ///
    /// - Parameter hostKey: The page's name for the host.
    void forgetHostSession(const char* hostKey);

    /// The bytes to store for a host, empty when it has no pairing.
    ///
    /// Owned here and valid until the next call that changes the host's record.
    ///
    /// - Parameter hostKey: The page's name for the host.
    [[nodiscard]] const char* hostRecordBytes(const char* hostKey) const;

    /// The byte count of ``hostRecordBytes``, which may hold a zero byte.
    ///
    /// - Parameter hostKey: The page's name for the host.
    [[nodiscard]] int hostRecordLength(const char* hostKey) const;

    // --- Resume across a reload ------------------------------------------------
    // A window keeps its client instance and its resume record across a reload
    // of the page (Docs/sync.md §6.9). Core owns the record and when it is
    // written or purged; the page owns only where its bytes live, which is the
    // tab's session storage: one window, one tab.

    /// Installs the window's record slot before the first greeting and draws
    /// the stored picture into this terminal, so the page paints it before the
    /// first packet and the next greeting resumes the stored attachment.
    ///
    /// - Parameters:
    ///   - slot: Where the encoded record lives; the terminal keeps it.
    ///   - clientInstance: The window's stored instance, or zero for none, in
    ///     which case this terminal's own instance becomes the window's.
    /// - Returns: Whether the slot was installed. False once a greeting has
    ///   gone, or when one is installed already.
    bool restoreResume(std::unique_ptr<Session::ResumeRecordSlot> slot, Protocol::Sync::ID128 clientInstance);

    /// Writes the record now, as a page does when it is about to be hidden or
    /// unloaded: the stored picture is the newest one held.
    void persistResume() { m_sync.persistResume(); }

    /// The instance this window greets its host as.
    [[nodiscard]] Protocol::Sync::ID128 clientInstance() const { return m_sync.clientInstance(); }

    /// Whether the picture on screen is the stored one, and no connection has
    /// replaced it yet.
    [[nodiscard]] bool showsRestoredPicture() const { return m_sync.hasRestoredPicture(); }

    // --- Beam ---------------------------------------------------------------
    // The palette's state machine is Core's and shared with every frontend; the
    // browser supplies the commands, the keys and the surface.

    /// Opens or closes the palette. Returns whether it is open afterwards.
    bool toggleBeam();

    /// Routes a key while the palette is open.
    ///
    /// - Returns: Whether Beam consumed it. False means the caller sends the key
    ///   to the host as usual — an open palette must not swallow the terminal's
    ///   input wholesale.
    bool feedBeamKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text);

    /// Where the palette should be drawn, from [appearance] beam_surface.
    ///
    /// The browser has no native palette today, so every value resolves to the
    /// in-grid one — but the preference is stored rather than discarded, because
    /// dropping it here would make the setting silently untrue on the frontend
    /// most likely to gain a native palette first.
    ///
    /// - Parameter surface: The configured surface, stored as given.
    void setBeamSurface(Preferences::BeamSurface surface) { m_beamSurface = surface; }

    /// The font families this page can actually render, for the palette's font
    /// drill.
    ///
    /// Supplied by the frontend rather than derived here, because which families
    /// resolve is a fact about the browser and its installed fonts that no
    /// portable code can answer. Core runs the drill; the page says what is in
    /// it. An empty list hides the command rather than offering a drill with
    /// nothing behind it.
    ///
    /// - Parameters:
    ///   - families: Family names, in the order to list them.
    ///   - currentIndex: Which is in effect, or -1.
    void setFontOptions(std::vector<std::string> families, int currentIndex);

    /// The chosen theme's NAME, empty when none has been chosen.
    ///
    /// By name and not by index, because an index is a position in a table the
    /// user does not control: adding or reordering a theme in Core would make a
    /// persisted index name a different theme, silently and only for people who
    /// had already chosen one.
    [[nodiscard]] const char* currentThemeName() const;

    /// Restores a theme by name. Returns whether the name was known — an unknown
    /// one leaves the palette alone rather than falling back to a default, so a
    /// theme removed from Core does not silently become a different one.
    bool setThemeByName(const char* name);

private:
    /// Re-applies the chosen theme over a palette the host just replaced.
    /// A no-op when no theme has been chosen, so an untouched client keeps
    /// exactly what the host sent.
    void reapplyTheme();

public:
    /// Declares whether this build has a native palette to hand the user.
    ///
    /// Unavailable is the browser's answer today. It exists as a SETTER rather
    /// than a constant so the suppression path is reachable and testable: with a
    /// native palette available and "native" configured, nothing is drawn into
    /// the grid, and that is the contract macOS depends on.
    ///
    /// - Parameter availability: Whether a native palette exists on this host.
    void setNativeBeam(Preferences::NativeBeam availability) { m_nativeBeam = availability; }

    [[nodiscard]] bool isBeamOpen() const { return m_beam.isOpen(); }

    /// How many result rows the last frame drew. Zero when the palette is closed
    /// or drew nothing.
    [[nodiscard]] int beamRowsDrawn() const { return m_beamGeometry.bodyRows; }

    /// What the palette is showing, for a caller that draws it itself or a test
    /// that asserts on the rows rather than on the picture.
    [[nodiscard]] const CommandPalette::BeamState& beamState() const { return m_beam.state(); }

    /// The command id the last key accepted, or empty. Taken once: reading it
    /// clears it, so a caller polling per frame cannot run it twice.
    [[nodiscard]] const char* takeBeamCommand();

    /// Whether the host reported an OPTIMISED build at the handshake.
    ///
    /// Surfaced because an unoptimised daemon is indistinguishable from a slow
    /// one from here, and measuring around one has cost two people an hour each.
    /// False before the handshake, which the caller distinguishes with
    /// ``isAttached``.
    [[nodiscard]] bool hostIsOptimised() const
    {
        return m_sync.hostBuildFlags().contains(Protocol::Sync::HostBuildFlag::Optimised);
    }

    // --- GPU frame: the instances every backend draws ------------------------
    //
    // The same instance stream the CPU path composites, stopping before the
    // composite so a caller can upload it and let a GPU do that work — the
    // instances Metal and Vulkan bind, from one builder, over one atlas. Nothing
    // in this group is browser-shaped.

    /// Whether a program is mid-composition and this frame must not be shown.
    ///
    /// Asked once per frame by the caller rather than by each renderer: the CPU
    /// raster has no opinion about DECSET 2026, so a frame withheld from the
    /// instance path and then drawn by the raster is not withheld at all. The
    /// answer defers and never discards — a caller re-presents what it already
    /// has and asks again next frame.
    [[nodiscard]] bool isFrameWithheld();

    /// Builds this frame's instances.
    ///
    /// A false answer means present the last complete frame again, not that
    /// something failed: DECSET 2026 withholds a frame the application is still
    /// composing, and the instances from the previous call stay valid for
    /// exactly that.
    ///
    /// - Returns: False for a degenerate grid, or while synchronised output
    ///   holds the frame.
    [[nodiscard]] bool buildFrame();
    /// Core-placed rich text for the browser native text layer.
    /// - Returns: Borrowed JSON, valid until the next frame capture.
    [[nodiscard]] const char* richTextFrameJSON()
    {
        const Rendering::ChromePlacement layers[] = { hintPlacement(), beamPlacement() };
        return m_richText.frameJSON(m_frameInputs, layers);
    }

    /// The cell-background pass: one ``Rendering::CellInstance`` per visible
    /// cell, at a 64-byte stride. Valid until the next ``buildFrame``.
    [[nodiscard]] const Rendering::CellInstance* cellInstances() const { return m_cells.data(); }
    [[nodiscard]] int cellInstanceCount() const { return m_cellCount; }

    /// Two-cell glyphs, which draw from their OWN atlas page in a second pass.
    ///
    /// A cell quad samples one texture. The two pages are the same SIZE but a
    /// wide slot is two cells across, so slot N covers different pixels on each
    /// and a wide glyph's coordinate names a different glyph on the mono page.
    /// Baking it into a cell that binds mono draws a real, sharp, wrong glyph —
    /// not a blank and not a fallback box, which is why it survived every smoke
    /// test this frontend has: only a reader of the language could see it.
    [[nodiscard]] const Rendering::GlyphInstance* wideGlyphInstances() const { return m_wideGlyphs.data(); }
    [[nodiscard]] int wideGlyphInstanceCount() const { return m_wideGlyphCount; }

    /// The wide page, for the pass above to bind.
    [[nodiscard]] const std::uint8_t* wideAtlasPixels() const { return m_fonts->renderer.wideAtlas().pixels; }
    [[nodiscard]] int wideAtlasWidth() const { return m_fonts->renderer.wideAtlas().width; }
    [[nodiscard]] int wideAtlasHeight() const { return m_fonts->renderer.wideAtlas().height; }

    /// Returns the Core-shaped glyphs and their independent coverage sheet.
    [[nodiscard]] const Rendering::GlyphInstance* proportionalGlyphInstances() const { return m_proportionalGlyphs.data(); }
    [[nodiscard]] int proportionalGlyphInstanceCount() const { return m_proportionalGlyphCount; }
    [[nodiscard]] const std::uint8_t* proportionalAtlasPixels() const { return m_fonts->renderer.proportionalAtlas().pixels; }
    [[nodiscard]] int proportionalAtlasWidth() const { return m_fonts->renderer.proportionalAtlas().width; }
    [[nodiscard]] int proportionalAtlasHeight() const { return m_fonts->renderer.proportionalAtlas().height; }
    [[nodiscard]] std::uint32_t proportionalAtlasGeneration() const { return m_fonts->renderer.proportionalAtlasGeneration(); }

    /// Returns bounded proportional fallback strips and their independent sheet.
    [[nodiscard]] const Rendering::GlyphInstance* proportionalStripInstances() const { return m_proportionalStrips.data(); }
    [[nodiscard]] int proportionalStripInstanceCount() const { return m_proportionalStripCount; }
    [[nodiscard]] const std::uint8_t* proportionalStripAtlasPixels() const { return m_fonts->renderer.proportionalStripAtlas().pixels; }
    [[nodiscard]] int proportionalStripAtlasWidth() const { return m_fonts->renderer.proportionalStripAtlas().width; }
    [[nodiscard]] int proportionalStripAtlasHeight() const { return m_fonts->renderer.proportionalStripAtlas().height; }
    [[nodiscard]] bool proportionalStripAtlasIsDirty() const { return m_fonts->renderer.proportionalStripAtlasIsDirty(); }
    /// Marks the current proportional-strip atlas mirror as uploaded.
    void didUploadProportionalStripAtlas() { m_fonts->renderer.didUploadProportionalStripAtlas(); }

    /// Returns Core's run-composited strip stream and its coverage sheet.
    [[nodiscard]] const Rendering::GlyphInstance* ligatureGlyphInstances() const { return m_ligatureGlyphs.data(); }
    [[nodiscard]] int ligatureGlyphInstanceCount() const { return m_ligatureGlyphCount; }
    [[nodiscard]] const std::uint8_t* ligatureAtlasPixels() const { return m_fonts->renderer.ligatureAtlas().pixels; }
    [[nodiscard]] int ligatureAtlasWidth() const { return m_fonts->renderer.ligatureAtlas().width; }
    [[nodiscard]] int ligatureAtlasHeight() const { return m_fonts->renderer.ligatureAtlas().height; }
    [[nodiscard]] bool ligatureAtlasIsDirty() const { return m_fonts->renderer.ligatureAtlasIsDirty(); }
    /// Marks the current strip mirror as uploaded.
    void didUploadLigatureAtlas() { m_fonts->renderer.didUploadLigatureAtlas(); }

    /// Changes when the font resources are replaced, invalidating every upload.
    [[nodiscard]] std::uint32_t fontResourceGeneration() const { return m_fontResourceGeneration; }

    /// The emoji instances, drawn from the RGBA sheet rather than tinted.
    ///
    /// - Returns: The instances the last frame produced.
    [[nodiscard]] const Rendering::GlyphInstance* colorGlyphInstances() const { return m_colorGlyphs.data(); }
    /// - Returns: How many of them are live; zero without a colour source.
    [[nodiscard]] int colorGlyphInstanceCount() const { return m_colorGlyphCount; }
    /// The colour sheet, four bytes per pixel where the other two are one.
    ///
    /// - Returns: The pixels, or null when the rasterizer has no colour source.
    [[nodiscard]] const std::uint8_t* colorAtlasPixels() const { return m_fonts->renderer.colorAtlas().pixels; }
    /// - Returns: The sheet's width in pixels.
    [[nodiscard]] int colorAtlasWidth() const { return m_fonts->renderer.colorAtlas().width; }
    /// - Returns: The sheet's height in pixels.
    [[nodiscard]] int colorAtlasHeight() const { return m_fonts->renderer.colorAtlas().height; }

    /// The overlay pass — the cursor, and one quad per selection row span.
    [[nodiscard]] const Rendering::OverlayInstance* overlayInstances() const { return m_overlays.data(); }
    [[nodiscard]] int overlayInstanceCount() const { return m_overlayCount; }
    /// Shared box-drawing geometry, painted after cell backgrounds.
    /// - Returns: The last frame's quads, including horizontal diagonal bleed.
    [[nodiscard]] const Rendering::OverlayInstance* boxFillInstances() const { return m_boxFills.data(); }
    /// - Returns: The number of initialized box-fill quads.
    [[nodiscard]] int boxFillInstanceCount() const { return m_boxFillCount; }
    /// - Returns: Whether coverage uses Core's bitmap-face quantization.
    [[nodiscard]] bool frameUsesBitmapFace() const { return m_frameInputs.inputs().isBitmapFace; }
    /// How many instances at the end of each grid stream are the cursor tier.
    [[nodiscard]] const Rendering::InstanceCounts::CursorTier& cursorTier() const { return m_cursorTier; }

    /// The decoration pass — underline, overline, strikethrough, box rules.
    [[nodiscard]] const Rendering::DecorationInstance* decorationInstances() const { return m_decorations.data(); }
    [[nodiscard]] int decorationInstanceCount() const { return m_decorationCount; }

    /// Whether this frame needs a pass the browser's cell GPU pipeline lacks.
    /// Inline images and Tek's storage-tube picture are drawn by the shared
    /// CPU compositor; even an empty active Tek screen must cover the grid.
    [[nodiscard]] bool frameRequiresCPUCompositing() const
    {
        return m_hasImages || m_terminal.isTekModeActive || (!m_backgroundImage.isEmpty() && !m_configuration.backgroundImagePath.isEmpty());
    }

    /// Sets the window's background image from an image file's bytes.
    ///
    /// A page has no file to read `[appearance] background_image` from, so it
    /// hands the bytes in; the mode and opacity stay the configuration's. A
    /// frame with an image is composited on the CPU, which draws it with
    /// Core's rule (``Rendering::compositeBackgroundImage``).
    ///
    /// - Parameter fileBytes: The file's contents; empty clears the image.
    /// - Returns: False when the bytes do not decode, leaving no image set.
    bool setBackgroundImage(std::span<const std::uint8_t> fileBytes);

    /// The R8 coverage atlas the instance UVs index into.
    [[nodiscard]] const std::uint8_t* atlasPixels() const { return m_fonts->renderer.monoAtlas().pixels; }
    [[nodiscard]] int atlasWidth() const { return m_fonts->renderer.monoAtlas().width; }
    [[nodiscard]] int atlasHeight() const { return m_fonts->renderer.monoAtlas().height; }

    /// Changes only when a glyph was rasterized, so an unchanged atlas needs no
    /// re-upload.
    /// How many times the mono sheet's pixels have changed.
    ///
    /// Per sheet so the page re-uploads only what moved: one counter for all
    /// three re-sends the colour sheet, at four bytes per pixel, every time a
    /// mono glyph faults.
    [[nodiscard]] std::uint32_t monoAtlasGeneration() const { return m_fonts->renderer.monoAtlasGeneration(); }

    /// How many times the wide sheet's pixels have changed.
    [[nodiscard]] std::uint32_t wideAtlasGeneration() const { return m_fonts->renderer.wideAtlasGeneration(); }

    /// How many times the colour sheet's pixels have changed.
    [[nodiscard]] std::uint32_t colorAtlasGeneration() const { return m_fonts->renderer.colorAtlasGeneration(); }

    /// Cell geometry in device pixels, for a caller sizing its own viewport.
    [[nodiscard]] int cellWidth() const { return m_fonts->renderer.cellWidth(); }
    [[nodiscard]] int cellHeight() const { return m_fonts->renderer.cellHeight(); }

private:
    // Shared by buildKey and feedKey so the mode gathering is stated once.
    Rendering::GlyphRasterizer& activeRasterizer();

    // Resolves the live selection into per-row spans for the instance builder.
    /// Fills a frame's style from the live configuration: the rules, bold
    /// brightening, the cursor, the links, the storage tube, the contrast floor
    /// and the ground.
    ///
    /// - Parameter options: Filled in place.
    void applyConfiguredFrameStyle(Rendering::TerminalSnapshotOptions& options);
    /// Resolves only local placement; it never mutates or resizes the mirror.
    void updatePresentation();
    void buildSelectionSpans();
    /// Resolves the DEC mode 1001 hilite band into `m_hiliteSpans`.
    ///
    /// Left empty when the host has named no band. The band's shape belongs to
    /// `Rendering::hiliteRegionRowSpans`, so this supplies the terminal's four
    /// scalars and the view offset and derives nothing itself.
    void buildHiliteSpans();

    /// Settles the outstanding terminate, if there is one.
    ///
    /// The first answer is the answer, matching `SessionDirectoryCore`: a
    /// A correlated result followed by the deadline must not be re-read as a
    /// second outcome, and a settled row must not be re-settled by a frame that
    /// was already in flight.
    ///
    /// - Parameter outcome: What the frame or the elapsed wait says.
    void settleTerminate(TerminateOutcome outcome);

    /// What the page reported of a key, as Core's key press.
    ///
    /// - Parameters:
    ///   - keyCode: What the key typed.
    ///   - baseLayoutKey: The standard layout's code point at its position.
    ///   - modifiers: The modifiers held.
    ///   - text: The text it produced, or 0.
    ///   - eventType: Press, repeat or release.
    ///   - physicalKey: The browser code mapped to a layout-independent identity.
    /// - Returns: The press, or `nullopt` for an event that names no key.
    [[nodiscard]] static std::optional<Runtime::KeyPress> keyPress(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, Keys::VirtualKey physicalKey = {});

    /// Sends one input event to the session's pane and appends what is ready
    /// to leave to the frame the page sends.
    ///
    /// - Parameter intent: The event.
    void appendIntent(Protocol::Sync::InputIntent intent);

    /// Sends bytes as they are, as `Raw` events in order.
    ///
    /// - Parameter bytes: The bytes.
    void appendRawInput(std::string_view bytes);

    /// Encodes one key event for the wire, via the shared Core encoder.
    ///
    /// The frontend's own entry point: it reports the browser's key fields as a
    /// ``Runtime::KeyPress`` and hands it to ``Runtime::encodeKey`` with this
    /// terminal, so the web frontend cannot drift from the others on what a key
    /// sends — it names no mode to drift on.
    ///
    /// - Parameters:
    ///   - keyCode: The codePoint the key TYPED — `event.key`, so `:` for
    ///     Shift+`;`. Core reports the unshifted key and carries this as the
    ///     shifted alternate.
    ///   - baseLayoutKey: The standard layout's codePoint for this physical
    ///     position, or 0 when the page cannot resolve one.
    ///   - modifiers: An `Keys::Keymap::keymapModifier*` bitmask.
    ///   - text: The codePoint the key produces, or 0 when it produces none.
    ///   - eventType: Press, repeat, or release.
    ///   - output: Destination for the sequence.
    ///   - physicalKey: The browser code mapped to a layout-independent identity.
    /// - Returns: The byte count written, or 0 when the event is suppressed or
    ///   `output` has no room.
    int encodeKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, std::span<char> output, Keys::VirtualKey physicalKey = {});

    // Bridges Core's synchronous OSC 52 contract to the page's asynchronous one.
    //
    // Declared before the terminal so it outlives it: members are destroyed in
    // reverse, and the terminal holds a checked pointer to this for as long as
    // it exists.
    class Clipboard;
    std::unique_ptr<Clipboard> m_clipboard;
    // Declared before the Terminal so it outlives what points at it: a member
    // is destroyed in reverse declaration order, and the Terminal holds a
    // non-owning pointer to this.
    WebCapabilityPolicy m_capabilityPolicy;
    /// Answers a proportional run's measure in the face the frame draws it
    /// in, so a query and a rewrap agree with the frame. Declared before the
    /// Terminal, which holds a checked pointer to it.
    struct ProportionalMeasurer final : TextMeasureClient {
        WebTerminal* owner = nullptr;
        /// Shapes a run in the face the frame draws.
        ///
        /// - Parameters:
        ///   - codePoints: The run's text.
        ///   - style: The face bits the run is set in.
        ///   - glyphsOut: Receives the shaped glyphs.
        /// - Returns: How many glyphs were written.
        int shapeProportionalRun(std::span<const std::uint32_t> codePoints, ProportionalRunStyle style, std::span<ProportionalShapedGlyph> glyphsOut) override;
        /// Answers the frame's cell advance, in the pixels the glyphs are
        /// shaped in.
        ///
        /// - Returns: One cell's width in device pixels.
        float proportionalCellAdvanceInPixels() override;
    };
    ProportionalMeasurer m_measurer;
    /// This terminal's effect route: counts each bell its program rings, so a
    /// burst within one feed reads as the bells it was rather than one cue.
    /// Declared before the terminal it serves, which must not outlive it.
    class BellRoute final : public EffectRoute {
    public:
        /// Counts one bell, saturating rather than wrapping.
        void ringBell() override
        {
            if (m_bellsRung != UINT32_MAX)
                ++m_bellsRung;
        }

        /// Takes the bells rung since the last take.
        ///
        /// - Returns: How many.
        std::uint32_t take() { return std::exchange(m_bellsRung, 0); }

    private:
        std::uint32_t m_bellsRung = 0;
    };
    BellRoute m_bellRoute;
    std::string m_capturedProgramState;
    std::string m_programMetadataJSON;
    std::vector<std::array<int, 2>> m_progressReports;
    std::string m_takenProgressReports;
    bool m_hasProgressReportOverflow { false };
    Terminal m_terminal;
    // The page is single-threaded and the search executor is pumped on it, so
    // this lock is never contended; Core's search and selection take the
    // terminal's ModelLock, and the page supplies the one it holds.
    ModelLock m_modelLock;
    Search::SearchExecutor m_searchExecutor { Search::SearchExecutor::ExecutionMode::Pumped };
    std::shared_ptr<Search::SearchController> m_searchController;
    Search::Status m_searchStatus { .isComplete = true };
    std::string m_searchStatusJSON;

    /// Returns the controller, creating it on the first request.
    [[nodiscard]] std::shared_ptr<Search::SearchController> searchController();

    /// Constructs a case-sensitive literal request; null clears the search.
    ///
    /// - Parameter literal: The text to find.
    /// - Returns: The request.
    static Search::Request literalSearchRequest(const char* literal);

    /// Projects published hits and reveals only a newly active match.
    void searchDidChange();

    Input::BindingTable m_bindings;
    Input::ChordResolver m_chords { m_bindings };
    std::vector<std::uint8_t> m_bindingBytes;
    // Owns the backing storage `FontStack::face` routes through: `view()`
    // hands out spans and string_views into these strings and vectors, so this
    // must outlive every `FontStack` built from it. Declared before `m_fonts`
    // for exactly that reason — members destroy in reverse declaration order.
    Preferences::FontRoutePreferences m_fontRoutePreferences;
    // Unifont is the fallback rather than the face: it carries the box drawing
    // and symbol coverage a real face usually lacks, so it stays reachable even
    // when the host supplies a font. Declared first — the font rasterizer holds
    // a reference to it, and the renderer holds one to whichever is chosen.
    //
    // The three are grouped and held indirectly because a font-size change
    // rebuilds all of them: each caches metrics taken at construction, and the
    // renderer's reference is fixed there. Rebuilding them as a unit is what
    // stops a renderer measuring cells with one size while a rasterizer draws
    // them at another.
    struct FontStack {
        /// Builds the three rasterizers and the renderer that share one font.
        ///
        /// - Parameters:
        ///   - pixelSize: The em size in device pixels.
        ///   - deviceScale: The display scale `pixelSize` already carries.
        ///     Passed separately because the underline rule's constant term is
        ///     in points and scales with the display, while the size-relative
        ///     term is already in device pixels.
        ///   - lineSpacingCssPixels: Extra space between rows, before the scale.
        ///   - characterSpacingInPixels: The `font.character_spacing` tracking
        ///     in device pixels, which widens the cell and leaves the ink.
        ///   - preferences: The route preferences to draw with; a view whose
        ///     backing storage the caller owns and must outlive `FontStack`.
        ///   - fontVariations: The `font.variations` specification.
        ///   - weights: `font.weight` and `font.bold_weight`.
        ///   - runSubstitution: Whether `font.ligatures` and `font.features`
        ///     leave a run of grid text anything to fuse.
        FontStack(int pixelSize, int deviceScale, double lineSpacingCssPixels, int characterSpacingInPixels, const Rendering::Font::FontFallbackPreferences& preferences, const std::string& fontVariations = std::string(), Rendering::Font::WeightSettings weights = {}, WebFontRasterizer::RunSubstitution runSubstitution = WebFontRasterizer::RunSubstitution::Possible);

        /// The line spacing in device pixels. Declared first so the two
        /// rasterizers below can be constructed from it.
        int lineSpacingInPixels = 0;
        Rendering::UnifontRasterizer unifont;
        WebFontRasterizer face;
        // Box drawing goes through the decorator rather than the face, so a
        // border joins its neighbours instead of showing the face's side
        // bearings as hairline gaps. Declared after `face` and before
        // `renderer`: it holds a reference to the first and the second holds one
        // to it, and members destroy in reverse declaration order.
        //
        // Every frontend does this: macOS calls edgeStretchBoxScratch inline,
        // Linux composes this same decorator. Without it the gap hides here,
        // because WebFontRasterizer routes box code points to the Unifont
        // fallback. That tiles, so no gap appears; it also draws them in a
        // different face from the surrounding text, at whatever weight Unifont
        // has, beside the configured font.
        Rendering::BoxDrawingRasterizer boxes;
        Rendering::SoftwareRenderer renderer;
        /// Face-derived rule weight, shared with the CPU snapshot renderer.
        Rendering::BoxDrawing::BoxStrokeProfile boxStrokeProfile;
    };
    std::unique_ptr<FontStack> m_fonts;
    WebRichText m_richText;
    /// Publishes measured browser typography to the terminal and its Sync replica.
    void publishRichTextTypography();
    std::uint32_t m_fontResourceGeneration = 1;
    /// Renders one CPU frame with a margin drawn inside it.
    ///
    /// The margin is part of the frame rather than pasted around it, so an
    /// overlay that reaches past the grid, such as a search pill on the first
    /// column, is drawn into it while the grid's own layers stay clipped to
    /// the grid box.
    ///
    /// - Parameters:
    ///   - paddingInPixels: The margin in device pixels; zero renders the grid alone.
    ///   - widthOut: The frame's width in device pixels.
    ///   - heightOut: The frame's height in device pixels.
    /// - Returns: Tightly packed RGBA8, or empty when the frame could not be rendered.
    std::vector<std::uint8_t> renderFrame(Rendering::EdgeInsets paddingInPixels, int& widthOut, int& heightOut);
    /// Hands the frame the terminal's search matches, focused and other.
    ///
    /// - Parameter options: The frame options the spans are written into;
    ///   they borrow this terminal's scratch until the next frame.
    void applySearchMatchSpans(Rendering::TerminalSnapshotOptions& options);
    /// Lays the palette out for this frame, or leaves it empty when the palette
    /// belongs to the frontend's own UI. Called from both render paths, because
    /// laying out in one and not the other makes the popover appear on GPU and
    /// vanish on CPU.
    void layoutBeamForFrame();
    /// Lays out the reserved-gesture hint for this frame, as Core answers it
    /// at this tick.
    void layoutHintForFrame();
    [[nodiscard]] Rendering::ChromePlacement hintPlacement() const;
    [[nodiscard]] Rendering::ChromePlacement beamPlacement() const;

    CommandPalette::BeamSession m_beam;
    Rendering::BeamGeometry m_beamGeometry;
    // The reserved-gesture hint drawn into cells. The browser composites chrome
    // into the frame it renders, so this arm has the in-grid surface the way
    // the GTK one does. What it says and for how long are the ladder's.
    Rendering::HintToastGeometry m_hintGeometry;
    // Words until the page says otherwise: a browser on a Mac reports glyphs.
    Input::ModifierVocabulary m_modifierVocabulary = Input::ModifierVocabulary::Words;
    Preferences::BeamSurface m_beamSurface = Preferences::BeamSurface::Auto;
    Preferences::NativeBeam m_nativeBeam = Preferences::NativeBeam::Unavailable;
    /// Which theme is in effect, or -1 before one is chosen. Held so the drill
    /// can tick the current value; the palette itself cannot answer it, because
    /// a theme and an OSC 4 override produce the same colours.
    int m_themeIndex = -1;
    std::vector<std::string> m_fontOptions;
    int m_fontIndex = -1;
    std::string m_beamCommand;
    // The command handed out by takeBeamCommand, kept alive because the caller
    // holds a const char* across the C ABI until its next call.
    std::string m_beamTakenCommand;
    Rendering::TerminalFrameInputs m_frameInputs;
    std::vector<Rendering::CellInstance> m_cells;
    std::vector<Rendering::OverlayInstance> m_overlays;
    std::vector<Rendering::OverlayInstance> m_boxFills;
    std::vector<Rendering::DecorationInstance> m_decorations;
    std::vector<Rendering::GlyphInstance> m_wideGlyphs;
    std::vector<Rendering::GlyphInstance> m_proportionalGlyphs;
    std::vector<Rendering::GlyphInstance> m_proportionalStrips;
    std::vector<Rendering::GlyphInstance> m_ligatureGlyphs;
    std::vector<Rendering::GlyphInstance> m_colorGlyphs;
    int m_cellCount = 0;
    int m_wideGlyphCount = 0;
    int m_proportionalGlyphCount = 0;
    int m_proportionalStripCount = 0;
    int m_ligatureGlyphCount = 0;
    int m_colorGlyphCount = 0;
    int m_overlayCount = 0;
    int m_boxFillCount = 0;
    int m_decorationCount = 0;
    // The cursor tier's tails, clamped as the counts above are: the last
    // instances of each stream, which the GPU path draws as a layer of their
    // own after the heads (InstanceCounts::cursorTier).
    Rendering::InstanceCounts::CursorTier m_cursorTier;
    // The link scan's scratch, held rather than stacked: it runs on every
    // pointer motion, and wasm's default stack does not have room for a full
    // wrapped group. Sized for a large grid's worth of wrapped rows.
    std::vector<std::uint32_t> m_linkScanCodePoints;
    std::vector<std::uint16_t> m_linkScanIDs;
    std::array<char, Ubiquitty::VT::maxLinkURILength> m_linkURI {};
    // One view's selection through Core's Terminal-bound facade — gesture
    // sequencing, word and line growth, wide bounds, the copy walk and the
    // viewport spans are all answered there, as on every other frontend.
    Selection::Session m_selection {};
    std::string m_selectionText;
    std::vector<Rendering::SelectionRowSpan> m_selectionSpans;
    std::vector<RichText::BlockSelection> m_richTextSelections;
    std::vector<Rendering::SelectionRowSpan> m_hiliteSpans;
    std::vector<Rendering::SelectionRowSpan> m_triggerHighlightSpans;
    // The decoded `[appearance] background_image`, as the page delivered it.
    Rendering::BackgroundImagePixels m_backgroundImage;
    std::vector<Rendering::SelectionRowSpan> m_searchMatchSpans;
    std::vector<Rendering::SelectionRowSpan> m_otherSearchMatchSpans;

    // Absolute buffer rows: history first, live screen last. The page speaks in
    // viewport rows, Core selects in these, and mixing the two is what made a
    // selection slide over its text when the view moved.
    [[nodiscard]] int historyRows() const;
    [[nodiscard]] int absoluteRowFor(int visibleRow) const { return visibleRow + historyRows() - m_viewOffset; }

    /// Moves the viewport so `absoluteRow` sits a quarter of the way down it.
    ///
    /// Solves ``absoluteRowFor`` for the offset instead of the row, then goes
    /// through ``scrollBy`` so the move is clamped by the one rule every other
    /// scroll here obeys — a jump that landed outside the retained history would
    /// read as a terminal that has lost it.
    ///
    /// The quarter is the placement macOS jumps to (`beamScrollToAbsoluteRow:`),
    /// stated a second time because it lives in that frontend rather than in
    /// Core: a block's output is the rows after its prompt, so the prompt goes
    /// near the top, and the rows above it are the context that says which
    /// block this is.
    ///
    /// - Parameter absoluteRow: The row to reveal, in the space
    ///   ``Screen::CommandBlock::promptRow`` reports. A row outside the buffer
    ///   scrolls to the nearest end rather than off it.
    void scrollToAbsoluteRow(int absoluteRow);

    /// Places the viewport after output landed beneath it.
    ///
    /// A scrolled-back reader keeps their rows as history accumulates, and a
    /// view at the tail follows it, both decided by Core so the browser agrees
    /// with the desktop arms about when a view snaps during output.
    void followTailOrHoldViewport();

    /// Asks the host for the history a reader's view reached past what this
    /// client holds, by the rule every Sync client shares
    /// (``Protocol::Sync::HistoryPull``). The want waits in the screen
    /// plane's output for the page's next send.
    ///
    /// - Returns: Whether a want was queued.
    [[nodiscard]] bool pullHistory();

    int m_viewOffset = 0;
    /// What the reader's scrolling asked of the pane's history on this
    /// connection.
    Protocol::Sync::HistoryPull m_historyPull;
    FloatSize m_presentationViewport;
    Rendering::RemoteViewportPlacement m_presentation;
    bool m_hasImages = false;
    // The core reports the screen through an observer. Held by value and
    // declared before the core, because the core takes its address at
    // construction and members initialise in declaration order.
    // OSC 50 and the rest of the window seam. Held by value and declared before
    // the Terminal that points at it is cleared in the destructor, for the same
    // reason the mirror client is: a CheckedPtr faults if the pointee dies first.
    class Window final : public WindowClient {
    public:
        explicit Window(WebTerminal* owner)
            : m_owner(owner)
        {
        }
        [[nodiscard]] bool setFont(std::string_view family, double sizePoints, double sizeDelta) override;
        /// Returns to the size the page configured, the family kept.
        ///
        /// - Returns: True: the size is this object's to change.
        [[nodiscard]] bool resetFontSize() override;
        /// Stages a decoded progress report for the page to take.
        ///
        /// - Parameters:
        ///   - state: The decoded state, 0..4.
        ///   - value: The percentage, 0..100, or -1 when omitted.
        void reportProgress(uint8_t state, int value) override
        {
            if (m_owner->m_progressReports.size() < 256)
                m_owner->m_progressReports.push_back({ state, value });
            else
                m_owner->m_hasProgressReportOverflow = true;
        }

    private:
        WebTerminal* m_owner;
    };

    // OSC 7 and OSC 9/777. Both are staged: a notification needs a page-owned
    // API and permission, and the directory is the page's to display.
    class Shell final : public ShellClient {
    public:
        explicit Shell(WebTerminal* owner)
            : m_owner(owner)
        {
        }
        void setCurrentDirectory(std::string_view directory) override
        {
            m_owner->m_currentDirectory.assign(directory.begin(), directory.end());
        }
        void postNotification(std::string_view title, std::string_view body) override
        {
            postNotificationRequest({ .title = title, .body = body, .identifier = {}, .occasion = NotificationOccasion::Always });
        }
        /// Stages a notification for the page to show.
        ///
        /// - Parameter request: The notification as parsed.
        void postNotificationRequest(const NotificationRequest& request) override { m_owner->stageNotification(request); }

    private:
        WebTerminal* m_owner;
    };

    /// One clipboard question the host has put and the page has not answered.
    struct ClipboardServeRequest {
        std::uint32_t id = 0;
        Protocol::Sync::ClipboardRequestKind kind = Protocol::Sync::ClipboardRequestKind::Types;
        std::string mime;
    };

    // How many questions the page keeps. The host bounds what it leaves
    // outstanding, so a queue that reaches this is a host that is not the one
    // this client was written against; the page holds the ones it can answer
    // and lets the rest reach the host's own deadline, rather than growing a
    // list a peer chooses the length of.
    static constexpr std::size_t maxPendingClipboardServeRequests = 8;

    // The host's pending clipboard questions, oldest first, and the answer the
    // page is staging for the oldest. A page reads its clipboard through a
    // promise, so the question being read for has to outlive the arrival of the
    // next one: the answer carries the id the read was started for, and framing
    // it under a newer id would answer the newer question with the older one's
    // bytes and leave the older with no id to be answered under.
    std::deque<ClipboardServeRequest> m_clipboardServeRequests;
    std::vector<Protocol::Sync::ClipboardServeItem> m_clipboardServeItems;
    /// Whether this page's Greet claimed the serving capability.
    ///
    /// Latched at the handshake: a page that never claimed must not answer,
    /// and the claim cannot change under a connection the host already
    /// recorded. bool-ok: it records what the wire agreed, not a flag steering
    /// a call.
    bool m_didClaimClipboardServe = false;

    class SyncObserver final : public Protocol::Sync::SyncClientObserver {
    public:
        explicit SyncObserver(WebTerminal* owner)
            : m_owner(owner)
        {
        }
        /// Records a bell delivered by the remote session.
        void onBell() override { m_owner->noteBell(); }

        /// Directory state is recorded beside the screen, not parsed from
        /// terminal output on a passive client.
        ///
        /// - Parameter facts: The host's pane metadata, including its working directory.
        void onPaneFacts(uint32_t sessionID, const Protocol::Sync::PaneFacts& facts) override
        {
            if (auto* view = m_owner->workspacePane(sessionID))
                view->m_currentDirectory = facts.currentDirectory;
        }

        /// Borrows a retained pane for checkpoints, including after reconnect.
        /// - Parameter sessionID: The host session, or zero for initial renderer capabilities.
        /// - Returns: The retained terminal, or null when no view is attached.
        Ubiquitty::Terminal* screenTerminal(uint32_t sessionID) override
        {
            if (!sessionID && m_owner->m_connectionMode == ConnectionMode::Workspace)
                return &m_owner->m_terminal; // Renderer capabilities before the first bind.
            auto* view = m_owner->workspacePane(sessionID);
            return view ? &view->m_terminal : nullptr;
        }

        /// A new binding has not received this view's viewport yet.
        /// - Parameter sessionID: The session whose viewport must be published.
        void onPaneBound(uint32_t sessionID) override
        {
            if (auto* view = m_owner->workspacePane(sessionID)) {
                view->m_sentViewport.reset();
                view->m_resizeCallID.reset();
            }
        }

        /// A program on the host asked for a clipboard the host does not have.
        ///
        /// Queued rather than answered: reading a browser clipboard is a
        /// promise, and the host is waiting on a frame rather than on this
        /// returning. Queued rather than substituted for the one already
        /// there, because that one may be the question a read is in flight
        /// for, and its bytes must go back under its own id. Two programs
        /// reading a clipboard in the same shell put two questions, and the
        /// host holds both open.
        ///
        /// Past the page's own bound the question is dropped, and the host's
        /// deadline answers it. The alternative is a queue whose length a peer
        /// picks.
        ///
        /// - Parameter request: What the host wants, and the id to answer with.
        void onClipboardRequest(const Protocol::Sync::ClipboardRequestMessage& request) override
        {
            if (m_owner->m_clipboardServeRequests.size() >= maxPendingClipboardServeRequests)
                return;
            m_owner->m_clipboardServeRequests.push_back(
                ClipboardServeRequest { request.requestID, request.kind, request.mime });
        }

        /// Stages a complete host-admitted write through the browser's route.
        ///
        /// - Parameters:
        ///   - buffer: The original selector; unsupported selections stay local.
        ///   - items: Borrowed complete representations, copied by the route.
        void onClipboardWriteItems(ClipboardBuffer buffer, std::span<const ClipboardItem> items) override
        {
            auto& terminal = m_owner->m_terminal;
            if (terminal.clipboardClient && terminal.osc52ClipboardWritePolicy != OSC::ClipboardWritePolicy::Deny)
                terminal.clipboardClient->writeClipboardItems(buffer, items);
        }

        /// A checkpoint or an update that moved the palette carries the HOST's
        /// palette, which replaces whatever the client had — so a theme the
        /// user picked here would last only until the next one, and checkpoints
        /// arrive on every reconnect and every resync. The theme would revert
        /// within seconds and look like it had never applied.
        ///
        /// Reasserted rather than sent to the host: a theme is this client's
        /// presentation choice, the same class as titlebar_style and
        /// color_space, neither of which crosses the wire. Two clients on one
        /// session can want different colours, and the host has no business
        /// arbitrating that.
        /// - Parameter sessionID: The session whose picture changed.
        void onScreenChanged(uint32_t sessionID) override
        {
            // Only an admitted attachment receives a picture. Its first
            // picture retires the pending notice even when approval and the
            // checkpoint reach presentation in one batch.
            m_owner->m_hostNotice.clear();
            m_owner->m_consentStatus.reset();
            if (auto* view = m_owner->workspacePane(sessionID)) {
                view->reapplyTheme();
                view->followTailOrHoldViewport();
            }
        }

        /// Marks the next frame as carrying inline images.
        ///
        /// `SyncClientCore` reassembles IMAGE chunks and applies placements into
        /// the mirrored Terminal, so the pixels are already where the renderer
        /// looks by the time this runs. What the frontend owes is the repaint:
        /// an image arrives on its own frame, with no cell change to drive one,
        /// so a client that only redraws on grid deltas holds the frame it had
        /// and the picture appears whenever something else happens to move.
        void onImagesChanged() override
        {
            m_owner->m_hasPendingImageFrame = true;
            for (auto* pane : m_owner->m_workspacePanes)
                pane->m_hasPendingImageFrame = true;
        }

        // Own-attachment verdicts belong to the observer. Human questions
        // arrive separately as host notifies and are retained by the carrier.

        /// Records that the host is holding a request for a human's consent.
        ///
        /// This notice describes attachment consent only; typed termination
        /// is settled by its own correlated result.
        ///
        /// - Parameter sessionID: The held session.
        void onConsentPending(std::uint32_t sessionID) override
        {
            (void)sessionID;
            m_owner->m_hostNotice = Protocol::Sync::attachHeldNotice();
            m_owner->m_consentStatus = Protocol::Sync::ConsentStatusPhase::Pending;
        }

        /// Records that the host refused this attach, and why.
        ///
        /// - Parameters:
        ///   - sessionID: The session whose attachment was refused.
        ///   - reason: Declined or timed out — different problems with
        ///     different answers, so the wording distinguishes them.
        void onConsentDenied(std::uint32_t sessionID, Protocol::Sync::ConsentStatusPhase reason) override
        {
            (void)sessionID;
            m_owner->m_hostNotice = Protocol::Sync::consentDeniedNotice(reason);
            m_owner->m_consentStatus = reason;
        }

        /// Records that the host refused this client's handshake, and why.
        ///
        /// A refusal while a terminate is outstanding is that request being
        /// refused — its token or its scope — and the page must show the reason
        /// rather than ask again.
        ///
        /// - Parameter reason: The refusal to word. Most of these are about a
        ///   token and one is not, which is the distinction a viewer acts on.
        void onRefused(Protocol::Sync::ByeReason reason) override
        {
            if (reason != Protocol::Sync::ByeReason::NoConsent
                || (m_owner->m_consentStatus != Protocol::Sync::ConsentStatusPhase::Denied && m_owner->m_consentStatus != Protocol::Sync::ConsentStatusPhase::Expired))
                m_owner->m_hostNotice = Protocol::Sync::byeNotice(reason);
            m_owner->settleTerminate(TerminateOutcome::Refused);
        }

    private:
        WebTerminal* m_owner;
    };

    std::vector<std::uint8_t> m_pendingHostFrame;
    Window m_window { this };
    Shell m_shell { this };
    std::string m_currentDirectory;
    std::string m_hostNotice;
    /// What ``inputInDoubtNotice`` last read.
    Session::InputInDoubtNotice m_inputInDoubtNotice;
    std::optional<Protocol::Sync::ConsentStatusPhase> m_consentStatus;
    std::string m_notificationTitle;
    std::string m_notificationBody;
    std::string m_notificationTag;
    std::string m_pendingFontFamily;
    SyncObserver m_syncObserver { this };
    // Declared before the core, which keeps a store that writes into it.
    std::unique_ptr<Session::ResumeRecordSlot> m_resumeSlot;
    WebTerminal* m_workspace = nullptr;
    std::uint32_t m_workspaceSessionID = 0;
    std::uint32_t m_requestedWorkspaceID = 0;
    ConnectionMode m_connectionMode = ConnectionMode::Session;
    std::vector<WebTerminal*> m_workspacePanes;
    std::unique_ptr<Protocol::Sync::SyncClientCore> m_ownedSync;
    Protocol::Sync::SyncClientCore& m_sync;
    /// Finds a renderer attached to this carrier.
    /// - Parameter sessionID: The host session identity.
    /// - Returns: The borrowed renderer, or null for an unvisited workspace pane.
    [[nodiscard]] WebTerminal* workspacePane(std::uint32_t sessionID)
    {
        if (m_connectionMode == ConnectionMode::Session)
            return this;
        for (auto* pane : m_workspacePanes) {
            if (pane->m_workspaceSessionID == sessionID)
                return pane;
        }
        return nullptr;
    }
    bool m_areProportionalFacesOwed = false;
    // Once this terminal mirrors a host, only a host picture may resize its
    // cells, including while disconnected. Window geometry is a separate fact.
    bool m_isHostMirror = false;
    std::optional<Protocol::Sync::Viewport> m_requestedViewport;
    std::optional<Protocol::Sync::Viewport> m_sentViewport;
    std::optional<std::uint64_t> m_resizeCallID;
    std::vector<std::uint8_t> m_frame;
    // The subscription's monotonically allocated identity, and how many whole
    // answers the host's listing has given.
    std::uint32_t m_sessionListRequestID = 0;
    std::uint32_t m_hostAnswerGeneration = 0;
    // The host's tree as this connection was sent it, the rows the person
    // has closed, and the text the last outline was handed out as.
    Session::HostListing m_hostListing;
    Runtime::HostOutlineRequest m_hostOutlineRequest;
    std::uint32_t m_hostOutlineGeneration = 0;
    std::string m_hostOutlineJSON;
    std::string m_hostWorkspaceJSON;
    std::vector<Codec::JSON::Value> m_webConsentQuestions;
    std::vector<std::string> m_pendingWebCalls;
    std::vector<std::string> m_webCallResults;
    std::string m_webCallResultJSON;
    std::string m_hostCallRefusal;
    // The changes asked of the host's structure that are out, and how the
    // last one ended.
    /// ``requestHostStructureChange`` with the token a change that ends
    /// sessions is sent with.
    ///
    /// - Parameters:
    ///   - operation: A `Runtime::StructureOperation`.
    ///   - target: The row's identity.
    ///   - text: The label or the name.
    ///   - tags: The tags, one a line.
    ///   - window: The window a moved tab is to stand in.
    ///   - index: The place it takes there.
    ///   - confirmationToken: The token, or zero.
    /// - Returns: The request's number.
    [[nodiscard]] std::uint32_t requestConfirmedHostStructureChange(int operation, const char* target, const char* text, const char* tags, const char* window, int index, std::uint64_t confirmationToken);
    Runtime::StructureCalls m_structureCalls;
    Runtime::StructureResult m_structureResult;
    std::uint32_t m_hostStructureGeneration = 0;
    std::string m_hostStructureResultJSON;
    std::string m_hostDestructiveConfirmationJSON;
    std::string m_hostTerminateRefusal;
    /// The sessions a confirmed terminate has still to ask for, in order.
    std::vector<std::uint32_t> m_owedTerminations;

    /// Keeps how a structure change ended.
    ///
    /// - Parameter result: How it ended.
    void noteHostStructureSettled(Runtime::StructureResult result);

    /// Reads the answers to this connection's calls and assembles the host's
    /// tree again when what it is built from moved.
    void serviceHostListing();
    /// Reports the latest requested window geometry under the granted role.
    /// An Agent has at most one override call in flight; later sizes coalesce.
    void serviceResize();
    // The outstanding terminate and its answer. The id stays after the settle so
    // the page can say which row the outcome belongs to; Pending is what says
    // there is still an ask.
    std::uint32_t m_terminateSessionID = 0;
    TerminateOutcome m_terminateOutcome = TerminateOutcome::Pending;
    std::uint32_t m_terminateGeneration = 0;
    // The exact outstanding operation, never inferred from the selected row.
    std::string m_terminateRequestID;
    std::uint64_t m_nextTerminateRequestID = 0;
    // The per-host pairing, and the page's store standing behind it. The map is
    // the bytes the page handed over and the bytes it is owed back; nothing here
    // reads inside them.
    Session::RememberedSessions m_rememberedSessions;
    std::unordered_map<std::string, std::string> m_hostRecords;
    Session::AttachDecision m_decision;
    std::vector<std::uint8_t> m_image;
    int m_imageWidth = 0;
    int m_imageHeight = 0;
    int m_glyphScale = 1;
    bool m_hasUnheardBell = false;
    mutable std::string m_composedTitle;
    bool m_isFocused = true; // a page that never told us is not a page drawing an unfocused cursor
    double m_fontSize = 0.0; // CSS pixels; the device size is this times the scale
    // Core's four resolved defaults, which are not one value: top is zero.
    static constexpr Preferences::Values::PaddingEdges s_defaultPadding = Preferences::Defaults::paddingEdges(Preferences::currentDefaultsTarget());
    Rendering::EdgeInsets m_paddingInsets {
        static_cast<float>(s_defaultPadding.left), static_cast<float>(s_defaultPadding.right),
        static_cast<float>(s_defaultPadding.top), static_cast<float>(s_defaultPadding.bottom)
    };
    double m_lineSpacing = Preferences::Defaults::lineSpacing; // CSS pixels between rows
    // `font.character_spacing` in device pixels, from Core's fold; the font
    // stack is rebuilt when it changes because every cell is measured with it.
    int m_characterSpacingInPixels = 0;
    // The `font.variations` specification, unparsed. Held as the text the reader
    // wrote so a stack rebuilt after a size change carries the same axes.
    std::string m_fontVariations;
    // `font.weight` and `font.bold_weight`, held so a stack rebuilt after a size
    // change draws at the same weights.
    Rendering::Font::WeightSettings m_fontWeights;
    // The CSS half of the list above, composed when it is set.
    std::string m_fontVariationSettingsCSS;
    // `font.features` and its descriptor half, the same pair as the axes above.
    std::string m_fontFeatures;
    std::string m_fontFeatureSettingsCSS;
    // Folded into the descriptor above rather than held for a lever of its own,
    // because this arm has no shaper to tell.
    Rendering::Ligatures m_ligatures = Rendering::Ligatures::Enabled;
    // Core's fold of the live document, re-read when the configuration epoch
    // moves; every frame's style is read from it, so a document the page hands
    // in after construction reaches the next frame.
    Rendering::RenderConfiguration m_configuration {};
    std::uint64_t m_configurationEpoch = 0;
    // The pointer ladder's state -- the open selection gesture, the mode-1001
    // gesture, the motion dedup, the scroll residue -- kept by Core's ladder
    // so the page carries no copy of the rules the other frontends run.
    Input::PointerLadder m_pointerLadder;
    int m_pointerVerdict = 0;
    std::vector<std::uint8_t> m_pageImage; // the frame with the padding drawn inside it
    int m_pageWidth = 0;
    int m_pageHeight = 0;
    bool m_hasPendingImageFrame = false; // an IMAGE arrived; the next frame must redraw
    double m_initialFontSize = 0.0;
    int m_fontPixelSize = 0; // device pixels; what the stack was built at
};

} // namespace Ubiquitty::Web
