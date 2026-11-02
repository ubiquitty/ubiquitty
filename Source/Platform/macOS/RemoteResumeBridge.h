// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// A macOS remote window's protected resume owner: the sealed resume record of
// one window identity, restored before any I/O and handed to the window's
// session (Docs/sync.md §6.9). Core owns the record and its rules; the Swift
// side owns the window identity and the protected descriptor that names the
// peer the record belongs to. The store and sealing are the Apple ones the
// phone uses (SealedResumeRecordStore with the keychain-backed sealer).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// NOLINTBEGIN(modernize-use-using)
typedef struct UbiquittyMacResumeOwner UbiquittyMacResumeOwner;

/// The protected descriptor's scope, borrowed only during the call. A zero
/// host names a window that has not yet been welcomed by any host.
typedef struct UbiquittyMacResumeIdentity {
    uint64_t clientLow;
    uint64_t clientHigh;
    uint64_t hostLow;
    uint64_t hostHigh;
    const uint8_t* principalDigest;
    const uint8_t* certificatePin;
    size_t digestLength;
    size_t pinLength;
} UbiquittyMacResumeIdentity;

/// Synchronous main-thread callbacks; they must not mutate or destroy the
/// session. The context is owned by the owner only when creation succeeds.
typedef struct UbiquittyMacResumeHooks {
    void* context;
    /// Records the authenticated peer a Welcome bound; false refuses storage.
    bool (*bind)(void* context, uint64_t hostLow, uint64_t hostHigh, const char* principal, size_t principalLength, const uint8_t* pin, size_t pinLength);
    /// Releases the context once Core no longer holds the store.
    void (*release)(void* context);
} UbiquittyMacResumeHooks;

/// Prepares the owner and restores its record before any network I/O.
///
/// - Parameters:
///   - path: The private absolute record path, never one a peer named.
///   - identity: The descriptor's window identity and peer scope.
///   - hooks: Synchronous callbacks, owned only on success.
/// - Returns: The prepared owner, or null on refusal.
UbiquittyMacResumeOwner* ubiquittyMacResumeCreate(const char* path, UbiquittyMacResumeIdentity identity, UbiquittyMacResumeHooks hooks);

/// Releases the unused owner, or the handle left after the session took it.
///
/// - Parameter owner: The handle; null is harmless.
void ubiquittyMacResumeDestroy(UbiquittyMacResumeOwner* owner);

/// Exposes the unique Core owner for `RuntimeDrive.prepareRemoteResume`.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The borrowed unique-owner address, or zero for null.
uintptr_t ubiquittyMacResumeCoreAddress(UbiquittyMacResumeOwner* owner);

/// The low half of the first restored picture's pane.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The low half; both halves are zero without a picture.
uint64_t ubiquittyMacResumePreviewLow(const UbiquittyMacResumeOwner* owner);

/// The high half of the first restored picture's pane.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The high half; both halves are zero without a picture.
uint64_t ubiquittyMacResumePreviewHigh(const UbiquittyMacResumeOwner* owner);

/// Retires the record of a scope, its key and its file, as a window the
/// person closed leaves nothing to resume.
///
/// - Parameters:
///   - path: The private absolute record path.
///   - identity: The scope to retire.
/// - Returns: Whether the key is confirmed gone, or nothing was ever bound.
bool ubiquittyMacResumeRetire(const char* path, UbiquittyMacResumeIdentity identity);
// NOLINTEND(modernize-use-using)

#ifdef __cplusplus
}
#endif
