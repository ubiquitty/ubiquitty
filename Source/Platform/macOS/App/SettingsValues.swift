// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SettingsValues.swift — the Settings window's reads and writes of one
// preference, addressed by Core's key.
//
// A read resolves through `Preferences::effectiveValue`, so a row shows what
// the terminal does, defaults included, and no Swift file names where a setting
// is stored. A write goes through `Preferences::configureOwnKey`, which
// configures Core and persists as the application's own write; every open
// window then follows through the one configuration subscription. A key with no
// `Key` (a macro, the option-key policy) goes through the section-and-key door.
//

import UbiquittyKit

/// The key every helper below addresses a preference by.
typealias PreferencesKey = Ubiquitty.Preferences.Key

/// What a preference reads as right now.
///
/// - Parameter key: The preference.
/// - Returns: Its resolved value, or nil when `key` names no enumerator.
func settingValue(_ key: PreferencesKey) -> Ubiquitty.Preferences.Value? {
    Ubiquitty.Preferences.effectiveValue(key, Ubiquitty.Preferences.values().pointee).value
}

/// A toggle's resolved state.
func settingBool(_ key: PreferencesKey) -> Bool {
    settingValue(key)?.boolean ?? false
}

/// A whole-number preference's resolved value.
///
/// A key stored as a fraction answers its rounded value, so a stepper over a
/// key of either kind reads one way.
func settingInt(_ key: PreferencesKey) -> Int {
    guard let value = settingValue(key) else { return 0 }
    return value.kind == .Double ? Int(value.number.rounded()) : Int(value.integer)
}

/// A numeric preference's resolved value, whether it is stored whole or not.
func settingDouble(_ key: PreferencesKey) -> Double {
    guard let value = settingValue(key) else { return 0 }
    return value.kind == .Int ? Double(value.integer) : value.number
}

/// A text or token preference's resolved value; empty when it is unset.
func settingText(_ key: PreferencesKey) -> String {
    guard let value = settingValue(key) else { return "" }
    return String(value.text)
}

/// The vocabulary of a closed-choice preference, in the order a picker offers it.
///
/// - Parameter key: The preference.
/// - Returns: Each term's token, the spelling the file holds.
func settingTokens(_ key: PreferencesKey) -> [String] {
    Ubiquitty.Preferences.vocabularyFor(key).map { String(cString: $0.token) }
}

/// A closed-choice preference's selected row.
///
/// - Parameters:
///   - key: The preference.
///   - fallback: The row to show when the resolved token is outside the
///     vocabulary. A picker cannot show an absent selection, and Core resolves
///     an unreadable value to the default in the same direction.
/// - Returns: The index of the resolved token in ``settingTokens``.
func settingTermIndex(_ key: PreferencesKey, fallback: Int = 0) -> Int {
    settingTokens(key).firstIndex(of: settingText(key)) ?? fallback
}

/// Persists one preference as the application's own write.
///
/// - Parameters:
///   - key: The preference.
///   - value: Its new value; the caller picks the slot that matches the key's
///     serializer.
/// - Returns: Whether the configuration took the value.
@discardableResult
private func configureSetting(_ key: PreferencesKey, _ value: Ubiquitty.Preferences.Value) -> Bool {
    Ubiquitty.Preferences.configureOwnKey(key, value).value != nil
}

/// The serializer a preference is written with.
private func settingKind(_ key: PreferencesKey) -> Ubiquitty.Preferences.SerializeKind {
    Ubiquitty.Preferences.descriptorFor(key).pointee.kind
}

/// Persists a toggle.
///
/// - Returns: Whether the configuration took the value.
@discardableResult
func setSetting(_ key: PreferencesKey, bool value: Bool) -> Bool { // bool-ok: the toggle's own state, written as its TOML boolean.
    configureSetting(key, Ubiquitty.Preferences.Value.ofBool(settingKind(key), value))
}

/// Persists a whole number, in the slot the key's serializer reads.
///
/// - Returns: Whether the configuration took the value.
@discardableResult
func setSetting(_ key: PreferencesKey, int value: Int) -> Bool {
    let kind = settingKind(key)
    if kind == .Double {
        return configureSetting(key, Ubiquitty.Preferences.Value.ofNumber(kind, Double(value)))
    }
    return configureSetting(key, Ubiquitty.Preferences.Value.ofInteger(kind, Int64(value)))
}

