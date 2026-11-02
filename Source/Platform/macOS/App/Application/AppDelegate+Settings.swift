// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AppDelegate+Settings.swift — the settings window's writes that carry more
// than one key's value: a clamp the schema owns, a value translated from a
// picker's row, a side effect beyond the configuration, or a block of the
// document.
//
// Every write is an edit of the live configuration document: Core rewrites
// the text and configures from it, every open window hears it through the one
// subscription its owner holds, and the file takes the same text as the
// application's own write, so the file watcher does not reload it.
//

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit
import UniformTypeIdentifiers

/// Reads the configuration file into Core, writing the documented template
/// first when there is none, and registers what a load registers beside the
/// values.
///
/// What the file could not apply is shown in every window's title row as well
/// as logged.
@MainActor
func loadPreferencesIntoDefaults() {
    SettingsWindowController.preferencesDidLoad()
    guard let directory = Ubiquitty.Preferences.directoryPath().value.map({ String($0) }) else { return }
    let file = (directory as NSString).appendingPathComponent("config.toml")
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: file) {
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? UBAppDelegate.defaultConfigurationContents().write(to: URL(fileURLWithPath: file), options: .atomic)
    }
    _ = Ubiquitty.Preferences.configureFromFile(std.string(file), .Permissive)
    Ubiquitty.Themes.registerThemesFromValues(Ubiquitty.Preferences.values().pointee)
    SystemTheme.refresh()
    // The opt-in scripting hook: the program [scripting] names runs here, and
    // Core merges what it printed into the document just configured.
    _ = ScriptingHook.run()
    TerminalWindowController.showConfigurationDiagnostics()
    Ubiquitty.Runtime.applyProcessPreferences(Ubiquitty.Preferences.values().pointee)
}

/// What a block edit from the settings surface owes after Core configured from
/// the spliced document: what a load registers beside the values.
@MainActor
private func settleSettingsDocumentEdit() {
    Ubiquitty.Themes.registerThemesFromValues(Ubiquitty.Preferences.values().pointee)
    SystemTheme.refresh()
    TerminalWindowController.showConfigurationDiagnostics()
    Ubiquitty.Runtime.applyProcessPreferences(Ubiquitty.Preferences.values().pointee)
}

/// Configures Core from an edited copy of the live document.
@MainActor
private func configureEditedDocument(_ document: std.string) {
    _ = Ubiquitty.Preferences.configureOwnDocument(document)
}

private func optionalText(_ value: std.string?) -> String? {
    guard let value, !value.empty() else { return nil }
    return String(value)
}

extension UBAppDelegate {
    private typealias Values = Ubiquitty.Preferences.Values

    private var values: Values { Ubiquitty.Preferences.values().pointee }

    // MARK: - Appearance

    /// The appearance picker's row: 0 System, 1 Light, 2 Dark.
    ///
    /// Following the system wins; otherwise the pinned theme's darkness
    /// decides. Core's `appearanceModeFromValues` owns the rule, and its values
    /// are the picker's rows.
    func settingsAppearanceMode() -> Int {
        Int(Ubiquitty.SwiftBridge.appearanceMode(values))
    }

    func settingsSetSystemLightTheme(_ index: Int) {
        // The picker hands a row; the configuration keeps the theme's name, and
        // a row with no theme is ignored rather than persisted blank.
        guard let name = Self.themeName(at: index) else { return }
        setSetting(.AppearanceSystemLightTheme, text: name)
        applySystemAppearanceThemeIfEnabled()
    }

    func settingsSetSystemDarkTheme(_ index: Int) {
        guard let name = Self.themeName(at: index) else { return }
        setSetting(.AppearanceSystemDarkTheme, text: name)
        applySystemAppearanceThemeIfEnabled()
    }

    func settingsSetAppearanceMode(_ mode: Int) {
        if mode == 0 {
            // System: follow the appearance and apply its theme.
            setSetting(.AppearanceFollowSystem, bool: true)
            applySystemAppearanceThemeIfEnabled()
            return
        }
        let index = Ubiquitty.SwiftBridge.firstThemeOfDarkness(mode == 2 ? .Dark : .Light)
        guard index >= 0 else { return }
        let name = Self.themeName(at: Int(index)) ?? ""
        setSetting(.AppearanceFollowSystem, bool: false)
        setSetting(.AppearanceTheme, text: name)
        applyThemeToOpenWindows(at: Int(index))
    }

    // The name of the theme at a registry index, or nil when out of range.
    // Themes persist by name; a picker or menu carries the index.
    private static func themeName(at index: Int) -> String? {
        guard let theme = Ubiquitty.Themes.get(Int32(clamping: index)), let name = theme.pointee.name else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }

    // MARK: - Selection, mouse and links

    func settingsSetSmartDoubleClick(_ isOn: Bool) { setSetting(.SelectionSmartDoubleClick, bool: isOn) }
    func settingsSetCopy(onSelect isOn: Bool) { setSetting(.SelectionCopyOnSelect, bool: isOn) }
    func settingsSetOSC8ClickOpens(_ isOn: Bool) { setSetting(.SelectionOSC8ClickOpens, bool: isOn) }
    func settingsSetLinksOverrideReporting(_ isOn: Bool) { setSetting(.SelectionLinksOverrideReporting, bool: isOn) }
    func settingsSetRestrictSelection(toText isOn: Bool) { setSetting(.SelectionRestrictToText, bool: isOn) }
    func settingsSetConfirmMultilinePaste(_ isOn: Bool) { setSetting(.PasteConfirmMultiline, bool: isOn) }

    func settingsSetConfirmMultilinePasteThreshold(_ lines: Int) {
        setSetting(.PasteConfirmMultilineThreshold, int: Self.clamp(lines, "paste", "confirm_multiline_threshold"))
    }

    func settingsSetWheelSpeed(_ speed: Double) {
        setSetting(.MouseWheelSpeed, double: Ubiquitty.Preferences.Schema.clampToRange(speed, "mouse", "wheel_speed"))
    }

    func settingsSetWheelLines(_ lines: Int) {
        setSetting(.MouseWheelLines, int: Self.clamp(lines, "mouse", "wheel_lines"))
    }

    // Clamped to the schema's scrollback range, which is the stepper's, so the
    // stored value never lands outside what the control can show.
    func settingsSetScrollbackLines(_ lines: Int) {
        setSetting(.TerminalScrollbackLines, int: Self.clamp(lines, "terminal", "scrollback_lines"))
    }

    func settingsSetTrackpadSpeed(_ speed: Double) {
        setSetting(.MouseTrackpadSpeed, double: Ubiquitty.Preferences.Schema.clampToRange(speed, "mouse", "trackpad_speed"))
    }

    func settingsSetUnderlineLinks(_ isOn: Bool) { setSetting(.UnderlineLinks, bool: isOn) }
    /// 0 single, 1 dotted.
    func settingsSetLinkUnderlineStyle(_ style: Int) { setSetting(.UnderlineLinkStyle, int: style) }
    func settingsSetLinkColorSystemBlue(_ isOn: Bool) { setSetting(.UnderlineLinkColorBlue, bool: isOn) }
    func settingsSetLinkStylePerKind(_ isOn: Bool) { setSetting(.UnderlineLinkStylePerKind, bool: isOn) }

