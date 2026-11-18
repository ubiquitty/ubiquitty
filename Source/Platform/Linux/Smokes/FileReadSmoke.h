// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-fileread — the kitty t=f reader is wired, gated, and hardened.
//
// The hardening itself is asserted portably by Tests/Platform/test_gated_file_read.cpp,
// which runs under ctest. It cannot run here: linking it needs Core's Terminal,
// and the container build leaves object files rather than an archive. So this
// asserts the part that is this frontend's — that the client is wired at all,
// that it obeys the pane's policy, and that the rules reach it through the
// shared implementation rather than being absent on this arm.
/// Checks the wired image-file reader and its capability policy.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFileRead()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-fileread: FAILED — no term\n");
        return 1;
    }
    // Through the production wiring, not its own. A smoke that wired the client
    // itself would pass with the real path removed, which is exactly the state
    // this exists to keep out.
    wirePaneClients(*activePane(), *term);
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    if (!term->fileReadClient) {
        g_printerr("smoke-fileread: FAILED — wirePaneClients left no file-read client\n");
        return 1;
    }

    int failures = 0;
    const std::string directory = std::string(g_get_tmp_dir());
    // Named with the kitty t=t marker, which the delete below needs.
    const std::string path = directory + "/ubq-smoke-fileread-tty-graphics-protocol";
    const std::string payload = "PIXELS";
    ::unlink(path.c_str());
    if (!g_file_set_contents(path.c_str(), payload.c_str(), static_cast<gssize>(payload.size()), nullptr)) {
        g_printerr("smoke-fileread: FAILED — could not write the fixture at %s\n", path.c_str());
        return 1;
    }

    std::array<unsigned char, 64> buffer {};
    const int count = term->fileReadClient->readFile(path.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
    g_print("  local origin, t=f: %d byte(s)\n", count);
    if (count != static_cast<int>(payload.size()) || std::memcmp(buffer.data(), payload.data(), payload.size()) != 0) {
        g_printerr("smoke-fileread: FAILED — the wired client did not return the file's bytes\n");
        ++failures;
    }

    // The pane's policy denies a Remote principal, and the reader asks it. A
    // client wired but ungated would read this exactly as it read the line above.
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
    const int denied = term->fileReadClient->readFile(path.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
    g_print("  remote origin:     %d\n", denied);
    if (denied >= 0) {
        g_printerr("smoke-fileread: FAILED — a Remote origin was served\n");
        ++failures;
    }
    term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;

    // A symlink at the name is refused rather than followed: this is the shared
    // O_NOFOLLOW open answering, and it is here to show the rules reached this
    // arm rather than to re-test them.
    const std::string link = path + "-link";
    ::unlink(link.c_str());
    if (::symlink(path.c_str(), link.c_str()) == 0) {
        const int throughLink = term->fileReadClient->readFile(link.c_str(), false, buffer.data(), static_cast<int>(buffer.size()));
        g_print("  through a symlink: %d\n", throughLink);
        if (throughLink >= 0) {
            g_printerr("smoke-fileread: FAILED — a symlinked name was followed\n");
            ++failures;
        }
        ::unlink(link.c_str());
    } else {
        g_printerr("smoke-fileread: FAILED — could not plant the symlink fixture\n");
        ++failures;
    }

    // t=t deletes what it read, and only inside a temporary directory with the
    // marker in its name. The fixture is both, so this is the deleting arm.
    const int consumed = term->fileReadClient->readFile(path.c_str(), true, buffer.data(), static_cast<int>(buffer.size()));
    const bool isStillPresent = ::access(path.c_str(), F_OK) == 0;
    g_print("  t=t: %d byte(s), file %s\n", consumed, isStillPresent ? "kept" : "removed");
    if (consumed != static_cast<int>(payload.size()) || isStillPresent) {
        g_printerr("smoke-fileread: FAILED — t=t did not read then remove its temp file\n");
        ++failures;
    }
    ::unlink(path.c_str());

    // t=s, the shared-memory transport. Declared supported here, so the dispatch
    // will use it; the read primitive differs from the macOS arm's on purpose,
    // because a Linux shm object can shrink under a mapped copy and take SIGBUS
    // while a Darwin one cannot.
    if (!term->fileReadClient->supportsSharedMemoryTransport()) {
        g_printerr("smoke-fileread: FAILED — the shared-memory transport reports itself unsupported\n");
        ++failures;
    }
    const char* shmName = "/ubq-smoke-shm";
    ::shm_unlink(shmName);
    const int shmDescriptor = ::shm_open(shmName, O_CREAT | O_RDWR, 0600);
    if (shmDescriptor < 0 || ::ftruncate(shmDescriptor, static_cast<off_t>(payload.size())) != 0) {
        g_printerr("smoke-fileread: FAILED — could not stage a shared-memory fixture\n");
        ++failures;
    } else {
        void* mapping = ::mmap(nullptr, payload.size(), PROT_READ | PROT_WRITE, MAP_SHARED, shmDescriptor, 0);
        if (mapping != MAP_FAILED) {
            std::memcpy(mapping, payload.data(), payload.size());
            ::munmap(mapping, payload.size());
        }
        ::close(shmDescriptor);

        // Sized to the payload, the way the sequence calls it: an oversized
        // buffer would return the object's rounded size on one platform and its
        // exact size on the other.
        std::array<unsigned char, 6> shmBuffer {};
        const int shmCount = term->fileReadClient->readSharedMemory(shmName, false, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        g_print("  t=s: %d byte(s)\n", shmCount);
        if (shmCount != static_cast<int>(payload.size()) || std::memcmp(shmBuffer.data(), payload.data(), payload.size()) != 0) {
            g_printerr("smoke-fileread: FAILED — the shared-memory read did not return the object's bytes\n");
            ++failures;
        }

        // A buffer SMALLER than the object, which is what exercises the bound.
        // Without this the fixture and the buffer are the same size and a copy
        // bounded by the object rather than by the caller reads identically —
        // the mutation that removes the bound survived here until this case
        // existed, and on the other arm it only failed by overflowing a heap
        // buffer, which is a crash rather than a verdict.
        std::array<unsigned char, 3> shortBuffer {};
        const int shortCount = term->fileReadClient->readSharedMemory(shmName, false, shortBuffer.data(),
            static_cast<int>(shortBuffer.size()));
        g_print("  t=s into a 3-byte buffer: %d\n", shortCount);
        if (shortCount != 3 || std::memcmp(shortBuffer.data(), payload.data(), 3) != 0) {
            g_printerr("smoke-fileread: FAILED — the shared-memory read was not bounded by the buffer\n");
            ++failures;
        }

        // The same gate as the file transport, on the name rather than a
        // descriptor path — an shm object has none.
        term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Remote;
        const int shmDenied = term->fileReadClient->readSharedMemory(shmName, false, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        g_print("  t=s remote origin: %d\n", shmDenied);
        if (shmDenied >= 0) {
            g_printerr("smoke-fileread: FAILED — a Remote origin was served over shared memory\n");
            ++failures;
        }
        term->currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;

        // The delete flag removes the name, so a second open finds nothing.
        const int shmConsumed = term->fileReadClient->readSharedMemory(shmName, true, shmBuffer.data(),
            static_cast<int>(shmBuffer.size()));
        const int reopened = ::shm_open(shmName, O_RDONLY, 0);
        if (reopened >= 0)
            ::close(reopened);
        g_print("  t=s with unlink: %d byte(s), object %s\n", shmConsumed, reopened >= 0 ? "kept" : "removed");
        if (shmConsumed != static_cast<int>(payload.size()) || reopened >= 0) {
            g_printerr("smoke-fileread: FAILED — the unlink flag did not remove the object\n");
            ++failures;
        }
    }
    ::shm_unlink(shmName);

    term->fileReadClient = nullptr; // detach before the Ubiquitty::Terminal is disposed
    term->capabilityPolicy = nullptr;
    if (failures) {
        g_printerr("smoke-fileread: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-fileread: PASS (t=f wired and gated, symlink refused, t=t and t=s each read then removed)\n");
    return 0;
}
