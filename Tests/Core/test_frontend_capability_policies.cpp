// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "TerminalFixture.h"

// test_frontend_capability_policies — what each frontend's own policy answers a
// principal that is not Local, through Core's gates.
//
// No frontend holds a consent question, so each answers PAL's default and
// refuses what PAL would ask about. The case that ships is the macOS app's tmux
// pane dialled over SSH, which runs as Remote under UBCapabilityPolicy: its
// programs block on DA, DSR and colour queries for capability detection, and
// the pane sends the answers back to tmux as the pane's input. Every case runs
// each frontend's shipped policy rather than a copy, and a refusal is paired
// with an answer, because a policy that refused everything and one that allowed
// everything would each pass half of them.

#include "Core/Protocol/Tmux/PaneReplies.h"
#include "Core/Protocol/Tmux/Tmux.h"
#include "Core/TerminalOperations.h"
#include "PAL/Capability.h"
#include "PAL/Stream.h"
#include "PAL/TerminalClients.h"
#include "Platform/Linux/CapabilityPolicy.h"
#include "Platform/Web/WebCapabilityPolicy.h"
#include "Platform/Wscons/CapabilityPolicy.h"
#include "Platform/iOS/CapabilityPolicy.h"
#include "Platform/macOS/UBCapabilityPolicy.h"

#include <array>
#include <charconv>
#include <cstddef>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

using namespace Ubiquitty;
using UbiquittyTest::feed;

namespace {

/// One of each frontend's shipped policy.
struct FrontendPolicies {
    Linux::LinuxCapabilityPolicy linuxPolicy;
    Wscons::WsconsCapabilityPolicy wsconsPolicy;
    WebCapabilityPolicy webPolicy;
    UBCapabilityPolicy macOSPolicy;
    IOS::IOSCapabilityPolicy iOSPolicy;

    /// Every policy, in a fixed order.
    [[nodiscard]] std::array<CapabilityPolicy*, 5> all() { return { &linuxPolicy, &wsconsPolicy, &webPolicy, &macOSPolicy, &iOSPolicy }; }
};

constexpr std::array nonLocalOrigins { CapabilityOrigin::Agent, CapabilityOrigin::Remote };

/// What a frontend owes one origin for one capability, read from the tier
/// table rather than from the function the policies call.
///
/// - Parameters:
///   - capability: The effect.
///   - origin: Who drives it.
/// - Returns: Allow for Local, and for a non-Local origin's effects that stay
///   on the grid; Deny for its host escapes and exfiltrating reads.
CapabilityDecision expectedFrontendDecision(Capability capability, CapabilityOrigin origin)
{
    if (origin == CapabilityOrigin::Local)
        return CapabilityDecision::Allow;
    switch (tierOf(capability)) {
    case CapabilityTier::LowRiskInfo:
    case CapabilityTier::Benign:
    case CapabilityTier::Rendering:
        return CapabilityDecision::Allow;
    case CapabilityTier::HostEscaping:
    case CapabilityTier::ReadExfil:
        return CapabilityDecision::Deny;
    }
    return CapabilityDecision::Deny;
}

/// A terminal under one frontend's policy, driven from one origin.
///
/// The policy outlives the terminal; anything installed on it afterwards is
/// declared before this, so it outlives the terminal too.
struct PolicedTerminal {
    PolicedTerminal(CapabilityPolicy& policy, CapabilityOrigin origin)
    {
        hardReset(terminal);
        resize(terminal, 5, 40);
        terminal.capabilityPolicy = &policy;
        terminal.currentCapabilityOrigin = origin;
    }

    ~PolicedTerminal()
    {
        terminal.clipboardClient = nullptr;
        terminal.capabilityPolicy = nullptr;
    }

    PolicedTerminal(const PolicedTerminal&) = delete;
    PolicedTerminal& operator=(const PolicedTerminal&) = delete;

    /// Feeds one sequence and drains every reply it drew.
    ///
    /// - Parameter sequence: The program's output.
    /// - Returns: The replies, empty when none was allowed.
    std::string replyTo(std::string_view sequence)
    {
        feed(terminal, sequence);
        std::array<char, 512> replies {};
        const int length = UbiquittyTest::drain(terminal, replies);
        return std::string(replies.data(), static_cast<std::size_t>(length));
    }

    Terminal terminal;
};

/// Records the OSC 52 writes that reach the clipboard.
struct RecordingClipboard final : ClipboardClient {
    int writeCount = 0;

    void writeClipboard(ClipboardBuffer, std::span<const char>) override { ++writeCount; }
};

/// Records what the pane writes to the tmux control channel.
struct RecordingStream final : PAL::ByteStream {
    std::string written;

    int read(std::span<char>) override { return 0; }
    int write(std::span<const char> bytes) override { return writeAll(bytes); }
    int writeAll(std::span<const char> bytes) override
    {
        written.append(bytes.data(), bytes.size());
        return static_cast<int>(bytes.size());
    }
    bool drainPendingWrite() override { return false; }
    bool hasPendingWrite() const override { return false; }
    int lastError() const override { return 0; }
};

/// Decodes `send-keys -t %<pane> -H xx xx …` lines back to the bytes they type.
///
/// - Parameters:
///   - written: The control channel's bytes.
///   - prefix: The command and target every line must start with.
/// - Returns: The typed bytes, or nothing past the first malformed line.
std::string decodeSendKeys(std::string_view written, std::string_view prefix)
{
    std::string decoded;
    while (!written.empty()) {
        if (!written.starts_with(prefix))
            return decoded;
        written.remove_prefix(prefix.size());
        while (written.size() >= 3 && written.front() == ' ') {
            unsigned value = 0;
            const auto result = std::from_chars(written.data() + 1, written.data() + 3, value, 16);
            if (result.ec != std::errc())
                return decoded;
            decoded.push_back(static_cast<char>(value));
            written.remove_prefix(3);
        }
        if (written.empty() || written.front() != '\n')
            return decoded;
        written.remove_prefix(1);
    }
    return decoded;
}

} // namespace

