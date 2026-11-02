// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// ChromeAccessoryBar.swift — the row of small indicators a window, a tab or a
// pane wears at its trailing edge: the Secure Keyboard Entry lock, the build
// identity of a development build, the broadcast-input and tmux pills.
//
// One bar per scope lays its accessories out from the trailing edge inward,
// highest priority nearest the edge, so an indicator that appears moves its
// neighbours rather than covering them. The window
// scope wraps it in a titlebar accessory, a tab or a pane hosts it as a
// subview of its own chrome.
//
import AppKit

/// Shared geometry for the title row's compact status symbols.
@MainActor
enum ChromeAccessorySymbol {
    static let viewSize = NSSize(width: 18, height: 18)
    static let imageSize = NSSize(width: 16, height: 16)

    /// Fits a symbol into a centered canvas, independent of its font metrics.
    static func image(named name: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        let scale = 14 / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let result = NSImage(size: imageSize, flipped: false) { bounds in
            symbol.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2,
                    y: bounds.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            )
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = description
        return result
    }
}

/// Centers compact button images without the standard button cell's title insets.
@MainActor
final class ChromeAccessorySymbolButtonCell: NSButtonCell {
    override func imageRect(forBounds bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.midX - ChromeAccessorySymbol.imageSize.width / 2,
            y: bounds.midY - ChromeAccessorySymbol.imageSize.height / 2,
            width: ChromeAccessorySymbol.imageSize.width,
            height: ChromeAccessorySymbol.imageSize.height
        )
    }
}

/// Where a bar lives, which decides what it speaks for.
@objc(UBChromeAccessoryScope)
public enum ChromeAccessoryScope: Int {
    /// The title bar's trailing edge: facts about the window, every tab.
    case window
    /// A tab's own cell in the strip: facts about that tab.
    case tab
    /// A pane's top-trailing corner, over its grid: facts about that pane.
    case pane
}

/// A trailing-aligned row of indicator views.
@objc(UBChromeAccessoryBar)
public final class ChromeAccessoryBar: NSVisualEffectView {
    /// The scope the bar speaks for.
    @objc
    public let scope: ChromeAccessoryScope

    /// The gap between neighbouring accessories, in points.
    @objc
    public static let gapInPoints: CGFloat = 8

    /// The inset between the trailing accessory and the bar's trailing edge.
    @objc
    public static let trailingInsetInPoints: CGFloat = 9

    /// The title row's height, the bar's height in the window scope.
    @objc
    public static let titleRowHeightInPoints: CGFloat = 28

    /// The narrowest a compressible accessory is shown at; below it the
    /// ellipsis would be most of what is left, so it gives up its place.
    @objc
    public static let minCompressedWidthInPoints: CGFloat = 40

    private struct Entry {
        let view: NSView
        let priority: Int
        let isCompressible: Bool
    }

    private var entries: [Entry] = []
    private let heightInPoints: CGFloat
    private var windowResizeObserver: NSObjectProtocol?

