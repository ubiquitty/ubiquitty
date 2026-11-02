// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+TitlebarIdentity.swift — the title row, on this shell.
//
// One row carries four things that look separate and are not: the folder proxy
// that reveals on a dwell, the styled title with its dimmed directory segment,
// the popover the whole row opens, and the tag markers that can wash the row in
// a colour. They share a slot, so one controller arbitrates it —
// `ProxyIconRevealController`, which both shells instantiate rather than
// either re-implementing.
//
// What is here is the feeding: which facts the controller reads, and where the
// popover's edits are written back to. The edits go through the window's one
// custom-title writer, `setCustomTitles`, which every other surface uses too,
// so what the popover shows is what Rename Tab, the inspector and a script see.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// Builds the titlebar identity and wires its write-backs.
    ///
    /// File > Edit Title… — the same popover the title row's whole-row click
    /// opens.
    ///
    /// The menu item is the keyboard's way in; without it the popover is
    /// reachable only by clicking the title, which a reader driving from the
    /// keyboard cannot do.
    ///
    /// - Parameter sender: Passed through as the popover's anchor.
    @objc
    public func showTitleActionsPopover(_ sender: Any?) {
        proxyIconReveal?.documentActionsController.showPopover(sender)
    }

    /// Called once, when the window is built: the controller installs views
    /// into the title row, and a second one would fight the first for the slot.
    internal func installTitlebarIdentity() {
        guard let window, proxyIconReveal == nil else { return }
        let reveal = ProxyIconRevealController(window: window)
        proxyIconReveal = reveal
        reveal.connectionIndicator = remoteConnectionIndicator
        reveal.requestSlotResolution = { [weak self] in
            self?.updateRepresentedURL()
        }

        let actions = reveal.documentActionsController
        actions.willPresent = { [weak self, weak actions] in
            guard let self, let actions else { return }
            // Read at presentation rather than pushed on every change: the
            // popover is opened rarely and the facts it shows move constantly,
            // so the fresh read is both cheaper and impossible to leave stale.
            actions.windowTitleOverride = customWindowTitle
            actions.tabTitleOverride = customTabTitle
            let grid = focusedGrid()
            actions.columns = grid.columns
            actions.rows = grid.rows
            actions.tags = manualTags
            // The rule half of the tags the title row draws, from the same
            // Core list, so the popover shows what the window wears.
            actions.ruleTags = windowTags.filter { $0.source == .Rule }.map(TitlebarRuleTag.init(resolved:))
            // A pane whose geometry the host or another client owns follows
            // that size; a resize here would be refused or undone.
            actions.sizeUnavailableReason =
                titleSurface?.drive.isRemoteGeometryOwnedElsewhere == true
                ? "The host sets this size; another client controls it." : nil
        }
        actions.applyTitles = { [weak self] (windowTitle: String, tabTitle: String) in
            self?.setCustomTitles(window: windowTitle, tab: tabTitle)
        }
        actions.applyGridSize = { [weak self] columns, rows in
            self?.resizeWindow(toColumns: columns, rows: rows)
        }
        actions.applyTags = { [weak self] tags in
            self?.manualTags = tags
        }
        actions.openTagRules = { [weak self] selectedRule in
            // The rules pane opens on the rule this window matched, when one
            // did; otherwise on a new rule pre-filled with the host this window
            // is on, so a reader who wants "everything on this box tagged"
            // does not have to type its name again. Called rather than sent:
            // the opener is the app's own Swift type and is in hand here, so a
            // trip down the responder chain would only be a longer way to the
            // same method, and a way that says nothing when no one answers.
            guard let self else { return }
            let matched = selectedRule >= 0 ? selectedRule : Int(Ubiquitty.Session.firstMatchedTagRule(self.windowTags))
            if matched >= 0 {
                TagRulePrefill.open(ruleIndex: matched)
                return
            }
            let host = self.remoteHostKey
            TagRulePrefill.open(host: host.isEmpty ? nil : host)
        }

        reveal.chromeDidChange()
        applyWindowTitleStyle()
        applyWindowTags()
    }

    /// Resolves who owns the title row's leading slot, and stands the folder
    /// proxy in it or takes it down.
    ///
    /// A chromeless window and a reader who turned `[appearance] folder_icon`
    /// off both release the slot outright. Otherwise the proposal is the
    /// directory the title was woven from, and the controller decides what
    /// actually shows — it owns the reveal's dwell and its flight, and a URL
    /// written past it would appear without either.
    internal func updateRepresentedURL() {
        guard let window else { return }
        guard let reveal = proxyIconReveal else {
            // Before the identity is installed there is no arbiter, so the
            // window carries the plain icon or none.
            window.representedURL = representedDirectoryURL()
            return
        }
        let configuration = Ubiquitty.Preferences.values().pointee
        guard !isTitleBarHiddenForIdentity, Ubiquitty.Preferences.Effective.folderIcon(configuration) else {
            reveal.invalidateSession()
            return
        }
        // A reader who asked the system for permanent titlebar icons gets them
        // here too: the reveal is an affordance, not a way to withhold one.
        // Asked by selector: the accessibility switch is not in every SDK this
        // builds against, and a reader who set it gets the permanent icon here
        // as they do everywhere else.
        let iconsAlways = NSSelectorFromString("accessibilityDisplayShouldShowWindowTitlebarIcons")
        let systemAlways =
            NSWorkspace.shared.responds(to: iconsAlways)
            && (NSWorkspace.shared.value(forKey: "accessibilityDisplayShouldShowWindowTitlebarIcons") as? Bool ?? false)
        reveal.resolveRepresentedDirectory(
            representedDirectoryURL(),
            alwaysVisible: systemAlways || Ubiquitty.Preferences.Effective.folderIconAlways(configuration)
        )
    }

    /// Resolves this window's tags and hands them to the title row.
    ///
    /// Two sources, joined by Core: the `[[tags]]` rules that match this
    /// window's host and profile, and the names the reader put on it by hand.
    /// The first loud tag also washes the row — two tints cannot both be the
    /// background, and a row where everything shouts says nothing.
    ///
    /// The host the rules match is Core's ``paneHost(of:)`` for the pane the
    /// chip speaks for, so the chip and the tags cannot name two machines;
    /// when that answer moves, both are drawn again. So are they when the
    /// host the tab's tags match moves, as a pane of a Sync window going on
    /// to another machine moves it.
    internal func refreshWindowTagLocation() {
        if tagLocationIdentity(of: windowHost()) != resolvedTagLocationName {
            applyWindowTags()
        }
    }

    /// Where the pane the title row speaks for lives.
    private func windowHost() -> Ubiquitty.Session.PaneHost {
        hostSurface.map { paneHost(of: $0) } ?? Ubiquitty.Session.PaneHost()
    }

    /// Where the pane the tab names says it is, for the tab's tags: its own
    /// location sources, which Core reads for a pane of a Sync window that
    /// has gone on to another machine (`Session::surfaceTagHost`).
    private func tabPaneLocation() -> Ubiquitty.Session.LocationInputs {
        guard let surface = titleSurface ?? hostSurface else { return Ubiquitty.Session.LocationInputs() }
        return (hostingSurface ?? surface).drive.locationInputs()
    }

    /// Everything the window's tags and its tab's tags are matched against,
    /// whether the tab's group is on one host among them, as one string a
    /// refresh compares.
    private func tagLocationIdentity(of host: Ubiquitty.Session.PaneHost) -> String {
        let tabHost = Ubiquitty.Session.surfaceTagHost(host, tabPaneLocation())
        return Self.identity(of: host) + "\u{1E}" + Self.identity(of: tabHost) + "\u{1E}"
            + (windowHostFacts().doTabsMixPlaces ? "mixed" : "shared")
    }

    /// One string for everything the chip and the tags read off a host, so a
    /// change to any of it redraws both.
    private static func identity(of host: Ubiquitty.Session.PaneHost) -> String {
        [String(describing: host.place.rawValue), String(host.machine), String(host.label), String(host.carrier)]
            .joined(separator: "\u{1F}")
    }

    internal func applyWindowTags() {
        guard let reveal = proxyIconReveal else { return }
        let configuration = Ubiquitty.Preferences.values().pointee
        // How strongly every tag's colour is drawn, in the title row and on
        // the tab; read here, where a settings change re-resolves the tags of
        // every open window.
        let previousOpacity = tagColorOpacity
        tagColorOpacity = CGFloat(Ubiquitty.Preferences.Effective.tagColorOpacity(configuration))
        let host = windowHost()
        resolvedTagLocationName = tagLocationIdentity(of: host)
        var manualNames = Ubiquitty.Session.TagNames()
        for name in manualTags {
            manualNames.push_back(std.string(name))
        }
        let resolved = Ubiquitty.Session.resolveWindowTags(
            configuration.tags,
            host,
            std.string(appliedProfileName),
            manualNames
        )
        windowTags = resolved
        // Every pane header resolves its own again against the new rules.
        paneHeaderTagRuns.removeAll()

        // The title bar draws the tags Core places there, in the window's
        // order; a rule placed off it is missing from the chip, the markers
        // and the wash alike.
        var markers: [TitlebarTagMarker] = []
        var hostTag: HostChipTag?
        var tint: NSColor?
        // The loud tag's own colour, which a capsule of that colour is told apart from it by.
        var washingColor: NSColor?
        for tag in Ubiquitty.Session.tagsDrawnOn(resolved, .window) {
            let color = tag.color.set ? NSColor(tagColor: tag.color) : nil
            let spokenName = String(Ubiquitty.Session.tagSpokenName(tag))
            let icon = String(tag.icon)
            // What the marker writes: the name, unless the rule draws the
            // icon or the dot alone. The spoken name stays the tag's.
            let title = tag.drawsName() ? String(tag.name) : ""
            // The host chip wears the first coloured tag the rules gave this
            // window, before the hand-put ones join: a name typed on one
            // window is not a fact about the machine.
            var isHostTag = false
            if hostTag == nil, tag.source == .Rule, let color {
                isHostTag = true
                hostTag = HostChipTag(
                    fill: color.withAlphaComponent(1.0),
                    title: title,
                    spokenName: spokenName,
                    iconName: icon,
                    iconWeight: tag.iconWeight
                )
            }
            markers.append(
                TitlebarTagMarker(
                    name: title,
                    spokenName: spokenName,
                    color: color,
                    prominence: tag.prominence == .Loud ? .loud : .quiet,
                    iconName: icon,
                    iconWeight: tag.iconWeight,
                    isHostTag: isHostTag
                )
            )
            if tint == nil, tag.prominence == .Loud, let color {
                tint = loudTagWash(of: color)
                washingColor = color.withAlphaComponent(1.0)
            }
        }
        // The tab draws what tells it apart, and names every tag it is placed
        // to show: in a window attached over Sync, the connection's own tags
        // are the host chip's (`Session::resolveTabTags`).
        let tabTags = Ubiquitty.Session.resolveTabTags(
            configuration.tags,
            host,
            tabPaneLocation(),
            std.string(appliedProfileName),
            manualNames,
            windowHostFacts().doTabsMixPlaces ? .Mixed : .Shared
        )
        let tabMarks = Self.tagMarks(of: tabTags.drawn)
        let tabNames = Self.spokenNames(of: tabTags.named)
        let isWashChanged = loudTagTint != tint
        loudTagTint = tint
        loudTagColor = washingColor
        // Before the repaint, which compares against it: the repaint then
        // finds the row's style current, and the chip and the markers are
        // drawn once, below.
        titleRowTagStyle = resolvedTitleRowTagStyle()
        if isWashChanged {
            tintTitlebar()
        }
        // After the wash, which the chip reads to tell its capsule from a row
        // of the same colour.
        hostChipTag = hostTag
        refreshHostChip()
        reveal.setTagMarkers(markers, titlebarTint: tint, style: titleRowTagStyle)
        applyWindowTitleStyle()
        // The tab's title leads with every tag Core places on the tab — each
        // its icon in its colour, or a dot of that colour — and the tab names
        // them on hover. Both are the bake's: the marks are the title's first
        // run, and the names are in the tooltip.
        if tabMarks != tabTagMarks || tabNames != tabTagNames || tagColorOpacity != previousOpacity {
            tabTagMarks = tabMarks
            tabTagNames = tabNames
            refreshTabTitle(facts: nil, writesStripBack: false)
        }
        refreshPaneChrome()
    }

    /// The tags a pane's header leads its title with, as Core resolves them
    /// for that pane (`Session::resolvePaneHeaderTags`).
    ///
    /// The rules match the pane's own host, since panes of one window can be
    /// on different machines; the window's profile and the names set on it by
    /// hand are the window's. A pane of a Sync window leaves the connection's
    /// tags to the chip unless it has gone on to another machine, and still
    /// names them for a screen reader. Resolved once for each place a pane is
    /// found in, and again after the window's tags are.
    ///
    /// - Parameters:
    ///   - surface: The pane.
    ///   - pane: Its header's identity.
    /// - Returns: The run, nil when the header names no tag.
    internal func paneHeaderTagRun(for surface: TerminalSurface, pane: Int32) -> TabTagMarkRun? {
        let host = paneHost(of: surface)
        let location = (hostingSurface ?? surface).drive.locationInputs()
        let hostIdentity = Self.identity(of: host) + "\u{1E}" + Self.identity(of: Ubiquitty.Session.surfaceTagHost(host, location))
        if let held = paneHeaderTagRuns[pane], held.hostIdentity == hostIdentity {
            return held.run
        }
        let configuration = Ubiquitty.Preferences.values().pointee
        var manualNames = Ubiquitty.Session.TagNames()
        for name in manualTags {
            manualNames.push_back(std.string(name))
        }
        let tags = Ubiquitty.Session.resolvePaneHeaderTags(
            configuration.tags,
            host,
            location,
            std.string(appliedProfileName),
            manualNames
        )
        let run = Self.tagRun(of: tags, opacity: tagColorOpacity)
        paneHeaderTagRuns[pane] = (hostIdentity, run)
        return run
    }

    /// The run a title leads with: a mark for each tag drawn, spoken by every
    /// tag named; nil when it names none.
    private static func tagRun(of tags: Ubiquitty.Session.SurfaceTags, opacity: CGFloat) -> TabTagMarkRun? {
        let names = spokenNames(of: tags.named)
        guard !names.isEmpty else { return nil }
        return TabTagMarkRun(marks: tagMarks(of: tags.drawn), opacity: opacity, spokenNames: names)
    }

    /// One mark for each tag, in order: its colour at full strength, nil for
    /// a tag that claims none, and its icon.
    private static func tagMarks(of tags: Ubiquitty.Session.ResolvedTags) -> [TabTagMark] {
        tags.map { tag in
            TabTagMark(
                color: tag.color.set ? NSColor(tagColor: tag.color).withAlphaComponent(1.0) : nil,
                iconName: String(tag.icon),
                iconWeight: tag.iconWeight
            )
        }
    }

    /// The tags' names as a screen reader speaks them, in order.
    private static func spokenNames(of tags: Ubiquitty.Session.ResolvedTags) -> String {
        tags.map { String(Ubiquitty.Session.tagSpokenName($0)) }.joined(separator: ", ")
    }

    /// The colour a program asked this window's tab to wear, or nil for none.
    ///
    /// OSC 21337: a session marking its own state — an agent waiting, busy or
    /// idle. It is read off the published snapshot for the reason the progress
    /// pair is: the report moves no cell, so nothing a frontend watches would
    /// ever tell it. The pane the title speaks for speaks for the colour too —
    /// the active pane, or a hosted window's root — so a split whose panes
    /// disagree has one colour to show, and a hosted window is not left bare.
    internal func tabStatusIndicatorColor() -> NSColor? {
        guard let surface = titleSurface else { return nil }
        // Core resolves it: a program's status takes the pane's theme colour
        // for that status, and an OSC 21337 indicator is the program's own.
        let color = surface.drive.tabStatusColor()
        guard color.isSet else { return nil }
        return NSColor(
            srgbRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1.0
        )
    }

    /// A loud tag's wash over this window's chrome: the tag's colour mixed into
    /// the row's own ground as Core's `Themes::Contrast::loudTagWash` mixes it, so a dark
    /// theme's chrome stays dark under it and a light theme's light.
    ///
    /// - Parameter color: The tag's colour.
    /// - Returns: The wash, opaque.
    private func loudTagWash(of color: NSColor) -> NSColor {
        var ground = untaggedTitleRowGround()
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .performAsCurrentDrawingAppearance {
                ground = ground.usingColorSpace(.sRGB) ?? ground
            }
        guard let tag = color.usingColorSpace(.sRGB), let base = ground.usingColorSpace(.sRGB) else { return color }
        let pack = { (ink: NSColor) -> UInt32 in
            let byte = { (channel: CGFloat) in UInt32(UInt8(clamping: Int((channel * 255).rounded()))) }
            return (byte(ink.redComponent) << 16) | (byte(ink.greenComponent) << 8) | byte(ink.blueComponent)
        }
        return NSColor(packedRGB: Ubiquitty.Themes.Contrast.loudTagWash(pack(tag), pack(base)))
    }

    /// The symbol a window's title shows for its program's status record: the
    /// symbol its tab shows, in the status's theme colour; nil with no record.
    ///
    /// - Returns: The symbol and its ink.
    internal func windowTitleStatusSymbol() -> TitleStatusSymbol? {
        guard let surface = titleSurface else { return nil }
        let snapshot = surface.drive.readSnapshot()
        guard let status = HostOutlineStatus(rawValue: snapshot.programStatusKind), status != .none else { return nil }
        let blockKind = HostOutlineBlockKind(rawValue: snapshot.programBlockKind) ?? .none
        return TitleStatusSymbol(
            name: status == .working ? TabStatusMark.workingSymbolName : status.symbolName(blockKind: blockKind),
            // Working wears the status text's own ink, as its tab's ellipsis wears the ring's.
            ink: status == .working ? nil : tabStatusIndicatorColor()
        )
    }

    /// The label a program gave the colour it asked this window's tab to wear,
    /// or nil for none.
    ///
    /// OSC 21337's `status` ("Waiting"), read off the same published snapshot
    /// as the colour and from the same pane, so the label a reader hovers and
    /// the colour they are looking at cannot come from two different reports.
    /// Empty whenever no colour is set; that is Core's rule, not a check here.
    internal func tabStatusLabel() -> String? {
        guard let surface = titleSurface else { return nil }
        let label = String(surface.drive.readSnapshot().tabStatusLabel())
        return label.isEmpty ? nil : label
    }

    /// Hands the title row the bell an unheard ring left on this window.
    ///
    /// The title's copy of the tab's accessory mark, and the one that carries
    /// it for a window with no strip: a lone window's accessory slot is never
    /// on screen, so without this the bell it caught could not be found at all.
    /// Both marks are fed from the same latch, so a window showing one in its
    /// strip and nothing in its title is not a state this can reach.
    internal func refreshTitleBellMark() {
        guard let reveal = proxyIconReveal else { return }
        // Written in the order that restyles the row once either way: the
        // colour is only wanted while a bell stands, so it is set before the
        // bell arrives and after the bell has gone.
        guard hasUnheardBell else {
            reveal.hasUnheardBell = false
            reveal.bellStatusColor = nil
            return
        }
        reveal.bellStatusColor = tabStatusIndicatorColor()
        reveal.hasUnheardBell = true
    }

    /// Paints the title row's text: which segment is dimmed, which is bright,
    /// and what the popover shows beside it.
    ///
    /// The directory segment reads dimmer than the rest so the name a reader is
    /// looking for is the part that stands out. An inactive window paints at
    /// Core's `inactiveWindowTitleScale` of the active ink.
    ///
    /// The surface is the one the title was woven from: a hosted window holds
    /// no local pane, and a style keyed to the local pane never paints its row,
    /// which then shows Core's bare join — the segments run together with no
    /// space around the dashes — where the styled row spaces and dims them.
    internal func applyWindowTitleStyle() {
        guard let reveal = proxyIconReveal, let window, let surface = titleSurface else { return }
        let configuration = Ubiquitty.Preferences.values().pointee
        let composition = Ubiquitty.Preferences.Effective.windowTitleComposition(configuration)
        // One resolve for the whole row: the text's lead, and the components the
        // row draws beside it, all from the parts Core gated by this window's
        // composition — so a switch turned off, a name typed over the title, or
        // a session that has ended take a component away here exactly as they
        // take a segment out of the text.
        let woven = wovenTitle(for: surface, as: .window)
        reveal.rowTitleText = woven.title

        let isActive = WindowTabSelection.isGroupActive(window)
        let activeAlpha: CGFloat = isActive ? 1.0 : Ubiquitty.Themes.inactiveWindowTitleScale
        let isNativeRow = isUsingNativeTitlebar
        let themed = themeForeground(of: surface)
        var brightColor =
            isNativeRow
            ? (isActive ? .labelColor : .secondaryLabelColor)
            : NSColor(packedRGB: themed, alpha: activeAlpha)
        // The runs that only place or join the title, the directory, the
        // separators and the size, wear system label colours on a themed row
        // as on a native one, never the theme's foreground at a lower alpha:
        // a system label colour is resolved by the row's appearance, which
        // follows the theme's lightness, and drawn vibrantly wherever the row
        // lies over material.
        var dimColor: NSColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor
        if let loudTagTint, let readable = NSColor(labelOn: loudTagTint) {
            // A washed row is no longer a question about the theme: the ink is
            // whatever reads on that fill, which is the same policy the chips
            // drawn beside it use.
            brightColor = readable.withAlphaComponent(activeAlpha)
            dimColor = readable.withAlphaComponent(0.62 * activeAlpha)
        }

        var directorySegment = ""
        // The base text alone. Joining it to the directory is the separator's
        // job and the separator is Core's, so this arm does not spell one.
        var baseTitleBeforeDirectory = ""
        if composition.showsDirectory {
            directorySegment = woven.lead
            let baseTitle = String(composition.baseTitle)
            if !directorySegment.isEmpty, !baseTitle.isEmpty {
                baseTitleBeforeDirectory = baseTitle
            }
        }
        // A program's status record shows as what the program says it is doing,
        // whole, and as its symbol where no tab bar or pane bar already shows
        // it; the program's own OSC 21337 text, with no record behind it, as
        // itself. Nothing shows where the composition leaves the status out.
        let hasRecord = surface.drive.readSnapshot().programStatusKind != 0
        let isMarkedElsewhere = (window.tabbedWindows?.count ?? 1) > 1 || projectedSurfaces.count > 1
        let isShown = !woven.programStatus.isEmpty
        reveal.programStatusSymbol = isShown && hasRecord && !isMarkedElsewhere ? windowTitleStatusSymbol() : nil
        reveal.programStatusSpokenText = isShown && hasRecord ? surface.drive.statusHelpText() : ""
        reveal.programStatusTitle = !isShown ? "" : hasRecord ? surface.drive.programActivityText() : woven.programStatus
        reveal.processIconGround = titleRowGround()
        reveal.processIconKey = ProcessIcons.isShown ? surface.drive.processIconKey(surface.drive.readSnapshot()) : ""
        reveal.isHostFallbackTitle = woven.usesFallbackName && remoteConnectionIndicator?.statedHostName == woven.title
        reveal.applyTitleStyle(
            directorySegment: directorySegment,
            baseTitleBeforeDirectory: baseTitleBeforeDirectory,
            trailingRegularSegment: woven.dimensions,
            dimColor: dimColor,
            brightColor: brightColor,
            detailColor: loudTagTint == nil ? .tertiaryLabelColor : dimColor
        )
    }

    /// Sizes the window so its grid becomes exactly this many cells.
    ///
    /// Anchored at the top-left, the corner a reader is least likely to be
    /// looking at: growing downward and rightward leaves what they are reading
    /// where it was.
    ///
    /// The surface is ``titleSurface`` rather than the focused pane: a window
    /// mirroring a host has no pane model to focus, so a hosted window asking
    /// for a grid would find no surface and size nothing.
    ///
    /// - Parameters:
    ///   - columns: The target column count.
    ///   - rows: The target row count.
    package func resizeWindow(toColumns columns: Int, rows: Int) {
        guard let window, var sized = frame(forColumns: columns, rows: rows, from: window.frame) else { return }
        // A native tab strip can change AppKit's content layout after the first
        // frame is applied. Re-measure the pane once so the grid, not the stale
        // pre-strip overhead, determines the final frame.
        for _ in 0..<2 {
            window.setFrame(sized, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let next = frame(forColumns: columns, rows: rows, from: window.frame) else { return }
            if abs(next.width - window.frame.width) < 1 && abs(next.height - window.frame.height) < 1 { return }
            sized = next
        }
    }

    /// The window frame whose grid is exactly this many cells, top-left
    /// anchored on `frame`, without applying it.
    ///
    /// - Parameters:
    ///   - columns: The target column count.
    ///   - rows: The target row count.
    ///   - frame: The frame to anchor on.
    /// - Returns: The frame, or nil before the surface has a cell size.
    package func frame(forColumns columns: Int, rows: Int, from frame: NSRect) -> NSRect? {
        guard let surface = titleSurface, let renderer = surface.renderer else { return nil }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0 else { return nil }
        let clampedColumns = min(max(columns, 1), Int(Ubiquitty.maxColumns))
        let clampedRows = min(max(rows, 1), Int(Ubiquitty.maxRows))
        let insets = renderer.gridFitInsets(for: surface)
        var coreInsets = Ubiquitty.Rendering.EdgeInsets()
        coreInsets.left = Float(insets.left)
        coreInsets.right = Float(insets.right)
        coreInsets.top = Float(insets.top)
        coreInsets.bottom = Float(insets.bottom)
        // Core's inverse of the fit the resize path derives the grid with, so
        // the window lands on exactly the counts asked for rather than one off.
        let extent = Ubiquitty.Rendering.viewportForGrid(
            Ubiquitty.GridSize(columns: Int32(clampedColumns), rows: Int32(clampedRows)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            coreInsets,
            0
        )
        let viewport = NSSize(width: CGFloat(extent.width), height: CGFloat(extent.height))
        let frameRect = windowSize(forTerminalViewport: viewport)
        return CGRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - frameRect.height,
            width: frameRect.width,
            height: frameRect.height
        )
    }

    /// The grid the pane the title speaks for is showing.
    ///
    /// - Returns: Its columns and rows, or the classic 80×24 before one exists.
    private func focusedGrid() -> (columns: Int, rows: Int) {
        guard let surface = titleSurface else { return (80, 24) }
        let snapshot = surface.drive.readSnapshot()
        let columns = Int(snapshot.columns)
        let rows = Int(snapshot.rows)
        return (columns > 0 ? columns : 80, rows > 0 ? rows : 24)
    }

    /// The directory the folder proxy would stand on, or nil when there is none.
    private func representedDirectoryURL() -> URL? {
        // A reported document wins over the folder it sits in.
        //
        // A program that names a focused document (OSC 6) is naming something
        // more specific than its working directory, and that is what a reader
        // dragging the proxy icon, or asking to reveal it, means. The
        // icon therefore follows the document when one is reported.
        //
        // Whether a reported URL may be represented is Core's rule
        // (`isLocalDocumentURL`), not a second copy of the test here: a shell on
        // the far side of an ssh session reports the document on that side, and
        // pointing the Finder at that path would be pointing it at nothing.
        if let reported = titleSurface?.drive.currentFileURL(),
            Ubiquitty.Title.isLocalDocumentURL(std.string(reported)),
            let documentURL = URL(string: reported),
            documentURL.isFileURL
        {
            return documentURL
        }
        let directory = titleSurface?.drive.representedLocalDirectory() ?? ""
        guard !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }
}

extension NSColor {
    /// Builds a colour from a Core tag entry's components.
    ///
    /// - Parameter tagColor: The entry, whose `set` the caller has checked.
    fileprivate convenience init(tagColor: Ubiquitty.Preferences.ColorEntry) {
        self.init(
            srgbRed: CGFloat(tagColor.red) / 255.0,
            green: CGFloat(tagColor.green) / 255.0,
            blue: CGFloat(tagColor.blue) / 255.0,
            alpha: CGFloat(tagColor.alpha) / 255.0
        )
    }

    /// The label colour that reads on a fill, by Core's contrast rule.
    ///
    /// - Parameter fill: The colour the row is washed with.
    fileprivate convenience init?(labelOn fill: NSColor) {
        guard let srgb = fill.usingColorSpace(.sRGB) else { return nil }
        let packed =
            (UInt32(srgb.redComponent * 255.0) << 16)
            | (UInt32(srgb.greenComponent * 255.0) << 8)
            | UInt32(srgb.blueComponent * 255.0)
        self.init(packedRGB: Ubiquitty.Themes.Contrast.labelColorOnFill(packed))
    }
}
