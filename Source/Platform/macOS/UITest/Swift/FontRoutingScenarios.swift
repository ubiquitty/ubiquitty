// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import UbiquittyKit
import UbiquittyRenderKit

// FontRoutingScenarios.swift — the configuration keys that steer the font
// route, asserted against the face a code point actually resolves to.
//
// These assert the resolved family rather than the stored setting, because the
// defect they cover was a setting that stored and validated correctly and
// reached no glyph: the macOS app did not link the translation unit that turns
// a configuration into route preferences, so the router assembled its own and
// named two of the six fields.
//
// Each scenario calibrates against the machine's own font inventory: it reads
// the family a code point resolves to with nothing configured, picks a
// DIFFERENT installed family covering the same code point, and asserts the
// setting moved the answer to it. A test naming a fixed family would pass on a
// machine where that family was already the cascade's answer, which is the one
// way a routing test can be green and prove nothing.

/// Registers the font-routing scenarios with the UI-test runner.
///
/// A scenario is a C function pointer, so each closure below carries no
/// context.
enum FontRoutingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_reapplies_an_inherited_profile_without_replacing_the_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift terminal opens")
                    return
                }
                let parent = "Parity parent " + UUID().uuidString
                let child = "Parity child " + UUID().uuidString
                defer {
                    shell.window?.close()
                    app.settingsDeleteProfileNamed(child)
                    app.settingsDeleteProfileNamed(parent)
                }
                t.pump(0.3)
                surface.drive.stopIngest()
                surface.feed(Data("\u{1b}[2J\u{1b}[Hprofile-session-marker".utf8))
                let wanted = surface.drawnFontFamilyForTesting == "Menlo" ? "Courier New" : "Menlo"
                app.settingsSaveProfile([
                    "name": parent, "fontFamily": wanted, "fontSize": NSNumber(value: 19),
                    "theme": "Noir Clair", "lineSpacing": NSNumber(value: 3),
                    "paddingLeft": NSNumber(value: 13), "paddingRight": NSNumber(value: 17),
                    "paddingTop": NSNumber(value: 11), "paddingBottom": NSNumber(value: 9),
                    "titlelessPaddingTop": NSNumber(value: 7),
                    "hideTitleBar": NSNumber(value: true),
                ])
                app.settingsSaveProfile(["name": child, "parentProfile": parent, "startupHost": "unreachable.invalid"])
                shell.applyProfile(named: child)
                t.pump(0.3)
                t.expect(shell.focusedSurfaceForTesting === surface, desc: "profile application keeps the same surface")
                t.expect(
                    surface.gridTextForTesting().contains("profile-session-marker"),
                    desc: "profile application retains terminal contents"
                )
                t.expect(
                    surface.drawnFontFamilyForTesting == wanted && surface.drawnFontPointSizeForTesting == 19,
                    desc: "the existing renderer adopts the inherited font"
                )
                t.expect(surface.typographyForTesting?.lineSpacingInPoints == 3, desc: "the inherited line spacing reaches the renderer")
                t.expect(
                    surface.gridFitBoxForTesting?.insets.left == 13 && surface.gridFitBoxForTesting?.insets.right == 17,
                    desc: "horizontal padding reaches the renderer"
                )
                t.expect(
                    surface.gridFitBoxForTesting?.insets.top == 7 && surface.gridFitBoxForTesting?.insets.bottom == 9,
                    desc: "the inherited titleless and bottom padding reach the renderer"
                )
                t.expect(shell.isTitleBarHiddenForIdentity, desc: "the inherited titlebar choice reaches the window")
                t.expect(shell.appliedProfileName == child, desc: "the title composition retains the selected profile name")
                t.expect((surface.drawnBackgroundForTesting()?.color.x ?? 0) > 0.8, desc: "the frame draws the named light theme")
            }
        }

        UBUITestRegister("swift_shell_osc50_swaps_the_font_and_answers_the_query") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = t.newWindowRunning(["/bin/sh", "-c", "stty raw -echo; printf OSC50-READY; exec /bin/cat"]),
                    let surface = shell.focusedSurfaceForTesting,
                    let opened = surface.drawnFontFamilyForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                guard t.wait(until: { surface.gridTextForTesting().contains("OSC50-READY") }, timeout: 5) else {
                    t.expect(false, desc: "the OSC 50 PTY child is ready")
                    return
                }

                // Before any sequence at all: the query has an answer because
                // the window published what it opened with. Asserted first and
                // separately, because a swap publishes the family too — read
                // after one, this holds whether or not the window ever seeded
                // it, and the entry it stands for is exactly the session that
                // never sees an OSC 50.
                t.expect(
                    surface.publishedFontFamilyForTesting == opened,
                    desc:
                        "a fresh window seeds the query with the face it opened on (holds \(surface.publishedFontFamilyForTesting.debugDescription), draws \(opened))"
                )

                // A family this window is not already drawing, so the swap is a
                // change rather than a no-op the assertion could not tell from
                // a request nobody read.
                let wanted = opened == "Menlo" ? "Courier New" : "Menlo"
                // The raw PTY child echoes both sequences through the ingest
                // loop. A direct model feed raises no drain event, while the
                // login shell's startup can outlast a fixed sleep and swallow
                // a command typed before its first prompt.
                // Both requests leave the PTY in one burst, before the
                // frontend can acknowledge either. The relative step must
                // compose with the preceding absolute request rather than
                // with the font the window opened on.
                let escape = "\u{1b}"
                let terminator = "\(escape)\\"
                surface.send("\(escape)]50;\(wanted):size=17\(terminator)\(escape)]50;#+3\(terminator)")
                _ = t.wait(
                    until: { surface.drawnFontFamilyForTesting == wanted && surface.drawnFontPointSizeForTesting == 20 },
                    timeout: 5
                )
                t.expect(
                    surface.drawnFontFamilyForTesting == wanted,
                    desc:
                        "queued OSC 50 requests keep the requested face (asked \(wanted), draws \(surface.drawnFontFamilyForTesting ?? "nothing"))"
                )
                t.expect(
                    surface.drawnFontPointSizeForTesting == 20,
                    desc:
                        "the relative step composes with size 17 (draws \(surface.drawnFontPointSizeForTesting?.description ?? "nothing")pt)"
                )
                let box = surface.gridFitBoxForTesting
                t.expect(
                    (box?.cell.height ?? 0) > 0,
                    desc: "and the grid re-fits to the new metrics (cell \(box?.cell.debugDescription ?? "none"))"
                )

                // What `OSC 50 ?` would answer with. The reply is written to
                // the PTY as though typed, so no observer on this side sees it;
                // what this side can see is the family Core holds to answer it
                // with, which is the thing a frontend has to publish. Core
                // learns one from an OSC 50 SET and from nowhere else.
                t.expect(
                    surface.publishedFontFamilyForTesting == surface.drawnFontFamilyForTesting,
                    desc:
                        "the query would report the family being drawn (holds \(surface.publishedFontFamilyForTesting.debugDescription), draws \(surface.drawnFontFamilyForTesting ?? "nothing"))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_settings_font_family_reaches_an_open_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the app delegate answers")
                    return
                }
                guard let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting,
                    let opened = surface.drawnFontFamilyForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                let restore = app.settingsFontFamily()
                defer {
                    app.settingsSetFontFamily(restore ?? "")
                    TerminalWindowController.applyFontConfigurationToOpenWindows()
                }

                // Two faces that ship with the system, so whichever the window
                // opened on the other one is a real change.
                let wanted = opened == "Menlo" ? "Courier New" : "Menlo"
                app.settingsSetFontFamily(wanted)
                t.pump(0.3)
                // The fan-out must carry the family as well as the size and the
                // typography, or a reader who chose a face in Settings keeps
                // the old one on every open Swift window until it is reopened.
                t.expect(
                    surface.drawnFontFamilyForTesting == wanted,
                    desc:
                        "the chosen family reaches the open window (asked \(wanted), draws \(surface.drawnFontFamilyForTesting ?? "nothing"))"
                )

                // A name no face answers to still leaves a terminal that draws:
                // the substitution happens inside the face store, so what this
                // side has to guarantee is that the window keeps a cell to lay
                // a grid out in rather than measuring nothing and blanking.
                app.settingsSetFontFamily("Ubiquitty No Such Face")
                t.pump(0.3)
                let box = surface.gridFitBoxForTesting
                t.expect(
                    (box?.cell.width ?? 0) > 0 && (box?.cell.height ?? 0) > 0,
                    desc: "an unavailable family still leaves a cell to draw in (cell \(box?.cell.debugDescription ?? "none"))"
                )
            }
        }

        // Launch leaves View > Font empty: filling it runs the trait probes
        // over every installed family, which has no place between launch and
        // the first window. Opening the menu fills it, with nothing else
        // having asked for the catalog first — Settings included.
        UBUITestRegister("swift_shell_the_font_menu_fills_when_it_opens") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
                guard let fontMenu = viewMenu?.items.first(where: { $0.title == "Font" })?.submenu else {
                    t.expect(false, desc: "the app menu has View > Font")
                    return
                }
                t.expect(fontMenu.items.isEmpty, desc: "launch leaves the font menu unfilled (\(fontMenu.items.count) items)")
                guard let delegate = fontMenu.delegate else {
                    t.expect(false, desc: "the font menu has a delegate to fill it on open")
                    return
                }
                delegate.menuNeedsUpdate?(fontMenu)
                let titles = fontMenu.items.map(\.title)
                t.expect(titles.contains("Menlo"), desc: "opening it lists the installed monospace families (\(titles.count) items)")
            }
        }

        UBUITestRegister("swift_shell_beam_font_menu_updates_the_current_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting,
                    let opened = surface.drawnFontFamilyForTesting
                else {
                    t.expect(false, desc: "a Swift terminal opens")
                    return
                }
                let previous = app.settingsFontFamily()
                defer {
                    app.settingsSetFontFamily(previous ?? "")
                    shell.window?.close()
                }
                let wanted = opened == "Menlo" ? "Courier New" : "Menlo"
                let item = NSMenuItem(title: wanted, action: NSSelectorFromString("chooseFontFamily:"), keyEquivalent: "")
                t.expect(NSApp.sendAction(item.action!, to: app, from: item), desc: "Beam's menu action is dispatched")
                t.pump(0.3)
                t.expect(surface.drawnFontFamilyForTesting == wanted, desc: "the existing tab draws the chosen font")
            }
        }

        UBUITestRegister("swift_monaspace_shaping_cache_stays_bounded") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else { return }
                let saved = app.settingsFontFamily()
                app.settingsSetFontFamily("Monaspace Neon")
                defer { app.settingsSetFontFamily(saved ?? "") }
                guard let shell = TerminalWindowController.spawn(), let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "a Monaspace terminal opens")
                    return
                }
                defer { shell.window?.close() }
                shell.resizeWindow(toColumns: 80, rows: 24)
                t.pump(0.4)
                var maximumLines = 0
                for frame in 0..<24 {
                    var text = "\u{1b}[2J\u{1b}[H\u{1b}[?25l"
                    for row in 0..<20 {
                        text += "window minimum swimming \(frame * 100 + row) illmw tmux\r\n"
                    }
                    surface.feed(Data(text.utf8))
                    guard t.wait(until: { surface.renderedFrameForTesting() != nil }, timeout: 1) else {
                        t.expect(
                            false,
                            desc: "frame \(frame) renders after the erase settles (drawable \(surface.metalLayer.drawableSize))"
                        )
                        return
                    }
                    maximumLines = max(maximumLines, surface.shapingStatisticsForTesting?.lines ?? 0)
                }
                guard let statistics = surface.shapingStatisticsForTesting else {
                    t.expect(false, desc: "the live atlas reports shaping statistics")
                    return
                }
                t.expect(
                    statistics.segments > 0 && statistics.segments < 400,
                    desc: "active segments cover two frames, not the stream history (\(statistics.segments))"
                )
                t.expect(maximumLines < 200, desc: "native shaping calls stay bounded per frame (\(maximumLines))")
                NSLog("Monaspace shaping: max native calls/frame=%d active segments=%d", maximumLines, statistics.segments)
            }
        }

        UBUITestRegister("swift_live_font_routes_follow_add_change_and_remove") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyFontConfigurationToOpenWindows()
                }
                configureFontRoutes(over: saved)
                guard let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting,
                    let baseline = surface.routedFamilyForTesting(0x4E00),
                    let target = familyCovering(0x4E00, otherThan: baseline)
                else {
                    t.expect(false, desc: "a live surface and two Han faces are available")
                    return
                }
                defer { shell.window?.close() }
                for family in [target, baseline] {
                    configureFontRoutes(over: saved, rangeMapTable(first: 0x4E00, last: 0x4E00, family: family))
                    TerminalWindowController.applyFontConfigurationToOpenWindows()
                    t.expect(
                        surface.routedFamilyForTesting(0x4E00) == family,
                        desc: "the existing atlas follows the range rule for \(family)"
                    )
                }
                configureFontRoutes(over: saved, languageFallbackTable(script: "han", family: target))
                TerminalWindowController.applyFontConfigurationToOpenWindows()
                t.expect(
                    surface.routedFamilyForTesting(0x4E00) == target,
                    desc: "the existing atlas follows the script rule"
                )
                configureFontRoutes(over: saved)
                TerminalWindowController.applyFontConfigurationToOpenWindows()
                t.expect(surface.routedFamilyForTesting(0x4E00) == baseline, desc: "removing rules restores the cascade")
            }
        }

        UBUITestRegister("range_map_routes_its_range_to_the_named_family") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Unified Han: absent from the primary, and carried by many
                // installed families, so a second family to move it to exists.
                let codePoint: UInt32 = 0x4E00
                guard let baseline = routedFamily(for: codePoint) else {
                    t.expect(false, desc: "U+4E00 resolves to some face before any override")
                    return
                }
                guard let target = familyCovering(codePoint, otherThan: baseline) else {
                    t.expect(false, desc: "a second installed family covers U+4E00 to route it to")
                    return
                }

                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                configureFontRoutes(over: saved, rangeMapTable(first: codePoint, last: codePoint, family: target))
                let routed = routedFamily(for: codePoint)
                t.restoreConfiguration(saved)

                t.expect(
                    routed == target,
                    desc: "[[font.range_map]] routes U+4E00 to \(target), got \(routed ?? "nothing")"
                )
            }
        }

        UBUITestRegister("range_map_leaves_code_points_outside_its_range_alone") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let inside: UInt32 = 0x4E00
                let outside: UInt32 = 0x4E8C
                guard let baseline = routedFamily(for: outside),
                    let target = familyCovering(inside, otherThan: baseline)
                else {
                    t.expect(false, desc: "a second Han code point and a second covering family exist")
                    return
                }

                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                configureFontRoutes(over: saved, rangeMapTable(first: inside, last: inside, family: target))
                let routed = routedFamily(for: outside)
                t.restoreConfiguration(saved)

                t.expect(
                    routed == baseline,
                    desc: "U+4E8C is outside the mapped range and still resolves to \(baseline)"
                )
            }
        }

        UBUITestRegister("language_fallback_routes_its_script_to_the_named_family") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Arabic: absent from the primary, carried by many families.
                let codePoint: UInt32 = 0x0633
                guard let baseline = routedFamily(for: codePoint) else {
                    t.expect(false, desc: "U+0633 resolves to some face before any override")
                    return
                }
                guard let target = familyCovering(codePoint, otherThan: baseline) else {
                    t.expect(false, desc: "a second installed family covers U+0633 to route it to")
                    return
                }

                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                configureFontRoutes(over: saved, languageFallbackTable(script: "arabic", family: target))
                let routed = routedFamily(for: codePoint)
                t.restoreConfiguration(saved)

                t.expect(
                    routed == target,
                    desc: "[[font.language_fallback]] routes Arabic to \(target), got \(routed ?? "nothing")"
                )
            }
        }

        UBUITestRegister("range_override_added_in_settings_routes_and_persists") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let codePoint: UInt32 = 0x4E00
                guard let baseline = routedFamily(for: codePoint),
                    let target = familyCovering(codePoint, otherThan: baseline)
                else {
                    t.expect(false, desc: "a second installed family covers U+4E00 to route it to")
                    return
                }

                app.settingsSetRangeMap(from: codePoint, to: codePoint, family: target)

                // It reached the file and came back through the reader...
                let listed = FontRoutingPane.currentEntries()
                t.expect(
                    listed.contains { $0.first == codePoint && $0.last == codePoint && $0.family == target },
                    desc: "the pane lists the override it just wrote"
                )
                // ...and it reached the route, which is the point of writing it.
                t.expect(
                    routedFamily(for: codePoint) == target,
                    desc: "the added override routes U+4E00 to \(target)"
                )

                app.settingsRemoveRangeMap(from: codePoint, to: codePoint)
                t.expect(
                    routedFamily(for: codePoint) == baseline,
                    desc: "removing it puts U+4E00 back to \(baseline)"
                )
                t.expect(
                    !FontRoutingPane.currentEntries().contains { $0.first == codePoint },
                    desc: "the pane no longer lists the removed override"
                )
            }
        }

        UBUITestRegister("fallback_size_settings_apply_global_and_range_overrides") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    case .toggle(let get, let set) = settingsRow(labelled: "Match Fallback Font Size"),
                    let faces = FontFaces(family: "Menlo", size: 26, pixelsPerPoint: 1)
                else {
                    t.expect(false, desc: "the fallback size control and primary font are available")
                    return
                }
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { restoreLiveDocument(saved) }
                configureFontRoutes(over: saved)
                func currentFont() -> CTFont? {
                    let router = FontRouter(
                        primary: faces,
                        cjkFamilyName: "",
                        cjkLanguage: "",
                        symbolFamilyName: "",
                        symbolFontPath: "",
                        configuration: Ubiquitty.Preferences.values().pointee
                    )
                    return router.routedFont(for: 0x2426, face: .Regular, variableWeight: 0, wantsEmoji: false)
                }
                for isMatching in [false, true] {
                    set(isMatching)
                    t.expect(get() == isMatching, desc: "the default control reads its applied choice")
                    for override: Bool? in [nil, false, true] {
                        app.settingsSetRangeMap(from: 0x2426, to: 0x2426, family: "Apple Symbols", shouldMatchSize: override)
                        guard let font = currentFont() else {
                            t.expect(false, desc: "the configured range resolves U+2426")
                            continue
                        }
                        let shouldMatch = override ?? isMatching
                        t.expect(
                            shouldMatch
                                ? abs(CTFontGetXHeight(font) - CTFontGetXHeight(faces[.Regular])) < 0.02
                                : abs(CTFontGetSize(font) - 26) < 0.02,
                            desc: "the rendered range follows its override or the default"
                        )
                        t.expect(
                            FontRoutingPane.currentEntries().first(where: { $0.first == 0x2426 })?.shouldMatchSize == override,
                            desc: "the range control reads its applied choice, including Use Default"
                        )
                    }
                }
            }
        }

        UBUITestRegister("range_override_removal_leaves_other_entries_alone") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                guard let target = familyCovering(0x4E00, otherThan: nil) else {
                    t.expect(false, desc: "an installed family covers U+4E00")
                    return
                }

                // Two overrides; removing one must not disturb the other.
                app.settingsSetRangeMap(from: 0x4E00, to: 0x4E00, family: target)
                app.settingsSetRangeMap(from: 0x0633, to: 0x0633, family: target)
                app.settingsRemoveRangeMap(from: 0x4E00, to: 0x4E00)

                let remaining = FontRoutingPane.currentEntries()
                t.expect(
                    remaining.contains { $0.first == 0x0633 && $0.family == target },
                    desc: "the untouched override is still listed"
                )
                t.expect(
                    !remaining.contains { $0.first == 0x4E00 },
                    desc: "the removed override is gone"
                )

                app.settingsRemoveRangeMap(from: 0x0633, to: 0x0633)
            }
        }

        UBUITestRegister("range_field_takes_characters_and_code_points_alike") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // What a person has in hand is the character, not its number.
                let pasted = FontRoutingPane.range(from: "⌘")
                t.expect(pasted?.first == 0x2318 && pasted?.last == 0x2318, desc: "a pasted character is its own code point")

                // Several characters make the range they span: they were typed
                // together because they belong together.
                let spanned = FontRoutingPane.range(from: "─┐")
                t.expect(spanned?.first == 0x2500 && spanned?.last == 0x2510, desc: "several characters span a range")

                // The file's own spellings, so what a reader sees in config.toml
                // is what they can type back in.
                t.expect(FontRoutingPane.range(from: "U+2318")?.first == 0x2318, desc: "U+2318 is read as a code point")
                t.expect(FontRoutingPane.range(from: "2318")?.first == 0x2318, desc: "a bare hex code point is read as one")
                let ranged = FontRoutingPane.range(from: "U+2500-U+257F")
                t.expect(ranged?.first == 0x2500 && ranged?.last == 0x257F, desc: "a dashed range is read whole")

                t.expect(FontRoutingPane.range(from: "") == nil, desc: "an empty field is not a range")
                // A backwards range is refused rather than silently swapped: the
                // reader would drop it, so accepting it here would be a no-op
                // that looked like a write.
                t.expect(FontRoutingPane.range(from: "U+257F-U+2500") == nil, desc: "a backwards range is refused")
            }
        }

        UBUITestRegister("script_fallback_added_in_settings_routes_and_persists") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                // Arabic: absent from the primary and carried by many families.
                let codePoint: UInt32 = 0x0633
                guard let baseline = routedFamily(for: codePoint),
                    let target = familyCovering(codePoint, otherThan: baseline)
                else {
                    t.expect(false, desc: "a second installed family covers U+0633 to route it to")
                    return
                }

                app.settingsSetLanguageFallback(forScript: "arabic", family: target)

                t.expect(
                    FontRoutingPane.currentScriptFallbacks().contains { $0.script == "arabic" && $0.family == target },
                    desc: "the pane lists the script fallback it just wrote"
                )
                t.expect(
                    routedFamily(for: codePoint) == target,
                    desc: "the added script fallback routes Arabic to \(target)"
                )

                app.settingsRemoveLanguageFallback(forScript: "arabic")
                t.expect(
                    routedFamily(for: codePoint) == baseline,
                    desc: "removing it puts Arabic back to \(baseline)"
                )
                t.expect(
                    !FontRoutingPane.currentScriptFallbacks().contains { $0.script == "arabic" },
                    desc: "the pane no longer lists the removed script fallback"
                )
            }
        }

        UBUITestRegister("script_picker_offers_only_scripts_the_reader_keeps") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let offered = app.settingsFontScriptNames()
                t.expect(!offered.isEmpty, desc: "the script picker offers something")

                // Every offered script has to survive a write and a re-read: a
                // picker offering one the reader drops would look like it
                // worked and route nothing.
                guard let family = familyCovering(0x0633, otherThan: nil) else {
                    t.expect(false, desc: "an installed family to route to")
                    return
                }
                var kept = true
                for script in offered {
                    app.settingsSetLanguageFallback(forScript: script, family: family)
                    if !FontRoutingPane.currentScriptFallbacks().contains(where: { $0.script == script }) {
                        kept = false
                        t.expect(false, desc: "the reader keeps the offered script \(script)")
                    }
                    app.settingsRemoveLanguageFallback(forScript: script)
                }
                t.expect(kept, desc: "every script the picker offers survives a write and a re-read")

                // Han is absent because the CJK Fallback row already sets it,
                // and one setting reachable from two controls is one setting
                // with two answers.
                t.expect(!offered.contains("han"), desc: "Han is left to the CJK Fallback row")
            }
        }

        UBUITestRegister("emoji_fallback_row_offers_every_installed_family") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                guard case .menu(let options, _, _, _)? = settingsRow(labelled: "Emoji Fallback") else {
                    t.expect(false, desc: "the Emoji Fallback row is a menu in the Fonts pane")
                    return
                }
                t.expect(options.first == "System Emoji", desc: "the platform face is the row's first entry")

                // Membership, not a filter: the key accepts any family, so
                // every installed family has to be arrivable by clicking.
                let installed = app.settingsAllFontFamilyNames()
                t.expect(!installed.isEmpty, desc: "the machine has installed families to offer")
                let offered = Set(options.dropFirst().map(familyOfEmojiLabel))
                t.expect(
                    installed.allSatisfy { offered.contains($0) },
                    desc: "every installed family is reachable in the Emoji Fallback row"
                )

                // Pictograph-carrying families lead, and are unmarked.
                let carrying = Set(app.settingsEmojiFontNames())
                if let firstMarked = options.dropFirst().firstIndex(where: { $0.hasSuffix(" — no pictographs") }) {
                    let leading = options[1..<firstMarked].map(familyOfEmojiLabel)
                    t.expect(
                        leading.allSatisfy { carrying.contains($0) },
                        desc: "the unmarked entries ahead of the mark all carry pictographs"
                    )
                }
            }
        }

        UBUITestRegister("emoji_fallback_row_moves_the_routed_face") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The row is only worth having if choosing in it changes which
                // face draws a pictograph, which is the property the key had
                // on no platform until the router read it.
                let codePoint: UInt32 = 0x1F600
                guard case .menu(let options, _, _, let set)? = settingsRow(labelled: "Emoji Fallback") else {
                    t.expect(false, desc: "the Emoji Fallback row is a menu in the Fonts pane")
                    return
                }
                guard let covering = familyCovering(codePoint, otherThan: nil),
                    let index = options.firstIndex(where: { familyOfEmojiLabel($0) == covering })
                else {
                    t.expect(false, desc: "a pictograph-carrying family is offered in the row")
                    return
                }

                set(index)
                let routed = routedFamily(for: codePoint, wantsEmoji: true)
                set(0)

                t.expect(
                    routed == covering,
                    desc: "choosing \(covering) in the row routes U+1F600 to it, got \(routed ?? "nothing")"
                )
                t.expect(
                    (NSApp.delegate as? UBAppDelegate)?.settingsEmojiFallbackFont() == nil,
                    desc: "index 0 clears the override back to the platform face"
                )
            }
        }

        UBUITestRegister("emoji_fallback_reaches_the_route") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A machine typically carries exactly one family covering
                // astral emoji, so this asserts the configured family is the
                // one routed when it covers the code point, and that a
                // configured family lacking that coverage is declined rather
                // than inked as that family's tofu.
                let codePoint: UInt32 = 0x1F600
                guard let covering = familyCovering(codePoint, otherThan: nil) else {
                    t.expect(false, desc: "some installed family covers U+1F600")
                    return
                }

                let saved = t.configureAppending("[font]\nemoji_fallback = \(tomlQuoted(covering))\n")
                let configured = routedFamily(for: codePoint, wantsEmoji: true)
                t.restoreConfiguration(saved)
                t.configureAppending("[font]\nemoji_fallback = \(tomlQuoted(primaryFamily))\n")
                let declined = routedFamily(for: codePoint, wantsEmoji: true)
                t.restoreConfiguration(saved)

                t.expect(
                    configured == covering,
                    desc: "font.emoji_fallback routes U+1F600 to the configured \(covering)"
                )
                t.expect(
                    declined != primaryFamily,
                    desc: "an emoji fallback lacking the glyph is declined, got \(declined ?? "nothing")"
                )
            }
        }

        UBUITestRegister("configured_weight_survives_a_width_the_family_cannot_honour") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let weightTag: UInt32 = 0x7767_6874
                let widthTag: UInt32 = 0x7764_7468
                // A family whose weight rides its `wght` axis while a width
                // has no axis to ride: the pair that sends the width to the
                // trait rematch, which resolves from the family and so starts
                // without the axes already placed. Calibrated against the
                // machine's own inventory, like the routing scenarios above.
                var candidate: (family: String, weight: Int)?
                for family in NSFontManager.shared.availableFontFamilies.sorted() {
                    let font = CTFontCreateWithName(family as CFString, 14, nil)
                    guard (CTFontCopyFamilyName(font) as String) == family else { continue }
                    let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
                    guard
                        !axes.contains(where: { $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 == widthTag }),
                        let wght = axes.first(where: { $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 == weightTag }),
                        let minimum = wght[kCTFontVariationAxisMinimumValueKey as String] as? Double,
                        let maximum = wght[kCTFontVariationAxisMaximumValueKey as String] as? Double,
                        let rest = wght[kCTFontVariationAxisDefaultValueKey as String] as? Double
                    else { continue }
                    // A coordinate away from the axis default, since CoreText
                    // reports the default as no coordinate at all.
                    let target = rest == maximum ? minimum : maximum
                    guard target != rest, target >= 100, target <= 900 else { continue }
                    candidate = (family, Int(target))
                    break
                }
                guard let (family, weight) = candidate else {
                    t.expect(false, desc: "an installed family carries a wght axis and no wdth axis")
                    return
                }

                func regularWeightCoordinate(widthPercent: Double) -> Double? {
                    guard
                        let faces = FontFaces(
                            family: family,
                            size: 14,
                            pixelsPerPoint: 1,
                            weight: weight,
                            boldWeight: 0,
                            featureSpec: "",
                            widthPercent: widthPercent,
                            variationSpec: ""
                        )
                    else { return nil }
                    let regular = faces[Ubiquitty.Rendering.FontFace.Regular]
                    return (CTFontCopyVariation(regular) as? [UInt32: Double])?[weightTag]
                }

                // The unwidened arm establishes the weight is expressible at
                // all; without it a family refusing the axis would pass the
                // widened arm's absence off as the defect.
                t.expect(
                    regularWeightCoordinate(widthPercent: 0) == Double(weight),
                    desc: "\(family) at weight \(weight) with no width carries the wght coordinate"
                )
                t.expect(
                    regularWeightCoordinate(widthPercent: 60) == Double(weight),
                    desc: "\(family) at weight \(weight) keeps the wght coordinate through the width-trait rematch"
                )
            }
        }

        UBUITestRegister("weight_and_width_rows_write_the_absence_they_mean") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let priorWeight = app.settingsFontWeight()
                let priorBold = app.settingsBoldFontWeight()
                let priorWidth = app.settingsFontWidth()

                // Set from unset: the row's value has to land whatever the key
                // held before, which is where a setter consulting the old
                // value to decide whether to store the new one goes wrong.
                app.settingsSetFontWidth(60)
                t.expect(app.settingsFontWidth() == 60, desc: "a width set from unset reads back as 60")
                app.settingsSetFontWidth(0)
                t.expect(app.settingsFontWidth() == 0, desc: "clearing the width reads back as the face's own")

                app.settingsSetFontWeight(600, bold: 800)
                t.expect(app.settingsFontWeight() == 600, desc: "a weight set from unset reads back as 600")
                t.expect(app.settingsBoldFontWeight() == 800, desc: "a bold weight set from unset reads back as 800")
                app.settingsSetFontWeight(0, bold: 0)
                t.expect(app.settingsFontWeight() == 0, desc: "Font Default reads back as the face's own weight")
                t.expect(app.settingsBoldFontWeight() == 0, desc: "Font Default reads back as the face's own bold")

                app.settingsSetFontWidth(priorWidth)
                app.settingsSetFontWeight(priorWeight, bold: priorBold)
            }
        }

        UBUITestRegister("font_variants_apply_to_scalar_and_mixed_runs") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let surface = shell.focusedSurfaceForTesting,
                    var typography = surface.typographyForTesting
                else {
                    t.expect(false, desc: "a terminal opens for the font variant oracle")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                for ligates in [false, true] {
                    typography.canLigate = ligates
                    for style in ["0", "1", "3", "1;3"] {
                        for (character, tag) in [("l", "cv01"), ("ł", "cv01"), (":", "case")] {
                            var variants: [Data] = []
                            for feature in ["-" + tag, tag] {
                                typography.ligatureFeatureSpec = feature
                                t.expect(
                                    surface.adoptFontForTesting(familyName: "JetBrains Mono", pointSize: 24, typography: typography),
                                    desc: "the bundled face adopts the requested variant"
                                )
                                var reference: Data?
                                let word = tag == "case" ? character + "abc" : String(repeating: character, count: 4)
                                for text in [character, character + "ł", word, character + " " + character] {
                                    surface.feed(Data("\u{1B}[?25l\u{1B}[2J\u{1B}[H\u{1B}[\(style)m\(text)".utf8))
                                    surface.invalidateRetainedBaseline()
                                    var renderedFrame = surface.renderedFrameForTesting()
                                    if renderedFrame == nil {
                                        t.wait(
                                            until: {
                                                renderedFrame = surface.renderedFrameForTesting()
                                                return renderedFrame != nil
                                            },
                                            timeout: 1
                                        )
                                    }
                                    guard let frame = renderedFrame,
                                        let box = surface.gridFitBoxForTesting
                                    else {
                                        t.expect(false, desc: "the glyph frame can be read back")
                                        return
                                    }
                                    let scale = Double(frame.width) / box.bounds.width
                                    let left = Int((box.insets.left * scale).rounded())
                                    let top = Int((box.insets.top * scale).rounded())
                                    let width = Int((box.cell.width * scale).rounded(.down))
                                    let height = Int((box.cell.height * scale).rounded(.down))
                                    var cell = Data()
                                    for row in top..<(top + height) {
                                        let start = (row * frame.width + left) * 4
                                        cell.append(frame.pixels[start..<(start + width * 4)])
                                    }
                                    if let reference {
                                        t.expect(
                                            cell == reference,
                                            desc:
                                                "\(feature), style \(style), ligatures \(ligates): \(character) retains its pixels in \(text)"
                                        )
                                    } else {
                                        reference = cell
                                    }
                                }
                                if let reference { variants.append(reference) }
                            }
                            t.expect(
                                variants.count == 2 && variants[0] != variants[1],
                                desc: "\(tag) changes actual \(character) pixels in style \(style)"
                            )
                        }
                    }
                }
            }
        }

        UBUITestRegister("bundled_nerd_font_routes_private_use_icons") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let path = Bundle.main.path(
                        forResource: "SymbolsNerdFontMono-Regular",
                        ofType: "ttf",
                        inDirectory: "fonts"
                    ),
                    let faces = FontFaces(
                        family: "Menlo",
                        size: 14,
                        pixelsPerPoint: 1,
                        weight: 0,
                        boldWeight: 0,
                        featureSpec: "",
                        widthPercent: 0,
                        variationSpec: ""
                    )
                else {
                    t.expect(false, desc: "the application packages its symbol font and resolves the primary")
                    return
                }
                let router = FontRouter(
                    primary: faces,
                    cjkFamilyName: "",
                    cjkLanguage: "",
                    symbolFamilyName: String(Ubiquitty.Preferences.Effective.symbolFallbackFamily(Ubiquitty.Preferences.Values())),
                    symbolFontPath: path,
                    configuration: Ubiquitty.Preferences.values().pointee
                )
                for codePoint: UInt32 in [0xE0B0, 0xF07B, 0xF120, 0xF0001, 0xF0002] {
                    let font = router.routedFont(
                        for: codePoint,
                        face: .Regular,
                        variableWeight: 0,
                        wantsEmoji: false
                    )
                    t.expect(
                        font.map { CTFontCopyFamilyName($0) as String } == "Symbols Nerd Font Mono",
                        desc: "U+\(String(codePoint, radix: 16)) routes to the bundled icon face"
                    )
                    guard let font, let scalar = UnicodeScalar(codePoint) else { continue }
                    let characters = Array(String(scalar).utf16)
                    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                    t.expect(
                        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
                            && glyphs.contains(where: { $0 != 0 }),
                        desc: "the routed face supplies an actual icon glyph"
                    )
                }
            }
        }

        UBUITestRegister("technical_symbols_default_to_stix_two_math") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let codePoint: UInt32 = 0x23BE
                guard covers(codePoint, "STIX Two Math") else {
                    t.expect(false, desc: "STIX Two Math carries U+23BE on this machine")
                    return
                }

                // Both symbol-fallback spellings empty, so the product default
                // route is observed.
                let saved = t.configureAppending("[font]\nsymbol_fallback = \"\"\nfallback = \"\"\n")
                let routed = routedFamily(for: codePoint)
                t.restoreConfiguration(saved)

                t.expect(
                    routed == "STIX Two Math",
                    desc: "without a symbol-fallback override, U+23BE routes to STIX Two Math, got \(routed ?? "nothing")"
                )
            }
        }
    }
}