    // The schema's integer clamp, at the stepper's width.
    private static func clamp(_ value: Int, _ section: String, _ key: String) -> Int {
        Int(Ubiquitty.Preferences.Schema.clampToRange(Int32(clamping: value), section, key))
    }

    // MARK: - Window background

    func settingsSetBackgroundOpacity(_ opacity: Double) {
        setSetting(
            .AppearanceBackgroundOpacity,
            double: Ubiquitty.Preferences.Schema.clampToRange(opacity, "appearance", "background_opacity")
        )
    }

    func settingsSetBlurRadius(_ radius: Double) {
        setSetting(.AppearanceBlurRadius, double: Ubiquitty.Preferences.Schema.clampToRange(radius, "appearance", "blur_radius"))
    }

    func settingsSetTextContrastOnBlur(_ isEnabled: Bool) { setSetting(.AppearanceTextContrastOnBlur, bool: isEnabled) }
    func settingsSetTextContrast(_ isEnabled: Bool) { setSetting(.AppearanceTextContrast, bool: isEnabled) }
    func settingsSetBackgroundVibrancy(_ isEnabled: Bool) { setSetting(.AppearanceBackgroundVibrancy, bool: isEnabled) }

    func settingsSetBackgroundBlur(_ isOn: Bool) {
        settingsSetBlurRadius(isOn ? Ubiquitty.Preferences.Defaults.blurRadius : 0.0)
    }

    // MARK: - Tags

    /// Writes how strongly tag colours are drawn in the title bar and on tabs,
    /// clamped to the schema's range, which is the slider's.
    ///
    /// - Parameter opacity: The opacity, 0.1 to 1.
    func settingsSetTagColorOpacity(_ opacity: Double) {
        setSetting(
            .AppearanceTagColorOpacity,
            double: Ubiquitty.Preferences.Schema.clampToRange(opacity, "appearance", "tag_color_opacity")
        )
    }

    // MARK: - Fonts

    func settingsFontFamily() -> String? { optionalText(values.fontFamily.value) }

    /// Empty is System Monospaced, the picker's first row: the override is
    /// cleared, which reads back as unset.
    func settingsSetFontFamily(_ family: String) {
        setSetting(.FontFamily, text: family)
        // The family's own features, axes and weights are what the Fonts pane
        // offers, so the pane rebuilds on the change.
        NotificationCenter.default.post(name: Notification.Name("UBFontFamilyChanged"), object: nil)
    }

    func settingsSymbolFallbackFont() -> String? {
        let values = values
        return optionalText(values.symbolFallbackFont.value ?? values.fallbackFont.value)
    }

    func settingsSetSymbolFallbackFont(_ family: String) { setSetting(.FontSymbolFallback, text: family) }

    func settingsCJKFallbackFont() -> String? { optionalText(values.cjkFallbackFont.value) }

    func settingsSetCJKFallbackFont(_ preference: String) {
        setSetting(.FontCJKFallback, text: preference == "auto" ? "" : preference)
    }

    func settingsCJKFontNames() -> [String] {
        refreshFontCatalogIfNeeded()
        return settingsCJKFontNamesCache
    }

    func settingsSymbolFontNames() -> [String] {
        refreshFontCatalogIfNeeded()
        return settingsSymbolFontNamesCache
    }

    func settingsEmojiFallbackFont() -> String? { optionalText(values.emojiFallbackFont.value) }

    /// Empty is the platform's own emoji face: the override is cleared, so the
    /// picker's first row reads back as unset.
    func settingsSetEmojiFallbackFont(_ family: String) { setSetting(.FontEmojiFallback, text: family) }

    func settingsEmojiFontNames() -> [String] {
        refreshFontCatalogIfNeeded()
        return settingsEmojiFontNamesCache
    }

    func settingsAllFontFamilyNames() -> [String] {
        refreshFontCatalogIfNeeded()
        return fontFamilySnapshot ?? []
    }

    /// System Monospaced, the default, then every installed fixed-pitch
    /// family, sorted.
    func settingsMonospacedFontNames() -> [String] {
        refreshFontCatalogIfNeeded()
        return settingsMonospacedFontNamesCache.isEmpty ? ["System Monospaced"] : settingsMonospacedFontNamesCache
    }

    // MARK: - Font routing
    //
    // Reads come from the parsed configuration; writes go through Core's
    // splicers against the document's own text, so a block this editor does not
    // touch — a hand-authored range, a comment inside one — survives byte for
    // byte.

    /// The configured [[font.range_map]] entries: `range`, `family`, `first`
    /// and `last` each. The range is the file's own spelling when it has one,
    /// so a diagnostic quotes what a person wrote.
    func settingsRangeMapEntries() -> [[String: Any]] {
        values.rangeMap.map { entry in
            let range =
                entry.range.empty() ? Ubiquitty.Preferences.formatCodePointRange(entry.firstCodePoint, entry.lastCodePoint) : entry.range
            var result: [String: Any] = [
                "range": String(range), "family": String(entry.family), "first": entry.firstCodePoint, "last": entry.lastCodePoint,
            ]
            if let shouldMatchSize = entry.shouldMatchSize.value { result["matchSize"] = shouldMatchSize }
            return result
        }
    }

    func settingsSetRangeMap(from first: UInt32, to last: UInt32, family: String, shouldMatchSize: Bool? = nil) {
        // The reader drops such an entry, so writing one would do nothing.
        guard first <= last, !family.isEmpty else { return }
        var sizing = Ubiquitty.Preferences.RangeMapEntry().shouldMatchSize
        if let shouldMatchSize { sizing = .init(shouldMatchSize) }
        let document = family.withCString {
            Ubiquitty.Preferences.spliceRangeMap(Ubiquitty.Preferences.liveDocument().pointee, first, last, std.string_view($0), sizing)
        }
        configureEditedDocument(document)
    }

    func settingsRemoveRangeMap(from first: UInt32, to last: UInt32) {
        guard first <= last else { return }
        configureEditedDocument(Ubiquitty.Preferences.removeRangeMap(Ubiquitty.Preferences.liveDocument().pointee, first, last))
    }

    /// The configured [[font.language_fallbacks]] entries: `script` and
    /// `family` each.
    func settingsLanguageFallbackEntries() -> [[String: Any]] {
        values.languageFallbacks.map { entry in ["script": String(entry.script), "family": String(entry.family)] }
    }

    /// The scripts the reader accepts, so the picker cannot offer one whose
    /// entry it would drop. Han has its own control in the Fonts pane, and two
    /// places setting one thing is how they disagree.
    func settingsFontScriptNames() -> [String] {
        [
            "arabic", "bengali", "cyrillic", "devanagari", "greek", "gurmukhi", "hangul", "hebrew",
            "kana", "khmer", "lao", "latin", "math", "myanmar", "symbols", "thai",
        ]
    }

