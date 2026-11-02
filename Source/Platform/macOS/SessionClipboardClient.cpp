// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/macOS/SessionClipboardClient.h"

#include "Core/Clipboard/ReadStage.h"
#include "Core/Clipboard/StagedClient.h"
#include "Core/Protocol/Sync/NativeAttachment.h"
#include "Core/Runtime/WorkspaceSession.h"
#include "Core/VT/Constants.h"
#include "PAL/Capability.h"
#include "Platform/Apple/CFAuto.h"
#include "Platform/macOS/SessionClipboardSeam.h"
#include "Platform/macOS/TypedPasteboard.h"
#include "Platform/macOS/UBCapabilityPolicy.h"
#include "Platform/macOS/UBFileReadClient.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace Ubiquitty::SessionClients {

namespace {

/// A Swift clipboard, released when the last holder lets it go. A write queued
/// for the main thread holds it too, so one queued as the pane closes still
/// lands.
using SharedClipboard = std::shared_ptr<void>;

/// A CoreFoundation copy of bytes for the seam; null when none could be made.
CFDataRef dataFrom(std::span<const char> bytes)
{
    return ::CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8*>(bytes.data()), static_cast<CFIndex>(bytes.size()));
}

/// The bytes the seam lent, viewed for the length of the call.
std::span<const char> viewOf(CFDataRef data)
{
    if (!data)
        return {};
    return { reinterpret_cast<const char*>(::CFDataGetBytePtr(data)), static_cast<std::size_t>(::CFDataGetLength(data)) };
}

/// Runs `work` on the main queue, once, owning it until then.
void onMain(std::function<void()> work)
{
    auto owned = std::make_unique<std::function<void()>>(std::move(work));
    dispatch_async_f(dispatch_get_main_queue(), owned.release(), [](void* context) {
        const std::unique_ptr<std::function<void()>> taken(static_cast<std::function<void()>*>(context));
        (*taken)();
    });
}

/// Adapts Core's virtual clipboard client to the Swift session clipboard.
/// Owned copies cross the ingest/main boundary; replies return through the
/// session command ring only while the client remains alive.
class SessionClipboardClient final : public Clipboard::StagedClient {
public:
    explicit SessionClipboardClient(Runtime::TerminalSession* session)
        : m_session(session)
        , m_fileReadClient(session->terminal())
        , m_isAlive(std::make_shared<std::atomic<bool>>(true))
        , m_clipboard(ubiquittySessionClipboardCreate(), &ubiquittySessionClipboardRelease)
    {
        Terminal* terminal = session->terminal();
        terminal->capabilityPolicy = &m_capabilityPolicy;
        terminal->fileReadClient = &m_fileReadClient;
    }

    /// Marks the work in flight stale: the client dies with its session, on
    /// the main thread that work runs on, so a prompt answered after the pane
    /// closed resolves nothing.
    ~SessionClipboardClient() override { m_isAlive->store(false); }

    /// Clears this client's model pointers before an adopted pane is released.
    ///
    /// - Parameter terminal: The adopted model, held under its owner's lock.
    void detach(Terminal& terminal)
    {
        m_isAlive->store(false);
        if (terminal.clipboardClient.get() == this)
            terminal.clipboardClient = nullptr;
        if (terminal.capabilityPolicy.isInstalled(&m_capabilityPolicy))
            terminal.capabilityPolicy = nullptr;
        if (terminal.fileReadClient.get() == &m_fileReadClient)
            terminal.fileReadClient = nullptr;
    }

    void writeClipboard(ClipboardBuffer buffer, std::span<const char> data) override
    {
        onMain([clipboard = m_clipboard, bytes = std::vector<char>(data.begin(), data.end()), buffer] {
            const Apple::UniqueCF<CFDataRef> owned(dataFrom(bytes));
            if (owned)
                ubiquittySessionClipboardWrite(clipboard.get(), owned.get(), static_cast<int>(buffer));
        });
    }

    void writeClipboardItems(ClipboardBuffer buffer, std::span<const ClipboardItem> items) override
    {
        if (buffer != ClipboardBuffer::Clipboard) {
            ClipboardClient::writeClipboardItems(buffer, items);
            return;
        }
        std::vector<std::pair<std::string, std::vector<char>>> owned;
        owned.reserve(items.size());
        for (const ClipboardItem& item : items)
            owned.emplace_back(std::string(item.mime), std::vector<char>(item.bytes.begin(), item.bytes.end()));
        onMain([owned = std::move(owned)] {
            std::vector<ClipboardItem> views;
            views.reserve(owned.size());
            for (const auto& [name, bytes] : owned)
                views.push_back({ name, bytes });
            TypedPasteboard::apply({}, views);
        });
    }

