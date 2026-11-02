// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import ImageIO
import UbiquittyKit
import UbiquittyRenderKit
import UniformTypeIdentifiers

// SymbolFallbackScenarios.swift — Settings ▸ Fonts ▸ Symbol Fallback, driven
// through the catalog the pane is built from, so the assertions are about the
// row a reader sees rather than about the accessors under it.
//
// The row offers every installed family. font.symbol_fallback is a string key
// that accepts any family name, so a picker offering a subset would leave
// values reachable by hand and not by clicking — a control narrower than the
// key it edits. Coverage of the blocks a symbol fallback answers orders the
// list instead of gating it: covering families first under their own names,
// the rest after and marked.
//
// The row also owns `font.symbol_fallback` — the key that outranks the
// `font.fallback` alias — so what the picker writes is what Core routes
// symbols with.

/// Registers the symbol-fallback scenarios with the UI-test runner.
///
/// A scenario is a C function pointer, so each closure below carries no
/// context.
enum SymbolFallbackScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("symbol_fallback_face_grows_the_slot_and_a_change_rebuilds_it") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = symbolFallbackSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard var typography = surface.typographyForTesting else {
                    t.expect(false, desc: "the surface reports the typography it draws under")
                    return
                }

                // A primary whose own bounding box overhangs its advance by
                // little, so the slot policy's clamp — one cell of margin per
                // side — is not already reached before the symbol face has its
                // say. JetBrains Mono, Menlo and Monaco all overhang a full
                // cell on their own through their widest glyphs and sit at the
                // clamp with or without the face; the system's plainer
                // monospaces do not. The first installed one is taken.
                let tightFamilies = ["Andale Mono", "Courier New", "PT Mono", "SF Mono"]
                guard let family = tightFamilies.first(where: { installedFace($0) != nil }) else {
                    t.expect(false, desc: "one of \(tightFamilies) is installed")
                    return
                }
                let pointSize = 13.0
                // No symbol face at all: the slot is sized to the primary alone.
                typography.symbolFamilyName = ""
                typography.symbolFontPath = ""
                t.expect(
                    surface.adoptFontForTesting(familyName: family, pointSize: pointSize, typography: typography),
                    desc: "the renderer adopts \(family) with no symbol face"
                )
                // The frame renderer is rebuilt on the next frame, and the
                // slot is read off it, so each adopt is followed by a draw.
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
                t.pump(0.4)
                guard let bare = surface.glyphSlotForTesting() else {
                    t.expect(false, desc: "the surface reports its slot without a symbol face")
                    return
                }

                // The bundled face, by name where the app registered it and by
                // its file otherwise: a typography change, so the renderer
                // re-measures and re-cuts its sheet, and the face's bounding
                // box — cut to a larger em than the primary's — grows the
                // margins by half its excess per side, as Core's policy folds
                // it.
                typography.symbolFamilyName = "Symbols Nerd Font Mono"
                typography.symbolFontPath =
                    Bundle.main.path(forResource: "SymbolsNerdFontMono-Regular", ofType: "ttf", inDirectory: "fonts") ?? ""
                t.expect(
                    surface.adoptFontForTesting(familyName: family, pointSize: pointSize, typography: typography),
                    desc: "the renderer adopts the symbol face as a typography change"
                )
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
                t.pump(0.4)
                guard let grown = surface.glyphSlotForTesting() else {
                    t.expect(false, desc: "the surface reports its slot with the symbol face")
                    return
                }
                t.expect(
                    grown.glyphMarginInPixels.width >= bare.glyphMarginInPixels.width + 2,
                    desc:
                        "the face's box grows \(family)'s slot side margins (\(bare.glyphMarginInPixels.width) to \(grown.glyphMarginInPixels.width) px)"
                )
                t.expect(
                    grown.slotWidthInPixels > bare.slotWidthInPixels && grown.glyphWidthInPixels == bare.glyphWidthInPixels,
                    desc:
                        "the slot widens while the cell box holds (slot \(bare.slotWidthInPixels) to \(grown.slotWidthInPixels), cell \(bare.glyphWidthInPixels) and \(grown.glyphWidthInPixels))"
                )

                // Back to none: the same change in reverse rebuilds again, so a
                // face removed does not leave the wider slot behind.
                typography.symbolFamilyName = ""
                typography.symbolFontPath = ""
                t.expect(
                    surface.adoptFontForTesting(familyName: family, pointSize: pointSize, typography: typography),
                    desc: "the renderer adopts the removal"
                )
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
                t.pump(0.4)
                let removed = surface.glyphSlotForTesting()
                t.expect(
                    removed?.glyphMarginInPixels.width == bare.glyphMarginInPixels.width,
                    desc:
                        "the removal takes the margins back (\(removed.map { String($0.glyphMarginInPixels.width) } ?? "nothing") vs \(bare.glyphMarginInPixels.width))"
                )
            }
        }

        UBUITestRegister("symbol_fallback_picker_offers_every_installed_family") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                guard case .menu(let options, _, _, _)? = symbolFallbackControl() else {
                    t.expect(false, desc: "the Symbol Fallback row is a menu in the Fonts pane")
                    return
                }
                t.expect(options.first == "Symbols Nerd Font Mono (Default)", desc: "the default symbol family is the first entry")

                // Membership is the requirement: the key accepts any family, so
                // every installed family has to be arrivable by clicking.
                let installed = app.settingsAllFontFamilyNames()
                t.expect(!installed.isEmpty, desc: "the machine has installed families to offer")
                let offered = Set(options.dropFirst().map(familyOfLabel))
                t.expect(
                    installed.allSatisfy { offered.contains($0) },
                    desc: "every installed family is reachable from the picker"
                )
                t.expect(
                    offered.contains(where: { !isMonospaced($0) }),
                    desc: "proportional families among them — the row is not filtered by pitch"
                )

                // The probe still discriminates, and now it discriminates by
                // ORDER and MARK rather than by membership. Both halves are
                // asserted, so a probe that degenerated to always-true or
                // always-false would fail here rather than pass quietly.
                let covering = Set(app.settingsSymbolFontNames())
                t.expect(!covering.isEmpty, desc: "some installed family covers the symbol blocks")
                t.expect(
                    installed.contains(where: { !covering.contains($0) }),
                    desc: "and some installed family does not — the probe is not answering yes to everything"
                )

                let ranks = options.dropFirst().enumerated()
                let lastCovering = ranks.filter { covering.contains(familyOfLabel($0.element)) }.map(\.offset).max()
                let firstNonCovering = ranks.filter { !covering.contains(familyOfLabel($0.element)) }.map(\.offset).min()
                if let lastCovering, let firstNonCovering {
                    t.expect(lastCovering < firstNonCovering, desc: "every covering family sorts above every non-covering one")
                }
                t.expect(
                    options.dropFirst()
                        .allSatisfy { label in
                            label.hasSuffix(limitedCoverageMark) != covering.contains(familyOfLabel(label))
                        },
                    desc: "the mark is on exactly the families the probe does not cover"
                )
            }
        }

        UBUITestRegister("symbol_fallback_picker_writes_the_symbol_key") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let saved = app.settingsSymbolFallbackFont()
                defer { app.settingsSetSymbolFallbackFont(saved ?? "") }

                guard case .menu(let options, _, let get, let set)? = symbolFallbackControl() else {
                    t.expect(false, desc: "the Symbol Fallback row is a menu in the Fonts pane")
                    return
                }
                guard let chosenIndex = options.indices.dropFirst().first else {
                    t.expect(false, desc: "the row offers a face to choose")
                    return
                }
                let chosen = familyOfLabel(options[chosenIndex])
                t.expect(
                    options[chosenIndex] == chosen,
                    desc: "the first offered entry is a covering family, so its label is its family name"
                )

                set(chosenIndex)
                t.pump(0.1)
                t.expect(
                    symbolFallbackFamily() == chosen,
                    desc: "choosing a face makes it the family Core routes symbols with"
                )
                t.expect(
                    configFileNamesSymbolFallback(chosen),
                    desc: "and the choice is written to font.symbol_fallback, the key that outranks"
                )
                t.expect(get() == chosenIndex, desc: "the row reads its own choice back")

                set(0)
                t.pump(0.1)
                t.expect(symbolFallbackFamily() == "Symbols Nerd Font Mono", desc: "index 0 restores the bundled icon family")
                t.expect(get() == 0, desc: "the row shows the default selection again")
            }
        }

        UBUITestRegister("symbol_fallback_picker_shows_a_config_set_family") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let saved = app.settingsSymbolFallbackFont()
                defer { app.settingsSetSymbolFallbackFont(saved ?? "") }

                // A family set outside the picker — the config-file case — has to
                // be the selection the row shows, or the picker silently offers
                // to overwrite a choice it never displayed.
                guard case .menu(_, _, _, let set)? = symbolFallbackControl() else {
                    t.expect(false, desc: "the Symbol Fallback row is a menu in the Fonts pane")
                    return
                }
                guard let installed = firstOfferedFamily() else {
                    t.expect(false, desc: "an installed symbol face to set")
                    return
                }
                set(0)
                t.pump(0.1)
                app.settingsSetSymbolFallbackFont(installed)
                t.pump(0.1)

                guard case .menu(let freshOptions, _, let freshGet, _)? = symbolFallbackControl() else {
                    t.expect(false, desc: "the row rebuilds")
                    return
                }
                t.expect(
                    freshOptions.indices.contains(freshGet()) && familyOfLabel(freshOptions[freshGet()]) == installed,
                    desc: "a family set outside the picker is the selection the row shows"
                )
            }
        }

        // The oracle, as a test: with Menlo as primary and as symbol
        // fallback the brackets align, and with a primary that lacks them and
        // Menlo as the fallback they shift. Nothing about Menlo changed between
        // those two runs -- only whether the glyph arrived through the fallback
        // pen -- so the fallback pen is the whole of the difference, and the
        // property to hold is that it makes none.
        //
        // Asserted against the PLAIN pen rather than against a second rendering,
        // because the plain pen is exactly what the primary path uses: a piece
        // that lands there has landed where the face would have put it as the
        // primary, which is the same statement and does not need two atlases to
        // make it.
        UBUITestRegister("bracket_pieces_land_where_the_face_puts_them") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let primary = installedFace("Menlo") else {
                    t.expect(false, desc: "the fixture face Menlo is installed")
                    return
                }
                let cell = advanceWidth(of: primary, "M")
                let margin: CGFloat = 1.0
                let slotWidth = cell + margin * 2.0
                let slotHeight = CGFloat(ceil(CTFontGetAscent(primary) + CTFontGetDescent(primary))) + margin * 2.0
                let baseline = CGFloat(ceil(CTFontGetDescent(primary))) + margin
                let subpixel: CGFloat = 0

                // Every piece that stacks. A face need not carry them all --
                // JetBrains Mono has no integral -- so presence is measured per
                // face and the count is asserted at the end; a run that skipped
                // everything must not read as a pass.
                let pieces: [UInt32] = [
                    0x2320, 0x2321, 0x23AE,
                    0x239B, 0x239C, 0x239D, 0x239E, 0x239F, 0x23A0,
                    0x23A1, 0x23A2, 0x23A3, 0x23A4, 0x23A5, 0x23A6,
                    0x23A7, 0x23A8, 0x23A9, 0x23AA, 0x23AB, 0x23AC, 0x23AD,
                    0x23B0, 0x23B1, 0x23B8, 0x23B9,
                ]
                var asserted = 0
                var facesSeen = 0
                for family in ["Menlo", "JetBrains Mono", "Apple Symbols", "STIX Two Math"] {
                    guard let face = installedFace(family) else {
                        continue
                    }
                    facesSeen += 1
                    for codePoint in pieces {
                        guard let ink = inkBox(of: codePoint, in: face) else {
                            continue // this face does not carry it
                        }
                        let pen = SymbolFallbackPen.pen(
                            codePoint: codePoint,
                            ink: ink,
                            subpixel: subpixel,
                            glyphMarginX: margin,
                            glyphWidth: cell,
                            slotWidth: slotWidth,
                            slotHeight: slotHeight,
                            baselinePen: baseline
                        )
                        let name = "\(family) U+\(String(codePoint, radix: 16, uppercase: true))"
                        t.expect(
                            abs(pen.x - (margin + subpixel)) < 0.001,
                            desc: "\(name) draws at the face's own column, not centred on its ink"
                        )
                        t.expect(
                            abs(pen.y - baseline) < 0.001,
                            desc: "\(name) draws on the text baseline, not lifted to fit its ink"
                        )
                        asserted += 1
                    }
                }
                t.expect(facesSeen > 0, desc: "at least one fixture face is installed")
                t.expect(
                    asserted >= 12,
                    desc: "the run actually reached the pieces (asserted \(asserted)) — a run that "
                        + "skipped every glyph would otherwise pass having checked nothing"
                )

                // The control. The centring still applies to the symbols it
                // exists for, so this cannot pass by the pen having been turned
                // off: an ordinary symbol from a face whose em is not the
                // primary's must still be moved off the plain pen.
                var movedOne = false
                for family in ["Apple Symbols", "STIX Two Math"] {
                    guard let face = installedFace(family), let ink = inkBox(of: 0x2318, in: face) else {
                        continue
                    }
                    let pen = SymbolFallbackPen.pen(
                        codePoint: 0x2318,
                        ink: ink,
                        subpixel: subpixel,
                        glyphMarginX: margin,
                        glyphWidth: cell,
                        slotWidth: slotWidth,
                        slotHeight: slotHeight,
                        baselinePen: baseline
                    )
                    if abs(pen.x - (margin + subpixel)) >= 0.001 {
                        movedOne = true
                    }
                }
                t.expect(
                    movedOne,
                    desc: "an ordinary symbol is still centred — the exemption is the family's, "
                        + "not the pen being inert"
                )
            }
        }

        // The same oracle at the raster, where the misalignment is visible. One face,
        // one glyph, one plane, and the only difference between the two draws is
        // which pen placed it: the plain pen a PRIMARY face draws through, and
        // the fallback pen a face reached as the symbol fallback draws through.
        // Menlo as its own fallback aligns and a different primary with Menlo as
        // the fallback shifts, so the two planes must be the same bytes.
        //
        // The digests are the golden: they pin the raster itself, so a change
        // that moved the two pens together -- which the equality above would
        // not notice -- still fails here. Regenerate with UBQ_PRINT_GOLDEN=1.
        //
        // They pin the raster of one operating system. CoreText's coverage for
        // a glyph is the OS's to change, and a major release does change it:
        // nine of these pieces hash differently on the release after the one
        // the first table was drawn on, with both pens still agreeing on every
        // one. So there is a table per release, compared on its own release.
        // A release with no table yet prints its block in the paste-ready
        // form, so the run that first meets it also supplies its table; the
        // two-pen equality is unconditional and catches a pen regression on
        // any release. On a release with no table each piece's plane also goes
        // into the log as a base64 PNG, which is how a release's raster is
        // looked at rather than hashed; UBQ_WRITE_RASTERS=<dir> writes the
        // same PNGs to a directory for a reader at a keyboard.
        UBUITestRegister("bracket_pieces_raster_the_same_through_either_pen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let size: CGFloat = 14
                let face = CTFontCreateWithName("Menlo" as CFString, size, nil)
                let cell = advanceWidth(of: face, "M")
                let margin: CGFloat = 1.0
                let slotWidth = Int(ceil(cell + margin * 2.0))
                let slotHeight = Int(ceil(CTFontGetAscent(face) + CTFontGetDescent(face) + margin * 2.0))
                let baseline = CGFloat(ceil(CTFontGetDescent(face))) + margin
                // The test owns its plane rather than reaching for the
                // renderer's: the pen is what is under test, and a scenario that
                // widened a product type's access to observe it would be testing
                // through a seam it had just created.
                guard let plane = CoveragePlane(width: slotWidth, height: slotHeight) else {
                    t.expect(false, desc: "a rasterisation plane could be made")
                    return
                }

                let pieces: [UInt32] = [
                    0x2320, 0x2321, 0x23AE,
                    0x239B, 0x239C, 0x239D, 0x239E, 0x239F, 0x23A0,
                    0x23A1, 0x23A2, 0x23A3, 0x23A4, 0x23A5, 0x23A6,
                    0x23A7, 0x23A8, 0x23A9, 0x23AA, 0x23AB, 0x23AC, 0x23AD,
                    0x23B0, 0x23B1, 0x23B8, 0x23B9,
                ]
                let printing = ProcessInfo.processInfo.environment["UBQ_PRINT_GOLDEN"] != nil
                let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                let goldens = bracketRasterGoldens[osMajor]
                if goldens == nil {
                    print("    no raster goldens for macOS \(osMajor); its block, to paste under that key:")
                }
                let rastersDirectory = ProcessInfo.processInfo.environment["UBQ_WRITE_RASTERS"]
                var compared = 0
                for codePoint in pieces {
                    guard let ink = inkBox(of: codePoint, in: face),
                        let glyph = glyphIdentifier(of: codePoint, in: face)
                    else {
                        continue
                    }
                    let name = "U+" + String(codePoint, radix: 16, uppercase: true)

                    // As the PRIMARY: the plain pen.
                    let asPrimary = plane.draw(glyph, in: face, at: CGPoint(x: margin, y: baseline))

                    // As the symbol FALLBACK: whatever the fallback pen decides.
                    let pen = SymbolFallbackPen.pen(
                        codePoint: codePoint,
                        ink: ink,
                        subpixel: 0,
                        glyphMarginX: margin,
                        glyphWidth: cell,
                        slotWidth: CGFloat(slotWidth),
                        slotHeight: CGFloat(slotHeight),
                        baselinePen: baseline
                    )
                    let asFallback = plane.draw(glyph, in: face, at: pen)

                    t.expect(
                        asPrimary == asFallback,
                        desc: "\(name) rasterises identically as primary and as fallback"
                    )
                    if printing || goldens == nil {
                        print("    \(name): \(hexLiteral(digest(of: asPrimary))),")
                    }
                    // On a release with no table the raster itself goes into the
                    // log as well, one PNG per piece in base64: CI keeps no
                    // artifacts, so the log is where a release's drawing is read,
                    // and twenty-two lines of a few hundred bytes is what that
                    // costs. Decoded on the reading side, it is the picture the
                    // digest above hashes.
                    if goldens == nil, let png = coveragePNG(asPrimary, width: slotWidth, height: slotHeight) {
                        print("    raster \(name) png: \(png.base64EncodedString())")
                    }
                    if let directory = rastersDirectory {
                        writeCoveragePNG(
                            asPrimary,
                            width: slotWidth,
                            height: slotHeight,
                            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
                        )
                    }
                    if let want = goldens?[codePoint] {
                        t.expect(
                            digest(of: asPrimary) == want,
                            desc: "\(name) matches its committed raster golden"
                        )
                    }
                    compared += 1
                }
                t.expect(
                    compared >= 12,
                    desc: "the run reached the pieces (compared \(compared)) — Menlo carries them, "
                        + "so a run that compared nothing has measured the lookup and not the raster"
                )
            }
        }

        // A piece must span exactly its cell: a shortfall leaves a visible
        // break between the rows, and an excess runs into the row beside it -- where the next row's background paints
        // over it, which is why the overhang vanished under a cursor line.
        //
        // Faces do not provide this. At 14pt against a 17px line, Menlo's pieces
        // span 0.97-0.99 of it, Apple Symbols' 0.82-0.84, and STIX Two Math's
        // brace middle 1.60 -- a math face sizes these for display. The fit is
        // what makes all three land on the same seam, so it is asserted on all
        // three rather than on the one that happened to be close.
        UBUITestRegister("tiling_pieces_span_exactly_their_cell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let size: CGFloat = 14
                let metricFace = CTFontCreateWithName("Menlo" as CFString, size, nil)
                let margin = 1
                let boxHeight = Int(ceil(CTFontGetAscent(metricFace) + CTFontGetDescent(metricFace)))
                let slotHeight = boxHeight + margin * 2
                let slotWidth = Int(ceil(advanceWidth(of: metricFace, "M"))) + margin * 2
                guard let plane = CoveragePlane(width: slotWidth, height: slotHeight) else {
                    t.expect(false, desc: "a plane could be made")
                    return
                }

                let pieces: [UInt32] = [
                    0x2320, 0x2321, 0x23AE,
                    0x239B, 0x239C, 0x239D, 0x239E, 0x239F, 0x23A0,
                    0x23A1, 0x23A2, 0x23A3, 0x23A4, 0x23A5, 0x23A6,
                    0x23A7, 0x23A8, 0x23A9, 0x23AA, 0x23AB, 0x23AC, 0x23AD,
                ]
                var fitted = 0
                var facesSeen = 0
                for family in ["Menlo", "JetBrains Mono", "Apple Symbols", "STIX Two Math"] {
                    let face = CTFontCreateWithName(family as CFString, size, nil)
                    var carried = 0
                    for codePoint in pieces {
                        guard let ink = inkBox(of: codePoint, in: face),
                            let glyph = glyphIdentifier(of: codePoint, in: face), ink.height > 0.5
                        else {
                            continue
                        }
                        carried += 1
                        // The atlas's fit, reproduced: scale the height to the
                        // box and pin the ink's bottom to the box's bottom edge.
                        let verticalScale = CGFloat(boxHeight) / ink.height
                        let pen = CGPoint(
                            x: CGFloat(margin),
                            y: CGFloat(margin) / verticalScale - ink.minY
                        )
                        let drawn = plane.draw(glyph, in: face, at: pen, verticalScale: verticalScale)
                        let name = "\(family) U+\(String(codePoint, radix: 16, uppercase: true))"
                        guard let rows = plane.inkRows(drawn) else {
                            t.expect(false, desc: "\(name) drew something")
                            continue
                        }
                        // Top-down rows: the ink must start at the box's top and
                        // end at its bottom, within a pixel of antialiasing.
                        t.expect(
                            abs(rows.first - margin) <= 1,
                            desc: "\(name) starts at the cell's top edge (row \(rows.first), want \(margin))"
                        )
                        t.expect(
                            abs(rows.last - (slotHeight - margin - 1)) <= 1,
                            desc: "\(name) ends at the cell's bottom edge (row \(rows.last), want "
                                + "\(slotHeight - margin - 1))"
                        )
                        fitted += 1
                    }
                    if carried > 0 {
                        facesSeen += 1
                    }
                }
                t.expect(facesSeen >= 2, desc: "more than one face was measured (\(facesSeen))")
                t.expect(
                    fitted >= 40,
                    desc: "the run reached the pieces across the faces (fitted \(fitted)) — a run that "
                        + "measured a handful would not have covered the faces that disagree"
                )
            }
        }

        // The gap itself, which is what was reported: "their vertical line
        // doesn't connect". Every test above measures ONE piece against its
        // cell; this one stacks three the way a tall bracket is actually built
        // and asserts the ink is unbroken from the top of the first to the
        // bottom of the last.
        //
        // A blank row anywhere in that span is the defect, and it is the thing a
        // per-piece assertion cannot see: three pieces can each sit correctly
        // inside their own cell and still leave a hairline between them, which
        // is precisely what a side bearing does.
        UBUITestRegister("a_stacked_bracket_has_no_gap_between_its_rows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let size: CGFloat = 14
                let metricFace = CTFontCreateWithName("Menlo" as CFString, size, nil)
                let margin = 1
                let cellHeight = Int(ceil(CTFontGetAscent(metricFace) + CTFontGetDescent(metricFace)))
                let rows = 3
                let planeHeight = cellHeight * rows + margin * 2
                let planeWidth = Int(ceil(advanceWidth(of: metricFace, "M"))) + margin * 2
                guard let plane = CoveragePlane(width: planeWidth, height: planeHeight) else {
                    t.expect(false, desc: "a plane could be made")
                    return
                }

                // Upper hook, extension, lower hook — one bracket, three rows.
                let families: [(name: String, pieces: [UInt32])] = [
                    ("left parenthesis", [0x239B, 0x239C, 0x239D]),
                    ("right parenthesis", [0x239E, 0x239F, 0x23A0]),
                    ("left square bracket", [0x23A1, 0x23A2, 0x23A3]),
                    ("right square bracket", [0x23A4, 0x23A5, 0x23A6]),
                    ("left curly bracket", [0x23A7, 0x23AA, 0x23A9]),
                    ("right curly bracket", [0x23AB, 0x23AA, 0x23AD]),
                    ("integral", [0x2320, 0x23AE, 0x2321]),
                ]
                var stacked = 0
                for family in ["Menlo", "JetBrains Mono", "Apple Symbols", "STIX Two Math"] {
                    let face = CTFontCreateWithName(family as CFString, size, nil)
                    for bracket in families {
                        let glyphs = bracket.pieces.compactMap { glyphIdentifier(of: $0, in: face) }
                        let inks = bracket.pieces.compactMap { inkBox(of: $0, in: face) }
                        guard glyphs.count == rows, inks.count == rows,
                            inks.allSatisfy({ $0.height > 0.5 })
                        else {
                            continue // this face does not carry the whole family
                        }
                        plane.clear()
                        for row in 0..<rows {
                            let verticalScale = CGFloat(cellHeight) / inks[row].height
                            // Bottom-up user space: row 0 is the topmost cell.
                            let cellBottom = CGFloat(planeHeight - margin - (row + 1) * cellHeight)
                            plane.add(
                                glyphs[row],
                                in: face,
                                at: CGPoint(
                                    x: CGFloat(margin),
                                    y: cellBottom / verticalScale - inks[row].minY
                                ),
                                verticalScale: verticalScale
                            )
                        }
                        let drawn = plane.bytes()
                        let name = "\(family) \(bracket.name)"
                        guard let span = plane.inkRows(drawn) else {
                            t.expect(false, desc: "\(name) drew something")
                            continue
                        }
                        // No blank row anywhere between the first and last ink.
                        var blank: Int?
                        for row in span.first...span.last {
                            var inked = false
                            for column in 0..<planeWidth where drawn[row * planeWidth + column] >= 128 {
                                inked = true
                                break
                            }
                            if !inked {
                                blank = row
                                break
                            }
                        }
                        t.expect(
                            blank == nil,
                            desc: "\(name) is unbroken down the stack"
                                + (blank.map { " — row \($0) is empty" } ?? "")
                        )
                        // And it fills the three cells rather than sitting inside one.
                        t.expect(
                            span.last - span.first >= cellHeight * rows - rows,
                            desc: "\(name) spans all three rows (\(span.last - span.first + 1) of "
                                + "\(cellHeight * rows))"
                        )
                        stacked += 1
                    }
                }
                t.expect(
                    stacked >= 7,
                    desc: "whole families were stacked (\(stacked)) — a run that found no complete "
                        + "family would pass having assembled nothing"
                )
            }
        }

        UBUITestRegister("symbol_fallback_glyph_stays_inside_its_cell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Measured, not assumed: real proportional faces, real ink from
                // CoreText, and a cell derived the way a terminal derives one —
                // the primary's own advance at a real size.
                guard let primary = installedFace("Menlo") else {
                    t.expect(false, desc: "the fixture face Menlo is installed")
                    return
                }
                let cell = advanceWidth(of: primary, "M")
                t.expect(cell > 0, desc: "the primary has an advance to build a cell from")
                // The slot carries a margin either side of the cell box, which
                // is the room the clamp is allowed to use.
                let margin: CGFloat = 1.0
                let slotWidth = cell + margin * 2.0
                let slotHeight = CGFloat(ceil(CTFontGetAscent(primary) + CTFontGetDescent(primary))) + margin * 2.0
                let baseline = CGFloat(ceil(CTFontGetDescent(primary))) + margin

                var overhangingWithoutTheCentring = 0
                var wider = 0
                for family in ["Apple Symbols", "STIX Two Math"] {
                    guard let face = installedFace(family) else {
                        continue
                    }
                    for codePoint: UInt32 in [0x2318, 0x2211, 0x23BF, 0x25CF, 0x2192] {
                        guard let ink = inkBox(of: codePoint, in: face) else {
                            continue
                        }
                        let pen = SymbolFallbackPen.pen(
                            codePoint: codePoint,
                            ink: ink,
                            subpixel: 0,
                            glyphMarginX: margin,
                            glyphWidth: cell,
                            slotWidth: slotWidth,
                            slotHeight: slotHeight,
                            baselinePen: baseline
                        )
                        let left = pen.x + ink.origin.x
                        let bottom = pen.y + ink.origin.y
                        let name = "\(family) U+\(String(codePoint, radix: 16, uppercase: true))"
                        // Ink that FITS must end up wholly inside the slot.
                        // Ink that does not fit cannot be contained by a
                        // translation — the slot bitmap crops it — so the claim
                        // there is that the crop is centred rather than spent
                        // on one edge.
                        if ink.width <= slotWidth {
                            t.expect(
                                left >= -0.5 && left + ink.width <= slotWidth + 0.5,
                                desc: "\(name) keeps its ink inside the slot horizontally"
                            )
                        } else {
                            wider += 1
                            // Centred means it hangs off each edge by half. The clamp
                            // this replaced put left at exactly 0 and spent the
                            // whole overflow on the right, so a left edge still
                            // at zero is the shape being ruled out — asserted
                            // sharply, because the overflow can be a pixel or
                            // two and a tolerance would swallow it.
                            t.expect(
                                left < 0,
                                desc: "\(name) is wider than the cell and hangs off the left edge too, not only the right"
                            )
                            t.expect(
                                abs((-left) - (left + ink.width - slotWidth)) <= 1.0,
                                desc: "\(name) splits its overflow evenly between the two edges"
                            )
                        }
                        if ink.height <= slotHeight {
                            t.expect(
                                bottom >= -0.5 && bottom + ink.height <= slotHeight + 0.5,
                                desc: "\(name) keeps its ink inside the slot vertically"
                            )
                        } else {
                            t.expect(
                                abs(bottom + ink.height - slotHeight + bottom) <= 1.0,
                                desc: "\(name) is taller than the cell, so its crop is centred rather than one-sided"
                            )
                        }
                        // The control: the plain pen is where the glyph would
                        // land with no symbol-face handling at all. If none of
                        // these overhang there, the placement above is proving
                        // nothing about proportional faces.
                        let plainLeft = margin + ink.origin.x
                        if plainLeft < 0 || plainLeft + ink.width > slotWidth {
                            overhangingWithoutTheCentring += 1
                        }
                    }
                }
                t.expect(
                    overhangingWithoutTheCentring > 0,
                    desc: "at least one real symbol glyph WOULD overhang at the plain pen, so the centring is doing work"
                )
                t.expect(
                    wider > 0,
                    desc: "at least one real symbol glyph is wider than the cell, so the centred-crop branch is exercised"
                )
            }
        }
    }
}

