// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_selection_color.cpp — the colour a GNOME desktop selects text
// in, as the Linux frontend reports it to Core's native selection wash.

#include "Platform/Linux/Presentation/SelectionColor.h"

#include <cmath>

using namespace Ubiquitty;
using namespace Ubiquitty::Linux::Presentation;

namespace {

// What Core's wash draws over the ground with the reported colour.
Rendering::Vec4 washed(Rendering::Vec4 ground, Rendering::Vec4 reported)
{
    const float opacity = Rendering::nativeSelectionOpacity;
    return { opacity * reported.x + (1 - opacity) * ground.x, opacity * reported.y + (1 - opacity) * ground.y,
        opacity * reported.z + (1 - opacity) * ground.z, 1 };
}

bool near(Rendering::Vec4 left, Rendering::Vec4 right)
{
    return std::abs(left.x - right.x) < 1e-4f && std::abs(left.y - right.y) < 1e-4f && std::abs(left.z - right.z) < 1e-4f;
}

const Rendering::Vec4 darkGround { 0.09f, 0.09f, 0.10f, 1 };
const Rendering::Vec4 lightGround { 0.98f, 0.98f, 0.98f, 1 };
const Rendering::Vec4 blueAccent { 0.208f, 0.518f, 0.894f, 1 };

} // namespace

TEST(theWashLandsOnTheDesktopsMix)
{
    // Core washes at its own opacity; what reaches the screen is the
    // desktop's 30% accent over the ground.
    const Rendering::Vec4 reported = nativeWashMatching(darkGround, blueAccent, focusedSelectionStrength);
    const Rendering::Vec4 desktop { 0.3f * blueAccent.x + 0.7f * darkGround.x, 0.3f * blueAccent.y + 0.7f * darkGround.y,
        0.3f * blueAccent.z + 0.7f * darkGround.z, 1 };
    CHECK(near(washed(darkGround, reported), desktop));
}

TEST(aFocusedSelectionCarriesTheAccent)
{
    const Rendering::Vec4 focused = washed(darkGround, desktopSelectionColor(darkGround, blueAccent, SelectionFocus::Focused));
    CHECK(focused.z > focused.x + 0.1f); // blue leads: the accent shows
}

TEST(anUnfocusedSelectionIsNeutralGrey)
{
    for (const Rendering::Vec4 ground : { darkGround, lightGround }) {
        const Rendering::Vec4 grey = washed(ground, desktopSelectionColor(ground, blueAccent, SelectionFocus::Unfocused));
        CHECK(std::abs(grey.x - grey.y) < 0.01f && std::abs(grey.y - grey.z) < 0.02f);
        CHECK(!near(grey, ground)); // still visible as a selection
    }
}

TEST(theGreyLightensADarkGroundAndDarkensALightOne)
{
    CHECK(washed(darkGround, desktopSelectionColor(darkGround, blueAccent, SelectionFocus::Unfocused)).x > darkGround.x);
    CHECK(washed(lightGround, desktopSelectionColor(lightGround, blueAccent, SelectionFocus::Unfocused)).x < lightGround.x);
}

TEST(theReportedColourStaysInRange)
{
    for (const Rendering::Vec4 ground : { Rendering::Vec4 { 0, 0, 0, 1 }, Rendering::Vec4 { 1, 1, 1, 1 } }) {
        for (const SelectionFocus focus : { SelectionFocus::Focused, SelectionFocus::Unfocused }) {
            const Rendering::Vec4 color = desktopSelectionColor(ground, blueAccent, focus);
            CHECK(color.x >= 0 && color.x <= 1 && color.y >= 0 && color.y <= 1 && color.z >= 0 && color.z <= 1 && color.w == 1);
        }
    }
}

UBIQUITTY_TEST_MAIN()
