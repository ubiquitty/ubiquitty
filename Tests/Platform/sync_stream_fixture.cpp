// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/sync_stream_fixture.cpp — writes the stream a host sends a
// client that attached, for the Emacs and Neovim clients' decoder tests to read.
//
// The bytes are the host's own: a Sync host connection publishes a live
// terminal, and what it writes is recorded as direct canonical envelopes.
// A real Core client takes the same bytes beside the
// recording and acknowledges them, so the update after the checkpoint is the
// one a host sends a client that kept up, rather than one built by hand.
//
// The terminal is driven to a state whose every asserted value is chosen
// rather than incidental — a cursor neither at the origin nor in the corner,
// a first row that is unmistakable, a row of wide, sized, clustered and
// proportional cells — so a decoder that walks a field wrong reads a wrong
// answer instead of a plausible one.
//
// Writes, in order: the attach (Welcome, PaneBind, CheckpointHead and the
// checkpoint's BulkChunks), the update that follows more output, and, when a
// third path is given, the frames a host sends about a client's input and on
// the control channel, each from the host's own encoder: a Receipt, a
// PasteReceipt, an InputDiscarded, a Notify, a Result, a Call and a Bye; and,
// when a fourth path is given, the attach of a second pane holding one picture
// from each image protocol, with the image lane admitted.
//
// With `--verify <upstream>` it reads instead: the frames an editor's client
// sent, which it decodes with the host's own decoders, refusing any it would
// refuse, and prints as a transcript. A Greet is handed to a host connection,
// which must welcome it. A key is printed as the bytes the host's key encoder
// writes for it, under the default modes and under application cursor keys,
// and a pointer event as the report it writes under SGR mouse tracking, so a
// transcript says what the program would be sent.
//

#include "Core/Image/TerminalImage.h"
#include "Core/Protocol/Sync/Connection.h"
#include "Core/Protocol/Sync/Envelope.h"
#include "Core/Protocol/Sync/Messages.h"
#include "Core/Runtime/KeyEncode.h"
#include "Core/Runtime/RemoteInput.h"
#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace {

using namespace Ubiquitty::Protocol;

/// A Core client's policy with the capabilities an editor's Greet names: the
/// echo context, and neither deflated checkpoints nor the span and scroll
/// ops, so the host sends what it would send an editor.
Sync::ClientPolicy editorClientPolicy()
{
    Sync::ClientPolicy policy = Sync::measuredClientPolicy(0);
    policy.capabilities = Sync::ClientCapabilities { Sync::ClientCapability::EchoContext };
    return policy;
}

/// Whether a carrier's host admits the image lane.
enum class ImageLane : std::uint8_t {
    Closed,
    Admitted,
};

/// The host's end and a Core client's end of one connection, on a shared
/// clock, with everything the host sends recorded as canonical envelopes. The client
/// keeps no history, as the editors' clients announce.
class Carrier {
public:
    explicit Carrier(const Ubiquitty::Terminal& terminal, ImageLane imageLane = ImageLane::Closed)
        : m_source(terminal, { .low = 7, .high = 0x5EED })
        , m_host(Sync::measuredHostPolicy(0), Sync::HostIdentity { .hostInstanceID = { 1, 2 }, .attachmentID = { 3, 4 }, .resumeSecret = { 5, 6 }, .principal = "fixture", .selection = { .target = Sync::AdmissionTarget::Session, .sessionID = 7, .workspaceID = 0, .daemonInstanceID = 0x5EED, .socketName = "fixture.sock", .buildFlags = 0, .hostPlatform = "fixture" } })
        , m_client(editorClientPolicy(), Sync::ClientIdentity { .clientInstance = { 7, 8 }, .kind = Sync::ClientKind::Human, .facts = { .viewportRows = 6, .viewportColumns = 20, .cellPixelWidth = 0, .cellPixelHeight = 0, .textAreaPixelWidth = 0, .textAreaPixelHeight = 0, .refreshIntervalMicroseconds = 0, .link = Sync::LinkCost::Unmetered, .power = Sync::PowerState::Normal, .isFocused = true } }, nullptr)
    {
        // The image lane is admitted as a daemon admits it for a client that
        // can draw pictures: one connection budget under one aggregate.
        if (imageLane == ImageLane::Admitted) {
            m_host.setImageSourceAdmission([this] {
                return Sync::BulkSourceAdmission { .connection = m_imageBudget, .aggregate = m_imageBudget, .otherConnectionBytes = m_host.retainedOutboundPayloadBytes(), .otherAggregateBytes = m_host.retainedOutboundPayloadBytes() };
            });
        }
        m_client.start();
        m_host.receiveStream(m_client.takeStreamOutput(), advance());
    }

