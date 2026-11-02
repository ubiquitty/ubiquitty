// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreTransferable
import Observation
import SwiftUI
import UIKit
import UbiquittyKit
import UniformTypeIdentifiers

import enum UbiquittyRenderKit.HostWords

/// The workspace's tabs as cards of live pictures, in Safari's manner.
///
/// Each card draws its tab's split layout in miniature, every pane a picture
/// of the frame it shows, named as Core names it. A tap on a pane focuses it
/// and closes the overview. A new tab opens as soon as the host confirms its
/// pane. Every change is asked of the host, and what it refuses is drawn on
/// the card it was about.
struct TerminalTabOverview: View {
    let session: TerminalSessionModel
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.displayScale)
    private var displayScale
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State
    private var thumbnails = TerminalThumbnails()
    @State
    private var renaming: TerminalTab?
    @State
    private var proposedName = ""
    @State
    private var focusedFeedback = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(tabCount)
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbar }
                .alert("Rename Tab", item: $renaming) { tab in
                    TextField("Tab Name", text: $proposedName)
                        .accessibilityIdentifier("tab-rename-field")
                    Button(role: .cancel) {}
                    Button("Rename") { session.renameTab(tab.id, to: proposedName) }
                } message: { _ in
                    Text("Leave the name empty to name the tab after what runs in it.")
                }
        }
        .sensoryFeedback(.selection, trigger: focusedFeedback)
        .task {
            // The pictures follow the panes while the overview is up, at a pace
            // that costs the device little: one frame per pane every two seconds, and a
            // picture that did not change is not drawn again.
            while !Task.isCancelled {
                session.refreshTabTitles()
                thumbnails.refresh(session: session, maxPixelWidth: Int(220 * displayScale), scale: displayScale)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var tabCount: String {
        session.tabs.count == 1 ? "1 Tab" : "\(session.tabs.count) Tabs"
    }

    @ViewBuilder
    private var content: some View {
        if session.tabs.isEmpty {
            ContentUnavailableView {
                Label(session.supportsWorkspace ? "No Tabs" : "Tabs Unavailable", systemImage: InterfaceSymbol.tabs)
            } description: {
                Text(
                    session.supportsWorkspace
                        ? "This workspace has no tabs yet."
                        : "Connect to a Ubiquitty host to open tabs and panes."
                )
            } actions: {
                if session.supportsWorkspace {
                    Button("New Tab") { session.addTab() }
                        .disabled(!session.canChangeTabs)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 16)], spacing: 20) {
                    ReorderableTabs(session: session) { position, tab in
                        TerminalTabCard(
                            session: session,
                            tab: tab,
                            position: position,
                            count: session.tabs.count,
                            thumbnails: thumbnails,
                            onFocus: { pane in
                                session.selectPane(pane)
                                focusedFeedback += 1
                                dismiss()
                            },
                            onRename: {
                                proposedName = tab.customTitle
                                renaming = tab
                            }
                        )
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
                .modifier(TabReorderContainer(session: session))
                .padding()
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35), value: session.tabs.map(\.id))
                if !session.workspaceMessage.isEmpty {
                    Label(session.workspaceMessage, systemImage: session.isChangingPanes ? "hourglass" : InterfaceSymbol.error)
                        .font(.footnote)
                        .foregroundStyle(session.isChangingPanes ? Color.secondary : Color.red)
                        .padding(.horizontal)
                        .accessibilityIdentifier("workspace-operation-status")
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("New Tab", systemImage: "plus") { session.addTab() }
                .disabled(!session.canChangeTabs || !session.supportsWorkspace)
                .accessibilityIdentifier("tab-overview-new-tab")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(role: .close) { dismiss() }
                .accessibilityIdentifier("tab-overview-done")
        }
    }
}

/// One tab's card: its panes in miniature, its name and its close button.
private struct TerminalTabCard: View {
    let session: TerminalSessionModel
    let tab: TerminalTab
    let position: Int
    let count: Int
    let thumbnails: TerminalThumbnails
    let onFocus: (UInt32) -> Void
    let onRename: () -> Void
    @State
    private var isConfirmingClose = false
    @State
    private var paneToClose: UInt32?
    @ScaledMetric(relativeTo: .caption2)
    private var labelInset = 4.0

    private var isActive: Bool { tab.id == session.activeTab?.id }
    private var isPending: Bool { session.pendingTabIDs.contains(tab.id) }

    /// What VoiceOver reads for the card: its place, its name, its panes and
    /// whether it is the one in use.
    private var accessibilityDescription: String {
        var parts = ["Tab \(position + 1) of \(count)", tab.title]
        parts.append(tab.panes.count == 1 ? "1 pane" : "\(tab.panes.count) panes")
        if isActive { parts.append("focused") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            miniature
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { onFocus(tab.focusedPaneID) }
                .accessibilityAction(named: "Close Tab") { isConfirmingClose = true }
                .accessibilityAction(named: "Rename Tab") { onRename() }
                .accessibilityActions {
                    if session.canChangeTabs {
                        if session.canMoveTab(tab.id, by: -1) {
                            Button(HostWords.text(.moveTabEarlier)) { session.moveTab(tab.id, by: -1) }
                        }
                        if session.canMoveTab(tab.id, by: 1) {
                            Button(HostWords.text(.moveTabLater)) { session.moveTab(tab.id, by: 1) }
                        }
                    }
                    if tab.panes.count > 1 {
                        ForEach(tab.panes) { pane in
                            Button("Show \(tab.paneTitles[pane.id] ?? "Pane")") { onFocus(pane.id) }
                        }
                    }
                }
                .accessibilityIdentifier("tab-card-\(tab.id)")
            header
            if let problem = session.tabProblems[tab.id] {
                Label(problem, systemImage: InterfaceSymbol.error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .accessibilityIdentifier("tab-problem-\(tab.id)")
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu { tabMenu }
        .confirmationDialog(closeQuestion.title, isPresented: closingBinding, titleVisibility: .visible) {
            Button(TerminalSessionModel.closeVerb, role: .destructive) {
                if let paneToClose {
                    session.closeTabPane(paneToClose)
                } else {
                    session.closeTab(tab.id)
                }
                paneToClose = nil
            }
            Button(role: .cancel) { paneToClose = nil }
        } message: {
            if !closeQuestion.body.isEmpty { Text(closeQuestion.body) }
        }
    }

    private var closingBinding: Binding<Bool> {
        Binding(
            get: { isConfirmingClose || paneToClose != nil },
            set: {
                if !$0 {
                    isConfirmingClose = false
                    paneToClose = nil
                }
            }
        )
    }

    private var closeQuestion: (title: String, body: String) {
        if let paneToClose {
            return TerminalSessionModel.closeQuestion(.pane, programs: tab.runningPrograms[paneToClose].map { [$0] } ?? [])
        }
        return TerminalSessionModel.closeQuestion(.tab, programs: tab.panes.compactMap { tab.runningPrograms[$0.id] })
    }

    /// The tab's panes where its split tree puts them, each a live picture.
    private var miniature: some View {
        GeometryReader { space in
            ZStack(alignment: .topLeading) {
                ForEach(tab.panes) { pane in
                    let frame = CGRect(
                        x: pane.frame.minX * space.size.width,
                        y: pane.frame.minY * space.size.height,
                        width: pane.frame.width * space.size.width,
                        height: pane.frame.height * space.size.height
                    )
                    paneTile(pane)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .overlay(alignment: .trailing) {
                            if pane.frame.maxX < 1 {
                                (session.isGroundDark ? Color.white : Color.black).opacity(0.16)
                                    .frame(width: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if pane.frame.maxY < 1 {
                                (session.isGroundDark ? Color.white : Color.black).opacity(0.16)
                                    .frame(height: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .background(Color(uiColor: session.groundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay {
            if isPending {
                ProgressView()
                    .controlSize(.large)
                    .padding(12)
                    .glassEffect(.regular, in: Circle())
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// A pane's picture; among several panes it has a menu of its own, which
    /// carries the tab's verbs too, since a long press on it is a long press
    /// on the card.
    @ViewBuilder
    private func paneTile(_ pane: TerminalTabPane) -> some View {
        if tab.panes.count > 1 {
            paneButton(pane)
                .contextMenu {
                    paneMenu(pane)
                    Divider()
                    tabMenu
                }
        } else {
            paneButton(pane)
        }
    }

    private func paneButton(_ pane: TerminalTabPane) -> some View {
        let isFocusedPane = isActive && tab.panes.count > 1 && pane.id == tab.focusedPaneID
        return Button {
            onFocus(pane.id)
        } label: {
            GeometryReader { tile in
                ZStack(alignment: .topLeading) {
                    Color(uiColor: session.groundColor)
                    // The pane's frame at the tile's width, from its top: the
                    // rows a person reads first, as Safari shows a page's top.
                    if let image = thumbnails.images[pane.id] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(
                                width: tile.size.width,
                                height: tile.size.width * CGFloat(image.height) / CGFloat(max(image.width, 1))
                            )
                    }
                }
                .frame(width: tile.size.width, height: tile.size.height, alignment: .topLeading)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if tab.panes.count > 1 {
                        Text(tab.paneTitles[pane.id] ?? "")
                            .font(.caption2)
                            .lineLimit(1)
                            // The program ends the name, and it is the part
                            // that tells two panes in one directory apart.
                            .truncationMode(.head)
                            .padding(.horizontal, labelInset + 2)
                            .padding(.vertical, labelInset / 2)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: max(tile.size.width - 2 * labelInset, 0), alignment: .leading)
                            .padding(labelInset)
                    }
                }
            }
            .overlay {
                Rectangle().strokeBorder(Color.accentColor.opacity(isFocusedPane ? 1 : 0), lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tab.title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Button {
                isConfirmingClose = true
            } label: {
                Label("Close Tab", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!session.canChangeTabs)
            .accessibilityIdentifier("tab-card-close-\(tab.id)")
        }
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button(HostWords.text(.renameTab), systemImage: "pencil") { onRename() }
        Button("New Tab", systemImage: "plus") { session.addTab() }
            .disabled(!session.canChangePanes)
        Button("Split Right", systemImage: InterfaceSymbol.splitRight) { session.split(pane: tab.focusedPaneID, .splitBeside) }
            .disabled(!session.canChangePanes)
        Button("Split Down", systemImage: InterfaceSymbol.splitDown) { session.split(pane: tab.focusedPaneID, .splitBelow) }
            .disabled(!session.canChangePanes)
        Divider()
        Button("Close Tab", systemImage: "xmark", role: .destructive) { isConfirmingClose = true }
            .disabled(!session.canChangeTabs)
    }

    @ViewBuilder
    private func paneMenu(_ pane: TerminalTabPane) -> some View {
        Button(tab.zoomedPaneID == pane.id ? "Unzoom Pane" : "Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
            session.zoomPane(pane.id)
        }
        .disabled(!session.canChangePanes)
        Button("Move to New Tab", systemImage: InterfaceSymbol.tabs) { session.movePaneToNewTab(pane.id) }
            .disabled(!session.canChangePanes || tab.panes.count < 2)
        Divider()
        Button("Close Pane", systemImage: "xmark", role: .destructive) { paneToClose = pane.id }
            .disabled(!session.canChangeTabs)
    }
}

/// The pictures of the panes, made from each pane's own frame.
@Observable
@MainActor
final class TerminalThumbnails {
    private(set) var images: [UInt32: CGImage] = [:]

    /// Draws every pane of every tab again, and forgets panes that are gone.
    ///
    /// - Parameters:
    ///   - session: The workspace.
    ///   - maxPixelWidth: The widest a picture is drawn.
    ///   - scale: The screen's scale.
    func refresh(session: TerminalSessionModel, maxPixelWidth: Int, scale: Double) {
        var drawn: [UInt32: CGImage] = [:]
        for tab in session.tabs {
            for pane in tab.panes {
                guard let view = session.surface(forPane: pane.id) else { continue }
                let width = max(64, Int(Double(maxPixelWidth) * pane.frame.width))
                let previous = images[pane.id]
                guard let fresh = view.thumbnail(maxPixelWidth: width, contentScale: scale) else {
                    drawn[pane.id] = previous
                    continue
                }
                // The same picture again is kept as it was, so a pane that
                // printed nothing redraws nothing on the card.
                drawn[pane.id] = previous.map { Self.isSamePicture($0, fresh) } == true ? previous : fresh
            }
        }
        if drawn.keys != images.keys || drawn.contains(where: { images[$0.key] !== $0.value }) {
            images = drawn
        }
    }

    private static func isSamePicture(_ first: CGImage, _ second: CGImage) -> Bool {
        guard first.width == second.width, first.height == second.height,
            let firstBytes = first.dataProvider?.data, let secondBytes = second.dataProvider?.data
        else { return false }
        return CFEqual(firstBytes, secondBytes)
    }
}

/// The tabs as a strip under the bar, in Safari's iPad manner: a wide window
/// has the room, and switching is one tap rather than a visit to the overview.
struct TerminalTabStrip: View {
    let session: TerminalSessionModel
    @State
    private var renaming: TerminalTab?
    @State
    private var proposedName = ""
    @State
    private var closing: TerminalTab?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                // One container, so the selection's glass moves between tabs
                // rather than fading out of one capsule and into another.
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ReorderableTabs(session: session) { _, tab in
                            tabButton(tab)
                        }
                    }
                    .modifier(TabReorderContainer(session: session))
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            Button {
                session.addTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .disabled(!session.canChangeTabs || !session.supportsWorkspace)
            .accessibilityIdentifier("tab-strip-new-tab")
            .padding(.trailing, 8)
        }
        .padding(.vertical, 4)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: session.activeTab?.id)
        .alert("Rename Tab", item: $renaming) { tab in
            TextField("Tab Name", text: $proposedName)
            Button(role: .cancel) {}
            Button("Rename") { session.renameTab(tab.id, to: proposedName) }
        } message: { _ in
            Text("Leave the name empty to name the tab after what runs in it.")
        }
        .confirmationDialog(
            TerminalSessionModel.closeQuestion(.tab, programs: []).title,
            item: $closing,
            titleVisibility: .visible
        ) { tab in
            Button(TerminalSessionModel.closeVerb, role: .destructive) { session.closeTab(tab.id) }
            Button(role: .cancel) {}
        } message: { tab in
            let body = TerminalSessionModel.closeQuestion(.tab, programs: tab.panes.compactMap { tab.runningPrograms[$0.id] }).body
            if !body.isEmpty { Text(body) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func tabButton(_ tab: TerminalTab) -> some View {
        let isActive = tab.id == session.activeTab?.id
        return HStack(spacing: 4) {
            Button {
                session.selectTab(tab.id)
            } label: {
                Text(tab.title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(minWidth: 60, maxWidth: 200)
            }
            .buttonStyle(.plain)
            if isActive {
                Button {
                    closing = tab
                } label: {
                    Label("Close Tab", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!session.canChangeTabs)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(isActive ? .regular.interactive() : .identity, in: Capsule())
        .overlay { if session.tabProblems[tab.id] != nil { Capsule().strokeBorder(.red, lineWidth: 1) } }
        .hoverEffect(.highlight)
        .contextMenu {
            Button(HostWords.text(.renameTab), systemImage: "pencil") {
                proposedName = tab.customTitle
                renaming = tab
            }
            Button("Close Tab", systemImage: "xmark", role: .destructive) { closing = tab }
                .disabled(!session.canChangeTabs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("tab-strip-tab-\(tab.id)")
    }
}

/// The tabs in the host's order, each drawn by `content` with its position,
/// and draggable into another place where the system offers reordering.
private struct ReorderableTabs<Content: View>: View {
    let session: TerminalSessionModel
    @ViewBuilder
    let content: (Int, TerminalTab) -> Content
    @State
    private var dragScope = UUID()

    var body: some View {
        let tabs = ForEach(session.tabs) { tab in
            content(session.tabs.firstIndex { $0.id == tab.id } ?? 0, tab)
        }
        if #available(iOS 27.0, *) {
            tabs.reorderable()
        } else {
            ForEach(session.tabs) { tab in
                let card = content(session.tabs.firstIndex { $0.id == tab.id } ?? 0, tab)
                if session.canChangeTabs {
                    card
                        .draggable(TabReorderItem(scope: dragScope, tabID: tab.id))
                        .dropDestination(for: TabReorderItem.self, isEnabled: session.canChangeTabs) { items, _ in
                            guard items.count == 1, let item = items.first, item.scope == dragScope else { return }
                            session.moveTab(item.tabID, toPlaceOf: tab.id)
                        }
                } else {
                    card
                }
            }
        }
    }
}

/// iOS 26 drags stay within this process and their originating tab container.
/// The host remains responsible for admitting the resulting order request.
private struct TabReorderItem: Codable, Transferable {
    let scope: UUID
    let tabID: UInt32

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "org.ubiquitty.tab-reorder"))
            .visibility(.ownProcess)
    }
}

/// Turns a drag that moves a tab into the host's tab-order request; the
/// order on screen changes when the host's structure says so.
private struct TabReorderContainer: ViewModifier {
    let session: TerminalSessionModel

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.reorderContainer(for: TerminalTab.self, isEnabled: session.canChangeTabs) { difference in
                guard let moved = difference.sources.first else { return }
                switch difference.destination.position {
                case .before(let next): session.moveTab(moved, before: next)
                case .end: session.moveTab(moved, before: nil)
                }
            }
        } else {
            content
        }
    }
}
