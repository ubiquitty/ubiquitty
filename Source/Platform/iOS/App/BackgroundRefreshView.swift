// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Displays cached host facts without creating a renderer or claiming a live pane.
struct BackgroundRefreshView: View {
    let record: HostRecord
    let openHost: () -> Void
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var refresh = BackgroundRefreshCoordinator.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let date = refresh.summaries[record.id]?.refreshedAt {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Not checked yet")
                    }
                    if let failure = refresh.summaries[record.id]?.failure { Text(failure).foregroundStyle(.secondary) }
                    if refresh.summaries[record.id]?.hadRetentionGap == true {
                        Text("Some older events are no longer available.").foregroundStyle(.secondary)
                    }
                    Button("Refresh Now") { refresh.refreshInForeground() }
                    Button("Open Host", action: openHost)
                } footer: {
                    Text("Saved status can be out of date. Open the host to see it live.")
                }
                ForEach(refresh.summaries[record.id]?.panes ?? []) { pane in
                    Section(pane.title.isEmpty ? "Session \(pane.sessionID)" : pane.title) {
                        if !pane.status.isEmpty { Text(pane.status) }
                        if !pane.screen.isEmpty {
                            Text(pane.screen).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(record.displayName)
            .sheetChrome()
            .toolbar { SheetToolbar.close { dismiss() } }
        }
    }
}
