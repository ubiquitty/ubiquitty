// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/iOS/SessionBridge.cpp — see SessionBridge.h.
//
// Adapts native carrier and observer hooks to the portable session clients.
// Control requests use the same dispatcher without creating a terminal.

#include "Platform/iOS/SessionBridge.h"

#include "Core/Protocol/Sync/FrameIngress.h"
#include "Core/Protocol/Sync/NativeAttachment.h"
#include "Core/Protocol/Sync/QUICBootstrap.h"
#include "Core/Runtime/PostedDispatcher.h"
#include "Core/Session/RemoteBootstrap.h"
#include "Core/Session/RemoteSessionCore.h"
#include "Core/Session/SSHReach.h"
#include "Core/Session/SessionDirectoryCore.h"
#include "Core/Terminal.h"
#include "Core/Transport/CarrierCapacity.h"
#include "Core/Transport/DelegatedChannel.h"
#include "Core/Transport/KnownHosts.h"
#include "Core/Transport/Origin.h"
#if defined(UBIQUITTY_QUIC)
#include "Core/Transport/QUICChannel.h"
#endif
#include "Core/Transport/SSHHost.h"
#include "Core/Unicode/UTF8Repair.h"
#include "Platform/Apple/MainQueueLoop.h"
#include "UbiquittyKit/Session.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace {

Ubiquitty::Transport::DelegatedChannel::Driver delegatedDriver(UbiquittyIOSCarrierDriver driver)
{
    return { .context = driver.context,
        .start = driver.start,
        .send = driver.send,
        .stop = driver.stop,
        .setWindowSize = driver.setWindowSize,
        .release = driver.release,
        .suspendReading = driver.suspendReading,
        .resumeReading = driver.resumeReading,
        .pendingOutboundBytes = driver.pendingOutboundBytes,
        .outboundCapacityBytes = driver.outboundCapacityBytes,
        .peerAuthenticationFailed = driver.peerAuthenticationFailed };
}

// The session thread, which on this frontend is the main queue.
//
// The facade's contract is that every public method and every observer hook
// runs on the dispatcher's thread. Choosing the main queue is what lets a
// SwiftUI shell touch its state straight out of a callback rather than hopping
// again. The macOS and iOS drives post their sessions' work to the same loop.
[[nodiscard]] Ubiquitty::Runtime::PostedDispatcher mainQueueDispatcher() { return Ubiquitty::Runtime::PostedDispatcher(Ubiquitty::Apple::mainQueueLoop()); }

// Forwards the facade's hooks to the shell's function pointers.
//
// A null pointer is a no-op rather than a crash, on the same terms the carrier
// Driver states: a shell that wants no bell should not have to supply one.
class ForwardingObserver final : public UbiquittyKit::Session::Observer {
public:
    explicit ForwardingObserver(UbiquittyIOSSessionObserver hooks)
        : m_hooks(hooks)
    {
    }

    ~ForwardingObserver() override
    {
        if (m_hooks.release)
            m_hooks.release(m_hooks.context);
    }

    void onFrame() override
    {
        if (m_hooks.onFrame)
            m_hooks.onFrame(m_hooks.context);
    }

    void onTitle(std::string_view utf8) override
    {
        if (m_hooks.onTitle)
            m_hooks.onTitle(m_hooks.context, utf8.data(), utf8.size());
    }

    void onBell() override
    {
        if (m_hooks.onBell)
            m_hooks.onBell(m_hooks.context);
    }

    void onExit() override
    {
        if (m_hooks.onExit)
            m_hooks.onExit(m_hooks.context);
    }

    void onHealthChanged(Ubiquitty::Session::Health health, const std::string& detail) override
    {
        if (m_hooks.onHealthChanged)
            m_hooks.onHealthChanged(m_hooks.context, static_cast<int32_t>(health), detail.data(), detail.size());
    }

private:
    UbiquittyIOSSessionObserver m_hooks;
};

/// Keeps the carrier hooks alive until both the factory and channel are gone.
struct ControlCarrierState {
    explicit ControlCarrierState(UbiquittyIOSCarrierDriver suppliedDriver)
        : driver(suppliedDriver)
    {
    }

    ~ControlCarrierState()
    {
        if (driver.release)
            driver.release(driver.context);
    }

    const UbiquittyIOSCarrierDriver driver;
    Ubiquitty::Transport::DelegatedChannel* channel = nullptr;
};

/// Adapts one native exec carrier without giving it a remote PTY size.
class ControlChannelFactory final : public Ubiquitty::Session::ChannelFactory {
public:
    explicit ControlChannelFactory(std::shared_ptr<ControlCarrierState> carrier)
        : m_carrier(std::move(carrier))
    {
    }

