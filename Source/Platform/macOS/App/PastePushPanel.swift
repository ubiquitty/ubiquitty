// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UniformTypeIdentifiers

/// The progress panel a pasted image shows while it crosses to the host.
///
/// A pushed paste is asynchronous — the payload crosses the wire, the host
/// lands it as a file, and only then does the path appear in the program — so
/// without this a user pressing paste sees nothing happen for as long as the
/// transfer takes.
///
/// Laid out from the system's copy-progress panel, measured off a capture of
/// it; `Scripts/compare-paste-panel.py` checks the two against each other.
/// One panel serves the app: a user pastes into one window at a time.
@objc(UBPastePushPanel)
@MainActor
public final class PastePushPanel: NSObject {
    /// The app's panel.
    @objc
    public static let shared = PastePushPanel()

    // Monospaced figures, as the system's panel sets them: the byte counter
    // would jitter under proportional ones as it counts up. Against a capture
    // of that panel, proportional figures drew the title 6pt short while the
    // digitless status line matched — which is where the difference shows.
    private static let panelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // Measured from the system's panel, in points.
    private static let panelSize = NSSize(width: 404, height: 88)
    private static let inset: CGFloat = 18
    private static let iconSide: CGFloat = 32
    private static let textLeft: CGFloat = 60
    private static let barHeight: CGFloat = 8
    // The bar is not flush with the title above it.
    private static let barLeftOffset: CGFloat = 2
    private static let iconTop: CGFloat = 40
    private static let barTop: CGFloat = 52 // below the panel's top edge
    private static let titleTop: CGFloat = 34
    private static let statusTop: CGFloat = 65
    private static let barRight: CGFloat = 371
    private static let cancelCentreX: CGFloat = 385.5
    private static let cancelCentreY: CGFloat = 56 // below the panel's top
    // The symbol carries the disc's size, not the frame: image scaling only
    // ever shrinks, so a frame alone leaves the symbol at its natural size.
    // The frame stays wider than the disc to give the pointer a target.
    private static let cancelDiscDiameter: CGFloat = 11
    private static let cancelHitDiameter: CGFloat = 22

    // How long a finished panel stays up: long enough to read the landed
    // name, short enough to be gone before the next paste.
    private static let landedDwell: TimeInterval = 1.6
    // Longer: it is the only place the reason is said.
    private static let failureDwell: TimeInterval = 4.0
    // A host without this protocol drops the frame unanswered, and
    // without this the panel would say "Sending…" for the window's life.
    private static let answerTimeout: TimeInterval = 25.0
    private static let progressInterval: TimeInterval = 1.0 / 30.0

    private var panel: NSPanel?
    private var iconView = NSImageView()
    private var titleLabel = NSTextField(labelWithString: "")
    private var statusLabel = NSTextField(labelWithString: "")
    private var bar = NSProgressIndicator()
    private var hideButton = NSButton()
    private var progressTimer: Timer?
    /// What fraction of the payload has left, asked of the sender.
    private var progressSource: (() -> Double)?
    // The dismissal in flight. A paste that starts while an earlier one is
    // still dismissing takes the panel over, and the earlier timer must not
    // then close the new paste's panel.
    private var dismissGeneration = 0

    private func buildPanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let size = Self.panelSize
        let built = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Closable and miniaturisable so those buttons exist at all: a
            // mask without them draws no buttons rather than disabled ones.
            // Zoom's absence is what greys the third one.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        built.titlebarAppearsTransparent = true
        built.titleVisibility = .hidden
        built.isMovableByWindowBackground = true
        built.hidesOnDeactivate = false
        // Nothing here needs key — no text field, no editable view — so
        // "only if needed" left it unable to become key at all, drawing its
        // buttons and bar in the grey a non-key window gets. It still never
        // takes focus on its own: it is ordered front, not made key.
        built.becomesKeyOnlyIfNeeded = false
        // The paste is about the window underneath; sinking behind it would
        // report nothing.
        built.level = .floating
        built.standardWindowButton(.zoomButton)?.isEnabled = false
        // Width only: the sheet holds one row, so a taller one is empty space.
        built.minSize = NSSize(width: 280, height: size.height)
        built.maxSize = NSSize(width: 2000, height: size.height)

