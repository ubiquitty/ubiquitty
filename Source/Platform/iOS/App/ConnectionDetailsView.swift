// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyKit

/// What became of the last connection attempt, for a person working out what
/// to do about it.
///
/// It opens on the answer: what happened and what to do, in the words the
/// failure's typed fact was given. Below it, the steps the attempt took, each
/// in a sentence with how long it had been, so "the host was reached and then
/// refused the password" reads differently from "the host was never reached".
/// The raw log, which is what a developer wants and nobody else does, is
/// folded away at the bottom, and Share Diagnostics hands all of it on.
struct ConnectionDetailsView: View {
    let session: TerminalSessionModel
    let presentation: TerminalConnectionPresentation
    /// The host as the list names it, for the shared report's heading.
    let hostLabel: String
    let onDone: () -> Void
    var onThemeChosen: ((String) -> Void)?

    @Environment(\.systemColorScheme)
    private var systemColorScheme
    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionDetailsHeader(session: session, presentation: presentation)
                        // On the sheet's ground, as a header rather than a row.
                        .listRowBackground(Color.clear)
                }
                Section("Connection") {
                    if !session.sessionSummary.isEmpty { LabeledContent("Session", value: session.sessionSummary) }
                    LabeledContent("Protocol", value: session.transport.rawValue)
                    LabeledContent(
                        "Attached",
                        value: session.otherAttendeeCount == 0
                            ? "Only you"
                            : "You and \(session.otherAttendeeCount) \(session.otherAttendeeCount == 1 ? "other" : "others")"
                    )
                    if !session.programStatusLabel.isEmpty { LabeledContent("Program Status", value: session.programStatusLabel) }
                    if !session.presentedHostKeyFingerprint.isEmpty {
                        LabeledContent("Host Key") {
                            Text(session.presentedHostKeyFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .accessibilityIdentifier("terminal-host-key")
                    }
                    if let onThemeChosen {
                        Picker("Host Theme", selection: Binding(get: { session.themeName }, set: { onThemeChosen($0) })) {
                            Text("Use App Default").tag("")
                            ForEach(TerminalSurface.themeNames, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("terminal-host-theme")
                    }
                }
                if !session.connectionLog.steps.isEmpty {
                    Section("What Happened") {
                        ForEach(session.connectionLog.steps) { step in
                            ConnectionStepRow(step: step)
                        }
                    }
                }
                if !session.connectionLog.entries.isEmpty {
                    Section {
                        DisclosureGroup("Raw Log") {
                            ForEach(session.connectionLog.entries) { entry in
                                Text(entry.line)
                                    // Monospaced so the elapsed column lines up
                                    // and a slow step is visible by its shape.
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityIdentifier("connection-details-raw-log")
                    } footer: {
                        Text("The raw log is what the app recorded at each step. Share it when you report a problem.")
                    }
                }
            }
            .navigationTitle("Connection Details")
            .navigationSubtitle(hostLabel)
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            // The terminal colours its own bars for its ground, and a sheet's
            // bar would inherit that; this one takes the sheet's appearance.
            .toolbarColorScheme(systemColorScheme ?? colorScheme, for: .navigationBar)
            .toolbar {
                SheetToolbar.close(onDone)
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: diagnostics, preview: SharePreview("Connection Diagnostics")) {
                        Label("Share Diagnostics", systemImage: InterfaceSymbol.share)
                    }
                    .accessibilityIdentifier("connection-details-share")
                }
            }
        }
        // A form sheet: centred on a wide display, iPhone Duo's inner one
        // included, rather than a bottom sheet stretched across it.
        .task { session.refreshAttendance() }
        .presentationSizing(.form)
        .presentationDetents([.large])
    }

    /// The whole report as text: the answer, the steps, then the raw log.
    private var diagnostics: String {
        var lines = ["Connection Details: \(hostLabel)", presentation.cause]
        if !presentation.fix.isEmpty { lines.append(presentation.fix) }
        let steps = session.connectionLog.steps
        if !steps.isEmpty {
            lines.append("")
            lines.append("What Happened")
            for step in steps {
                let mark = step.outcome == .succeeded ? "✓" : "✕"
                lines.append(String(format: "%@ %6.2fs  %@", mark, step.offset, step.sentence))
            }
        }
        lines.append("")
        lines.append("Raw Log")
        lines.append(session.connectionLog.transcript)
        return lines.joined(separator: "\n")
    }
}

/// The answer at the top: a symbol, what happened as a headline, and what to
/// do as body text.
private struct ConnectionDetailsHeader: View {
    let session: TerminalSessionModel
    let presentation: TerminalConnectionPresentation

    var body: some View {
        VStack(spacing: 8) {
            symbol
                .font(.system(.largeTitle))
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(presentation.cause)
                .font(.headline)
                .accessibilityIdentifier("connection-details-cause")
            if !presentation.fix.isEmpty {
                Text(presentation.fix)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connection-details-fix")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        if session.hasFailed {
            Image(systemName: InterfaceSymbol.connectionFailed)
                .foregroundStyle(StatusTone.error.color)
        } else if session.isConnected {
            Image(systemName: InterfaceSymbol.stepSucceeded)
                .foregroundStyle(StatusTone.connected.color)
        } else if session.hasExited {
            Image(systemName: InterfaceSymbol.session)
                .foregroundStyle(StatusTone.state.color)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }
}

/// One step: a symbol that says how it went, its sentence, and how long into
/// the attempt it happened; the raw entry behind it, when there is one, is a
/// disclosure away.
private struct ConnectionStepRow: View {
    let step: ConnectionLog.Step

    var body: some View {
        if step.detail.isEmpty || step.detail == step.sentence {
            label
        } else {
            DisclosureGroup {
                Text(step.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                label
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: step.outcome == .succeeded ? InterfaceSymbol.stepSucceeded : InterfaceSymbol.stepFailed)
                .foregroundStyle(step.outcome == .succeeded ? StatusTone.connected.color : StatusTone.error.color)
                .accessibilityLabel(step.outcome == .succeeded ? "Succeeded" : "Failed")
            Text(step.sentence)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text("\(step.offset, format: .number.precision(.fractionLength(2))) s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
