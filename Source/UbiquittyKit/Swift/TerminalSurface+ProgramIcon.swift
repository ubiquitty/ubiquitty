// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+ProgramIcon.swift — a program's icon for a host's own chrome.
//
// Core's catalog (Title/ProcessIconCatalog.h) names the programs, their icon
// files and how each is painted; ProcessIcons reads the files from the shipped
// resources, the framework's own bundle in a host and the app's in the app.
// This carries that answer across the module wall as AppKit values, so a host
// drawing its own tabs reads the catalog through the Kit and parses nothing.
//
// macOS only: the icons ship in the macOS app and framework, and an icon a
// title draws is the desktop's.

import AppKit

extension TerminalSurface {
    /// A program's icon from Ubiquitty's process catalog, and how Ubiquitty
    /// paints it, for a host drawing a program's tab or pane chrome.
    ///
    /// The catalog is Core's: a key names one program, its icon file and its
    /// ink. ``foregroundProgramKey`` gives the key of what a pane runs, and
    /// ``foregroundProgramIcon`` the icon for it. The file is read from the
    /// framework's own bundle, never the host's.
    ///
    /// The first lookup of a key reads its file on the main thread, and the
    /// image read is kept for the life of the process: at most one per
    /// catalog program, whatever keys a host asks for. Every later lookup of
    /// that key reads nothing. A lookup walks the catalog's few entries by
    /// key, and a key it does not hold reads no file. Each lookup returns
    /// images of its own, which draw the kept one, so a host can resize or
    /// tint one without touching another lookup's.
    ///
    /// The lookup and ``image(side:ink:ground:)`` run on the main thread. The
    /// value is `Sendable`: its members and ``needsPlate(on:)`` read on any
    /// thread, and the images it carries and makes draw on any thread, so a
    /// host can hand an icon to a background task or a cache and rasterise it
    /// there.
    public struct ProgramIcon: Sendable {
        /// How the icon is painted, as Core's catalog says.
        public enum RenderingMode: Sendable {
            /// One colour, the ink of the text beside it, so it reads on any
            /// ground as the text does.
            case template
            /// The icon's own colours, as its owner draws them; on a plate in
            /// the text's ink where ``ProgramIcon/needsPlate(on:)`` says so.
            case original
        }

        /// The side Ubiquitty's titles draw an icon at, in points: the size
        /// Safari draws a site's icon at in its tab. ``image`` is this size.
        public static let preferredSide: CGFloat = ProcessIcons.side

        /// The catalog key, such as `claude-code`.
        public let key: String
        /// The program's name as its owner writes it, such as `Claude Code`,
        /// for a tooltip or an accessibility label.
        public let title: String
        /// How the icon is painted.
        public let renderingMode: RenderingMode
        /// The icon in its file's own colours, fitted and centred in a square
        /// of ``preferredSide``, with ``title`` as its accessibility
        /// description.
        ///
        /// A template icon's image is marked `isTemplate`, so an image view,
        /// a button or a menu paints it in its own tint; drawn directly, it
        /// draws in the file's black. The image draws the shipped file at
        /// whatever size it is given, so a host may set another size.
        public let image: NSImage

        /// Creates the icon a catalog key names.
        ///
        /// - Parameter key: A catalog key, as ``TerminalSurface/foregroundProgramKey``
        ///   gives it. A program's name is not a key: Claude Code runs as
        ///   `claude` and its key is `claude-code`.
        /// - Returns: The icon, or nil for an empty key, a key the catalog does
        ///   not hold, or a framework without the icon's file.
        @MainActor
        public init?(key: String) {
            guard let image = ProcessIcons.image(forKey: key, side: Self.preferredSide) else {
                return nil
            }
            self.key = key
            self.title = ProcessIcons.title(forKey: key)
            self.renderingMode = ProcessIcons.isTemplate(forKey: key) ? .template : .original
            self.image = image
        }

        /// Whether the icon needs a plate behind it to be made out on a
        /// ground: Core's decision for a drawn icon whose own colour is too
        /// close to the ground and that brings no tile of its own. Ubiquitty
        /// draws the plate as a squircle in the text's ink. Runs on any thread.
        ///
        /// - Parameter ground: The colour the icon is drawn on.
        /// - Returns: Whether to draw a plate behind it; always false for a
        ///   template icon.
        public func needsPlate(on ground: NSColor) -> Bool {
            ProcessIcons.needsPlate(forKey: key, ground: ground)
        }

        /// The icon as Ubiquitty's own titles draw it: a template icon in
        /// `ink`, a drawn icon in its own colours, on a plate in `ink` when
        /// ``needsPlate(on:)`` says so for `ground`.
        ///
        /// - Parameters:
        ///   - side: The square's side, in points; ``preferredSide`` is the
        ///     size Ubiquitty draws.
        ///   - ink: The colour of the text beside the icon.
        ///   - ground: The colour the icon is drawn on.
        /// - Returns: The image, with ``title`` as its accessibility
        ///   description; nil for a side that is not positive.
        @MainActor
        public func image(side: CGFloat, ink: NSColor, ground: NSColor) -> NSImage? {
            ProcessIcons.image(forKey: key, side: side, ink: ink, ground: ground)
        }
    }

    /// The icon of the program the pane runs: the ``ProgramIcon`` for
    /// ``foregroundProgramKey``.
    ///
    /// Read from the same sample as ``foregroundProgramKey``, so it is current
    /// whenever that is, and inside the callbacks of one delivery it names the
    /// program the key does. Nil whenever the key is nil.
    public var foregroundProgramIcon: ProgramIcon? {
        foregroundProgramKey.flatMap { ProgramIcon(key: $0) }
    }
}
