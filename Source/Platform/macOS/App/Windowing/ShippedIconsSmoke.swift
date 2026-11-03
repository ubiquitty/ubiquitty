// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShippedIconsSmoke.swift — the icons a tag and a title draw come from the
// files shipped beside this code.
//
// Both readers take their files from the shipped resources: the Phosphor
// catalog and its two fonts, and each program's icon in process-icons. Run in
// the application, that is the app's bundle; run in a host embedding
// UbiquittyKit.framework, it is the framework's, and the host carries none of
// the files, so a reader that looked in the host's bundle draws nothing and
// fails here.

import AppKit
internal import CxxStdlib
internal import UbiquittyCore

/// The smoke's entry, which the application's entry point and the framework's
/// consumer check dispatch.
public final class ShippedIconsSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether the Phosphor catalog, both of its weights, and every
    ///   program's icon were read from the shipped files, and no key outside
    ///   the catalog drew an icon or kept a file.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            ShippedIconsSmoke.run()
        }
    }
}

/// The scenario: the Phosphor catalog, an icon in each weight, every program
/// Core's catalog names, then keys it does not name.
@MainActor
enum ShippedIconsSmoke {
    /// - Returns: Whether every icon was drawn from its shipped file.
    static func run() -> Bool {
        var findings: [String] = []
        let catalog = PhosphorIcons.catalog
        if let first = catalog.first {
            let weights: [(weight: Ubiquitty.Session.TagIconWeight, name: String)] = [(.Regular, "regular"), (.Fill, "fill")]
            for (weight, name) in weights where PhosphorIcons.image(named: first.name, weight: weight, side: 16, color: .black) == nil {
                findings.append("no \(name) Phosphor glyph for \(first.name)")
            }
        } else {
            findings.append("no Phosphor catalog")
        }
        var programs = 0
        for ordinal in UInt8(1)...UInt8.max {
            let key = String(Ubiquitty.Title.processIconKeyAt(ordinal))
            if key.isEmpty {
                break
            }
            if ProcessIcons.image(forKey: key, side: ProcessIcons.side, ink: .black, ground: .white) == nil {
                findings.append("no icon for \(key)")
            }
            programs += 1
        }
        if programs == 0 {
            findings.append("no program in Core's icon catalog")
        }
        // A key the catalog does not hold is not a program: it draws nothing
        // and keeps nothing, however many a host asks for.
        for name in ["", "claude", "no-such-program", "Claude-Code"]
        where ProcessIcons.image(forKey: name, side: ProcessIcons.side, ink: .black, ground: .white) != nil {
            findings.append("an icon for \"\(name)\", which is no catalog key")
        }
        if ProcessIcons.keptSourceCount > programs {
            findings.append("\(ProcessIcons.keptSourceCount) icon files kept for \(programs) programs")
        }
        guard findings.isEmpty else {
            FileHandle.standardError.write(Data("smoke-shipped-icons: FAILED — \(findings.joined(separator: "; "))\n".utf8))
            return false
        }
        print(
            "smoke-shipped-icons: ok (the Phosphor catalog of \(catalog.count) icons and both its weights, and \(programs) programs' icons, from their shipped files; no other key drew or kept one)"
        )
        return true
    }
}
