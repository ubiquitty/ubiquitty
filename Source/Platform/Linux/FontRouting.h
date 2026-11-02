// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Preferences/Preferences.h"

#include <string>
#include <string_view>

namespace Ubiquitty::Linux {

void configureFontRouting(int fontPixelSize, const Preferences::Values& config);
std::string diagnoseFontRoutes(std::string_view utf8Text, const char* rendererName);

} // namespace Ubiquitty::Linux
