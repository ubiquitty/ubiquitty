// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TagIconPicker.swift — the controls a tag's look is chosen with: its icon,
// from a searchable grid of the whole Phosphor catalog, and a custom colour
// beside the seven of the palette.
//
// The Tags settings pane and the title popover both offer them, so an icon and
// a colour are chosen the same way wherever a tag is edited. Colour values are
// read through Core (`Session::tagColorFromValue`, `Session::tagPaletteName`),
// so the swatch a picker lights is the colour the title row draws.

import AppKit
internal import UbiquittyCore

extension PhosphorIcons {
    /// The weight an `icon_weight` value names, as Core reads it.
    ///
    /// - Parameter spelling: The value as the config spells it; anything but
    ///   `regular` names the default fill.
    /// - Returns: The weight.
    nonisolated package static func weight(spelled spelling: String) -> Ubiquitty.Session.TagIconWeight {
        spelling.withCString { Ubiquitty.Session.tagIconWeightFromString(std.string_view($0)) }
    }

    /// The `icon_weight` value a config spells a weight with.
    ///
    /// - Parameter weight: The weight.
    /// - Returns: `fill` or `regular`.
    nonisolated package static func spelling(of weight: Ubiquitty.Session.TagIconWeight) -> String {
        String(cString: Ubiquitty.Session.tagIconWeightToString(weight))
    }

    /// What a reader hears for an icon: its name with spaces for hyphens.
    ///
    /// - Parameter name: The icon's name.
    /// - Returns: The words.
    nonisolated package static func spokenName(of name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
    }

    /// An icon as ``image(named:weight:side:color:)`` draws it, kept so a grid
    /// scrolled back over a cell does not build its image again.
    ///
    /// The cache is bounded; an evicted image is built again on its next use.
    ///
    /// - Parameters:
    ///   - name: The icon's name.
    ///   - weight: Which of its two weights.
    ///   - side: The image's side, in points.
    ///   - color: The ink.
    /// - Returns: The image, or nil where the uncached call returns nil.
    package static func cachedImage(
        named name: String,
        weight: Ubiquitty.Session.TagIconWeight,
        side: CGFloat,
        color: NSColor
    )
        -> NSImage?
    {
        let key = "\(name)|\(spelling(of: weight))|\(side)|\(color)" as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = image(named: name, weight: weight, side: side, color: color) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4096
        return cache
    }()
}

/// Tag colour values as Core reads them, for the pickers that offer and show
/// them.
package enum TagColorValue {
    /// The colour a `[[tags]]` colour value names: one of the palette's, or a
    /// `#rrggbb` literal.
    ///
    /// - Parameter value: The value as the config or a hand-set name spells it.
    /// - Returns: The colour, or nil when the value names none.
    package static func color(of value: String) -> NSColor? {
        var entry = Ubiquitty.Preferences.ColorEntry()
        guard Ubiquitty.Session.tagColorFromValue(std.string(value), &entry) else { return nil }
        return color(of: entry)
    }

    /// The colour Core resolved for a tag.
    ///
    /// - Parameter entry: The resolved colour.
    /// - Returns: The colour, or nil when the entry is unset.
    package static func color(of entry: Ubiquitty.Preferences.ColorEntry) -> NSColor? {
        guard entry.set else { return nil }
        return NSColor(
            srgbRed: CGFloat(entry.red) / 255,
            green: CGFloat(entry.green) / 255,
            blue: CGFloat(entry.blue) / 255,
            alpha: CGFloat(entry.alpha) / 255
        )
    }

    /// Whether a value is a custom colour: one that names a colour without
    /// being one of the palette's names.
    ///
    /// - Parameter value: The value as the config or a hand-set name spells it.
    /// - Returns: True for a colour literal Core resolves.
    package static func isCustom(_ value: String) -> Bool {
        guard color(of: value) != nil else { return false }
        return value.withCString { Ubiquitty.Session.tagPaletteName(std.string_view($0)).empty() }
    }

    /// The `#rrggbb` literal a custom colour is written as.
    ///
    /// The colour is converted to sRGB, the space Core reads the literal in,
    /// so what is written is what the colour panel showed. Opacity is dropped:
    /// a tag's colour is opaque.
    ///
    /// - Parameter color: The colour chosen.
    /// - Returns: The literal, lower case.
    package static func literal(for color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    }
}