    /// Publishes the terminal and returns what the host sends for it, as
    /// canonical envelopes; the client takes the same bytes and acknowledges them.
    /// A pane the host binds is sent its screen once the client's `View`
    /// shows it, so the first publish carries two rounds: the bind, then the
    /// checkpoint.
    std::vector<std::uint8_t> publish()
    {
        const bool isBinding = m_handle == 0;
        if (isBinding)
            m_handle = m_host.bindPane(m_source);
        m_source.publish(Sync::FrameClass::Settled, m_now);
        std::vector<std::uint8_t> recorded;
        for (int round = 0; round < (isBinding ? 2 : 1); ++round) {
            const std::uint64_t now = advance();
            m_host.service(now);
            std::vector<std::uint8_t> envelope;
            for (;;) {
                envelope.clear();
                if (!m_host.popStreamFrame(envelope, now))
                    break;
                recorded.insert(recorded.end(), envelope.begin(), envelope.end());
                m_client.receiveStream(envelope, now);
            }
            m_client.tick(advance());
            m_host.receiveStream(m_client.takeStreamOutput(), advance());
        }
        return recorded;
    }

    [[nodiscard]] std::uint32_t handle() const { return m_handle; }
    [[nodiscard]] const Sync::ClientConnection& client() const { return m_client; }

private:
    std::uint64_t advance()
    {
        m_now += 20'000;
        return m_now;
    }

    std::shared_ptr<Sync::BulkSourceBudget> m_imageBudget = std::make_shared<Sync::BulkSourceBudget>(Sync::maxCatalogMessageBytes);
    Sync::PaneSource m_source;
    Sync::HostConnection m_host;
    Sync::ClientConnection m_client;
    std::uint64_t m_now = 1'000'000;
    std::uint32_t m_handle = 0;
};

bool writeFile(const char* path, const std::vector<std::uint8_t>& bytes)
{
    std::FILE* out = std::fopen(path, "wb");
    if (!out) {
        std::fprintf(stderr, "sync_stream_fixture: cannot write %s\n", path);
        return false;
    }
    const std::size_t written = std::fwrite(bytes.data(), 1, bytes.size(), out);
    std::fclose(out);
    if (written != bytes.size()) {
        std::fprintf(stderr, "sync_stream_fixture: short write to %s\n", path);
        return false;
    }
    return true;
}

/// Appends one direct canonical envelope from its actual message encoder.
template<typename Message>
void record(std::vector<std::uint8_t>& stream, Sync::FrameKind kind, std::uint32_t channel, const Message& message)
{
    std::vector<std::uint8_t> body;
    Sync::encode(body, message);
    std::vector<std::uint8_t> envelope;
    if (!Sync::appendFrame(envelope, kind, channel, body)) {
        std::fprintf(stderr, "sync_stream_fixture: a frame of kind %u was refused by its own encoder\n", static_cast<unsigned>(kind));
        return;
    }
    stream.insert(stream.end(), envelope.begin(), envelope.end());
}

