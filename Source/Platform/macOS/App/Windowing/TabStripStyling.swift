// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AppKit moves a tab group's shared strip into the selected window's titlebar.
// Material and title updates therefore find the current host across the group.

import AppKit

@MainActor
@objc(UBTabStripStyling)
public final class TabStripStyling: NSObject {
    /// Keeps a themed title in its native field while AppKit remaps the strip
    /// during a selection or main-window transfer.
    ///
    /// The notification arrives synchronously with AppKit's assignment,
    /// before the next frame.
    @MainActor
    private final class TitleFieldGuard {
        weak var window: NSWindow?
        weak var strip: NSView?
        var correctionsForTesting = 0
        private var observation: NSKeyValueObservation?

        init(field: NSTextField) {
            observation = field.observe(\.attributedStringValue, options: [.new]) { [weak self] field, _ in
                MainActor.assumeIsolated {
                    self?.restore(in: field)
                }
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
        }

        private func restore(in field: NSTextField) {
            guard let window, let strip, TabStripStyling.themedTitleStrips.contains(strip),
                field.isDescendant(of: strip), let title = window.tab.attributedTitle,
                field.stringValue == title.string, !field.attributedStringValue.isEqual(to: title)
            else { return }
            correctionsForTesting += 1
            field.attributedStringValue = title
        }
    }

    private static let titleFieldGuards = NSMapTable<NSTextField, TitleFieldGuard>.weakToStrongObjects()

    /// Leaves every part of the native strip unchanged when explicitly requested.
    static let isNativeStripForced = ProcessInfo.processInfo.environment["UBIQUITTY_NATIVE_TABBAR"] != nil

    /// Composes native tabs over the window's themed titlebar background.
    ///
    /// The same track material covers opaque and translucent backgrounds.
    /// AppKit owns every pill's fill, selection, hover, and focus appearance.
    ///
    /// - Parameters:
    ///   - container: The calling window's titlebar container.
    ///   - window: Any window in the tab group.
    ///   - usesNativeTitleColors: Whether AppKit also owns title-color resolution.
    @objc
    public static func apply(container: NSView, window: NSWindow, usesNativeTitleColors: Bool) {
        apply(container: container, window: window, usesNativeTitleColors: usesNativeTitleColors, attempt: 0)
    }

    private static func apply(container: NSView, window: NSWindow, usesNativeTitleColors: Bool, attempt: Int) {
        guard #available(macOS 26.0, *) else { return }
        let host = stripHostContainer(inGroupOf: window) ?? container
        guard let strip = tabStrip(in: host) else {
            // AppKit installs or transfers the shared strip after tab selection.
            if (window.tabGroup?.windows.count ?? 1) > 1, attempt < 4 {
                DispatchQueue.main.async {
                    apply(container: container, window: window, usesNativeTitleColors: usesNativeTitleColors, attempt: attempt + 1)
                }
            }
            return
        }
        guard !isNativeStripForced else {
            clear(container: host)
            return
        }
        installNativeMaterial(in: strip)
        if usesNativeTitleColors {
            restoreNativeTitles(in: strip)
        } else {
            themedTitleStrips.add(strip)
            restyleTitles(in: window)
        }
    }

    private static let themedTitleStrips = NSHashTable<NSView>.weakObjects()

    /// Writes every tab's baked title back over AppKit's copy of it.
    ///
    /// AppKit copies a tab's attributed title into the strip with its colour
    /// mapped by main-window and selection state: an unselected title, or any
    /// title in a window that is not main, lands as the system's dim grey
    /// whatever colour was baked — measured at 1.7:1 on a light theme. The
    /// bake already carries both facts, so the copy is written back as baked.
    /// The map runs again whenever the title or that state changes, so this is
    /// called after each: by the strip paint, and by the shells once their own
    /// title and focus handling has landed.
    ///
    /// - Parameter window: Any window of the group.
    @objc(restyleTitlesInWindow:)
    public static func restyleTitles(in window: NSWindow) {
        guard #available(macOS 26.0, *), !isNativeStripForced else { return }
        stripWriteBacksForTesting += 1
        _ = applicationObservers
        // A window showing no strip has nothing to write back into, and the
        // search for one is a walk of its whole title row: a lone window paid
        // that walk on every screen update to be told there is no strip.
        guard window.tabGroup?.isTabBarVisible == true else { return }
        let host = stripHostContainer(inGroupOf: window)
        guard let host, let strip = tabStrip(in: host), themedTitleStrips.contains(strip) else { return }
        let stripHost = stripWindow(of: strip) ?? host.window ?? window
        write(
            titles: bakedTitles(of: stripHost),
            into: pillFields(in: strip, tabCount: stripHost.tabGroup?.windows.count ?? 1),
            windows: stripHost.tabGroup?.windows ?? [stripHost],
            strip: strip
        )
    }

    /// The width a bake fitted a tab's title to, carried on the title.
    package static let fittedWidthKey = NSAttributedString.Key("UBTabTitleFittedWidth")

    /// Told of a tab whose title was fitted to a width its pill no longer
    /// has, with the room the pill has now, so its window can fit it again.
    package static var titleWidthDidChange: ((NSWindow, CGFloat) -> Void)?

    /// The row AppKit lays a tab's content out in, and the item of it that
    /// holds the title.
    ///
    /// The row is the outermost horizontal stack between the title field and
    /// its pill: the close button, the title, and the accessory or AppKit's
    /// own placeholder for one, in that order from the leading end.
    ///
    /// - Parameters:
    ///   - field: The tab's title field.
    ///   - pill: The pill the field stands in, where the search stops.
    /// - Returns: The row and its title item; nil where the field stands in
    ///   no row.
    private static func titleRow(holding field: NSView, under pill: NSView) -> (row: NSStackView, title: NSView)? {
        var child = field
        var found: (row: NSStackView, title: NSView)?
        while let parent = child.superview, parent !== pill {
            if let row = parent as? NSStackView, row.orientation == .horizontal, row.arrangedSubviews.contains(child) {
                found = (row, child)
            }
            child = parent
        }
        return found
    }