// MARK: - Icon picker

/// A button showing a tag's icon that opens a searchable grid of every icon.
///
/// The grid draws each icon in the tag's colour and weight, so the choice is
/// made on the marker as the title row will draw it. Its popover takes the
/// keyboard: typing searches, the arrow keys move through the grid, Return
/// picks, and Escape closes without a change.
@MainActor
package final class TagIconPicker: NSButton {
    /// The icon shown, empty for none.
    package var iconName = "" {
        didSet { refresh() }
    }

    /// The weight the icons are drawn in.
    package var iconWeight: Ubiquitty.Session.TagIconWeight = .Fill {
        didSet { refresh() }
    }

    /// The ink, nil for a tag that names no colour.
    package var tint: NSColor? {
        didSet { refresh() }
    }

    /// Called with the picked icon's name, or empty when the reader chose none.
    package var onPick: ((String) -> Void)?

    private var popover: NSPopover?

    /// Makes a picker showing no icon.
    package init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        bezelStyle = .push
        imagePosition = .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(toggleGrid(_:))
        // A pop-up, not a plain button: it carries a value, the icon chosen,
        // and pressing it offers the others.
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Icon")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    package override func accessibilityValue() -> Any? {
        iconName.isEmpty ? "None" : PhosphorIcons.spokenName(of: iconName)
    }

    /// Shows the current icon, or says there is none. A name the catalog does
    /// not carry is shown as spelled, without a glyph, since the tag draws its
    /// dot in that case.
    private func refresh() {
        if let glyph = PhosphorIcons.cachedImage(named: iconName, weight: iconWeight, side: 16, color: tint ?? .secondaryLabelColor) {
            image = glyph
            title = PhosphorIcons.spokenName(of: iconName)
        } else {
            image = nil
            title = iconName.isEmpty ? "No Icon" : PhosphorIcons.spokenName(of: iconName)
        }
        invalidateIntrinsicContentSize()
    }

    @objc
    private func toggleGrid(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let grid = TagIconGridController(current: iconName, weight: iconWeight, tint: tint ?? .labelColor)
        let popover = NSPopover()
        grid.onPick = { [weak self] name in
            self?.pick(name)
        }
        grid.onClose = { [weak popover] in
            popover?.performClose(nil)
        }
        popover.behavior = .transient
        popover.contentViewController = grid
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    private func pick(_ name: String) {
        popover?.performClose(nil)
        iconName = name
        onPick?(name)
    }
}