// File scope because a scenario is a C function pointer, which cannot capture
// the context a type's static member carries.

/// An installed family's face at a fixed size, or nil when CoreText substituted.
///
/// - Parameter family: The family name to resolve.
/// - Returns: The face, or nil when the family is not installed.
@MainActor
private func symbolFallbackSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = symbolFallbackSurface(under: subview) {
            return found
        }
    }
    return nil
}

private func installedFace(_ family: String) -> CTFont? {
    let font = CTFontCreateWithName(family as CFString, 14.0, nil)
    guard (CTFontCopyFamilyName(font) as String).compare(family, options: .caseInsensitive) == .orderedSame else {
        return nil
    }
    return font
}

/// A face's advance for one character, which is how a cell width is derived.
///
/// - Parameters:
///   - font: The face to measure.
///   - character: The character to advance over.
/// - Returns: The advance in points, or zero when the face lacks the glyph.
private func advanceWidth(of font: CTFont, _ character: Character) -> CGFloat {
    let units = Array(String(character).utf16)
    var glyphs = Array(repeating: CGGlyph(), count: units.count)
    let mapped = units.withUnsafeBufferPointer { unitBuffer in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
            CTFontGetGlyphsForCharacters(font, unitBuffer.baseAddress!, glyphBuffer.baseAddress!, units.count)
        }
    }
    guard mapped, glyphs[0] != 0 else {
        return 0
    }
    return CGFloat(ceil(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs[0], nil, 1)))
}

