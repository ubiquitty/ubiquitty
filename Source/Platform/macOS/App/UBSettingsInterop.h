// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// UBSettingsInterop.h — what the Swift Settings window needs from C++ that is
// not one preference's value. A preference is read and written by Core's key
// (`Preferences::effectiveValue`, `Preferences::configureOwnKey`); nothing here
// names a setting's storage.
//

namespace Ubiquitty::SwiftBridge {

/// The theme the light appearance applies when follow-system is on.
///
/// The configured `[appearance] system_light_theme` when it names a light
/// or adaptive theme, else the curated default, else the first light theme, so the picker
/// always shows a valid match. The policy is `Themes::resolvedAutomaticThemeIndex`, the
/// one the live auto-switch applies, so the picker and the switch cannot
/// disagree.
///
/// - Returns: A theme index, or -1 when the registry holds no light theme.
int systemLightTheme();

/// The theme the dark appearance applies when follow-system is on.
///
/// - Returns: A theme index, or -1 when the registry holds no dark theme.
int systemDarkTheme();

/// Whether this build compiles in the window-server blur radius.
///
/// The private CGS call (UBBackgroundBlur.h). When false the Settings UI
/// hides the Blur Radius slider — the blur itself is the system material's,
/// in every build, and the radius key would persist a number nothing reads.
///
/// - Returns: True when the radius reaches the window server.
bool backgroundBlurRadiusCompiledIn();

} // namespace Ubiquitty::SwiftBridge
