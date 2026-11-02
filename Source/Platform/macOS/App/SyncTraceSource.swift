// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// SyncTraceSource.swift — where the Sync Debug window's numbers come from.
//
// Core builds the report (Core/Session/SyncTraceReport.h) from a remote session's
// trace; this file only finds the session and copies the report into Swift
// values the view can hold across polls. A window answers through its hosted
// surface's drive, and the numbers, the type names and the transport name are
// Core's.

/// One Sync Debug sample: a remote session's traffic, protocol and timing as
/// Core reported it, plus the command the session was started with.
struct SyncTraceSample {
    /// One frame in the recent-frames log.
    struct Frame {
        /// Position since the trace began; a jump of more than one between
        /// neighbours means the ring overflowed.
        let ordinal: UInt64
        /// Wall-clock microseconds.
        let unixMicros: Int64
        /// Microseconds since the trace's epoch, for inter-frame gaps.
        let monotonicMicros: Int64
        /// Whether the client sent it.
        let isOutbound: Bool
        /// Bytes as it travelled.
        let wireBytes: UInt32
        /// The wire type's protocol name.
        let typeName: String
    }

    /// Totals for one wire type in one direction.
    struct TypeStat {
        /// Whether the row counts frames the client sent.
        let isOutbound: Bool
        /// Frames seen.
        let count: UInt64
        /// Their bytes as they travelled.
        let wireBytes: UInt64
        /// Their bytes once decompressed.
        let logicalBytes: UInt64
        /// The wire type's protocol name.
        let typeName: String
    }

    /// One entry from the connection-event timeline.
    struct Event {
        /// Wall-clock microseconds.
        let unixMicros: Int64
        /// What happened.
        let text: String
    }

    /// Where the connection is, in the view's own terms.
    enum ConnectionState {
        case connecting
        case connected
        case reconnecting
        case failed
        case deploying
    }

    let state: ConnectionState
    let usesQUIC: Bool
    let transport: String
    let shellCommand: String
    let sessionID: UInt32
    let sampleUnixMicros: Int64
    let uptimeMicros: Int64

    let inboundFrames: UInt64
    let outboundFrames: UInt64
    let inboundWireBytes: UInt64
    let inboundLogicalBytes: UInt64
    let outboundWireBytes: UInt64
    let resyncs: UInt64
    let largestInboundWireBytes: UInt32
    let largestOutboundWireBytes: UInt32
    let lastScreenAgeMicros: Int64

    let latencyCount: UInt64
    let latencyLastMicros: Int64
    let latencyMinMicros: Int64
    let latencyP50Micros: Int64
    let latencyP95Micros: Int64
    let latencyMaxMicros: Int64

    let hasTransportStats: Bool
    let rttSmoothedMicros: Int64
    let rttLatestMicros: Int64
    let rttMinMicros: Int64
    let rttVarMicros: Int64
    let congestionWindow: UInt64
    let bytesInFlight: UInt64
    let slowStartThreshold: UInt64
    let packetsSent: UInt64
    let packetsReceived: UInt64
    let packetsLost: UInt64
    let transportBytesSent: UInt64
    let transportBytesReceived: UInt64
    let transportBytesLost: UInt64

    let typeStats: [TypeStat]
    let recentFrames: [Frame]
    let events: [Event]

