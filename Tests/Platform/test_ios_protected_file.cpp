// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Helpers/TempDir.h"
#include "PAL/BoundedFile.h"
#include "PAL/DurableFile.h"
#include "Platform/iOS/ProtectedFile.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>

/// Defined in Swift (test_ios_protected_file_probe.swift): a file's protection
/// class is a Foundation resource value.
extern "C" bool ubiquittyTestHasCompleteProtection(const char* path);

using namespace Ubiquitty;

namespace {

constexpr std::array<std::byte, 4> content { std::byte { 0 }, std::byte { 1 }, std::byte { 254 }, std::byte { 255 } };

bool hasCompleteProtection(const std::string& path)
{
    return ubiquittyTestHasCompleteProtection(path.c_str());
}

} // namespace

TEST(aProtectedCreatorReturnsOnlyAnEmptyPrivateCompleteFile)
{
    Test::TempDir directory;
    REQUIRE(directory.valid());
    PAL::UnixFileDescriptor parent(::open(directory.path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    REQUIRE(parent);
    const auto path = directory.path() + "/record";
    auto file = Platform::createCompleteProtectedFile(parent.get(), "record");
    REQUIRE(file);
    struct stat status {};
    REQUIRE(::fstat(file.get(), &status) == 0);
    CHECK(S_ISREG(status.st_mode));
    CHECK_EQ(status.st_size, 0);
    CHECK_EQ(status.st_nlink, 1);
    CHECK_EQ(status.st_uid, ::geteuid());
    CHECK_EQ(status.st_mode & 0777, 0600);
    CHECK(hasCompleteProtection(path));
    CHECK_EQ(::write(file.get(), content.data(), content.size()), static_cast<ssize_t>(content.size()));
    const auto read = PAL::storageReadBounded(path.c_str(), content.size());
    REQUIRE(read);
    CHECK(std::ranges::equal(std::as_bytes(read->view()), content));
}

TEST(aProtectedCreatorNeverReplacesACollisionOrFollowsASymlink)
{
    Test::TempDir directory;
    REQUIRE(directory.valid());
    PAL::UnixFileDescriptor parent(::open(directory.path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    REQUIRE(parent);
    auto first = Platform::createCompleteProtectedFile(parent.get(), "target");
    REQUIRE(first);
    REQUIRE(::write(first.get(), content.data(), content.size()) == static_cast<ssize_t>(content.size()));
    struct stat original {};
    REQUIRE(::fstat(first.get(), &original) == 0);
    REQUIRE(::symlinkat("target", parent.get(), "link") == 0);
    REQUIRE(::mkdirat(parent.get(), "directory", 0700) == 0);
    for (const char* name : { "target", "link", "directory" }) {
        CHECK(!Platform::createCompleteProtectedFile(parent.get(), name));
        CHECK_EQ(errno, EEXIST);
    }
    struct stat after {};
    REQUIRE(::fstatat(parent.get(), "target", &after, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK_EQ(after.st_ino, original.st_ino);
    CHECK_EQ(after.st_size, static_cast<off_t>(content.size()));
    REQUIRE(::fstatat(parent.get(), "link", &after, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK(S_ISLNK(after.st_mode));
    const auto read = PAL::storageReadBounded((directory.path() + "/target").c_str(), content.size());
    REQUIRE(read);
    CHECK(std::ranges::equal(std::as_bytes(read->view()), content));
}

TEST(aProtectedCreatorRefusesInvalidNamesAndNonprivateParents)
{
    Test::TempDir directory;
    REQUIRE(directory.valid());
    PAL::UnixFileDescriptor parent(::open(directory.path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    REQUIRE(parent);
    for (const char* name : { "", ".", "..", "../elsewhere", "child/record" })
        CHECK(!Platform::createCompleteProtectedFile(parent.get(), name));
    CHECK(!Platform::createCompleteProtectedFile(parent.get(), nullptr));
    CHECK(!Platform::createCompleteProtectedFile(-1, "record"));
    REQUIRE(::chmod(directory.path().c_str(), 0755) == 0);
    CHECK(!Platform::createCompleteProtectedFile(parent.get(), "record"));
    CHECK(::faccessat(parent.get(), "record", F_OK, 0) != 0);
    REQUIRE(::chmod(directory.path().c_str(), 0700) == 0);
}

TEST(aProtectedCreatorFollowsThePinnedParentRatherThanItsReplacedOldPath)
{
    Test::TempDir directory;
    REQUIRE(directory.valid());
    const auto original = directory.path() + "/original";
    const auto moved = directory.path() + "/moved";
    REQUIRE(::mkdir(original.c_str(), 0700) == 0);
    PAL::UnixFileDescriptor parent(::open(original.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    REQUIRE(parent);
    REQUIRE(::rename(original.c_str(), moved.c_str()) == 0);
    REQUIRE(::mkdir(original.c_str(), 0700) == 0);
    auto file = Platform::createCompleteProtectedFile(parent.get(), "record");
    REQUIRE(file);
    CHECK(::access((original + "/record").c_str(), F_OK) != 0);
    CHECK(hasCompleteProtection(moved + "/record"));
    struct stat opened {};
    struct stat named {};
    REQUIRE(::fstat(file.get(), &opened) == 0);
    REQUIRE(::stat((moved + "/record").c_str(), &named) == 0);
    CHECK_EQ(opened.st_dev, named.st_dev);
    CHECK_EQ(opened.st_ino, named.st_ino);
}

TEST(anIOSDurableReplacementKeepsCompleteProtectionAndExactBytes)
{
    Test::TempDir directory;
    REQUIRE(directory.valid());
    const auto path = directory.path() + "/record";
    REQUIRE(PAL::storageWriteDurable(path.c_str(), content) == PAL::DurableFileResult::Durable);
    CHECK(hasCompleteProtection(path));
    auto read = PAL::storageReadBounded(path.c_str(), content.size());
    REQUIRE(read);
    CHECK(std::ranges::equal(std::as_bytes(read->view()), content));
    REQUIRE(PAL::storageWriteDurable(path.c_str(), {}) == PAL::DurableFileResult::Durable);
    CHECK(hasCompleteProtection(path));
    read = PAL::storageReadBounded(path.c_str(), 0);
    REQUIRE(read);
    CHECK_EQ(read->size, 0u);
}

UBIQUITTY_TEST_MAIN()
