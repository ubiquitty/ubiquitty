// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Presentation/SelectionColor.h"

#include <algorithm>

namespace Ubiquitty::Linux::Presentation {

namespace {

float mixChannel(float ground, float overlay, float strength)
{
    return strength * overlay + (1.0f - strength) * ground;
}

// The channel Core's wash must carry: wash = opacity * colour + (1 - opacity) * ground.
float washChannel(float ground, float target)
{
    const float opacity = Rendering::nativeSelectionOpacity;
    return std::clamp((target - (1.0f - opacity) * ground) / opacity, 0.0f, 1.0f);
}

} // namespace

Rendering::Vec4 nativeWashMatching(Rendering::Vec4 ground, Rendering::Vec4 overlay, float strength)
{
    return {
        washChannel(ground.x, mixChannel(ground.x, overlay.x, strength)),
        washChannel(ground.y, mixChannel(ground.y, overlay.y, strength)),
        washChannel(ground.z, mixChannel(ground.z, overlay.z, strength)),
        1.0f,
    };
}

Rendering::Vec4 desktopSelectionColor(Rendering::Vec4 ground, Rendering::Vec4 accent, SelectionFocus focus)
{
    if (focus == SelectionFocus::Focused)
        return nativeWashMatching(ground, accent, focusedSelectionStrength);
    // libadwaita's view ink: white on a dark view, near-black at 80% on a
    // light one, judged on the frame's own ground as its header ink is.
    const float lightness = 0.2126f * ground.x + 0.7152f * ground.y + 0.0722f * ground.z;
    const bool isGroundDark = lightness < 0.5f;
    const float inkStrength = 0.8f;
    const Rendering::Vec4 ink = isGroundDark
        ? Rendering::Vec4 { 1.0f, 1.0f, 1.0f, 1.0f }
        : Rendering::Vec4 { mixChannel(ground.x, 0.0f, inkStrength), mixChannel(ground.y, 0.0f, inkStrength),
              mixChannel(ground.z, 6.0f / 255.0f, inkStrength), 1.0f };
    return nativeWashMatching(ground, ink, unfocusedSelectionStrength);
}

} // namespace Ubiquitty::Linux::Presentation
