// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@objc(UBPasteBuffersWindowController)
public final class PasteBuffersWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    private let model = PasteBuffersModel()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("PasteBuffersSearch"))
    @objc
    public init() {
        let hosting = NSHostingController(rootView: PasteBuffersView(model: model))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Paste Buffers"
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isExcludedFromWindowsMenu = true
        panel.backgroundColor = .windowBackgroundColor
        panel.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "PasteBuffers")
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.setContentSize(NSSize(width: 480, height: 400))
        panel.center()
        panel.setFrameAutosaveName("UBPasteBuffersPanel")
        super.init(window: panel)
        searchItem.searchField.placeholderString = "Search buffers"
        searchItem.searchField.delegate = self
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.setAccessibilityLabel("Search paste buffers")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.insertItem(withItemIdentifier: searchItem.itemIdentifier, at: 0)
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [searchItem.itemIdentifier]
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [searchItem.itemIdentifier]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        identifier == searchItem.itemIdentifier ? searchItem : nil
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.query = searchItem.searchField.stringValue
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
