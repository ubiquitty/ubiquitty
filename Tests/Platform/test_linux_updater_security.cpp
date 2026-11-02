// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// Tests/Platform/test_linux_updater_security.cpp
//
// Security negative for LinuxUpdater: $APPDIR, $APPIMAGE, and $PATH are all
// attacker-influenceable environment values. Forging any or
// all of them must not make Updater::isAppImage()/check()/planUpdate()
// trust an attacker-planted "updater" binary — the AppDir root is verified
// against the kernel-reported running executable (/proc/self/exe), which a
// process cannot spoof the way it can setenv(). This test binary is not
// laid out as <AppDir>/usr/bin/ubiquitty-linux, so isAppImage() must read
// false regardless of what the forged env vars claim.

#include "Platform/Linux/Updater.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <csignal>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// The session a spawned child ended up in, once it is far enough along to be
// asked.
//
// setsid() runs in the child between the fork and the exec, and the parent gets
// no order against it: a getsid() taken too early reads the session the child
// has not left yet and reports whatever the caller hoped for. The child touches
// `markerPath` as its first act after exec, so a marker on disk means the whole
// pre-exec half — setsid included — is already done.
//
// Returns -1 if the child never got that far.
static pid_t sessionOfSpawnedChild(pid_t childID, const std::string& markerPath)
{
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (::access(markerPath.c_str(), F_OK) == 0)
            return ::getsid(childID);
        ::usleep(1000);
    }
    return -1;
}

// A command that announces its own exec and then stays alive to be asked about.
static std::vector<std::string> markerThenWait(const std::string& markerPath)
{
    return { "/bin/sh", "-c", "touch \"$1\"; sleep 30", "sh", markerPath };
}

// Plant an executable regular file at `path` (the attacker's fake updater).
static void plantExecutable(const std::string& path)
{
    int fileDescriptor = ::open(path.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0755);
    if (fileDescriptor >= 0) {
        static const char body[] = "#!/bin/sh\nexit 0\n";
        CHECK_EQ(::write(fileDescriptor, body, sizeof(body) - 1), static_cast<ssize_t>(sizeof(body) - 1));
        ::close(fileDescriptor);
    }
}

