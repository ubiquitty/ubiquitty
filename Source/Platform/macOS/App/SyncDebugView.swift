// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SyncDebugView — the live Sync traffic / protocol / performance monitor.
//
// Polls SyncTraceSource.frontmost() a few times a second and
// renders, for the frontmost remote (thin-client) session:
//   • context (transport, state, session, uptime, command)
//   • throughput (In/Out bytes/s + frames/s) with a 60-second sparkline
//   • echo latency (keystroke → next screen frame): last / p50 / p95 / max
//   • QUIC transport stats when on QUIC: RTT, congestion window, bytes in
//     flight, packet loss, packets/bytes sent+received
//   • expansion, screen frames, resyncs, screen age, largest frame
//   • a per-frame-type histogram
//   • the connection-event timeline
//   • a scrolling log of recent frames with inter-frame timing
// plus a "Copy report" button that puts a text summary on the clipboard.
//
// Built to answer "where is a slow session over SSH spending its bytes/time?"
// without a packet capture. Core records the trace and builds the report
// (Core/Session/SyncTraceReport.h); SyncTraceSource finds the session in either
// shell and hands the report over.
//

import AppKit
import Combine
import SwiftUI

struct SyncDebugView: View {
    @State
    private var current: SyncTraceSample?
    @State
    private var previous: SyncTraceSample?
    @State
    private var paused: Bool = false
    // Rolling 60 s of throughput (≈240 samples at 4 Hz) for the sparklines.
    @State
    private var inHistory: [Double] = []
    @State
    private var outHistory: [Double] = []