    func settingsSetLanguageFallback(forScript script: String, family: String) {
        guard !script.isEmpty, !family.isEmpty else { return }
        let document = script.withCString { scriptBytes in
            family.withCString { familyBytes in
                Ubiquitty.Preferences.spliceLanguageFallback(
                    Ubiquitty.Preferences.liveDocument().pointee,
                    std.string_view(scriptBytes),
                    std.string_view(familyBytes)
                )
            }
        }
        configureEditedDocument(document)
    }

    func settingsRemoveLanguageFallback(forScript script: String) {
        guard !script.isEmpty else { return }
        let document = script.withCString {
            Ubiquitty.Preferences.removeLanguageFallback(Ubiquitty.Preferences.liveDocument().pointee, std.string_view($0))
        }
        configureEditedDocument(document)
    }

    // MARK: - Title composition
    //
    // Each getter reads the effective composition, the value the title weave
    // reads, and each setter persists through the composition table's key.

    private func titleFlag(_ key: Ubiquitty.Preferences.Key) -> Bool {
        Ubiquitty.Preferences.TitleComposition.effectiveBoolForKey(values, key)
    }

    private func titleText(_ surface: Ubiquitty.Preferences.TitleComposition.Surface) -> String {
        String(Ubiquitty.SwiftBridge.effectiveTitleText(values, Int32(surface.rawValue)))
    }

    // The row names the key, so a surface cannot be paired with another
    // surface's key here.
    private func setTitleText(_ text: String, _ surface: Ubiquitty.Preferences.TitleComposition.Surface) {
        guard let row = Ubiquitty.Preferences.TitleComposition.descriptorForTextSurface(surface) else { return }
        setSetting(row.pointee.key, text: text)
    }

    func settingsTitleWindowDirectory() -> Bool { titleFlag(.TitleWindowDirectory) }
    func settingsSetTitleWindowDirectory(_ isOn: Bool) { setSetting(.TitleWindowDirectory, bool: isOn) }
    func settingsTitleWindowProcess() -> Bool { titleFlag(.TitleWindowProcess) }
    func settingsSetTitleWindowProcess(_ isOn: Bool) { setSetting(.TitleWindowProcess, bool: isOn) }
    func settingsTitleWindowProcessArguments() -> Bool { titleFlag(.TitleWindowProcessArguments) }
    func settingsSetTitleWindowProcessArguments(_ isOn: Bool) { setSetting(.TitleWindowProcessArguments, bool: isOn) }
    func settingsTitleWindowShellCommand() -> Bool { titleFlag(.TitleWindowShellCommand) }
    func settingsSetTitleWindowShellCommand(_ isOn: Bool) { setSetting(.TitleWindowShellCommand, bool: isOn) }
    func settingsTitleWindowTTYName() -> Bool { titleFlag(.TitleWindowTTYName) }
    func settingsSetTitleWindowTTYName(_ isOn: Bool) { setSetting(.TitleWindowTTYName, bool: isOn) }
    func settingsTitleWindowText() -> String { titleText(.Window) }
    func settingsSetTitleWindowText(_ text: String) { setTitleText(text, .Window) }
    func settingsTitleTabText() -> String { titleText(.Tab) }
    func settingsSetTitleTabText(_ text: String) { setTitleText(text, .Tab) }
    func settingsTitlePaneText() -> String { titleText(.Pane) }
    func settingsSetTitlePaneText(_ text: String) { setTitleText(text, .Pane) }

    // MARK: - Font face

    func settingsSetFontSize(_ points: Double) {
        setSetting(.FontSize, double: Ubiquitty.Preferences.Schema.clampToRange(points, "font", "size"))
    }

    func settingsSetLigatures(_ isOn: Bool) { setSetting(.FontLigatures, bool: isOn) }

    // `font.features` is an allow and block list of OpenType feature tags. The
    // stored value is the canonical spelling — parsed, normalized and
    // deduplicated — so it is stable.
    private func applyFontFeatures(_ specification: std.string) {
        setSetting(.FontFeatures, text: String(Ubiquitty.Rendering.canonicalFontFeatureSpecification(specification)))
    }

    func settingsFontFeatures() -> String? { optionalText(values.fontFeatures.value) }

    func settingsSetFontFeatures(_ features: String) { applyFontFeatures(std.string(features)) }

    // `font.variations` is a `tag=value` list of variable-font axes, stored in
    // its canonical spelling for the same reason.
    func settingsFontVariations() -> String? { optionalText(values.fontVariations.value) }

    func settingsSetFontVariations(_ variations: String) {
        let canonical = Ubiquitty.Rendering.serializeFontVariationSettings(
            Ubiquitty.Rendering.parseFontVariationSpecification(std.string(variations))
        )
        setSetting(.FontVariations, text: String(canonical))
    }

    func settingsCharacterSpacing() -> Double { Ubiquitty.Preferences.Effective.characterSpacing(values) }

    func settingsSetCharacterSpacing(_ points: Double) {
        setSetting(.FontCharacterSpacing, double: Ubiquitty.Preferences.Schema.clampToRange(points, "font", "character_spacing"))
    }

    func settingsFontWidth() -> Double { Ubiquitty.Preferences.Effective.fontWidthPercent(values) }

    func settingsBaselineOffset() -> Double { values.baselineOffset.value ?? 0 }

    func settingsSetBaselineOffset(_ points: Double) {
        setSetting(.FontBaselineOffset, double: Ubiquitty.Preferences.Schema.clampToRange(points, "font", "baseline_offset"))
    }

    /// Zero is the face's own width, the default, which the configuration
    /// stores as written rather than clamping into the range a person picks
    /// from.
    func settingsSetFontWidth(_ percent: Double) {
        setSetting(.FontWidth, double: percent > 0 ? Ubiquitty.Preferences.Schema.clampToRange(percent, "font", "width") : 0.0)
    }

    func settingsFontWeight() -> Int { Int(Ubiquitty.Preferences.Effective.fontWeight(values)) }

    func settingsBoldFontWeight() -> Int { Int(Ubiquitty.Preferences.Effective.boldFontWeight(values)) }

    /// Zero is the face's own instance, the default; any other weight is an
    /// axis value the face is asked for.
    func settingsSetFontWeight(_ weight: Int, bold boldWeight: Int) {
        setSetting(.FontWeight, int: max(weight, 0))
        setSetting(.FontBoldWeight, int: max(boldWeight, 0))
    }

    /// Whether `font.features` enables the `zero` tag.
    func settingsSlashedZero() -> Bool {
        Ubiquitty.SwiftBridge.fontFeaturesEnableSlashedZero(values)
    }

    /// Enables the `zero` tag, or drops it entirely so the canonical string
    /// stays minimal; a change that is already in place writes nothing.
    func settingsSetSlashedZero(_ isOn: Bool) {
        let edited = Ubiquitty.SwiftBridge.fontFeaturesWithSlashedZero(values, isOn ? .Enabled : .Disabled)
        guard let specification = edited.value else { return }
        applyFontFeatures(specification)
    }

    func settingsSetLineSpacing(_ points: Double) {
        setSetting(.FontLineSpacing, double: Ubiquitty.Preferences.Schema.clampToRange(points, "font", "line_spacing"))
    }