/// A code point's ink bounding box in a face.
///
/// - Parameters:
///   - codePoint: The character to measure.
///   - font: The face carrying it.
/// - Returns: The ink rect, or nil when the face lacks the glyph or inks nothing.
private func inkBox(of codePoint: UInt32, in font: CTFont) -> CGRect? {
    guard let scalar = UnicodeScalar(codePoint) else {
        return nil
    }
    let units = Array(String(scalar).utf16)
    var glyphs = Array(repeating: CGGlyph(), count: units.count)
    let mapped = units.withUnsafeBufferPointer { unitBuffer in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
            CTFontGetGlyphsForCharacters(font, unitBuffer.baseAddress!, glyphBuffer.baseAddress!, units.count)
        }
    }
    guard mapped, glyphs[0] != 0 else {
        return nil
    }
    let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs[0], nil, 1)
    return ink.width > 0 && ink.height > 0 ? ink : nil
}

/// The Symbol Fallback row's control, found by walking the catalog the Settings
/// window builds its panes from.
///
/// - Returns: The control, or nil when no such row is in the catalog.
@MainActor
private func symbolFallbackControl() -> SettingsRow.Control? {
    for category in SettingsCatalog.categories() {
        guard case .pane(let pane) = category.content else {
            continue
        }
        for card in pane.cards {
            for row in card.rows where row.id == "font.symbol_fallback" {
                return row.control.resolved()
            }
        }
    }
    return nil
}

