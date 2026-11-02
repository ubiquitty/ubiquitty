// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PassGPUProbe.swift — per-pass GPU spans for the Swift renderer's frame.
//
// The profiler's gpuexec lane is one span across every pass of the frame, so
// a regression inside it names the frame and not the pass. This probe samples
// the GPU timestamp at each render pass's stage boundaries — Apple GPUs
// support stage-boundary sampling and not draw-boundary — and prints one line
// per frame with the grid pass, the drawable pass, and the gap between them
// on the GPU timeline. Diagnostic only: armed by UBIQUITTY_PASS_GPU=1, absent
// from the frame otherwise.

import Foundation
import Metal

/// A frame's sample buffer on its way into the command buffer's completion
/// handler.
///
/// Unchecked because the SDK marks `MTLCounter` and `MTLCounterSet`
/// `NS_SWIFT_SENDABLE` and not `MTLCounterSampleBuffer`. No two frames share a
/// buffer: ``PassGPUProbe/makeFrameSampleBuffer()`` mints one per frame and
/// ``PassGPUProbe/attach(to:buffer:slot:)`` overwrites the renderer's reused
/// grid pass descriptor every frame, the absent buffer included, so a frame
/// whose allocation failed samples into nothing rather than into the previous
/// frame's buffer. The handler resolves it after the command buffer completes,
/// which is Metal's happens-after edge over the GPU's writes.
private struct FrameSampleBufferBox: @unchecked Sendable {
    /// The one buffer this frame's passes sampled into.
    let buffer: MTLCounterSampleBuffer

    init(_ buffer: MTLCounterSampleBuffer) {
        self.buffer = buffer
    }
}

/// Samples GPU timestamps at the render passes' stage boundaries and prints
/// per-pass spans, one line per completed frame.
final class PassGPUProbe {
    /// The GPU-timestamp counter set the sample buffers draw from.
    private let counterSet: MTLCounterSet

    /// The device the correlation pair below was sampled on.
    private let device: MTLDevice

    /// CPU/GPU timestamp pair taken at init: the second pair, taken when a
    /// frame completes, turns GPU ticks into seconds by linear correlation.
    private let baseTimestamps: (cpu: MTLTimestamp, gpu: MTLTimestamp)

    /// Sample slots per frame: grid start, grid end, drawable start,
    /// drawable end.
    private static let samplesPerFrame = 4

    /// Creates a probe when the diagnostic is armed and the device can
    /// sample timestamps at stage boundaries; nil otherwise.
    ///
    /// - Parameter device: The device the renderer encodes on.
    init?(device: MTLDevice) {
        guard ProcessInfo.processInfo.environment["UBIQUITTY_PASS_GPU"] == "1" else {
            return nil
        }
        guard device.supportsCounterSampling(.atStageBoundary),
            let counterSet = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else {
            FileHandle.standardError.write(Data("passgpu: stage-boundary timestamp sampling unsupported\n".utf8))
            return nil
        }
        self.device = device
        self.counterSet = counterSet
        self.baseTimestamps = device.sampleTimestamps()
    }

    /// Makes this frame's sample buffer.
    ///
    /// One buffer per frame rather than one reused: resolution happens in the
    /// completed handler, and a shared buffer would race the next frame's
    /// samples against it.
    ///
    /// - Returns: The buffer the frame's passes sample into, or nil.
    func makeFrameSampleBuffer() -> MTLCounterSampleBuffer? {
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = counterSet
        descriptor.sampleCount = Self.samplesPerFrame
        descriptor.storageMode = .shared
        return try? device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    /// Points one render pass at two of the frame buffer's sample slots.
    ///
    /// The attachment is written on every call, the absent buffer included:
    /// the renderer reuses one grid pass descriptor across frames, so a frame
    /// whose allocation failed clears the stored attachment rather than
    /// inherit the previous frame's buffer - inheriting it would let this
    /// frame's GPU passes write a buffer whose completion handler may be
    /// resolving it.
    ///
    /// - Parameters:
    ///   - pass: The pass descriptor to sample.
    ///   - buffer: The frame's sample buffer, or nil to sample into nothing.
    ///   - slot: The start slot; the pass's end lands in the next one.
    func attach(to pass: MTLRenderPassDescriptor, buffer: MTLCounterSampleBuffer?, slot: Int) {
        let attachment = pass.sampleBufferAttachments[0]
        attachment?.sampleBuffer = buffer
        attachment?.startOfVertexSampleIndex = slot
        attachment?.endOfFragmentSampleIndex = slot + 1
    }

    /// Resolves and prints the frame's spans once the buffer completes.
    ///
    /// - Parameters:
    ///   - commands: The frame's command buffer, not yet committed.
    ///   - buffer: The frame's sample buffer.
    ///   - isReusingGrid: Whether the grid pass loaded retained rows, so a
    ///     cheap grid span can be told from an idle one.
    func scheduleReport(on commands: MTLCommandBuffer, buffer: MTLCounterSampleBuffer, isReusingGrid: Bool) {
        let base = baseTimestamps
        let device = device
        let box = FrameSampleBufferBox(buffer)
        commands.addCompletedHandler { _ in
            guard let resolved = try? box.buffer.resolveCounterRange(0..<Self.samplesPerFrame) else {
                FileHandle.standardError.write(Data("passgpu: resolve failed\n".utf8))
                return
            }
            var stamps = [UInt64](repeating: 0, count: Self.samplesPerFrame)
            _ = stamps.withUnsafeMutableBytes { resolved.copyBytes(to: $0) }
            guard !stamps.contains(.max), !stamps.contains(0) else {
                FileHandle.standardError.write(Data("passgpu: unresolved sample\n".utf8))
                return
            }
            // GPU ticks → seconds by correlating the init-time pair with one
            // taken now; the span between the pairs grows every frame, so the
            // scale converges over the run.
            let now = device.sampleTimestamps()
            let gpuTicks = Double(now.gpu &- base.gpu)
            guard gpuTicks > 0 else {
                return
            }
            let nanosecondsPerTick = Double(now.cpu &- base.cpu) / gpuTicks
            func microseconds(_ from: UInt64, _ to: UInt64) -> Double {
                Double(Int64(bitPattern: to &- from)) * nanosecondsPerTick / 1_000.0
            }
            let line = String(
                format: "passgpu reuse=%d grid=%.1f drawable=%.1f gap=%.1f total=%.1f\n",
                isReusingGrid ? 1 : 0,
                microseconds(stamps[0], stamps[1]),
                microseconds(stamps[2], stamps[3]),
                microseconds(stamps[1], stamps[2]),
                microseconds(stamps[0], stamps[3])
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
