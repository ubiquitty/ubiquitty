// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// FileDropTestSupport.swift — a drag the suite can hand to a surface.
//
// AppKit builds NSDraggingInfo from a real drag session, which a headless run
// has no way to start. Everything the drop path reads is the pasteboard, so
// this carries one and answers the rest with the values a drag over a view
// would have had.

import AppKit

final class FileDropStub: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let location: NSPoint

    init(pasteboard: NSPasteboard, location: NSPoint = .zero) {
        self.pasteboard = pasteboard
        self.location = location
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination: Bool { // bool-ok: NSDraggingInfo names this requirement
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { pasteboard.pasteboardItems?.count ?? 0 }
        set { _ = newValue }
    }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