/// The primary family every scenario routes from.
///
/// Fixed rather than read from the configuration: the code points below are
/// chosen for being absent from it, and the route consults the primary before
/// any override, so a primary that covered them would answer first and no
/// configured stage would ever be reached.
private let primaryFamily = "Menlo"

/// The family a code point resolves to, through a router built the way the
/// renderer builds one.
///
/// A new router each call on purpose: the router reads the configuration once,
/// at construction, so a router built before a setting changed would answer
/// from the configuration that preceded it.
@MainActor
private func routedFamily(for codePoint: UInt32, wantsEmoji: Bool = false) -> String? {
    guard
        let faces = FontFaces(
            family: primaryFamily,
            size: 14,
            pixelsPerPoint: 1,
            weight: 0,
            boldWeight: 0,
            featureSpec: "",
            widthPercent: 0,
            variationSpec: ""
        )
    else {
        return nil
    }
    let router = FontRouter(
        primary: faces,
        cjkFamilyName: "",
        cjkLanguage: "",
        symbolFamilyName: "",
        symbolFontPath: "",
        configuration: Ubiquitty.Preferences.values().pointee
    )
    guard
        let font = router.routedFont(
            for: codePoint,
            face: Ubiquitty.Rendering.FontFace.Regular,
            variableWeight: 0,
            wantsEmoji: wantsEmoji
        )
    else {
        return nil
    }
    return CTFontCopyFamilyName(font) as String
}

