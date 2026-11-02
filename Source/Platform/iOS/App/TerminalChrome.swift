// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyKit

import class UbiquittyRenderKit.RuntimeDrive

/// The way back to the live output from the scrollback, with how much
/// arrived below meanwhile, and the scroll indicator beside it.
///
/// At the bottom trailing edge above the bar, as Messages places its own.
/// Output arriving does not move a held view — that is the terminal's rule —
/// so this button is the reader's only cue that there is more below.
struct TerminalScrollbackControls: View {
    let position: TerminalScrollbackPosition
    let onJump: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            indicator
            Button(action: onJump) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                    if position.rowsArrivedBelow > 0 {
                        Text("\(position.rowsArrivedBelow) new")
                            .monospacedDigit()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, position.rowsArrivedBelow > 0 ? 14 : 0)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.glass)
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .accessibilityLabel("Jump to Bottom")
            .accessibilityValue(position.rowsArrivedBelow > 0 ? "\(position.rowsArrivedBelow) new lines" : "")
            .accessibilityIdentifier("terminal-jump-to-bottom")
            .hoverEffect(.highlight)
        }
    }

    /// A thin bar on the trailing edge, sized to the share of the scrollback
    /// on screen and placed where the view stands in it.
    private var indicator: some View {
        GeometryReader { space in
            let total = CGFloat(max(position.reachableRows + position.visibleRows, 1))
            let length = max(36, space.size.height * CGFloat(position.visibleRows) / total)
            let travel = space.size.height - length
            let fromBottom = travel * CGFloat(position.rowsAboveTail) / CGFloat(max(position.reachableRows, 1))
            Capsule()
                .fill(.secondary.opacity(0.6))
                .frame(width: 3, height: length)
                .position(x: space.size.width - 4, y: space.size.height - fromBottom - length / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Some of what was typed may not have reached the host, in Core's words,
/// with the two answers.
///
/// Over the grid, never in front of the keyboard's target: the pane stays
/// readable and what is typed waits behind the input in doubt. Neither
/// answer is prominent, because neither is safe to take without reading:
/// sending again can run a command twice.
struct TerminalInputInDoubtBanner: View {
    let notice: RuntimeDrive.InputInDoubtNotice
    let onResend: () -> Void
    let onDiscard: () -> Void

    @Environment(\.colorSchemeContrast)
    private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: InterfaceSymbol.attention)
                    .foregroundStyle(StatusTone.state.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.message)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("terminal-input-in-doubt-message")
                    Text(notice.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("terminal-input-in-doubt-detail")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button(notice.discardButton, action: onDiscard)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .accessibilityIdentifier("terminal-input-in-doubt-discard")
                Button(notice.resendButton, action: onResend)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .accessibilityIdentifier("terminal-input-in-doubt-send-again")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .modifier(StatusCardBackground(isContrastIncreased: contrast == .increased))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-input-in-doubt")
    }
}

/// A failed connection's cause, in one line under the status bar, with what
/// to do about it.
///
/// The cause is the sentence the failure came with — "127.0.0.1 refused the
/// connection on port 1." — not a generic one with the cause behind a button.
/// It is dismissible, and the grid under it stays live.
struct TerminalFailureBanner<Actions: View>: View {
    let cause: String
    let fix: String
    let hasFailed: Bool
    let onDetails: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder
    let actions: () -> Actions

    @Environment(\.colorSchemeContrast)
    private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: hasFailed ? InterfaceSymbol.error : InterfaceSymbol.session)
                    .foregroundStyle(hasFailed ? StatusTone.error.color : StatusTone.state.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cause)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("terminal-failure-cause")
                    if !fix.isEmpty {
                        Text(fix)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("terminal-failure-fix")
                    }
                }
                Spacer(minLength: 0)
                // The close role with its glyph: outside a bar the system
                // would spell the role out as a word.
                Button(role: .close, action: onDismiss) {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("terminal-failure-dismiss")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .modifier(StatusCardBackground(isContrastIncreased: contrast == .increased))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-connection-status")
    }

    @ViewBuilder
    private var buttons: some View {
        actions()
        Button("Details", action: onDetails)
            .buttonStyle(.glass)
            .fixedSize()
            .accessibilityIdentifier("terminal-connection-details")
    }
}
