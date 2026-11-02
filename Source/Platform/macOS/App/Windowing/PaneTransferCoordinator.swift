// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Carries a live pane or tab through a drag; the backend owns its layout.
@MainActor
package final class PaneTransferCoordinator: NSObject, NSDraggingSource {
    package static let shared = PaneTransferCoordinator()
    static let pasteboardType = NSPasteboard.PasteboardType("org.ubiquitty.pane-transfer")

    package struct Transfer {
        let controller: TerminalWindowController
        let surface: TerminalSurface
        let scope: Ubiquitty.Runtime.TerminalSession.TransferScope
        package init(controller: TerminalWindowController, surface: TerminalSurface, wholeTab: Bool) {
            self.controller = controller
            self.surface = surface
            self.scope = wholeTab ? .Tab : .Pane
        }
    }

    package enum Placement: CaseIterable {
        case tab, left, right, above, below

        var title: String {
            switch self {
            case .tab: return "Move to Tab"
            case .left: return "Split Left"
            case .right: return "Split Right"
            case .above: return "Split Above"
            case .below: return "Split Below"
            }
        }
        var orientation: Ubiquitty.Panes.Orientation { self == .above || self == .below ? .Horizontal : .Vertical }
        var side: Ubiquitty.Panes.InsertSide { self == .left || self == .above ? .First : .Second }
    }

    package struct Destination {
        let controller: TerminalWindowController
        let surface: TerminalSurface
        package let placement: Placement
        package let frame: NSRect
        let paneFrame: NSRect
        let tabFrame: NSRect
        package let allowsSplit: Bool
        package let allowsRootSplit: Bool
        package var insertTarget: Ubiquitty.Panes.InsertTarget = .Pane
        package var acceptsDrop = true

        var title: String {
            insertTarget == .Root ? placement.title.replacingOccurrences(of: "Split ", with: "Split Tab ") : placement.title
        }
    }

    private var monitor: Any?
    private var pending: (Transfer, NSEvent)?
    private var active: Transfer?
    private var overlays: [TransferDropView] = []
    private var cancelled = false
    private var menuActions: [() -> Void] = []

    private struct NativeTabDrag {
        let transfer: Transfer
        let origin: NSPoint
        let originalWindows: [NSWindow]
        let originalFrame: NSRect
        var started = false
        var destination: Destination?
    }
    private var nativeTabDrag: NativeTabDrag?
    private var completingNativeTransfer: Transfer?
    private var nativeTrackingTimer: Timer?

    /// Whether the transfer being completed was a drag that left its tab's
    /// face, rather than a press released where it landed.
    private var didCompletingDragStart = false

    /// Whether a tab is being dragged out of its strip, or such a drag is
    /// being settled: the selection AppKit moves meanwhile is provisional. A
    /// press that has not moved is a click, and the tab it selects is the
    /// person's choice.
    var isDraggingNativeTab: Bool {
        nativeTabDrag?.started == true || (completingNativeTransfer != nil && didCompletingDragStart)
    }

    func isTrackingNativeTab(from drive: RuntimeDrive) -> Bool {
        guard let transfer = nativeTabDrag?.transfer ?? completingNativeTransfer else { return false }
        return transfer.surface.drive.sharesRemoteWorkspaceConnection(with: drive)
    }

    private struct HostedPlacement {
        weak var source: RuntimeDrive?
        let pane: Int32
        weak var destination: NSWindow?
        let placement: Ubiquitty.Runtime.TerminalSession.ExtractionPlacement
        let expires: Date
    }
    private var hostedPlacements: [HostedPlacement] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            cancelled = true
            pending = nil
            finishNativeTabDrag()
            return event
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            guard let transfer = transfer(at: event) else { return event }
            if event.type == .rightMouseDown {
                showMenu(for: transfer, event: event)
            } else if transfer.scope == .Tab {
                observeNativeTabDrag(transfer, event: event)
                return event
            } else {
                pending = (transfer, event)
            }
            return nil
        }
        if nativeTabDrag != nil {
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if event.type == .leftMouseDragged {
                updateNativeTabDrag(at: point)
            } else if event.type == .leftMouseUp {
                updateNativeTabDrag(at: point)
                finishNativeTabDrag()
            }
            return event
        }
        if event.type == .leftMouseUp, let (transfer, _) = pending {
            pending = nil
            transfer.controller.window?.tabGroup?.selectedWindow = transfer.controller.window
            transfer.controller.window?.makeFirstResponder(transfer.surface)
            return nil
        }
        if event.type == .leftMouseDragged, let (transfer, down) = pending {
            let delta = NSPoint(
                x: event.locationInWindow.x - down.locationInWindow.x,
                y: event.locationInWindow.y - down.locationInWindow.y
            )
            guard hypot(delta.x, delta.y) > 4 else { return nil }
            pending = nil
            begin(transfer, event: event)
            return nil
        }
        return event
    }

    private func observeNativeTabDrag(_ transfer: Transfer, event: NSEvent) {
        guard let window = transfer.controller.window, let eventWindow = event.window else { return }
        cancelled = false
        pending = nil
        nativeTabDrag = NativeTabDrag(
            transfer: transfer,
            origin: eventWindow.convertPoint(toScreen: event.locationInWindow),
            originalWindows: window.tabGroup?.windows ?? [window],
            originalFrame: window.frame
        )
        // AppKit owns the tab's tracking loop and miniature window. Sampling
        // only during that gesture adds destinations without taking its events.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateNativeTabDrag(at: NSEvent.mouseLocation)
                if NSEvent.pressedMouseButtons & 1 == 0 { self.finishNativeTabDrag() }
            }
        }
        nativeTrackingTimer?.invalidate()
        nativeTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func updateNativeTabDrag(at point: NSPoint) {
        guard var drag = nativeTabDrag else { return }
        if !drag.started {
            guard hypot(point.x - drag.origin.x, point.y - drag.origin.y) > 4 else { return }
            drag.started = true
            active = drag.transfer
        }
        drag.destination = nil
        var preview: Destination?
        for window in NSApp.orderedWindows
        where window.isVisible && !window.isMiniaturized
            && window !== drag.transfer.controller.window && window.frame.contains(point)
        {
            guard let owner = window.windowController as? TerminalWindowController else {
                // AppKit's floating drag preview is not a destination window.
                if window.canBecomeKey { break }
                continue
            }
            if owner === drag.transfer.controller { continue }
            guard window.attachedSheet == nil else { break }
            let location = window.convertPoint(fromScreen: point)
            // Native strips keep their own insertion marker and reorder rules.
            if TabStripStyling.transferTab(at: location, in: window) == nil {
                preview = destination(in: owner, at: location)
                drag.destination = preview?.acceptsDrop == true ? preview : nil
            }
            break
        }
        nativeTabDrag = drag
        if let destination = preview, !overlays.contains(where: { $0.owner === destination.controller }),
            let frameView = destination.controller.window?.contentView?.superview
        {
            addDropView(to: frameView, owner: destination.controller, native: true)
        }
        for overlay in overlays {
            overlay.show(preview?.controller === overlay.owner ? preview : nil)
        }
    }

    private static func tabTargetFrame(in pane: NSRect) -> NSRect {
        let width = min(120, pane.width * 0.3)
        return NSRect(x: pane.midX - width / 2, y: pane.midY - 16, width: width, height: 32)
    }

    private func finishNativeTabDrag() {
        nativeTrackingTimer?.invalidate()
        nativeTrackingTimer = nil
        guard let drag = nativeTabDrag else { return }
        nativeTabDrag = nil
        active = nil
        removeDropViews()
        let shouldComplete = drag.started && !cancelled
        didCompletingDragStart = drag.started
        completingNativeTransfer = drag.transfer
        // The native tracker must finish detaching/reordering its windows before
        // the backend or a pane transfer changes their ownership.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let transferred = shouldComplete && self.completeNativeTabDrag(drag)
                self.completingNativeTransfer = nil
                self.didCompletingDragStart = false
                if !transferred {
                    drag.transfer.controller.remoteWorkspaceDidChange(on: drag.transfer.surface)
                }
            }
        }
    }

    private func completeNativeTabDrag(_ drag: NativeTabDrag) -> Bool {
        let transfer = drag.transfer
        guard !transfer.controller.isWindowClosed, let window = transfer.controller.window else { return false }
        if let destination = drag.destination {
            return move(
                transfer,
                to: destination.controller,
                target: destination.surface,
                placement: destination.placement,
                insertTarget: destination.insertTarget
            )
        } else if let receiver = window.tabGroup?.windows
            .first(where: { candidate in
                candidate !== window && !drag.originalWindows.contains(where: { $0 === candidate })
            }), let owner = receiver.windowController as? TerminalWindowController, let surface = owner.activeSurface
        {
            if !move(transfer, to: owner, target: surface, placement: .tab) {
                window.tabGroup?.removeWindow(window)
                window.setFrame(drag.originalFrame, display: false)
                if let original = drag.originalWindows.first(where: { $0 !== window && !$0.isMiniaturized }) {
                    attach(window, to: original)
                }
                return false
            }
            return true
        } else if drag.originalWindows.count > 1 && (window.tabGroup?.windows.count ?? 1) == 1 {
            return extract(transfer, newWindow: true)
        }
        return false
    }

    private func installDropViews(native: Bool) {
        removeDropViews()
        for window in NSApp.windows where window.isVisible && !window.isMiniaturized {
            guard let owner = window.windowController as? TerminalWindowController,
                !owner.isWindowClosed, window.attachedSheet == nil, let frameView = window.contentView?.superview
            else { continue }
            addDropView(to: frameView, owner: owner, native: native)
        }
    }

    private func addDropView(to frameView: NSView, owner: TerminalWindowController, native: Bool) {
        let overlay = TransferDropView(frame: frameView.bounds, owner: owner, coordinator: self, native: native)
        overlay.autoresizingMask = [.width, .height]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlays.append(overlay)
    }

    private func removeDropViews() {
        overlays.forEach { $0.removeFromSuperview() }
        overlays.removeAll()
    }

    private func transfer(at event: NSEvent) -> Transfer? {
        guard let window = event.window, let controller = window.windowController as? TerminalWindowController,
            !controller.isWindowClosed, window.attachedSheet == nil
        else { return nil }
        if let tab = TabStripStyling.transferTab(at: event.locationInWindow, in: window),
            let owner = tab.windowController as? TerminalWindowController, let surface = owner.activeSurface
        {
            return Transfer(controller: owner, surface: surface, wholeTab: true)
        }
        guard let host = window.contentView else { return nil }
        func findHandle(_ view: NSView) -> Transfer? {
            if let chrome = view as? PaneChrome, let surface = chrome.contentView as? TerminalSurface,
                chrome.isTransferHandle(at: chrome.convert(event.locationInWindow, from: nil))
            {
                return Transfer(controller: controller, surface: surface, wholeTab: false)
            }
            for child in view.subviews {
                if let found = findHandle(child) { return found }
            }
            return nil
        }
        return findHandle(host)
    }

    private func begin(_ transfer: Transfer, event: NSEvent) {
        guard let host = event.window?.contentView else { return }
        active = transfer
        cancelled = false
        installDropViews(native: false)
        let item = NSPasteboardItem()
        item.setString(UUID().uuidString, forType: Self.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: NSSize(width: 220, height: 36), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let title = transfer.scope == .Tab ? "Move Tab" : "Move Pane"
            (title as NSString)
                .draw(
                    at: NSPoint(x: 14, y: 10),
                    withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)]
                )
            return true
        }
        let point = host.convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: point.x - 100, y: point.y - 18, width: 220, height: 36), contents: image)
        host.beginDraggingSession(with: [dragging], event: event, source: self)
    }

    package func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
    package func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    package func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let transfer = active
        active = nil
        removeDropViews()
        if operation.isEmpty, !cancelled, let transfer,
            !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) })
        {
            _ = extract(transfer, newWindow: true, at: screenPoint)
        }
    }

    func destination(in controller: TerminalWindowController, at point: NSPoint) -> Destination? {
        guard let active else { return nil }
        return destination(for: active, in: controller, at: point, native: nativeTabDrag != nil)
    }

    package func destination(
        for transfer: Transfer,
        in controller: TerminalWindowController,
        at point: NSPoint,
        native: Bool = false
    ) -> Destination? {
        guard !transfer.controller.isWindowClosed, !controller.isWindowClosed,
            let window = controller.window, let focused = controller.activeSurface
        else { return nil }
        if let hovered = TabStripStyling.transferTab(at: point, in: window),
            let receiver = hovered.windowController as? TerminalWindowController,
            let surface = receiver.activeSurface, transfer.surface.drive.canTransfer(to: surface.drive)
        {
            let frame = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return Destination(
                controller: receiver,
                surface: surface,
                placement: .tab,
                frame: frame,
                paneFrame: frame,
                tabFrame: frame,
                allowsSplit: false,
                allowsRootSplit: false
            )
        }
        let views = controller.projectedSurfaces.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        let target = views.first { $0.bounds.contains($0.convert(point, from: nil)) } ?? focused
        guard transfer.surface.drive.canTransfer(to: target.drive) else { return nil }
        let frame = target.convert(target.bounds, to: nil)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let allowsSplit = transfer.surface !== target && !(transfer.scope == .Tab && transfer.controller === controller)
        let tabFrame = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
        let rootTarget = views.first { $0 !== transfer.surface } ?? target
        let allowsRootSplit =
            views.count > 1 && rootTarget !== transfer.surface
            && !(transfer.scope == .Tab && transfer.controller === controller)
        if allowsRootSplit, tabFrame.contains(point) {
            let edges: [(Placement, CGFloat)] = [
                (.left, point.x - tabFrame.minX), (.right, tabFrame.maxX - point.x),
                (.above, tabFrame.maxY - point.y), (.below, point.y - tabFrame.minY),
            ]
            if let edge = edges.min(by: { $0.1 < $1.1 }), edge.1 < 28 {
                return Destination(
                    controller: controller,
                    surface: rootTarget,
                    placement: edge.0,
                    frame: Self.splitFrame(tabFrame, placement: edge.0),
                    paneFrame: frame,
                    tabFrame: tabFrame,
                    allowsSplit: allowsSplit,
                    allowsRootSplit: true,
                    insertTarget: .Root
                )
            }
        }
        var placement = Placement.tab
        var highlight = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? frame
        if frame.contains(point) {
            let distances: [(Placement, CGFloat)] = [
                (.left, (point.x - frame.minX) / frame.width), (.right, (frame.maxX - point.x) / frame.width),
                (.above, (frame.maxY - point.y) / frame.height), (.below, (point.y - frame.minY) / frame.height),
            ]
            if allowsSplit, let closest = distances.min(by: { $0.1 < $1.1 }), closest.1 < 0.3 {
                placement = closest.0
                highlight = Self.splitFrame(frame, placement: placement)
            }
        }
        return Destination(
            controller: controller,
            surface: target,
            placement: placement,
            frame: highlight,
            paneFrame: frame,
            tabFrame: tabFrame,
            allowsSplit: allowsSplit && frame.contains(point),
            allowsRootSplit: allowsRootSplit,
            // The remaining tab's body is not a tab well during native tear-off.
            acceptsDrop: !native || placement != .tab || !frame.contains(point) || Self.tabTargetFrame(in: frame).contains(point)
        )
    }

    private static func splitFrame(_ frame: NSRect, placement: Placement) -> NSRect {
        var result = frame
        switch placement {
        case .left: result.size.width /= 2
        case .right:
            result.origin.x += frame.width / 2
            result.size.width /= 2
        case .above:
            result.origin.y += frame.height / 2
            result.size.height /= 2
        case .below: result.size.height /= 2
        case .tab: break
        }
        return result
    }

    func accept(_ destination: Destination) -> Bool {
        guard let active else { return false }
        return move(
            active,
            to: destination.controller,
            target: destination.surface,
            placement: destination.placement,
            insertTarget: destination.insertTarget
        )
    }

    @discardableResult
    package func move(
        _ transfer: Transfer,
        to destination: TerminalWindowController,
        target: TerminalSurface,
        placement: Placement,
        insertTarget: Ubiquitty.Panes.InsertTarget = .Pane
    ) -> Bool {
        let source = transfer.controller
        guard !source.isWindowClosed, !destination.isWindowClosed, transfer.surface.drive.canTransfer(to: target.drive) else {
            return false
        }
        let wholeTab = transfer.scope == .Tab || source.transferTree.paneCount() == 1
        if placement != .tab && (transfer.surface === target || (wholeTab && source === destination)) { return false }
        if placement == .tab && source === destination && wholeTab { return true }
        let outcome = transfer.surface.drive.requestTransfer(
            to: target.drive,
            tree: source.transferTree,
            orientation: placement.orientation,
            side: placement.side,
            wholeTab: wholeTab,
            asTab: placement == .tab,
            insertTarget: insertTarget
        )
        switch outcome {
        case .handled:
            if placement == .tab && !wholeTab { rememberHostedPlacement(transfer, destination: destination.window, newWindow: false) }
            return true
        case .unsupported: return false
        case .localActionRequired: break
        @unknown default: return false
        }
        if placement == .tab, wholeTab, let window = source.window, let targetWindow = destination.window,
            let group = window.tabGroup, group === targetWindow.tabGroup,
            let index = group.windows.firstIndex(of: targetWindow)
        {
            group.insertWindow(window, at: index)
            group.selectedWindow = window
            source.refreshTabGroupForFocusChange()
            return true
        }
        if placement == .tab {
            let moved = wholeTab ? source : source.extractLocalPane(transfer.surface)
            guard let moved, let window = moved.window, let targetWindow = destination.window else { return false }
            attach(window, to: targetWindow)
            moved.refreshTabGroupForFocusChange()
            return true
        }
        guard let model = TerminalWindowController.windowModel,
            let pane = source.paneID(of: transfer.surface), let targetPane = destination.paneID(of: target),
            model.moveToPane(
                source.workspaceSurface,
                pane,
                targetPane,
                placement.orientation,
                placement.side,
                wholeTab ? .Tab : .Pane,
                insertTarget
            )
        else { return false }
        let moved = wholeTab ? source.surfaces : [pane: transfer.surface]
        for (identity, view) in moved {
            source.surfaces.removeValue(forKey: identity)
            destination.surfaces[identity] = view
            destination.adoptTransferredSurface(view)
        }
        if source !== destination {
            if source.surfaces.isEmpty { source.close() } else { source.rebuildPaneLayout() }
        }
        destination.rebuildPaneLayout()
        destination.window?.makeKeyAndOrderFront(nil)
        destination.window?.makeFirstResponder(transfer.surface)
        return true
    }

    @discardableResult
    package func extract(_ transfer: Transfer, newWindow: Bool, at point: NSPoint? = nil) -> Bool {
        let source = transfer.controller
        guard !source.isWindowClosed else { return false }
        let wholeTab = transfer.scope == .Tab || source.transferTree.paneCount() == 1
        let outcome = transfer.surface.drive.requestExtraction(wholeTab: wholeTab, newWindow: newWindow)
        switch outcome {
        case .handled:
            rememberHostedPlacement(transfer, destination: newWindow ? nil : source.window, newWindow: newWindow)
            return true
        case .unsupported: return false
        case .localActionRequired: break
        @unknown default: return false
        }
        let made = wholeTab ? source : source.extractLocalPane(transfer.surface)
        guard let made, let window = made.window else { return false }
        if newWindow {
            window.tabGroup?.removeWindow(window)
            if let point { window.setFrameTopLeftPoint(point) }
            window.makeKeyAndOrderFront(nil)
        } else if let original = source.window, original !== window {
            attach(window, to: original)
        }
        made.refreshTabGroupForFocusChange()
        return true
    }

    private func rememberHostedPlacement(_ transfer: Transfer, destination: NSWindow?, newWindow: Bool) {
        guard let pane = transfer.controller.tmuxSurfaces.first(where: { $0.value === transfer.surface })?.key,
            let host = transfer.controller.hostingSurface
        else { return }
        hostedPlacements.append(
            HostedPlacement(
                source: host.drive,
                pane: pane,
                destination: destination,
                placement: newWindow ? .Window : .Tab,
                expires: Date().addingTimeInterval(10)
            )
        )
    }

    func hostedLayoutDidChange(_ controller: TerminalWindowController) {
        guard let host = controller.hostingSurface, let window = controller.window else { return }
        hostedPlacements.removeAll { placement in
            if placement.expires < Date() || placement.source == nil { return true }
            guard placement.source === host.drive,
                controller.tmuxSurfaces[placement.pane] != nil, controller.tmuxSurfaces.count == 1
            else { return false }
            if placement.placement == .Window {
                window.tabGroup?.removeWindow(window)
                window.makeKeyAndOrderFront(nil)
            } else if let destination = placement.destination, destination !== window {
                attach(window, to: destination)
            }
            controller.refreshTabGroupForFocusChange()
            return true
        }
    }

    private func attach(_ window: NSWindow, to destination: NSWindow) {
        let frame = destination.frame
        // Detaching before resizing preserves the source group's frame.
        window.tabGroup?.removeWindow(window)
        window.setFrame(frame, display: false)
        destination.addTabbedWindow(window, ordered: .above)
        window.tabGroup?.selectedWindow = window
    }

    private func showMenu(for transfer: Transfer, event: NSEvent) {
        menuActions.removeAll()
        let menu = NSMenu()
        func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menuActions.count
            menuActions.append(action)
            menu.addItem(item)
        }
        add(transfer.scope == .Tab ? "Move Tab to New Window" : "Move Pane to New Window", to: menu) { [weak self] in
            _ = self?.extract(transfer, newWindow: true)
        }
        if transfer.scope == .Pane {
            add("Move Pane to New Tab", to: menu) { [weak self] in _ = self?.extract(transfer, newWindow: false) }
        }
        for controller in TerminalWindowController.spawnedControllers where !controller.isWindowClosed {
            guard let target = controller.activeSurface, let window = controller.window,
                transfer.surface.drive.canTransfer(to: target.drive), controller !== transfer.controller
            else { continue }
            let item = NSMenuItem(title: window.title.isEmpty ? "Terminal" : window.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for placement in Placement.allCases {
                add(placement.title, to: submenu) { [weak self] in
                    _ = self?.move(transfer, to: controller, target: target, placement: placement)
                }
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: transfer.controller.paneHost)
        menuActions.removeAll()
    }

    @objc
    private func runMenuAction(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        menuActions[sender.tag]()
    }
}

