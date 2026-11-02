// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// ⚠️  No new code in this file. Write Swift, in the Swift arm.
//
// Objective-C++ on the macOS frontend is being retired: the Swift arm under
// Source/Platform/macOS/App is where logic lives, and it reaches Core
// directly through cxx-interop. Add nothing here. Do not grow an @objc seam to
// reach Swift from here either — existing seams shrink toward thin accessors
// and never grow. Migrate the surrounding code instead, by the recipes in
// Docs/swift-cxx-interop.md.

#include "Core/Terminal.h"
#include "PAL/TerminalClients.h"
#include "Platform/POSIX/GatedFileRead.h"

#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <list>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <vector>

// Kitty graphics FILE TRANSPORT (t=f regular / t=t temp): reads raw pixel bytes from
// a file the client named, so a framebuffer-video stream avoids base64 through
// the PTY. The path is attacker-controlled, so every opened file must satisfy
// these checks:
//   - open O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC (no final-symlink swap; a FIFO can't hang the
//     async decode queue);
//   - fstat the descriptor, require S_ISREG (TOCTOU-safe; subsumes FIFO/device/symlink-to-special);
//   - RE-GATE the OPENED descriptor's own canonical path (F_GETPATH) against the same
//     CapabilityPolicy the Core pre-checked (Graphics.cpp), at the current origin —
//     race-free because the gated object is the descriptor that is read; FAIL-CLOSED if no policy;
//   - bounded read to maxLength (never trust st_size — attacker can grow the file);
//   - t=t unlink only inode-verified inside a temp dir, via unlinkat(directory descriptor).
//     That verified unlink is DEFERRED OFF this parse/ingest thread (DeferredUnlinkService
//     below): the ~72ms open+fstatat+unlinkat cost per framebuffer-video frame ran
//     synchronously on the ingest thread, so it runs on a process-wide serial
//     queue with BYTE-IDENTICAL verification (containment + O_DIRECTORY|O_NOFOLLOW parent
//     descriptor + fstatat dev/ino/S_ISREG + unlinkat). It is not weakened — only moved.
// The GUI installs a Local-Allow FileReadAccess policy (Local origin = the user's own
// process rendering a file it wrote as an image, no read-back channel; Remote stays strict).

namespace UBFileReadDetail {

// The value-only record a deferred unlink carries: everything the verified unlink needs
// is captured before readFile returns (the descriptor's canonical path + its fstat'd
// device/inode), so the block never touches the (possibly destroyed) client or Terminal.
//
// The shared identity type, not a second one with the same fields: it is filled by the
// same read that gates the file, and a separate record here would be a second place for
// the parent/base split to be got wrong.
using PendingUnlinkRecord = Ubiquitty::POSIX::GatedFileIdentity;

// PROCESS-WIDE service that runs the kitty t=t VERIFIED UNLINK off the parse/ingest
// thread. There is exactly one instance (a leaked singleton, `shared()`), shared across
// every per-Terminal UBFileReadClient — the queue, the pending maps, and the directory-
// descriptor cache are all process-wide, not per-instance. All the security-critical
// verification (temp-dir containment, O_DIRECTORY|O_NOFOLLOW parent descriptor, fstatat
// dev/ino/S_ISREG match, unlinkat) is single-sourced here and reused by both the deferred
// path and the synchronous accumulation-bound backpressure path.
class DeferredUnlinkService {
public:
    // Leaked on purpose: the service is process-wide and must outlive every client, and
    // never running its destructor keeps the dispatch queue's ownership identical in ARC
    // (.mm) and non-ARC (.cpp test) translation units. One instance across all TUs
    // because this inline function's function-local static has a single definition.
    static DeferredUnlinkService &shared()
    {
        static DeferredUnlinkService *service = new DeferredUnlinkService();
        return *service;
    }