/// The frames a host sends about a client's input and on the control channel.
std::vector<std::uint8_t> inputAndControlFrames(std::uint32_t handle)
{
    std::vector<std::uint8_t> stream;
    record(stream, Sync::FrameKind::Receipt, handle, Sync::Receipt { .inputWritten = 1, .inputSettled = 1 });
    record(stream, Sync::FrameKind::PasteReceipt, handle, Sync::PasteReceipt { .inputSeq = 2, .bytesWritten = 8192 });
    record(stream, Sync::FrameKind::InputDiscarded, handle, Sync::InputDiscarded { .inputWritten = 3, .throughSeq = 5 });
    record(stream, Sync::FrameKind::Notify, 0, Sync::Notify { .kind = Sync::NotifyKind::Attachments, .record = { 4, 0, 0, 0, 0, 0, 0, 0, 0 } });
    record(stream, Sync::FrameKind::Result, 0, Sync::Result { .transfer = 0, .text = R"({"jsonrpc":"2.0","id":7,"result":null})" });
    record(stream, Sync::FrameKind::Call, 0, Sync::Call { .text = R"({"jsonrpc":"2.0","id":9,"method":"nothing.here"})" });
    record(stream, Sync::FrameKind::Bye, 0, Sync::Bye { .reason = Sync::ByeReason::Superseded, .detail = "moved" });
    Sync::PaneFacts facts;
    facts.revision = 7;
    facts.programTitle = "recorded-title";
    facts.currentDirectory = "/srv/project";
    facts.homeDirectory = "/home/user";
    facts.currentFileURL = "file:///srv/project/README";
    facts.processChain = "less ◂ -zsh";
    facts.processChainWithArguments = "less README ◂ -zsh";
    facts.shellCommandName = "zsh";
    facts.terminalName = "ttys004";
    facts.hostName = "fixture";
    facts.foreground = { .processID = 73, .name = "less", .generation = 2 };
    facts.hasMarkedPrompt = true;
    facts.progress = { .state = Ubiquitty::OSC::ProgressNormal, .value = 42 };
    facts.indicator = Sync::IndicatorFacts { .red = 1, .green = 2, .blue = 3, .label = "building" };
    facts.tabColor = Sync::TabColorFacts { .red = 4, .green = 5, .blue = 6 };
    facts.badgeText = "badge";
    facts.userVariables.push_back({ .name = "user.project", .value = "ubiquitty" });
    facts.exitStatus = -2;
    facts.geometry.owner = Sync::ID128 { 3, 4 };
    facts.geometry.isPinned = true;
    facts.geometry.pinnedBy = Sync::ID128 { 5, 6 };
    facts.attention.hasUnseenNotification = true;
    facts.attention.notificationTitle = "done";
    facts.attention.notificationBody = "finished";
    for (unsigned pass = 0; pass < 2; ++pass) {
        std::vector<std::uint8_t> body;
        Sync::encodePaneFacts(body, facts);
        std::vector<std::uint8_t> envelope;
        (void)Sync::appendFrame(envelope, Sync::FrameKind::PaneFacts, handle, body);
        stream.insert(stream.end(), envelope.begin(), envelope.end());
        facts = {};
        facts.revision = 8;
        facts.isAtPrompt = true;
    }
    return stream;
}

std::optional<std::vector<std::uint8_t>> readFile(const char* path)
{
    std::FILE* in = std::fopen(path, "rb");
    if (!in)
        return std::nullopt;
    std::vector<std::uint8_t> bytes;
    std::array<std::uint8_t, 65536> chunk {};
    for (;;) {
        const std::size_t got = std::fread(chunk.data(), 1, chunk.size(), in);
        bytes.insert(bytes.end(), chunk.begin(), chunk.begin() + static_cast<std::ptrdiff_t>(got));
        if (got < chunk.size())
            break;
    }
    std::fclose(in);
    return bytes;
}