/// The first installed family the row offers, past the bundled entry.
///
/// - Returns: The family name, or nil when the row offers none.
@MainActor
private func firstOfferedFamily() -> String? {
    guard case .menu(let options, _, _, _)? = symbolFallbackControl() else {
        return nil
    }
    return options.dropFirst().first.map(familyOfLabel)
}

/// The mark the row puts on a family that does not cover the symbol blocks.
private let limitedCoverageMark = " — limited symbol coverage"

/// The family a row label names, with any coverage mark taken off.
///
/// The labels are not family names for the marked half, and the value the row
/// writes is always the bare family — so a case comparing a label to a
/// configured value has to come through here.
///
/// - Parameter label: The label as the row presents it.
/// - Returns: The family name.
private func familyOfLabel(_ label: String) -> String {
    label.hasSuffix(limitedCoverageMark) ? String(label.dropLast(limitedCoverageMark.count)) : label
}

/// The family Core routes a symbol code point with, through the same accessor
/// the font route reads.
///
/// - Returns: The resolved family name, including the default technical symbol family.
@MainActor
private func symbolFallbackFamily() -> String {
    String(Ubiquitty.Preferences.Effective.symbolFallbackFamily(Ubiquitty.Preferences.values().pointee))
}

/// Whether the sandboxed config file carries `family` under the
/// `symbol_fallback` key.
///
/// The written KEY is the claim, and only the file shows it: in memory the
/// symbol family and the alias resolve to the same string, so a picker that
/// wrote the alias would read back identically. The suite points
/// XDG_CONFIG_HOME at a throwaway directory and the settings setters write
/// there.
///
/// - Parameter family: The family the picker was set to.
/// - Returns: True when the symbol key names it.
private func configFileNamesSymbolFallback(_ family: String) -> Bool {
    guard let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
        let text = try? String(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("ubiquitty/config.toml"), encoding: .utf8)
    else {
        return false
    }
    return text.contains("symbol_fallback = \"\(family)\"")
}