    void createChannel(Ubiquitty::Session::TransportMode, Done done) override
    {
        auto context = std::make_unique<std::shared_ptr<ControlCarrierState>>(m_carrier);
        Ubiquitty::Transport::DelegatedChannel::Driver driver;
        driver.context = context.release();
        driver.start = [](void* context) {
            const auto& driver = carrierFrom(context).driver;
            return driver.start(driver.context);
        };
        driver.send = [](void* context, const std::uint8_t* bytes, std::size_t count) {
            const auto& driver = carrierFrom(context).driver;
            if (driver.send)
                driver.send(driver.context, bytes, count);
        };
        driver.stop = [](void* context) {
            const auto& driver = carrierFrom(context).driver;
            if (driver.stop)
                driver.stop(driver.context);
        };
        driver.release = [](void* context) {
            std::unique_ptr<std::shared_ptr<ControlCarrierState>> carrier(static_cast<std::shared_ptr<ControlCarrierState>*>(context));
            (*carrier)->channel = nullptr;
        };
        auto channel = std::make_unique<Ubiquitty::Transport::DelegatedChannel>(
            // copy-ok: the channel's diagnostic description, not interface text
            driver, Ubiquitty::Transport::Origin { Ubiquitty::Transport::OriginKind::Daemon, "" }, "ssh control");
        m_carrier->channel = channel.get();
        done(std::move(channel), false);
    }

private:
    static ControlCarrierState& carrierFrom(void* context)
    {
        return **static_cast<std::shared_ptr<ControlCarrierState>*>(context);
    }

    const std::shared_ptr<ControlCarrierState> m_carrier;
};

/// Owns native callbacks separately from a directory's callback stack.
struct ControlObserverState {
    explicit ControlObserverState(UbiquittyIOSControlObserver suppliedHooks)
        : hooks(suppliedHooks)
    {
    }

    ~ControlObserverState()
    {
        if (hooks.release)
            hooks.release(hooks.context);
    }

    const UbiquittyIOSControlObserver hooks;
    bool isActive = true;
};

/// Defers native answers until Core has left its observer callback.
class ControlObserver final : public Ubiquitty::Session::SessionDirectoryObserver {
public:
    ControlObserver(Ubiquitty::Session::Dispatcher& dispatcher, std::shared_ptr<ControlObserverState> state)
        : m_dispatcher(dispatcher)
        , m_state(std::move(state))
    {
    }

    void onCallAnswered(const std::string& response) override
    {
        m_dispatcher.post([weakState = std::weak_ptr(m_state), response = std::string(response)] {
            if (const auto state = weakState.lock(); state && state->isActive && state->hooks.onAnswer)
                state->hooks.onAnswer(state->hooks.context, response.data(), response.size());
        });
    }

    void onDirectoryFailed(const Ubiquitty::Session::DirectoryFailureReport& report) override
    {
        m_dispatcher.post([weakState = std::weak_ptr(m_state), reason = Ubiquitty::Session::listingFailureNotice(report, Ubiquitty::Session::NoticePlacement::Standalone)] {
            if (const auto state = weakState.lock(); state && state->isActive && state->hooks.onFailure)
                state->hooks.onFailure(state->hooks.context, reason.data(), reason.size());
        });
    }

private:
    Ubiquitty::Session::Dispatcher& m_dispatcher;
    const std::shared_ptr<ControlObserverState> m_state;
};

} // namespace

// Everything the shell holds behind one handle.
//
// Declaration order is destruction order reversed, and it matters: the session
// must go before the observer and the terminal it was built over, or a hook in
// flight reaches freed state.
struct UbiquittyIOSSessionOpaque {
    Ubiquitty::Terminal terminal;
    Ubiquitty::Runtime::PostedDispatcher dispatcher = mainQueueDispatcher();
    std::unique_ptr<ForwardingObserver> observer;
    // Borrowed. The session owns the channel; this is how the carrier's inbound
    // direction reaches it, and it is null once the session has been destroyed.
    Ubiquitty::Transport::DelegatedChannel* channel = nullptr;
    std::unique_ptr<UbiquittyKit::Session> session;
};

/// Destroys Core before the factory, observer, and dispatcher it borrows.
struct UbiquittyIOSControlClientOpaque {
    UbiquittyIOSControlClientOpaque(UbiquittyIOSCarrierDriver driver, UbiquittyIOSControlObserver hooks)
        : carrier(std::make_shared<ControlCarrierState>(driver))
        , observerState(std::make_shared<ControlObserverState>(hooks))
        , factory(carrier)
        , observer(dispatcher, observerState)
        , directory(std::make_unique<Ubiquitty::Session::SessionDirectoryCore>(&dispatcher, &factory, &observer))
    {
    }

    ~UbiquittyIOSControlClientOpaque()
    {
        observerState->isActive = false;
        directory.reset();
    }

    Ubiquitty::Runtime::PostedDispatcher dispatcher = mainQueueDispatcher();
    const std::shared_ptr<ControlCarrierState> carrier;
    const std::shared_ptr<ControlObserverState> observerState;
    ControlChannelFactory factory;
    ControlObserver observer;
    std::unique_ptr<Ubiquitty::Session::SessionDirectoryCore> directory;
    bool hasStarted = false;
};

