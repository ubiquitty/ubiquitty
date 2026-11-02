// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Protocol/Sync/Envelope.h"
#include "Core/Protocol/Sync/NativeAttachment.h"
#include "Core/Protocol/Sync/QUICBootstrap.h"
#include "Core/Protocol/Sync/Wire.h"
#include "Core/Session/RemoteBootstrap.h"
#include "Core/Session/RemoteSessionCore.h"
#include "Core/Session/SessionDirectoryCore.h"
#include "Platform/iOS/SessionBridge.h"

#include <array>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace {

struct Provider {
    std::vector<UbiquittyIOSQUICRequest*> requests;
    bool isReleased = false;
    std::function<void()> onRelease;

    UbiquittyIOSQUICProvider hooks()
    {
        return { this,
            [](void* context, UbiquittyIOSQUICRequest* request) {
                static_cast<Provider*>(context)->requests.push_back(request);
            },
            [](void* context) {
                auto& provider = *static_cast<Provider*>(context);
                provider.isReleased = true;
                if (provider.onRelease) {
                    provider.onRelease();
                }
            } };
    }
};

struct NativeStream {
    UbiquittyIOSSyncCarrier* handle = nullptr;
    unsigned starts = 0;
    unsigned stops = 0;
    unsigned releases = 0;
    unsigned pauses = 0;
    unsigned resumes = 0;
    unsigned failures = 0;
    bool hasAuthenticationFailed = false;
    std::vector<std::uint8_t> sent;

    UbiquittyIOSCarrierDriver hooks()
    {
        UbiquittyIOSCarrierDriver driver {};
        driver.context = this;
        driver.start = [](void* context) {
            auto& stream = *static_cast<NativeStream*>(context);
            ++stream.starts;
            ubiquittyIOSSyncCarrierNotifyConnect(stream.handle);
            return true;
        };
        driver.send = [](void* context, const std::uint8_t* bytes, std::size_t count) {
            auto& sent = static_cast<NativeStream*>(context)->sent;
            sent.insert(sent.end(), bytes, bytes + count);
        };
        driver.stop = [](void* context) {
            auto& stream = *static_cast<NativeStream*>(context);
            ++stream.stops;
            stream.handle = nullptr;
        };
        driver.release = [](void* context) { ++static_cast<NativeStream*>(context)->releases; };
        driver.suspendReading = [](void* context) { ++static_cast<NativeStream*>(context)->pauses; };
        driver.resumeReading = [](void* context) { ++static_cast<NativeStream*>(context)->resumes; };
        driver.pendingOutboundBytes = [](void*) -> std::int64_t { return 0; };
        driver.outboundCapacityBytes = [](void*) -> std::int64_t { return ubiquittyIOSSyncCarrierRequiredOutboundCapacity(); };
        driver.peerAuthenticationFailed = [](void* context) { return static_cast<NativeStream*>(context)->hasAuthenticationFailed; };
        driver.fail = [](void* context, const char* reason) {
            auto& stream = *static_cast<NativeStream*>(context);
            ++stream.failures;
            ubiquittyIOSSyncCarrierNotifyClose(stream.handle, UbiquittyIOSCarrierOutcomeFailed, reason);
        };
        return driver;
    }

    static void bind(void* context, UbiquittyIOSSyncCarrier* handle) { static_cast<NativeStream*>(context)->handle = handle; }
};

struct MemoryDispatcher final : Ubiquitty::Session::Dispatcher {
    std::vector<Ubiquitty::Session::PostedWork> queued;
    std::vector<Ubiquitty::Session::PostedWork> delayed;
    void post(Ubiquitty::Session::PostedWork work) override { queued.push_back(std::move(work)); }
    void postDelayed(double, Ubiquitty::Session::PostedWork work) override { delayed.push_back(std::move(work)); }
    void drain()
    {
        auto pending = std::move(queued);
        queued.clear();
        for (auto& work : pending)
            std::move(work)();
    }
    void fireDelayed()
    {
        auto pending = std::move(delayed);
        delayed.clear();
        for (auto& work : pending)
            std::move(work)();
    }
};

struct UnavailableQUIC final : Ubiquitty::Transport::Channel {
    bool start(Ubiquitty::Transport::ChannelObserver*) override { return false; }
    void send(std::span<const std::uint8_t>) override { }
    void stop() override { }
    Ubiquitty::Transport::Origin origin() const override { return {}; }
    Ubiquitty::Transport::Health health() const override { return Ubiquitty::Transport::Health::Failed; }
    std::string description() const override { return "mock unavailable QUIC"; }
};

struct StreamFallbackFactory final : Ubiquitty::Session::ChannelFactory {
    Ubiquitty::Session::ChannelFactory& stream;
    explicit StreamFallbackFactory(Ubiquitty::Session::ChannelFactory& suppliedStream)
        : stream(suppliedStream)
    {
    }
    void createChannel(Ubiquitty::Session::TransportMode mode, Done done) override
    {
        if (mode == Ubiquitty::Session::TransportMode::QUIC)
            done(std::make_unique<UnavailableQUIC>(), true);
        else
            stream.createChannel(mode, std::move(done));
    }
};

std::string bootstrapCommand(const UbiquittyIOSQUICRequest* request)
{
    const auto length = ubiquittyIOSQUICRequestBootstrapCommand(request, nullptr, 0);
    std::string command(length, '\0');
    CHECK_EQ(ubiquittyIOSQUICRequestBootstrapCommand(request, command.data(), command.size()), length);
    return command;
}

std::optional<Ubiquitty::Protocol::Sync::Greet> firstGreet(std::span<const std::uint8_t> bytes)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    Sync::FrameDecoder decoder;
    decoder.append(bytes);
    const auto frame = decoder.next();
    if (!frame || frame->kind != Sync::FrameKind::Greet)
        return std::nullopt;
    return Sync::decodeGreet(frame->body);
}

