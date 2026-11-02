// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// PasswordPromptBadge.swift — the lock a surface shows beside a password
// prompt while the model believes one is on screen (private mode 7401, or
// the [security] password_detect heuristic settled on a prompt row).
//
// The system lock symbol, sized to the row and set after the caret —
// "Password: ▌🔒" — the way a password field carries its affordance at the
// trailing edge: the caret keeps its place and its blink, the one element
// that says where typing goes, and the lock stands still beside it in a
// secondary tint, saying what happens to the typing — not echoed and, while
// the app holds Secure Keyboard Entry, not observable by other processes. The
// title bar's own lock speaks for the process; this one speaks for the
// prompt. Shown and hidden with a short fade; the pane's content never moves
// for it.
//
import AppKit

/// The lock beside a password prompt.
///
/// Exported to Objective-C for the ObjC++ shell's view, which shows the same
/// glyph for the same fact; one type, so the two shells cannot drift apart.
@objc(UBPasswordPromptBadge)
public final class PasswordPromptBadge: NSView {
    private let symbol = NSImageView()
    private var foreground = NSColor.labelColor

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        symbol.imageScaling = .scaleProportionallyDown
        symbol.imageAlignment = .alignLeft
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalTo: widthAnchor),
            symbol.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Password prompt: typing is hidden")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PasswordPromptBadge is built in code")
    }

    /// Tints the glyph from the pane's text colour.
    ///
    /// - Parameter foreground: The default foreground, the symbol's tint.
    @objc
    public func apply(foreground: NSColor) {
        self.foreground = foreground
        symbol.contentTintColor = foreground.withAlphaComponent(0.5)
    }

    /// Fits the glyph to the row, starting at a cell.
    ///
    /// The symbol takes the row's height and as much width as it needs — up
    /// to two cells, which a narrow face's cell would otherwise squeeze it
    /// below legibility; the cells after the cursor are blank at a prompt.
    ///
    /// - Parameter cell: The cell after the cursor, in the pane's coordinates.
    @objc
    public func place(in cell: NSRect) {
        // A hair off the cursor's block, and a point size the symbol's cap
        // height turns into roughly two thirds of the row.
        let gap = (cell.width * 0.25).rounded()
        frame = NSRect(x: cell.minX + gap, y: cell.minY, width: cell.width * 2, height: cell.height)
        let configuration = NSImage.SymbolConfiguration(pointSize: (cell.height * 0.9).rounded(), weight: .semibold)
        symbol.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Password prompt")?
            .withSymbolConfiguration(configuration)
    }

    /// Shows or hides the badge with a fade.
    ///
    /// - Parameter isShown: Whether a password prompt is on screen.
    @objc
    public func setShown(_ isShown: Bool) {
        guard isShown != !isHidden || (isShown && alphaValue < 1) else { return }
        if isShown {
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.15
                animator().alphaValue = isShown ? 1 : 0
            },
            completionHandler: { [weak self] in
                // NSAnimationContext completion handlers run on the main thread.
                MainActor.assumeIsolated {
                    guard let self, !isShown, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            }
        )
    }

    /// Draws the badge as shown into a context whose user space is the
    /// badge's own bounds in points, origin at its bottom-left.
    ///
    /// The snapshot arm renders the Metal frame alone and the glyph lives over
    /// it as a view, so a golden that shows the lock composites it through
    /// this — the same view, displayed off-screen, not a second drawing of it.
    ///
    /// - Parameters:
    ///   - context: The target, already translated to the badge's origin.
    ///   - contentScale: Device pixels per point, so the cached display is
    ///     rasterised at the frame's own density.
    @objc
    public func drawAsShown(into context: CGContext, contentScale: CGFloat) {
        layoutSubtreeIfNeeded()
        guard
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((bounds.width * contentScale).rounded(.up)),
                pixelsHigh: Int((bounds.height * contentScale).rounded(.up)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return }
        representation.size = bounds.size
        cacheDisplay(in: bounds, to: representation)
        guard let image = representation.cgImage else { return }
        context.draw(image, in: bounds)
    }
}