    // Enqueue a verified unlink to run on the serial queue. Called on the ingest
    // thread from readFile's didSucceed path; returns without doing any file syscall
    // EXCEPT under the accumulation bound (hazard #3), where the oldest pending unlink is
    // run synchronously here as natural backpressure.
    void enqueue(PendingUnlinkRecord &&record)
    {
        // Hazard #3 (accumulation bound): never let the pending set grow past the cap. On
        // overflow, run the OLDEST live entry SYNCHRONOUSLY on this (ingest) thread — that
        // throttles the caller to the drain rate instead of growing unbounded. The oldest
        // is the smallest generation; a scan over <= cap entries is cheap and only happens
        // at the cap, so no separate ordering structure is needed (and none can leak).
        for (;;) {
            PendingUnlinkRecord evicted;
            bool haveEvicted = false;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                if (m_pendingByGeneration.size() < maxPendingUnlinkCount)
                    break;
                auto oldest = m_pendingByGeneration.end();
                for (auto candidate = m_pendingByGeneration.begin(); candidate != m_pendingByGeneration.end(); ++candidate) {
                    if (oldest == m_pendingByGeneration.end() || candidate->first < oldest->first)
                        oldest = candidate;
                }
                if (oldest != m_pendingByGeneration.end()) {
                    const uint64_t oldestGeneration = oldest->first;
                    evicted = std::move(oldest->second);
                    auto pathIterator = m_generationByPath.find(evicted.canonicalPath);
                    if (pathIterator != m_generationByPath.end() && pathIterator->second == oldestGeneration)
                        m_generationByPath.erase(pathIterator);
                    m_pendingByGeneration.erase(oldest);
                    haveEvicted = true;
                }
            }
            if (!haveEvicted)
                break;
            verifiedUnlinkSynchronous(evicted); // ingest thread, no lock held during syscalls
        }

        uint64_t generation;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            generation = ++m_generationCounter;
            // Supersede any still-live pending unlink for the same canonical path so the
            // older generation's block can never run (defence in depth — cancelPending at
            // the top of readFile already handles the common same-name-reuse ordering).
            auto existing = m_generationByPath.find(record.canonicalPath);
            if (existing != m_generationByPath.end()) {
                m_pendingByGeneration.erase(existing->second);
                existing->second = generation;
            } else {
                m_generationByPath.emplace(record.canonicalPath, generation);
            }
            m_pendingByGeneration.emplace(generation, std::move(record));
        }
        // The block captures only scalars — the immortal singleton `this` and the
        // generation — so it is trivially copyable and never references a client that may
        // already be gone (hazard #4). It looks its record up by generation under the lock.
        dispatch_async(m_serialQueue, ^{
            this->runDeferredUnlinkOnQueue(generation);
        });
    }

    // Hazard #1 (same-name reuse — a security constraint): a client that reuses one fixed
    // path with O_TRUNC would otherwise let frame N's deferred unlink delete frame N+1's
    // freshly-written, still-unread bytes — and dev/ino cannot protect because it is the
    // same inode. Called at the top of readFile (before the read) with the canonical path
    // about to be read: it removes that path's live pending generation from both maps, so
    // the corresponding dispatched block, when it runs, finds no entry and returns without
    // unlinking.
    //
    // Race-safety against a block that is already in-flight: cancelPending and the block's
    // claim both mutate the maps under the same m_mutex, so they are totally ordered. If
    // the cancel's critical section completes before the block's, the block's find() misses
    // and it does not unlink — the cancel is honoured. If the block's critical section runs
    // first, it has already atomically CLAIMED (erased) its generation under the lock, so a
    // later cancel finds nothing pending; there is no interleaving in which the
    // cancel observes success while the block still unlinks. A block that claimed just
    // before the cancel ran did so before readFile even reached this top-of-function cancel
    // point — the physical delete had already committed, which is not a lost cancel.
    void cancelPending(const char *canonicalPath)
    {
        if (!canonicalPath || !canonicalPath[0])
            return;
        std::lock_guard<std::mutex> lock(m_mutex);
        auto pathIterator = m_generationByPath.find(canonicalPath);
        if (pathIterator == m_generationByPath.end())
            return;
        m_pendingByGeneration.erase(pathIterator->second);
        m_generationByPath.erase(pathIterator);
    }

    // Hazard #4 (teardown): the controller destroys UBFileReadClient before its Terminal.
    // Blocks capture values only, so an outliving service is already safe — but drain every
    // remaining pending unlink now and close the cached directory descriptors so nothing is
    // orphaned. Runs the drain ON the serial queue (dispatch_sync) so it is serialised with
    // any in-flight block and may reuse the queue-confined descriptor cache. Never invoked
    // from a serial-queue block (blocks hold no client), so the dispatch_sync cannot
    // self-deadlock.
    void drainAll()
    {
        dispatch_sync(m_serialQueue, ^{
            for (;;) {
                PendingUnlinkRecord record;
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    if (m_pendingByGeneration.empty())
                        break;
                    auto it = m_pendingByGeneration.begin();
                    record = std::move(it->second);
                    auto pathIterator = m_generationByPath.find(record.canonicalPath);
                    if (pathIterator != m_generationByPath.end() && pathIterator->second == it->first)
                        m_generationByPath.erase(pathIterator);
                    m_pendingByGeneration.erase(it);
                }
                executeVerifiedUnlinkCached(record);
            }
            this->closeAllDirectoryDescriptors();
        });
    }

    // Build the {canonicalPath, parentDirectoryPath, baseName, device, inode} record from
    // the descriptor's canonical path. Returns false (⇒ no unlink is scheduled) for a path
    // with no usable parent/base — byte-identical to the original strrchr guards (no parent,
    // root, or trailing slash). The temp-dir CONTAINMENT check is not done
    // here: it stays in the deferred/synchronous core so its cost is off the ingest thread.
    static bool buildRecord(const char *canonicalPath, dev_t device, ino_t inode, PendingUnlinkRecord &outputBuffer)
    {
        return Ubiquitty::POSIX::buildFileIdentity(canonicalPath, device, inode, outputBuffer);
    }