/// Whether CoreText reports a family as fixed-pitch.
///
/// - Parameter family: The installed family name.
/// - Returns: True when the family carries the monospace trait.
private func isMonospaced(_ family: String) -> Bool {
    let font = CTFontCreateWithName(family as CFString, 12.0, nil)
    return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
}

/// The glyph a face maps a code point to, or nil when it carries none.
private func glyphIdentifier(of codePoint: UInt32, in font: CTFont) -> CGGlyph? {
    guard let scalar = UnicodeScalar(codePoint) else {
        return nil
    }
    let units = Array(String(scalar).utf16)
    var glyphs = Array(repeating: CGGlyph(), count: units.count)
    let mapped = units.withUnsafeBufferPointer { unitBuffer in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
            CTFontGetGlyphsForCharacters(font, unitBuffer.baseAddress!, glyphBuffer.baseAddress!, units.count)
        }
    }
    guard mapped, glyphs[0] != 0 else {
        return nil
    }
    return glyphs[0]
}

/// One piece's coverage plane as a greyscale PNG: what the digest hashes, as a
/// picture. Best effort by design — a plane that cannot be encoded costs the
/// scenario nothing, because the picture is for a reader and not an assertion.
private func coveragePNG(_ plane: [UInt8], width: Int, height: Int) -> Data? {
    guard plane.count == width * height, width > 0, height > 0 else { return nil }
    var bytes = plane
    let data = NSMutableData()
    guard
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private func writeCoveragePNG(_ plane: [UInt8], width: Int, height: Int, to url: URL) {
    guard let data = coveragePNG(plane, width: width, height: height) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

/// A digest in the table's own spelling: sixteen upper-case hex digits in
/// groups of four, so a printed block pastes in without a hand edit.
private func hexLiteral(_ value: UInt64) -> String {
    let digits = Array(String(format: "%016llX", value))
    return "0x" + stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<$0 + 4]) }.joined(separator: "_")
}

