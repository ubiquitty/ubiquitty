// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostOutlineStore.swift — the rows of one host's outline as a view reads
// them, and the reader's half of what decides them.
//
// Core decides every row (`App::buildSessionOutline`): its order, what folds
// into it, what it is called, its status and each mark's ink, its words and
// its ages. What a frontend holds is small and is all here: which rows the
// person closed, what the person is searching for, and when to read the rows
// again. Nothing in this file composes, ranks, sorts or words a row.
//
// A store reads from a source, so the same store draws a host the Mac asks
// through its directory client, a host a phone is attached to, and rows a
// scenario stands up without a host.
//

import Foundation
import Observation
import SwiftUI
import UbiquittyRenderKit

/// How current the tree behind an outline is, numbered as Core's
/// `Runtime::HostDirectoryClient::TreeFreshness`.
enum HostOutlineFreshness: UInt8, Sendable {
    /// There is no tree.
    case none = 0
    /// The tree is what a listing answered; nothing follows it.
    case listed = 1
    /// A watch that is connected keeps the tree current.
    case live = 2
    /// A watch kept the tree current and has lost its host.
    case stale = 3
}

/// Where an outline's rows come from.
@MainActor
protocol HostOutlineSource: AnyObject {
    /// Core's rows for a reader, over the newest tree the source holds.
    ///
    /// - Parameter reader: Which rows are closed, what is searched for and
    ///   which marks the platform colours itself.
    /// - Returns: The rows; none before any tree.
    func outline(for reader: HostOutlineReader) -> HostOutline

    /// How current the tree is.
    var freshness: HostOutlineFreshness { get }

    /// Core's sentence for why the tree is not being followed; empty while it
    /// is.
    var watchError: String { get }
}

/// What names a row across refreshes, so a list keeps a row in place while
/// its facts change under it.
enum HostOutlineRowKey: Hashable, Sendable {
    /// A row with an identity of its own.
    case identity(HostOutlineIdentity)
    /// A window's or a tab's row in a workspace nothing runs in, by its
    /// place in that workspace's record.
    case recorded(HostOutlineRecordedKey)
    /// A row with neither, by where it stands in the tree.
    case place(level: HostOutlineLevel, workspace: Int, window: Int, tab: Int, pane: Int)
}

extension HostOutlineRow {
    /// What names the row across refreshes.
    var key: HostOutlineRowKey {
        if let id {
            return .identity(id)
        }
        if let recordedKey {
            return .recorded(recordedKey)
        }
        return .place(level: level, workspace: pathWorkspace, window: pathWindow, tab: pathTab, pane: pathPane)
    }
}

/// The rows a view draws for one host, and the person's closed rows and
/// search behind them.
@MainActor
@Observable
final class HostOutlineStore {
    /// Core's rows, in the order they are drawn.
    private(set) var rows: [HostOutlineRow] = []

    /// How many rows match the search; zero without one.
    private(set) var matchCount = 0

    /// The tree revision the rows describe.
    private(set) var revision: UInt64 = 0

    /// How current the tree behind the rows is.
    private(set) var freshness = HostOutlineFreshness.none

    /// Core's sentence for why the tree is not being followed.
    private(set) var watchError = ""

    /// What the person is searching for; the rows follow it.
    var query: String {
        get { reader.query }
        set {
            guard reader.query != newValue else { return }
            reader.query = newValue
            reload()
        }
    }

    /// Whether the rows are a search's, as Core read the query. Core opens
    /// the way to every match whatever is closed, so a fold has nothing to
    /// act on meanwhile.
    private(set) var isSearching = false

    /// The reader's half of the outline: closed rows, search and the marks
    /// the platform colours itself.
    @ObservationIgnored
    private var reader: HostOutlineReader

    @ObservationIgnored
    private weak var source: (any HostOutlineSource)?

    @ObservationIgnored
    private var ageRefresh: Task<Void, Never>?

    /// How often the rows are read again so their ages stay current. The
    /// tree is not asked for again: Core measures each age against the host's
    /// clock as it has kept it running.
    private static let ageRefreshSeconds: Double = 10

    /// Makes a store for a platform.
    ///
    /// - Parameters:
    ///   - platformMarks: The status marks the platform has a colour of its
    ///     own for.
    ///   - density: How much room the reader gives a row; a compact reader's
    ///     workspaces start closed, each row carrying what it hides.
    init(platformMarks: HostOutlinePlatformMarks, density: HostOutlineDensity = .regular) {
        var reader = HostOutlineReader()
        reader.platformMarks = platformMarks
        reader.density = density
        self.reader = reader
    }