    func settingsSetWideGlyphBoost(_ isOn: Bool) { setSetting(.FontWideGlyphBoost, bool: isOn) }

    func settingsSetWideGlyphScale(_ scale: Double) {
        setSetting(.FontWideGlyphScale, double: Ubiquitty.Preferences.Schema.clampToRange(scale, "font", "wide_glyph_scale"))
    }

    func settingsSetUnderlineThickness(_ scale: Double) {
        setSetting(.UnderlineThickness, double: Ubiquitty.Preferences.Schema.clampToRange(scale, "underline", "thickness"))
    }

    func settingsSetUnderlineOffset(_ points: Double) {
        setSetting(.UnderlineOffset, double: Ubiquitty.Preferences.Schema.clampToRange(points, "underline", "offset"))
    }

    func settingsSetUnderlineSkipInk(_ isOn: Bool) { setSetting(.UnderlineSkipInk, bool: isOn) }
    func settingsSetUnderlineFollowsInk(_ isOn: Bool) { setSetting(.UnderlineFollowsInk, bool: isOn) }
    func settingsSetBrailleGrid(_ isOn: Bool) { setSetting(.FontBrailleGrid, bool: isOn) }

    func settingsSetUnderlineSkipInkPad(_ points: Double) {
        setSetting(.UnderlineSkipInkPad, double: Ubiquitty.Preferences.Schema.clampToRange(points, "underline", "skip_ink_pad"))
    }

    // MARK: - Text rendering

    func settingsSetBrightenBold(_ isOn: Bool) { setSetting(.TextBrightenBold, bool: isOn) }
    func settingsSetBeamTerminalFont(_ isOn: Bool) { setSetting(.AppearanceBeamTerminalFont, bool: isOn) }
    func settingsSetTekBrightPen(_ isOn: Bool) { setSetting(.TekBrightPen, bool: isOn) }
    func settingsSetTekGlowVectors(_ isOn: Bool) { setSetting(.TekGlowVectors, bool: isOn) }

    /// 0 the terminal theme, 1 the custom beam and background.
    func settingsSetTekColorMode(_ mode: Int) { setSetting(.TekColorMode, int: mode <= 0 ? 0 : 1) }

    /// A packed 0xRRGGBB, stored in the "#rrggbb" spelling.
    func settingsSetTekBeamColor(_ rgb: UInt32) { setSetting(.TekBeamColor, text: Self.hexColor(rgb)) }

    func settingsSetTekBackgroundColor(_ rgb: UInt32) { setSetting(.TekBackgroundColor, text: Self.hexColor(rgb)) }

    private static func hexColor(_ rgb: UInt32) -> String {
        let hex = String(rgb & 0xFFFFFF, radix: 16)
        return "#" + String(repeating: "0", count: 6 - hex.count) + hex
    }

    func settingsSetWindowPaddingLeft(_ points: Double) { setPadding(.AppearancePaddingLeft, points, "padding_left") }
    func settingsSetWindowPaddingRight(_ points: Double) { setPadding(.AppearancePaddingRight, points, "padding_right") }
    func settingsSetWindowPaddingTop(_ points: Double) { setPadding(.AppearancePaddingTop, points, "padding_top") }
    func settingsSetWindowPaddingBottom(_ points: Double) { setPadding(.AppearancePaddingBottom, points, "padding_bottom") }
    /// The top inset of a window with its title bar hidden.
    func settingsSetTitlelessPaddingTop(_ points: Double) { setPadding(.AppearanceTitlelessPaddingTop, points, "titleless_padding_top") }

    private func setPadding(_ key: Ubiquitty.Preferences.Key, _ points: Double, _ schemaKey: String) {
        setSetting(key, double: Ubiquitty.Preferences.Schema.clampToRange(points, "appearance", schemaKey))
    }

    func settingsSetSquareBottomCorners(_ isSquare: Bool) { setSetting(.AppearanceSquareBottomCorners, bool: isSquare) }
    func settingsSetFolderIcon(_ isShown: Bool) { setSetting(.AppearanceFolderIcon, bool: isShown) }
    func settingsSetFolderIconAlways(_ isShown: Bool) { setSetting(.AppearanceFolderIconAlways, bool: isShown) }
    func settingsSetProcessIcons(_ isShown: Bool) { setSetting(.AppearanceProcessIcons, bool: isShown) }

    // MARK: - Appearance pane

    /// 0 none, 1 deuteranopia, 2 protanopia, 3 tritanopia.
    func settingsSetColorblindMode(_ mode: Int) {
        guard let parsed = Ubiquitty.Preferences.colorblindModeFromInt(Int32(clamping: mode)).value else { return }
        setSetting(.AppearanceColorblindMode, text: String(cString: Ubiquitty.Preferences.colorblindModeToString(parsed)))
    }

    func settingsSetCursorShape(_ shape: Int) {
        guard let parsed = Ubiquitty.Preferences.cursorShapeFromInt(Int32(clamping: shape)).value else { return }
        setSetting(.CursorShape, text: String(cString: Ubiquitty.Preferences.cursorShapeToString(parsed)))
        // Picked in the settings pane, so both shells hand the style back rather
        // than seeding under a DECSCUSR that outranks the pick.
        TerminalWindowController.applyPickedCursorShapeToOpenWindows()
    }

    func settingsSetCursorMotion(_ mode: Int) {
        guard let parsed = Ubiquitty.Preferences.cursorMotionFromInt(Int32(clamping: mode)).value else { return }
        setSetting(.CursorMotion, text: String(cString: Ubiquitty.Preferences.cursorMotionToString(parsed)))
    }

    /// 0 themed, 1 native.
    func settingsSetTitlebarStyle(_ style: Int) {
        guard let parsed = Ubiquitty.Preferences.titlebarStyleFromInt(Int32(clamping: style)).value else { return }
        setSetting(.AppearanceTitlebarStyle, text: String(cString: Ubiquitty.Preferences.titlebarStyleToString(parsed)))
    }

    func settingsSetCursorBlink(_ isOn: Bool) { setSetting(.CursorBlink, bool: isOn) }
    func settingsSetCursorLinger(_ frames: Int) { setSetting(.CursorLinger, int: Self.clamp(frames, "cursor", "linger")) }
    func settingsSetCursorBlinkRate(_ milliseconds: Int) {
        setSetting(.CursorBlinkRate, int: Self.clamp(milliseconds, "cursor", "blink_rate"))
    }
    func settingsSetCursorAlpha(_ alpha: Int) { setSetting(.CursorAlpha, int: Self.clamp(alpha, "cursor", "alpha")) }
    func settingsSetBellAudible(_ isOn: Bool) { setSetting(.BellAudible, bool: isOn) }
    func settingsSetBellVisual(_ isOn: Bool) { setSetting(.BellVisual, bool: isOn) }

    func settingsSetColorSpaceP3(_ isP3: Bool) {
        setSetting(.AppearanceColorSpace, text: String(cString: Ubiquitty.Preferences.colorSpaceToString(isP3 ? .DisplayP3 : .SRGB)))
    }

