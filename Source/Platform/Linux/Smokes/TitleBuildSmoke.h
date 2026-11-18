// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks the platform-resolved directory segment in a composed window title.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeTitleBuild()
{
    struct Case {
        const char* cwd;
        const char* home;
        bool isFullPath;
        const char* want;
    };
    const Case cases[] = {
        { "/home/user/Projects/ubiquitty", "/home/user", false, "ubiquitty" }, // basename
        { "/home/user", "/home/user", false, "~" }, // exactly home → ~
        { "/home/user/Projects", "/home/user", true, "~/Projects" }, // full ~-path
        { "/var/log/", "/home/user", false, "log" }, // trailing slash trimmed
        { "", "/home/user", false, "" }, // no directory
    };
    bool doesLeadingMatch = true;
    std::string detail;
    for (const Case& testCase : cases) {
        const std::string got = titleDirectorySegment(testCase.cwd, testCase.home, testCase.isFullPath ? Ubiquitty::Title::PathFormat::FullPath : Ubiquitty::Title::PathFormat::BasenameOnly);
        if (got != testCase.want)
            doesLeadingMatch = false;
        detail += "[" + std::string(testCase.cwd) + "→" + got + "]";
    }

    // Integration sanity: formatTitle weaves the segments together (exact glyphs +
    // empty-segment dropping are host-tested in Core); here just confirm each
    // non-empty segment survives.
    const std::string title = Ubiquitty::PAL::Process::formatTitle("ubiquitty", "vim", "zsh", 80, 24, Ubiquitty::PAL::Process::DimensionFormat::IncludeDimensions, Ubiquitty::PAL::Process::TitleSeparator::Spaced);
    const bool doesTitleMatch = title.find("ubiquitty") != std::string::npos && title.find("vim") != std::string::npos && title.find("zsh") != std::string::npos && title.find("80") != std::string::npos && title.find("24") != std::string::npos;

    const bool didPass = doesLeadingMatch && doesTitleMatch;
    g_print("smoke-titlebuild: lead=%d %s title=\"%s\" -- %s\n", static_cast<int>(doesLeadingMatch), detail.c_str(), title.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
