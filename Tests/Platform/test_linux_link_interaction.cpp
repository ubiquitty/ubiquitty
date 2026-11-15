// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "TerminalFixture.h"

#include "Core/Mouse/Mouse.h"
#include "Core/Preferences/Preferences.h"
#include "Core/TerminalOperations.h"
#include "Platform/Linux/Input/LinkInteraction.h"

using namespace Ubiquitty;
using namespace Ubiquitty::Input;
using namespace Ubiquitty::Linux;

TEST(nativeControlRevealsDetectedLinksWithoutUsingTheWindowManagerChord)
{
    Preferences::Values configuration;
    const LinkTargetFacts guessed { false, false, "https://example.com" };
    PointerMoment moment;
    CHECK(!LinkInteraction(moment, configuration).canOpen(guessed));
    moment.held.hasControl = true;
    CHECK(LinkInteraction(moment, configuration).canOpen(guessed));
    CHECK(LinkInteraction(moment, configuration).probe() == LinkProbe::Any);
    moment.held.hasShift = true;
    CHECK(!LinkInteraction(moment, configuration).canOpen(guessed));
    moment.held = { .hasCommand = true };
    CHECK(!LinkInteraction(moment, configuration).canOpen(guessed));
}

TEST(alternateScreenAndMouseReportingAreIndependentLinkFacts)
{
    Terminal terminal;
    hardReset(terminal);
    resize(terminal, 6, 40);
    Preferences::Values configuration;
    const LinkTargetFacts guessed { false, false, "https://example.com" };
    const LinkTargetFacts declared { true, false, "https://example.com" };
    for (const std::string_view bytes : { "", "\x1b[?1049h", "\x1b[?1049l\x1b[?1003h", "\x1b[?1049h" }) {
        UbiquittyTest::feed(terminal, bytes);
        PointerMoment moment;
        moment.isMouseReporting = Mouse::tracksPointer(&terminal);
        const LinkInteraction interaction(moment, configuration);
        CHECK(interaction.canOpen(declared));
        CHECK_EQ(interaction.canOpen(guessed), moment.isMouseReporting);
        CHECK(interaction.probe() == (moment.isMouseReporting ? LinkProbe::Any : LinkProbe::Declared));
        moment.held.hasControl = true;
        CHECK(LinkInteraction(moment, configuration).canOpen(guessed));
    }
}

TEST(disablingPlainLinkOverridesKeepsExplicitControlAndSelectionPrecedence)
{
    Preferences::Values configuration;
    configuration.linksOverrideReporting = false;
    PointerMoment moment;
    moment.isMouseReporting = true;
    const LinkTargetFacts declared { true, false, "https://example.com" };
    const LinkTargetFacts guessed { false, false, "https://example.com" };
    CHECK(LinkInteraction(moment, configuration).probe() == LinkProbe::None);
    CHECK(!LinkInteraction(moment, configuration).canOpen(declared));
    moment.held.hasControl = true;
    CHECK(LinkInteraction(moment, configuration).canOpen(declared));
    CHECK(LinkInteraction(moment, configuration).canOpen(guessed));
    configuration.osc8ClickOpens = false;
    CHECK(LinkInteraction(moment, configuration).canOpen(guessed));
    moment.held = {};
    CHECK(LinkInteraction(moment, configuration).probe() == LinkProbe::None);
    configuration.selectModifier = "ctrl";
    moment.held.hasControl = true;
    CHECK(!LinkInteraction(moment, configuration).canOpen(declared));
    CHECK(LinkInteraction(moment, configuration).reportingState().isSelectionOverrideModifierArmed);
}

TEST(reportingOverrideKeepsPathsAndConnectionSchemesModifierGated)
{
    Preferences::Values configuration;
    PointerMoment moment;
    moment.isMouseReporting = true;
    const LinkInteraction plain(moment, configuration);
    CHECK(plain.canOpen({ false, false, "https://example.com" }));
    CHECK(plain.canOpen({ false, false, "file:///tmp/notes" }));
    CHECK(!plain.canOpen({ false, true, "/tmp/notes" }));
    CHECK(!plain.canOpen({ false, false, "mailto:test@example.com" }));
    CHECK(!plain.canOpen({ true, false, "ssh://example.com" }));
    moment.held.hasControl = true;
    const LinkInteraction controlled(moment, configuration);
    CHECK(controlled.canOpen({ false, true, "/tmp/notes" }));
    CHECK(controlled.canOpen({ true, false, "ssh://example.com" }));
}

UBIQUITTY_TEST_MAIN()
