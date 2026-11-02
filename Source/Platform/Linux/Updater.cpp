// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/Updater.cpp — see Updater.h.
//
// No GTK here: fork/exec/waitpid only, so the logic is shared by the headless
// `--check-update` flag and the in-app menu action. Built -fno-exceptions.
#include "Platform/Linux/Updater.h"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include <limits.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace Ubiquitty::Linux {

namespace {

// True when `path` is a regular, non-symlink, executable file — the trust check
// for a resolved updater-tool candidate. lstat (not stat) rejects a planted
// symlink rather than following it.
//
// No owner check by design: verifiedAppDir() anchors the path to the squashfs
// mount backing this running process, whose contents are exactly what shipped in
// the runtime-immutable AppImage (writing needs a fresh mount, i.e. root),
// regardless of the uid the FUSE layer reports. The path anchor is the mitigation.
bool isTrustedExecutable(const std::string& path)
{
    struct stat st;
    if (path.empty() || ::lstat(path.c_str(), &st) != 0)
        return false;
    if (!S_ISREG(st.st_mode))
        return false;
    return ::access(path.c_str(), X_OK) == 0;
}

// Derive the AppDir root from a resolved executable path, or empty when it
// doesn't match the packaged layout (<AppDir>/usr/bin/ubiquitty-linux). Anchoring
// on that literal suffix ties the root to what the kernel says is running — not
// the spoofable $APPDIR. Pure (no I/O) so it's independently testable.
std::string appDirFromExePath(const std::string& exePath)
{
    static const char suffix[] = "/usr/bin/ubiquitty-linux";
    const std::size_t suffixLength = sizeof(suffix) - 1;
    if (exePath.size() <= suffixLength)
        return std::string();
    if (exePath.compare(exePath.size() - suffixLength, suffixLength, suffix) != 0)
        return std::string();
    return exePath.substr(0, exePath.size() - suffixLength);
}

// Resolve the AppDir root from /proc/self/exe (kernel-verified — a process can't
// spoof its own path). Empty when unreadable or not laid out as a packaged
// AppImage.
std::string verifiedAppDir()
{
    char buffer[PATH_MAX];
    const ssize_t n = ::readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
    if (n <= 0)
        return std::string();
    buffer[n] = '\0';
    return appDirFromExePath(std::string(buffer));
}

// Decode one mountinfo field. The kernel escapes space, tab, newline and
// backslash as three-digit octal, so a mount whose path contains a space
// arrives as `\040` and a naive reader would compare the wrong string.
std::string decodeMountInfoField(std::string_view field)
{
    std::string decoded;
    decoded.reserve(field.size());
    for (std::size_t i = 0; i < field.size(); ++i) {
        const bool hasOctalEscape = field[i] == '\\' && i + 3 < field.size()
            && field[i + 1] >= '0' && field[i + 1] <= '3'
            && field[i + 2] >= '0' && field[i + 2] <= '7'
            && field[i + 3] >= '0' && field[i + 3] <= '7';
        if (!hasOctalEscape) {
            decoded.push_back(field[i]);
            continue;
        }
        decoded.push_back(static_cast<char>(((field[i + 1] - '0') << 6) | ((field[i + 2] - '0') << 3) | (field[i + 3] - '0')));
        i += 3;
    }
    return decoded;
}

// The file a mount is backed by, for the mount whose mount point is exactly
// the AppDir.
//
// This is what replaces $APPIMAGE. The AppDir is derived from /proc/self/exe,
// which a process cannot spoof, and the mount table is the kernel's answer to
// what that directory is mounted from -- so the file the updater is about to
// overwrite becomes a fact about the running process rather than a string its
// environment supplied.
//
// mountinfo's layout is `id parent major:minor root mountpoint options...` then
// a lone `-` separator, then `fstype source superopts`. The optional fields
// before the separator are variable in number, which is what the separator is
// for: the source cannot be found by counting from the left.
//
// Only an exact mount-point match, and only an absolute source. An AppImage's
// AppDir is a mount point in its own right; a prefix match would accept the
// mount that /tmp itself sits on and name that filesystem's backing device as
// the file to replace.
std::string appImagePathFromMountInfo(std::string_view mountInfo, const std::string& appDirectory)
{
    if (appDirectory.empty())
        return std::string();
    std::size_t lineStart = 0;
    while (lineStart < mountInfo.size()) {
        std::size_t lineEnd = mountInfo.find('\n', lineStart);
        if (lineEnd == std::string_view::npos)
            lineEnd = mountInfo.size();
        const std::string_view line = mountInfo.substr(lineStart, lineEnd - lineStart);
        lineStart = lineEnd + 1;

        std::vector<std::string_view> fields;
        std::size_t fieldStart = 0;
        while (fieldStart < line.size()) {
            const std::size_t fieldEnd = line.find(' ', fieldStart);
            if (fieldEnd == std::string_view::npos) {
                fields.push_back(line.substr(fieldStart));
                break;
            }
            if (fieldEnd > fieldStart)
                fields.push_back(line.substr(fieldStart, fieldEnd - fieldStart));
            fieldStart = fieldEnd + 1;
        }
        // mountpoint is the fifth field, and the source is the second after the
        // separator. A line carrying neither is not a mount line.
        if (fields.size() < 7)
            continue;
        if (decodeMountInfoField(fields[4]) != appDirectory)
            continue;
        std::size_t separator = 0;
        while (separator < fields.size() && fields[separator] != "-")
            ++separator;
        if (separator + 2 >= fields.size())
            continue;
        const std::string source = decodeMountInfoField(fields[separator + 2]);
        if (source.empty() || source[0] != '/')
            continue; // a device name or a pseudo-source is not a file to replace
        return source;
    }
    return std::string();
}

// The AppImage backing this process, or empty when that cannot be established.
std::string verifiedAppImagePath()
{
    const std::string appDirectory = verifiedAppDir();
    if (appDirectory.empty())
        return std::string();
    std::ifstream mountInfoStream("/proc/self/mountinfo");
    if (!mountInfoStream)
        return std::string();
    const std::string mountInfo((std::istreambuf_iterator<char>(mountInfoStream)), std::istreambuf_iterator<char>());
    return appImagePathFromMountInfo(mountInfo, appDirectory);
}

// Resolve the updater tool from the verified AppDir only — never from $APPDIR or
// a PATH search (both attacker-influenceable). Prefer the GUI variant when asked.
// Empty when not a genuine AppImage, no candidate exists, or one fails the trust
// check.
std::string findTool(bool preferGui)
{
    const std::string appDirectory = verifiedAppDir();
    if (appDirectory.empty())
        return std::string();
    const char* names2[2] = { preferGui ? "AppImageUpdate" : "appimageupdatetool", preferGui ? "appimageupdatetool" : "AppImageUpdate" };
    for (const char* name : names2) {
        std::string p = appDirectory + "/usr/bin/" + name;
        if (isTrustedExecutable(p))
            return p;
    }
    return std::string();
}

// Whether the child leaves our session. An update outlives the process it is
// replacing, so it needs a session of its own; a check runs and reports back
// within our lifetime and keeps ours.
enum class SessionMode {
    Inherit,
    Detached,
};

// fork/exec the tool with the given args, returning the child's process id or
// -1. Every spawn here goes through this: the argv marshalling and the
// APPIMAGE_EXTRACT_AND_RUN nested tools need to run without FUSE are the same
// whether the caller waits, watches, or does neither.
//
// setsid() only leaves our session. It does not sever the parent link, so a
// detached child is still waited on and its ending is still observable.
pid_t forkExec(const std::vector<std::string>& argv, SessionMode sessionMode)
{
    const pid_t processID = ::fork();
    if (processID != 0)
        return processID; // the parent's answer, and -1 stays -1
    if (sessionMode == SessionMode::Detached)
        ::setsid();
    ::setenv("APPIMAGE_EXTRACT_AND_RUN", "1", 1);
    std::vector<char*> childArgv;
    childArgv.reserve(argv.size() + 1);
    for (const std::string& argument : argv)
        childArgv.push_back(const_cast<char*>(argument.c_str()));
    childArgv.push_back(nullptr);
    ::execvp(childArgv[0], childArgv.data());
    ::_exit(127); // exec failed
}

// fork/exec the tool; wait and return the exit code, or -1 if the child
// couldn't be run / didn't exit normally.
int runAndWait(const std::vector<std::string>& argv)
{
    const pid_t processID = forkExec(argv, SessionMode::Inherit);
    if (processID < 0)
        return -1;
    int status = 0;
    if (::waitpid(processID, &status, 0) < 0)
        return -1;
    if (!WIFEXITED(status))
        return -1;
    return WEXITSTATUS(status);
}

} // namespace

