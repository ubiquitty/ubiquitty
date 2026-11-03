// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShippedFacesSmoke.swift — a family we ship is drawn from our files, whatever
// else carrying its name the machine has registered.
//
// CoreText answers a family name or a style trait from every face carrying the
// name, so a box with its own copy of a shipped family drew that copy: a
// static JetBrains Mono Bold Italic in ~/Library/Fonts beat the bundled
// variable italic, and specimen_faces matched CTLineDraw of the installed file
// instead of the golden. This registers a copy of every shipped file from a
// temporary directory in the process ahead of the resolution, the way an
// installed family sits there, and requires every style of each shipped
// family to come from the bundled file Core's table names for it. A clean
// machine cannot hide the defect from it. The symbol face a renderer falls
// back to is held to the same rule: the factory hands the renderer the
// bundled file's path.

#if canImport(AppKit)
import AppKit
import CoreText
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The smoke's entry, which the application's entry point dispatches.
public final class ShippedFacesSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether every shipped style and the symbol face resolved to
    ///   their bundled files.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            ShippedFacesSmoke.run()
        }
    }
}

/// The scenario: decoys first, then each shipped family's four styles, then
/// the symbol face.
@MainActor
enum ShippedFacesSmoke {
    /// A family, and the bundled file each of its four styles must come from,
    /// in FontFace order.
    private static let expectations: [(family: String, files: [String])] = [
        (
            "JetBrains Mono",
            ["JetBrainsMono[wght].ttf", "JetBrainsMono[wght].ttf", "JetBrainsMono-Italic[wght].ttf", "JetBrainsMono-Italic[wght].ttf"]
        ),
        (
            "Monaspace Neon",
            ["MonaspaceNeon-Regular.otf", "MonaspaceNeon-Bold.otf", "MonaspaceNeon-Italic.otf", "MonaspaceNeon-BoldItalic.otf"]
        ),
        ("Monaspace Neon Var", ["MonaspaceNeonVar.ttf", "MonaspaceNeonVar.ttf", "MonaspaceNeonVar.ttf", "MonaspaceNeonVar.ttf"]),
        ("Noto Sans", ["NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "NotoSans-Regular.ttf", "NotoSans-Bold.ttf"]),
    ]

    /// - Returns: Whether every style came from its bundled file.
    static func run() -> Bool {
        guard let directory = ShippedResources.fontDirectory,
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("JetBrainsMono[wght].ttf").path)
        else {
            return failed("no bundled fonts beside this binary")
        }
        let decoyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ubiquitty-shipped-faces-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: decoyDirectory, withIntermediateDirectories: true)) != nil else {
            return failed("no temporary directory for the decoy faces")
        }
        let decoys = registerDecoys(from: directory, into: decoyDirectory)
        defer {
            for decoy in decoys {
                CTFontManagerUnregisterFontsForURL(decoy as CFURL, .process, nil)
            }
            try? FileManager.default.removeItem(at: decoyDirectory)
        }
        guard !decoys.isEmpty else {
            return failed("no decoy face could be registered, so the smoke would prove nothing")
        }
        var findings: [String] = []
        let styles: [(Ubiquitty.Rendering.FontFace, String)] = [
            (.Regular, "regular"), (.Bold, "bold"), (.Italic, "italic"), (.BoldItalic, "bold italic"),
        ]
        for expectation in expectations {
            guard let faces = FontFaces(family: expectation.family, size: 26, pixelsPerPoint: 2) else {
                findings.append("\(expectation.family): no faces")
                continue
            }
            for (index, style) in styles.enumerated() {
                let font = faces[style.0]
                let wanted = directory.appendingPathComponent(expectation.files[index]).standardizedFileURL
                let file = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.standardizedFileURL
                if file != wanted {
                    findings.append(
                        "\(expectation.family) \(style.1): \(file?.path ?? "a face with no file") — wanted \(wanted.lastPathComponent)"
                    )
                }
            }
        }
        // A proportional run set in a shipped family takes the same files.
        let proportionalExpectations: [(family: String, files: [String])] = [
            ("Noto Sans", ["NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "NotoSans-Regular.ttf", "NotoSans-Bold.ttf"]),
            (
                "JetBrains Mono",
                ["JetBrainsMono[wght].ttf", "JetBrainsMono[wght].ttf", "JetBrainsMono-Italic[wght].ttf", "JetBrainsMono-Italic[wght].ttf"]
            ),
        ]
        if let grid = FontFaces(family: "JetBrains Mono", size: 26, pixelsPerPoint: 2) {
            for expectation in proportionalExpectations {
                let request = LigatureSheet.ProportionalFaceRequest(familyName: expectation.family)
                for (index, style) in styles.enumerated() {
                    let isBold = index & 1 != 0
                    let isItalic = index & 2 != 0
                    let font = LigatureSheet.proportionalFace(sizedLike: grid, request: request, isBold: isBold, isItalic: isItalic)
                    let wanted = directory.appendingPathComponent(expectation.files[index]).standardizedFileURL
                    let file = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.standardizedFileURL
                    if file != wanted {
                        findings.append(
                            "proportional \(expectation.family) \(style.1): \(file?.path ?? "a face with no file") — wanted \(wanted.lastPathComponent)"
                        )
                    }
                }
            }
        } else {
            findings.append("no grid faces to size the proportional run by")
        }
        // Last, since building a renderer registers the shipped files for a
        // framework's process, and every resolution above must find only the
        // decoys by name.
        let symbolFile = directory.appendingPathComponent("SymbolsNerdFontMono-Regular.ttf").standardizedFileURL
        switch TerminalSurface.buildRenderer(
            fontFamily: "JetBrains Mono",
            pointSize: 13,
            typography: SurfaceTypography(),
            style: SurfaceStyle()
        ) {
        case .success(let renderer):
            let path = (renderer as? SurfaceRenderer)?.typography.symbolFontPath ?? ""
            if path.isEmpty || URL(fileURLWithPath: path).standardizedFileURL != symbolFile {
                findings.append("the symbol face: \(path.isEmpty ? "no file" : path) — wanted \(symbolFile.lastPathComponent)")
            }
        case .failure(let refusal):
            findings.append("no renderer to read the symbol face from: \(refusal)")
        }
        guard findings.isEmpty else {
            return failed(findings.joined(separator: "; "))
        }
        print(
            "smoke-shipped-faces: ok (\(expectations.count) families, 4 styles each, the proportional run and the symbol face, from their bundled files past \(decoys.count) same-named decoys)"
        )
        return true
    }

    /// Registers a copy of each shipped file — every face in it, named
    /// instances included, carrying the shipped family's name as an installed
    /// copy does — in this process.
    ///
    /// A decoy's file sits in the temporary directory, so a style resolved
    /// from one answers that path and cannot pass for the bundled file.
    ///
    /// - Parameters:
    ///   - directory: The bundled font directory.
    ///   - decoyDirectory: The temporary directory the copies are written to.
    /// - Returns: The registered decoy files, to unregister.
    private static func registerDecoys(from directory: URL, into decoyDirectory: URL) -> [URL] {
        let sources = Set(expectations.flatMap(\.files)).sorted()
        var decoys: [URL] = []
        for file in sources {
            let decoy = decoyDirectory.appendingPathComponent(file)
            guard (try? FileManager.default.copyItem(at: directory.appendingPathComponent(file), to: decoy)) != nil,
                CTFontManagerRegisterFontsForURL(decoy as CFURL, .process, nil)
            else {
                continue
            }
            decoys.append(decoy)
        }
        return decoys
    }

    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("smoke-shipped-faces: FAILED — \(reason)\n".utf8))
        return false
    }
}
#endif
