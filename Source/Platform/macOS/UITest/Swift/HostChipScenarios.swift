// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// HostChipScenarios.swift — a window on a host says which host, all the time.
//
// Three claims. A window attached to a ubiquitty-host wears the host chip in
// its title row while the link is steady, not only while it is in trouble, and
// still wears it once a dropped carrier has been reconnected; its tab and its
// subtitle name the host too. A plain local shell wears none of it. And two
// tabs on two hosts carry two different host marks, so a strip mixing them
// can be read.
//
// The first runs against a real ubiquitty-host forked with a home of its own,
// because the steady state and the reconnect are the daemon's answers.
//
// A chip that wears a tag is that tag's capsule: one 22-point fill of the tag's
// colour holding its icon, the machine's name and its title, padded evenly and
// reserved whole by the title, keeping the fill through a reconnect and saying
// the link's state on a dot, and outlined over a wash of its own colour. At a
// strength below full the fill is laid down at that opacity and the ink is
// chosen against the fill as it composites over the row: one concrete colour
// for the name, the title and the icon.
//
// The capsule is the last pill of the title row's tag stack. The markers
// before it stack as overlapping pills, each tucked under the next and the
// last under the chip, cut by the upper pill's start so the row shows in the
// gap; every pill shares the chip's height, centre line and baseline, and
// lays its fill down at the same strength.
//
// Every icon beside text in the row stands on that text's cap band: the
// place's symbol, set in the title's type and fitted into a square, the bare
// chip's a little over the title's point size or the capsule's icon square;
// a tag's icon in the capsule and in its own pill; and a program's status
// symbol, set in the status's face.

