// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/Web/WebExports.cpp — the wasm entry points.
//
// Conversions only: pointers, lengths, and enum values crossing the C ABI. Every
// decision belongs to `WebTerminal`, which a ctest can drive without a browser.
//
// A returned pointer addresses the wasm heap and stays valid until the next call
// that can reallocate, so a caller reads it before making one.
//

#include "Core/Rendering/CellInstance.h"
#include "Core/Rendering/RenderPathMarker.h"
#include "PAL/PAL.h"
#include "Platform/Web/WebTerminal.h"

#include "Core/Codec/JSON.h"
#include "Core/Diagnostics/EscapeDecode.h"
#include "Core/Input/Keybindings.h"
#include "Core/Input/PointerInput.h"
#include "Core/Keys/KeyTranslation.h"
#include "Core/Keys/Keymap.h"
#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/EffectiveValue.h"
#include "Core/Preferences/Schema.h"
#include "Core/Preferences/SnapshotConfigurationFlags.h"
#include "Core/Protocol/Sync/NativeAttachment.h"
#include "Core/Protocol/Sync/WireVersion.h"
#include "Core/Runtime/SessionListWords.h"
#include "Core/Session/RememberedSessions.h"
#include "Core/Themes/Themes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define UBIQUITTY_WEB_EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define UBIQUITTY_WEB_EXPORT
#endif

#ifdef __EMSCRIPTEN__
// The tab's session storage, keyed by the page's name for the window's host.
// One code unit per byte, because a record holds zero bytes and any text
// encoding would reinterpret them. Every call is synchronous, so a write that
// returns 1 is held by the browser when the record store reports a commit.
// clang-format off
EM_JS(int, webResumeSlotWrite, (const char* key, const std::uint8_t* begin, const std::uint8_t* end), {
    try {
        // Each byte widened to one UTF-16 code unit below 256, never a surrogate.
        const text = new TextDecoder('utf-16le').decode(Uint16Array.from(HEAPU8.subarray(begin, end)));
        sessionStorage.setItem(UTF8ToString(key), text);
        return 1;
    } catch (error) {
        return 0;
    }
});

EM_JS(int, webResumeSlotLength, (const char* key), {
    try {
        const text = sessionStorage.getItem(UTF8ToString(key));
        return text === null ? -1 : text.length;
    } catch (error) {
        return -1;
    }
});

EM_JS(int, webResumeSlotRead, (const char* key, std::uint8_t* out, int capacity), {
    try {
        const text = sessionStorage.getItem(UTF8ToString(key));
        if (text === null || text.length > capacity)
            return -1;
        for (let index = 0; index < text.length; ++index)
            HEAPU8[out + index] = text.charCodeAt(index) & 0xff;
        return text.length;
    } catch (error) {
        return -1;
    }
});

EM_JS(int, webResumeSlotErase, (const char* key), {
    try {
        sessionStorage.removeItem(UTF8ToString(key));
        return 1;
    } catch (error) {
        return 0;
    }
});
// clang-format on
#endif

namespace {
#ifdef __EMSCRIPTEN__
/// The window's resume record in the tab's session storage.
class SessionStorageResumeSlot final : public Ubiquitty::Session::ResumeRecordSlot {
public:
    explicit SessionStorageResumeSlot(std::string key)
        : m_key(std::move(key))
    {
    }

    bool write(std::span<const std::uint8_t> bytes) override
    {
        return bytes.size() <= static_cast<std::size_t>(std::numeric_limits<int>::max())
            && webResumeSlotWrite(m_key.c_str(), bytes.data(), bytes.data() + bytes.size()) == 1;
    }

    std::optional<std::vector<std::uint8_t>> read(std::size_t maxBytes) override
    {
        const int length = webResumeSlotLength(m_key.c_str());
        if (length < 0 || static_cast<std::size_t>(length) > maxBytes)
            return std::nullopt;
        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
        if (webResumeSlotRead(m_key.c_str(), bytes.data(), length) != length)
            return std::nullopt;
        return bytes;
    }

    bool erase() override { return webResumeSlotErase(m_key.c_str()) == 1; }

private:
    std::string m_key;
};

/// Reads 32 hexadecimal digits, high half first, as the page stores an instance.
std::optional<Ubiquitty::Protocol::Sync::ID128> parseInstance(std::string_view text)
{
    if (text.size() != 32)
        return std::nullopt;
    std::uint64_t halves[2] {};
    for (std::size_t index = 0; index < 32; ++index) {
        const char digit = text[index];
        const int value = digit >= '0' && digit <= '9' ? digit - '0' : digit >= 'a' && digit <= 'f' ? digit - 'a' + 10
                                                                                                    : -1;
        if (value < 0)
            return std::nullopt;
        halves[index / 16] = halves[index / 16] << 4 | static_cast<std::uint64_t>(value);
    }
    return Ubiquitty::Protocol::Sync::ID128 { .low = halves[1], .high = halves[0] };
}

/// Writes an instance as `parseInstance` reads it.
std::string formatInstance(Ubiquitty::Protocol::Sync::ID128 instance)
{
    static constexpr char digits[] = "0123456789abcdef";
    std::string text(32, '0');
    for (std::size_t index = 0; index < 16; ++index) {
        text[15 - index] = digits[(instance.high >> (index * 4)) & 15];
        text[31 - index] = digits[(instance.low >> (index * 4)) & 15];
    }
    return text;
}
#endif

// The instance ``ubiquittyWebRestoreResume`` last answered, held so the
// pointer it returns stays valid until the next call.
std::string restoredInstance;

// A workspace owns its carrier before its borrowed pane views. JavaScript
// selects a view before each synchronous call, including render and input.
std::unique_ptr<Ubiquitty::Web::WebTerminal> carrier;
std::unordered_map<std::uint32_t, std::unique_ptr<Ubiquitty::Web::WebTerminal>> workspacePanes;
Ubiquitty::Web::WebTerminal* terminal = nullptr;
// The frame the last `build*` produced. Held so its length is a separate query
// rather than an out-parameter across the C ABI.
const std::vector<std::uint8_t>* frame = nullptr;
// The document ``ubiquittyWebStateSnapshotFlags`` last wrote, held so the
// pointer it returns stays valid until the next call.
std::string statedSnapshotDocument;
// A pointer-lock chord's key facts, as Core takes them. Declared here rather
// than beside the entry points that call it: it returns a C++ type, and inside
// the extern "C" block it would be given C linkage it cannot have.
Ubiquitty::Input::PointerLockKeyState pointerLockKeys(int isControl, int isMeta, int isShift, int isAlternate, int isAnyKey)
{
    Ubiquitty::Input::PointerLockKeyState keys;
    keys.isControlHeld = isControl != 0;
    keys.isCommandHeld = isMeta != 0;
    keys.isShiftHeld = isShift != 0;
    keys.isOptionHeld = isAlternate != 0;
    keys.isAnyNonModifierKeyHeld = isAnyKey != 0;
    return keys;
}
}

namespace {
// Only client rendering preferences cross this boundary; host and process
// configuration stays with the host. Values and limits come from Core.
constexpr Ubiquitty::Preferences::Key webRenderingKeys[] = {
    Ubiquitty::Preferences::Key::FontProportionalFamily,
    Ubiquitty::Preferences::Key::FontProportionalSize,
    Ubiquitty::Preferences::Key::FontLigatures,
    Ubiquitty::Preferences::Key::FontFeatures,
    Ubiquitty::Preferences::Key::FontCharacterSpacing,
    Ubiquitty::Preferences::Key::FontWeight,
    Ubiquitty::Preferences::Key::FontBoldWeight,
    Ubiquitty::Preferences::Key::UnderlineThickness,
    Ubiquitty::Preferences::Key::UnderlineOffset,
    Ubiquitty::Preferences::Key::UnderlineSkipInk,
    Ubiquitty::Preferences::Key::UnderlineFollowsInk,
    Ubiquitty::Preferences::Key::UnderlineSkipInkPad,
    Ubiquitty::Preferences::Key::UnderlineLinks,
};

Ubiquitty::Codec::JSON::Value preferenceJSON(const Ubiquitty::Preferences::Value& value)
{
    using Ubiquitty::Codec::JSON::Value;
    using Ubiquitty::Preferences::SerializeKind;
    switch (value.kind) {
    case SerializeKind::Bool:
        return Value::boolean(value.boolean);
    case SerializeKind::Int:
        return Value::number(static_cast<double>(value.integer));
    case SerializeKind::Double:
        return Value::number(value.number);
    default:
        return Value::string(value.text);
    }
}
}