void completeWithReadyBootstrap(UbiquittyIOSQUICRequest* request)
{
    const std::array<std::uint8_t, 3> token { 1, 2, 3 };
    const std::array<std::uint8_t, Ubiquitty::Protocol::Sync::certificateSHA256Length> pin { 255 };
    ubiquittyIOSQUICRequestComplete(request, 443, token.data(), token.size(), pin.data(), pin.size(), "192.0.2.1");
}

} // namespace

TEST(aSyncSSHFallbackKeepsThePinnedOwnerAndAttachOnlyHELLO)
{
    struct Observer final : Ubiquitty::Session::RemoteSessionObserver {
        void onStateChanged(Ubiquitty::Session::State, const std::string&) override { }
    } observer;
    Provider provider;
    NativeStream native;
    MemoryDispatcher dispatcher;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("kept-daemon.sock"));
    StreamFallbackFactory fallback(*channels);
    {
        Ubiquitty::Session::RemoteSessionCore core(nullptr, &dispatcher, &fallback, &observer);
        core.setWorkspace("kept-work", false);
        core.setReattachPolicy(Ubiquitty::Session::ReattachPolicy::AttachOnly);
        core.start(77, 80, 24);
        CHECK(provider.requests.empty());
        dispatcher.fireDelayed();
        REQUIRE(provider.requests.size() == 1);
        auto* request = provider.requests.back();
        CHECK(ubiquittyIOSQUICRequestCarrierKind(request) == UbiquittyIOSCarrierSyncSSH);
        CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(request));
        CHECK(bootstrapCommand(request) == Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::passiveControlRemoteCommand(), "kept-daemon.sock"));
        CHECK(bootstrapCommand(request).find("--ensure") == std::string::npos);
        ubiquittyIOSQUICRequestCompleteSSH(request, native.hooks(), NativeStream::bind);
        dispatcher.drain();
        CHECK_EQ(native.starts, 1u);
        CHECK(!core.isUsingQUIC());
        const auto hello = firstGreet(native.sent);
        REQUIRE(hello);
        CHECK_EQ(hello->request.sessionID, 77u);
        CHECK(hello->request.workspaceName == "kept-work");
        CHECK(hello->request.isAttachOnly);
        core.stop();
    }
    CHECK_EQ(native.stops, 1u);
    CHECK_EQ(native.releases, 1u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aNewerSameOwnerAttemptRejectsAnOlderNativeStreamWithoutStartingIt)
{
    Provider provider;
    NativeStream native;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("kept.sock"));
    unsigned completions = 0;
    const auto refuse = [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
        CHECK(!channel && !isQUIC);
        ++completions;
    };
    channels->createChannel(Ubiquitty::Session::TransportMode::TCP, refuse);
    REQUIRE(provider.requests.size() == 1);
    auto* older = provider.requests.back();
    channels->createChannel(Ubiquitty::Session::TransportMode::TCP, refuse);
    REQUIRE(provider.requests.size() == 2);
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(older));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(provider.requests.back()));
    ubiquittyIOSQUICRequestCompleteSSH(older, native.hooks(), NativeStream::bind);
    CHECK_EQ(completions, 1u);
    CHECK_EQ(native.starts, 0u);
    CHECK_EQ(native.releases, 1u);
    CHECK(!native.handle);
    CHECK(!channels->creationFailure());
    ubiquittyIOSQUICRequestComplete(provider.requests.back(), 0, nullptr, 0, nullptr, 0, nullptr);
    CHECK_EQ(completions, 2u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(anAuthenticatedNullQUICBootstrapReachesTheSamePinnedSessionOverSSH)
{
    struct Observer final : Ubiquitty::Session::RemoteSessionObserver {
        void onStateChanged(Ubiquitty::Session::State, const std::string&) override { }
    } observer;
    Provider provider;
    NativeStream native;
    MemoryDispatcher dispatcher;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("kept.sock"));
    {
        Ubiquitty::Session::RemoteSessionCore core(nullptr, &dispatcher, channels, &observer);
        core.setWorkspace("kept-work", false);
        core.setReattachPolicy(Ubiquitty::Session::ReattachPolicy::AttachOnly);
        core.start(77, 80, 24);
        REQUIRE(provider.requests.size() == 1);
        CHECK(ubiquittyIOSQUICRequestCarrierKind(provider.requests.back()) == UbiquittyIOSCarrierQUIC);
        const std::string reason = "the authenticated host offered no QUIC listener";
        ubiquittyIOSQUICRequestFail(provider.requests.back(), UbiquittyIOSQUICFailureUseStream, reason.data(), reason.size());
        REQUIRE(provider.requests.size() == 2);
        CHECK(ubiquittyIOSQUICRequestCarrierKind(provider.requests.back()) == UbiquittyIOSCarrierSyncSSH);
        CHECK(bootstrapCommand(provider.requests.back()) == Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::passiveControlRemoteCommand(), "kept.sock"));
        ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), native.hooks(), NativeStream::bind);
        dispatcher.drain();
        CHECK_EQ(native.starts, 1u);
        const auto hello = firstGreet(native.sent);
        REQUIRE(hello);
        CHECK_EQ(hello->request.sessionID, 77u);
        CHECK(hello->request.workspaceName == "kept-work");
        CHECK(hello->request.isAttachOnly);
        core.stop();
    }
    CHECK_EQ(native.releases, 1u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aNativeSyncStreamWithoutFlowControlOrCapacityCannotBeAccepted)
{
    for (const bool missingFlowControl : { false, true }) {
        Provider provider;
        NativeStream native;
        auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
        REQUIRE(factory);
        auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
        CHECK(channels->pinDaemonSocket("kept.sock"));
        unsigned completions = 0;
        channels->createChannel(Ubiquitty::Session::TransportMode::TCP,
            [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
                CHECK(!channel && !isQUIC);
                ++completions;
            });
        auto driver = native.hooks();
        if (missingFlowControl)
            driver.suspendReading = nullptr;
        else
            driver.outboundCapacityBytes = [](void*) -> std::int64_t { return 1; };
        ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), driver, NativeStream::bind);
        CHECK_EQ(completions, 1u);
        CHECK_EQ(native.starts, 0u);
        CHECK_EQ(native.releases, 1u);
        REQUIRE(channels->creationFailure());
        CHECK(channels->creationFailure()->recovery == Ubiquitty::Session::ChannelFailureRecovery::Stop);
        ubiquittyIOSQUICFactoryDestroy(factory);
    }
}