extern "C" {

UbiquittyIOSControlClient* ubiquittyIOSControlClientCreate(UbiquittyIOSCarrierDriver driver, UbiquittyIOSControlObserver observer)
{
    if (!driver.start) {
        if (driver.release)
            driver.release(driver.context);
        if (observer.release)
            observer.release(observer.context);
        return nullptr;
    }
    return std::make_unique<UbiquittyIOSControlClientOpaque>(driver, observer).release();
}

bool ubiquittyIOSControlClientStart(UbiquittyIOSControlClient* client, const char* request)
{
    if (!client || client->hasStarted || !request)
        return false;
    const std::size_t length = strnlen(request, Ubiquitty::Protocol::Sync::maxFrameBodyBytes + 1);
    if (!length || length > Ubiquitty::Protocol::Sync::maxFrameBodyBytes)
        return false;
    client->hasStarted = true;
    return client->directory->call(std::string(request, length));
}

void ubiquittyIOSControlClientNotifyConnect(UbiquittyIOSControlClient* client)
{
    if (client && client->carrier->channel)
        client->carrier->channel->notifyConnect();
}

void ubiquittyIOSControlClientDeliver(UbiquittyIOSControlClient* client, const uint8_t* bytes, size_t byteCount)
{
    if (client && client->carrier->channel && bytes && byteCount)
        client->carrier->channel->deliver(std::span<const std::uint8_t>(bytes, byteCount));
}

void ubiquittyIOSControlClientNotifyClose(UbiquittyIOSControlClient* client, UbiquittyIOSCarrierOutcome outcome, const char* reason)
{
    if (!client || !client->carrier->channel)
        return;
    const auto health = outcome == UbiquittyIOSCarrierOutcomeFailed ? Ubiquitty::Transport::Health::Failed : Ubiquitty::Transport::Health::Closed;
    client->carrier->channel->notifyClose(health, reason ? std::string(reason) : std::string());
}

void ubiquittyIOSControlClientDestroy(UbiquittyIOSControlClient* client)
{
    std::unique_ptr<UbiquittyIOSControlClient> held(client);
}

size_t ubiquittyIOSControlRemoteCommand(char* buffer, size_t capacity)
{
    const std::string command = Ubiquitty::Session::passiveControlRemoteCommand();
    if (buffer && capacity)
        std::memcpy(buffer, command.data(), std::min(command.size(), capacity));
    return command.size();
}

UbiquittyIOSSession* ubiquittyIOSSessionCreateDirect(UbiquittyIOSCarrierDriver driver,
    const char* originHost, UbiquittyIOSSessionObserver observer)
{
    // A Driver with no start is not a carrier — the C++ seam says so, and
    // answering here means the shell learns it at construction rather than from
    // a session that never connects.
    if (!driver.start) {
        if (driver.release)
            driver.release(driver.context);
        if (observer.release)
            observer.release(observer.context);
        return nullptr;
    }

    auto* handle = new UbiquittyIOSSessionOpaque();
    handle->observer = std::make_unique<ForwardingObserver>(observer);

    auto bridged = delegatedDriver(driver);

    // SSH rather than Local, because that is what the session reports as its
    // origin and what a shell renders as its badge. The host string is the
    // carrier's, not ours to compose.
    Ubiquitty::Transport::Origin origin;
    origin.transport = Ubiquitty::Transport::OriginKind::SSH;
    origin.host = originHost ? originHost : "";

    auto channel = std::make_unique<Ubiquitty::Transport::DelegatedChannel>(
        std::move(bridged), origin, "ssh");
    handle->channel = channel.get();

    // The resize reaches the carrier's own geometry through the same channel —
    // an SSH window-change request — which is the second half of setSize.
    auto* channelForResize = handle->channel;
    handle->session = UbiquittyKit::Session::createDirect(handle->terminal, handle->dispatcher,
        *handle->observer, std::move(channel),
        [channelForResize](int columns, int rows) { channelForResize->setWindowSize(columns, rows); });

    if (!handle->session) {
        delete handle;
        return nullptr;
    }
    return handle;
}

void ubiquittyIOSSessionStart(UbiquittyIOSSession* session, int columns, int rows)
{
    if (session && session->session)
        session->session->start(columns, rows);
}

void ubiquittyIOSSessionSendInput(UbiquittyIOSSession* session, const char* bytes, size_t byteCount)
{
    if (session && session->session && bytes)
        session->session->sendInput(std::string_view(bytes, byteCount));
}

void ubiquittyIOSSessionSetSize(UbiquittyIOSSession* session, int columns, int rows)
{
    if (session && session->session)
        session->session->setSize(columns, rows);
}

void ubiquittyIOSSessionStop(UbiquittyIOSSession* session)
{
    if (session && session->session)
        session->session->stop();
}

void ubiquittyIOSSessionDestroy(UbiquittyIOSSession* session)
{
    if (!session)
        return;
    if (session->session)
        session->session->stop();
    // Before the members go: the channel belongs to the session, so a carrier
    // that calls in after this must find no channel rather than a freed one.
    session->channel = nullptr;
    delete session;
}

void ubiquittyIOSSessionNotifyConnect(UbiquittyIOSSession* session)
{
    if (session && session->channel)
        session->channel->notifyConnect();
}

void ubiquittyIOSSessionDeliver(UbiquittyIOSSession* session, const uint8_t* bytes, size_t byteCount)
{
    if (session && session->channel && bytes && byteCount)
        session->channel->deliver(std::span<const std::uint8_t>(bytes, byteCount));
}

void ubiquittyIOSSessionNotifyClose(UbiquittyIOSSession* session, UbiquittyIOSCarrierOutcome outcome, const char* reason)
{
    if (!session || !session->channel)
        return;
    // Transport::Health, not Session::Health: the two enumerations share four
    // spellings and neither converts to the other, so naming the wrong one
    // compiles wherever the value happens to exist under both.
    const auto health = outcome == UbiquittyIOSCarrierOutcomeFailed
        ? Ubiquitty::Transport::Health::Failed
        : Ubiquitty::Transport::Health::Closed;
    session->channel->notifyClose(health, reason ? std::string(reason) : std::string());
}

bool ubiquittyIOSSessionCursor(UbiquittyIOSSession* session, int* column, int* row)
{
    if (!session)
        return false;
    const auto* screen = session->terminal.screens.active;
    if (!screen)
        return false;
    if (column)
        *column = screen->cursorX;
    if (row)
        *row = screen->cursorY;
    return session->terminal.modes.isCursorVisible;
}

int ubiquittyIOSSessionColumns(UbiquittyIOSSession* session)
{
    return session ? session->terminal.columns : 0;
}

int ubiquittyIOSSessionRows(UbiquittyIOSSession* session)
{
    return session ? session->terminal.rows : 0;
}

size_t ubiquittyIOSHostKeyFingerprint(const uint8_t* keyBytes, size_t byteCount, char* buffer, size_t capacity)
{
    if (!keyBytes || !byteCount)
        return 0;
    const std::string fingerprint = Ubiquitty::Transport::hostKeyFingerprint(
        std::span<const std::uint8_t>(keyBytes, byteCount));
    if (buffer && capacity)
        std::memcpy(buffer, fingerprint.data(), fingerprint.size() < capacity ? fingerprint.size() : capacity);
    return fingerprint.size();
}

int32_t ubiquittyIOSVerifyHostKeyFingerprint(const char* pinnedFingerprint, const char* presentedFingerprint)
{
    return static_cast<int32_t>(Ubiquitty::Transport::verifyHostKeyFingerprint(
        pinnedFingerprint ? pinnedFingerprint : "", presentedFingerprint ? presentedFingerprint : ""));
}

bool ubiquittyIOSValidateSSHHost(const char* host)
{
    return host && Ubiquitty::Transport::validateSSHHost(host);
}

namespace {

/// Where a bootstrap's QUIC carrier reached the daemon: what a resume dials
/// again with no bootstrap.
struct QUICReach {
    std::string address;
    std::uint16_t port = 0;
    std::string certificateSHA256;
};

/// A retained identity makes an old answer stale even after repeated handovers.
using QUICOwnerGeneration = std::uint8_t;

/// Requests outlive the factory but may update its reach only while it is live
/// and still names the owner generation captured by the request.
struct QUICOwnerState {
    QUICReach reach;
    std::string daemonSocketName;
    std::shared_ptr<const QUICOwnerGeneration> generation = std::make_shared<QUICOwnerGeneration>();
    std::shared_ptr<const QUICOwnerGeneration> attempt = std::make_shared<QUICOwnerGeneration>();
    bool isFactoryAlive = true;
    std::optional<Ubiquitty::Session::ChannelCreationFailure> creationFailure;
};

/// A directory's unbound passive exec may address the host, never attach or
/// create a session. Check the actual first Greet before forwarding one byte.
/// Mutable admission state is used only by Core's session thread; immutable
/// native hooks retain their own I/O-thread synchronization.
struct NativeSyncCarrierState {
    NativeSyncCarrierState(UbiquittyIOSCarrierDriver suppliedDriver, bool controlOnly) // bool-ok: immutable request admission data.
        : native(suppliedDriver)
        , isControlOnly(controlOnly)
    {
    }
    ~NativeSyncCarrierState()
    {
        if (native.release)
            native.release(native.context);
    }

    void stop()
    {
        if (hasStopped)
            return;
        hasStopped = true;
        pending.clear();
        decoder.reset();
        if (native.stop)
            native.stop(native.context);
    }

    void send(std::span<const std::uint8_t> bytes)
    {
        if (hasStopped || didRefuseOutbound || !native.send)
            return;
        if (!isControlOnly || didAdmitHello) {
            native.send(native.context, bytes.data(), bytes.size());
            return;
        }
        bool isRefused = bytes.size() > Ubiquitty::Transport::guaranteedOutboundFrameBytes - pending.size();
        if (!isRefused) {
            pending.insert(pending.end(), bytes.begin(), bytes.end());
            namespace Sync = Ubiquitty::Protocol::Sync;
            bool isComplete = false;
            const auto result = decoder.consume(bytes, [](std::span<const std::uint8_t> prefix) {
                Sync::FrameHeader header;
                Sync::EnvelopeError error = Sync::EnvelopeError::None;
                const auto status = Sync::readFrameHeader(prefix, header, error);
                if (status == Sync::FrameHeaderState::NeedsMore)
                    return Sync::FrameHeaderDecision {};
                if (status == Sync::FrameHeaderState::Failed || header.kind != Sync::FrameKind::Greet)
                    return Sync::FrameHeaderDecision { .state = Sync::FrameHeaderDecision::State::Refused };
                return Sync::FrameHeaderDecision { .state = Sync::FrameHeaderDecision::State::Admitted, .bodyBytes = header.bodyBytes }; }, [&](std::span<const std::uint8_t>, std::span<const std::uint8_t> body) {
                const auto greeting = Sync::decodeGreet(body);
                isComplete = true;
                isRefused = !greeting || (greeting->request.target != Sync::AdmissionTarget::Control
                                            && greeting->request.target != Sync::AdmissionTarget::Management)
                    || greeting->facts.viewportColumns || greeting->facts.viewportRows;
                return Sync::FrameDelivery::Stop; });
            isRefused = isRefused || result.state == Sync::FrameIngress::State::Refused;
            if (!isComplete && !isRefused)
                return;
        }
        if (isRefused) {
            didRefuseOutbound = true;
            pending.clear();
            decoder.reset();
            native.fail(native.context, "This SSH connection can reach only the host, so it cannot open or create a terminal session.");
            return;
        }
        didAdmitHello = true;
        auto admitted = std::move(pending);
        pending = {};
        decoder.reset();
        native.send(native.context, admitted.data(), admitted.size());
    }

    Ubiquitty::Transport::DelegatedChannel::Driver hooks()
    {
        Ubiquitty::Transport::DelegatedChannel::Driver driver;
        driver.context = this;
        driver.start = [](void* context) {
            auto& state = *static_cast<NativeSyncCarrierState*>(context);
            return state.native.start && state.native.start(state.native.context);
        };
        driver.send = [](void* context, const std::uint8_t* bytes, std::size_t count) { static_cast<NativeSyncCarrierState*>(context)->send({ bytes, count }); };
        driver.stop = [](void* context) { static_cast<NativeSyncCarrierState*>(context)->stop(); };
        driver.release = [](void* context) { std::unique_ptr<NativeSyncCarrierState> released(static_cast<NativeSyncCarrierState*>(context)); };
        driver.suspendReading = [](void* context) {
            const auto& native = static_cast<NativeSyncCarrierState*>(context)->native;
            if (native.suspendReading)
                native.suspendReading(native.context);
        };
        driver.resumeReading = [](void* context) {
            const auto& native = static_cast<NativeSyncCarrierState*>(context)->native;
            if (native.resumeReading)
                native.resumeReading(native.context);
        };
        driver.pendingOutboundBytes = [](void* context) -> std::int64_t {
            const auto& state = *static_cast<NativeSyncCarrierState*>(context);
            const auto queued = state.native.pendingOutboundBytes ? state.native.pendingOutboundBytes(state.native.context) : -1;
            if (queued < 0)
                return -1;
            const auto buffered = static_cast<std::int64_t>(state.pending.size());
            return queued > std::numeric_limits<std::int64_t>::max() - buffered ? std::numeric_limits<std::int64_t>::max() : queued + buffered;
        };
        driver.outboundCapacityBytes = [](void* context) -> std::int64_t {
            const auto& native = static_cast<NativeSyncCarrierState*>(context)->native;
            return native.outboundCapacityBytes ? native.outboundCapacityBytes(native.context) : -1;
        };
        driver.peerAuthenticationFailed = [](void* context) {
            const auto& native = static_cast<NativeSyncCarrierState*>(context)->native;
            return native.peerAuthenticationFailed && native.peerAuthenticationFailed(native.context);
        };
        driver.boundsInitialSetupFailures = [](void*) { return true; };
        return driver;
    }

    const UbiquittyIOSCarrierDriver native;
    const bool isControlOnly;
    Ubiquitty::Protocol::Sync::FrameIngress decoder { Ubiquitty::Protocol::Sync::maxFrameBodyBytes };
    std::vector<std::uint8_t> pending;
    bool hasStopped = false;
    bool didAdmitHello = false;
    bool didRefuseOutbound = false;
};

} // namespace

struct UbiquittyIOSQUICRequest {
    std::string host;
    Ubiquitty::Session::ChannelFactory::Done done;
    const std::shared_ptr<QUICOwnerState> owner;
    const std::shared_ptr<const QUICOwnerGeneration> generation;
    const std::shared_ptr<const QUICOwnerGeneration> attempt;
    const std::string bootstrapCommand;
    const bool hasPinnedOwner;
    const UbiquittyIOSCarrierKind carrierKind;
    const bool isControlOnly;
};

namespace {

class PinnedQUICFactory final : public Ubiquitty::Session::ChannelFactory {
public:
    PinnedQUICFactory(std::string host, UbiquittyIOSQUICProvider provider)
        : m_host(std::move(host))
        , m_provider(provider)
    {
    }

    ~PinnedQUICFactory() override
    {
        m_owner->isFactoryAlive = false;
        if (m_provider.release) {
            m_provider.release(m_provider.context);
        }
    }

    void createChannel(Ubiquitty::Session::TransportMode mode, Done done) override
    {
        m_owner->creationFailure.reset();
        m_owner->attempt = std::make_shared<QUICOwnerGeneration>();
        const bool isQUIC = mode == Ubiquitty::Session::TransportMode::QUIC;
        if (!isQUIC && m_owner->daemonSocketName.empty()) {
            m_owner->creationFailure = Ubiquitty::Session::ChannelCreationFailure {
                .recovery = Ubiquitty::Session::ChannelFailureRecovery::Stop,
                .detail = "Ubiquitty does not know which host process owns this session, so it cannot reconnect over SSH."
            };
            done(nullptr, false);
            return;
        }
        // The provider owns the request independently of the factory, so an
        // asynchronous bootstrap can settle after the session closes.
        const auto command = isQUIC ? Ubiquitty::Session::quicBootstrapRemoteCommand() : Ubiquitty::Session::passiveControlRemoteCommand();
        m_provider.request(m_provider.context, new UbiquittyIOSQUICRequest { .host = m_host, .done = std::move(done), .owner = m_owner, .generation = m_owner->generation, .attempt = m_owner->attempt, .bootstrapCommand = Ubiquitty::Session::substituteReattachSocket(command, m_owner->daemonSocketName), .hasPinnedOwner = !m_owner->daemonSocketName.empty(), .carrierKind = isQUIC ? UbiquittyIOSCarrierQUIC : UbiquittyIOSCarrierSyncSSH, .isControlOnly = false });
    }

    void createControlChannel(Done done) override
    {
        m_owner->creationFailure.reset();
        m_owner->attempt = std::make_shared<QUICOwnerGeneration>();
        m_provider.request(m_provider.context, new UbiquittyIOSQUICRequest { .host = m_host, .done = std::move(done), .owner = m_owner, .generation = m_owner->generation, .attempt = m_owner->attempt, .bootstrapCommand = Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::passiveControlRemoteCommand(), m_owner->daemonSocketName), .hasPinnedOwner = !m_owner->daemonSocketName.empty(), .carrierKind = UbiquittyIOSCarrierSyncSSH, .isControlOnly = true });
    }

    [[nodiscard]] std::optional<Ubiquitty::Session::ChannelCreationFailure> creationFailure() const override { return m_owner->creationFailure; }
    [[nodiscard]] Ubiquitty::Session::TransportMode controlTransport() const override { return Ubiquitty::Session::TransportMode::QUIC; }

    /// Whether a bootstrap's carrier reached the daemon, so the carrier can
    /// be dialled again with no bootstrap.
    [[nodiscard]] bool canResumeChannel() const override
    {
#if defined(UBIQUITTY_QUIC)
        return m_owner->reach.port != 0;
#else
        return false;
#endif
    }

    /// Dials the reach the last bootstrap recorded, presenting a resume key
    /// in place of a token. The provider is not asked: no SSH runs.
    ///
    /// - Parameters:
    ///   - key: What the carrier presents.
    ///   - done: Receives the carrier, or null with no reach recorded.
    void resumeChannel(Ubiquitty::Session::ResumeKey key, Done done) override
    {
        m_owner->attempt = std::make_shared<QUICOwnerGeneration>();
#if defined(UBIQUITTY_QUIC)
        const auto& reach = m_owner->reach;
        if (reach.port != 0) {
            const Ubiquitty::Transport::Origin origin { Ubiquitty::Transport::OriginKind::Daemon, "" };
            done(std::make_unique<Ubiquitty::Transport::QUICChannel>(reach.address, reach.port,
                     Ubiquitty::Transport::ExportedPreamble { .exporterLabel = std::move(key.exporterLabel), .build = std::move(key.buildPreamble) },
                     reach.certificateSHA256, origin),
                true);
            return;
        }
#else
        (void)key;
#endif
        done(nullptr, false);
    }

    /// Pins bootstrap requests to the exact daemon that accepted the workspace.
    bool pinDaemonSocket(std::string_view socketName) override
    {
        if (socketName.empty()) {
            return m_owner->daemonSocketName.empty();
        }
        if (socketName.size() > std::numeric_limits<std::uint16_t>::max()
            || !std::ranges::all_of(socketName, [](unsigned char character) {
                   return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
                       || (character >= '0' && character <= '9') || character == '.' || character == '_' || character == '-';
               })
            || (!m_owner->daemonSocketName.empty() && m_owner->daemonSocketName != socketName)) {
            return false;
        }
        if (m_owner->daemonSocketName.empty()) {
            m_owner->daemonSocketName = socketName;
            m_owner->generation = std::make_shared<QUICOwnerGeneration>();
        }
        return true;
    }

    /// Rediscovers a successor only when Core authorizes an authenticated handover.
    void clearHandoverReach() override
    {
        m_owner->daemonSocketName.clear();
        m_owner->reach = {};
        m_owner->generation = std::make_shared<QUICOwnerGeneration>();
    }

    bool seedResume(const char* address, std::uint16_t port, std::span<const std::uint8_t> pin)
    {
        if (!address || !Ubiquitty::Session::isNumericAddress(address) || !port || pin.size() != 32
            || std::ranges::all_of(pin, [](auto byte) { return byte == 0; }) || m_owner->reach.port)
            return false;
        m_owner->reach = { .address = address, .port = port, .certificateSHA256 = { reinterpret_cast<const char*>(pin.data()), pin.size() } };
        return true;
    }

    [[nodiscard]] std::string_view pinnedDaemonOwner() const { return m_owner->daemonSocketName; }

private:
    std::string m_host;
    UbiquittyIOSQUICProvider m_provider;
    const std::shared_ptr<QUICOwnerState> m_owner = std::make_shared<QUICOwnerState>();
};

} // namespace

