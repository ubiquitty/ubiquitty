// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontRoutePreview.swift — sample strings for the Settings font diagnostics preview.

import Foundation

struct FontPreviewSample: Identifiable {
    enum ID: String {
        case code, characters, languages, drawing, underlines, mixed
        case han, kana, hangul, arabic, hebrew, cyrillic, greek, indic, southeastAsian, emoji, symbols, math
    }
    let id: ID
    let title: String
    let text: String

    init(_ id: ID, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

enum FontRoutePreview {
    static let samples: [FontPreviewSample] = [
        .init(.han, title: "Han / CJK", text: "東京オペレーション端末"),
        .init(.kana, title: "Kana", text: "オペレーション"),
        .init(.hangul, title: "Hangul", text: "가나다 테스트"),
        .init(.arabic, title: "Arabic", text: "سلام دنیا"),
        .init(.hebrew, title: "Hebrew", text: "שלום עולם"),
        .init(.cyrillic, title: "Cyrillic", text: "Привет, мир"),
        .init(.greek, title: "Greek", text: "γειά σου"),
        .init(.indic, title: "Devanagari", text: "नमस्ते"),
        .init(.southeastAsian, title: "Thai", text: "ภาษาไทย"),
        .init(.emoji, title: "Emoji", text: "😀👨‍👩‍👧‍👦"),
        .init(.symbols, title: "Symbols", text: " ─ ◆"),
        .init(.math, title: "Math", text: "𝟘∑∞"),
    ]
}