    /// Points the store at a source, keeping the search and dropping the
    /// closed rows of the source before it.
    ///
    /// - Parameters:
    ///   - source: Where the rows come from, nil for nowhere.
    ///   - closed: The rows the person closed on this source before.
    func setSource(_ source: (any HostOutlineSource)?, closed: HostOutlineClosedRows = HostOutlineClosedRows()) {
        self.source = source
        reader.collapsed = closed.identities
        reader.collapsedRecordedRows = closed.recorded
        reload()
    }

    /// Sets what names a row whose title has no part to draw: the host, as
    /// the window showing it calls it.
    ///
    /// - Parameter name: The name.
    func setFallbackName(_ name: String) {
        guard reader.fallbackName != name else { return }
        reader.fallbackName = name
        reload()
    }

    /// States what Core compares rows with: what the reader calls the host
    /// listed, what its own window shows, and what this app has open.
    ///
    /// - Parameters:
    ///   - host: The listed host as the reader names hosts; empty for this
    ///     machine.
    ///   - here: What the reader's own window shows, nil for a reader with no
    ///     window of its own.
    ///   - alreadyOpen: What this app has open, on every host.
    func setPlace(host: String, here: HostOutlineWindowPlace?, alreadyOpen: [HostOutlineOpenWorkspace]) {
        guard reader.host != host || reader.here != here || reader.alreadyOpen != alreadyOpen else { return }
        reader.host = host
        reader.here = here
        reader.alreadyOpen = alreadyOpen
        reload()
    }

    /// The rows the person has closed, for a caller that keeps them while the
    /// store is pointed elsewhere.
    var closedRows: HostOutlineClosedRows {
        HostOutlineClosedRows(identities: reader.collapsed, recorded: reader.collapsedRecordedRows)
    }

    /// Reads the rows again from the source.
    func reload() {
        guard let source else {
            rows = []
            matchCount = 0
            revision = 0
            isSearching = false
            freshness = .none
            watchError = ""
            return
        }
        let outline = source.outline(for: reader)
        // Without animation: rows that change under a reader are a status
        // moving or a search narrowing, and neither is a reason for a list to
        // slide its rows about, nor for it to measure them twice on the way.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rows = outline.rows
            matchCount = outline.matchCount
            revision = outline.revision
            isSearching = outline.isSearching
            freshness = source.freshness
            watchError = source.watchError
        }
    }

    /// Opens a closed row or closes an open one.
    ///
    /// - Parameter row: The row; one with nothing under it is left alone.
    func toggle(_ row: HostOutlineRow) {
        setExpanded(!row.isExpanded, row)
    }

    /// Opens or closes a row.
    ///
    /// - Parameters:
    ///   - isExpanded: Whether the rows under it are to be shown.
    ///   - row: The row; one with nothing under it is left alone.
    func setExpanded(_ isExpanded: Bool, _ row: HostOutlineRow) {
        guard row.isExpandable, !isSearching else { return }
        if let id = row.id {
            // Through the reader's own doors: Core's request keeps what the
            // person opened by hand apart from what starts open.
            if isExpanded {
                reader.open(id)
            } else {
                reader.close(id)
            }
        } else if let key = row.recordedKey {
            if isExpanded {
                reader.collapsedRecordedRows.remove(key)
            } else {
                reader.collapsedRecordedRows.insert(key)
            }
        } else {
            return
        }
        reload()
    }

    /// The row a key names among the rows drawn now.
    ///
    /// - Parameter key: The key.
    /// - Returns: The row, nil when it is not drawn.
    func row(for key: HostOutlineRowKey?) -> HostOutlineRow? {
        guard let key else { return nil }
        return rows.first { $0.key == key }
    }

    /// Keeps the ages current while a view shows the rows.
    func startRefreshingAges() {
        guard ageRefresh == nil else { return }
        ageRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.ageRefreshSeconds))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    /// Stops reading the rows again once no view shows them.
    func stopRefreshingAges() {
        ageRefresh?.cancel()
        ageRefresh = nil
    }
}

/// The rows a person closed on one host.
struct HostOutlineClosedRows: Equatable, Sendable {
    /// The closed rows that have an identity.
    var identities: Set<HostOutlineIdentity> = []
    /// The closed rows of a workspace nothing runs in, by their place in its
    /// record.
    var recorded: Set<HostOutlineRecordedKey> = []
}