    /// The segmented control's row through Core's map; a row out of range is
    /// sRGB rather than any nonzero row reading as P3.
    func settingsSetColorSpaceIndex(_ index: Int) {
        let space = Ubiquitty.Preferences.colorSpaceFromInt(Int32(clamping: index)).value ?? .SRGB
        settingsSetColorSpaceP3(space == .DisplayP3)
    }

    func settingsSetPaneTitleBars(_ isOn: Bool) { setSetting(.AppearancePaneTitleBars, bool: isOn) }
    func settingsSetSnapWindowResize(_ isOn: Bool) { setSetting(.AppearanceSnapWindowResize, bool: isOn) }
    /// Read live at the next column switch, so the write alone takes effect.
    func settingsSetColumnModeResizesWindow(_ isOn: Bool) { setSetting(.TerminalColumnModeResizesWindow, bool: isOn) }
    func settingsSetBlinkAnimation(_ isOn: Bool) { setSetting(.AppearanceBlinkAnimation, bool: isOn) }
    func settingsSetHideTitleBar(_ isOn: Bool) { setSetting(.AppearanceHideTitleBar, bool: isOn) }

    // MARK: - Tabs, notifications and advanced

    /// 0 off, 1 always, 2 while ⌘ is held; a row out of range is always.
    func settingsSetTabShortcutHintMode(_ mode: Int) {
        let hints = Ubiquitty.Preferences.tabShortcutHintsFromInt(Int32(clamping: mode)).value ?? .Always
        setSetting(.TabsShowShortcuts, text: String(cString: Ubiquitty.Preferences.tabShortcutHintsToString(hints)))
    }

    func settingsSetNotificationsEnabled(_ isOn: Bool) { setSetting(.NotificationsEnabled, bool: isOn) }
    func settingsSetNotificationSound(_ isOn: Bool) { setSetting(.NotificationsSound, bool: isOn) }
    func settingsSetAutoInstallHost(_ isOn: Bool) { setSetting(.RemoteAutoInstallHost, bool: isOn) }
    func settingsSetDockBounce(_ isOn: Bool) { setSetting(.DockBounce, bool: isOn) }
    /// The updater follows the write through its own configuration subscription.
    func settingsSetCheckForUpdatesAutomatically(_ isOn: Bool) { setSetting(.UpdatesCheckAutomatically, bool: isOn) }

    func settingsSetDockBadge(_ isOn: Bool) {
        setSetting(.DockBadge, bool: isOn)
        // Cleared at once when turned off.
        if !isOn { NSApp.dockTile.badgeLabel = nil }
    }

    func settingsSetSecureKeyboardEntry(_ isOn: Bool) {
        setSetting(.SecuritySecureKeyboardEntry, bool: isOn)
        applySecureKeyboardEntry()
    }

    /// Every live terminal takes the heuristic's new value through the same
    /// fold a configuration reload applies.
    func settingsSetPasswordDetect(_ isOn: Bool) { setSetting(.SecurityPasswordDetect, bool: isOn) }

    func settingsSetSecureKeyboardEntry(atPasswordPrompts isOn: Bool) {
        setSetting(.SecuritySecureKeyboardEntryAtPasswordPrompts, bool: isOn)
        applySecureKeyboardEntry()
    }

    func settingsSetSessionPersistence(_ isOn: Bool) { setSetting(.ExperimentalSessionPersistence, bool: isOn) }
    func settingsSetCursorInvertText(_ isOn: Bool) { setSetting(.CursorInvertText, bool: isOn) }

    func settingsTermProgram() -> String? { optionalText(values.termProgram.value) }
    func settingsSetTermProgram(_ program: String) { setSetting(.TermProgram, text: program) }
    func settingsTermProgramVersion() -> String? { optionalText(values.termProgramVersion.value) }
    func settingsSetTermProgramVersion(_ version: String) { setSetting(.TermVersion, text: version) }

    /// The input encoding's canonical name, or nil when unset or unrecognized,
    /// which is the UTF-8 default; an alias reads back as its canonical name so
    /// the picker matches one of its entries.
    func settingsEncoding() -> String? {
        guard let name = optionalText(values.encoding.value) else { return nil }
        guard let encoding = name.withCString({ Ubiquitty.Unicode.encodingFromName(std.string_view($0)) }).value else { return nil }
        return String(cString: Ubiquitty.Unicode.encodingName(encoding))
    }

    /// UTF-8, or an empty or unknown name, clears the override so it reads
    /// back as the default.
    func settingsSetEncoding(_ name: String) {
        let encoding = name.isEmpty ? nil : name.withCString({ Ubiquitty.Unicode.encodingFromName(std.string_view($0)) }).value
        let canonical = encoding.flatMap { $0 == .UTF8 ? nil : String(cString: Ubiquitty.Unicode.encodingName($0)) } ?? ""
        setSetting(.TerminalEncoding, text: canonical)
    }

    /// The picker's encodings in display order, UTF-8 first, each spelled as
    /// Core's table spells it.
    ///
    /// Every name round-trips through Core's parser, so the picker shows Core's
    /// canonical spelling and cannot offer a name Core would refuse.
    func settingsEncodingNames() -> [String] {
        let order = [
            "utf-8", "latin1", "iso-8859-15", "windows-1252", "koi8-r", "shift_jis", "euc-jp", "euc-kr", "gb18030", "big5",
        ]
        return order.compactMap { name in
            guard let encoding = name.withCString({ Ubiquitty.Unicode.encodingFromName(std.string_view($0)) }).value else {
                return nil
            }
            return String(cString: Ubiquitty.Unicode.encodingName(encoding))
        }
    }

    // MARK: - Themes

    /// Every registered theme's name, built-ins first, indexed as the registry
    /// is.
    func settingsThemeNames() -> [String] {
        (0..<Ubiquitty.Themes.count())
            .map { index in
                guard let theme = Ubiquitty.Themes.get(index), let name = theme.pointee.name else { return "" }
                return String(cString: name)
            }
    }

    /// Every manual theme pick — the palette, the settings pane, the theme menu —
    /// is handed to the runtime here, so none can carry it out differently.
    func settingsSelectTheme(_ index: Int) {
        runtime?.selectTheme(Int32(clamping: index), .Manual)
    }