        let content = built.contentView ?? NSView()
        iconView.frame = NSRect(
            x: Self.inset,
            y: size.height - Self.iconTop - Self.iconSide,
            width: Self.iconSide,
            height: Self.iconSide
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(iconView)

        let textWidth = Self.barRight - Self.textLeft

        titleLabel.frame = NSRect(x: Self.textLeft, y: size.height - Self.titleTop - 18, width: textWidth, height: 18)
        titleLabel.font = Self.panelFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(titleLabel)

        bar.frame = NSRect(
            x: Self.textLeft + Self.barLeftOffset,
            y: size.height - Self.barTop - Self.barHeight,
            width: textWidth - Self.barLeftOffset,
            height: Self.barHeight
        )
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        // Regular, not small: the small size draws a 6pt rail where the
        // system's panel has 8.
        bar.controlSize = .regular
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)

        // This hides the panel rather than cancelling: the frame is sent
        // whole and the host types the path the moment it lands, so nothing
        // here can recall it. The label says so; the glyph alone would not.
        hideButton.frame = NSRect(
            x: Self.cancelCentreX - Self.cancelHitDiameter / 2,
            y: size.height - Self.cancelCentreY - Self.cancelHitDiameter / 2,
            width: Self.cancelHitDiameter,
            height: Self.cancelHitDiameter
        )
        hideButton.bezelStyle = .circular
        hideButton.isBordered = false
        hideButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide")?
            .withSymbolConfiguration(.init(pointSize: Self.cancelDiscDiameter, weight: .regular))
        hideButton.imageScaling = .scaleProportionallyDown
        hideButton.contentTintColor = .secondaryLabelColor
        hideButton.target = self
        hideButton.action = #selector(hidePressed)
        hideButton.toolTip = "Hide this panel. The paste is on its way and can’t be recalled."
        hideButton.setAccessibilityLabel("Hide")
        hideButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(hideButton)

        statusLabel.frame = NSRect(x: Self.textLeft, y: size.height - Self.statusTop - 18, width: textWidth, height: 18)
        statusLabel.font = Self.panelFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(statusLabel)

