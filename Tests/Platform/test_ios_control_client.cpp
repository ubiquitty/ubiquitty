// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Session/RemoteBootstrap.h"
#include "Core/Session/ScriptedListingHost.h"
#include "Platform/iOS/SessionBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

namespace Sync = Ubiquitty::Protocol::Sync;

struct Carrier final : Ubiquitty::Transport::ChannelObserver {
    UbiquittyIOSControlClient* client = nullptr;
    UbiquittyTest::ScriptedHost host;
    std::vector<std::uint8_t> sent;
    int starts = 0;
    int stops = 0;
    int releases = 0;
    int resizes = 0;
    bool canStart = true;

    UbiquittyIOSCarrierDriver hooks()
    {
        host.peer = this;
        return { this,
            [](void* context) {
                auto& carrier = *static_cast<Carrier*>(context);
                ++carrier.starts;
                return carrier.canStart;
            },
            [](void* context, const std::uint8_t* bytes, std::size_t count) {
                auto& carrier = *static_cast<Carrier*>(context);
                carrier.sent.insert(carrier.sent.end(), bytes, bytes + count);
                carrier.host.receive({ bytes, count });
            },
            [](void* context) {
                auto& carrier = *static_cast<Carrier*>(context);
                ++carrier.stops;
                carrier.client = nullptr;
                carrier.host.peer = nullptr;
            },
            [](void* context, int, int) { ++static_cast<Carrier*>(context)->resizes; },
            [](void* context) { ++static_cast<Carrier*>(context)->releases; },
            nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    }

    void onConnect() override { ubiquittyIOSControlClientNotifyConnect(client); }
    void onData(std::span<const std::uint8_t> bytes) override { ubiquittyIOSControlClientDeliver(client, bytes.data(), bytes.size()); }
    void onClose(const std::string& reason) override { ubiquittyIOSControlClientNotifyClose(client, UbiquittyIOSCarrierOutcomeClosed, reason.c_str()); }

    void connect()
    {
        onConnect();
        const std::string boundary = "\n" + std::string(Ubiquitty::Session::syncSentinel) + "\n";
        onData({ reinterpret_cast<const std::uint8_t*>(boundary.data()), boundary.size() });
    }
};

struct Observer {
    UbiquittyIOSControlClient* client = nullptr;
    int answers = 0;
    int failures = 0;
    int releases = 0;
    bool shouldDestroyOnAnswer = false;
    std::string response;

    UbiquittyIOSControlObserver hooks()
    {
        return { this,
            [](void* context, const char* bytes, std::size_t count) {
                auto& observer = *static_cast<Observer*>(context);
                ++observer.answers;
                observer.response.assign(bytes, count);
                observer.finish();
            },
            [](void* context, const char* bytes, std::size_t count) {
                auto& observer = *static_cast<Observer*>(context);
                ++observer.failures;
                observer.response.assign(bytes, count);
                observer.finish();
            },
            [](void* context) { ++static_cast<Observer*>(context)->releases; } };
    }

    void finish()
    {
        if (shouldDestroyOnAnswer)
            ubiquittyIOSControlClientDestroy(std::exchange(client, nullptr));
    }
};

struct DirectSession {
    std::string sent;
    std::string title;
    int starts = 0;
    int stops = 0;
    int carrierReleases = 0;
    int observerReleases = 0;
    int frames = 0;
    int titles = 0;
    int bells = 0;
    int exits = 0;
    std::unique_ptr<UbiquittyIOSSession, decltype(&ubiquittyIOSSessionDestroy)> session { nullptr, &ubiquittyIOSSessionDestroy };

    DirectSession()
    {
        UbiquittyIOSCarrierDriver driver {};
        driver.context = this;
        driver.start = [](void* context) {
            auto& direct = *static_cast<DirectSession*>(context);
            ++direct.starts;
            ubiquittyIOSSessionNotifyConnect(direct.session.get());
            return true;
        };
        driver.send = [](void* context, const std::uint8_t* bytes, std::size_t count) {
            static_cast<DirectSession*>(context)->sent.append(reinterpret_cast<const char*>(bytes), count);
        };
        driver.stop = [](void* context) { ++static_cast<DirectSession*>(context)->stops; };
        driver.release = [](void* context) { ++static_cast<DirectSession*>(context)->carrierReleases; };

        UbiquittyIOSSessionObserver observer {};
        observer.context = this;
        observer.onFrame = [](void* context) { ++static_cast<DirectSession*>(context)->frames; };
        observer.onTitle = [](void* context, const char* bytes, std::size_t count) {
            auto& direct = *static_cast<DirectSession*>(context);
            ++direct.titles;
            direct.title.assign(bytes, count);
        };
        observer.onBell = [](void* context) { ++static_cast<DirectSession*>(context)->bells; };
        observer.onExit = [](void* context) { ++static_cast<DirectSession*>(context)->exits; };
        observer.release = [](void* context) { ++static_cast<DirectSession*>(context)->observerReleases; };
        session.reset(ubiquittyIOSSessionCreateDirect(driver, "host.example", observer));
    }

