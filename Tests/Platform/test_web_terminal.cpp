// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// test_web_terminal.cpp — the browser frontend's bridge, driven without a browser.
//
// WebTerminal is where the web frontend decides: the export shim below it
// converts pointers, lengths and arguments and nothing else, and the page above
// it owns a canvas and a socket. Everything between — geometry, the snapshot
// the page blits, the mouse gate, the sync frames that carry a shell — is here,
// so it is reachable from ctest. A conversion can still drop or transpose an
// argument, so the last section calls the shim as the page does.
//
// A build check alone says only that the web path compiles. It cannot see an
// encoder with no opinion about motion behind a pointer gate that compiles.

#include "Core/Input/Keybindings.h"
#include "Core/Keys/KeyTranslation.h"
#include "Core/OSC/Dispatch.h"
#include "Core/Protocol/Sync/AttachmentLink.h"
#include "Harness.h"
#include "ScreenPlaneFixture.h"

#include "Core/Input/PointerInput.h"
#include "Core/Keys/Keymap.h"
#include "Core/Keys/KittyKeyboard.h"
#include "Core/Mouse/MouseEvent.h"
#include "Core/OSC/Dispatch.h"
#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/Preferences.h"
#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Preferences/PreferencesDefaults.h"
// The host's own wording for a refusal, which a terminate outcome carries
// rather than restating.
#include "Core/Protocol/Sync/AttachVerdictText.h"
#include "Core/Protocol/Sync/ConsentStatus.h"
#include "Core/Protocol/Sync/NativeAttachment.h"
#include "Core/Screen/Scrollback.h"
// A host-side Terminal to publish checkpoints from, which is what a reconnect
// case needs two of.
#include "Core/TerminalOperations.h"
// `Session::TerminateOutcome`, the numbers the web mirror pins itself to. Named
// here because the claim under test is that the two agree, and a test that read
// only the mirror could not tell.
#include "Core/Codec/JSON.h"
#include "Core/Session/ResumeRecordFormat.h"
#include "Core/Session/ScriptedListingHost.h"
#include "Core/Session/SessionDirectoryCore.h"
#include "Platform/Web/WebTerminal.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <span>
#include <string>
#include <thread>
#include <variant>
#include <vector>

namespace {

using Ubiquitty::Web::WebTerminal;

// The settings this binary reads, pinned to none.
//
// `Preferences::values()` parses whatever the PAL backend answers for the
// configuration blob on first use, and on a developer's machine that is their
// own config.toml — this suite was measured reading padding 8, font size 12 and
// line spacing 1 against Core's 6, none and 2. Every assertion below that names
// a `Defaults::` value is therefore an assertion about the machine unless the
// set is pinned first.
//
// A frontend that honours its configuration rather than seeding itself from
// `Defaults::` directly is what makes the leak reachable, so the pin belongs
// with it.
//
// Static storage so it runs before main and before any case: the singleton is
// created lazily, and the first thing to touch it decides what every later test
// sees.
// Configures Core from a case's own document, strictly: a misspelt key fails
// the case rather than leaving it to run on a default.
void configureDocument(const std::string& document)
{
    (void)Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict);
}

struct PinnedPreferences {
    PinnedPreferences() { configureDocument(""); }
};
const PinnedPreferences s_pinnedPreferences;

// The block cursor, for the cases that count its tier or its hollow. The
// re-emitted cell at the tail of the stream (InstanceCounts::cursorTier) and
// the stroked outline an unfocused terminal draws are the focused BLOCK's
// alone: a bar or an underline is an overlay, re-emits no cell, and draws the
// same with and without focus. The shape is a `[cursor]` preference the
// terminal reads at construction, and the shipped default is a bar, so a case
// that measures the block names it, for its own scope, rather than inheriting
// whichever default ships.
struct BlockCursorConfiguration {
    BlockCursorConfiguration() { (void)Ubiquitty::Preferences::configure("[cursor]\nshape = \"block\"\n", Ubiquitty::Preferences::ParseMode::Strict); }
    ~BlockCursorConfiguration() { (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict); }
};

namespace Sync = Ubiquitty::Protocol::Sync;

// The borrowed body of the single first-byte Greet a builder wrote.
std::span<const std::uint8_t> helloPayload(const std::vector<std::uint8_t>& frames)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    Sync::EnvelopeError error = Sync::EnvelopeError::None;
    const auto frame = Sync::decodeDatagram(frames, error);
    if (!frame || frame->kind != Sync::FrameKind::Greet || frame->channel != 0)
        return {};
    return frame->body;
}

// The actual fixture incarnation every page host names in Welcome.selection.
constexpr std::uint64_t pageDaemonInstanceID = 0x5EED;

// The host end of a page's connection: a terminal it publishes, and the
// screen plane that carries it to the page.
class PageHost {
public:
    explicit PageHost(std::uint32_t sessionID, int rows = 24, int columns = 80, Ubiquitty::Protocol::Sync::Role role = Ubiquitty::Protocol::Sync::Role::Owner)
        : m_screen(sessionID, pageDaemonInstanceID, rows, columns, 0, role)
    {
    }

    /// The host's terminal, which a case writes to between publishes.
    Ubiquitty::Terminal& terminal() { return m_screen.terminal(); }

    /// Reads the page's first-byte Greet and returns its Welcome and picture.
    std::vector<std::uint8_t> answer(const std::vector<std::uint8_t>& hello)
    {
        m_screen.plane().receive(hello);
        return m_screen.publish();
    }

    /// Reads bytes the page sent that a case collected itself.
    void receive(const std::vector<std::uint8_t>& sent) { m_screen.plane().receive(sent); }

    /// What the host sends for what it has read, publishing nothing.
    std::vector<std::uint8_t> flush() { return m_screen.flush(); }

    /// Changes the pane's records without publishing another screen.
    void setFacts(const Ubiquitty::Protocol::Sync::PaneFacts& facts) { m_screen.plane().setFacts(facts); }

    /// The input events the page's client was written at the pane's program.
    [[nodiscard]] const UbiquittyTest::TypedInput& typed() { return m_screen.plane().typed(); }

    /// Whether the page's client last said it holds the keyboard focus.
    [[nodiscard]] bool isClientFocused() { return m_screen.plane().connection().facts().isFocused; }

    /// The host's end of the page's screen connection, for a case that
    /// lists the host or answers a call.
    [[nodiscard]] Ubiquitty::Protocol::Sync::HostConnection& connection() { return m_screen.plane().connection(); }

    /// The pane's producer for effects that depend on its published picture.
    ///
    /// - Returns: The source owned by this host fixture.
    [[nodiscard]] Ubiquitty::Protocol::Sync::PaneSource& source() { return m_screen.plane().source(); }

    /// Reads what the page owes and returns what the host has queued for it,
    /// publishing nothing.
    std::vector<std::uint8_t> exchange(WebTerminal& page)
    {
        m_screen.plane().receive(page.takePendingHostFrame());
        std::vector<std::uint8_t> out;
        m_screen.plane().flush(out);
        return out;
    }

    /// Reads what the page owes and returns the frames that publish the
    /// host's terminal as it now stands.
    std::vector<std::uint8_t> publish(WebTerminal& page)
    {
        m_screen.plane().receive(page.takePendingHostFrame());
        return m_screen.publish();
    }

private:
    UbiquittyTest::HostScreen m_screen;
};

// Feeds what a host sent; false once the page's decoder faults.
bool feedWire(WebTerminal& terminal, const std::vector<std::uint8_t>& wire)
{
    return terminal.feedFromHost(
        std::string_view(reinterpret_cast<const char*>(wire.data()), wire.size()));
}

/// A held attachment whose identity, approval and first picture use the real
/// screen-plane owners. No pane is bound until exact approval succeeds.
class PendingPageHost {
public:
    explicit PendingPageHost(std::uint32_t sessionID = 7)
        : m_question { .requestID = 71, .sessionID = sessionID }
        , m_table({ pageDaemonInstanceID, 0 }, Ubiquitty::Protocol::Sync::measuredResumePolicy(), m_secrets)
        , m_terminal(makeTerminal())
        , m_source(*m_terminal, { sessionID, pageDaemonInstanceID })
        , m_connection(Ubiquitty::Protocol::Sync::measuredHostPolicy(0),
              { .hostInstanceID = { pageDaemonInstanceID, 0 }, .pendingConsent = m_question, .selection = { .target = Ubiquitty::Protocol::Sync::AdmissionTarget::Session, .sessionID = sessionID, .workspaceID = 0, .daemonInstanceID = pageDaemonInstanceID, .socketName = "fixture.sock", .buildFlags = 0, .hostPlatform = "fixture" } })
    {
        m_connection.serveFromTable(m_table, authority(), 1,
            [](Ubiquitty::Protocol::Sync::ID128) -> Ubiquitty::Protocol::Sync::PaneSource* { return nullptr; });
    }

    /// Greets the real host and delivers its mandatory pending Welcome.
    [[nodiscard]] bool begin(WebTerminal& page)
    {
        receive(page.buildHello("t", m_question.sessionID));
        CHECK_MSG(!page.isAttached(), "Greet alone grants no attachment");
        std::vector<std::uint8_t> wire;
        flush(wire);
        return feedWire(page, wire);
    }

    /// Queues one exact Pending, Denied or Expired transition through its owner.
    [[nodiscard]] bool sendStatus(WebTerminal& page, Ubiquitty::Protocol::Sync::ConsentStatusPhase phase)
    {
        if (!m_connection.sendConsentStatus({ .question = m_question, .phase = phase }))
            return false;
        std::vector<std::uint8_t> wire;
        flush(wire);
        return feedWire(page, wire);
    }

    /// Promotes the same held identity, delivering approval before any pane.
    [[nodiscard]] bool approve(WebTerminal& page)
    {
        if (!m_connection.deliverConsentApproval(m_question, authority(), m_now, m_now + 1'000'000))
            return false;
        std::vector<std::uint8_t> wire;
        flush(wire);
        return feedWire(page, wire);
    }

    /// Binds and publishes the first authorized picture on this same connection.
    [[nodiscard]] bool publish(WebTerminal& page)
    {
        receive(page.takePendingHostFrame());
        const auto handle = m_connection.bindPane(m_source);
        if (!handle)
            return false;
        UbiquittyTest::showPane(m_connection, handle, advance());
        m_source.publish(Ubiquitty::Protocol::Sync::FrameClass::Settled, advance());
        std::vector<std::uint8_t> wire;
        flush(wire);
        return feedWire(page, wire);
    }

    [[nodiscard]] Ubiquitty::Terminal& terminal() { return *m_terminal; }
    [[nodiscard]] Ubiquitty::Protocol::Sync::ConsentBinding question() const { return m_question; }
    [[nodiscard]] Ubiquitty::Protocol::Sync::ConnectionState state() const { return m_connection.state(); }

private:
    class Secrets final : public Ubiquitty::Protocol::Sync::SecretSource {
    public:
        Ubiquitty::Protocol::Sync::ID128 nextSecret() override { return { ++m_next, pageDaemonInstanceID }; }

    private:
        std::uint64_t m_next = 0;
    };

    static std::unique_ptr<Ubiquitty::Terminal> makeTerminal()
    {
        auto terminal = std::make_unique<Ubiquitty::Terminal>();
        Ubiquitty::hardReset(*terminal);
        Ubiquitty::resize(*terminal, 24, 80);
        return terminal;
    }

    static Ubiquitty::Protocol::Sync::ConnectionAuthority authority()
    {
        return { .principal = "verified-page", .mayDrive = true, .verifiedKind = Ubiquitty::Protocol::Sync::ClientKind::Agent };
    }

    std::uint64_t advance() { return m_now += 20'000; }

    void receive(const std::vector<std::uint8_t>& wire)
    {
        m_connection.receiveStream(wire, advance());
    }

    void flush(std::vector<std::uint8_t>& wire)
    {
        const auto now = advance();
        m_connection.service(now);
        std::vector<std::uint8_t> frame;
        while (m_connection.popStreamFrame(frame, now)) {
            wire.insert(wire.end(), frame.begin(), frame.end());
            frame.clear();
        }
    }

    const Ubiquitty::Protocol::Sync::ConsentBinding m_question;
    Secrets m_secrets;
    Ubiquitty::Protocol::Sync::AttachmentTable m_table;
    std::unique_ptr<Ubiquitty::Terminal> m_terminal;
    Ubiquitty::Protocol::Sync::PaneSource m_source;
    Ubiquitty::Protocol::Sync::HostConnection m_connection;
    std::uint64_t m_now = 1'000'000;
};

/// Encodes a typed status directly for a client-side rejection case.
std::vector<std::uint8_t> ownConsentStatusWire(Ubiquitty::Protocol::Sync::ConsentStatus status)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    const auto body = Sync::consentStatusNotify(status);
    CHECK(body);
    if (!body)
        return {};
    std::vector<std::uint8_t> frame;
    CHECK(Sync::appendFrame(frame, Sync::FrameKind::Notify, 0, *body));
    return frame;
}

/// Answers one actual typed termination and returns its exact requested session.
/// - Parameters:
///   - page: The client whose result owner is exercised.
///   - host: The matching physical host connection.
///   - frame: The client's encoded request.
///   - outcome: The correlated result word.
/// - Returns: The requested session, or zero when the fixture saw no valid call.
std::uint32_t answerPageTermination(WebTerminal& page, PageHost& host, const std::vector<std::uint8_t>& frame, std::string_view outcome)
{
    namespace Control = Ubiquitty::Protocol::Control;
    namespace JSON = Ubiquitty::Codec::JSON;
    host.receive(frame);
    const auto calls = host.connection().takeCalls();
    CHECK_EQ(calls.size(), 1u);
    if (calls.size() != 1)
        return 0;
    const auto request = Control::decodeRequest(calls.front().text, {});
    CHECK_STR_EQ(request.method, "session.terminate");
    CHECK(request.hasID && request.id.isString());
    const auto session = static_cast<std::uint32_t>(request.params.numberOr("session"));
    auto result = JSON::Value::object();
    result.set("session", JSON::Value::number(session));
    result.set("outcome", JSON::Value::string(std::string(outcome)));
    CHECK(host.connection().answerCall(calls.front().callIndex, JSON::serialize(Control::rpcResult(request.idOrNull(), std::move(result)))) == Ubiquitty::Protocol::Sync::CallAnswer::Sent);
    for (int round = 0; round < 3; ++round)
        CHECK(feedWire(page, host.exchange(page)));
    return session;
}

/// Establishes the real typed connection with the page's explicit serve choice.
void attachClipboardPage(WebTerminal& terminal, PageHost& host, WebTerminal::ClipboardServing serving)
{
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", 7, serving))));
    for (int round = 0; round < 3; ++round)
        CHECK(feedWire(terminal, host.exchange(terminal)));
}

/// Delivers an exact correlated request through the host's typed scheduler.
void requestPageClipboard(WebTerminal& terminal, PageHost& host, const Sync::ClipboardRequestMessage& request)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    const auto panes = host.connection().boundPanes();
    REQUIRE(panes.size() == 1);
    REQUIRE(host.connection().requestClipboard(panes.front().first, { .requestID = request.requestID, .buffer = Ubiquitty::ClipboardBuffer::Clipboard, .kind = request.kind == Sync::ClipboardRequestKind::Types ? Sync::EffectClipboardRequestKind::Types : Sync::EffectClipboardRequestKind::Item, .mime = request.mime }));
    CHECK(feedWire(terminal, host.exchange(terminal)));
}

/// Reads the page's answer using the actual host owner and payload decoder.
std::optional<Sync::ClipboardDataMessage> pageClipboardAnswer(PageHost& host, const std::vector<std::uint8_t>& bytes)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    host.receive(bytes);
    std::optional<Sync::ClipboardDataMessage> result;
    CHECK(host.connection().drainClipboardReplies([&](std::uint32_t, const Sync::ClipboardRead& request, Sync::EffectClipboardStatus status, const Sync::EffectClipboardBundle& bundle) {
        CHECK(!result);
        result.emplace();
        result->requestID = request.requestID;
        result->status = static_cast<Sync::ClipboardServeStatus>(status);
        for (const auto& item : std::span(bundle.items).first(bundle.count))
            result->items.push_back({ std::string(item.mime), std::vector<std::uint8_t>(item.data.begin(), item.data.end()) });
        return true;
    }));
    return result;
}

/// The bytes a program is written.
class ProgramBytes final : public Ubiquitty::Runtime::ByteSink {
public:
    /// Takes bytes whole.
    ///
    /// - Parameters:
    ///   - clientInstance: The client whose input they are.
    ///   - bytes: The bytes.
    /// - Returns: `Written`.
    [[nodiscard]] Ubiquitty::Protocol::Sync::WriteStatus writeAll(Ubiquitty::Protocol::Sync::ID128, std::span<const std::uint8_t> bytes) override
    {
        written.append(bytes.begin(), bytes.end());
        return Ubiquitty::Protocol::Sync::WriteStatus::Written;
    }

    std::string written;
};

/// A page attached to a host, with the host's program on the far side of the
/// input: what the page sends is an event, and the bytes the program reads
/// are what the host encodes it to under the modes the program set. A case
/// that asks what a key or a click sends asks here, since a page with no
/// host sends nothing.
struct AttachedPage {
    WebTerminal terminal;
    PageHost host;
    ProgramBytes program;
    Ubiquitty::Runtime::RemoteInputEncoder encoder;
    std::size_t eventsEncoded = 0;

    /// - Parameters:
    ///   - rows: The grid's rows, the page's and the host's.
    ///   - columns: Its columns.
    explicit AttachedPage(int rows = 24, int columns = 80)
        : terminal(rows, columns, 1)
        , host(1, rows, columns)
        , encoder(host.terminal(), program)
    {
        (void)terminal.feedFromHost(asText(host.answer(terminal.buildHello("t", 0))));
        settle();
    }

    /// Carries what each end owes the other until both are quiet.
    void settle()
    {
        for (int round = 0; round < 3; ++round)
            (void)terminal.feedFromHost(asText(host.publish(terminal)));
    }

    /// The host's program prints, and the page's mirror follows: text, or a
    /// mode the program sets.
    ///
    /// - Parameter bytes: What it prints.
    void programPrints(std::string_view bytes)
    {
        Ubiquitty::processBytes(&host.terminal(), bytes);
        settle();
    }

    /// The bytes the program reads for a frame the page built: the host
    /// takes the frame, and each event in it is encoded under the program's
    /// modes as the host's writer does.
    ///
    /// - Parameter frame: The frame, as the page would send it.
    /// - Returns: The bytes; empty for a frame that carries no input.
    std::string programReads(const std::vector<std::uint8_t>& frame)
    {
        host.receive(frame);
        (void)terminal.feedFromHost(asText(host.flush()));
        const std::size_t before = program.written.size();
        const std::vector<Ubiquitty::Protocol::Sync::InputIntent>& events = host.typed().events();
        for (; eventsEncoded < events.size(); ++eventsEncoded)
            (void)encoder.write({ 1, 2 }, events[eventsEncoded]);
        return program.written.substr(before);
    }

private:
    /// Bytes as the page's feed takes them.
    static std::string_view asText(const std::vector<std::uint8_t>& bytes) { return { reinterpret_cast<const char*>(bytes.data()), bytes.size() }; }
};

// What a person looking at the tab would read off it.
std::string screenText(WebTerminal& terminal)
{
    terminal.selectAll();
    return terminal.selectionText();
}

// Unifont's native cell, the basis every geometry assertion below is stated in.
//
// The height carries the line spacing the frontend applies, derived from Core's
// default rather than restated: a literal here would have to be edited whenever
// that default moves, and editing a geometry constant to match new output is
// indistinguishable from papering over a regression.
constexpr int glyphWidth = 8;
constexpr int lineSpacingAtScaleOne = static_cast<int>(Ubiquitty::Preferences::Defaults::lineSpacing + 0.5);
constexpr int glyphHeight = 16 + lineSpacingAtScaleOne;

/// The cell height at a glyph scale, spacing included.
///
/// Spacing is in points and scales with the display, so it multiplies alongside
/// the type rather than being added once.
///
/// - Parameter scale: The glyph scale the terminal was built with.
/// - Returns: The expected cell height in device pixels.
constexpr int cellHeightAtScale(int scale)
{
    return 16 * scale + static_cast<int>(Ubiquitty::Preferences::Defaults::lineSpacing * scale + 0.5);
}

TEST(testGeometryFollowsTheRequestedGrid)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.rows() == 24);
    CHECK(terminal.columns() == 80);

    const std::vector<std::uint8_t>& image = terminal.render();
    CHECK_MSG(!image.empty(), "a fresh terminal still renders");
    CHECK(terminal.imageWidth() == 80 * glyphWidth);
    CHECK(terminal.imageHeight() == 24 * glyphHeight);
    // Tightly packed RGBA8: the page blits this with no stride of its own.
    CHECK(image.size() == static_cast<std::size_t>(terminal.imageWidth()) * terminal.imageHeight() * 4);
}

// The scale exists because Unifont at 1:1 is a hairline on a Retina display.
// It multiplies the raster, so it must multiply the image in both axes and
// leave the cell count alone — a scale that changed the grid would silently
// reflow the shell every time the page moved between displays.
TEST(testGlyphScaleMultipliesPixelsNotCells)
{
    WebTerminal terminal(10, 20, 3);
    terminal.render();
    CHECK(terminal.rows() == 10);
    CHECK(terminal.columns() == 20);
    CHECK(terminal.imageWidth() == 20 * glyphWidth * 3);
    CHECK(terminal.imageHeight() == 10 * cellHeightAtScale(3));
}

// An inline image sized in pixels is placed by the cell's device-pixel size,
// which only the frontend knows. A frontend that never publishes it leaves Core
// with nothing to divide by: the pixel size is ignored, the image draws at its
// natural size times the device scale, and the cursor steps by a fallback cell
// height — a 24 px picture drawn 48 px square with the cursor a row below it.
//
// At scale 2 the cell is 16 by 36 device pixels. `width=24px` is two columns,
// the square picture fits them at 32 pixels tall, and 32 pixels is one row: the
// cursor stays on the image's row. A 40-pixel-tall box is two such rows, and
// one row once the line spacing makes the cell 40 pixels tall, which a size
// published once and never again still counts as two.
TEST(testAnInlineImageSizedInPixelsIsPlacedByThePublishedCell)
{
    const std::string payload = ";size=104:"
                                "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAL0lEQVR42mO4Y6RPELXOZCCIGEYNGjVo1CC8Bql1XyKItnYyEESjBo0aNGoQXgQAtVDf3/jjW+IAAAAASUVORK5CYII=\x07";
    const std::string fitted = "\x1b]1337;File=inline=1;width=24px;height=24px" + payload;
    const std::string stretched = "\x1b]1337;File=inline=1;preserveAspectRatio=0;width=16px;height=40px" + payload;

    WebTerminal terminal(8, 14, 2);
    terminal.render();
    REQUIRE_MSG(terminal.imageWidth() == 14 * 16 && terminal.imageHeight() == 8 * 36, "the cell is 16 by 36 device pixels");
    terminal.feed("x\r\n" + fitted);
    CHECK_MSG(terminal.cursorRow() == 1, "24px is two 16-pixel columns, 32 pixels tall, one 36-pixel row");
    terminal.feed("\x1b[2J\x1b[Hx\r\n" + stretched);
    CHECK_MSG(terminal.cursorRow() == 2, "40 pixels is two 36-pixel rows");

    terminal.setLineSpacing(4);
    terminal.render();
    REQUIRE_MSG(terminal.imageHeight() == 8 * 40, "the cell is 40 device pixels tall");
    terminal.feed("\x1b[2J\x1b[Hx\r\n" + stretched);
    CHECK_MSG(terminal.cursorRow() == 1, "and one 40-pixel row, by the size published with the new metrics");
}

TEST(testResizeChangesGridAndImage)
{
    WebTerminal terminal(24, 80, 1);
    terminal.render();

    terminal.resize(30, 100);
    CHECK(terminal.rows() == 30);
    CHECK(terminal.columns() == 100);

    const std::vector<std::uint8_t>& image = terminal.render();
    CHECK(terminal.imageWidth() == 100 * glyphWidth);
    CHECK(terminal.imageHeight() == 30 * glyphHeight);
    CHECK(image.size() == static_cast<std::size_t>(terminal.imageWidth()) * terminal.imageHeight() * 4);
}

// A nonsense resize is ignored, not applied. The page derives its grid by
// dividing the window by the cell size, and a window mid-teardown (or a hidden
// tab) divides to zero — which must leave the attached session exactly as it
// was rather than collapsing the grid the host is still writing to.
TEST(testNonsenseResizeLeavesTheGridIntact)
{
    WebTerminal terminal(24, 80, 1);
    terminal.render();

    const int width = terminal.imageWidth();
    const int height = terminal.imageHeight();

    terminal.resize(0, 0);
    terminal.resize(-4, 80);
    terminal.resize(24, -4);

    CHECK_MSG(terminal.rows() == 24, "rows survive a zero resize");
    CHECK_MSG(terminal.columns() == 80, "columns survive a zero resize");
    const std::vector<std::uint8_t>& image = terminal.render();
    CHECK_MSG(!image.empty(), "the terminal still renders");
    CHECK(terminal.imageWidth() == width);
    CHECK(terminal.imageHeight() == height);
}

TEST(testFedBytesReachTheRaster)
{
    WebTerminal blank(4, 20, 1);
    const std::vector<std::uint8_t> empty = blank.render();

    WebTerminal written(4, 20, 1);
    const char text[] = "hello";
    written.feed(text);
    const std::vector<std::uint8_t>& painted = written.render();

    CHECK(empty.size() == painted.size());
    CHECK_MSG(std::memcmp(empty.data(), painted.data(), empty.size()) != 0,
        "text fed through the VT changes the pixels the page blits");
}

// A document the page hands Core reaches the frames the terminal draws: bold
// red brightens to the bright red the configuration asks for, and a document
// handed in while the terminal runs reaches its next frame.
TEST(testTheConfiguredFrameStyleReachesTheRaster)
{
    const char boldRed[] = "\033[?25l\033[1;31mXXXX\033[0m";
    WebTerminal plain(2, 8, 1);
    plain.feed(boldRed);
    const std::vector<std::uint8_t> unbrightened = plain.render();

    (void)Ubiquitty::Preferences::configure("[text]\nbrighten_bold = true\n", Ubiquitty::Preferences::ParseMode::Strict);
    const std::vector<std::uint8_t> reloaded = plain.render();
    WebTerminal brightened(2, 8, 1);
    brightened.feed(boldRed);
    const std::vector<std::uint8_t> constructed = brightened.render();
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);

    REQUIRE(unbrightened.size() == constructed.size() && unbrightened.size() == reloaded.size());
    CHECK_MSG(std::memcmp(unbrightened.data(), constructed.data(), unbrightened.size()) != 0,
        "a terminal built under brighten_bold draws bold red bright");
    CHECK_MSG(std::memcmp(constructed.data(), reloaded.data(), constructed.size()) == 0,
        "a terminal running when the document arrives draws its next frame the same way");
}

// DECSET 2026: while an application holds the block it is composing a frame, and
// a frontend that repaints on every read shows it half-drawn. This is the case
// that made `kitten __benchmark__` print everything it wrote in the browser and
// nothing of it on macOS.
TEST(testSynchronizedOutputWithholdsTheFrame)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.buildFrame(), "an ordinary frame builds");

    const char begin[] = "\033[?2026h";
    terminal.feed(begin);
    CHECK_MSG(!terminal.buildFrame(), "an open block withholds the frame");

    const char end[] = "\033[?2026l";
    terminal.feed(end);
    CHECK_MSG(terminal.buildFrame(), "the completed frame presents");
}

// The DECSSDT status row reaches the instance path, not only the image one.
//
// The page has two renders: render() goes through Core's whole-terminal entry,
// which derives the status row itself, and buildFrame() hands the capture a
// terminal and options this file builds. Only the first is what the snapshot
// arm exercises, so the second can stop drawing the row with every golden
// still green: a page that renders the status line as whatever the grid holds
// in the last row is indistinguishable, from the goldens, from one that draws it.
//
// Counting instances would not see it: the builder emits one per cell whether
// the cell is blank or not, so both frames carry the same number. What
// separates them is the glyph each instance points at — a blank cell's atlas
// rect is empty, and a cell carrying a letter is not. The text is written to
// the status buffer and never to the grid, so a glyph on the last row can only
// have come from the row this path is expected to ask for.
TEST(testStatusRowReachesTheInstancePath)
{
    constexpr int rows = 4;
    const auto glyphsOnLastRow = [](const WebTerminal& terminal) {
        int count = 0;
        for (int index = 0; index < terminal.cellInstanceCount(); ++index) {
            const Ubiquitty::Rendering::CellInstance& instance = terminal.cellInstances()[index];
            const bool isLastRow = static_cast<int>(instance.gridPosition.y) == rows - 1;
            const bool hasGlyph = instance.atlasBottomRight.x > instance.atlasTopLeft.x
                && instance.atlasBottomRight.y > instance.atlasTopLeft.y;
            if (isLastRow && hasGlyph)
                count++;
        }
        return count;
    };

    WebTerminal bare(rows, 20, 1);
    CHECK_MSG(bare.buildFrame(), "a frame with no status line builds");
    CHECK_EQ(glyphsOnLastRow(bare), 0);

    WebTerminal statused(rows, 20, 1);
    const char sequence[] = "\033[2$~\033[1$}STATUS\033[0$}";
    statused.feed(sequence);
    CHECK_MSG(statused.buildFrame(), "a frame with a status line builds");
    CHECK_MSG(glyphsOnLastRow(statused) == 6,
        "the status row's six letters reach the instance stream the page draws");
}

// --- The mouse gate, as the browser reaches it ------------------------------
//
namespace {

// The page's pointer facts, as its listeners build them: a cell, no pixel,
// no modifiers unless the case names one.
Ubiquitty::Input::PointerFact fact(Ubiquitty::Input::PointerFact::Kind kind, Ubiquitty::Input::PointerButton button, int row, int column, int clickCount)
{
    Ubiquitty::Input::PointerFact fact;
    fact.kind = kind;
    fact.button = button;
    fact.row = row;
    fact.column = column;
    fact.clickCount = clickCount;
    fact.isDragging = kind == Ubiquitty::Input::PointerFact::Kind::Motion && button != Ubiquitty::Input::PointerButton::None;
    return fact;
}

const std::vector<std::uint8_t>& press(WebTerminal& terminal, int row, int column, int clickCount = 1)
{
    return terminal.pointer(fact(Ubiquitty::Input::PointerFact::Kind::Press, Ubiquitty::Input::PointerButton::Left, row, column, clickCount));
}

const std::vector<std::uint8_t>& shiftPress(WebTerminal& terminal, int row, int column)
{
    Ubiquitty::Input::PointerFact shifted = fact(Ubiquitty::Input::PointerFact::Kind::Press, Ubiquitty::Input::PointerButton::Left, row, column, 1);
    shifted.hasShift = true;
    return terminal.pointer(shifted);
}

const std::vector<std::uint8_t>& drag(WebTerminal& terminal, int row, int column)
{
    return terminal.pointer(fact(Ubiquitty::Input::PointerFact::Kind::Motion, Ubiquitty::Input::PointerButton::Left, row, column, 1));
}

const std::vector<std::uint8_t>& release(WebTerminal& terminal, int row, int column)
{
    return terminal.pointer(fact(Ubiquitty::Input::PointerFact::Kind::Release, Ubiquitty::Input::PointerButton::Left, row, column, 1));
}

const std::vector<std::uint8_t>& hover(WebTerminal& terminal, int row, int column)
{
    return terminal.pointer(fact(Ubiquitty::Input::PointerFact::Kind::Motion, Ubiquitty::Input::PointerButton::None, row, column, 1));
}

Ubiquitty::Input::ScrollFact notch(double deltaY, int row, int column)
{
    Ubiquitty::Input::ScrollFact fact;
    fact.deltaY = deltaY;
    fact.row = row;
    fact.column = column;
    return fact;
}

}

// Whether an event belongs to the program or to the page's own selection is
// the ladder's answer, asked at the boundary the browser calls. The frontends
// that predate the page each carried their own copy of the tracking rule; the
// page carries none, so a wrong answer reaches it unfiltered.

TEST(testNoTrackingModeMeansTheSelectionIsThePages)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    page.programPrints("some words");
    press(terminal, 0, 0);
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictOpenedGesture, "a fresh terminal tracks nothing: the press is the page's");
    release(terminal, 0, 0);

    page.programPrints("\033[?1000h");
    CHECK_MSG(!press(terminal, 0, 0).empty(), "DECSET 1000 turns tracking on: the press is the program's");
    release(terminal, 0, 0);

    page.programPrints("\033[?1000l");
    CHECK_MSG(press(terminal, 0, 0).empty(), "DECSET 1000l turns it back off");
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictOpenedGesture, "and the press is the page's again");
    release(terminal, 0, 0);
}

TEST(testEveryTrackingModeIsRecognised)
{
    const char* const setters[] = { "\033[?9h", "\033[?1000h", "\033[?1002h", "\033[?1003h" };
    for (const char* setter : setters) {
        AttachedPage page;
        WebTerminal& terminal = page.terminal;
        page.programPrints(setter);
        CHECK_MSG(!press(terminal, 0, 0).empty(), "a tracking mode the page must honour");
    }

    // The coordinate encodings are not tracking modes. A program that sets only
    // 1006 has asked how to be told, not to be told; treating that as tracking
    // would take the page's text selection away for nothing.
    const char* const encodings[] = { "\033[?1005h", "\033[?1006h", "\033[?1015h", "\033[?1016h" };
    for (const char* encoding : encodings) {
        AttachedPage page;
        WebTerminal& terminal = page.terminal;
        page.programPrints(encoding);
        CHECK_MSG(press(terminal, 0, 0).empty(), "an encoding alone is not tracking");
        CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictOpenedGesture, "and the press is the page's");
    }
}

TEST(testPressEncodesThroughTheBridge)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const char enable[] = "\033[?1000h\033[?1006h"; // VT200 tracking, SGR coords
    page.programPrints(enable);

    const std::vector<std::uint8_t>& frame = press(terminal, 8, 33);
    CHECK_MSG(!frame.empty(), "a press under 1000 produces a frame");
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictConsumed, "and the page prevents the browser's default");
    CHECK_MSG(!(terminal.pointerVerdict() & WebTerminal::PointerVerdictOpenedGesture), "a reported press opens no selection");

    // The report rides inside a Sync frame, so assert on the payload
    // rather than the offset: the framing is the protocol's business.
    CHECK_MSG(page.programReads(frame).find("\033[<0;34;9M") != std::string::npos,
        "SGR press, 1-based, at the cell the page named");
}

// The same rule test_mouse_encode_guards states about the encoder, asserted at
// the boundary the browser actually calls: a 1000-only program must never see
// motion, and turning on 1002 must let a drag through unchanged.
TEST(testMotionIsGatedAtTheBridge)
{
    {
        AttachedPage page;
        WebTerminal& terminal = page.terminal;
        const char enable[] = "\033[?1000h\033[?1006h";
        page.programPrints(enable);
        CHECK_MSG(hover(terminal, 8, 33).empty(), "1000 sends no button-less motion");
        press(terminal, 8, 30);
        CHECK_MSG(drag(terminal, 8, 33).empty(), "1000 sends no drag motion");
    }

    {
        AttachedPage page;
        WebTerminal& terminal = page.terminal;
        const char enable[] = "\033[?1002h\033[?1006h";
        page.programPrints(enable);
        press(terminal, 8, 30);
        CHECK_MSG(!drag(terminal, 8, 33).empty(), "1002 sends drag motion");
        CHECK_MSG(drag(terminal, 8, 33).empty(), "and one report per cell: the same cell again is not repeated");
        release(terminal, 8, 33);
        CHECK_MSG(hover(terminal, 8, 34).empty(), "1002 still sends no button-less motion");
    }

    {
        AttachedPage page;
        WebTerminal& terminal = page.terminal;
        const char enable[] = "\033[?1003h\033[?1006h";
        page.programPrints(enable);
        CHECK_MSG(!hover(terminal, 8, 33).empty(), "1003 sends button-less motion");
    }
}

TEST(aLocalWebResizeKeepsTheTextAtTheTopOfItsViewport)
{
    WebTerminal terminal(4, 12, 1);
    terminal.feed("a\r\n" + std::string(36, 'x') + "\r\nTARGET keeper\r\n");
    for (int line = 0; line < 20; ++line)
        terminal.feed(std::string(1 + line % 5 * 13, 'y') + "\r\n");
    terminal.scrollBy(terminal.scrollbackRows() - 4);
    const auto topText = [&] {
        terminal.clearSelection();
        press(terminal, 0, 0);
        drag(terminal, 0, 6);
        release(terminal, 0, 6);
        return std::string(terminal.selectionText());
    };
    CHECK_STR_EQ(topText(), "TARGET");
    for (const int columns : { 7, 23, 12 }) {
        terminal.resize(4, columns);
        CHECK_STR_EQ(topText(), "TARGET");
    }
    terminal.scrollBy(-terminal.scrollbackRows());
    terminal.resize(6, 9);
    CHECK_EQ(terminal.viewOffset(), 0);
}

TEST(testAReportedPressDropsThePagesSelection)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("some words on a line");
    press(terminal, 0, 0);
    drag(terminal, 0, 8);
    release(terminal, 0, 8);
    CHECK(terminal.hasSelection());

    terminal.feed("\033[?1000h\033[?1006h");
    press(terminal, 3, 3);
    CHECK_MSG(!terminal.hasSelection(), "a press the host takes is input to it, and the standing selection drops");
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictNeedsDisplay, "which the page repaints");
    release(terminal, 3, 3);

    const std::vector<std::uint8_t>& shifted = shiftPress(terminal, 0, 0);
    CHECK_MSG(shifted.empty(), "shift keeps a press local under reporting");
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictOpenedGesture, "and opens the page's own gesture");
    release(terminal, 0, 0);
}

TEST(testTheWheelScrollsTheViewOrReportsAsCoreDecides)
{
    AttachedPage page(4, 20);
    WebTerminal& terminal = page.terminal;
    for (int i = 0; i < 12; ++i)
        page.programPrints("line\r\n");
    CHECK_EQ(terminal.viewOffset(), 0);
    const std::vector<std::uint8_t>& local = terminal.scroll(notch(1.0, 0, 0));
    CHECK_MSG(local.empty(), "nothing tracking: no bytes for the host");
    CHECK_MSG(terminal.viewOffset() > 0, "and the view moved into history");
    CHECK_MSG(terminal.pointerVerdict() & WebTerminal::PointerVerdictNeedsDisplay, "which the page repaints");

    terminal.scroll(notch(-100.0, 0, 0));
    CHECK_EQ(terminal.viewOffset(), 0);

    page.programPrints("\033[?1000h\033[?1006h");
    const std::vector<std::uint8_t>& reported = terminal.scroll(notch(1.0, 2, 3));
    CHECK_MSG(page.programReads(reported).find("\033[<64;4;3M") != std::string::npos, "tracking: a wheel-up press at the cell");
    CHECK_EQ(terminal.viewOffset(), 0);
}

// The viewport wants among frames a page built.
std::vector<Sync::HistoryWant> viewportWants(const std::vector<std::uint8_t>& frames)
{
    std::vector<Sync::HistoryWant> wants;
    Sync::FrameDecoder decoder;
    decoder.append(frames);
    while (const auto frame = decoder.next()) {
        if (frame->kind != Sync::FrameKind::HistoryWant)
            continue;
        const auto want = Sync::decodeHistoryWant(frame->body);
        CHECK(want.has_value());
        if (want && want->priority == Sync::HistoryPriority::Viewport)
            wants.push_back(*want);
    }
    CHECK(decoder.error() == Sync::EnvelopeError::None);
    return wants;
}

// The host keeps 3,000 lines and backfills 2,000. A reader who scrolls to the
// oldest row the page holds asks for the lines above it with one viewport
// want, by the rule every Sync client shares; scrolling on within the same
// gap asks nothing more, and the lines that arrive become the view's history.
// A wheel that reaches the next gap carries its want in the gesture's own
// frame (Docs/sync.md §6.6 "The client pulls on scroll").
TEST(testAScrollPastTheBackfillPullsEachGapOnce)
{
    // The history is the host's before the page attaches: a backfill sends
    // the newest 2,000 of it, where lines scrolled during the attachment
    // would all travel as appends.
    WebTerminal terminal(24, 80, 1);
    PageHost host(1, 24, 80);
    Ubiquitty::setScrollbackLimit(&host.terminal(), 10'000);
    std::string lines;
    for (int line = 0; line < 3'000; ++line)
        lines += "history-" + std::to_string(line) + "\r\n";
    Ubiquitty::processBytes(&host.terminal(), lines);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello("t", 0))));
    const auto settle = [&] {
        for (int round = 0; round < 64; ++round)
            CHECK(feedWire(terminal, host.publish(terminal)));
    };
    settle();
    const int backfilled = terminal.scrollbackRows();
    CHECK_EQ(backfilled, static_cast<int>(Sync::defaultBackfillDepthLines));

    terminal.scrollToTop();
    terminal.scrollBy(-3);
    terminal.scrollBy(2);
    const std::vector<std::uint8_t> owed = terminal.takePendingHostFrame();
    const std::vector<Sync::HistoryWant> wants = viewportWants(owed);
    REQUIRE(wants.size() == 1);
    REQUIRE(wants[0].ranges.size() == 1);
    const Sync::LineRange first = wants[0].ranges[0];
    CHECK_EQ(first.to - first.from, std::uint64_t { 48 });

    host.receive(owed);
    settle();
    CHECK_EQ(terminal.scrollbackRows(), backfilled + 48);
    CHECK(viewportWants(terminal.takePendingHostFrame()).empty());

    const std::vector<std::uint8_t> gesture = terminal.scroll(notch(100.0, 0, 0));
    const std::vector<Sync::HistoryWant> next = viewportWants(gesture);
    REQUIRE(next.size() == 1);
    CHECK((next[0].ranges == std::vector<Sync::LineRange> { { first.from - 48, first.from } }));
}

// --- The GPU frame ----------------------------------------------------------
//
// buildFrame produces the instance stream Metal and Vulkan draw, from the shared
// builder, so these assert the stream's shape rather than any pixel: the page
// uploads what is here and the GPU composites it. Getting this wrong renders a
// blank or scrambled screen with every other test still green, which is the
// failure the CPU-blit path could not have.

TEST(testFrameProducesOneInstancePerCell)
{
    const BlockCursorConfiguration blockCursor;
    WebTerminal terminal(6, 20, 1);
    // The cursor is parked clear of the text, so the tier's one cell is the
    // only instance past the grid's own.
    const char text[] = "hello\x1b[3;10H";
    terminal.feed(text);
    CHECK(terminal.buildFrame());

    // Wide-continuation halves are skipped, so plain text is exactly one per
    // cell — plus the focused block's cell again at the tail, the cursor tier.
    CHECK_MSG(terminal.cellInstanceCount() == 6 * 20 + 1, "one instance per visible cell, and the cursor tier's");
    CHECK_MSG(terminal.cellInstances() != nullptr, "the stream is readable");
}

TEST(testFrameCarriesGlyphUVsForWrittenCellsAndNotBlanks)
{
    WebTerminal terminal(4, 20, 1);
    const char text[] = "hi";
    terminal.feed(text);
    CHECK(terminal.buildFrame());

    const Ubiquitty::Rendering::CellInstance* cells = terminal.cellInstances();
    // A blank cell is marked by an empty UV rect, which is how the shader knows
    // not to sample texel (0,0) and paint a stray glyph into every space.
    const auto hasGlyph = [](const Ubiquitty::Rendering::CellInstance& c) {
        return c.atlasBottomRight.x > c.atlasTopLeft.x;
    };
    CHECK_MSG(hasGlyph(cells[0]), "a written cell carries a glyph UV");
    CHECK_MSG(hasGlyph(cells[1]), "and so does the next");
    CHECK_MSG(!hasGlyph(cells[10]), "an untouched cell carries an empty UV rect");
}

TEST(testFrameGridPositionsAreCellCoordinates)
{
    WebTerminal terminal(3, 5, 1);
    CHECK(terminal.buildFrame());
    const Ubiquitty::Rendering::CellInstance* cells = terminal.cellInstances();

    // The vertex shader multiplies gridPosition by the cell size, so these must
    // be cell units and in row-major order — a pixel value here would place the
    // whole grid off-screen.
    CHECK(cells[0].gridPosition.x == 0.0f && cells[0].gridPosition.y == 0.0f);
    CHECK(cells[4].gridPosition.x == 4.0f && cells[4].gridPosition.y == 0.0f);
    CHECK(cells[5].gridPosition.x == 0.0f && cells[5].gridPosition.y == 1.0f);
}

TEST(testFrameExposesTheAtlasTheUVsIndex)
{
    WebTerminal terminal(4, 20, 1);
    const char text[] = "atlas";
    terminal.feed(text);
    CHECK(terminal.buildFrame());

    CHECK_MSG(terminal.atlasPixels() != nullptr, "a faulted glyph gives the page something to upload");
    CHECK(terminal.atlasWidth() > 0);
    CHECK(terminal.atlasHeight() > 0);

    // The rects are atlas pixels of exactly this atlas; one past the extent
    // would sample outside the texture the page uploaded. Bounded by the
    // dimensions rather than by 1, which is the same claim against the atlas
    // that exists rather than against a normalized range.
    const Ubiquitty::Rendering::CellInstance& first = terminal.cellInstances()[0];
    CHECK(first.atlasTopLeft.x >= 0.0f && first.atlasTopLeft.x <= static_cast<float>(terminal.atlasWidth()));
    CHECK(first.atlasBottomRight.y >= 0.0f && first.atlasBottomRight.y <= static_cast<float>(terminal.atlasHeight()));
}

TEST(testGlyphScaleDrivesTheCellGeometryThePageLaysOutWith)
{
    WebTerminal one(4, 10, 1);
    WebTerminal three(4, 10, 3);
    CHECK(one.buildFrame());
    CHECK(three.buildFrame());

    CHECK(one.cellWidth() == 8 && one.cellHeight() == cellHeightAtScale(1));
    CHECK_MSG(three.cellWidth() == 24 && three.cellHeight() == cellHeightAtScale(3),
        "the page sizes its viewport from the same cell the glyphs were rastered at");
}

TEST(testCursorReachesTheOverlayPass)
{
    WebTerminal terminal(4, 20, 1);
    const char bar[] = "\033[5 q"; // DECSCUSR: a bar cursor is an overlay quad
    terminal.feed(bar);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.overlayInstanceCount() > 0, "a non-block cursor is an overlay instance");
    CHECK(terminal.overlayInstances() != nullptr);
}

TEST(testFrameRefusesDegenerateGridAndReportsNoInstances)
{
    const BlockCursorConfiguration blockCursor;
    WebTerminal terminal(4, 20, 1);
    CHECK(terminal.buildFrame());
    CHECK(terminal.cellInstanceCount() > 0);

    // resize() rejects this, so the grid stays valid — the point is that a
    // refused capture must leave a count of zero rather than a stale one.
    terminal.resize(0, 0);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.cellInstanceCount() == 4 * 20 + 1, "the surviving grid still builds, cursor tier and all");
}

TEST(testRebuildAfterResizeReportsTheNewCount)
{
    // One instance per cell, plus the cursor tier: the focused block's cell is
    // re-emitted at the tail of the cell stream (InstanceCounts::cursorTier),
    // so a full grid reports its area and one more. A count equal to the area
    // would mean the buffer was sized to the grid and clipped the tier.
    const BlockCursorConfiguration blockCursor;
    WebTerminal terminal(4, 20, 1);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.cellInstanceCount() == 81, "the grid's cells and the cursor tier's one");

    terminal.resize(10, 30);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.cellInstanceCount() == 301, "the buffer grew and the count followed");

    terminal.resize(2, 5);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.cellInstanceCount() == 11,
        "a shrink reports the smaller count, not the capacity still allocated");
}

// --- Keyboard ---------------------------------------------------------------
//
// The page reports a browser key event's shape; every decision about what bytes
// that becomes is Core's, against this terminal's live modes. These pin the
// cases a JavaScript key table would have got subtly wrong — and would have got
// wrong silently, because a terminal that sends the wrong bytes for Escape still
// looks like a working terminal.

TEST(physicalKeyPositionsReachTheHostIndependentlyOfBrowserText)
{
    AttachedPage page;
    page.programPrints("\033[?81h");
    CHECK(page.terminal.reportsKeyPositions());
    const auto& frame = page.terminal.buildKey(0x0444, 0x0444,
        Ubiquitty::Keys::Keymap::keymapModifierShift | (2u << Ubiquitty::Keys::positionModifierShift),
        0x0444, Ubiquitty::Keys::KeyEventType::Press, Ubiquitty::Keys::VirtualKey::KeyA);
    CHECK(page.programReads(frame) == "\033_:C0102\033\\");
    page.programPrints("\033[?81l");
    CHECK(!page.terminal.reportsKeyPositions());
    const auto& text = page.terminal.buildKey('a', 'a', 0, 'a',
        Ubiquitty::Keys::KeyEventType::Press, Ubiquitty::Keys::VirtualKey::KeyA);
    CHECK(page.programReads(text) == "a");
}

TEST(testControlKeysEncodeAsControlBytes)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const auto wire = [&](std::uint32_t key, std::uint32_t modifiers, std::uint32_t text) {
        const std::vector<std::uint8_t>& frame = terminal.buildKey(key, 0, modifiers, text);
        return page.programReads(frame);
    };

    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0).find('\033') != std::string::npos, "Escape sends ESC");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyEnter, 0, 0).find('\r') != std::string::npos, "Enter sends CR");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyTab, 0, 0).find('\t') != std::string::npos, "Tab sends HT");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyBackspace, 0, 0).find('\177') != std::string::npos, "Backspace sends DEL");
}

// Ctrl-C is the case that matters most: a page that sent the letter 'c' would
// leave the user unable to interrupt anything.
TEST(testControlModifierFoldsToTheControlByte)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const std::vector<std::uint8_t>& frame = terminal.buildKey('c', 'c', Ubiquitty::Keys::Keymap::keymapModifierCtrl, 'c');
    const std::string wire = page.programReads(frame);
    CHECK_MSG(wire.find('\003') != std::string::npos, "Ctrl-C sends ETX, not the letter");

    const std::vector<std::uint8_t>& d = terminal.buildKey('d', 'd', Ubiquitty::Keys::Keymap::keymapModifierCtrl, 'd');
    const std::string wireD = page.programReads(d);
    CHECK_MSG(wireD.find('\004') != std::string::npos, "Ctrl-D sends EOT");
}

// Alt/Meta prefixes with ESC under mode 1036, which defaults on. A page that
// dropped the modifier would break every readline word-motion binding.
TEST(testAlternateSendsEscapePrefix)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const std::vector<std::uint8_t>& frame = terminal.buildKey('f', 'f', Ubiquitty::Keys::Keymap::keymapModifierAlternate, 'f');
    const std::string wire = page.programReads(frame);
    CHECK_MSG(wire.find("\033f") != std::string::npos, "Alt-f sends ESC f");
}

// macOS applies Option to the character before the browser ever reports it:
// Option+F arrives as U+0192 'f with hook', not 'f'. Encoding that code point
// would send ESC followed by a character no readline binding matches, which is
// why Alt-f did nothing in emacs. The key the encoder needs is the layout key,
// which the page recovers from KeyboardEvent.code and passes as keyCode; the
// transformed character is only the associated text.
TEST(testAlternateUsesTheLayoutKeyNotTheTransformedCharacter)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    // keyCode 'f' (from event.code "KeyF"), text U+0192 (what macOS produced).
    const std::vector<std::uint8_t>& frame = terminal.buildKey('f', 'f', Ubiquitty::Keys::Keymap::keymapModifierAlternate, 0x192);
    const std::string wire = page.programReads(frame);
    CHECK_MSG(wire.find("\033f") != std::string::npos, "Alt-f is ESC f even when the OS transformed the character");
    CHECK_MSG(wire.find("\xc6\x92") == std::string::npos, "the transformed character is not what goes on the wire");
}

// A shifted character key must send the character it produced, not the
// unshifted key it sits on. Shift+; is ':' — the layout map answers the
// UNSHIFTED character for a physical key, so a frontend that used it as the key
// code for ordinary typing would send ';' for every colon, and lower case for
// every capital.
TEST(testShiftedCharactersSendWhatWasTyped)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const auto wire = [&](std::uint32_t key, std::uint32_t base, std::uint32_t modifiers, std::uint32_t text) {
        const std::vector<std::uint8_t>& frame = terminal.buildKey(key, base, modifiers, text);
        return page.programReads(frame);
    };

    // Shift+; on a US layout: produced ':', unshifted ';'.
    const std::string colon = wire(':', ';', Ubiquitty::Keys::Keymap::keymapModifierShift, ':');
    CHECK_MSG(colon.find(':') != std::string::npos, "Shift+; sends a colon");
    CHECK_MSG(colon.find(';') == std::string::npos, "and not the unshifted key");

    // Shift+a: produced 'A'.
    const std::string capital = wire('A', 'a', Ubiquitty::Keys::Keymap::keymapModifierShift, 'A');
    CHECK_MSG(capital.find('A') != std::string::npos, "Shift+a sends a capital");

    // Shift+1 on a US layout: '!'.
    const std::string bang = wire('!', '1', Ubiquitty::Keys::Keymap::keymapModifierShift, '!');
    CHECK_MSG(bang.find('!') != std::string::npos, "Shift+1 sends a bang");
    CHECK_MSG(bang.find('1') == std::string::npos, "and not the digit");
}

// DECCKM changes what an arrow key sends, which is exactly the kind of live mode
// a JavaScript table cannot see.
TEST(testArrowsFollowApplicationCursorKeys)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const auto up = [&]() {
        const std::vector<std::uint8_t>& frame = terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyUp, 0, 0, 0);
        return page.programReads(frame);
    };

    CHECK_MSG(up().find("\033[A") != std::string::npos, "normal mode sends CSI A");

    const char decckm[] = "\033[?1h";
    page.programPrints(decckm);
    CHECK_MSG(up().find("\033OA") != std::string::npos, "DECCKM sends SS3 A");

    const char off[] = "\033[?1l";
    page.programPrints(off);
    CHECK_MSG(up().find("\033[A") != std::string::npos, "and back again");
}

TEST(testFunctionAndEditingKeysEncode)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const auto wire = [&](std::uint32_t key) {
        const std::vector<std::uint8_t>& frame = terminal.buildKey(key, 0, 0, 0);
        return page.programReads(frame);
    };
    CHECK_MSG(!wire(Ubiquitty::Keys::Keymap::keymapKeyF1).empty(), "F1 encodes");
    CHECK_MSG(!wire(Ubiquitty::Keys::Keymap::keymapKeyF5).empty(), "F5 encodes");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyHome).find('\033') != std::string::npos, "Home encodes a sequence");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyPageUp).find('\033') != std::string::npos, "PageUp encodes a sequence");
    CHECK_MSG(wire(Ubiquitty::Keys::Keymap::keymapKeyDelete).find('\033') != std::string::npos, "Delete encodes a sequence");
}

// The kitty protocol changes the encoding of nearly everything once a program
// enables it. Reaching it from the browser is the reason the encoder lives in
// Core rather than in the page.
TEST(testKittyKeyboardProtocolChangesTheEncoding)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const auto escape = [&]() {
        const std::vector<std::uint8_t>& frame = terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0, 0);
        return page.programReads(frame);
    };
    const std::string legacy = escape();

    const char push[] = "\033[>1u"; // kitty: disambiguate escape codes
    page.programPrints(push);
    const std::string kitty = escape();

    CHECK_MSG(kitty != legacy, "the kitty flag stack reaches the encoder");
    CHECK_MSG(kitty.find("27u") != std::string::npos, "Escape becomes CSI 27 u");
}

TEST(testAKeyThatProducesNothingBuildsNoFrame)
{
    // A bare modifier press has no key code and no text; sending an empty input
    // frame for it would put the host to work for every shift tap.
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.buildKey(0, 0, Ubiquitty::Keys::Keymap::keymapModifierShift, 0).empty());
}

// --- Keybindings ------------------------------------------------------------
//
// Cmd-key shortcuts are not keystrokes to encode — they are bindings to resolve,
// and Core owns both the table and the chord state machine. The page asks before
// encoding, so a bound key never reaches the shell and an unbound one always
// does.

TEST(testCommandBindingResolvesInsteadOfEncoding)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.addKeybinding("cmd+k", "clear_scrollback"));

    const int action = terminal.resolveBinding('k', 'k', Ubiquitty::Input::bindModSuper);
    CHECK_MSG(action == static_cast<int>(Ubiquitty::Input::ActionKind::ClearScrollback),
        "cmd+k resolves to the action, not to bytes");

    // The same key without the modifier is ordinary input.
    CHECK_MSG(terminal.resolveBinding('k', 'k', 0) == 0, "bare k is not bound");
}

// Clearing scrollback drops history and leaves the grid, which is what makes it
// look like nothing happened. Both halves are asserted because "nothing visible
// changed" is indistinguishable from "the action did not run".
TEST(testClearScrollbackDropsHistoryAndKeepsTheScreen)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 20; ++i) {
        const char line[] = "history\r\n";
        terminal.feed(line);
    }
    const char visible[] = "onscreen";
    terminal.feed(visible);
    CHECK(terminal.buildFrame());

    CHECK_MSG(terminal.scrollbackRows() > 0, "there is history to drop");

    // The visible row's glyphs, before the clear.
    const auto glyphCount = [&]() {
        int n = 0;
        const Ubiquitty::Rendering::CellInstance* cells = terminal.cellInstances();
        for (int i = 0; i < terminal.cellInstanceCount(); ++i) {
            if (cells[i].atlasBottomRight.x > cells[i].atlasTopLeft.x)
                ++n;
        }
        return n;
    };
    const int before = glyphCount();
    CHECK_MSG(before > 0, "something is on screen");

    terminal.clearScrollback();
    CHECK(terminal.buildFrame());

    CHECK_MSG(terminal.scrollbackRows() == 0, "the history is gone");
    CHECK_MSG(glyphCount() == before, "the visible grid is untouched — history is not the screen");

    // The clear-buffer action goes further: screen and history, plus the frame
    // the process needs so its prompt model agrees with what is on screen.
    (void)terminal.buildClearBuffer();
    CHECK(terminal.buildFrame());
    CHECK_MSG(glyphCount() < before, "clearing the buffer empties the screen too");
    // The redraw is input to the process, which an attached page's host
    // writes it.
    AttachedPage page;
    page.programPrints("$ ");
    page.host.receive(page.terminal.buildClearBuffer());
    const auto calls = page.host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    const auto request = Ubiquitty::Protocol::Control::decodeRequest(calls.front().text, {});
    CHECK(request.method == "pane.clear" && request.params.stringOr("command") == "buffer");
    CHECK(page.host.typed().events().empty());
}

TEST(clearToPreviousMarkRoutesToTheHostWithoutEditingItsMirror)
{
    AttachedPage page;
    page.programPrints("\x1b[?1049hprogram chrome");
    const int rows = page.terminal.scrollbackRows();
    page.terminal.clearToPreviousMark();
    CHECK(page.terminal.scrollbackRows() == rows);
    page.host.receive(page.terminal.takePendingHostFrame(0));
    const auto calls = page.host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    const auto request = Ubiquitty::Protocol::Control::decodeRequest(calls.front().text, {});
    CHECK(request.method == "pane.clear");
    CHECK(request.params.stringOr("command") == "previous-mark");
    CHECK(page.host.typed().events().empty());
}

TEST(testUnboundCommandKeysDoNotMatch)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.addKeybinding("cmd+k", "clear_scrollback"));
    CHECK_MSG(terminal.resolveBinding('l', 'l', Ubiquitty::Input::bindModSuper) == 0,
        "cmd+l is unbound, so the page leaves it to the browser");
}

TEST(testSendBytesBindingCarriesItsPayload)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.addKeybinding("cmd+shift+a", "send:\\x01"));

    const int action = terminal.resolveBinding('a', 'a', Ubiquitty::Input::bindModSuper | Ubiquitty::Input::bindModShift);
    CHECK(action == static_cast<int>(Ubiquitty::Input::ActionKind::SendBytes));
    CHECK_MSG(terminal.bindingBytes().size() == 1 && terminal.bindingBytes()[0] == 0x01,
        "the decoded payload is what goes to the PTY");
}

// A leader key must be swallowed rather than encoded: sending it would put a
// stray character in the shell before the chord completes.
TEST(testChordPrefixIsSwallowedNotEncoded)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.addKeybinding("ctrl+a ctrl+x", "copy"));

    CHECK_MSG(terminal.resolveBinding('a', 'a', Ubiquitty::Input::bindModCtrl) == -1,
        "the leader is pending, so the page swallows it");
    CHECK_MSG(terminal.resolveBinding('x', 'x', Ubiquitty::Input::bindModCtrl)
            == static_cast<int>(Ubiquitty::Input::ActionKind::Copy),
        "the second key completes the chord");
}

// Bindings are written in ASCII, so a non-Latin layout has to match on the
// character the same physical key carries under an ASCII layout — otherwise
// cmd+k is unreachable for anyone typing Cyrillic.
TEST(testNonLatinLayoutMatchesThroughTheAsciiFallback)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.addKeybinding("cmd+k", "clear_scrollback"));

    // Cyrillic small el (U+043B) is what the layout produces; 'k' is the key's
    // ASCII-layout character.
    const int action = terminal.resolveBinding(0x43B, 'k', Ubiquitty::Input::bindModSuper);
    CHECK_MSG(action == static_cast<int>(Ubiquitty::Input::ActionKind::ClearScrollback),
        "a Cyrillic layout still reaches cmd+k");
}

TEST(testNoBindingsMeansEveryKeyIsInput)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.resolveBinding('k', 'k', Ubiquitty::Input::bindModSuper) == 0,
        "an empty table resolves nothing");
}

// --- The font seam ----------------------------------------------------------
//
// Off-target there is no host text engine, so every glyph reaches the fallback.
// That is the path a browser without a configured font also takes, and it is the
// one this build can exercise: a terminal must render with no font installed.

TEST(testRendersWithNoHostFont)
{
    WebTerminal terminal(6, 20, 1);
    const char text[] = "fallback";
    terminal.feed(text);
    CHECK(terminal.buildFrame());

    // Glyphs still reach the atlas, so the UVs are real rather than the blank
    // sentinel — a terminal that silently drew nothing would also "build".
    const Ubiquitty::Rendering::CellInstance* cells = terminal.cellInstances();
    CHECK_MSG(cells[0].atlasBottomRight.x > cells[0].atlasTopLeft.x,
        "the fallback face rasterizes when no host font is installed");
    CHECK_MSG(terminal.atlasPixels() != nullptr, "and the atlas has pixels to upload");
}

// The cell geometry must come from whichever face actually draws, because the
// decorations are positioned against it. Taking it from the fallback while a
// host face draws would put every underline at the wrong height.
TEST(testCellGeometryComesFromTheDrawingFace)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.cellWidth() == 8 && terminal.cellHeight() == cellHeightAtScale(1),
        "the fallback's own cell, since it is what draws here");

    WebTerminal scaled(6, 20, 2);
    CHECK(scaled.buildFrame());
    CHECK_MSG(scaled.cellWidth() == 16 && scaled.cellHeight() == cellHeightAtScale(2),
        "and it scales with the requested raster size");
}

// --- OSC 52 -----------------------------------------------------------------
//
// Both directions are asynchronous in a browser and synchronous in Core, so the
// staging is where this can break. A write that is never pulled never reaches
// the clipboard; a read that is never answered leaves the program waiting.

TEST(testProgramWritingTheClipboardStagesForThePage)
{
    WebTerminal terminal(6, 20, 1);
    CHECK_MSG(terminal.pendingClipboardWrite()[0] == '\0', "nothing staged before a program asks");

    // OSC 52 ; c ; base64("hi") — set the system clipboard.
    const char write[] = "\033]52;c;aGk=\033\\";
    terminal.feed(write);

    CHECK_MSG(std::strcmp(terminal.pendingClipboardWrite(), "hi") == 0, "the decoded text is staged");

    // Staging persists until taken: a page that has not written it yet must not
    // lose it to the next frame.
    CHECK(std::strcmp(terminal.pendingClipboardWrite(), "hi") == 0);
    terminal.takeClipboardWrite();
    CHECK_MSG(terminal.pendingClipboardWrite()[0] == '\0', "and clears once taken");
}

TEST(testProgramReadingTheClipboardWaitsForThePage)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(!terminal.wantsClipboardRead());

    // OSC 52 ; c ; ? — ask what is on the clipboard.
    const char query[] = "\033]52;c;?\033\\";
    terminal.feed(query);

    CHECK_MSG(terminal.wantsClipboardRead(), "the page is asked, because a browser read is a promise");

    terminal.provideClipboardRead("pasted");
    CHECK_MSG(!terminal.wantsClipboardRead(), "and the request is retired once answered");
}

// The page is told when Core's policy says to ask, and the default policy says so.
//
// Core's clipboard read policy defaults to Prompt. It carries that to a frontend
// as ClipboardReadConfirmation::Required and expects the frontend to ask before
// reading. The Web client took the argument and dropped it, so Required and
// NotRequired produced the same pending read and the page read the clipboard
// either way — a policy of "ask the user" became "read it", with neither the user
// nor Core learning the question was never put.
//
// The browser's own permission prompt is not this gate: it is asked once per
// origin and remembered, so after the first grant every later read by any program
// is silent. Core's policy is per read.
//
// Fails-without-it: clipboardReadNeedsConfirmation is false under the Prompt
// policy, so the page reads without asking.
TEST(testAPromptPolicyReachesThePageAsAConfirmation)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(!terminal.wantsClipboardRead());
    CHECK(!terminal.clipboardReadNeedsConfirmation());

    const char query[] = "\033]52;c;?\033\\";
    terminal.feed(query);

    CHECK(terminal.wantsClipboardRead());
    CHECK_MSG(terminal.clipboardReadNeedsConfirmation(),
        "the default read policy is Prompt, so the page must ask first");

    // Answering retires both: a stale confirmation flag would make the next
    // read — possibly an allowed one — put a dialog in front of the user.
    terminal.provideClipboardRead("pasted");
    CHECK(!terminal.wantsClipboardRead());
    CHECK(!terminal.clipboardReadNeedsConfirmation());
}

// An Allow policy reaches the page as a read that needs no dialog. Without this
// arm the case above would pass against a frontend that asked for confirmation
// unconditionally, which is a different defect wearing the same green.
TEST(testAnAllowPolicyNeedsNoConfirmation)
{
    // Delivered before construction: the policy is seeded onto the Terminal
    // when it is built, and the pinned set is restored so the value reaches
    // no later case.
    configureDocument("[security]\nclipboard_read = \"allow\"\n");
    WebTerminal terminal(6, 20, 1);
    configureDocument("");

    const char query[] = "\033]52;c;?\033\\";
    terminal.feed(query);

    CHECK_MSG(terminal.wantsClipboardRead(), "an allowed read still routes through the page");
    CHECK_MSG(!terminal.clipboardReadNeedsConfirmation(), "but it does not ask");
    terminal.provideClipboardRead("pasted");
}

// A page that declines, or a browser that refuses permission, must still answer.
// Silence leaves the program waiting for a reply that is never coming.
TEST(testDecliningAClipboardReadStillAnswers)
{
    WebTerminal terminal(6, 20, 1);
    const char query[] = "\033]52;c;?\033\\";
    terminal.feed(query);
    CHECK(terminal.wantsClipboardRead());

    terminal.provideClipboardRead(nullptr);
    CHECK_MSG(!terminal.wantsClipboardRead(), "a refusal is an answer");
}

// --- OSC 5522, typed --------------------------------------------------------
//
// The typed set crosses the same staging seam the text does: a program's
// typed write waits whole for the page's pump, and a read's typed answer
// accumulates from the page before the text completes the query.

TEST(testProgramWritingTypedItemsStagesTheSetForThePage)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(terminal.pendingClipboardItemCount() == 0);

    // A 5522 session: "hi" as text, "PNG" (b64 "UE5H") as image/png.
    terminal.feed("\033]5522;type=write\033\\");
    terminal.feed("\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\033\\");
    terminal.feed("\033]5522;type=wdata:mime=aW1hZ2UvcG5n;UE5H\033\\");
    terminal.feed("\033]5522;type=wdata\033\\");

    CHECK_MSG(terminal.pendingClipboardItemCount() == 2, "both payloads wait for the pump");
    CHECK(std::strcmp(terminal.pendingClipboardItemMime(0), "text/plain") == 0);
    CHECK(terminal.pendingClipboardItemLength(0) == 2
        && std::strncmp(terminal.pendingClipboardItemBytes(0), "hi", 2) == 0);
    CHECK(std::strcmp(terminal.pendingClipboardItemMime(1), "image/png") == 0);
    CHECK(terminal.pendingClipboardItemLength(1) == 3
        && std::strncmp(terminal.pendingClipboardItemBytes(1), "PNG", 3) == 0);
    // Outside the count: the answers a pump indexing past the end gets.
    CHECK(terminal.pendingClipboardItemMime(2)[0] == '\0');
    CHECK(terminal.pendingClipboardItemLength(-1) == 0);
    CHECK(terminal.pendingClipboardItemBytes(9)[0] == '\0');

    // The text rides the plain staging too — the fallback for a browser
    // that refuses the typed write.
    CHECK(std::strcmp(terminal.pendingClipboardWrite(), "hi") == 0);

    terminal.takeClipboardItems();
    CHECK_MSG(terminal.pendingClipboardItemCount() == 0, "and clears once taken");
}

TEST(testTypedItemsForThePrimaryBufferNeverLeaveThePage)
{
    WebTerminal terminal(6, 20, 1);
    // loc=primary: the browser has no primary selection, and inventing one
    // would clobber the clipboard through a selector nobody addressed.
    terminal.feed("\033]5522;type=write:loc=primary\033\\");
    terminal.feed("\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\033\\");
    terminal.feed("\033]5522;type=wdata\033\\");
    CHECK(terminal.pendingClipboardItemCount() == 0);
}

TEST(testEmptyClipboardClearIsNotConfusedWithNoPendingWrite)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(!terminal.hasPendingClipboardWrite());
    terminal.feed("\033]52;c;\033\\");
    CHECK(terminal.hasPendingClipboardWrite());
    CHECK(terminal.pendingClipboardWrite()[0] == '\0');
    terminal.takeClipboardWrite();
    CHECK(!terminal.hasPendingClipboardWrite());

    terminal.feed("\033]5522;type=write\033\\");
    terminal.feed("\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\033\\");
    terminal.feed("\033]5522;type=wdata\033\\");
    CHECK(terminal.pendingClipboardItemCount() == 1);
    terminal.feed("\033]52;c;\033\\");
    CHECK(terminal.pendingClipboardItemCount() == 0);
    CHECK(terminal.hasPendingClipboardWrite());
    CHECK(terminal.pendingClipboardWrite()[0] == '\0');
}

TEST(testTypedClipboardWithoutTextDoesNotReuseAnOlderFallback)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("\033]52;c;aGk=\033\\");
    CHECK(terminal.hasPendingClipboardWrite());
    terminal.feed("\033]5522;type=write\033\\");
    terminal.feed("\033]5522;type=wdata:mime=aW1hZ2UvcG5n;UE5H\033\\");
    terminal.feed("\033]5522;type=wdata\033\\");
    CHECK(terminal.pendingClipboardItemCount() == 1);
    CHECK(!terminal.hasPendingClipboardWrite());
    CHECK(terminal.pendingClipboardWrite()[0] == '\0');
}

TEST(testATypedReadAnswerCrossesWholeAndRetiresTheQuery)
{
    // Delivered before construction: the policy is seeded onto the Terminal
    // when it is built, and the pinned set is restored so the value reaches
    // no later case.
    configureDocument("[security]\nclipboard_read = \"allow\"\n");
    WebTerminal terminal(6, 20, 1);
    configureDocument("");

    // b64("text/plain image/png") — a typed 5522 read defers to the page
    // like the text read does.
    terminal.feed("\033]5522;type=read;dGV4dC9wbGFpbiBpbWFnZS9wbmc=\033\\");
    CHECK_MSG(terminal.wantsClipboardRead(), "a typed read routes through the page");

    // The page answers with both halves: the payloads, then the text that
    // completes the query — the typed staging serves Core's type and item
    // reads inside this call.
    terminal.beginClipboardReadItems();
    terminal.addClipboardReadItem("text/plain", { "hi", 2 });
    terminal.addClipboardReadItem("image/png", { "PNG", 3 });
    terminal.provideClipboardRead("hi");
    CHECK_MSG(!terminal.wantsClipboardRead(), "answered and retired");

    // A later answer with no items stages the empty set: nothing stale from
    // this read can answer the next one.
    terminal.feed("\033]5522;type=read;dGV4dC9wbGFpbg==\033\\");
    CHECK(terminal.wantsClipboardRead());
    terminal.beginClipboardReadItems();
    terminal.provideClipboardRead("later");
    CHECK(!terminal.wantsClipboardRead());
}

// Only the system clipboard crosses into the page. X11's primary and the cut
// buffers have no browser equivalent, and treating them as the clipboard would
// let a program clobber the user's real one through a selector they did not
// think they were addressing.
TEST(testNonSystemSelectorsDoNotReachThePage)
{
    WebTerminal terminal(6, 20, 1);
    const char primary[] = "\033]52;p;aGk=\033\\"; // p = primary selection
    terminal.feed(primary);
    CHECK_MSG(terminal.pendingClipboardWrite()[0] == '\0', "a primary-selection write is not staged");

    const char cut[] = "\033]52;0;aGk=\033\\"; // cut buffer 0
    terminal.feed(cut);
    CHECK_MSG(terminal.pendingClipboardWrite()[0] == '\0', "nor a cut-buffer write");
}

// --- Attached mode ----------------------------------------------------------

TEST(testHelloCarriesGeometryAndToken)
{
    WebTerminal terminal(30, 100, 1);
    const std::vector<std::uint8_t>& hello = terminal.buildHello("open-sesame");
    CHECK_MSG(!hello.empty(), "HELLO is built");

    const std::string wire(reinterpret_cast<const char*>(hello.data()), hello.size());
    CHECK_MSG(wire.find("open-sesame") != std::string::npos, "the token reaches the wire");
    // A fresh page has no session to resume, and the daemon reads sessionID 0 as
    // "make me one" — which is also what makes its scope check demand NewSession.
    CHECK_MSG(!terminal.isAttached(), "not attached until the host acks");
    CHECK_EQ(static_cast<int>(terminal.sessionID()), 0);
}

// A press and release with no motion between them selects nothing. The policy is
// Core's, so this holds wherever it is asked.
TEST(testABareClickLeavesNoHighlight)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("some words on a line");

    press(terminal, 0, 5);
    release(terminal, 2, 6);
    CHECK_MSG(!terminal.hasSelection(), "a press and release with no motion selects nothing");
}

// The other half of the same rule: the single click's selection is deferred to
// the first motion rather than abandoned, so a drag still selects from where the
// press landed.
TEST(testADragOpensTheSelectionTheClickDeferred)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("some words on a line");

    press(terminal, 0, 0);
    CHECK_MSG(!terminal.hasSelection(), "nothing yet on the press");
    drag(terminal, 0, 8);
    CHECK_MSG(terminal.hasSelection(), "the drag opens it");
    release(terminal, 2, 6);

    const std::string text = terminal.selectionText();
    CHECK_MSG(text.find("some") != std::string::npos, "it starts where the press landed");
}

// Double and triple click do commit immediately — the deferral is a property of
// the single click, not of pressing.
TEST(testDoubleClickTakesAWordAndTripleTakesTheLine)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("alpha beta gamma");

    press(terminal, 0, 7, 2);
    CHECK_MSG(terminal.hasSelection(), "a double click selects without any drag");
    const std::string word = terminal.selectionText();
    CHECK_MSG(word.find("beta") != std::string::npos, "the word under the click");
    CHECK_MSG(word.find("alpha") == std::string::npos, "and not its neighbour");
    release(terminal, 2, 6);

    WebTerminal line(24, 80, 1);
    line.feed("alpha beta gamma");
    press(line, 0, 7, 3);
    CHECK_MSG(line.hasSelection(), "a triple click selects without any drag");
    const std::string whole = line.selectionText();
    CHECK_MSG(whole.find("alpha") != std::string::npos && whole.find("gamma") != std::string::npos,
        "the whole line, both ends");
    release(line, 0, 7);
}

// Select All reaches into the scrollback. The frontends each had their own
// answer to that until it moved into Core — this one and macOS covered history,
// Linux stopped at the top of the screen.
TEST(testSelectAllCoversTheScrollbackNotJustTheScreen)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 12; ++i)
        terminal.feed("line\r\n");
    CHECK_MSG(terminal.scrollbackRows() > 0, "there is history to include");

    terminal.selectAll();
    CHECK(terminal.hasSelection());
    const std::string text = terminal.selectionText();
    // More rows of text than fit on a four-row screen means history came too.
    int newlines = 0;
    for (char c : text) {
        if (c == '\n')
            ++newlines;
    }
    CHECK_MSG(newlines >= 4, "the selection runs past a screenful");
}

// Typing over a highlight drops it, because the highlight would be standing on
// content the user has started editing. The return value is what a frontend
// repaints on, so it must be false when there was nothing to drop.
TEST(testSendingInputDropsTheSelection)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("alpha beta");
    CHECK_MSG(!terminal.clearSelectionForUserInput(), "nothing to drop, nothing to repaint");

    press(terminal, 0, 0, 2);
    CHECK(terminal.hasSelection());
    CHECK_MSG(terminal.clearSelectionForUserInput(), "the drop is worth a repaint");
    CHECK_MSG(!terminal.hasSelection(), "and the highlight is gone");
}

// select_all is a bindable action like copy and paste, so a page states a key
// and not a behaviour.
TEST(testSelectAllIsABindableAction)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.addKeybinding("cmd+a", "select_all"), "the action name resolves");
    CHECK_MSG(terminal.addKeybinding("cmd+c", "copy"), "and copy, now there is a selection to copy");
}

// The CPU composite takes its inputs from the same capture as the instance
// path, so a capture with no selection to carry leaves ?gpu=0 highlighting
// nothing while the GPU path highlights correctly — one frontend, two
// renderers, two answers.
TEST(testTheCPUCompositeDrawsTheSelectionToo)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("selectable text here");

    const std::vector<std::uint8_t> plain = terminal.render();
    CHECK(!plain.empty());

    press(terminal, 0, 0);
    drag(terminal, 0, 15);
    release(terminal, 2, 6);
    CHECK(terminal.hasSelection());

    const std::vector<std::uint8_t>& highlighted = terminal.render();
    CHECK_EQ(highlighted.size(), plain.size());
    CHECK_MSG(std::memcmp(plain.data(), highlighted.data(), plain.size()) != 0,
        "a selection changes the pixels the CPU path blits");
}

// Scrolling by a line, a page and to an end — the actions every other frontend
// binds, reached here through the bridge. The clamp is Core's, so a request past
// either end lands on a row that exists rather than off the buffer.
TEST(testScrollingByLinePageAndToTheEnds)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 30; ++i)
        terminal.feed("line\r\n");
    const int history = terminal.scrollbackRows();
    CHECK(history > 8);

    terminal.scrollBy(1);
    CHECK_EQ(terminal.viewOffset(), 1);
    terminal.scrollBy(-1);
    CHECK_EQ(terminal.viewOffset(), 0);

    // A page is the visible row count, as on the other frontends.
    terminal.scrollBy(terminal.rows());
    CHECK_EQ(terminal.viewOffset(), 4);

    terminal.scrollToTop();
    CHECK_MSG(terminal.viewOffset() == history, "the top is the oldest retained row");
    terminal.scrollToBottom();
    CHECK_EQ(terminal.viewOffset(), 0);
}

// Past either end is a request a frontend makes constantly — a page scroll near
// the top, a wheel flick at the bottom — and it must land on a row that exists.
TEST(testScrollingPastEitherEndClamps)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 10; ++i)
        terminal.feed("line\r\n");
    const int history = terminal.scrollbackRows();

    terminal.scrollBy(10000);
    CHECK_MSG(terminal.viewOffset() == history, "clamped to the oldest row");
    terminal.scrollBy(-10000);
    CHECK_MSG(terminal.viewOffset() == 0, "clamped to the live grid");

    // The Core clamp answers the same way without a terminal in front of it.
    CHECK_EQ(Ubiquitty::Screen::clampViewOffset(-5, 100), 0);
    CHECK_EQ(Ubiquitty::Screen::clampViewOffset(500, 100), 100);
    CHECK_EQ(Ubiquitty::Screen::clampViewOffset(7, 100), 7);
    CHECK_MSG(Ubiquitty::Screen::clampViewOffset(3, 0) == 0, "no history means no offset");
}

// The actions this frontend can honour are bindable by name, so a page states a
// key and Core states what the key means. What toggle_fullscreen does is the
// page's — a browser has no other way to ask — but which chord reaches it, and
// whether the name resolves at all, is checkable here.
TEST(testTheActionsThisFrontendHonoursAllResolve)
{
    WebTerminal terminal(24, 80, 1);
    const char* const bound[] = {
        "copy",
        "paste",
        "select_all",
        "clear",
        "clear_scrollback",
        "scroll_line_up",
        "scroll_line_down",
        "scroll_page_up",
        "scroll_page_down",
        "scroll_to_top",
        "scroll_to_bottom",
        "toggle_fullscreen",
    };
    for (const char* action : bound)
        CHECK_MSG(terminal.addKeybinding("ctrl+shift+f13", action), "the action name resolves");

    // A name Core does not define must be refused rather than silently bound to
    // nothing, or a typo in a page's table is a key that does anything at all.
    CHECK_MSG(!terminal.addKeybinding("ctrl+shift+f14", "scroll_line_sideways"),
        "an unknown action is refused");
}

// Zooming rebuilds the rasterizers and the renderer, because each caches metrics
// taken at construction. The property that matters is that the CELL moves —
// a size change the renderer did not see is a renderer measuring cells at one
// size while a rasterizer draws them at another.
TEST(testZoomingChangesTheCell)
{
    WebTerminal terminal(24, 80, 1);
    terminal.render();
    const int width = terminal.cellWidth();
    const int height = terminal.cellHeight();
    CHECK(width > 0 && height > 0);

    // A full Unifont scale, not one step. Without a canvas the face rasterizer
    // reports unavailable and the bitmap fallback draws, and its scale is a
    // whole multiple of the 8x16 cell — so under the fallback a zoom moves the
    // cell only when it crosses a multiple. A browser with the face loaded
    // honours every step; a headless test cannot see that path.
    terminal.stepFontSize(16);
    CHECK_MSG(terminal.fontSize() > 16.0, "the size went up");
    terminal.render();
    CHECK_MSG(terminal.cellHeight() > height, "a bigger font is a taller cell");

    terminal.resetFontSize();
    terminal.render();
    CHECK_EQ(terminal.cellWidth(), width);
    CHECK_EQ(terminal.cellHeight(), height);
}

// The bounds are Core's, shared with every frontend that zooms, so a request
// past either end lands on a size that exists rather than being refused.
TEST(testZoomingClampsToTheSchemaRange)
{
    WebTerminal terminal(24, 80, 1);
    const auto& range = Ubiquitty::Preferences::Zoom::fontZoomRange();

    terminal.setFontSize(range.maximum + 1000.0);
    CHECK_MSG(terminal.fontSize() == range.maximum, "clamped to the top of the range");

    terminal.setFontSize(range.minimum - 1000.0);
    CHECK_MSG(terminal.fontSize() == range.minimum, "clamped to the bottom");

    // And a step from the boundary stays inside it rather than walking out.
    terminal.stepFontSize(-5);
    CHECK_MSG(terminal.fontSize() == range.minimum, "a step past the end holds");

    // The grid is unchanged by any of it: zoom moves the cell, not the model.
    CHECK_EQ(terminal.rows(), 24);
    CHECK_EQ(terminal.columns(), 80);
}

// OSC 0/2 sets the title, and which Terminal hears it depends on whether this
// client is attached: a program's escape reaches the HOST's Terminal and comes
// back in PaneFacts, so a frontend reading only its local field shows
// nothing while the shell renames itself every prompt.
TEST(backgroundBellAndProgramStatusReachTheBrowserTitle)
{
    const std::string saved = Ubiquitty::Preferences::liveDocument();
    configureDocument("[title]\ntab_program_status = true\n");
    WebTerminal terminal(24, 80, 1);
    terminal.feed("\033]2;Build\007\033]21337;indicator=#5f87ff;status=Waiting\007");
    CHECK(std::string(terminal.title()).find("Waiting") != std::string::npos);
    configureDocument("[title]\ntab_program_status = false\n");
    CHECK(std::string(terminal.title()).find("Waiting") == std::string::npos);
    configureDocument("[title]\ntab_program_status = true\n");
    terminal.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    terminal.feed("\007");
    CHECK(std::string(terminal.title()).starts_with("🔔 "));
    terminal.feed("\033]2;Finished\007");
    CHECK(std::string(terminal.title()).starts_with("🔔 "));
    terminal.setFocus(Ubiquitty::Modes::FocusState::Focused);
    CHECK(!std::string(terminal.title()).starts_with("🔔 "));
    terminal.noteBell();
    CHECK(!std::string(terminal.title()).starts_with("🔔 "));
    terminal.feed("\033]21337;indicator=;status=\007");
    CHECK_STR_EQ(terminal.title(), "Finished");
    WebTerminal attached(24, 80, 1);
    attached.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    PageHost host(3);
    REQUIRE(feedWire(attached, host.answer(attached.buildHello("t", 3))));
    REQUIRE(feedWire(attached, host.exchange(attached)));
    const auto pump = [&] {
        // The page's production timer sends the screen ACK that releases
        // a visible effect. Service its stated deadline, not a fabricated ACK.
        const int delay = attached.screenTickDelayMilliseconds();
        if (delay > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(delay));
        CHECK(feedWire(attached, host.exchange(attached)));
    };
    REQUIRE(host.source().appendEffect(Ubiquitty::Protocol::Sync::BellEffect {}, { 1, pageDaemonInstanceID }));
    for (int round = 0; round < 4 && host.source().effects().retiredThrough() < 1; ++round)
        pump();
    CHECK_EQ(host.source().effects().retiredThrough(), 1u);
    CHECK(!std::string(attached.title()).starts_with("🔔 "));
    REQUIRE(host.source().appendEffect(Ubiquitty::Protocol::Sync::BellEffect {}, host.connection().clientInstance()));
    for (int round = 0; round < 4 && host.source().effects().retiredThrough() < 2; ++round)
        pump();
    CHECK_EQ(host.source().effects().retiredThrough(), 2u);
    CHECK(std::string(attached.title()).starts_with("🔔 "));
    attached.setFocus(Ubiquitty::Modes::FocusState::Focused);
    CHECK(!std::string(attached.title()).starts_with("🔔 "));
    configureDocument(saved);
}

TEST(retiredFileDataCannotEnterAnAttachedWebTerminal)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(3);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello("t", 3))));
    REQUIRE(feedWire(terminal, host.exchange(terminal)));
    // The obsolete outer FileData header is a negative byte fixture, not an API.
    const std::vector<std::uint8_t> wire { 0x9A, 0, 0, 0, 0 };
    CHECK(!feedWire(terminal, wire));
    CHECK(!feedWire(terminal, wire)); // The page closes its socket on this latched fault.
}

TEST(testTheTitleComesFromWhicheverTerminalHeardIt)
{
    WebTerminal detached(24, 80, 1);
    CHECK_STR_EQ(detached.title(), "");

    const char osc[] = "\033]2;a local title\007";
    detached.feed(std::string_view(osc, static_cast<std::size_t>(sizeof(osc) - 1)));
    CHECK_STR_EQ(detached.title(), "a local title");

    // Attached, the host's title wins — the local field is not where a program's
    // OSC landed.
    WebTerminal attached(24, 80, 1);
    attached.feed(std::string_view(osc, static_cast<std::size_t>(sizeof(osc) - 1)));

    PageHost host(3);
    REQUIRE(feedWire(attached, host.answer(attached.buildHello("t", 3))));
    REQUIRE(feedWire(attached, host.exchange(attached)));
    Ubiquitty::Protocol::Sync::PaneFacts facts;
    facts.programTitle = "the host's title";
    host.setFacts(facts);
    REQUIRE(feedWire(attached, host.exchange(attached)));
    CHECK_STR_EQ(attached.title(), "the host's title");
}

TEST(testPaneFactsReachThePageWithoutAnotherScreenUpdate)
{
    AttachedPage page;
    const std::uint64_t checkpoints = page.host.connection().counters().checkpointsSent;
    Ubiquitty::Protocol::Sync::PaneFacts facts;
    facts.programTitle = "recorded title";
    facts.currentDirectory = "/srv/project";
    page.host.setFacts(facts);
    CHECK(feedWire(page.terminal, page.host.exchange(page.terminal)));
    CHECK_STR_EQ(page.terminal.title(), "recorded title");
    CHECK_STR_EQ(page.terminal.currentDirectory(), "/srv/project");
    CHECK_EQ(page.host.connection().counters().checkpointsSent, checkpoints);

    page.host.setFacts({});
    CHECK(feedWire(page.terminal, page.host.exchange(page.terminal)));
    CHECK_STR_EQ(page.terminal.title(), "");
    CHECK_STR_EQ(page.terminal.currentDirectory(), "");
}

TEST(aWebNonOwnerFitsTheWholePictureWithoutChangingTheHostGrid)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    configureDocument("[remote]\nnon_owner_presentation = \"fit\"\n");
    WebTerminal page(10, 40, 1);
    PageHost host(7, 10, 40, Sync::Role::Viewer);
    Ubiquitty::processBytes(&host.terminal(), "\033[1;31mcell\033[0m\033Pq#1;2;100;0;0#1~\033\\\033[4;8H");
    host.source().geometry().noteTyping({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, 1);
    host.source().geometry().noteViewport({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, { 10, 40 }, 2);
    REQUIRE(host.source().geometry().status().owner == Sync::ID128(99, pageDaemonInstanceID));
    host.setFacts({});
    REQUIRE(feedWire(page, host.answer(page.buildHello("t", 7))));
    REQUIRE(feedWire(page, host.exchange(page)));
    const std::vector<std::uint8_t> natural = page.render();
    REQUIRE(!natural.empty());
    const int width = page.imageWidth();
    const int height = page.imageHeight();
    page.setPresentationViewport(width * 0.5f, height * 0.5f);
    const auto& fitted = page.render();
    CHECK_EQ(page.presentation().scale, 0.5f);
    CHECK_EQ(page.presentation().origin.x, 0);
    CHECK_EQ(page.presentation().origin.y, 0);
    CHECK(fitted == natural);
    CHECK_EQ(page.imageWidth(), width);
    CHECK_EQ(page.imageHeight(), height);
    CHECK_EQ(page.columns(), 40);
    CHECK_EQ(page.rows(), 10);
    CHECK_EQ(host.terminal().columns, 40);
    CHECK_EQ(host.terminal().rows, 10);
    const Ubiquitty::FloatPoint picture { page.cellWidth() * 7.5f, page.cellHeight() * 3.5f };
    const auto hit = page.presentation().viewportPoint(picture);
    CHECK_EQ(page.pointerCell(hit.x, hit.y).column, 7);
    CHECK_EQ(page.pointerCell(hit.x, hit.y).row, 3);
    CHECK_EQ(page.pointerPixel(hit.x, hit.y).x, static_cast<int>(picture.x) + 1);
    CHECK_EQ(page.pointerPixel(hit.x, hit.y).y, static_cast<int>(picture.y) + 1);
    CHECK_EQ(page.cursorCellRect().origin.x, 7 * page.cellWidth() * 0.5f);
    CHECK_EQ(page.cursorCellRect().origin.y, 3 * page.cellHeight() * 0.5f);
    configureDocument("");
}

TEST(aWebNonOwnerPansToItsLiveCursorAndHoldsWhileTheCursorIsHidden)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    configureDocument("[remote]\nnon_owner_presentation = \"pan\"\n");
    WebTerminal page(20, 80, 1);
    PageHost host(7, 20, 80, Sync::Role::Viewer);
    host.source().geometry().noteTyping({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, 1);
    host.source().geometry().noteViewport({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, { 20, 80 }, 2);
    REQUIRE(host.source().geometry().status().owner == Sync::ID128(99, pageDaemonInstanceID));
    host.setFacts({});
    Ubiquitty::processBytes(&host.terminal(), "\033[18;70H");
    REQUIRE(feedWire(page, host.answer(page.buildHello("t", 7))));
    REQUIRE(feedWire(page, host.exchange(page)));
    const int cw = page.cellWidth();
    const int ch = page.cellHeight();
    page.setPresentationViewport(20 * cw, 6 * ch);
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().scale, 1);
    CHECK_EQ(page.presentation().origin.x, -50 * cw);
    CHECK_EQ(page.presentation().origin.y, -12 * ch);
    CHECK_EQ(page.pointerCell(19.5f * cw, 5.5f * ch).column, 69);
    CHECK_EQ(page.pointerCell(19.5f * cw, 5.5f * ch).row, 17);
    const auto pan = page.presentation();
    Ubiquitty::processBytes(&host.terminal(), "\033[?25l\033[H");
    REQUIRE(feedWire(page, host.publish(page)));
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().origin.x, pan.origin.x);
    CHECK_EQ(page.presentation().origin.y, pan.origin.y);
    Ubiquitty::processBytes(&host.terminal(), "\033[?25h");
    REQUIRE(feedWire(page, host.publish(page)));
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().origin.x, 0);
    CHECK_EQ(page.presentation().origin.y, 0);
    configureDocument("");
}

TEST(aWebPictureNeverReusesAnotherConnectionsGeometryOwnership)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    configureDocument("[remote]\nnon_owner_presentation = \"letterbox\"\n");
    WebTerminal page(10, 40, 1);
    PageHost host(7, 10, 40, Sync::Role::Viewer);
    host.source().geometry().noteTyping({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, 1);
    host.source().geometry().noteViewport({ 99, pageDaemonInstanceID }, Sync::GeometryStanding::Driver, { 10, 40 }, 2);
    REQUIRE(host.source().geometry().status().owner == Sync::ID128(99, pageDaemonInstanceID));
    host.setFacts({});
    REQUIRE(feedWire(page, host.answer(page.buildHello("t", 7))));
    REQUIRE(feedWire(page, host.exchange(page)));
    page.setPresentationViewport(20 * page.cellWidth(), 6 * page.cellHeight());
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().scale, 1);
    CHECK_EQ(page.presentation().origin.x, -10 * page.cellWidth());
    CHECK_EQ(page.presentation().origin.y, -2 * page.cellHeight());
    page.noteTerminateTransportLost();
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().origin.x, 0);
    CHECK_EQ(page.presentation().origin.y, 0);
    // The old host picture remains, but a fresh greeting has no authority yet.
    const auto greeting = page.buildHello("t", 7);
    REQUIRE(!greeting.empty());
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.columns(), 40);
    CHECK_EQ(page.rows(), 10);
    CHECK_EQ(page.presentation().origin.x, 0);
    CHECK_EQ(page.presentation().origin.y, 0);
    PageHost successor(7, 10, 40, Sync::Role::Viewer);
    REQUIRE(feedWire(page, successor.answer(greeting)));
    REQUIRE(feedWire(page, successor.exchange(page)));
    REQUIRE(page.buildFrame());
    CHECK_EQ(page.presentation().origin.x, 0);
    CHECK_EQ(page.presentation().origin.y, 0);
    configureDocument("");
}

TEST(retiredPaneRecordsFailAtTheirHeaderWithoutChangingThePage)
{
    for (const std::uint8_t tag : { 0x83, 0x88, 0x8F }) {
        AttachedPage page;
        Ubiquitty::Protocol::Sync::PaneFacts facts;
        facts.programTitle = "recorded title";
        facts.currentDirectory = "/srv/project";
        page.host.setFacts(facts);
        REQUIRE(feedWire(page.terminal, page.host.exchange(page.terminal)));
        const std::vector<std::uint8_t> header { tag, 0xFF, 0xFF, 0xFF, 0x7F };
        CHECK(!feedWire(page.terminal, header));
        CHECK_STR_EQ(page.terminal.title(), "recorded title");
        CHECK_STR_EQ(page.terminal.currentDirectory(), "/srv/project");
        CHECK(!feedWire(page.terminal, page.host.exchange(page.terminal)));
    }
}

// OSC 22 lets a program set the pointer. macOS implements WindowClient to be
// PUSHED the resolved shape, because it sets an NSCursor imperatively; this
// frontend asks per frame and reads the same stack through the same resolver, so
// it needs no client for this — which is worth an assertion rather than an
// assumption, since "the frontend that does not implement the client silently
// does nothing" is the usual shape here.
TEST(testAProgramCanSetThePointerShape)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("text");
    CHECK_EQ(terminal.pointerShape(false, false, false, false), static_cast<int>(Ubiquitty::MousePointerShape::Text));

    const char setCrosshair[] = "\033]22;crosshair\007";
    terminal.feed(std::string_view(setCrosshair, static_cast<std::size_t>(sizeof(setCrosshair) - 1)));
    CHECK_MSG(terminal.pointerShape(false, false, false, false) == static_cast<int>(Ubiquitty::MousePointerShape::Crosshair),
        "the program's shape reaches the frontend without a WindowClient");

    // A link still outranks it, which is the ordering Core states so a hyperlink
    // stays clickable under a program that asked for something else.
    terminal.feed(" https://example.com/x");
    CHECK_MSG(terminal.pointerShape(true, false, false, false) == static_cast<int>(Ubiquitty::MousePointerShape::Pointer),
        "a link outranks an app-requested shape");
}

// OSC 50 is a live font swap. Core resolves the three axes and hands them over;
// this frontend owns the size and can apply it, and the family reaches the
// rasterizer through a page-owned JavaScript global, so it is staged instead.
// A frontend that implements neither leaves the escape a silent no-op, which is
// what this one did.
TEST(testAProgramCanChangeTheFontSize)
{
    WebTerminal terminal(24, 80, 1);
    const double initial = terminal.fontSize();

    // OSC 50 with an absolute size.
    const char absolute[] = "\033]50;xft:Monospace:size=24\007";
    terminal.feed(std::string_view(absolute, static_cast<std::size_t>(sizeof(absolute) - 1)));
    CHECK_MSG(terminal.fontSize() != initial, "an absolute size reaches the frontend");

    terminal.resetFontSize();
    CHECK_EQ(static_cast<int>(terminal.fontSize()), static_cast<int>(initial));
}

// The family cannot be applied here — this object holds no emscripten type and
// the rasterizer reads a page-owned global — so it is staged, and taken once.
TEST(testFontQueryReportsTheRenderedFallbackUntilThePageAdoptsARequest)
{
    WebTerminal terminal(2, 6, 1);
    std::array<char, 512> reply {};
    for (const char* input : { "\033]50;?\007", "\033]50;Missing Family\007\033]50;?\007", "\033c\033]50;?\007" }) {
        terminal.feed(input);
        const int length = terminal.takeReplies(reply);
        CHECK(std::string_view(reply.data(), static_cast<std::size_t>(length)) == "\033]50;Unifont\007");
    }
    terminal.rebuildFontStack();
    terminal.feed("\033]50;?\033\\");
    const int length = terminal.takeReplies(reply);
    CHECK(std::string_view(reply.data(), static_cast<std::size_t>(length)) == "\033]50;Unifont\033\\");
}

TEST(testAFontFamilyRequestIsStagedForThePage)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_STR_EQ(terminal.pendingFontFamily(), "");

    const char request[] = "\033]50;xft:Fira Code\007";
    terminal.feed(std::string_view(request, static_cast<std::size_t>(sizeof(request) - 1)));
    const std::string staged = terminal.pendingFontFamily();
    CHECK_MSG(!staged.empty(), "the family is staged for the page to apply");

    terminal.takeFontFamily();
    CHECK_MSG(terminal.pendingFontFamily()[0] == '\0', "taken once, not re-offered every frame");
}

// OSC 9 and OSC 777 raise a desktop notification. Core routes both through
// ShellClient, and a frontend without one drops them — this frontend had none,
// so a long build finishing told nobody.
//
// A banner is for a person who is looking somewhere else: the page says it
// does not hold the focus before the program speaks.
TEST(testAProgramCanRaiseANotification)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_STR_EQ(terminal.pendingNotificationTitle(), "");
    terminal.setFocus(Ubiquitty::Modes::FocusState::Unfocused);

    const char osc9[] = "\033]9;the build finished\007";
    terminal.feed(std::string_view(osc9, static_cast<std::size_t>(sizeof(osc9) - 1)));
    const std::string body = terminal.pendingNotificationBody();
    const std::string title = terminal.pendingNotificationTitle();
    CHECK_MSG(!body.empty() || !title.empty(), "the notification is staged for the page");

    terminal.takeNotification();
    CHECK_MSG(terminal.pendingNotificationTitle()[0] == '\0', "taken once, not re-raised every frame");
    CHECK_MSG(terminal.pendingNotificationBody()[0] == '\0', "both halves clear together");
}

// The converse: a page that holds the focus is being looked at, so what a
// program says there is on screen already and no banner is staged for it. A
// page that never reported its focus counts as focused.
TEST(testAFocusedPageStagesNoNotification)
{
    const char osc9[] = "\033]9;the build finished\007";
    WebTerminal untold(24, 80, 1);
    untold.feed(std::string_view(osc9, static_cast<std::size_t>(sizeof(osc9) - 1)));
    CHECK_MSG(untold.pendingNotificationTitle()[0] == '\0' && untold.pendingNotificationBody()[0] == '\0', "a page that never said otherwise is looked at");

    WebTerminal focused(24, 80, 1);
    focused.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    focused.setFocus(Ubiquitty::Modes::FocusState::Focused);
    focused.feed(std::string_view(osc9, static_cast<std::size_t>(sizeof(osc9) - 1)));
    CHECK_MSG(focused.pendingNotificationTitle()[0] == '\0' && focused.pendingNotificationBody()[0] == '\0', "a focused page stages none");
    // Looked away from, the same words are staged.
    focused.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    focused.feed(std::string_view(osc9, static_cast<std::size_t>(sizeof(osc9) - 1)));
    CHECK_MSG(focused.pendingNotificationTitle()[0] != '\0' || focused.pendingNotificationBody()[0] != '\0', "and once it is not, the next one is");
}

// OSC 7 is how a shell reports where it is. Every frontend that shows a path in
// a title or a tab reads it from here rather than parsing the prompt.
TEST(testAShellCanReportItsDirectory)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_STR_EQ(terminal.currentDirectory(), "");

    const char osc7[] = "\033]7;file://host/tmp/somewhere\007";
    terminal.feed(std::string_view(osc7, static_cast<std::size_t>(sizeof(osc7) - 1)));
    const std::string directory = terminal.currentDirectory();
    CHECK_MSG(directory.find("somewhere") != std::string::npos, "the shell's directory reaches the frontend");
}

// Inline images (kitty graphics) reach the browser through the shared CPU
// compositor: capture hands the Terminal's image and placement tables to
// SoftwareRenderer, which resolves and draws them. The instance path has no
// image pass, so a frame carrying one is flagged and the page routes it to the
// CPU — a fallback that only works because the fallback can actually draw them.
//
// Asserted rather than assumed: I read TerminalSnapshot.cpp, found no image
// handling, and nearly concluded this frontend could not show a picture at all.
// The pass is in SoftwareRenderer, one file over.
TEST(testAnInlineImageReachesThePixels)
{
    WebTerminal blank(8, 20, 1);
    CHECK(blank.buildFrame());
    CHECK_MSG(!blank.frameRequiresCPUCompositing(), "an ordinary cell frame can use the GPU");
    const std::vector<std::uint8_t> without = blank.render();
    CHECK(!without.empty());

    WebTerminal withImage(8, 20, 1);
    // One red pixel, transmitted and placed: a=T, f=24 (RGB), s=v=1.
    const char kitty[] = "\033_Ga=T,f=24,s=1,v=1;/wAA\033\\";
    withImage.feed(std::string_view(kitty, static_cast<std::size_t>(sizeof(kitty) - 1)));

    CHECK_MSG(withImage.buildFrame(), "the frame builds");
    CHECK_MSG(withImage.frameRequiresCPUCompositing(), "the page routes the picture to the compositor that draws it");

    const std::vector<std::uint8_t>& painted = withImage.render();
    CHECK_EQ(painted.size(), without.size());
    CHECK_MSG(std::memcmp(without.data(), painted.data(), without.size()) != 0,
        "the image reaches the pixels the page blits");
}

// The passive page draws typed image state without parsing program VT bytes.
TEST(aPassivePageRendersCroppedAlphaImagesDeliveredThroughTypedTransfers)
{
    WebTerminal page(8, 20, 1);
    PageHost host(7, 8, 20);
    namespace Sync = Ubiquitty::Protocol::Sync;
    const auto connectionBudget = std::make_shared<Sync::BulkSourceBudget>(Sync::maxCatalogMessageBytes);
    const auto aggregateBudget = std::make_shared<Sync::BulkSourceBudget>(4 * Sync::maxCatalogMessageBytes);
    host.connection().setImageSourceAdmission([&host, connectionBudget, aggregateBudget] {
        const auto retained = host.connection().retainedOutboundPayloadBytes();
        return Sync::BulkSourceAdmission { .connection = connectionBudget, .aggregate = aggregateBudget, .otherConnectionBytes = retained, .otherAggregateBytes = retained };
    });
    Ubiquitty::processBytes(&host.terminal(), "\033]11;#000000\007\033[?25l");
    REQUIRE(feedWire(page, host.answer(page.buildHello("t", 7))));
    REQUIRE(feedWire(page, host.exchange(page)));
    REQUIRE(page.hasScreen());
    const auto panes = host.connection().boundPanes();
    REQUIRE(panes.size() == 1);
    REQUIRE(page.buildFrame());
    CHECK(!page.frameRequiresCPUCompositing());
    const std::vector<std::uint8_t> without = page.render();
    REQUIRE(!without.empty());
    const auto colorAtPlacement = [&page](const std::vector<std::uint8_t>& pixels) {
        const int x = 3 * page.cellWidth();
        const int y = 2 * page.cellHeight() + page.cellHeight() / 2;
        const std::size_t offset = (static_cast<std::size_t>(y) * page.imageWidth() + x) * 4;
        return (static_cast<int>(pixels[offset]) << 16) | (static_cast<int>(pixels[offset + 1]) << 8)
            | static_cast<int>(pixels[offset + 2]);
    };
    CHECK_EQ(colorAtPlacement(without), 0x000000);

    // Two source texels: half-transparent red, opaque blue. Crop to red and
    // enlarge it over two cells, so taking the full image would sample blue.
    Ubiquitty::processBytes(&host.terminal(),
        "\033[3;3H\033_Ga=T,f=32,s=2,v=1,i=88,p=8,c=2,r=1,x=0,y=0,w=1,h=1,C=1;/wAAgAAA//8=\033\\");
    REQUIRE(host.terminal().images.stored[0].used);
    REQUIRE(feedWire(page, host.publish(page)));
    for (int round = 0; round < 6; ++round)
        REQUIRE(feedWire(page, host.exchange(page)));
    REQUIRE(page.buildFrame());
    CHECK(page.frameRequiresCPUCompositing());
    CHECK_MSG(colorAtPlacement(page.render()) == 0x800000, "the crop's straight alpha blends over the received black background");

    // Only the placement changes: no pixel retransmission is needed to crop
    // the other source texel, and the frontend must invalidate its picture.
    Ubiquitty::processBytes(&host.terminal(),
        "\033[3;3H\033_Ga=d,d=i,i=88,q=2\033\\\033_Ga=p,i=88,p=8,c=2,r=1,x=1,y=0,w=1,h=1,C=1,q=2\033\\");
    REQUIRE(feedWire(page, host.publish(page)));
    for (int round = 0; round < 3; ++round)
        REQUIRE(feedWire(page, host.exchange(page)));
    REQUIRE(page.buildFrame());
    CHECK_MSG(colorAtPlacement(page.render()) == 0x0000FF, "a placement-only crop change reaches the compositor");

    Ubiquitty::processBytes(&host.terminal(), "\033_Ga=d,d=I,i=88,q=2\033\\");
    REQUIRE(feedWire(page, host.publish(page)));
    for (int round = 0; round < 3; ++round)
        REQUIRE(feedWire(page, host.exchange(page)));
    REQUIRE(page.buildFrame());
    CHECK(!page.frameRequiresCPUCompositing());
    CHECK_MSG(page.render() == without, "removing the placement restores the received grid and GPU route");
}

TEST(testTekFramesUseTheCPUCompositorUntilTheProgramReturnsToText)
{
    WebTerminal terminal(8, 20, 1);
    terminal.feed("text under the storage tube");
    CHECK(terminal.buildFrame());
    CHECK(!terminal.frameRequiresCPUCompositing());
    terminal.feed("\033[?38h\033\014");
    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.frameRequiresCPUCompositing(), "even an empty active Tek tube covers the text grid");
    const std::vector<std::uint8_t> emptyTube = terminal.render();
    const char stroke[] = { 0x1D, 0x27, 0x7A, 0x2F, 0x54, 0x21, 0x72, 0x20, 0x59 };
    terminal.feed(std::string_view(stroke, sizeof(stroke)));
    CHECK(terminal.buildFrame());
    CHECK(terminal.frameRequiresCPUCompositing());
    CHECK_MSG(terminal.render() != emptyTube, "the fallback paints the Tek stroke, not just a different routing flag");
    terminal.feed("\033\003"); // Tek ESC ETX returns to VT text mode.
    CHECK(terminal.buildFrame());
    CHECK_MSG(!terminal.frameRequiresCPUCompositing(), "leaving Tek restores the GPU cell route");
}

// DEC mode 1004: a program that asked to hear about focus is told with CSI I and
// CSI O. macOS and Linux both drive Core's focusChanged on every window
// transition, and so must this frontend, or vim never learns the window has
// gone away.
TEST(testFocusReachesAProgramThatAskedForIt)
{
    WebTerminal terminal(24, 80, 1);
    const char enable[] = "\033[?1004h";
    terminal.feed(std::string_view(enable, static_cast<std::size_t>(sizeof(enable) - 1)));

    terminal.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    CHECK_MSG(!terminal.isFocused(), "the terminal knows it lost focus");

    terminal.setFocus(Ubiquitty::Modes::FocusState::Focused);
    CHECK_MSG(terminal.isFocused(), "and that it got it back");
}

// The cursor draws hollow while unfocused, on both paths. A frontend that never
// says otherwise draws a solid cursor on a window the user is not in, which
// reads as the window being active.
TEST(testAnUnfocusedCursorLooksDifferent)
{
    const BlockCursorConfiguration blockCursor;
    WebTerminal terminal(4, 12, 1);
    terminal.feed("hi");
    const std::vector<std::uint8_t> focused = terminal.render();

    terminal.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::vector<std::uint8_t>& unfocused = terminal.render();

    CHECK_EQ(focused.size(), unfocused.size());
    CHECK_MSG(std::memcmp(focused.data(), unfocused.data(), focused.size()) != 0,
        "losing focus changes what is drawn");
}

// Pasted text is not typed text. It travels as a paste, and the host writes
// it to the program under Core's paste policy, as macOS and Linux do with a
// local clipboard.
TEST(testPasteIsFencedWhenTheApplicationAsksForIt)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const char enable[] = "\033[?2004h";
    page.programPrints(std::string_view(enable, static_cast<std::size_t>(sizeof(enable) - 1)));

    const char text[] = "two\nlines";
    const std::vector<std::uint8_t>& frame = terminal.buildPaste(std::string_view(text, static_cast<std::size_t>(sizeof(text) - 1)));
    const std::string wire = page.programReads(frame);
    CHECK_MSG(wire.find("\033[200~") != std::string::npos, "the paste opens a fence");
    CHECK_MSG(wire.find("\033[201~") != std::string::npos, "and closes it");
}

// The security half, and the reason this is not merely a formatting nicety: a
// clipboard carrying its own end-fence must not be able to close the one the
// terminal opened, or everything after it is delivered as keystrokes — which
// for a shell means executed.
TEST(testPastedTextCannotCloseTheFenceItDidNotOpen)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const char enable[] = "\033[?2004h";
    page.programPrints(std::string_view(enable, static_cast<std::size_t>(sizeof(enable) - 1)));

    const char hostile[] = "safe\033[201~rm -rf /\n";
    const std::vector<std::uint8_t>& frame = terminal.buildPaste(std::string_view(hostile, static_cast<std::size_t>(sizeof(hostile) - 1)));
    const std::string wire = page.programReads(frame);

    std::size_t opens = 0;
    for (std::size_t at = wire.find("\033[200~"); at != std::string::npos; at = wire.find("\033[200~", at + 1))
        ++opens;
    std::size_t closes = 0;
    for (std::size_t at = wire.find("\033[201~"); at != std::string::npos; at = wire.find("\033[201~", at + 1))
        ++closes;
    // Both counts, or the assertion is satisfied by a paste that was never
    // fenced at all — exactly the failure this guards, so counting closes
    // alone would pass against it.
    CHECK_MSG(opens == 1, "the terminal opened exactly one fence");
    CHECK_MSG(closes == 1, "the embedded fence was neutralised, not passed through");
    CHECK_MSG(wire.rfind("\033[201~") > wire.find("\033[200~"), "the close is the terminal's own, after its open");
}

// With bracketed paste off, a shell executes each line as it arrives, so the
// policy strips the control characters that would do it rather than wrapping.
TEST(testPasteIsStrippedWhenTheApplicationHasNotAskedForFencing)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    const char text[] = "line\rone";
    const std::vector<std::uint8_t>& frame = terminal.buildPaste(std::string_view(text, static_cast<std::size_t>(sizeof(text) - 1)));
    const std::string wire = page.programReads(frame);
    CHECK_MSG(wire.find("\033[200~") == std::string::npos, "no fence when none was asked for");
    CHECK_MSG(wire.find("line") != std::string::npos, "the text still arrives");
}

// An input method composes into an editable element and places its candidate
// window at that element, so the element has to follow the caret — otherwise the
// popup sits wherever it was laid out and reads as belonging to another
// application. The position is the terminal's to report.
TEST(testTheCursorPositionIsReportableForAnInputMethod)
{
    WebTerminal terminal(6, 20, 1);
    CHECK_EQ(terminal.cursorRow(), 0);
    CHECK_EQ(terminal.cursorColumn(), 0);

    terminal.feed("ab\r\ncd");
    CHECK_EQ(terminal.cursorRow(), 1);
    CHECK_EQ(terminal.cursorColumn(), 2);
}

// Scrolled back, the cursor is below the viewport. It is clamped rather than
// reported off-grid, so the element stays somewhere a popup can be drawn.
TEST(testTheReportedCursorStaysOnTheGridWhenScrolledBack)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 20; ++i)
        terminal.feed("line\r\n");
    terminal.scrollBy(10);

    const int row = terminal.cursorRow();
    CHECK_MSG(row >= 0 && row < terminal.rows(), "the reported row is on the grid");
    const int column = terminal.cursorColumn();
    CHECK_MSG(column >= 0 && column < terminal.columns(), "and so is the column");
}

// Attached, the program that enabled DEC 1004 runs against the HOST's Terminal,
// so telling this mirror is not telling it. Sync `Focus` is how a client says
// what only it can see — a host cannot observe a window it does not own.
TEST(testFocusIsReportableOverTheWire)
{
    // The program asked to hear of focus (DECSET 1004), and runs against the
    // host's terminal: what it reads is the host's report of what the page
    // said.
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    page.programPrints("\033[?1004h");
    CHECK_MSG(page.host.isClientFocused(), "a page that said nothing is taken to be focused");
    // The report the page sends once after the handshake: the pane's focus
    // is the page's to state, and the program hears of it.
    CHECK_STR_EQ(page.programReads(terminal.buildFocusChanged()), std::string("\033[I"));

    terminal.setFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::string lost = page.programReads(terminal.buildFocusChanged());
    CHECK_MSG(!page.host.isClientFocused(), "the wire carries the state it lost");
    CHECK_STR_EQ(lost, std::string("\033[O"));

    terminal.setFocus(Ubiquitty::Modes::FocusState::Focused);
    const std::string gained = page.programReads(terminal.buildFocusChanged());
    CHECK_MSG(page.host.isClientFocused(), "and the state it got back");
    CHECK_STR_EQ(gained, std::string("\033[I"));

    // The same state again is nothing to say.
    CHECK_MSG(terminal.buildFocusChanged().empty(), "a state the host already holds builds no frame");
}

// this frontend's build* helpers each clear one shared scratch buffer, so a
// caller that builds a second frame before sending the first sends the second
// one twice. Pinned because I did exactly that: the initial focus report was
// written over the HELLO it was meant to follow.
//
// Core does the opposite — encodeFrame appends, and accumulating several frames
// into one buffer then writing once is correct there. The discipline asserted
// here belongs to WebTerminal's export model, where each build must produce
// exactly one frame for frameLength() to describe.
TEST(testBuildingASecondFrameInvalidatesTheFirst)
{
    WebTerminal terminal(24, 80, 1);
    const std::vector<std::uint8_t>& hello = terminal.buildHello("t", 0);
    const std::uint8_t helloType = hello[0];
    CHECK_EQ(helloType, std::to_underlying(Ubiquitty::Protocol::Sync::FrameKind::Greet));

    (void)terminal.buildListSessions();
    CHECK_MSG(hello.empty(), "a pre-Welcome list is refused and clears the shared builder buffer");
}

// A selection can produce spans but no visible pixels: the builder defaults
// selectionColor to a fully transparent quad, so a frontend that sets no colour
// emits the overlay every frame and draws nothing. Asserting on the span count
// passes either way.
TEST(testTheSelectionOverlayIsActuallyVisible)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("hello world");
    CHECK(terminal.buildFrame());
    const int overlaysWithoutSelection = terminal.overlayInstanceCount();

    press(terminal, 0, 0);
    drag(terminal, 0, 10);
    release(terminal, 2, 6);
    CHECK_MSG(terminal.hasSelection(), "the drag selected something");

    CHECK(terminal.buildFrame());
    CHECK_MSG(terminal.overlayInstanceCount() > overlaysWithoutSelection,
        "a selection emits an overlay quad");

    // The quad exists either way; what matters is that it is visible.
    bool sawVisibleHighlight = false;
    for (int i = 0; i < terminal.overlayInstanceCount(); ++i) {
        if (terminal.overlayInstances()[i].color.w > 0.0f)
            sawVisibleHighlight = true;
    }
    CHECK_MSG(sawVisibleHighlight, "the overlay is drawn with a non-zero alpha");
}

// --- The host's verdict on an attach ----------------------------------------
//
// A held or refused attach carries no checkpoint, and every one of these cases
// asserts against SILENCE rather than against wording: the failure being fenced
// off is a frontend that decodes the verdict and shows an empty grid, which is
// indistinguishable from a host that is down. That is what the browser did, and
// it turned one unanswered permission question into a terminal that looked
// broken.

// Feeds one encoded frame and returns the standing verdict afterwards.
std::string noticeAfter(WebTerminal& terminal, const std::vector<std::uint8_t>& frame)
{
    (void)terminal.buildHello("t");
    CHECK(!feedWire(terminal, frame));
    CHECK(!terminal.isAttached());
    return terminal.hostNotice();
}

// A pending Welcome identifies the held question without granting a pane. The
// page must explain that wait before any checkpoint can exist.
TEST(testAHeldAttachSaysSoRatherThanShowingABlankGrid)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    PendingPageHost host;
    CHECK_STR_EQ(terminal.hostNotice(), "");

    REQUIRE(host.begin(terminal));
    CHECK(host.state() == Sync::ConnectionState::AwaitingConsent);
    CHECK(!terminal.isAttached());
    CHECK(!terminal.hasScreen());
    CHECK(terminal.buildListSessions().empty());
    CHECK(terminal.buildTerminateSession(7).empty());
    const std::string held = terminal.hostNotice();
    CHECK_MSG(!held.empty(), "a held attach reaches the screen");
    CHECK_MSG(held.find("permission") != std::string::npos,
        "and names what is being waited for, not merely that something is wrong");

    REQUIRE(host.sendStatus(terminal, Sync::ConsentStatusPhase::Pending));
    CHECK_STR_EQ(terminal.hostNotice(), held);
    CHECK(!terminal.isAttached());
    CHECK(!terminal.hasScreen());
    REQUIRE(host.approve(terminal));
    CHECK(terminal.isAttached());
    CHECK(!terminal.hasScreen());

    Ubiquitty::processBytes(&host.terminal(), "approved shell");
    REQUIRE(host.publish(terminal));
    CHECK(terminal.hasScreen());
    CHECK_STR_EQ(terminal.hostNotice(), "");
    CHECK_MSG(screenText(terminal).find("approved shell") != std::string::npos,
        "the same approved attachment receives its first real checkpoint");
}

// Declined and timed-out are different problems with different answers: one
// means ask again, the other means nobody was there. A mapping that ignores the
// exact phase satisfies "something is shown" and still sends the user the wrong
// way, so the two are compared against each other rather than against empty.
TEST(testARefusedAttachSaysWhichRefusalItWas)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    const auto noticeForPhase = [](Sync::ConsentStatusPhase phase) {
        WebTerminal terminal(24, 80, 1);
        PendingPageHost host;
        CHECK(host.begin(terminal));
        CHECK(host.sendStatus(terminal, Sync::ConsentStatusPhase::Pending));
        CHECK(!host.sendStatus(terminal, phase));
        CHECK(host.state() == Sync::ConnectionState::Closed);
        CHECK(!terminal.isAttached());
        CHECK(!terminal.hasScreen());
        CHECK(terminal.buildListSessions().empty());
        CHECK(terminal.buildTerminateSession(7).empty());
        const std::string verdict = terminal.hostNotice();
        CHECK_STR_EQ(verdict, Sync::consentDeniedNotice(phase));
        CHECK_MSG(!feedWire(terminal, ownConsentStatusWire({ .question = host.question(), .phase = Sync::ConsentStatusPhase::Approved })),
            "a terminal verdict and NoConsent Bye cannot be reopened by later approval");
        CHECK_STR_EQ(terminal.hostNotice(), verdict);
        return verdict;
    };

    const std::string declined = noticeForPhase(Sync::ConsentStatusPhase::Denied);
    const std::string timedOut = noticeForPhase(Sync::ConsentStatusPhase::Expired);
    CHECK_MSG(!declined.empty(), "a decline reaches the screen");
    CHECK_MSG(!timedOut.empty(), "so does a timeout");
    CHECK_MSG(declined != timedOut, "and the two refusals do not read as the same event");
}

TEST(testAPendingAttachRefusesOutOfOrderOrMismatchedOwnStatus)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    for (const auto phase : { Sync::ConsentStatusPhase::Approved, Sync::ConsentStatusPhase::Denied, Sync::ConsentStatusPhase::Expired }) {
        WebTerminal terminal(24, 80, 1);
        PendingPageHost host;
        REQUIRE(host.begin(terminal));
        CHECK(!feedWire(terminal, ownConsentStatusWire({ .question = host.question(), .phase = phase })));
        CHECK(!terminal.isAttached());
        CHECK(!terminal.hasScreen());
        CHECK(terminal.buildTerminateSession(7).empty());
    }

    for (const unsigned variant : { 0u, 1u, 2u }) {
        WebTerminal terminal(24, 80, 1);
        PendingPageHost host;
        REQUIRE(host.begin(terminal));
        REQUIRE(host.sendStatus(terminal, Sync::ConsentStatusPhase::Pending));
        auto question = host.question();
        if (variant == 1)
            ++question.requestID;
        if (variant == 2)
            ++question.sessionID;
        const auto phase = variant ? Sync::ConsentStatusPhase::Approved : Sync::ConsentStatusPhase::Pending;
        CHECK(!feedWire(terminal, ownConsentStatusWire({ .question = question, .phase = phase })));
        CHECK(!terminal.isAttached());
        CHECK(!terminal.hasScreen());
        CHECK(terminal.buildListSessions().empty());
    }
}

TEST(testAPendingAttachRefusesPaneDataBeforeApproval)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    for (const auto phase : { Sync::ConsentStatusPhase::Pending, Sync::ConsentStatusPhase::Denied, Sync::ConsentStatusPhase::Expired }) {
        WebTerminal terminal(24, 80, 1);
        PendingPageHost host;
        REQUIRE(host.begin(terminal));
        REQUIRE(host.sendStatus(terminal, Sync::ConsentStatusPhase::Pending));
        if (phase != Sync::ConsentStatusPhase::Pending)
            REQUIRE(feedWire(terminal, ownConsentStatusWire({ .question = host.question(), .phase = phase })));
        const std::string verdict = terminal.hostNotice();
        std::vector<std::uint8_t> body;
        Sync::encode(body, Sync::PaneBind { .handle = 1, .paneID = { 7, pageDaemonInstanceID } });
        std::vector<std::uint8_t> frame;
        CHECK(Sync::appendFrame(frame, Sync::FrameKind::PaneBind, 0, body));
        std::vector<std::uint8_t> wire;
        wire.insert(wire.end(), frame.begin(), frame.end());
        CHECK(!feedWire(terminal, wire));
        CHECK(!terminal.isAttached());
        CHECK(!terminal.hasScreen());
        CHECK_STR_EQ(terminal.hostNotice(), verdict);
        CHECK(terminal.buildTerminateSession(7).empty());
    }
}

// The reason a browser is refused is USUALLY that no human is attached to grant
// consent, which has nothing to do with a token. A table indexed by the wire
// number drifts as reasons are added: one written for five reasons reads past
// its end for an eighth — printing a bare "7" beside advice to reissue a
// token, for the one refusal a token cannot fix. Every reason is checked, so
// adding one without wording it fails here.
TEST(testEveryAuthRefusalReadsAsItself)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    const Sync::ByeReason reasons[] = {
        Sync::ByeReason::TokenMissing,
        Sync::ByeReason::TokenInvalid,
        Sync::ByeReason::TokenExpired,
        Sync::ByeReason::TokenRevoked,
        Sync::ByeReason::OutsideScope,
        Sync::ByeReason::VersionMismatch,
        Sync::ByeReason::DuplicateHandshake,
        Sync::ByeReason::NoConsent,
    };

    std::vector<std::string> notices;
    for (const Sync::ByeReason reason : reasons) {
        WebTerminal terminal(24, 80, 1);
        std::vector<std::uint8_t> body;
        Sync::encode(body, Sync::Bye { .reason = reason, .detail = "fixture refusal" });
        std::vector<std::uint8_t> frame;
        CHECK(Sync::appendFrame(frame, Sync::FrameKind::Bye, 0, body));
        notices.push_back(noticeAfter(terminal, frame));
    }

    for (std::size_t i = 0; i < notices.size(); ++i) {
        CHECK_MSG(!notices[i].empty(), "every refusal reason says something");
        for (std::size_t j = i + 1; j < notices.size(); ++j)
            CHECK_MSG(notices[i] != notices[j], "and no two reasons read identically");
    }

    const std::string consent = notices.back();
    CHECK_MSG(consent.find("token") == std::string::npos,
        "the consent refusal must not blame the token — reissuing one cannot fix it");
    CHECK_MSG(consent.find("allow") != std::string::npos,
        "it says someone has to allow the connection, so the user knows to go and grant it");
}

// A verdict answers the connection that earned it. The next Greet begins a
// connection the host has not judged, so a page reading the notice after a
// failed read can tell this connection's refusal from the last one's.
TEST(aRefusalDoesNotOutliveItsConnection)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    std::vector<std::uint8_t> body;
    Sync::encode(body, Sync::Bye { .reason = Sync::ByeReason::NoConsent, .detail = "fixture refusal" });
    std::vector<std::uint8_t> frame;
    REQUIRE(Sync::appendFrame(frame, Sync::FrameKind::Bye, 0, body));
    CHECK(!noticeAfter(terminal, frame).empty());
    (void)terminal.buildHello("t");
    CHECK_STR_EQ(terminal.hostNotice(), "");
    CHECK_STR_EQ(noticeAfter(terminal, frame), Sync::byeNotice(Sync::ByeReason::NoConsent));
}

// A reason byte outside the enum is reachable from the wire, and the decoder
// hands it over as-is. Falling through to an empty string would restore exactly
// the silence these cases exist to remove, on the one path nobody exercises.
TEST(testARefusalReasonThisBuildDoesNotKnowIsStillAnnounced)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    (void)terminal.buildHello("t");
    const std::uint8_t body[] = { 200, 0, 0 };
    std::vector<std::uint8_t> frame;
    CHECK(Sync::appendFrame(frame, Sync::FrameKind::Bye, 0, body));
    CHECK_MSG(!feedWire(terminal, frame), "an unknown typed reason fails the canonical grammar");
    CHECK(!terminal.isAttached());
    CHECK(!feedWire(terminal, frame));
}

// A client that cannot apply an update must ask for a checkpoint. The core
// owes that request to the host, and a frontend that never collects what is
// owed leaves the screen frozen until something else makes the host publish a
// checkpoint. Refusing the update is only half a recovery.
TEST(testARefusedUpdateAsksTheHostForACheckpoint)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(9);
    Ubiquitty::processBytes(&host.terminal(), "before");
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", 9))));
    CHECK_MSG(terminal.hasScreen(), "the checkpoint applied");
    (void)terminal.takePendingHostFrame();

    // A Chain update whose base the client never received cannot be applied.
    // Exercise recovery without using a UI clear to corrupt the replica.
    namespace Sync = Ubiquitty::Protocol::Sync;
    std::vector<std::uint8_t> update;
    Sync::encode(update, Sync::UpdateHeader { .baseGeneration = 998, .generation = 999 });
    std::vector<std::uint8_t> envelope;
    CHECK(Sync::appendFrame(envelope, Sync::FrameKind::Update, 1, update));
    std::vector<std::uint8_t> wire;
    wire.insert(wire.end(), envelope.begin(), envelope.end());
    CHECK(feedWire(terminal, wire));
    std::vector<std::uint8_t> owed;
    const std::vector<std::uint8_t>& pending = terminal.takePendingHostFrame();
    owed.insert(owed.end(), pending.begin(), pending.end());
    CHECK_MSG(!owed.empty(), "the client owes the host a checkpoint request");
    Sync::FrameDecoder decoder;
    decoder.append(owed);
    bool hasResync = false;
    while (const auto frame = decoder.next())
        hasResync |= frame->kind == Sync::FrameKind::Resync;
    CHECK_MSG(decoder.error() == Sync::EnvelopeError::None && decoder.bufferedBytes() == 0 && hasResync,
        "the owed bytes contain a direct canonical Resync");

    host.receive(owed);
    Ubiquitty::processBytes(&host.terminal(), "\r\nafter");
    CHECK(feedWire(terminal, host.publish(terminal)));
    CHECK_MSG(screenText(terminal).find("after") != std::string::npos,
        "the checkpoint that answers it brings the screen back");
}

// An attached clear leaves the replica and its diff base unchanged until the
// authoritative host applies the requested command.
TEST(testClearingAMirroredGridWaitsForTheHost)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(5);
    CHECK_MSG(!terminal.hasScreen(), "no checkpoint has been applied yet");

    // A real screen first. Without one these assertions read false, false,
    // false — and "clearing the buffer drops the screen" would hold just as
    // well if clearing did nothing at all. The claim is a transition, so the
    // true state has to exist first.
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", 5))));
    CHECK_MSG(terminal.hasScreen(), "a checkpoint establishes the screen");

    const auto before = screenText(terminal);
    const std::vector<std::uint8_t> cleared = terminal.buildClearBuffer();
    CHECK(terminal.hasScreen());
    CHECK(screenText(terminal) == before);

    host.receive(cleared);
    auto calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    auto request = Ubiquitty::Protocol::Control::decodeRequest(calls.front().text, {});
    CHECK(request.method == "pane.clear" && request.params.numberOr("pane") == 1 && request.params.stringOr("command") == "buffer");
    CHECK(feedWire(terminal, host.publish(terminal)));
    CHECK(terminal.hasScreen());

    terminal.clearScrollback();
    CHECK(terminal.hasScreen());
    CHECK(screenText(terminal) == before);
    host.receive(terminal.takePendingHostFrame());
    calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    request = Ubiquitty::Protocol::Control::decodeRequest(calls.front().text, {});
    CHECK(request.method == "pane.clear" && request.params.stringOr("command") == "scrollback");
}

// The invalidation is Core's, reached through the Terminal, so it is not a thing
// each frontend has to remember at each call site — which is how it was missed.
TEST(testTheMirrorIsWiredWithoutTheFrontendAskingPerCall)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.hasMirrorClient(), "Core can reach the sync client through the Terminal");
}

// Reload is what the id is for: without one in the HELLO the host has no way to
// know this is the same page and opens a second shell, which is what the browser
// did until the id became a parameter.
TEST(testHelloEchoesTheSessionAReattachAsksFor)
{
    WebTerminal terminal(30, 100, 1);
    const std::vector<std::uint8_t>& hello = terminal.buildHello("t", 4242);
    CHECK(!hello.empty());

    Ubiquitty::Protocol::Sync::Greet decoded {};
    const auto decodedGained = Ubiquitty::Protocol::Sync::decodeGreet(helloPayload(hello));
    CHECK(decodedGained.has_value());
    decoded = decodedGained.value_or(decoded);
    CHECK_EQ(static_cast<int>(decoded.request.sessionID), 4242);
    CHECK(decoded.request.isAttachOnly);
    CHECK_EQ(static_cast<int>(decoded.facts.viewportColumns), 100);
}

// A fresh request stores the host's selected ID. A saved numeric selection
// is attach-only and cannot be silently replaced by a different shell.
TEST(testTheAckedSessionIsTheOneAReattachCarries)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    PageHost host(77);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello("t", 0))));
    REQUIRE(terminal.isAttached());
    CHECK_EQ(terminal.sessionID(), 77u);
    const auto decoded = Sync::decodeGreet(helloPayload(terminal.buildHello("t", terminal.sessionID())));
    REQUIRE(decoded);
    CHECK_EQ(decoded->request.sessionID, 77u);
    CHECK(decoded->request.isAttachOnly);

    WebTerminal pinned(24, 80, 1);
    PageHost other(77);
    CHECK(!feedWire(pinned, other.answer(pinned.buildHello("t", 4242))));
    CHECK(!pinned.isAttached());
    CHECK(pinned.sessionID() != 77u);
}

TEST(testHelloWithoutATokenStillBuilds)
{
    // An unauthenticated daemon is a valid configuration; the page passes the
    // empty string when the URL carried no token, and that must not produce a
    // frame claiming an empty token.
    WebTerminal terminal(24, 80, 1);
    CHECK(!terminal.buildHello("").empty());
    CHECK(!terminal.buildHello(nullptr).empty());
}

TEST(testInputAndResizeBuildFrames)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;

    const char keys[] = "ls\r";
    const std::vector<std::uint8_t>& input = terminal.buildInput(keys);
    CHECK_MSG(!input.empty(), "bytes build a frame");
    CHECK_STR_EQ(page.programReads(input), std::string("ls\r"));
    // A page with no host has nowhere to send them.
    WebTerminal alone(24, 80, 1);
    CHECK_MSG(alone.buildInput(keys).empty(), "a page that is not attached builds no input");

    // A resize says the window's size in the facts and the page's size of
    // its pane in a Viewport, in one frame; the same size again says nothing.
    const std::vector<std::uint8_t> resized = terminal.buildResize(40, 120);
    CHECK_MSG(!resized.empty(), "a resize builds a frame");
    page.host.receive(resized);
    const Ubiquitty::Protocol::Sync::Facts& facts = page.host.connection().facts();
    CHECK_MSG(facts.viewportRows == 40 && facts.viewportColumns == 120, "the window's size did not reach the host's facts");
    const std::vector<Ubiquitty::Protocol::Sync::ViewportReport> viewports = page.host.connection().takeViewportReports();
    CHECK_MSG(viewports.size() == 1 && viewports[0].viewport.rows == 40 && viewports[0].viewport.columns == 120, "the page's size of its pane did not reach the host");
    CHECK_MSG(terminal.buildResize(40, 120).empty(), "the same size was sent again");
    CHECK_MSG(alone.buildResize(40, 120).empty(), "a page that is not attached built a resize");
}

TEST(testBrowserResizeUsesGrantedRoleAndWaitsForTheHostPicture)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    for (const Sync::Role role : { Sync::Role::Agent, Sync::Role::Viewer }) {
        WebTerminal page(24, 80, 1);
        PageHost host(7, 24, 80, role);
        CHECK(feedWire(page, host.answer(page.buildHello("t", 7))));
        for (int round = 0; round < 3; ++round)
            CHECK(feedWire(page, host.exchange(page)));
        page.resize(40, 120);
        CHECK_EQ(page.rows(), 24);
        CHECK_EQ(page.columns(), 80);
        host.receive(page.buildResize(40, 120));
        CHECK(host.connection().state() == Sync::ConnectionState::Attached);
        CHECK(host.connection().takeViewportReports().empty());
        auto calls = host.connection().takeCalls();
        if (role == Sync::Role::Viewer) {
            CHECK(calls.empty());
            continue;
        }
        REQUIRE(calls.size() == 1);
        CHECK(calls[0].text.find("pane.overrideGeometry") != std::string::npos);
        CHECK(calls[0].text.find("\"rows\":40,\"columns\":120") != std::string::npos);
        host.receive(page.buildResize(30, 100));
        host.receive(page.buildResize(31, 101));
        CHECK(host.connection().takeCalls().empty());
        CHECK(Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":1,"error":{"code":-32003,"message":"Drive refused"}})"));
        CHECK(feedWire(page, host.exchange(page)));
        CHECK(feedWire(page, host.exchange(page)));
        calls = host.connection().takeCalls();
        REQUIRE(calls.size() == 1);
        CHECK(calls[0].text.find("\"rows\":31,\"columns\":101") != std::string::npos);
        CHECK(host.connection().takeViewportReports().empty());
        CHECK(Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":2,"result":{"rows":31,"columns":101}})"));
        CHECK(feedWire(page, host.exchange(page)));
        host.receive(page.buildResize(31, 101));
        CHECK(host.connection().takeCalls().empty());
        Ubiquitty::resize(host.terminal(), 31, 101);
        CHECK(feedWire(page, host.publish(page)));
        CHECK_EQ(page.rows(), 31);
        CHECK_EQ(page.columns(), 101);

        // Reconnecting keeps the requested browser size, not a local reflow
        // of the retained host mirror, and retries once on the new authority.
        PageHost resumed(7, 31, 101, role);
        const auto hello = page.buildHello("t", 7);
        page.resize(10, 20);
        CHECK_EQ(page.rows(), 31);
        CHECK_EQ(page.columns(), 101);
        CHECK(feedWire(page, resumed.answer(hello)));
        CHECK(feedWire(page, resumed.exchange(page)));
        CHECK(resumed.connection().state() == Sync::ConnectionState::Attached);
        CHECK(resumed.connection().takeViewportReports().empty());
        calls = resumed.connection().takeCalls();
        REQUIRE(calls.size() == 1);
        CHECK(calls[0].text.find("\"rows\":31,\"columns\":101") != std::string::npos);
    }
}

TEST(testBrowserDriverResizeReportsNewFontPixelsWithoutReflowingTheMirror)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    for (const Sync::Role role : { Sync::Role::Owner, Sync::Role::Driver }) {
        WebTerminal page(24, 80, 1);
        PageHost host(7, 24, 80, role);
        CHECK(feedWire(page, host.answer(page.buildHello("t", 7))));
        for (int round = 0; round < 3; ++round)
            CHECK(feedWire(page, host.exchange(page)));
        const int oldHeight = page.cellHeight();
        page.setFontSize(32);
        page.setPadding(7);
        CHECK(page.cellHeight() > oldHeight);
        page.resize(40, 120);
        CHECK_EQ(page.rows(), 24);
        CHECK_EQ(page.columns(), 80);
        host.receive(page.buildResize(40, 120));
        REQUIRE(host.connection().state() == Sync::ConnectionState::Attached);
        CHECK(host.connection().takeCalls().empty());
        const auto viewports = host.connection().takeViewportReports();
        REQUIRE(viewports.size() == 1);
        const auto& viewport = viewports.front().viewport;
        CHECK_EQ(viewport.cellPixelWidth, page.cellWidth());
        CHECK_EQ(viewport.cellPixelHeight, page.cellHeight());
        CHECK_EQ(viewport.textAreaPixelWidth, 120 * page.cellWidth());
        CHECK_EQ(viewport.textAreaPixelHeight, 40 * page.cellHeight());
        CHECK_EQ(viewport.drawablePixelWidth, viewport.textAreaPixelWidth + 14);
        CHECK_EQ(viewport.drawablePixelHeight, viewport.textAreaPixelHeight + 14);
        CHECK_EQ(host.connection().facts().textAreaPixelWidth, viewport.textAreaPixelWidth);
        CHECK_EQ(host.connection().facts().textAreaPixelHeight, viewport.textAreaPixelHeight);

        // A cached driver viewport must not escape into a downgraded greeting.
        for (const Sync::Role downgraded : { Sync::Role::Agent, Sync::Role::Viewer }) {
            PageHost next(7, 24, 80, downgraded);
            CHECK(feedWire(page, next.answer(page.buildHello("t", 7))));
            for (int round = 0; round < 3; ++round)
                CHECK(feedWire(page, next.exchange(page)));
            CHECK(next.connection().state() == Sync::ConnectionState::Attached);
            CHECK(next.connection().takeViewportReports().empty());
            CHECK_EQ(next.connection().takeCalls().size(), downgraded == Sync::Role::Agent ? 1u : 0u);
        }
    }
}

// Empty and negative lengths reach these from the page whenever a key produces
// no bytes; they must build nothing rather than an empty-payload frame the host
// has to interpret.
TEST(testEmptyBuildsProduceNoFrame)
{
    WebTerminal terminal(24, 80, 1);
    CHECK(terminal.buildInput({}).empty());
    CHECK(terminal.buildResize(0, 80).empty());
    CHECK(terminal.buildResize(24, 0).empty());
    CHECK(terminal.buildResize(-1, -1).empty());
    CHECK(terminal.buildResize(Ubiquitty::maxRows + 1, 80).empty());
    CHECK(terminal.buildResize(24, Ubiquitty::maxColumns + 1).empty());
    CHECK(terminal.buildResize(65536, 65536).empty());
}

TEST(testHostBytesDecodeAndFaultsAreReported)
{
    WebTerminal terminal(24, 80, 1);
    // Nothing to decode is not a fault: an empty socket message is ordinary.
    CHECK(terminal.feedFromHost(std::string_view(nullptr, static_cast<std::size_t>(0))));
    CHECK(terminal.feedFromHost(""));

    // Garbage is. The page drops the connection on a false return, so a decoder
    // that swallowed this would leave a dead socket looking healthy.
    WebTerminal faulted(24, 80, 1);
    const std::string_view garbage("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", 12);
    bool hasReportedFault = !faulted.feedFromHost(garbage);
    for (int i = 0; i < 8 && !hasReportedFault; ++i)
        hasReportedFault = !faulted.feedFromHost(garbage);
    CHECK_MSG(hasReportedFault, "a malformed stream is reported as a fault");
    CHECK_MSG(!faulted.isAttached(), "a faulted client never reads as attached");
}

// --- a second attach on the same page ---------------------------------------
//
// A tab whose socket drops reconnects rather than waiting for a reload, and the
// connection it opens runs through the same WebTerminal: one frame decoder, one
// client core, one grid. The three cases below are what the connection that
// died must not leave behind.

// A host whose terminal shows `text`, for session `sessionID`.
std::unique_ptr<PageHost> hostShowing(std::uint32_t sessionID, const char* text)
{
    auto host = std::make_unique<PageHost>(sessionID);
    Ubiquitty::processBytes(&host->terminal(), text);
    return host;
}

// Each connection's screen plane is its own: a host numbers generations per
// attachment, so a session it creates after a drop starts over near one. A
// staleness floor carried from the connection that raised it would read every
// generation of the next as older than the grid on screen and drop it, and the
// dead session's screen would be what the tab shows until somebody reloads.
TEST(aSecondAttachTakesTheNextSessionsCheckpoint)
{
    WebTerminal terminal(24, 80, 1);
    auto first = hostShowing(1, "first session");
    CHECK(feedWire(terminal, first->answer(terminal.buildHello("t", 0))));
    for (int frame = 0; frame < 40; ++frame) {
        Ubiquitty::processBytes(&first->terminal(), "x");
        CHECK(feedWire(terminal, first->publish(terminal)));
    }
    CHECK_MSG(screenText(terminal).find("first session") != std::string::npos,
        "the first session's checkpoint is on screen");

    // The caller explicitly opens a new session after the socket drops. This
    // is not a fallback for a missing saved numeric ID.
    auto second = hostShowing(2, "second session");
    CHECK(feedWire(terminal, second->answer(terminal.buildHello("t", 0))));

    const std::string shown = screenText(terminal);
    CHECK_MSG(shown.find("second session") != std::string::npos,
        "and the second session's checkpoint replaces it");
    CHECK_MSG(shown.find("first session") == std::string::npos,
        "with nothing of the session that ended left on the grid");
}

// A checkpoint is thousands of bytes, so a link that dies mid-frame is the
// ordinary shape of a dropped connection rather than an exotic one. The bytes it
// left in the reassembly buffer are a body with no rest coming: prefixed to the
// next connection's stream they swallow its handshake and its checkpoint as
// their own payload, and the page decodes nothing again.
TEST(aSecondAttachAfterAFrameCutInHalfStillDecodes)
{
    WebTerminal terminal(24, 80, 1);
    auto first = hostShowing(1, "first session");
    const std::vector<std::uint8_t> answer = first->answer(terminal.buildHello("t", 0));
    REQUIRE(answer.size() > 2 * Ubiquitty::Protocol::Sync::maxEnvelopeHeaderBytes);
    const std::vector<std::uint8_t> half(answer.begin(), answer.begin() + static_cast<std::ptrdiff_t>(answer.size() / 2));
    (void)feedWire(terminal, half);
    CHECK_MSG(screenText(terminal).find("first session") == std::string::npos,
        "half a checkpoint draws nothing, which is why the tab reconnects");

    auto second = hostShowing(2, "second session");
    CHECK_MSG(feedWire(terminal, second->answer(terminal.buildHello("t", 0))),
        "the reattach decodes instead of faulting on the residue");
    CHECK_MSG(terminal.isAttached(), "the second handshake lands");
    CHECK_MSG(screenText(terminal).find("second session") != std::string::npos,
        "and the checkpoint after it reaches the grid");
}

// The decoder's fault latch is permanent by design — framing cannot be
// resynchronised — so it has to end with the stream that tripped it. Held, the
// page refuses the first bytes of every connection after it, closes the socket
// on the fault it reports, and retries into the same refusal for as long as the
// tab is open.
TEST(aSecondAttachClearsTheFaultThatEndedTheLastOne)
{
    WebTerminal terminal(24, 80, 1);
    (void)terminal.buildHello("t", 0);

    const std::string_view rubbish("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", 12);
    bool hasFaulted = !terminal.feedFromHost(rubbish);
    for (int i = 0; i < 8 && !hasFaulted; ++i)
        hasFaulted = !terminal.feedFromHost(rubbish);
    REQUIRE(hasFaulted);

    auto host = hostShowing(3, "after the fault");
    CHECK_MSG(feedWire(terminal, host->answer(terminal.buildHello("t", 0))),
        "the new connection's bytes are read, not refused by the old one's fault");
    CHECK_MSG(terminal.isAttached(), "so the handshake lands");
    CHECK_MSG(screenText(terminal).find("after the fault") != std::string::npos,
        "and the host's grid reaches the page");
}

// --- links, and the pointer shape that depends on them ----------------------

namespace {

/// A primary click with no modifier.
constexpr WebTerminal::LinkModifier plainClick = WebTerminal::LinkModifier::Up;

} // namespace

TEST(testTheBrowserFindsABareURL)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("see https://example.com/x now");
    CHECK_CSTR_EQ(terminal.linkAtCell(0, 10, plainClick), "https://example.com/x");
    CHECK_MSG(terminal.linkAtCell(0, 0, plainClick)[0] == '\0', "and nothing where there is no link");
}

TEST(testTheBrowserResolvesAnOSC8Hyperlink)
{
    WebTerminal terminal(24, 80, 1);
    const char feed[] = "\x1b]8;;https://example.com/t\x1b\\ordinary words\x1b]8;;\x1b\\";
    terminal.feed(std::string_view(feed, static_cast<std::size_t>(sizeof(feed) - 1)));
    CHECK_MSG(std::strcmp(terminal.linkAtCell(0, 4, plainClick), "https://example.com/t") == 0,
        "text that reads nothing like a URL is still a link when the program said so");
}

// A path is a candidate a frontend resolves against a working directory and
// confirms on a filesystem. A browser has neither, so offering one would show a
// link affordance for something no click could open.
TEST(testTheBrowserDoesNotOfferAFilePathAsALink)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("edit src/main.cpp now");
    CHECK(terminal.linkAtCell(0, 8, plainClick)[0] == '\0');
}

// The program writes the escape, so the URI is attacker-controlled, and in a
// browser `javascript:` runs in the page's own origin. A link the page will not
// open must not look like one either, or the affordance is the lie.
TEST(testADangerousSchemeIsNotOfferedAsALink)
{
    const char* const hostile[] = {
        "\x1b]8;;javascript:alert(1)\x1b\\click\x1b]8;;\x1b\\",
        "\x1b]8;;file:///etc/passwd\x1b\\click\x1b]8;;\x1b\\",
        "\x1b]8;;data:text/html,<script>alert(1)</script>\x1b\\click\x1b]8;;\x1b\\",
        "\x1b]8;;vbscript:msgbox(1)\x1b\\click\x1b]8;;\x1b\\",
    };
    for (const char* feed : hostile) {
        WebTerminal terminal(24, 80, 1);
        terminal.feed(feed);
        CHECK_MSG(terminal.linkAtCell(0, 2, plainClick)[0] == '\0', "a scheme the page will not open is not a link");
        CHECK_MSG(terminal.pointerShape(false, false, false, false) != static_cast<int>(Ubiquitty::MousePointerShape::Pointer),
            "and it does not get the hand cursor either");
    }
}

TEST(testTheSchemesAPageCanOpenAreStillLinks)
{
    const char* const allowed[] = {
        "\x1b]8;;https://example.com/a\x1b\\click\x1b]8;;\x1b\\",
        "\x1b]8;;http://example.com/b\x1b\\click\x1b]8;;\x1b\\",
        "\x1b]8;;mailto:someone@example.com\x1b\\click\x1b]8;;\x1b\\",
    };
    for (const char* feed : allowed) {
        WebTerminal terminal(24, 80, 1);
        terminal.feed(feed);
        CHECK_MSG(terminal.linkAtCell(0, 2, plainClick)[0] != '\0', "an ordinary link still works");
    }
}

// A connection to a host the program named is the reader's to ask for, as on
// every other frontend: a plain click leaves ssh, sftp, ftp and ftps alone, and
// Command or Ctrl opens them. The web schemes still open on a plain click.
TEST(testAConnectionSchemeOpensOnlyWithTheLinkModifier)
{
    for (const char* uri : { "ssh://build.example", "sftp://build.example/srv", "ftp://files.example/pub", "FTPS://files.example/pub" }) {
        WebTerminal terminal(24, 80, 1);
        terminal.feed(std::string("\x1b]8;;") + uri + "\x1b\\connect\x1b]8;;\x1b\\");
        CHECK_MSG(terminal.linkAtCell(0, 2, plainClick)[0] == '\0', uri);
        CHECK_MSG(std::strcmp(terminal.linkAtCell(0, 2, WebTerminal::LinkModifier::Held), uri) == 0, uri);
    }
    WebTerminal terminal(24, 80, 1);
    terminal.feed("see https://example.com/x now");
    CHECK_CSTR_EQ(terminal.linkAtCell(0, 10, plainClick), "https://example.com/x");
    CHECK_CSTR_EQ(terminal.linkAtCell(0, 10, WebTerminal::LinkModifier::Held), "https://example.com/x");
}

TEST(testThePointerIsAHandOverALinkAndAnIBeamOverText)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("see https://example.com/x now");
    CHECK_EQ(terminal.pointerShape(true, false, false, false), static_cast<int>(Ubiquitty::MousePointerShape::Pointer));
    CHECK_EQ(terminal.pointerShape(false, false, false, false), static_cast<int>(Ubiquitty::MousePointerShape::Text));
}

TEST(testPastTheEndOfTheRowThereIsNothingToSelect)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("text");
    CHECK_EQ(terminal.pointerShape(false, false, false, true), static_cast<int>(Ubiquitty::MousePointerShape::Default));
}

// A tracking application owns the clicks, so the I-beam would mislead — but a
// link still outranks it, which is the ordering the shared decision exists for.
TEST(testATrackingApplicationSuppressesTheIBeamButNotTheLink)
{
    WebTerminal terminal(24, 80, 1);
    const char enableTracking[] = "\x1b[?1000h";
    terminal.feed(std::string_view(enableTracking, static_cast<std::size_t>(sizeof(enableTracking) - 1)));
    terminal.feed("see https://example.com/x now");
    CHECK_EQ(terminal.pointerShape(false, false, false, false), static_cast<int>(Ubiquitty::MousePointerShape::Default));
    CHECK_EQ(terminal.pointerShape(true, false, false, false), static_cast<int>(Ubiquitty::MousePointerShape::Pointer));
}

TEST(testTheLinkScanGrowsWithTheGrid)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("see https://example.com/x now");
    CHECK(terminal.linkAtCell(0, 10, plainClick)[0] != '\0');
    // A scratch sized for the old grid would refuse every row of a larger one.
    terminal.resize(60, 200);
    const char redraw[] = "\x1b[2J\x1b[Hhttps://example.com/y";
    terminal.feed(std::string_view(redraw, static_cast<std::size_t>(sizeof(redraw) - 1)));
    CHECK_MSG(terminal.linkAtCell(0, 3, plainClick)[0] != '\0', "the scan grew with the grid");
}

// The withhold is one question for the whole frame, not one per renderer.
//
// If buildFrame asks it and the CPU raster does not, a frame withheld from the
// instance path is drawn by the raster anyway when the caller falls through --
// so a GPU build honours DECSET 2026 exactly until it has a reason not to. The
// caller asks once, and this is the query it asks.
TEST(testAWithheldFrameIsWithheldFromEveryRenderer)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(!terminal.isFrameWithheld(), "nothing is composing, so present");

    const char begin[] = "\033[?2026h";
    terminal.feed(std::string_view(begin, static_cast<std::size_t>(sizeof(begin) - 1)));
    CHECK_MSG(terminal.isFrameWithheld(), "an open block withholds");
    CHECK_MSG(!terminal.buildFrame(), "and the instance path agrees");

    const char end[] = "\033[?2026l";
    terminal.feed(std::string_view(end, static_cast<std::size_t>(sizeof(end) - 1)));
    CHECK_MSG(!terminal.isFrameWithheld(), "the completed frame presents");
    CHECK_MSG(terminal.buildFrame(), "on both paths");
}

// --- selection and the scrollback viewport ----------------------------------

TEST(testADragSelectsTheTextItCovers)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("hello world");
    CHECK_MSG(!terminal.hasSelection(), "a fresh terminal has no selection");

    press(terminal, 0, 0);
    drag(terminal, 0, 4);
    release(terminal, 2, 6);
    CHECK(terminal.hasSelection());
    CHECK_CSTR_EQ(terminal.selectionText(), "hello");
}

TEST(testClearingDropsTheSelection)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("hello world");
    press(terminal, 0, 0);
    drag(terminal, 0, 4);
    release(terminal, 2, 6);
    terminal.clearSelection();
    CHECK(!terminal.hasSelection());
    CHECK_MSG(terminal.selectionText()[0] == '\0', "and the text goes with it");
}

// A double-click selects the word under it without any drag, which is the whole
// point: the caller reports the click count and Core does the expansion.
TEST(testADoubleClickTakesTheWord)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("hello world");
    press(terminal, 0, 7, 2);
    release(terminal, 2, 6);
    CHECK_CSTR_EQ(terminal.selectionText(), "world");
}

TEST(testATripleClickTakesTheLine)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("hello world");
    press(terminal, 0, 3, 3);
    release(terminal, 2, 6);
    CHECK_CSTR_EQ(terminal.selectionText(), "hello world");
}

// Trailing blanks are not selected text: a drag to the window edge copies the
// line, not the line plus the empty rest of the row.
TEST(testTrailingBlanksAreNotCopied)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("hi");
    press(terminal, 0, 0);
    drag(terminal, 0, 19);
    release(terminal, 2, 6);
    CHECK_CSTR_EQ(terminal.selectionText(), "hi");
}

TEST(testTheViewportScrollsAndClamps)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 20; ++i)
        terminal.feed("line\r\n");
    CHECK_EQ(terminal.viewOffset(), 0);

    terminal.scrollBy(5);
    CHECK_MSG(terminal.viewOffset() == 5, "scrolling back moves the view");

    // Over-scrolling in either direction is ordinary: a wheel does not know how
    // much history there is, so the clamp is the terminal's job.
    terminal.scrollBy(-100);
    CHECK_MSG(terminal.viewOffset() == 0, "and it never goes below the live grid");
    terminal.scrollBy(10000);
    CHECK_MSG(terminal.viewOffset() == terminal.scrollbackRows(), "nor past the oldest row");

    terminal.scrollToBottom();
    CHECK_EQ(terminal.viewOffset(), 0);
}

TEST(testAnEmptyScrollbackCannotScroll)
{
    WebTerminal terminal(6, 20, 1);
    terminal.feed("one screen");
    terminal.scrollBy(5);
    CHECK_MSG(terminal.viewOffset() == 0, "nothing to scroll into");
}

// A selection addressed in viewport rows forbids scrolling mid-drag, because a
// moving view drags it across the text. It is addressed in absolute buffer
// rows, as on the other frontends, so the
// viewport is free to move and the selection stays on the characters it was
// taken from — which is what extends a selection past the top of the screen.
TEST(testADragCanScrollAndKeepsItsText)
{
    WebTerminal terminal(4, 20, 1);
    for (int i = 0; i < 20; ++i)
        terminal.feed("line\r\n");

    press(terminal, 3, 0);
    drag(terminal, 3, 3);
    CHECK(terminal.hasSelection());
    const std::string beforeScroll = terminal.selectionText();

    terminal.scrollBy(5);
    CHECK_MSG(terminal.viewOffset() == 5, "the view moves during a live drag");
    CHECK_STR_EQ(terminal.selectionText(), beforeScroll.c_str());

    release(terminal, 2, 6);
}

// Links are resolved against the visible grid, so a scrolled view must look
// where the user is looking rather than at the live rows.
TEST(testTheLinkLookupFollowsTheViewport)
{
    WebTerminal terminal(4, 40, 1);
    terminal.feed("see https://example.com/x now\r\n");
    for (int i = 0; i < 8; ++i)
        terminal.feed("filler\r\n");

    CHECK_MSG(terminal.linkAtCell(0, 10, plainClick)[0] == '\0', "the link has scrolled off the live grid");
    terminal.scrollBy(9);
    CHECK_MSG(terminal.linkAtCell(0, 10, plainClick)[0] != '\0', "and is found again once it is back on screen");
}

} // namespace

// Beam reaches the frame, which is the only claim the wiring can get wrong
// silently: the session can be perfectly correct and the popover still never
// composited, and every session test would still pass.
//
// The assertion is that the CELLS CHANGE — not that a function was called. A
// wiring that laid the palette out and dropped the geometry produces an
// identical frame, and only a comparison of what was built can tell.
TEST(testBeamCompositesIntoTheFrame)
{
    WebTerminal terminal(24, 80, 1);
    terminal.feed("hello");

    const std::vector<std::uint8_t> plainImage = terminal.render();
    CHECK_MSG(!plainImage.empty(), "a frame was rendered at all");

    CHECK_MSG(terminal.toggleBeam(), "toggling opens the palette");
    CHECK(terminal.isBeamOpen());

    // The CONTENT, not the count. The builder emits an instance per cell either
    // way, so a count is identical whether or not the popover was composited —
    // asserting on it is the count-only comparison that has hidden real render
    // bugs in this tree before, and it passed against no composite at all.
    const std::vector<std::uint8_t> withBeam = terminal.render();
    CHECK_MSG(withBeam != plainImage, "the rendered image changes — the geometry reached the raster");

    // And closing puts it back exactly, so the popover leaves nothing behind.
    CHECK_MSG(!terminal.toggleBeam(), "toggling again closes it");
    const std::vector<std::uint8_t> closed = terminal.render();
    CHECK_MSG(closed == plainImage, "closing restores the frame byte for byte");
}

// A two-cell glyph must leave the cell for its own stream, because a cell quad
// samples one texture and the wide page is a different texture with different
// slot geometry. A wide UV baked into a cell that binds the mono page draws a
// real, sharply rendered, WRONG glyph — not a blank and not a fallback box,
// which is why no smoke test of this frontend can see it: only a reader of the
// language could.
//
// The assertion is on the STREAM and on the cell being left glyphless, not on
// the image, because the CPU raster reads both pages and is correct either way.
// A pixel comparison here would pass against that defect.
TEST(aWideGlyphDrawsFromItsOwnPage)
{
    WebTerminal terminal(6, 20, 1);
    // U+65E5 (日), two cells wide and present in the bundled Unifont.
    const char text[] = "\xE6\x97\xA5";
    terminal.feed(text);
    CHECK(terminal.buildFrame());

    CHECK_MSG(terminal.wideGlyphInstanceCount() == 1, "the two-cell glyph reached the wide stream");
    CHECK_MSG(terminal.wideGlyphInstances() != nullptr, "and the stream is readable");
    CHECK_MSG(terminal.wideAtlasPixels() != nullptr && terminal.wideAtlasWidth() > 0,
        "with a page for the pass to bind");

    // Its cell carries no baked glyph, so nothing samples the mono page for it.
    // A cell that kept the UV would draw the wrong glyph underneath the right
    // one, and on an opaque background the wrong one is what shows.
    const Ubiquitty::Rendering::CellInstance& cell = terminal.cellInstances()[0];
    CHECK_MSG(cell.atlasTopLeft.x == cell.atlasBottomRight.x
            && cell.atlasTopLeft.y == cell.atlasBottomRight.y,
        "the cell quad is glyphless, so the wide pass is the only draw");

    // Narrow text is untouched by any of this — it still bakes into its cell,
    // and a fix that moved every glyph off the cell would be a regression no
    // count of wide glyphs could detect.
    WebTerminal plain(6, 20, 1);
    const char ascii[] = "hi";
    plain.feed(ascii);
    CHECK(plain.buildFrame());
    CHECK_MSG(plain.wideGlyphInstanceCount() == 0, "narrow text produces no wide instances");
    const Ubiquitty::Rendering::CellInstance& narrow = plain.cellInstances()[0];
    CHECK_MSG(narrow.atlasTopLeft.x != narrow.atlasBottomRight.x,
        "and it still carries its glyph on the cell");
}

// Choosing a theme is the reason the palette exists, and the browser's values
// come straight from Core's table — so the list is the same one every frontend
// shows, with no copy here and no round trip to the host.
//
// The assertion is that the RENDERED COLOURS change. A test that checked the
// session's option index would pass against a drill wired to nothing at all,
// which is the shape that has already caught me out twice in this file.
TEST(aThemeChosenInBeamRepaintsTheTerminal)
{
    WebTerminal terminal(6, 20, 1);
    const char text[] = "hello";
    terminal.feed(text);

    const std::vector<std::uint8_t> before = terminal.render();
    CHECK_MSG(!before.empty(), "a frame was rendered");

    CHECK(terminal.toggleBeam());
    for (const char ch : std::string("theme"))
        terminal.feedBeamKey(static_cast<std::uint32_t>(ch), 0, 0, static_cast<std::uint32_t>(ch));

    // Right enters the drill. Its absence is the interesting failure: a command
    // registered as an action rather than a drill still lists and still runs,
    // and only this tells them apart.
    CHECK_MSG(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0), "Right was consumed");
    CHECK_MSG(terminal.isBeamOpen(), "the drill is open, not the palette closed");

    // Walk off the current value so Enter cannot be a no-op, then take it.
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyDown, 0, 0, 0);
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyDown, 0, 0, 0);
    terminal.feedBeamKey(13u, 0, 0, 0); // Enter

    CHECK_MSG(!terminal.isBeamOpen(), "accepting closed the palette");
    CHECK_MSG(terminal.takeBeamCommand()[0] == 0,
        "the theme was applied here rather than handed to the page");

    const std::vector<std::uint8_t> after = terminal.render();
    CHECK_MSG(after.size() == before.size(), "the frame is the same shape");
    CHECK_MSG(after != before, "and its colours changed — the theme reached the palette");
}

// The selection must stay inside the box that is drawn. The layout shows as many
// rows as fit; the session scrolls against a window it is told separately, and
// nothing connects them by construction — so a frontend that never says how many
// rows it drew scrolls against the default, and on a short grid the selection
// walks off the bottom of a list that never moves.
//
// Asserted through the RENDERED FRAME: pressing Down past the last visible row
// must change the picture, because the list has to scroll. Asserting the
// session's selectedIndex would pass against exactly this failure — the index moves
// either way; it is the drawing that does not.
TEST(theSelectionStaysInsideTheDrawnPalette)
{
    // Short enough that the height cap bites and far fewer rows are drawn than
    // there are themes to show.
    WebTerminal terminal(14, 80, 1);
    CHECK(terminal.toggleBeam());
    for (const char ch : std::string("choose theme"))
        terminal.feedBeamKey(static_cast<std::uint32_t>(ch), 0, 0, static_cast<std::uint32_t>(ch));
    CHECK(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0));
    CHECK_MSG(!terminal.beamState().drillTitle.empty(), "the theme drill is open");

    // Render once so the frontend has reported its drawn row count.
    const std::vector<std::uint8_t> atTop = terminal.render();
    const int drawn = terminal.beamRowsDrawn();
    CHECK_MSG(drawn > 0, "the palette drew result rows");
    CHECK_MSG(drawn < static_cast<int>(terminal.beamState().rows.size()),
        "and fewer than there are themes, or this grid proves nothing");

    // Walk to the first row PAST the last visible one. The visible window is
    // 0..drawn-1, so index `drawn` is one beyond it and takes exactly `drawn`
    // presses from the top. The list must scroll, so the picture must change.
    for (int i = 0; i < drawn; ++i)
        terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyDown, 0, 0, 0);
    const std::vector<std::uint8_t> scrolled = terminal.render();

    CHECK_MSG(terminal.beamState().selectedIndex == drawn,
        "the selection moved past the last drawn row");

    // The property: the selection is inside the window that was drawn. Asserted
    // directly rather than through the image — with the failure the picture changes
    // too, because the highlight vanishing off the bottom is also a change, so
    // "the frame differs" passes either way and proves nothing.
    const int top = terminal.beamState().scrollTop;
    const int selected = terminal.beamState().selectedIndex;
    CHECK_MSG(selected >= top && selected < top + drawn,
        "the selected row is one of the rows on screen");
    CHECK_MSG(top > 0, "reached by scrolling, not by the window happening to be large enough");
    CHECK_MSG(scrolled != atTop, "and the frame followed");
}

// The font drill is the frontend supplying the list and Core running the drill.
// Choosing STAGES the family through the same pending-family path OSC 50 uses,
// rather than applying it here: the family lives in the page's rasterizer
// bridge, and two rebuild sequences would have to be kept agreeing.
TEST(aFontChosenInBeamIsStagedForThePage)
{
    WebTerminal terminal(6, 20, 1);
    terminal.setFontOptions({ "JetBrains Mono", "Menlo", "Consolas" }, 0);

    CHECK(terminal.toggleBeam());
    // "choose font" rather than "font": the latter also matches Increase,
    // Decrease and Reset Font Size, so the selected row would be whichever of
    // the four ranked first — a real behaviour, and a test that depends on it
    // asserts the ranker rather than the drill.
    for (const char ch : std::string("choose font"))
        terminal.feedBeamKey(static_cast<std::uint32_t>(ch), 0, 0, static_cast<std::uint32_t>(ch));
    const auto& rows = terminal.beamState().rows;
    CHECK_MSG(!rows.empty() && rows[0].title == "Choose Font", "the font command is the top match");
    CHECK_MSG(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0), "Right entered the drill");
    CHECK_MSG(!terminal.beamState().drillTitle.empty(), "and the drill is open");

    // Off the current value, so accepting cannot pass by being a no-op.
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyDown, 0, 0, 0);
    terminal.feedBeamKey(13u, 0, 0, 0);

    CHECK_MSG(!terminal.isBeamOpen(), "accepting closed the palette");
    CHECK_MSG(terminal.takeBeamCommand()[0] == 0, "and did not hand a command to the page");

    // Staged, and it is one of the families offered rather than whatever the
    // selection index happened to name.
    const std::string staged = terminal.pendingFontFamily();
    CHECK_MSG(!staged.empty(), "a family was staged for the page to apply");
    CHECK_MSG(staged == "Menlo" || staged == "Consolas", "one of the offered families");
    CHECK_MSG(staged != "JetBrains Mono", "and not the one already in effect");
}

// A page that has not said what it can render gets no font command at all. A
// drill with nothing behind it looks like a feature and opens an empty box.
TEST(theFontCommandIsAbsentUntilThePageOffersFamilies)
{
    WebTerminal terminal(6, 20, 1);
    CHECK(terminal.toggleBeam());
    for (const char ch : std::string("font"))
        terminal.feedBeamKey(static_cast<std::uint32_t>(ch), 0, 0, static_cast<std::uint32_t>(ch));

    bool sawFontRow = false;
    for (const auto& row : terminal.beamState().rows)
        if (row.title == "Choose Font")
            sawFontRow = true;
    CHECK_MSG(!sawFontRow, "no font command without a list behind it");

    // And the theme command is still there, so this is the font row missing
    // rather than the query matching nothing.
    WebTerminal withThemes(6, 20, 1);
    withThemes.toggleBeam();
    for (const char ch : std::string("theme"))
        withThemes.feedBeamKey(static_cast<std::uint32_t>(ch), 0, 0, static_cast<std::uint32_t>(ch));
    CHECK_MSG(!withThemes.beamState().rows.empty(), "the palette still lists commands");
}

// A theme is restored by NAME across a reload, and an unknown name changes
// nothing.
//
// Reported as "when I reload I see the same content but the theme resets": the
// session id is persisted so the shell comes back, and the theme was not
// persisted at all, so the colours did not.
//
// By name and not by index. An index is a position in Core's table, so adding or
// reordering a theme would make a stored index name a DIFFERENT one — silently,
// and only for people who had already chosen.
TEST(aThemeIsRestoredByNameAndAnUnknownNameChangesNothing)
{
    const auto background = [](WebTerminal& terminal) {
        const std::vector<std::uint8_t> image = terminal.render();
        const std::size_t last = image.size() - 4;
        return (static_cast<int>(image[last]) << 16) | (static_cast<int>(image[last + 1]) << 8)
            | static_cast<int>(image[last + 2]);
    };

    // Choose one, and read back the name the page would store.
    int chosen = 0;
    std::string storedName;
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        CHECK_MSG(std::string(terminal.currentThemeName()).empty(), "nothing chosen yet");
        (void)terminal.toggleBeam();
        for (const char* p = "gruvbox"; *p; ++p)
            (void)terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
        (void)terminal.feedBeamKey(13u, 0, 0, 0);
        chosen = background(terminal);
        storedName = terminal.currentThemeName();
        CHECK_MSG(!storedName.empty(), "the page has a name to store");
    }

    // A fresh terminal is the reload. Restoring by that name reproduces the
    // colours exactly.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        CHECK_MSG(background(terminal) != chosen, "a fresh terminal starts on the host default");
        CHECK_MSG(terminal.setThemeByName(storedName.c_str()), "the stored name is known");
        CHECK_MSG(background(terminal) == chosen, "and reproduces the chosen colours");
    }

    // A name Core no longer knows leaves the palette ALONE rather than falling
    // back to a default the user never picked.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        CHECK(terminal.setThemeByName(storedName.c_str()));
        const int themed = background(terminal);
        CHECK_MSG(!terminal.setThemeByName("A Theme That Was Deleted"), "an unknown name is refused");
        CHECK_MSG(background(terminal) == themed, "and changes nothing");
        CHECK_MSG(std::string(terminal.currentThemeName()) == storedName, "leaving the previous choice in place");
    }
}

TEST(aThemeChangeInvalidatesTheCachedGPUFramePalette)
{
    WebTerminal terminal(4, 20, 1);
    terminal.feed("\033[34mB");
    CHECK(terminal.buildFrame());

    // Prime the capture before changing theme: the CPU raster reads the live
    // palette, while subsequent GPU frames may reuse the captured palette.
    CHECK(terminal.setThemeByName("Noir"));
    CHECK(terminal.buildFrame());
    const auto& cell = terminal.cellInstances()[0];
    using Ubiquitty::Rendering::channelToByte;
    CHECK_EQ(channelToByte(cell.foreground.x), 114);
    CHECK_EQ(channelToByte(cell.foreground.y), 163);
    CHECK_EQ(channelToByte(cell.foreground.z), 232);
    CHECK_EQ(channelToByte(cell.background.x), 21);
    CHECK_EQ(channelToByte(cell.background.y), 23);
    CHECK_EQ(channelToByte(cell.background.z), 28);
}

// A chosen theme survives the host's checkpoints.
//
// A checkpoint carries the host's palette and replaces the client's, so a theme
// picked here that the checkpoint overrides lasts only until the next one — and
// checkpoints arrive on every reconnect and every resync, so it reverts within
// seconds and looks as though it had never applied at all.
//
// Asserted on the RENDERED BACKGROUND rather than on a stored index: an index
// that survives while the palette does not is exactly the failure.
TEST(aChosenThemeSurvivesAHostCheckpoint)
{
    const auto background = [](WebTerminal& terminal) {
        const std::vector<std::uint8_t> image = terminal.render();
        const std::size_t last = image.size() - 4; // bottom-right: always background
        return (static_cast<int>(image[last]) << 16) | (static_cast<int>(image[last + 1]) << 8)
            | static_cast<int>(image[last + 2]);
    };
    // A fresh connection each time, so each delivery is a whole checkpoint.
    std::uint32_t nextSession = 1;
    const auto feedCheckpoint = [&nextSession](WebTerminal& terminal) {
        PageHost host(nextSession++);
        return feedWire(terminal, host.answer(terminal.buildHello("t", 0)));
    };

    WebTerminal terminal(24, 80, 1);
    terminal.feed("hello");
    const int hostDefault = background(terminal);

    (void)terminal.toggleBeam();
    for (const char* p = "gruvbox"; *p; ++p)
        (void)terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
    (void)terminal.feedBeamKey(13u, 0, 0, 0);
    const int chosen = background(terminal);
    CHECK_MSG(chosen != hostDefault, "choosing a theme changed the background at all");

    CHECK(feedCheckpoint(terminal));
    CHECK_MSG(background(terminal) == chosen, "and the host's checkpoint did not undo it");

    // A second checkpoint, because the reassert must be per-checkpoint and not a
    // one-shot that happens to cover the first.
    CHECK(feedCheckpoint(terminal));
    CHECK_MSG(background(terminal) == chosen, "nor the one after that");

    // A client that chose nothing still takes the host's palette. Reasserting
    // unconditionally would pin every client to whatever it booted with.
    WebTerminal untouched(24, 80, 1);
    untouched.feed("hello");
    const int before = background(untouched);
    CHECK(feedCheckpoint(untouched));
    CHECK_MSG(background(untouched) == before, "an unthemed client follows the host");
}

// Copying a line that wrapped must give back the line, not the rows.
//
// This is the most consequential copy behaviour there is: a spurious newline in
// the middle of a wrapped command means the shell runs half of it the moment it
// is pasted. The header promises it — "rows join with a newline except across a
// soft wrap" — and nothing checked it.
//
// The discriminating pair is soft against HARD. A test that only asserted "no
// newlines" would pass against an implementation that dropped every newline,
// including the ones the user typed.
TEST(aWrappedLineCopiesBackAsOneLine)
{
    const int columns = 20;

    // Soft wrap: one logical line, longer than the grid, no CR/LF anywhere.
    {
        WebTerminal terminal(6, columns, 1);
        const std::string typed = "echo aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd";
        CHECK_MSG(static_cast<int>(typed.size()) > columns * 2, "the line must wrap at least twice");
        terminal.feed(typed);

        terminal.selectAll();
        const std::string copied = terminal.selectionText();
        const std::string firstLine = copied.substr(0, copied.find('\n'));
        CHECK_MSG(firstLine == typed, "a soft-wrapped line copies back whole, with no newline where it wrapped");
    }

    // Hard newline: two logical lines. These must stay two.
    {
        WebTerminal terminal(6, columns, 1);
        const char typed[] = "first\r\nsecond";
        terminal.feed(typed);

        terminal.selectAll();
        const std::string copied = terminal.selectionText();
        const std::size_t brk = copied.find('\n');
        CHECK_MSG(brk != std::string::npos, "a typed newline survives the copy");
        CHECK_MSG(copied.substr(0, brk) == "first", "and splits where it was typed");
        CHECK_MSG(copied.substr(brk + 1, 6) == "second", "with the second line after it");
    }
}

// Three ways a person looks for a theme — the queries a person types rather
// than the ones an implementer imagines — and what each needs:
//
//   "noir"          a theme NAME — finds nothing unless values are searchable
//   "Select Theme"  the command by another name — finds nothing without keywords
//   Enter on it     opens the drill command, rather than running it to no
//                   effect and closing Beam
TEST(theQueriesAUserActuallyTypesFindTheTheme)
{
    const auto rowsFor = [](WebTerminal& terminal, const char* query) {
        terminal.toggleBeam();
        for (const char* p = query; *p; ++p)
            terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
        return terminal.beamState().rows;
    };
    const auto contains = [](const std::vector<Ubiquitty::CommandPalette::BeamRow>& rows, const char* title) {
        for (const auto& row : rows)
            if (row.title == title)
                return true;
        return false;
    };

    // A theme name finds the theme, with the owning command named beside it so a
    // bare "Noir" is not a row whose effect has to be guessed.
    {
        WebTerminal terminal(24, 80, 1);
        const auto rows = rowsFor(terminal, "noir");
        CHECK_MSG(contains(rows, "Noir"), "typing a theme name finds that theme");
        for (const auto& row : rows)
            if (row.title == "Noir")
                CHECK_MSG(row.detail == "Choose Theme", "and says what it belongs to");
    }

    // The command answers a word that is not in its title.
    {
        WebTerminal terminal(24, 80, 1);
        CHECK_MSG(contains(rowsFor(terminal, "select theme"), "Choose Theme"), "\"select theme\" finds it");
    }
    {
        WebTerminal terminal(24, 80, 1);
        CHECK_MSG(contains(rowsFor(terminal, "color"), "Choose Theme"), "so does \"color\"");
    }

    // Enter on the drill command OPENS it. Running a command with no effect and
    // closing the palette reads as the whole feature being dead.
    {
        WebTerminal terminal(24, 80, 1);
        const auto rows = rowsFor(terminal, "choose theme");
        CHECK_MSG(!rows.empty() && rows[0].title == "Choose Theme", "the command is the top match");
        CHECK(terminal.feedBeamKey(13u, 0, 0, 0)); // Enter
        CHECK_MSG(terminal.isBeamOpen(), "Enter did not close the palette");
        CHECK_MSG(!terminal.beamState().drillTitle.empty(), "it opened the value list");
    }

    // Accepting a value row applies the theme, with no drill involved. The frame
    // has to CHANGE — an option index alone would pass against a row wired to
    // nothing.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        const std::vector<std::uint8_t> before = terminal.render();
        const auto rows = rowsFor(terminal, "gruvbox");
        CHECK_MSG(!rows.empty(), "a theme name matched");
        CHECK(terminal.feedBeamKey(13u, 0, 0, 0));
        CHECK_MSG(!terminal.isBeamOpen(), "accepting a value closes");
        CHECK_MSG(terminal.render() != before, "and the colours changed");
    }
}

// Kitty key-release events. The page reports press/release/repeat and Core
// decides whether any bytes follow — reportsNonPressEvent wants REPORT_EVENTS on
// and an escape-code channel for the key.
//
// The frontend half is that the event type CROSSES at all. It did not: the web
// encoder hardcoded Press, so a release could not be expressed however the mode
// was set, and every kitty client asking for key-up got silence that looked
// exactly like a correctly-suppressed release.
TEST(aKeyReleaseCrossesTheWebABIAndCoreDecidesTheBytes)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;

    // Mode off: the semantic release still reaches its owner, but the
    // program receives no bytes. The client cannot gate on replica modes.
    const std::vector<std::uint8_t>& quiet
        = terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release);
    CHECK_MSG(!quiet.empty(), "a release is admitted without consulting the replica's flags");
    CHECK_MSG(page.programReads(quiet).empty(), "the host suppresses release bytes while REPORT_EVENTS is off");

    // CSI > 1 u — kitty disambiguate + report-events (flags 1|2 = 3).
    const char enable[] = "\033[>3u";
    page.programPrints(enable);

    const std::vector<std::uint8_t>& release
        = terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release);
    CHECK_MSG(!release.empty(), "with the mode on, a release reaches the wire");

    // Kitty encodes the event type as the third sub-parameter of the second
    // parameter: ":3" is release. Asserted on the BYTES, because a release that
    // encoded as a press would also be a non-empty frame.
    const std::string bytes = page.programReads(release);
    CHECK_MSG(bytes.find(":3") != std::string::npos, "and says it is a release");

    // A press through the same path is not marked as one, so the distinction is
    // carried rather than stamped on everything.
    const std::vector<std::uint8_t>& press
        = terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Press);
    const std::string pressBytes = page.programReads(press);
    CHECK_MSG(!pressBytes.empty(), "a press still encodes");
    CHECK_MSG(pressBytes.find(":3") == std::string::npos, "and is not labelled a release");
}

TEST(aWebReleaseReachesTheHostBeforeItsReportEventsModeReachesTheReplica)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    AttachedPage page;
    // No settle: only the host has seen the mode, just as when a screen
    // update is delayed behind a keystroke in the other direction.
    Ubiquitty::processBytes(&page.host.terminal(), "\x1b[>3u");
    REQUIRE(Ubiquitty::Kitty::KeyFlagSet::fromRaw(page.host.terminal().kittyKeyboardFlags[0]).contains(Ubiquitty::Kitty::KeyFlag::ReportEvents));
    const auto before = page.host.typed().events().size();
    const auto& frame = page.terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release);
    REQUIRE(!frame.empty());
    const auto bytes = page.programReads(frame);
    CHECK(bytes.find(":3") != std::string::npos);
    REQUIRE(page.host.typed().events().size() == before + 1);
    const auto* keys = std::get_if<Sync::KeyInput>(&page.host.typed().events().back());
    REQUIRE(keys);
    REQUIRE(keys->events.size() == 1);
    CHECK(keys->events.front().kind == Sync::KeyEventKind::Release);
}

TEST(aWebReleaseUsesTheHostsDisabledModeWhileItsReplicaStillReportsEvents)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    AttachedPage page;
    page.programPrints("\x1b[>3u");
    // Both saw the enable; only the host sees the pop. Transport still
    // carries one semantic release, never bytes encoded from stale flags.
    Ubiquitty::processBytes(&page.host.terminal(), "\x1b[<u");
    REQUIRE(!Ubiquitty::Kitty::KeyFlagSet::fromRaw(page.host.terminal().kittyKeyboardFlags[0]).contains(Ubiquitty::Kitty::KeyFlag::ReportEvents));
    const auto before = page.host.typed().events().size();
    const auto& frame = page.terminal.buildKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release);
    REQUIRE(!frame.empty());
    CHECK(page.programReads(frame).empty());
    REQUIRE(page.host.typed().events().size() == before + 1);
    const auto* keys = std::get_if<Sync::KeyInput>(&page.host.typed().events().back());
    REQUIRE(keys);
    REQUIRE(keys->events.size() == 1);
    CHECK(keys->events.front().kind == Sync::KeyEventKind::Release);
}

TEST(aStandaloneWebReleaseStillUsesItsLocalKeyboardModes)
{
    WebTerminal terminal(4, 20, 1);
    CHECK(!terminal.feedKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release));
    terminal.feed("\x1b[>3u");
    CHECK(terminal.feedKey(Ubiquitty::Keys::Keymap::keymapKeyLeft, 0, 0, 0, Ubiquitty::Keys::KeyEventType::Release));
}

// DECSET 7403, relative pointer lock — the mode a mouselook client turns on.
//
// Core encodes the delta and applies the 0x8000 bias; the frontend's whole job
// is to notice the mode, hold the pointer, and pass the raw signed delta. This
// pins the frontend half: that the mode is visible at all, and that a motion
// report in that mode carries the DELTA rather than a cell position.
//
// The browser is named in Core's own comment as having leaked motion into
// 1000-only sessions before the encoder took the rule, so the negative — that
// nothing is reported when the mode is off and no tracking is on — is the half
// worth keeping.
TEST(pointerLockIsVisibleAndReportsDeltas)
{
    AttachedPage page;
    WebTerminal& terminal = page.terminal;
    CHECK_MSG(!terminal.pointerLockActive(), "off until a program asks");

    // Motion with no tracking mode reports nothing at all.
    Ubiquitty::Input::PointerFact still = fact(Ubiquitty::Input::PointerFact::Kind::Motion, Ubiquitty::Input::PointerButton::None, 3, 5, 1);
    still.pixelX = 40;
    still.pixelY = 60;
    const std::vector<std::uint8_t>& idle = terminal.pointer(still);
    CHECK_MSG(idle.empty(), "no tracking mode, no report");

    // ?1016 (SGR-pixels) + ?7403.
    const char enable[] = "\033[?1016h\033[?7403h";
    page.programPrints(enable);
    CHECK_MSG(terminal.pointerLockActive(), "the page can see the mode");

    // A signed delta, exactly what event.movementX/movementY gives under the
    // Pointer Lock API. Core biases by 0x8000, so -5 must appear as 32763 and
    // +7 as 32775 — asserted as the NUMBERS, because a report that echoed the
    // cell position would also be a well-formed SGR frame.
    Ubiquitty::Input::PointerFact motion = still;
    motion.deltaX = -5;
    motion.deltaY = 7;
    const std::vector<std::uint8_t>& moved = terminal.pointer(motion);
    CHECK_MSG(!moved.empty(), "locked motion is reported even with no tracking mode set");
    const std::string report = page.programReads(moved);
    CHECK_MSG(report.find("32763") != std::string::npos, "the negative delta arrives biased, not clamped away");
    CHECK_MSG(report.find("32775") != std::string::npos, "and the positive one");
    CHECK_MSG(report.find(";5;") == std::string::npos && report.find(";3;") == std::string::npos,
        "and it is a delta report, not the cell position");

    // Releasing the mode releases the page's lock with it.
    const char disable[] = "\033[?7403l";
    page.programPrints(disable);
    CHECK_MSG(!terminal.pointerLockActive(), "and the page lets the pointer go");
}

// [appearance] beam_surface decides whose palette opens, and the half that can
// go wrong quietly is the suppression: a frontend drawing its own palette must
// not also get the in-grid one composited underneath it.
//
// The browser has no native palette, so the availability is a setter — without
// it this path would be unreachable and the setting would be untested until
// macOS wired in, which is when it would be expensive to be wrong.
TEST(testBeamSurfaceDecidesWhoDrawsThePalette)
{
    // Native available and native asked for: the frontend draws it, so nothing
    // reaches the grid. The session still opens — the setting picks the surface,
    // not whether the palette exists.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        terminal.setNativeBeam(Ubiquitty::Preferences::NativeBeam::Available);
        terminal.setBeamSurface(Ubiquitty::Preferences::BeamSurface::Native);

        const std::vector<std::uint8_t> plainImage = terminal.render();
        CHECK(terminal.toggleBeam());
        CHECK_MSG(terminal.isBeamOpen(), "the session opens whoever draws it");
        CHECK_MSG(terminal.render() == plainImage, "nothing was composited into the grid");
    }

    // The same build with "in-terminal" draws in the grid, which is the user's
    // override and the reason the setting is not just an availability probe.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        terminal.setNativeBeam(Ubiquitty::Preferences::NativeBeam::Available);
        terminal.setBeamSurface(Ubiquitty::Preferences::BeamSurface::InTerminal);

        const std::vector<std::uint8_t> plainImage = terminal.render();
        CHECK(terminal.toggleBeam());
        CHECK_MSG(terminal.render() != plainImage, "in-terminal draws in the grid on a native-capable build");
    }

    // And with no native palette, "native" still opens something. A keystroke
    // that silently does nothing reads as a broken binding, not as a setting.
    {
        WebTerminal terminal(24, 80, 1);
        terminal.feed("hello");
        terminal.setBeamSurface(Ubiquitty::Preferences::BeamSurface::Native);

        const std::vector<std::uint8_t> plainImage = terminal.render();
        CHECK(terminal.toggleBeam());
        CHECK_MSG(terminal.render() != plainImage, "a native request falls back rather than opening nothing");
    }
}

// An open palette owns the keys it needs and no others. The passthrough half is
// what stops an open Beam from making the terminal look hung.
TEST(testBeamOwnsOnlyTheKeysItNeeds)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(!terminal.feedBeamKey('a', 0, 0, 'a'), "a closed palette consumes nothing");

    terminal.toggleBeam();
    CHECK_MSG(terminal.feedBeamKey('c', 0, 0, 'c'), "an open one takes ordinary typing");
    CHECK_MSG(!terminal.feedBeamKey('t', 0, Ubiquitty::Keys::Keymap::keymapModifierSuper, 't'),
        "but not a Super-modified key, which is the frontend's own binding");

    // Escape closes, and the palette stops consuming immediately afterwards.
    CHECK(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0, 0));
    CHECK(!terminal.isBeamOpen());
    CHECK_MSG(!terminal.feedBeamKey('a', 0, 0, 'a'), "and a closed palette consumes nothing again");
}

// The window padding: Core parses `[appearance] padding` and macOS and GTK
// both consume it, so the page must too. A page that divides its own viewport
// by its own cell with no inset in the arithmetic leaves a visible margin that
// is whatever rounding the window down to whole cells leaves over — it moves
// with the window and nothing can set it.
//
// The failure to guard against is quiet in both directions: a padding that is
// stored but not subtracted gives a grid too wide for its window, and one
// subtracted in the wrong unit is right at scale 1 and half-size on a retina
// display. Both draw a terminal that looks plausible.
TEST(theBrowserHonoursTheWindowPaddingItIsGiven)
{
    WebTerminal terminal(24, 80, 1);

    // Core's default rather than zero — the browser is not a frontend with its
    // own idea of the inset.
    CHECK_MSG(terminal.padding() == Ubiquitty::Preferences::Defaults::padding,
        "the browser starts at the padding every other frontend starts at");

    const int cellWidth = terminal.cellWidth();
    const int cellHeight = terminal.cellHeight();
    CHECK_MSG(cellWidth > 0 && cellHeight > 0, "the cell is measurable");

    // Zero padding is the control: the grid is the plain division, so anything
    // the inset later removes is attributable to the inset.
    terminal.setPadding(0.0);
    const auto bare = terminal.gridForViewport(cellWidth * 100.0, cellHeight * 40.0, 1.0);
    CHECK_EQ(bare.columns, 100);
    CHECK_EQ(bare.rows, 40);

    // Two whole cells of padding on each axis removes exactly two columns and
    // two rows — the number, not merely "fewer". A test asserting only that the
    // grid shrank passes on an inset applied once instead of to both edges.
    terminal.setPadding(cellWidth);
    const auto insetHorizontally = terminal.gridForViewport(cellWidth * 100.0, cellHeight * 40.0, 1.0);
    CHECK_EQ(insetHorizontally.columns, 98);

    terminal.setPadding(cellHeight);
    const auto insetVertically = terminal.gridForViewport(cellWidth * 100.0, cellHeight * 40.0, 1.0);
    CHECK_EQ(insetVertically.rows, 38);

    // The scale is what a padding stated in CSS pixels needs to reach a viewport
    // measured in device pixels. At scale 2 the same setting removes twice the
    // device pixels, so a retina window loses the same VISIBLE margin rather
    // than half of one.
    terminal.setPadding(cellWidth);
    const auto retina = terminal.gridForViewport(cellWidth * 200.0, cellHeight * 80.0, 2.0);
    CHECK_MSG(retina.columns == 196, "the inset scales with the display, not with the pixel count");

    // The grid plus both insets fits inside the window it was fitted to. Every
    // assertion above holds for a grid shrunk by one inset and drawn against
    // two, which is a terminal whose right edge sits under the window's — and
    // the page, which draws the canvas at the inset this arithmetic assumed,
    // cannot notice.
    //
    // Swept rather than sampled: the interesting sizes are the ones where the
    // division has a remainder, and a single window either has one or does not.
    for (double width = 200.0; width <= 1600.0; width += 37.0) {
        for (const double scale : { 1.0, 2.0 }) {
            terminal.setPadding(7.0);
            const auto fitted = terminal.gridForViewport(width, width, scale);
            if (fitted.columns == WebTerminal::minColumns)
                continue; // floored rather than fitted; the sliver case is its own test
            const double used = fitted.columns * static_cast<double>(cellWidth) + 2.0 * 7.0 * scale;
            CHECK_MSG(used <= width, "the fitted grid and both insets fit the window they were fitted to");
        }
    }
}

TEST(theBrowserRefusesAPaddingItsOwnSchemaWouldRefuse)
{
    WebTerminal terminal(24, 80, 1);

    // The bounds are Core's `[appearance] padding` row, so the palette cannot
    // set a value a config file would be clamped out of. Both ends, because a
    // clamp written once and applied to one is the shape that half-ships.
    terminal.setPadding(-40.0);
    CHECK_MSG(terminal.padding() == 0.0, "a negative inset floors at zero rather than growing the grid");
    terminal.setPadding(4000.0);
    CHECK_MSG(terminal.padding() == 64.0, "and a huge one stops at the schema's ceiling");

    // A window smaller than its own padding still yields a grid a shell can draw
    // in. The arithmetic alone gives zero or a negative here, and a terminal of
    // zero rows is one nothing recovers from.
    const auto sliver = terminal.gridForViewport(10.0, 10.0, 1.0);
    CHECK_MSG(sliver.columns >= WebTerminal::minColumns, "a sliver of a window keeps a usable width");
    CHECK_MSG(sliver.rows >= WebTerminal::minRows, "and a usable height");
}

// The palette's entry for it. `beam.padding` is the first `DrillNumber` any
// frontend registers, so this is also the first time the editor is reached
// through a real command rather than a session built by hand.
TEST(beamEditsTheWindowPaddingAsANumber)
{
    WebTerminal terminal(24, 80, 1);
    terminal.toggleBeam();
    for (const char* p = "padding"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));

    const auto& rows = terminal.beamState().rows;
    CHECK_MSG(!rows.empty() && rows[0].title == "Window Padding", "the command is the top match");
    CHECK_MSG(rows[0].hasChildren, "and offers the drill affordance, so the row does not read as an action");

    CHECK(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0));
    CHECK_MSG(terminal.beamState().isValueEditor, "Right opened the value editor");
    CHECK_MSG(terminal.beamState().query == "6", "on the live value rather than an empty field");
    CHECK_MSG(terminal.beamState().status == "0–64 pt", "with the schema's own range under it");

    // Two steps up, then commit. The assertion is on the TERMINAL, not on the
    // field: a palette that edits its own text and applies nothing is exactly
    // what a value editor looks like from the outside.
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyUp, 0, 0, 0);
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyUp, 0, 0, 0);
    CHECK(terminal.feedBeamKey(13u, 0, 0, 0));
    CHECK_MSG(!terminal.isBeamOpen(), "applying a value closes, as running a command does");
    CHECK_MSG(terminal.padding() == 8.0, "and the terminal holds what was committed");

    // The page is told, because the window geometry that follows is the page's
    // to change. Applied-and-silent would leave the canvas at its old inset with
    // the grid fitted to the new one.
    CHECK_STR_EQ(terminal.takeBeamCommand(), "beam.padding");
}

// The colour behind the padding. The page carried Core's default as a literal in
// its stylesheet, which agrees until the first theme is applied and then frames
// the new theme's grid in the old theme's background.
TEST(theBackgroundBehindThePaddingFollowsTheTheme)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.backgroundColor() == 0x101014,
        "the neutral dark Core seeds, narrowed to the eight bits CSS takes");

    terminal.toggleBeam();
    for (const char* p = "gruvbox"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
    CHECK(terminal.feedBeamKey(13u, 0, 0, 0));
    CHECK_MSG(terminal.backgroundColor() != 0x101014, "a theme moves it");
}

// --- The host's sessions ------------------------------------------------------
//
// The flat sidebar and outline consume one typed subscription.
struct DirectoryPageHost {
    PageHost host { 4 };
    std::vector<std::unique_ptr<UbiquittyTest::HostedPane>> panes;
    bool isAttached = false;
    std::uint32_t latestRequest = 0;
    std::map<std::uint32_t, std::uint32_t> calls;

    /// Establishes the real screen plane without requesting a directory.
    /// - Parameter page: The frontend under test.
    void attach(WebTerminal& page)
    {
        if (!isAttached) {
            CHECK(feedWire(page, host.answer(page.buildHello("t", 4))));
            CHECK(feedWire(page, host.exchange(page)));
            isAttached = true;
        }
    }

    /// Records one typed list request on the authenticated plane.
    /// - Parameter page: The frontend under test.
    /// - Returns: The unique suffix of its JSON call id.
    std::uint32_t request(WebTerminal& page)
    {
        attach(page);
        const auto bytes = page.buildListSessions();
        CHECK(!bytes.empty());
        CHECK_EQ(bytes.front(), std::to_underlying(Ubiquitty::Protocol::Sync::FrameKind::Call));
        host.receive(bytes);
        const auto received = host.connection().takeCalls();
        CHECK_EQ(received.size(), 1u);
        if (received.empty())
            return 0;
        bool isJSON = false;
        const auto call = Ubiquitty::Codec::JSON::parse(received.front().text, isJSON);
        CHECK(isJSON && call.stringOr("method") == "host.sessions.subscribe");
        const std::string id = call.stringOr("id");
        constexpr std::string_view prefix = "ubiquitty.host-listing.";
        CHECK(id.starts_with(prefix));
        latestRequest = static_cast<std::uint32_t>(std::strtoul(id.c_str() + prefix.size(), nullptr, 10));
        calls[latestRequest] = received.front().callIndex;
        return latestRequest;
    }
};

// What a fixture host holds of one session: a workspace of one pane, stated as
// a host states it. Every field distinct so a wrong one is not read as a right
// one.
struct ListedSession {
    std::uint32_t id = 0;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    std::uint8_t flags = 0;
    std::string title;
    std::string currentDirectory;
    std::string foregroundProcess;
    std::uint32_t workspaceID = 0;
    std::string workspaceName;
    std::uint8_t attendeeCount = 0;
    std::uint8_t humanAttendeeCount = 0;
};

/// The facts a listed session's flags carry.
constexpr std::uint8_t listedAtPrompt = 0x01;
constexpr std::uint8_t listedEndsWhenDetached = 0x02;

ListedSession listedSession(std::uint32_t id, const char* title, const char* directory, const char* foreground, std::uint8_t flags)
{
    ListedSession info {};
    info.id = id;
    info.columns = 120;
    info.rows = 40;
    info.flags = flags;
    info.title = title;
    info.currentDirectory = directory;
    info.foregroundProcess = foreground;
    return info;
}

// The same, with a workspace name and an attendee summary. Every field distinct
// from the plain helper's, so a field read at the wrong offset is not read as
// the right one.
ListedSession namedListedSession(std::uint32_t id, std::uint32_t workspaceID, const char* workspaceName,
    std::uint8_t attendees, std::uint8_t people, std::uint8_t flags)
{
    ListedSession info {};
    info.id = id;
    info.columns = 100;
    info.rows = 30;
    info.flags = flags;
    info.title = "titled";
    info.currentDirectory = "/named";
    info.foregroundProcess = "vim";
    info.workspaceID = workspaceID;
    info.workspaceName = workspaceName;
    info.attendeeCount = attendees;
    info.humanAttendeeCount = people;
    return info;
}

// Sends actual typed structures/facts and a correlated completion promise.
// An old request's late result does not announce a new topology.
bool feedSessionList(WebTerminal& terminal, DirectoryPageHost& fixture, std::uint32_t requestID, const std::vector<ListedSession>& sessions)
{
    namespace Session = Ubiquitty::Session;
    namespace Sync = Ubiquitty::Protocol::Sync;
    using Ubiquitty::Codec::JSON::Value;
    Value result = Value::object();
    Value workspaces = Value::array();
    Value revisions = Value::array();
    Value facts = Value::array();
    if (requestID == fixture.latestRequest && requestID != 0) {
        for (const auto& row : sessions) {
            auto pane = std::make_unique<UbiquittyTest::HostedPane>(row.id, row.title, row.foregroundProcess);
            pane->stated.title.currentDirectory = row.currentDirectory;
            pane->stated.title.rows = row.rows;
            pane->stated.title.columns = row.columns;
            pane->stated.status.isAtPrompt = (row.flags & listedAtPrompt) != 0;
            pane->restate();
            Session::TreeWorkspace workspace;
            workspace.id = row.workspaceID ? row.workspaceID : row.id;
            workspace.name = row.workspaceName;
            workspace.revision = 1;
            workspace.endsWhenDetached = (row.flags & listedEndsWhenDetached) != 0;
            Session::TreeWindow window;
            window.id = Session::Layout::SurfaceID { row.id };
            Session::TreeTab tab;
            tab.id = Session::Layout::TabID { row.id };
            tab.split.paneID = pane->stated.paneID;
            tab.split.rows = row.rows;
            tab.split.columns = row.columns;
            tab.split.structuralGeneration = 1;
            Session::TreePane leaf;
            leaf.id = Session::Layout::PaneID { row.id };
            leaf.sessionID = row.id;
            for (unsigned index = 0; index < row.attendeeCount; ++index)
                leaf.attendees.push_back({ index + 1, index < row.humanAttendeeCount ? Session::TreeAttendeeKind::Person : Session::TreeAttendeeKind::Agent });
            tab.panes.push_back(std::move(leaf));
            window.tabs.push_back(std::move(tab));
            workspace.windows.push_back(std::move(window));
            auto record = std::make_shared<std::vector<std::uint8_t>>();
            CHECK(Session::encodeWorkspaceStructure(*record, workspace));
            fixture.host.connection().offerWorkspaceStructure(workspace.id, 1, record);
            CHECK(fixture.host.connection().listPane(*pane->source, Sync::ListedDetail::Whole) != 0);
            workspaces.push(Value::number(workspace.id));
            revisions.push(Value::string("1"));
            Value expected = Value::object();
            expected.set("session", Value::number(row.id));
            expected.set("revision", Value::number(pane->source->facts().revision));
            facts.push(std::move(expected));
            fixture.panes.push_back(std::move(pane));
        }
    }
    result.set("workspaces", std::move(workspaces));
    result.set("structureRevisions", std::move(revisions));
    result.set("paneRevisions", std::move(facts));
    result.set("panes", Value::number(sessions.size()));
    result.set("hostNowUnixMilliseconds", Value::number(5000000));
    Value answer = Value::object();
    answer.set("jsonrpc", Value::string("2.0"));
    answer.set("id", Value::string("ubiquitty.host-listing." + std::to_string(requestID)));
    answer.set("result", std::move(result));
    const std::string encoded = Ubiquitty::Codec::JSON::serialize(answer);
    const auto call = fixture.calls.find(requestID);
    if (call == fixture.calls.end()) {
        std::vector<std::uint8_t> body;
        Sync::encode(body, Sync::Result { .transfer = 0, .text = encoded });
        std::vector<std::uint8_t> inner;
        CHECK(Sync::appendFrame(inner, Sync::FrameKind::Result, 0, body));
        std::vector<std::uint8_t> wire;
        wire.insert(wire.end(), inner.begin(), inner.end());
        return feedWire(terminal, wire);
    }
    CHECK(fixture.host.connection().answerCall(call->second, encoded) == Sync::CallAnswer::Sent);
    for (int round = 0; round < 8; ++round) {
        if (!feedWire(terminal, fixture.host.exchange(terminal)))
            return false;
    }
    return true;
}

// A terminal past its handshake, which is the state every case below starts a
// terminate from.
void handshakeWithHost(WebTerminal& terminal, std::uint32_t sessionID)
{
    PageHost host(sessionID);
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", sessionID))));
    for (int round = 0; round < 3; ++round)
        CHECK(feedWire(terminal, host.exchange(terminal)));
}

// The requestID is the only thing tying a reply to an ask. A builder that reused
// one would make every reply look current, which is the failure the mismatch
// test below cannot catch on its own.
/// Builds the revision promise for the held workspace's exact current records.
/// - Parameters:
///   - call: The request being answered.
///   - held: The advertised workspace.
/// - Returns: The typed JSON result.
std::string listingReply(const Ubiquitty::Protocol::Sync::ReceivedCall& call, const UbiquittyTest::HeldWorkspace& held)
{
    using Ubiquitty::Codec::JSON::Value;
    bool isJSON = false;
    const Value request = Ubiquitty::Codec::JSON::parse(call.text, isJSON);
    CHECK(isJSON);
    Value result = Value::object();
    Value workspaces = Value::array();
    workspaces.push(Value::number(UbiquittyTest::HeldWorkspace::workspaceID));
    result.set("workspaces", std::move(workspaces));
    Value revisions = Value::array();
    revisions.push(Value::string("1"));
    result.set("structureRevisions", std::move(revisions));
    Value facts = Value::array();
    for (const auto& [id, pane] : held.panes) {
        Value expected = Value::object();
        expected.set("session", Value::number(pane.stated.sessionID));
        expected.set("revision", Value::number(pane.source->facts().revision));
        facts.push(std::move(expected));
    }
    result.set("paneRevisions", std::move(facts));
    result.set("panes", Value::number(held.panes.size()));
    result.set("hostNowUnixMilliseconds", Value::number(5000000));
    Value answer = Value::object();
    answer.set("jsonrpc", Value::string("2.0"));
    answer.set("id", Value::string(request.stringOr("id")));
    answer.set("result", std::move(result));
    return Ubiquitty::Codec::JSON::serialize(answer);
}

TEST(eachSessionListAskCarriesItsOwnRequestID)
{
    WebTerminal terminal(24, 80, 1);
    DirectoryPageHost directory;
    const std::uint32_t first = directory.request(terminal);
    const std::uint32_t second = directory.request(terminal);
    CHECK_MSG(first != 0, "0 marks a reply to nothing, so it is never an outstanding id");
    CHECK_MSG(second != first, "a second ask is a distinct request, or a stale reply answers it");
}

// A page that subscribes is sent its host's structures and records on the
// connection it already has, and reads the rows Core decided from them. It
// chooses only which rows are closed and what is searched for.
TEST(aPageSubscribesToItsHostsListingAndReadsTheOutline)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    const auto outlineOf = [](WebTerminal& page, const char* query) {
        bool isJSON = false; // bool-ok: the parser's out flag
        JSON::Value parsed = JSON::parse(page.hostOutlineJSON(query), isJSON);
        CHECK(isJSON);
        return parsed;
    };
    const auto rowsOf = [](const JSON::Value& outline) {
        const JSON::Value* rows = outline.find("rows");
        return rows ? rows->items() : std::vector<JSON::Value> {};
    };

    WebTerminal page(24, 80, 1);
    // No host has welcomed the page: there is nobody to call, and the
    // outline is one of no rows.
    CHECK(!page.subscribeHostListing());
    CHECK_EQ(static_cast<int>(page.hostOutlineGeneration()), 0);
    CHECK(rowsOf(outlineOf(page, "")).empty());
    CHECK(rowsOf(outlineOf(page, nullptr)).empty());

    PageHost host(7);
    CHECK(feedWire(page, host.answer(page.buildHello("t", 7))));
    CHECK(feedWire(page, host.exchange(page)));
    REQUIRE(page.subscribeHostListing());
    CHECK(feedWire(page, host.exchange(page)));
    const std::vector<Ubiquitty::Protocol::Sync::ReceivedCall> calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK(calls[0].text.find("host.sessions.subscribe") != std::string::npos);
    CHECK_MSG(static_cast<int>(page.hostOutlineGeneration()) == 0, "asking is not answering");

    // The host answers, describes its one workspace and lists both panes.
    UbiquittyTest::HeldWorkspace held;
    host.connection().offerWorkspaceStructure(UbiquittyTest::HeldWorkspace::workspaceID, 1, held.record());
    for (auto& [id, pane] : held.panes)
        CHECK(host.connection().listPane(*pane.source, Ubiquitty::Protocol::Sync::ListedDetail::Whole) != 0);
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, listingReply(calls[0], held)));
    for (int round = 0; round < 6; ++round)
        CHECK(feedWire(page, host.exchange(page)));
    CHECK(!page.isHostListingRefused());
    const std::uint32_t described = page.hostOutlineGeneration();
    CHECK(described > 0);

    const JSON::Value outline = outlineOf(page, "");
    const std::vector<JSON::Value> rows = rowsOf(outline);
    REQUIRE(rows.size() == 3);
    CHECK_STR_EQ(rows[0].stringOr("level"), "workspace");
    CHECK_STR_EQ(rows[0].stringOr("title"), "work");
    CHECK_STR_EQ(rows[0].stringOr("id"), "workspace:9");
    CHECK_STR_EQ(rows[1].stringOr("title"), "make all");
    CHECK_STR_EQ(rows[2].stringOr("title"), "vim notes");
    REQUIRE(rows[0].find("status") != nullptr);
    CHECK_STR_EQ(rows[0].find("status")->stringOr("kind"), "blocked");
    // The page has applied no theme: the mark is the colour its terminal's
    // own palette derives, not black.
    CHECK_STR_EQ(rows[0].stringOr("statusSlot"), "blocked");
    CHECK_STR_EQ(rows[0].stringOr("statusColor"), "#cdcd00");
    // A theme the page applies colours the marks from then on.
    REQUIRE(Ubiquitty::Themes::count() > 0);
    const Ubiquitty::Themes::Theme* themed = Ubiquitty::Themes::get(0);
    REQUIRE(page.setThemeByName(themed->name));
    const Ubiquitty::ColorRGBA blocked = themed->statusColors().color(Ubiquitty::Themes::StatusColorSlot::Blocked);
    char spelled[8] = {};
    std::snprintf(spelled, sizeof spelled, "#%02x%02x%02x", blocked.red, blocked.green, blocked.blue);
    CHECK_STR_EQ(rowsOf(outlineOf(page, ""))[0].stringOr("statusColor"), spelled);
    CHECK(std::string_view(spelled) != "#cdcd00");

    // The page closes a row and opens it again, by the identity its JSON
    // spelled.
    CHECK(page.collapseHostOutlineRow("workspace:9"));
    CHECK(page.collapseHostOutlineRow("workspace:9"));
    CHECK_EQ(rowsOf(outlineOf(page, "")).size(), 1u);
    CHECK(!page.expandHostOutlineRow("workspace"));
    CHECK(!page.expandHostOutlineRow(nullptr));
    CHECK(!page.collapseHostOutlineRow("nine"));
    CHECK(!page.collapseHostOutlineRow(nullptr));
    CHECK_EQ(rowsOf(outlineOf(page, "")).size(), 1u);
    CHECK(page.expandHostOutlineRow("workspace:9"));
    CHECK_EQ(rowsOf(outlineOf(page, "")).size(), 3u);

    // A search keeps what matches and the way to it.
    const JSON::Value found = outlineOf(page, "MAKE");
    CHECK_EQ(static_cast<int>(found.numberOr("matchCount")), 1);
    REQUIRE(rowsOf(found).size() == 2);
    CHECK_STR_EQ(rowsOf(found)[1].stringOr("title"), "make all");
    CHECK(rowsOf(found)[1].boolOr("match"));
    // The search is the call's, not the page's from then on.
    CHECK_EQ(rowsOf(outlineOf(page, "")).size(), 3u);

    // A recorded row is closed by its place; a level that is neither a
    // window's nor a tab's, or a place below zero, names none.
    CHECK(page.collapseRecordedHostOutlineRow(5, 1, 0, 0));
    CHECK(page.collapseRecordedHostOutlineRow(5, 2, 0, 1));
    CHECK(!page.collapseRecordedHostOutlineRow(5, 0, 0, 0));
    CHECK(!page.collapseRecordedHostOutlineRow(5, 3, 0, 0));
    CHECK(!page.collapseRecordedHostOutlineRow(5, 1, -1, 0));
    CHECK(!page.collapseRecordedHostOutlineRow(5, 2, 0, -1));
    CHECK(page.expandRecordedHostOutlineRow(5, 1, 0, 0));
    CHECK(!page.expandRecordedHostOutlineRow(5, 9, 0, 0));
}

// A page asks its host for a change by a typed request on the connection it
// lists on, and reads how it ended: refused here against the outline's tree,
// served, refused in the host's words, or unanswered when the connection is
// replaced under it.
TEST(aPageAsksItsHostForAChangeAndReadsHowItEnded)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    using Ubiquitty::Runtime::StructureOperation;
    const auto resultOf = [](WebTerminal& page) {
        bool isJSON = false; // bool-ok: the parser's out flag
        JSON::Value parsed = JSON::parse(page.hostStructureResultJSON(), isJSON);
        CHECK(isJSON);
        return parsed;
    };
    const int rename = std::to_underlying(StructureOperation::RenameWorkspace);
    const int tagIt = std::to_underlying(StructureOperation::SetTags);
    const int move = std::to_underlying(StructureOperation::MoveTab);

    WebTerminal page(24, 80, 1);
    CHECK_EQ(static_cast<int>(resultOf(page).numberOr("requestID")), 0);
    // An operation or an identity that is none asks nothing.
    CHECK_EQ(static_cast<int>(page.requestHostStructureChange(0, "workspace:9", "x", "", "", 0)), 0);
    CHECK_EQ(static_cast<int>(page.requestHostStructureChange(7, "workspace:9", "x", "", "", 0)), 0);
    CHECK_EQ(static_cast<int>(page.requestHostStructureChange(rename, "nine", "x", "", "", 0)), 0);
    CHECK_EQ(static_cast<int>(page.requestHostStructureChange(rename, nullptr, "x", "", "", 0)), 0);
    CHECK_EQ(static_cast<int>(page.requestHostStructureChange(move, "tab:1", "", "", "window:1", -1)), 0);
    CHECK_EQ(static_cast<int>(page.hostStructureGeneration()), 0);
    // No listing yet: refused here, in Core's words.
    const std::uint32_t early = page.requestHostStructureChange(rename, "workspace:9", "client", nullptr, nullptr, 0);
    CHECK(early != 0);
    CHECK_EQ(static_cast<int>(page.hostStructureGeneration()), 1);
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), early);
    CHECK_STR_EQ(resultOf(page).stringOr("outcome"), "refusedHere");
    CHECK_STR_EQ(resultOf(page).stringOr("reason"), "This host’s list is out of date. Refresh it, then try again.");
    CHECK_STR_EQ(resultOf(page).stringOr("target"), "workspace:9");
    CHECK_EQ(static_cast<int>(resultOf(page).numberOr("operation")), rename);

    PageHost host(7);
    CHECK(feedWire(page, host.answer(page.buildHello("t", 7))));
    CHECK(feedWire(page, host.exchange(page)));
    REQUIRE(page.subscribeHostListing());
    CHECK(feedWire(page, host.exchange(page)));
    std::vector<Ubiquitty::Protocol::Sync::ReceivedCall> calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    UbiquittyTest::HeldWorkspace held;
    host.connection().offerWorkspaceStructure(UbiquittyTest::HeldWorkspace::workspaceID, 1, held.record());
    for (auto& [id, pane] : held.panes)
        CHECK(host.connection().listPane(*pane.source, Ubiquitty::Protocol::Sync::ListedDetail::Whole) != 0);
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, listingReply(calls[0], held)));
    for (int round = 0; round < 6; ++round)
        CHECK(feedWire(page, host.exchange(page)));
    const std::uint32_t outlineBefore = page.hostOutlineGeneration();

    // Served: one typed call, answered under its own id.
    const std::uint32_t served = page.requestHostStructureChange(rename, "workspace:9", "client \"work\"", "", "", 0);
    CHECK(served > early);
    CHECK_MSG(static_cast<int>(page.hostStructureGeneration()) == 1, "asking is not answering");
    CHECK(feedWire(page, host.exchange(page)));
    calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK_MSG(calls[0].text.find(R"("method":"workspace.rename")") != std::string::npos && calls[0].text.find(R"("workspace":9)") != std::string::npos && calls[0].text.find(R"("name":"client \"work\"")") != std::string::npos, calls[0].text.c_str());
    const std::string id = Ubiquitty::Runtime::StructureCalls::callID(served);
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":")" + id + R"(","result":{"workspace":"workspace:9","name":"client"}})"));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK_EQ(static_cast<int>(page.hostStructureGeneration()), 2);
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), served);
    CHECK_STR_EQ(resultOf(page).stringOr("outcome"), "served");
    CHECK(resultOf(page).stringOr("reason").empty());
    CHECK_MSG(page.hostOutlineGeneration() == outlineBefore && !page.isHostListingRefused(), "a change's answer was read as the listing's");

    // Tags are one a line, and the host's refusal is shown in its words.
    const std::uint32_t tagged = page.requestHostStructureChange(tagIt, "workspace:9", "", "production\nbilling", "", 0);
    CHECK(feedWire(page, host.exchange(page)));
    calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK_MSG(calls[0].text.find(R"("tags":["production","billing"])") != std::string::npos, calls[0].text.c_str());
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":")" + Ubiquitty::Runtime::StructureCalls::callID(tagged) + R"(","error":{"code":-32002,"message":"tags.set: a person is attached to session:1 of workspace:9"}})"));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK_STR_EQ(resultOf(page).stringOr("outcome"), "refusedByHost");
    CHECK_STR_EQ(resultOf(page).stringOr("reason"), "tags.set: a person is attached to session:1 of workspace:9");
    // A target the outline does not hold is never sent.
    const std::uint32_t absent = page.requestHostStructureChange(move, "tab:99999", "", "", "window:1", 0);
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), absent);
    CHECK_STR_EQ(resultOf(page).stringOr("reason"), "tab:99999 is no longer on this host’s list.");
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(host.connection().takeCalls().empty());

    // A window is closed only with the token of the question Core worded
    // for it; the entry that takes any operation never closes one.
    const int closeIt = static_cast<int>(Ubiquitty::Runtime::StructureOperation::CloseWindow);
    const auto questionOf = [&](int request, const char* target) {
        bool isJSON = false; // bool-ok: the parser's out flag
        return Ubiquitty::Codec::JSON::parse(page.hostDestructiveConfirmationJSON(request, target, "devbox"), isJSON);
    };
    const std::uint32_t unasked = page.requestHostStructureChange(closeIt, "window:1", "", "", "", 0);
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), unasked);
    CHECK_STR_EQ(resultOf(page).stringOr("reason"), "This was not confirmed. Nothing is ended without asking first.");
    CHECK_STR_EQ(questionOf(0, "window:1").stringOr("whyNot"), "This is not a request this build asks about.");
    CHECK_STR_EQ(questionOf(1, "one").stringOr("whyNot"), "This is not a request this build asks about.");
    CHECK_STR_EQ(questionOf(1, "window:77").stringOr("whyNot"), "window:77 is no longer on this host’s list.");
    const Ubiquitty::Codec::JSON::Value closing = questionOf(1, "window:1");
    CHECK_STR_EQ(closing.stringOr("title"), "Close this window on devbox?");
    CHECK_STR_EQ(closing.stringOr("body"), "The host closes the window and ends its 2 sessions and everything running in them. Running: make, vim.");
    CHECK_STR_EQ(closing.stringOr("safeButton"), "Keep Window");
    CHECK_STR_EQ(closing.stringOr("destructiveButton"), "Close Window");
    CHECK(static_cast<int>(closing.numberOr("sessionCount")) == 2 && closing.stringOr("whyNot").empty());
    const std::uint32_t closeToken = static_cast<std::uint32_t>(closing.numberOr("token"));
    REQUIRE(closeToken != 0);
    (void)page.closeHostWindow("window:1", closeToken + 100);
    CHECK_STR_EQ(resultOf(page).stringOr("reason"), "This was not confirmed. Nothing is ended without asking first.");
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(host.connection().takeCalls().empty());
    const std::uint32_t closedWindow = page.closeHostWindow("window:1", closeToken);
    CHECK(feedWire(page, host.exchange(page)));
    calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK_MSG(calls[0].text.find(R"("method":"window.close")") != std::string::npos && calls[0].text.find(R"("window":1)") != std::string::npos, calls[0].text.c_str());
    CHECK_MSG(calls[0].text.find(R"("expectedRevision":"1")") != std::string::npos, calls[0].text.c_str());
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":")" + Ubiquitty::Runtime::StructureCalls::callID(closedWindow) + R"(","error":{"code":-32002,"message":"window.close: an agent rearranges nothing"}})"));
    for (int round = 0; round < 3; ++round)
        CHECK(feedWire(page, host.exchange(page)));
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), closedWindow);
    (void)page.closeHostWindow("window:1", closeToken);
    CHECK_MSG(resultOf(page).stringOr("reason") == "This was not confirmed. Nothing is ended without asking first.", "a token is spent once");

    // A terminate is built only with its own question's token: a session's
    // is one frame, a workspace's is one a session, the rest owed.
    CHECK(page.buildConfirmedTerminate(2, "session:1", 0).empty());
    CHECK_STR_EQ(page.hostTerminateRefusal(), "This was not confirmed. Nothing is ended without asking first.");
    CHECK(page.buildConfirmedTerminate(1, "window:1", closeToken).empty());
    CHECK_STR_EQ(page.hostTerminateRefusal(), "This is not a request this build sends.");
    const Ubiquitty::Codec::JSON::Value ending = questionOf(3, "workspace:9");
    CHECK_STR_EQ(ending.stringOr("title"), "Terminate work on devbox?");
    const std::uint32_t endToken = static_cast<std::uint32_t>(ending.numberOr("token"));
    CHECK(page.buildConfirmedTerminate(2, "session:1", endToken).empty());
    const auto firstTermination = page.buildConfirmedTerminate(3, "workspace:9", endToken);
    REQUIRE(!firstTermination.empty());
    CHECK_STR_EQ(page.hostTerminateRefusal(), "");
    CHECK_EQ(page.owedTerminateCount(), 1u);
    // While one is out and one is owed, another is not begun.
    const std::uint32_t lateToken = static_cast<std::uint32_t>(questionOf(2, "session:2").numberOr("token"));
    CHECK(page.buildConfirmedTerminate(2, "session:2", lateToken).empty());
    CHECK_STR_EQ(page.hostTerminateRefusal(), "This host is still ending what was asked before. Try again in a moment.");
    CHECK(page.buildOwedTerminate().empty());
    CHECK_EQ(page.owedTerminateCount(), 1u);
    CHECK_EQ(answerPageTermination(page, host, firstTermination, "terminated"), 1u);
    CHECK_EQ(answerPageTermination(page, host, page.buildOwedTerminate(), "terminated"), 2u);
    CHECK(page.owedTerminateCount() == 0 && page.buildOwedTerminate().empty());

    // A change out when the page subscribes on a new connection ends as
    // unanswered.
    const std::uint32_t out = page.requestHostStructureChange(rename, "workspace:9", "later", "", "", 0);
    const std::uint32_t settledBefore = page.hostStructureGeneration();
    REQUIRE(page.subscribeHostListing());
    CHECK_EQ(page.hostStructureGeneration(), settledBefore + 1);
    CHECK_EQ(static_cast<std::uint32_t>(resultOf(page).numberOr("requestID")), out);
    CHECK_STR_EQ(resultOf(page).stringOr("outcome"), "unanswered");
    CHECK(!resultOf(page).stringOr("reason").empty());
}

// A host that refuses the subscription leaves the page with no rows and the
// reason it has none.
TEST(aPageIsToldItsHostDoesNotListItself)
{
    WebTerminal page(24, 80, 1);
    PageHost host(7);
    CHECK(feedWire(page, host.answer(page.buildHello("t", 7))));
    CHECK(feedWire(page, host.exchange(page)));
    REQUIRE(page.subscribeHostListing());
    CHECK(feedWire(page, host.exchange(page)));
    const std::vector<Ubiquitty::Protocol::Sync::ReceivedCall> calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK(Ubiquitty::Protocol::Sync::CallAnswer::Sent == host.connection().answerCall(calls[0].callIndex, R"({"jsonrpc":"2.0","id":"ubiquitty.host-listing.1","error":{"code":-32003,"message":"not for this connection"}})"));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(feedWire(page, host.exchange(page)));
    CHECK(page.isHostListingRefused());
    CHECK_MSG(static_cast<int>(page.hostOutlineGeneration()) == 1, "a refusal is an answer the page is told of once");
    // Subscribing again asks again, and forgets the refusal until it is
    // answered.
    REQUIRE(page.subscribeHostListing());
    CHECK(!page.isHostListingRefused());
}

// The host's outline as the page reads it: Core's rows, one JSON text.
std::vector<Ubiquitty::Codec::JSON::Value> outlineRowsOf(WebTerminal& page)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    bool isJSON = false; // bool-ok: the parser's out flag
    const JSON::Value parsed = JSON::parse(page.hostOutlineJSON(""), isJSON);
    CHECK(isJSON);
    const JSON::Value* rows = parsed.find("rows");
    return rows ? rows->items() : std::vector<JSON::Value> {};
}

// What a sidebar renders: what each row is called, what opening it attaches
// to, and the facts Core gives it. A workspace of one pane is one row standing
// for that pane.
TEST(aListingAnswerIsDrawnAsTheOutline)
{
    WebTerminal terminal(24, 80, 1);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);

    CHECK(feedSessionList(terminal, directory, requestID,
        { listedSession(7, "build", "/src/ubiquitty", "ninja", 0),
            listedSession(9, "shell", "/var/log", "zsh", listedAtPrompt) }));

    const auto rows = outlineRowsOf(terminal);
    REQUIRE(rows.size() == 2);
    CHECK(rows[0].stringOr("directory") == "/src/ubiquitty");
    CHECK(rows[0].stringOr("program") == "ninja");
    CHECK_EQ(static_cast<int>(rows[0].numberOr("columns", 0)), 120);
    CHECK_EQ(static_cast<int>(rows[0].numberOr("rows", 0)), 40);
    const auto* open = rows[0].find("open");
    REQUIRE(open != nullptr);
    CHECK_MSG(open->stringOr("how") == "session" && open->stringOr("session") == "session:7",
        "opening the row attaches to the session it stands for");
    CHECK(rows[1].stringOr("directory") == "/var/log");
    CHECK_MSG(rows[1].find("open") && rows[1].find("open")->stringOr("session") == "session:9", "the second row opens its own session");
}

// An answer arrives on a frame of its own with nothing on the grid to notice it
// by, so the page polls this. It counts rather than flags because a host
// holding nothing is an answer, and an outline of no rows is what "no reply
// yet" also looks like.
TEST(theHostAnswerGenerationSeparatesAnEmptyAnswerFromNoAnswer)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_EQ(static_cast<int>(terminal.hostAnswerGeneration()), 0);
    CHECK(outlineRowsOf(terminal).empty());

    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);
    CHECK_MSG(static_cast<int>(terminal.hostAnswerGeneration()) == 0,
        "asking is not answering — the previous answer stands until a reply lands");

    CHECK(feedSessionList(terminal, directory, requestID, {}));
    CHECK_MSG(static_cast<int>(terminal.hostAnswerGeneration()) == 1,
        "a host holding nothing is an answer and must be reported as one");
    CHECK(outlineRowsOf(terminal).empty());
}

// A reply to a superseded ask describes sessions that have since been listed
// again. Taking it replaces a newer answer with an older one, and nothing about
// the frame says which it is except the id.
TEST(aSupersededListingReplyDoesNotReplaceTheCurrentOne)
{
    WebTerminal terminal(24, 80, 1);
    DirectoryPageHost directory;
    const std::uint32_t stale = directory.request(terminal);
    const std::uint32_t current = directory.request(terminal);

    CHECK(feedSessionList(terminal, directory, current, { listedSession(3, "current", "/now", "zsh", listedAtPrompt) }));
    CHECK_EQ(static_cast<int>(terminal.hostAnswerGeneration()), 1);

    CHECK(feedSessionList(terminal, directory, stale, { listedSession(99, "stale", "/then", "vim", 0) }));
    CHECK_MSG(static_cast<int>(terminal.hostAnswerGeneration()) == 1,
        "the stale reply raises no new answer");
    const auto rows = outlineRowsOf(terminal);
    REQUIRE(rows.size() == 1);
    CHECK(rows[0].stringOr("directory") == "/now");
}

// The host is not trusted to only answer what was asked. A listing this client
// never requested must not present itself as this client's own — and
// requestID 0 is what an unsolicited one carries, because an outstanding id is
// never 0.
TEST(anUnrequestedListingIsIgnored)
{
    WebTerminal terminal(24, 80, 1);
    DirectoryPageHost directory;
    directory.attach(terminal);
    CHECK(feedSessionList(terminal, directory, 0, { listedSession(4, "uninvited", "/", "sh", 0) }));
    CHECK_EQ(static_cast<int>(terminal.hostAnswerGeneration()), 0);
    CHECK(outlineRowsOf(terminal).empty());
}

// A title is arbitrary UTF-8 a program set through OSC 0, so it may hold any
// byte — including the ones a delimited encoding would use to separate fields.
// The outline is one JSON text, and this is the case that fails if a field is
// ever packed into a string by hand.
TEST(aListedTitleSurvivesTheBytesADelimiterWouldClaim)
{
    WebTerminal terminal(24, 80, 1);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);
    const std::string awkward = "one\ttwo\nthree\x1b[0m|four";
    CHECK(feedSessionList(terminal, directory, requestID, { listedSession(11, awkward.c_str(), "/a\tb", "zsh", 0) }));

    const auto rows = outlineRowsOf(terminal);
    REQUIRE(rows.size() == 1);
    CHECK(rows[0].stringOr("directory") == "/a\tb");
    const std::string json = terminal.hostOutlineJSON("");
    CHECK_MSG(json.find("\x1b") == std::string::npos, "a control byte in a title is escaped in the outline's text, never passed through raw");
}

// A workspace's name, who is on it and whether it outlives the last person:
// the facts a row is chosen by, worded by Core.
TEST(aRowSaysItsWorkspaceWhoIsOnItAndWhetherItStays)
{
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);

    CHECK(feedSessionList(terminal, directory, requestID,
        { namedListedSession(21, 3, "release", 4, 2, listedEndsWhenDetached),
            namedListedSession(22, 0, "", 1, 0, listedAtPrompt) }));

    const auto rows = outlineRowsOf(terminal);
    REQUIRE(rows.size() == 2);
    CHECK(rows[0].stringOr("title") == "release");
    CHECK(rows[0].stringOr("id") == "workspace:3");
    const auto* attendance = rows[0].find("attendance");
    REQUIRE(attendance != nullptr);
    CHECK_MSG(attendance->numberOr("people", 0) == 2 && attendance->numberOr("agents", 0) == 2,
        "the people are counted apart from the agents: two agents on a session is not two colleagues");
    CHECK_MSG(rows[0].boolOr("endsWhenDetached", false), "the row has to say which workspaces will not be there tomorrow");
    CHECK(rows[1].stringOr("id") == "workspace:22");
    CHECK_MSG(!rows[1].boolOr("endsWhenDetached", true), "and which will");
}

// --- The HELLO's workspace name and lifetime ---------------------------------

// A name reaches the host, and so does the flag that says what becomes of the
// session it creates. Both are read by the host only on a create, which is why
// they are sent on every handshake rather than only on one believed to be new:
// the page cannot know whether the id it is asking for still exists.
TEST(aHelloCarriesTheWorkspaceNameAndTheLifetimeFlagWhenSet)
{
    WebTerminal terminal(24, 80, 1);
    const std::vector<std::uint8_t>& hello = terminal.buildHello("t", 0,
        WebTerminal::ClipboardServing::Disabled,
        "release", WebTerminal::SessionLifetime::EndsWhenDetached);

    const auto decoded = Ubiquitty::Protocol::Sync::decodeGreet(helloPayload(hello));
    CHECK(decoded.has_value());
    CHECK_MSG(decoded.has_value() && decoded->request.workspaceName == "release",
        "the name the page was asked to attach under is the name on the wire");
    CHECK_MSG(decoded.has_value() && decoded->request.endsWhenDetached,
        "and an ephemeral create says so, or the host keeps a shell nobody can name again");
}

// Most callers make this call without the two arguments, and an argument that
// changes the frame when it is not used breaks every one of them. The call
// with neither argument — no name, no flag — is pinned here as producing the
// same HELLO bytes as the two ways of spelling "no workspace" explicitly. The
// greeting after it names a fresh client instance per connection, so it is
// left out.
TEST(aHelloThatNamesNoWorkspaceIsByteIdenticalToTheCallWithoutOne)
{
    WebTerminal defaulted(24, 80, 1);
    const std::vector<std::uint8_t> withoutArguments = defaulted.buildHello("t", 5,
        WebTerminal::ClipboardServing::Enabled);

    WebTerminal explicitlyNull(24, 80, 1);
    const std::vector<std::uint8_t> withNullName = explicitlyNull.buildHello("t", 5,
        WebTerminal::ClipboardServing::Enabled,
        nullptr, WebTerminal::SessionLifetime::Persists);

    WebTerminal explicitlyEmpty(24, 80, 1);
    const std::vector<std::uint8_t> withEmptyName = explicitlyEmpty.buildHello("t", 5,
        WebTerminal::ClipboardServing::Enabled,
        "", WebTerminal::SessionLifetime::Persists);

    const auto normalized = [](const auto& frame) {
        auto greet = Ubiquitty::Protocol::Sync::decodeGreet(helloPayload(frame));
        CHECK(greet);
        std::vector<std::uint8_t> body;
        if (greet) {
            // Each Greet mints a fresh client instance; nothing else may differ.
            greet->clientInstance = { 1, 1 };
            Ubiquitty::Protocol::Sync::encode(body, *greet);
        }
        return body;
    };
    CHECK(normalized(withNullName) == normalized(withoutArguments));
    CHECK(normalized(withEmptyName) == normalized(withoutArguments));

    const auto decoded = Ubiquitty::Protocol::Sync::decodeGreet(helloPayload(withoutArguments));
    CHECK(decoded.has_value());
    CHECK_MSG(decoded.has_value() && decoded->request.workspaceName.empty(),
        "a page that names no workspace puts nothing on the wire a host could read as one");
    CHECK_MSG(decoded.has_value() && !decoded->request.endsWhenDetached,
        "and asks for the host's own lifetime rather than an ephemeral session");
}

// --- Terminate ---------------------------------------------------------------
//
// The ask crosses one frame and the answer arrives as any of five different
// exchanges. `SessionDirectoryCore` classifies them for the desktop; this arm
// mirrors that mapping, and the ordinals are Core's so the two cannot report the
// same exchange as different things.

// The page restates these numbers in JavaScript — one table beside the cwraps
// rather than six exported accessors — so this is what stops the two drifting.
// Every value is named against Core's own, because the point of pinning them is
// that a browser and a desktop agree, not that the browser is self-consistent.
TEST(theTerminateOutcomeOrdinalsAreTheOnesThePageReads)
{
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Terminated), 0);
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Denied), 1);
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::TimedOut), 2);
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Failed), 3);
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Refused), 4);

    CHECK_MSG(static_cast<int>(WebTerminal::TerminateOutcome::Terminated)
            == static_cast<int>(Ubiquitty::Session::TerminateOutcome::Terminated),
        "an ordinal crossing this ABI means what it means everywhere else");
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Denied),
        static_cast<int>(Ubiquitty::Session::TerminateOutcome::Denied));
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::TimedOut),
        static_cast<int>(Ubiquitty::Session::TerminateOutcome::TimedOut));
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Failed),
        static_cast<int>(Ubiquitty::Session::TerminateOutcome::Failed));
    CHECK_EQ(static_cast<int>(WebTerminal::TerminateOutcome::Refused),
        static_cast<int>(Ubiquitty::Session::TerminateOutcome::Refused));

    // Pending is this arm's alone: a page holds a row before it asks anything,
    // where the desktop's errand object exists only while an ask is outstanding.
    // 255 rather than a sixth position, so it can never collide with a Core
    // outcome and can never shift one.
    CHECK_MSG(static_cast<int>(WebTerminal::TerminateOutcome::Pending) == 255,
        "an unasked row must not read as a session that was destroyed");
}

// The bytes are the whole of the ask: one Call, one session id. A builder
// naming the wrong session ends the wrong shell, and nothing downstream can tell.
// They are the connection's owed stream, so what the connection already owed
// rides ahead of the Call: here the Probe a Welcome starts the client's round
// trip with and the View of the pane the page shows, since nothing took the
// page's output after the Welcome.
TEST(aTerminateFrameNamesTheSessionItEnds)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(4);
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", 4))));

    const std::vector<std::uint8_t>& frame = terminal.buildTerminateSession(88);
    CHECK(!frame.empty());
    {
        using Ubiquitty::Protocol::Sync::FrameKind;
        Ubiquitty::Protocol::Sync::FrameDecoder decoder;
        decoder.append(frame);
        std::vector<FrameKind> kinds;
        while (const auto decoded = decoder.next())
            kinds.push_back(decoded->kind);
        CHECK(decoder.error() == Ubiquitty::Protocol::Sync::EnvelopeError::None);
        CHECK_EQ(decoder.bufferedBytes(), 0u);
        CHECK_EQ(std::ranges::count(kinds, FrameKind::Call), 1);
        CHECK(!kinds.empty() && kinds.back() == FrameKind::Call);
    }
    CHECK_EQ(static_cast<int>(terminal.terminateSessionID()), 88);
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending,
        "an ask that has just gone out has not settled");
    CHECK_MSG(static_cast<int>(terminal.terminateGeneration()) == 0,
        "and raises no answer for the page to report");
    CHECK_EQ(answerPageTermination(terminal, host, frame, "terminated"), 88u);
    CHECK(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Terminated);

    // 0 is not a session, so it builds nothing rather than a frame the host
    // would have to decide what to do with.
    CHECK(terminal.buildTerminateSession(0).empty());
}

// Only a correlated typed result can settle a termination.
TEST(aCorrelatedResultSettlesTheTerminateAsTerminated)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(4);
    CHECK(feedWire(terminal, host.answer(terminal.buildHello("t", 4))));
    CHECK_EQ(answerPageTermination(terminal, host, terminal.buildTerminateSession(91), "terminated"), 91u);

    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Terminated, "the session is gone");
    CHECK_MSG(static_cast<int>(terminal.terminateGeneration()) == 1, "and the page has one answer to report");
    CHECK_EQ(static_cast<int>(terminal.terminateSessionID()), 91);
}

// The two halves of a consent gate that answered. They are different problems
// with different answers — one person said no, the other never looked — so a
// single "denied" would tell a viewer to give up where they should ask again.
TEST(aDeniedConsentIsToldApartFromOneThatRanOut)
{
    WebTerminal declined(24, 80, 1);
    PageHost declinedHost(4);
    CHECK(feedWire(declined, declinedHost.answer(declined.buildHello("t", 4))));
    CHECK_EQ(answerPageTermination(declined, declinedHost, declined.buildTerminateSession(92), "denied"), 92u);
    CHECK_MSG(declined.terminateOutcome() == WebTerminal::TerminateOutcome::Denied,
        "a person on the session said no");

    WebTerminal unanswered(24, 80, 1);
    PageHost unansweredHost(4);
    CHECK(feedWire(unanswered, unansweredHost.answer(unanswered.buildHello("t", 4))));
    CHECK_EQ(answerPageTermination(unanswered, unansweredHost, unanswered.buildTerminateSession(93), "timed-out"), 93u);
    CHECK_MSG(unanswered.terminateOutcome() == WebTerminal::TerminateOutcome::TimedOut,
        "nobody answered, which is a reason to ask again rather than to stop");
}

// An own-attach status has no place on an already admitted connection. It is
// refused without turning an unrelated termination into a result.
TEST(aConsentDenialForAnotherSessionLeavesTheTerminateOutstanding)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    terminal.buildTerminateSession(94);

    CHECK(!feedWire(terminal, ownConsentStatusWire({ .question = { .requestID = 71, .sessionID = 95 }, .phase = Sync::ConsentStatusPhase::Denied })));

    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending,
        "the row this page armed is still waiting");
    CHECK_MSG(static_cast<int>(terminal.terminateGeneration()) == 0, "and no answer has been raised");
    CHECK_STR_EQ(terminal.hostNotice(), "");
    CHECK(!terminal.isAttached());
}

// A welcomed connection's typed authority refusal also refuses its outstanding
// operation. The page presents the host's reason rather than asking again.
TEST(anAuthDenialSettlesTheTerminateAsRefused)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    PageHost host(4);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello("t", 4))));
    host.receive(terminal.buildTerminateSession(96));
    REQUIRE(host.connection().takeCalls().size() == 1);

    host.connection().refuse(Sync::ByeReason::OutsideScope);
    CHECK(!feedWire(terminal, host.flush()));

    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Refused,
        "the host refused the request itself");
    CHECK_MSG(std::string(terminal.hostNotice()) == std::string(Sync::byeNotice(Sync::ByeReason::OutsideScope)),
        "and the reason shown is the host's, not a word this arm chose");
}

// A timer cannot establish that the host committed a destructive operation.
TEST(silenceOnAnUnheldTerminateNeverReportsSuccess)
{
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    terminal.buildTerminateSession(97);

    terminal.noteTerminateGraceElapsed();
    CHECK(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending);
    CHECK_EQ(terminal.terminateGeneration(), 0u);
    terminal.noteTerminateDeadlineElapsed();
    CHECK(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::TimedOut);
}

// A typed call held for a person's decision has no result yet. Neither a short
// wait nor a deadline can establish that a destructive operation committed.
TEST(aHeldTerminateWaitsPastTheGraceAndThenTimesOut)
{
    WebTerminal terminal(24, 80, 1);
    PageHost host(4);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello("t", 4))));
    host.receive(terminal.buildTerminateSession(98));
    REQUIRE(host.connection().takeCalls().size() == 1);

    terminal.noteTerminateGraceElapsed();
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending,
        "a held call has no correlated answer, so the grace window decides nothing");

    terminal.noteTerminateDeadlineElapsed();
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::TimedOut,
        "the page can stop waiting but cannot report an unconfirmed destroy");
}

// A socket that goes with the ask outstanding never delivered it. The desktop's
// errand may read its own drop as the destroy, because its connection is bound
// to the session it is ending; this page's connection is bound to the session it
// is mirroring, usually another one, so its drop says nothing about the target.
TEST(aLostTransportSettlesTheTerminateAsFailed)
{
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    terminal.buildTerminateSession(99);

    terminal.noteTerminateTransportLost();
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Failed,
        "the transport supplied no confirmed result");

    // And a settled row is not re-settled by a wait that was already armed.
    terminal.noteTerminateGraceElapsed();
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Failed, "the first answer is the answer");
    CHECK_MSG(static_cast<int>(terminal.terminateGeneration()) == 1, "and it is reported once");
}

// A page holding no ask must not read as one whose session was destroyed, which
// is what a Pending sharing an ordinal with Terminated would do.
TEST(aTerminalThatHasAskedNothingReadsPending)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending, "nothing has been asked");
    CHECK_EQ(static_cast<int>(terminal.terminateSessionID()), 0);
    CHECK_EQ(static_cast<int>(terminal.terminateGeneration()), 0);

    // And the waits decide nothing when there is nothing outstanding.
    terminal.noteTerminateGraceElapsed();
    terminal.noteTerminateDeadlineElapsed();
    terminal.noteTerminateTransportLost();
    CHECK_MSG(terminal.terminateOutcome() == WebTerminal::TerminateOutcome::Pending,
        "an elapsed wait on nothing is not an outcome");
    CHECK_EQ(static_cast<int>(terminal.terminateGeneration()), 0);
}

// --- The pairing the connect rule reads --------------------------------------
//
// The rule is Core's and the store is the page's, so what this arm owns is the
// hand-off: bytes in, bytes out, and never a look inside them.

// A record written for one host comes back for that host and for no other, and
// survives the round trip through bytes the page keeps. The bytes hold a zero
// and a length-prefixed name, which is why the length is carried beside the
// pointer instead of the page reading to a terminator.
TEST(aHostPairingRoundTripsThroughThePagesStore)
{
    WebTerminal terminal(24, 80, 1);
    terminal.rememberHostSession("ws://build:9/ws", 41, "release");

    const int length = terminal.hostRecordLength("ws://build:9/ws");
    CHECK_MSG(length > 0, "a remembered host has bytes to keep");
    const std::string kept(terminal.hostRecordBytes("ws://build:9/ws"), static_cast<std::size_t>(length));
    CHECK_MSG(kept.size() == static_cast<std::size_t>(length),
        "the extent is what is copied — a record may hold a zero byte");
    CHECK_EQ(terminal.hostRecordLength("ws://laptop:9/ws"), 0);

    // A second page, given the same bytes, decides the same way — which is the
    // whole point of the store being opaque.
    WebTerminal reloaded(24, 80, 1);
    reloaded.loadHostRecord("ws://build:9/ws", kept.data(), length);
    handshakeWithHost(reloaded, 4);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(reloaded);
    CHECK(feedSessionList(reloaded, directory, requestID, { namedListedSession(41, 3, "release", 1, 1, 0) }));

    CHECK_MSG(reloaded.decideAttach("ws://build:9/ws", nullptr) == Ubiquitty::Session::AttachPlan::AttachByID,
        "the host still lists the remembered session, so the reload re-homes to it");
    CHECK_EQ(static_cast<int>(reloaded.decidedSessionID()), 41);
    CHECK_STR_EQ(reloaded.decidedWorkspaceName(), "release");

    // Forgetting leaves the host looking like one never visited, which is what a
    // refused reattach and a terminated session both have to produce.
    reloaded.forgetHostSession("ws://build:9/ws");
    CHECK_EQ(reloaded.hostRecordLength("ws://build:9/ws"), 0);
    CHECK_MSG(reloaded.decideAttach("ws://build:9/ws", nullptr) == Ubiquitty::Session::AttachPlan::ChooseFromList,
        "with no pairing and a host that has sessions, the choice is the person's");
}

// A page that has not heard the host's list yet has not been told the host is
// empty. The remembered session is the answer, not a fresh one beside it, and a
// page that remembers nothing waits rather than creating.
TEST(aPageWithNoListingYetDoesNotReadTheHostAsEmpty)
{
    WebTerminal terminal(24, 80, 1);
    CHECK_MSG(terminal.decideAttach("ws://build:9/ws", nullptr) == Ubiquitty::Session::AttachPlan::AwaitListing,
        "nothing remembered and nothing heard is a wait, not a new session");

    terminal.rememberHostSession("ws://build:9/ws", 41, "");
    CHECK_MSG(terminal.decideAttach("ws://build:9/ws", nullptr) == Ubiquitty::Session::AttachPlan::AttachByID,
        "the remembered session is returned to before the host answers");
    CHECK_EQ(static_cast<int>(terminal.decidedSessionID()), 41);
}

// A predefined name outranks the pairing, and asks one question with either
// answer: attach to the session bearing it, or create one under it.
TEST(aPredefinedWorkspaceNameDecidesTheConnectWhicheverWayItLands)
{
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);
    CHECK(feedSessionList(terminal, directory, requestID, { namedListedSession(51, 8, "release", 1, 1, 0) }));

    CHECK_MSG(terminal.decideAttach("ws://build:9/ws", "release") == Ubiquitty::Session::AttachPlan::AttachNamed,
        "the host lists it, so the connect joins it");
    CHECK_STR_EQ(terminal.decidedWorkspaceName(), "release");

    CHECK_MSG(terminal.decideAttach("ws://build:9/ws", "nightly") == Ubiquitty::Session::AttachPlan::CreateNamed,
        "nothing bears the name, so the connect creates it under that name");
    CHECK_STR_EQ(terminal.decidedWorkspaceName(), "nightly");
}

// The page decides on the host's tree, not on rows: two workspaces bearing the
// name a connect asks for are the person's to choose between. Rows could only
// take the first that matched, and a Greet by that name would land on
// whichever the host found first.
TEST(aNameTwoWorkspacesBearIsThePersonsToChoose)
{
    WebTerminal terminal(24, 80, 1);
    handshakeWithHost(terminal, 4);
    DirectoryPageHost directory;
    const std::uint32_t requestID = directory.request(terminal);
    CHECK(feedSessionList(terminal, directory, requestID,
        { namedListedSession(61, 6, "release", 1, 1, 0), namedListedSession(62, 7, "release", 0, 0, listedAtPrompt) }));

    CHECK_MSG(terminal.decideAttach("ws://build:9/ws", "release") == Ubiquitty::Session::AttachPlan::ChooseFromList,
        "two workspaces bear the name, so the connect asks rather than joining the first");
    CHECK_STR_EQ(terminal.decidedWorkspaceName(), "");
}

// Font size as a value editor beside the three step actions. Stepping suits "a
// bit bigger"; typing suits 14, and reaching 14 from 16 by pressing a key twice
// is what a number editor replaces.
//
// The bounds come from `font.size` in Core's settings table, which is the same
// row `Preferences::Zoom::fontZoomRange` reads — so the editor and the step actions
// cannot disagree about what the terminal accepts.
TEST(beamEditsTheFontSizeAsANumber)
{
    WebTerminal terminal(24, 80, 1);
    const double original = terminal.fontSize();

    terminal.toggleBeam();
    for (const char* p = "font size"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));

    const auto& rows = terminal.beamState().rows;
    CHECK_MSG(!rows.empty() && rows[0].title == "Font Size", "the command is the top match");
    CHECK_MSG(rows[0].hasChildren, "and offers the drill affordance");

    CHECK(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0));
    CHECK_MSG(terminal.beamState().isValueEditor, "Right opened the editor");
    CHECK_MSG(terminal.beamState().status == "6–96 pt",
        "with font.size's own range under it, not a range written here");

    // Type a size the step actions would take several presses to reach.
    for (int i = 0; i < 4; ++i)
        terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyBackspace, 0, 0, 0);
    for (const char* p = "28"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
    CHECK(terminal.feedBeamKey(13u, 0, 0, 0));

    CHECK_MSG(terminal.fontSize() == 28.0, "the terminal holds what was committed");
    CHECK_MSG(terminal.fontSize() != original, "which is not where it started");
    CHECK_STR_EQ(terminal.takeBeamCommand(), "beam.fontSize");
}

// The editor clamps to the schema rather than to numbers written at the call
// site, so a value the TOML parse would refuse cannot arrive through the palette.
TEST(beamRefusesAFontSizeTheSchemaWouldRefuse)
{
    WebTerminal terminal(24, 80, 1);
    terminal.toggleBeam();
    for (const char* p = "font size"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
    CHECK(terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyRight, 0, 0, 0));
    for (int i = 0; i < 4; ++i)
        terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyBackspace, 0, 0, 0);
    for (const char* p = "900"; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
    CHECK(terminal.feedBeamKey(13u, 0, 0, 0));
    CHECK_MSG(terminal.fontSize() == 96.0, "clamped to font.size's ceiling");
}

// --- the Blocks scope -------------------------------------------------------
//
// `Screen::commandBlocks` walks the OSC 133 marks and `BeamSession` resolves the
// '@' prefix, both portable and both already covered where they live. What is
// checkable only here is the registration between them: which scope the browser
// fills, whether it says it has a terminal at all, and what accepting a row
// does. A frontend that never registers the scope shows an empty list, and a
// frontend that never declares a terminal refuses the prefix outright — neither
// fails anything in Core.

// Bytes as text, which is what every sequence below is written as.
void feedText(WebTerminal& terminal, const char* bytes)
{
    terminal.feed(bytes);
}

// One shell-integrated command, in the byte order a shell emits it.
//
// `previousExitStatus` closes the command before this one: OSC 133 reports a
// status when the next prompt is drawn, so a failure is recorded against a row
// that may already have scrolled into history.
void runCommand(WebTerminal& terminal, int previousExitStatus, const char* commandLine, const char* output)
{
    feedText(terminal, ("\033]133;D;" + std::to_string(previousExitStatus) + "\007\033]133;A\007").c_str());
    feedText(terminal, commandLine);
    feedText(terminal, "\r\n\033]133;C\007");
    feedText(terminal, output);
    feedText(terminal, "\r\n");
}

// Types ASCII into an open palette, one character event per byte.
void typeIntoBeam(WebTerminal& terminal, const char* text)
{
    for (const char* p = text; *p; ++p)
        terminal.feedBeamKey(static_cast<unsigned char>(*p), 0, 0, static_cast<unsigned char>(*p));
}

// The whole text of one visible row, taken the way a user takes it.
std::string visibleLine(WebTerminal& terminal, int visibleRow)
{
    press(terminal, visibleRow, 0, 3);
    release(terminal, 2, 6);
    std::string text = terminal.selectionText();
    terminal.clearSelection();
    return text;
}

// The Actions scope is Core's named-action catalog, not a list this frontend
// keeps. What is checkable here is that the two are the same set: an id the page
// offers is a token `[keys]` parses, and an action Core carries that this page
// can run is offered. A private list drifts silently — this one omitted every
// scroll-line and scroll-page action while binding all four to keys.
TEST(theActionsScopeIsCoresCatalog)
{
    WebTerminal terminal(12, 40, 1);
    CHECK(terminal.toggleBeam());

    std::vector<std::string> offered;
    for (const auto& row : terminal.beamState().rows)
        offered.push_back(row.commandID);

    // Every offered action id is a catalog token. A `beam.`-prefixed id here
    // would mean the frontend had started naming actions again.
    int catalogCount = 0;
    const Ubiquitty::Input::NamedActionEntry* catalog = Ubiquitty::Input::namedActionCatalog(catalogCount);
    const auto isCatalogToken = [&](const std::string& id) {
        for (int i = 0; i < catalogCount; ++i)
            if (id == catalog[i].token)
                return true;
        return false;
    };
    const auto offers = [&](const char* id) {
        return std::find(offered.begin(), offered.end(), id) != offered.end();
    };

    // The drills are this page's own settings entries and keep their own ids;
    // everything else has to be an action Core named.
    int actionRows = 0;
    for (const std::string& id : offered) {
        if (id.starts_with("beam."))
            continue;
        CHECK_MSG(isCatalogToken(id), "an offered id that Core's catalog does not carry");
        ++actionRows;
    }
    CHECK(actionRows > 0);

    // Every action Core carries is either offered or named here with the reason
    // it is not. Listing the ones known to be missing is the mistake a
    // frontend-side list makes: an action added to the catalog later and wired
    // nowhere passes a check that enumerates the omissions known when it was
    // written. The loop is over CORE's table, so a new entry fails until someone
    // decides about it, at the moment the decision is cheap.
    struct DeliberateOmission {
        std::string_view token;
        const char* reason;
    };
    const DeliberateOmission omitted[] = {
        { "new_tab", "one page, one terminal" },
        { "close_tab", "one page, one terminal" },
        { "next_tab", "one page, one terminal" },
        { "prev_tab", "one page, one terminal" },
        { "new_window", "one page, one terminal" },
        { "toggle_beam", "you are looking at it" },
        { "toggle_fullscreen", "the browser gives it to the user through its own chrome" },
    };
    const auto isOmitted = [&](std::string_view token) {
        for (const DeliberateOmission& entry : omitted)
            if (entry.token == token)
                return true;
        return false;
    };

    for (int i = 0; i < catalogCount; ++i) {
        const std::string_view token = catalog[i].token;
        const bool isOffered = offers(std::string(token).c_str());
        CHECK_MSG(isOffered || isOmitted(token), "a catalog action neither offered nor deliberately omitted");
        CHECK_MSG(!(isOffered && isOmitted(token)), "an action listed as omitted is being offered");
    }

    // And the other direction, which is what stops the list above rotting into
    // an allowlist: an omission naming an action Core no longer carries goes
    // quiet exactly when the catalog changes underneath it.
    for (const DeliberateOmission& entry : omitted)
        CHECK_MSG(isCatalogToken(std::string(entry.token)), "an omission names an action Core no longer carries");
}

TEST(theBlocksScopeListsTheCommandsTheShellMarked)
{
    WebTerminal terminal(12, 40, 1);
    runCommand(terminal, 0, "$ echo one", "one");
    runCommand(terminal, 0, "$ echo two", "two");
    runCommand(terminal, 0, "$ echo three", "three");

    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@");

    CHECK_MSG(terminal.beamState().scope == Ubiquitty::CommandPalette::Scope::Blocks,
        "'@' retargeted the palette rather than filtering the actions for a literal '@'");
    CHECK_MSG(terminal.beamState().query.empty(), "and the prefix was stripped rather than left to filter");

    // Newest first, which is Core's order and not this frontend's.
    const auto& rows = terminal.beamState().rows;
    REQUIRE(rows.size() == 3);
    CHECK_STR_EQ(rows[0].title, "$ echo three");
    CHECK_STR_EQ(rows[1].title, "$ echo two");
    CHECK_STR_EQ(rows[2].title, "$ echo one");
}

// A failed command is marked on the row, because a palette that lists a failure
// identically to a success is a list the user has to re-read the buffer to use.
// Core reports the failure as a bool and names no presentation, so the glyph is
// this frontend's — and it must reach the drawn row, not stop at the command.
TEST(aFailedCommandsRowSaysSoAndASucceededOneDoesNot)
{
    WebTerminal terminal(12, 40, 1);
    runCommand(terminal, 0, "$ true", "");
    runCommand(terminal, 0, "$ false", "");
    // The status of `$ false`, reported where a shell reports one: at the prompt
    // that follows it. The bare prompt this leaves is not itself a block.
    feedText(terminal, "\033]133;D;1\007\033]133;A\007$ ");

    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@");

    const auto& rows = terminal.beamState().rows;
    REQUIRE(rows.size() == 2);
    CHECK_STR_EQ(rows[0].title, "$ false");
    CHECK_STR_EQ(rows[0].detail, "✗");
    CHECK_STR_EQ(rows[1].title, "$ true");
    CHECK_MSG(rows[1].detail.empty(), "a command that succeeded wears nothing");
}

// The two answers a frontend must not conflate. A buffer with no OSC 133 marks
// has nothing to list, which is not the same as having no terminal to read: the
// browser always has one, local or mirrored from a host, so the prefix is
// honoured and the scope opens empty. Refusing it instead would leave a literal
// '@' in the query, which reads as a palette that ignored a keystroke.
TEST(theBlocksScopeOpensEmptyRatherThanRefusingWithoutShellIntegration)
{
    WebTerminal terminal(12, 40, 1);
    feedText(terminal, "output from a shell that marks nothing\r\n");

    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@");

    CHECK_MSG(terminal.beamState().scope == Ubiquitty::CommandPalette::Scope::Blocks,
        "the browser has a terminal, so the scope is reachable with nothing in it");
    CHECK_MSG(terminal.beamState().query.empty(), "a refused prefix would have stayed in the query as text");
    CHECK_MSG(terminal.beamState().rows.empty(), "and there is nothing to list");
}

// The list is the buffer at the moment the palette opens. Registering it once
// would list the session as it stood the first time anyone pressed the key, and
// the command the user just ran — the one they are most likely reaching for —
// would be the one command missing.
TEST(theBlockListIsRebuiltOnEveryOpen)
{
    WebTerminal terminal(12, 40, 1);
    runCommand(terminal, 0, "$ echo one", "one");

    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@");
    CHECK_EQ(static_cast<int>(terminal.beamState().rows.size()), 1);
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0, 0); // leaves the scope
    terminal.feedBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0, 0); // closes
    CHECK_MSG(!terminal.isBeamOpen(), "the palette closed");

    runCommand(terminal, 0, "$ echo two", "two");
    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@");

    const auto& rows = terminal.beamState().rows;
    REQUIRE(rows.size() == 2);
    CHECK_STR_EQ(rows[0].title, "$ echo two");
}

// Accepting a block moves the viewport to it, and lands the prompt a quarter of
// the way down so the output below it is what the jump reveals.
//
// The row accepted here is the OLDER of two blocks, reached by filtering rather
// than by arrow keys: ranking puts it at position 0 while it is the second
// block, so a jump keyed on the row's POSITION would scroll to the newest one
// and the assertion below would read the wrong line.
TEST(acceptingABlockScrollsTheViewToIt)
{
    WebTerminal terminal(12, 40, 1);
    // A banner first, so the target prompt is not row 0: a block at the very top
    // of the buffer is reached by any jump that clamps to the oldest row, and
    // this case would pass against a scroll-to-top.
    for (int i = 0; i < 5; ++i)
        feedText(terminal, "banner\r\n");
    runCommand(terminal, 0, "$ echo first", "first");
    for (int i = 0; i < 40; ++i)
        feedText(terminal, "filler\r\n");
    runCommand(terminal, 0, "$ echo last", "last");

    const int landingRow = terminal.rows() / 4;
    CHECK_EQ(terminal.viewOffset(), 0);
    CHECK_MSG(visibleLine(terminal, landingRow) != "$ echo first",
        "the target is off screen, or the jump has nothing to prove");

    CHECK(terminal.toggleBeam());
    typeIntoBeam(terminal, "@first");
    const auto& rows = terminal.beamState().rows;
    REQUIRE(rows.size() == 1);
    CHECK_STR_EQ(rows[0].title, "$ echo first");
    CHECK(terminal.feedBeamKey(13u, 0, 0, 0));

    CHECK_MSG(!terminal.isBeamOpen(), "accepting closed the palette");
    CHECK_MSG(terminal.takeBeamCommand()[0] == 0,
        "the viewport is this object's, so the jump was applied here rather than handed to the page");
    CHECK_MSG(terminal.viewOffset() > 0, "the view moved back into history");
    CHECK_MSG(terminal.viewOffset() < terminal.scrollbackRows(),
        "and stopped at the block rather than running to the oldest row");
    CHECK_STR_EQ(visibleLine(terminal, landingRow), "$ echo first");
}

// The host here is only an in-memory screen connection and raw owner. No
// private file is created and no path is injected into any program.
TEST(aWebPasteWaitsForExactUploadCreditAndNeverExceedsOneChunk)
{
    using namespace Ubiquitty::Protocol::Control;
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    const std::vector<std::uint8_t> payload(2 * Sync::bulkChunkPayloadBytes + 7, 0x89);
    CHECK(terminal.buildPastePush("image/png", payload).empty());
    PageHost host(53);
    REQUIRE(feedWire(terminal, host.answer(terminal.buildHello(nullptr, 53))));
    const auto callFrame = terminal.buildPastePush("image/png", payload);
    REQUIRE(!callFrame.empty());
    host.receive(callFrame);
    const auto calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    const auto call = Sync::decodeCallRequest(calls.front().text);
    REQUIRE(call.outcome == RequestOutcome::Dispatch);
    CHECK(call.method == "paste.push");
    REQUIRE(call.id.isString());
    const auto manifest = pastePushParameters(call.params);
    REQUIRE(manifest);
    CHECK(manifest->mime == "image/png");
    CHECK_EQ(manifest->bytes, payload.size());
    CHECK(!call.params.find("data"));
    CHECK(terminal.buildPastePush("image/png", payload).empty());

    PasteUpload receiver;
    REQUIRE(receiver.begin(*manifest, 9, [](std::size_t) { return true; }));
    std::uint32_t nextIndex = 0;
    host.connection().setControlUploadReceiver([&](const Sync::BulkChunk& chunk) {
        CHECK_EQ(chunk.index, nextIndex++);
        CHECK(chunk.bytes.size() <= Sync::bulkChunkPayloadBytes);
        const auto accepted = receiver.accept(chunk, [] { return true; });
        return accepted == PasteUploadProgress::Refused ? Sync::ClientBulkDisposition::Refused : Sync::ClientBulkDisposition::Accepted; }, [&](std::uint32_t transfer) { return receiver.transfer() == transfer; });
    host.receive(terminal.takePendingHostFrame());
    CHECK_EQ(nextIndex, 0u);
    REQUIRE(host.connection().sendNotify(*pasteReadyNotify({ "not-this-call", manifest->pane, 9 })));
    REQUIRE(feedWire(terminal, host.flush()));
    host.receive(terminal.takePendingHostFrame());
    CHECK_EQ(nextIndex, 0u);

    const auto credit = pasteReadyNotify({ call.id.asString(), manifest->pane, 9 });
    REQUIRE(credit);
    REQUIRE(host.connection().sendNotify(*credit));
    REQUIRE(receiver.grantCredit(9));
    REQUIRE(feedWire(terminal, host.flush()));
    host.receive(terminal.takePendingHostFrame(Ubiquitty::Transport::guaranteedOutboundFrameBytes));
    CHECK_EQ(nextIndex, 0u);
    for (unsigned index = 0; index < 3; ++index) {
        REQUIRE(host.connection().sendNotify(*credit)); // An identical retry must not rewind.
        REQUIRE(feedWire(terminal, host.flush()));
        host.receive(terminal.takePendingHostFrame());
        CHECK_EQ(nextIndex, index + 1);
    }
    CHECK(receiver.isComplete());
    CHECK(std::ranges::equal(receiver.data(), payload));

    auto result = Ubiquitty::Codec::JSON::Value::object();
    result.set("pane", Ubiquitty::Codec::JSON::Value::number(manifest->pane));
    result.set("status", Ubiquitty::Codec::JSON::Value::string("busy"));
    result.set("path", Ubiquitty::Codec::JSON::Value::string("/tmp/not-a-real-file.png"));
    const auto answer = Ubiquitty::Codec::JSON::serialize(rpcResult(call.idOrNull(), std::move(result)));
    REQUIRE(host.connection().answerCall(calls.front().callIndex, answer) == Sync::CallAnswer::Sent);
    REQUIRE(feedWire(terminal, host.flush()));
    CHECK(!terminal.buildPastePush("image/png", payload).empty());
}

// The page delivers config.toml before create(), so a preference the person
// wrote is live by the time WebTerminal is constructed. Seeding a capability
// from a default-constructed `Values` instead reads every key at its default
// and discards what they wrote — and it passes every test that only checks the
// default, because the default is what it returns.
//
// `[security] password_detect` is the one where that matters most: it decides
// whether typing at a detected prompt is masked, so a discarded `false` masks
// input a person asked to see.
TEST(testPasswordDetectFollowsTheDeliveredPreferences)
{
    const std::string saved = Ubiquitty::Preferences::liveDocument();

    // Off is the non-default, so a seed that ignores the delivered values
    // answers `true` here and cannot answer `false` by accident.
    static_assert(Ubiquitty::Preferences::Defaults::passwordDetect, "off is the non-default");
    configureDocument("[security]\npassword_detect = false\n");
    {
        WebTerminal terminal(24, 80, 1);
        CHECK_MSG(!terminal.passwordDetectEnabled(),
            "a delivered password_detect = false reaches the terminal");
    }

    // And the key's absence still resolves through Core rather than through
    // Terminal.h's in-class value, which is a different number.
    configureDocument("");
    {
        WebTerminal terminal(24, 80, 1);
        CHECK_MSG(terminal.passwordDetectEnabled(),
            "an absent key resolves to Core's default, not to the member initialiser");
    }

    configureDocument(saved);
}

// `[font] size` is a double all the way from the reader to the field, so a
// fractional size is one a person can write and this arm has to honour. What
// loses it is arithmetic order: truncating the POINTS and multiplying by the
// device scale afterwards spends the fraction before the scale can express it.
//
// At scale 1 a half point cannot survive — the rasterizer wants whole pixels —
// so the case is stated at scale 2, where 15.5pt is 31px and 16pt is 32px and
// the two are only the same number under the wrong order.
TEST(testAFractionalFontSizeSurvivesToTheDeviceSize)
{
    const std::string saved = Ubiquitty::Preferences::liveDocument();

    auto devicePixelsForSize = [](double points, int glyphScale) {
        configureDocument("[font]\nsize = " + std::to_string(points) + "\n");
        WebTerminal terminal(4, 8, glyphScale);
        return terminal.fontPixelSize();
    };

    // The DEVICE size rather than the cell, because the cell cannot answer it
    // here: this arm rasterises through Unifont, a bitmap face upscaled by a
    // whole factor, so 31px and 32px land on the same cell whatever the size
    // asked for. The ordering is decided before that quantisation and this is
    // where it is visible.
    CHECK_MSG(devicePixelsForSize(15.0, 2) == 30, "a whole size scales exactly");
    CHECK_MSG(devicePixelsForSize(15.5, 2) == 31,
        "a half point at 2x is the odd pixel between them, not rounded away first");
    CHECK_MSG(devicePixelsForSize(16.0, 2) == 32, "and the whole size above is unmoved");

    // At scale 1 the fraction cannot survive and rounds to the nearest whole
    // pixel, which is the rasterizer's own limit rather than an ordering bug.
    CHECK_MSG(devicePixelsForSize(15.5, 1) == 16, "at 1x a half point rounds to the nearest pixel");

    configureDocument(saved);
}

// The clipboard a remote host does not have. The page is a full Sync client, so
// a program on the host that shells out for a clipboard can be answered from
// the browser's — which is the same asynchronous shape OSC 52 already takes
// here, with the answer going to a frame rather than an escape reply.
// Two clipboard questions can be outstanding at once: the host bounds what it
// has pending, not what it asks in a row, and a page reads its clipboard through
// a promise. The page starts a read for the first, the second lands while that
// promise is still unresolved, and the bytes the first read produced then get
// framed — under whichever id the page is holding.
//
// So the id has to be the one the read was started for. Framed under the newer
// id, the newer question is answered with the older question's bytes: a probe
// for type NAMES becomes an answer of zero bytes for text/plain, which the tool
// on the host reads as an empty clipboard. The older question then has no id
// left to answer under, and its tool waits out the host's whole deadline.
TEST(aSecondClipboardRequestWaitsBehindTheOneThePageIsReading)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Enabled);

    auto ask = [&terminal, &host](std::uint32_t id, Sync::ClipboardRequestKind kind, const char* mime) {
        Sync::ClipboardRequestMessage request;
        request.requestID = id;
        request.kind = kind;
        request.mime = mime;
        requestPageClipboard(terminal, host, request);
    };

    // `xclip -o -t TARGETS` and `pbpaste` in the same shell, in that order.
    ask(7, Sync::ClipboardRequestKind::Types, "");
    ask(8, Sync::ClipboardRequestKind::Item, "text/plain");

    // The page is still reading for 7, so 7 is what it reads back — the second
    // question does not displace the one whose answer is on its way.
    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 7);
    CHECK_MSG(terminal.pendingClipboardServeWantsTypes(), "the page is still serving the type probe");

    terminal.beginClipboardServeItems();
    terminal.addClipboardServeItem("text/plain", {});
    const std::vector<std::uint8_t>& first
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!first.empty());
    const auto firstDecoded = pageClipboardAnswer(host, first);
    REQUIRE(firstDecoded.has_value());
    CHECK_EQ(static_cast<int>(firstDecoded->requestID), 7);

    // And the second is still outstanding, with its own kind and mime, so the
    // next turn of the page's pump answers it rather than leaving its tool to
    // time out.
    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 8);
    CHECK_MSG(!terminal.pendingClipboardServeWantsTypes(), "the second question wants bytes");
    CHECK_STR_EQ(terminal.pendingClipboardServeMime(), "text/plain");

    terminal.beginClipboardServeItems();
    terminal.addClipboardServeItem("text/plain", {});
    const std::vector<std::uint8_t>& second
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!second.empty());
    const auto secondDecoded = pageClipboardAnswer(host, second);
    REQUIRE(secondDecoded.has_value());
    CHECK_EQ(static_cast<int>(secondDecoded->requestID), 8);
    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 0);
}

TEST(aPageAnswersTheHostsClipboardRequestFromItsOwn)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    // Opt in the way a real page does: staging on an unclaimed page is exactly
    // what the serve gate refuses.
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Enabled);

    // Nothing pending before the host asks, so a page polling every frame does
    // not answer a question nobody put.
    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 0);
    CHECK_MSG(terminal.buildClipboardServeAnswer(0).empty(), "no request, no frame");

    Sync::ClipboardRequestMessage ask;
    ask.requestID = 55;
    ask.kind = Sync::ClipboardRequestKind::Types;
    requestPageClipboard(terminal, host, ask);

    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 55);
    CHECK_MSG(terminal.pendingClipboardServeWantsTypes(), "the probe asks for types, not bytes");

    terminal.beginClipboardServeItems();
    terminal.addClipboardServeItem("image/png", {});
    terminal.addClipboardServeItem("text/plain", {});
    const std::vector<std::uint8_t>& answer
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!answer.empty());

    const auto decodedOpt = pageClipboardAnswer(host, answer);
    REQUIRE(decodedOpt.has_value());
    const Sync::ClipboardDataMessage& decoded = *decodedOpt;
    CHECK_EQ(static_cast<int>(decoded.requestID), 55);
    CHECK_EQ(static_cast<int>(decoded.status), static_cast<int>(Sync::ClipboardServeStatus::OK));
    CHECK_EQ(static_cast<int>(decoded.items.size()), 2);

    // The request is spent: a page that framed twice would answer an id the
    // host has already filed, and the host drops those.
    CHECK_EQ(static_cast<int>(terminal.pendingClipboardServeID()), 0);
}

// A page without the browser's permission refuses rather than going quiet. The
// program that asked is waiting, and a refusal it can see beats a wait it
// cannot end.
TEST(aPageWithoutPermissionRefusesRatherThanStayingSilent)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    // Opt in the way a real page does: staging on an unclaimed page is exactly
    // what the serve gate refuses.
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Enabled);

    Sync::ClipboardRequestMessage ask;
    ask.requestID = 8;
    ask.kind = Sync::ClipboardRequestKind::Item;
    ask.mime = "image/png";
    requestPageClipboard(terminal, host, ask);
    CHECK_MSG(!terminal.pendingClipboardServeWantsTypes(), "this one wants the bytes");
    CHECK_STR_EQ(terminal.pendingClipboardServeMime(), "image/png");

    const std::vector<std::uint8_t>& refusal
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::Refused));
    REQUIRE(!refusal.empty());
    const auto decodedOpt = pageClipboardAnswer(host, refusal);
    REQUIRE(decodedOpt.has_value());
    const Sync::ClipboardDataMessage& decoded = *decodedOpt;
    CHECK_EQ(static_cast<int>(decoded.status), static_cast<int>(Sync::ClipboardServeStatus::Refused));
    CHECK_MSG(decoded.items.empty(), "a refusal carries nothing");

    // A status the page passes wrongly becomes a refusal rather than an
    // accidental OK: the value crosses the wasm boundary as an integer.
    Sync::ClipboardRequestMessage second;
    second.requestID = 9;
    requestPageClipboard(terminal, host, second);
    const std::vector<std::uint8_t>& nonsense = terminal.buildClipboardServeAnswer(4242);
    REQUIRE(!nonsense.empty());
    const auto garbledOpt = pageClipboardAnswer(host, nonsense);
    REQUIRE(garbledOpt.has_value());
    const Sync::ClipboardDataMessage& garbled = *garbledOpt;
    CHECK_EQ(static_cast<int>(garbled.status), static_cast<int>(Sync::ClipboardServeStatus::Refused));
}

// A page staging more items than one answer carries stops at the cap.
//
// The page drives this from JavaScript, so the count is whatever a loop over
// navigator.clipboard.read() produced — a browser holding a long type list, or
// a caller that forgot to begin a fresh answer. Dropped at the door rather than
// grown without bound, and the answer that goes out is the one the wire's
// reader will accept.
TEST(aPageStagingPastTheItemMaximumKeepsWhatFits)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    // Opt in the way a real page does: staging on an unclaimed page is exactly
    // what the serve gate refuses.
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Enabled);

    Sync::ClipboardRequestMessage ask;
    ask.requestID = 71;
    ask.kind = Sync::ClipboardRequestKind::Types;
    requestPageClipboard(terminal, host, ask);

    terminal.beginClipboardServeItems();
    const std::size_t offered = Sync::maxClipboardServeItems + 7;
    for (std::size_t i = 0; i < offered; ++i)
        terminal.addClipboardServeItem("application/x-probe-" + std::to_string(i), {});

    const std::vector<std::uint8_t>& answer
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!answer.empty());
    const auto decodedOpt = pageClipboardAnswer(host, answer);
    REQUIRE(decodedOpt.has_value());
    const Sync::ClipboardDataMessage& decoded = *decodedOpt;
    CHECK_EQ(static_cast<int>(decoded.items.size()), static_cast<int>(Sync::maxClipboardServeItems));
    // Guarded rather than dereferenced: front() on an empty vector traps under
    // libc++ hardening, which kills the binary and takes the other 151 cases'
    // verdicts with it. A case must be able to FAIL.
    REQUIRE(!decoded.items.empty());
    // The ones it kept are the first offered, not an arbitrary window: a
    // browser lists its richest types first and a page truncating from the far
    // end would answer with the least useful of them.
    CHECK_STR_EQ(decoded.items.front().mime.c_str(), "application/x-probe-0");
}

// A page that never offered to serve answers nothing, whatever it staged.
//
// This is the hole the gate closes, and it is reachable: the three cases above
// stage an answer on an unclaimed page, and without the gate they are handed it
// back, because the page's own staging is the only thing consulted. The host
// records what a HELLO claimed, so an answer from a client that claimed nothing
// is a reply to a question the host does not believe it asked.
TEST(aPageThatNeverClaimedServesNothingHoweverItStaged)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal terminal(24, 80, 1);
    // The connection is established without an offer to serve the clipboard.
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Disabled);

    Sync::ClipboardRequestMessage ask;
    ask.requestID = 31;
    ask.kind = Sync::ClipboardRequestKind::Types;
    requestPageClipboard(terminal, host, ask);

    terminal.beginClipboardServeItems();
    terminal.addClipboardServeItem("text/plain", {});
    const std::vector<std::uint8_t>& answer
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!answer.empty());

    const auto decodedOpt = pageClipboardAnswer(host, answer);
    REQUIRE(decodedOpt.has_value());
    const Sync::ClipboardDataMessage& decoded = *decodedOpt;
    CHECK_EQ(static_cast<int>(decoded.status), static_cast<int>(Sync::ClipboardServeStatus::Refused));
    CHECK_MSG(decoded.items.empty(), "a refusal carries nothing, whatever the page staged");
}

// `clipboardRead = deny` refuses the shim route too, on the page as on a native
// client.
//
// A program on the host reads a clipboard by shelling out or by writing an
// OSC 52 query, whichever works. A person who set deny said programs may not
// read their clipboard, and the sentence names no transport — so a page that
// honoured only its own opt-in would be the way around the setting.
TEST(aDeniedClipboardReadRefusesThePageEvenWhenItClaimed)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    // Delivered before construction: the policy is seeded onto a Terminal when
    // it is built, so a later change would not reach this one. The pinned set
    // is restored at the end so the value does not leak into the cases after
    // this.
    configureDocument("[security]\nclipboard_read = \"deny\"\n");
    WebTerminal terminal(24, 80, 1);
    PageHost host(7);
    attachClipboardPage(terminal, host, WebTerminal::ClipboardServing::Enabled);

    Sync::ClipboardRequestMessage ask;
    ask.requestID = 32;
    ask.kind = Sync::ClipboardRequestKind::Types;
    requestPageClipboard(terminal, host, ask);

    terminal.beginClipboardServeItems();
    terminal.addClipboardServeItem("text/plain", {});
    const std::vector<std::uint8_t>& answer
        = terminal.buildClipboardServeAnswer(static_cast<int>(Sync::ClipboardServeStatus::OK));
    REQUIRE(!answer.empty());

    const auto decodedOpt = pageClipboardAnswer(host, answer);
    REQUIRE(decodedOpt.has_value());
    const Sync::ClipboardDataMessage& decoded = *decodedOpt;
    CHECK_EQ(static_cast<int>(decoded.status), static_cast<int>(Sync::ClipboardServeStatus::Refused));
    CHECK(decoded.items.empty());

    configureDocument("");
}

// The page offers its clipboard only when it says so. The offer exposes this
// browser's clipboard to every process on the host, so it is the page's
// decision and not a default.
TEST(aPageClaimsClipboardServingOnlyWhenItOptsIn)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    WebTerminal quiet(24, 80, 1);
    const std::vector<std::uint8_t>& plain = quiet.buildHello("");
    const auto plainDecoded = Sync::decodeGreet(helloPayload(plain));
    REQUIRE(plainDecoded.has_value());
    const Sync::Greet& decoded = *plainDecoded;
    CHECK_MSG(!decoded.request.servesClipboard,
        "a page that said nothing does not promise to serve its clipboard");

    WebTerminal serving(24, 80, 1);
    const std::vector<std::uint8_t>& opted = serving.buildHello(
        "", 0, WebTerminal::ClipboardServing::Enabled);
    const auto optedDecoded = Sync::decodeGreet(helloPayload(opted));
    REQUIRE(optedDecoded.has_value());
    const Sync::Greet& optedIn = *optedDecoded;
    CHECK_MSG(optedIn.request.servesClipboard,
        "and one that opted in does");
}

// `[font] features` reaches the browser through a FontFace descriptor, because
// this arm has no shaper of its own — the browser's is what applies a feature,
// and a descriptor is the only place to name one. Core parses the grammar and
// this composes the descriptor value, so the page pastes a string it cannot
// misread.
TEST(testFontFeaturesComposeADescriptorValue)
{
    const std::string saved = Ubiquitty::Preferences::liveDocument();
    configureDocument("");
    WebTerminal terminal(4, 8, 1);

    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()).empty(),
        "no specification names no feature");

    terminal.setFontFeatures("zero, ss01");
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"zero\" 1, \"ss01\" 1",
        "two bare tags compose as enabled, comma-separated, in the order written");

    // A disabled tag is SPELLED rather than omitted: the descriptor's default
    // for an unnamed feature is the face's own, so dropping it would enable
    // exactly the feature the reader asked to turn off.
    terminal.setFontFeatures("-calt");
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"calt\" 0",
        "a disabled tag is spelled with its zero rather than omitted");

    // An explicit value survives, which is what a parametric or alternate
    // feature is written with.
    terminal.setFontFeatures("ss02=2");
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"ss02\" 2",
        "an explicit alternate value survives");

    // Unlike the variations twin, no tag is held back. That one drops `wght`
    // because a descriptor outranks the property for the axis it names; a
    // feature has no property here to outrank.
    terminal.setFontFeatures("liga");
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"liga\" 1",
        "no tag is held back the way the variations twin holds back wght");

    configureDocument(saved);
}

// `[font] ligatures = false` reaches the browser, which is this arm's shaper and
// applies `liga`, `clig` and `calt` by default exactly as HarfBuzz does on the
// Linux one. There is no separate lever here: the policy is only expressible as
// a suppression inside the feature descriptor, so a setting that did not reach
// that descriptor could not reach the pixels either.
TEST(theLigatureToggleReachesTheFeatureDescriptor)
{
    const std::string saved = Ubiquitty::Preferences::liveDocument();
    configureDocument("");
    // Delivered as OFF before construction, so the seed is what has to carry it —
    // a setter-only wiring would leave a page that never calls one drawing
    // ligatures against a config that says no.
    configureDocument("[font]\nligatures = false\n");
    {
        WebTerminal seeded(4, 8, 1);
        CHECK_MSG(std::string(seeded.fontFeatureSettingsCSS()) == "\"liga\" 0, \"clig\" 0, \"calt\" 0",
            "a delivered ligatures = false reaches the descriptor at construction");
    }
    configureDocument("");

    WebTerminal terminal(4, 8, 1);

    // On by default, and an enabled policy asks for nothing: an empty
    // descriptor means the face's own behaviour, which is what "on" is.
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()).empty(),
        "ligatures on and no features named asks the browser for nothing");

    terminal.setLigatures(Ubiquitty::Rendering::Ligatures::Disabled);
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"liga\" 0, \"clig\" 0, \"calt\" 0",
        "the toggle names all three tags a shaper enables by default");

    // A feature named explicitly beats the toggle, because the specification is
    // appended after the suppression and a later entry wins. `calt` rather than
    // `liga` mirrors what the Linux arm measured: a face can carry its
    // operators under `calt` alone.
    terminal.setFontFeatures("+calt");
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"liga\" 0, \"clig\" 0, \"calt\" 0, \"calt\" 1",
        "an explicit feature is requested after the suppression, so it wins");

    // And turning ligatures back on drops the suppression while keeping what
    // the reader asked for.
    terminal.setLigatures(Ubiquitty::Rendering::Ligatures::Enabled);
    CHECK_MSG(std::string(terminal.fontFeatureSettingsCSS()) == "\"calt\" 1",
        "the suppression goes and the specification stays");

    configureDocument(saved);
}

TEST(testDiagonalsUseSharedGeometryInsteadOfCellClippedAtlasInk)
{
    WebTerminal terminal(4, 12, 1);
    terminal.feed("\x1b[?25l\u2571\u2572\u2573\r\n \u2571\u2572");
    CHECK(terminal.buildFrame());
    REQUIRE(terminal.cellInstanceCount() > 0);
    REQUIRE(terminal.boxFillInstanceCount() == 6);
    CHECK(!terminal.frameRequiresCPUCompositing());
    const auto& first = terminal.boxFillInstances()[0];
    CHECK(first.topLeftInPixels.x < 0);
    CHECK(first.bottomRightInPixels.x > terminal.cellWidth());
    for (int index = 0; index < terminal.cellInstanceCount(); ++index) {
        const auto& cell = terminal.cellInstances()[index];
        CHECK(cell.atlasTopLeft.x == cell.atlasBottomRight.x);
        CHECK(cell.atlasTopLeft.y == cell.atlasBottomRight.y);
    }
}

TEST(testBoxGeometryGrowsAndKeepsTheCursorTier)
{
    BlockCursorConfiguration configuration;
    WebTerminal terminal(1, 1, 1);
    terminal.setFocus(Ubiquitty::Modes::FocusState::Focused);
    terminal.feed("\u2573\x1b[H");
    CHECK(terminal.buildFrame());
    CHECK(terminal.boxFillInstanceCount() == 4);
    CHECK(terminal.cursorTier().boxFills == 2);
    // Each X has two quads, including the focused cursor's independently
    // coloured copy. The initial cell-sized capacity has room for only two.
    for (int index = 0; index < terminal.boxFillInstanceCount(); ++index) {
        const auto& quad = terminal.boxFillInstances()[index];
        CHECK(quad.bottomRightInPixels.x > quad.topLeftInPixels.x);
        CHECK(quad.bottomRightInPixels.y > quad.topLeftInPixels.y);
        CHECK(quad.shapeKind > 0);
    }
}

TEST(testOnlyADeclaredRendererAnswersTheProportionalMeasure)
{
    WebTerminal terminal(2, 20, 1);
    CHECK(terminal.drawnText() == Ubiquitty::Runtime::DrawnText::GridOnly);
    char reply[64] {};
    terminal.feed("\033]66;p=1:q=1:i=4;OK\033\\\033]66;p=1:c=6;OK\033\\");
    CHECK(terminal.takeReplies(reply) == 0);
    CHECK_EQ(terminal.cursorColumn(), 2);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    terminal.feed("\033]66;p=1:q=1:i=4;OK\033\\");
    const int length = terminal.takeReplies(reply);
    CHECK(std::string_view(reply, static_cast<std::size_t>(length)).starts_with("\033]66;i=4:c="));
}

TEST(testProportionalGlyphPageIsIndependentAndGrowsPastTheGrid)
{
    WebTerminal terminal(1, 20, 1);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    const std::string text = "\x1b[?25l\x1b]66;p=1:c=20;" + std::string(48, 'i') + "\x07";
    terminal.feed(text);
    CHECK(terminal.buildFrame());
    CHECK(terminal.proportionalAtlasPixels() != nullptr);
    CHECK(terminal.proportionalAtlasPixels() != terminal.atlasPixels());
    CHECK(terminal.proportionalAtlasPixels() != terminal.wideAtlasPixels());
    CHECK(terminal.proportionalGlyphInstanceCount() > terminal.rows() * terminal.columns());
    CHECK(terminal.wideGlyphInstanceCount() == 0);
    const auto proportionalGeneration = terminal.proportionalAtlasGeneration();
    CHECK(proportionalGeneration > 0);
    const auto monoGeneration = terminal.monoAtlasGeneration();
    CHECK(terminal.buildFrame());
    CHECK(terminal.proportionalAtlasGeneration() == proportionalGeneration);
    CHECK(terminal.monoAtlasGeneration() == monoGeneration);

    const std::vector<std::uint8_t>& image = terminal.render();
    CHECK(!image.empty());
    CHECK(terminal.proportionalAtlasGeneration() == proportionalGeneration);
    CHECK(terminal.cellWidth() == glyphWidth);
}

// The widest claim the protocol allows, packed: 600 characters, then the
// 1,024 the sixteen-per-cell ceiling permits a full-row claim to carry in
// its first cells, each drawn as its own glyph in source order. The buffers
// grow past the grid to hold them, and the count says how many were drawn.
TEST(testALongPackedProportionalRowDrawsEveryGlyphInOrder)
{
    for (const int count : { 600, 1024 }) {
        WebTerminal terminal(1, 1024, 1);
        terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
        const std::string text = "\x1b[?25l\x1b]66;p=1:c=1024;" + std::string(static_cast<std::size_t>(count), 'i') + "\x07";
        terminal.feed(text);
        CHECK(terminal.buildFrame());
        CHECK_MSG(terminal.proportionalGlyphInstanceCount() == count, "one glyph per character, whatever the grid holds");
        CHECK_MSG(terminal.proportionalStripInstanceCount() == 0, "drawn glyph by glyph, not as a strip");
        const Ubiquitty::Rendering::GlyphInstance* glyphs = terminal.proportionalGlyphInstances();
        CHECK(glyphs != nullptr);
        for (int i = 1; glyphs && i < count; ++i)
            CHECK_MSG(glyphs[i].originInPixels.x >= glyphs[i - 1].originInPixels.x, "in source order, left to right");
        // The 256th and the last glyph sit past the byte boundary an eight-bit
        // owner would fold, at the pens the strike's advances put them.
        if (glyphs && count > 256)
            CHECK(glyphs[256].originInPixels.x > glyphs[255].originInPixels.x);
    }
}

// Text past the claim: forty-eight letters in eight cells overflow it, and
// the run draws the glyphs that begin inside its cells and no other — the
// tail is cut at the claim, not drawn over the neighbour.
TEST(testAProportionalSourceTailPastTheClaimIsCutAtTheClaim)
{
    WebTerminal terminal(1, 20, 1);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    terminal.feed("\x1b[?25l\x1b]66;p=1:c=8;" + std::string(48, 'i') + "\x07");
    CHECK(terminal.buildFrame());
    const int drawn = terminal.proportionalGlyphInstanceCount();
    CHECK_MSG(drawn > 0 && drawn < 48, "some of the tail is cut");
    const float claimRight = 8.0f * static_cast<float>(terminal.cellWidth());
    const Ubiquitty::Rendering::GlyphInstance* glyphs = terminal.proportionalGlyphInstances();
    for (int i = 0; glyphs && i < drawn; ++i) {
        CHECK_MSG(glyphs[i].originInPixels.x < claimRight, "every drawn glyph begins inside the claim");
        CHECK_MSG(glyphs[i].originInPixels.x + glyphs[i].sizeInPixels.x <= claimRight + 0.01f, "and is cut at its edge");
    }
}

TEST(testOverlappingProportionalInkReachesTheWebStripStream)
{
    WebTerminal terminal(1, 20, 2);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    terminal.feed("\x1b[?25l\x1b]66;p=1:c=8;WWWW\x07");
    CHECK(terminal.buildFrame());
    CHECK(terminal.proportionalGlyphInstanceCount() == 0);
    CHECK(terminal.proportionalStripInstanceCount() == 1);
    CHECK(terminal.ligatureGlyphInstanceCount() == 0);
    CHECK(terminal.proportionalStripAtlasPixels() != nullptr);
    CHECK(terminal.proportionalStripAtlasPixels() != terminal.proportionalAtlasPixels());
    CHECK(terminal.proportionalStripAtlasPixels() != terminal.ligatureAtlasPixels());
    CHECK(terminal.proportionalStripAtlasWidth() > 0);
    CHECK(terminal.proportionalStripAtlasHeight() > 0);
    CHECK(terminal.proportionalStripAtlasIsDirty());
    terminal.didUploadProportionalStripAtlas();
    CHECK(!terminal.proportionalStripAtlasIsDirty());
    CHECK(terminal.buildFrame());
    CHECK(terminal.proportionalStripInstanceCount() == 1);
    CHECK(!terminal.proportionalStripAtlasIsDirty());
    terminal.rebuildFontStack();
    CHECK(terminal.proportionalStripAtlasIsDirty());
}

TEST(testFontResourceReplacementInvalidatesUnchangedAtlasCounters)
{
    WebTerminal terminal(1, 20, 1);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    terminal.feed("\x1b[?25lABC\x1b]66;p=1:c=10;iii\x07");
    CHECK(terminal.buildFrame());
    const auto fontGeneration = terminal.fontResourceGeneration();
    const auto proportionalGeneration = terminal.proportionalAtlasGeneration();
    const auto monoGeneration = terminal.monoAtlasGeneration();
    terminal.rebuildFontStack();
    CHECK(terminal.fontResourceGeneration() != fontGeneration);
    CHECK(terminal.buildFrame());
    CHECK(terminal.proportionalAtlasGeneration() == proportionalGeneration);
    CHECK(terminal.monoAtlasGeneration() == monoGeneration);
}

// The program-observable state a conformance harness reads back: the grid's
// text and styles, the cursor with its pending wrap, the replies Core queued,
// and each bell the program rang, counted one by one within a single feed.
TEST(testCaptureProgramStateReportsWhatTheProgramDid)
{
    WebTerminal terminal(2, 4, 1);
    terminal.feed("\033[1;31mAB\033[0mCD\a\a\033[5n\033]2;hi\a");
    const std::string_view state = terminal.captureProgramState();
    CHECK(state.find("\"text\":\"A\"") != std::string_view::npos);
    CHECK(state.find("\"fg\":1,\"bg\":null,\"bold\":true") != std::string_view::npos);
    CHECK(state.find("\"pendingWrap\":true") != std::string_view::npos);
    CHECK(state.find("\"title\":\"hi\"") != std::string_view::npos);
    char reply[64] {};
    const int length = terminal.takeReplies(reply);
    CHECK(std::string_view(reply, static_cast<std::size_t>(length)) == "\033[0n");
    CHECK(terminal.takeReplies(reply) == 0);
    CHECK(terminal.takeBellsRung() == 2);
    CHECK(terminal.takeBellsRung() == 0);
}

TEST(testCaptureProgramStateExposesTheSeparateHostWritableStatusRow)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    WebTerminal terminal(2, 6, 1);
    bool isJSON = false; // bool-ok: JSON parser result
    const JSON::Value initial = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* initialStatus = initial.find("statusRowText");
    REQUIRE(initialStatus);
    CHECK(initialStatus->isNull());

    terminal.feed("\033[2$~\033[1$}");
    terminal.feed("X\033\r");
    const JSON::Value written = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* writtenStatus = written.find("statusRowText");
    REQUIRE(writtenStatus && writtenStatus->isArray());
    REQUIRE(writtenStatus->items().size() == 6);
    CHECK(writtenStatus->items()[0].asString() == "X");
    CHECK(writtenStatus->items()[1].asString().empty());
    const auto* dataRows = written.find("rows");
    REQUIRE(dataRows && dataRows->isArray());
    const auto* firstDataCell = dataRows->items()[0].items()[0].find("text");
    REQUIRE(firstDataCell);
    CHECK(firstDataCell->asString().empty());

    terminal.feed("T");
    terminal.feed("\033[0$}M");
    const JSON::Value cancelled = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* cancelledStatus = cancelled.find("statusRowText");
    REQUIRE(cancelledStatus && cancelledStatus->isArray());
    CHECK(cancelledStatus->items()[0].asString().empty());
    const auto* cancelledRows = cancelled.find("rows");
    REQUIRE(cancelledRows && cancelledRows->isArray());
    const auto* writtenDataCell = cancelledRows->items()[0].items()[0].find("text");
    REQUIRE(writtenDataCell);
    CHECK(writtenDataCell->asString() == "M");

    terminal.feed("\033[0$~");
    const JSON::Value disabled = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* disabledStatus = disabled.find("statusRowText");
    REQUIRE(disabledStatus);
    CHECK(disabledStatus->isNull());
}

TEST(webProgramMetadataReadsDecodedRecordsWithoutDrainingThem)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    WebTerminal terminal(2, 4, 1);
    terminal.feed("\033]2;Review\a\033]7;file://host/srv/project\a"
                  "\033]7501;state=working:app=claude:progress=40\a"
                  "\033]7501;id=tool:state=blocked:kind=permission:msg=UnVuIHRlc3RzPw==\a"
                  "\033]9;4;1;25\a");
    bool isJSON = false; // bool-ok: JSON parser result
    const JSON::Value metadata = JSON::parse(terminal.programMetadataJSON(), isJSON);
    REQUIRE(isJSON);
    CHECK(metadata.stringOr("programTitle") == "Review");
    CHECK(metadata.stringOr("currentDirectory") == "/srv/project");
    REQUIRE(metadata.find("host"));
    CHECK(metadata.find("host")->isNull());
    CHECK(metadata.numberOr("primaryRecord", -1) == 1);
    const auto* records = metadata.find("records");
    REQUIRE(records && records->items().size() == 2);
    const auto& primary = records->items()[1];
    CHECK(primary.stringOr("state") == "blocked");
    CHECK(primary.stringOr("kind") == "permission");
    CHECK(primary.stringOr("app").empty());
    CHECK(primary.stringOr("effectiveApp") == "claude");
    CHECK(primary.stringOr("message") == "Run tests?");
    REQUIRE(primary.find("progress"));
    CHECK(primary.find("progress")->isNull());
    const auto* progress = metadata.find("progress");
    REQUIRE(progress);
    CHECK(progress->numberOr("state") == 1);
    CHECK(progress->numberOr("value") == 25);
    CHECK(JSON::serialize(metadata) == terminal.programMetadataJSON());
    CHECK(std::string_view(terminal.takeProgressReports()) == "{\"reports\":[[1,25]],\"overflow\":false}");

    // A malformed replacement leaves the decoded record intact; the page
    // never has to validate or interpret the OSC grammar itself.
    terminal.feed("\033]7501;id=tool:state=unknown\a");
    CHECK(JSON::serialize(metadata) == terminal.programMetadataJSON());
    terminal.feed("\033]7501;state=done:app=claude\a\033]133;D;7\a\033]133;A\a$ \033]133;B\a");
    const JSON::Value prompt = JSON::parse(terminal.programMetadataJSON(), isJSON);
    REQUIRE(isJSON);
    CHECK(prompt.boolOr("isReadingCommand"));
    CHECK(prompt.numberOr("exitStatus") == 7);
    const auto* retained = prompt.find("records");
    REQUIRE(retained && retained->items().size() == 1);
    CHECK(retained->items()[0].stringOr("state") == "done");
    terminal.feed("\033]7501;state=clear\a");
    const JSON::Value cleared = JSON::parse(terminal.programMetadataJSON(), isJSON);
    REQUIRE(isJSON);
    REQUIRE(cleared.find("primaryRecord"));
    CHECK(cleared.find("primaryRecord")->isNull());
    REQUIRE(cleared.find("records"));
    CHECK(cleared.find("records")->items().empty());
}

TEST(webProgramMetadataUsesHostRecordsWithoutAnotherScreen)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    namespace Sync = Ubiquitty::Protocol::Sync;
    AttachedPage page;
    page.programPrints("\033]7501;state=blocked:app=codex:kind=question\a");
    const auto checkpoints = page.host.connection().counters().checkpointsSent;
    Sync::PaneFacts facts;
    facts.programTitle = "remote review";
    facts.currentDirectory = "/srv/remote";
    facts.foreground = { 1234, "vim", 2 };
    facts.processChain = "zsh → vim";
    facts.processChainWithArguments = "zsh → vim README.md";
    facts.shellCommandName = "zsh";
    facts.terminalName = "ttys003";
    facts.hostName = "build-host";
    facts.progress = { 4, 65 };
    facts.exitStatus = 9;
    page.host.setFacts(facts);
    REQUIRE(feedWire(page.terminal, page.host.exchange(page.terminal)));
    bool isJSON = false; // bool-ok: JSON parser result
    const JSON::Value metadata = JSON::parse(page.terminal.programMetadataJSON(), isJSON);
    REQUIRE(isJSON);
    CHECK(metadata.stringOr("programTitle") == "remote review");
    CHECK(metadata.stringOr("currentDirectory") == "/srv/remote");
    const auto* host = metadata.find("host");
    REQUIRE(host);
    CHECK(host->stringOr("foregroundName") == "vim");
    CHECK(host->numberOr("foregroundProcessID") == 1234);
    CHECK(host->stringOr("processChain") == "zsh → vim");
    CHECK(host->stringOr("processChainWithArguments") == "zsh → vim README.md");
    CHECK(host->stringOr("shellCommandName") == "zsh");
    CHECK(host->stringOr("terminalName") == "ttys003");
    CHECK(host->stringOr("hostName") == "build-host");
    CHECK(!host->boolOr("isAtPrompt"));
    CHECK(!host->boolOr("didEnd"));
    CHECK(metadata.numberOr("exitStatus") == 9);
    const auto* records = metadata.find("records");
    REQUIRE(records && records->items().size() == 1);
    CHECK(records->items()[0].stringOr("effectiveApp") == "codex");
    const auto* progress = metadata.find("progress");
    REQUIRE(progress);
    CHECK(progress->numberOr("state") == 4);
    CHECK(progress->numberOr("value") == 65);
    CHECK(page.host.connection().counters().checkpointsSent == checkpoints);

    page.host.setFacts({});
    page.programPrints("\033]7501;state=clear\a");
    const JSON::Value cleared = JSON::parse(page.terminal.programMetadataJSON(), isJSON);
    REQUIRE(isJSON);
    CHECK(cleared.stringOr("programTitle").empty());
    CHECK(cleared.stringOr("currentDirectory").empty());
    const auto* clearedHost = cleared.find("host");
    REQUIRE(clearedHost);
    CHECK(clearedHost->stringOr("foregroundName").empty());
    REQUIRE(clearedHost->find("foregroundProcessID"));
    CHECK(clearedHost->find("foregroundProcessID")->isNull());
    REQUIRE(cleared.find("records"));
    CHECK(cleared.find("records")->items().empty());
    REQUIRE(cleared.find("exitStatus"));
    CHECK(cleared.find("exitStatus")->isNull());
}

TEST(testProgressReportsSurviveBatchedInputAndDrain)
{
    WebTerminal terminal(2, 4, 1);
    terminal.feed("\033]9;4;1;25\a\033]9;4;1;25\a\033]9;4;4;60\033\\\033]9;4;2\a\033]9;4;0\a");
    CHECK(std::string_view(terminal.takeProgressReports()) == "{\"reports\":[[1,25],[1,25],[4,60],[2,-1],[0,-1]],\"overflow\":false}");
    CHECK(std::string_view(terminal.takeProgressReports()) == "{\"reports\":[],\"overflow\":false}");
    for (int report = 0; report < 257; ++report)
        terminal.feed("\033]9;4;1;50\a");
    CHECK(std::string_view(terminal.takeProgressReports()).find("\"overflow\":true") != std::string_view::npos);
    CHECK(std::string_view(terminal.takeProgressReports()) == "{\"reports\":[],\"overflow\":false}");
}

TEST(capturedCellsExposeTheirSemanticRoles)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    WebTerminal terminal(2, 6, 1);
    terminal.feed("\033]133;A\007$ \033]133;B\007ls\033]133;C\007!");
    bool isJSON = false; // bool-ok: JSON parser result
    const JSON::Value state = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* rows = state.find("rows");
    REQUIRE(rows && rows->items().size() == 2);
    const auto& cells = rows->items()[0].items();
    REQUIRE(cells.size() == 6);
    const std::array expected { "prompt", "prompt", "input", "input", "output", "output" };
    for (std::size_t column = 0; column < expected.size(); ++column) {
        const auto* style = cells[column].find("style");
        REQUIRE(style);
        const auto* role = style->find("semantic");
        REQUIRE(role);
        CHECK(role->asString() == expected[column]);
    }
}

TEST(capturedSizedBlocksExposeTextOnlyAtTheirAnchor)
{
    namespace JSON = Ubiquitty::Codec::JSON;
    WebTerminal terminal(3, 6, 1);
    terminal.setDrawnText(Ubiquitty::Runtime::DrawnText::SizedAndProportional);
    terminal.feed("\033]66;s=3:w=2;X\033\\");
    bool isJSON = false; // bool-ok: JSON parser result
    const JSON::Value state = JSON::parse(terminal.captureProgramState(), isJSON);
    REQUIRE(isJSON);
    const auto* rows = state.find("rows");
    REQUIRE(rows && rows->items().size() == 3);
    for (std::size_t row = 0; row < rows->items().size(); ++row) {
        const auto& cells = rows->items()[row].items();
        REQUIRE(cells.size() == 6);
        for (std::size_t column = 0; column < cells.size(); ++column) {
            const auto* text = cells[column].find("text");
            REQUIRE(text);
            CHECK(text->asString() == (row == 0 && column == 0 ? "X" : ""));
        }
    }
}

TEST(testPromptRowsAreCapturedFromCoreMarkers)
{
    WebTerminal terminal(3, 6, 1);
    terminal.feed("\033[2;3H\033]9;12\a$");
    CHECK(std::string_view(terminal.captureProgramState()).find("\"promptRows\":[2]") != std::string_view::npos);
    terminal.feed("\033[3;1H\n");
    CHECK(std::string_view(terminal.captureProgramState()).find("\"promptRows\":[1]") != std::string_view::npos);
    terminal.feed("\033[2J");
    CHECK(std::string_view(terminal.captureProgramState()).find("\"promptRows\":[]") != std::string_view::npos);
}

// A config.toml that defines a theme and names it opens the grid in that
// theme, as every other arm's launch does; the page does not have to name it.
TEST(testTheConfiguredThemeColoursANewTerminal)
{
    (void)Ubiquitty::Preferences::configure("[appearance]\ntheme = \"paper\"\n\n[[themes]]\nname = \"paper\"\nfg = \"#102030\"\nbg = \"#fafafa\"\n", Ubiquitty::Preferences::ParseMode::Strict);
    {
        WebTerminal terminal(2, 4, 1);
        terminal.feed("\033]10;?\a");
        char reply[64] {};
        const int length = terminal.takeReplies(reply);
        CHECK(std::string_view(reply, static_cast<std::size_t>(length)) == "\033]10;rgb:1010/2020/3030\a");
    }
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
}

TEST(webSearchWaitsForThePumpAndDropsReplacedQueries)
{
    WebTerminal terminal(6, 40, 1);
    terminal.feed("needle.* first\r\nNeedle.* second\r\nneedle.* third\r\n");
    CHECK(terminal.searchLiteral("absent"));
    const auto oldGeneration = terminal.searchStatus().generation;
    CHECK(!terminal.searchStatus().isComplete);
    CHECK(terminal.searchLiteral("needle.*"));
    CHECK(terminal.searchStatus().generation > oldGeneration);
    CHECK(!terminal.stepSearch(Ubiquitty::Search::StepDirection::Older));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (terminal.pumpSearch() && std::chrono::steady_clock::now() < deadline) {
    }
    const auto found = terminal.searchStatus();
    CHECK(found.isComplete);
    CHECK_EQ(found.foundCount, 2);
    CHECK_EQ(found.activeIndex, 0);
    CHECK(terminal.searchLiteral("needle.*"));
    CHECK_EQ(terminal.searchStatus().generation, found.generation);
    CHECK(terminal.stepSearch(Ubiquitty::Search::StepDirection::Older));
    CHECK_EQ(terminal.searchStatus().activeIndex, 1);
    CHECK(terminal.searchStatus().revealEpoch > found.revealEpoch);
    CHECK(terminal.stepSearch(Ubiquitty::Search::StepDirection::Newer));
    CHECK_EQ(terminal.searchStatus().activeIndex, 0);
    bool isJSON = false;
    const auto status = Ubiquitty::Codec::JSON::parse(terminal.searchStatusJSON(), isJSON);
    CHECK(isJSON);
    REQUIRE(status.find("foundCount"));
    CHECK_EQ(status.find("foundCount")->asNumber(), 2);
}

TEST(webSearchRevealsHistoryOnceAndClearsItsHighlights)
{
    WebTerminal terminal(6, 40, 1);
    terminal.feed("\033[?25lneedle\r\n");
    for (int index = 0; index < 100; ++index)
        terminal.feed("ordinary line\r\n");
    CHECK(terminal.searchLiteralAndWait("needle"));
    REQUIRE(terminal.searchStatus().foundCount == 1);
    CHECK(terminal.viewOffset() > 0);
    const auto highlighted = terminal.render();
    CHECK(terminal.searchLiteral(""));
    while (terminal.pumpSearch()) {
    }
    CHECK(terminal.searchStatus().isComplete);
    CHECK_EQ(terminal.searchStatus().foundCount, 0);
    CHECK(terminal.render() != highlighted);
    CHECK(!terminal.stepSearch(Ubiquitty::Search::StepDirection::Older));

    CHECK(terminal.searchLiteralAndWait("needle"));
    terminal.scrollBy(-terminal.viewOffset());
    CHECK_EQ(terminal.viewOffset(), 0);
    CHECK(terminal.searchLiteral("needle"));
    CHECK(!terminal.pumpSearch());
    CHECK_EQ(terminal.viewOffset(), 0);
}

TEST(webSearchAutomationRefreshesAnIdenticalCompletedProbe)
{
    WebTerminal terminal(6, 40, 1);
    CHECK(terminal.searchLiteralAndWait("needle"));
    CHECK_EQ(terminal.searchStatus().foundCount, 0);
    terminal.feed("needle\r\n");
    CHECK(terminal.searchLiteralAndWait("needle"));
    CHECK_EQ(terminal.searchStatus().foundCount, 1);
    CHECK(terminal.searchStatus().isComplete);
}

UBIQUITTY_TEST_MAIN()

// The page's own gesture entry points, not Core's: a drag held while the
// page feeds more output must grow to the retained pointer row through
// WebTerminal's followTailOrHoldViewport, and a released one must not. This
// is the arm's wiring under test -- Core's answer is proven in
// test_terminal_selection, and a page that took the cheap viewport-only path
// with a gesture open would keep Core's answer from ever being asked.
TEST(aHeldDragOnThePageFollowsOutputAndAReleasedOneDoesNot)
{
    WebTerminal terminal(4, 12, 1);
    terminal.feed("anchor\r\nmiddle\r\npointer");
    press(terminal, 0, 0);
    drag(terminal, 2, 6);
    CHECK(terminal.hasSelection());
    const std::string before = terminal.selectionText();
    CHECK_MSG(before.find("new") == std::string::npos, "nothing past the pointer is selected before output");

    terminal.feed("\r\nnew\r\nmore");
    const std::string held = terminal.selectionText();
    CHECK_MSG(held.find("anchor") != std::string::npos, "the press stays attached to its buffer character");
    CHECK_MSG(held.find("new") != std::string::npos, "the held head grows to the retained pointer row");
    CHECK_MSG(held.find("more") == std::string::npos, "and stops at that row");

    release(terminal, 2, 6);
    terminal.feed("\r\nlater");
    CHECK_MSG(std::string(terminal.selectionText()).find("later") == std::string::npos,
        "a released selection does not grow with output");
}

// --- Resume across a reload ----------------------------------------------------

namespace {

/// The tab's session storage as the record store sees it: bytes that outlive
/// the page, which the test keeps between two pages.
struct TabStorage {
    std::optional<std::vector<std::uint8_t>> bytes;
    std::size_t writes = 0;
};

/// One page's view of the tab's storage.
class TabStorageSlot final : public Ubiquitty::Session::ResumeRecordSlot {
public:
    explicit TabStorageSlot(TabStorage& storage)
        : m_storage(storage)
    {
    }
    bool write(std::span<const std::uint8_t> bytes) override
    {
        m_storage.bytes.emplace(bytes.begin(), bytes.end());
        ++m_storage.writes;
        return true;
    }
    std::optional<std::vector<std::uint8_t>> read(std::size_t maxBytes) override
    {
        if (!m_storage.bytes || m_storage.bytes->size() > maxBytes)
            return std::nullopt;
        return m_storage.bytes;
    }
    bool erase() override
    {
        m_storage.bytes.reset();
        return true;
    }

private:
    TabStorage& m_storage;
};

/// Carries what the page and the host have for each other until both are quiet.
void exchangeWithHost(UbiquittyTest::AttachmentLink::Host& host, WebTerminal& page, std::uint64_t& now)
{
    for (int round = 0; round < 50; ++round, now += 2'000) {
        host.connection->receiveStream(page.takePendingHostFrame(), now);
        host.connection->service(now);
        std::vector<std::uint8_t> down;
        std::vector<std::uint8_t> frame;
        while (host.connection->popStreamFrame(frame, now)) {
            down.insert(down.end(), frame.begin(), frame.end());
            frame.clear();
        }
        if (!down.empty())
            CHECK(feedWire(page, down));
    }
}

} // namespace

// A reloaded page keeps its window: the stored picture is on screen before
// the first packet, the greeting names the stored client instance, and the
// host continues the attachment with a diff rather than a checkpoint.
TEST(aReloadedPageDrawsItsStoredPictureFirstAndResumesDiffed)
{
    namespace Link = UbiquittyTest::AttachmentLink;
    // The daemon instance names the pane's high half, so the fixture's pane
    // is session 9 of this host.
    Link::Host host({ 10, 42 });
    TabStorage storage;
    std::uint64_t now = 1'000'000;
    Ubiquitty::Protocol::Sync::ID128 kept;
    {
        WebTerminal first(24, 80, 1);
        REQUIRE(first.restoreResume(std::make_unique<TabStorageSlot>(storage), {}));
        CHECK(!first.showsRestoredPicture());
        kept = first.clientInstance();
        host.accept();
        host.connection->receiveStream(first.buildHello("t", 9), now);
        exchangeWithHost(host, first, now);
        REQUIRE(host.connection->state() == Ubiquitty::Protocol::Sync::ConnectionState::Attached);
        if (host.connection->boundPanes().empty())
            (void)host.connection->bindPane(*host.pane.source);
        UbiquittyTest::feed(host.pane.terminal, "before the reload\r\n");
        host.pane.source->publish(Ubiquitty::Protocol::Sync::FrameClass::Settled, now);
        exchangeWithHost(host, first, now);
        REQUIRE(screenText(first).find("before the reload") != std::string::npos);
        CHECK(storage.writes > 0);
        first.persistResume();
        host.lose(now);
    }
    REQUIRE(storage.bytes.has_value());
    UbiquittyTest::feed(host.pane.terminal, "while the page was gone\r\n");
    host.pane.source->publish(Ubiquitty::Protocol::Sync::FrameClass::Settled, now);

    WebTerminal second(24, 80, 1);
    REQUIRE(second.restoreResume(std::make_unique<TabStorageSlot>(storage), kept));
    CHECK(second.clientInstance() == kept);
    CHECK(second.showsRestoredPicture());
    const std::string restored = screenText(second);
    CHECK_MSG(restored.find("before the reload") != std::string::npos, "the stored picture is on screen before any packet");
    CHECK(restored.find("while the page was gone") == std::string::npos);

    const std::uint64_t checkpointsBefore = host.connection ? host.connection->counters().checkpointsSent : 0;
    CHECK_EQ(checkpointsBefore, 0u);
    host.accept();
    host.connection->receiveStream(second.buildHello("t", 9), now);
    exchangeWithHost(host, second, now);
    REQUIRE(host.connection->state() == Ubiquitty::Protocol::Sync::ConnectionState::Attached);
    CHECK(host.connection->clientInstance() == kept);
    CHECK_EQ(host.connection->counters().checkpointsSent, 0u);
    CHECK(!second.showsRestoredPicture());
    const std::string resumed = screenText(second);
    CHECK_MSG(resumed.find("while the page was gone") != std::string::npos, "the diff brings what was printed meanwhile");
    CHECK(resumed.find("before the reload") != std::string::npos);
}

// A record left by another window's instance is not drawn into this one: the
// store is purged and the page attaches as the instance it was given.
TEST(aStoredRecordOfAnotherInstanceIsPurgedNotDrawn)
{
    namespace Link = UbiquittyTest::AttachmentLink;
    Link::Host host({ 10, 42 });
    TabStorage storage;
    std::uint64_t now = 1'000'000;
    {
        WebTerminal first(24, 80, 1);
        REQUIRE(first.restoreResume(std::make_unique<TabStorageSlot>(storage), { 1, 2 }));
        host.accept();
        host.connection->receiveStream(first.buildHello("t", 9), now);
        exchangeWithHost(host, first, now);
        first.persistResume();
        host.lose(now);
    }
    REQUIRE(storage.bytes.has_value());
    WebTerminal second(24, 80, 1);
    REQUIRE(second.restoreResume(std::make_unique<TabStorageSlot>(storage), { 3, 4 }));
    CHECK((second.clientInstance() == Ubiquitty::Protocol::Sync::ID128 { 3, 4 }));
    CHECK(!second.showsRestoredPicture());
    CHECK(!storage.bytes.has_value());
}

namespace {

/// Attaches a page, types `z` into a connection that dies with that frame
/// unsent, and attaches again. The host kept no count of the page's input,
/// so `z` is in doubt.
///
/// - Parameters:
///   - host: The host.
///   - page: The page.
///   - now: The time, advanced past both attaches.
void attachThenLoseTyping(UbiquittyTest::AttachmentLink::Host& host, WebTerminal& page, std::uint64_t& now)
{
    host.accept();
    host.connection->receiveStream(page.buildHello("t", 9), now);
    exchangeWithHost(host, page, now);
    REQUIRE(host.connection->state() == Ubiquitty::Protocol::Sync::ConnectionState::Attached);
    if (host.connection->boundPanes().empty())
        (void)host.connection->bindPane(*host.pane.source);
    exchangeWithHost(host, page, now);
    CHECK(page.inputInDoubtNotice().message.empty());
    (void)page.buildInput("z");
    host.lose(now);
    host.accept();
    host.connection->receiveStream(page.buildHello("t", 9), now);
    exchangeWithHost(host, page, now);
    REQUIRE(host.connection->state() == Ubiquitty::Protocol::Sync::ConnectionState::Attached);
}

} // namespace

// A page whose typing a reconnect could not account for shows Core's notice,
// and nothing typed after it goes ahead of the person's answer.
TEST(aPageWithTypingInDoubtShowsCoresNoticeAndSendsNothingUnasked)
{
    UbiquittyTest::AttachmentLink::Host host({ 10, 42 });
    std::uint64_t now = 1'000'000;
    WebTerminal page(24, 80, 1);
    attachThenLoseTyping(host, page, now);
    const auto& notice = page.inputInDoubtNotice();
    CHECK_STR_EQ(notice.message, "Some of what you typed may not have reached the host");
    CHECK_STR_EQ(notice.resendButton, "Send Again");
    CHECK_STR_EQ(notice.discardButton, "Discard");
    host.connection->receiveStream(page.buildInput("w"), now);
    exchangeWithHost(host, page, now);
    CHECK_STR_EQ(host.pane.writer.bytes(), std::string());
    CHECK(!page.inputInDoubtNotice().message.empty());
}

// Send Again puts the typing in doubt on the wire ahead of what waited.
TEST(aPagesSendAgainWritesWhatWasInDoubtThenWhatWaited)
{
    UbiquittyTest::AttachmentLink::Host host({ 10, 42 });
    std::uint64_t now = 1'000'000;
    WebTerminal page(24, 80, 1);
    attachThenLoseTyping(host, page, now);
    host.connection->receiveStream(page.buildInput("w"), now);
    host.connection->receiveStream(page.resendInputInDoubt(), now);
    exchangeWithHost(host, page, now);
    CHECK_STR_EQ(host.pane.writer.bytes(), std::string("zw"));
    CHECK(page.inputInDoubtNotice().message.empty());
}

// Discard drops the typing in doubt, and what waited behind it goes.
TEST(aPagesDiscardDropsWhatWasInDoubtAndSendsWhatWaited)
{
    UbiquittyTest::AttachmentLink::Host host({ 10, 42 });
    std::uint64_t now = 1'000'000;
    WebTerminal page(24, 80, 1);
    attachThenLoseTyping(host, page, now);
    host.connection->receiveStream(page.buildInput("w"), now);
    host.connection->receiveStream(page.discardInputInDoubt(), now);
    exchangeWithHost(host, page, now);
    CHECK_STR_EQ(host.pane.writer.bytes(), std::string("w"));
    CHECK(page.inputInDoubtNotice().message.empty());
}

TEST(readlineMouseMovementReachesTheAttachedHost)
{
    AttachedPage page;
    page.programPrints("\033[?2001;2002h\033[1;6H");
    CHECK(press(page.terminal, 0, 2).empty());
    CHECK(page.programReads(release(page.terminal, 0, 2)) == "\033[D\033[D\033[D");
    auto middle = fact(Ubiquitty::Input::PointerFact::Kind::Press, Ubiquitty::Input::PointerButton::Middle, 0, 7, 1);
    CHECK(page.programReads(page.terminal.pointer(middle)) == "\033[C\033[C");
    CHECK((page.terminal.pointerVerdict() & WebTerminal::PointerVerdictConsumed) == 0);
}

TEST(pasteEventsSendMimeNamesAcrossSyncBeforeBracketedText)
{
    AttachedPage page;
    auto& terminal = page.terminal;
    page.programPrints("\033[?2004;5522h");
    CHECK(terminal.reportsPasteEvents());
    CHECK(page.programReads(terminal.buildPasteNotification("text/plain image/png"))
        == Ubiquitty::OSC::clipboardPasteNotification("text/plain image/png", Ubiquitty::ClipboardBuffer::Clipboard));
    CHECK(page.programReads(terminal.buildPaste("clipboard contents"))
        == Ubiquitty::OSC::clipboardPasteNotification("text/plain", Ubiquitty::ClipboardBuffer::Clipboard));
    page.programPrints("\033[?5522l");
    CHECK(!terminal.reportsPasteEvents());
    CHECK(terminal.buildPasteNotification("image/png").empty());
    CHECK(page.programReads(terminal.buildPaste("pasted")) == "\033[200~pasted\033[201~");
}

TEST(webCRTDeadlineRendersBlackAndHostInputRestoresText)
{
    WebTerminal terminal(2, 4, 1);
    terminal.feed("ABCD");
    CHECK(terminal.serviceDisplayIdle(Ubiquitty::PAL::monotonicTicks()) == -1);
    // The feed stamps the deadline on the clock, so whatever ran before `now`
    // is already spent: the render, and a loaded machine's scheduling.
    const auto beforeFeed = Ubiquitty::PAL::monotonicTicks();
    terminal.feed("\033[?97h");
    const auto original = terminal.render();
    const auto now = Ubiquitty::PAL::monotonicTicks();
    CHECK(terminal.serviceDisplayIdle(now) >= 108000 - static_cast<int>(now.since(beforeFeed)));
    CHECK(terminal.serviceDisplayIdle(Ubiquitty::Ticks(now.count + 108000)) == -1);
    const auto blank = terminal.render();
    REQUIRE(!blank.empty());
    for (std::size_t i = 0; i < blank.size(); i += 4) {
        CHECK(blank[i] == 0 && blank[i + 1] == 0 && blank[i + 2] == 0);
        CHECK(blank[i + 3] == 255);
    }
    terminal.feed(std::string_view("\0", 1));
    CHECK(terminal.serviceDisplayIdle(Ubiquitty::PAL::monotonicTicks()) > 107990);
    CHECK(terminal.render() == original);
}

TEST(workspaceViewsKeepIndependentPicturesAndInputOnOneCarrier)
{
    using namespace Ubiquitty;
    Terminal left, right;
    hardReset(left);
    hardReset(right);
    resize(left, 24, 80);
    resize(right, 24, 80);
    UbiquittyTest::TypedInput leftInput, rightInput;
    Sync::PaneSource leftSource(left, { .low = 1, .high = pageDaemonInstanceID });
    Sync::PaneSource rightSource(right, { .low = 2, .high = pageDaemonInstanceID });
    leftSource.setInputWriter(leftInput);
    rightSource.setInputWriter(rightInput);
    Sync::HostConnection host(Sync::measuredHostPolicy(0),
        { .hostInstanceID = { pageDaemonInstanceID, 0 }, .attachmentID = { 1, pageDaemonInstanceID }, .mayDrive = true, .verifiedKind = Sync::ClientKind::Human, .selection = { .target = Sync::AdmissionTarget::Workspace, .sessionID = 1, .workspaceID = 9, .daemonInstanceID = pageDaemonInstanceID, .socketName = "fixture.sock", .hostPlatform = "fixture" } });
    const auto imageBudget = std::make_shared<Sync::BulkSourceBudget>(Sync::maxCatalogMessageBytes);
    const auto aggregateImageBudget = std::make_shared<Sync::BulkSourceBudget>(4 * Sync::maxCatalogMessageBytes);
    host.setImageSourceAdmission([&host, imageBudget, aggregateImageBudget] {
        const auto retained = host.retainedOutboundPayloadBytes();
        return Sync::BulkSourceAdmission { .connection = imageBudget, .aggregate = aggregateImageBudget, .otherConnectionBytes = retained, .otherAggregateBytes = retained };
    });
    WebTerminal carrier(24, 80, 1, WebTerminal::ConnectionMode::Workspace);
    carrier.setWorkspaceID(9);
    std::uint64_t now = 1'000'000;
    const auto exchange = [&] {
        now += 20'000;
        host.receiveStream(carrier.takePendingHostFrame(), now);
        host.service(now);
        std::vector<std::uint8_t> frame;
        while (host.popStreamFrame(frame, now)) {
            CHECK(feedWire(carrier, frame));
            frame.clear();
        }
    };
    host.receiveStream(carrier.buildHello("t", 0), now);
    exchange();
    REQUIRE(carrier.isAttached());
    const auto leftHandle = host.bindPane(leftSource);
    const auto rightHandle = host.bindPane(rightSource);
    REQUIRE(leftHandle && rightHandle);
    exchange();
    WebTerminal first(24, 80, 1, WebTerminal::ConnectionMode::Session, &carrier, 1);
    WebTerminal second(24, 80, 1, WebTerminal::ConnectionMode::Session, &carrier, 2);
    first.setWorkspacePaneView(Sync::ViewState::Live);
    second.setWorkspacePaneView(Sync::ViewState::Live);
    exchange();
    processBytes(&left, "FIRST");
    processBytes(&right, "SECOND");
    for (int round = 0; round < 6; ++round) {
        leftSource.publish(Sync::FrameClass::Settled, now);
        rightSource.publish(Sync::FrameClass::Settled, now);
        exchange();
    }
    const auto firstRow = [](WebTerminal& pane) {
        bool isJSON = false;
        const auto state = Codec::JSON::parse(pane.captureProgramState(), isJSON);
        CHECK(isJSON);
        std::string text;
        const auto* rows = state.find("rows");
        if (rows && !rows->items().empty()) {
            for (const auto& cell : rows->items().front().items())
                text += cell.stringOr("text");
        }
        return text;
    };
    CHECK(firstRow(first).starts_with("FIRST"));
    CHECK(firstRow(second).starts_with("SECOND"));
    host.receiveStream(first.buildInput("one"), now);
    host.receiveStream(second.buildInput("two"), now);
    CHECK_STR_EQ(leftInput.bytes(), "one");
    CHECK_STR_EQ(rightInput.bytes(), "two");
    CHECK_EQ(first.sessionID(), 1u);
    CHECK_EQ(second.sessionID(), 2u);

    processBytes(&left, "\033[3;3H\033_Ga=T,f=24,s=1,v=1,i=88,p=8,c=2,r=1,C=1;/wAA\033\\");
    processBytes(&right, "\033[3;3H\033_Ga=T,f=24,s=1,v=1,i=88,p=8,c=2,r=1,C=1;AAD/\033\\");
    for (int round = 0; round < 12; ++round) {
        leftSource.publish(Sync::FrameClass::Settled, now);
        rightSource.publish(Sync::FrameClass::Settled, now);
        exchange();
    }
    const auto imagePixel = [](WebTerminal& pane) {
        CHECK(pane.buildFrame());
        CHECK(pane.frameRequiresCPUCompositing());
        const auto& pixels = pane.render();
        const auto offset = static_cast<std::size_t>((2 * pane.cellHeight() + pane.cellHeight() / 2) * pane.imageWidth() + 3 * pane.cellWidth()) * 4;
        return (static_cast<int>(pixels[offset]) << 16) | (static_cast<int>(pixels[offset + 1]) << 8) | pixels[offset + 2];
    };
    CHECK_EQ(imagePixel(first), 0xFF0000);
    CHECK_EQ(imagePixel(second), 0x0000FF);
}

TEST(webHostCallsValidateAndCorrelateExactReplies)
{
    WebTerminal page(24, 80, 1);
    PageHost host(1);
    CHECK(feedWire(page, host.answer(page.buildHello("t", 1))));
    CHECK(page.buildHostCall("not.a.method", "{}", 1).empty());
    CHECK(std::string(page.hostCallRefusal()).find("does not know") != std::string::npos);
    CHECK(page.buildHostCall("pane.processes", "{\"pane\":0}", 2).empty());
    CHECK(!std::string(page.hostCallRefusal()).empty());
    host.receive(page.buildHostCall("pane.processes", "{\"pane\":1}", 3));
    const auto calls = host.connection().takeCalls();
    REQUIRE(calls.size() == 1);
    CHECK(calls.front().text.find("ubiquitty.web-call.3") != std::string::npos);
    REQUIRE(host.connection().answerCall(calls.front().callIndex, R"({"jsonrpc":"2.0","id":"ubiquitty.web-call.3","result":{"pane":1,"available":true,"complete":true,"processes":[]}})") == Sync::CallAnswer::Sent);
    CHECK(feedWire(page, host.flush()));
    CHECK(std::string(page.takeHostCallResultJSON()).find("\"processes\":[]") != std::string::npos);
    CHECK_STR_EQ(page.takeHostCallResultJSON(), "");
}

TEST(workspaceDirectoryDiscoveryNeverCreatesASession)
{
    WebTerminal page(24, 80, 1, WebTerminal::ConnectionMode::Workspace);
    const auto directory = Sync::decodeGreet(helloPayload(page.buildHello("", 0)));
    REQUIRE(directory);
    CHECK(directory->request.target == Sync::AdmissionTarget::Control);
    CHECK_EQ(directory->request.sessionID, 0u);
    page.setWorkspaceID(42);
    const auto workspace = Sync::decodeGreet(helloPayload(page.buildHello("", 0)));
    REQUIRE(workspace);
    CHECK(workspace->request.target == Sync::AdmissionTarget::Workspace);
    CHECK_EQ(workspace->request.workspaceID, 42u);
}

TEST(webConsentQuestionsRetireOnlyTheirExactResolutionAndClearOnReconnect)
{
    WebTerminal page(24, 80, 1);
    PageHost host(1);
    REQUIRE(feedWire(page, host.answer(page.buildHello("t", 1))));
    const auto pending = Sync::consentQuestionNotify({ .requestID = 7, .sessionID = 1, .peerProcessID = 100, .peerProcess = "verified-agent", .agentLabel = "claimed name", .action = 0 });
    REQUIRE(pending);
    REQUIRE(host.connection().sendNotify(*pending));
    REQUIRE(feedWire(page, host.flush()));
    const auto questions = [&] {
        bool isJSON = false;
        auto state = Ubiquitty::Codec::JSON::parse(page.hostWorkspaceJSON(), isJSON);
        CHECK(isJSON);
        return state.find("questions")->items().size();
    };
    CHECK_EQ(questions(), 1u);
    const auto unrelated = Sync::consentResolvedNotify({ Sync::ConsentKind::Terminate, 7, 1 });
    REQUIRE(unrelated);
    REQUIRE(host.connection().sendNotify(*unrelated));
    REQUIRE(feedWire(page, host.flush()));
    CHECK_EQ(questions(), 1u);
    const auto exact = Sync::consentResolvedNotify({ Sync::ConsentKind::Attach, 7, 1 });
    REQUIRE(exact);
    REQUIRE(host.connection().sendNotify(*exact));
    REQUIRE(feedWire(page, host.flush()));
    CHECK_EQ(questions(), 0u);
    REQUIRE(host.connection().sendNotify(*pending));
    REQUIRE(feedWire(page, host.flush()));
    CHECK_EQ(questions(), 1u);
    (void)page.buildHello("t", 1);
    CHECK_EQ(questions(), 0u);
}

// --- The export shim, as the page calls it -------------------------------------
//
// The wasm module's entry points, compiled into this binary so a case calls
// them with the arguments the page passes. Compiled into this file rather than
// linked beside it because the module keeps its one terminal in a file-scope
// pointer no page ever frees, so a case frees it: left to the process's exit,
// it would be destroyed after the Core state built while the case ran.
#include "Platform/Web/WebExports.cpp"

namespace Ubiquitty::Wasm {

// The store the page's configuration blobs go into. The wasm preferences
// backend owns it, and a native Core links the POSIX backend in its place; the
// shim's blob entry point still names it, so it is defined here. No case reads
// it.
std::unordered_map<std::string, std::vector<std::byte>>& preferenceBlobs()
{
    static std::unordered_map<std::string, std::vector<std::byte>> blobs;
    return blobs;
}

} // namespace Ubiquitty::Wasm

namespace {

/// The module's own terminal attached to a host, every byte between them
/// crossing the module's entry points: the Greet, what the host sends, and
/// what the page owes back. The host's program reads what the host encodes,
/// as an `AttachedPage`'s does.
class ExportedPage {
public:
    /// - Parameters:
    ///   - rows: The grid's rows, the module's and the host's.
    ///   - columns: Its columns.
    explicit ExportedPage(int rows = 24, int columns = 80)
        : m_host(1, rows, columns)
        , m_encoder(m_host.terminal(), m_program)
    {
        ubiquittyWebCreate(rows, columns, 1);
        feed(m_host.answer(taken(ubiquittyWebBuildHello("t", 0, 0, nullptr, 0))));
        settle();
    }

    /// Frees the module's terminals, its carrier and any workspace panes, and
    /// forgets the module's last frame and active terminal, which point into
    /// them. All of it is the shim's file-scope state.
    ~ExportedPage()
    {
        frame = nullptr;
        terminal = nullptr;
        workspacePanes.clear();
        carrier.reset();
    }

    ExportedPage(const ExportedPage&) = delete;
    ExportedPage& operator=(const ExportedPage&) = delete;

    /// Copies out the frame an entry point returned, as the page reads it off
    /// the heap: from the returned base, for the length the module reports.
    ///
    /// - Parameter base: What the entry point returned; null for no frame.
    /// - Returns: The frame; empty for none.
    static std::vector<std::uint8_t> taken(const unsigned char* base)
    {
        if (!base)
            return {};
        return std::vector<std::uint8_t>(base, base + ubiquittyWebFrameLength());
    }

    /// The host's program prints, and the module's mirror follows.
    ///
    /// - Parameter bytes: What it prints.
    void programPrints(std::string_view bytes)
    {
        Ubiquitty::processBytes(&m_host.terminal(), bytes);
        settle();
    }

    /// The bytes the program reads for a frame the module returned: the host
    /// takes the frame, and each event in it is encoded under the program's
    /// modes as the host's writer does.
    ///
    /// - Parameter sent: The frame, as the page would send it.
    /// - Returns: The bytes; empty for a frame that carries no input.
    std::string programReads(const std::vector<std::uint8_t>& sent)
    {
        m_host.receive(sent);
        feed(m_host.flush());
        const std::size_t before = m_program.written.size();
        const std::vector<Ubiquitty::Protocol::Sync::InputIntent>& events = m_host.typed().events();
        for (; m_eventsEncoded < events.size(); ++m_eventsEncoded)
            (void)m_encoder.write({ 1, 2 }, events[m_eventsEncoded]);
        return m_program.written.substr(before);
    }

private:
    /// Carries what each end owes the other until both are quiet.
    void settle()
    {
        for (int round = 0; round < 3; ++round)
            feed(m_host.answer(taken(ubiquittyWebTakePendingHostFrame(0))));
    }

    /// Hands the module what the host sent.
    ///
    /// - Parameter wire: The host's bytes.
    static void feed(const std::vector<std::uint8_t>& wire)
    {
        (void)ubiquittyWebFeedFromHost(reinterpret_cast<const char*>(wire.data()), static_cast<int>(wire.size()));
    }

    PageHost m_host;
    ProgramBytes m_program;
    Ubiquitty::Runtime::RemoteInputEncoder m_encoder;
    std::size_t m_eventsEncoded = 0;
};

} // namespace

// DECSET 7403 through the module's pointer entry point. The page passes the
// Pointer Lock API's movementX and movementY as `deltaX` and `deltaY`, the
// shim copies them into the fact Core reads, and the report the program reads
// carries them, biased by 0x8000, as its two coordinates. Every other argument
// is a value neither delta takes, so one dropped or swapped with a neighbour
// shows in those numbers, and the two deltas differ, so a transposed pair
// shows in their order.
TEST(theModulesPointerExportCarriesItsDeltasIntoTheLockReport)
{
    ExportedPage page;
    REQUIRE_MSG(ubiquittyWebIsAttached() == 1, "premise: the module attached through its own entry points");
    page.programPrints("\033[?1016h\033[?7403h");
    REQUIRE_MSG(ubiquittyWebPointerLockActive() == 1, "the module sees the lock the program asked for");

    // Row 3, column 5, pixel (40, 60), no modifiers, one click, no drag, and
    // no measured x: the page's argument order, every value apart from the
    // deltas and their biased sums.
    const auto motion = [](int deltaX, int deltaY) {
        return ExportedPage::taken(ubiquittyWebPointer(ubiquittyWebPointerKindMotion(), ubiquittyWebPointerButtonNone(),
            3, 5, 40, 60, deltaX, deltaY, 0, 0, 0, 0, 1, 0, -1.0));
    };
    // From the first separator on: the two coordinates and the final byte,
    // past the button code the ladder chooses.
    const auto coordinates = [](const std::string& report) { return report.substr(std::min(report.find(';'), report.size())); };

    const std::string first = page.programReads(motion(-5, 7));
    CHECK_MSG(first.starts_with("\033[<"), "the program reads an SGR report");
    CHECK_STR_EQ(coordinates(first), ";32763;32775M");

    // A second pair through the same frame buffer, so each call is read for
    // its own arguments.
    const std::string second = page.programReads(motion(9, -3));
    CHECK_MSG(second.starts_with("\033[<"), "and one for the next motion");
    CHECK_STR_EQ(coordinates(second), ";32777;32765M");
}
