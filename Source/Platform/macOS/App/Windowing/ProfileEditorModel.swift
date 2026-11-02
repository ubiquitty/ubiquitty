// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

internal import CxxStdlib
import Foundation
internal import UbiquittyCore

// A profile edited in the UI. Optionals model "inherit" (unset); the
// bridge omits absent keys from the [[profiles]] block.
/// Holds a profile editor draft and its Core presentation conversion.
package struct Profile: Identifiable {
    package static let presentationFields: [(label: String, key: String)] = [
        ("Theme", "theme"), ("Font", "fontFamily"), ("Fallback Font", "fallbackFont"),
        ("Font Size", "fontSize"), ("Line Spacing", "lineSpacing"),
        ("Left Padding", "paddingLeft"), ("Right Padding", "paddingRight"),
        ("Top Padding", "paddingTop"), ("Titleless Top Padding", "titlelessPaddingTop"),
        ("Bottom Padding", "paddingBottom"), ("Hide Title Bar", "hideTitleBar"),
    ]

    package var id = UUID()
    package var name: String
    package var scope: Int? // 0 local / 1 synced / 2 ephemeral
    package var parentProfile: String?
    package var theme: String?
    package var fontFamily: String?
    package var fallbackFont: String?
    package var fontSize: Double?
    package var lineSpacing: Double?
    package var paddingLeft: Double?
    package var paddingRight: Double?
    package var paddingTop: Double?
    package var titlelessPaddingTop: Double?
    package var paddingBottom: Double?
    package var hideTitleBar: Bool?
    package var startupHost: String?
    package var processExit: String?

    package init(dict: [String: Any]) {
        name = dict["name"] as? String ?? ""
        scope = (dict["scope"] as? NSNumber)?.intValue
        parentProfile = dict["parentProfile"] as? String
        theme = dict["theme"] as? String
        fontFamily = dict["fontFamily"] as? String
        fallbackFont = dict["fallbackFont"] as? String
        fontSize = (dict["fontSize"] as? NSNumber)?.doubleValue
        lineSpacing = (dict["lineSpacing"] as? NSNumber)?.doubleValue
        paddingLeft = (dict["paddingLeft"] as? NSNumber)?.doubleValue
        paddingRight = (dict["paddingRight"] as? NSNumber)?.doubleValue
        paddingTop = (dict["paddingTop"] as? NSNumber)?.doubleValue
        titlelessPaddingTop = (dict["titlelessPaddingTop"] as? NSNumber)?.doubleValue
        paddingBottom = (dict["paddingBottom"] as? NSNumber)?.doubleValue
        hideTitleBar = (dict["hideTitleBar"] as? NSNumber)?.boolValue
        startupHost = dict["startupHost"] as? String
        processExit = dict["processExit"] as? String
    }

    package init(core: Ubiquitty.Preferences.Profile) {
        name = String(core.name)
        scope = core.scope.value.map { Int($0.rawValue) }
        parentProfile = core.parentProfile.value.map { String($0) }
        theme = core.themeName.value.map { String($0) }
        fontFamily = core.fontFamily.value.map { String($0) }
        fallbackFont = core.fallbackFont.value.map { String($0) }
        fontSize = core.fontSize.value
        lineSpacing = core.lineSpacing.value
        paddingLeft = core.paddingLeft.value
        paddingRight = core.paddingRight.value
        paddingTop = core.paddingTop.value
        titlelessPaddingTop = core.titlelessPaddingTop.value
        paddingBottom = core.paddingBottom.value
        hideTitleBar = core.hideTitleBar.value
        startupHost = core.startupHost.value.map { String($0) }
        processExit = core.processExit.value.map { String($0) }
    }

    package init(name: String) {
        self.name = name
        self.scope = 0
    }

    package func dictionary() -> [String: Any] {
        var d: [String: Any] = ["name": name]
        if let scope { d["scope"] = NSNumber(value: scope) }
        if let parentProfile, !parentProfile.isEmpty { d["parentProfile"] = parentProfile }
        if let theme, !theme.isEmpty { d["theme"] = theme }
        if let fontFamily, !fontFamily.isEmpty { d["fontFamily"] = fontFamily }
        if let fallbackFont, !fallbackFont.isEmpty { d["fallbackFont"] = fallbackFont }
        if let fontSize { d["fontSize"] = NSNumber(value: fontSize) }
        if let lineSpacing { d["lineSpacing"] = NSNumber(value: lineSpacing) }
        if let paddingLeft { d["paddingLeft"] = NSNumber(value: paddingLeft) }
        if let paddingRight { d["paddingRight"] = NSNumber(value: paddingRight) }
        if let paddingTop { d["paddingTop"] = NSNumber(value: paddingTop) }
        if let titlelessPaddingTop { d["titlelessPaddingTop"] = NSNumber(value: titlelessPaddingTop) }
        if let paddingBottom { d["paddingBottom"] = NSNumber(value: paddingBottom) }
        if let hideTitleBar { d["hideTitleBar"] = NSNumber(value: hideTitleBar) }
        if let startupHost { d["startupHost"] = startupHost }
        if let processExit { d["processExit"] = processExit }
        return d
    }
}
