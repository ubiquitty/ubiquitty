// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Metal
import UbiquittyCore

extension MTLDevice {
    /// Storage for a texture the CPU writes and the GPU only reads.
    ///
    /// The atlas sheets, the colour and coverage sheets and the image store are
    /// all filled on the CPU and sampled on the GPU, and they all want the same
    /// answer to the same question.
    ///
    /// A platform conditional, for a compile-time fact. `.managed` is a
    /// separate CPU copy kept in step with a discrete GPU's own, and iOS has no
    /// discrete GPUs — the case does not exist there, and Metal marks it
    /// `@available(iOS, unavailable)`. So it cannot be NAMED in a translation
    /// unit compiled for iOS, even on a branch that platform would never take.
    /// That is a compile-time fact about the enumeration rather than a runtime
    /// difference this layer could decide, which is why the conditional cannot
    /// be replaced by asking the device.
    ///
    /// It is here, once, so no sheet carries one of its own.
    ///
    /// - Returns: The storage mode for a CPU-written, GPU-read texture.
    /// The largest 2D texture edge this device allows.
    ///
    /// Metal states it per GPU family rather than exposing a query, so the
    /// family test is written here and resolved through
    /// `Source/Platform/Apple/MetalTextureLimits.h`, the one header that holds
    /// the numbers.
    ///
    /// The atlas grid is clamped to this by Core, one derivation for every
    /// backend; what belongs here is only which family the device is in.
    package var maximumTexture2DDimension: Int {
        #if os(macOS)
        let isLargeTextureFamily = supportsFamily(.apple3) || supportsFamily(.mac2)
        #else
        // The Mac family names no iOS device, and iOS 27 deprecates it.
        let isLargeTextureFamily = supportsFamily(.apple3)
        #endif
        return Int(Ubiquitty.Apple.maximumTexture2DDimension(isLargeTextureFamily))
    }

    var cpuWrittenTextureStorageMode: MTLStorageMode {
        #if os(macOS)
        // Unified memory shares one allocation, so the managed copy is pure
        // cost where it exists at all.
        return hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }
}
