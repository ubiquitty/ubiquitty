// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AdaptiveDriveDebugWindowController — hosts the "Adaptive Drive" debug window:
// a 10 Hz readout of the frontmost terminal's frame driver (the panel interval it
// measures against, what it recommends, what the link is doing, frames
// presented), a strip chart of presents per second over the last ten seconds
// with the link's mode as its ground, and a log of mode transitions. Floats like
// the Stream Debug window and follows the frontmost terminal the same way.

import AppKit
import Combine
import SwiftUI

/// One poll of the readout.
private struct DriveSample {
    let time: TimeInterval
    let presentsPerSecond: Double
    let isLinkContinuous: Bool
}

/// One mode edge, for the log.
private struct DriveTransition: Identifiable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct AdaptiveDriveDebugView: View {
    let refresh: AnyPublisher<Void, Never>
    let factsProvider: @MainActor () -> AdaptiveDriveFacts?
    @State
    private var facts: AdaptiveDriveFacts?
    @State
    private var samples: [DriveSample] = []
    @State
    private var transitions: [DriveTransition] = []
    /// (time, frames presented) history the rate is read off, over rateWindow.
    @State
    private var frameHistory: [(TimeInterval, Int)] = []
    @State
    private var sampledSurfaceIdentity: Int?
    @State
    private var lastMode: (link: Bool, recommended: Bool)?
    @State
    private var openedAt: TimeInterval = Date().timeIntervalSince1970

    private static let chartSeconds: TimeInterval = 10
    private static let rateWindow: TimeInterval = 0.5
    private static let logLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
            log
        }
        .padding(12)
        .font(.system(.body, design: .monospaced))
        .onReceive(refresh) { _ in poll() }
    }

    @ViewBuilder
    private var header: some View {
        if let facts {
            let hz = facts.frameIntervalSeconds > 0 ? String(format: "%.0f Hz", 1 / facts.frameIntervalSeconds) : "unsourced"
            let rate = samples.last.map { String(format: "%.1f", $0.presentsPerSecond) } ?? "—"
            HStack(spacing: 16) {
                Text("arm \(facts.arm)")
                Text("adaptive \(facts.isAdaptive ? "ON" : "OFF")")
                    .foregroundStyle(facts.isAdaptive ? Color.green : Color.secondary)
                Text("panel \(hz)")
                Text("link \(facts.isLinkContinuous ? "CONTINUOUS" : "PARKED")")
                    .foregroundStyle(facts.isLinkContinuous ? Color.orange : Color.blue)
                Text("recommends \(facts.isRecommendedContinuous ? "continuous" : "on-demand")")
                Text("streak \(facts.fastDrainStreak)")
                Text("presents/s \(rate)")
                Text("presented \(facts.framesPresented)")
                Text("draws \(facts.framesDrawn)")
            }
        } else {
            Text("No terminal window in front")
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Canvas { context, size in
            guard let last = samples.last else { return }
            let span = Self.chartSeconds
            let peak = max(1, samples.map(\.presentsPerSecond).max() ?? 1)
            func x(_ time: TimeInterval) -> CGFloat {
                CGFloat((time - (last.time - span)) / span) * size.width
            }
            // Ground: the link's mode per sample, continuous in orange, parked in blue.
            for (index, sample) in samples.enumerated() {
                let next = index + 1 < samples.count ? samples[index + 1].time : last.time + 0.1
                let rect = CGRect(x: x(sample.time), y: 0, width: max(1, x(next) - x(sample.time)), height: size.height)
                context.fill(Path(rect), with: .color((sample.isLinkContinuous ? Color.orange : Color.blue).opacity(0.15)))
            }
            var line = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: x(sample.time), y: size.height - CGFloat(sample.presentsPerSecond / peak) * (size.height - 4) - 2)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(.primary), lineWidth: 1.5)
            context.draw(Text(String(format: "%.0f/s", peak)).font(.caption), at: CGPoint(x: 24, y: 8))
        }
    }

    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(transitions.reversed()) { transition in
                    Text(String(format: "+%7.2fs  %@", transition.time - openedAt, transition.text))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func poll() {
        let now = Date().timeIntervalSince1970
        guard let current = factsProvider() else {
            facts = nil
            frameHistory.removeAll()
            sampledSurfaceIdentity = nil
            return
        }
        if sampledSurfaceIdentity != current.surfaceIdentity {
            frameHistory.removeAll()
            sampledSurfaceIdentity = current.surfaceIdentity
        }
        // A frontmost change hands over another surface's counter: a drop
        // restarts the history rather than reading as a negative rate.
        if let last = frameHistory.last, current.framesPresented < last.1 {
            frameHistory.removeAll()
        }
        frameHistory.append((now, current.framesPresented))
        frameHistory.removeAll { now - $0.0 > Self.rateWindow }
        var perSecond = 0.0
        if let first = frameHistory.first, now > first.0 {
            perSecond = Double(current.framesPresented - first.1) / (now - first.0)
        }
        samples.append(DriveSample(time: now, presentsPerSecond: perSecond, isLinkContinuous: current.isLinkContinuous))
        samples.removeAll { now - $0.time > Self.chartSeconds }
        let mode = (link: current.isLinkContinuous, recommended: current.isRecommendedContinuous)
        if let last = lastMode, last != mode {
            let text =
                "link \(mode.link ? "CONTINUOUS" : "PARKED"), recommends \(mode.recommended ? "continuous" : "on-demand"), streak \(current.fastDrainStreak)"
            transitions.append(DriveTransition(id: transitions.count, time: now, text: text))
            if transitions.count > Self.logLimit {
                transitions.removeFirst(transitions.count - Self.logLimit)
            }
        }
        lastMode = mode
        facts = current
    }
}