/// Whether `family` has a glyph for `codePoint`.
@MainActor
private func covers(_ codePoint: UInt32, _ family: String) -> Bool {
    let font = CTFontCreateWithName(family as CFString, 14, nil)
    // CTFont substitutes rather than failing, so a name it does not know would
    // otherwise pass on the substitute's coverage.
    guard (CTFontCopyFamilyName(font) as String).compare(family, options: .caseInsensitive) == .orderedSame,
        let scalar = UnicodeScalar(codePoint)
    else {
        return false
    }
    var units = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
}

/// An installed family carrying `codePoint`, other than `excluded` and the
/// primary.
@MainActor
private func familyCovering(_ codePoint: UInt32, otherThan excluded: String?) -> String? {
    guard let app = NSApp.delegate as? UBAppDelegate else {
        return nil
    }
    for family in app.settingsAllFontFamilyNames() where family != excluded && family != primaryFamily {
        if covers(codePoint, family) {
            return family
        }
    }
    return nil
}

/// A `[[font.range_map]]` table routing `[first, last]` to `family`.
private func rangeMapTable(first: UInt32, last: UInt32, family: String) -> String {
    let range = String(format: "U+%04X-U+%04X", first, last)
    return "[[font.range_map]]\nrange = \"\(range)\"\nmode = \"custom\"\nfamily = \(tomlQuoted(family))\n"
}

