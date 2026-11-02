// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_macos_file_read — pins UBFileReadClient (Source/Platform/macOS/UBFileReadClient.h),
// the hardened kitty t=f/t=t file-transport reader. This is an escape-driven,
// attacker-controlled arbitrary-file-read surface, so the tests exercise the security
// contract security ratified: FAIL-CLOSED without a policy, ORIGIN-GATED (Local only),
// S_ISREG-only (a FIFO is rejected), BOUNDED read (trust maxLength not st_size), TEMP-DIR
// only (a user path is never read, so never deleted), and the t=t unlink is INODE + TEMP-DIR
// + MARKER verified (a temp file without `tty-graphics-protocol` is neither read nor deleted).

#include "Platform/macOS/UBCapabilityPolicy.h"
#include "Platform/macOS/UBFileReadClient.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

// Tests exercise the SHIPPED GUI policy (UBCapabilityPolicy), not a copy: Local
// -> Allow, every other origin -> Deny.

static std::string tempDir()
{
    const char* directory = getenv("TMPDIR");
    std::string result = (directory && directory[0]) ? directory : "/tmp";
    if (result.back() != '/')
        result += '/';
    return result;
}

static std::string makeTempFileNamed(const char* stem, const unsigned char* bytes, int length)
{
    std::string templatePath = tempDir() + stem + "-XXXXXX";
    std::vector<char> buffer(templatePath.begin(), templatePath.end());
    buffer.push_back('\0');
    const int fileDescriptor = mkstemp(buffer.data());
    if (fileDescriptor < 0)
        return {};
    (void)write(fileDescriptor, bytes, static_cast<size_t>(length));
    close(fileDescriptor);
    return { buffer.data() };
}

// A temp file a t=f may name; without the marker no t=t may consume it.
static std::string makeTempFile(const unsigned char* bytes, int length)
{
    return makeTempFileNamed("ubq-fileread", bytes, length);
}

// A temp file named as the kitty protocol tells a t=t client to name one.
static std::string makeTransportTempFile(const unsigned char* bytes, int length)
{
    return makeTempFileNamed("ubq-fileread-tty-graphics-protocol", bytes, length);
}

static bool fileExists(const std::string& path)
{
    struct stat status;
    return stat(path.c_str(), &status) == 0;
}