/// Samples the frontmost terminal while its diagnostic window is visible.
@objc(UBAdaptiveDriveDebugWindowController)
@MainActor
public final class AdaptiveDriveDebugWindowController: NSWindowController, NSWindowDelegate {
    private let refresh: PassthroughSubject<Void, Never>
    private var refreshTimer: Timer?

    /// Returns the frontmost terminal window's readout.
    ///
    /// Walks the z-order
    /// so the floating debug window being key still names the terminal the
    /// user was on.
    static func frontmostFacts() -> AdaptiveDriveFacts? {
        for window in NSApp.orderedWindows {
            if let group = window.tabGroup, group.selectedWindow !== window {
                continue
            }
            if let facts = TerminalWindowController.adaptiveDriveFacts(for: window) {
                return facts
            }
        }
        return nil
    }

    /// Creates a diagnostic window for the frontmost terminal.
    @objc
    public convenience init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window, factsProvider: Self.frontmostFacts)
    }

    /// Creates a diagnostic hosted in a window with a supplied readout source.
    ///
    /// - Parameters:
    ///   - window: The retained diagnostic window.
    ///   - factsProvider: The source sampled while the window is visible.
    package init(window: NSWindow, factsProvider: @escaping @MainActor () -> AdaptiveDriveFacts?) {
        let refresh = PassthroughSubject<Void, Never>()
        self.refresh = refresh
        window.contentViewController = NSHostingController(
            rootView: AdaptiveDriveDebugView(refresh: refresh.eraseToAnyPublisher(), factsProvider: factsProvider)
        )
        window.title = "Adaptive Drive"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 900, height: 420))
        window.setFrameAutosaveName("UBAdaptiveDriveDebugWindow")
        window.level = .floating
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        refreshTimer?.invalidate()
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        updatePolling()
    }

    /// Stops sampling before the retained window closes.
    ///
    /// - Parameter notification: The window's close notification.
    public func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    /// Stops sampling when the window is minimized.
    ///
    /// - Parameter notification: The window's miniaturization notification.
    public func windowDidMiniaturize(_ notification: Notification) {
        stopPolling()
    }

    /// Resumes sampling when the restored window is visible.
    ///
    /// - Parameter notification: The window's restoration notification.
    public func windowDidDeminiaturize(_ notification: Notification) {
        updatePolling()
    }

    /// Matches sampling to the window's compositor visibility.
    ///
    /// - Parameter notification: The window's occlusion notification.
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        updatePolling()
    }

    private var canSampleWindow: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func updatePolling() {
        guard canSampleWindow else {
            stopPolling()
            return
        }
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollIfVisible()
            }
        }
        timer.tolerance = 0.02
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh.send(())
    }

    private func pollIfVisible() {
        guard canSampleWindow else {
            stopPolling()
            return
        }
        refresh.send(())
    }

    private func stopPolling() {
        // The controller retains its hosting view between openings, so closing
        // the window must release the run-loop source independently of SwiftUI.
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