/// Bytes as a transcript spells them: printable ASCII as itself, the rest as
/// `\xNN`.
std::string spelled(std::span<const char> bytes)
{
    std::string out;
    for (const char byte : bytes) {
        const auto value = static_cast<unsigned char>(byte);
        if (value >= 0x20 && value < 0x7F && value != '\\') {
            out.push_back(byte);
        } else {
            std::array<char, 8> hex {};
            std::snprintf(hex.data(), hex.size(), "\\x%02X", static_cast<unsigned>(value));
            out += hex.data();
        }
    }
    return out;
}

std::string spelled(std::span<const std::uint8_t> bytes)
{
    return spelled(std::span<const char> { reinterpret_cast<const char*>(bytes.data()), bytes.size() });
}

/// The bytes the host's key encoder writes for a wire key event on `terminal`.
std::string encodedKey(const Ubiquitty::Terminal& terminal, const Sync::KeyEvent& event)
{
    std::array<char, 128> buffer {};
    const Ubiquitty::Runtime::KeyEncoding encoding = Ubiquitty::Runtime::encodeKey(terminal, Ubiquitty::Runtime::keyPressOf(event), buffer);
    return spelled(std::span<const char> { buffer.data(), static_cast<std::size_t>(encoding.length) });
}

Ubiquitty::Mouse::EventType mouseEventTypeOf(Sync::PointerEventKind kind)
{
    switch (kind) {
    case Sync::PointerEventKind::Press:
        return Ubiquitty::Mouse::EventType::Press;
    case Sync::PointerEventKind::Release:
        return Ubiquitty::Mouse::EventType::Release;
    case Sync::PointerEventKind::Motion:
        break;
    }
    return Ubiquitty::Mouse::EventType::Motion;
}