TEST(aNullBootstrapSecurityRefusalNeverRequestsAStream)
{
    struct Observer final : Ubiquitty::Session::RemoteSessionObserver {
        void onStateChanged(Ubiquitty::Session::State, const std::string&) override { }
    } observer;
    Provider provider;
    MemoryDispatcher dispatcher;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("kept.sock"));
    {
        Ubiquitty::Session::RemoteSessionCore core(nullptr, &dispatcher, channels, &observer);
        core.start(77, 80, 24);
        REQUIRE(provider.requests.size() == 1);
        const std::string reason = "the pinned host refused authentication";
        ubiquittyIOSQUICRequestFail(provider.requests.back(), UbiquittyIOSQUICFailureStop, reason.data(), reason.size());
        CHECK(core.state() == Ubiquitty::Session::State::Failed);
        dispatcher.fireDelayed();
        dispatcher.drain();
        CHECK_EQ(provider.requests.size(), 1u);
        core.stop();
    }
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aNativeSyncStreamForwardsFlowControlAndAuthenticationFacts)
{
    struct Observer final : Ubiquitty::Transport::ChannelObserver {
        unsigned connects = 0;
        void onConnect() override { ++connects; }
        void onData(std::span<const std::uint8_t>) override { }
        void onClose(const std::string&) override { }
    } observer;
    Provider provider;
    NativeStream native;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("kept.sock"));
    std::unique_ptr<Ubiquitty::Transport::Channel> received;
    channels->createChannel(Ubiquitty::Session::TransportMode::TCP,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!isQUIC);
            received = std::move(channel);
        });
    ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), native.hooks(), NativeStream::bind);
    REQUIRE(received);
    CHECK(received->start(&observer));
    CHECK_EQ(observer.connects, 1u);
    received->suspendReading();
    received->resumeReading();
    CHECK_EQ(native.pauses, 1u);
    CHECK_EQ(native.resumes, 1u);
    CHECK_EQ(received->pendingOutboundBytes(), 0);
    CHECK_EQ(received->outboundCapacityBytes(), static_cast<std::int64_t>(ubiquittyIOSSyncCarrierRequiredOutboundCapacity()));
    CHECK(!received->peerAuthenticationFailed());
    native.hasAuthenticationFailed = true;
    CHECK(received->peerAuthenticationFailed());
    received.reset();
    CHECK_EQ(native.stops, 1u);
    CHECK_EQ(native.releases, 1u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aFirstDirectoryRequestUsesPassiveSSHAndAControlOnlyHELLO)
{
    struct Observer final : Ubiquitty::Session::SessionDirectoryObserver {
        void onSessionList(const std::vector<Ubiquitty::Session::SessionRow>&) override { }
    } observer;
    Provider provider;
    NativeStream native;
    MemoryDispatcher dispatcher;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    {
        Ubiquitty::Session::SessionDirectoryCore directory(&dispatcher, channels, &observer);
        CHECK(directory.refresh());
        REQUIRE(provider.requests.size() == 1);
        auto* request = provider.requests.back();
        CHECK(ubiquittyIOSQUICRequestCarrierKind(request) == UbiquittyIOSCarrierSyncSSH);
        CHECK(ubiquittyIOSQUICRequestIsControlOnly(request));
        CHECK(!ubiquittyIOSQUICRequestHasPinnedOwner(request));
        CHECK(bootstrapCommand(request) == Ubiquitty::Session::passiveControlRemoteCommand());
        CHECK(bootstrapCommand(request).find("--ensure") == std::string::npos);
        ubiquittyIOSQUICRequestCompleteSSH(request, native.hooks(), NativeStream::bind);
        dispatcher.drain();
        CHECK_EQ(native.starts, 1u);
        const auto hello = firstGreet(native.sent);
        REQUIRE(hello);
        CHECK(hello->request.target == Ubiquitty::Protocol::Sync::AdmissionTarget::Control);
        CHECK_EQ(hello->request.sessionID, 0u);
        CHECK_EQ(hello->facts.viewportColumns, 0);
        CHECK_EQ(hello->facts.viewportRows, 0);
        CHECK(hello->request.workspaceName.empty());
        CHECK_EQ(hello->request.workspaceID, 0u);
        CHECK(!hello->request.isAttachOnly && !hello->request.endsWhenDetached);
        CHECK(!hello->resume);
    }
    CHECK_EQ(native.stops, 1u);
    CHECK_EQ(native.releases, 1u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(onlyHostListingsUseTheControlOnlyCarrierDoor)
{
    struct Factory final : Ubiquitty::Session::ChannelFactory {
        unsigned controlRequests = 0;
        unsigned ordinaryRequests = 0;
        std::optional<Ubiquitty::Session::TransportMode> lastMode;
        Done pending;
        void createChannel(Ubiquitty::Session::TransportMode mode, Done done) override
        {
            ++ordinaryRequests;
            lastMode = mode;
            pending = std::move(done);
        }
        void createControlChannel(Done done) override
        {
            ++controlRequests;
            pending = std::move(done);
        }
        Ubiquitty::Session::TransportMode controlTransport() const override { return Ubiquitty::Session::TransportMode::QUIC; }
    };
    for (unsigned operation = 0; operation < 5; ++operation) {
        Factory factory;
        MemoryDispatcher dispatcher;
        Ubiquitty::Session::SessionDirectoryObserver observer;
        Ubiquitty::Session::SessionDirectoryCore directory(&dispatcher, &factory, &observer);
        switch (operation) {
        case 0:
            CHECK(directory.refresh());
            break;
        case 1:
            CHECK(directory.watch());
            break;
        case 2:
            CHECK(directory.terminate(77));
            break;
        case 3:
            CHECK(directory.call(R"({"jsonrpc":"2.0","id":"route","method":"host.methods"})"));
            break;
        case 4:
            Ubiquitty::Protocol::Sync::ManagementRequest request;
            request.operation = Ubiquitty::Protocol::Sync::ManagementOperation::List;
            CHECK(directory.manage(std::move(request)));
            break;
        }
        CHECK_EQ(factory.controlRequests, operation < 2 ? 1u : 0u);
        CHECK_EQ(factory.ordinaryRequests, operation < 2 ? 0u : 1u);
        if (operation >= 2)
            CHECK(factory.lastMode == Ubiquitty::Session::TransportMode::QUIC);
    }
}

TEST(aControlOnlySSHCarrierRefusesEverySessionBindingBeforeForwardingBytes)
{
    for (unsigned mutation = 0; mutation < 8; ++mutation) {
        struct Observer final : Ubiquitty::Transport::ChannelObserver {
            unsigned closes = 0;
            void onConnect() override { }
            void onData(std::span<const std::uint8_t>) override { }
            void onClose(const std::string&) override { ++closes; }
        } observer;
        Provider provider;
        NativeStream native;
        auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
        REQUIRE(factory);
        auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
        std::unique_ptr<Ubiquitty::Transport::Channel> received;
        channels->createControlChannel([&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!isQUIC);
            received = std::move(channel);
        });
        ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), native.hooks(), NativeStream::bind);
        REQUIRE(received && received->start(&observer));
        namespace Sync = Ubiquitty::Protocol::Sync;
        Sync::Greet hello;
        hello.wireVersion = Sync::wireVersion;
        hello.request.target = Sync::AdmissionTarget::Control;
        switch (mutation) {
        case 0:
            hello.request.target = Sync::AdmissionTarget::Session;
            break;
        case 1:
            hello.request.target = Sync::AdmissionTarget::Session;
            hello.request.sessionID = 77;
            hello.request.isAttachOnly = true;
            break;
        case 2:
            hello.request.target = Sync::AdmissionTarget::Workspace;
            hello.request.workspaceName = "must-not-create";
            break;
        case 3:
            hello.request.target = Sync::AdmissionTarget::Workspace;
            hello.request.workspaceID = 7;
            hello.request.isAttachOnly = true;
            break;
        case 4:
            hello.facts.viewportColumns = 80;
            break;
        case 5:
            hello.facts.viewportRows = 24;
            break;
        case 6:
            hello.request.target = Sync::AdmissionTarget::Session;
            hello.request.endsWhenDetached = true;
            break;
        case 7:
            hello.request.target = Sync::AdmissionTarget::Workspace;
            break;
        }
        std::vector<std::uint8_t> body;
        Sync::encode(body, hello);
        REQUIRE(!body.empty());
        if (mutation == 6) {
            // Preserve a session-only flag while claiming a control target.
            Sync::WireReader prefix(body);
            (void)prefix.u16();
            (void)prefix.utf8(Sync::maxAppVersionBytes);
            (void)prefix.take(32);
            (void)prefix.take(16);
            (void)prefix.u8();
            (void)prefix.u8();
            REQUIRE(prefix.ok() && prefix.offset() < body.size());
            body[prefix.offset()] = std::to_underlying(Sync::AdmissionTarget::Control);
            REQUIRE(!Sync::decodeGreet(body));
        } else {
            REQUIRE(Sync::decodeGreet(body));
        }
        std::vector<std::uint8_t> bytes;
        REQUIRE(Sync::appendFrame(bytes, Sync::FrameKind::Greet, 0, body));
        received->send(std::span(bytes).first(1));
        CHECK(native.sent.empty());
        CHECK_EQ(received->pendingOutboundBytes(), 1);
        received->send(std::span(bytes).subspan(1));
        CHECK_EQ(observer.closes, 1u);
        CHECK(native.sent.empty());
        CHECK_EQ(native.failures, 1u);
        CHECK_EQ(native.stops, 0u);
        CHECK_EQ(received->pendingOutboundBytes(), 0);
        received->send(bytes);
        CHECK_EQ(native.failures, 1u);
        received.reset();
        CHECK_EQ(native.stops, 1u);
        CHECK_EQ(native.releases, 1u);
        ubiquittyIOSQUICFactoryDestroy(factory);
    }
}

