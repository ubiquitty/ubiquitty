// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import UbiquittyKit
import UbiquittyRenderKit

// BoxGlyphRouteScenarios.swift — which face draws a box-drawing cell.
//
// Core's routing is font-first for the line and terminal-graphics families:
// prefersProcedural declines them, and CellInstanceBuilder falls to geometry
// only when the atlas answers absent. The atlas's coverage probe read one face,
// so a primary lacking the glyph sent the cell to geometry even where the
// symbol fallback carried it — the configured fallback could not win a box cell
// at all.
//
// The ladder is two faces and stops: a box scene's strokes must meet, and
// strokes gathered per code point from the system cascade arrive at several
// weights on several rows.

/// Registers the box-glyph route scenarios with the UI-test runner.
///
/// A scenario is a C function pointer, so each closure below carries no
/// context.
enum BoxGlyphRouteScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("box_glyph_falls_to_the_symbol_face_the_primary_lacks") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Real installed faces, because the claim is about real coverage:
                // Menlo carries the box-drawing rules and no scan line,
                // and Apple Symbols carries both.
                guard let primary = installedFace("Menlo"), let symbol = installedFace("Apple Symbols") else {
                    t.expect(false, desc: "the fixture faces Menlo and Apple Symbols are installed")
                    return
                }
                // The fixture is only meaningful while these hold, so they are
                // asserted rather than assumed: a Menlo that gained the elbow
                // would make the case pass without routing anywhere.
                t.expect(
                    BoxFaceLadder.faceCarrying(0x2502, primary: primary, symbolFallback: nil) != nil,
                    desc: "the primary carries the rule it is the primary for"
                )
                t.expect(
                    BoxFaceLadder.faceCarrying(0x23BA, primary: primary, symbolFallback: nil) == nil,
                    desc: "and does not carry the scan line"
                )

                let routed = BoxFaceLadder.faceCarrying(0x23BA, primary: primary, symbolFallback: symbol)
                t.expect(routed != nil, desc: "with a symbol fallback the elbow is carried after all")
                t.expect(
                    routed.map { CTFontCopyFamilyName($0.font) as String } == "Apple Symbols",
                    desc: "and it is the symbol fallback that carries it, not the primary"
                )
                t.expect(
                    routed?.glyph != 0,
                    desc: "the glyph is the fallback's own, not its notdef"
                )
            }
        }

        UBUITestRegister("box_glyph_prefers_the_primary_over_the_symbol_face") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let primary = installedFace("Menlo"), let symbol = installedFace("Apple Symbols") else {
                    t.expect(false, desc: "the fixture faces Menlo and Apple Symbols are installed")
                    return
                }
                // Both carry U+2502. The primary has to win, or a configured
                // symbol face would quietly redraw every rule in the scene at
                // its own weight — the fault this ladder exists to avoid.
                let routed = BoxFaceLadder.faceCarrying(0x2502, primary: primary, symbolFallback: symbol)
                t.expect(
                    BoxFaceLadder.faceCarrying(0x2502, primary: symbol, symbolFallback: nil) != nil,
                    desc: "the symbol face carries the rule too, so the preference below is a real choice"
                )
                t.expect(
                    routed.map { CTFontCopyFamilyName($0.font) as String } == "Menlo",
                    desc: "a glyph both faces carry is drawn from the primary"
                )
            }
        }

        UBUITestRegister("box_glyph_without_a_symbol_face_stays_procedural") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let primary = installedFace("Menlo") else {
                    t.expect(false, desc: "the fixture face Menlo is installed")
                    return
                }
                // No fallback loaded is the case that must still reach geometry:
                // an absent answer here is what keeps Core on the procedural
                // path rather than drawing a notdef box.
                t.expect(
                    BoxFaceLadder.faceCarrying(0x23BA, primary: primary, symbolFallback: nil) == nil,
                    desc: "no symbol face and no primary glyph is an absent answer, so the cell stays geometry"
                )
            }
        }
    }
}

// File scope because a scenario is a C function pointer, which cannot capture
// the context a type's static member carries.

/// An installed family's face, or nil when CoreText substituted for the name.
///
/// The substitution check is the point: a machine without the family would
/// otherwise hand back Helvetica and the case would assert about a face nobody
/// named.
///
/// - Parameter family: The family name to resolve.
/// - Returns: The face, or nil when the family is not installed.
private func installedFace(_ family: String) -> CTFont? {
    let font = CTFontCreateWithName(family as CFString, 14.0, nil)
    guard (CTFontCopyFamilyName(font) as String).compare(family, options: .caseInsensitive) == .orderedSame else {
        return nil
    }
    return font
}
