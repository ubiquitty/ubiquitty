// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Runtime/HostedWindows.h"
#include "Core/Session/FileLink.h"
#include "Platform/Linux/Input/LinkTarget.h"

#include <string>

using namespace Ubiquitty;

namespace {

std::string pathTarget(std::string_view candidate, std::string_view directory = "/work/project", std::string_view home = "/home/user")
{
    return Linux::linkTargetURI({ false, true, candidate }, Runtime::FilesystemLocation::ThisMachine, directory, home);
}

std::string decodedPath(std::string_view uri)
{
    return Session::localFileLinkPath(uri, {}, Session::FilePathEncoding::Bytes);
}

TEST(detectedAbsoluteRelativeAndHomePathsReachTheFileScheme)
{
    CHECK(pathTarget("/tmp/notes.txt") == "file:///tmp/notes.txt");
    CHECK(pathTarget("src/main.cpp") == "file:///work/project/src/main.cpp");
    CHECK(pathTarget("./src/../notes.txt") == "file:///work/project/notes.txt");
    CHECK(pathTarget("~/notes.txt") == "file:///home/user/notes.txt");
}

TEST(relativePathsFollowTheRequestingPanesDirectory)
{
    CHECK(pathTarget("src/main.cpp", "/first/project") == "file:///first/project/src/main.cpp");
    CHECK(pathTarget("src/main.cpp", "/second/project") == "file:///second/project/src/main.cpp");
    CHECK(pathTarget("../notes.txt", "/second/project") == "file:///second/notes.txt");
}

TEST(nativeEncodingPreservesSpacesPercentSignsAndLiteralFragments)
{
    const std::string uri = pathTarget("/tmp/a file%23#name.txt");
    CHECK(uri == "file:///tmp/a%20file%2523%23name.txt");
    CHECK(decodedPath(uri) == "/tmp/a file%23#name.txt");
    CHECK(decodedPath(pathTarget("~/my notes.txt")) == "/home/user/my notes.txt");
}

TEST(aLiteralColonSuffixDoesNotIntroduceAnEditorPosition)
{
    const std::string uri = pathTarget("src/main.cpp:12:5");
    CHECK(decodedPath(uri) == "/work/project/src/main.cpp:12:5");
    CHECK(Session::fileLinkLine(uri).line == 0);
    CHECK(Session::fileLinkLine(uri).column == 0);
}

TEST(unresolvablePathsNeverFallBackToTheTerminalProcessesDirectory)
{
    CHECK(pathTarget("").empty());
    CHECK(pathTarget("src/main.cpp", "").empty());
    CHECK(pathTarget("src/main.cpp", "relative/project").empty());
    CHECK(pathTarget("~/notes.txt", "/work/project", "").empty());
    CHECK(pathTarget("~user2/notes.txt").empty());
    CHECK(pathTarget(std::string_view("/tmp/notes\0ignored", 18)).empty());
    CHECK(pathTarget(std::string_view("/tmp/a\0/../notes.txt", 20)).empty());
    CHECK(pathTarget("/tmp/notes.txt", "", "") == "file:///tmp/notes.txt");
}

TEST(declaredFileURIsKeepTheirAuthorityEncodingAndLineReference)
{
    for (const std::string_view uri : { "file:///tmp/my%20notes.txt#L12:5", "file://localhost/tmp/notes.txt", "file:/tmp/notes.txt" })
        CHECK(Linux::linkTargetURI({ true, false, uri }, Runtime::FilesystemLocation::ThisMachine, "/ignored", "/ignored") == uri);
}

TEST(nonFileURLsReachTheExistingSchemePolicyUnchanged)
{
    for (const std::string_view uri : { "https://example.com/a%20b#part", "mailto:reader@example.com", "ssh://host/path", "javascript:alert(1)" })
        CHECK(Linux::linkTargetURI({ false, false, uri }, Runtime::FilesystemLocation::ThisMachine, "/ignored", "/ignored") == uri);
}

TEST(remoteAndUnknownFilesystemsCannotOpenCoincidentallyMatchingLocalFiles)
{
    for (const auto location : { Runtime::FilesystemLocation::AnotherMachine, Runtime::FilesystemLocation::Unknown }) {
        CHECK(Linux::linkTargetURI({ false, true, "/tmp/notes.txt" }, location, "/work/project", "/home/user").empty());
        CHECK(Linux::linkTargetURI({ true, false, "file:///tmp/notes.txt#L12:5" }, location, "/work/project", "/home/user").empty());
        CHECK(Linux::linkTargetURI({ false, true, "src/main.cpp" }, location, "/work/project", "/home/user").empty());
        CHECK(Linux::linkTargetURI({ true, false, "https://example.com" }, location, "/ignored", "/ignored") == "https://example.com");
    }
}

} // namespace

UBIQUITTY_TEST_MAIN()
