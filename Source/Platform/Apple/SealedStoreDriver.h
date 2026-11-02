// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "PAL/RestoreAuthorization.h"
#include "PAL/SealedStore.h"

// Implemented in the shared Apple Swift layer. No process-wide installation
// or implicit enablement: a restored window must choose its exact scope and
// explicitly own a store before any record can reach these entry points.
extern "C" {
/// Seals one bounded record through the protected Apple keychain.
///
/// - Returns: The exact ciphertext length, or -1 on any refusal.
std::ptrdiff_t ubiquittySealRecord(const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
/// Opens one envelope only after authenticating its exact scope.
///
/// - Returns: The exact plaintext length, or -1 without partial output.
std::ptrdiff_t ubiquittyOpenRecord(const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
/// Retires the exact record's protected key without a fallback keychain.
///
/// - Returns: Whether the keychain confirms that key is absent.
bool ubiquittyForgetRecordKey(const std::uint8_t*, std::size_t);
/// Reads protected restore authorization without creating an item.
///
/// - Returns: The PAL authorization state, or Unavailable on refusal.
std::uint8_t ubiquittyReadRestoreAuthorization(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
/// Persists deny intent or exact committed-plaintext authorization.
///
/// - Returns: Whether protected storage confirmed the complete change.
bool ubiquittyWriteRestoreAuthorization(const std::uint8_t*, std::size_t, std::uint8_t, const std::uint8_t*, std::size_t);
}

namespace Ubiquitty::Apple {

/// Creates the explicit Apple secure-storage driver. The platform may refuse
/// when its protected keychain is unavailable; no other key store is tried.
///
/// - Returns: A store whose operations use the protected Apple keychain.
[[nodiscard]] inline PAL::SealedStore sealedStore()
{
    return PAL::SealedStore({ .seal = ubiquittySealRecord, .open = ubiquittyOpenRecord, .forget = ubiquittyForgetRecordKey });
}

/// Creates the protected authorization driver, with no plaintext fallback.
///
/// - Returns: A synchronous owner using the device-local unlocked keychain.
[[nodiscard]] inline PAL::RestoreAuthorization restoreAuthorization()
{
    return PAL::RestoreAuthorization({ .read = ubiquittyReadRestoreAuthorization, .write = ubiquittyWriteRestoreAuthorization });
}

} // namespace Ubiquitty::Apple