// The whole table, for every frontend. On the policies that refused every
// non-Local origin outright, every Benign, LowRiskInfo and Rendering row fails.
TEST(everyFrontendAnswersANonLocalOriginByTierAndNeverPrompts)
{
    FrontendPolicies policies;
    for (unsigned code = 0; code <= std::to_underlying(Capability::None); ++code) {
        const auto capability = static_cast<Capability>(code);
        for (CapabilityPolicy* policy : policies.all()) {
            for (CapabilityOrigin origin : { CapabilityOrigin::Local, CapabilityOrigin::Agent, CapabilityOrigin::Remote })
                CHECK(policy->check(capability, origin, {}) == expectedFrontendDecision(capability, origin));
        }
    }
    // The two effects PAL asks a remote owner about are refused, not asked.
    for (CapabilityPolicy* policy : policies.all()) {
        CHECK(policy->check(Capability::ClipboardWrite, CapabilityOrigin::Remote, {}) == CapabilityDecision::Deny);
        CHECK(policy->check(Capability::DesktopNotification, CapabilityOrigin::Remote, {}) == CapabilityDecision::Deny);
    }
}

// What programs block on for capability detection: DA, the cursor report and a
// colour query. Refused, each one costs the program its read timeout.
TEST(aRemoteOrAgentProgramUnderEveryFrontendGetsTheRepliesItBlocksOn)
{
    FrontendPolicies policies;
    for (CapabilityPolicy* policy : policies.all()) {
        for (CapabilityOrigin origin : nonLocalOrigins) {
            PolicedTerminal pane(*policy, origin);
            const std::string attributes = pane.replyTo("\033[c");
            CHECK(attributes.starts_with("\033[?") && attributes.ends_with("c"));
            CHECK_STR_EQ(pane.replyTo("\033[6n"), "\033[1;1R");
            CHECK(pane.replyTo("\033]11;?\033\\").starts_with("\033]11;rgb:"));
        }
    }
}

// A working-directory note changes nothing outside the grid the reader is
// already looking at.
TEST(aRemoteOrAgentProgramUnderEveryFrontendKeepsItsInformationalEffects)
{
    FrontendPolicies policies;
    for (CapabilityPolicy* policy : policies.all()) {
        for (CapabilityOrigin origin : nonLocalOrigins) {
            PolicedTerminal pane(*policy, origin);
            feed(pane.terminal, "\033]7;file:///tmp/remote-pane\033\\");
            CHECK_STR_EQ(pane.terminal.currentDirectory.view(), "/tmp/remote-pane");
        }
    }
}

// DECRQCRA reads cells back and is exfiltration; an OSC 52 write stages bytes
// the user may paste. Both are refused away from Local and served at Local, so
// the refusal is the origin's and not the sequence's.
TEST(aRemoteOrAgentProgramUnderEveryFrontendIsRefusedExfiltrationAndHostEscapes)
{
    constexpr std::string_view checksumQuery = "\033[1;0;1;1;1;1*y";
    constexpr std::string_view clipboardWrite = "\033]52;c;SGVsbG8=\033\\";
    FrontendPolicies policies;
    for (CapabilityPolicy* policy : policies.all()) {
        for (CapabilityOrigin origin : nonLocalOrigins) {
            RecordingClipboard clipboard;
            PolicedTerminal pane(*policy, origin);
            pane.terminal.clipboardClient = &clipboard;
            CHECK(pane.replyTo(checksumQuery).empty());
            feed(pane.terminal, clipboardWrite);
            CHECK_EQ(clipboard.writeCount, 0);
        }
        RecordingClipboard clipboard;
        PolicedTerminal local(*policy, CapabilityOrigin::Local);
        local.terminal.clipboardClient = &clipboard;
        CHECK(local.replyTo(checksumQuery).starts_with("\033P1!~"));
        feed(local.terminal, clipboardWrite);
        CHECK_EQ(clipboard.writeCount, 1);
    }
}

// The path the macOS app ships: an adopted tmux pane at Remote under the macOS
// policy answers DA, and the answer goes back to tmux as that pane's input, the
// way TmuxControlHost flushes a pane's replies after each delivery.
TEST(aRemoteTmuxPaneUnderTheMacOSPolicySendsItsDeviceAttributesBackToTmux)
{
    RecordingStream stream;
    UBCapabilityPolicy policy;
    PolicedTerminal pane(policy, CapabilityOrigin::Remote);
    feed(pane.terminal, "\033[c");
    Protocol::Tmux::TmuxClient client {};
    client.state = Protocol::Tmux::TmuxState::Line;
    Protocol::Tmux::flushPaneReplies(pane.terminal, &client, 7, stream);
    const std::string typed = decodeSendKeys(stream.written, "send-keys -t %7 -H");
    CHECK(typed.starts_with("\033[?") && typed.ends_with("c"));
}

UBIQUITTY_TEST_MAIN()
