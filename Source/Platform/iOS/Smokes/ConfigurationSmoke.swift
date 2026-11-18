// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyKit

/// Whether this shell draws what its stored configuration document says, and
/// whether its settings sheet's write is a by-key edit of that document.
///
/// The shell read nothing at launch and built its panes with the renderer
/// type's own defaults over a font kept in its own store, so a document naming
/// a size, a colour space or padding drew none of them. The document goes in
/// the way a reader's would — the app's stored copy, loaded by the launch
/// path — and the witness is the pane the app builds.
enum ConfigurationSmokeEntry {
    @MainActor
    static func run() -> Bool {
        let original = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer { _ = Ubiquitty.Preferences.configureOwnDocument(std.string(original)) }

        // Stored, then forgotten, then loaded by the launch path.
        let stored = "[font]\nsize = 21.0\n[appearance]\ncolor_space = \"display-p3\"\npadding_left = 19.0\n"
        _ = Ubiquitty.Preferences.configureOwnDocument(std.string(stored))
        _ = Ubiquitty.Preferences.configure(std.string(), .Permissive)
        StoredConfiguration.load()
        guard String(Ubiquitty.Preferences.liveDocument().pointee) == stored else {
            return failed("the launch path did not configure Core from the stored document")
        }

        let settings = AppSettingsModel()
        guard settings.fontPointSize == 21 else { return failed("settings without a connection ignored the stored font") }
        let model = TerminalSessionModel()
        guard let surface = model.surfaceForDrawing() else {
            return failed("Core declined a surface")
        }
        guard surface.zoomedPointSize == 21 else {
            return failed("the pane draws at \(surface.zoomedPointSize) pt where the document names 21")
        }
        guard surface.metalLayer.colorspace?.name == CGColorSpace.displayP3 else {
            return failed("the pane's layer is not tagged Display P3 though the document names it")
        }
        guard surface.gridFitBoxForTesting?.insets.left == 19 else {
            return failed("the pane's grid does not take the document's left padding")
        }
        guard paddingFollowsSettings(settings, surface: surface) else { return false }

        // The settings sheet's write, round-tripped: the live document carries
        // the key, the stored copy is that same document, and the open pane
        // redraws at the new size through the configuration subscription.
        let otherModel = TerminalSessionModel()
        guard let otherSurface = otherModel.surfaceForDrawing() else { return failed("Core declined the second surface") }
        settings.selectFont(pointSize: 17)
        let live = String(Ubiquitty.Preferences.liveDocument().pointee)
        guard live.contains("size = 17.0") else {
            return failed("the size write did not land in the live document")
        }
        guard let path = Ubiquitty.Preferences.filePath().value.map({ String($0) }),
            (try? String(contentsOfFile: path, encoding: .utf8)) == live
        else {
            return failed("the stored document is not the live one after the write")
        }
        guard surface.zoomedPointSize == 17 else {
            return failed("the open pane stayed at \(surface.zoomedPointSize) pt after the write")
        }
        guard otherSurface.zoomedPointSize == 17 else { return failed("the other connection did not follow app settings") }
        settings.number(.FontLineSpacing).wrappedValue = 0
        guard let originalCell = surface.gridFitBoxForTesting?.cell,
            let otherOriginalCell = otherSurface.gridFitBoxForTesting?.cell
        else { return failed("the panes have no font geometry") }
        settings.number(.FontLineSpacing).wrappedValue = 5
        guard surface.typographyForTesting?.lineSpacingInPoints == 5,
            otherSurface.typographyForTesting?.lineSpacingInPoints == 5,
            String(Ubiquitty.Preferences.liveDocument().pointee).contains("line_spacing = 5.0")
        else { return failed("line spacing did not reach every open pane and the saved settings") }
        guard let spacedCell = surface.gridFitBoxForTesting?.cell,
            let otherSpacedCell = otherSurface.gridFitBoxForTesting?.cell,
            spacedCell.height >= originalCell.height + 4.5,
            otherSpacedCell.height >= otherOriginalCell.height + 4.5,
            spacedCell.width == originalCell.width,
            otherSpacedCell.width == otherOriginalCell.width
        else { return failed("line spacing did not increase the actual terminal row height") }
        _ = Ubiquitty.Preferences.configure(std.string(), .Permissive)
        StoredConfiguration.load()
        guard settings.value(.FontLineSpacing).number == 5,
            surface.gridFitBoxForTesting?.cell == spacedCell
        else { return failed("line spacing did not survive reloading the saved settings") }
        settings.write(.AppearanceFollowSystem, .ofBool(.Bool, true))
        settings.write(.AppearanceSystemLightTheme, .ofText(.String, std.string("Noir Clair")))
        settings.write(.AppearanceSystemDarkTheme, .ofText(.String, std.string("Noir")))
        model.setSystemAppearance(isDark: false)
        otherModel.setSystemAppearance(isDark: true)
        guard !model.isGroundDark, otherModel.isGroundDark else { return failed("the system theme pair was not applied") }
        let darkName = TerminalSurface.themeNames.first { name in
            guard let index = TerminalSurface.themeNames.firstIndex(of: name) else { return false }
            return Ubiquitty.Themes.isThemeDark(Int32(index))
        }
        guard let darkName else { return failed("no dark theme is registered") }
        model.selectTheme(named: darkName)
        model.setSystemAppearance(isDark: false)
        settings.selectFont(pointSize: 18)
        guard model.isGroundDark else { return failed("an app setting replaced the saved host theme") }
        model.selectTheme(named: "")
        guard !model.isGroundDark else { return failed("clearing the host override did not restore the app theme") }
        let unchanged = String(Ubiquitty.Preferences.liveDocument().pointee)
        guard !settings.saveRange("U+3000-U+2000", family: "Menlo", shouldMatchSize: false, replacing: nil),
            String(Ubiquitty.Preferences.liveDocument().pointee) == unchanged
        else { return failed("an invalid range changed configuration") }
        guard settings.saveRange("U+2426", family: "Menlo", shouldMatchSize: false, replacing: nil),
            let range = settings.fallbackRanges.first(where: { $0.first == 0x2426 }), range.shouldMatchSize == false
        else { return failed("the range editor did not save its size override") }
        settings.remove(range)
        guard !settings.fallbackRanges.contains(where: { $0.first == 0x2426 }) else { return failed("the range was not removed") }
        guard model.accessorySymbols.map(\.capTitle) == TerminalAccessoryKey.symbols.map(\.capTitle) else {
            return failed("the keyboard default differs from the supported symbol table")
        }
        settings.setAccessorySymbols(Array(TerminalAccessoryKey.symbols.suffix(4).reversed()))
        guard model.accessorySymbols.map(\.capTitle).joined() == "}{][",
            otherModel.accessorySymbols.map(\.id) == model.accessorySymbols.map(\.id)
        else { return failed("live keyboards did not follow the reordered symbols") }
        settings.setAccessorySymbols([])
        guard model.accessorySymbols.isEmpty else { return failed("hidden symbols stayed in the keyboard") }
        settings.resetAccessorySymbols()
        guard !settings.hasCustomAccessorySymbols, model.accessorySymbols.count == TerminalAccessoryKey.symbols.count else {
            return failed("reset did not restore the default symbol row")
        }
        settings.optionSendsMeta.wrappedValue = true
        guard Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == .Both else {
            return failed("the Option toggle did not reach input policy")
        }
        settings.optionSendsMeta.wrappedValue = false
        guard Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == .None else {
            return failed("Option remained Meta after turning it off")
        }
        guard sessionTitlesFollowSettings(settings) else { return false }
        do {
            var preview: ReceivedFilePreview? = try ReceivedFilePreview(data: Data("preview".utf8), name: "../../report.txt")
            let url = preview!.url
            guard url.lastPathComponent == "report.txt", (try Data(contentsOf: url)) == Data("preview".utf8) else {
                return failed("the native preview lost the received bytes or filename")
            }
            preview = nil
            guard !FileManager.default.fileExists(atPath: url.path) else { return failed("the preview left a temporary file behind") }
        } catch { return failed("the native preview could not prepare a protected file") }
        return true
    }