@MainActor
package final class TransferDropView: NSView {
    weak var owner: TerminalWindowController?
    let coordinator: PaneTransferCoordinator
    private var destination: PaneTransferCoordinator.Destination?
    private let isNativeDrag: Bool

    package init(frame: NSRect, owner: TerminalWindowController, coordinator: PaneTransferCoordinator, native: Bool) {
        self.owner = owner
        self.coordinator = coordinator
        self.isNativeDrag = native
        super.init(frame: frame)
        setAccessibilityIdentifier("pane.transfer.dropTargets")
        if !native { registerForDraggedTypes([PaneTransferCoordinator.pasteboardType]) }
    }
    package required init?(coder: NSCoder) { fatalError("TransferDropView is built in code") }

    package override func hitTest(_ point: NSPoint) -> NSView? { isNativeDrag ? nil : super.hitTest(point) }

    package func show(_ destination: PaneTransferCoordinator.Destination?) {
        self.destination = destination
        needsDisplay = true
    }

    package override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    package override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? PaneTransferCoordinator === coordinator, let owner else { return [] }
        show(coordinator.destination(in: owner, at: sender.draggingLocation))
        return destination == nil ? [] : .move
    }
    package override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        show(nil)
    }
    package override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { destination != nil }
    package override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let destination else { return false }
        return coordinator.accept(destination)
    }
    package override func draw(_ dirtyRect: NSRect) {
        guard let destination else { return }
        let rectangle = convert(destination.frame, from: nil).insetBy(dx: 4, dy: 4)
        if destination.acceptsDrop {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: 10, yRadius: 10).fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: rectangle, xRadius: 10, yRadius: 10)
            border.lineWidth = 2
            border.stroke()
        }
        let pane = convert(destination.paneFrame, from: nil)
        let tab = convert(destination.tabFrame, from: nil)
        if destination.allowsSplit {
            for placement in PaneTransferCoordinator.Placement.allCases {
                let center: NSPoint
                switch placement {
                case .left: center = NSPoint(x: pane.minX + pane.width * 0.16, y: pane.midY)
                case .right: center = NSPoint(x: pane.maxX - pane.width * 0.16, y: pane.midY)
                case .above: center = NSPoint(x: pane.midX, y: pane.maxY - pane.height * 0.16)
                case .below: center = NSPoint(x: pane.midX, y: pane.minY + pane.height * 0.16)
                case .tab: center = NSPoint(x: pane.midX, y: pane.midY)
                }
                drawGuide(
                    placement.title,
                    at: center,
                    selected: destination.acceptsDrop && destination.insertTarget == .Pane && destination.placement == placement,
                    maxWidth: pane.width * 0.3,
                    minWidth: placement == .tab ? 120 : 0
                )
            }
        } else {
            drawGuide(destination.title, at: NSPoint(x: rectangle.midX, y: rectangle.midY), selected: true)
        }
        if destination.allowsRootSplit {
            let edgeWidth: CGFloat = 28
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: NSRect(x: tab.minX, y: tab.minY, width: tab.width, height: edgeWidth)).fill()
            NSBezierPath(rect: NSRect(x: tab.minX, y: tab.maxY - edgeWidth, width: tab.width, height: edgeWidth)).fill()
            NSBezierPath(rect: NSRect(x: tab.minX, y: tab.minY + edgeWidth, width: edgeWidth, height: max(0, tab.height - 2 * edgeWidth)))
                .fill()
            NSBezierPath(
                rect: NSRect(x: tab.maxX - edgeWidth, y: tab.minY + edgeWidth, width: edgeWidth, height: max(0, tab.height - 2 * edgeWidth))
            )
            .fill()
            for placement in PaneTransferCoordinator.Placement.allCases where placement != .tab {
                let center: NSPoint
                let title: String
                switch placement {
                case .left:
                    center = NSPoint(x: tab.minX + edgeWidth / 2, y: tab.midY)
                    title = "←"
                case .right:
                    center = NSPoint(x: tab.maxX - edgeWidth / 2, y: tab.midY)
                    title = "→"
                case .above:
                    center = NSPoint(x: tab.midX, y: tab.maxY - edgeWidth / 2)
                    title = "↑ Split Tab Above"
                case .below:
                    center = NSPoint(x: tab.midX, y: tab.minY + edgeWidth / 2)
                    title = "↓ Split Tab Below"
                case .tab: continue
                }
                drawGuide(title, at: center, selected: destination.insertTarget == .Root && destination.placement == placement)
            }
        }
    }

    private func drawGuide(_ text: String, at center: NSPoint, selected: Bool, maxWidth: CGFloat = 200, minWidth: CGFloat = 0) {
        let title = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        let width = min(max(size.width + 16, minWidth), maxWidth)
        let rectangle = NSRect(x: center.x - width / 2, y: center.y - 12, width: width, height: 24)
        (selected ? NSColor.controlAccentColor : NSColor.windowBackgroundColor.withAlphaComponent(0.96)).setFill()
        NSBezierPath(roundedRect: rectangle, xRadius: 6, yRadius: 6).fill()
        title.draw(
            with: rectangle.insetBy(dx: 8, dy: 4),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }
}