/// The picker's popover: a search field over the grid, and the choice of none.
@MainActor
private final class TagIconGridController: NSViewController, NSSearchFieldDelegate, NSCollectionViewDataSource,
    NSCollectionViewDelegate
{
    private enum Layout {
        static let itemSide: CGFloat = 34
        static let glyphSide: CGFloat = 20
        static let spacing: CGFloat = 4
        static let inset: CGFloat = 10
        static let columns: CGFloat = 10
        static let gridHeight: CGFloat = 300
    }

    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let currentName: String
    private let weight: Ubiquitty.Session.TagIconWeight
    private let tint: NSColor
    private let searchField = NSSearchField()
    private let collectionView = TagIconGridView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var results: [PhosphorIcons.Icon] = PhosphorIcons.catalog

    init(current: String, weight: Ubiquitty.Session.TagIconWeight, tint: NSColor) {
        currentName = current
        self.weight = weight
        self.tint = tint
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let gridWidth = Layout.inset * 2 + Layout.columns * Layout.itemSide + (Layout.columns - 1) * Layout.spacing
        // A legacy scroller takes its width from the content; the grid keeps
        // its columns by being given that width back.
        let scrollerWidth =
            NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let content = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search Icons"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("tagIconPicker.search")

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: Layout.itemSide, height: Layout.itemSide)
        layout.minimumInteritemSpacing = Layout.spacing
        layout.minimumLineSpacing = Layout.spacing
        layout.sectionInset = NSEdgeInsets(top: Layout.inset, left: Layout.inset, bottom: Layout.inset, right: Layout.inset)
        collectionView.frame = NSRect(x: 0, y: 0, width: gridWidth, height: Layout.gridHeight)
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TagIconGridItem.self, forItemWithIdentifier: TagIconGridItem.identifier)
        collectionView.setAccessibilityLabel("Icons")
        collectionView.setAccessibilityIdentifier("tagIconPicker.grid")
        collectionView.onReturn = { [weak self] in
            self?.pickSelection()
        }
        collectionView.onEscape = { [weak self] in
            self?.onClose?()
        }
        collectionView.onTyping = { [weak self] text in
            self?.typeIntoSearch(text)
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let noneButton = NSButton(title: "No Icon", target: self, action: #selector(pickNone(_:)))
        noneButton.translatesAutoresizingMaskIntoConstraints = false
        noneButton.controlSize = .small
        noneButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        noneButton.setAccessibilityIdentifier("tagIconPicker.none")

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [searchField, scrollView, noneButton, summaryLabel] as [NSView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.inset),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.inset),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: gridWidth + scrollerWidth),
            scrollView.heightAnchor.constraint(equalToConstant: Layout.gridHeight),
            noneButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            noneButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.inset),
            noneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Layout.inset),
            summaryLabel.centerYAnchor.constraint(equalTo: noneButton.centerYAnchor),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: noneButton.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.inset),
        ])
        view = content
        preferredContentSize = content.fittingSize
        refreshSummary()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Typing goes to the search field from the first key, so the popover
        // takes the keyboard from the window it was opened over.
        view.window?.makeKey()
        view.window?.makeFirstResponder(searchField)
        if let index = results.firstIndex(where: { $0.name == currentName }) {
            select(index, scrollPosition: .centeredVertically)
        }
    }

    // MARK: search

    @objc
    func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        results = PhosphorIcons.search(query)
        collectionView.reloadData()
        collectionView.selectionIndexPaths = []
        if !results.isEmpty {
            // A query's best match is selected, so Return picks it; the whole
            // catalog starts unselected and at its top.
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
            } else {
                select(0, scrollPosition: .top)
            }
        }
        refreshSummary()
    }

    /// Hands a key typed while the grid had focus to the search field, at the
    /// end of what is already there.
    private func typeIntoSearch(_ text: String) {
        view.window?.makeFirstResponder(searchField)
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        let end = NSRange(location: (editor.string as NSString).length, length: 0)
        editor.insertText(text, replacementRange: end)
        searchChanged(searchField)
    }

    /// The search field keeps the keyboard while the arrows move the grid's
    /// selection, so a reader can type, look, and step without changing focus.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -columnCount)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: columnCount)
        case #selector(NSResponder.moveLeft(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveRight(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            pickSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    // MARK: selection

    /// How many icons a row holds at the grid's laid-out width, by the same
    /// arithmetic the flow layout fills a row with.
    private var columnCount: Int {
        let width = collectionView.bounds.width - Layout.inset * 2
        return max(1, Int((width + Layout.spacing) / (Layout.itemSide + Layout.spacing)))
    }

    /// Moves the selection, starting at the first icon when none is selected.
    /// A step past either end of the results leaves the selection where it is.
    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        guard let current = collectionView.selectionIndexPaths.first?.item else {
            select(0, scrollPosition: .nearestHorizontalEdge)
            return
        }
        let target = current + offset
        guard results.indices.contains(target) else { return }
        select(target, scrollPosition: .nearestHorizontalEdge)
    }

    private func select(_ index: Int, scrollPosition: NSCollectionView.ScrollPosition) {
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: scrollPosition)
        refreshSummary()
    }

    private func pickSelection() {
        guard let index = collectionView.selectionIndexPaths.first?.item, results.indices.contains(index) else {
            NSSound.beep()
            return
        }
        onPick?(results[index].name)
    }

    @objc
    func pickNone(_ sender: Any?) {
        onPick?("")
    }

    /// Names the selected icon, or counts what the search found.
    private func refreshSummary() {
        if let index = collectionView.selectionIndexPaths.first?.item, results.indices.contains(index) {
            summaryLabel.stringValue = PhosphorIcons.spokenName(of: results[index].name)
        } else if results.isEmpty {
            summaryLabel.stringValue = "No icons match"
        } else {
            summaryLabel.stringValue = results.count == 1 ? "1 icon" : "\(results.count) icons"
        }
    }

    // MARK: grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        results.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: TagIconGridItem.identifier, for: indexPath)
        guard let cell = item as? TagIconGridItem, results.indices.contains(indexPath.item) else { return item }
        let name = results[indexPath.item].name
        cell.show(
            name: name,
            image: PhosphorIcons.cachedImage(named: name, weight: weight, side: Layout.glyphSide, color: tint),
            isCurrent: name == currentName,
            onPress: { [weak self] in
                self?.onPick?(name)
            }
        )
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        refreshSummary()
    }
}

