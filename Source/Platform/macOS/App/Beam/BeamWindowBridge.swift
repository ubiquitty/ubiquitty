// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

/// Gives the Kit's windows this shell's command palette.
///
/// A free-standing class for the reason the paste-push install is one: an
/// `@objc` extension on a class the bridging header declares makes the
/// generated header import that bridging header, and a translation unit
/// including both then sees the class declared twice.
@objc(UBBeamBridge)
@MainActor
public final class BeamBridge: NSObject {
    /// Installs the palette the Kit's windows summon.
    ///
    /// Called once at launch, ahead of any window: a controller asked before
    /// this is installed summons nothing.
    @objc
    public static func installBeamPresenter() {
        TerminalWindowController.beamPresenter = BeamPresenter(
            toggle: { window, foreground, background, accent, cursor in
                MainActor.assumeIsolated {
                    BeamController.toggle(in: window, foreground: foreground, background: background, accent: accent, cursor: cursor)
                }
            },
            isActive: { window in
                MainActor.assumeIsolated { BeamController.isActive(in: window) }
            },
            searchDidChange: { surface in
                MainActor.assumeIsolated { BeamController.searchDidChange(surface) }
            }
        )
    }
}