struct UbiquittyIOSQUICFactory {
    PinnedQUICFactory factory;
};

UbiquittyIOSQUICFactory* ubiquittyIOSQUICFactoryCreate(const char* host, UbiquittyIOSQUICProvider provider)
{
    if (!ubiquittyIOSValidateSSHHost(host) || !provider.request) {
        return nullptr;
    }
    return new UbiquittyIOSQUICFactory { PinnedQUICFactory(host, provider) };
}

bool ubiquittyIOSQUICFactorySeedResume(UbiquittyIOSQUICFactory* factory, const char* address, uint16_t port, const uint8_t* pin, size_t pinLength)
{
    return factory && pin && factory->factory.seedResume(address, port, { pin, pinLength });
}

bool ubiquittyIOSQUICFactoryPinDaemonOwner(UbiquittyIOSQUICFactory* factory, const char* socketName)
{
    return factory && socketName && *socketName && factory->factory.pinDaemonSocket(socketName);
}

size_t ubiquittyIOSQUICFactoryPinnedDaemonOwner(const UbiquittyIOSQUICFactory* factory, char* buffer, size_t capacity)
{
    if (!factory)
        return 0;
    const auto name = factory->factory.pinnedDaemonOwner();
    if (buffer && capacity)
        std::memcpy(buffer, name.data(), std::min(name.size(), capacity));
    return name.size();
}

