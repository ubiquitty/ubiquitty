// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore

/// The tag a host chip wears as its capsule.
///
/// Which tag that is belongs to the caller: the window's first coloured rule
/// tag, since a rule is a fact about the machine where a name typed on one
/// window is not.
package struct HostChipTag: Equatable {
    /// The capsule's fill, opaque.
    package var fill: NSColor
    /// The title the capsule writes after the machine's name: empty for an
    /// untitled tag, and for one whose rule hides its name.
    package var title: String
    /// What a screen reader speaks for the tag: its title, or for an untitled
    /// tag Core's `Session::tagSpokenName`.
    package var spokenName: String
    /// The Phosphor icon drawn in place of the place's symbol, empty for none.
    package var iconName: String
    /// The weight the icon is drawn in.
    package var iconWeight: Ubiquitty.Session.TagIconWeight

    /// Makes the tag a host chip wears.
    ///
    /// - Parameters:
    ///   - fill: The capsule's fill, opaque.
    ///   - title: The tag's title, empty for an untitled tag.
    ///   - spokenName: What a screen reader speaks for the tag.
    ///   - iconName: The Phosphor icon, empty for none.
    ///   - iconWeight: The weight the icon is drawn in.
    package init(fill: NSColor, title: String, spokenName: String, iconName: String, iconWeight: Ubiquitty.Session.TagIconWeight) {
        self.fill = fill
        self.title = title
        self.spokenName = spokenName
        self.iconName = iconName
        self.iconWeight = iconWeight
    }
}

