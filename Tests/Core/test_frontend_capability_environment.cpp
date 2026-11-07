// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "PAL/Capability.h"
#include "Platform/Linux/CapabilityPolicy.h"
#include "Platform/Web/WebCapabilityPolicy.h"
#include "Platform/Wscons/CapabilityPolicy.h"
#include "Platform/iOS/CapabilityPolicy.h"
#include "Platform/macOS/UBCapabilityPolicy.h"

#include <cstdlib>
#include <utility>

using namespace Ubiquitty;

TEST(theEnvironmentCannotRelaxFrontendPolicies)
{
    Linux::LinuxCapabilityPolicy linuxPolicy;
    Wscons::WsconsCapabilityPolicy wsconsPolicy;
    WebCapabilityPolicy webPolicy;
    UBCapabilityPolicy macOSPolicy;
    IOS::IOSCapabilityPolicy iOSPolicy;
    CapabilityPolicy* frontends[] = { &linuxPolicy, &wsconsPolicy, &webPolicy, &macOSPolicy, &iOSPolicy };
    for (unsigned code = 0; code <= std::to_underlying(Capability::None); ++code) {
        const auto capability = static_cast<Capability>(code);
        for (auto origin : { CapabilityOrigin::Local, CapabilityOrigin::Agent, CapabilityOrigin::Remote }) {
            // A frontend answers PAL's default with nobody to ask, which the
            // environment does not enter, and never a Prompt that unattended
            // consent could turn into an Allow.
            for (auto* policy : frontends) {
                const CapabilityDecision decision = policy->check(capability, origin, {});
                CHECK(decision == defaultDecisionWithoutConsent(capability, origin));
                CHECK(decision != CapabilityDecision::Prompt);
            }
        }
    }
}

int main(int argc, char** argv)
{
    // Set before any policy query so process-local environment caching cannot
    // make a negative regression vacuous. Each test process is isolated.
    if (::setenv("UBIQUITTY_UNATTENDED", "1", 1) != 0)
        return 2;
    UBIQUITTY_TEST_PIN_PREFERENCES();
    return UbiquittyTest::runRegisteredCases(argc, argv);
}