size_t ubiquittyIOSQUICRequestBootstrapCommand(const UbiquittyIOSQUICRequest* request, char* buffer, size_t capacity)
{
    if (!request) {
        return 0;
    }
    if (buffer && capacity) {
        std::memcpy(buffer, request->bootstrapCommand.data(), std::min(request->bootstrapCommand.size(), capacity));
    }
    return request->bootstrapCommand.size();
}

bool ubiquittyIOSQUICRequestHasPinnedOwner(const UbiquittyIOSQUICRequest* request)
{
    return request && request->hasPinnedOwner;
}

UbiquittyIOSCarrierKind ubiquittyIOSQUICRequestCarrierKind(const UbiquittyIOSQUICRequest* request)
{
    return request ? request->carrierKind : UbiquittyIOSCarrierQUIC;
}

bool ubiquittyIOSQUICRequestIsControlOnly(const UbiquittyIOSQUICRequest* request)
{
    return request && request->isControlOnly;
}

bool ubiquittyIOSQUICRequestIsCurrent(const UbiquittyIOSQUICRequest* request)
{
    return request && request->owner->isFactoryAlive && request->generation == request->owner->generation
        && request->attempt == request->owner->attempt;
}

void ubiquittyIOSQUICRequestFail(UbiquittyIOSQUICRequest* request, UbiquittyIOSQUICFailureRecovery recovery, const char* detail, size_t detailLength)
{
    std::unique_ptr<UbiquittyIOSQUICRequest> held(request);
    if (!held)
        return;
    if (ubiquittyIOSQUICRequestIsCurrent(held.get())) {
        const std::string_view bounded = detail ? std::string_view(detail, std::min<std::size_t>(detailLength, 1024)) : std::string_view {};
        std::string message(bounded);
        Ubiquitty::Unicode::repairUTF8(message);
        if (message.size() > 1024)
            message.resize(Ubiquitty::Unicode::wellFormedUTF8PrefixLength(std::string_view(message).substr(0, 1024)));
        auto policy = Ubiquitty::Session::ChannelFailureRecovery::Stop;
        if (recovery == UbiquittyIOSQUICFailureRetry)
            policy = Ubiquitty::Session::ChannelFailureRecovery::Retry;
        else if (recovery == UbiquittyIOSQUICFailureUseStream && held->carrierKind == UbiquittyIOSCarrierQUIC)
            policy = Ubiquitty::Session::ChannelFailureRecovery::UseStream;
        else if (recovery == UbiquittyIOSQUICFailureInstanceGone)
            policy = Ubiquitty::Session::ChannelFailureRecovery::InstanceGone;
        held->owner->creationFailure = Ubiquitty::Session::ChannelCreationFailure {
            .recovery = policy,
            .detail = std::move(message)
        };
    }
    held->done(nullptr, false);
}