    /// The width a tab's title may take, for a bake to fit its label to: the
    /// widest text AppKit lays out centred in the pill and clear of the
    /// controls at both ends.
    ///
    /// The title is centred while it fits, so each side gives up the wider of
    /// the two reaches: the close button with the row's spacing at the leading
    /// end, and the accessory with it at the trailing one. Every term is one
    /// the title does not move. The row's width, the close button's frame and
    /// the accessory's outer edge are AppKit's; the accessory's width is its
    /// content's, because AppKit stretches an accessory toward a short title
    /// and squeezes it under a long one. A room read off the accessory's frame
    /// is the label already shown plus a constant, and a label fitted to it
    /// can never grow back.
    ///
    /// Measured where the write-back already holds the field, and handed to
    /// the tab's window through ``titleWidthDidChange``: a bake that looked
    /// the strip up for itself paid a search of the group's title rows on
    /// screen updates that moved nothing.
    ///
    /// - Parameters:
    ///   - row: The tab's row, as ``titleRow(holding:under:)`` found it.
    ///   - title: The row's title item.
    ///   - accessory: The tab's accessory view, whose width is its content's.
    /// - Returns: The room in whole points; nil before the row is laid out.
    private static func titleRoom(in row: NSStackView, around title: NSView, accessory: NSView?) -> CGFloat? {
        let bounds = row.bounds
        let items = row.arrangedSubviews.filter { !(row.detachesHiddenViews && $0.isHidden) }
        guard bounds.width > 0, let index = items.firstIndex(of: title) else { return nil }
        let isRightToLeft = row.userInterfaceLayoutDirection == .rightToLeft
        func spacing(after view: NSView) -> CGFloat {
            let custom = row.customSpacing(after: view)
            return custom == NSStackView.useDefaultSpacing ? row.spacing : custom
        }
        func width(of view: NSView) -> CGFloat {
            let laidOut = view.alignmentRect(forFrame: view.frame).width
            guard view === accessory else { return laidOut }
            let content = view.intrinsicContentSize.width
            return content == NSView.noIntrinsicMetric ? laidOut : max(0, content)
        }
        // How far one end's items reach in toward the title: the inset to the
        // outermost, then each item and the gap after it, in row order.
        func reach(of side: ArraySlice<NSView>, gaps: [NSView], isLeading: Bool) -> CGFloat {
            let isAtLeft = isLeading != isRightToLeft
            guard let outer = isLeading ? side.first : side.last else {
                return isAtLeft ? row.edgeInsets.left : row.edgeInsets.right
            }
            let edge = outer.alignmentRect(forFrame: outer.frame)
            let inset = isAtLeft ? edge.minX - bounds.minX : bounds.maxX - edge.maxX
            return inset + side.reduce(CGFloat(0)) { $0 + width(of: $1) } + gaps.reduce(CGFloat(0)) { $0 + spacing(after: $1) }
        }
        let leadingSide = items[..<index]
        let trailingSide = items[(index + 1)...]
        let leadingReach = reach(of: leadingSide, gaps: Array(leadingSide), isLeading: true)
        let trailingReach = reach(of: trailingSide, gaps: [title] + trailingSide.dropLast(), isLeading: false)
        let room = (bounds.width - 2 * max(leadingReach, trailingReach)).rounded(.down)
        return room > 0 ? room : nil
    }

    /// Writes a group's titles back once AppKit lays a tab's row out at
    /// another width.
    ///
    /// Nothing else announces that: a tab opening or closing, or the strip
    /// settling after its animation, while every program is quiet, moves the
    /// room with no screen update behind it, and a label fitted to the room
    /// before stays fitted to it.
    @MainActor
    private final class RowWidthWatch: NSObject {
        /// Any window of the row's group, whose strip is written back.
        weak var window: NSWindow?

        init(row: NSView) {
            super.init()
            row.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(rowDidResize(_:)),
                name: NSView.frameDidChangeNotification,
                object: row
            )
        }

        @objc
        private func rowDidResize(_ notification: Notification) {
            guard let window else { return }
            TabStripStyling.writeBackAfterLayout(of: window)
        }
    }

    private static let rowWidthWatches = NSMapTable<NSView, RowWidthWatch>.weakToStrongObjects()

    /// The groups whose rows moved this turn, written back once on the next.
    private static let windowsAwaitingWriteBack = NSHashTable<NSWindow>.weakObjects()