    private let historyLimit = 240
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let snapshot = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(snapshot)
                        Divider()
                        throughputSection(snapshot)
                        Divider()
                        latencySection(snapshot)
                        if snapshot.hasTransportStats {
                            Divider()
                            quicSection(snapshot)
                        }
                        Divider()
                        protocolSection(snapshot)
                        Divider()
                        typeTable(snapshot)
                        if !snapshot.events.isEmpty {
                            Divider()
                            eventsSection(snapshot)
                        }
                        Divider()
                        frameLogHeader
                        frameLog(snapshot)
                    }
                }
            } else {
                empty
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .onReceive(tick) { _ in poll() }
        .onAppear { poll() }
    }

    // MARK: - Polling

    private func poll() {
        guard !paused else { return }
        let next = SyncTraceSource.frontmost()
        // A continuation = the same session whose trace clock moved forward.
        // A different session, or a counters reset (uptime regressed), is a
        // discontinuity: drop the delta baseline and the sparkline history so we
        // never compute a rate across two unrelated counter sets.
        if let next, let currentSample = current,
            next.sessionID == currentSample.sessionID, next.uptimeMicros >= currentSample.uptimeMicros
        {
            previous = currentSample
            // dt from the monotonic trace age, not wall-clock (immune to NTP steps).
            let dt = Double(next.uptimeMicros - currentSample.uptimeMicros) / 1_000_000.0
            appendHistory(&inHistory, rate(next.inboundWireBytes, currentSample.inboundWireBytes, dt))
            appendHistory(&outHistory, rate(next.outboundWireBytes, currentSample.outboundWireBytes, dt))
        } else {
            previous = nil
            inHistory.removeAll()
            outHistory.removeAll()
        }
        current = next
    }

    private func appendHistory(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > historyLimit { buffer.removeFirst(buffer.count - historyLimit) }
    }

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No Remote Session").font(.headline)
            Text("Connect a window over SSH (a thin-client session) to see live Sync traffic here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Header

    private func header(_ s: SyncTraceSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                badge(s.transport, color: s.usesQUIC ? .green : .orange)
                badge(stateLabel(s.state), color: stateColor(s.state))
                if s.sessionID != 0 {
                    Text("session \(s.sessionID)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("up \(formatDuration(s.uptimeMicros))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !s.shellCommand.isEmpty {
                Text(s.shellCommand)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(s.shellCommand)
            }
        }
        .padding(10)
    }

    // MARK: - Throughput + sparkline

    private func throughputSection(_ s: SyncTraceSample) -> some View {
        let dt = previous.map { Double(s.uptimeMicros - $0.uptimeMicros) / 1_000_000.0 } ?? 0
        let inRate = rate(s.inboundWireBytes, previous?.inboundWireBytes, dt)
        let outRate = rate(s.outboundWireBytes, previous?.outboundWireBytes, dt)
        let inFps = rate(s.inboundFrames, previous?.inboundFrames, dt)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                metric("In", "\(formatBytes(inRate))/s", sub: "\(s.inboundFrames) frm")
                metric("Out", "\(formatBytes(outRate))/s", sub: "\(s.outboundFrames) frm")
                metric(
                    "In frames/s",
                    String(format: "%.0f", inFps),
                    sub: "Σ \(formatBytes(Double(s.inboundWireBytes)))"
                )
            }
            HStack(spacing: 12) {
                sparkline(inHistory, color: .green, label: "in")
                sparkline(outHistory, color: .blue, label: "out")
            }
            .frame(height: 38)
        }
        .padding(10)
    }

    private func sparkline(_ values: [Double], color: Color, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.06))
            Sparkline(values: values, color: color)
            Text(label).font(.caption2).foregroundStyle(.secondary).padding(3)
        }
    }

    // MARK: - Latency

    private func latencySection(_ s: SyncTraceSample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Echo latency", trailing: "input → next screen frame")
            if s.latencyCount == 0 {
                Text("No keystrokes sampled yet — type in the session to measure round-trip paint latency.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    metric("Last", formatMicrosMillis(s.latencyLastMicros), sub: "\(s.latencyCount) samples")
                    metric("p50", formatMicrosMillis(s.latencyP50Micros), sub: nil)
                    metric("p95", formatMicrosMillis(s.latencyP95Micros), sub: nil)
                    metric("max", formatMicrosMillis(s.latencyMaxMicros), sub: "min \(formatMicrosMillis(s.latencyMinMicros))")
                }
            }
        }
        .padding(10)
    }

    // MARK: - QUIC transport stats

    private func quicSection(_ s: SyncTraceSample) -> some View {
        let sent = s.packetsSent
        let lost = s.packetsLost
        let lossPct = sent > 0 ? Double(lost) / Double(sent) * 100.0 : 0
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("QUIC transport", trailing: "ngtcp2 connection info")
            HStack {
                metric(
                    "RTT",
                    formatMicrosMillis(s.rttSmoothedMicros),
                    sub: "min \(formatMicrosMillis(s.rttMinMicros))"
                )
                metric(
                    "latest",
                    formatMicrosMillis(s.rttLatestMicros),
                    sub: "var \(formatMicrosMillis(s.rttVarMicros))"
                )
                metric(
                    "cwnd",
                    formatBytes(Double(s.congestionWindow)),
                    sub: "in-flight \(formatBytes(Double(s.bytesInFlight)))"
                )
            }
            HStack {
                metric(
                    "Loss",
                    String(format: "%.2f%%", lossPct),
                    sub: "\(lost) lost",
                    emphasize: lossPct >= 1.0
                )
                metric("Pkts", "\(sent)↑ \(s.packetsReceived)↓", sub: nil)
                metric(
                    "Bytes",
                    "\(formatBytes(Double(s.transportBytesSent)))↑",
                    sub: "\(formatBytes(Double(s.transportBytesReceived)))↓"
                )
            }
        }
        .padding(10)
    }

    // MARK: - Protocol (expansion / resyncs / cadence)

    private func protocolSection(_ s: SyncTraceSample) -> some View {
        let screenFrameCount = typeCount(s, inbound: true, names: ["CheckpointHead", "Update"])
        let ratio =
            s.inboundWireBytes > 0
            ? Double(s.inboundLogicalBytes) / Double(s.inboundWireBytes) : 1.0
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Protocol", trailing: nil)
            HStack {
                metric(
                    "Decoded",
                    formatBytes(Double(s.inboundLogicalBytes)),
                    sub: "wire \(formatBytes(Double(s.inboundWireBytes)))"
                )
                metric(
                    "Expansion",
                    String(format: "%.1f×", ratio),
                    sub: ratio > 1.05 ? "zlib win" : nil
                )
                metric(
                    "Screen frames",
                    "\(screenFrameCount)",
                    sub: "\(s.resyncs) resyncs",
                    emphasize: s.resyncs > 0
                )
            }
            HStack {
                metric(
                    "Last screen",
                    s.lastScreenAgeMicros < 0 ? "—" : "\(formatDuration(s.lastScreenAgeMicros)) ago",
                    sub: nil
                )
                metric("Largest in", formatBytes(Double(s.largestInboundWireBytes)), sub: nil)
                metric("Largest out", formatBytes(Double(s.largestOutboundWireBytes)), sub: nil)
            }
        }
        .padding(10)
    }

    // MARK: - Per-type histogram

    private func typeTable(_ s: SyncTraceSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Frames by type", trailing: nil)
            ForEach(Array(s.typeStats.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Text(r.isOutbound ? "↑" : "↓")
                        .foregroundStyle(r.isOutbound ? Color.blue : Color.green).frame(width: 12)
                    Text(r.typeName).frame(width: 150, alignment: .leading)
                    Text("\(r.count)").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                    Text(formatBytes(Double(r.wireBytes))).frame(width: 80, alignment: .trailing)
                    if r.logicalBytes > r.wireBytes {
                        Text(String(format: "%.1f×", Double(r.logicalBytes) / Double(max(r.wireBytes, 1))))
                            .frame(width: 50, alignment: .trailing).foregroundStyle(.green)
                    } else {
                        Spacer().frame(width: 50)
                    }
                }
                .font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }

    // MARK: - Events timeline

    private func eventsSection(_ s: SyncTraceSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Events", trailing: nil)
            ForEach(Array(s.events.enumerated().reversed()), id: \.offset) { _, e in
                HStack(spacing: 6) {
                    Text(clockString(e.unixMicros)).foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(e.text).foregroundStyle(.primary)
                    Spacer()
                }
                .font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }

    // MARK: - Live frame log

    private var frameLogHeader: some View {
        HStack {
            sectionTitle("Live frames", trailing: nil)
            Spacer()
            Toggle("Pause", isOn: $paused).toggleStyle(.button).controlSize(.small)
            Button("Copy Report") { copyReport() }.controlSize(.small)
            Button("Reset") {
                SyncTraceSource.resetFrontmost()
                previous = nil
                inHistory.removeAll()
                outHistory.removeAll()
                poll()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }

    private func frameLog(_ s: SyncTraceSample) -> some View {
        let shown = s.recentFrames.suffix(250).reversed().map { $0 } // newest first
        return LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.element.ordinal) { idx, f in
                let older = idx + 1 < shown.count ? shown[idx + 1] : nil
                let deltaMicros = older.map { f.monotonicMicros - $0.monotonicMicros } ?? 0
                frameRow(f, deltaMicros: deltaMicros)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func frameRow(_ f: SyncTraceSample.Frame, deltaMicros: Int64) -> some View {
        let bigGap = deltaMicros >= 100_000
        return HStack(spacing: 6) {
            Text(clockString(f.unixMicros)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(f.isOutbound ? "↑" : "↓")
                .foregroundStyle(f.isOutbound ? Color.blue : Color.green).frame(width: 10)
            Text(f.typeName).foregroundStyle(Color.primary)
                .frame(width: 140, alignment: .leading)
            Text(formatBytes(Double(f.wireBytes))).frame(width: 64, alignment: .trailing)
            Text(deltaMicros > 0 ? "+\(formatMicrosMillis(deltaMicros))" : "")
                .foregroundStyle(bigGap ? Color.red : Color.secondary).frame(width: 64, alignment: .trailing)
            if bigGap { Text("⚠").foregroundStyle(.red) }
            Spacer()
        }
        .font(.caption.monospaced())
    }

    // MARK: - Copy report

    private func copyReport() {
        guard let s = current else { return }
        var lines: [String] = []
        lines.append("Sync Debug report")
        lines.append(
            "transport: \(s.transport)  state: \(stateLabel(s.state))  session: \(s.sessionID)  up: \(formatDuration(s.uptimeMicros))"
        )
        lines.append("command: \(s.shellCommand)")
        lines.append("")
        lines.append(
            // copy-ok: a developer report copied to the pasteboard for a bug report, not interface text
            "In  \(formatBytes(Double(s.inboundWireBytes))) wire / \(formatBytes(Double(s.inboundLogicalBytes))) decoded over \(s.inboundFrames) frames"
        )
        lines.append("Out \(formatBytes(Double(s.outboundWireBytes))) over \(s.outboundFrames) frames")
        lines.append(
            "resyncs: \(s.resyncs)  largest in: \(formatBytes(Double(s.largestInboundWireBytes)))  largest out: \(formatBytes(Double(s.largestOutboundWireBytes)))"
        )
        if s.latencyCount > 0 {
            lines.append(
                "echo latency: last \(formatMicrosMillis(s.latencyLastMicros))  p50 \(formatMicrosMillis(s.latencyP50Micros))  p95 \(formatMicrosMillis(s.latencyP95Micros))  max \(formatMicrosMillis(s.latencyMaxMicros))  (\(s.latencyCount) samples)"
            )
        }
        if s.hasTransportStats {
            let lossPct = s.packetsSent > 0 ? Double(s.packetsLost) / Double(s.packetsSent) * 100.0 : 0
            lines.append(
                "QUIC: rtt \(formatMicrosMillis(s.rttSmoothedMicros)) (min \(formatMicrosMillis(s.rttMinMicros)))  cwnd \(formatBytes(Double(s.congestionWindow)))  in-flight \(formatBytes(Double(s.bytesInFlight)))  loss \(String(format: "%.2f%%", lossPct)) (\(s.packetsLost)/\(s.packetsSent))"
            )
        }
        lines.append("")
        lines.append("Frames by type:")
        for r in s.typeStats {
            lines.append("  \(r.isOutbound ? "↑" : "↓") \(r.typeName)  ×\(r.count)  \(formatBytes(Double(r.wireBytes)))")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Small building blocks

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let trailing {
                Text(trailing).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    private func metric(_ label: String, _ value: String, sub: String?, emphasize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced().weight(.medium))
                .foregroundStyle(emphasize ? Color.red : Color.primary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derivations & formatting

    private func rate(_ now: UInt64, _ then: UInt64?, _ dt: Double) -> Double {
        guard let then, dt > 0, now >= then else { return 0 }
        return Double(now - then) / dt
    }

    private func typeCount(_ s: SyncTraceSample, inbound: Bool, names: [String]) -> Int {
        var total = 0
        for r in s.typeStats where r.isOutbound == !inbound && names.contains(r.typeName) {
            total += Int(r.count)
        }
        return total
    }

    private func stateLabel(_ state: SyncTraceSample.ConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Failed"
        case .deploying: return "Deploying"
        }
    }

    private func stateColor(_ state: SyncTraceSample.ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .deploying: return .orange
        case .reconnecting: return .yellow
        case .failed: return .red
        }
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes < 1024 { return String(format: "%.0f B", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.2f MB", bytes / (1024 * 1024))
    }

    private func formatMicrosMillis(_ micros: Int64) -> String {
        if micros < 0 { return "—" }
        let ms = Double(micros) / 1000.0
        if ms < 10 { return String(format: "%.1fms", ms) }
        return String(format: "%.0fms", ms)
    }

    private func formatDuration(_ micros: Int64) -> String {
        let seconds = Int(micros / 1_000_000)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    private func clockString(_ unixMicros: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(unixMicros) / 1_000_000.0)
        return Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// A minimal line-chart of recent samples, auto-scaled to the window max.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