private:
    DeferredUnlinkService()
    {
        m_serialQueue = dispatch_queue_create("org.ubiquitty.kitty.deferred-unlink",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }

    // Serial-queue side of a deferred unlink. Phase 1 (under the lock): claim this
    // generation — if it is gone (cancelPending / superseded / already run) do nothing.
    // Phase 2 (no lock): the verified unlink syscalls, which must not hold m_mutex or a
    // concurrent cancelPending on the ingest thread would stall for the whole ~50ms delete.
    void runDeferredUnlinkOnQueue(uint64_t generation)
    {
        PendingUnlinkRecord record;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            auto it = m_pendingByGeneration.find(generation);
            if (it == m_pendingByGeneration.end())
                return; // cancelled or superseded — hazard #1: do not unlink
            record = std::move(it->second);
            auto pathIterator = m_generationByPath.find(record.canonicalPath);
            if (pathIterator != m_generationByPath.end() && pathIterator->second == generation)
                m_generationByPath.erase(pathIterator);
            m_pendingByGeneration.erase(it);
        }
        executeVerifiedUnlinkCached(record);
    }

    // Temp-dir containment: the descriptor's realpath must sit inside a process temp dir
    // ($TMPDIR / _CS_DARWIN_USER_TEMP_DIR / /tmp), never a user path, and carry the kitty
    // t=t marker. readGatedFile already refuses to read such a file; this is the backstop.
    static bool pathInTempDir(const char *canonical)
    {
        return canonical && Ubiquitty::POSIX::pathNamesTemporaryTransportFile(canonical);
    }

    // The SINGLE-SOURCE verified-unlink core: given an OPEN parent-directory descriptor
    // (O_DIRECTORY|O_NOFOLLOW, so a symlink swapped in between read and unlink cannot
    // redirect the delete), fstatat the base name and unlink it only when st_dev/st_ino
    // still match the descriptor that was read and it is a regular file. Both the deferred
    // (cached-descriptor) path and the synchronous (own-descriptor) path call this, so the
    // verification exists in exactly one place.
    //
    // Hazard #2 (inode-reuse ABA): deferring stretches the dev/ino match window from
    // "immediately after read" to "queue latency later". Negligible on APFS, whose 64-bit
    // inode numbers are not recycled within a session — no code needed.
    static void verifyAndUnlinkAt(int directoryDescriptor, const char *baseName, dev_t device, ino_t inode)
    {
        Ubiquitty::POSIX::verifyAndUnlinkAt(directoryDescriptor, baseName, device, inode);
    }

    // Deferred/teardown path: temp-dir containment, then the verified unlink through the
    // process-wide cached parent-directory descriptor. Serial-queue-CONFINED: the
    // descriptor cache is only ever touched from runDeferredUnlinkOnQueue and from drainAll
    // (both run on m_serialQueue), so it needs no lock.
    void executeVerifiedUnlinkCached(const PendingUnlinkRecord &record)
    {
        if (!pathInTempDir(record.canonicalPath.c_str()))
            return;
        const int directoryDescriptor = directoryDescriptorFor(record.parentDirectoryPath);
        if (directoryDescriptor < 0)
            return;
        verifyAndUnlinkAt(directoryDescriptor, record.baseName.c_str(), record.device, record.inode);
    }

    // Synchronous path (accumulation-bound backpressure): temp-dir containment, then the
    // verified unlink through a FRESH parent-directory descriptor it opens and closes
    // itself — it runs on the ingest thread and so must not touch the queue-confined cache.
    // Shares pathInTempDir + verifyAndUnlinkAt with the deferred path (same verification).
    static void verifiedUnlinkSynchronous(const PendingUnlinkRecord &record)
    {
        if (!pathInTempDir(record.canonicalPath.c_str()))
            return;
        const int directoryDescriptor = open(record.parentDirectoryPath.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directoryDescriptor < 0)
            return;
        verifyAndUnlinkAt(directoryDescriptor, record.baseName.c_str(), record.device, record.inode);
        close(directoryDescriptor);
    }

    // Cache one long-lived directory descriptor per parent-directory path (a framebuffer-
    // video stream lands every frame in one $TMPDIR), so per frame the deferred block only
    // fstatat/unlinkat relative to the cached descriptor. Serial-queue-confined (see
    // executeVerifiedUnlinkCached): no lock. A stale cached descriptor (its directory
    // unlinked/remounted) fails fstatat ⇒ no unlink ⇒ fail-closed.
    int directoryDescriptorFor(const std::string &parentDirectoryPath)
    {
        auto it = m_directoryDescriptorByParentPath.find(parentDirectoryPath);
        if (it != m_directoryDescriptorByParentPath.end()) {
            // Touch: move this key to the front of the recency order so a hot directory stays
            // most-recently-used and is never the eviction victim below.
            m_directoryDescriptorRecencyOrder.splice(m_directoryDescriptorRecencyOrder.begin(), m_directoryDescriptorRecencyOrder, it->second.second);
            return it->second.first;
        }
        const int directoryDescriptor = open(parentDirectoryPath.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directoryDescriptor < 0)
            return -1;
        // BOUND the cache: the parent path derives from an attacker-controlled temp path, so an
        // UNBOUNDED cache would accumulate one open descriptor per distinct temp subdirectory — an
        // fd-exhaustion DoS the synchronous open+close baseline never had. Evict the LEAST-recently-
        // used entry (never recency-blind): a framebuffer-video stream lands every frame in one
        // $TMPDIR, so its single hot descriptor stays most-recently-used and is never evicted — a
        // recency-blind evict could drop the hot dir and reintroduce a per-frame open() (a crown
        // regression). Only a pathological/hostile spread of distinct parents evicts, forcing a
        // cheap off-thread re-open later. Serial-queue-confined: no lock.
        if (m_directoryDescriptorByParentPath.size() >= maxCachedDirectoryDescriptors) {
            auto victim = m_directoryDescriptorByParentPath.find(m_directoryDescriptorRecencyOrder.back());
            if (victim != m_directoryDescriptorByParentPath.end()) {
                close(victim->second.first);
                m_directoryDescriptorByParentPath.erase(victim);
            }
            m_directoryDescriptorRecencyOrder.pop_back();
        }
        m_directoryDescriptorRecencyOrder.push_front(parentDirectoryPath);
        m_directoryDescriptorByParentPath.emplace(parentDirectoryPath, std::make_pair(directoryDescriptor, m_directoryDescriptorRecencyOrder.begin()));
        return directoryDescriptor;
    }

    // Serial-queue-confined: close + drop every cached directory descriptor (teardown).
    void closeAllDirectoryDescriptors()
    {
        for (auto &entry : m_directoryDescriptorByParentPath)
            close(entry.second.first);
        m_directoryDescriptorByParentPath.clear();
        m_directoryDescriptorRecencyOrder.clear();
    }

    static constexpr size_t maxPendingUnlinkCount = 64;
    static constexpr size_t maxCachedDirectoryDescriptors = 8;

    dispatch_queue_t m_serialQueue { nullptr };
    std::mutex m_mutex;
    uint64_t m_generationCounter { 0 }; // guarded by m_mutex
    std::unordered_map<uint64_t, PendingUnlinkRecord> m_pendingByGeneration; // guarded by m_mutex
    std::unordered_map<std::string, uint64_t> m_generationByPath; // guarded by m_mutex
    // Bounded, hot-preserving LRU cache of open parent-directory descriptors. The recency order
    // (front = most-recently-used) and the map value's iterator into it are both serial-queue-
    // confined (touched only from runDeferredUnlinkOnQueue + drainAll, both on m_serialQueue): no lock.
    std::list<std::string> m_directoryDescriptorRecencyOrder; // serial-queue-confined (no lock)
    std::unordered_map<std::string, std::pair<int, std::list<std::string>::iterator>> m_directoryDescriptorByParentPath; // serial-queue-confined (no lock)
};

} // namespace UBFileReadDetail