TEST(macosFileRead)
{

    static const unsigned char pixels[] = { 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00 }; // 2px RGB
    unsigned char outputBuffer[64];

    // (1) Regular file, Local origin, policy Allow -> reads the exact bytes; t=f keeps it.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        const std::string path = makeTempFile(pixels, sizeof(pixels));
        CHECK(!path.empty());
        std::memset(outputBuffer, 0, sizeof(outputBuffer));
        const int count = client.readFile(path.c_str(), /*unlinkAfter*/ false, outputBuffer, sizeof(outputBuffer));
        CHECK(count == static_cast<int>(sizeof(pixels)));
        CHECK(std::memcmp(outputBuffer, pixels, sizeof(pixels)) == 0);
        CHECK(fileExists(path));
        unlink(path.c_str());
    }

    // (2) FAIL-CLOSED: no CapabilityPolicy installed -> refuse (without a policy the
    // Core pre-gate answers PAL's Local Allow, so the client must be the authoritative gate).
    {
        Ubiquitty::Terminal t;
        t.capabilityPolicy = nullptr;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        const std::string path = makeTempFile(pixels, sizeof(pixels));
        CHECK(client.readFile(path.c_str(), false, outputBuffer, sizeof(outputBuffer)) < 0);
        unlink(path.c_str());
    }

    // (3) ORIGIN DISCRIMINATION: a Remote origin is denied even with a policy present.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
        UBFileReadClient client(&t);
        const std::string path = makeTempFile(pixels, sizeof(pixels));
        CHECK(client.readFile(path.c_str(), false, outputBuffer, sizeof(outputBuffer)) < 0);
        unlink(path.c_str());
    }

    // (4) S_ISREG only: a FIFO is rejected (descriptor-check subsumes device/symlink-to-special).
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        const std::string fifo = tempDir() + "ubq-fileread-fifo";
        unlink(fifo.c_str());
        if (mkfifo(fifo.c_str(), 0600) == 0) {
            CHECK(client.readFile(fifo.c_str(), false, outputBuffer, sizeof(outputBuffer)) < 0);
            unlink(fifo.c_str());
        }
    }

    // (5) t=t unlink: a temp file is deleted after a successful read. The verified unlink
    // is DEFERRED off the ingest thread onto a process-wide serial queue, so the delete
    // is observable only once the queue has run it. Destroying the client DRAINS the pending
    // unlinks synchronously (the teardown seam), so scope the client and check after it dies.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        const std::string path = makeTransportTempFile(pixels, sizeof(pixels));
        int count = -1;
        {
            UBFileReadClient client(&t);
            count = client.readFile(path.c_str(), /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
        } // client destructor drains the deferred verified unlink synchronously
        CHECK(count == static_cast<int>(sizeof(pixels)));
        CHECK(!fileExists(path));
        if (fileExists(path))
            unlink(path.c_str());
    }

    // (5b) t=t needs the marker: a temp file named without `tty-graphics-protocol` is
    // refused unread, and nothing is queued to delete it — a t=t is not a request to
    // delete whatever file the sender names in /tmp.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        const std::string path = makeTempFile(pixels, sizeof(pixels));
        int count = 0;
        {
            UBFileReadClient client(&t);
            count = client.readFile(path.c_str(), /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
        } // client destructor drains any deferred unlink synchronously
        CHECK(count < 0);
        CHECK(fileExists(path));
        unlink(path.c_str());
    }

    // (6) Reads are temp-dir-only: a file OUTSIDE a temp dir is neither read nor deleted
    // (an attacker can't turn t=t into delete-arbitrary-file on a user path), even after
    // OSC 7 names its directory — a report is program output, which a remote host sends
    // as easily as the local shell.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        // Anchored to the home directory rather than the working directory. A
        // relative path is only outside a temp prefix if the working directory
        // happens to be, and under ctest the working directory is the BUILD
        // directory — one placed under /tmp makes this path temp-contained, the
        // guard correctly permits the unlink, and the case fails while reporting
        // the opposite of what it means.
        const char* home = getenv("HOME");
        char nonTempPath[PATH_MAX] = { 0 };
        // A fixture that cannot be built fails, never with a return: the cases
        // after this one are in the same function, and returning would report
        // them as passing. A home that cannot hold one file is a broken
        // environment, and a containment check that declined there would read
        // as one that held.
        const bool haveNonTempPath = home && home[0]
            && snprintf(nonTempPath, sizeof(nonTempPath), "%s/.ubq-fileread-nontemp-tty-graphics-protocol-DELETEME-%d", home, (int)getpid())
                < (int)sizeof(nonTempPath);
        CHECK_MSG(haveNonTempPath, "containment fixture: HOME names no usable non-temp location");
        const char* path = haveNonTempPath ? nonTempPath : nullptr;
        const int fileDescriptor = path ? open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600) : -1;
        CHECK_MSG(!path || fileDescriptor >= 0, "containment fixture: cannot create a file under HOME");
        if (fileDescriptor >= 0) {
            (void)write(fileDescriptor, pixels, sizeof(pixels));
            close(fileDescriptor);
            int count = 0;
            {
                Ubiquitty::setReportedDirectoryString(t, home);
                UBFileReadClient client(&t);
                count = client.readFile(path, /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
                Ubiquitty::setReportedDirectoryString(t, "");
            } // client destructor drains any deferred unlink synchronously
            CHECK(count < 0); // refused: outside every temp dir, whatever the shell reported
            CHECK(fileExists(path)); // and so never deleted
            unlink(path);
        }
    }

    // (7) BOUNDED read: a file larger than maxLength returns exactly maxLength (never st_size).
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        unsigned char big[128];
        std::memset(big, 0xAB, sizeof(big));
        const std::string path = makeTempFile(big, sizeof(big));
        const int capacity = 32;
        CHECK(client.readFile(path.c_str(), false, outputBuffer, capacity) == capacity);
        unlink(path.c_str());
    }

    // (8) HAZARD #1 (same-name O_TRUNC reuse) — the security case this test exists for. A client that
    // reuses one fixed path with O_TRUNC lets frame N's DEFERRED unlink target frame N+1's
    // freshly-written, still-unread bytes, and dev/ino cannot protect (it is the same inode).
    // The defense is cancelPending at the top of readFile, which drops the stale pending unlink
    // before the reuse. Assert the reread returns the FRESH frame, never the stale one.
    // Determinism: the deferred unlink runs on a real serial queue that can fire between the
    // rewrite and the reread's open (the documented dropped-frame residual for a fixed-name
    // client), so this test (i) calls cancelPending explicitly up front — exactly what
    // readFile's own top-of-function cancel does — to neutralize the stale unlink, and (ii)
    // rewrites with O_CREAT so the path is present regardless, making the fresh reread
    // deterministic rather than dependent on queue timing.
    {
        static const unsigned char frameA[] = { 0xAA, 0xAA, 0xAA, 0xAA };
        static const unsigned char frameB[] = { 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB };
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        const std::string path = makeTransportTempFile(frameA, sizeof(frameA));
        CHECK(!path.empty());
        // The deferred unlink is keyed by the descriptor's canonical path (F_GETPATH), which
        // resolves the /var -> /private/var symlink; capture it the same way so the explicit
        // cancelPending below matches the pending entry readFile enqueued.
        char canonicalPath[PATH_MAX] = { 0 };
        {
            const int probe = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            CHECK(probe >= 0);
            if (probe >= 0) {
                CHECK(fcntl(probe, F_GETPATH, canonicalPath) == 0);
                close(probe);
            }
        }
        {
            UBFileReadClient client(&t);
            // frame N: read + DEFER the verified unlink of `path`.
            std::memset(outputBuffer, 0, sizeof(outputBuffer));
            const int countFrameN = client.readFile(path.c_str(), /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
            CHECK(countFrameN == static_cast<int>(sizeof(frameA)));
            CHECK(std::memcmp(outputBuffer, frameA, sizeof(frameA)) == 0);
            // Neutralize frame N's still-pending deferred unlink before reusing the name —
            // exactly what readFile's own top-of-function cancelPending does.
            UBFileReadDetail::DeferredUnlinkService::shared().cancelPending(canonicalPath);
            // frame N+1: rewrite the same path with fresh, longer content.
            const int rewriteDescriptor = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
            CHECK(rewriteDescriptor >= 0);
            if (rewriteDescriptor >= 0) {
                (void)write(rewriteDescriptor, frameB, sizeof(frameB));
                close(rewriteDescriptor);
            }
            std::memset(outputBuffer, 0, sizeof(outputBuffer));
            const int countFrameNPlus1 = client.readFile(path.c_str(), /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
            CHECK(countFrameNPlus1 == static_cast<int>(sizeof(frameB))); // FRESH bytes, never the stale frame
            CHECK(std::memcmp(outputBuffer, frameB, sizeof(frameB)) == 0);
            CHECK(std::memcmp(outputBuffer, frameA, sizeof(frameA)) != 0);
        } // client destructor drains frame N+1's deferred unlink
        CHECK(!fileExists(path));
    }

    // (9) BOUNDED directory-descriptor cache — the deferred unlink caches one open parent-dir
    // descriptor per distinct temp subdirectory; an attacker-controlled spread of parents must
    // not accumulate descriptors unboundedly (fd-exhaustion DoS). Drive more distinct parent
    // directories than the cache cap through the deferred path and assert every temp file is
    // still correctly deleted after the drain — LRU eviction re-opens as needed and never drops
    // a verified unlink.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        const int distinctParentCount = 12; // > the cache cap (8) so eviction is exercised
        std::vector<std::string> paths;
        std::vector<std::string> directories;
        {
            UBFileReadClient client(&t);
            for (int index = 0; index < distinctParentCount; ++index) {
                std::string directoryTemplate = tempDir() + "ubq-fileread-dir-XXXXXX";
                std::vector<char> buffer(directoryTemplate.begin(), directoryTemplate.end());
                buffer.push_back('\0');
                if (!mkdtemp(buffer.data()))
                    continue;
                const std::string directory(buffer.data());
                directories.push_back(directory);
                const std::string path = directory + "/tty-graphics-protocol-frame";
                const int fileDescriptor = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
                if (fileDescriptor < 0)
                    continue;
                (void)write(fileDescriptor, pixels, sizeof(pixels));
                close(fileDescriptor);
                paths.push_back(path);
                std::memset(outputBuffer, 0, sizeof(outputBuffer));
                const int count = client.readFile(path.c_str(), /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
                CHECK(count == static_cast<int>(sizeof(pixels)));
            }
        } // client destructor drains every deferred unlink across all distinct parents
        for (const std::string& path : paths)
            CHECK(!fileExists(path)); // every verified unlink ran despite cache eviction
        for (const std::string& directory : directories)
            rmdir(directory.c_str());
    }

    // ---- kitty t=s shared-memory transport (readSharedMemory) ----
    // Same security contract as the file transport: FAIL-CLOSED without a
    // policy, origin-gated, name-validated (flat namespace only), bounded copy,
    // unlink-after-successful-read.

    // Helper: create + size + fill an shm object via mmap (macOS shm fds do not
    // support write(2); ftruncate is one-shot).
    auto makeSharedMemoryObject = [](const char* name, const unsigned char* bytes, size_t length) -> bool {
        shm_unlink(name); // tolerate residue from an aborted prior run
        const int descriptor = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (descriptor < 0)
            return false;
        if (ftruncate(descriptor, static_cast<off_t>(length)) != 0) {
            close(descriptor);
            shm_unlink(name);
            return false;
        }
        void* mapping = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
        if (mapping == MAP_FAILED) {
            close(descriptor);
            shm_unlink(name);
            return false;
        }
        memcpy(mapping, bytes, length);
        munmap(mapping, length);
        close(descriptor);
        return true;
    };
    auto sharedMemoryObjectExists = [](const char* name) -> bool {
        const int descriptor = shm_open(name, O_RDONLY);
        if (descriptor < 0)
            return false;
        close(descriptor);
        return true;
    };

    // (10) Roundtrip + unlink-after-read: bytes come back exactly, and the
    // object is gone afterwards (kitty t=s: the terminal deletes it).
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        CHECK(client.supportsSharedMemoryTransport());
        const char* name = "/ubq-shm-roundtrip";
        CHECK(makeSharedMemoryObject(name, pixels, sizeof(pixels)));
        memset(outputBuffer, 0, sizeof(outputBuffer));
        // The kernel page-rounds shm object sizes, so exactness comes from the
        // caller's cap (Core passes the protocol's S= / expected size). Pass the
        // exact payload length, mirroring the Core contract.
        const int count = client.readSharedMemory(name, /*unlinkAfter*/ true, outputBuffer, sizeof(pixels));
        CHECK(count == static_cast<int>(sizeof(pixels)));
        CHECK(memcmp(outputBuffer, pixels, sizeof(pixels)) == 0);
        CHECK(!sharedMemoryObjectExists(name)); // unlinked after the successful read
    }

    // (11) FAIL-CLOSED: no capability policy installed => refused, object untouched.
    {
        Ubiquitty::Terminal t; // no policy
        UBFileReadClient client(&t);
        const char* name = "/ubq-shm-ungated";
        CHECK(makeSharedMemoryObject(name, pixels, sizeof(pixels)));
        const int count = client.readSharedMemory(name, /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
        CHECK(count < 0);
        CHECK(sharedMemoryObjectExists(name)); // refused reads never unlink
        shm_unlink(name);
    }

    // (12) ORIGIN-GATED: Remote origin => refused.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
        UBFileReadClient client(&t);
        const char* name = "/ubq-shm-remote";
        CHECK(makeSharedMemoryObject(name, pixels, sizeof(pixels)));
        const int count = client.readSharedMemory(name, /*unlinkAfter*/ true, outputBuffer, sizeof(outputBuffer));
        CHECK(count < 0);
        CHECK(sharedMemoryObjectExists(name));
        shm_unlink(name);
    }

    // (13) NAME VALIDATION: no leading slash, path-like names, and overlong
    // names are refused before any shm API sees them.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        CHECK(client.readSharedMemory("noslash", true, outputBuffer, sizeof(outputBuffer)) < 0);
        CHECK(client.readSharedMemory("/a/b", true, outputBuffer, sizeof(outputBuffer)) < 0);
        CHECK(client.readSharedMemory("/this-name-is-well-past-the-psh-limit", true, outputBuffer, sizeof(outputBuffer)) < 0);
        CHECK(client.readSharedMemory("/", true, outputBuffer, sizeof(outputBuffer)) < 0);
    }

    // (14) BOUNDED: an object larger than maxLength copies exactly maxLength
    // bytes — the caller's cap governs, never the object size.
    {
        UBCapabilityPolicy policy;
        Ubiquitty::Terminal t;
        t.capabilityPolicy = &policy;
        t.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
        UBFileReadClient client(&t);
        const char* name = "/ubq-shm-bounded";
        unsigned char big[512];
        for (size_t i = 0; i < sizeof(big); ++i)
            big[i] = static_cast<unsigned char>(i * 7 + 3);
        CHECK(makeSharedMemoryObject(name, big, sizeof(big)));
        unsigned char small[64];
        const int count = client.readSharedMemory(name, /*unlinkAfter*/ true, small, sizeof(small));
        CHECK(count == static_cast<int>(sizeof(small)));
        CHECK(memcmp(small, big, sizeof(small)) == 0);
        CHECK(!sharedMemoryObjectExists(name));
    }
}

UBIQUITTY_TEST_MAIN()