void ubiquittyIOSQUICRequestComplete(UbiquittyIOSQUICRequest* request,
    uint16_t port, const uint8_t* token, size_t tokenLength,
    const uint8_t* certificateSHA256, size_t certificateLength,
    const char* reachedAddress)
{
    std::unique_ptr<UbiquittyIOSQUICRequest> held(request);
    if (!held) {
        return;
    }
    if (!ubiquittyIOSQUICRequestIsCurrent(held.get()) || held->carrierKind != UbiquittyIOSCarrierQUIC) {
        held->done(nullptr, false);
        return;
    }
    if (!port || !token || !tokenLength || tokenLength > Ubiquitty::Protocol::Sync::maxQUICTokenLength
        || !certificateSHA256 || certificateLength != Ubiquitty::Protocol::Sync::certificateSHA256Length
        || !reachedAddress || !Ubiquitty::Session::isNumericAddress(reachedAddress)) {
        // An empty completion is the provider cancelling a superseded ask.
        // A partial ready answer is a setup failure, never a lesser pin.
        if (port || token || tokenLength || certificateSHA256 || certificateLength || reachedAddress) {
            held->owner->creationFailure = Ubiquitty::Session::ChannelCreationFailure {
                .recovery = Ubiquitty::Session::ChannelFailureRecovery::Stop,
                .detail = "The host sent incomplete QUIC connection details."
            };
        }
        held->done(nullptr, false);
        return;
    }
#if defined(UBIQUITTY_QUIC)
    // Bootstrap fields are binary byte strings, not UTF-8 text.
    std::string tokenBytes(reinterpret_cast<const char*>(token), tokenLength);
    std::string pinBytes(reinterpret_cast<const char*>(certificateSHA256), certificateLength);
    const Ubiquitty::Transport::Origin origin { Ubiquitty::Transport::OriginKind::Daemon, "" };
    held->owner->reach = { .address = reachedAddress, .port = port, .certificateSHA256 = pinBytes };
    held->done(std::make_unique<Ubiquitty::Transport::QUICChannel>(std::string(reachedAddress), port, tokenBytes, pinBytes, origin), true);
#else
    held->done(nullptr, false);
#endif
}