class UBFileReadClient : public Ubiquitty::FileReadClient {
public:
    explicit UBFileReadClient(Ubiquitty::Terminal *term)
        : m_term(term)
    {
    }

    // Hazard #4 (teardown): the controller destroys this before the Terminal. The deferred
    // unlinks captured VALUES only, so the process-wide service outliving this client is
    // safe; drain the remaining ones + close cached directory descriptors so nothing is
    // orphaned when the owning Terminal goes away.
    ~UBFileReadClient() override
    {
        UBFileReadDetail::DeferredUnlinkService::shared().drainAll();
    }

    // unlinkAfter matches the Core FileReadClient::readFile(bool) seam (t=t deletes after read).
    [[nodiscard]] int readFile(const char *path, bool unlinkAfter, unsigned char *outputBuffer, int maxLength) override // bool-ok: seam-defined
    {
        if (!path || !outputBuffer || maxLength <= 0 || !m_term)
            return -1;
        // The open, the S_ISREG check, the descriptor-path gate and the bounded
        // read are Ubiquitty::POSIX::readGatedFile's, shared with the GTK
        // frontend so the two arms cannot answer them differently. What stays
        // here is the scheduling around it, which is this arm's alone.
        Ubiquitty::POSIX::GatedFileIdentity identity;
        const int result = Ubiquitty::POSIX::readGatedFile(*m_term, path,
            std::span<unsigned char>(outputBuffer, static_cast<std::size_t>(maxLength)),
            unlinkAfter ? Ubiquitty::POSIX::GatedFileDisposition::DeleteAfterReading : Ubiquitty::POSIX::GatedFileDisposition::Keep, &identity,
            // Hazard #1 (same-name reuse): cancel any pending deferred unlink for this
            // canonical path before we read it. Once cancelled, no prior frame's deferred
            // unlink can delete the bytes this read returns (dev/ino can't protect — an
            // O_TRUNC-reused fixed name keeps the same inode). The one residual for a
            // fixed-name O_TRUNC client is a block that fires in the gap between the client's
            // external write and this open: it deletes the temp file (always dev/ino- and
            // temp-dir-verified, so never an arbitrary delete) and this open then misses ⇒
            // that one frame is dropped, never read stale or partial. dosbox-x is immune
            // (fresh mkstemp name/inode per frame); a fixed-name client degrades to an
            // occasional dropped frame, not corruption.
            //
            // Passed as the before-read hook rather than done before the call because it
            // needs the canonical path, which only the opened descriptor can give.
            [](void *, const char *canonicalPath) {
                UBFileReadDetail::DeferredUnlinkService::shared().cancelPending(canonicalPath);
            });
        if (result >= 0 && unlinkAfter && identity.isValid()) {
            // Defer the inode-verified temp unlink OFF this parse/ingest thread:
            // everything it needs (canonical path, parent dir, base, dev, ino) is
            // in hand now, so enqueue a value-only record and return without the
            // ~72ms open+fstatat+unlinkat cost. The verified-unlink core runs later
            // on the process-wide serial queue (or synchronously only under the
            // accumulation-bound backpressure) — same verification, just later.
            UBFileReadDetail::DeferredUnlinkService::shared().enqueue(UBFileReadDetail::PendingUnlinkRecord { identity });
        }
        return result;
    }

