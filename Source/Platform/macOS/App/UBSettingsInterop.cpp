// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "UBSettingsInterop.h"

#include "Core/Themes/ThemeApply.h"
#include "Platform/macOS/UBBackgroundBlur.h"

namespace Ubiquitty::SwiftBridge {

int systemLightTheme() { return Themes::resolvedAutomaticThemeIndex(Themes::AutomaticAppearance::Light); }

int systemDarkTheme() { return Themes::resolvedAutomaticThemeIndex(Themes::AutomaticAppearance::Dark); }

bool backgroundBlurRadiusCompiledIn() { return UB_ENABLE_BACKGROUND_BLUR != 0; }

} // namespace Ubiquitty::SwiftBridge