    /// Makes an empty bar.
    ///
    /// - Parameters:
    ///   - scope: Where the bar lives.
    ///   - heightInPoints: The bar's height; accessories centre in it.
    @objc
    public init(scope: ChromeAccessoryScope, heightInPoints: CGFloat) {
        self.scope = scope
        self.heightInPoints = heightInPoints
        super.init(frame: NSRect(x: 0, y: 0, width: ChromeAccessoryBar.trailingInsetInPoints, height: heightInPoints))
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        // The titlebar owns the background; this material supplies only the
        // semantic compositing environment for its accessory controls.
        maskImage = NSImage(size: NSSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChromeAccessoryBar is built in code")
    }

    /// Adds an accessory, sized by its own frame.
    ///
    /// - Parameters:
    ///   - view: The indicator; its frame's size is kept, its origin is the bar's.
    ///   - priority: Higher sits nearer the trailing edge.
    @objc
    public func add(_ view: NSView, priority: Int) {
        add(view, priority: priority, isCompressible: false)
    }

    /// Adds an accessory that gives up width when the row has too little.
    ///
    /// A compressible accessory is measured by its fitting size rather than
    /// its frame, and is narrowed — a text field truncates — so the row ends
    /// before the window buttons at the title row's leading edge. Only a
    /// sentence may be compressed: a badge cut short says nothing.
    ///
    /// - Parameters:
    ///   - view: The accessory.
    ///   - priority: Higher sits nearer the trailing edge.
    ///   - isCompressible: Whether the row may narrow it.
    public func add(_ view: NSView, priority: Int, isCompressible: Bool) {
        entries.append(Entry(view: view, priority: priority, isCompressible: isCompressible))
        entries.sort { $0.priority > $1.priority }
        addSubview(view)
        relayout()
    }

    /// Shows or hides an accessory and closes the gap it leaves.
    ///
    /// - Parameters:
    ///   - view: An accessory added earlier.
    ///   - isShown: Whether it takes part in the row.
    @objc
    public func setShown(_ view: NSView, _ isShown: Bool) {
        guard view.isHidden == isShown else { return }
        view.isHidden = !isShown
        relayout()
    }

    /// Re-measures a resized accessory and places the row again.
    @objc
    public func relayout() {
        let shown = entries.filter { !$0.view.isHidden }
        var widths = shown.map { $0.isCompressible ? $0.view.fittingSize.width.rounded(.up) : $0.view.frame.width }
        func rowWidth() -> CGFloat {
            let placed = widths.filter { $0 > 0 }
            return placed.reduce(0, +) + CGFloat(max(placed.count - 1, 0)) * ChromeAccessoryBar.gapInPoints
                + ChromeAccessoryBar.trailingInsetInPoints
        }
        if let limit = availableWidth() {
            for index in shown.indices.reversed() where shown[index].isCompressible && rowWidth() > limit {
                let narrowed = widths[index] - (rowWidth() - limit)
                widths[index] = narrowed >= ChromeAccessoryBar.minCompressedWidthInPoints ? narrowed : 0
            }
        }
        let width = rowWidth()
        var trailing = width - ChromeAccessoryBar.trailingInsetInPoints
        for (entry, entryWidth) in zip(shown, widths) {
            let height = entry.view.frame.height
            guard entryWidth > 0 else {
                // Too narrow to say anything: out of the row, without
                // touching whether its owner wants it shown.
                entry.view.frame = NSRect(x: 0, y: 0, width: 0, height: height)
                continue
            }
            trailing -= entryWidth
            entry.view.frame = NSRect(
                x: trailing,
                y: ((heightInPoints - height) / 2).rounded() + 2,
                width: entryWidth,
                height: height
            )
            trailing -= ChromeAccessoryBar.gapInPoints
        }
        setFrameSize(NSSize(width: width, height: heightInPoints))
        invalidateIntrinsicContentSize()
        // A titlebar accessory is sized by its view's frame; the title row
        // lays out again when told the frame moved.
        window?.layoutIfNeeded()
    }

    /// The widest the row may be before it reaches the window buttons.
    ///
    /// A trailing titlebar accessory grows leftward, and AppKit does not stop
    /// it at the close, minimise and zoom buttons: a row wider than the room
    /// after them is drawn over them. Only the window scope shares its row
    /// with those buttons.
    ///
    /// - Returns: The width, or nil outside a window's title row.
    private func availableWidth() -> CGFloat? {
        guard scope == .window, let window else { return nil }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let leadingEdge =
            buttonTypes.compactMap { type -> CGFloat? in
                guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
                return button.convert(button.bounds, to: nil).maxX
            }
            .max() ?? 0
        return max(window.frame.width - leadingEdge - ChromeAccessoryBar.gapInPoints, 0)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
            self.windowResizeObserver = nil
        }
        guard scope == .window, let window else { return }
        // The room after the window buttons is the window's width, so a
        // resize is a new limit for the row.
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        relayout()
    }

    override public var intrinsicContentSize: NSSize {
        frame.size
    }

    /// Wraps the bar for a window's title row, trailing edge.
    ///
    /// - Returns: The accessory to add to the window.
    @objc
    public func makeTitlebarAccessory() -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = self
        accessory.layoutAttribute = .right
        return accessory
    }
}