    [[nodiscard]] bool supportsSharedMemoryTransport() const override { return true; }

    // Kitty t=s: read a POSIX shared-memory object. macOS kernel facts this
    // implementation is built on (both probed empirically on Darwin 25):
    //   - read(2)/pread(2) on an shm descriptor fail with ENXIO/ESPIPE — mmap is
    //     the only read path;
    //   - ftruncate on an shm object is one-shot (a second resize fails EINVAL),
    //     so once fstat observes a size the object can never shrink — the shrink-mid-read
    //     SIGBUS attack against a mapped read is structurally
    //     impossible here. A Linux implementation must not copy this assumption:
    //     tmpfs-backed shm can shrink, so it needs its own mitigation.
    // Hardening mirrors readFile: name validated (defense in depth behind the
    // Core-side check), the same capability policy re-gated at the current
    // origin (fail-closed without a policy), the copy bounded by maxLength, and
    // the object unlinked only after a successful read (flat-namespace
    // shm_unlink — cheap, no directory descriptors, no deferral needed).
    [[nodiscard]] int readSharedMemory(const char *name, bool unlinkAfter, unsigned char *outputBuffer, int maxLength) override // bool-ok: seam-defined
    {
        if (!m_term || !name || !outputBuffer || maxLength <= 0)
            return -1;
        // Name validation, the gate, the bound and the unlink are
        // Ubiquitty::POSIX::readGatedSharedMemory's, shared with the GTK
        // frontend. So is the choice of read primitive, which differs by
        // platform for reasons measured on each: this arm maps because read(2)
        // fails on an shm descriptor here and mapping is safe because ftruncate
        // is one-shot, and the other reads because there it is the mapping that
        // is unsafe.
        return Ubiquitty::POSIX::readGatedSharedMemory(*m_term, name,
            std::span<unsigned char>(outputBuffer, static_cast<std::size_t>(maxLength)),
            unlinkAfter ? Ubiquitty::POSIX::SharedMemoryDisposition::UnlinkAfterReading
                        : Ubiquitty::POSIX::SharedMemoryDisposition::Keep);
    }

private:
    // b-prime: re-gate the descriptor's canonical path against the same policy at the
    // CURRENT origin. Fail-closed when no policy is installed — without one the Core
    // pre-gate at Graphics.cpp answers PAL's Local Allow, so this is the authoritative gate.
    bool fileReadAllowed(const char *canonical) const
    {
        Ubiquitty::Terminal *term = m_term;
        if (!term)
            return false;
        // effectGranted, not effectAllowed: an absent policy refuses here.
        return Ubiquitty::effectGranted(*term, Ubiquitty::Capability::FileReadAccess, canonical);
    }

    // Borrowed; readFile is only invoked from the owning Terminal's parser (Terminal
    // alive), and the controller destroys this before the Terminal, matching UBTerminalClient.
    Ubiquitty::Terminal *m_term;
};