/// Decodes the frames a client sent and prints them as a transcript.
///
/// - Returns: The process exit code: 0 when every frame is one the host
///   reads, 1 otherwise.
int verifyUpstream(const char* path)
{
    const std::optional<std::vector<std::uint8_t>> upstream = readFile(path);
    if (!upstream) {
        std::fprintf(stderr, "sync_stream_fixture: cannot read %s\n", path);
        return 1;
    }
    Ubiquitty::Terminal plain;
    Ubiquitty::resize(plain, 6, 20);
    Ubiquitty::Terminal applicationCursor;
    Ubiquitty::resize(applicationCursor, 6, 20);
    Ubiquitty::processBytes(&applicationCursor, "\x1b[?1h");
    Ubiquitty::Terminal mouse;
    Ubiquitty::resize(mouse, 6, 20);
    Ubiquitty::processBytes(&mouse, "\x1b[?1000h\x1b[?1006h");

    int failures = 0;
    const auto refuse = [&](const char* what) {
        std::printf("REFUSED %s\n", what);
        ++failures;
    };
    Sync::FrameDecoder frames;
    frames.append(*upstream);
    while (const std::optional<Sync::Frame> frame = frames.next()) {
        // A Result is among them: the host calls nothing, so a client's
        // Result answers nothing and closes its connection.
        if (Sync::directionOf(frame->kind) == Sync::Direction::HostToClient) {
            refuse("a kind only a host sends");
            continue;
        }
        const std::uint32_t channel = frame->channel;
        switch (frame->kind) {
        case Sync::FrameKind::Greet: {
            const std::optional<Sync::Greet> greet = Sync::decodeGreet(frame->body);
            if (!greet) {
                refuse("Greet");
                break;
            }
            // The host's own verdict on it: a connection given the Greet
            // welcomes the client or closes.
            Sync::HostConnection host(Sync::measuredHostPolicy(0), Sync::HostIdentity { .hostInstanceID = { 1, 2 }, .attachmentID = { 3, 4 }, .resumeSecret = { 5, 6 }, .principal = "fixture", .selection = { .target = Sync::AdmissionTarget::Session, .sessionID = 7, .workspaceID = 0, .daemonInstanceID = 0x5EED, .socketName = "fixture.sock", .buildFlags = 0, .hostPlatform = "fixture" } });
            std::vector<std::uint8_t> bytes;
            (void)Sync::appendFrame(bytes, frame->kind, frame->channel, frame->body);
            host.receiveStream(bytes, 1'000'000);
            std::printf("Greet version=%u viewport=%ux%u focused=%d historyCacheLines=%u capabilities=%u resume=%d welcomed=%d\n",
                static_cast<unsigned>(greet->wireVersion), static_cast<unsigned>(greet->facts.viewportColumns),
                static_cast<unsigned>(greet->facts.viewportRows), greet->facts.isFocused ? 1 : 0, static_cast<unsigned>(greet->historyCacheLines),
                static_cast<unsigned>(greet->capabilities.toRaw()), greet->resume ? 1 : 0, host.state() == Sync::ConnectionState::Attached ? 1 : 0);
            if (host.state() != Sync::ConnectionState::Attached)
                ++failures;
            break;
        }
        case Sync::FrameKind::Facts: {
            const std::optional<Sync::Facts> facts = Sync::decodeFacts(frame->body);
            if (!facts) {
                refuse("Facts");
                break;
            }
            std::printf("Facts viewport=%ux%u pixels=%u refresh=%u link=%u power=%u focused=%d palette=%d", static_cast<unsigned>(facts->viewportColumns),
                static_cast<unsigned>(facts->viewportRows), static_cast<unsigned>(facts->cellPixelWidth + facts->cellPixelHeight + facts->textAreaPixelWidth + facts->textAreaPixelHeight),
                static_cast<unsigned>(facts->refreshIntervalMicroseconds), static_cast<unsigned>(facts->link), static_cast<unsigned>(facts->power), facts->isFocused ? 1 : 0,
                facts->themePalette ? 1 : 0);
            if (facts->themePalette) {
                const Ubiquitty::TermPalette& live = facts->themePalette->live;
                std::printf(" ansi15=%04x%04x%04x cursor=%04x%04x%04x", static_cast<unsigned>(live.indexed[15].red), static_cast<unsigned>(live.indexed[15].green),
                    static_cast<unsigned>(live.indexed[15].blue), static_cast<unsigned>(live.cursor.red), static_cast<unsigned>(live.cursor.green), static_cast<unsigned>(live.cursor.blue));
                std::printf(" ansi1=%04x%04x%04x foreground=%04x%04x%04x background=%04x%04x%04x baselineSame=%d", static_cast<unsigned>(live.indexed[1].red),
                    static_cast<unsigned>(live.indexed[1].green), static_cast<unsigned>(live.indexed[1].blue), static_cast<unsigned>(live.defaultForeground.red),
                    static_cast<unsigned>(live.defaultForeground.green), static_cast<unsigned>(live.defaultForeground.blue), static_cast<unsigned>(live.defaultBackground.red),
                    static_cast<unsigned>(live.defaultBackground.green), static_cast<unsigned>(live.defaultBackground.blue), facts->themePalette->baseline == live ? 1 : 0);
            }
            std::printf("\n");
            break;
        }
        case Sync::FrameKind::Ack:
            if (Sync::decodeAck(frame->body))
                std::printf("Ack\n");
            else
                refuse("Ack");
            break;
        case Sync::FrameKind::Echo:
            if (Sync::decodeEcho(frame->body))
                std::printf("Echo\n");
            else
                refuse("Echo");
            break;
        case Sync::FrameKind::View: {
            const std::optional<Sync::View> view = Sync::decodeView(frame->body);
            if (view)
                std::printf("View pane=%u state=%u\n", channel, static_cast<unsigned>(view->state));
            else
                refuse("View");
            break;
        }
        case Sync::FrameKind::Resync:
            if (Sync::decodeResync(frame->body))
                std::printf("Resync pane=%u\n", channel);
            else
                refuse("Resync");
            break;
        case Sync::FrameKind::Raw: {
            const std::optional<Sync::Raw> raw = Sync::decodeRaw(frame->body);
            if (raw && raw->bytes.size() > 32)
                std::printf("Raw pane=%u seq=%llu bytes=%zu first=%s\n", channel, static_cast<unsigned long long>(raw->inputSeq), raw->bytes.size(), spelled(raw->bytes.first(8)).c_str());
            else if (raw)
                std::printf("Raw pane=%u seq=%llu bytes=%s\n", channel, static_cast<unsigned long long>(raw->inputSeq), spelled(raw->bytes).c_str());
            else
                refuse("Raw");
            break;
        }
        case Sync::FrameKind::Keys: {
            const std::optional<Sync::Keys> keys = Sync::decodeKeys(frame->body);
            if (!keys) {
                refuse("Keys");
                break;
            }
            for (const Sync::KeyEvent& event : keys->events)
                std::printf("Keys pane=%u seq=%llu key=%u modifiers=%u writes=%s applicationCursor=%s\n", channel, static_cast<unsigned long long>(keys->inputSeq),
                    static_cast<unsigned>(event.key), static_cast<unsigned>(event.modifiers), encodedKey(plain, event).c_str(), encodedKey(applicationCursor, event).c_str());
            break;
        }
        case Sync::FrameKind::Pointer: {
            const std::optional<Sync::Pointer> pointer = Sync::decodePointer(frame->body);
            if (!pointer) {
                refuse("Pointer");
                break;
            }
            for (const Sync::PointerEvent& event : pointer->events) {
                std::array<char, 64> buffer {};
                const int length = Ubiquitty::encodeMouseReport(mouse, mouseEventTypeOf(event.kind), event.button, event.row, event.column, event.modifiers, buffer);
                std::printf("Pointer pane=%u seq=%llu kind=%u button=%u row=%u column=%u writes=%s\n", channel, static_cast<unsigned long long>(pointer->inputSeq),
                    static_cast<unsigned>(event.kind), static_cast<unsigned>(event.button), static_cast<unsigned>(event.row), static_cast<unsigned>(event.column),
                    spelled(std::span<const char> { buffer.data(), static_cast<std::size_t>(std::max(length, 0)) }).c_str());
            }
            break;
        }
        case Sync::FrameKind::Focus: {
            const std::optional<Sync::Focus> focus = Sync::decodeFocus(frame->body);
            if (focus)
                std::printf("Focus pane=%u focused=%d\n", channel, focus->isFocused ? 1 : 0);
            else
                refuse("Focus");
            break;
        }
        case Sync::FrameKind::Viewport: {
            const std::optional<Sync::Viewport> viewport = Sync::decodeViewport(frame->body);
            if (viewport)
                std::printf("Viewport pane=%u viewport=%ux%u cellPixels=%ux%u textAreaPixels=%ux%u drawablePixels=%ux%u\n", channel, viewport->columns, viewport->rows,
                    viewport->cellPixelWidth, viewport->cellPixelHeight, viewport->textAreaPixelWidth, viewport->textAreaPixelHeight, viewport->drawablePixelWidth, viewport->drawablePixelHeight);
            else
                refuse("Viewport");
            break;
        }
        case Sync::FrameKind::Paste: {
            const std::optional<Sync::Paste> paste = Sync::decodePaste(frame->body);
            if (paste)
                std::printf("Paste pane=%u seq=%llu offset=%llu state=%u bytes=%zu first=%s\n", channel, static_cast<unsigned long long>(paste->inputSeq),
                    static_cast<unsigned long long>(paste->offset), static_cast<unsigned>(paste->state), paste->text.size(),
                    spelled(paste->text.first(std::min<std::size_t>(paste->text.size(), 8))).c_str());
            else
                refuse("Paste");
            break;
        }
        case Sync::FrameKind::PasteAbort: {
            const std::optional<Sync::PasteAbort> abort = Sync::decodePasteAbort(frame->body);
            if (abort)
                std::printf("PasteAbort pane=%u seq=%llu\n", channel, static_cast<unsigned long long>(abort->inputSeq));
            else
                refuse("PasteAbort");
            break;
        }
        case Sync::FrameKind::Bye:
            if (Sync::decodeBye(frame->body))
                std::printf("Bye\n");
            else
                refuse("Bye");
            break;
        default:
            std::printf("REFUSED kind %u, which this transcript does not read\n", static_cast<unsigned>(frame->kind));
            ++failures;
            break;
        }
    }
    if (frames.error() != Sync::EnvelopeError::None || frames.bufferedBytes() != 0) {
        std::printf("REFUSED a frame longer than the wire carries\n");
        ++failures;
    }
    return failures == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc == 3 && std::strcmp(argv[1], "--verify") == 0)
        return verifyUpstream(argv[2]);
    if (argc < 3) {
        std::fprintf(stderr, "usage: sync_stream_fixture <attach-path> <update-path> [input-and-control-path [pictures-path]]\n       sync_stream_fixture --verify <upstream-path>\n");
        return 2;
    }

    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 6, 20); // six rows of twenty columns
    // Sized text is drawn, so OSC 66 interns a spec and stamps it into the
    // cells rather than flattening to plain text before the frame is built.
    terminal.drawsSizedText = true;
    terminal.drawsProportionalText = true;

    // Row 0 is the marker the decoder tests read back character by character.
    // Row 1 carries an SGR run, so a decoder that lands on the wrong pen
    // reports the wrong colours as well as the wrong glyphs.
    Ubiquitty::processBytes(&terminal,
        "UBIQUITTY-SYNC-OK\r\n"
        "\x1b[31mRED\x1b[0m plain\r\n"
        "third\r\n");

    // Row 3 is the row whose cells are not plain ASCII, one shape per group of
    // columns:
    //
    //   0-3   two wide glyphs, each a lead cell and the continuation the Core
    //         writes beside it, which travel as one unit
    //   4-5   a sized cell (OSC 66 fraction) carrying a grapheme cluster, so
    //         its cluster reference names the cluster pool while its pen names
    //         a text-size spec
    //   6-9   a proportional run, whose anchor's cluster reference names the
    //         run-text store under a spec that is proportional
    //
    // The two stores mint ids from one space each, so the sized cell and the
    // run anchor both carry id 1 and only the spec they name separates them.
    Ubiquitty::processBytes(&terminal, "\x1b[4;1H\xE6\x97\xA5\xE6\x9C\xAC");
    Ubiquitty::processBytes(&terminal,
        "\x1b]66;n=1:d=2;\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\x07");
    Ubiquitty::processBytes(&terminal, "\x1b]66;p=1:c=4;PROP\x07");

    // Columns 18-19: a wide glyph in the row's last two columns, where a client
    // that counts a continuation cell as a trailing blank erases the half it
    // already painted.
    Ubiquitty::processBytes(&terminal, "\x1b[4;19H\xE4\xB8\x96"); // U+4E16

    // Mouse tracking in the SGR encoding and bracketed paste: the modes a
    // client has to read out of the modes block to encode its input.
    Ubiquitty::processBytes(&terminal, "\x1b[?1000h\x1b[?1006h\x1b[?2004h");

    // A cursor at a position that is neither the origin nor the corner: a
    // field misread as a cursor position lands on a small plausible integer,
    // which is exactly the failure that makes a wrong decoder look right.
    Ubiquitty::processBytes(&terminal, "\x1b[5;9H");

    terminal.titleStackLength = 10;
    terminal.titleStackValid = 0x3FF;
    terminal.iconNameStackValid = 0x3FF;
    for (std::size_t index = 0; index < terminal.titleStackCapacity; ++index) {
        (void)terminal.titleUTF8Stack[index].tryAssign("window label");
        (void)terminal.iconNameUTF8Stack[index].tryAssign("icon label");
    }
    terminal.lineTabStops.set(200);
    terminal.lineHome = 2;
    terminal.mousePointerShapeStack.fill(Ubiquitty::MousePointerShape::NorthResize);
    terminal.mousePointerShapeStackLength = 16;
    terminal.alternateMousePointerShapeStack.fill(Ubiquitty::MousePointerShape::SouthResize);
    terminal.alternateMousePointerShapeStackLength = 16;
    (void)terminal.tabAlignments.tryResize(Ubiquitty::maxColumns);
    (void)terminal.tabAlignmentTargets.tryResize(Ubiquitty::maxColumns);
    terminal.tabAlignments[200] = Ubiquitty::CharacterTabAlignment::TargetCharacter;
    terminal.tabAlignmentTargets[200] = 0x754C;
    terminal.shouldEndSemanticRoleAtLineBreak = true;

    Carrier carrier(terminal);
    const std::vector<std::uint8_t> attach = carrier.publish();
    if (carrier.handle() == 0 || carrier.client().paneGeneration(carrier.handle()) == 0) {
        std::fprintf(stderr, "sync_stream_fixture: the Core client did not take the checkpoint\n");
        return 1;
    }
    if (!writeFile(argv[1], attach))
        return 1;

    // The update a client that kept up is sent next: a row written, the cursor
    // moved past the text, and bracketed paste turned off, so a decoder that
    // applies only rows still shows the old cursor and the old mode.
    Ubiquitty::processBytes(&terminal, "\x1b[6;1Hupdate-row-six\x1b[?2004l");
    const std::uint64_t checkpointGeneration = carrier.client().paneGeneration(carrier.handle());
    const std::vector<std::uint8_t> update = carrier.publish();
    if (carrier.client().paneGeneration(carrier.handle()) <= checkpointGeneration) {
        std::fprintf(stderr, "sync_stream_fixture: the Core client did not take the update\n");
        return 1;
    }
    if (!writeFile(argv[2], update))
        return 1;
    if (argc > 3 && !writeFile(argv[3], inputAndControlFrames(carrier.handle())))
        return 1;

    // A second pane, attached with the image lane admitted, holding one
    // picture from each protocol, so the editors decode the ImagePlacements
    // body the host writes rather than one built to their own idea of it:
    //
    //   an OSC 1337 24x24 PNG in a 24px box at row 0, column 11, whose drawn
    //   size is 24x24 device pixels and whose cell box is the 3x2 cells it
    //   covers at the fallback 8x16 cell;
    //   a kitty 8x16 raw-RGB image at its natural size at row 3, column 16,
    //   with no cell box and no drawn size.
    if (argc > 4) {
        Ubiquitty::Terminal pictures;
        Ubiquitty::resize(pictures, 6, 20);
        Ubiquitty::processBytes(&pictures, "pictures\r\n\x1b[1;12H");
        Ubiquitty::processBytes(&pictures,
            "\x1b]1337;File=inline=1;width=24px;height=24px:"
            "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAL0lEQVR42mO4Y6RPELXOZCCIGEYNGjVo1CC8Bql1XyKItnYyEESjBo0aNGoQXgQAtVDf3/jjW+IAAAAASUVORK5CYII=\x07");
        std::string kitty = "\x1b[4;17H\x1b_Ga=T,f=24,s=8,v=16,C=1;";
        for (int group = 0; group < 8 * 16; ++group)
            kitty += "3DIv";
        kitty += "\x1b\\";
        Ubiquitty::processBytes(&pictures, kitty);
        Ubiquitty::drainAsyncDecodes(pictures);
        if (Ubiquitty::Image::placementCount(&pictures) != 2) {
            std::fprintf(stderr, "sync_stream_fixture: the picture pane holds %d placements, not 2\n", Ubiquitty::Image::placementCount(&pictures));
            return 1;
        }
        Carrier pictureCarrier(pictures, ImageLane::Admitted);
        const std::vector<std::uint8_t> pictureStream = pictureCarrier.publish();
        if (!writeFile(argv[4], pictureStream))
            return 1;
    }

    std::printf("sync_stream_fixture: attach %zu bytes, update %zu bytes, wire version %u\n",
        attach.size(), update.size(), static_cast<unsigned>(Sync::wireVersion));
    return 0;
}
