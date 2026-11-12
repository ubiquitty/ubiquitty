// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Bounds SSH bytes before copying them or admitting a UI delivery.
/// The lock owns the FIFO, its one in-flight batch, and read-watermark state.
final class SSHInboundBuffer: @unchecked Sendable {
    struct Limits {
        var capacity = 8 * 1024 * 1024
        var highWater = 1024 * 1024
        var lowWater = 512 * 1024
        var batch = 128 * 1024
        var block = 64 * 1024
    }

    struct Action {
        var schedulesDelivery = false
        var changesReading = false
        var overflows = false
    }

    private let lock = NSLock()
    private let limits: Limits
    private var blocks: [Data] = []
    private var head = 0
    private var byteCount = 0
    private var inFlight: Data?
    private var isDeliveryScheduled = false
    private var isConsumerReady = true
    private var isAtHighWater = false
    private var hasOverflowed = false
    private var hasEnded = false
    private var isCancelled = false

    init(limits: Limits = Limits()) {
        precondition(limits.lowWater >= 0 && limits.lowWater < limits.highWater)
        precondition(limits.highWater <= limits.capacity && limits.batch > 0 && limits.block > 0)
        self.limits = limits
    }

    var pendingByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return byteCount
    }

    var shouldSuspendReading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsReadingSuspended
    }

    var canDeliverClose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEnded && !isCancelled && byteCount == 0 && inFlight == nil
    }

    func append(_ bytes: UnsafeRawBufferPointer) -> Action {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !hasEnded, !hasOverflowed, !bytes.isEmpty else { return Action() }
        let wasSuspended = wantsReadingSuspended
        guard bytes.count <= limits.capacity - byteCount else {
            hasOverflowed = true
            return Action(changesReading: !wasSuspended, overflows: true)
        }
        // Coalesce short reads too: a byte limit alone would permit millions
        // of retained Data objects from one-byte SSH packets.
        var offset = 0
        while offset < bytes.count {
            if blocks.count == head || (blocks.last?.count ?? limits.block) >= limits.block {
                blocks.append(Data(capacity: limits.block))
            }
            let last = blocks.count - 1
            let count = min(limits.block - blocks[last].count, bytes.count - offset)
            blocks[last].append(bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), count: count)
            offset += count
        }
        byteCount += bytes.count
        if byteCount >= limits.highWater { isAtHighWater = true }
        return action(after: wasSuspended)
    }

    /// Leaves the bytes charged until the consumer accepts the returned batch.
    func takeBatch() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, isConsumerReady, inFlight == nil else { return nil }
        guard head < blocks.count else {
            isDeliveryScheduled = false
            return nil
        }
        var data = Data(capacity: min(limits.batch, byteCount))
        while head < blocks.count, data.count < limits.batch {
            let count = min(limits.batch - data.count, blocks[head].count)
            data.append(blocks[head].prefix(count))
            if count == blocks[head].count {
                blocks[head] = Data()
                head += 1
            } else {
                blocks[head].removeFirst(count)
            }
        }
        if head == blocks.count {
            blocks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 16 && head >= blocks.count / 2 {
            blocks.removeFirst(head)
            head = 0
        }
        inFlight = data
        return data
    }

    func completeBatch(delivered: Bool) -> Action {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, let data = inFlight else { return Action() }
        let wasSuspended = wantsReadingSuspended
        inFlight = nil
        isDeliveryScheduled = false
        if delivered {
            byteCount -= data.count
            if byteCount <= limits.lowWater { isAtHighWater = false }
        } else {
            // No surface yet: keep the exact batch first, and stop reads until
            // adoption announces a consumer. No second pending-byte queue.
            if head > 0 {
                head -= 1
                blocks[head] = data
            } else {
                blocks.insert(data, at: 0)
            }
            isConsumerReady = false
        }
        return action(after: wasSuspended)
    }

    func consumerBecameReady() -> Action {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return Action() }
        let wasSuspended = wantsReadingSuspended
        isConsumerReady = true
        return action(after: wasSuspended)
    }

    func finish() -> Action {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return Action() }
        let wasSuspended = wantsReadingSuspended
        hasEnded = true
        return action(after: wasSuspended)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        blocks.removeAll()
        head = 0
        byteCount = 0
        inFlight = nil
        isDeliveryScheduled = false
    }

    private var wantsReadingSuspended: Bool { isCancelled || hasEnded || hasOverflowed || !isConsumerReady || isAtHighWater }

    private func action(after wasSuspended: Bool) -> Action {
        var result = Action(changesReading: wasSuspended != wantsReadingSuspended)
        if !isDeliveryScheduled, isConsumerReady, byteCount > 0 || hasEnded {
            isDeliveryScheduled = true
            result.schedulesDelivery = true
        }
        return result
    }
}
