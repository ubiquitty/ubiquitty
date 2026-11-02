// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectRecents.swift — the most-recently-used connection target per
// ConnectKind, so Beam's per-kind commands can drill straight into "the
// hosts you actually use" instead of always bouncing to the Connect form.
//

import Foundation

enum ConnectRecents {
    private static let maxPerKind = 8
    private static let defaultsKey = "UBConnectRecents"

    // Most-recent-first. Never contains blank/whitespace-only targets — a
    // blank target (attach-to-main tmux, "local" host) has no meaningful
    // recent to show and would otherwise fill the list with empty rows.
    static func recent(for kind: ConnectKind) -> [String] {
        load()[kind.rawValue] ?? []
    }

    // Every kind's recents from one UserDefaults read — Beam builds all its
    // recent rows per palette open, so it calls this instead of recent(for:)
    // per kind (which would re-read + re-decode the blob once per kind).
    static func recent(for kinds: [ConnectKind]) -> [ConnectKind: [String]] {
        let all = load()
        var result: [ConnectKind: [String]] = [:]
        for kind in kinds {
            if let list = all[kind.rawValue], !list.isEmpty { result[kind] = list }
        }
        return result
    }

    static func record(_ target: String, for kind: ConnectKind) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = load()
        var list = all[kind.rawValue] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxPerKind { list.removeLast(list.count - maxPerKind) }
        all[kind.rawValue] = list
        save(all)
    }

    private static func load() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    private static func save(_ all: [String: [String]]) {
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}