/// A `[[font.language_fallbacks]]` table routing `script` to `family`.
private func languageFallbackTable(script: String, family: String) -> String {
    "[[font.language_fallbacks]]\nscript = \(tomlQuoted(script))\nmode = \"custom\"\nfamily = \(tomlQuoted(family))\n"
}

/// Configures Core from `base` with its range and script routes replaced by
/// `tables`, so a scenario routes through its own overrides and no others.
///
/// - Parameters:
///   - base: The document the scenario found live.
///   - tables: The route tables to configure; empty routes by the cascade alone.
@MainActor
private func configureFontRoutes(over base: String, _ tables: String = "") {
    let unrouted = documentDroppingTables(base) { $0 == "[[font.range_map]]" || $0 == "[[font.language_fallbacks]]" }
    restoreLiveDocument(unrouted + "\n" + tables)
}

/// The catalog row a reader sees under `label`, so a scenario asserts the row
/// rather than the accessor beneath it.
@MainActor
private func settingsRow(labelled label: String) -> SettingsRow.Control? {
    for category in SettingsCatalog.categories() {
        guard case .pane(let pane) = category.content else {
            continue
        }
        for card in pane.cards {
            for row in card.rows where row.label == label {
                return row.control.resolved()
            }
        }
    }
    return nil
}

/// The family a picker label names, with any coverage mark taken back off.
private func familyOfEmojiLabel(_ label: String) -> String {
    let mark = " — no pictographs"
    return label.hasSuffix(mark) ? String(label.dropLast(mark.count)) : label
}