int spawnForWatch(const std::vector<std::string>& argv)
{
    return static_cast<int>(forkExec(argv, SessionMode::Inherit));
}

int spawnDetachedForWatch(const std::vector<std::string>& argv)
{
    return static_cast<int>(forkExec(argv, SessionMode::Detached));
}

bool Updater::isAppImage()
{
    // $APPIMAGE is spoofable; require it non-empty and the kernel-verified binary
    // laid out inside a packaged AppDir, so a forged APPIMAGE with no matching
    // real mount can't claim self-update is available.
    const char* p = ::getenv("APPIMAGE");
    if (p == nullptr || p[0] == '\0')
        return false;
    return !verifiedAppDir().empty();
}

std::string Updater::appImagePath()
{
    // The kernel's answer, not the environment's. $APPIMAGE is set by the
    // AppImage runtime and is attacker-influenceable: anything able to seed one
    // variable in this process's environment would otherwise choose the file a
    // self-update writes a download over.
    //
    // Empty when no mount backs the AppDir. An extracted run
    // (APPIMAGE_EXTRACT_AND_RUN) has none to read, so nothing here can establish
    // which file is the running image, and an update that cannot name its target
    // does not start.
    return verifiedAppImagePath();
}

Updater::Status Updater::planCheck(std::vector<std::string>& argvOut)
{
    if (!isAppImage())
        return Status::NotAnAppImage;
    const std::string tool = findTool(/*preferGui=*/false);
    if (tool.empty())
        return Status::ToolMissing;
    argvOut = { tool, "--check-for-update", appImagePath() };
    return Status::UpdateAvailable;
}

