// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TerminalSurface+FileDrop.swift — files dropped on the grid become arguments.
//
// Dragging a file onto a terminal means "I want to type this path", and typing
// a path by hand is where the escaping goes wrong: a space, a bracket or a
// quotation mark in a folder name splits into arguments nobody meant. The paths
// arrive escaped, so what lands is what the shell will read.

#if canImport(AppKit)
import AppKit
internal import UbiquittyCore

extension TerminalSurface {
    /// The pasteboard types a drop on the grid is accepted for.
    ///
    /// File URLs only. Everything else a drag can carry has a meaning here that
    /// this cannot guess — text is already a paste, and a colour or an image is
    /// not something a prompt can be handed.
    package static let fileDropTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// Whether a drag carries at least one file to insert.
    ///
    /// - Parameter info: The drag in flight.
    /// - Returns: Copy when there is something to insert, else none.
    package func fileDropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options) else {
            return []
        }
        return .copy
    }

    /// Inserts the dropped files' paths at the prompt.
    ///
    /// The escaping and the joining are Core's — `Input::shellEscapedDropText`,
    /// which every frontend inserts through, so a
    /// path with a space in it lands the same way whichever window it was
    /// dropped on.
    ///
    /// - Parameter info: The drag being dropped.
    /// - Returns: Whether anything was inserted.
    package func performFileDrop(_ info: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
                as? [URL], !urls.isEmpty
        else {
            return false
        }
        var paths = Ubiquitty.Input.DroppedPaths()
        for url in urls where !url.path.isEmpty {
            paths.push_back(std.string(url.path))
        }
        let text = String(Ubiquitty.Input.shellEscapedDropText(paths))
        guard !text.isEmpty else { return false }
        send(text)
        return true
    }
}

extension TerminalSurface {
    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDrop.acceptsDrops ? dragDrop.entered(sender) : fileDropOperation(for: sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDrop.acceptsDrops ? dragDrop.updated(sender) : fileDropOperation(for: sender)
    }

    override public func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !(dragDrop.acceptsDrops ? dragDrop.updated(sender) : fileDropOperation(for: sender)).isEmpty
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragDrop.acceptsDrops ? dragDrop.perform(sender) : performFileDrop(sender)
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if dragDrop.acceptsDrops { dragDrop.left() }
    }

    override public func wantsPeriodicDraggingUpdates() -> Bool { dragDrop.acceptsDrops }
}
#endif
