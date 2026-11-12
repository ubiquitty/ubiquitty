// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

@main
struct SSHInboundBufferTests {
    static func main() {
        let limits = SSHInboundBuffer.Limits(capacity: 16, highWater: 8, lowWater: 4, batch: 4, block: 4)
        func append(_ bytes: [UInt8], to buffer: SSHInboundBuffer) -> SSHInboundBuffer.Action {
            bytes.withUnsafeBytes { buffer.append($0) }
        }

        let watermarks = SSHInboundBuffer(limits: limits)
        let first = append(Array(0..<8), to: watermarks)
        precondition(first.schedulesDelivery && first.changesReading && watermarks.shouldSuspendReading)
        precondition(!append([8, 9], to: watermarks).schedulesDelivery, "one wake covers all admitted reads")
        precondition(watermarks.takeBatch() == Data(0..<4))
        precondition(watermarks.pendingByteCount == 10, "in-flight bytes remain charged")
        var action = watermarks.completeBatch(delivered: true)
        precondition(action.schedulesDelivery && !action.changesReading && watermarks.shouldSuspendReading)
        precondition(watermarks.takeBatch() == Data(4..<8))
        action = watermarks.completeBatch(delivered: true)
        precondition(action.changesReading && !watermarks.shouldSuspendReading, "only the low watermark resumes reads")
        precondition(watermarks.takeBatch() == Data([8, 9]))
        precondition(!watermarks.completeBatch(delivered: true).schedulesDelivery)
        precondition(watermarks.pendingByteCount == 0)

        let missingSurface = SSHInboundBuffer(limits: limits)
        _ = append(Array(0..<12), to: missingSurface)
        precondition(missingSurface.takeBatch() == Data(0..<4))
        action = missingSurface.completeBatch(delivered: false)
        precondition(!action.schedulesDelivery && missingSurface.shouldSuspendReading)
        precondition(missingSurface.pendingByteCount == 12, "no surface must not lose or release bytes")
        precondition(missingSurface.takeBatch() == nil)
        precondition(missingSurface.consumerBecameReady().schedulesDelivery)
        for first in stride(from: 0, to: 12, by: 4) {
            precondition(missingSurface.takeBatch() == Data(UInt8(first)..<UInt8(first + 4)))
            _ = missingSurface.completeBatch(delivered: true)
        }
        precondition(!missingSurface.shouldSuspendReading && missingSurface.pendingByteCount == 0)

        let interleaved = SSHInboundBuffer(limits: limits)
        _ = append(Array(0..<6), to: interleaved)
        precondition(interleaved.takeBatch() == Data(0..<4))
        precondition(!append(Array(6..<10), to: interleaved).schedulesDelivery)
        _ = interleaved.completeBatch(delivered: true)
        precondition(interleaved.takeBatch() == Data(4..<8))
        _ = interleaved.completeBatch(delivered: true)
        precondition(interleaved.takeBatch() == Data([8, 9]))
        _ = interleaved.completeBatch(delivered: true)

        let ended = SSHInboundBuffer(limits: limits)
        _ = append(Array(0..<6), to: ended)
        precondition(!ended.finish().schedulesDelivery, "EOF shares the pending wake")
        precondition(!ended.canDeliverClose)
        precondition(!append([99], to: ended).schedulesDelivery)
        precondition(ended.pendingByteCount == 6, "EOF must reject later bytes")
        precondition(ended.takeBatch() == Data(0..<4))
        _ = ended.completeBatch(delivered: true)
        precondition(!ended.canDeliverClose)
        precondition(ended.takeBatch() == Data([4, 5]))
        precondition(ended.completeBatch(delivered: true).schedulesDelivery)
        precondition(ended.takeBatch() == nil && ended.canDeliverClose, "EOF follows the final accepted batch")

        let oversized = SSHInboundBuffer(limits: limits)
        action = append(Array(repeating: 1, count: 17), to: oversized)
        precondition(action.overflows && !action.schedulesDelivery && oversized.pendingByteCount == 0)
        precondition(oversized.shouldSuspendReading)
        precondition(!append([1], to: oversized).overflows, "overflow is reported once")

        let full = SSHInboundBuffer(limits: limits)
        _ = append(Array(0..<16), to: full)
        precondition(append([16], to: full).overflows && full.pendingByteCount == 16)
        _ = full.finish()
        for first in stride(from: 0, to: 16, by: 4) {
            precondition(full.takeBatch() == Data(UInt8(first)..<UInt8(first + 4)))
            _ = full.completeBatch(delivered: true)
        }
        precondition(full.takeBatch() == nil && full.canDeliverClose)

        let cancelled = SSHInboundBuffer(limits: limits)
        _ = append([0, 1, 2, 3], to: cancelled)
        precondition(cancelled.takeBatch() != nil)
        cancelled.cancel()
        precondition(cancelled.pendingByteCount == 0 && cancelled.takeBatch() == nil)
        precondition(cancelled.shouldSuspendReading, "late control reconciliation must never resume a cancelled reader")
        precondition(!cancelled.completeBatch(delivered: true).schedulesDelivery)
        precondition(!cancelled.consumerBecameReady().schedulesDelivery && !cancelled.finish().schedulesDelivery)
        precondition(!append([99], to: cancelled).schedulesDelivery && !cancelled.canDeliverClose)

        let shortReads = SSHInboundBuffer(limits: limits)
        var wakes = 0
        for byte: UInt8 in 0..<16 {
            if append([byte], to: shortReads).schedulesDelivery { wakes += 1 }
        }
        precondition(wakes == 1)
        var received = Data()
        while let batch = shortReads.takeBatch() {
            received.append(batch)
            _ = shortReads.completeBatch(delivered: true)
        }
        precondition(received == Data(0..<16) && shortReads.pendingByteCount == 0)
        print("PASS SSH inbound admission, bounded ordered batches, watermarks, missing surface, EOF and cancellation")
    }
}
