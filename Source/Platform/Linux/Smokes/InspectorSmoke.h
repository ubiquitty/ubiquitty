// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-inspector — the process-inspector row format over the portable
// PAL::Process::marker policy. The live tree needs a real PTY (verified by hand);
// here, synthetic records assert the marker column: "$"/"#" (root) login shell,
// "•" for not-safe-to-close, none for an allowlisted process.
/// Checks process-inspector markers for synthetic process records.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeInspector()
{
    auto record = [](const char* name, std::uint32_t processID, bool isLeader, const char* user) {
        Ubiquitty::PAL::Process::Record r {};
        r.name = name;
        r.user = user;
        r.processID = processID;
        r.isSessionLeader = isLeader ? 1 : 0;
        return r;
    };
    const std::string loginRow = formatProcessRow(record("-zsh", 100, true, "user"));
    const std::string rootRow = formatProcessRow(record("-bash", 1, true, "root"));
    const std::string vimRow = formatProcessRow(record("vim", 200, false, "user"));
    const std::string sshRow = formatProcessRow(record("ssh", 300, false, "user"));

    const bool hasLoginRow = loginRow == "$ -zsh (100)";
    const bool hasRootRow = rootRow == "# -bash (1)";
    // "vim" isn't safe-to-close → a "•" marker precedes the name (multibyte; just
    // assert a marker prefix + the name/processID tail).
    const bool hasVimMarker = vimRow.find("vim (200)") != std::string::npos && !vimRow.starts_with("vim");
    const bool hasWhitelistedSSH = sshRow == "ssh (300)"; // whitelisted → no marker

    const bool didPass = hasLoginRow && hasRootRow && hasVimMarker && hasWhitelistedSSH;
    g_print("smoke-inspector: login=\"%s\" root=\"%s\" vim=\"%s\" ssh=\"%s\" -- %s\n", loginRow.c_str(), rootRow.c_str(), vimRow.c_str(), sshRow.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