TEST(aControlOnlySSHCarrierAdmitsFragmentedUnboundGreetingsAndForwardsCoalescedCallsExactlyOnce)
{
    namespace Sync = Ubiquitty::Protocol::Sync;
    for (const auto target : { Sync::AdmissionTarget::Control, Sync::AdmissionTarget::Management }) {
        Sync::Greet greeting;
        greeting.wireVersion = Sync::wireVersion;
        greeting.request.target = target;
        std::vector<std::uint8_t> body;
        Sync::encode(body, greeting);
        REQUIRE(Sync::decodeGreet(body));
        std::vector<std::uint8_t> greetingBytes;
        REQUIRE(Sync::appendFrame(greetingBytes, Sync::FrameKind::Greet, 0, body));
        Sync::Call call;
        call.text = R"({"jsonrpc":"2.0","id":19,"method":"host.methods"})";
        body.clear();
        Sync::encode(body, call);
        std::vector<std::uint8_t> callBytes;
        REQUIRE(Sync::appendFrame(callBytes, Sync::FrameKind::Call, 0, body));
        auto expected = greetingBytes;
        expected.insert(expected.end(), callBytes.begin(), callBytes.end());
        for (std::size_t split = 0; split < greetingBytes.size(); ++split) {
            struct Observer final : Ubiquitty::Transport::ChannelObserver {
                unsigned closes = 0;
                void onConnect() override { }
                void onData(std::span<const std::uint8_t>) override { }
                void onClose(const std::string&) override { ++closes; }
            } observer;
            Provider provider;
            NativeStream native;
            auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
            REQUIRE(factory);
            auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
            std::unique_ptr<Ubiquitty::Transport::Channel> received;
            channels->createControlChannel([&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
                CHECK(!isQUIC);
                received = std::move(channel);
            });
            ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), native.hooks(), NativeStream::bind);
            REQUIRE(received && received->start(&observer));
            received->send(std::span(expected).first(split));
            CHECK(native.sent.empty());
            CHECK_EQ(received->pendingOutboundBytes(), static_cast<std::int64_t>(split));
            received->send(std::span(expected).subspan(split));
            CHECK(native.sent == expected);
            CHECK_EQ(received->pendingOutboundBytes(), 0);
            CHECK_EQ(native.failures, 0u);
            CHECK_EQ(observer.closes, 0u);
            received->send(callBytes);
            expected.insert(expected.end(), callBytes.begin(), callBytes.end());
            CHECK(native.sent == expected);
            expected.resize(greetingBytes.size() + callBytes.size());
            received.reset();
            CHECK_EQ(native.stops, 1u);
            CHECK_EQ(native.releases, 1u);
            ubiquittyIOSQUICFactoryDestroy(factory);
        }
    }
}