/// Names the host once in the title row, with Core's link health beside it.
///
/// The passive view has no button bezel or click action. Transport is drawn
/// with the platform's filled or outline globe and stated explicitly, with
/// link status, in the tooltip and accessibility description.
///
/// Untagged, the host name stays in native secondary ink while the connection
/// changes state, and a link that is not steady tints the symbol. Wearing a
/// tag, the chip is that tag's capsule: the tag's colour fills it, at the
/// strength the row lays tag colours down at, whatever the link is doing, so a
/// marker on a machine that matters cannot drop out during a reconnect; the
/// tag's icon stands in the symbol's place; and a link that is not steady
/// shows as a flag-coloured dot ringed in the capsule's ink at the symbol's
/// corner, because a flag colour laid on an arbitrary fill can vanish into it.
///
/// The capsule is the last pill of the title row's tag stack, on top: its
/// typography, height and centre line are ``TitlebarCapsuleGeometry``'s, and
/// the title places it over the stack's last pill by the geometry's overlap.
/// Its ink is one concrete colour, ``TitlebarTagChip/ink(onFill:style:appearance:)``,
/// for the name, the tag's title, the divider and the icon alike.
@MainActor
package final class RemoteConnectionIndicator: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// The tag's title, after the machine's name inside the capsule.
    private let tagLabel = NSTextField(labelWithString: "")
    /// The link's state on a capsule, where the symbol's tint cannot carry it.
    private let statusDot = LinkStatusDot(frame: .zero)
    private weak var titleWindow: NSWindow?
    /// Reconciles the title's reserved span after the indicator changes size or visibility.
    package var presentationDidChange: (() -> Void)?
    /// Draws a tag's icon; while nil, the place's symbol stands in the
    /// capsule.
    package var tagIconDrawing: TitlebarTagIconDrawing? {
        didSet { redrawPresentation() }
    }
    private var presentation: Presentation?
    private var symbolName = ""
    /// The square the place's symbol was fitted into.
    private var fittedSymbolSide: CGFloat = 0
    /// The tag's icon the chip draws, empty while the place's symbol stands.
    private var tagIconName = ""
    /// What the drawn tag icon was drawn from, so a redraw with the same
    /// name, weight, side and ink keeps the image it has.
    private var tagIconKey = ""
    /// The ink the tag's icon was drawn in, nil while the place's symbol
    /// stands.
    private var tagIconInk: NSColor?
    /// The tag's colour the capsule is filled with, nil for the plain chip.
    private var capsuleFill: NSColor?
    /// The opacity the capsule's fill is drawn at.
    private var capsuleFillOpacity: CGFloat = 1
    /// The ink that reads on the capsule's fill: everything the capsule holds
    /// is drawn in it, and the outline and the hairline it draws itself.
    private var capsuleInk: NSColor = .labelColor
    /// Whether the capsule is outlined: the row under it is washed in its own
    /// colour, and a capsule of the wash's colour on the wash is not there.
    private var hasCapsuleBorder = false
    /// The hairline between the machine's name and the tag's title, nil when
    /// the tag has no title.
    private var dividerFrame: NSRect?
    /// Where the capsule's last text ends, from which its trailing padding is
    /// counted.
    private var capsuleTextEnd: CGFloat = 0
    /// Where the machine's name starts inside the capsule, as text rather than
    /// as its field's frame.
    private var capsuleNameStart: CGFloat = 0

    /// What the chip was last told, kept to redraw it for a new appearance.
    private struct Presentation {
        var place: Ubiquitty.Session.HostPlace
        var health: Ubiquitty.Session.Health
        var host: String
        var carrier: String
        var isShared: Bool
        var hostTag: HostChipTag?
        var titlebarWash: NSColor?
        var tagStyle: TitlebarTagStyle
    }

    /// The gap between the symbol and the host, in points.
    private static let gapInPoints: CGFloat = 4

    /// The air either side of the hairline between the machine's name and the
    /// tag's title, in points.
    private static let dividerGapInPoints: CGFloat = 6

    /// The widest the tag's title is drawn inside the capsule.
    private static let maxTagTitleWidthInPoints: CGFloat = 140

    /// The narrowest the tag's title is cut to before the machine's name
    /// gives way.
    private static let minTagTitleWidthInPoints: CGFloat = 32

    /// The capsule's outline over a wash of its own colour: enough to find the
    /// edge, faint enough not to read as a control.
    private static let capsuleBorderAlpha: CGFloat = 0.35

    /// The hairline between the name and the title, quieter than either.
    private static let dividerAlpha: CGFloat = 0.4

    /// How far apart, per sRGB component, a wash and a fill may be and still
    /// read as one colour.
    private static let washMatchTolerance: CGFloat = 0.1

    /// The face the host's name is set in: the title's, once the title has
    /// named it.
    private var titleFont: NSFont { label.font ?? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }

    /// The square the bare chip fits the place's symbol into: a little over
    /// the title's point size, so the globe keeps about its own size and a
    /// wider symbol, such as the desktop, is drawn no wider than the globe.
    ///
    /// - Parameter font: The title's font.
    /// - Returns: The square's side, in points.
    package static func symbolSide(forTitleFont font: NSFont) -> CGFloat {
        ceil(font.pointSize + 2)
    }

    /// The pixels per point the chip is drawn at.
    private var backingScale: CGFloat {
        (window ?? titleWindow)?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// The widest the host's name is drawn, however wide the window.
    private static let maxLabelWidthInPoints: CGFloat = 220

    /// The narrowest the host's name is cut to: below it the ellipsis would
    /// be most of what is left.
    private static let minLabelWidthInPoints: CGFloat = 48

    /// The share of the window's width the chip may take from the title row.
    private static let windowShare: CGFloat = 0.4

    /// How wide the whole chip may be in a window this wide.
    ///
    /// - Parameters:
    ///   - width: The window's width, nil before the chip is in one.
    ///   - floor: The narrowest the chip's layout can be cut to.
    /// - Returns: The chip's budget, in points.
    private func widthBudget(forWindowWidth width: CGFloat?, floor: CGFloat) -> CGFloat {
        guard let width else { return .greatestFiniteMagnitude }
        return max(width * Self.windowShare, floor)
    }

    /// The window-resize observation that re-measures the chip, since its
    /// budget is a share of the window's width.
    private var windowResizeObserver: NSObjectProtocol?

    /// What this Mac's own daemon is called in the chrome, whatever its row in
    /// the Connect window is named: the reader is asking which machine, and
    /// the answer for the daemon beside them is this one.
    package static let thisMacName = "This Mac"

    package init(window: NSWindow) {
        titleWindow = window
        super.init(frame: .zero)
        // Every image the icon shows is made at the size it is drawn.
        icon.imageScaling = .scaleNone
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        tagLabel.font = label.font
        tagLabel.lineBreakMode = .byTruncatingTail
        tagLabel.maximumNumberOfLines = 1
        tagLabel.isHidden = true
        statusDot.isHidden = true
        label.setAccessibilityElement(false)
        tagLabel.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(icon)
        addSubview(label)
        addSubview(tagLabel)
        // Over the symbol, whose corner it marks.
        addSubview(statusDot)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("RemoteConnectionIndicator is built in code") }

    /// Matches the field that contains this indicator, including changes to native title typography.
    /// - Parameter font: The adjacent title's actual font.
    package func setTitleFont(_ font: NSFont) {
        guard label.font != font else { return }
        label.font = font
        tagLabel.font = font
        // The place's symbol is configured from the font, so it is made again.
        symbolName = ""
        redrawPresentation()
    }

    /// Distance from this unflipped view's bottom edge to its host label's baseline.
    package var hostLabelBaselineOffsetFromBottom: CGFloat {
        let baseline = label.isFlipped ? label.firstBaselineOffsetFromTop : label.bounds.height - label.firstBaselineOffsetFromTop
        return convert(NSPoint(x: 0, y: baseline), from: label).y
    }

    /// The name the chrome gives a host: this Mac's daemon by its place, any
    /// other by its label.
    ///
    /// - Parameter host: Core's answer for where the session lives.
    /// - Returns: The name, empty for a plain local shell.
    package static func hostName(of host: Ubiquitty.Session.PaneHost) -> String {
        hostName(place: host.place, host: String(host.label))
    }

    /// The name the chrome gives a host: this Mac's daemon by its place, any
    /// other by its label.
    ///
    /// - Parameters:
    ///   - place: Where the session lives.
    ///   - host: The destination's label; empty falls back to "remote".
    /// - Returns: The name, empty for a plain local shell.
    package static func hostName(place: Ubiquitty.Session.HostPlace, host: String) -> String {
        switch place {
        case .None:
            return ""
        case .ThisMachine:
            return thisMacName
        case .Remote:
            return host.isEmpty ? "remote" : host
        @unknown default:
            return host
        }
    }

    /// Draws the chip for one host and one link state, or takes it down for a
    /// plain local shell.
    ///
    /// - Parameters:
    ///   - place: Where the window's session lives, Core's
    ///     ``Ubiquitty/Session/hostPlaceFor(_:)``.
    ///   - health: Core's link state, which a caller holding a connection phase
    ///     folds with ``Ubiquitty/Session/healthFor(_:)``.
    ///   - host: The destination's label; empty falls back to "remote".
    ///   - carrier: How the bytes get there, as Core names it (`quic`, `ssh`,
    ///     `mosh`). The tooltip always states the supplied transport.
    ///   - isShared: Whether the session is a local shell this window shared
    ///     into this Mac's daemon, which the chip says beside the name.
    ///   - hostTag: The tag the chip wears as its capsule; nil draws the plain
    ///     chip in the chrome's own ink.
    ///   - titlebarWash: The colour a loud tag washes the title row with, nil
    ///     for none; a capsule of that colour is outlined to stay visible on it.
    ///   - tagStyle: How the row lays a tag's colour down: the strength the
    ///     capsule's fill is drawn at, and what its ink is chosen against.
    package func update(
        place: Ubiquitty.Session.HostPlace,
        health: Ubiquitty.Session.Health,
        host: String,
        carrier: String,
        isShared: Bool = false,
        hostTag: HostChipTag? = nil,
        titlebarWash: NSColor? = nil,
        tagStyle: TitlebarTagStyle = .fullStrength
    ) {
        let previousSize = frame.size
        let wasHidden = isHidden
        let previousDescription = accessibilityLabel()
        let chip = Ubiquitty.Session.hostChipFor(place, health)
        guard chip.isShown else {
            withdraw()
            return
        }
        presentation = Presentation(
            place: place,
            health: health,
            host: host,
            carrier: carrier,
            isShared: isShared,
            hostTag: hostTag,
            titlebarWash: titlebarWash,
            tagStyle: tagStyle
        )
        let state: String
        let flag: NSColor
        switch health {
        case .Connected:
            state = "Connected"
            flag = .secondaryLabelColor
        case .Connecting:
            state = "Connecting"
            flag = .systemYellow
        case .Deploying:
            // Progress rather than a problem, so it is blue where the rest are
            // the colours of something to look at.
            state = "Setting up"
            flag = .systemBlue
        case .Reconnecting:
            state = "Reconnecting"
            flag = .systemOrange
        case .Failed:
            state = "Disconnected"
            flag = .systemRed
        @unknown default:
            state = ""
            flag = .secondaryLabelColor
        }
        statedHostName = Self.hostName(place: place, host: host)
        let name = statedHostName + (isShared ? " (shared)" : "")
        let placeSymbol = place == .ThisMachine ? "desktopcomputer" : (carrier == "quic" ? "globe.fill" : "globe")

        // Link state stays in the symbol, or beside it, and in the accessible
        // description, so the host remains one stable identity beside the
        // content title.
        label.stringValue = name
        label.sizeToFit()
        let windowWidth = (window ?? titleWindow)?.frame.width
        if let hostTag {
            layOutCapsule(
                for: hostTag,
                placeSymbol: placeSymbol,
                unsteadyFlag: chip.isSteady ? nil : flag,
                titlebarWash: titlebarWash,
                style: tagStyle,
                windowWidth: windowWidth
            )
        } else {
            // Core decides whether the link is steady; the frontend decides
            // what steady looks like, which is the chrome's own ink.
            layOutPlain(placeSymbol: placeSymbol, ink: chip.isSteady ? .secondaryLabelColor : flag, windowWidth: windowWidth)
        }
        needsDisplay = true

        let transport = place == .Remote && !carrier.isEmpty ? " over \(carrier.uppercased())" : ""
        linkDescription = "Session on \(name)\(transport). \(state)."
        let tagSentence = hostTag.map { " Tagged \($0.spokenName)." } ?? ""
        let description = "Session on \(name)\(transport).\(tagSentence) \(state)."
        toolTip = description
        setAccessibilityLabel(description)
        isHidden = false
        if wasHidden || frame.size != previousSize || description != previousDescription {
            presentationDidChange?()
        }
    }

    /// Lays the chip out bare: the place's symbol in the link's ink, then the
    /// name in the chrome's secondary ink.
    ///
    /// - Parameters:
    ///   - placeSymbol: The system symbol for the host's place.
    ///   - ink: The symbol's ink, flagged while the link is not steady.
    ///   - windowWidth: The window's width, nil before the chip is in one.
    private func layOutPlain(placeSymbol: String, ink: NSColor, windowWidth: CGFloat?) {
        capsuleFill = nil
        capsuleFillOpacity = 1
        hasCapsuleBorder = false
        dividerFrame = nil
        tagLabel.isHidden = true
        statusDot.isHidden = true
        let side = Self.symbolSide(forTitleFont: titleFont)
        showSymbol(placeSymbol, fittedInto: side)
        label.textColor = .secondaryLabelColor
        icon.contentTintColor = ink

        let gap = Self.gapInPoints
        let budget = widthBudget(forWindowWidth: windowWidth, floor: Self.minLabelWidthInPoints + side + gap)
        let labelBudget = budget - side - gap
        label.frame.size.width = max(min(label.frame.width, labelBudget, Self.maxLabelWidthInPoints), Self.minLabelWidthInPoints)

        // The chip is the name's line, which the title reserves whole before
        // its directory segment; the symbol's square is a little over the
        // title's point size, so the symbol stands inside the line.
        let height = ceil(label.frame.height)
        let total = side + gap + label.frame.width
        label.frame.origin = NSPoint(x: total - label.frame.width, y: (height - label.frame.height) / 2)
        frame.size = NSSize(width: total, height: height)
        let symbol = icon.image.map { Self.iconFrame(for: $0, capHeight: titleFont.capHeight, backingScale: backingScale) } ?? .zero
        icon.frame = symbol.offsetBy(dx: (side - symbol.width) / 2, dy: hostLabelBaselineOffsetFromBottom)
    }

    /// Lays the chip out as its tag's capsule: the icon, the machine's name
    /// and the tag's title on the tag's fill, in the ink that reads on it.
    ///
    /// The height, the padding, the icon and the line the text stands on are
    /// ``TitlebarCapsuleGeometry``'s for the title's font, as every pill in the
    /// row takes them; the title reserves the capsule's whole width, padding
    /// included. Its padding is counted from what it holds: the icon's box at
    /// the leading end, the text itself at the trailing one, not the text
    /// field's own inset around it.
    ///
    /// - Parameters:
    ///   - tag: The tag the chip wears.
    ///   - placeSymbol: The system symbol for the host's place, drawn when the
    ///     tag has no icon or names one the drawing does not know.
    ///   - unsteadyFlag: The flag colour for a link that is not steady, nil
    ///     for a steady one.
    ///   - titlebarWash: The row's wash, nil for none.
    ///   - style: How the row lays a tag's colour down.
    ///   - windowWidth: The window's width, nil before the chip is in one.
    private func layOutCapsule(
        for tag: HostChipTag,
        placeSymbol: String,
        unsteadyFlag: NSColor?,
        titlebarWash: NSColor?,
        style: TitlebarTagStyle,
        windowWidth: CGFloat?
    ) {
        let geometry = TitlebarCapsuleGeometry(titleFont: titleFont)
        let fill = tag.fill
        let ink = TitlebarTagChip.ink(onFill: fill, style: style, appearance: effectiveAppearance)
        capsuleFill = fill
        capsuleFillOpacity = style.opacity
        capsuleInk = ink
        hasCapsuleBorder = titlebarWash.map { Self.isSameColor($0, fill) } ?? false
        let side = TitlebarCapsuleGeometry.iconSide
        let drawsTagIcon = showTagIcon(of: tag, side: side, ink: ink)
        if !drawsTagIcon {
            showSymbol(placeSymbol, fittedInto: side)
        }
        // The place's symbol is a template the image view tints; the tag's
        // icon is drawn in the ink already, and the tint leaves it alone.
        icon.contentTintColor = ink
        label.textColor = ink
        let hasTitle = !tag.title.isEmpty
        tagLabel.stringValue = tag.title
        tagLabel.textColor = ink
        tagLabel.isHidden = !hasTitle
        tagLabel.sizeToFit()

        // The tag's title gives way first, down to its own floor, and only
        // then the machine's name, down to its: the name is what the chip is
        // for. Neither is drawn wider than it needs. The widths are the
        // fields' frames, which carry each field's inset on both sides.
        let padding = TitlebarCapsuleGeometry.endPadding
        let gap = TitlebarCapsuleGeometry.iconGap
        let nameInset = Self.textInset(of: label)
        let titleInset = hasTitle ? Self.textInset(of: tagLabel) : 0
        let dividerSpan = hasTitle ? 2 * Self.dividerGapInPoints + 1 : 0
        let fixed = padding + side + gap + dividerSpan + padding - 2 * nameInset - 2 * titleInset
        let floor = fixed + Self.minLabelWidthInPoints + (hasTitle ? Self.minTagTitleWidthInPoints : 0)
        let room = widthBudget(forWindowWidth: windowWidth, floor: floor) - fixed
        let nameNatural = min(label.frame.width, Self.maxLabelWidthInPoints)
        let titleNatural = hasTitle ? min(tagLabel.frame.width, Self.maxTagTitleWidthInPoints) : 0
        let titleFloor = min(titleNatural, Self.minTagTitleWidthInPoints)
        let nameWidth = max(min(nameNatural, room - titleFloor), min(nameNatural, Self.minLabelWidthInPoints))
        let titleWidth = hasTitle ? max(min(titleNatural, room - nameWidth), titleFloor) : 0
        label.frame.size.width = nameWidth
        tagLabel.frame.size.width = titleWidth

        let height = geometry.height
        let capHeight = geometry.font.capHeight
        let baseline = geometry.baselineAboveBottom
        var x = padding
        // The icon's box is the geometry's square: a tag's icon fills it, and
        // the place's symbol was fitted into it whole, as the bare chip fits
        // it into its own. Either stands on the name's cap band.
        let iconRect =
            icon.image.map { Self.iconFrame(for: $0, capHeight: capHeight, backingScale: backingScale) }
            ?? NSRect(x: 0, y: (capHeight - side) / 2, width: side, height: side)
        icon.frame = iconRect.offsetBy(dx: x + (side - iconRect.width) / 2, dy: baseline)
        x += side + gap
        capsuleNameStart = x
        label.frame.origin = NSPoint(x: x - nameInset, y: baseline - Self.baselineOffsetFromBottom(of: label))
        x += nameWidth - 2 * nameInset
        dividerFrame = nil
        if hasTitle {
            x += Self.dividerGapInPoints
            dividerFrame = NSRect(x: x.rounded(), y: baseline - 2, width: 1, height: capHeight + 4)
            x += 1 + Self.dividerGapInPoints
            tagLabel.frame.origin = NSPoint(x: x - titleInset, y: baseline - Self.baselineOffsetFromBottom(of: tagLabel))
            x += titleWidth - 2 * titleInset
        }
        capsuleTextEnd = x
        frame.size = NSSize(width: ceil(x + padding), height: height)

        guard let unsteadyFlag else {
            statusDot.isHidden = true
            return
        }
        // At the symbol's lower trailing corner, reaching into the gap before
        // the name but not across it, and never below the capsule. The halo is
        // the fill as it composites, the colour the dot is cut out of.
        let diameter = max(ceil(side * 0.6), 8)
        statusDot.frame = NSRect(
            x: icon.frame.maxX - diameter * 0.7,
            y: max(0, icon.frame.minY - diameter * 0.3),
            width: diameter,
            height: diameter
        )
        statusDot.dotColor = unsteadyFlag
        statusDot.ringColor = ink
        statusDot.haloColor = TitlebarTagChip.compositedFill(fill, style: style, appearance: effectiveAppearance)
        statusDot.isHidden = false
    }

    /// The air a label's cell keeps between its frame and its text on either
    /// side.
    ///
    /// - Parameter field: The label.
    /// - Returns: The inset, in points.
    private static func textInset(of field: NSTextField) -> CGFloat {
        guard let cell = field.cell, let font = field.font else { return 0 }
        let text = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        return max(0, (cell.cellSize.width - text) / 2)
    }

    /// Stands the place's system symbol in the icon's slot: set in the title's
    /// type, then fitted whole into a square.
    ///
    /// - Parameters:
    ///   - name: The symbol's name.
    ///   - side: The square's side.
    private func showSymbol(_ name: String, fittedInto side: CGFloat) {
        tagIconName = ""
        tagIconKey = ""
        tagIconInk = nil
        guard symbolName != name || fittedSymbolSide != side else { return }
        symbolName = name
        fittedSymbolSide = side
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.symbolConfiguration(matching: titleFont))
        else {
            icon.image = nil
            return
        }
        icon.image = Self.fitted(symbol, into: side)
    }

    /// The configuration that sets a system symbol in a font's own type: its
    /// point size and weight, at the default medium scale.
    ///
    /// - Parameter font: The text the symbol stands beside.
    /// - Returns: The configuration.
    private static func symbolConfiguration(matching font: NSFont) -> NSImage.SymbolConfiguration {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? CGFloat).map { NSFont.Weight(rawValue: $0) } ?? .regular
        return NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: weight, scale: .medium)
    }

    /// A symbol scaled whole to fit a square, its alignment rect scaled with
    /// it.
    ///
    /// Drawn at the size the icon's view shows it, so the view never scales
    /// it: an image view that scales a symbol draws it afresh for the new
    /// size, and that drawing need not keep the alignment rect's place.
    ///
    /// - Parameters:
    ///   - symbol: The symbol, configured.
    ///   - side: The square's side.
    /// - Returns: The fitted symbol, a template as the symbol is.
    private static func fitted(_ symbol: NSImage, into side: CGFloat) -> NSImage {
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return symbol }
        let scale = side / max(size.width, size.height)
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: false) { bounds in
            symbol.draw(in: bounds)
            return true
        }
        image.isTemplate = true
        let alignment = symbol.alignmentRect
        image.alignmentRect = NSRect(
            x: alignment.minX * scale,
            y: alignment.minY * scale,
            width: alignment.width * scale,
            height: alignment.height * scale
        )
        return image
    }

    /// Where an icon stands beside a line of text, at its own size, its origin
    /// measured from the text's baseline: its own cap band centred on the
    /// text's, by ``TitleIconPlacement``.
    ///
    /// - Parameters:
    ///   - image: The icon.
    ///   - capHeight: The text's cap height.
    ///   - backingScale: The pixels per point the chip is drawn at.
    /// - Returns: The image's frame.
    private static func iconFrame(for image: NSImage, capHeight: CGFloat, backingScale: CGFloat) -> NSRect {
        let bottom = TitleIconPlacement.bottomAboveBaseline(of: image, capHeight: capHeight, backingScale: backingScale)
        return NSRect(origin: NSPoint(x: 0, y: bottom), size: image.size)
    }

    /// Stands a tag's icon in the symbol's slot, drawn in the capsule's ink.
    ///
    /// Drawn in the ink rather than as a template the image view tints: a
    /// template's tint resolves under the view's appearance, which is not the
    /// colour the capsule's text beside it is drawn in.
    ///
    /// - Parameters:
    ///   - tag: The tag whose icon is drawn.
    ///   - side: The icon's side, in points.
    ///   - ink: The capsule's ink.
    /// - Returns: Whether the icon stands; false for a tag with no icon, one the
    ///   drawing does not know, or no drawing at all.
    private func showTagIcon(of tag: HostChipTag, side: CGFloat, ink: NSColor) -> Bool {
        guard !tag.iconName.isEmpty, let tagIconDrawing else { return false }
        let inkKey =
            ink.usingColorSpace(.sRGB).map { String(format: "%.4f,%.4f,%.4f", $0.redComponent, $0.greenComponent, $0.blueComponent) }
            ?? ink.description
        let key = [tag.iconName, String(tag.iconWeight.rawValue), "\(side)", inkKey].joined(separator: "\u{1F}")
        if key != tagIconKey {
            guard let image = tagIconDrawing(tag.iconName, tag.iconWeight, side, ink) else { return false }
            image.isTemplate = false
            icon.image = image
            tagIconKey = key
        }
        tagIconName = tag.iconName
        tagIconInk = ink
        symbolName = ""
        return true
    }

    /// The distance from a label's frame bottom to its first baseline.
    private static func baselineOffsetFromBottom(of field: NSTextField) -> CGFloat {
        field.frame.height - field.firstBaselineOffsetFromTop
    }

    /// Whether a wash and a fill read as one colour.
    private static func isSameColor(_ wash: NSColor, _ fill: NSColor) -> Bool {
        guard let wash = wash.usingColorSpace(.sRGB), let fill = fill.usingColorSpace(.sRGB) else { return false }
        return abs(wash.redComponent - fill.redComponent) < washMatchTolerance
            && abs(wash.greenComponent - fill.greenComponent) < washMatchTolerance
            && abs(wash.blueComponent - fill.blueComponent) < washMatchTolerance
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let capsuleFill else { return }
        let radius = bounds.height / 2
        TitlebarTagChip.laidDown(capsuleFill, opacity: capsuleFillOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if hasCapsuleBorder {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            capsuleInk.withAlphaComponent(Self.capsuleBorderAlpha).setStroke()
            outline.stroke()
        }
        if let dividerFrame {
            capsuleInk.withAlphaComponent(Self.dividerAlpha).setFill()
            dividerFrame.fill(using: .sourceOver)
        }
    }

    /// Takes the badge out of the title row: the window's session is local
    /// again, and a local window names no host.
    package func withdraw() {
        let wasHidden = isHidden
        presentation = nil
        statedHostName = ""
        linkDescription = ""
        isHidden = true
        if !wasHidden { presentationDidChange?() }
    }

    /// The host this chip names in the title row, as a tab's label would
    /// spell it; empty while the chip is withdrawn. What the window's chrome
    /// already says, which Core reads to keep a tab from saying it again.
    package private(set) var statedHostName = ""

    /// What the chip says without its tag: the host, the carrier and the
    /// link's state; empty while the chip is withdrawn. The title's spoken
    /// label reads this after naming the window's tags, this chip's among them,
    /// so the tag is not said twice.
    package private(set) var linkDescription = ""

    /// Whether the chip stands as its tag's capsule, the pill the title's tag
    /// stack tucks under; false for the plain chip and while withdrawn.
    package var isWearingTagCapsule: Bool { !isHidden && capsuleFill != nil }

    /// Whether the badge stands in the title row, for a scenario.
    package var isShownForTesting: Bool { !isHidden }

    /// The badge's visible host identity, for a scenario.
    package var readingForTesting: String {
        label.stringValue
    }

    /// The symbol the chip draws for its host's place, for a scenario; empty
    /// while a tag's icon stands in its place.
    package var symbolNameForTesting: String { symbolName }

    /// The tag's icon the chip draws in place of the place's symbol, for a
    /// scenario; empty while it draws the symbol.
    package var tagIconNameForTesting: String { tagIconName }

    /// The ink the globe is tinted with, or the tag's icon was drawn in, for
    /// a scenario.
    package var globeInkForTesting: NSColor? { tagIconName.isEmpty ? icon.contentTintColor : tagIconInk }

    /// The ink the host name is drawn in, for a scenario.
    package var hostInkForTesting: NSColor? { label.textColor }

    /// The tag's colour the chip is filled with, at full strength, for a
    /// scenario; nil for the plain chip.
    package var capsuleFillForTesting: NSColor? { isHidden ? nil : capsuleFill }

    /// The opacity the capsule's fill is drawn at, for a scenario; nil for
    /// the plain chip.
    package var capsuleFillOpacityForTesting: CGFloat? { capsuleFillForTesting == nil ? nil : capsuleFillOpacity }

    /// The one colour everything in the capsule is drawn in, for a scenario;
    /// nil for the plain chip.
    package var capsuleInkForTesting: NSColor? { capsuleFillForTesting == nil ? nil : capsuleInk }

    /// Where the capsule's icon and the machine's name stand in the chip, for
    /// a scenario reading what each drew; nil for the plain chip.
    package var capsuleContentFramesForTesting: (icon: NSRect, name: NSRect)? {
        capsuleFillForTesting == nil ? nil : (icon.frame, label.frame)
    }

    /// Where the capsule's content stands inside it, for a scenario: the air
    /// before the icon's box, the icon's side, the air from the icon to the
    /// name's text, and the air after the last text. Nil for the plain chip.
    package var capsuleGeometryForTesting: (leading: CGFloat, iconSide: CGFloat, iconToName: CGFloat, trailing: CGFloat)? {
        guard capsuleFillForTesting != nil else { return nil }
        return (icon.frame.minX, icon.frame.width, capsuleNameStart - icon.frame.maxX, bounds.maxX - capsuleTextEnd)
    }

    /// The tag's title the capsule shows after the machine's name, for a
    /// scenario; empty for none.
    package var tagTitleForTesting: String { tagLabel.isHidden ? "" : tagLabel.stringValue }

    /// The colour of the link-state dot on the capsule, for a scenario; nil
    /// while none shows.
    package var linkStatusColorForTesting: NSColor? { statusDot.isHidden ? nil : statusDot.dotColor }

    /// Whether the capsule is outlined against a wash of its own colour, for a
    /// scenario.
    package var hasCapsuleBorderForTesting: Bool { capsuleFill != nil && hasCapsuleBorder }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
            self.windowResizeObserver = nil
        }
        guard let window else { return }
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawPresentation() }
        }
        redrawPresentation()
    }

    /// Draws the chip again from what it was last told.
    private func redrawPresentation() {
        guard let presentation else { return }
        update(
            place: presentation.place,
            health: presentation.health,
            host: presentation.host,
            carrier: presentation.carrier,
            isShared: presentation.isShared,
            hostTag: presentation.hostTag,
            titlebarWash: presentation.titlebarWash,
            tagStyle: presentation.tagStyle
        )
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawPresentation()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The icon's offset from the baseline is counted in backing pixels.
        redrawPresentation()
    }
}

/// The link's state on a tag's capsule: a flag-coloured dot in a ring of the
/// capsule's ink, cut out of the symbol beneath by a halo of the fill.
///
/// The ring is what reads on any fill; the flag colour inside it says which
/// state, as the tinted symbol does on the plain chip.
@MainActor
private final class LinkStatusDot: NSView {
    /// The link state's flag colour.
    var dotColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// The capsule's readable ink.
    var ringColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// The capsule's fill.
    var haloColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        haloColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        ringColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        dotColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
    }
}