Updater::Status Updater::check()
{
    if (!isAppImage())
        return Status::NotAnAppImage;
    const std::string tool = findTool(/*preferGui=*/false);
    if (tool.empty())
        return Status::ToolMissing;
    // appimageupdatetool --check-for-update: exit 0 = up to date, 1 = update
    // available, >1 = error.
    const int code = runAndWait({ tool, "--check-for-update", appImagePath() });
    switch (code) {
    case 0:
        return Status::UpToDate;
    case 1:
        return Status::UpdateAvailable;
    default:
        return Status::Error;
    }
}

Updater::Status Updater::planUpdate(std::vector<std::string>& argvOut)
{
    if (!isAppImage())
        return Status::NotAnAppImage;
    const std::string tool = findTool(/*preferGui=*/true);
    if (tool.empty())
        return Status::ToolMissing;
    const std::string target = appImagePath();
    if (target.empty())
        return Status::Error; // no mount names the running image; see appImagePath
    // No flag = download + apply in place. The GUI variant shows its own
    // progress window; the CLI variant runs to completion in the background.
    argvOut = { tool, target };
    return Status::UpdateAvailable;
}

Updater::Status Updater::statusForApplyExit(int waitStatus)
{
    // Only a clean zero means the image was replaced. A signalled child, or a
    // tool that refused the update, leaves the old image in place — which is
    // indistinguishable from success unless it is said out loud.
    if (!WIFEXITED(waitStatus) || WEXITSTATUS(waitStatus) != 0)
        return Status::UpdateFailed;
    return Status::UpdateApplied;
}

const char* Updater::statusString(Status s)
{
    switch (s) {
    case Status::NotAnAppImage:
        return "Ubiquitty isn’t running from an AppImage, so it can’t update itself. Update it the way you installed it.";
    case Status::ToolMissing:
        return "No AppImage updater was found. Install AppImageUpdate or run appimaged, then try again.";
    case Status::UpToDate:
        return "Ubiquitty is up to date.";
    case Status::UpdateAvailable:
        return "A new version of Ubiquitty is available.";
    case Status::UpdateApplied:
        return "The update is installed. Restart Ubiquitty to use the new version.";
    case Status::UpdateFailed:
        return "The update couldn’t be installed. The current version is unchanged.";
    case Status::Error:
        return "Ubiquitty couldn’t check for updates. Check your internet connection, then try again.";
    }
    return "unknown";
}

#if UBIQUITTY_ENABLE_TEST_HOOKS
namespace ForTest {
std::string appDirFromExePath(const std::string& exePath) { return Linux::appDirFromExePath(exePath); }
bool isTrustedExecutable(const std::string& path) { return Linux::isTrustedExecutable(path); }
int runAndWait(const std::vector<std::string>& argv) { return Linux::runAndWait(argv); }
std::string appImagePathFromMountInfo(std::string_view mountInfo, const std::string& appDirectory) { return Linux::appImagePathFromMountInfo(mountInfo, appDirectory); }
std::string decodeMountInfoField(std::string_view field) { return Linux::decodeMountInfoField(field); }
} // namespace ForTest
#endif

} // namespace Ubiquitty::Linux
