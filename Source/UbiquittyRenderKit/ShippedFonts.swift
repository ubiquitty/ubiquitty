// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShippedFonts.swift — the font files Core's table names, found in the shipped
// resources and made reachable by name in this process.
//
// The renderer opens a shipped family's files by path and never needs them
// registered. What does need them is everything that resolves a family by
// name: the preferred family's by-name check, a fallback list naming a shipped
// face, and a settings list offering one. An application registers them before
// any of its code runs, through its Info.plist (`ATSApplicationFontsPath` on
// macOS, `UIAppFonts` on iOS). The system reads that key from the main bundle
// only, so a framework registers its own, and a host embedding it does nothing.
//
// Only the files the table names are registered, never the whole directory: a
// file left behind in it by an earlier copy is never asked for, and so never
// competes with a shipped face for its family's name.

import CoreText
import Foundation
import UbiquittyCore

/// The shipped font files, and their registration for this process.
package enum ShippedFonts {
    /// Every file Core's table names that is present in the shipped font
    /// directory, each once.
    package static var files: [URL] {
        guard let directory = ShippedResources.fontDirectory else {
            return []
        }
        var names: [String] = []
        for font in Ubiquitty.Rendering.bundledFontFamilies() {
            let faceFiles = Ubiquitty.Rendering.bundledFaceFiles(font)
            for file in [faceFiles.regular, faceFiles.bold, faceFiles.italic, faceFiles.boldItalic] {
                let name = String(file)
                if !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The file a shipped family's upright is drawn from.
    ///
    /// - Parameter family: The family a configuration named.
    /// - Returns: The file, or nil when the family is not shipped or its file
    ///   is not in the shipped font directory.
    package static func uprightFile(family: String) -> URL? {
        let name = String(Ubiquitty.Rendering.bundledFaceFiles(std.string(family)).regular)
        guard !name.isEmpty, let file = ShippedResources.fontDirectory?.appendingPathComponent(name),
            FileManager.default.fileExists(atPath: file.path)
        else {
            return nil
        }
        return file
    }

    /// Registers every shipped file for this process.
    ///
    /// A file already registered is refused with an error and stays
    /// registered, so calling this again changes nothing.
    ///
    /// - Returns: How many files this call registered.
    @discardableResult
    package static func register() -> Int {
        var registered = 0
        for file in files where CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) {
            registered += 1
        }
        return registered
    }

    /// Registers the shipped files the first time any caller asks, when this
    /// module is packaged as a framework.
    ///
    /// Called before anything resolves a family by name: the preferred
    /// family's lookup, and a surface or renderer measuring text. In an
    /// application the Info.plist has registered them already, and this does
    /// nothing.
    package static func registerIfEmbedded() {
        _ = embeddedRegistration
    }

    /// The first of a list of families that CoreText resolves by its own name,
    /// asked once the shipped files are registered.
    ///
    /// A shipped family is found by name on a system without a copy of it only
    /// after ``registerIfEmbedded()``, so this registers before it asks, and a
    /// caller choosing among families by name leaves the order to it.
    ///
    /// - Parameter candidates: The families, best first.
    /// - Returns: The first family CoreText answers with a face of that family,
    ///   or nil when it answers none of them.
    package static func firstFamilyFoundByName(in candidates: [String]) -> String? {
        registerIfEmbedded()
        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, 12, nil)
            if (CTFontCopyFamilyName(font) as String) == candidate {
                return candidate
            }
        }
        return nil
    }

    /// The one registration ``registerIfEmbedded()`` makes.
    private static let embeddedRegistration: Void = {
        guard ShippedResources.bundle != Bundle.main else {
            return
        }
        register()
    }()
}