    // Remote capture runs on the frontend loop, where the pasteboard may be
    // read, and hands the sink the items while they are still borrowed.
    [[nodiscard]] bool captureClipboardForRemote(ClipboardBuffer, const std::function<void(std::span<const ClipboardItem>)>& sink) override
    {
        return TypedPasteboard::captureForRemote(sink);
    }

    [[nodiscard]] bool requestClipboardRead(ClipboardBuffer buffer, std::string_view setSpec, ClipboardReadConfirmation confirmation) override
    {
        std::string spec(setSpec.substr(0, std::min<std::size_t>(setSpec.size(), 15)));
        onMain([this, isAlive = m_isAlive, clipboard = m_clipboard, buffer, spec = std::move(spec), confirmation] {
            if (!isAlive->load())
                return;
            const Apple::UniqueCF<CFStringRef> setSpec(::CFStringCreateWithBytes(kCFAllocatorDefault,
                reinterpret_cast<const UInt8*>(spec.data()), static_cast<CFIndex>(spec.size()), kCFStringEncodingUTF8, false));
            auto pending = std::make_unique<PendingRead>(PendingRead { .client = this, .isAlive = isAlive, .buffer = buffer, .spec = spec });
            ubiquittySessionClipboardRequestRead(clipboard.get(), m_session->identityAddress(), static_cast<int>(buffer), setSpec ? setSpec.get() : CFSTR(""),
                confirmation == ClipboardReadConfirmation::Required ? UbiquittyClipboardReadConfirmation::Required : UbiquittyClipboardReadConfirmation::NotRequired,
                VT::maxExtendedClipboardReadBytes, pending.release(), &answerRead, &discardRead);
        });
        return true;
    }

private:
    /// A read asked of the Swift side, until it answers or is dropped.
    struct PendingRead {
        SessionClipboardClient* client;
        std::shared_ptr<std::atomic<bool>> isAlive;
        ClipboardBuffer buffer;
        std::string spec;
    };

    static void answerRead(void* context, UbiquittyClipboardReadDecision decision, CFDataRef bytes)
    {
        const bool isApproved = decision == UbiquittyClipboardReadDecision::Approved;
        const std::unique_ptr<PendingRead> pending(static_cast<PendingRead*>(context));
        if (!pending->isAlive->load())
            return;
        SessionClipboardClient* client = pending->client;
        if (isApproved) {
            client->provideClipboardReadBytes(pending->buffer, viewOf(bytes));
            // The general clipboard's typed items ride with its text, read here,
            // once, on the main-thread turn the answer arrived on: the Swift
            // side is asked to leave them to this caller.
            client->provideSnapshot(pending->buffer == ClipboardBuffer::Clipboard
                    ? TypedPasteboard::capture({}, VT::maxExtendedClipboardReadBytes)
                    : Clipboard::Snapshot {});
        }
        client->m_session->resolveClipboardRead(pending->spec, isApproved ? OSC::ClipboardReadDecision::Approved : OSC::ClipboardReadDecision::Refused);
    }

    static void discardRead(void* context) { std::unique_ptr<PendingRead>(static_cast<PendingRead*>(context)).reset(); }

    Runtime::TerminalSession* m_session;
    UBCapabilityPolicy m_capabilityPolicy;
    UBFileReadClient m_fileReadClient;
    std::shared_ptr<std::atomic<bool>> m_isAlive;
    SharedClipboard m_clipboard;
};

} // namespace

void install(void*, Runtime::TerminalSession& session)
{
    auto client = std::make_unique<SessionClipboardClient>(&session);
    if (Terminal* terminal = session.terminal())
        terminal->clipboardClient = client.get();
    session.adoptClientOwnership(std::move(client), [](Terminal& terminal, ClipboardClient& owned) {
        static_cast<SessionClipboardClient&>(owned).detach(terminal);
    });
}

void registerAsDefaultInstaller()
{
    Runtime::WorkspaceSession::setDefaultTerminalClientInstaller(&install, nullptr);
}

} // namespace Ubiquitty::SessionClients
