// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Input/LinkInteraction.h"

#include "Core/Attributes/LinkRun.h"
#include "Core/Preferences/PreferencesAccessors.h"

namespace Ubiquitty::Linux {

LinkInteraction::LinkInteraction(const Input::PointerMoment& moment, const Preferences::Values& configuration)
    : m_isPlainClickEnabled(Preferences::Effective::osc8ClickOpens(configuration))
{
    auto policy = Input::pointerPolicyFromPreferences(configuration);
    policy.linkChord = { .hasControl = true };
    m_reporting = Input::pointerReportingState(moment, policy);
}

Input::LinkProbe LinkInteraction::probe() const
{
    return Input::linkProbe(m_reporting, m_isPlainClickEnabled);
}

bool LinkInteraction::canOpen(const LinkTargetFacts& target) const
{
    if (target.uri.empty() || !Input::allowsLocalLinkInteraction(m_reporting))
        return false;
    if (m_reporting.isLinkModifierArmed)
        return true;
    if (!m_isPlainClickEnabled || Attributes::LinkRun::requiresLinkModifier(target.uri))
        return false;
    if (!m_reporting.isMouseReporting || !m_reporting.isLinkOverrideEnabled)
        return target.isHyperlink;
    return Input::plainClickOpenableUnderReporting({
        .isOSC8 = target.isHyperlink,
        .isFile = target.isFilePath,
        .hasOpenableScheme = Input::isOpenableURLScheme(target.uri),
    });
}

const Input::PointerReportingState& LinkInteraction::reportingState() const
{
    return m_reporting;
}

} // namespace Ubiquitty::Linux