void ubiquittyIOSQUICRequestCompleteSSH(UbiquittyIOSQUICRequest* request,
    UbiquittyIOSCarrierDriver driver, void (*bind)(void*, UbiquittyIOSSyncCarrier*))
{
    std::unique_ptr<UbiquittyIOSQUICRequest> held(request);
    // Owning the driver immediately also releases an obsolete completion.
    auto state = std::make_unique<NativeSyncCarrierState>(driver, held && held->isControlOnly);
    auto bridged = state->hooks();
    state.release(); // The delegated driver now owns and releases this state.
    auto channel = std::make_unique<Ubiquitty::Transport::DelegatedChannel>(
        bridged,
        Ubiquitty::Transport::Origin { Ubiquitty::Transport::OriginKind::Daemon, "" }, "Sync+SSH");
    if (!held)
        return;
    if (!ubiquittyIOSQUICRequestIsCurrent(held.get())) {
        held->done(nullptr, false);
        return;
    }
    if (held->carrierKind != UbiquittyIOSCarrierSyncSSH || (!held->hasPinnedOwner && !held->isControlOnly)
        || !driver.start || !driver.send || !driver.stop || !driver.release || !bind
        || !driver.suspendReading || !driver.resumeReading || !driver.pendingOutboundBytes
        || !driver.outboundCapacityBytes || !driver.peerAuthenticationFailed
        || (held->isControlOnly && !driver.fail)
        || channel->outboundCapacityBytes() < static_cast<std::int64_t>(Ubiquitty::Transport::guaranteedOutboundFrameBytes)) {
        held->owner->creationFailure = Ubiquitty::Session::ChannelCreationFailure {
            .recovery = Ubiquitty::Session::ChannelFailureRecovery::Stop,
            .detail = "The SSH connection could not be set up for this session."
        };
        held->done(nullptr, false);
        return;
    }
    bind(driver.context, reinterpret_cast<UbiquittyIOSSyncCarrier*>(channel.get()));
    held->done(std::move(channel), false);
}