    void deliver(std::string_view bytes)
    {
        ubiquittyIOSSessionDeliver(session.get(), reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size());
    }
};

void runUntil(const std::function<bool()>& isDone)
{
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2;
    while (!isDone() && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
    CHECK(isDone());
}

void drainMainQueue()
{
    bool isDrained = false;
    dispatch_async_f(dispatch_get_main_queue(), &isDrained, [](void* context) { *static_cast<bool*>(context) = true; });
    runUntil([&] { return isDrained; });
}

constexpr char request[] = R"({"jsonrpc":"2.0","id":1,"method":"host.refresh","params":{}})";

} // namespace

TEST(controlRequestHasNoPaneOrGeometryAndMayDestroyItselfInAnswer)
{
    Carrier carrier;
    Observer observer;
    observer.shouldDestroyOnAnswer = true;
    observer.client = carrier.client = ubiquittyIOSControlClientCreate(carrier.hooks(), observer.hooks());
    CHECK(ubiquittyIOSControlClientStart(observer.client, request));
    CHECK(!ubiquittyIOSControlClientStart(observer.client, request));
    carrier.connect();
    CHECK_EQ(observer.answers, 0);
    runUntil([&] { return observer.releases == 1; });

    CHECK_EQ(observer.answers, 1);
    CHECK_EQ(observer.failures, 0);
    CHECK(observer.response == R"({"jsonrpc":"2.0","id":1,"result":{"served":true}})");
    CHECK_EQ(carrier.host.calls.size(), 1u);
    CHECK(carrier.host.calls.front() == request);
    CHECK_EQ(carrier.host.panesAtExit, 0u);
    CHECK_EQ(carrier.starts, 1);
    CHECK_EQ(carrier.stops, 1);
    CHECK_EQ(carrier.releases, 1);
    CHECK_EQ(carrier.resizes, 0);

    Sync::FrameDecoder decoder;
    decoder.append(carrier.sent);
    const auto frame = decoder.next();
    REQUIRE(frame && frame->kind == Sync::FrameKind::Greet);
    const auto hello = Sync::decodeGreet(frame->body);
    REQUIRE(hello);
    if (hello) {
        CHECK_EQ(hello->facts.viewportColumns, 0);
        CHECK_EQ(hello->facts.viewportRows, 0);
        CHECK(hello->request.target == Sync::AdmissionTarget::Control);
        CHECK_EQ(hello->request.sessionID, 0u);
        CHECK_EQ(hello->request.workspaceID, 0u);
        CHECK(!hello->resume);
    }
}

TEST(destroyingAControlClientCancelsQueuedCarrierCallbacks)
{
    Carrier carrier;
    Observer observer;
    observer.client = carrier.client = ubiquittyIOSControlClientCreate(carrier.hooks(), observer.hooks());
    CHECK(ubiquittyIOSControlClientStart(observer.client, request));
    carrier.connect();
    carrier.onClose("peer closed");
    ubiquittyIOSControlClientDestroy(std::exchange(observer.client, nullptr));
    drainMainQueue();
    CHECK(carrier.sent.empty());
    CHECK_EQ(observer.answers, 0);
    CHECK_EQ(observer.failures, 0);
    CHECK_EQ(observer.releases, 1);
    CHECK_EQ(carrier.stops, 1);
    CHECK_EQ(carrier.releases, 1);
}

TEST(controlStartFailureIsDeferredAndItsCallbackMayDestroyTheClient)
{
    Carrier carrier;
    carrier.canStart = false;
    Observer observer;
    observer.shouldDestroyOnAnswer = true;
    observer.client = carrier.client = ubiquittyIOSControlClientCreate(carrier.hooks(), observer.hooks());
    CHECK(ubiquittyIOSControlClientStart(observer.client, request));
    CHECK_EQ(observer.failures, 0);
    runUntil([&] { return observer.releases == 1; });
    CHECK_EQ(observer.failures, 1);
    CHECK(!observer.response.empty());
    CHECK_EQ(carrier.releases, 1);
    CHECK_EQ(carrier.stops, 1);
}

TEST(destroyingAControlClientCancelsItsDeferredFailure)
{
    Carrier carrier;
    carrier.canStart = false;
    Observer observer;
    auto* client = ubiquittyIOSControlClientCreate(carrier.hooks(), observer.hooks());
    CHECK(ubiquittyIOSControlClientStart(client, request));
    CHECK_EQ(observer.failures, 0);
    ubiquittyIOSControlClientDestroy(client);
    drainMainQueue();
    CHECK_EQ(observer.failures, 0);
    CHECK_EQ(observer.releases, 1);
    CHECK_EQ(carrier.releases, 1);
}

TEST(controlBridgeRejectsInvalidInputBeforeStartingACarrier)
{
    Carrier carrier;
    Observer observer;
    auto driver = carrier.hooks();
    driver.start = nullptr;
    CHECK(!ubiquittyIOSControlClientCreate(driver, observer.hooks()));
    CHECK_EQ(carrier.releases, 1);
    CHECK_EQ(observer.releases, 1);

    auto* client = ubiquittyIOSControlClientCreate(carrier.hooks(), observer.hooks());
    CHECK(!ubiquittyIOSControlClientStart(client, nullptr));
    CHECK(!ubiquittyIOSControlClientStart(client, ""));
    const std::string oversized(Ubiquitty::Protocol::Sync::maxFrameBodyBytes + 1, 'x');
    CHECK(!ubiquittyIOSControlClientStart(client, oversized.c_str()));
    CHECK_EQ(carrier.starts, 0);
    ubiquittyIOSControlClientDestroy(client);
    CHECK_EQ(carrier.releases, 2);
    CHECK_EQ(observer.releases, 2);
}

TEST(controlBridgeCopiesCoresPassiveRemoteCommand)
{
    const std::string command = Ubiquitty::Session::passiveControlRemoteCommand();
    CHECK_EQ(ubiquittyIOSControlRemoteCommand(nullptr, 0), command.size());
    std::string copied(command.size(), '\0');
    CHECK_EQ(ubiquittyIOSControlRemoteCommand(copied.data(), copied.size()), command.size());
    CHECK(copied == command);
    char firstByte = '\0';
    CHECK_EQ(ubiquittyIOSControlRemoteCommand(&firstByte, 1), command.size());
    CHECK_EQ(firstByte, command.front());
}

TEST(directSSHSessionAnswersCursorQueriesWithoutDisclosingScreenChecksums)
{
    DirectSession direct;
    REQUIRE(direct.session);
    ubiquittyIOSSessionStart(direct.session.get(), 80, 24);
    drainMainQueue();
    direct.sent.clear();

    // DECRQCRA reads screen content and must be refused, while the cursor
    // reply still reaches the remote program through the same carrier.
    direct.deliver("\033]2;remote title\007secret\033[12;0;1;1;1;1*y\033[3;7H\033[6n");
    drainMainQueue();
    CHECK(direct.sent == "\033[3;7R");
    CHECK_EQ(direct.titles, 1);
    CHECK(direct.title == "remote title");

    int column = -1;
    int row = -1;
    (void)ubiquittyIOSSessionCursor(direct.session.get(), &column, &row);
    CHECK_EQ(column, 6);
    CHECK_EQ(row, 2);
    CHECK_EQ(direct.starts, 1);
    direct.session.reset();
    CHECK_EQ(direct.stops, 1);
    CHECK_EQ(direct.carrierReleases, 1);
    CHECK_EQ(direct.observerReleases, 1);
}

TEST(destroyingADirectSSHSessionCancelsQueuedRepliesAndObserverCallbacks)
{
    DirectSession direct;
    REQUIRE(direct.session);
    ubiquittyIOSSessionStart(direct.session.get(), 80, 24);
    drainMainQueue();
    direct.sent.clear();
    const int framesBefore = direct.frames;

    direct.deliver("\033]2;queued title\007\007\033[6n");
    ubiquittyIOSSessionNotifyClose(direct.session.get(), UbiquittyIOSCarrierOutcomeClosed, "peer closed");
    direct.session.reset();
    drainMainQueue();
    CHECK(direct.sent.empty());
    CHECK_EQ(direct.frames, framesBefore);
    CHECK_EQ(direct.titles, 0);
    CHECK_EQ(direct.bells, 0);
    CHECK_EQ(direct.exits, 0);
    CHECK_EQ(direct.stops, 1);
    CHECK_EQ(direct.carrierReleases, 1);
    CHECK_EQ(direct.observerReleases, 1);
}

UBIQUITTY_TEST_MAIN()
