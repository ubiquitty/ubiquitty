// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// FindBarMemory.swift — whether the find bar matches case.
//
// A frontend-only preference, like the window level: no other frontend has this
// bar, and nothing in Core has an opinion about it. It outlives the window that
// was asked, because a reader who turned case-matching on meant searching, not
// searching in this window.

import AppKit

@MainActor
@objc(UBFindBarMemory)
public final class FindBarMemory: NSObject {
    // The one key both shells read and write.
    private static let defaultsKey = "UBFindCaseSensitive"

    /// Whether the find bar was last left matching case.
    ///
    /// Off is the default: a search that quietly ignored half the matches would
    /// be the harder default to notice. The regex toggle beside it is not
    /// remembered, and that is the choice rather than an omission: a pattern is
    /// written for one search, and a bar that opened in regex mode would read
    /// the next literal term as one.
    ///
    /// - Returns: Whether to open matching case.
    @objc
    public static func isCaseSensitive() -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Remembers whether the find bar matches case.
    ///
    /// - Parameter isCaseSensitive: What the reader just chose.
    @objc(setCaseSensitive:)
    public static func setCaseSensitive(_ isCaseSensitive: Bool) {
        UserDefaults.standard.set(isCaseSensitive, forKey: defaultsKey)
    }
}
