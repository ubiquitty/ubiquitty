// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/GTK/GObjectPointer.h"
#include "Platform/Linux/Presentation/ChromeGround.h"

#include <gtk/gtk.h>

#include <map>
#include <string>
#include <string_view>
#include <utility>

namespace Ubiquitty::Linux::GTK {

/// Loads the icons of the programs a title names — an agent's logo, say —
/// from the catalog Core ships (`Title::processIconCatalog`), staged beside
/// the binary.
///
/// A drawn icon keeps its colours and is handed to GTK as a file, so its
/// vectors are drawn at the size shown. A template icon is a shape inked like
/// the chrome's text: it is rendered once per ink and handed over as a
/// texture, so a header and a libadwaita tab bar both show it in that ink.
class ProcessIconLoader final {
public:
    ProcessIconLoader() = default;
    ProcessIconLoader(const ProcessIconLoader&) = delete;
    ProcessIconLoader& operator=(const ProcessIconLoader&) = delete;

    /// The icon for a program, drawn on a ground.
    ///
    /// - Parameters:
    ///   - key: The program's catalog key.
    ///   - ground: The ground the icon is drawn on.
    /// - Returns: A borrowed icon, or null for no key, an unknown key, or a
    ///   file that would not load.
    [[nodiscard]] GIcon* icon(std::string_view key, const Presentation::ChromeGround& ground);

    /// The directory the catalog's icon files are staged in, beside the binary.
    [[nodiscard]] static const std::string& iconDirectory();

private:
    std::map<std::pair<std::string, bool>, GObjectPointer<GIcon>> m_icons;
};

} // namespace Ubiquitty::Linux::GTK