size_t ubiquittyIOSSyncCarrierRequiredOutboundCapacity(void)
{
    return Ubiquitty::Transport::guaranteedOutboundFrameBytes;
}

void ubiquittyIOSSyncCarrierNotifyConnect(UbiquittyIOSSyncCarrier* carrier)
{
    if (carrier)
        reinterpret_cast<Ubiquitty::Transport::DelegatedChannel*>(carrier)->notifyConnect();
}

void ubiquittyIOSSyncCarrierDeliver(UbiquittyIOSSyncCarrier* carrier, const uint8_t* bytes, size_t byteCount)
{
    if (carrier && bytes)
        reinterpret_cast<Ubiquitty::Transport::DelegatedChannel*>(carrier)->deliver({ bytes, byteCount });
}

void ubiquittyIOSSyncCarrierNotifyClose(UbiquittyIOSSyncCarrier* carrier, UbiquittyIOSCarrierOutcome outcome, const char* reason)
{
    if (carrier)
        reinterpret_cast<Ubiquitty::Transport::DelegatedChannel*>(carrier)->notifyClose(
            outcome == UbiquittyIOSCarrierOutcomeClosed ? Ubiquitty::Transport::Health::Closed : Ubiquitty::Transport::Health::Failed,
            reason ? reason : "");
}

void ubiquittyIOSQUICFactoryDestroy(UbiquittyIOSQUICFactory* factory)
{
    delete factory;
}

uintptr_t ubiquittyIOSQUICFactoryAddress(UbiquittyIOSQUICFactory* factory)
{
    if (!factory)
        return 0;
    return reinterpret_cast<uintptr_t>(static_cast<Ubiquitty::Session::ChannelFactory*>(&factory->factory));
}

} // extern "C"
