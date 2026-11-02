// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Self-update for the AppImage build, using its embedded update address and
// wrapping appimageupdatetool (CLI) / AppImageUpdate (GUI) for the
// in-app "Check for Updates…" action and the `--check-update` flag.
//
// No-op unless running from a genuine packaged AppImage: $APPIMAGE set and the
// kernel-verified running binary (/proc/self/exe) laid out inside a packaged
// AppDir — never a bare $APPDIR/$PATH env-var check (attacker-influenceable). The
// tool is resolved only from that verified AppDir, never a PATH search.
//
// Auto-update design + runbook: Docs/auto-update.md.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace Ubiquitty::Linux {

class Updater {
public:
    enum class Status {
        NotAnAppImage, // not launched from an AppImage — self-update N/A
        ToolMissing, // no appimageupdatetool/AppImageUpdate available
        UpToDate, // newest version already installed
        UpdateAvailable,
        UpdateApplied, // written over the running image; a relaunch picks it up
        UpdateFailed, // the updater ran and did not replace the image
        Error,
    };

    // True when running from an AppImage (the only context self-update applies).
    static bool isAppImage();
    // The running AppImage's path, read from the kernel's mount table; empty
    // when no mount backs the verified AppDir.
    static std::string appImagePath();

    // Check for a newer release without downloading it (a small zsync metadata
    // fetch). Blocks briefly on the network. Maps appimageupdatetool's
    // --check-for-update exit code.
    static Status check();

    /// The pieces of ``check`` a caller needs to run it without blocking:
    /// the early answers, or the argv to spawn and watch.
    ///
    /// A status other than ``UpdateAvailable`` is final — show it. With
    /// ``UpdateAvailable`` the argv is filled and the answer is the spawned
    /// tool's exit code: 0 up to date, 1 update available, anything else
    /// ``Error``.
    ///
    /// - Parameters:
    ///   - argvOut: Receives the check command when the tool exists.
    /// - Returns: The early answer, or ``UpdateAvailable`` when argvOut holds
    ///   a command to run.
    static Status planCheck(std::vector<std::string>& argvOut);

    /// The pieces of an in-place update a caller needs to run it without
    /// blocking: the early answers, or the argv to spawn and watch.
    ///
    /// A status other than ``UpdateAvailable`` is final — show it. With
    /// ``UpdateAvailable`` the argv is filled, and the answer is what
    /// ``statusForApplyExit`` makes of the child's wait status.
    ///
    /// Spawn it with ``spawnDetachedForWatch``: the tool overwrites the file
    /// this process is running from, so it has to outlive a quit, and its
    /// ending is the only place a refused or failed update is visible.
    ///
    /// - Parameters:
    ///   - argvOut: Receives the apply command when the tool exists.
    /// - Returns: The early answer, or ``UpdateAvailable`` when argvOut holds
    ///   a command to run.
    static Status planUpdate(std::vector<std::string>& argvOut);

    /// What a finished updater child says about the update.
    ///
    /// The tool exits zero once the image is replaced, so anything else — a
    /// refusal, a failed download, a signal — is a failure the user is told
    /// about rather than a silent no-op.
    ///
    /// - Parameter waitStatus: The status ``waitpid`` (or a GLib child watch)
    ///   reported for the child.
    /// - Returns: ``UpdateApplied`` or ``UpdateFailed``.
    static Status statusForApplyExit(int waitStatus);

    static const char* statusString(Status);
};

/// Spawns the tool without waiting, for a caller that watches the exit itself.
///
/// The child is not reaped here: the caller owns the wait — a GLib child
/// watch, a waitpid of its own — and a caller that forgets it leaks a zombie
/// until this process exits.
///
/// - Parameters:
///   - argv: The command line; argv[0] is resolved through PATH.
/// - Returns: The child's process id, or -1 when the spawn failed.
int spawnForWatch(const std::vector<std::string>& argv);

/// Spawns the tool in a session of its own, still as our child.
///
/// An in-place update replaces the file this process is running from, so the
/// updater has to survive our exit and the hang-up that reaches a session on
/// terminal close. ``setsid`` puts it out of that reach; it does not sever the
/// parent link, so the caller still waits on it and still learns how the
/// update ended.
///
/// - Parameters:
///   - argv: The command line; argv[0] is resolved through PATH.
/// - Returns: The child's process id, or -1 when the spawn failed.
int spawnDetachedForWatch(const std::vector<std::string>& argv);

#if UBIQUITTY_ENABLE_TEST_HOOKS
/// Test seam over the helpers this file keeps private.
///
/// The public surface can only reach them from inside a packaged AppImage:
/// every path through check()/startUpdate() stops at the kernel-verified
/// /proc/self/exe layout, which no test binary satisfies. The suffix
/// anchoring, the lstat trust check and the two spawn shapes are exactly the
/// security-relevant halves, so a test drives them here rather than leaving
/// them provable only in production.
namespace ForTest {
std::string appDirFromExePath(const std::string& exePath);
bool isTrustedExecutable(const std::string& path);
int runAndWait(const std::vector<std::string>& argv);
/// The file backing the mount whose mount point is exactly `appDirectory`.
///
/// The parse, separated from the read of `/proc/self/mountinfo` so the rule
/// that decides which file a self-update overwrites can be stated against
/// fixtures rather than against whatever this machine happens to have mounted.
///
/// - Parameters:
///   - mountInfo: The contents of a mountinfo file.
///   - appDirectory: The AppDir, as derived from `/proc/self/exe`.
/// - Returns: The mount's source when it is an absolute path, else empty.
std::string appImagePathFromMountInfo(std::string_view mountInfo, const std::string& appDirectory);

/// One mountinfo field with its octal escapes resolved.
///
/// The kernel escapes space, tab, newline and backslash as three-digit octal.
/// A sequence that is not one of those is left alone, so a literal backslash in
/// a path survives unchanged.
///
/// - Parameter field: One space-delimited field, as written by the kernel.
/// - Returns: The field's decoded text.
std::string decodeMountInfoField(std::string_view field);
} // namespace ForTest
#endif

} // namespace Ubiquitty::Linux