int main()
{
    char tmplate[] = "/tmp/ub-updater-security-XXXXXX";
    const char* directory = ::mkdtemp(tmplate);
    CHECK(directory != nullptr);
    if (!directory)
        return 1;

    const std::string fakeAppDir = std::string(directory) + "/fakeappdir";
    const std::string fakeBin = fakeAppDir + "/usr/bin";
    const std::string fakePathDirectory = std::string(directory) + "/fakepathdir";
    ::mkdir(fakeAppDir.c_str(), 0755);
    ::mkdir((fakeAppDir + "/usr").c_str(), 0755);
    ::mkdir(fakeBin.c_str(), 0755);
    ::mkdir(fakePathDirectory.c_str(), 0755);

    plantExecutable(fakeBin + "/appimageupdatetool");
    plantExecutable(fakeBin + "/AppImageUpdate");
    plantExecutable(fakePathDirectory + "/appimageupdatetool");
    plantExecutable(fakePathDirectory + "/AppImageUpdate");

    // Forge every env var a naive resolver would trust: a fake APPDIR pointing
    // at the attacker's bundled-looking tool, a fake PATH with another
    // attacker tool ahead of the real one, and a non-empty APPIMAGE (the
    // "we're running from an AppImage" signal).
    ::setenv("APPDIR", fakeAppDir.c_str(), 1);
    ::setenv("APPIMAGE", "/tmp/definitely-not-a-real-appimage.AppImage", 1);
    std::string forgedPath = fakePathDirectory + ":" + (::getenv("PATH") ? ::getenv("PATH") : "");
    ::setenv("PATH", forgedPath.c_str(), 1);

    // This test binary is not <AppDir>/usr/bin/ubiquitty-linux, so the
    // verified-AppDir check must reject every forged signal above.
    CHECK(!Ubiquitty::Linux::Updater::isAppImage());
    CHECK(Ubiquitty::Linux::Updater::check() == Ubiquitty::Linux::Updater::Status::NotAnAppImage);
    std::vector<std::string> applyCommand { "sentinel" };
    CHECK(Ubiquitty::Linux::Updater::planUpdate(applyCommand) == Ubiquitty::Linux::Updater::Status::NotAnAppImage);
    // A refused plan leaves the caller's vector alone, so nothing downstream
    // can spawn what a forged environment nominated.
    CHECK(applyCommand.size() == 1 && applyCommand[0] == "sentinel");

    // appImagePath does not relay $APPIMAGE. The variable above is set, points
    // at a plausible path, and is ignored: the file a self-update overwrites is
    // read from the kernel's mount table for the verified AppDir, so a process
    // that can seed one environment variable cannot choose it. This test
    // binary is not mounted from an AppImage, so there is no such file.
    CHECK(Ubiquitty::Linux::Updater::appImagePath().empty());
    ::unsetenv("APPDIR");
    ::unsetenv("APPIMAGE");
    CHECK(Ubiquitty::Linux::Updater::appImagePath().empty());

    // Every status has a sentence.
    using Status = Ubiquitty::Linux::Updater::Status;
    for (const Status status : { Status::NotAnAppImage, Status::ToolMissing, Status::UpToDate, Status::UpdateAvailable, Status::UpdateApplied, Status::UpdateFailed, Status::Error }) {
        const char* text = Ubiquitty::Linux::Updater::statusString(status);
        CHECK(text != nullptr && text[0] != '\0');
    }

    // The private halves, through the ForTest seam: the suffix anchor that
    // derives the AppDir root, the lstat trust check, and the two spawn
    // shapes. These are the pieces the public surface can only reach from
    // inside a packaged AppImage.
    {
        namespace ForTest = Ubiquitty::Linux::ForTest;

        // The mount table is what names the file an update overwrites, so the
        // read of it is a security surface and is exercised as one.
        {
            // What a running AppImage looks like: the AppDir is a mount point
            // in its own right, and its source is the image file.
            const std::string mounted
                = "24 30 0:22 / /proc rw,nosuid - proc proc rw\n"
                  "31 24 0:5 / /tmp rw,nosuid - tmpfs tmpfs rw\n"
                  "77 31 0:44 / /tmp/.mount_Ubiq7x rw,nodev,relatime - fuse.squashfuse /home/user/Apps/Ubiquitty.AppImage ro,user_id=1000\n";
            CHECK(ForTest::appImagePathFromMountInfo(mounted, "/tmp/.mount_Ubiq7x") == "/home/user/Apps/Ubiquitty.AppImage");

            // A different AppDir is not this one. The answer is empty rather
            // than the nearest mount: naming the wrong file here is the whole
            // failure being prevented.
            CHECK(ForTest::appImagePathFromMountInfo(mounted, "/tmp/.mount_Other").empty());

            // The AppDir's PARENT is a mount, and a prefix match would take it
            // and hand back a tmpfs as the file to replace.
            CHECK(ForTest::appImagePathFromMountInfo(mounted, "/tmp").empty());

            // The same shape with an absolute path as the parent's source,
            // which is what makes a prefix match dangerous rather than merely
            // wrong. /dev/sda1 is a path, and an updater handed it writes a
            // downloaded image over the block device holding the filesystem.
            // An AppDir with no mount of its own answers empty here.
            const std::string diskBacked
                = "31 24 8:1 / /tmp rw,relatime - ext4 /dev/sda1 rw\n";
            CHECK(ForTest::appImagePathFromMountInfo(diskBacked, "/tmp/.mount_Ubiq7x").empty());
            CHECK(ForTest::appImagePathFromMountInfo(diskBacked, "/tmp") == "/dev/sda1");

            // Nothing mounted there at all — an extracted run. Empty, so the
            // update is refused rather than aimed at a guess.
            CHECK(ForTest::appImagePathFromMountInfo("", "/tmp/.mount_Ubiq7x").empty());

            // The optional fields before the `-` vary in number, which is why
            // the source cannot be found by counting from the left. Same mount,
            // with a propagation field present.
            const std::string propagated
                = "77 31 0:44 / /tmp/.mount_Ubiq7x rw,nodev shared:12 master:3 - fuse.squashfuse /home/user/Ubiquitty.AppImage ro\n";
            CHECK(ForTest::appImagePathFromMountInfo(propagated, "/tmp/.mount_Ubiq7x") == "/home/user/Ubiquitty.AppImage");

            // A source that is not a path is not a file to overwrite.
            const std::string deviceBacked
                = "77 31 0:44 / /tmp/.mount_Ubiq7x rw - squashfs squashfs ro\n";
            CHECK(ForTest::appImagePathFromMountInfo(deviceBacked, "/tmp/.mount_Ubiq7x").empty());

            // The kernel escapes space, tab, newline and backslash as octal in
            // both the mount point and the source. A reader that compared the
            // raw text would miss the mount for anyone whose home has a space
            // in it, and would hand back a path that does not exist.
            const std::string escaped
                = "77 31 0:44 / /tmp/.mount_A\\040B rw - fuse.squashfuse /home/user/My\\040Apps/Ubiquitty\\040Beta.AppImage ro\n";
            CHECK(ForTest::appImagePathFromMountInfo(escaped, "/tmp/.mount_A B") == "/home/user/My Apps/Ubiquitty Beta.AppImage");
            CHECK(ForTest::decodeMountInfoField("a\\040b") == "a b");
            CHECK(ForTest::decodeMountInfoField("tab\\011here") == "tab\there");
            CHECK(ForTest::decodeMountInfoField("back\\134slash") == "back\\slash");
            // Not an escape: too few digits, and a digit outside the range.
            CHECK(ForTest::decodeMountInfoField("\\04") == "\\04");
            CHECK(ForTest::decodeMountInfoField("\\409") == "\\409");
            CHECK(ForTest::decodeMountInfoField("plain") == "plain");

            // A truncated line names no mount and must not be read as one.
            CHECK(ForTest::appImagePathFromMountInfo("77 31 0:44 / /tmp/.mount_Ubiq7x rw -\n", "/tmp/.mount_Ubiq7x").empty());
            CHECK(ForTest::appImagePathFromMountInfo("nonsense\n", "/tmp/.mount_Ubiq7x").empty());
            CHECK(ForTest::appImagePathFromMountInfo(mounted, "").empty());
        }

        // The anchor takes only the packaged layout, and only with something
        // above it to be the root.
        CHECK(ForTest::appDirFromExePath("").empty());
        CHECK(ForTest::appDirFromExePath("/usr/bin/ubiquitty-linux").empty());
        CHECK(ForTest::appDirFromExePath("/opt/thing/usr/bin/other").empty());
        CHECK(ForTest::appDirFromExePath("/opt/pkg/usr/bin/ubiquitty-linux") == "/opt/pkg");

        // Trust: a regular executable file, reached without following links.
        const std::string trusted = std::string(directory) + "/trusted-tool";
        plantExecutable(trusted);
        CHECK(ForTest::isTrustedExecutable(trusted));
        CHECK(!ForTest::isTrustedExecutable(""));
        CHECK(!ForTest::isTrustedExecutable(std::string(directory) + "/absent"));
        const std::string plain = std::string(directory) + "/plain-file";
        {
            std::FILE* f = std::fopen(plain.c_str(), "w");
            if (f)
                std::fclose(f);
        }
        CHECK(!ForTest::isTrustedExecutable(plain)); // regular but not executable
        const std::string link = std::string(directory) + "/link-to-tool";
        CHECK(::symlink(trusted.c_str(), link.c_str()) == 0);
        CHECK(!ForTest::isTrustedExecutable(link)); // a planted symlink never passes

        // The waited spawn maps the child's ending: exit code as-is, a failed
        // exec as 127, a signalled child as -1.
        CHECK(ForTest::runAndWait({ "/usr/bin/true" }) == 0);
        CHECK(ForTest::runAndWait({ "/usr/bin/false" }) == 1);
        CHECK(ForTest::runAndWait({ std::string(directory) + "/absent" }) == 127);
        CHECK(ForTest::runAndWait({ "/bin/sh", "-c", "kill -9 $$" }) == -1);
    }

    // How an update ends. The tool overwrites the running image, so only a
    // clean zero means it happened: a refusal and a signalled child both leave
    // the old version in place, and reporting either as success is the failure
    // this mapping exists to prevent.
    {
        using Status = Ubiquitty::Linux::Updater::Status;
        // The wait statuses a real child produces, taken from real children so
        // the encoding is the kernel's rather than this test's idea of it.
        int waitStatus = 0;

        const int appliedID = Ubiquitty::Linux::spawnDetachedForWatch({ "/usr/bin/true" });
        CHECK(appliedID > 0);
        CHECK(::waitpid(appliedID, &waitStatus, 0) == appliedID);
        CHECK(Ubiquitty::Linux::Updater::statusForApplyExit(waitStatus) == Status::UpdateApplied);

        const int refusedID = Ubiquitty::Linux::spawnDetachedForWatch({ "/usr/bin/false" });
        CHECK(refusedID > 0);
        CHECK(::waitpid(refusedID, &waitStatus, 0) == refusedID);
        CHECK(Ubiquitty::Linux::Updater::statusForApplyExit(waitStatus) == Status::UpdateFailed);

        const int signalledID = Ubiquitty::Linux::spawnDetachedForWatch({ "/bin/sh", "-c", "kill -9 $$" });
        CHECK(signalledID > 0);
        CHECK(::waitpid(signalledID, &waitStatus, 0) == signalledID);
        CHECK(Ubiquitty::Linux::Updater::statusForApplyExit(waitStatus) == Status::UpdateFailed);

        // A tool that is not there fails the exec, which the child reports as
        // 127 — a failed update, not a missing one.
        const int absentID = Ubiquitty::Linux::spawnDetachedForWatch({ std::string(directory) + "/absent" });
        CHECK(absentID > 0);
        CHECK(::waitpid(absentID, &waitStatus, 0) == absentID);
        CHECK(Ubiquitty::Linux::Updater::statusForApplyExit(waitStatus) == Status::UpdateFailed);

        // Detached means a session of its own, not a severed parent. Both
        // halves matter: the session is what puts the updater out of reach of
        // a hang-up when the terminal that launched us closes, and the parent
        // link is what lets every wait above happen at all.
        const std::string detachedMarker = std::string(directory) + "/detached-exec";
        const int detachedID = Ubiquitty::Linux::spawnDetachedForWatch(markerThenWait(detachedMarker));
        CHECK(detachedID > 0);
        CHECK(sessionOfSpawnedChild(detachedID, detachedMarker) == detachedID); // its own leader
        CHECK(::kill(detachedID, SIGKILL) == 0);
        CHECK(::waitpid(detachedID, &waitStatus, 0) == detachedID); // still our child

        // The watched spawn stays in our session, which is what a check wants:
        // it reports back within our lifetime and has nothing to survive.
        const std::string inheritedMarker = std::string(directory) + "/inherited-exec";
        const int inheritedID = Ubiquitty::Linux::spawnForWatch(markerThenWait(inheritedMarker));
        CHECK(inheritedID > 0);
        CHECK(sessionOfSpawnedChild(inheritedID, inheritedMarker) == ::getsid(0));
        CHECK(::kill(inheritedID, SIGKILL) == 0);
        CHECK(::waitpid(inheritedID, &waitStatus, 0) == inheritedID);
    }

    return UBIQUITTY_TEST_SUMMARY();
}