        panel = built
        return built
    }

    /// Shows (or re-targets) the panel for a paste now crossing.
    ///
    /// - Parameters:
    ///   - destination: The machine's name; empty reads as "the host".
    ///   - mime: The payload's MIME name, which picks the document icon.
    ///   - window: The window to sit over; nil centres it on screen.
    ///   - progress: What fraction of the payload has left, 0 to 1, or a
    ///     negative answer when the sender cannot say — then the bar runs
    ///     unmeasured rather than claiming a position.
    @objc
    public func showPasting(
        toDestination destination: String,
        mime: String,
        over window: NSWindow?,
        progress: (() -> Double)?
    ) {
        let panel = buildPanelIfNeeded()
        dismissGeneration += 1 // a dismissal armed by an earlier paste no longer applies

        iconView.image = Self.documentIcon(forMIME: mime)
        let named = destination.isEmpty ? "the host" : "“\(destination)”"
        titleLabel.attributedStringValue = Self.tracked("Pasting to \(named)…", font: titleLabel.font!, colour: .labelColor)
        statusLabel.attributedStringValue = Self.tracked("Sending…", font: statusLabel.font!, colour: .secondaryLabelColor)

        progressSource = progress
        bar.isIndeterminate = progress == nil
        bar.doubleValue = 0
        if progress == nil {
            bar.startAnimation(nil)
        } else {
            startProgressPolling()
        }

        if let window {
            // Over the window's upper third, where a sheet would sit: the
            // paste belongs to this session, not to the screen.
            let frame = window.frame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - Self.panelSize.width / 2,
                    y: frame.maxY - Self.panelSize.height - frame.height * 0.18
                )
            )
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()

        // Nothing else retires the panel if the host never answers.
        let generation = dismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            self.finishFailed(reason: "The host didn’t answer. It may be running an older ubiquitty-host; update it, then try again.")
        }
    }

    /// Reports the paste landed and dismisses shortly after.
    ///
    /// - Parameter path: The host path it landed at; the last component is
    ///   what the status line names.
    @objc
    public func finishLanded(atPath path: String) {
        guard panel != nil else { return }
        stopProgressPolling()
        bar.isIndeterminate = false
        bar.doubleValue = bar.maxValue // the payload is all the way there
        let name = (path as NSString).lastPathComponent
        statusLabel.attributedStringValue = Self.tracked(
            name.isEmpty ? "Pasted" : "Pasted as \(name)",
            font: statusLabel.font!,
            colour: .secondaryLabelColor
        )
        dismiss(after: Self.landedDwell)
    }

    /// Reports the paste did not land and dismisses shortly after.
    ///
    /// - Parameter reason: A short user-facing sentence.
    @objc
    public func finishFailed(reason: String) {
        guard panel != nil else { return }
        stopProgressPolling()
        statusLabel.attributedStringValue = Self.tracked(
            reason.isEmpty ? "The paste didn’t reach the host. Try again." : reason,
            font: statusLabel.font!,
            colour: .secondaryLabelColor
        )
        dismiss(after: Self.failureDwell)
    }

    @objc
    private func hidePressed() { dismissNow() }

    /// One line of the panel's text.
    ///
    /// No kerning attribute: the interface font tracks its own letters wider
    /// at these sizes, and setting one — including zero — replaces that with
    /// a flat value. Measured against the system's panel, a flat zero drew
    /// the title 4% narrow.
    ///
    /// - Parameters:
    ///   - text: The line.
    ///   - font: The face to set it in.
    ///   - colour: The ink.
    /// - Returns: The string to hand a label.
    private static func tracked(_ text: String, font: NSFont, colour: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: colour,
            ]
        )
    }

    /// Shows the panel with content chosen by the caller, for the pixel
    /// comparison against the system's panel.
    ///
    /// The product derives its title and status from the paste. The
    /// comparison needs the reference's exact strings, or the two panels
    /// differ over glyphs rather than layout.
    ///
    /// - Parameters:
    ///   - title: The title line, verbatim.
    ///   - status: The status line, verbatim.
    ///   - mime: Picks the document icon.
    ///   - fraction: Where the bar sits, 0 to 1.
    @objc
    public func showForVisualCheck(title: String, status: String, mime: String, fraction: Double) {
        let panel = buildPanelIfNeeded()
        dismissGeneration += 1
        stopProgressPolling()
        progressSource = nil
        iconView.image = Self.documentIcon(forMIME: mime)
        titleLabel.attributedStringValue = Self.tracked(title, font: titleLabel.font!, colour: .labelColor)
        statusLabel.attributedStringValue = Self.tracked(status, font: statusLabel.font!, colour: .secondaryLabelColor)
        bar.isIndeterminate = false
        bar.doubleValue = min(max(fraction, 0), 1)
        panel.center()
        panel.orderFrontRegardless()
    }

    /// The panel's window number, for a visual check that captures it.
    ///
    /// - Returns: The number, or 0 before the panel has been built.
    @objc
    public func windowNumberForVisualCheck() -> Int {
        panel?.windowNumber ?? 0
    }

    /// Takes key, for a capture that wants the active appearance — the
    /// buttons and bar draw grey until something is key. The product never
    /// calls it: a paste must not pull focus off what the user is typing.
    @objc
    public func makeKeyForVisualCheck() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// What the window says about its own focus, for diagnosing why it will
    /// not take it.
    @objc
    public func focusReportForVisualCheck() -> String {
        guard let panel else { return "no panel" }
        return "title font=\(titleLabel.font?.fontName ?? "none") "
            + "advance=\(titleLabel.font.map { "\(($0 as NSFont).advancement(forGlyph: NSGlyph(68)).width)" } ?? "?") "
            + "app active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
            + "canBecomeKey=\(panel.canBecomeKey) isKey=\(panel.isKeyWindow) "
            + "becomesKeyOnlyIfNeeded=\(panel.becomesKeyOnlyIfNeeded) "
            + "floatingPanel=\(panel.isFloatingPanel) level=\(panel.level.rawValue) "
            + "styleMask=\(panel.styleMask.rawValue) visible=\(panel.isVisible)"
    }

    /// Hides the panel now — a window closing under a paste in flight.
    @objc
    public func dismissNow() {
        dismissGeneration += 1
        stopProgressPolling()
        panel?.orderOut(nil)
    }

    /// The icon Finder draws for a file of that MIME type, so the panel shows
    /// what the landed file will look like. An unknown type falls back to the
    /// plain document.
    ///
    /// - Parameter mime: The payload's MIME name, parameters ignored.
    /// - Returns: The system icon for that type.
    static func documentIcon(forMIME mime: String) -> NSImage {
        let bare = mime.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mime
        let type = UTType(mimeType: bare) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private func startProgressPolling() {
        stopProgressPolling()
        progressTimer = Timer.scheduledTimer(withTimeInterval: Self.progressInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let source = self.progressSource else { return }
                let fraction = source()
                if fraction < 0 {
                    // The sender stopped being able to say. Freezing at the
                    // last position would claim a number nothing stands behind.
                    self.bar.isIndeterminate = true
                    self.progressTimer?.invalidate()
                    self.progressTimer = nil
                    self.bar.startAnimation(nil)
                    return
                }
                self.bar.doubleValue = min(max(fraction, 0), 1)
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
        bar.stopAnimation(nil)
    }

    private func dismiss(after seconds: TimeInterval) {
        dismissGeneration += 1
        let generation = dismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            // A paste that started since owns the panel now.
            if self.dismissGeneration == generation {
                self.dismissNow()
            }
        }
    }
}
