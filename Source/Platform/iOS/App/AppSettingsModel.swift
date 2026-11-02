// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Observation
import SwiftUI
import UbiquittyCore
import UbiquittyKit

/// App preferences remain available without constructing a terminal or connection.
@Observable
@MainActor
final class AppSettingsModel {
    private var configurationEpoch: UInt64 = 0
    @ObservationIgnored
    private var subscription: Ubiquitty.Preferences.ConfigurationSubscription?

    init() {
        subscription = Ubiquitty.Preferences.ConfigurationSubscription.notifying(
            Ubiquitty.Apple.ownedCallback { [weak self] in
                MainActor.assumeIsolated { self?.configurationEpoch &+= 1 }
            }
        )
    }

    var accessorySymbols: [TerminalAccessoryKey] {
        _ = configurationEpoch
        return TerminalAccessoryKey.configuredSymbols
    }

    func setAccessorySymbols(_ keys: [TerminalAccessoryKey]) {
        write(.KeysAccessorySymbols, .ofText(.String, std.string(keys.map(\.capTitle).joined())))
    }

    var hasCustomAccessorySymbols: Bool {
        _ = configurationEpoch
        return Ubiquitty.Preferences.values().pointee.keyboardAccessorySymbols.value != nil
    }

    func resetAccessorySymbols() {
        let document = Ubiquitty.Preferences.removeSectionKey(
            Ubiquitty.Preferences.liveDocument().pointee,
            std.string("keys"),
            std.string("accessory_symbols")
        )
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
    }