TEST(aControlOnlySSHCarrierBoundsAnIncompleteFirstHELLO)
{
    struct Observer final : Ubiquitty::Transport::ChannelObserver {
        unsigned closes = 0;
        void onConnect() override { }
        void onData(std::span<const std::uint8_t>) override { }
        void onClose(const std::string&) override { ++closes; }
    } observer;
    Provider provider;
    NativeStream native;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    std::unique_ptr<Ubiquitty::Transport::Channel> received;
    channels->createControlChannel([&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool) { received = std::move(channel); });
    ubiquittyIOSQUICRequestCompleteSSH(provider.requests.back(), native.hooks(), NativeStream::bind);
    REQUIRE(received && received->start(&observer));
    const std::vector<std::uint8_t> oversized(ubiquittyIOSSyncCarrierRequiredOutboundCapacity() + 1, 0);
    received->send(oversized);
    CHECK_EQ(observer.closes, 1u);
    CHECK(native.sent.empty());
    CHECK_EQ(native.failures, 1u);
    CHECK_EQ(native.stops, 0u);
    received.reset();
    CHECK_EQ(native.stops, 1u);
    CHECK_EQ(native.releases, 1u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aBootstrapFailureReachesTheFactoryWithItsBoundedCause)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->controlTransport() == Ubiquitty::Session::TransportMode::QUIC);
    unsigned completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    const std::string detail = "the host refused the login";
    ubiquittyIOSQUICRequestFail(provider.requests.back(), UbiquittyIOSQUICFailureStop, detail.data(), detail.size());
    CHECK_EQ(completions, 1u);
    REQUIRE(channels->creationFailure());
    CHECK(channels->creationFailure()->detail == detail);
    CHECK(channels->creationFailure()->recovery == Ubiquitty::Session::ChannelFailureRecovery::Stop);

    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel>, bool) { ++completions; });
    CHECK(!channels->creationFailure());
    std::string oversized(2048, 'x');
    oversized[1023] = '\xF0';
    ubiquittyIOSQUICRequestFail(provider.requests.back(), UbiquittyIOSQUICFailureRetry, oversized.data(), oversized.size());
    REQUIRE(channels->creationFailure());
    CHECK(channels->creationFailure()->detail.size() == 1023);
    CHECK(channels->creationFailure()->detail == std::string(1023, 'x'));
    CHECK(channels->creationFailure()->recovery == Ubiquitty::Session::ChannelFailureRecovery::Retry);
    CHECK_EQ(completions, 2u);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(anObsoleteBootstrapFailureCannotPoisonTheSuccessorsFactory)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    unsigned completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel>, bool) { ++completions; });
    REQUIRE(provider.requests.size() == 1);
    auto* previous = provider.requests.back();
    CHECK(channels->pinDaemonSocket("selected.sock"));
    const std::string detail = "obsolete authentication refusal";
    ubiquittyIOSQUICRequestFail(previous, UbiquittyIOSQUICFailureStop, detail.data(), detail.size());
    CHECK_EQ(completions, 1u);
    CHECK(!channels->creationFailure());
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aStreamRequestCannotSilentlyStartAnotherQUICBootstrap)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    unsigned completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::TCP,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    CHECK_EQ(completions, 1u);
    CHECK(provider.requests.empty());
    REQUIRE(channels->creationFailure());
    CHECK(channels->creationFailure()->recovery == Ubiquitty::Session::ChannelFailureRecovery::Stop);
    CHECK(channels->creationFailure()->detail.find("which host process owns this session") != std::string::npos);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aBootstrapRequestOwnsItsCommandAndBoundsItsCopy)
{
    CHECK_EQ(ubiquittyIOSQUICRequestBootstrapCommand(nullptr, nullptr, 0), 0u);
    CHECK(!ubiquittyIOSQUICRequestHasPinnedOwner(nullptr));
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(nullptr));
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    auto* request = provider.requests.front();
    const auto expected = Ubiquitty::Session::quicBootstrapRemoteCommand();
    CHECK(bootstrapCommand(request) == expected);
    CHECK(!ubiquittyIOSQUICRequestHasPinnedOwner(request));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(request));
    std::array<char, 8> bounded;
    bounded.fill('!');
    CHECK_EQ(ubiquittyIOSQUICRequestBootstrapCommand(request, bounded.data() + 1, 5), expected.size());
    CHECK(bounded.front() == '!' && bounded[6] == '!' && bounded.back() == '!');
    CHECK(std::memcmp(bounded.data() + 1, expected.data(), 5) == 0);
    CHECK_EQ(ubiquittyIOSQUICRequestBootstrapCommand(request, bounded.data(), 0), expected.size());
    CHECK(bounded.front() == '!');
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(request));
    CHECK(bootstrapCommand(request) == expected);
    completeWithReadyBootstrap(request);
    CHECK_EQ(completions, 1);
}