    /// Writes a theme's block, creating it or replacing the one by its name.
    ///
    /// A rename moves the appearance settings and profiles naming the old theme
    /// with it. The colors are packed 0xRRGGBBAA.
    ///
    /// - Parameters:
    ///   - name: The theme's name.
    ///   - originalName: The name it is saved over, for a rename; nil for a new
    ///     theme or one saved under its own name.
    ///   - isDark: Whether the theme is dark.
    ///   - ansi: The 16 ANSI colors.
    ///   - foreground: The foreground color.
    ///   - background: The background color.
    ///   - cursor: The cursor color.
    ///   - select: Whether the saved theme becomes the active one.
    func settingsSaveThemeNamed(
        _ name: String,
        replacingName originalName: String?,
        isDark: Bool,
        ansi: [UInt32],
        foreground: UInt32,
        background: UInt32,
        cursor: UInt32,
        select: Bool
    ) {
        guard !name.isEmpty, ansi.count >= 16 else {
            NSSound.beep()
            return
        }
        var colors = Ubiquitty.Themes.PackedThemeColors()
        colors.foreground = foreground
        colors.background = background
        colors.cursor = cursor
        for index in 0..<16 { colors.setANSI(Int32(index), ansi[index]) }
        let document = Ubiquitty.Themes.documentSavingTheme(
            Ubiquitty.Preferences.liveDocument().pointee,
            values,
            std.string(name),
            std.string(originalName ?? name),
            isDark,
            colors
        )
        configureEditedDocument(document)
        settleSettingsDocumentEdit()
        let values = values
        rebuildThemeMenu()
        let index = name.withCString { Ubiquitty.Themes.indexForName($0) }
        if select {
            if index >= 0 { settingsSelectTheme(Int(index)) }
        } else if Ubiquitty.Preferences.Effective.followSystemAppearance(values) {
            applySystemAppearanceThemeIfEnabled()
        } else if values.themeName.value.map({ String($0) }) == name {
            if index >= 0 { applyThemeToOpenWindows(at: Int(index)) }
        }
    }

    /// Removes a theme's block; a built-in theme has none and is unaffected.
    func settingsDeleteThemeNamed(_ name: String) {
        guard !name.isEmpty else { return }
        configureEditedDocument(
            Ubiquitty.Preferences.removeNamedBlock(Ubiquitty.Preferences.liveDocument().pointee, "themes", std.string(name))
        )
        settleSettingsDocumentEdit()
        rebuildThemeMenu()
    }