/// FNV-1a over a coverage plane, so a golden is one comparable number.
private func digest(of plane: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in plane {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return hash
}

// The committed raster goldens: Menlo at 14pt, drawn through the plain pen,
// one table per macOS release under that release's major version. The digests
// are a release's CoreText output and the scenario compares them only on that
// release. To add a release, run the scenario on it: it prints the block for a
// release it has no table for (UBQ_PRINT_GOLDEN=1 prints it for one it has).
private let bracketRasterGoldens: [Int: [UInt32: UInt64]] = [
    26: [
        0x2320: 0xC8EC_58B8_0F27_AB5E, 0x2321: 0x0DD6_49A2_FCD6_05E6, 0x23AE: 0x41DF_64CE_13C5_9ACE,
        0x239B: 0x27E3_862C_F2ED_36A9, 0x239C: 0x481D_141E_5796_2E00, 0x239D: 0x30B6_C66D_070B_CC9C,
        0x239E: 0xFBC7_EF90_1261_4354, 0x239F: 0x10C9_D941_8408_E6BD, 0x23A0: 0x95DB_EAB7_9B48_3C27,
        0x23A1: 0xA17E_CEDB_BC9F_9E59, 0x23A2: 0x481D_141E_5796_2E00, 0x23A3: 0xD68A_8586_AE16_C574,
        0x23A4: 0x1737_D5A6_F209_3ABD, 0x23A5: 0xF6A3_4C21_E2F1_31AC, 0x23A6: 0xA3B4_DDB9_7967_CBA4,
        0x23A7: 0xA83E_AB5E_5993_2B28, 0x23A8: 0xAE6E_0565_2708_EF01, 0x23A9: 0x7C84_9686_D9FB_CF19,
        0x23AA: 0xB432_08A9_620A_8841, 0x23AB: 0x079D_D8E2_6D6B_96B3, 0x23AC: 0x0502_03EA_A620_EBBA,
        0x23AD: 0x5F82_0A2D_1257_D220,
    ],
    27: [
        0x2320: 0x7067_DFBD_DE36_8844,
        0x2321: 0x90E8_B453_74D7_616F,
        0x23AE: 0x41DF_64CE_13C5_9ACE,
        0x239B: 0x27E3_862C_F2ED_36A9,
        0x239C: 0x481D_141E_5796_2E00,
        0x239D: 0x30B6_C66D_070B_CC9C,
        0x239E: 0xFBC7_EF90_1261_4354,
        0x239F: 0xB4D0_D347_A141_ACA7,
        0x23A0: 0x95DB_EAB7_9B48_3C27,
        0x23A1: 0x60B7_6917_487E_3022,
        0x23A2: 0x481D_141E_5796_2E00,
        0x23A3: 0x3593_9D6A_B97F_4932,
        0x23A4: 0xF402_A238_67BB_AE47,
        0x23A5: 0xF6A3_4C21_E2F1_31AC,
        0x23A6: 0x8A72_42F4_70C6_9696,
        0x23A7: 0xA83E_AB5E_5993_2B28,
        0x23A8: 0x746F_E8F3_B80F_0220,
        0x23A9: 0x7C84_9686_D9FB_CF19,
        0x23AA: 0xB432_08A9_620A_8841,
        0x23AB: 0x079D_D8E2_6D6B_96B3,
        0x23AC: 0x73A1_CEB7_1646_DE71,
        0x23AD: 0x5F82_0A2D_1257_D220,
    ],
]

/// A grayscale plane the scenario draws one glyph into, to compare two pens.
///
/// The test's own rather than the renderer's, because what is under test is
/// where the pen puts a glyph: observing that through a product type would
/// have meant widening its access for the test that needed it.
private final class CoveragePlane {
    private let context: CGContext
    private let width: Int
    private let height: Int

    init?(width: Int, height: Int) {
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }
        self.context = context
        self.width = width
        self.height = height
    }

    /// Clears the plane, draws one glyph at `origin` with its height scaled,
    /// and returns the bytes — the atlas's fitted draw, reproduced.
    func draw(_ glyph: CGGlyph, in font: CTFont, at origin: CGPoint, verticalScale: CGFloat) -> [UInt8] {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.saveGState()
        context.scaleBy(x: 1, y: verticalScale)
        var glyphs = [glyph]
        var positions = [origin]
        CTFontDrawGlyphs(font, &glyphs, &positions, 1, context)
        context.restoreGState()
        guard let data = context.data else {
            return []
        }
        return Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: width * height
            )
        )
    }

    /// Clears the plane to empty, for a stack built from several draws.
    func clear() {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws one more glyph into the plane without clearing what is there.
    func add(_ glyph: CGGlyph, in font: CTFont, at origin: CGPoint, verticalScale: CGFloat) {
        context.setFillColor(gray: 1, alpha: 1)
        context.saveGState()
        context.scaleBy(x: 1, y: verticalScale)
        var glyphs = [glyph]
        var positions = [origin]
        CTFontDrawGlyphs(font, &glyphs, &positions, 1, context)
        context.restoreGState()
    }

    /// The plane's bytes as they stand.
    func bytes() -> [UInt8] {
        guard let data = context.data else {
            return []
        }
        return Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: width * height
            )
        )
    }

    /// The first and last rows carrying ink, top-down, or nil when the plane is blank.
    func inkRows(_ plane: [UInt8]) -> (first: Int, last: Int)? {
        var first: Int?
        var last: Int?
        for row in 0..<height {
            for column in 0..<width where plane[row * width + column] >= 128 {
                if first == nil { first = row }
                last = row
                break
            }
        }
        guard let f = first, let l = last else { return nil }
        return (f, l)
    }

    /// Clears the plane, draws one glyph at `origin`, and returns the bytes.
    func draw(_ glyph: CGGlyph, in font: CTFont, at origin: CGPoint) -> [UInt8] {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        var glyphs = [glyph]
        var positions = [origin]
        CTFontDrawGlyphs(font, &glyphs, &positions, 1, context)
        guard let data = context.data else {
            return []
        }
        return Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: width * height
            )
        )
    }
}
