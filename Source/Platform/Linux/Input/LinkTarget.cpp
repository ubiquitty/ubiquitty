// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Input/LinkTarget.h"

#include "Core/Attributes/LinkRun.h"
#include "Core/Runtime/HostedWindows.h"
#include "Core/Session/FileLink.h"

#include <glib.h>

namespace Ubiquitty::Linux {

std::string linkTargetURI(const LinkTargetFacts& target, Runtime::FilesystemLocation filesystemLocation, std::string_view baseDirectory, std::string_view homeDirectory)
{
    if ((target.isFilePath || Session::isFileLinkURI(target.uri)) && filesystemLocation != Runtime::FilesystemLocation::ThisMachine)
        return {};
    if (!target.isFilePath)
        return std::string(target.uri);
    if (target.uri.find('\0') != std::string_view::npos)
        return {};
    const std::string path = Attributes::LinkRun::resolveFilePathCandidate(target.uri, baseDirectory, homeDirectory);
    // The native filename API takes a C string. A NUL must not turn a
    // measured candidate into a different, truncated path.
    if (path.empty() || path.find('\0') != std::string::npos)
        return {};
    gchar* encoded = g_filename_to_uri(path.c_str(), nullptr, nullptr);
    if (!encoded)
        return {};
    std::string uri(encoded);
    g_free(encoded);
    return uri;
}

} // namespace Ubiquitty::Linux