    var optionSendsMeta: Binding<Bool> {
        Binding(
            get: {
                _ = self.configurationEpoch
                return Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) != .None
            },
            set: {
                _ = Ubiquitty.Preferences.configureOwnSectionKey(
                    std.string("keys"),
                    std.string("option_as_alt"),
                    std.string($0 ? "\"both\"" : "\"none\"")
                )
            }
        )
    }

    var fontFamily: String {
        _ = configurationEpoch
        return TerminalSurface.family(of: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
    }

    var fontPointSize: Double {
        _ = configurationEpoch
        return Ubiquitty.Preferences.Effective.liveRenderConfiguration().fontSizePoints
    }

    var hasCustomFont: Bool {
        _ = configurationEpoch
        let values = Ubiquitty.Preferences.values().pointee
        return values.fontFamily.value != nil || values.fontSize.value != nil || values.lineSpacingPoints.value != nil
    }

    func value(_ key: Ubiquitty.Preferences.Key) -> Ubiquitty.Preferences.Value {
        _ = configurationEpoch
        return Ubiquitty.Preferences.effectiveValue(key, Ubiquitty.Preferences.values().pointee).value ?? .init()
    }

    func toggle(_ key: Ubiquitty.Preferences.Key) -> Binding<Bool> {
        Binding(get: { self.value(key).boolean }, set: { self.write(key, .ofBool(.Bool, $0)) })
    }

    /// Reads the same defaults and inheritance as the title composer.
    func titleToggle(_ key: Ubiquitty.Preferences.Key) -> Binding<Bool> {
        Binding(
            get: {
                _ = self.configurationEpoch
                return Ubiquitty.Preferences.TitleComposition.effectiveBoolForKey(Ubiquitty.Preferences.values().pointee, key)
            },
            set: { self.write(key, .ofBool(.Bool, $0)) }
        )
    }

    func number(_ key: Ubiquitty.Preferences.Key) -> Binding<Double> {
        Binding(get: { self.value(key).number }, set: { self.write(key, .ofNumber(.Double, $0)) })
    }

    func integer(_ key: Ubiquitty.Preferences.Key) -> Binding<Int> {
        Binding(get: { Int(self.value(key).integer) }, set: { self.write(key, .ofInteger(.Int, Int64($0))) })
    }

    func text(_ key: Ubiquitty.Preferences.Key) -> Binding<String> {
        Binding(get: { String(self.value(key).text) }, set: { self.write(key, .ofText(self.value(key).kind, std.string($0))) })
    }

    func write(_ key: Ubiquitty.Preferences.Key, _ value: Ubiquitty.Preferences.Value) {
        _ = Ubiquitty.Preferences.configureOwnKey(key, value)
    }

    func remove(_ range: FallbackRange) {
        let document = Ubiquitty.Preferences.removeRangeMap(
            Ubiquitty.Preferences.liveDocument().pointee,
            range.first,
            range.last
        )
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
    }

    /// Validates with the configuration reader before replacing the old range atomically.
    func saveRange(_ spelling: String, family: String, shouldMatchSize: Bool?, replacing original: FallbackRange?) -> Bool {
        guard !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let parsed = spelling.withCString({ Ubiquitty.Preferences.parseCodePointRange(std.string_view($0)).value })
        else { return false }
        var document = Ubiquitty.Preferences.liveDocument().pointee
        if let original { document = Ubiquitty.Preferences.removeRangeMap(document, original.first, original.last) }
        var sizing = Ubiquitty.Preferences.RangeMapEntry().shouldMatchSize
        if let shouldMatchSize { sizing = .init(shouldMatchSize) }
        document = family.withCString {
            Ubiquitty.Preferences.spliceRangeMap(document, parsed.firstCodePoint, parsed.lastCodePoint, std.string_view($0), sizing)
        }
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
        return true
    }

    /// The settings sheet's font write: one key edited in the live document,
    /// which every pane then hears through the configuration subscription.
    ///
    /// - Parameters:
    ///   - family: The family to draw in, or nil to keep the configured one.
    ///   - pointSize: The size, or nil to keep the configured one.
    func selectFont(family: String? = nil, pointSize: Double? = nil) {
        if let pointSize {
            guard pointSize.isFinite else { return }
            _ = Ubiquitty.Preferences.configureOwnKey(
                .FontSize,
                Ubiquitty.Preferences.Value.ofNumber(.Double, Ubiquitty.Preferences.Zoom.clampFontZoom(pointSize))
            )
        }
        if let family {
            _ = Ubiquitty.Preferences.configureOwnKey(.FontFamily, Ubiquitty.Preferences.Value.ofText(.String, std.string(family)))
        }
    }

    /// Returns the font to the default table's: the keys leave the document.
    func resetFont() {
        var document = Ubiquitty.Preferences.liveDocument().pointee
        for key in ["family", "size", "line_spacing"] {
            document = Ubiquitty.Preferences.removeSectionKey(document, std.string("font"), std.string(key))
        }
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
    }

    /// The four `[appearance]` edge keys, named and in the order Settings lists them.
    static let paddingEdges: [(title: String, key: Ubiquitty.Preferences.Key)] = [
        ("Top", .AppearancePaddingTop), ("Bottom", .AppearancePaddingBottom),
        ("Left", .AppearancePaddingLeft), ("Right", .AppearancePaddingRight),
    ]
    private static var paddingEdgeKeys: [Ubiquitty.Preferences.Key] { paddingEdges.map(\.key) }

    /// The bounds and step every padding edge shares, from Core's schema.
    static var paddingRange: (bounds: ClosedRange<Double>, step: Double) {
        guard let range = Ubiquitty.Preferences.Schema.rangeFor("appearance", "padding")?.pointee else { return (0...64, 1) }
        return (range.minimum...range.maximum, range.step)
    }

    /// The padding every edge has, or nil while the edges differ.
    var uniformPadding: Double? {
        let edges = Self.paddingEdgeKeys.map { value($0).number }
        return edges.allSatisfy { $0 == edges[0] } ? edges[0] : nil
    }

    /// One padding for every edge.
    ///
    /// Reads the shared value, or the widest edge while they differ, so a step
    /// from mixed edges starts at a value one of them already has. Writes all
    /// four edge keys in one edit of the live document, so a pane re-lays out
    /// its grid once, and an edge key set earlier cannot keep its own value.
    var paddingOnEveryEdge: Binding<Double> {
        Binding(
            get: { self.uniformPadding ?? Self.paddingEdgeKeys.map { self.value($0).number }.max() ?? 0 },
            set: { points in
                let clamped = Ubiquitty.Preferences.Schema.clampToRange(points, "appearance", "padding")
                var document = Ubiquitty.Preferences.liveDocument().pointee
                for key in Self.paddingEdgeKeys {
                    guard let edited = Ubiquitty.Preferences.writeValueIntoBody(key, .ofNumber(.Double, clamped), document).value
                    else { return }
                    document = edited
                }
                _ = Ubiquitty.Preferences.configureOwnDocument(document)
            }
        )
    }

    /// One edge's padding, clamped to the schema's bounds before it is written.
    ///
    /// - Parameter key: One of the keys in ``paddingEdges``.
    /// - Returns: A binding over the edge's effective value.
    func padding(_ key: Ubiquitty.Preferences.Key) -> Binding<Double> {
        Binding(
            get: { self.value(key).number },
            set: { self.write(key, .ofNumber(.Double, Ubiquitty.Preferences.Schema.clampToRange($0, "appearance", "padding"))) }
        )
    }

    /// Whether the document states any padding, so Core's default for this
    /// device is not the one in use.
    var hasCustomPadding: Bool {
        _ = configurationEpoch
        let values = Ubiquitty.Preferences.values().pointee
        return values.padding.value != nil || values.paddingLeft.value != nil || values.paddingRight.value != nil
            || values.paddingTop.value != nil || values.paddingBottom.value != nil
    }

    /// Returns every edge to Core's default for this device: the shorthand
    /// and the edge keys leave the document.
    func resetPadding() {
        var document = Ubiquitty.Preferences.liveDocument().pointee
        for key in ["padding", "padding_left", "padding_right", "padding_top", "padding_bottom"] {
            document = Ubiquitty.Preferences.removeSectionKey(document, std.string("appearance"), std.string(key))
        }
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
    }

    var shouldMatchFallbackSize: Bool {
        _ = configurationEpoch
        return Ubiquitty.Preferences.Effective.matchFallbackSize(Ubiquitty.Preferences.values().pointee)
    }

    func setFallbackSizeMatching(_ enabled: Bool) {
        _ = Ubiquitty.Preferences.configureOwnKey(.FontMatchFallbackSize, Ubiquitty.Preferences.Value.ofBool(.Bool, enabled))
    }

    struct FallbackRange: Identifiable {
        let first: UInt32
        let last: UInt32
        let range: String
        let family: String
        let shouldMatchSize: Bool?
        var id: String { "\(first)-\(last)-\(family)" }
    }

    var fallbackRanges: [FallbackRange] {
        _ = configurationEpoch
        return Ubiquitty.Preferences.values().pointee.rangeMap
            .filter { !$0.family.empty() }
            .map { entry in
                FallbackRange(
                    first: entry.firstCodePoint,
                    last: entry.lastCodePoint,
                    range: String(entry.range),
                    family: String(entry.family),
                    shouldMatchSize: entry.shouldMatchSize.value
                )
            }
    }

    func setFallbackRangeSizing(_ range: FallbackRange, shouldMatchSize: Bool?) {
        var sizing = Ubiquitty.Preferences.RangeMapEntry().shouldMatchSize
        if let shouldMatchSize { sizing = .init(shouldMatchSize) }
        let document = range.family.withCString {
            Ubiquitty.Preferences.spliceRangeMap(
                Ubiquitty.Preferences.liveDocument().pointee,
                range.first,
                range.last,
                std.string_view($0),
                sizing
            )
        }
        _ = Ubiquitty.Preferences.configureOwnDocument(document)
    }

    var shouldPersistRemoteHistory: Bool {
        _ = configurationEpoch
        return Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory()
    }
    private(set) var historyPersistenceError = ""

    func setHistoryPersistence(_ enabled: Bool) {
        historyPersistenceError =
            ColdResumeSession.setHistoryPersistence(enabled)
            ? "" : "Saved history couldn’t be removed, so the setting wasn’t changed. Unlock this device and try again."
    }
}