    /// The padding page's controls move the open pane's grid, persist in the
    /// stored document, and reset to Core's iOS default of 4 pt on every edge.
    @MainActor
    private static func paddingFollowsSettings(_ settings: AppSettingsModel, surface: TerminalSurface) -> Bool {
        func insets() -> [CGFloat]? {
            surface.gridFitBoxForTesting.map { [$0.insets.top, $0.insets.bottom, $0.insets.left, $0.insets.right] }
        }
        guard let stated = insets(), stated[2] == 19, stated[0] == 4, stated[1] == 4, stated[3] == 4 else {
            return failed("the edges the document leaves unstated are not Core's iOS default of 4 pt: \(insets() ?? [])")
        }
        guard settings.hasCustomPadding, settings.uniformPadding == nil else {
            return failed("the padding page reads a uniform padding over differing edges")
        }
        settings.paddingOnEveryEdge.wrappedValue = 30
        guard insets() == [30, 30, 30, 30], settings.uniformPadding == 30 else {
            return failed("All Edges did not move every edge of the pane's grid: \(insets() ?? [])")
        }
        settings.padding(.AppearancePaddingTop).wrappedValue = 12
        guard insets() == [12, 30, 30, 30], settings.uniformPadding == nil else {
            return failed("the Top control did not move only the top edge: \(insets() ?? [])")
        }
        let live = String(Ubiquitty.Preferences.liveDocument().pointee)
        guard live.contains("padding_top = 12.0"), live.contains("padding_right = 30.0"),
            let path = Ubiquitty.Preferences.filePath().value.map({ String($0) }),
            (try? String(contentsOfFile: path, encoding: .utf8)) == live
        else { return failed("the padding writes did not reach the stored document") }
        _ = Ubiquitty.Preferences.configure(std.string(), .Permissive)
        StoredConfiguration.load()
        guard insets() == [12, 30, 30, 30] else { return failed("the padding did not survive reloading the saved settings") }
        settings.resetPadding()
        guard !settings.hasCustomPadding, insets() == [4, 4, 4, 4], settings.uniformPadding == 4 else {
            return failed("Reset to Default did not return the pane to Core's iOS default of 4 pt: \(insets() ?? [])")
        }
        return true
    }