/// The grid's collection view, taking the picker's keys while it has focus:
/// the arrows move as the collection view moves them, Return picks, Escape
/// closes, and anything typed goes to the search field.
@MainActor
private final class TagIconGridView: NSCollectionView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTyping: ((String) -> Void)?

    /// The keys the collection view and the window already answer: moving
    /// through the grid, and moving focus out of it.
    private static let navigationKeys: Set<NSEvent.SpecialKey> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .home, .end, .tab, .backTab,
    ]

    override func keyDown(with event: NSEvent) {
        if let key = event.specialKey, Self.navigationKeys.contains(key) {
            super.keyDown(with: event)
        } else {
            interpretKeyEvents([event])
        }
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        onTyping?(text)
    }

    override func insertNewline(_ sender: Any?) {
        onReturn?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// One cell of the grid.
@MainActor
private final class TagIconGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("tagIconPicker.item")

    private let cell = TagIconCellView()

    override func loadView() {
        view = cell
    }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    func show(name: String, image: NSImage?, isCurrent: Bool, onPress: @escaping () -> Void) {
        cell.show(name: name, image: image, isCurrent: isCurrent)
        cell.isSelected = isSelected
        cell.onPress = onPress
    }
}

/// An icon in the tag's ink on a tile: tinted when it is the tag's current
/// icon, ringed in the accent colour when the keyboard has selected it.
///
/// A click picks rather than selects: the grid is a chooser, and the
/// selection exists for the keyboard to step through.
@MainActor
private final class TagIconCellView: NSView {
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilitySelected(isSelected)
        }
    }

    var onPress: (() -> Void)?

    private var image: NSImage?
    private var isCurrent = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(name: String, image: NSImage?, isCurrent: Bool) {
        self.image = image
        self.isCurrent = isCurrent
        let spoken = PhosphorIcons.spokenName(of: name)
        toolTip = spoken
        setAccessibilityLabel(spoken)
        setAccessibilityIdentifier("tagIconPicker.icon.\(name)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if isCurrent {
            NSColor.quaternaryLabelColor.setFill()
            tile.fill()
        }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            tile.fill()
            tile.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            tile.stroke()
        }
        guard let image else { return }
        let side = min(image.size.width, bounds.width)
        image.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
    }

    override func mouseDown(with event: NSEvent) {
        // Taking the press keeps the collection view from turning it into a
        // selection and routes the release to mouseUp below.
    }

    override func mouseUp(with event: NSEvent) {
        // Picked on release inside, the button convention, so a drag off the
        // cell abandons the press.
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

// MARK: - Custom colour

/// A swatch beside a tag palette that stands for any colour outside it.
///
/// A press opens the shared colour panel; each colour chosen there is reported
/// as the `#rrggbb` literal a `[[tags]]` colour or a hand-set tag name spells.
/// The swatch shows a spectrum until it has a colour, and is ringed while the
/// tag being edited wears its colour. A press on a swatch that has a colour
/// the tag does not wear also chooses that colour, so a custom colour is one
/// press away again after a palette colour replaced it.
@MainActor
package final class TagCustomColorSwatch: NSControl {
    /// How the swatch sits among the palette it extends.
    package enum Look {
        /// A small dot in an 18-point square, ringed in its own colour: the
        /// title popover's dot strip.
        case dot
        /// An 18-point disc ringed in the accent colour: the settings pane's
        /// swatches.
        case disc
    }

    /// The custom colour shown, or nil for the spectrum.
    package var color: NSColor? {
        didSet { needsDisplay = true }
    }

    /// Whether the tag being edited wears the swatch's colour.
    package var isChosen = false {
        didSet { needsDisplay = true }
    }

    /// Called with the literal of each colour chosen.
    package var onPick: ((String) -> Void)?

    private let look: Look

    /// Makes a swatch showing the spectrum.
    ///
    /// - Parameter look: The palette it sits in.
    package init(look: Look) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        toolTip = "Custom Color\u{2026}"
        setAccessibilityElement(true)
        setAccessibilityRole(.colorWell)
        setAccessibilityLabel("Custom color")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The literal of the colour the tag wears, nil while it wears another.
    package override func accessibilityValue() -> Any? {
        guard isChosen, let color else { return nil }
        return TagColorValue.literal(for: color)
    }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    package override func draw(_ dirtyRect: NSRect) {
        let disc = look == .dot ? bounds.insetBy(dx: 4, dy: 4) : bounds.insetBy(dx: 1, dy: 1)
        if let color {
            color.setFill()
            NSBezierPath(ovalIn: disc).fill()
        } else {
            drawSpectrum(in: disc)
        }
        guard isChosen else { return }
        let ring = NSBezierPath(ovalIn: look == .dot ? bounds.insetBy(dx: 1.25, dy: 1.25) : bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = look == .dot ? 1.5 : 2
        (look == .dot ? (color ?? .labelColor) : NSColor.controlAccentColor).setStroke()
        ring.stroke()
    }

    /// A wheel of hues, the mark for a colour not yet chosen.
    private func drawSpectrum(in disc: NSRect) {
        let center = NSPoint(x: disc.midX, y: disc.midY)
        let wedges = 12
        let sweep = 360 / CGFloat(wedges)
        for index in 0..<wedges {
            let start = CGFloat(index) * sweep
            let wedge = NSBezierPath()
            wedge.move(to: center)
            // Each wedge overlaps the next by a fraction of a degree, so no
            // background shows along the seams.
            wedge.appendArc(withCenter: center, radius: disc.width / 2, startAngle: start, endAngle: start + sweep + 0.5)
            wedge.close()
            NSColor(hue: CGFloat(index) / CGFloat(wedges), saturation: 0.7, brightness: 0.95, alpha: 1).setFill()
            wedge.fill()
        }
    }

    package override func mouseDown(with event: NSEvent) {
        // Taking the press keeps it from falling through to a popover and
        // routes the release to mouseUp below.
    }

    package override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            press()
        }
    }

    package override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func press() {
        if !isChosen, let color {
            onPick?(TagColorValue.literal(for: color))
        }
        TagColorPanelLink.shared.connect(self)
    }

    /// Takes a colour chosen in the panel.
    fileprivate func takeChosenColor(_ chosen: NSColor) {
        color = chosen
        onPick?(TagColorValue.literal(for: chosen))
    }

    /// Takes a colour as the colour panel would report it, for a scenario: the
    /// panel's wheel is not a control a scenario can turn.
    ///
    /// - Parameter chosen: The colour to report.
    package func takeColorForTesting(_ chosen: NSColor) {
        takeChosenColor(chosen)
    }
}

/// The one connection between the shared colour panel and whichever custom
/// swatch was pressed last.
///
/// The panel's target is this object, which lives as long as the app, rather
/// than a swatch a closing sheet frees, so the panel never reports to a freed
/// object; the swatch is held weakly, and once it is gone the panel's choices
/// fall on nothing. A swatch in a popover outlives the popover's closing, so
/// the panel goes on editing that tag after a click in the panel dismissed it.
@MainActor
private final class TagColorPanelLink: NSObject {
    static let shared = TagColorPanelLink()

    private weak var owner: TagCustomColorSwatch?

    func connect(_ swatch: TagCustomColorSwatch) {
        let panel = NSColorPanel.shared
        // Disconnected while its colour is set, so the setting is not
        // reported back as a choice.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        if let color = swatch.color {
            panel.color = color
        }
        owner = swatch
        panel.setTarget(self)
        panel.setAction(#selector(panelColorDidChange(_:)))
        panel.orderFront(nil)
    }

    @objc
    func panelColorDidChange(_ sender: NSColorPanel) {
        owner?.takeChosenColor(sender.color)
    }
}
