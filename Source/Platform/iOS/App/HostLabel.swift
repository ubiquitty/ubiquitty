// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore

/// What the chrome says about the machine a host's session lives on.
///
/// Core's one answer, `Session::resolvePaneHost`, read the way the desktop's
/// title row reads it: the place and the name the pill shows, and the
/// `[[tags]]` rules matched against the same answer, so a host a rule marks is
/// marked here under the name the pill gives it.
struct HostLabel: Equatable {
    /// The host's name as the pill shows it.
    let name: String
    /// How the bytes get there, as Core names it (`quic`, `ssh`).
    let carrier: String
    /// The tags the rules give this host, in the order the config declared them.
    let tags: [Tag]

    /// One tag the host wears.
    struct Tag: Equatable {
        /// The title; empty for an untitled rule tag, drawn as a dot.
        let name: String
        /// What a screen reader speaks: the title, or for an untitled tag
        /// Core's `Session::tagSpokenName`.
        let spokenName: String
        /// The tag's colour, nil for a tag that names no colour.
        let color: UIColor?
        /// Whether the capsule draws the name: false for an untitled tag and
        /// for one whose rule hides its name, each drawn as a dot (Core's
        /// `Session::ResolvedTag::drawsName`).
        let isNameShown: Bool
    }

    /// The colour the host is told apart by: its first coloured tag's.
    var tint: UIColor? { tags.first { $0.color != nil }?.color }

    /// What a screen reader hears for the pill.
    var accessibilityDescription: String {
        let tagged = tags.isEmpty ? "" : ", tagged " + tags.map(\.spokenName).joined(separator: ", ")
        return "On \(name) over \(carrier)\(tagged)"
    }

    /// Places a host record's session and matches the rules against it.
    ///
    /// - Parameters:
    ///   - record: The host.
    ///   - usesQUIC: Whether the session rides QUIC to a ubiquitty-host, which
    ///     is a host session of ours; over SSH the bytes are a login shell's,
    ///     which the transport stamp places.
    ///   - isSync: Whether a kept host session's Sync stream rides the carrier.
    @MainActor
    init(record: HostRecord, usesQUIC: Bool, isSync: Bool = false) {
        let key = record.username.isEmpty ? record.hostName : "\(record.username)@\(record.hostName)"
        var inputs = Ubiquitty.Session.PaneHostInputs()
        inputs.hostKey = std.string(key)
        inputs.hostLabel = std.string(record.displayName)
        if usesQUIC || isSync {
            inputs.isHostSession = true
            inputs.usesQUIC = usesQUIC
        } else {
            inputs.location.origin.transport = .SSH
            inputs.location.origin.host = std.string(key)
        }
        let host = Ubiquitty.Session.resolvePaneHost(inputs)
        let label = String(host.label)
        name = label.isEmpty ? record.displayName : label
        carrier = isSync && !usesQUIC ? "Sync+SSH" : String(host.carrier)
        let configuration = Ubiquitty.Preferences.values().pointee
        let resolved = Ubiquitty.Session.resolveTagsForPaneHost(configuration.tags, host, std.string())
        tags = resolved.map { tag in
            Tag(
                name: String(tag.name),
                spokenName: String(Ubiquitty.Session.tagSpokenName(tag)),
                color: tag.color.set
                    ? UIColor(
                        red: CGFloat(tag.color.red) / 255,
                        green: CGFloat(tag.color.green) / 255,
                        blue: CGFloat(tag.color.blue) / 255,
                        alpha: 1
                    ) : nil,
                isNameShown: tag.drawsName()
            )
        }
    }

    /// The ink that reads on a tag's fill, by the rule the desktop's chips use.
    ///
    /// - Parameter fill: The capsule's colour.
    /// - Returns: The label's colour.
    static func labelColor(on fill: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard fill.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .black }
        let channel = { (value: CGFloat) -> UInt32 in UInt32((min(max(value, 0), 1) * 255).rounded()) }
        let packed = (channel(red) << 16) | (channel(green) << 8) | channel(blue)
        let label = Ubiquitty.Themes.Contrast.labelColorOnFill(packed)
        return UIColor(
            red: CGFloat((label >> 16) & 0xff) / 255,
            green: CGFloat((label >> 8) & 0xff) / 255,
            blue: CGFloat(label & 0xff) / 255,
            alpha: 1
        )
    }
}

/// A tag as a filled capsule with its name in it: colour, text and shape, so
/// a reader who cannot tell the colour still reads the name. An untitled tag,
/// which only a rule with a colour supplies, is a dot of that colour, and so
/// is a tag whose rule hides its name.
struct HostTagCapsule: View {
    let tag: HostLabel.Tag

    var body: some View {
        let fill = tag.color ?? .systemGray4
        if !tag.isNameShown {
            Circle()
                .fill(Color(uiColor: fill))
                .frame(width: 9, height: 9)
                .accessibilityLabel(tag.spokenName)
        } else {
            capsule(fill: fill)
        }
    }

    private func capsule(fill: UIColor) -> some View {
        Text(tag.name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color(uiColor: HostLabel.labelColor(on: fill)))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color(uiColor: fill), in: Capsule())
    }
}

/// The host pill: which machine the session is on, and the tags its rules
/// give it.
///
/// Drawn without a ground of its own: it stands in the terminal's bar, whose
/// glass is already its capsule, and in a list row, which has its own.
///
/// The symbol wears the host's tag colour while the link is steady and the
/// link's own colour while it is not, as the desktop's chip does; the name
/// stays in the secondary ink, being the session's identity rather than news.
struct HostPill: View {
    let label: HostLabel
    /// Whether the link is in its steady state, as Core's `hostChipFor` says.
    var isSteady = true
    /// Whether the pill stands in a bar that holds the terminal's controls
    /// too: there the name is cut short and the tags are told by the symbol's
    /// colour, their names going to the screen reader and the host list.
    var isCompact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "network")
                .foregroundStyle(symbolInk)
            Text(isCompact ? Self.shortened(label.name) : label.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                // A bar hands each item what it has left, and a name squeezed
                // to its first letter names nothing: the compact pill asks for
                // its whole, already shortened, width.
                .fixedSize(horizontal: isCompact, vertical: false)
            if !isCompact {
                // By place: two untitled tags share the empty name.
                ForEach(Array(label.tags.enumerated()), id: \.offset) { _, tag in
                    HostTagCapsule(tag: tag)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.accessibilityDescription)
        .accessibilityIdentifier("terminal-host-pill")
    }

    /// The longest name the compact pill spells out.
    private static let compactNameLength = 14

    /// A name cut from the middle to ``compactNameLength`` characters, which
    /// keeps the start a person recognises and the end that tells siblings
    /// apart.
    ///
    /// - Parameter name: The host's name.
    /// - Returns: The name, or its two ends around an ellipsis.
    static func shortened(_ name: String) -> String {
        guard name.count > compactNameLength else { return name }
        let kept = compactNameLength - 1
        return String(name.prefix((kept + 1) / 2)) + "\u{2026}" + String(name.suffix(kept / 2))
    }

    private var symbolInk: Color {
        // A link that is not steady is a state, not an error: the screen
        // that holds the pill says what went wrong in words.
        guard isSteady else { return StatusTone.state.color }
        return label.tint.map { Color(uiColor: $0) } ?? .secondary
    }
}
