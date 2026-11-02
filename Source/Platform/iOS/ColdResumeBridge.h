// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// NOLINTBEGIN(modernize-use-using)
typedef struct UbiquittyIOSResumeOwner UbiquittyIOSResumeOwner;

/// Borrowed only during creation; the protected descriptor supplies these bytes.
typedef struct UbiquittyIOSResumeIdentity {
    uint64_t clientLow;
    uint64_t clientHigh;
    uint64_t hostLow;
    uint64_t hostHigh;
    const uint8_t* principalDigest;
    const uint8_t* certificatePin;
    size_t digestLength;
    size_t pinLength;
    bool shouldPersistHistory;
} UbiquittyIOSResumeIdentity;

/// Synchronous main-thread callbacks. They must not mutate or destroy the
/// attachment. Context ownership transfers only when creation succeeds.
typedef struct UbiquittyIOSResumeHooks {
    void* context;
    bool (*mayUse)(void* context);
    bool (*bind)(void* context, uint64_t hostLow, uint64_t hostHigh, const char* principal, size_t principalLength, const uint8_t* pin, size_t pinLength);
    void (*retirementRefused)(void* context);
    void (*release)(void* context);
} UbiquittyIOSResumeHooks;

/// Owns the protected store and restores its bounded pictures before any I/O.
///
/// The absolute path is application-owned, never supplied by a peer.
///
/// - Parameters:
///   - path: The private absolute record path.
///   - identity: The protected descriptor's exact scope and transport pin.
///   - hooks: Synchronous policy callbacks, owned only on success.
/// - Returns: The prepared owner, or null on refusal.
UbiquittyIOSResumeOwner* ubiquittyIOSResumeCreate(const char* path, UbiquittyIOSResumeIdentity identity, UbiquittyIOSResumeHooks hooks);
/// Releases the unused prepared owner, or the extra handle after Core took it.
///
/// - Parameter owner: The handle to release; null is harmless.
void ubiquittyIOSResumeDestroy(UbiquittyIOSResumeOwner* owner);
/// Exposes the unique Core owner for synchronous RuntimeDrive preparation.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The borrowed unique-owner address, or zero for null.
uintptr_t ubiquittyIOSResumeCoreAddress(UbiquittyIOSResumeOwner* owner);
/// Identifies the first authenticated cached picture's low half.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The low identity half; both halves are zero without a picture.
uint64_t ubiquittyIOSResumePreviewLow(const UbiquittyIOSResumeOwner* owner);
/// Identifies the first authenticated cached picture's high half.
///
/// - Parameter owner: The prepared handle.
/// - Returns: The high identity half; both halves are zero without a picture.
uint64_t ubiquittyIOSResumePreviewHigh(const UbiquittyIOSResumeOwner* owner);
/// Retires the exact protected scope after descriptor denial committed.
///
/// - Parameters:
///   - path: The private absolute record path.
///   - identity: The denied descriptor's exact protected scope.
/// - Returns: Whether durable key retirement succeeded.
bool ubiquittyIOSResumeRetire(const char* path, UbiquittyIOSResumeIdentity identity);
/// Confirms private directory ownership and strict durability of both it and
/// its existing parent. Protection-class verification remains the Apple caller's.
///
/// - Parameter path: The private absolute directory path.
/// - Returns: Whether ownership checks and both durability barriers succeeded.
bool ubiquittyIOSResumeDirectoryDurable(const char* path);
#if defined(UBIQUITTY_IOS_UI_TESTS)
/// Writes a task-owned picture through the production binding/sealing owner.
///
/// No host, carrier, or user credential is contacted by this fixture.
///
/// A refusal names the step that refused, so a lane that fails here says
/// whether the binding, the fixture picture, or the protected write declined.
///
/// - Parameter owner: The unused fixture handle.
/// - Returns: Null when the real protected store committed the picture;
///   otherwise a static description of the refusing step.
const char* ubiquittyIOSResumePopulateForTest(UbiquittyIOSResumeOwner* owner);
/// Checks the independently materialized fixture before any observer or dial.
///
/// - Parameter owner: The replacement fixture handle.
/// - Returns: Whether the protected secret and copied picture match.
bool ubiquittyIOSResumeRestoredForTest(UbiquittyIOSResumeOwner* owner);
#endif
// NOLINTEND(modernize-use-using)

#ifdef __cplusplus
}
#endif
