// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+EditCommands.swift — the surface half of the Edit menu.
//
// Three operations the menu names and this arm could not perform. Each is one
// call into Core: the reset is `softReset`, the last-command region is
// `Selection::lastCommandOutputRegion` over the shell's OSC 133 marks, and the
// escaping is `Input::shellEscapedPath`. What is here is the surface's share —
// its selection, its wire — and no policy at all.

internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#endif

extension TerminalSurface {
    /// Performs a local soft reset.
    package func softResetTerminal() {
        drive.softResetTerminal()
        needsDisplay = true
    }

    /// Whether the shell's marks yield a last-command-output region.
    ///
    /// Asked without applying anything, because a menu has to know before the
    /// user picks the item whether picking it would do something.
    package var hasLastCommandOutput: Bool {
        drive.hasLastCommandOutput
    }

    /// Selects the last command's output.
    package func selectLastCommandOutput() {
        guard selectionModel.withState({ drive.selectLastCommandOutput(into: &$0) }) else {
            #if canImport(AppKit)
            NSSound.beep()
            #endif
            return
        }
        needsDisplay = true
    }
}
