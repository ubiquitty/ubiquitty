// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// StreamDebugRecorder — records the raw PTY byte stream for the Stream Debug window.
// Thread-safe ring buffer of chunks (received/sent) with timestamps.
// Used by the modern Swift arm (TerminalSurface).
//

import Foundation
import UbiquittyCore

/// Direction of a byte chunk relative to the terminal.
public enum StreamDebugDirection: Int, Sendable {
    case received = 0 // bytes read from PTY (terminal output)
    case sent = 1 // bytes written to PTY (user input + replies)
}

/// A single recorded chunk of the byte stream.
public final class StreamDebugChunk: Sendable, Equatable {
    public let direction: StreamDebugDirection
    public let timestampMicros: UInt64
    public let data: Data

    init(direction: StreamDebugDirection, timestampMicros: UInt64, data: Data) {
        self.direction = direction
        self.timestampMicros = timestampMicros
        self.data = data
    }

    public static func == (lhs: StreamDebugChunk, rhs: StreamDebugChunk) -> Bool {
        lhs.direction == rhs.direction
            && lhs.timestampMicros == rhs.timestampMicros
            && lhs.data == rhs.data
    }
}

/// Snapshot of the recorded stream for the debug view.
public final class StreamDebugSnapshot: Sendable, Equatable {
    public let chunks: [StreamDebugChunk]
    public let totalReceivedBytes: UInt64
    public let totalSentBytes: UInt64

    init(chunks: [StreamDebugChunk], totalReceivedBytes: UInt64, totalSentBytes: UInt64) {
        self.chunks = chunks
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
    }

    public static func == (lhs: StreamDebugSnapshot, rhs: StreamDebugSnapshot) -> Bool {
        lhs.chunks == rhs.chunks
            && lhs.totalReceivedBytes == rhs.totalReceivedBytes
            && lhs.totalSentBytes == rhs.totalSentBytes
    }
}

/// Records the raw byte stream for a terminal session.
/// Thread-safe: can be fed from the ingest thread (received) and main thread (sent).
/// Ring buffer with bounded total bytes and chunk count.
public final class StreamDebugRecorder: @unchecked Sendable {
    /// Package rather than implicit: the implicit initializer is internal,
    /// and the surface constructing one lives in the Kit module, which
    /// reaches this type through package visibility.
    package init() {}

    private let lock = NSLock()
    private var chunks: [StreamDebugChunk] = []
    private var totalReceived: UInt64 = 0
    private var totalSent: UInt64 = 0
    private var _isRecording = false

    // Limits to bound memory usage.
    private static let maxTotalBytes = 1 << 20 // 1 MiB of stream data
    private static let maxChunks = 512 // max chunks in ring

    /// Call when the debug window starts watching this recorder.
    public func startRecording() {
        lock.withLock { _isRecording = true }
    }

    /// Call when the debug window stops watching this recorder.
    public func stopRecording() {
        lock.withLock { _isRecording = false }
    }

    /// Whether the recorder is actively recording.
    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    /// Feed bytes from the PTY (received by terminal).
    public func appendReceived(bytes: UnsafePointer<CChar>, count: Int) {
        append(bytes: bytes, count: count, direction: .received)
    }

    /// Feed bytes to the PTY (sent by terminal: user input + replies).
    public func appendSent(bytes: UnsafePointer<CChar>, count: Int) {
        append(bytes: bytes, count: count, direction: .sent)
    }

    private func append(bytes: UnsafePointer<CChar>, count: Int, direction: StreamDebugDirection) {
        lock.withLock {
            // The copy is taken here, INSIDE the recording guard, not by the
            // caller: the tap fires on the ingest thread for every bite, and a
            // copy taken outside the guard is a flood's worth of memcpy dropped
            // whenever the debug window is closed. Off, this returns before
            // allocating. The borrowed pointer is valid for the synchronous tap
            // call this runs inside. The backing field, not the `isRecording`
            // property, which takes this same non-reentrant lock.
            guard _isRecording, count > 0 else { return }
            let data = Data(bytes: bytes, count: count)
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let chunk = StreamDebugChunk(direction: direction, timestampMicros: now, data: data)
            chunks.append(chunk)
            switch direction {
            case .received: totalReceived += UInt64(data.count)
            case .sent: totalSent += UInt64(data.count)
            }
            enforceLimits()
        }
    }

    private func enforceLimits() {
        // Trim chunks to stay within limits.
        while chunks.count > Self.maxChunks || (totalReceived + totalSent) > Self.maxTotalBytes {
            guard let removed = chunks.first else { break }
            chunks.removeFirst()
            switch removed.direction {
            case .received: totalReceived = totalReceived > UInt64(removed.data.count) ? totalReceived - UInt64(removed.data.count) : 0
            case .sent: totalSent = totalSent > UInt64(removed.data.count) ? totalSent - UInt64(removed.data.count) : 0
            }
        }
    }

    /// Capture a snapshot of the current recording for the view.
    public func snapshot() -> StreamDebugSnapshot {
        lock.withLock {
            StreamDebugSnapshot(chunks: chunks, totalReceivedBytes: totalReceived, totalSentBytes: totalSent)
        }
    }

    /// Clear all recorded data.
    public func reset() {
        lock.withLock {
            chunks.removeAll()
            totalReceived = 0
            totalSent = 0
        }
    }

    /// Install the taps on a TerminalSession.
    /// Must be called before the session starts ingest.
    package func install(on session: Ubiquitty.Runtime.TerminalSession) {
        // Inbound (received) tap — called on ingest thread from drainAvailable/flood pipeline.
        session.setRawByteTap(
            { context, bytes in
                guard let recorder = Unmanaged<StreamDebugRecorder>.fromOpaque(context!).takeUnretainedValue() as StreamDebugRecorder?
                else { return }
                guard bytes.size() > 0, let base = bytes.__dataUnsafe() else { return }
                recorder.appendReceived(bytes: base, count: Int(bytes.size()))
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Outbound (sent) tap — called from sendInputBytes (main) and flushReplies (ingest thread).
        session.setOutboundByteTap(
            { context, bytes in
                guard let recorder = Unmanaged<StreamDebugRecorder>.fromOpaque(context!).takeUnretainedValue() as StreamDebugRecorder?
                else { return }
                guard bytes.size() > 0, let base = bytes.__dataUnsafe() else { return }
                recorder.appendSent(bytes: base, count: Int(bytes.size()))
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
