// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import CoreText
internal import CxxStdlib
internal import UbiquittyCore

/// The app's headless `--snapshot` command: one offscreen frame written as a
/// PNG, through the portable software renderer or the surface's Metal
/// renderer, with no NSApplication, delegate or window.
///
/// Core reads the words, states the flags into the case's document and draws
/// the portable frame (`Core/App/SnapshotRequest.h`); this registers the
/// bundled fonts, reads the files, configures from the case and hands the Metal
/// frame to ``SurfaceSnapshotEntry``.
@MainActor
public enum SnapshotRunner {
    /// Renders and exits when the words ask for a snapshot; returns otherwise,
    /// so the app launches as usual.
    ///
    /// - Parameter words: The terminal's own command line, the program first.
    public static func runIfRequested(_ words: [String]) {
        var commandLine = Ubiquitty.App.SnapshotWords()
        for word in words {
            commandLine.push_back(std.string(word))
        }
        var arguments = Ubiquitty.Diagnostics.SnapshotArguments()
        var unsupportedBackend = std.string()
        switch Ubiquitty.App.parseSnapshotRequest(commandLine, &arguments, &unsupportedBackend) {
        case .Requested:
            break
        case .UnsupportedBackend:
            FileHandle.standardError.write(Data("snapshot: unsupported backend: \(String(unsupportedBackend))\n".utf8))
            exit(2)
        default:
            return
        }

        // A pinned clock keeps the blink phase, of the cursor and of blinking
        // text, the same in every run, so goldens stay byte-stable. Tick 0 lands
        // in the half-period the cursor shows; a caller may set another.
        setenv("UBIQUITTY_FAKE_TICKS", "0", 0)

        autoreleasepool {
            if arguments.outPath.empty() {
                fail("--snapshot requires an output path")
            }
            // The shipped default face (JetBrains Mono) has to resolve headless.
            registerBundledFonts()

            // The case's document, its file or nothing, with the flags that are
            // the configuration's own keys written into it, is the process's
            // configuration even when the case names none: `values()` would
            // otherwise be the developer's own file, and a reader of the
            // global — the background-image decode reads the colour space
            // through it — would mint goldens in whatever that file says.
            let hasConfiguration = !arguments.configPath.empty()
            var document = std.string()
            if hasConfiguration, !Ubiquitty.App.readSnapshotFile(arguments.configPath, &document) {
                fail("--config could not be read")
            }
            Ubiquitty.App.stateSnapshotDocument(arguments, .EveryBackend, &document)
            configureStrictly(document, arguments: arguments)

            if !arguments.feedFile.empty() {
                // The file's bytes are fed as they are, with no escape decoding.
                var contents = std.string()
                if !Ubiquitty.App.readSnapshotFile(arguments.feedFile, &contents) {
                    fail("--feed-file could not be read")
                }
                arguments.feed = contents
                arguments.haveFeed = true
            }
            Ubiquitty.App.normaliseSnapshotGeometry(&arguments)

            if arguments.shouldUsePortableBackend {
                switch Ubiquitty.App.renderPortableSnapshot(arguments, Ubiquitty.Preferences.values().pointee, hasConfiguration) {
                case .Written:
                    exit(0)
                case .ThemeNotFound:
                    fail("--theme name not found")
                default:
                    fail("portable renderer failed to write PNG")
                }
            }

            Ubiquitty.App.stateSnapshotDocument(arguments, .SurfaceRenderer, &document)
            configureStrictly(document, arguments: arguments)
            guard SurfaceSnapshotEntry.render(arguments, configuration: Ubiquitty.Preferences.values().pointee) else {
                fail("surface renderer failed")
            }
            fflush(nil)
            _exit(0)
        }
    }

    /// Ends the run with 2 and the reason, as every refusal of the command does.
    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("Ubiquitty --snapshot: \(reason)\n".utf8))
        exit(2)
    }

    /// Configures from the case's document, strictly: a file that misspells a
    /// key fails rather than drawing with the key missing.
    private static func configureStrictly(_ document: std.string, arguments: Ubiquitty.Diagnostics.SnapshotArguments) {
        let configured = Ubiquitty.Preferences.configure(document, .Strict)
        guard !configured.isApplied else { return }
        let source = arguments.configPath.empty() ? "--snapshot" : String(arguments.configPath)
        for skipped in configured.diagnostics {
            FileHandle.standardError.write(Data("\(source): \(String(Ubiquitty.Preferences.diagnosticSentence(skipped)))\n".utf8))
        }
        fail("--config contains an unknown, malformed, or mistyped setting")
    }

    /// Makes the app's bundled fonts (Resources/fonts) available to this
    /// process, and says what is there, so a fallback face is never silent.
    ///
    /// A run from inside the bundle already has them through the Info.plist's
    /// ATSApplicationFontsPath; registering again is harmless and also covers a
    /// run outside the bundle.
    private static func registerBundledFonts() {
        let faces = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? []
        guard let first = faces.first else {
            FileHandle.standardError.write(Data("snapshot: no bundled fonts in Resources/fonts; CoreText will use system fallbacks\n".utf8))
            return
        }
        var newlyRegistered = 0
        for face in faces where CTFontManagerRegisterFontsForURL(face as CFURL, .process, nil) {
            // A face already registered is reported as an error and is in the
            // process scope either way.
            newlyRegistered += 1
        }
        let directory = first.deletingLastPathComponent().path
        print("snapshot: \(faces.count) bundled font(s) at \(directory) (\(newlyRegistered) newly registered)")
        fflush(stdout)
    }
}
#endif