    /// File ▸ Import Theme…: a Ubiquitty, iTerm2 or Ghostty theme file, saved
    /// as a theme block by the editor's own write and applied.
    @objc
    func importTheme(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Ubiquitty (.toml), iTerm2 (.itermcolors), or Ghostty theme file."
        panel.prompt = "Import"
        // iTerm2 presets are XML property lists and Ghostty themes plain text,
        // commonly without an extension. No .itermcolors type is registered, so
        // those match through the generic data type.
        panel.allowedContentTypes = [.plainText, .data, .propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            NSSound.beep()
            return
        }
        var bytes = std.string()
        for byte in data { bytes.push_back(CChar(bitPattern: byte)) }
        let imported = Ubiquitty.SwiftBridge.importTheme(bytes)
        guard imported.ok else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Import the Theme"
            alert.informativeText =
                "The file isn’t a Ubiquitty, iTerm2 (.itermcolors), or Ghostty theme, "
                + "or it’s missing one or more of the 16 ANSI colors. Choose another theme file."
            alert.runModal()
            return
        }
        // The file's own name for the theme, else the file name without its
        // extension, else "Imported".
        var name = imported.name.empty() ? url.deletingPathExtension().lastPathComponent : String(imported.name)
        if name.isEmpty { name = "Imported" }
        let ansi = (0..<16).map { imported.ansiColor(Int32($0)) }
        settingsSaveThemeNamed(
            name,
            replacingName: nil,
            isDark: imported.isDark,
            ansi: ansi,
            foreground: imported.foreground,
            background: imported.background,
            cursor: imported.cursor,
            select: true
        )
    }

    // MARK: - Key bindings

    /// The live [keys] specs, in file order, aligned with
    /// `settingsKeyBindingActions`.
    func settingsKeyBindingSpecs() -> [String] { values.keyBindings.map { String($0.spec) } }

    func settingsKeyBindingActions() -> [String] { values.keyBindings.map { String($0.action) } }

    /// Whether `spec` parses to a chord sequence and `action` to a binding
    /// action, which gates the editor's Save button.
    func settingsValidateKeySpec(_ spec: String, action: String) -> Bool {
        Ubiquitty.SwiftBridge.isValidKeyBinding(std.string(spec), std.string(action))
    }

    /// Replaces the whole [keys] table; every live terminal view rebuilds its
    /// binding table. The two arrays must be the same length.
    func settingsSetKeyBindingSpecs(_ specs: [String], actions: [String]) {
        guard specs.count == actions.count else {
            NSSound.beep()
            return
        }
        var bindings = Ubiquitty.SwiftBridge.TextLines()
        for (spec, action) in zip(specs, actions) where !spec.isEmpty && !action.isEmpty {
            bindings.push_back(Ubiquitty.SwiftBridge.keyBindingLine(std.string(spec), std.string(action)))
        }
        configureEditedDocument(Ubiquitty.Preferences.rewriteKeysSection(Ubiquitty.Preferences.liveDocument().pointee, bindings))
        NotificationCenter.default.post(name: Notification.Name(KeyBindingNotice.didChangeNotificationName), object: nil)
    }

    // MARK: - Profiles and tags

    /// The configured profiles, each a dictionary holding only the fields it
    /// sets; `scope` is 0 local, 1 synced, 2 ephemeral.
    func settingsProfiles() -> [[String: Any]] {
        values.profiles.map { profile in
            var dictionary: [String: Any] = ["name": String(profile.name)]
            if let scope = profile.scope.value { dictionary["scope"] = Int(Ubiquitty.Preferences.profileScopeToInt(scope)) }
            if let parent = profile.parentProfile.value { dictionary["parentProfile"] = String(parent) }
            if let theme = profile.themeName.value { dictionary["theme"] = String(theme) }
            if let family = profile.fontFamily.value { dictionary["fontFamily"] = String(family) }
            if let family = profile.fallbackFont.value { dictionary["fallbackFont"] = String(family) }
            if let size = profile.fontSize.value { dictionary["fontSize"] = size }
            if let spacing = profile.lineSpacing.value { dictionary["lineSpacing"] = spacing }
            if let padding = profile.paddingLeft.value { dictionary["paddingLeft"] = padding }
            if let padding = profile.paddingRight.value { dictionary["paddingRight"] = padding }
            if let padding = profile.paddingTop.value { dictionary["paddingTop"] = padding }
            if let padding = profile.titlelessPaddingTop.value { dictionary["titlelessPaddingTop"] = padding }
            if let padding = profile.paddingBottom.value { dictionary["paddingBottom"] = padding }
            if let hidden = profile.hideTitleBar.value { dictionary["hideTitleBar"] = hidden }
            if let behaviour = profile.processExit.value { dictionary["processExit"] = String(behaviour) }
            if let host = profile.startupHost.value { dictionary["startupHost"] = String(host) }
            return dictionary
        }
    }

    // A profile from a settings dictionary; only the keys present are set.
    private static func profile(from dictionary: [String: Any]) -> Ubiquitty.Preferences.Profile {
        var profile = Ubiquitty.Preferences.Profile()
        profile.name = std.string(dictionary["name"] as? String ?? "")
        func text(_ key: String) -> String? {
            guard let value = dictionary[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> Double? { (dictionary[key] as? NSNumber)?.doubleValue }
        if let parent = text("parentProfile") { profile.parentProfile = .init(std.string(parent)) }
        // The picker's row through Core's map: a row out of range is Local.
        if let scope = dictionary["scope"] as? NSNumber {
            profile.scope = .init(Ubiquitty.Preferences.profileScopeFromInt(scope.int32Value))
        }
        if let theme = text("theme") { profile.themeName = .init(std.string(theme)) }
        if let family = text("fontFamily") { profile.fontFamily = .init(std.string(family)) }
        if let family = text("fallbackFont") { profile.fallbackFont = .init(std.string(family)) }
        if let size = number("fontSize") { profile.fontSize = .init(size) }
        if let spacing = number("lineSpacing") { profile.lineSpacing = .init(spacing) }
        if let padding = number("paddingLeft") { profile.paddingLeft = .init(padding) }
        if let padding = number("paddingRight") { profile.paddingRight = .init(padding) }
        if let padding = number("paddingTop") { profile.paddingTop = .init(padding) }
        if let padding = number("titlelessPaddingTop") { profile.titlelessPaddingTop = .init(padding) }
        if let padding = number("paddingBottom") { profile.paddingBottom = .init(padding) }
        if let hidden = dictionary["hideTitleBar"] as? NSNumber { profile.hideTitleBar = .init(hidden.boolValue) }
        if let behaviour = dictionary["processExit"] as? String { profile.processExit = .init(std.string(behaviour)) }
        if let host = dictionary["startupHost"] as? String { profile.startupHost = .init(std.string(host)) }
        return profile
    }

    /// The configured tags, in file order: `index`, `name`, `color`,
    /// `matchHost`, `matchProfile`, `prominence`, `icon`, `iconWeight`,
    /// `showName`, `showInTitleBar`, `showInTabs` and `showInPaneHeaders`
    /// each.
    ///
    /// `index` is the rule's position among the `[[tags]]` blocks, which is
    /// how a save, a delete or a move addresses it: an untitled rule has no
    /// name to be found by. Every field the entry carries crosses, because a
    /// save writes the whole block back and a field left out here is dropped
    /// from the file.
    func settingsTags() -> [[String: Any]] {
        values.tags.enumerated()
            .map { index, tag in
                [
                    "index": index,
                    "name": String(tag.name),
                    "color": String(tag.color),
                    "matchHost": String(tag.matchHost),
                    "matchProfile": String(tag.matchProfile),
                    "prominence": String(tag.prominence),
                    "icon": String(tag.icon),
                    "iconWeight": String(tag.iconWeight),
                    "showName": tag.showsName,
                    "showInTitleBar": tag.showsInTitleBar,
                    "showInTabs": tag.showsInTabs,
                    "showInPaneHeaders": tag.showsInPaneHeaders,
                ]
            }
    }

    /// A Core tag entry from a settings dictionary; a `show*` key left out
    /// keeps Core's default, which is on.
    private static func tagEntry(from tag: [String: Any]) -> Ubiquitty.Preferences.TagEntry {
        var entry = Ubiquitty.Preferences.TagEntry()
        entry.name = std.string((tag["name"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        entry.color = std.string((tag["color"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        entry.matchHost = std.string(tag["matchHost"] as? String ?? "")
        entry.matchProfile = std.string(tag["matchProfile"] as? String ?? "")
        entry.prominence = std.string(tag["prominence"] as? String ?? "")
        entry.icon = std.string((tag["icon"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        entry.iconWeight = std.string(tag["iconWeight"] as? String ?? "")
        if let shows = tag["showName"] as? Bool { entry.showsName = shows }
        if let shows = tag["showInTitleBar"] as? Bool { entry.showsInTitleBar = shows }
        if let shows = tag["showInTabs"] as? Bool { entry.showsInTabs = shows }
        if let shows = tag["showInPaneHeaders"] as? Bool { entry.showsInPaneHeaders = shows }
        return entry
    }

    /// Whether Core accepts a tag dictionary as a rule: a title, a colour, or
    /// both (`Session::isValidTagRule`).
    func settingsIsValidTag(_ tag: [String: Any]) -> Bool {
        Ubiquitty.Session.isValidTagRule(Self.tagEntry(from: tag))
    }

    /// Writes a tag's block at its position, or appends a new one.
    ///
    /// - Parameters:
    ///   - tag: The tag's fields.
    ///   - index: The rule's position from ``settingsTags()``, or -1 for a new
    ///     rule.
    func settingsSaveTag(_ tag: [String: Any], at index: Int) {
        let entry = Self.tagEntry(from: tag)
        guard Ubiquitty.Session.isValidTagRule(entry) else {
            NSSound.beep()
            return
        }
        configureEditedDocument(
            Ubiquitty.Session.writeTagRule(Ubiquitty.Preferences.liveDocument().pointee, Int32(index), entry)
        )
        settleSettingsDocumentEdit()
    }

    /// Removes the tag rule at a position from ``settingsTags()``.
    func settingsDeleteTag(at index: Int) {
        guard index >= 0 else { return }
        configureEditedDocument(
            Ubiquitty.Session.removeTagRule(Ubiquitty.Preferences.liveDocument().pointee, Int32(index))
        )
        settleSettingsDocumentEdit()
    }

    /// Moves the tag rule at a position from ``settingsTags()`` to another,
    /// the rules between shifting one place.
    ///
    /// Rules draw in file order, so this is what puts one tag ahead of
    /// another on every window. Core moves the block as written, its comments
    /// and every key with it (`Session::moveTagRule`).
    ///
    /// - Parameters:
    ///   - from: The rule's position.
    ///   - to: The position it takes.
    func settingsMoveTag(from: Int, to: Int) {
        let count = values.tags.count
        guard from != to, (0..<count).contains(from), (0..<count).contains(to) else { return }
        configureEditedDocument(
            Ubiquitty.Session.moveTagRule(Ubiquitty.Preferences.liveDocument().pointee, Int32(from), Int32(to))
        )
        settleSettingsDocumentEdit()
    }

    /// Writes a profile's block, creating it or replacing the one by its name.
    func settingsSaveProfile(_ dictionary: [String: Any]) {
        guard let name = dictionary["name"] as? String, !name.isEmpty else {
            NSSound.beep()
            return
        }
        let profile = Self.profile(from: dictionary)
        // The serializer leaves out the newline the splicer expects ahead of an
        // appended block; the splicer strips it again on an in-place replace.
        let block = std.string("\n") + Ubiquitty.Preferences.serializeProfile(profile)
        configureEditedDocument(
            Ubiquitty.Preferences.spliceNamedBlock(Ubiquitty.Preferences.liveDocument().pointee, "profiles", profile.name, block)
        )
        settleSettingsDocumentEdit()
        rebuildProfilesMenu()
    }

    /// Names references that would change meaning if the profile disappeared.
    func settingsProfileDeletionReferences(_ name: String) -> [String] {
        let values = Ubiquitty.Preferences.values().pointee
        var references = values.profiles.compactMap { profile -> String? in
            guard String(profile.parentProfile.value ?? std.string()) == name else { return nil }
            return "Profile: " + String(profile.name)
        }
        for tag in values.tags where String(tag.matchProfile) == name {
            references.append("Tag: " + String(tag.name))
        }
        if NSApp.windows.contains(where: {
            guard let controller = $0.windowController as? TerminalWindowController else { return false }
            return !controller.isWindowClosed && controller.appliedProfileName == name
        }) {
            references.append("Open terminal windows")
        }
        references += SessionLayout.allSessions()
            .compactMap { session in
                let usesProfile = session.groups.contains { group in
                    group.tabs.contains { tab in
                        tab.paneLayout.flatMap(SavedTerminalPresentation.decoded)?.profileName == name
                    }
                }
                return usesProfile ? "Saved workspace: " + session.name : nil
            }
        return Array(Set(references)).sorted()
    }

    func settingsDeleteProfileNamed(_ name: String) {
        guard !name.isEmpty, settingsProfileDeletionReferences(name).isEmpty else { return }
        configureEditedDocument(
            Ubiquitty.Preferences.removeNamedBlock(Ubiquitty.Preferences.liveDocument().pointee, "profiles", std.string(name))
        )
        settleSettingsDocumentEdit()
        rebuildProfilesMenu()
    }

    // MARK: - Agent tokens

    /// The daemon's capability tokens: `id`, `idShort`, `label`, `scope` and
    /// `expiry` each.
    ///
    /// The store is the daemon's tokens file in the control directory, one
    /// record per line; Core reads each record and decides its expiry.
    func settingsAgentTokens() -> [[String: Any]] {
        let environment = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"] ?? ""
        let controlDirectory = environment.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent(".ubiquitty") : environment
        guard let text = try? String(contentsOfFile: (controlDirectory as NSString).appendingPathComponent("tokens"), encoding: .utf8),
            !text.isEmpty
        else { return [] }
        let now = UInt64(Date().timeIntervalSince1970)
        var lines = Ubiquitty.SwiftBridge.TextLines()
        for line in text.components(separatedBy: "\n") { lines.push_back(std.string(line)) }
        return Ubiquitty.SwiftBridge.listAgentTokens(lines, now)
            .map { token in
                let identifier = String(token.identifier)
                return [
                    "id": identifier,
                    "idShort": String(identifier.prefix(16)),
                    "label": String(token.label),
                    "scope": String(token.scope),
                    "expiry": String(token.expiry),
                ]
            }
    }

    // The bundled daemon, else a development tree's; nil when neither runs.
    private func agentHostBinaryPath() -> String? {
        let bundled = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Helpers/ubiquitty-host")
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return ShareSessionSupport.localHostBinaryPath()
    }

    // Runs `ubiquitty-host token <arguments>`, keeping its output and its
    // errors apart.
    //
    // - Returns: The exit status, or -1 when the tool could not launch.
    private func runAgentToken(_ arguments: [String], output: inout String, errors: inout String) -> Int32 {
        guard let host = agentHostBinaryPath() else {
            errors = "ubiquitty-host isn’t bundled (build without --no-helpers)."
            return -1
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: host)
        task.arguments = ["token"] + arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
        } catch {
            errors = error.localizedDescription
            return -1
        }
        // The output is tiny — a 64-character secret and a status line — so
        // reading to the end before waiting cannot fill a pipe and deadlock.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        errors = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return task.terminationStatus
    }

    /// Issues a token and returns its secret, which the reader sees exactly
    /// once.
    ///
    /// - Parameters:
    ///   - label: The token's label; empty for none.
    ///   - scope: A comma-separated scope list; empty for the default.
    ///   - error: Receives the reason when nothing was issued.
    /// - Returns: The plaintext secret, or nil.
    func settingsIssueAgentToken(withLabel label: String, scope: String, error: inout NSString?) -> String? {
        var arguments = ["issue"]
        if !scope.isEmpty { arguments += ["--scope", scope] }
        if !label.isEmpty { arguments += ["--label", label] }
        var output = ""
        var errors = ""
        let status = runAgentToken(arguments, output: &output, errors: &errors)
        guard status == 0, !output.isEmpty else {
            error = (errors.isEmpty ? "token issue failed." : errors) as NSString
            return nil
        }
        return output
    }

    /// Revokes a token by its identifier.
    ///
    /// - Returns: False, with the reason in `error`, when it was not revoked.
    func settingsRevokeAgentToken(_ tokenID: String, error: inout NSString?) -> Bool {
        guard !tokenID.isEmpty else {
            error = "no token id."
            return false
        }
        var output = ""
        var errors = ""
        guard runAgentToken(["revoke", tokenID], output: &output, errors: &errors) == 0 else {
            error = (errors.isEmpty ? "token revoke failed." : errors) as NSString
            return false
        }
        return true
    }

    // MARK: - Platform overrides

    /// The global configuration's values for the fields a platform section can
    /// override, keyed by the field tokens.
    func settingsPlatformBaseValues() -> [String: Any] {
        Self.platformFields(Ubiquitty.Preferences.profileFromValues(values, "Default"))
    }

    /// One platform section's overrides: 0 [mac], 1 [linux]; empty for any
    /// other index.
    func settingsPlatformOverrides(forPlatform platform: Int) -> [String: Any] {
        guard let platform = Self.platform(at: platform) else { return [:] }
        return Self.platformFields(Ubiquitty.Preferences.platformOverrideProfile(values, platform).pointee)
    }

    /// Sets one field of a platform section, or removes it when `value` is nil,
    /// then applies it live when the section is this build's platform.
    func settingsSetPlatformOverride(_ platform: Int, field: String, value: Any?) {
        guard let resolved = Self.platform(at: platform) else {
            NSSound.beep()
            return
        }
        let text = value as? String ?? ""
        let number = (value as? NSNumber)?.doubleValue ?? (text as NSString).doubleValue
        guard
            Ubiquitty.SwiftBridge.editPlatformOverride(
                resolved == .Mac ? .Mac : .Linux,
                std.string(field),
                value == nil ? .Remove : .Set,
                std.string(text),
                number
            )
        else {
            NSSound.beep()
            return
        }
        settleSettingsDocumentEdit()
        if resolved == Ubiquitty.Preferences.currentPlatform() { applyAllPersistedSettings() }
    }

    private static func platform(at index: Int) -> Ubiquitty.Preferences.Platform? {
        switch index {
        case 0: .Mac
        case 1: .Linux
        default: nil
        }
    }

    // A profile's set fields under the platform field tokens.
    private static func platformFields(_ profile: Ubiquitty.Preferences.Profile) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        if let theme = profile.themeName.value { dictionary["theme"] = String(theme) }
        if let family = profile.fontFamily.value { dictionary["fontFamily"] = String(family) }
        if let family = profile.fallbackFont.value { dictionary["fallbackFont"] = String(family) }
        if let size = profile.fontSize.value { dictionary["fontSize"] = size }
        if let spacing = profile.lineSpacing.value { dictionary["lineSpacing"] = spacing }
        if let padding = profile.paddingLeft.value { dictionary["paddingLeft"] = padding }
        if let padding = profile.paddingRight.value { dictionary["paddingRight"] = padding }
        if let padding = profile.paddingTop.value { dictionary["paddingTop"] = padding }
        if let padding = profile.titlelessPaddingTop.value { dictionary["titlelessPaddingTop"] = padding }
        if let padding = profile.paddingBottom.value { dictionary["paddingBottom"] = padding }
        if let host = profile.startupHost.value { dictionary["startupHost"] = String(host) }
        return dictionary
    }
}