extern "C" {

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetPreferenceBlob(const char* name, const char* bytes, int length)
{
    // The browser's answer to "where does configuration come from". A desktop
    // reads a file; a page has no file and hands the bytes in under a name, and
    // Core asks for them by that name through the same PAL seam either way.
    //
    if (!name || length < 0 || (!bytes && length > 0))
        return;
    Ubiquitty::Wasm::preferenceBlobs()[name].assign_range(
        std::span { reinterpret_cast<const std::byte*>(bytes), static_cast<std::size_t>(length) });
    // The configuration blob is handed to Core whole, before a terminal exists
    // or while one runs: Core parses it, and the terminal reads the new fold at
    // its next frame.
    if (std::string_view { name } == Ubiquitty::PAL::configurationBlobKey.name)
        (void)Ubiquitty::Preferences::configureFromStoredDocument(Ubiquitty::Preferences::ParseMode::Permissive);
}

// The headless snapshot's configuration flags — `--bg-opacity`, `--tek-glow`,
// the padding — written into the case's document by the Core helper every
// software arm uses, so the shim hands Core one document rather than threading
// a flag beside it. `words` is the flags and their values, one per line.
// Returns the document, or null when a flag did not parse; valid until the
// next call.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebStateSnapshotFlags(const char* document, const char* words)
{
    if (!document || !words)
        return nullptr;
    std::vector<std::string> lines;
    for (std::string_view rest { words }; !rest.empty();) {
        const std::size_t end = rest.find('\n');
        lines.emplace_back(rest.substr(0, end));
        rest = end == std::string_view::npos ? std::string_view {} : rest.substr(end + 1);
    }
    Ubiquitty::Preferences::SnapshotConfigurationFlags flags;
    for (std::size_t index = 0; index < lines.size(); ++index) {
        const auto next = [&]() -> const char* { return index + 1 < lines.size() ? lines[++index].c_str() : nullptr; };
        if (Ubiquitty::Preferences::parseSnapshotConfigurationFlag(lines[index], next, flags) != Ubiquitty::Preferences::SnapshotFlagParse::Consumed)
            return nullptr;
    }
    std::optional<std::string> stated = Ubiquitty::Preferences::stateSnapshotConfigurationFlags(flags, document);
    if (!stated)
        return nullptr;
    statedSnapshotDocument = std::move(*stated);
    return statedSnapshotDocument.c_str();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebCreate(int rows, int columns, int glyphScale)
{
    frame = nullptr;
    workspacePanes.clear();
    carrier = std::make_unique<Ubiquitty::Web::WebTerminal>(rows, columns, glyphScale);
    terminal = carrier.get();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebCreateWorkspace(int rows, int columns, int glyphScale)
{
    frame = nullptr;
    workspacePanes.clear();
    carrier = std::make_unique<Ubiquitty::Web::WebTerminal>(rows, columns, glyphScale, Ubiquitty::Web::WebTerminal::ConnectionMode::Workspace);
    terminal = carrier.get();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebCreateWorkspacePane(std::uint32_t sessionID, int rows, int columns, int glyphScale)
{
    if (!carrier || !sessionID || workspacePanes.contains(sessionID) || workspacePanes.size() >= 256)
        return 0;
    auto pane = std::make_unique<Ubiquitty::Web::WebTerminal>(rows, columns, glyphScale, Ubiquitty::Web::WebTerminal::ConnectionMode::Session, carrier.get(), sessionID);
    terminal = pane.get();
    workspacePanes.emplace(sessionID, std::move(pane));
    return 1;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebSelectWorkspacePane(std::uint32_t sessionID)
{
    const auto found = workspacePanes.find(sessionID);
    if (sessionID && found == workspacePanes.end())
        return 0;
    terminal = sessionID ? found->second.get() : carrier.get();
    return terminal ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebDestroyWorkspacePane(std::uint32_t sessionID)
{
    const auto found = workspacePanes.find(sessionID);
    if (found == workspacePanes.end())
        return;
    if (terminal == found->second.get())
        terminal = carrier.get();
    workspacePanes.erase(found);
    frame = nullptr;
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetWorkspaceID(std::uint32_t workspaceID)
{
    if (carrier)
        carrier->setWorkspaceID(workspaceID);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetWorkspacePaneVisible(int isVisible)
{
    if (terminal)
        terminal->setWorkspacePaneView(isVisible ? Ubiquitty::Protocol::Sync::ViewState::Live : Ubiquitty::Protocol::Sync::ViewState::Dormant);
}

// The window's background image, as an image file's bytes: a page has no path
// to read `[appearance] background_image` from. Empty clears it; 0 when the
// bytes do not decode.
UBIQUITTY_WEB_EXPORT int ubiquittyWebSetBackgroundImage(const unsigned char* bytes, int length)
{
    if (!terminal || length < 0 || (!bytes && length > 0))
        return 0;
    return terminal->setBackgroundImage({ bytes, static_cast<std::size_t>(length) }) ? 1 : 0;
}

// Installs the window's resume record before the first greeting, under the
// session-storage key the page names for this window and host, and draws the
// stored picture. `clientInstance` is the instance the page stored for the
// window, empty for none. Returns the instance the window greets as, for the
// page to store; empty when nothing was installed.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebRestoreResume(const char* key, const char* clientInstance)
{
    restoredInstance.clear();
#ifdef __EMSCRIPTEN__
    if (!terminal || !key || !key[0])
        return "";
    const auto stored = clientInstance ? parseInstance(clientInstance) : std::nullopt;
    if (!terminal->restoreResume(std::make_unique<SessionStorageResumeSlot>(key), stored.value_or(Ubiquitty::Protocol::Sync::ID128 {})))
        return "";
    restoredInstance = formatInstance(terminal->clientInstance());
#else
    (void)key;
    (void)clientInstance;
#endif
    return restoredInstance.c_str();
}

// Writes the window's resume record now; the page calls it as it is hidden.
UBIQUITTY_WEB_EXPORT void ubiquittyWebPersistResume()
{
    if (terminal)
        terminal->persistResume();
}

// Whether the picture on screen is the stored one, awaiting its connection.
UBIQUITTY_WEB_EXPORT int ubiquittyWebShowsRestoredPicture() { return terminal && terminal->showsRestoredPicture() ? 1 : 0; }

UBIQUITTY_WEB_EXPORT void ubiquittyWebResize(int rows, int columns)
{
    if (terminal)
        terminal->resize(rows, columns);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetPresentationViewport(float width, float height)
{
    if (terminal)
        terminal->setPresentationViewport(width, height);
}

UBIQUITTY_WEB_EXPORT float ubiquittyWebPresentationScale() { return terminal ? terminal->presentation().scale : 1.0f; }
UBIQUITTY_WEB_EXPORT float ubiquittyWebPresentationOriginX() { return terminal ? terminal->presentation().origin.x : 0.0f; }
UBIQUITTY_WEB_EXPORT float ubiquittyWebPresentationOriginY() { return terminal ? terminal->presentation().origin.y : 0.0f; }
UBIQUITTY_WEB_EXPORT float ubiquittyWebCursorCellX() { return terminal ? terminal->cursorCellRect().origin.x : 0.0f; }
UBIQUITTY_WEB_EXPORT float ubiquittyWebCursorCellY() { return terminal ? terminal->cursorCellRect().origin.y : 0.0f; }

// The wire the page reads instances over is Core's structs verbatim, so the
// page's stride constants must equal Core's sizeof — a page built against a
// stale stride reads fields from the wrong offsets and draws garbage that no
// assert catches. The page compares these at startup and refuses to run on a
// mismatch.
UBIQUITTY_WEB_EXPORT int ubiquittyWebOverlayInstanceStride() { return static_cast<int>(sizeof(Ubiquitty::Rendering::OverlayInstance)); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebDecorationInstanceStride() { return static_cast<int>(sizeof(Ubiquitty::Rendering::DecorationInstance)); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebGlyphInstanceStride() { return static_cast<int>(sizeof(Ubiquitty::Rendering::GlyphInstance)); }

UBIQUITTY_WEB_EXPORT void ubiquittyWebFeed(const char* bytes, int length)
{
    // The length crosses the wasm boundary signed, and a negative one cast
    // to size_t is a span reaching most of the address space.
    if (length < 0)
        return;
    if (terminal)
        terminal->feed({ bytes, static_cast<std::size_t>(length) });
}

// The same text with its C-string escapes decoded first — `\e[4m` becomes the
// four bytes it names rather than four characters the terminal prints. Every
// other frontend's headless entry point decodes with this function; a caller
// re-spelling the table in another language gets the two-character escapes
// right and `\xHH` wrong, and the result is a screen full of literal escape
// text that reads as a rendering difference.
UBIQUITTY_WEB_EXPORT void ubiquittyWebFeedEscaped(const char* text)
{
    if (!terminal || !text)
        return;
    const std::string decoded = Ubiquitty::Diagnostics::decodeEscapes(text);
    terminal->feed(decoded);
}

// Returns the RGBA8 image base, or null for a degenerate grid. The width and
// height queries describe the image this call produced, so they follow it.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebRender()
{
    if (!terminal)
        return nullptr;
    const std::vector<unsigned char>& image = terminal->render();
    return image.empty() ? nullptr : image.data();
}

// The same frame with the padding drawn around it, for a caller capturing what
// a viewer sees rather than feeding a canvas the page has already inset.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebRenderPage()
{
    if (!terminal)
        return nullptr;
    const std::vector<unsigned char>& image = terminal->renderPage();
    return image.empty() ? nullptr : image.data();
}

// Names the path the wasm module renders through, so a harness attributes the
// frame to a renderer instead of to the arm that asked for it. The module draws
// with Core's CPU rasteriser; the canvas and WebGL compositors the live page can
// use are not what a snapshot exercises, and an arm that cannot say so reads as
// though it covered them.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebRenderPathMarker()
{
    static const std::string marker = Ubiquitty::Rendering::renderPathMarkerLine(
        Ubiquitty::Rendering::CellBuilder::Core, Ubiquitty::Rendering::FrameCompositor::Software, Ubiquitty::Rendering::FrameEncoder::Native);
    return marker.c_str();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebPageWidth() { return terminal ? terminal->pageWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPageHeight() { return terminal ? terminal->pageHeight() : 0; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebImageWidth() { return terminal ? terminal->imageWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebImageHeight() { return terminal ? terminal->imageHeight() : 0; }
// --- Attached mode --------------------------------------------------------
// Each `build*` returns a frame base; `ubiquittyWebFrameLength` gives its extent.
// One buffer serves them all, so a caller sends before building again.

UBIQUITTY_WEB_EXPORT int ubiquittyWebFeedFromHost(const char* bytes, int length)
{
    // The length crosses the wasm boundary signed, and a negative one cast
    // to size_t is a span reaching most of the address space.
    if (length < 0)
        return 0;
    return (terminal && terminal->feedFromHost({ bytes, static_cast<std::size_t>(length) })) ? 1 : 0;
}

// `sessionID` is 0 to start a session, or an id a previous
// `ubiquittyWebSessionID` reported, to reattach that session across a reload.
//
// `workspaceName` names the workspace to attach to or create, empty for an
// unnamed session; `endsWhenDetached` nonzero asks the host to end a session
// this Greet creates when its last human leaves. Both are read by the host only
// on a create — a reattach observes the session it finds.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildHello(
    const char* authToken, int sessionID, int clipboardServing,
    const char* workspaceName, int endsWhenDetached)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildHello(authToken, static_cast<unsigned int>(sessionID),
        clipboardServing ? Ubiquitty::Web::WebTerminal::ClipboardServing::Enabled
                         : Ubiquitty::Web::WebTerminal::ClipboardServing::Disabled,
        workspaceName,
        endsWhenDetached ? Ubiquitty::Web::WebTerminal::SessionLifetime::EndsWhenDetached
                         : Ubiquitty::Web::WebTerminal::SessionLifetime::Persists);
    return frame->empty() ? nullptr : frame->data();
}

// The frames the client owes the host — the screen plane's acknowledgements
// and resyncs — taken after feeding host bytes and whenever
// ubiquittyWebScreenTickDelay says one is due. Null when nothing is owed.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebTakePendingHostFrame(int pendingOutboundBytes)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->takePendingHostFrame(static_cast<std::size_t>(std::max(0, pendingOutboundBytes)));
    return frame->empty() ? nullptr : frame->data();
}

// Milliseconds until the screen plane owes the host an acknowledgement, or -1
// when it owes none. The page arms a timer for it and then takes the frames.
UBIQUITTY_WEB_EXPORT int ubiquittyWebScreenTickDelay()
{
    return terminal ? terminal->screenTickDelayMilliseconds() : -1;
}

// Nonzero when the host reported an optimised build. A slow host and an
// unoptimised one look identical from here, and the page says which.
UBIQUITTY_WEB_EXPORT int ubiquittyWebHostIsOptimised()
{
    return (terminal && terminal->hostIsOptimised()) ? 1 : 0;
}

// The host's verdict on this attach — held for consent, or refused — or "" when
// it raised none. A held attach delivers no checkpoint, so the page has nothing
// else to distinguish it from a host that is down.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostNotice()
{
    return terminal ? terminal->hostNotice() : "";
}

// Core's notice while some of what was typed may not have reached the host,
// each part read afresh and valid until the next of these calls; "" while
// nothing awaits the person's decision. The page reads it after every feed
// and every answer, as it reads the host's verdict.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebInputInDoubtMessage()
{
    return terminal ? terminal->inputInDoubtNotice().message.c_str() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebInputInDoubtDetail()
{
    return terminal ? terminal->inputInDoubtNotice().detail.c_str() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebInputInDoubtResendButton()
{
    return terminal ? terminal->inputInDoubtNotice().resendButton.c_str() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebInputInDoubtDiscardButton()
{
    return terminal ? terminal->inputInDoubtNotice().discardButton.c_str() : "";
}

// The person's two answers, each the frame it puts on the wire. Called only
// from the notice's buttons: sending again can run a command twice.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebResendInputInDoubt()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->resendInputInDoubt();
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebDiscardInputInDoubt()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->discardInputInDoubt();
    return frame->empty() ? nullptr : frame->data();
}

// --- Beam -------------------------------------------------------------------
// The palette's state machine is Core's; these are the calls the page makes.

// Opens or closes the palette. Nonzero when it is open afterwards.
UBIQUITTY_WEB_EXPORT int ubiquittyWebToggleBeam()
{
    return (terminal && terminal->toggleBeam()) ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebIsBeamOpen()
{
    return (terminal && terminal->isBeamOpen()) ? 1 : 0;
}

// The Kitty functional key code for a DOM `KeyboardEvent.key` name, or 0 for a
// name that carries its own text and needs none.
//
// The translation is here rather than in the browser because only the NAMES are
// a web concept; the codes are Core's, and a table in script would be a second
// copy of `Keymap.h`'s numbers with nothing comparing the two. A key added to
// Core and not to the copy reports 0 and the key stops working, which is a
// silent divergence per frontend — the class this whole seam exists to close.
UBIQUITTY_WEB_EXPORT int ubiquittyWebKeyCodeForName(const char* name)
{
    if (!name)
        return 0;
    using namespace Ubiquitty::Keys::Keymap;
    const std::string_view key(name);
    // Ordered as `Keymap.h` declares them, so a reader can diff the two lists by
    // eye and a new constant lands in one obvious place.
    static constexpr struct {
        std::string_view name;
        int code;
    } names[] = {
        { "Escape", keymapKeyEscape },
        { "Enter", keymapKeyEnter },
        { "Tab", keymapKeyTab },
        { "Backspace", keymapKeyBackspace },
        { "Insert", keymapKeyInsert },
        { "Delete", keymapKeyDelete },
        { "ArrowLeft", keymapKeyLeft },
        { "ArrowRight", keymapKeyRight },
        { "ArrowUp", keymapKeyUp },
        { "ArrowDown", keymapKeyDown },
        { "PageUp", keymapKeyPageUp },
        { "PageDown", keymapKeyPageDown },
        { "Home", keymapKeyHome },
        { "End", keymapKeyEnd },
        { "CapsLock", keymapKeyCapsLock },
        { "ScrollLock", keymapKeyScrollLock },
        { "NumLock", keymapKeyNumLock },
        { "PrintScreen", keymapKeyPrintScreen },
        { "Pause", keymapKeyPause },
        { "ContextMenu", keymapKeyMenu },
        { "F1", keymapKeyF1 },
        { "F2", keymapKeyF2 },
        { "F3", keymapKeyF3 },
        { "F4", keymapKeyF4 },
        { "F5", keymapKeyF5 },
        { "F6", keymapKeyF6 },
        { "F7", keymapKeyF7 },
        { "F8", keymapKeyF8 },
        { "F9", keymapKeyF9 },
        { "F10", keymapKeyF10 },
        { "F11", keymapKeyF11 },
        { "F12", keymapKeyF12 },
    };
    for (const auto& entry : names) {
        if (entry.name == key)
            return entry.code;
    }
    return 0;
}

// The Kitty modifier mask for the four flags a `KeyboardEvent` carries.
//
// Composed from Core's bits rather than returned one bit at a time, so the
// browser never holds a number it could combine in the wrong order.
UBIQUITTY_WEB_EXPORT int ubiquittyWebKeyModifiers(int shift, int alternate, int ctrl, int super)
{
    using namespace Ubiquitty::Keys::Keymap;
    return (shift ? keymapModifierShift : 0)
        | (alternate ? keymapModifierAlternate : 0)
        | (ctrl ? keymapModifierCtrl : 0)
        | (super ? keymapModifierSuper : 0);
}

// Nonzero when Beam consumed the key. Zero means send it to the host as usual:
// an open palette must not swallow the terminal's input wholesale.
UBIQUITTY_WEB_EXPORT int ubiquittyWebFeedBeamKey(int keyCode, int baseLayoutKey, int modifiers, int text)
{
    return (terminal
               && terminal->feedBeamKey(static_cast<unsigned>(keyCode), static_cast<unsigned>(baseLayoutKey),
                   static_cast<unsigned>(modifiers), static_cast<unsigned>(text)))
        ? 1
        : 0;
}

// The command id the last key accepted, or "". Taken once, so a caller polling
// per frame cannot run it twice.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebTakeBeamCommand()
{
    return terminal ? terminal->takeBeamCommand() : "";
}

// Sets [appearance] beam_surface from its config token ("auto" | "native" |
// "in-terminal"). Nonzero when the token was recognized.
//
// Parsed by the same function that reads the config file rather than by a
// second table here — a page and a config file disagreeing about what "native"
// spells is a divergence nobody would find, because each half works.
//
// The browser has no native palette yet, so every value resolves to the in-grid
// one today. It is still worth setting: the resolution is Core's, and the day a
// native palette lands the setting already means what it says.
// The font families this page can render, newline-separated, with which one is
// in effect. Newline rather than comma: a family name may contain a comma
// ("Menlo, monospace" is a legal CSS stack) and cannot contain a newline.
//
// Supplied by the page because which families resolve is a fact about the
// browser and its installed fonts. An empty list hides the command rather than
// offering a drill with nothing behind it.
// The chosen theme's NAME, or "" — what the page persists across a reload.
// Validate and rewrite one document before publishing one epoch. A malformed
// later member cannot leave an earlier preference applied.
UBIQUITTY_WEB_EXPORT int ubiquittyWebSetRenderingPreferences(const char* json)
{
    using namespace Ubiquitty;
    if (!json || std::strlen(json) > 8192)
        return 0;
    bool isValid = false;
    const auto parsed = Codec::JSON::parse(json, isValid);
    if (!isValid || !parsed.isObject() || parsed.members().size() > std::size(webRenderingKeys))
        return 0;
    std::string document = Preferences::liveDocument();
    for (const auto& [name, raw] : parsed.members()) {
        const auto key = std::ranges::find_if(webRenderingKeys, [&](auto candidate) {
            const auto* descriptor = Preferences::descriptorFor(candidate);
            return name == std::string(descriptor->section) + "." + descriptor->key;
        });
        if (key == std::end(webRenderingKeys))
            return 0;
        const auto* descriptor = Preferences::descriptorFor(*key);
        Preferences::Value value;
        value.kind = descriptor->kind;
        if (value.kind == Preferences::SerializeKind::Bool && raw.isBool())
            value.boolean = raw.asBool();
        else if (value.kind == Preferences::SerializeKind::String && raw.isString() && raw.asString().size() <= 256 && raw.asString().find_first_of("\r\n") == std::string::npos)
            value.text = raw.asString();
        else if ((value.kind == Preferences::SerializeKind::Double || value.kind == Preferences::SerializeKind::Int) && raw.isNumber() && std::isfinite(raw.asNumber())) {
            const auto* range = Preferences::Schema::rangeFor(descriptor->section, descriptor->key);
            if (!range || raw.asNumber() < range->minimum || raw.asNumber() > range->maximum)
                return 0;
            value.number = raw.asNumber();
            value.integer = static_cast<long long>(value.number);
            if (value.kind == Preferences::SerializeKind::Int && value.number != static_cast<double>(value.integer))
                return 0;
        } else
            return 0;
        auto next = Preferences::writeValueIntoBody(*key, value, document);
        if (!next)
            return 0;
        document = std::move(*next);
    }
    if (document != Preferences::liveDocument() && !Preferences::configure(document, Preferences::ParseMode::Strict).isApplied)
        return 0;
    if (terminal)
        terminal->refreshConfiguration();
    return 1;
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebSettingsCatalogJSON()
{
    using Ubiquitty::Codec::JSON::Value;
    static std::string document;
    Value result = Value::object();
    Value themes = Value::array();
    for (int index = 0; index < Ubiquitty::Themes::count(); ++index) {
        if (const auto* theme = Ubiquitty::Themes::get(index))
            themes.push(Value::string(theme->name));
    }
    result.set("themes", std::move(themes));
    Value rendering = Value::array();
    for (const auto key : webRenderingKeys) {
        const auto* descriptor = Ubiquitty::Preferences::descriptorFor(key);
        Value entry = Value::object();
        entry.set("key", Value::string(std::string(descriptor->section) + "." + descriptor->key));
        entry.set("value", preferenceJSON(*Ubiquitty::Preferences::effectiveValue(key, Ubiquitty::Preferences::values())));
        entry.set("default", preferenceJSON(*Ubiquitty::Preferences::effectiveValue(key, {})));
        if (const auto* range = Ubiquitty::Preferences::Schema::rangeFor(descriptor->section, descriptor->key)) {
            entry.set("min", Value::number(range->minimum));
            entry.set("max", Value::number(range->maximum));
            entry.set("step", Value::number(range->step));
            entry.set("unit", Value::string(range->unit));
        }
        rendering.push(std::move(entry));
    }
    result.set("rendering", std::move(rendering));
    document = Ubiquitty::Codec::JSON::serialize(result);
    return document.c_str();
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebCurrentThemeName()
{
    return terminal ? terminal->currentThemeName() : "";
}

// Restores a theme by name. Zero means the name is unknown, which leaves the
// palette alone: a theme removed from Core must not silently become another one.
UBIQUITTY_WEB_EXPORT void ubiquittyWebFollowHostTheme()
{
    if (terminal)
        terminal->followHostTheme();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebSetThemeByName(const char* name)
{
    return (terminal && terminal->setThemeByName(name)) ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebSetFontOptions(const char* newlineSeparated, int currentIndex)
{
    if (!terminal)
        return 0;
    std::vector<std::string> families;
    if (newlineSeparated) {
        std::string all(newlineSeparated);
        std::size_t start = 0;
        while (start <= all.size()) {
            const std::size_t end = all.find('\n', start);
            std::string one = all.substr(start, end == std::string::npos ? std::string::npos : end - start);
            if (!one.empty())
                families.push_back(std::move(one));
            if (end == std::string::npos)
                break;
            start = end + 1;
        }
    }
    const int count = static_cast<int>(families.size());
    terminal->setFontOptions(std::move(families), currentIndex < count ? currentIndex : -1);
    return count;
}

// Returns 1 on success, 0 for an unrecognized token, and -1 when there is no
// terminal yet. The last two are distinct so a caller that asks too early is
// not told its value is wrong: "unrecognized ?beam=native" for a good value
// sends the reader to the token table instead of to the call site.
UBIQUITTY_WEB_EXPORT int ubiquittyWebSetBeamSurface(const char* token)
{
    if (!terminal)
        return -1;
    if (!token)
        return 0;
    const auto surface = Ubiquitty::Preferences::beamSurfaceFromString(token);
    if (!surface)
        return 0;
    terminal->setBeamSurface(*surface);
    return 1;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebSessionID()
{
    return terminal ? static_cast<int>(terminal->sessionID()) : 0;
}

// --- The host's sessions -------------------------------------------------------
// Both halves. Who may destroy a session is answered by the daemon's own gate —
// a requester attached to it terminates directly, and anyone else is held for
// the human on it — so this ABI carries the ask and the verdict rather than
// deciding anything.
//
// The reply lands asynchronously, so the page polls the generations and reads
// the outline when one moved. A terminate is asked as Core's question and sent
// only with the token its answer carries.

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildListSessions()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildListSessions();
    return frame->empty() ? nullptr : frame->data();
}

// Advances on each whole answer of the host's listing. A host holding nothing
// is an answer, so an outline of no rows does not distinguish "no sessions"
// from "no reply yet"; this does.
UBIQUITTY_WEB_EXPORT int ubiquittyWebHostAnswerGeneration()
{
    return terminal ? static_cast<int>(terminal->hostAnswerGeneration()) : 0;
}

// The host's outline: every workspace, window, tab and pane as the rows Core
// decided, one JSON text a call. The page subscribes once per connection,
// polls the generation, and reads the rows when it moved.
UBIQUITTY_WEB_EXPORT int ubiquittyWebSubscribeHostListing() { return (terminal && terminal->subscribeHostListing()) ? 1 : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebHostOutlineGeneration() { return terminal ? static_cast<int>(terminal->hostOutlineGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebIsHostListingRefused() { return (terminal && terminal->isHostListingRefused()) ? 1 : 0; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostOutlineJSON(const char* query) { return terminal ? terminal->hostOutlineJSON(query) : "{\"rows\":[]}"; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostWorkspaceJSON() { return carrier ? carrier->hostWorkspaceJSON() : "{\"workspaces\":[]}"; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildHostCall(const char* method, const char* parameters, std::uint32_t requestID)
{
    if (!carrier)
        return nullptr;
    frame = &carrier->buildHostCall(method, parameters, requestID);
    return frame->empty() ? nullptr : frame->data();
}
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebTakeHostCallResultJSON() { return carrier ? carrier->takeHostCallResultJSON() : ""; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostCallRefusal() { return carrier ? carrier->hostCallRefusal() : "The terminal is not ready."; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebRequestHostStructureChange(int operation, const char* target, const char* text, const char* tags, const char* window, int index)
{
    return terminal ? static_cast<int>(terminal->requestHostStructureChange(operation, target, text, tags, window, index)) : 0;
}
// A request that ends sessions is asked about first: the question is Core's,
// and the token it returns is what the close or the terminate is sent with.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostDestructiveConfirmationJSON(int request, const char* target, const char* hostName)
{
    return terminal ? terminal->hostDestructiveConfirmationJSON(request, target, hostName) : "{\"token\":0,\"whyNot\":\"No terminal is running.\"}";
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebCloseHostWindow(const char* window, int confirmationToken)
{
    return terminal ? static_cast<int>(terminal->closeHostWindow(window, confirmationToken > 0 ? static_cast<unsigned int>(confirmationToken) : 0)) : 0;
}
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildConfirmedTerminate(int request, const char* target, int confirmationToken)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildConfirmedTerminate(request, target, confirmationToken > 0 ? static_cast<unsigned int>(confirmationToken) : 0);
    return frame->empty() ? nullptr : frame->data();
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebOwedTerminateCount() { return terminal ? static_cast<int>(terminal->owedTerminateCount()) : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildOwedTerminate()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildOwedTerminate();
    return frame->empty() ? nullptr : frame->data();
}
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostTerminateRefusal() { return terminal ? terminal->hostTerminateRefusal() : ""; }
// Every phrase a session list shows that never varies, as `{key: words}`:
// the page draws Core's words and words none.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebSessionListPhrasesJSON()
{
    static const std::string phrases = [] {
        Ubiquitty::Codec::JSON::Value all = Ubiquitty::Codec::JSON::Value::object();
        for (std::size_t index = 0; index < Ubiquitty::Runtime::sessionListPhraseCount; ++index) {
            const auto phrase = static_cast<Ubiquitty::Runtime::SessionListPhrase>(index);
            all.set(std::string(Ubiquitty::Runtime::sessionListPhraseKey(phrase)), Ubiquitty::Codec::JSON::Value::string(std::string(Ubiquitty::Runtime::sessionListPhraseWords(phrase))));
        }
        return Ubiquitty::Codec::JSON::serialize(all);
    }();
    return phrases.c_str();
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebHostStructureGeneration() { return terminal ? static_cast<int>(terminal->hostStructureGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostStructureResultJSON() { return terminal ? terminal->hostStructureResultJSON() : "{\"requestID\":0}"; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCollapseHostOutlineRow(const char* id) { return (terminal && terminal->collapseHostOutlineRow(id)) ? 1 : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebExpandHostOutlineRow(const char* id) { return (terminal && terminal->expandHostOutlineRow(id)) ? 1 : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebExpandAllUnderHostOutlineRow(const char* id) { return (terminal && terminal->expandAllUnderHostOutlineRow(id)) ? 1 : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebExpandAllUnderRecordedHostOutlineRow(int workspaceID, int level, int window, int tab)
{
    return (terminal && workspaceID >= 0 && terminal->expandAllUnderRecordedHostOutlineRow(static_cast<std::uint32_t>(workspaceID), level, window, tab)) ? 1 : 0;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebCollapseRecordedHostOutlineRow(int workspaceID, int level, int window, int tab)
{
    return (terminal && workspaceID >= 0 && terminal->collapseRecordedHostOutlineRow(static_cast<std::uint32_t>(workspaceID), level, window, tab)) ? 1 : 0;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebExpandRecordedHostOutlineRow(int workspaceID, int level, int window, int tab)
{
    return (terminal && workspaceID >= 0 && terminal->expandRecordedHostOutlineRow(static_cast<std::uint32_t>(workspaceID), level, window, tab)) ? 1 : 0;
}

// Advances on each settled terminate. A counter and not a flag, because two
// rows refused in a row are two answers and would otherwise read as one.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTerminateGeneration()
{
    return terminal ? static_cast<int>(terminal->terminateGeneration()) : 0;
}

// The `WebTerminal::TerminateOutcome` ordinal, which carries Core's numbers:
// 0 terminated, 1 denied, 2 timed out, 3 failed, 4 refused, and 255 for an ask
// that has not settled. Read with the generation above, which is what says the
// value belongs to a settled ask.
//
// A page holding no terminal reads 255 for the same reason a fresh one does:
// nothing has settled, and answering 0 would report a destroy nobody asked for.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTerminateOutcome()
{
    return static_cast<int>(terminal ? terminal->terminateOutcome() : Ubiquitty::Web::WebTerminal::TerminateOutcome::Pending);
}

// Which session the outcome belongs to, so a page showing several rows says it
// against the right one.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTerminateSessionID()
{
    return terminal ? static_cast<int>(terminal->terminateSessionID()) : 0;
}

// The two waits, in seconds, so the page's timers and Core's rule read one set
// of numbers. Milliseconds because setTimeout takes them.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTerminateGraceMilliseconds()
{
    return static_cast<int>(Ubiquitty::Web::WebTerminal::terminateGraceSeconds * 1000.0);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebTerminateConsentMilliseconds()
{
    return static_cast<int>(Ubiquitty::Web::WebTerminal::terminateConsentSeconds * 1000.0);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebNoteTerminateGraceElapsed()
{
    if (terminal)
        terminal->noteTerminateGraceElapsed();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebNoteTerminateDeadlineElapsed()
{
    if (terminal)
        terminal->noteTerminateDeadlineElapsed();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebNoteTerminateTransportLost()
{
    if (terminal)
        terminal->noteTerminateTransportLost();
}

// --- The connect rule, and the pairing it reads ------------------------------
// The rule is Core's `Session::RememberedSessions` and the STORE is the page's.
// So the page hands over the bytes it kept for a host, asks what to do, and
// writes back whatever the ask left — and never reads inside the bytes, which
// is what keeps the rule from being half-restated in JavaScript.

UBIQUITTY_WEB_EXPORT void ubiquittyWebLoadHostRecord(const char* hostKey, const char* bytes, int length)
{
    if (terminal)
        terminal->loadHostRecord(hostKey, bytes, length);
}

// The `Session::AttachPlan` ordinal: 0 attach the remembered id, 1 create under
// the name, 2 attach the listed session bearing the name, 3 ask the person,
// 4 create a fresh unnamed session, 5 wait for the host's listing. The page asks
// only once a listing has landed, so it never receives 5; the five below name
// the plans it does receive, so the page reads no bare number.
UBIQUITTY_WEB_EXPORT int ubiquittyWebDecideAttach(const char* hostKey, const char* predefinedWorkspaceName)
{
    return terminal ? static_cast<int>(terminal->decideAttach(hostKey, predefinedWorkspaceName)) : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebAttachPlanAttachByID() { return static_cast<int>(Ubiquitty::Session::AttachPlan::AttachByID); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAttachPlanCreateNamed() { return static_cast<int>(Ubiquitty::Session::AttachPlan::CreateNamed); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAttachPlanAttachNamed() { return static_cast<int>(Ubiquitty::Session::AttachPlan::AttachNamed); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAttachPlanChooseFromList() { return static_cast<int>(Ubiquitty::Session::AttachPlan::ChooseFromList); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAttachPlanCreateNew() { return static_cast<int>(Ubiquitty::Session::AttachPlan::CreateNew); }

UBIQUITTY_WEB_EXPORT int ubiquittyWebDecidedSessionID() { return terminal ? static_cast<int>(terminal->decidedSessionID()) : 0; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebDecidedWorkspaceName() { return terminal ? terminal->decidedWorkspaceName() : ""; }

UBIQUITTY_WEB_EXPORT void ubiquittyWebRememberHostSession(const char* hostKey, int sessionID, const char* workspaceName)
{
    if (terminal)
        terminal->rememberHostSession(hostKey, static_cast<unsigned int>(sessionID < 0 ? 0 : sessionID), workspaceName);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebForgetHostSession(const char* hostKey)
{
    if (terminal)
        terminal->forgetHostSession(hostKey);
}

// The record to store, as a base pointer and a length: a record holds a zero
// byte, so the page copies the extent rather than reading to a terminator.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebHostRecordBytes(const char* hostKey) { return terminal ? terminal->hostRecordBytes(hostKey) : ""; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebHostRecordLength(const char* hostKey) { return terminal ? terminal->hostRecordLength(hostKey) : 0; }

// `keyCode` is a Kitty functional key code or a code point; `modifiers` are the
// `Keys::Keymap::keymapModifier` bits; `text` is the code point produced.
// `eventType` is Keys::KeyEventType: 1 press, 2 repeat, 3 release — the kitty
// wire numbers, which start at 1 rather than 0. The host encodes every admitted
// transition under its own live modes. Null means there is no frame ready,
// never that the replica's REPORT_EVENTS flag refused a release.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildKeyEvent(int keyCode, int baseLayoutKey, int modifiers, int text, int eventType, int physicalKey)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildKey(static_cast<unsigned>(keyCode), static_cast<unsigned>(baseLayoutKey),
        static_cast<unsigned>(modifiers), static_cast<unsigned>(text),
        static_cast<Ubiquitty::Keys::KeyEventType>(eventType), static_cast<Ubiquitty::Keys::VirtualKey>(physicalKey));
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildKey(int keyCode, int baseLayoutKey, int modifiers, int text)
{
    return ubiquittyWebBuildKeyEvent(keyCode, baseLayoutKey, modifiers, text,
        static_cast<int>(Ubiquitty::Keys::KeyEventType::Press), 0);
}

// The `ActionKind` values a caller acts on. Exported rather than restated
// elsewhere: the enum gains members, and a copied index would come to mean
// something else without saying so.
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionSendBytes() { return std::to_underlying(Ubiquitty::Input::ActionKind::SendBytes); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionCopy() { return std::to_underlying(Ubiquitty::Input::ActionKind::Copy); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionPaste() { return std::to_underlying(Ubiquitty::Input::ActionKind::Paste); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionClearScrollback() { return std::to_underlying(Ubiquitty::Input::ActionKind::ClearScrollback); }

UBIQUITTY_WEB_EXPORT int ubiquittyWebActionToggleBeam() { return std::to_underlying(Ubiquitty::Input::ActionKind::ToggleBeam); }

UBIQUITTY_WEB_EXPORT int ubiquittyWebActionClearBuffer() { return std::to_underlying(Ubiquitty::Input::ActionKind::ClearBuffer); }

UBIQUITTY_WEB_EXPORT int ubiquittyWebActionClearScreen() { return std::to_underlying(Ubiquitty::Input::ActionKind::ClearScreen); }

// Scrolls the prompt to the top. The frame is empty unless Core handed off to
// the program, in which case it carries the redraw request.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildClearScreen()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildClearScreen();
    return frame->empty() ? nullptr : frame->data();
}

// Clears, and returns the frame a caller sends so the process redraws.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildClearBuffer()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildClearBuffer();
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebClearScrollback()
{
    if (terminal)
        terminal->clearScrollback();
}

// --- OSC 52 ---------------------------------------------------------------
// A write is staged until taken; a read is requested and answered later. Both
// cross asynchronously because a browser clipboard is a promise on both sides.

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingClipboardWrite()
{
    return terminal ? terminal->pendingClipboardWrite() : "";
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebHasPendingClipboardWrite()
{
    return terminal && terminal->hasPendingClipboardWrite() ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebTakeClipboardWrite()
{
    if (terminal)
        terminal->takeClipboardWrite();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebWantsClipboardRead()
{
    return (terminal && terminal->wantsClipboardRead()) ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebClipboardReadNeedsConfirmation()
{
    return (terminal && terminal->clipboardReadNeedsConfirmation()) ? 1 : 0;
}

// A null or empty answer is still an answer: a program that asked and is never
// told waits forever.
UBIQUITTY_WEB_EXPORT void ubiquittyWebProvideClipboardRead(const char* text)
{
    if (terminal)
        terminal->provideClipboardRead(text);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebPendingClipboardItemCount()
{
    return terminal ? terminal->pendingClipboardItemCount() : 0;
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebClipboardItemMime(int index)
{
    return terminal ? terminal->pendingClipboardItemMime(index) : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebClipboardItemBytes(int index)
{
    return terminal ? terminal->pendingClipboardItemBytes(index) : "";
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebClipboardItemLength(int index)
{
    return terminal ? terminal->pendingClipboardItemLength(index) : 0;
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebTakeClipboardItems()
{
    if (terminal)
        terminal->takeClipboardItems();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebBeginClipboardReadItems()
{
    if (terminal)
        terminal->beginClipboardReadItems();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebAddClipboardReadItem(const char* mime, const char* bytes, int length)
{
    // The pointer-and-length pair is the wasm ABI's own shape; the guards
    // are its contract, and the span forms behind them.
    if (terminal && mime != nullptr && length >= 0)
        terminal->addClipboardReadItem(mime, { bytes != nullptr ? bytes : "", static_cast<std::size_t>(length) });
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebAddKeybinding(const char* spec, const char* action)
{
    return (terminal && terminal->addKeybinding(spec, action)) ? 1 : 0;
}

// Returns the `Input::ActionKind`, 0 for no match, -1 while a chord is pending.
UBIQUITTY_WEB_EXPORT int ubiquittyWebResolveBinding(int keyCode, int baseLayoutKey, int modifiers)
{
    return terminal ? terminal->resolveBinding(static_cast<unsigned>(keyCode), static_cast<unsigned>(baseLayoutKey), static_cast<unsigned>(modifiers)) : 0;
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBindingBytes()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->bindingBytes();
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebFeedKeyEvent(int keyCode, int baseLayoutKey, int modifiers, int text, int eventType, int physicalKey)
{
    return (terminal
               && terminal->feedKey(static_cast<unsigned>(keyCode), static_cast<unsigned>(baseLayoutKey),
                   static_cast<unsigned>(modifiers), static_cast<unsigned>(text),
                   static_cast<Ubiquitty::Keys::KeyEventType>(eventType), static_cast<Ubiquitty::Keys::VirtualKey>(physicalKey)))
        ? 1
        : 0;
}

// An embedder with a local PTY or demo program delivers these bytes to that
// program. Encoding alone never feeds the screen or queues a remote intent.
UBIQUITTY_WEB_EXPORT int ubiquittyWebEncodeLocalKeyEvent(int keyCode, int baseLayoutKey, int modifiers, int text, int eventType, int physicalKey, char* output, int capacity)
{
    if (!terminal || capacity < 0 || (!output && capacity != 0))
        return 0;
    return terminal->encodeLocalKey(static_cast<unsigned>(keyCode), static_cast<unsigned>(baseLayoutKey),
        static_cast<unsigned>(modifiers), static_cast<unsigned>(text),
        static_cast<Ubiquitty::Keys::KeyEventType>(eventType), { output, static_cast<std::size_t>(capacity) },
        static_cast<Ubiquitty::Keys::VirtualKey>(physicalKey));
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebFeedKey(int keyCode, int baseLayoutKey, int modifiers, int text)
{
    return ubiquittyWebFeedKeyEvent(keyCode, baseLayoutKey, modifiers, text,
        static_cast<int>(Ubiquitty::Keys::KeyEventType::Press), 0);
}

// --- the clipboard a remote host does not have ------------------------------
//
// The page polls for a pending request, reads its own clipboard through the
// Async Clipboard API, stages what it read, and frames the answer. Polled
// rather than pushed: a callback into JavaScript from inside the parse would
// run while Core holds its own state, and the page already drives a frame loop.

/// The host's pending clipboard request, or 0 when there is none.
UBIQUITTY_WEB_EXPORT unsigned int ubiquittyWebPendingClipboardServeID()
{
    return terminal ? terminal->pendingClipboardServeID() : 0u;
}

/// Whether the pending request wants the type list rather than one payload.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPendingClipboardServeWantsTypes()
{
    return terminal && terminal->pendingClipboardServeWantsTypes() ? 1 : 0;
}

/// The MIME the pending request names, empty for a type list.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingClipboardServeMime()
{
    return terminal ? terminal->pendingClipboardServeMime() : "";
}

/// Opens the answer; items follow.
UBIQUITTY_WEB_EXPORT void ubiquittyWebBeginClipboardServeItems()
{
    if (terminal)
        terminal->beginClipboardServeItems();
}

/// Adds one payload, or one type name with no bytes for a list answer.
UBIQUITTY_WEB_EXPORT void ubiquittyWebAddClipboardServeItem(const char* mime, const char* bytes, int length)
{
    if (!terminal || mime == nullptr)
        return;
    // A type-list entry carries a name and no bytes, so an empty payload is a
    // valid answer here rather than a caller error.
    const char* data = bytes != nullptr ? bytes : "";
    const std::size_t count = length > 0 ? static_cast<std::size_t>(length) : 0;
    terminal->addClipboardServeItem(mime, { data, count });
}

/// Frames the answer and clears the pending request.
///
/// `status` is the wire's value: 0 OK, 1 empty, 2 refused, 3 too large. A page
/// that declines answers 2 rather than staying silent — a program that asked is
/// waiting, and a refusal it can see beats a wait it cannot end.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildClipboardServeAnswer(int status)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildClipboardServeAnswer(status);
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildPastePush(const char* mime, const char* bytes, int length)
{
    // The pointer-and-length pair is the wasm ABI's own shape; the guards
    // are its contract, and the span forms behind them.
    if (!terminal || mime == nullptr || bytes == nullptr || length <= 0)
        return nullptr;
    frame = &terminal->buildPastePush(mime, { reinterpret_cast<const std::uint8_t*>(bytes), static_cast<std::size_t>(length) });
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildInput(const char* bytes, int length)
{
    if (!terminal)
        return nullptr;
    if (length < 0)
        return nullptr;
    frame = &terminal->buildInput({ bytes, static_cast<std::size_t>(length) });
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildResize(int rows, int columns)
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildResize(rows, columns);
    return frame->empty() ? nullptr : frame->data();
}

// `eventType` is `Mouse::EventType`: 0 press, 1 release, 2 motion.
// One pointer event through Core's ladder. `kind` is Input::PointerFact::Kind
// and `button` Input::PointerButton, both by value; the page spells neither
// rule -- which mode reports, which modifier keeps a drag local, whether a
// press opens a selection -- and reads the verdict back through
// ubiquittyWebPointerVerdict.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebPointer(int kind, int button, int row, int column, int pixelX, int pixelY, int deltaX, int deltaY, int shift, int alternate, int control, int command, int clickCount, int isDragging, double xInCells)
{
    if (!terminal)
        return nullptr;
    Ubiquitty::Input::PointerFact fact;
    fact.kind = static_cast<Ubiquitty::Input::PointerFact::Kind>(kind);
    fact.button = static_cast<Ubiquitty::Input::PointerButton>(button);
    fact.row = row;
    fact.column = column;
    fact.pixelX = pixelX;
    fact.pixelY = pixelY;
    // Negative is the page's spelling of "not measured", which keeps the
    // gesture on whole cells.
    if (xInCells >= 0.0)
        fact.xInCells = xInCells;
    fact.deltaX = deltaX;
    fact.deltaY = deltaY;
    fact.hasShift = shift != 0;
    fact.hasAlternate = alternate != 0;
    fact.hasControl = control != 0;
    fact.hasCommand = command != 0;
    fact.clickCount = clickCount;
    fact.isDragging = isDragging != 0;
    frame = &terminal->pointer(fact);
    return frame->empty() ? nullptr : frame->data();
}

// One scroll gesture through Core's wheel ladder. `isPrecise` nonzero is a
// pixel delta (a trackpad); zero a line delta (a notched wheel).
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebScroll(double deltaX, double deltaY, int isPrecise, int row, int column, int pixelX, int pixelY, int shift, int alternate, int control)
{
    if (!terminal)
        return nullptr;
    Ubiquitty::Input::ScrollFact fact;
    fact.deltaX = deltaX;
    fact.deltaY = deltaY;
    fact.isPrecise = isPrecise != 0;
    fact.row = row;
    fact.column = column;
    fact.pixelX = pixelX;
    fact.pixelY = pixelY;
    fact.hasShift = shift != 0;
    fact.hasAlternate = alternate != 0;
    fact.hasControl = control != 0;
    frame = &terminal->scroll(fact);
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerVerdict() { return terminal ? terminal->pointerVerdict() : 0; }

// The values the page passes as `kind` and `button`, so the page reads them
// from Core rather than restating an enumeration order.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerKindPress() { return static_cast<int>(Ubiquitty::Input::PointerFact::Kind::Press); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerKindRelease() { return static_cast<int>(Ubiquitty::Input::PointerFact::Kind::Release); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerKindMotion() { return static_cast<int>(Ubiquitty::Input::PointerFact::Kind::Motion); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerButtonLeft() { return static_cast<int>(Ubiquitty::Input::PointerButton::Left); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerButtonMiddle() { return static_cast<int>(Ubiquitty::Input::PointerButton::Middle); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerButtonRight() { return static_cast<int>(Ubiquitty::Input::PointerButton::Right); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerButtonNone() { return static_cast<int>(Ubiquitty::Input::PointerButton::None); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerVerdictConsumed() { return Ubiquitty::Web::WebTerminal::PointerVerdictConsumed; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerVerdictNeedsDisplay() { return Ubiquitty::Web::WebTerminal::PointerVerdictNeedsDisplay; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerVerdictOpenedGesture() { return Ubiquitty::Web::WebTerminal::PointerVerdictOpenedGesture; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerVerdictFinishedGesture() { return Ubiquitty::Web::WebTerminal::PointerVerdictFinishedGesture; }

UBIQUITTY_WEB_EXPORT void ubiquittyWebClearSelection()
{
    if (terminal)
        terminal->clearSelection();
}

// The page maps shapes to CSS cursors by index, and a wrong index is a wrong
// cursor rather than an error. This is what lets it notice the enum grew.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerShapeCount()
{
    return static_cast<int>(Ubiquitty::MousePointerShape::NorthwestResize) + 1;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebHasSelection() { return (terminal && terminal->hasSelection()) ? 1 : 0; }

// Points into the terminal's own storage, valid until the next call.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebSelectionText()
{
    return terminal ? terminal->selectionText() : "";
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebScrollBy(int rows)
{
    if (terminal)
        terminal->scrollBy(rows);
}

// The rows one page of scrolling moves: Core's one rule, which every other
// frontend's page chord and the native scroller's track click take, so the
// page cannot page by its own amount.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPageLines() { return terminal ? Ubiquitty::Keys::pageLinesForRows(terminal->rows()) : 1; }

UBIQUITTY_WEB_EXPORT void ubiquittyWebSelectAll()
{
    if (terminal)
        terminal->selectAll();
}

// Selects the characters a drag over visible cells covers, for a headless
// frame that shows a selection.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSelectVisibleRect(int row0, int column0, int row1, int column1)
{
    if (!terminal)
        return;
    Ubiquitty::SelectionBounds visible {};
    visible.row0 = row0;
    visible.column0 = column0;
    visible.row1 = row1;
    visible.column1 = column1;
    terminal->selectVisibleRectangle(visible);
}

// A plain drag between two points, in cells across and rows down.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSelectBetweenPoints(double fromX, double fromY, double toX, double toY)
{
    if (terminal)
        terminal->selectBetweenPoints(fromX, fromY, toX, toY);
}

// Queues a literal search; the event loop pumps its slices.
UBIQUITTY_WEB_EXPORT int ubiquittyWebSearchLiteral(const char* literal)
{
    return (terminal && terminal->searchLiteral(literal)) ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebPumpSearch()
{
    return terminal && terminal->pumpSearch();
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebSearchStatusJSON()
{
    return terminal ? terminal->searchStatusJSON() : "{}";
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebStepSearch(int direction)
{
    return terminal && terminal->stepSearch(direction > 0 ? Ubiquitty::Search::StepDirection::Older : Ubiquitty::Search::StepDirection::Newer);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebSearchLiteralAndWait(const char* literal)
{
    return terminal && terminal->searchLiteralAndWait(literal);
}

// The two clear gestures, Cmd-L and Cmd-K's input-preserving clear.
UBIQUITTY_WEB_EXPORT void ubiquittyWebClearToPreviousMark()
{
    if (terminal)
        terminal->clearToPreviousMark();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebClearPreservingInput()
{
    if (terminal)
        terminal->clearPreservingInput();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebClearSelectionForUserInput()
{
    return (terminal && terminal->clearSelectionForUserInput()) ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebActionSelectAll() { return std::to_underlying(Ubiquitty::Input::ActionKind::SelectAll); }

UBIQUITTY_WEB_EXPORT void ubiquittyWebScrollToTop()
{
    if (terminal)
        terminal->scrollToTop();
}

// The size a configuration names, rather than a number of steps from whatever
// the page started at. Stepping reaches a size only from a known one, so a
// caller applying a settings file had to know the default to count from it, and
// a changed default silently moved every such caller's result.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetFontSize(double cssPixels)
{
    if (terminal)
        terminal->setFontSize(cssPixels);
}

// The `font.variations` axis list, as the text the reader wrote. Parsed on the
// C++ side so the page and the terminal cannot disagree about the grammar; a
// token neither of them can read is skipped rather than refused, which is what
// keeps a hand-written list from costing the axes that were spelled correctly.
// The `font-variation-settings` value for the axes a canvas font shorthand
// cannot name. The page registers a face carrying it; weight is not among them,
// because a descriptor naming an axis outranks the property for it and would
// pin every cell to one weight.
// The `font-feature-settings` value for `[font] features`. The page registers a
// face carrying it, which is the only route to a feature here: this arm has no
// shaper of its own, so the browser's is the one that applies them.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebFontFeatureSettingsCSS()
{
    return terminal ? terminal->fontFeatureSettingsCSS() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebFontVariationSettingsCSS()
{
    return terminal ? terminal->fontVariationSettingsCSS() : "";
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetFontVariations(const char* specification)
{
    if (terminal)
        terminal->setFontVariations(specification ? std::string(specification) : std::string());
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebStepFontSize(int steps)
{
    if (terminal)
        terminal->stepFontSize(steps);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebResetFontSize()
{
    if (terminal)
        terminal->resetFontSize();
}

// `focused` is 0 or 1. Drives DEC 1004 reporting, the hollow unfocused cursor,
// and whether a bell is worth a notification.
// Pasted text, sent as a paste the host normalises and fences by Core's paste
// policy — never as typed bytes. See WebTerminal::buildPaste.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildPaste(const char* text, int length)
{
    if (!terminal)
        return nullptr;
    if (length < 0)
        return nullptr;
    frame = &terminal->buildPaste({ text, static_cast<std::size_t>(length) });
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebReportsKeyPositions()
{
    return terminal && terminal->reportsKeyPositions() ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebReportsPasteEvents()
{
    return terminal && terminal->reportsPasteEvents() ? 1 : 0;
}

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildPasteNotification(const char* types)
{
    if (!terminal || !types)
        return nullptr;
    frame = &terminal->buildPasteNotification(types);
    return frame->empty() ? nullptr : frame->data();
}

// The frame reporting this surface's focus. Sent on every transition and once
// after the handshake — a page can open in a background tab.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBuildFocusChanged()
{
    if (!terminal)
        return nullptr;
    frame = &terminal->buildFocusChanged();
    return frame->empty() ? nullptr : frame->data();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorRow() { return terminal ? terminal->cursorRow() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorColumn() { return terminal ? terminal->cursorColumn() : 0; }

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetFocus(int focused)
{
    if (terminal)
        terminal->setFocus(focused ? Ubiquitty::Modes::FocusState::Focused : Ubiquitty::Modes::FocusState::Unfocused);
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingNotificationTitle()
{
    return terminal ? terminal->pendingNotificationTitle() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingNotificationBody()
{
    return terminal ? terminal->pendingNotificationBody() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingNotificationTag()
{
    return terminal ? terminal->pendingNotificationTag() : "";
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebTakeNotification()
{
    if (terminal)
        terminal->takeNotification();
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebCurrentDirectory()
{
    return terminal ? terminal->currentDirectory() : "";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebPendingFontFamily()
{
    return terminal ? terminal->pendingFontFamily() : "";
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebTakeFontFamily()
{
    if (terminal)
        terminal->takeFontFamily();
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebRebuildFont()
{
    if (terminal)
        terminal->rebuildFontStack();
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebTitle()
{
    return terminal ? terminal->title() : "";
}

// The visible grid, cursor and program facts as one JSON document, for a harness
// judging Core's terminal behaviour without a browser. Valid until the next call.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebCaptureProgramState()
{
    return terminal ? terminal->captureProgramState() : "";
}

// A non-consuming metadata snapshot, without the grid capture's per-cell work.
// Null before create; the returned storage survives until the next metadata read.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebProgramMetadataJSON()
{
    return terminal ? terminal->programMetadataJSON() : "null";
}

UBIQUITTY_WEB_EXPORT const char* ubiquittyWebTakeProgressReports()
{
    return terminal ? terminal->takeProgressReports() : "";
}

// Moves up to `capacity` bytes of the replies Core queued for the program into
// `buffer`; returns how many. Detached, nothing else reads them.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTakeReplies(char* buffer, int capacity)
{
    if (!terminal || !buffer || capacity <= 0)
        return 0;
    return terminal->takeReplies({ buffer, static_cast<std::size_t>(capacity) });
}

// The bells the program rang since the last call, one per bell.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTakeBellsRung()
{
    return terminal ? static_cast<int>(std::min<std::uint32_t>(terminal->takeBellsRung(), INT32_MAX)) : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebFontSize() { return terminal ? static_cast<int>(terminal->fontSize()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionIncreaseFontSize() { return std::to_underlying(Ubiquitty::Input::ActionKind::IncreaseFontSize); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionDecreaseFontSize() { return std::to_underlying(Ubiquitty::Input::ActionKind::DecreaseFontSize); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionResetFontSize() { return std::to_underlying(Ubiquitty::Input::ActionKind::ResetFontSize); }

UBIQUITTY_WEB_EXPORT int ubiquittyWebActionToggleFullscreen() { return std::to_underlying(Ubiquitty::Input::ActionKind::ToggleFullscreen); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollLineUp() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollLineUp); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollLineDown() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollLineDown); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollPageUp() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollPageUp); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollPageDown() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollPageDown); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollToTop() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollToTop); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebActionScrollToBottom() { return std::to_underlying(Ubiquitty::Input::ActionKind::ScrollToBottom); }

UBIQUITTY_WEB_EXPORT void ubiquittyWebScrollToBottom()
{
    if (terminal)
        terminal->scrollToBottom();
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebViewOffset() { return terminal ? terminal->viewOffset() : 0; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebScrollbackRows() { return terminal ? terminal->scrollbackRows() : 0; }

// DECSET 7403. Nonzero means the page should hold the Pointer Lock and send
// motion as movementX/movementY deltas rather than as cell positions.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerLockActive() { return (terminal && terminal->pointerLockActive()) ? 1 : 0; }
// How long the standing reserved-gesture hint has left, in 60 Hz ticks, or 0:
// the one repaint the page books so a lesson fades without a frame of its own.
// How the reader's keyboard names its modifiers: 0 for a Linux desktop's words,
// 1 for the Mac glyphs, 2 for Windows. A fact the page reads off the platform it
// runs on; the words are Core's.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetModifierVocabulary(int vocabulary)
{
    if (!terminal)
        return;
    switch (vocabulary) {
    case 1:
        terminal->setModifierVocabulary(Ubiquitty::Input::ModifierVocabulary::Mac);
        return;
    case 2:
        terminal->setModifierVocabulary(Ubiquitty::Input::ModifierVocabulary::Windows);
        return;
    default:
        terminal->setModifierVocabulary(Ubiquitty::Input::ModifierVocabulary::Words);
        return;
    }
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebServiceDisplayIdle() { return terminal ? terminal->serviceDisplayIdle(Ubiquitty::PAL::monotonicTicks()) : -1; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebHintTicksUntilExpiry() { return terminal ? static_cast<int>(terminal->hintTicksUntilExpiry()) : 0; }
// Pointer lock, decided in Core. The page reports the facts only it sees -- whether
// it is focused, whether the Pointer Lock API grab is held, which modifiers are
// down -- and executes the verdicts: request or exit the grab, and paint.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerLockVerdict(int isFocused)
{
    if (!terminal)
        return 0;
    Ubiquitty::Input::PointerLockFacts facts;
    facts.isSurfaceFocused = isFocused != 0;
    return terminal->pointerLockVerdict(facts) == Ubiquitty::Input::PointerLockVerdict::Hold ? 1 : 0;
}
UBIQUITTY_WEB_EXPORT void ubiquittyWebNotePointerLockGrab(int isHeld)
{
    if (terminal)
        terminal->notePointerLockGrab(isHeld != 0 ? Ubiquitty::Input::PointerLockGrab::Held : Ubiquitty::Input::PointerLockGrab::Released);
}
UBIQUITTY_WEB_EXPORT void ubiquittyWebNotePointerLockChord(int isControl, int isMeta, int isShift, int isAlternate, int isAnyKey)
{
    if (terminal)
        terminal->notePointerLockChord(pointerLockKeys(isControl, isMeta, isShift, isAlternate, isAnyKey));
}
// 1 when the hold elapsed with the chord still down: the mode is already clear, and
// the page exits the grab.
UBIQUITTY_WEB_EXPORT int ubiquittyWebTickPointerLockChord(int isControl, int isMeta, int isShift, int isAlternate, int isAnyKey)
{
    if (!terminal)
        return 0;
    return terminal->tickPointerLockChord(pointerLockKeys(isControl, isMeta, isShift, isAlternate, isAnyKey)) == Ubiquitty::Input::PointerLockChordVerdict::BreakOut ? 1 : 0;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerLockChordTicksUntilDeadline() { return terminal ? static_cast<int>(terminal->pointerLockChordTicksUntilDeadline()) : 0; }

/// The wire version this build speaks, from the header that owns it.
///
/// Read by the page and its fixtures rather than retyped there: a number
/// retyped in a script has nothing tying it to the constant, and a bump
/// reaches it as a refused handshake rather than a build error.
UBIQUITTY_WEB_EXPORT int ubiquittyWebWireVersion() { return static_cast<int>(Ubiquitty::Protocol::Sync::wireVersion); }

/// This build's version, as its handshake states it: the page shows what Core
/// sends and derives no version of its own.
///
/// - Returns: A NUL-terminated string that lives as long as the module.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebAppVersion() { return Ubiquitty::Protocol::Sync::appVersion().data(); }

/// What identifies this build beside its version: the commit's short hash and
/// what qualifies it.
///
/// - Returns: A NUL-terminated string that lives as long as the module.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebBuildIdentity() { return Ubiquitty::Protocol::Sync::buildIdentity().data(); }

// Row in the high half, column in the low: two clamped small ints in one
// crossing, because a struct return has no cwrap shape and a heap scratch
// would outlive its call. Sixteen bits bound each at 65535, far past any
// grid or canvas this page can size.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerCellPacked(float xInPixels, float yInPixels)
{
    if (!terminal)
        return 0;
    const Ubiquitty::CellPosition cell = terminal->pointerCell(xInPixels, yInPixels);
    return (cell.row << 16) | cell.column;
}

// Where the point stands along its row in cells, unrounded, which the page
// hands back with the pointer fact so a caret inside a proportional face's
// row lands between letters (LetterLayout.h).
UBIQUITTY_WEB_EXPORT double ubiquittyWebPointerXInCells(float xInPixels, float yInPixels)
{
    if (!terminal)
        return 0.0;
    return terminal->pointerXInCells(xInPixels, yInPixels);
}

// Y in the high half, X in the low, both 1-based — the same packing rule as
// the cell above.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerPixelPacked(float xInPixels, float yInPixels)
{
    if (!terminal)
        return (1 << 16) | 1;
    const Ubiquitty::IntPoint pixel = terminal->pointerPixel(xInPixels, yInPixels);
    return (pixel.y << 16) | pixel.x;
}

// The cursor cell's device-pixel origin, y in the high half and x in the
// low — the same packing rule as the pointer exports. The page places the
// IME element at this origin so the candidate window follows the cursor
// through the one placement every frontend derives.
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorCellOriginPacked()
{
    if (!terminal)
        return 0;
    const Ubiquitty::FloatRect box = terminal->cursorCellRect();
    return (static_cast<int>(box.origin.y) << 16) | static_cast<int>(box.origin.x);
}

// The URI a primary click on a cell opens, or the empty string. Points into the
// terminal's own storage and stays valid until the next call, which is what
// lets the page read it without owning a buffer. `isLinkModifierHeld` is the
// click's Command or Ctrl: without it an ssh, sftp, ftp or ftps link answers
// empty.
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebLinkAtCell(int row, int column, int isLinkModifierHeld)
{
    using LinkModifier = Ubiquitty::Web::WebTerminal::LinkModifier;
    return terminal ? terminal->linkAtCell(row, column, isLinkModifierHeld != 0 ? LinkModifier::Held : LinkModifier::Up) : "";
}

// The `MousePointerShape` for a cell, as an int the page maps to a CSS cursor.
UBIQUITTY_WEB_EXPORT int ubiquittyWebPointerShape(int isOverLink, int isRectangularSelectArmed, int selectionBypassesMouseReporting, int isOverTextVoid)
{
    if (!terminal)
        return 0;
    return terminal->pointerShape(isOverLink != 0, isRectangularSelectArmed != 0, selectionBypassesMouseReporting != 0, isOverTextVoid != 0);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebFrameLength() { return frame ? static_cast<int>(frame->size()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebIsAttached() { return (terminal && terminal->isAttached()) ? 1 : 0; }

// --- GPU frame ------------------------------------------------------------
// Uploadable as they stand: the instances are packed arrays at their struct
// stride, the atlas an R8 image. The bytes Metal and Vulkan bind.

UBIQUITTY_WEB_EXPORT int ubiquittyWebIsFrameWithheld() { return (terminal && terminal->isFrameWithheld()) ? 1 : 0; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebBuildFrame() { return (terminal && terminal->buildFrame()) ? 1 : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebCellInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->cellInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebCellInstanceCount() { return terminal ? terminal->cellInstanceCount() : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebOverlayInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->overlayInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebOverlayInstanceCount() { return terminal ? terminal->overlayInstanceCount() : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebBoxFillInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->boxFillInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebBoxFillInstanceCount() { return terminal ? terminal->boxFillInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebFrameUsesBitmapFace() { return terminal && terminal->frameUsesBitmapFace(); }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierBoxFillCount() { return terminal ? static_cast<int>(terminal->cursorTier().boxFills) : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebDecorationInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->decorationInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebDecorationInstanceCount() { return terminal ? terminal->decorationInstanceCount() : 0; }

// The cursor tier's tails (InstanceCounts::cursorTier): how many instances at
// the end of each grid stream are the cursor's cell re-emitted with the
// cursor's colours. The GPU path draws them as a layer of their own after
// every head, so the cell's own ink is not composited twice.
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierCellCount() { return terminal ? static_cast<int>(terminal->cursorTier().cells) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierWideGlyphCount() { return terminal ? static_cast<int>(terminal->cursorTier().wideGlyphs) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierProportionalGlyphCount() { return terminal ? static_cast<int>(terminal->cursorTier().proportionalGlyphs) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierProportionalStripCount() { return terminal ? static_cast<int>(terminal->cursorTier().proportionalStrips) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierLigatureGlyphCount() { return terminal ? static_cast<int>(terminal->cursorTier().ligatureGlyphs) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierColorGlyphCount() { return terminal ? static_cast<int>(terminal->cursorTier().colorGlyphs) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorTierDecorationCount() { return terminal ? static_cast<int>(terminal->cursorTier().decorations) : 0; }

// Two-cell glyphs and the page they draw from. A separate stream and a separate
// texture because a cell quad samples one texture, and a wide slot is two cells
// across — so the same coordinate names a different glyph on the mono page, and
// baking it into a cell draws a sharp, real, wrong one.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebWideGlyphInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->wideGlyphInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebWideGlyphInstanceCount() { return terminal ? terminal->wideGlyphInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebWideAtlasPixels() { return terminal ? terminal->wideAtlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebWideAtlasWidth() { return terminal ? terminal->wideAtlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebWideAtlasHeight() { return terminal ? terminal->wideAtlasHeight() : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebProportionalGlyphInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->proportionalGlyphInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalGlyphInstanceCount() { return terminal ? terminal->proportionalGlyphInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebProportionalAtlasPixels() { return terminal ? terminal->proportionalAtlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalAtlasWidth() { return terminal ? terminal->proportionalAtlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalAtlasHeight() { return terminal ? terminal->proportionalAtlasHeight() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalAtlasGeneration() { return terminal ? static_cast<int>(terminal->proportionalAtlasGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebProportionalStripInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->proportionalStripInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalStripInstanceCount() { return terminal ? terminal->proportionalStripInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebProportionalStripAtlasPixels() { return terminal ? terminal->proportionalStripAtlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalStripAtlasWidth() { return terminal ? terminal->proportionalStripAtlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalStripAtlasHeight() { return terminal ? terminal->proportionalStripAtlasHeight() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebProportionalStripAtlasIsDirty() { return terminal && terminal->proportionalStripAtlasIsDirty() ? 1 : 0; }
UBIQUITTY_WEB_EXPORT void ubiquittyWebDidUploadProportionalStripAtlas()
{
    if (terminal)
        terminal->didUploadProportionalStripAtlas();
}
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebLigatureGlyphInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->ligatureGlyphInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebLigatureGlyphInstanceCount() { return terminal ? terminal->ligatureGlyphInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebLigatureAtlasPixels() { return terminal ? terminal->ligatureAtlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebLigatureAtlasWidth() { return terminal ? terminal->ligatureAtlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebLigatureAtlasHeight() { return terminal ? terminal->ligatureAtlasHeight() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebLigatureAtlasIsDirty() { return terminal && terminal->ligatureAtlasIsDirty() ? 1 : 0; }
UBIQUITTY_WEB_EXPORT void ubiquittyWebDidUploadLigatureAtlas()
{
    if (terminal) {
        terminal->didUploadLigatureAtlas();
    }
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebFontResourceGeneration() { return terminal ? static_cast<int>(terminal->fontResourceGeneration()) : 0; }

// The colour sheet is RGBA where the mono and wide sheets are R8, so the width
// is in pixels rather than bytes and a caller uploads it with four times the
// stride. A null pixel pointer is the rasterizer having no colour source, which
// is the same condition that leaves the instance count at zero — a caller that
// checks the count alone never reaches a sheet that is not there.
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebColorGlyphInstances()
{
    return terminal ? reinterpret_cast<const unsigned char*>(terminal->colorGlyphInstances()) : nullptr;
}
UBIQUITTY_WEB_EXPORT int ubiquittyWebColorGlyphInstanceCount() { return terminal ? terminal->colorGlyphInstanceCount() : 0; }
UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebColorAtlasPixels() { return terminal ? terminal->colorAtlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebColorAtlasWidth() { return terminal ? terminal->colorAtlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebColorAtlasHeight() { return terminal ? terminal->colorAtlasHeight() : 0; }
UBIQUITTY_WEB_EXPORT const char* ubiquittyWebRichTextFrameJSON() { return terminal ? terminal->richTextFrameJSON() : "{}"; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebFrameRequiresCPUCompositing() { return (terminal && terminal->frameRequiresCPUCompositing()) ? 1 : 0; }

UBIQUITTY_WEB_EXPORT const unsigned char* ubiquittyWebAtlasPixels() { return terminal ? terminal->atlasPixels() : nullptr; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAtlasWidth() { return terminal ? terminal->atlasWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebAtlasHeight() { return terminal ? terminal->atlasHeight() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebMonoAtlasGeneration() { return terminal ? static_cast<int>(terminal->monoAtlasGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebWideAtlasGeneration() { return terminal ? static_cast<int>(terminal->wideAtlasGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebColorAtlasGeneration() { return terminal ? static_cast<int>(terminal->colorAtlasGeneration()) : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCellWidth() { return terminal ? terminal->cellWidth() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebCellHeight() { return terminal ? terminal->cellHeight() : 0; }

UBIQUITTY_WEB_EXPORT int ubiquittyWebRows() { return terminal ? terminal->rows() : 0; }
UBIQUITTY_WEB_EXPORT int ubiquittyWebColumns() { return terminal ? terminal->columns() : 0; }

// The terminal's default background as 0xRRGGBB.
//
// The page paints the padding, so it has to know what colour the terminal
// considers "behind the text". A page holding its own constant paints the frame
// one colour and the grid another the moment a theme is applied, and the two
// disagreeing at the window edge reads as a rendering fault.
UBIQUITTY_WEB_EXPORT int ubiquittyWebBackgroundColor()
{
    return terminal ? terminal->backgroundColor() : 0;
}

// The window padding, in CSS pixels. A double, not an int: the range is whole
// points today and the schema owns that, so an int here would be this file
// deciding a precision the settings table is free to change.
UBIQUITTY_WEB_EXPORT double ubiquittyWebPadding() { return terminal ? terminal->padding() : 0.0; }

// The `[underline]` tuning, set together. Four exports rather than one struct
// because the boundary carries numbers, and read back through four getters so a
// caller that clamps can see what it got.

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetPadding(double cssPixels)
{
    if (terminal)
        terminal->setPadding(cssPixels);
}

// The four edges, which Core resolves separately and does not default to one
// value — the built-in top is zero and the other three are six. Set through the
// shorthand alone, the browser drew a top inset the other frontends do not.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetPaddingInsets(double left, double right, double top, double bottom)
{
    if (terminal)
        terminal->setPaddingInsets({ static_cast<float>(left), static_cast<float>(right),
            static_cast<float>(top), static_cast<float>(bottom) });
}

UBIQUITTY_WEB_EXPORT double ubiquittyWebPaddingLeft() { return terminal ? terminal->paddingInsets().left : 0.0; }
UBIQUITTY_WEB_EXPORT double ubiquittyWebPaddingRight() { return terminal ? terminal->paddingInsets().right : 0.0; }
UBIQUITTY_WEB_EXPORT double ubiquittyWebPaddingTop() { return terminal ? terminal->paddingInsets().top : 0.0; }
UBIQUITTY_WEB_EXPORT double ubiquittyWebPaddingBottom() { return terminal ? terminal->paddingInsets().bottom : 0.0; }

// Extra space between rows. Baked into the cell, so this rebuilds the font
// stack and the caller re-fits its grid exactly as it does after a zoom.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetLineSpacing(double cssPixels)
{
    if (terminal)
        terminal->setLineSpacing(cssPixels);
}

UBIQUITTY_WEB_EXPORT double ubiquittyWebLineSpacing() { return terminal ? terminal->lineSpacing() : 0.0; }

// Whether the glyph under a block cursor takes a contrasting colour. Nothing
// here set it, so the option's own default answered and the setting reached
// only macOS's Metal renderer.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetCursorInvertText(int shouldInvert)
{
    if (terminal)
        terminal->setCursorTextContrast(shouldInvert != 0
                ? Ubiquitty::Web::WebTerminal::CursorTextContrast::Invert
                : Ubiquitty::Web::WebTerminal::CursorTextContrast::Keep);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebCursorInvertText() { return terminal && terminal->shouldCursorInvertText() ? 1 : 0; }

// The renderer's OSC 66 facts, both off on a fresh terminal. A host that
// embeds this module for its own grid renderer leaves them off; the bundled
// page renderer (terminal.js) draws both and turns them on after create.
UBIQUITTY_WEB_EXPORT void ubiquittyWebSetDrawsSizedText(int draws)
{
    if (!terminal)
        return;
    using Ubiquitty::Runtime::DrawnText;
    const bool isProportionalDrawn = Ubiquitty::Runtime::drawsProportionalText(terminal->drawnText());
    if (draws != 0)
        terminal->setDrawnText(isProportionalDrawn ? DrawnText::SizedAndProportional : DrawnText::Sized);
    else
        terminal->setDrawnText(isProportionalDrawn ? DrawnText::Proportional : DrawnText::GridOnly);
}

UBIQUITTY_WEB_EXPORT void ubiquittyWebSetDrawsProportionalText(int draws)
{
    if (!terminal)
        return;
    using Ubiquitty::Runtime::DrawnText;
    const bool isSizedDrawn = Ubiquitty::Runtime::drawsSizedText(terminal->drawnText());
    if (draws != 0)
        terminal->setDrawnText(isSizedDrawn ? DrawnText::SizedAndProportional : DrawnText::Proportional);
    else
        terminal->setDrawnText(isSizedDrawn ? DrawnText::Sized : DrawnText::GridOnly);
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebDrawsProportionalText()
{
    return terminal && Ubiquitty::Runtime::drawsProportionalText(terminal->drawnText()) ? 1 : 0;
}

// The grid that fits a viewport, padding removed — the division itself, not the
// numbers to do it with. The page held its own `floor(viewport / cell)`, which
// is `Rendering::gridFromViewport` rewritten in a second language, and a second
// copy of a rule is a place for the frontends to disagree about the same window.
//
// The viewport arrives in DEVICE pixels and `scale` is device pixels per CSS
// pixel, because that is the unit the padding is stated in.
UBIQUITTY_WEB_EXPORT int ubiquittyWebGridColumns(double viewportWidth, double viewportHeight, double scale)
{
    return terminal ? terminal->gridForViewport(viewportWidth, viewportHeight, scale).columns : 0;
}

UBIQUITTY_WEB_EXPORT int ubiquittyWebGridRows(double viewportWidth, double viewportHeight, double scale)
{
    return terminal ? terminal->gridForViewport(viewportWidth, viewportHeight, scale).rows : 0;
}

} // extern "C"
