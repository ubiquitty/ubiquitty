// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_macos_settings_search.swift — the first Swift host
// test, setting the repo's Swift-test precedent: pins the pure
// Settings-search data model
// (SettingsModel.swift settingsSearchHits() + SettingsSearchHit.matches())
// on a SYNTHETIC catalog. Compiled by plain `xcrun swiftc` together with
// SettingsModel.swift alone — no bridging header, no C++ interop, no app
// module — so the flatten + filter logic is exercised headlessly. The
// control closures and .custom AnyView builders are constructed but never
// invoked (the flattener reads only labels/titles/ids), so no view is ever
// realized.
//
// Convention matches the repo's C++ tests: a check() helper printing
// "FAIL file:line", a failure count, non-zero exit on any failure.
//

import SwiftUI

var failures = 0

func check(
    _ condition: Bool,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

// A row whose control is never exercised — the flattener reads only
// label/detail/id, so an inert toggle stands in for every control kind.
func inertRow(id: String, _ label: String, detail: String? = nil) -> SettingsRow {
    SettingsRow(
        id: id,
        label,
        detail: detail,
        control: .toggle(get: { false }, set: { _ in })
    )
}

// Synthetic catalog: two data-driven panes + two bespoke (.custom)
// categories, mirroring the real catalog's shapes without touching Settings.
func makeCatalog() -> [SettingsCategory] {
    let appearance = SettingsPane(cards: [
        SettingsCard(
            title: "Cursor",
            rows: [
                inertRow(id: "cursor.shape", "Cursor style", detail: "Block, bar, or underline"),
                inertRow(id: "cursor.blink", "Blinking"), // no detail -> inherits the card title
            ]
        ),
        SettingsCard(
            title: nil,
            rows: [
                inertRow(id: "appearance.background_opacity", "Background opacity", detail: "Window translucency")
            ]
        ),
    ])
    let fonts = SettingsPane(cards: [
        SettingsCard(
            title: "Font",
            rows: [
                inertRow(id: "font.size", "Font size", detail: "Point size for the grid")
            ]
        )
    ])
    return [
        SettingsCategory(
            id: "appearance",
            title: "Appearance",
            symbol: "paintpalette",
            content: .pane(appearance)
        ),
        SettingsCategory(
            id: "fonts",
            title: "Fonts",
            symbol: "textformat",
            content: .pane(fonts)
        ),
        SettingsCategory(
            id: "themes",
            title: "Themes",
            symbol: "swatchpalette",
            content: .custom { AnyView(EmptyView()) },
            searchKeywords: ["Theme Mode", "dark"]
        ),
        SettingsCategory(
            id: "keys",
            title: "Keyboard",
            symbol: "keyboard",
            content: .custom { AnyView(EmptyView()) }
        ),
    ]
}

@main
struct TestMain {
    static func main() {
        var navigation = SettingsNavigation(selection: "appearance")
        check(!navigation.canGoBack && !navigation.canGoForward, "initial page has no history")
        navigation.goBack()
        navigation.goForward()
        check(navigation.selection == "appearance", "history boundaries keep the current page")
        navigation.select("fonts")
        navigation.select("fonts")
        navigation.select("themes")
        navigation.goBack()
        check(navigation.selection == "fonts", "back visits the previous page")
        check(navigation.canGoBack && navigation.canGoForward, "middle of history supports both directions")
        navigation.goBack()
        check(navigation.selection == "appearance", "reselecting a page does not duplicate its history")
        navigation.goForward()
        check(navigation.selection == "fonts", "forward revisits the next page")
        navigation.select("accessibility")
        check(!navigation.canGoForward, "a new destination replaces the forward branch")
        navigation.goBack()
        check(navigation.selection == "fonts", "branching preserves the preceding history")
        navigation.goForward()
        check(navigation.selection == "accessibility", "forward follows the new branch")

        let catalog = makeCatalog()
        let nested =
            catalog + [
                SettingsCategory(
                    id: "font-features",
                    title: "Font Features",
                    symbol: "textformat.alt",
                    parentID: "fonts",
                    content: .custom { AnyView(EmptyView()) },
                    searchKeywords: ["OpenType", "Stylistic Sets"]
                )
            ]
        check(nested.sidebarCategoryID(for: "font-features") == "fonts", "subpages select their parent in the sidebar")
        check(nested.sidebarCategoryID(for: "appearance") == "appearance", "top-level pages select themselves")
        let nestedHits = nested.settingsSearchHits()
        check(
            nestedHits.first(where: { $0.categoryID == "font-features" })?.categoryTitle == "Fonts › Font Features",
            "nested search results show their category path"
        )
        check(
            nestedHits.contains(where: { $0.categoryID == "font-features" && $0.matches("Fonts") && $0.matches("OpenType") }),
            "subpages remain discoverable by parent and setting keywords"
        )
        let hits = catalog.settingsSearchHits()

        // --- Flattening shape -------------------------------------------
        // 4 pane rows + 2 custom title-level hits, in sidebar order.
        check(hits.count == 6, "6 hits, got \(hits.count)")
        check(
            hits.map(\.label) == [
                "Cursor style", "Blinking", "Background opacity",
                "Font size", "Themes", "Keyboard",
            ],
            "sidebar order preserved, got \(hits.map(\.label))"
        )

        // A pane row's hit carries its category identity + the stable setting address so
        // a match can scroll to and pulse the exact control.
        let cursorStyle = hits[0]
        check(cursorStyle.categoryID == "appearance", "categoryID")
        check(cursorStyle.categoryTitle == "Appearance", "categoryTitle")
        check(cursorStyle.categorySymbol == "paintpalette", "categorySymbol")
        check(cursorStyle.rowID != nil, "pane hit carries rowID")
        check(
            cursorStyle.id == "appearance:cursor.shape",
            "hit id is independent of display text, got \(cursorStyle.id)"
        )
        check(makeCatalog().settingsSearchHits().map(\.id) == hits.map(\.id), "catalogue refresh preserves identities")
        let localized = [
            SettingsCategory(
                id: "appearance",
                title: "Darstellung",
                symbol: "paintpalette",
                content: .pane(
                    SettingsPane(cards: [
                        SettingsCard(rows: [
                            inertRow(id: "cursor.shape", "Form"),
                            inertRow(id: "cursor.blink", "Form"),
                        ])
                    ])
                )
            )
        ]
        .settingsSearchHits()
        check(localized[0].id == cursorStyle.id, "translating a label preserves its reveal target")
        check(localized[0].id != localized[1].id, "duplicate display labels remain distinct settings")

        // detail falls back to the CARD title when the row has none — a
        // query matching the card's group name finds its untitled rows.
        check(
            hits[1].detail == "Cursor",
            "row without detail inherits card title, got \(String(describing: hits[1].detail))"
        )
        // ... and stays nil when the card is untitled too.
        check(hits[2].detail == "Window translucency", "explicit detail kept")

        // A .custom category contributes one title-level hit that opens the
        // pane: label = title, rowID = nil, detail = joined searchKeywords.
        let themes = hits[4]
        check(themes.id == "themes" && themes.rowID == nil, "custom hit shape")
        check(
            themes.detail == "Theme Mode, dark",
            "custom searchKeywords joined, got \(String(describing: themes.detail))"
        )
        let keyboard = hits[5]
        check(keyboard.detail == nil, "custom with no keywords has nil detail")

        // id is stable + unique across the catalog (no churn while filtering).
        check(Set(hits.map(\.id)).count == hits.count, "hit ids unique")
        check(
            catalog.settingsSearchHits().map(\.id) == hits.map(\.id),
            "hit ids stable across rebuilds"
        )

        // --- matches() filter -------------------------------------------
        func labels(_ query: String) -> [String] {
            hits.filter { $0.matches(query) }.map(\.label)
        }
        // By label, case-insensitively.
        check(labels("style") == ["Cursor style"], "label match, got \(labels("style"))")
        check(labels("STYLE") == ["Cursor style"], "case-insensitive query")
        // By detail — including the card-title fallback and custom keywords.
        check(labels("translucency") == ["Background opacity"], "detail match")
        check(labels("theme mode") == ["Themes"], "custom keyword match via detail")
        // By category title: every hit of that category surfaces.
        check(
            labels("appearance") == ["Cursor style", "Blinking", "Background opacity"],
            "category-title match surfaces all its rows, got \(labels("appearance"))"
        )
        // The card-title fallback makes 'Cursor' find the untitled row too.
        check(
            labels("curso") == ["Cursor style", "Blinking"],
            "card-title fallback matches, got \(labels("curso"))"
        )
        // No match -> empty.
        check(labels("zzz-no-such-setting").isEmpty, "no-match returns empty")

        if failures == 0 {
            print("test_macos_settings_search: all passed")
        } else {
            print("test_macos_settings_search: \(failures) failure(s)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
