// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShippedFamilyLookupSmoke.swift — a family looked up by name in a framework
// host finds a shipped family the system has no copy of, from the process's
// first call.
//
// The framework registers its shipped fonts for the host's process, and the
// lookup that chooses the preferred family has to come after that
// registration: asked first, it misses every shipped family the system lacks,
// and a window spawned before any surface draws in another family than every
// window after it. Core's preference list cannot show the order on a system
// that has a family ahead of the shipped one, or its own copy of the shipped
// one. This asks the same lookup for the shipped families this system has no
// copy of, which only the registration makes findable, so the order shows on
// any system that lacks one of them.
//
// A framework host runs it as its first call into the framework. An
// application has registered its fonts before any of its code runs, so there
// is no order left to tell. macOS only, as the framework is: iOS offers no
// list of the font files a process can draw from.

#if os(macOS)
import CoreText
import Foundation
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The smoke's entry, which a framework host runs as its first call.
public enum ShippedFamilyLookupSmokeEntry {
    /// Runs the smoke.
    ///
    /// - Returns: Whether the lookup found a shipped family this system has no
    ///   copy of, and left every shipped file registered.
    public static func run() -> Bool { ShippedFamilyLookupSmoke.run() }
}

/// The scenario: the shipped families this system lacks, then the lookup.
enum ShippedFamilyLookupSmoke {
    /// - Returns: Whether the lookup found the first shipped family this
    ///   system lacks.
    static func run() -> Bool {
        let files = ShippedFonts.files
        guard !files.isEmpty else {
            return failed("no shipped fonts beside this binary")
        }
        guard registered(files).isEmpty else {
            return failed("the shipped fonts were registered before the lookup, which leaves no order to tell")
        }
        // Read from the system's list of families rather than asked by name, so
        // the lookup below is CoreText's first for each of them.
        let installed = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        var absent: [String] = []
        for family in Ubiquitty.Rendering.bundledFontFamilies() where !installed.contains(String(family)) {
            absent.append(String(family))
        }
        guard let expected = absent.first else {
            return failed("this system has a copy of every shipped family, which a lookup before the registration finds too")
        }
        let found = ShippedFonts.firstFamilyFoundByName(in: absent)
        guard found == expected else {
            return failed("the lookup answered \(found ?? "none") of \(absent), where \(expected) is found once registered")
        }
        let missing = Set(files).subtracting(registered(files))
        guard missing.isEmpty else {
            return failed("the lookup left unregistered: \(missing.map(\.lastPathComponent).sorted())")
        }
        print("smoke-shipped-family-lookup: ok (\(expected), which this system has no copy of, found by name)")
        return true
    }

    /// The files among `files` that this process can draw from.
    ///
    /// - Parameter files: The shipped files.
    /// - Returns: The registered ones.
    private static func registered(_ files: [URL]) -> [URL] {
        let available = ((CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? []).map { $0.resolvingSymlinksInPath().path }
        let paths = Set(available)
        return files.filter { paths.contains($0.resolvingSymlinksInPath().path) }
    }

    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("smoke-shipped-family-lookup: FAILED — \(reason)\n".utf8))
        return false
    }
}
#endif