/// Persists a number, in the slot the key's serializer reads.
///
/// - Returns: Whether the configuration took the value.
@discardableResult
func setSetting(_ key: PreferencesKey, double value: Double) -> Bool {
    let kind = settingKind(key)
    if kind == .Int {
        return configureSetting(key, Ubiquitty.Preferences.Value.ofInteger(kind, Int64(value.rounded())))
    }
    return configureSetting(key, Ubiquitty.Preferences.Value.ofNumber(kind, value))
}

/// Persists text or a token.
///
/// - Returns: Whether the configuration took the value.
@discardableResult
func setSetting(_ key: PreferencesKey, text value: String) -> Bool {
    configureSetting(key, Ubiquitty.Preferences.Value.ofText(settingKind(key), std.string(value)))
}

/// Persists the row a picker selected, as the vocabulary's token for it.
///
/// - Parameters:
///   - key: The preference.
///   - termIndex: A position in ``settingTokens``. Out of range is refused
///     rather than clamped: a caller off by one has a picker and a vocabulary
///     that disagree, and writing a neighbouring term would hide that.
/// - Returns: Whether the configuration took the value.
@discardableResult
func setSetting(_ key: PreferencesKey, termIndex: Int) -> Bool {
    let tokens = settingTokens(key)
    guard tokens.indices.contains(termIndex) else { return false }
    return setSetting(key, text: tokens[termIndex])
}

/// A string as a TOML basic-string literal.
func tomlQuoted(_ text: String) -> std.string {
    text.withCString { Ubiquitty.Preferences.tomlString(std.string_view($0)) }
}

/// Persists one entry of a table no `Key` names.
///
/// - Parameters:
///   - section: The table, such as `macros`.
///   - key: The entry's name.
///   - toml: The value as a TOML literal.
/// - Returns: Whether the configuration took the entry.
@discardableResult
func setSectionSetting(_ section: String, _ key: String, toml: std.string) -> Bool {
    Ubiquitty.Preferences.configureOwnSectionKey(std.string(section), std.string(key), toml).value != nil
}

/// Removes one entry of a table no `Key` names.
///
/// - Returns: Whether the configuration took the removal.
@discardableResult
func removeSectionSetting(_ section: String, _ key: String) -> Bool {
    Ubiquitty.Preferences.removeConfiguredSectionKey(std.string(section), std.string(key)).value != nil
}

/// The `[tabs] show_shortcuts` mode: 0 off, 1 always, 2 only while Command is held.
func settingTabShortcutHintMode() -> Int {
    Int(
        Ubiquitty.Preferences.tabShortcutHintsToInt(
            Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
        )
    )
}

/// Whether the wide-gamut colour space is selected.
func settingIsColorSpaceP3() -> Bool {
    Ubiquitty.Preferences.Effective.colorSpaceP3(Ubiquitty.Preferences.values().pointee)
}

/// A Tektronix colour as 0xRRGGBBAA, the layout the colour wells pack.
///
/// - Parameter key: `TekBeamColor` or `TekBackgroundColor`.
/// - Returns: The resolved colour with an opaque alpha.
func settingTekColor(_ key: PreferencesKey) -> UInt32 {
    let values = Ubiquitty.Preferences.values().pointee
    let rgb =
        key == .TekBeamColor
        ? Ubiquitty.Preferences.Effective.tekBeamColor(values)
        : Ubiquitty.Preferences.Effective.tekBackgroundColor(values)
    return (rgb << 8) | 0xFF
}

/// Persists which Option keys send the terminal Meta modifier.
///
/// - Parameter token: The configuration token: `none`, `left`, `right` or `both`.
/// - Returns: Whether the token names a policy and the configuration took it.
@discardableResult
func setOptionAsAlternate(_ token: String) -> Bool {
    guard Ubiquitty.Preferences.optionAsAlternateFromString(std.string(token)).value != nil else { return false }
    return setSectionSetting("keys", "option_as_alt", toml: tomlQuoted(token))
}