/// Registers the host-chip scenarios with the UI-test runner.
enum HostChipScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("host_chip_stacks_tags_as_overlapping_pills") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyTagStack(t) }
        }
        UBUITestRegister("host_chip_names_the_host_while_attached_and_after_a_reconnect") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyAttached(t) }
        }
        UBUITestRegister("host_chip_is_absent_on_a_plain_local_shell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyLocalShell(t) }
        }
        UBUITestRegister("host_chip_tabs_on_two_hosts_carry_different_marks") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyTwoHosts(t) }
        }
        UBUITestRegister("host_chip_matches_title_font_and_baseline") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyTitleBaseline(t) }
        }
        UBUITestRegister("host_chip_wears_its_tag_as_one_capsule") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyTagCapsule(t) }
        }
        UBUITestRegister("title_row_centres_every_icon_on_its_text_cap_band") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyIconsOnCapBand(t) }
        }
        UBUITestRegister("title_row_places_program_status_before_the_process_and_dimensions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyProgramStatusOrder(t) }
        }
    }

    @MainActor
    private static func verifyProgramStatusOrder(_ t: UBUITestContext) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Running the build — make ◂ zsh"
        window.orderFront(nil)
        defer { window.close() }
        let proxy = ProxyIconRevealController(window: window)
        let chip = RemoteConnectionIndicator(window: window)
        proxy.connectionIndicator = chip
        chip.update(place: .ThisMachine, health: .Connected, host: "", carrier: "")
        proxy.rowTitleText = "Running the build—make ◂ zsh"
        proxy.programStatusInsertionByteOffset = "Running the build".utf8.count
        proxy.programStatusTitle = "Linking objects"
        proxy.applyTitleStyle(
            directorySegment: "",
            baseTitleBeforeDirectory: "",
            trailingRegularSegment: "201×48",
            dimColor: .secondaryLabelColor,
            brightColor: .labelColor,
            detailColor: .secondaryLabelColor
        )
        t.pump(0.1)
        guard let field = chip.superview as? NSTextField else {
            t.expect(false, desc: "the title row has one attributed field")
            return
        }
        let text = field.attributedStringValue.string
        t.expect(
            text.hasSuffix("Running the build\(ProxyIconRevealController.statusArrow)Linking objects—make ◂ zsh—201×48"),
            desc: "the attributed title places the program status after the app title, then the process and dimensions (\(text))"
        )
        t.expect(
            window.title == "Running the build — make ◂ zsh",
            desc: "the system title remains Core's spaced title without row components"
        )
        proxy.rowTitleText = "make ◂ zsh"
        proxy.programStatusInsertionByteOffset = 0
        proxy.applyTitleStyle(
            directorySegment: "",
            baseTitleBeforeDirectory: "",
            trailingRegularSegment: "201×48",
            dimColor: .secondaryLabelColor,
            brightColor: .labelColor,
            detailColor: .secondaryLabelColor
        )
        let withoutAppTitle = field.attributedStringValue.string
        t.expect(
            withoutAppTitle.hasSuffix("Linking objects—make ◂ zsh—201×48"),
            desc: "a status with no app title still precedes the process and dimensions (\(withoutAppTitle))"
        )
        proxy.programStatusTitle = ""
        let withoutStatus = field.attributedStringValue.string
        t.expect(
            withoutStatus.hasSuffix("make ◂ zsh—201×48") && !withoutStatus.contains("Linking objects"),
            desc: "hiding program status leaves the process and dimensions in place (\(withoutStatus))"
        )
        withExtendedLifetime(proxy) {}
    }

    /// The chip wearing a tag, through the actual AppKit title composition.
    @MainActor
    private static func verifyTagCapsule(_ t: UBUITestContext) {
        guard PhosphorIcons.icon(named: "house") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "project — shell"
        window.orderFront(nil)
        defer { window.close() }
        let proxy = ProxyIconRevealController(window: window)
        let chip = RemoteConnectionIndicator(window: window)
        proxy.connectionIndicator = chip
        func style() {
            proxy.applyTitleStyle(
                directorySegment: "project",
                baseTitleBeforeDirectory: "",
                trailingRegularSegment: "",
                dimColor: .secondaryLabelColor,
                brightColor: .labelColor,
                detailColor: .secondaryLabelColor
            )
        }
        func show(_ health: Ubiquitty.Session.Health = .Connected, tag: HostChipTag?, wash: NSColor? = nil) {
            chip.update(place: .Remote, health: health, host: "build-01", carrier: "ssh", hostTag: tag, titlebarWash: wash)
            style()
            t.pump(0.1)
        }
        let fill = NSColor(srgbRed: 105.0 / 255, green: 179.0 / 255, blue: 1, alpha: 1)
        let tag = HostChipTag(fill: fill, title: "lab", spokenName: "lab", iconName: "house", iconWeight: .Fill)

        show(tag: nil)
        let plainWidth = chip.frame.width
        t.expect(
            chip.capsuleFillForTesting == nil && chip.symbolNameForTesting == "globe",
            desc: "an untagged chip is the bare globe and name"
        )

        proxy.setTagMarkerObjects(
            [
                TitlebarTagMarker(
                    name: "lab",
                    spokenName: nil,
                    color: fill,
                    prominence: .quiet,
                    iconName: "house",
                    iconWeight: .Fill,
                    isHostTag: true
                ),
                TitlebarTagMarker(name: "prod", color: .systemRed, prominence: .quiet),
            ],
            titlebarTint: nil
        )
        show(tag: tag)
        guard let field = chip.superview as? NSTextField else {
            t.expect(false, desc: "the plain AppKit window exposes its real title field")
            return
        }
        let ink = TitlebarTagChip.labelColor(on: fill)
        t.expect(chip.capsuleFillForTesting == fill, desc: "the chip is one capsule of the tag's colour")
        t.expect(
            chip.tagIconNameForTesting == "house" && chip.symbolNameForTesting.isEmpty,
            desc: "the tag's icon stands where the globe did (\(chip.tagIconNameForTesting), \(chip.symbolNameForTesting))"
        )
        t.expect(
            chip.readingForTesting == "build-01" && chip.tagTitleForTesting == "lab",
            desc: "the capsule holds the machine's name and the tag's title"
        )
        t.expect(
            chip.hostInkForTesting == ink && chip.globeInkForTesting == ink,
            desc: "everything in it is in the ink that reads on the fill"
        )
        t.expect(
            chip.frame.width > plainWidth && abs(chip.frame.height - 22) <= 0.01 && TitlebarCapsuleGeometry.standardHeight == 22,
            desc: "the capsule is 22 points tall, as a tag's is, and wider than the bare chip (\(chip.frame) vs \(plainWidth))"
        )
        if let geometry = chip.capsuleGeometryForTesting {
            let described =
                "leading \(geometry.leading), icon \(geometry.iconSide), gap \(geometry.iconToName), trailing \(geometry.trailing)"
            t.expect(
                abs(geometry.leading - 9) <= 0.01 && geometry.trailing >= 9 - 0.01 && geometry.trailing < 10,
                desc: "nine points stand between each rounded end and what it holds (\(described))"
            )
            t.expect(abs(geometry.iconToName - 5) <= 0.01, desc: "five points stand between the icon and the name (\(described))")
            t.expect(abs(geometry.iconSide - 15) <= 0.01, desc: "the icon is 15 points, scaled to the capsule (\(described))")
        } else {
            t.expect(false, desc: "the capsule reports its geometry")
        }
        if let row = field.superview {
            let inRow = chip.convert(chip.bounds, to: row)
            t.expect(
                inRow.minY >= row.bounds.minY + 1 && inRow.maxY <= row.bounds.maxY - 1,
                desc: "the capsule clears the title row's top and bottom edges (\(inRow) in \(row.bounds))"
            )
        }
        t.expect(chip.capsuleFillOpacityForTesting == 1, desc: "without a style the fill is laid down whole")
        t.expect(field.bounds.contains(chip.frame), desc: "the title reserves the whole capsule (\(chip.frame) in \(field.bounds))")
        if let words = proxy.titleWordsFrameForTesting {
            t.expect(
                chip.frame.maxX <= words.minX + 0.5,
                desc: "the title's words start past the capsule (chip \(chip.frame), words \(words))"
            )
        } else {
            t.expect(false, desc: "the title has words past the capsule")
        }
        t.expect(titleMarks(field).count, equals: 1, desc: "the marker run leaves out the tag the chip wears")
        t.expect(titleChipCount(field), equals: 2, desc: "so each tag is drawn once")
        let spoken = field.accessibilityLabel() ?? ""
        t.expect(
            spoken.hasPrefix("Tagged lab, prod. Session on build-01 over SSH. Connected.")
                && spoken.components(separatedBy: "lab").count == 2,
            desc: "the title names every tag once, then the link (\(spoken))"
        )
        t.expect(
            chip.accessibilityLabel() == "Session on build-01 over SSH. Tagged lab. Connected."
                && chip.toolTip == chip.accessibilityLabel(),
            desc: "the chip's own description names its tag beside the link's state (\(chip.accessibilityLabel() ?? "nil"))"
        )

        // A link that is not steady keeps the fill and flags itself on a dot.
        show(.Reconnecting, tag: tag)
        t.expect(chip.capsuleFillForTesting == fill, desc: "a reconnect keeps the tag's fill")
        t.expect(chip.linkStatusColorForTesting == .systemOrange, desc: "and says the link's state on a flag-coloured dot")
        t.expect(chip.globeInkForTesting == ink, desc: "while the icon keeps the readable ink")
        t.expect(
            chip.accessibilityLabel() == "Session on build-01 over SSH. Tagged lab. Reconnecting.",
            desc: "the description says the state as it always has (\(chip.accessibilityLabel() ?? "nil"))"
        )
        show(tag: tag)
        t.expect(chip.linkStatusColorForTesting == nil, desc: "a steady link shows no dot")

        // Over a wash of its own colour the capsule is outlined.
        show(tag: tag, wash: fill)
        t.expect(chip.hasCapsuleBorderForTesting, desc: "a capsule on a wash of its own colour is outlined")
        show(tag: tag, wash: .systemRed)
        t.expect(!chip.hasCapsuleBorderForTesting, desc: "one on a wash of another colour is not")

        // An icon the catalog does not carry leaves the place's symbol.
        show(tag: HostChipTag(fill: fill, title: "", spokenName: "Blue", iconName: "no-such-icon", iconWeight: .Fill))
        t.expect(
            chip.tagIconNameForTesting.isEmpty && chip.symbolNameForTesting == "globe" && chip.capsuleFillForTesting == fill,
            desc: "an unknown icon draws the globe in the capsule"
        )
        t.expect(chip.tagTitleForTesting.isEmpty, desc: "and an untitled tag adds no title")
        t.expect(chip.accessibilityLabel()?.contains("Tagged Blue.") == true, desc: "the untitled tag is named by its colour")

        verifyTagStrength(t, chip: chip, proxy: proxy, field: field, tag: tag, fill: fill)

        // A long title gives way inside the chip's share of the window.
        window.setContentSize(NSSize(width: 400, height: 400))
        let long = String(repeating: "staging-", count: 12)
        show(tag: HostChipTag(fill: fill, title: long, spokenName: long, iconName: "house", iconWeight: .Fill))
        t.expect(
            chip.frame.width <= window.frame.width * 0.4 + 1,
            desc: "a long tag title keeps the capsule within its window-share budget (\(chip.frame.width))"
        )
        t.expect(chip.accessibilityLabel()?.contains(long) == true, desc: "truncation keeps the whole title in the description")

        // Withdrawn, the chip hands the host's tag back to the marker run.
        chip.withdraw()
        style()
        t.expect(titleMarks(field).count, equals: 2, desc: "without the chip the host's tag is a marker again")
        withExtendedLifetime(proxy) {}
    }

    /// The capsule and the marker beside it at a strength: the fill laid down
    /// at that opacity, and one concrete ink chosen against the fill as it
    /// composites over the row, on a themed row and a native one alike.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - chip: The chip, standing in the title of a window that also wears
    ///     one marker.
    ///   - proxy: The title row's controller.
    ///   - field: The title field.
    ///   - tag: The tag the chip wears.
    ///   - fill: The tag's colour.
    @MainActor
    private static func verifyTagStrength(
        _ t: UBUITestContext,
        chip: RemoteConnectionIndicator,
        proxy: ProxyIconRevealController,
        field: NSTextField,
        tag: HostChipTag,
        fill: NSColor
    ) {
        func show(_ style: TitlebarTagStyle) {
            chip.update(place: .Remote, health: .Connected, host: "build-01", carrier: "ssh", hostTag: tag, tagStyle: style)
            proxy.setTagStyle(style)
            proxy.applyTitleStyle(
                directorySegment: "project",
                baseTitleBeforeDirectory: "",
                trailingRegularSegment: "",
                dimColor: .secondaryLabelColor,
                brightColor: .labelColor,
                detailColor: .secondaryLabelColor
            )
            t.pump(0.1)
        }
        // A dark themed row.
        let darkRow = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        let half = TitlebarTagStyle(opacity: 0.5, ground: darkRow)
        show(half)
        t.expect(chip.capsuleFillForTesting == fill, desc: "at half strength the capsule is still the tag's colour")
        t.expect(chip.capsuleFillOpacityForTesting == 0.5, desc: "laid down at half its opacity")
        let alpha = drawnAlpha(of: chip, at: NSPoint(x: chip.bounds.maxX - 3, y: chip.bounds.midY)) ?? 0
        t.expect(abs(alpha - 0.5) <= 0.06, desc: "and the capsule paints its fill at that alpha (\(alpha))")
        let halfInk = TitlebarTagChip.ink(onFill: fill, style: half, appearance: chip.effectiveAppearance)
        t.expect(
            chip.capsuleInkForTesting == halfInk && chip.hostInkForTesting == halfInk && chip.globeInkForTesting == halfInk,
            desc: "the capsule's name and icon take Core's ink for the composite, one colour (\(halfInk))"
        )
        let marker = titleMarks(field).first
        t.expect(marker?.fillOpacity == 0.5, desc: "the marker beside it is laid down at the same strength")
        if let image = marker?.image {
            let markerAlpha = drawnAlpha(of: image, at: NSPoint(x: 3, y: image.size.height / 2)) ?? 0
            t.expect(abs(markerAlpha - 0.5) <= 0.06, desc: "and paints its fill at that alpha (\(markerAlpha))")
            t.expect(abs(markerAlpha - alpha) <= 0.02, desc: "the alpha the chip paints its own at (\(markerAlpha) vs \(alpha))")
        }

        // The ink follows the composite, not the colour alone: a pale yellow
        // carries dark ink at full strength, and light ink once a dark row
        // shows through it.
        let yellow = NSColor(srgbRed: 242.0 / 255, green: 222.0 / 255, blue: 84.0 / 255, alpha: 1)
        let appearance = chip.effectiveAppearance
        let whole = TitlebarTagChip.ink(onFill: yellow, style: .fullStrength, appearance: appearance)
        let faint = TitlebarTagChip.ink(onFill: yellow, style: TitlebarTagStyle(opacity: 0.2, ground: darkRow), appearance: appearance)
        t.expect(
            (whole.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 && (faint.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.5,
            desc: "a faint yellow over a dark row takes light ink where a whole one takes dark (\(whole), \(faint))"
        )

        // A row whose text is the system's takes the same rule: one concrete
        // colour for the composite, never the system's label colour, and no
        // part of the capsule drawn under an appearance of its own.
        let native = TitlebarTagStyle(opacity: 0.5, ground: .windowBackgroundColor)
        show(native)
        let nativeInk = TitlebarTagChip.ink(onFill: fill, style: native, appearance: chip.effectiveAppearance)
        t.expect(
            chip.hostInkForTesting == nativeInk && chip.globeInkForTesting == nativeInk && chip.hostInkForTesting != .labelColor,
            desc: "a native row's capsule draws Core's ink for its composite, not the system's label colour (\(nativeInk))"
        )
        t.expect(
            chip.subviews.allSatisfy { $0.appearance == nil },
            desc: "and nothing in it is drawn under an appearance other than the row's"
        )
        // The marker is the window's red tag; its ink is chosen for its own fill.
        let markerInk = TitlebarTagChip.ink(onFill: .systemRed, style: native, appearance: field.effectiveAppearance)
        t.expect(
            titleMarks(field).first?.ink == markerInk,
            desc: "and the marker takes the concrete ink its own composite calls for (\(markerInk))"
        )

        show(.fullStrength)
        t.expect(chip.capsuleFillOpacityForTesting == 1, desc: "full strength lays the capsule's fill down whole")
    }

    /// The title row's tags as one stack of overlapping pills, through the
    /// actual AppKit title composition.
    ///
    /// A circle and a titled pill lead the chip. Each tucks under the next by
    /// the geometry's overlap and reaches as far past its own content, the
    /// last under the chip; a band of the row shows between each pair; nothing
    /// a lower pill holds is covered; every pill is one height on one line,
    /// its text on the title's baseline and its icon in its text's colour; and
    /// the markers and the chip lay their fills down at one alpha.
    @MainActor
    private static func verifyTagStack(_ t: UBUITestContext) {
        guard PhosphorIcons.icon(named: "house") != nil, PhosphorIcons.icon(named: "star") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "project — shell"
        window.orderFront(nil)
        defer { window.close() }
        let proxy = ProxyIconRevealController(window: window)
        let chip = RemoteConnectionIndicator(window: window)
        proxy.connectionIndicator = chip
        let red = NSColor(srgbRed: 236.0 / 255, green: 129.0 / 255, blue: 113.0 / 255, alpha: 1)
        let half = TitlebarTagStyle(opacity: 0.5, ground: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        let hostTag = HostChipTag(fill: red, title: "lab", spokenName: "lab", iconName: "house", iconWeight: .Fill)
        let hostMarker = TitlebarTagMarker(
            name: "lab",
            spokenName: nil,
            color: red,
            prominence: .quiet,
            iconName: "house",
            iconWeight: .Fill,
            isHostTag: true
        )
        let dot = TitlebarTagMarker(name: "", spokenName: "Red", color: red, prominence: .quiet)
        let iconDot = TitlebarTagMarker(
            name: "",
            spokenName: "Red",
            color: red,
            prominence: .quiet,
            iconName: "star",
            iconWeight: .Fill,
            isHostTag: false
        )
        // A name without descenders, so its lowest ink is its baseline.
        let beta = TitlebarTagMarker(
            name: "beta",
            spokenName: nil,
            color: red,
            prominence: .quiet,
            iconName: "star",
            iconWeight: .Fill,
            isHostTag: false
        )
        func show(_ markers: [TitlebarTagMarker], chipWears tag: HostChipTag?) {
            proxy.setTagMarkerObjects(markers, titlebarTint: nil)
            proxy.setTagStyle(half)
            if let tag {
                chip.update(place: .Remote, health: .Connected, host: "build-01", carrier: "ssh", hostTag: tag, tagStyle: half)
            } else {
                chip.withdraw()
            }
            proxy.applyTitleStyle(
                directorySegment: "project",
                baseTitleBeforeDirectory: "",
                trailingRegularSegment: "",
                dimColor: .secondaryLabelColor,
                brightColor: .labelColor,
                detailColor: .secondaryLabelColor
            )
            t.pump(0.2)
        }

        show([hostMarker, dot, beta], chipWears: hostTag)
        guard let field = chip.superview as? NSTextField, let titleFont = field.font, let stack = titleTagStack(field),
            let image = stack.image, let span = proxy.titleTagStackSpanForTesting, stack.marks.count == 2
        else {
            t.expect(false, desc: "the title leads with a stack of the circle and the titled pill, the chip's tag left to the chip")
            return
        }
        let geometry = TitlebarCapsuleGeometry(titleFont: titleFont)
        let (circle, pill) = (stack.marks[0], stack.marks[1])
        let overlap = geometry.overlap
        let knockout = TitlebarCapsuleGeometry.knockout
        let chipStartInStack = pill.frame.minX + pill.visibleWidth
        let titleBaseline =
            field.isFlipped ? field.firstBaselineOffsetFromTop : field.bounds.height - field.firstBaselineOffsetFromTop
        /// A height measured up from the title's baseline, as the field
        /// places it.
        func inField(_ height: CGFloat) -> CGFloat {
            field.isFlipped ? titleBaseline - height : titleBaseline + height
        }

        // The overlap: each pill reaches under the next by as much as it is
        // tucked, and the last under the chip.
        t.expect(
            abs(overlap - (geometry.height / 2).rounded(.up)) <= 0.01,
            desc: "a pill tucks half its height under the next (\(overlap) of \(geometry.height))"
        )
        t.expect(
            circle.isUntitled && circle.isTucked && abs(circle.visibleWidth - geometry.crescentWidth) <= 0.01
                && circle.visibleWidth < geometry.height,
            desc: "the untitled tag is a circle showing a crescent of itself (\(circle.visibleWidth) of \(geometry.height))"
        )
        t.expect(
            abs(pill.frame.minX - (circle.frame.minX + circle.visibleWidth)) <= 0.01
                && abs(circle.frame.maxX - pill.frame.minX - overlap) <= 0.01,
            desc: "the pill starts where the circle's crescent ends, over the circle's reach (circle \(circle.frame), pill \(pill.frame))"
        )
        t.expect(
            stack.isTuckedUnderHostChip && pill.isTucked && abs(pill.frame.width - pill.visibleWidth - overlap) <= 0.01
                && abs(image.size.width - pill.frame.maxX) <= 0.01,
            desc: "the pill reaches as far under the chip, and the stack ends there (\(pill.frame), image \(image.size))"
        )
        verifySquareEnds(t, [circle, pill], geometry: geometry)
        verifyBalancedInk(t, pill, geometry: geometry)
        t.expect(
            abs(chip.frame.minX - (span.lowerBound + chipStartInStack)) <= 0.5 && abs(span.upperBound - chip.frame.minX - overlap) <= 0.5,
            desc: "the chip stands over the stack's last reach (chip at \(chip.frame.minX), stack \(span))"
        )

        // One height on one centre line, every text on the title's baseline.
        for mark in stack.marks {
            t.expect(
                abs(mark.bounds.height - geometry.height) <= 0.01 && abs(mark.bounds.minY - geometry.bottomFromTitleBaseline) <= 0.01
                    && abs(mark.bounds.midY - titleFont.capHeight / 2) <= 0.01,
                desc: "'\(mark.name)' is a pill's height, centred on the title's cap band (\(mark.bounds), cap \(titleFont.capHeight))"
            )
        }
        t.expect(
            abs(chip.frame.height - geometry.height) <= 0.01 && abs(chip.frame.midY - inField(circle.bounds.midY)) <= 0.5,
            desc: "the chip is as tall, on the same centre line (chip \(chip.frame), line \(inField(circle.bounds.midY)))"
        )
        let chipBaseline = field.convert(NSPoint(x: 0, y: chip.hostLabelBaselineOffsetFromBottom), from: chip).y
        t.expect(
            abs(chipBaseline - titleBaseline) <= 0.51,
            desc: "the chip's name stands on the title's baseline (\(chipBaseline) vs \(titleBaseline))"
        )
        if let text = pill.textFrame {
            t.expect(
                abs(pill.bounds.minY + text.minY) <= 0.01,
                desc: "the pill's text is drawn on the title's baseline (\(pill.bounds.minY + text.minY) from it)"
            )
            let inkBottom = solidPixels(of: pill.image, in: text.insetBy(dx: 0, dy: -3)).map(\.bottom).min()
            t.expect(
                inkBottom.map { abs($0 - text.minY) <= 0.75 } == true,
                desc: "and its ink sits there (\(inkBottom.map { "\($0)" } ?? "no ink") vs \(text.minY))"
            )
        } else {
            t.expect(false, desc: "the titled pill reports its text")
        }

        // Each pill's icon is drawn in its text's colour, the pill's ink.
        if let ink = pill.ink, let iconFrame = pill.iconFrame, let text = pill.textFrame {
            let iconInk = solidPixels(of: pill.image, in: iconFrame).map(\.color)
            let textInk = solidPixels(of: pill.image, in: text.insetBy(dx: 0, dy: -3)).map(\.color)
            t.expect(
                !iconInk.isEmpty && !textInk.isEmpty && (iconInk + textInk).allSatisfy { isSameSRGBColor($0, ink, tolerance: 0.03) },
                desc: "the pill's icon and text are drawn in one ink (\(ink); \(iconInk.count) icon and \(textInk.count) text pixels)"
            )
        } else {
            t.expect(false, desc: "the titled pill reports its ink, icon and text")
        }
        t.expect(circle.ink == nil, desc: "a circle holding nothing has no ink")
        if let frames = chip.capsuleContentFramesForTesting, let ink = chip.capsuleInkForTesting {
            let iconInk = solidPixels(of: chip, in: frames.icon)
            let nameInk = solidPixels(of: chip, in: frames.name)
            t.expect(
                !iconInk.isEmpty && !nameInk.isEmpty
                    && (iconInk + nameInk).allSatisfy { isSameSRGBColor($0.color, ink, tolerance: 0.05) },
                desc:
                    "the chip's icon is drawn in its name's colour, the capsule's ink (\(ink); \(iconInk.count) icon and \(nameInk.count) name pixels)"
            )
            let nameBottom = nameInk.map(\.bottom).min()
            t.expect(
                nameBottom.map { abs($0 - chip.hostLabelBaselineOffsetFromBottom) <= 0.75 } == true,
                desc:
                    "and the name's ink sits on the baseline (\(nameBottom.map { "\($0)" } ?? "no ink") vs \(chip.hostLabelBaselineOffsetFromBottom))"
            )
        } else {
            t.expect(false, desc: "the chip reports its capsule's ink and content")
        }

        // One strength: the circle, the pill and the chip lay their fills down
        // at one alpha, alone and in the title as drawn.
        let chipAlpha = drawnAlpha(of: chip, at: NSPoint(x: chip.bounds.maxX - 3, y: chip.bounds.midY)) ?? 0
        let pillAlpha = drawnAlpha(of: pill.image, at: NSPoint(x: 3, y: geometry.height / 2)) ?? 0
        let circleAlpha = drawnAlpha(of: circle.image, at: NSPoint(x: geometry.height / 2, y: geometry.height / 2)) ?? 0
        t.expect(
            [chipAlpha, pillAlpha, circleAlpha].allSatisfy { abs($0 - 0.5) <= 0.03 }
                && abs(pillAlpha - chipAlpha) <= 0.02 && abs(circleAlpha - chipAlpha) <= 0.02,
            desc:
                "at strength 0.5 the circle, the pill and the chip lay their fills down at one alpha (\(circleAlpha), \(pillAlpha), \(chipAlpha))"
        )
        if let rep = drawnBitmap(of: field) {
            let markerFill = drawnColor(
                in: rep,
                of: field,
                at: NSPoint(x: span.lowerBound + pill.frame.minX + 3, y: inField(pill.bounds.midY))
            )
            let chipFill = drawnColor(
                in: rep,
                of: field,
                at: field.convert(NSPoint(x: chip.bounds.maxX - 3, y: chip.bounds.midY), from: chip)
            )
            let markerAlpha = markerFill?.alphaComponent ?? 0
            t.expect(
                abs(markerAlpha - 0.5) <= 0.03 && abs(markerAlpha - (chipFill?.alphaComponent ?? 0)) <= 0.02
                    && isSameSRGBColor(markerFill, chipFill, tolerance: 0.02),
                desc:
                    "in the title as drawn, the marker's fill and the chip's are one alpha and one colour (\(String(describing: markerFill)) vs \(String(describing: chipFill)))"
            )
        }

        // The knockout: a band cut out of each lower pill along the next one's
        // start, the lower pill laid down right up to it, and no fill over
        // another where one reaches under the next.
        if let stackRep = drawnBitmap(of: image) {
            let line = geometry.height / 2
            func stackAlpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                drawnColor(in: stackRep, size: image.size, at: NSPoint(x: x, y: y))?.alphaComponent ?? -1
            }
            let starts = [pill.frame.minX, chipStartInStack]
            let gaps = starts.map { stackAlpha($0 - knockout / 2, line) }
            let beside = starts.map { stackAlpha($0 - knockout - 0.75, line) }
            t.expect(gaps.allSatisfy { $0 >= 0 && $0 <= 0.02 }, desc: "a band is cut out of each lower pill along the next start (\(gaps))")
            t.expect(beside.allSatisfy { abs($0 - 0.5) <= 0.03 }, desc: "and the lower pill is laid down right up to it (\(beside))")
            // The pill's own icon and text are opaque ink, not a second fill.
            let pillContent = [pill.iconFrame, pill.textFrame].compactMap { $0?.offsetBy(dx: pill.frame.minX, dy: 0) }
            var deepest: CGFloat = 0
            for x in stride(from: pill.frame.minX, to: circle.frame.maxX, by: 0.5) {
                for y in stride(from: 0.25, to: geometry.height, by: 0.5)
                where !pillContent.contains(where: { $0.insetBy(dx: -1, dy: -3).contains(NSPoint(x: x, y: y)) }) {
                    deepest = max(deepest, stackAlpha(x, y))
                }
            }
            t.expect(deepest <= 0.53, desc: "where the circle reaches under the pill, no fill lands on another (deepest alpha \(deepest))")
        }
        if let row = field.superview, let rowRep = drawnBitmap(of: row) {
            let line = inField(circle.bounds.midY)
            func rowColor(_ x: CGFloat) -> NSColor? {
                drawnColor(in: rowRep, of: row, at: row.convert(NSPoint(x: x, y: line), from: field))
            }
            let ground = rowColor(span.lowerBound - 4)
            for (name, start) in [
                ("the circle and the pill", span.lowerBound + pill.frame.minX), ("the pill and the chip", chip.frame.minX),
            ] {
                let seen = rowColor(start - knockout / 2)
                t.expect(
                    isSameSRGBColor(seen, ground, tolerance: 0.02)
                        && abs((seen?.alphaComponent ?? -1) - (ground?.alphaComponent ?? -2)) <= 0.02,
                    desc:
                        "the band between \(name) shows the row's own pixels (\(String(describing: seen)) vs \(String(describing: ground)))"
                )
            }
        } else {
            t.expect(false, desc: "the title row can be drawn")
        }

        // Nothing a lower pill holds is covered.
        verifyUncovered(t, [circle, pill], in: image, nextStarts: [pill.frame.minX, chipStartInStack], geometry: geometry)

        // Unchanged: the title names every tag once, then the link; the chip's
        // tooltip is its description; and the chip stays inside the title,
        // whose rect takes the row's clicks.
        let spoken = field.accessibilityLabel() ?? ""
        t.expect(
            spoken.hasPrefix("Tagged lab, Red, beta. Session on build-01 over SSH. Connected."),
            desc: "the title names every tag once, then the link (\(spoken))"
        )
        t.expect(
            chip.toolTip == "Session on build-01 over SSH. Tagged lab. Connected." && chip.toolTip == chip.accessibilityLabel(),
            desc: "the chip's tooltip is its description (\(chip.toolTip ?? "nil"))"
        )
        t.expect(field.bounds.contains(chip.frame), desc: "the chip stands inside the title (\(chip.frame) in \(field.bounds))")
        if let words = proxy.titleWordsFrameForTesting {
            t.expect(chip.frame.maxX <= words.minX + 0.5, desc: "and the title's words start past it (chip \(chip.frame), words \(words))")
        }

        // A circle holding an icon: the icon in the circle's ink, uncovered.
        show([hostMarker, iconDot, beta], chipWears: hostTag)
        if let stack = titleTagStack(chip.superview as? NSTextField), let image = stack.image, stack.marks.count == 2 {
            let (circle, pill) = (stack.marks[0], stack.marks[1])
            if let ink = circle.ink, let iconFrame = circle.iconFrame {
                let iconInk = solidPixels(of: circle.image, in: iconFrame).map(\.color)
                t.expect(
                    circle.iconName == "star" && !iconInk.isEmpty && iconInk.allSatisfy { isSameSRGBColor($0, ink, tolerance: 0.03) },
                    desc: "a circle's icon is drawn in the circle's ink (\(ink), \(iconInk.count) pixels)"
                )
            } else {
                t.expect(false, desc: "the circle reports its icon and ink")
            }
            verifyUncovered(
                t,
                [circle, pill],
                in: image,
                nextStarts: [pill.frame.minX, pill.frame.minX + pill.visibleWidth],
                geometry: geometry
            )
        } else {
            t.expect(false, desc: "the stack leads with the icon's circle and the titled pill")
        }

        // A single tag stays a plain pill, with the air before the title.
        show([beta], chipWears: nil)
        if let single = titleTagStack(chip.superview as? NSTextField), let only = single.marks.first, single.marks.count == 1 {
            t.expect(
                !single.isTuckedUnderHostChip && !only.isTucked && abs(only.frame.width - only.visibleWidth) <= 0.01
                    && abs((single.image?.size.width ?? 0) - only.visibleWidth - TitlebarCapsuleGeometry.gapAfterStack) <= 0.01,
                desc: "a single tag is a plain pill, reaching under nothing (\(only.frame), image \(single.image?.size ?? .zero))"
            )
        } else {
            t.expect(false, desc: "a single tag draws one pill")
        }

        // The chip wearing the window's one tag stands alone.
        show([hostMarker], chipWears: hostTag)
        t.expect(
            titleTagStack(chip.superview as? NSTextField) == nil && proxy.titleTagStackSpanForTesting == nil && chip.isWearingTagCapsule,
            desc: "a chip wearing the window's one tag has no stack to tuck under it"
        )
        withExtendedLifetime(proxy) {}
    }

    /// Asserts that each tucked pill, drawn alone, fills the corners of the
    /// end the next pill covers, where a rounded end would leave them clear.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - marks: The tucked pills.
    ///   - geometry: The row's pill geometry.
    @MainActor
    private static func verifySquareEnds(_ t: UBUITestContext, _ marks: [TitlebarTagMark], geometry: TitlebarCapsuleGeometry) {
        for mark in marks {
            guard let alone = drawnBitmap(of: mark.image) else {
                t.expect(false, desc: "'\(mark.name)' can be drawn")
                continue
            }
            let corners = [0.75, geometry.height - 0.75]
                .map {
                    drawnColor(in: alone, size: mark.image.size, at: NSPoint(x: mark.frame.width - 0.75, y: $0))?.alphaComponent ?? 0
                }
            t.expect(
                corners.allSatisfy { $0 > 0.2 },
                desc: "'\(mark.name)' is square at the end under the next pill (corner alphas \(corners))"
            )
        }
    }

    /// Asserts that a tucked pill's ink keeps less air before the knockout
    /// than after its rounded start, by the hollow's allowance, to within the
    /// half point the width rounds by and the half point an edge pixel blurs.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - mark: The tucked pill.
    ///   - geometry: The row's pill geometry.
    @MainActor
    private static func verifyBalancedInk(_ t: UBUITestContext, _ mark: TitlebarTagMark, geometry: TitlebarCapsuleGeometry) {
        guard let ink = mark.ink, let alone = drawnBitmap(of: mark.image) else {
            t.expect(false, desc: "'\(mark.name)' reports its ink and can be drawn")
            return
        }
        let inkColumns = stride(from: CGFloat(0.25), to: mark.frame.width, by: 0.5)
            .filter { x in
                stride(from: CGFloat(0.25), to: geometry.height, by: 0.5)
                    .contains { y in
                        drawnColor(in: alone, size: mark.image.size, at: NSPoint(x: x, y: y))
                            .map { isSameSRGBColor($0, ink, tolerance: 0.03) } == true
                    }
            }
        guard let first = inkColumns.first, let last = inkColumns.last else {
            t.expect(false, desc: "'\(mark.name)' draws ink")
            return
        }
        let leading = first - 0.25
        let trailing = mark.visibleWidth - TitlebarCapsuleGeometry.knockout - (last + 0.25)
        let difference = leading - trailing - geometry.hollowAllowance
        t.expect(
            abs(difference) <= 1.1 && trailing >= TitlebarCapsuleGeometry.contentClearance,
            desc: "'\(mark.name)'s ink sits balanced against the hollow at its end (\(leading) before, \(trailing) after)"
        )
    }

    /// Asserts that each lower pill's content stops short of the next pill's
    /// start and its cut, and that the stack paints the pixels of that content
    /// as the pill drawn alone does.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - marks: The lower pills, in order.
    ///   - stack: The stack's image.
    ///   - nextStarts: Where the pill over each starts, in the stack's image.
    ///   - geometry: The row's pill geometry.
    @MainActor
    private static func verifyUncovered(
        _ t: UBUITestContext,
        _ marks: [TitlebarTagMark],
        in stack: NSImage,
        nextStarts: [CGFloat],
        geometry: TitlebarCapsuleGeometry
    ) {
        guard let stackRep = drawnBitmap(of: stack) else {
            t.expect(false, desc: "the stack can be drawn")
            return
        }
        for (mark, next) in zip(marks, nextStarts) {
            let content = [mark.iconFrame, mark.textFrame].compactMap { $0 }.reduce(NSRect.null) { $0.union($1) }
            guard !content.isNull, let alone = drawnBitmap(of: mark.image) else { continue }
            t.expect(
                mark.frame.minX + content.maxX <= next - TitlebarCapsuleGeometry.knockout - 1,
                desc: "'\(mark.name)'s content ends before the next pill's start and its cut (\(mark.frame.minX + content.maxX) vs \(next))"
            )
            var worst: CGFloat = 0
            for x in stride(from: content.minX + 0.25, to: content.maxX, by: 0.5) {
                for y in stride(from: 0.25, to: geometry.height, by: 0.5) {
                    let inStack = drawnColor(in: stackRep, size: stack.size, at: NSPoint(x: mark.frame.minX + x, y: y))
                    let drawnAlone = drawnColor(in: alone, size: mark.image.size, at: NSPoint(x: x, y: y))
                    worst = max(worst, componentDistance(inStack, drawnAlone))
                }
            }
            t.expect(worst <= 0.01, desc: "nothing covers '\(mark.name)'s icon or text in the stack (largest difference \(worst))")
        }
    }

    /// The largest difference between two colours' stored components, alpha
    /// included; 1 when either is missing.
    private static func componentDistance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a = a?.usingType(.componentBased), let b = b?.usingType(.componentBased),
            a.numberOfComponents >= 3, b.numberOfComponents >= 3
        else { return 1 }
        return max(
            abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent),
            abs(a.alphaComponent - b.alphaComponent)
        )
    }

    /// Exercises the actual AppKit title composition without starting a shell or contacting a host.
    @MainActor
    private static func verifyTitleBaseline(_ t: UBUITestContext) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "project — shell"
        window.orderFront(nil)
        defer { window.close() }
        let proxy = ProxyIconRevealController(window: window)
        let chip = RemoteConnectionIndicator(window: window)
        proxy.connectionIndicator = chip
        func style() {
            proxy.applyTitleStyle(
                directorySegment: "project",
                baseTitleBeforeDirectory: "",
                trailingRegularSegment: "",
                dimColor: .secondaryLabelColor,
                brightColor: .labelColor,
                detailColor: .secondaryLabelColor
            )
        }
        chip.update(place: .ThisMachine, health: .Connected, host: "", carrier: "")
        style()
        t.pump(0.1)
        guard let field = chip.superview as? NSTextField else {
            t.expect(false, desc: "the plain AppKit window exposes its real title field")
            return
        }
        let titleFonts = [
            NSFont.systemFont(ofSize: 11, weight: .semibold),
            NSFont.systemFont(ofSize: 13, weight: .semibold),
            NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            NSFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        for titleFont in titleFonts {
            for hasTag in [false, true] {
                field.font = titleFont
                proxy.setTagMarkerObjects(
                    hasTag ? [TitlebarTagMarker(name: "devbox", color: .systemGreen, prominence: .loud)] : [],
                    titlebarTint: nil
                )
                style()
                guard let label = chip.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "This Mac" }),
                    let font = label.font
                else {
                    t.expect(false, desc: "the connection exposes its label")
                    continue
                }
                let titleBaseline =
                    field.isFlipped ? field.firstBaselineOffsetFromTop : field.bounds.height - field.firstBaselineOffsetFromTop
                let labelBaseline =
                    label.isFlipped ? label.firstBaselineOffsetFromTop : label.bounds.height - label.firstBaselineOffsetFromTop
                let actualBaseline = field.convert(NSPoint(x: 0, y: labelBaseline), from: label).y
                let context =
                    "font=\(titleFont.fontName) \(titleFont.pointSize), tag=\(hasTag), baseline=\(actualBaseline)/\(titleBaseline)"
                t.expect(font == field.font, desc: "the host uses the title font (\(context))")
                t.expect(abs(actualBaseline - titleBaseline) < 0.51, desc: "host and title share a baseline (\(context))")
                expectIconOnCapBand(t, chip: chip, context: context)
                t.expect(field.bounds.contains(chip.frame), desc: "the title reserves the complete host span (\(context))")
                t.expect(chip.hostInkForTesting == .secondaryLabelColor, desc: "the host remains secondary text")
            }
        }
        let longHost = String(repeating: "long-host-", count: 20)
        chip.update(place: .Remote, health: .Connected, host: longHost, carrier: "quic")
        style()
        let wideWidth = chip.frame.width
        window.setContentSize(NSSize(width: 400, height: 400))
        chip.update(place: .Remote, health: .Connected, host: longHost, carrier: "quic")
        style()
        t.expect(chip.frame.width < wideWidth, desc: "a long host gives back title width when the window shrinks")
        t.expect(chip.frame.width <= window.frame.width * 0.4 + 1, desc: "the host remains within its window-share budget")
        t.expect(chip.accessibilityLabel()?.contains(longHost) == true, desc: "truncation preserves the complete accessible host identity")
        if let capturePath = ProcessInfo.processInfo.environment["UBQ_HOST_CHIP_CAPTURE"] {
            window.setContentSize(NSSize(width: 900, height: 400))
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            chip.update(place: .ThisMachine, health: .Connected, host: "", carrier: "")
            style()
            t.pump(0.2)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), capturePath]
            do {
                try capture.run()
                capture.waitUntilExit()
                t.expect(capture.terminationStatus == 0, desc: "the actual native title window was captured")
            } catch {
                t.expect(false, desc: "the native title capture started (\(error))")
            }
        }
        withExtendedLifetime(proxy) {}
    }

    /// Every icon the title row draws beside text stands on that text's cap
    /// band: in each title face, each place's symbol on the bare chip and in a
    /// tag's capsule, a tag's icon in the capsule, and a tag's icon in its own
    /// pill; and in each status face, every symbol a program's status shows.
    @MainActor
    private static func verifyIconsOnCapBand(_ t: UBUITestContext) {
        guard PhosphorIcons.icon(named: "house") != nil, PhosphorIcons.icon(named: "star") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "project — shell"
        window.orderFront(nil)
        defer { window.close() }
        let proxy = ProxyIconRevealController(window: window)
        let chip = RemoteConnectionIndicator(window: window)
        proxy.connectionIndicator = chip
        func style() {
            proxy.applyTitleStyle(
                directorySegment: "project",
                baseTitleBeforeDirectory: "",
                trailingRegularSegment: "",
                dimColor: .secondaryLabelColor,
                brightColor: .labelColor,
                detailColor: .secondaryLabelColor
            )
        }
        chip.update(place: .ThisMachine, health: .Connected, host: "", carrier: "")
        style()
        t.pump(0.1)
        guard let field = chip.superview as? NSTextField else {
            t.expect(false, desc: "the plain AppKit window exposes its real title field")
            return
        }
        let places: [(place: Ubiquitty.Session.HostPlace, host: String, carrier: String, isShared: Bool, symbol: String)] = [
            (.ThisMachine, "", "", false, "desktopcomputer"),
            (.ThisMachine, "", "", true, "desktopcomputer"),
            (.Remote, "build-01", "ssh", false, "globe"),
            (.Remote, "build-01", "quic", false, "globe.fill"),
        ]
        let fill = NSColor(srgbRed: 105.0 / 255, green: 179.0 / 255, blue: 1, alpha: 1)
        let tags: [(wearing: String, tag: HostChipTag?)] = [
            ("bare", nil),
            ("capsule", HostChipTag(fill: fill, title: "lab", spokenName: "lab", iconName: "", iconWeight: .Fill)),
            ("capsule with icon", HostChipTag(fill: fill, title: "lab", spokenName: "lab", iconName: "house", iconWeight: .Fill)),
        ]
        let marker = TitlebarTagMarker(
            name: "beta",
            spokenName: nil,
            color: fill,
            prominence: .quiet,
            iconName: "star",
            iconWeight: .Fill,
            isHostTag: false
        )
        let titleFonts = [
            NSFont.titleBarFont(ofSize: 0),
            NSFont.systemFont(ofSize: 11, weight: .semibold),
            NSFont.systemFont(ofSize: 13, weight: .regular),
            NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            NSFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        for titleFont in titleFonts {
            field.font = titleFont
            proxy.setTagMarkerObjects([marker], titlebarTint: nil)
            for place in places {
                for (wearing, tag) in tags {
                    chip.update(
                        place: place.place,
                        health: .Connected,
                        host: place.host,
                        carrier: place.carrier,
                        isShared: place.isShared,
                        hostTag: tag
                    )
                    style()
                    let context =
                        "font=\(titleFont.fontName) \(titleFont.pointSize), \(place.symbol), shared=\(place.isShared), \(wearing)"
                    let drawsTagIcon = tag.map { !$0.iconName.isEmpty } ?? false
                    t.expect(
                        drawsTagIcon
                            ? chip.tagIconNameForTesting == "house" && chip.symbolNameForTesting.isEmpty
                            : chip.symbolNameForTesting == place.symbol,
                        desc:
                            "the chip draws its state's icon (\(context): '\(chip.symbolNameForTesting)', '\(chip.tagIconNameForTesting)')"
                    )
                    expectIconOnCapBand(t, chip: chip, context: context)
                }
            }
            let pills = titleMarks(field).filter { $0.iconFrame != nil }
            t.expect(!pills.isEmpty, desc: "the title draws a tag's pill with an icon (font=\(titleFont.fontName) \(titleFont.pointSize))")
            for pill in pills {
                guard let iconFrame = pill.iconFrame else { continue }
                // The pill's icon fills its square, so the square's centre is
                // the icon's cap band's; both are measured from the title's
                // baseline.
                let iconCenter = pill.bounds.minY + iconFrame.midY
                let capCenter = titleFont.capHeight / 2
                t.expect(
                    abs(iconCenter - capCenter) <= 0.5,
                    desc:
                        "the icon in '\(pill.name)' is centred on the cap band (\(titleFont.fontName) \(titleFont.pointSize): \(iconCenter) vs \(capCenter))"
                )
            }
        }

        let statuses = (UInt8(0)...UInt8(7)).compactMap(HostOutlineStatus.init(rawValue:))
        let blockKinds = (UInt8(0)...UInt8(3)).compactMap(HostOutlineBlockKind.init(rawValue:))
        let statusSymbols = Set(
            statuses.flatMap { status in blockKinds.map { status.symbolName(blockKind: $0) } } + [TabStatusMark.workingSymbolName]
        )
        let statusWords = "Waiting"
        proxy.programStatusTitle = statusWords
        for face in [TitleStatusFace(size: .title), TitleStatusFace(size: .smaller)] {
            proxy.statusFace = face
            for name in statusSymbols.sorted() {
                proxy.programStatusSymbol = TitleStatusSymbol(name: name, ink: nil)
                style()
                expectStatusSymbolOnCapBand(t, field: field, name: name, statusWords: statusWords)
            }
        }
        proxy.programStatusSymbol = nil
        proxy.programStatusTitle = ""
        withExtendedLifetime(proxy) {}
    }

    /// Expects the title's program-status symbol to stand on the status's cap
    /// band: the centre of the symbol's own cap band, its alignment rect,
    /// within half a point of the centre of the status face's.
    ///
    /// The symbol is the attachment before the status's words, and the face is
    /// the one its character is set in. The attachment
    /// draws a tinted copy of the symbol at the symbol's size, so the symbol
    /// set in that face carries the cap band the copy is placed by.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - field: The title field.
    ///   - name: The status's symbol.
    ///   - statusWords: What the program says it is doing.
    @MainActor
    private static func expectStatusSymbolOnCapBand(_ t: UBUITestContext, field: NSTextField, name: String, statusWords: String) {
        let value = field.attributedStringValue
        // The symbol, then a space, then the words.
        let location = value.length - (statusWords as NSString).length - 2
        guard location >= 0,
            let attachment = value.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment,
            let font = value.attribute(.font, at: location, effectiveRange: nil) as? NSFont,
            let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))
        else {
            t.expect(false, desc: "the title ends with the status symbol '\(name)' and its words (\(value.string))")
            return
        }
        let context = "'\(name)' at \(font.pointSize) points"
        t.expect(
            attachment.bounds.size == glyph.size,
            desc: "the status symbol is drawn at its own size (\(context), \(attachment.bounds) for \(glyph.size))"
        )
        let symbolCenter = attachment.bounds.minY + glyph.alignmentRect.midY
        let capCenter = font.capHeight / 2
        t.expect(
            abs(symbolCenter - capCenter) <= 0.5,
            desc: "the status symbol's cap band is centred on the status's (\(context), symbol \(symbolCenter), cap \(capCenter))"
        )
    }

    /// Expects the chip's icon to stand on its name's cap band: the centre of
    /// the icon's own cap band within half a point of the centre of the name's.
    ///
    /// The icon's cap band is its image's alignment rect: a system symbol's
    /// runs from its baseline to its cap line, and a drawn icon's is its whole
    /// square. The image view draws every image at its own size, so the rect
    /// stands where the image's drawing does. The icon fills its square along
    /// its longer side: the capsule's icon square, or the bare chip's, a little
    /// over the title's point size, where the symbol's ink stays inside the
    /// chip's line.
    ///
    /// - Parameters:
    ///   - t: The running context.
    ///   - chip: The chip, laid out.
    ///   - context: What a failure names beside its numbers.
    @MainActor
    private static func expectIconOnCapBand(_ t: UBUITestContext, chip: RemoteConnectionIndicator, context: String) {
        let name = chip.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == chip.readingForTesting }
        guard let icon = chip.subviews.compactMap({ $0 as? NSImageView }).first, let image = icon.image, let font = name?.font else {
            t.expect(false, desc: "the chip exposes its icon and its name (\(context))")
            return
        }
        t.expect(
            abs(icon.frame.width - image.size.width) <= 0.01 && abs(icon.frame.height - image.size.height) <= 0.01,
            desc: "the icon is drawn at its image's own size, never scaled (\(context), \(icon.frame) for \(image.size))"
        )
        let iconCenter = icon.frame.minY + image.alignmentRect.midY
        let capCenter = chip.hostLabelBaselineOffsetFromBottom + font.capHeight / 2
        t.expect(
            abs(iconCenter - capCenter) <= 0.5,
            desc: "the icon's cap band is centred on the name's (\(context), icon \(iconCenter), cap \(capCenter))"
        )
        let side =
            chip.isWearingTagCapsule ? TitlebarCapsuleGeometry.iconSide : RemoteConnectionIndicator.symbolSide(forTitleFont: font)
        t.expect(
            abs(max(icon.frame.width, icon.frame.height) - side) <= 0.01,
            desc: "the icon fills its \(side)-point square along its longer side (\(context), \(icon.frame))"
        )
        if chip.isWearingTagCapsule {
            return
        }
        guard let rep = drawnBitmap(of: image) else {
            t.expect(false, desc: "the symbol draws (\(context))")
            return
        }
        let rows = solidPixels(in: rep, size: image.size, rect: NSRect(origin: .zero, size: image.size)).map(\.bottom)
        guard let lowest = rows.min(), let highest = rows.max() else {
            t.expect(false, desc: "the symbol has ink (\(context))")
            return
        }
        let inkBottom = icon.frame.minY + lowest
        let inkTop = icon.frame.minY + highest + image.size.height / CGFloat(rep.pixelsHigh)
        t.expect(
            inkBottom >= -0.01 && inkTop <= chip.bounds.height + 0.01,
            desc: "the symbol's ink stays inside the name's line (\(context), ink \(inkBottom)...\(inkTop) in \(chip.bounds.height))"
        )
    }

    /// The chip as a reader sees it: in the window, with no hidden ancestor —
    /// the titlebar accessory it stands in included — and with a width.
    @MainActor
    private static func isChipOnScreen(_ controller: TerminalWindowController) -> Bool {
        guard let chip = controller.remoteConnectionIndicator, let window = controller.window else { return false }
        return chip.window === window && !chip.isHiddenOrHasHiddenAncestor && chip.frame.width > 0
    }

    /// What the chip reads, with the facts a failure needs beside it.
    @MainActor
    private static func describeChip(_ controller: TerminalWindowController) -> String {
        guard let chip = controller.remoteConnectionIndicator else { return "no chip" }
        var hiddenAncestors: [String] = []
        var ancestor = chip.superview
        while let view = ancestor {
            if view.isHidden { hiddenAncestors.append(String(describing: type(of: view))) }
            ancestor = view.superview
        }
        let accessories = (controller.window?.titlebarAccessoryViewControllers ?? []).map { "\($0.isHidden)" }
        return "reading '\(chip.readingForTesting)', hidden \(chip.isHidden), "
            + "hidden ancestors \(hiddenAncestors), accessories hidden \(accessories), "
            + "hidden ancestor \(chip.isHiddenOrHasHiddenAncestor), in window \(chip.window != nil), "
            + "width \(chip.frame.width), state \(String(describing: controller.remoteSurface?.drive.remoteState))"
    }

    /// A remote window's title shows the chevron on hover and its menu works.
    @MainActor
    private static func verifyTitleMenu(_ t: UBUITestContext, controller: TerminalWindowController) {
        SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
        defer { SystemDisplayOptions.unpinForTesting() }
        guard let window = controller.window, let strip = titlebarStrip(of: window),
            let owner = hoverOwner(of: strip)
        else {
            t.expect(false, desc: "the remote window's title strip carries a hover owner")
            return
        }
        owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
        t.expect(
            t.wait(until: { chevronIsDrawn(in: identityControl(in: strip)) }, timeout: 3),
            desc: "hovering a remote window's title shows the chevron"
        )
        guard openIdentityPopover(in: strip, t), let dot = popoverTagDot("red") else {
            t.expect(false, desc: "the chevron opens the title menu on a remote window, carrying the tag dots")
            return
        }
        _ = dot.accessibilityPerformPress()
        t.pump(0.4)
        t.expect(manualTags(of: window) == ["red"], desc: "a tag added from the remote window's menu lands on the window")
        _ = dot.accessibilityPerformPress()
        t.pump(0.4)
        t.expect(manualTags(of: window).isEmpty, desc: "and a second press clears it")

        // Title and tab title are the window's own facts, ranked by Core.
        for (identifier, label) in [
            ("titlebarDocumentActions.windowTitle", "title"), ("titlebarDocumentActions.tabTitle", "tab title"),
        ] {
            guard let field = popoverView(identifier) as? NSTextField else {
                t.expect(false, desc: "the remote window's menu carries the \(label) field")
                continue
            }
            t.expect(field.isEnabled, desc: "the \(label) field is enabled on a remote window")
            field.stringValue = "named-by-hand"
            _ = field.sendAction(field.action, to: field.target)
            t.pump(0.3)
        }
        t.expect(controller.customWindowTitle == "named-by-hand", desc: "a title typed in a remote window's menu is applied")
        t.expect(
            t.wait(until: { controller.customTabTitle == "named-by-hand" }, timeout: 10),
            desc: "and so is a tab title, once the host's layout confirms it"
        )
        t.expect(
            t.wait(until: { window.title.contains("named-by-hand") }, timeout: 3),
            desc: "the remote window's title shows the title typed in the menu (\(window.title))"
        )
        for identifier in ["titlebarDocumentActions.windowTitle", "titlebarDocumentActions.tabTitle"] {
            if let field = popoverView(identifier) as? NSTextField {
                field.stringValue = ""
                _ = field.sendAction(field.action, to: field.target)
            }
        }
        t.expect(
            t.wait(until: { controller.customWindowTitle.isEmpty && controller.customTabTitle.isEmpty }, timeout: 10),
            desc: "clearing both fields restores the automatic titles"
        )

        // Size: the first attachment owns the grid, so the fields work and the
        // window follows the grid asked for.
        let isOwnedElsewhere = controller.remoteSurface?.drive.isRemoteGeometryOwnedElsewhere == true
        if let columns = popoverView("titlebarDocumentActions.columns") as? NSTextField,
            let rows = popoverView("titlebarDocumentActions.rows") as? NSTextField
        {
            let reason = popoverView("titlebarDocumentActions.sizeReason")
            if isOwnedElsewhere {
                t.expect(!columns.isEnabled && !rows.isEnabled, desc: "a followed grid disables the size fields")
                t.expect(
                    reason?.isHidden == false && !((reason as? NSTextField)?.stringValue.isEmpty ?? true),
                    desc: "and says why beside them"
                )
            } else {
                t.expect(columns.isEnabled && rows.isEnabled, desc: "the owning window can edit the size")
                t.expect(reason?.isHidden != false, desc: "and shows no reason")
                columns.integerValue = 100
                rows.integerValue = 30
                _ = columns.sendAction(columns.action, to: columns.target)
                t.expect(
                    t.wait(until: { Int(controller.remoteSurface?.drive.readSnapshot().columns ?? 0) == 100 }, timeout: 5),
                    desc: "a size set in the remote window's menu reaches the host grid"
                )
            }
        } else {
            t.expect(false, desc: "the remote window's menu carries the size fields")
        }

        // Rules: opens the rule editor prefilled for this connection.
        if let rules = popoverView("titlebarDocumentActions.tagRules") as? NSButton {
            t.expect(rules.isEnabled, desc: "the Rules button is enabled on a remote window")
            rules.performClick(nil)
            t.pump(1.2)
            t.expect(settingsPanelWindow() != nil, desc: "Rules opens the Settings window from a remote window")
            t.expect(
                t.wait(until: { anythingOnScreenReports("chip-host.ui-test") }, timeout: 3),
                desc: "and the new rule is prefilled with the remote host"
            )
            dismissEditSheet(t)
            settingsPanelWindow()?.close()
        } else {
            t.expect(false, desc: "the remote window's menu carries the Rules button")
        }
        closeIdentityPopover(in: strip, t)
        owner.perform(NSSelectorFromString("mouseExited:"), with: crossingOutside(in: window))
        t.pump(0.5)
    }

    /// Verifies the real title field reserves the live connection between tags and folder text.
    @MainActor
    private static func verifyLeadingPlacement(
        _ t: UBUITestContext,
        controller: TerminalWindowController
    ) {
        guard let chip = controller.remoteConnectionIndicator,
            let field = chip.superview as? NSTextField,
            let window = controller.window
        else {
            t.expect(
                false,
                desc:
                    "the live host identity is embedded in the title field, not the trailing accessory bar"
            )
            return
        }
        let text = field.attributedStringValue.string as NSString
        let rowTitle = controller.rowTitleTextForTesting ?? ""
        let titleRange = text.range(of: rowTitle, options: .backwards)
        guard titleRange.location != NSNotFound, titleRange.location >= 1 else {
            t.expect(
                false,
                desc: "the host prefix precedes the complete folder and process title (\(text))"
            )
            return
        }
        t.expect(
            text.substring(with: NSRange(location: titleRange.location - 1, length: 1)) == "\u{FFFC}",
            desc: "the reserved connection span stands directly before the folder, with no text connector"
        )
        let storage = NSTextStorage(attributedString: field.attributedStringValue)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: max(field.cell?.cellSize.width ?? 0, field.bounds.width), height: field.bounds.height)
        )
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        func leadingX(_ location: Int) -> CGFloat {
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            return 2 + manager.boundingRect(forGlyphRange: glyphs, in: container).minX
        }
        let prefixX = leadingX(titleRange.location - 1)
        let titleX = leadingX(titleRange.location)
        t.expect(
            abs(chip.frame.minX - prefixX) < 1 && chip.frame.maxX < titleX,
            desc:
                "the live globe and machine label occupy only their reserved leading span (chip=\(chip.frame), prefix=\(prefixX), title=\(titleX))"
        )
        // The measured distance between the chip's end and the next text: the
        // title's own separators leave about nine points either side of a dash.
        t.expect(
            titleX - chip.frame.maxX >= 9.5,
            desc: "the directory starts at least ten points past the connection name (gap=\(titleX - chip.frame.maxX))"
        )
        t.expect(
            field.bounds.contains(chip.frame),
            desc: "the connection identity fits vertically and horizontally inside the title"
        )
        t.expect(
            !window.titlebarAccessoryViewControllers.contains { chip.isDescendant(of: $0.view) },
            desc: "clipboard and secure-input accessories no longer carry the connection identity"
        )
        let spoken = field.accessibilityLabel() ?? ""
        if let hostRange = spoken.range(of: chip.statedHostName),
            let directoryRange = spoken.range(of: window.title)
        {
            t.expect(
                hostRange.lowerBound < directoryRange.lowerBound,
                desc: "accessibility reads the host before the folder and process title"
            )
        } else {
            t.expect(
                false,
                desc: "the accessible title includes both connection and session identity (\(spoken))"
            )
        }
    }

    // MARK: - Attached, against a daemon

    @MainActor
    private static func verifyAttached(_ t: UBUITestContext) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // Under /tmp: a Unix socket path is capped at 103 bytes and the
        // daemon's socket lives in this home.
        let root = "/tmp/ubq-chip-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: root)
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        guard
            t.wait(
                until: {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                    return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the daemon opened its socket")
            return
        }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        // Exec'd, so the attach process is the host binary itself and the
        // reconnect below can end exactly it.
        let attachCommand = "UBIQUITTY_HOME=\(quotedHome) exec \(quotedHost) --attach"

        guard
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: "chip host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "",
                hostKey: "chip-host.ui-test"
            ), let surface = controller.remoteSurface, let window = controller.window
        else {
            t.expect(false, desc: "a window attached to the forked daemon")
            return
        }
        defer { UbiquittyKit.HostDirectory.forget(host: "chip-host.ui-test") }
        guard
            t.wait(
                until: {
                    controller.remoteSurface?.drive.remoteState == .Connected && controller.remotePaneSurfaces.count == 1
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the window reached the daemon and projected its pane (\(surface.remoteFailureDetail))")
            return
        }
        // Settled: the projection, the first frames and the title weave that
        // follow an attach have all run, and each of them can take the chip away.
        t.pump(1.0)
        t.expect(
            t.wait(until: { isChipOnScreen(controller) }, timeout: 10),
            desc: "a connected window's title row shows the host chip (\(describeChip(controller)))"
        )
        t.expect(
            controller.remoteConnectionIndicator?.readingForTesting == "chip host",
            desc: "and the chip names the host and its carrier (\(describeChip(controller)))"
        )
        t.expect(
            window.subtitle == "chip host",
            desc: "the window's subtitle names the host ('\(window.subtitle)')"
        )
        verifyTitleMenu(t, controller: controller)
        controller.manualTags = ["test environment"]
        t.pump(0.2)
        verifyLeadingPlacement(t, controller: controller)
        t.expect(
            (controller.remoteConnectionIndicator?.superview as? NSTextField)?.accessibilityLabel()?
                .hasPrefix("Tagged test environment") == true,
            desc: "the tag remains before the connection in the accessible title"
        )
        // The host is said once per place: the chip in the title row names
        // it, so the window's one tab does not say it again.
        t.expect(
            t.wait(until: { !window.tab.title.isEmpty && !window.tab.title.contains("chip host — ") }, timeout: 10),
            desc: "the tab leaves the host to the chip that names it ('\(window.tab.title ?? "")')"
        )

        // The carrier drops: the attach process ends, Core backs off and dials
        // again, and the daemon hands the same session back.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "--", hostBinary + " --attach"]
        do { try kill.run() } catch {
            t.expect(false, desc: "the attach process could be ended (\(error))")
            return
        }
        kill.waitUntilExit()
        t.expect(
            t.wait(until: { controller.remoteSurface?.drive.remoteState != .Connected }, timeout: 10),
            desc: "ending the attach process dropped the link (\(describeChip(controller)))"
        )
        t.expect(
            t.wait(
                until: {
                    controller.remoteSurface?.drive.remoteState == .Connected && controller.remotePaneSurfaces.count == 1
                },
                timeout: 30
            ),
            desc: "the window reconnected to the daemon (\(describeChip(controller)))"
        )
        t.pump(1.0)
        t.expect(
            t.wait(until: { isChipOnScreen(controller) }, timeout: 10),
            desc: "after a reconnect the title row still shows the host chip (\(describeChip(controller)))"
        )
        t.expect(
            controller.remoteConnectionIndicator?.readingForTesting == "chip host",
            desc: "and it is back to the quiet steady reading (\(describeChip(controller)))"
        )
        verifyLeadingPlacement(t, controller: controller)
        t.expect(
            window.subtitle == "chip host" && !window.tab.title.contains("chip host — "),
            desc:
                "the subtitle still names the host and the tab still leaves it to the chip ('\(window.subtitle)', '\(window.tab.title ?? "")')"
        )
        // A picture of the window as the window server composites it, for a
        // reader checking the row by eye: run with `--visible` and
        // UBQ_HOST_CHIP_CAPTURE naming the file.
        if let path = ProcessInfo.processInfo.environment["UBQ_HOST_CHIP_CAPTURE"] {
            window.makeKeyAndOrderFront(nil)
            t.pump(1.0)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()
        }
    }

    // MARK: - A plain local shell

    @MainActor
    private static func verifyLocalShell(_ t: UBUITestContext) {
        guard let controller = TerminalWindowController.spawn(), let window = controller.window else {
            t.expect(false, desc: "a local window opened")
            return
        }
        defer { t.closeAllWindows() }
        t.pump(0.5)
        t.expect(!isChipOnScreen(controller), desc: "a plain local shell wears no host chip (\(describeChip(controller)))")
        t.expect(window.subtitle.isEmpty, desc: "and names no host in its subtitle ('\(window.subtitle)')")
        t.expect(
            !window.tab.title.contains("chip host — "),
            desc: "and its tab carries no host mark ('\(window.tab.title ?? "")')"
        )
    }

    // MARK: - Two hosts, one strip

    @MainActor
    private static func verifyTwoHosts(_ t: UBUITestContext) {
        defer { t.closeAllWindows() }
        // Silent transports: what is asserted is the marks, which a host
        // session wears from its first moment, steady or not.
        func open(label: String, key: String) -> TerminalWindowController? {
            TerminalWindowController.spawnRemoteWindow(
                shellCommand: "/bin/sleep 30",
                hostLabel: label,
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "",
                hostKey: key
            )
        }
        guard let alpha = open(label: "alpha", key: "alpha.ui-test"), let beta = open(label: "beta", key: "beta.ui-test"),
            let thisMac = open(label: "Ubiquitty Host", key: "local"),
            let alphaWindow = alpha.window, let betaWindow = beta.window, let thisMacWindow = thisMac.window
        else {
            t.expect(false, desc: "three host windows opened")
            return
        }
        alphaWindow.addTabbedWindow(betaWindow, ordered: .above)
        alphaWindow.addTabbedWindow(thisMacWindow, ordered: .above)
        t.pump(0.5)
        for controller in [alpha, beta, thisMac] {
            controller.refreshTitles()
        }
        // A silent host sets no title, so each label is its host's name, said
        // once rather than marked with itself.
        t.expect(alphaWindow.tab.title == "alpha", desc: "the first tab carries its host once ('\(alphaWindow.tab.title ?? "")')")
        t.expect(betaWindow.tab.title == "beta", desc: "the second tab carries its own ('\(betaWindow.tab.title ?? "")')")
        t.expect(
            thisMacWindow.tab.title.hasPrefix("This Mac — "),
            desc: "a tab on this Mac's daemon is marked as This Mac rather than by its row's name ('\(thisMacWindow.tab.title ?? "")')"
        )
        t.expect(
            alpha.remoteConnectionIndicator?.readingForTesting.hasSuffix("alpha") == true
                && beta.remoteConnectionIndicator?.readingForTesting.hasSuffix("beta") == true,
            desc: "each window's chip names its own host (\(describeChip(alpha)); \(describeChip(beta)))"
        )
        t.expect(
            thisMac.remoteConnectionIndicator?.readingForTesting.hasSuffix("This Mac") == true,
            desc: "the daemon on this Mac reads as This Mac (\(describeChip(thisMac)))"
        )
        t.expect(
            thisMac.remoteConnectionIndicator?.symbolNameForTesting != alpha.remoteConnectionIndicator?.symbolNameForTesting,
            desc: "and wears this machine's symbol rather than the remote globe"
        )
    }
}
