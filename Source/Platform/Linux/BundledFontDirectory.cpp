// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/BundledFontDirectory.h"

#include "Core/Rendering/BundledFonts.h"

#include <unistd.h>

namespace Ubiquitty::Linux {

std::string bundledFontDirectory()
{
    char path[4096];
    const ssize_t length = ::readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (length <= 0)
        return std::string();
    path[length] = '\0';
    const std::string full(path);
    const std::size_t slash = full.find_last_of('/');
    if (slash == std::string::npos)
        return std::string(".");
    return full.substr(0, slash);
}

std::string bundledFontPath(std::string_view family, std::string_view directory)
{
    const std::string_view file = Rendering::bundledFontFile(family);
    if (file.empty())
        return std::string();
    const std::string base = directory.empty() ? bundledFontDirectory() : std::string(directory);
    if (base.empty())
        return std::string();
    return base + "/" + std::string(file);
}

} // namespace Ubiquitty::Linux