TEST(anExactDaemonPinSurvivesRedialAndRefusesReplacement)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket(""));
    for (const std::string_view invalid : { "host/other.sock", "host;id.sock", "host\n.sock", "host\".sock", "$(id)", "host .sock" }) {
        CHECK(!channels->pinDaemonSocket(invalid));
    }
    const std::string embeddedNull("host\0other.sock", 15);
    CHECK(!channels->pinDaemonSocket(embeddedNull));
    CHECK(!channels->pinDaemonSocket(std::string(65536, 'a')));
    CHECK(channels->pinDaemonSocket("host-ABC_123.sock"));
    int completions = 0;
    const auto failed = [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
        CHECK(!channel && !isQUIC);
        ++completions;
    };
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, failed);
    REQUIRE(provider.requests.size() == 1);
    auto* first = provider.requests.front();
    const auto expected = Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::quicBootstrapRemoteCommand(), "host-ABC_123.sock");
    CHECK(bootstrapCommand(first) == expected);
    CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(first));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(first));
    CHECK(channels->pinDaemonSocket("host-ABC_123.sock"));
    CHECK(!channels->pinDaemonSocket("host-replacement.sock"));
    CHECK(!channels->pinDaemonSocket(""));
    CHECK(!channels->pinDaemonSocket("host/other.sock"));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(first));
    ubiquittyIOSQUICRequestComplete(first, 0, nullptr, 0, nullptr, 0, nullptr);
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, failed);
    REQUIRE(provider.requests.size() == 2);
    auto* redial = provider.requests.back();
    CHECK(bootstrapCommand(redial) == expected);
    CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(redial));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(redial));
    ubiquittyIOSQUICRequestComplete(redial, 0, nullptr, 0, nullptr, 0, nullptr);
    CHECK_EQ(completions, 2);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(pinningTheFirstOwnerMakesUnboundPendingAnswersStale)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    auto* unbound = provider.requests.front();
    CHECK(ubiquittyIOSQUICRequestIsCurrent(unbound));
    CHECK(channels->pinDaemonSocket("host-selected.sock"));
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(unbound));
    CHECK(!ubiquittyIOSQUICRequestHasPinnedOwner(unbound));
    CHECK(bootstrapCommand(unbound) == Ubiquitty::Session::quicBootstrapRemoteCommand());
    completeWithReadyBootstrap(unbound);
    CHECK_EQ(completions, 1);
    CHECK(!channels->canResumeChannel());
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aProtectedColdOwnerPinsTheFallbackWithoutChangingSessionAuthority)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    CHECK_EQ(ubiquittyIOSQUICFactoryPinnedDaemonOwner(factory, nullptr, 0), 0U);
    CHECK(!ubiquittyIOSQUICFactoryPinDaemonOwner(factory, nullptr));
    CHECK(!ubiquittyIOSQUICFactoryPinDaemonOwner(factory, ""));
    CHECK(!ubiquittyIOSQUICFactoryPinDaemonOwner(factory, "../other.sock"));
    CHECK(ubiquittyIOSQUICFactoryPinDaemonOwner(factory, "host-protected.sock"));
    CHECK(!ubiquittyIOSQUICFactoryPinDaemonOwner(factory, "host-replacement.sock"));
    const auto length = ubiquittyIOSQUICFactoryPinnedDaemonOwner(factory, nullptr, 0);
    std::string owner(length, '\0');
    CHECK_EQ(ubiquittyIOSQUICFactoryPinnedDaemonOwner(factory, owner.data(), owner.size()), length);
    CHECK(owner == "host-protected.sock");
    std::array<char, 4> prefix {};
    CHECK_EQ(ubiquittyIOSQUICFactoryPinnedDaemonOwner(factory, prefix.data(), prefix.size()), length);
    CHECK(std::string_view(prefix.data(), prefix.size()) == "host");

    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    unsigned completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::TCP,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    auto* request = provider.requests.front();
    CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(request));
    CHECK_EQ(ubiquittyIOSQUICRequestCarrierKind(request), UbiquittyIOSCarrierSyncSSH);
    CHECK(bootstrapCommand(request) == Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::passiveControlRemoteCommand(), owner));
    ubiquittyIOSQUICRequestComplete(request, 0, nullptr, 0, nullptr, 0, nullptr);
    CHECK_EQ(completions, 1U);
    CHECK(!channels->canResumeChannel());
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK_EQ(ubiquittyIOSQUICFactoryPinnedDaemonOwner(nullptr, nullptr, 0), 0U);
}