    @MainActor
    private static func sessionTitlesFollowSettings(_ settings: AppSettingsModel) -> Bool {
        guard settings.titleToggle(.TitleTabDirectory).wrappedValue,
            settings.titleToggle(.TitleTabAppTitle).wrappedValue,
            settings.titleToggle(.TitleTabProcess).wrappedValue,
            !settings.titleToggle(.TitleTabDimensions).wrappedValue
        else { return failed("the title controls disagree with the composer's defaults") }

        let workspace = TerminalSessionModel()
        workspace.seedShowcaseWorkspace()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && workspace.surface(forPane: 1)?.drive.currentDirectory() == nil {
            workspace.surface(forPane: 1)?.serviceIngestEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        workspace.refreshTabTitles()
        guard workspace.tabs.first?.title.contains("ubiquitty") == true else {
            return failed("the title fixture has no working directory")
        }
        settings.titleToggle(.TitleTabDirectory).wrappedValue = false
        guard workspace.tabs.first?.title == "vim notes.md",
            workspace.tabs.first?.paneTitles[1] == "vim notes.md",
            workspace.tabs.last?.title == "deploy"
        else { return failed("hiding the folder did not immediately update automatic titles and preserve custom names") }
        settings.titleToggle(.TitleTabAppTitle).wrappedValue = false
        guard workspace.tabs.first?.title == "Tab 1", workspace.tabs.first?.paneTitles[1] == "Pane 1" else {
            return failed("a title with no visible components lost its fallback name")
        }
        settings.titleToggle(.TitleTabAppTitle).wrappedValue = true
        _ = Ubiquitty.Preferences.configure(std.string(), .Permissive)
        StoredConfiguration.load()
        guard !settings.titleToggle(.TitleTabDirectory).wrappedValue, workspace.tabs.first?.title == "vim notes.md" else {
            return failed("the title components did not survive reloading saved settings")
        }
        settings.titleToggle(.TitleTabDirectory).wrappedValue = true
        guard workspace.tabs.first?.title.contains("ubiquitty") == true else {
            return failed("the working directory did not return when enabled")
        }
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("configuration: FAIL: \(reason)")
        return false
    }
}
