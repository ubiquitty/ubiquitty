// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// StreamDebugView — the live raw byte-stream monitor (like HexFiend).
// Shows all bytes the terminal receives (↓) and sends (↑) with hex + ASCII.
// Polls the frontmost terminal's StreamDebugRecorder via TerminalWindowController.
// Built to answer "what raw bytes are flowing through the PTY right now?".
//

import AppKit
import Combine
import SwiftUI
internal import UbiquittyRenderKit

struct StreamDebugView: View {
    @State
    private var snapshot: StreamDebugSnapshot?
    // The recorder whose startRecording this view owns. Tracked so a pause, a
    // window close, or the frontmost terminal changing stops the one recorder
    // this view started — a recorder left recording after its watcher is gone
    // copies every chunk on the ingest thread for a reader that never comes.
    @State
    private var watchedRecorder: StreamDebugRecorder?
    @State
    private var paused: Bool = false
    @State
    private var followTail = true
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let snap = snapshot, !snap.chunks.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(snap.chunks.enumerated()), id: \.offset) { idx, chunk in
                                VStack(alignment: .leading, spacing: 2) {
                                    chunkHeader(chunk, absoluteIndex: idx)
                                    hexDumpRows(chunk, startOffset: absoluteOffset(for: idx))
                                }
                                .id(idx)
                            }
                            // Anchor for auto-scroll
                            Color.clear.frame(height: 1).id("tail")
                        }
                        .padding(10)
                    }
                    .onChange(of: snapshot) { _, _ in
                        if followTail {
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                    .onChange(of: followTail) { _, newValue in
                        if newValue {
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                }
            } else if let snap = snapshot, snap.chunks.isEmpty {
                emptyState("Recording… no data yet")
            } else {
                emptyState("No local session")
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // On the Group, not the snapshot-gated branch inside it: a timer
        // mounted on the populated branch never fires from the empty state,
        // and the first poll is what leaves the empty state.
        .onReceive(timer) { _ in poll() }
        .onAppear { poll() }
        .onDisappear { stopWatching() }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                stopWatching()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Toggle("Pause", isOn: $paused)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Toggle("Follow tail", isOn: $followTail)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Button("Clear") { clear() }
                    .controlSize(.small)
                Button("Copy") { copy() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Polling

    private func poll() {
        guard !paused else { return }
        guard let recorder = TerminalWindowController.frontmostStreamDebugRecorder() else {
            stopWatching()
            if snapshot != nil {
                snapshot = nil // session went away
            }
            return
        }
        if watchedRecorder !== recorder {
            stopWatching()
            watchedRecorder = recorder
            recorder.startRecording()
        }
        let next = recorder.snapshot()
        if next.chunks != snapshot?.chunks || next.totalReceivedBytes != snapshot?.totalReceivedBytes
            || next.totalSentBytes != snapshot?.totalSentBytes
        {
            snapshot = next
        }
    }

    /// Stops the recorder this view started, if any.
    private func stopWatching() {
        watchedRecorder?.stopRecording()
        watchedRecorder = nil
    }

    // MARK: - Actions

    private func clear() {
        TerminalWindowController.frontmostStreamDebugRecorder()?.reset()
        snapshot = nil
    }

    private func copy() {
        guard let snap = snapshot else { return }
        var lines: [String] = []
        lines.append("Stream Debug report")
        lines.append(
            "In: \(formatBytes(Double(snap.totalReceivedBytes)))  Out: \(formatBytes(Double(snap.totalSentBytes)))  Chunks: \(snap.chunks.count)"
        )
        lines.append("")
        for chunk in snap.chunks {
            lines.append(chunkHeaderText(chunk))
            let dump = hexDumpData(chunk.data, startOffset: 0)
            lines.append(contentsOf: dump)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Chunk rendering

    private func chunkHeader(_ chunk: StreamDebugChunk, absoluteIndex: Int) -> some View {
        HStack(spacing: 8) {
            Text(clockString(chunk.timestampMicros))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Image(systemName: chunk.direction == .received ? "arrow.down" : "arrow.up")
                .font(.caption)
                .foregroundStyle(chunk.direction == .received ? Color.green : Color.blue)
                .frame(width: 14)
            Text("\(chunk.data.count) B")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(chunk.direction == .received ? "received" : "sent")
                .font(.caption)
                .foregroundStyle(chunk.direction == .received ? Color.green : Color.blue)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func chunkHeaderText(_ chunk: StreamDebugChunk) -> String {
        let dir = chunk.direction == .received ? "↓" : "↑"
        let name = chunk.direction == .received ? "received" : "sent"
        return "\(clockString(chunk.timestampMicros)) \(dir) \(chunk.data.count) B \(name)"
    }

    private func hexDumpRows(_ chunk: StreamDebugChunk, startOffset: UInt64) -> some View {
        let data = chunk.data
        let rows = data.count / 16 + (data.count % 16 > 0 ? 1 : 0)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                hexRow(data: data, row: row, baseOffset: startOffset + UInt64(row * 16))
            }
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private func hexRow(data: Data, row: Int, baseOffset: UInt64) -> some View {
        let start = row * 16
        let end = min(start + 16, data.count)
        let slice = data[start..<end]

        return HStack(spacing: 4) {
            Text(String(format: "%08llX", baseOffset))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            // Sixteen slots unconditionally, filled or blank, with the
            // mid-column gap keyed to the slot index — a short row then holds
            // exactly the geometry of a full one, instead of drifting by one
            // gap per missing byte.
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { slot in
                    let index = start + slot
                    Text(index < data.count ? String(format: "%02X", data[data.startIndex + index]) : "")
                        .foregroundStyle(.primary)
                        .frame(width: 24, alignment: .leading)
                    if slot == 7 { Text(" ").frame(width: 8) }
                }
            }
            .frame(width: 416, alignment: .leading)
            Text(asciiRepresentation(slice))
                .foregroundStyle(.secondary)
        }
    }

    private func asciiRepresentation(_ slice: Data.SubSequence) -> String {
        slice.map { b in
            (b >= 0x20 && b <= 0x7E) ? String(Character(UnicodeScalar(b))) : "."
        }
        .joined()
    }

    private func hexDumpData(_ data: Data, startOffset: UInt64) -> [String] {
        var lines: [String] = []
        let rows = data.count / 16 + (data.count % 16 > 0 ? 1 : 0)
        for row in 0..<rows {
            let start = row * 16
            let end = min(start + 16, data.count)
            let slice = data[start..<end]
            // Sixteen slots unconditionally (see hexRow): every line is the
            // same width without a format-string pad, which %s cannot provide
            // for a Swift String anyway.
            var hex = ""
            for slot in 0..<16 {
                let index = start + slot
                hex += index < data.count ? String(format: "%02X ", data[data.startIndex + index]) : "   "
                if slot == 7 { hex += " " }
            }
            let offset = String(format: "%08llX", startOffset + UInt64(row * 16))
            lines.append("\(offset)  \(hex) \(asciiRepresentation(slice))")
        }
        return lines
    }

    private func absoluteOffset(for chunkIndex: Int) -> UInt64 {
        guard let snap = snapshot else { return 0 }
        var offset: UInt64 = 0
        for i in 0..<min(chunkIndex, snap.chunks.count) {
            offset += UInt64(snap.chunks[i].data.count)
        }
        return offset
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes < 1024 { return String(format: "%.0f B", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.2f MB", bytes / (1024 * 1024))
    }

    private func clockString(_ unixMicros: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(unixMicros) / 1_000_000.0)
        return Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