TEST(handoverDropsThePinAndReachWithoutAcceptingLatePredecessorAnswers)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    const std::array<std::uint8_t, 32> pin { 7 };
    CHECK(ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.7", 443, pin.data(), pin.size()));
    CHECK(channels->pinDaemonSocket("host-predecessor.sock"));
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.8", 443, pin.data(), pin.size()));
#if defined(UBIQUITTY_QUIC)
    CHECK(channels->canResumeChannel());
#endif
    int completions = 0;
    const auto failed = [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
        CHECK(!channel && !isQUIC);
        ++completions;
    };
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, failed);
    REQUIRE(provider.requests.size() == 1);
    auto* predecessor = provider.requests.front();
    const auto predecessorCommand = bootstrapCommand(predecessor);
    CHECK(ubiquittyIOSQUICRequestIsCurrent(predecessor));
    channels->clearHandoverReach();
    CHECK(!channels->canResumeChannel());
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(predecessor));
    CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(predecessor));
    CHECK(bootstrapCommand(predecessor) == predecessorCommand);
    completeWithReadyBootstrap(predecessor);
    CHECK_EQ(completions, 1);
    CHECK(!channels->canResumeChannel());
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, failed);
    REQUIRE(provider.requests.size() == 2);
    auto* discovery = provider.requests.back();
    CHECK(!ubiquittyIOSQUICRequestHasPinnedOwner(discovery));
    CHECK(ubiquittyIOSQUICRequestIsCurrent(discovery));
    CHECK(bootstrapCommand(discovery) == Ubiquitty::Session::quicBootstrapRemoteCommand());
    CHECK(channels->pinDaemonSocket("host-successor.sock"));
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(discovery));
    completeWithReadyBootstrap(discovery);
    CHECK_EQ(completions, 2);
    CHECK(!channels->canResumeChannel());
    CHECK(ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.8", 443, pin.data(), pin.size()));
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(repinningTheSameNameAfterHandoverDoesNotReviveAnOldRequest)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("host-owner.sock"));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    auto* old = provider.requests.front();
    channels->clearHandoverReach();
    CHECK(channels->pinDaemonSocket("host-owner.sock"));
    CHECK(!ubiquittyIOSQUICRequestIsCurrent(old));
    completeWithReadyBootstrap(old);
    CHECK_EQ(completions, 1);
    CHECK(!channels->canResumeChannel());
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aFactoryInvalidatesItsRequestsBeforeTheProviderReleaseCallback)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("host-owner.sock"));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    auto* request = provider.requests.front();
    CHECK(ubiquittyIOSQUICRequestIsCurrent(request));
    provider.onRelease = [&] {
        CHECK(!ubiquittyIOSQUICRequestIsCurrent(request));
        CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(request));
        completeWithReadyBootstrap(request);
    };
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK(provider.isReleased);
    CHECK_EQ(completions, 1);
}

TEST(aPinnedReadyAnswerRetainsItsOwnerAndReachOnTheNextBootstrap)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    CHECK(channels->pinDaemonSocket("host-owner.sock"));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
#if defined(UBIQUITTY_QUIC)
            REQUIRE(channel);
            CHECK(isQUIC);
            CHECK(channel->description() == "quic 192.0.2.1:443");
#else
            CHECK(!channel && !isQUIC);
#endif
            ++completions;
        });
    REQUIRE(provider.requests.size() == 1);
    completeWithReadyBootstrap(provider.requests.front());
    CHECK_EQ(completions, 1);
#if defined(UBIQUITTY_QUIC)
    CHECK(channels->canResumeChannel());
#endif
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel && !isQUIC);
            ++completions;
        });
    REQUIRE(provider.requests.size() == 2);
    auto* next = provider.requests.back();
    CHECK(ubiquittyIOSQUICRequestIsCurrent(next));
    CHECK(ubiquittyIOSQUICRequestHasPinnedOwner(next));
    CHECK(bootstrapCommand(next) == Ubiquitty::Session::substituteReattachSocket(Ubiquitty::Session::quicBootstrapRemoteCommand(), "host-owner.sock"));
    ubiquittyIOSQUICRequestComplete(next, 0, nullptr, 0, nullptr, 0, nullptr);
    CHECK_EQ(completions, 2);
#if defined(UBIQUITTY_QUIC)
    CHECK(channels->canResumeChannel());
#endif
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(aProtectedColdReachSeedsOnlyABoundedPinnedProofDial)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("host.example", provider.hooks());
    REQUIRE(factory);
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    std::array<std::uint8_t, 32> pin { 7 };
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "host.example", 443, pin.data(), pin.size()));
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.7", 0, pin.data(), pin.size()));
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.7", 443, pin.data(), 31));
    const std::array<std::uint8_t, 32> zero {};
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.7", 443, zero.data(), zero.size()));
    CHECK(ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.7", 443, pin.data(), pin.size()));
    CHECK(!ubiquittyIOSQUICFactorySeedResume(factory, "192.0.2.8", 443, pin.data(), pin.size()));
#if defined(UBIQUITTY_QUIC)
    CHECK(channels->canResumeChannel());
#else
    CHECK(!channels->canResumeChannel());
#endif
    int completions = 0;
    channels->resumeChannel({ .exporterLabel = "fixture", .buildPreamble = [](std::span<const std::uint8_t, 32>) { return std::vector<std::uint8_t> { 2 }; } },
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
#if defined(UBIQUITTY_QUIC)
            REQUIRE(channel);
            CHECK(isQUIC);
            CHECK(channel->description() == "quic 192.0.2.7:443");
            CHECK_MSG(!channel->authenticatedCertificatePin(), "a cached pin is not an authenticated channel");
#else
            CHECK(!channel && !isQUIC);
#endif
            ++completions;
        });
    CHECK_EQ(completions, 1);
    CHECK(provider.requests.empty());
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK(provider.isReleased);
}

