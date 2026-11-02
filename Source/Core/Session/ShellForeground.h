// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once
// Whether the terminal's foreground process group is the shell's own work or a
// job the user started. Pure logic over facts the platform reads off the group's
// members; every reader of "is the shell in the foreground" — the close
// confirmation, the running-job marker, the at-prompt status, the resize reflow —
// takes its answer from here through `PAL::ProcessFacts::foregroundIsShell`.
//
// A shell hands the terminal to more than the user's jobs. Prompt hooks written
// as `( … & )` fork a subshell, and an interactive shell makes every foreground
// subshell a job in its own process group, so for as long as it lives the group
// is not the shell's. That instant follows every command and every Ctrl-C, when
// closing is most likely. Its members carry the distinction:
//
// - A fork that has not exec'd runs the shell's own code, as the shell does at
//   its prompt. A loop the shell runs in a subshell is no more a job than the
//   same loop run in the shell itself.
// - A program the shell exec'd as its own child is a job: `sleep`, `vim`, `ssh`,
//   a nested shell, and every element of a pipeline.
// - A program a subshell started is a job too, unless it ignores SIGINT. A shell
//   without job control, as inside a subshell, starts `cmd &` that way, so the
//   program a hook backgrounds is told apart from one a subshell waits for,
//   such as the `sleep` in `( sleep 30; true )`.
//
// Facts rather than time: a rule that waited for the group to persist would
// still read a slow hook as a job, and would answer late for a real one.

#include "PAL/Process.h"

#include <algorithm>
#include <cstdint>
#include <span>

namespace Ubiquitty::Session {

/// Whether one member of the foreground group makes the group a job.
///
/// - Parameters:
///   - member: The member's facts.
///   - shellProcessID: The session's shell, past any `login` wrapper.
/// - Returns: Whether the member is a program running on the user's behalf.
[[nodiscard]] constexpr bool isJobProcess(const PAL::Process::GroupMember& member, std::uint32_t shellProcessID)
{
    if (member.isZombie || !member.hasExecuted)
        return false;
    if (member.parentProcessID == shellProcessID)
        return true;
    return !member.isInterruptIgnored;
}

/// Whether the foreground group is the shell's own work.
///
/// A group with no live member reads as the shell's: its job has ended, and the
/// shell is taking the terminal back.
///
/// - Parameters:
///   - members: Every member of the group.
///   - shellProcessID: The session's shell, past any `login` wrapper.
/// - Returns: Whether no member is a job.
[[nodiscard]] constexpr bool isShellOwnedForegroundGroup(std::span<const PAL::Process::GroupMember> members, std::uint32_t shellProcessID)
{
    return std::ranges::none_of(members, [&](const PAL::Process::GroupMember& member) { return isJobProcess(member, shellProcessID); });
}

} // namespace Ubiquitty::Session
