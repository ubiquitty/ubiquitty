// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamTmuxContextCommands.swift — Beam's context-aware tmux actions: the
// same intent ("split this pane") reaches the terminal by whatever transport
// the focused pane actually understands. A -CC render-only pane takes control
// commands over the primary's channel; a full-screen raw `tmux attach` takes
// prefix-chord keystrokes; a native pane contributes nothing here — the
// existing native split/close/new-tab commands (menu walk) already apply, so
// duplicating them would double every palette hit.
//
// Each host raises the same commands and answers through its
// BeamTerminalHost conformance: a Swift host reaches Core's synthesis
// itself, an Objective-C host through its beamPerformTmuxIntent(_:value:).
// Classification and byte synthesis (Protocol::Tmux::classifyPaneContext /
// synthesizeAction) are Core's on both paths, so the transport a palette hit
// takes cannot differ between hosts, and a chord rides the host's own
// user-input route, so neither can its side
// effects — the dropped selection, the local echo, the broadcast fan-out.
// Per-window provider, constructed fresh at Beam summon from the focused
// window's controller, like AgentSurfaceCommandProvider.
//

import AppKit
import UbiquittyCore
import UbiquittyKit

struct TmuxContextCommandProvider: BeamCommandProvider {
    weak var target: (any BeamTerminalHost)?

    func commands() -> [BeamCommand] {
        guard let target else { return [] }
        let context = target.beamPaneContext
        guard context != .nativePane else { return [] }
        let inControlMode = (context == .controlMode)
        // Titles say where the action lands: these drive the tmux SESSION the
        // pane shows, not the surrounding native window.
        var out: [BeamCommand] = []
        out.append(
            BeamCommand(
                title: "tmux: Split Pane Left / Right",
                group: "tmux",
                keywords: ["tmux", "split", "pane", "vertical", "side"],
                identity: "tmux.splitSideBySide",
                run: { [weak target] in
                    _ = target?.performBeamPaneIntent(.splitSideBySide, value: "")
                }
            )
        )
        out.append(
            BeamCommand(
                title: "tmux: Split Pane Top / Bottom",
                group: "tmux",
                keywords: ["tmux", "split", "pane", "horizontal", "stack"],
                identity: "tmux.splitStacked",
                run: { [weak target] in
                    _ = target?.performBeamPaneIntent(.splitStacked, value: "")
                }
            )
        )
        out.append(
            BeamCommand(
                title: "tmux: New Window",
                group: "tmux",
                keywords: ["tmux", "new", "window", "tab"],
                identity: "tmux.newWindow",
                run: { [weak target] in
                    _ = target?.performBeamPaneIntent(.newWindow, value: "")
                }
            )
        )
        // Kill: in raw attach, tmux's own y/n prompt already gates the kill —
        // a second confirm would double-prompt. The -CC control command has no
        // tmux-side prompt, so Beam's confirm is the only gate: keep it.
        out.append(
            BeamCommand(
                title: "tmux: Kill Pane",
                group: "tmux",
                keywords: ["tmux", "kill", "close", "pane"],
                identity: "tmux.killPane",
                needsConfirm: inControlMode,
                run: { [weak target] in
                    _ = target?.performBeamPaneIntent(.killPane, value: "")
                }
            )
        )
        let currentName = target.beamHostedWindowName
        out.append(
            BeamCommand(
                title: "tmux: Rename Window",
                group: "tmux",
                value: currentName,
                keywords: ["tmux", "rename", "window", "title"],
                identity: "tmux.renameWindow",
                drill: .text(
                    current: currentName,
                    placeholder: "Window name",
                    apply: { [weak target] name in
                        _ = target?.performBeamPaneIntent(.renameWindow, value: name)
                    }
                )
            )
        )
        return out
    }
}