TEST(everyConnectionRequestsANewBootstrap)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("localhost", provider.hooks());
    CHECK(factory);
    // The C bridge exposes the address of its C++ abstract factory.
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    int completions = 0;
    for (int attempt = 0; attempt < 3; ++attempt) {
        channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
            [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
#if defined(UBIQUITTY_QUIC)
                CHECK(channel);
                CHECK(isQUIC);
#else
                CHECK(!channel);
                CHECK(!isQUIC);
#endif
                ++completions;
            });
        CHECK_EQ(provider.requests.size(), static_cast<std::size_t>(attempt + 1));
        CHECK_EQ(completions, attempt);
        const std::array<std::uint8_t, 3> token { 0, 255, static_cast<std::uint8_t>(attempt) };
        const std::array<std::uint8_t, Ubiquitty::Protocol::Sync::certificateSHA256Length> pin { 255 };
        ubiquittyIOSQUICRequestComplete(provider.requests.back(), 443, token.data(), token.size(), pin.data(), pin.size(), attempt == 1 ? "2001:db8::1" : "192.0.2.1");
        CHECK_EQ(completions, attempt + 1);
    }
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK(provider.isReleased);
}

// A factory whose bootstrap reached the daemon dials that reach again by a
// resume key without asking its provider, which is where SSH runs; before
// any bootstrap answered, and after one that produced no carrier, it has
// nowhere to dial.
TEST(aResumeDialsTheReachTheBootstrapRecordedAndAsksTheProviderNothing)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("localhost", provider.hooks());
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    const auto key = [] {
        return Ubiquitty::Session::ResumeKey { .exporterLabel = "label", .buildPreamble = [](std::span<const std::uint8_t, 32>) { return std::vector<std::uint8_t> { 2 }; } };
    };
    int resumed = 0;
    int refused = 0;
    const auto count = [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
        if (channel && isQUIC)
            ++resumed;
        else
            ++refused;
    };
    CHECK(!channels->canResumeChannel());
    channels->resumeChannel(key(), count);
    CHECK_EQ(refused, 1);

    const std::array<std::uint8_t, 3> token { 1, 2, 3 };
    const std::array<std::uint8_t, Ubiquitty::Protocol::Sync::certificateSHA256Length> pin { 255 };
    // An answer that names no address records no reach.
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, [](std::unique_ptr<Ubiquitty::Transport::Channel>, bool) { });
    ubiquittyIOSQUICRequestComplete(provider.requests.back(), 443, token.data(), token.size(), pin.data(), pin.size(), "build.example.org");
    CHECK(!channels->canResumeChannel());

    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC, [](std::unique_ptr<Ubiquitty::Transport::Channel>, bool) { });
    ubiquittyIOSQUICRequestComplete(provider.requests.back(), 443, token.data(), token.size(), pin.data(), pin.size(), "192.0.2.1");
    const std::size_t asked = provider.requests.size();
#if defined(UBIQUITTY_QUIC)
    CHECK(channels->canResumeChannel());
    channels->resumeChannel(key(), count);
    CHECK_EQ(resumed, 1);
#else
    CHECK(!channels->canResumeChannel());
    channels->resumeChannel(key(), count);
    CHECK_EQ(refused, 2);
#endif
    CHECK_EQ(provider.requests.size(), asked);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(outstandingBootstrapsCanSettleAfterFactoryDestruction)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("localhost", provider.hooks());
    // The C bridge exposes the address of its C++ abstract factory.
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    int completions = 0;
    for (int attempt = 0; attempt < 2; ++attempt) {
        channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
            [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
                CHECK(!channel);
                CHECK(!isQUIC);
                ++completions;
            });
    }
    ubiquittyIOSQUICFactoryDestroy(factory);
    CHECK(provider.isReleased);
    for (auto* request : provider.requests) {
        ubiquittyIOSQUICRequestComplete(request, 0, nullptr, 0, nullptr, 0, nullptr);
    }
    CHECK_EQ(completions, 2);
}

TEST(invalidCertificateCannotProduceAnUnpinnedCarrier)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("localhost", provider.hooks());
    // The C bridge exposes the address of its C++ abstract factory.
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    int completions = 0;
    channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
        [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
            CHECK(!channel);
            CHECK(!isQUIC);
            ++completions;
        });
    const std::array<std::uint8_t, 3> bytes { 0, 1, 2 };
    ubiquittyIOSQUICRequestComplete(provider.requests.back(), 443, bytes.data(), bytes.size(), bytes.data(), bytes.size(), "192.0.2.1");
    CHECK_EQ(completions, 1);
    ubiquittyIOSQUICFactoryDestroy(factory);
}

// The carrier dials the address the bootstrap's connection reached and
// resolves nothing: a complete answer with no address, or with a name where
// the address belongs, produces no carrier.
TEST(anAnswerWithoutANumericAddressProducesNoCarrier)
{
    Provider provider;
    auto* factory = ubiquittyIOSQUICFactoryCreate("build.example.org", provider.hooks());
    // The C bridge exposes the address of its C++ abstract factory.
    auto* channels = reinterpret_cast<Ubiquitty::Session::ChannelFactory*>(ubiquittyIOSQUICFactoryAddress(factory));
    const std::array<std::uint8_t, 3> token { 1, 2, 3 };
    const std::array<std::uint8_t, Ubiquitty::Protocol::Sync::certificateSHA256Length> pin { 255 };
    for (const char* address : { static_cast<const char*>(nullptr), "", "build.example.org", "192.0.2.256", "$(id)" }) {
        int completions = 0;
        channels->createChannel(Ubiquitty::Session::TransportMode::QUIC,
            [&](std::unique_ptr<Ubiquitty::Transport::Channel> channel, bool isQUIC) {
                CHECK(!channel);
                CHECK(!isQUIC);
                ++completions;
            });
        ubiquittyIOSQUICRequestComplete(provider.requests.back(), 443, token.data(), token.size(), pin.data(), pin.size(), address);
        CHECK_EQ(completions, 1);
    }
    ubiquittyIOSQUICFactoryDestroy(factory);
}

TEST(invalidProviderDoesNotTransferOwnership)
{
    Provider provider;
    CHECK(!ubiquittyIOSQUICFactoryCreate("bad host", provider.hooks()));
    CHECK(!provider.isReleased);
}

UBIQUITTY_TEST_MAIN()