    /// Copies Core's report into values the view can keep between polls.
    ///
    /// - Parameters:
    ///   - report: The report Core built.
    ///   - shellCommand: The command the session was started with.
    init(_ report: Ubiquitty.Session.SyncTraceReport, shellCommand: String) {
        // Core's Idle precedes the first start; a window shows it as
        // connecting, which is what it is about to do.
        switch report.state {
        case .Idle, .Connecting: state = .connecting
        case .Connected: state = .connected
        case .Reconnecting: state = .reconnecting
        case .Failed: state = .failed
        case .Deploying: state = .deploying
        @unknown default: state = .failed
        }
        usesQUIC = report.transportMode == .QUIC
        transport = String(report.transportName)
        self.shellCommand = shellCommand
        sessionID = report.sessionID
        sampleUnixMicros = report.sampleUnixMicros
        uptimeMicros = report.totals.uptimeMicros

        inboundFrames = report.totals.inboundFrames
        outboundFrames = report.totals.outboundFrames
        inboundWireBytes = report.totals.inboundWireBytes
        inboundLogicalBytes = report.totals.inboundLogicalBytes
        outboundWireBytes = report.totals.outboundWireBytes
        resyncs = report.totals.resyncs
        largestInboundWireBytes = report.totals.largestInboundWireBytes
        largestOutboundWireBytes = report.totals.largestOutboundWireBytes
        lastScreenAgeMicros = report.totals.lastScreenAgeMicros

        latencyCount = report.latency.count
        latencyLastMicros = report.latency.lastMicros
        latencyMinMicros = report.latency.minMicros
        latencyP50Micros = report.latency.p50Micros
        latencyP95Micros = report.latency.p95Micros
        latencyMaxMicros = report.latency.maxMicros

        hasTransportStats = report.hasTransportStats
        rttSmoothedMicros = report.transport.smoothedRttMicros
        rttLatestMicros = report.transport.latestRttMicros
        rttMinMicros = report.transport.minRttMicros
        rttVarMicros = report.transport.rttVarMicros
        congestionWindow = report.transport.congestionWindow
        bytesInFlight = report.transport.bytesInFlight
        slowStartThreshold = report.transport.slowStartThreshold
        packetsSent = report.transport.packetsSent
        packetsReceived = report.transport.packetsReceived
        packetsLost = report.transport.packetsLost
        transportBytesSent = report.transport.bytesSent
        transportBytesReceived = report.transport.bytesReceived
        transportBytesLost = report.transport.bytesLost

        typeStats = report.typeRows.map { row in
            TypeStat(
                isOutbound: row.isOutbound,
                count: row.count,
                wireBytes: row.wireBytes,
                logicalBytes: row.logicalBytes,
                typeName: String(row.typeName)
            )
        }
        recentFrames = report.recentFrames.map { frame in
            Frame(
                ordinal: frame.ordinal,
                unixMicros: frame.unixMicros,
                monotonicMicros: frame.monotonicMicros,
                isOutbound: frame.isOutbound,
                wireBytes: frame.wireBytes,
                typeName: String(frame.typeName)
            )
        }
        events = report.events.map { event in Event(unixMicros: event.unixMicros, text: String(event.text)) }
    }
}

/// Finds the remote session the Sync Debug window reports on.
///
/// The key window's, when it is remote; otherwise the frontmost remote window
/// of either shell. The debug window itself is not a terminal, so while it is
/// key the lookup falls through to the terminal behind it.
@MainActor
enum SyncTraceSource {
    /// A sample from the frontmost remote session.
    ///
    /// - Returns: The sample, or nil when no remote window is open.
    static func frontmost() -> SyncTraceSample? {
        for window in candidateWindows() {
            if let sample = sample(of: window) {
                return sample
            }
        }
        return nil
    }

    /// Clears the frontmost remote session's trace.
    static func resetFrontmost() {
        for window in candidateWindows() {
            if let hosted = window.windowController as? TerminalWindowController, let surface = hosted.remoteSurface {
                surface.drive.resetSyncTrace()
                return
            }
        }
    }

    /// The key window first, then every window front to back.
    private static func candidateWindows() -> [NSWindow] {
        var windows: [NSWindow] = []
        if let key = NSApp.keyWindow {
            windows.append(key)
        }
        windows.append(contentsOf: NSApp.orderedWindows.filter { $0 !== NSApp.keyWindow })
        return windows
    }

    /// The window's sample, when the window is a remote one.
    private static func sample(of window: NSWindow) -> SyncTraceSample? {
        if let hosted = window.windowController as? TerminalWindowController, let surface = hosted.remoteSurface {
            return SyncTraceSample(surface.drive.syncTraceReport(), shellCommand: hosted.remoteTransportCommand)
        }

        return nil
    }
}
