// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "HostedPaneFixture.h"

// test_ios_session_clients — the clipboard writer and the capability policy
// the iOS shell gives each pane's terminal (Source/Platform/iOS/SessionClients.cpp).
//
// The shell's panes are surfaces the shared Swift kit builds outside any
// workspace model, so nothing in the shell assigns a client and no source
// check can see a pane go without a policy. These cases run the shell's own
// installer over sessions made the way a surface makes them. The installer is
// portable C++, so it runs on any Apple host; the shell links it on iOS.

#include "Core/EffectGate.h"
#include "Core/Runtime/TerminalSession.h"
#include "Core/Runtime/WorkspaceSession.h"
#include "Core/Terminal.h"
#include "PAL/Capability.h"
#include "Platform/iOS/SessionClients.h"

using namespace Ubiquitty;
using namespace Ubiquitty::Runtime;

namespace {

/// The shell's installer as the process default for one case, and none after.
struct RegisteredSessionClients {
    RegisteredSessionClients() { IOS::registerSessionClients(); }
    ~RegisteredSessionClients() { WorkspaceSession::setDefaultTerminalClientInstaller(nullptr, nullptr); }

    RegisteredSessionClients(const RegisteredSessionClients&) = delete;
    RegisteredSessionClients& operator=(const RegisteredSessionClients&) = delete;
};

} // namespace

// Without the ask, the terminal has neither client and Core's fallback
// answers it. With it, the file-read gate, which refuses every origin when no
// policy is installed, answers Local, so the policy is the frontend's own and
// not the fallback; a Remote origin is still refused.
TEST(aPaneSessionTakesTheShellsClipboardAndPolicyWhenItAsks)
{
    const RegisteredSessionClients registered;
    TerminalSession* session = TerminalSession::make();
    REQUIRE(session);
    session->start(24, 80);
    Terminal* terminal = session->terminal();
    REQUIRE(terminal);
    CHECK(!terminal->clipboardClient);
    CHECK(!terminal->capabilityPolicy.installed());
    CHECK(!effectGranted(*terminal, Capability::FileReadAccess, {}));

    WorkspaceSession::installDefaultClients(*session);
    CHECK(terminal->clipboardClient);
    CHECK(terminal->capabilityPolicy.installed());
    CHECK(effectGranted(*terminal, Capability::FileReadAccess, {}));
    terminal->currentCapabilityOrigin = CapabilityOrigin::Remote;
    CHECK(!effectGranted(*terminal, Capability::FileReadAccess, {}));
    CHECK(effectAllowed(*terminal, Capability::DeviceAttributesRead, {}));
    CHECK(!effectAllowed(*terminal, Capability::ClipboardWrite, {}));
    terminal->currentCapabilityOrigin = CapabilityOrigin::Local;

    // The shell asks again once a pane attaches; a terminal that has both
    // keeps the ones it has.
    ClipboardClient* const installed = terminal->clipboardClient.get();
    WorkspaceSession::installDefaultClients(*session);
    CHECK(terminal->clipboardClient.get() == installed);
    releaseTerminalSession(session);
}

// An adopted terminal outlives the session that adopted it, so ending the
// adoption takes both clients back out of it; a pointer left behind would be
// the CheckedPtr abort at the session's teardown.
TEST(anAdoptedTerminalLosesTheShellsClientsWhenTheAdoptionEnds)
{
    const RegisteredSessionClients registered;
    UbiquittyTest::HostedPaneFixture pane;
    Terminal* external = pane.paneTerminal();
    REQUIRE(external);
    TerminalSession* adapter = TerminalSession::make();
    REQUIRE(adapter);
    adapter->start(24, 80);
    REQUIRE(adapter->adoptHostedPane(pane.sourceAddress(), UbiquittyTest::HostedPaneFixture::paneID));
    WorkspaceSession::installDefaultClients(*adapter);
    CHECK(external->clipboardClient);
    CHECK(external->capabilityPolicy.installed());
    adapter->endExternalAdoption();
    CHECK(!external->clipboardClient);
    CHECK(!external->capabilityPolicy.installed());
    releaseTerminalSession(adapter);
}

UBIQUITTY_TEST_MAIN()
