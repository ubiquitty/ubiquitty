// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Assert the capability gate refuses an exfiltrating read to a non-Local
// origin and serves it to a Local one, and answers a feature query for both.
//
// Both arms of the read, because either alone passes against a defect: a policy
// that denies everything looks correct if you only test the refusal, and a
// policy that allows everything looks correct if you only test the allow. The
// feature query is the third arm: programs block on DA for capability
// detection, so a policy that refused it to a Remote peer would stall the
// peer's programs while reading as strict.
//
// Replies are the observable because Core queues them on the terminal, where
// this reads exactly what the gate let through. DECRQCRA checksums cells, which
// is exfiltration; DA reveals nothing past the screen the peer already sees.
/// Checks that clipboard reads respect origin permissions while feature queries remain available.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeCapabilityOrigin()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-capability-origin: no term\n");
        return 1;
    }
    term->capabilityPolicy = &app().capabilityPolicy;

    const auto replyTo = [term](Ubiquitty::CapabilityOrigin origin, std::string_view query) {
        term->outputLength = 0;
        term->currentCapabilityOrigin = origin;
        Ubiquitty::processBytes(term, query);
        std::string reply(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
        term->outputLength = 0;
        return reply;
    };
    constexpr std::string_view checksumQuery = "\x1b[1;0;1;1;1;1*y";
    constexpr std::string_view attributesQuery = "\x1b[c";
    const std::string remoteChecksum = replyTo(Ubiquitty::CapabilityOrigin::Remote, checksumQuery);
    const std::string localChecksum = replyTo(Ubiquitty::CapabilityOrigin::Local, checksumQuery);
    const std::string remoteAttributes = replyTo(Ubiquitty::CapabilityOrigin::Remote, attributesQuery);

    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    term->capabilityPolicy = nullptr;

    const bool didPass = remoteChecksum.empty() && localChecksum.starts_with("\x1bP1!~") && remoteAttributes.starts_with("\x1b[?");
    g_print("smoke-capability-origin: remote checksum = \"");
    printEscaped(remoteChecksum);
    g_print("\" (expected empty), local checksum = \"");
    printEscaped(localChecksum);
    g_print("\", remote DA = \"");
    printEscaped(remoteAttributes);
    g_print("\" -- %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