    /// Writes a group's titles back on the next turn, once for every row
    /// that moved in this one: a resize moves every row of the strip.
    fileprivate static func writeBackAfterLayout(of window: NSWindow) {
        let isScheduled = !windowsAwaitingWriteBack.allObjects.isEmpty
        windowsAwaitingWriteBack.add(window)
        guard !isScheduled else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let windows = windowsAwaitingWriteBack.allObjects
                windowsAwaitingWriteBack.removeAllObjects()
                for window in windows {
                    restyleTitles(in: window)
                }
            }
        }
    }

    /// Watches a tab's row for the width AppKit lays it out at.
    ///
    /// - Parameters:
    ///   - row: The row.
    ///   - window: Any window of the row's group.
    private static func watchWidth(of row: NSView, for window: NSWindow) {
        let watch: RowWidthWatch
        if let existing = rowWidthWatches.object(forKey: row) {
            watch = existing
        } else {
            watch = RowWidthWatch(row: row)
            rowWidthWatches.setObject(watch, forKey: row)
        }
        watch.window = window
    }

    /// A pill and the field the strip shows its title in.
    private struct PillField {
        weak var pill: NSGlassEffectView?
        weak var field: NSTextField?
    }

    /// The pills found under each strip, keyed by the strip. The write-back
    /// runs on every screen update and the pills move only when a tab is
    /// added, removed or reordered — so the walk runs again when the count no
    /// longer matches the group or a pill or field has left the strip, and
    /// the write reads the cached pair otherwise.
    private static var pillCache: [ObjectIdentifier: [PillField]] = [:]

    @available(macOS 26.0, *)
    private static func pillFields(in strip: NSView, tabCount: Int) -> [PillField] {
        let key = ObjectIdentifier(strip)
        if let cached = pillCache[key], cached.count == tabCount,
            cached.allSatisfy({ entry in
                guard let pill = entry.pill, let field = entry.field else { return false }
                return pill.isDescendant(of: strip) && field.isDescendant(of: pill)
            })
        {
            // Dragging a tab moves the existing pill views without changing
            // their count or ancestry. Keep the cached hierarchy lookup, but
            // pair titles with pills in their current visual order.
            return cached.sorted { first, second in
                guard let firstPill = first.pill, let secondPill = second.pill else { return false }
                let firstX = firstPill.convert(firstPill.bounds, to: strip).midX
                let secondX = secondPill.convert(secondPill.bounds, to: strip).midX
                return strip.userInterfaceLayoutDirection == .rightToLeft
                    ? firstX > secondX
                    : firstX < secondX
            }
        }
        let found = pills(in: strip)
            .map { pill -> PillField in
                let fields = pill.descendants(ofType: NSTextField.self)
                let field = fields.first(where: { !$0.stringValue.isEmpty }) ?? fields.first
                return PillField(pill: pill, field: field)
            }
        pillCache[key] = found
        return found
    }

    /// The titlebar container found for each window, weakly on both sides: a
    /// window that closes and a container AppKit replaces both leave, and
    /// neither is kept alive by having been searched for.
    private static let titlebarContainers = NSMapTable<NSWindow, NSView>.weakToWeakObjects()

    /// The cached container, while it is still valid for the window.
    ///
    /// Valid means in a view tree and standing in this window's title row —
    /// the window itself while it is ordinary, or the toolbar window AppKit
    /// parents to it in full screen. A container that fails either test is a
    /// miss, so the search runs again for the row that stands now.
    ///
    /// - Parameter window: The window to answer for.
    /// - Returns: The container, or nil for a miss.
    static func cachedTitlebarContainer(of window: NSWindow) -> NSView? {
        guard let cached = titlebarContainers.object(forKey: window), cached.superview != nil,
            let host = cached.window
        else {
            return nil
        }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if host === window {
            return isFullScreen ? nil : cached
        }
        guard isFullScreen, host.parent === window, isMember(host, of: "NSToolbarFullScreenWindow") else {
            return nil
        }
        return cached
    }

    /// Keeps a found container for the window it was found in. Only a found
    /// one: caching "no container" would record the window's own start-up,
    /// where AppKit has not built one yet, as the answer for its whole life.
    ///
    /// - Parameters:
    ///   - container: The container the search found.
    ///   - window: The window it belongs to.
    static func cacheTitlebarContainer(_ container: NSView, of window: NSWindow) {
        titlebarContainers.setObject(container, forKey: window)
    }

    /// Drops what is remembered about a window's title row.
    ///
    /// For the edges that rebuild it: hiding or showing the bar, a titlebar
    /// style change, the Inspector's re-host, and the full-screen settle.
    ///
    /// - Parameter window: The window whose row was rebuilt.
    @objc(forgetTitlebarOfWindow:)
    public static func forgetTitlebar(of window: NSWindow) {
        titlebarContainers.removeObject(forKey: window)
        for group in [window.tabGroup].compactMap({ $0 }) {
            stripHosts.removeObject(forKey: group)
        }
    }

    /// The strip each tab group's one bar was last found in, weakly: the
    /// group goes when its last window does, and a strip AppKit moves between
    /// windows leaves by failing the validity test below.
    private static let stripHosts = NSMapTable<NSWindowTabGroup, NSView>.weakToWeakObjects()

    /// AppKit runs its colour map over every strip as the application
    /// activates or resigns, including the strips of windows that were not
    /// main either way and so hear no focus change of their own, so every
    /// themed strip is written back after either. Installed once, on the first
    /// write-back.
    private static let applicationObservers: [NSObjectProtocol] = {
        let center = NotificationCenter.default
        return [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    // After the turn: the map runs on the same notification.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if #available(macOS 26.0, *) {
                                restyleEveryThemedStrip()
                            }
                        }
                    }
                }
            }
    }()

    /// Writes theme-colored titles after AppKit refreshes a strip's state.
    @available(macOS 26.0, *)
    private static func restyleEveryThemedStrip() {
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            guard let group = window.tabGroup, seen.insert(ObjectIdentifier(group)).inserted,
                let host = stripHostContainer(inGroupOf: window), let strip = tabStrip(in: host),
                themedTitleStrips.contains(strip)
            else { continue }
            write(
                titles: bakedTitles(of: stripWindow(of: strip) ?? host.window ?? window),
                into: pillFields(in: strip, tabCount: group.windows.count),
                windows: group.windows,
                strip: strip
            )
        }
    }

    /// The attributed titles the group's windows baked, in strip order.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: One entry per tab; nil where a tab carries no baked title.
    private static func bakedTitles(of window: NSWindow) -> [NSAttributedString?] {
        (window.tabGroup?.windows ?? [window]).map(\.tab.attributedTitle)
    }

    /// Writes each baked title into its pill's title field, where it differs
    /// from what the field holds.
    ///
    /// - Parameters:
    ///   - titles: The baked titles, in strip order.
    ///   - pills: The pills, in strip order.
    ///   - windows: The group's windows, in strip order.
    ///   - strip: The native strip holding the fields.
    @available(macOS 26.0, *)
    private static func write(titles: [NSAttributedString?], into pills: [PillField], windows: [NSWindow], strip: NSView) {
        for (index, entry) in pills.enumerated() {
            guard index < titles.count, let title = titles[index], let field = entry.field else { continue }
            if index < windows.count {
                let guardForField: TitleFieldGuard
                if let existing = titleFieldGuards.object(forKey: field) {
                    guardForField = existing
                } else {
                    guardForField = TitleFieldGuard(field: field)
                    titleFieldGuards.setObject(guardForField, forKey: field)
                }
                guardForField.window = windows[index]
                guardForField.strip = strip
            }
            if !field.attributedStringValue.isEqual(to: title) {
                field.attributedStringValue = title
            }
            // A title fitted to a width its pill no longer has, or to none, is
            // fitted again after this write: tabs come and go, a window
            // resizes, and an accessory comes or goes.
            guard title.length > 0, index < windows.count, let pill = entry.pill,
                let found = titleRow(holding: field, under: pill)
            else { continue }
            let window = windows[index]
            watchWidth(of: found.row, for: window)
            if let room = titleRoom(in: found.row, around: found.title, accessory: window.tab.accessoryView),
                abs((title.attribute(fittedWidthKey, at: 0, effectiveRange: nil) as? CGFloat ?? 0) - room) > 0.5
            {
                DispatchQueue.main.async { titleWidthDidChange?(window, room) }
            }
        }
    }

    /// Restores AppKit's unmodified track and title handling.
    @objc
    public static func clear(container: NSView) {
        guard #available(macOS 26.0, *) else { return }
        let host = container.window.flatMap { stripHostContainer(inGroupOf: $0) } ?? container
        guard let strip = tabStrip(in: host) else { return }
        restoreTransparentMaterial(in: strip)
        restoreNativeTitles(in: strip)
    }

    /// Composes native tabs over the titlebar without replacing semantic ink.
    @objc
    public static func useTransparentMaterial(container: NSView) {
        guard !isNativeStripForced else {
            clear(container: container)
            return
        }
        guard #available(macOS 26.0, *) else { return }
        let host = container.window.flatMap { stripHostContainer(inGroupOf: $0) } ?? container
        guard let strip = tabStrip(in: host) else { return }
        installNativeMaterial(in: strip)
        restoreNativeTitles(in: strip)
    }

    @available(macOS 26.0, *)
    private static func installNativeMaterial(in strip: NSView) {
        let band = bandGlass(in: strip)
        let filterHost = band == nil ? TabStripMaterial.filterHost(in: strip) : nil
        if transparentMaterials.object(forKey: strip)?.matches(glassBand: band, filterHost: filterHost) == true { return }
        restoreTransparentMaterial(in: strip)
        if let band {
            transparentMaterials.setObject(TabStripMaterial(glassBand: band), forKey: strip)
        } else if let filterHost {
            transparentMaterials.setObject(TabStripMaterial(filterHost: filterHost), forKey: strip)
        }
    }

    @available(macOS 26.0, *)
    private static let transparentMaterials = NSMapTable<NSView, TabStripMaterial>.weakToStrongObjects()

    @available(macOS 26.0, *)
    private static func restoreTransparentMaterial(in strip: NSView) {
        transparentMaterials.object(forKey: strip)?.restore()
        transparentMaterials.removeObject(forKey: strip)
    }

    private static func restoreNativeTitles(in strip: NSView) {
        guard themedTitleStrips.contains(strip) else { return }
        themedTitleStrips.remove(strip)
        for entry in pillFields(in: strip, tabCount: stripWindow(of: strip)?.tabGroup?.windows.count ?? 0) {
            guard let field = entry.field else { continue }
            titleFieldGuards.object(forKey: field)?.stop()
            titleFieldGuards.removeObject(forKey: field)
        }
        // A title change asks AppKit to resolve its native foreground again.
        for tabWindow in stripWindow(of: strip)?.tabGroup?.windows ?? [] {
            let baked = tabWindow.tab.attributedTitle
            tabWindow.tab.attributedTitle = nil
            tabWindow.tab.attributedTitle = baked
        }
    }

    // MARK: - View lookup

    /// The container currently holding the group's one tab strip.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: The hosting container, or nil while the strip is between
    ///   windows.
    /// The tab strip of a window's group, wherever in the title row it lives.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: The strip, or nil where the group has no strip.
    package static func tabStripView(inGroupOf window: NSWindow) -> NSView? {
        guard let host = stripHostContainer(inGroupOf: window) else { return nil }
        return tabStrip(in: host)
    }

    /// Resolves a native tab face to its window, excluding the close control.
    static func transferTab(at point: NSPoint, in window: NSWindow) -> NSWindow? {
        guard let strip = tabStripView(inGroupOf: window), let group = window.tabGroup,
            strip.bounds.contains(strip.convert(point, from: nil))
        else { return nil }
        var buttons: [NSView] = []
        func collect(_ view: NSView) {
            if NSStringFromClass(type(of: view)) == "NSTabButton" {
                buttons.append(view)
            } else {
                view.subviews.forEach(collect)
            }
        }
        collect(strip)
        buttons.sort {
            let left = $0.convert($0.bounds, to: strip).minX
            let right = $1.convert($1.bounds, to: strip).minX
            return strip.userInterfaceLayoutDirection == .rightToLeft ? left > right : left < right
        }
        guard buttons.count == group.windows.count else { return nil }
        for (index, button) in buttons.enumerated() {
            let location = button.convert(point, from: nil)
            guard button.bounds.contains(location) else { continue }
            var hit = button.hitTest(button.superview?.convert(point, from: nil) ?? location)
            while let view = hit, view !== button {
                if view is NSButton { return nil }
                hit = view.superview
            }
            return group.windows[index]
        }
        return nil
    }

    /// The view inside the SELECTED tab's pill that chrome is pinned into.
    ///
    /// One band is shared by the whole group and its glass children are the
    /// pills; `NSTabButton`'s own `active` flag is what marks the selected one,
    /// the same traversal the strip tint walks. Glass pills arrived with macOS
    /// 26 — on an older system there is no pill to pin into at all, and a tab
    /// carries its report in the ring accessory instead.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: The pill's content view, or nil where there is no strip, no
    ///   glass, or no pill marked active.
    @objc(activePillContentInGroupOf:)
    public static func activePillContent(inGroupOf window: NSWindow) -> NSView? {
        guard #available(macOS 26.0, *) else { return nil }
        guard let strip = tabStripView(inGroupOf: window) else {
            return nil
        }
        for pill in pills(in: strip) {
            guard let button = enclosingTabButton(of: pill, under: strip), isActiveTabButton(button) else {
                continue
            }
            return pill.subviews.first ?? pill
        }
        return nil
    }

    /// The content view inside every pill of a group's strip, in tab order, with
    /// whether each pill's tab is the selected one.
    ///
    /// For a UI scenario that has to address a pill other than the selected
    /// one. The selection test is the one ``activePillContent(inGroupOf:)``
    /// uses, so a scenario does not re-derive AppKit's flag beside it.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: One entry per pill, leading to trailing; empty where there is
    ///   no strip or no glass.
    package static func pillContentsForTesting(inGroupOf window: NSWindow) -> [(content: NSView, isSelected: Bool)] {
        guard #available(macOS 26.0, *) else { return [] }
        guard let strip = tabStripView(inGroupOf: window) else {
            return []
        }
        return pills(in: strip)
            .map { pill in
                let isSelected = enclosingTabButton(of: pill, under: strip).map { isActiveTabButton($0) } ?? false
                return (pill.subviews.first ?? pill, isSelected)
            }
    }

    /// Every tab's pill in a group's strip, in tab order, with its tab button.
    ///
    /// For reading what each tab carries: the content view is the pill's
    /// own, and the button is where AppKit keeps the tab's title field and
    /// close control.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: One entry per pill, leading to trailing; empty where there is
    ///   no strip.
    package static func tabPills(inGroupOf window: NSWindow) -> [(button: NSView, content: NSView)] {
        guard #available(macOS 26.0, *), let strip = tabStripView(inGroupOf: window) else {
            return []
        }
        return pills(in: strip)
            .compactMap { pill in
                enclosingTabButton(of: pill, under: strip).map { ($0, pill.subviews.first ?? pill) }
            }
    }

    /// Each tab button's subtree as text — class, frame in the button, hidden
    /// and alpha — for a scenario that has to read where AppKit put a tab's
    /// close control and title before and during a hover.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: One block of lines per tab button.
    package static func describeTabButtonsForTesting(inGroupOf window: NSWindow) -> String {
        var lines: [String] = []
        for (index, entry) in tabPills(inGroupOf: window).enumerated() {
            lines.append("tab \(index): button \(NSStringFromClass(type(of: entry.button))) \(entry.button.frame)")
            var stack: [(NSView, Int)] = entry.button.subviews.map { ($0, 1) }
            while let (view, depth) = stack.popLast() {
                let frame = view.convert(view.bounds, to: entry.button)
                var detail = ""
                if let field = view as? NSTextField {
                    detail = " text=\(field.stringValue.debugDescription) baseline=\(field.firstBaselineOffsetFromTop)"
                }
                lines.append(
                    String(repeating: "  ", count: depth)
                        + "\(NSStringFromClass(type(of: view))) \(frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)"
                        + detail
                )
                stack.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) })
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The strip's traversal, link by link, as text: what each step found or
    /// did not, and the class tree of the strip to a fixed depth. For a UI
    /// scenario whose pill wait ran out, so the run's log names the link of
    /// the chain that answered nil rather than only that the chain did. The
    /// class names are exact, as the traversal matches them, so a release that
    /// renames or re-nests one is read off the tree.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: A multi-line description; never empty.
    package static func describeStrip(inGroupOf window: NSWindow) -> String {
        var lines = ["tab strip traversal for '\(window.title)':"]
        guard #available(macOS 26.0, *) else {
            lines.append("  an earlier release than macOS 26: no glass strip to describe")
            return lines.joined(separator: "\n")
        }
        guard let container = stripHostContainer(inGroupOf: window) else {
            // No window of the group has a titlebar container with an NSTabBar
            // under it. Each is listed with what its container does hold, so a
            // bar that moved or was renamed is read off the tree.
            lines.append("  host container: none — no titlebar container in the group holds an NSTabBar")
            for candidate in window.tabGroup?.windows ?? [window] {
                guard let titlebar = candidate.titlebarContainer else {
                    lines.append("    window '\(candidate.title)': no titlebar container")
                    continue
                }
                lines.append("    window '\(candidate.title)': titlebar container, holding:")
                lines.append(contentsOf: classTree(of: titlebar, depth: 2, limit: 6))
            }
            return lines.joined(separator: "\n")
        }
        lines.append("  host container: \(NSStringFromClass(type(of: container)))")
        guard let strip = tabStrip(in: container) else {
            lines.append("  NSTabBar under the container: none")
            lines.append(contentsOf: classTree(of: container, depth: 0, limit: 9))
            return lines.joined(separator: "\n")
        }
        let found = pills(in: strip)
        lines.append(
            "  NSTabBar: found; band glass: \(bandGlass(in: strip) == nil ? "none" : "found"); pills under the bar: \(found.count)"
        )
        for (index, pill) in found.enumerated() {
            if let button = enclosingTabButton(of: pill, under: strip) {
                lines.append("    pill \(index): NSTabButton ancestor found, active=\(isActiveTabButton(button))")
            } else {
                lines.append("    pill \(index): no NSTabButton ancestor")
            }
        }
        // Every glass-kind view under the bar, with its depth and whether its
        // class is exactly NSGlassEffectView: the pills are the exact glass
        // inside a tab button, so a release that draws them as a subclass, or
        // outside one, shows here as glass-kind views the traversal walked
        // past.
        lines.append("  glass-kind views under the bar:")
        lines.append(contentsOf: glassKind(under: strip, depth: 0))
        lines.append(contentsOf: classTree(of: strip, depth: 0, limit: 9))
        return lines.joined(separator: "\n")
    }

    /// Every descendant that is an NSGlassEffectView or a subclass, one per
    /// line with its depth and whether the class is exactly NSGlassEffectView.
    @available(macOS 26.0, *)
    private static func glassKind(under view: NSView, depth: Int) -> [String] {
        var lines: [String] = []
        if view is NSGlassEffectView {
            let exact = isMember(view, of: "NSGlassEffectView")
            lines.append("    depth \(depth): \(NSStringFromClass(type(of: view)))\(exact ? " (exact)" : " (subclass)")")
        }
        for subview in view.subviews {
            lines.append(contentsOf: glassKind(under: subview, depth: depth + 1))
        }
        return lines
    }

    /// A view's class and its descendants', one per line, indented by depth
    /// and cut at `limit` levels below the root.
    private static func classTree(of view: NSView, depth: Int, limit: Int) -> [String] {
        var lines = [String(repeating: "  ", count: depth + 1) + NSStringFromClass(type(of: view))]
        guard depth < limit else { return lines }
        for subview in view.subviews {
            lines.append(contentsOf: classTree(of: subview, depth: depth + 1, limit: limit))
        }
        return lines
    }

    /// Whether a view stands inside the selected tab's pill.
    ///
    /// Walks up from the view to its tab button rather than down from the
    /// strip, so asking on every progress tick costs a few ancestors and not a
    /// descent through the whole title row.
    ///
    /// - Parameters:
    ///   - view: The view to ask about, typically a band already homed in a pill.
    ///   - strip: The group's strip, where the walk stops.
    /// - Returns: Whether the tab button above the view is marked active; false
    ///   where the view stands under no tab button.
    package static func isInSelectedPill(_ view: NSView, under strip: NSView) -> Bool {
        guard let button = enclosingTabButton(of: view, under: strip) else {
            return false
        }
        return isActiveTabButton(button)
    }

    /// The tab button a pill belongs to.
    ///
    /// - Parameters:
    ///   - view: The pill.
    ///   - strip: Where the walk stops, so it cannot climb out of the strip.
    /// - Returns: The button, or nil for a pill standing under none.
    private static func enclosingTabButton(of view: NSView, under strip: NSView) -> NSView? {
        var ancestor = view.superview
        while let current = ancestor, current !== strip {
            if isMember(current, of: "NSTabButton") {
                return current
            }
            ancestor = current.superview
        }
        return nil
    }

    /// Whether a tab button is its strip's selected one.
    ///
    /// Asked by key-value coding because the flag is not on any published
    /// interface, and only where the getter exists: `value(forKey:)` on a key
    /// a class does not implement raises an Objective-C exception, which
    /// nothing on this side can catch.
    ///
    /// - Parameter view: The `NSTabButton` to ask.
    /// - Returns: Whether it is marked active; false where it cannot say.
    private static func isActiveTabButton(_ view: NSView) -> Bool {
        guard view.responds(to: NSSelectorFromString("isActive")) else { return false }
        return (view.value(forKey: "active") as? Bool) ?? false
    }

    /// Entries into the title write-back, for a scenario asking what a quiet
    /// screen update costs.
    package private(set) static var stripWriteBacksForTesting = 0

    /// The native field of a tab, for a scenario observing AppKit's title map.
    @available(macOS 26.0, *)
    package static func testTitleField(inGroupOf window: NSWindow, at index: Int) -> NSTextField? {
        guard let host = stripHostContainer(inGroupOf: window), let strip = tabStrip(in: host) else { return nil }
        let fields = pillFields(in: strip, tabCount: window.tabGroup?.windows.count ?? 1)
        guard fields.indices.contains(index) else { return nil }
        return fields[index].field
    }

    /// The room a tab's title has in its pill, as the write-back measures it.
    ///
    /// - Parameters:
    ///   - window: Any window of the group.
    ///   - index: The tab's place in the strip.
    /// - Returns: The room in whole points; nil where the tab's row is not found.
    @available(macOS 26.0, *)
    package static func titleRoomForTesting(inGroupOf window: NSWindow, at index: Int) -> CGFloat? {
        guard let host = stripHostContainer(inGroupOf: window), let strip = tabStrip(in: host) else { return nil }
        let windows = window.tabGroup?.windows ?? [window]
        let fields = pillFields(in: strip, tabCount: windows.count)
        guard fields.indices.contains(index), index < windows.count, let pill = fields[index].pill,
            let field = fields[index].field, let found = titleRow(holding: field, under: pill)
        else { return nil }
        return titleRoom(in: found.row, around: found.title, accessory: windows[index].tab.accessoryView)
    }

    /// Synchronous corrections made to one native title field.
    @available(macOS 26.0, *)
    package static func testTitleFieldCorrections(inGroupOf window: NSWindow, at index: Int) -> Int? {
        guard let field = testTitleField(inGroupOf: window, at: index) else { return nil }
        return titleFieldGuards.object(forKey: field)?.correctionsForTesting
    }

    /// Searches for the group's strip host, which a cache stands in front of.
    package private(set) static var stripHostSearchesForTesting = 0

    /// Searches for a window's titlebar container, which a cache stands in
    /// front of.
    package private(set) static var titlebarContainerSearchesForTesting = 0

    /// The container currently holding the group's one tab strip.
    ///
    /// AppKit hosts one strip per group and moves it a turn after the
    /// selection changes, so the answer is kept against the strip itself
    /// rather than against a window: the cached strip stands while it is in a
    /// tree and its window still belongs to the group, which is what the
    /// first-found search answers during the turn AppKit is moving it.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: The hosting container, or nil while the group has no strip.
    private static func stripHostContainer(inGroupOf window: NSWindow) -> NSView? {
        if let group = window.tabGroup, let strip = stripHosts.object(forKey: group), strip.superview != nil,
            let host = stripWindow(of: strip), group.windows.contains(host),
            let container = enclosingTitlebarContainer(of: strip)
        {
            return container
        }
        stripHostSearchesForTesting += 1
        let groupWindows = window.tabGroup?.windows ?? [window]
        for candidate in groupWindows {
            if let container = candidate.titlebarContainer, let strip = tabStrip(in: container) {
                if let group = window.tabGroup {
                    stripHosts.setObject(strip, forKey: group)
                }
                return container
            }
        }
        return nil
    }

    /// The group window a strip stands in: its own, or the window AppKit
    /// parents the full-screen toolbar to.
    ///
    /// - Parameter strip: The strip view.
    /// - Returns: The window of the group, or nil for a strip standing in none.
    private static func stripWindow(of strip: NSView) -> NSWindow? {
        guard let host = strip.window else { return nil }
        if isMember(host, of: "NSToolbarFullScreenWindow") {
            return host.parent
        }
        return host
    }

    /// The titlebar container a strip stands under.
    ///
    /// Walked up from the strip rather than searched down from the window: the
    /// strip is what the cache holds, and the container is whichever of its
    /// ancestors is the title row.
    ///
    /// - Parameter strip: The strip view.
    /// - Returns: The container, or nil for a strip standing outside one.
    private static func enclosingTitlebarContainer(of strip: NSView) -> NSView? {
        guard let resolved = namedClass("NSTitlebarContainerView") else { return nil }
        var ancestor: NSView? = strip.superview
        while let current = ancestor {
            if current.isMember(of: resolved) {
                return current
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func tabStrip(in container: NSView) -> NSView? {
        firstDescendant(of: container, className: "NSTabBar")
    }

    // The band under the strip, where a release draws one as glass: the first
    // glass-kind view under the bar that sits outside every tab button. macOS
    // 26 draws the band as an NSGlassEffectView with the pills as glass inside
    // it; macOS 27 draws the band as a private material that is no glass view
    // at all, and the pills as exact NSGlassEffectViews inside their
    // NSTabButtons. So the pills are found by their button, and the band is
    // whatever glass is left. TabStripMaterial handles either track hierarchy;
    // the pills retain AppKit's native selection material.
    @available(macOS 26.0, *)
    private static func bandGlass(in strip: NSView) -> NSGlassEffectView? {
        glassDescendants(of: strip).first { enclosingTabButton(of: $0, under: strip) == nil }
    }

    /// Every descendant that is an NSGlassEffectView or a subclass of it.
    @available(macOS 26.0, *)
    private static func glassDescendants(of root: NSView) -> [NSGlassEffectView] {
        var found: [NSGlassEffectView] = []
        for subview in root.subviews {
            if let glass = subview as? NSGlassEffectView {
                found.append(glass)
            }
            found.append(contentsOf: glassDescendants(of: subview))
        }
        return found
    }

    /// The strip's pills: the glass inside each tab button, leading to
    /// trailing.
    @available(macOS 26.0, *)
    private static func pills(in strip: NSView) -> [NSGlassEffectView] {
        var found: [NSView] = []
        collectDescendants(of: strip, className: "NSGlassEffectView", into: &found)
        var glass = found.compactMap { $0 as? NSGlassEffectView }.filter { enclosingTabButton(of: $0, under: strip) != nil }
        // The exact match is what the earlier string compare did, not a rule
        // that a pill cannot be a subclass. A release that draws the pills as
        // one leaves the exact walk empty, and only then does the walk accept
        // any NSGlassEffectView inside a tab button.
        if glass.isEmpty {
            glass = glassDescendants(of: strip).filter { enclosingTabButton(of: $0, under: strip) != nil }
        }
        // AppKit does not define descendant enumeration as tab order, while
        // `NSWindowTabGroup.windows` follows the strip's leading-to-trailing
        // order. Selection paint must pair the two in the same coordinate
        // system.
        return glass.sorted { first, second in
            let firstX = first.convert(first.bounds, to: strip).midX
            let secondX = second.convert(second.bounds, to: strip).midX
            return strip.userInterfaceLayoutDirection == .rightToLeft
                ? firstX > secondX
                : firstX < secondX
        }
    }

    // The class a name denotes, resolved once per name.
    //
    // A descendant search asks "is this the class called X" of every view it
    // visits, and `NSStringFromClass(type(of:))` answers by building a String:
    // an allocation and a character comparison per view, down the whole window,
    // several searches deep, on every screen update. A name denotes a class
    // object, so the question is identity against that object, and the same
    // search then costs a pointer compare per view.
    //
    // A name AppKit does not define resolves to nil and is cached as nil, which
    // is the answer the name comparison reached by never matching.
    private static var classesByName: [String: AnyClass?] = [:]

    fileprivate static func namedClass(_ name: String) -> AnyClass? {
        if let known = classesByName[name] {
            return known
        }
        // Annotated because the memo stores an optional class per name — a name
        // AppKit does not define is cached as "no such class" rather than asked
        // again — and inference otherwise reads the double optional as a
        // mistake.
        let resolved: AnyClass? = NSClassFromString(name)
        classesByName[name] = resolved
        return resolved
    }

    /// Whether an object's class is exactly the named one.
    ///
    /// Exact rather than `isKind(of:)`, because that is what comparing the
    /// class name did: a subclass carries its own name and never matched.
    ///
    /// - Parameters:
    ///   - object: The object to test.
    ///   - name: The class name, as AppKit spells it.
    /// - Returns: Whether the object is exactly that class.
    fileprivate static func isMember(_ object: NSObject, of name: String) -> Bool {
        guard let resolved = namedClass(name) else { return false }
        return object.isMember(of: resolved)
    }

    private static func firstDescendant(of root: NSView, className: String) -> NSView? {
        guard let resolved = namedClass(className) else { return nil }
        for subview in root.subviews {
            if subview.isMember(of: resolved) {
                return subview
            }
            if let found = firstDescendant(of: subview, className: className) {
                return found
            }
        }
        return nil
    }

    private static func collectDescendants(of root: NSView, className: String, into found: inout [NSView]) {
        guard let resolved = namedClass(className) else { return }
        collectDescendants(of: root, resolvedClass: resolved, into: &found)
    }

    private static func collectDescendants(of root: NSView, resolvedClass: AnyClass, into found: inout [NSView]) {
        for subview in root.subviews {
            if subview.isMember(of: resolvedClass) {
                found.append(subview)
            }
            collectDescendants(of: subview, resolvedClass: resolvedClass, into: &found)
        }
    }

    @available(macOS 26.0, *)
    package static func testPaint(
        in container: NSView
    ) -> (
        band: CGColor?, pills: [CGColor?], tints: [NSColor?], titleAlphas: [[CGFloat]],
        buttonAlphas: [[CGFloat]], styles: [NSGlassEffectView.Style], positions: [CGFloat],
        titleColors: [[CGColor?]]
    )? {
        guard let strip = tabStrip(in: container), let window = container.window else { return nil }
        let band = bandGlass(in: strip)
        let allPills = pills(in: strip)
        let titles = bakedTitles(of: window)
        return (
            band?.contentView?.layer?.backgroundColor,
            allPills.map { $0.contentView?.layer?.backgroundColor },
            allPills.map(\.tintColor),
            allPills.map { $0.descendants(ofType: NSTextField.self).map(\.alphaValue) },
            allPills.map { $0.descendants(ofType: NSButton.self).map(\.alphaValue) },
            allPills.map(\.style),
            allPills.map { $0.convert($0.bounds, to: strip).midX },
            allPills.enumerated()
                .map { index, pill -> [CGColor?] in
                    guard index < titles.count, let title = titles[index],
                        let field = pill.descendants(ofType: NSTextField.self).first(where: { $0.stringValue == title.string })
                    else { return [nil] }
                    let drawn = field.attributedStringValue
                    guard drawn.length > 0 else { return [field.textColor?.cgColor] }
                    return [(drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.cgColor]
                }
        )
    }

    @available(macOS 26.0, *)
    package static func testAppearanceNames(
        in container: NSView
    ) -> (
        container: NSAppearance.Name?, strip: NSAppearance.Name?, outer: NSAppearance.Name?,
        pills: [NSAppearance.Name?]
    )? {
        guard let strip = tabStrip(in: container) else { return nil }
        return (
            container.appearance?.name,
            strip.appearance?.name,
            bandGlass(in: strip)?.appearance?.name,
            pills(in: strip).map { $0.appearance?.name }
        )
    }

    /// Whether the strip under a container draws its band as glass this
    /// release, so a scenario knows whether a band assertion has a subject.
    ///
    /// - Parameter container: The window's titlebar container view.
    /// - Returns: True where a band glass stands outside the tab buttons.
    @available(macOS 26.0, *)
    package static func stripHasBand(in container: NSView) -> Bool {
        guard let strip = tabStrip(in: container) else { return false }
        return bandGlass(in: strip) != nil
    }

    /// Returns the native band's material tint for rendering tests.
    @available(macOS 26.0, *)
    package static func testBandTint(in container: NSView) -> NSColor? {
        guard let strip = tabStrip(in: container) else { return nil }
        return bandGlass(in: strip)?.tintColor
    }
}

extension NSView {
    fileprivate func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        var result: [T] = []
        for subview in subviews {
            if let match = subview as? T { result.append(match) }
            result.append(contentsOf: subview.descendants(ofType: type))
        }
        return result
    }
}

extension NSWindow {
    /// The titlebar container view, windowed or fullscreen.
    ///
    /// Fullscreen moves it into a separate AppKit-owned window, so the search
    /// starts from whichever root currently holds it.
    ///
    /// Found once and kept. The chrome asks on every screen update, and the
    /// search is a depth-first walk of the whole frame view — for a window
    /// with no strip it walks everything and answers nil. The cached view is
    /// used while it is still in a tree and still this window's title row, so
    /// a container AppKit rebuilds, a window re-hosted into full screen and a
    /// window handed back out of it are all misses that search again.
    var titlebarContainer: NSView? {
        if let cached = TabStripStyling.cachedTitlebarContainer(of: self) {
            return cached
        }
        let found = searchedTitlebarContainer
        if let found {
            TabStripStyling.cacheTitlebarContainer(found, of: self)
        }
        return found
    }

    /// The container as a search of the view tree finds it.
    private var searchedTitlebarContainer: NSView? {
        if !styleMask.contains(.fullScreen) {
            let root = contentView?.superview ?? contentView
            return root.flatMap { TabStripStyling.titlebarContainer(searchingFrom: $0) }
        }
        for child in childWindows ?? [] where TabStripStyling.isMember(child, of: "NSToolbarFullScreenWindow") {
            if let root = child.contentView,
                let found = TabStripStyling.titlebarContainer(searchingFrom: root)
            {
                return found
            }
        }
        return nil
    }
}

extension TabStripStyling {
    package static func titlebarContainer(searchingFrom root: NSView) -> NSView? {
        titlebarContainerSearchesForTesting += 1
        guard let resolved = namedClass("NSTitlebarContainerView") else { return nil }
        return titlebarContainer(searchingFrom: root, resolvedClass: resolved)
    }

    private static func titlebarContainer(searchingFrom root: NSView, resolvedClass: AnyClass) -> NSView? {
        if root.isMember(of: resolvedClass) {
            return root
        }
        for subview in root.subviews {
            if let found = titlebarContainer(searchingFrom: subview, resolvedClass: resolvedClass) {
                return found
            }
        }
        return nil
    }
}
