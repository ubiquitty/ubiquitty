// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_shell_foreground.cpp — Session/ShellForeground.h, the rule that tells a
// shell's own work in the foreground from a job. Each case is the group a real
// shell builds for the shape it names; Tests/Platform/test_pty.cpp drives a
// real zsh through the same shapes.

#include "Core/Session/ShellForeground.h"

#include <array>

using Ubiquitty::PAL::Process::GroupMember;
using Ubiquitty::Session::isJobProcess;
using Ubiquitty::Session::isShellOwnedForegroundGroup;

namespace {

constexpr std::uint32_t shell = 500;

constexpr GroupMember forkOf(std::uint32_t processID, std::uint32_t parent)
{
    return { .processID = processID, .parentProcessID = parent, .hasExecuted = false, .isInterruptIgnored = false, .isZombie = false };
}

constexpr GroupMember program(std::uint32_t processID, std::uint32_t parent)
{
    return { .processID = processID, .parentProcessID = parent, .hasExecuted = true, .isInterruptIgnored = false, .isZombie = false };
}

constexpr GroupMember backgroundedProgram(std::uint32_t processID, std::uint32_t parent)
{
    return { .processID = processID, .parentProcessID = parent, .hasExecuted = true, .isInterruptIgnored = true, .isZombie = false };
}

constexpr GroupMember zombie(std::uint32_t processID, std::uint32_t parent)
{
    return { .processID = processID, .parentProcessID = parent, .hasExecuted = true, .isInterruptIgnored = false, .isZombie = true };
}

} // namespace

TEST(aPromptHookSubshellIsTheShells)
{
    // `( function & )`: the subshell, and the fork it leaves running shell code.
    const std::array members { forkOf(600, shell), forkOf(601, 600) };
    CHECK(isShellOwnedForegroundGroup(members, shell));
    // Its fork outlives it and is reparented, still in the group.
    const std::array orphaned { forkOf(601, 1) };
    CHECK(isShellOwnedForegroundGroup(orphaned, shell));
}

TEST(aProgramAPromptHookBackgroundsIsTheShells)
{
    // `( program & )`: the subshell started the program with SIGINT ignored,
    // as a shell without job control starts every asynchronous list.
    const std::array members { forkOf(600, shell), backgroundedProgram(601, 600) };
    CHECK(isShellOwnedForegroundGroup(members, shell));
    const std::array orphaned { backgroundedProgram(601, 1) };
    CHECK(isShellOwnedForegroundGroup(orphaned, shell));
}

TEST(aGroupWhoseJobHasEndedIsTheShells)
{
    CHECK(isShellOwnedForegroundGroup({}, shell));
    const std::array members { zombie(600, shell) };
    CHECK(isShellOwnedForegroundGroup(members, shell));
}

TEST(aProgramTheShellRanIsAJob)
{
    // `sleep 30`, `vim`, `ssh`, a nested shell: exec'd children of the shell,
    // whatever their signal dispositions.
    const std::array members { program(600, shell) };
    CHECK(!isShellOwnedForegroundGroup(members, shell));
    const std::array ignoring { backgroundedProgram(600, shell) };
    CHECK(!isShellOwnedForegroundGroup(ignoring, shell));
    CHECK(isJobProcess(program(600, shell), shell));
}

TEST(aPipelineIsAJobWhateverLeadsIt)
{
    // `cat file | less` once cat has exited and not been reaped.
    const std::array afterTheFirst { zombie(600, shell), program(601, shell) };
    CHECK(!isShellOwnedForegroundGroup(afterTheFirst, shell));
    // `{ … } | less`: the group's leader is a fork running shell code.
    const std::array ledByAFork { forkOf(600, shell), program(601, shell) };
    CHECK(!isShellOwnedForegroundGroup(ledByAFork, shell));
}

TEST(aProgramASubshellWaitsForIsAJob)
{
    // `( sleep 30; true )`: Ctrl-C reaches the program, so it is the user's.
    const std::array members { forkOf(600, shell), program(601, 600) };
    CHECK(!isShellOwnedForegroundGroup(members, shell));
}

TEST(aZombieIsNeverAJob)
{
    CHECK(!isJobProcess(zombie(601, 600), shell));
    CHECK(!isJobProcess(forkOf(601, shell), shell));
}

UBIQUITTY_TEST_MAIN()
