// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TmuxHostingScenarios.swift — what a window hosting a tmux -CC session does
// beyond showing its panes: it says which session it belongs to, it sizes the
// session to itself, it closes only the requested window or pane, and it
// carries the reader's tmux intents to wherever the focused pane's input
// actually lands.
//
// Each scenario runs against a PRIVATE `-L <socket>` tmux server, killed before
// and after, so a run neither collides with the reader's own tmux nor leaks a
// session. The server is also the oracle: what tmux itself reports about the
// session is the answer these check against, rather than what this side
// believes it sent.

/// Registers the tmux-hosting scenarios with the UI-test runner.
enum TmuxHostingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("tmux_control_mode_moves_panes_between_splits_tabs_and_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-pane-transfer"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let control = shell.focusedSurfaceForTesting
                else { return }
                defer { shell.window?.close() }
                control.send("\(tmuxPath()) -L \(socket) -CC new-session -s transfer /bin/sh\n")
                t.expect(
                    t.wait(until: { shell.hostedWindowsForTesting.first?.boundTmuxPaneIDs().count == 1 }, timeout: 20),
                    desc: "the control client opens its first window"
                )
                guard let source = shell.hostedWindowsForTesting.first, let paneID = source.boundTmuxPaneIDs().first else { return }
                source.splitRight(nil)
                t.expect(t.wait(until: { source.boundTmuxPaneIDs().count == 2 }, timeout: 20), desc: "tmux supplies the split layout")
                guard let pane = source.tmuxSurfaceForTesting(paneID),
                    let survivorID = source.boundTmuxPaneIDs().first(where: { $0 != paneID }),
                    let survivor = source.tmuxSurfaceForTesting(survivorID)
                else { return }
                let process = askTmux(socket: socket, ["display-message", "-p", "-t", "%\(paneID)", "#{pane_pid}"]).output
                let coordinator = PaneTransferCoordinator.shared
                t.expect(
                    coordinator.extract(.init(controller: source, surface: pane, wholeTab: false), newWindow: true),
                    desc: "break-pane extracts into a window"
                )
                var detached: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            detached = shell.hostedWindowsForTesting.first { $0 !== source && $0.boundTmuxPaneIDs().contains(paneID) }
                            return detached != nil && source.boundTmuxPaneIDs().count == 1
                        },
                        timeout: 20
                    ),
                    desc: "the server's new window projects the extracted pane"
                )
                guard let detached, let moved = detached.tmuxSurfaceForTesting(paneID) else { return }
                t.expect((detached.window?.tabGroup?.windows.count ?? 1) == 1, desc: "the pane opens as a standalone native window")
                t.expect(
                    askTmux(socket: socket, ["display-message", "-p", "-t", "%\(paneID)", "#{pane_pid}"]).output == process,
                    desc: "the pane process survives extraction"
                )
                let tab = PaneTransferCoordinator.Transfer(controller: detached, surface: moved, wholeTab: true)
                detached.window?.setContentSize(NSSize(width: 960, height: 640))
                t.expect(
                    coordinator.move(tab, to: source, target: survivor, placement: .tab),
                    desc: "the extracted tmux tab joins a one-tab window"
                )
                t.expect(detached.window?.tabGroup === source.window?.tabGroup, desc: "native tab grouping joins the windows")
                source.window?.setContentSize(NSSize(width: 960, height: 640))
                source.window?.contentView?.layoutSubtreeIfNeeded()
                t.expect(
                    t.wait(
                        until: { (source.reportedTmuxClientGridForTesting?.rows ?? 0) >= 12 },
                        timeout: 10
                    ),
                    desc: "the client reports enough rows for a horizontal split"
                )
                t.expect(
                    coordinator.move(tab, to: source, target: survivor, placement: .below),
                    desc: "move-pane joins the tab into a horizontal split"
                )
                t.expect(
                    t.wait(until: { source.boundTmuxPaneIDs().count == 2 && detached.isClosedForTesting }, timeout: 20),
                    desc: "the server layout joins both panes and removes the empty window"
                )
                t.expect(
                    askTmux(socket: socket, ["display-message", "-p", "-t", "%\(paneID)", "#{pane_pid}"]).output == process,
                    desc: "joining preserves the original process"
                )
                source.tmuxSurfaceForTesting(paneID)?.send("echo moved-pane-$((6*7))\n")
                t.expect(
                    t.wait(
                        until: {
                            askTmux(socket: socket, ["capture-pane", "-p", "-S", "-", "-t", "%\(paneID)"]).output.contains("moved-pane-42")
                        },
                        timeout: 10
                    ),
                    desc: "input still reaches the moved tmux pane"
                )
                source.splitRight(nil)
                t.expect(t.wait(until: { source.boundTmuxPaneIDs().count == 3 }, timeout: 20), desc: "the source tab has nested splits")
                t.expect(
                    askTmux(socket: socket, ["new-window", "-d", "-t", "transfer"]).status == 0,
                    desc: "the server creates a destination window"
                )
                var receiver: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            receiver = shell.hostedWindowsForTesting.first { $0 !== source && $0.boundTmuxPaneIDs().count == 1 }
                            return receiver != nil
                        },
                        timeout: 20
                    ),
                    desc: "the destination window is projected"
                )
                guard let receiver, let targetID = receiver.boundTmuxPaneIDs().first,
                    let target = receiver.tmuxSurfaceForTesting(targetID), let moving = source.tmuxSurfaceForTesting(paneID)
                else { return }
                t.expect(
                    coordinator.move(
                        .init(controller: source, surface: moving, wholeTab: true),
                        to: receiver,
                        target: target,
                        placement: .right
                    ),
                    desc: "a nested tmux tab joins another window as a split"
                )
                t.expect(
                    t.wait(until: { receiver.boundTmuxPaneIDs().count == 4 && source.isClosedForTesting }, timeout: 20),
                    desc: "all nested panes reach their destination and the empty tab closes"
                )
                t.expect(
                    askTmux(socket: socket, ["display-message", "-p", "-t", "%\(paneID)", "#{pane_pid}"]).output == process,
                    desc: "moving a nested tab keeps the original process"
                )
                guard let movedPane = receiver.tmuxSurfaceForTesting(paneID) else { return }
                t.expect(
                    coordinator.move(
                        .init(controller: receiver, surface: movedPane, wholeTab: false),
                        to: receiver,
                        target: target,
                        placement: .below,
                        insertTarget: .Root
                    ),
                    desc: "a tmux pane moves to the bottom edge of its complete tab"
                )
                t.expect(
                    t.wait(
                        until: {
                            let width = askTmux(
                                socket: socket,
                                ["display-message", "-p", "-t", "%\(paneID)", "#{pane_width}:#{window_width}"]
                            )
                            .output
                            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
                            return width.count == 2 && width[0] == width[1] && receiver.boundTmuxPaneIDs().count == 4
                        },
                        timeout: 20
                    ),
                    desc: "the server makes the moved pane span the whole window without losing its siblings"
                )
            }
        }
        UBUITestRegister("explicit_tmux_client_waits_for_authentication_and_preserves_remote_origin") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-authenticated-control"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                let script =
                    "printf 'Authentication required: '; IFS= read -r answer; [ \"$answer\" = continue ] || exit 9; exec \"$1\" -L \"$2\" -f /dev/null -CC new-session -s authenticated"
                guard
                    let primary = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", script, "control-auth-fixture", tmuxPath(), socket],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild,
                        tmuxControlHost: "fixture.example"
                    ), let surface = primary.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the explicit control client opens")
                    return
                }
                defer { primary.window?.close() }
                t.expect(
                    t.wait(
                        until: {
                            surface.searchScrollbackAndWait("Authentication required:", isCaseSensitive: true).totalMatches > 0
                        },
                        timeout: 10
                    ),
                    desc: "authentication remains visible in the control window"
                )
                t.pump(0.5)
                t.expect(primary.liveHostedWindows.isEmpty, desc: "no hosted window exists before authentication")
                surface.send("continue\n")
                t.expect(
                    t.wait(
                        until: {
                            primary.liveHostedWindows.first?.savedTmuxWindow?.sshHost == "fixture.example"
                        },
                        timeout: 20
                    ),
                    desc: "the exact authentication answer reaches the client before any control command"
                )
                guard let hosted = primary.liveHostedWindows.first,
                    let pane = hosted.boundTmuxPaneIDs().first,
                    let paneSurface = hosted.tmuxSurfaceForTesting(pane),
                    let encoded = hosted.savedPresentation(needsLocalArrangement: true).encoded()
                else { return }
                t.expect(
                    paneSurface.drive.withTerminal { $0.currentCapabilityOrigin == .Remote } == true,
                    desc: "adopting the pane preserves remote capability authority"
                )
                t.expect(
                    SavedTerminalPresentation.decoded(encoded)?.tmuxWindow?.sshHost == "fixture.example",
                    desc: "the saved reference retains its explicit SSH authority"
                )
                t.expect(
                    hosted.savedTmuxWindow?.canReconnectLocally == false,
                    desc: "a remote authority cannot be mistaken for a local tmux socket"
                )
                // tmux answers DA1 for its panes itself, so the probe is DA3,
                // which only the terminal answers. The pane's model parses the
                // query from tmux's output and its answer is typed back into
                // the pane through tmux; the program prints the marker only
                // when it reads that answer.
                paneSurface.send(
                    "/bin/bash -c 'printf \"\\033[=c\"; IFS= read -r -s -d \"\\\\\" -t 5 reply; case \"$reply\" in *4D414352*) echo \"remote-da3-$((6*7))\";; *) echo remote-da3-unanswered;; esac'\n"
                )
                t.expect(
                    t.wait(until: { paneSurface.searchScrollbackAndWait("remote-da3-42").totalMatches > 0 }, timeout: 15),
                    desc: "a remote pane's program reads the terminal's DA3 answer"
                )
                // A checksum of the pane's cells reads back what the screen
                // holds, so a remote pane is refused it.
                paneSurface.send(
                    "/bin/bash -c 'printf \"\\033[1;0;1;1;1;1*y\"; IFS= read -r -s -d \"\\\\\" -t 2 reply; echo \"remote-checksum-$((6*7))-${#reply}\"'\n"
                )
                t.expect(
                    t.wait(until: { paneSurface.searchScrollbackAndWait("remote-checksum-42-0").totalMatches > 0 }, timeout: 15),
                    desc: "a remote pane's program is refused a checksum of its cells"
                )
            }
        }
        UBUITestRegister("connect_tmux_over_ssh_runs_its_panes_as_the_dialled_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-connect-ssh-tmux"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                // Connect records what it opened; the reader's recents are put
                // back as they were.
                let recentsKey = "UBConnectRecents"
                let recents = UserDefaults.standard.object(forKey: recentsKey)
                defer {
                    if let recents {
                        UserDefaults.standard.set(recents, forKey: recentsKey)
                    } else {
                        UserDefaults.standard.removeObject(forKey: recentsKey)
                    }
                }
                // An ssh that ignores its destination and runs this Mac's tmux
                // on a private server: the launch is Connect's own, through
                // Core's plan, and only the far end is local.
                let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ubiquitty-uitest-fixture-ssh")
                let script = "#!/bin/sh\nexec '\(tmuxPath())' -L '\(socket)' -f /dev/null -CC new-session -A -s dialled\n"
                guard (try? script.write(to: fixture, atomically: true, encoding: .utf8)) != nil,
                    (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)) != nil
                else {
                    t.expect(false, desc: "the ssh fixture is written")
                    return
                }
                defer { try? FileManager.default.removeItem(at: fixture) }
                let resolve = ConnectLauncher.resolveTool
                defer { ConnectLauncher.resolveTool = resolve }
                ConnectLauncher.resolveTool = { name in name == "ssh" ? fixture.path : resolve(name) }

                let before = Set(TerminalWindowController.spawnedControllers.map { ObjectIdentifier($0) })
                let failure = ConnectLauncher.openTmux(host: "fixture.example", session: "", localePolicy: .automatic)
                t.expect(failure == nil, desc: "Connect opens tmux over ssh (\(failure?.stateName ?? "opened"))")
                // Closed whether or not it ever hosts a window.
                let opened = TerminalWindowController.spawnedControllers.filter { !before.contains(ObjectIdentifier($0)) }
                defer { opened.forEach { $0.window?.close() } }
                var primary: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            primary = TerminalWindowController.spawnedControllers.first {
                                $0.liveHostedWindows.first?.savedTmuxWindow?.sshHost == "fixture.example"
                            }
                            return primary?.liveHostedWindows.first?.boundTmuxPaneIDs().isEmpty == false
                        },
                        timeout: 20
                    ),
                    desc: "the control client hosts its window for the dialled host"
                )
                guard let primary else { return }
                guard let hosted = primary.liveHostedWindows.first,
                    let pane = hosted.boundTmuxPaneIDs().first,
                    let paneSurface = hosted.tmuxSurfaceForTesting(pane)
                else { return }
                t.expect(
                    paneSurface.drive.withTerminal { $0.currentCapabilityOrigin == .Remote } == true,
                    desc: "a pane Connect dialled over ssh runs as Remote"
                )
                t.expect(
                    hosted.savedTmuxWindow?.canReconnectLocally == false,
                    desc: "and its saved window reattaches through the host rather than a local socket"
                )
            }
        }
        UBUITestRegister("saved_tmux_arrangements_reattach_and_refuse_restarted_servers") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkSavedTmuxArrangement(t) }
        }
        UBUITestRegister("swift_shell_tmux_rename_outranks_a_later_osc_title") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                surface.send("printf '\\033]2;osc-first\\007'\n")
                t.expect(
                    t.wait(until: { surface.title == "osc-first" }, timeout: 8),
                    desc: "the pane's program names itself"
                )
                t.pump(0.3)
                t.expect(window.tab.title.contains("osc-first"), desc: "and the tab carries that name")

                // tmux renames the window this tab shows.
                shell.tmuxWindowName = "renamed-window"
                t.pump(0.3)
                t.expect(window.tab.title.contains("renamed-window"), desc: "the tmux rename names the tab")
                t.expect(!window.tab.title.contains("osc-first"), desc: "outranking the pane's own title")

                // The prompt redraw that follows writes the pane's title again.
                // The rename is held apart from it, so it stands.
                surface.send("printf '\\033]2;osc-after-rename\\007'\n")
                t.expect(
                    t.wait(until: { surface.title == "osc-after-rename" }, timeout: 8),
                    desc: "the program writes its title again"
                )
                t.pump(0.3)
                t.expect(window.tab.title.contains("renamed-window"), desc: "and the rename survives it")
                t.expect(
                    !window.tab.title.contains("osc-after-rename"),
                    desc: "the later OSC-2 write does not clobber the rename"
                )
                t.expect(
                    window.title.contains("osc-after-rename"),
                    desc: "the window title is still the program's own — the rename names the tab"
                )

                // Nothing was merged into the pane: with the tmux name gone,
                // the pane's own title names the tab again.
                shell.tmuxWindowName = ""
                t.pump(0.3)
                t.expect(
                    window.tab.title.contains("osc-after-rename"),
                    desc: "and the pane's own title was never overwritten by it"
                )
            }
        }

        UBUITestRegister("swift_tmux_beam_context_actions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A window of local sessions: no tmux anywhere, so Beam
                // contributes nothing and an intent synthesizes nothing.
                if let native = TerminalWindowController.spawn(
                    arguments: ["/bin/sh"],
                    localePolicy: .auto,
                    sessionLifetime: .endsWithChild
                ) {
                    t.pump(0.3)
                    t.expect(native.tmuxPaneContext() == .nativePane, desc: "a plain window classifies as a native pane")
                    t.expect(
                        TmuxContextCommandProvider(target: native).commands().isEmpty,
                        desc: "and Beam raises no tmux commands over it"
                    )
                    t.expect(
                        !native.performTmuxIntent(.newWindow),
                        desc: "a native pane synthesizes nothing — its own menu action applies"
                    )
                    native.window?.close()
                }

                let socket = "ubiquitty-uitest-tmux-beam"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s beamses"),
                    let shell = waitForShell(t, of: primary)
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                t.expect(shell.tmuxPaneContext() == .controlMode, desc: "a -CC pane classifies as control mode")
                t.expect(
                    TmuxContextCommandProvider(target: shell).commands().count == 5,
                    desc: "and Beam raises the tmux commands over it"
                )

                t.expect(shell.performTmuxIntent(.newWindow), desc: "the new-window intent rides the control channel")
                t.expect(
                    t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 20),
                    desc: "and a second tmux window surfaced as a second shell"
                )

                t.expect(
                    shell.performTmuxIntent(.renameWindow, value: "beamed-title"),
                    desc: "the rename intent carries its value"
                )
                t.expect(
                    t.wait(until: { shell.tmuxWindowName == "beamed-title" }, timeout: 8),
                    desc: "and tmux echoed the new window name back"
                )

                t.expect(shell.performTmuxIntent(.splitStacked), desc: "the split intent rides the control channel")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and tmux split the window into two panes"
                )
                let panes = shell.boundTmuxPaneIDs().sorted()
                guard panes.count == 2, let second = shell.tmuxSurfaceForTesting(panes[1]) else {
                    t.expect(false, desc: "both panes are bound to surfaces")
                    return
                }
                // Beam's go-to lists the hosted panes by the ids tmux numbers
                // them with, and picking one moves the keyboard there: a hosted
                // window holds no local pane for the list to come from.
                if let owner = BeamTerminalContext(shell) {
                    t.expect(
                        owner.beamPanes().map(\.paneID) == panes.map { Int($0) },
                        desc: "Beam's go-to lists both hosted panes by their tmux ids"
                    )
                    owner.beamFocusPane(Int(panes[1]))
                    t.expect(shell.window?.firstResponder === second, desc: "and picking one moves the keyboard to its surface")
                    t.expect(
                        owner.beamPanes().first(where: \.isCurrent)?.paneID == Int(panes[1]),
                        desc: "which the list then marks as the current pane"
                    )
                } else {
                    t.expect(false, desc: "Beam takes a hosted window as its terminal context")
                }
                // The intent targets the FOCUSED pane, not the window's first:
                // in a split window the two differ, and a kill has to land
                // where the reader is.
                shell.window?.makeFirstResponder(second)
                t.pump(0.2)
                t.expect(shell.performTmuxIntent(.killPane), desc: "the kill intent rides the control channel")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 1 }, timeout: 8),
                    desc: "and tmux closed one pane"
                )
                t.expect(
                    shell.boundTmuxPaneIDs() == [panes[0]],
                    desc: "the pane that closed is the focused one, not the window's first"
                )
            }
        }

        UBUITestRegister("swift_tmux_beam_dismissal_returns_the_keyboard_to_a_hosted_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-beam-dismiss"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s beamdismiss"),
                    let shell = waitForShell(t, of: primary),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                t.expect(shell.performTmuxIntent(.splitSideBySide), desc: "the split intent rides the control channel")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and tmux split the window into two panes"
                )
                let panes = shell.boundTmuxPaneIDs().sorted()
                guard panes.count == 2, let first = shell.tmuxSurfaceForTesting(panes[0]),
                    let second = shell.tmuxSurfaceForTesting(panes[1])
                else {
                    t.expect(false, desc: "both panes are bound to surfaces")
                    return
                }
                window.makeFirstResponder(second)
                t.pump(0.2)

                // Everything below runs in one turn: the palette dismisses
                // itself on the next turn over a window that is not key, and
                // the harness's windows never are.
                shell.toggleBeam(nil)
                t.expect(BeamController.isActive(in: window), desc: "the palette is up over the hosted window")
                // The pane the palette saved goes while it is up, the way a
                // kill-pane from elsewhere takes it.
                shell.unbindTmuxPane(panes[1])
                t.expect(second.window == nil, desc: "the saved pane has left the window")
                shell.toggleBeam(nil)
                t.expect(!BeamController.isActive(in: window), desc: "and the palette is down")
                t.expect(
                    window.firstResponder === first,
                    desc: "the keyboard lands on the hosted pane still standing, not on nothing"
                )
            }
        }

        UBUITestRegister("swift_tmux_a_pane_banner_names_the_pane_it_came_from") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-banner"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s bannerses"),
                    let shell = waitForShell(t, of: primary)
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                t.expect(shell.performTmuxIntent(.splitSideBySide), desc: "the split intent rides the control channel")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and tmux split the window into two panes"
                )
                let panes = shell.boundTmuxPaneIDs().sorted()
                guard panes.count == 2, let first = shell.tmuxSurfaceForTesting(panes[0]),
                    let second = shell.tmuxSurfaceForTesting(panes[1])
                else {
                    t.expect(false, desc: "both panes are bound to surfaces")
                    return
                }
                shell.window?.makeFirstResponder(first)
                t.pump(0.2)

                // The second pane's program posts a banner while the reader is
                // in the first. The request reaches the window only through the
                // pane's own session, and is tagged with that pane.
                second.send("printf '\\033]9;%s\\007' banner-from-the-second-pane\n")
                t.expect(
                    t.wait(until: { shell.lastBannerForTesting?.title == "banner-from-the-second-pane" }, timeout: 10),
                    desc: "the hosted pane's banner reaches the window"
                )
                t.expect(
                    shell.lastBannerForTesting?.paneID == Int(panes[1]),
                    desc: "tagged with the pane that asked, not the one with the keyboard"
                )
                if let pane = shell.lastBannerForTesting?.paneID {
                    t.expect(shell.focusPane(withIdentifier: pane), desc: "the banner's pane is still open")
                    t.expect(shell.window?.firstResponder === second, desc: "and a click on the banner focuses it")
                }
            }
        }

        UBUITestRegister("swift_tmux_a_typed_control_client_hosts_its_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-typed"
                let plainSocket = "ubiquitty-uitest-tmux-typed-plain"
                t.killTmuxServer(onSocket: socket)
                t.killTmuxServer(onSocket: plainSocket)
                defer {
                    t.killTmuxServer(onSocket: socket)
                    t.killTmuxServer(onSocket: plainSocket)
                }

                // A plain `tmux attach` typed into a Swift shell is a raw
                // attach: it hosts nothing, and nothing is typed into it.
                t.expect(
                    askTmux(socket: plainSocket, ["new-session", "-d", "-s", "plain"]).status == 0,
                    desc: "a detached tmux session exists to attach to"
                )
                guard
                    let plainShell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let plainSurface = plainShell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { plainShell.window?.close() }
                t.pump(0.3)
                plainSurface.send("\(tmuxPath()) -L \(plainSocket) attach -t plain\n")
                t.expect(
                    t.wait(until: { plainShell.tmuxPaneContext() == .rawAttach }, timeout: 10),
                    desc: "the typed `tmux attach` classifies as a raw attach"
                )
                t.pump(1.0)
                t.expect(plainShell.hostedWindowsForTesting.isEmpty, desc: "a plain attach hosts no windows")
                t.expect(!plainSurface.drive.isHostingWindows, desc: "and its session is no hosting source")
                t.expect(
                    !askTmux(socket: plainSocket, ["capture-pane", "-p", "-t", "plain"]).output.contains("refresh-client"),
                    desc: "and no control command was typed into its pane"
                )

                // The same shell with `-CC` typed: its session becomes the
                // control client's host, and the tmux window opens as a Swift
                // window of its own.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a second Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.send("\(tmuxPath()) -L \(socket) -CC new-session -s typed\n")
                var hosted: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            hosted = shell.hostedWindowsForTesting.first
                            return hosted?.boundTmuxPaneIDs().isEmpty == false
                        },
                        timeout: 20
                    ),
                    desc: "the typed control client's window opens as a hosted Swift window with a bound pane"
                )
                guard let hosted, let pane = hosted.boundTmuxPaneIDs().first, let paneSurface = hosted.tmuxSurfaceForTesting(pane)
                else {
                    return
                }
                t.expect(surface.drive.isHostingWindows, desc: "the typing shell's session is the hosting source")
                t.expect(hosted.tmuxPaneContext() == .controlMode, desc: "the hosted pane classifies as control mode")
                t.expect(hosted.tmuxSessionName == "typed", desc: "and the window names the session it belongs to")

                // Typing in the hosted pane reaches the server's pane, and the
                // pane's output comes back into the hosted pane's model.
                paneSurface.send("echo typed-hosting-$((6*7))\n")
                t.expect(
                    t.wait(
                        until: {
                            askTmux(socket: socket, ["capture-pane", "-p", "-t", "typed"]).output.contains("typed-hosting-42")
                        },
                        timeout: 10
                    ),
                    desc: "typing in the hosted pane reaches the tmux server"
                )
                t.expect(
                    t.wait(
                        until: { paneSurface.searchScrollbackAndWait("typed-hosting-42").totalMatches > 0 },
                        timeout: 10
                    ),
                    desc: "and the pane's output lands in the hosted pane's own model"
                )

                // A split rides the control channel and binds a second pane.
                t.expect(hosted.performTmuxIntent(.splitSideBySide), desc: "the split intent rides the control channel")
                t.expect(
                    t.wait(until: { hosted.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and tmux's new pane binds in the hosted window"
                )

                // The server going ends the hosting: the hosted window closes,
                // the typing shell stays, and it no longer hosts.
                t.killTmuxServer(onSocket: socket)
                t.expect(
                    t.wait(until: { shell.hostedWindowsForTesting.isEmpty && !surface.drive.isHostingWindows }, timeout: 10),
                    desc: "the server's exit closes the hosted window and ends the hosting"
                )
                t.expect(shell.window?.isVisible == true, desc: "while the shell that typed it stays open")
            }
        }

        UBUITestRegister("swift_tmux_closing_the_typing_window_closes_what_it_hosts") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-typed-close"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                t.pump(0.3)
                surface.send("\(tmuxPath()) -L \(socket) -CC new-session -s closing\n")
                var hosted: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            hosted = shell.hostedWindowsForTesting.first
                            return hosted?.boundTmuxPaneIDs().isEmpty == false
                        },
                        timeout: 20
                    ),
                    desc: "the typed control client's window opens as a hosted Swift window"
                )
                guard let hosted else { return }

                // The window whose session hosts them goes while they are up:
                // they close first and unbind every pane, so nothing reads a
                // model the session frees as it goes.
                shell.window?.close()
                t.expect(hosted.boundTmuxPaneIDs().isEmpty, desc: "the hosted window's panes are unbound")
                t.expect(hosted.window?.isVisible != true, desc: "and the hosted window is closed")
                t.expect(shell.hostedWindowsForTesting.isEmpty, desc: "and the typing window hosts nothing any more")
                t.pump(0.5)
                t.expect(
                    t.wait(
                        until: { askTmux(socket: socket, ["list-clients"]).output.isEmpty },
                        timeout: 10
                    ),
                    desc: "the control client went with the typing window's shell"
                )
            }
        }

        UBUITestRegister("swift_tmux_a_hosted_pane_resizes_ahead_of_the_server") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-optimistic"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.send("exec \(tmuxPath()) -L \(socket) -CC new-session -s optimistic\n")
                var first: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            first = shell.hostedWindowsForTesting.first
                            return first?.boundTmuxPaneIDs().isEmpty == false
                        },
                        timeout: 20
                    ),
                    desc: "the control client's window opens as a hosted Swift window"
                )
                guard let first, let firstWindow = first.window else { return }
                // A second tmux window: a sibling tab of the same session.
                t.expect(first.performTmuxIntent(.newWindow), desc: "a second tmux window is asked for")
                var second: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            second = shell.hostedWindowsForTesting.first { $0 !== first }
                            return second?.boundTmuxPaneIDs().isEmpty == false
                        },
                        timeout: 20
                    ),
                    desc: "and opens as a second hosted window"
                )
                guard let second, let firstPane = first.boundTmuxPaneIDs().first,
                    let firstSurface = first.tmuxSurfaceForTesting(firstPane),
                    let secondPane = second.boundTmuxPaneIDs().first,
                    let secondSurface = second.tmuxSurfaceForTesting(secondPane)
                else {
                    return
                }
                t.pump(1.0)
                let columnsBefore = firstSurface.drive.withTerminal { Int($0.columns) } ?? 0

                // Everything below until the server is asked runs in one turn:
                // no %layout-change can have been applied yet, so a model that
                // moved was moved by this side.
                var frame = firstWindow.frame
                frame.size.width += 240
                firstWindow.setFrame(frame, display: true)
                firstWindow.contentView?.layoutSubtreeIfNeeded()
                let reported = first.reportedTmuxClientGridForTesting
                let columnsAfter = firstSurface.drive.withTerminal { Int($0.columns) } ?? 0
                let siblingColumns = secondSurface.drive.withTerminal { Int($0.columns) } ?? 0
                t.expect(
                    columnsAfter > columnsBefore,
                    desc: "the hosted pane's model took the wider grid at once: \(columnsBefore) to \(columnsAfter)"
                )
                t.expect(
                    reported.map { siblingColumns == $0.columns } == true,
                    desc:
                        "and the sibling tab's pane took the reported client width before the server re-laid it: \(siblingColumns) against \(String(describing: reported))"
                )

                // The server confirms the size this side already drew.
                t.expect(
                    t.wait(
                        until: {
                            askTmux(socket: socket, ["display-message", "-p", "-t", "optimistic", "#{pane_width}"]).output
                                == "\(columnsAfter)"
                        },
                        timeout: 10
                    ),
                    desc: "and tmux lays the pane out at the width the model already had"
                )
            }
        }

        UBUITestRegister("swift_tmux_beam_raw_attach_keystrokes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-raw"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                t.expect(
                    askTmux(socket: socket, ["new-session", "-d", "-s", "raw0"]).status == 0,
                    desc: "a detached tmux session exists to attach to"
                )
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec \(tmuxPath()) -L \(socket) attach -t raw0"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    )
                else {
                    t.expect(false, desc: "a window opens running a full-screen tmux attach")
                    return
                }
                defer { shell.window?.close() }
                t.expect(
                    t.wait(until: { shell.tmuxPaneContext() == .rawAttach }, timeout: 10),
                    desc: "a full-screen `tmux attach` classifies as a raw attach"
                )
                t.expect(
                    !TmuxContextCommandProvider(target: shell).commands().isEmpty,
                    desc: "and Beam raises the tmux commands over it"
                )
                t.expect(shell.performTmuxIntent(.newWindow), desc: "its new-window intent goes out as keystrokes")
                // The server is the oracle: the chord reached the client only
                // if tmux itself now counts two windows in the session.
                t.expect(
                    t.wait(
                        until: { askTmux(socket: socket, ["display-message", "-p", "-t", "raw0", "#{session_windows}"]).output == "2" },
                        timeout: 10
                    ),
                    desc: "the prefix chord created a real second tmux window"
                )
            }
        }

        UBUITestRegister("swift_tmux_session_badge_is_coloured_per_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-badge"
                let session = "badgeses"
                let picks = UserDefaults.standard.dictionary(forKey: TmuxSessionBadge.colorsDefaultsKey)
                UserDefaults.standard.removeObject(forKey: TmuxSessionBadge.colorsDefaultsKey)
                t.killTmuxServer(onSocket: socket)
                defer {
                    t.killTmuxServer(onSocket: socket)
                    UserDefaults.standard.set(picks, forKey: TmuxSessionBadge.colorsDefaultsKey)
                }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s \(session)"),
                    let first = waitForShell(t, of: primary),
                    let firstBadge = first.tmuxSessionBadgeForTesting
                else {
                    t.expect(false, desc: "a tmux window's shell wears a session pill")
                    return
                }
                t.expect(firstBadge.text == "tmux \(session)", desc: "the pill names the tmux session")
                let expected = defaultColorIndex(for: session)
                t.expect(
                    firstBadge.colorIndex == expected,
                    desc: "a session nobody has picked for takes Core's default for its name"
                )
                t.expect(
                    firstBadge.nameInk == TmuxSessionBadge.ink(at: expected),
                    desc: "and the label is the ink Core says reads on that fill"
                )

                // A second window of the same session is the same unit: one
                // colour, from the session's name rather than the window's.
                t.expect(first.performTmuxIntent(.newWindow), desc: "a second tmux window opens")
                var second: TerminalWindowController?
                t.expect(
                    t.wait(
                        until: {
                            second = t.tmuxChildren(of: primary).compactMap { $0 as? TerminalWindowController }.first { $0 !== first }
                            return second?.tmuxSessionBadgeForTesting != nil
                        },
                        timeout: 8
                    ),
                    desc: "and wears a pill of its own"
                )
                guard let secondBadge = second?.tmuxSessionBadgeForTesting else {
                    return
                }
                t.expect(secondBadge.colorIndex == firstBadge.colorIndex, desc: "both windows of the session share its colour")

                // A pick recolours every window of the session live, and is
                // remembered under the session's name.
                firstBadge.togglePicker()
                t.pump(0.2)
                let swatches = firstBadge.pickerSwatches
                t.expect(swatches.count == TmuxSessionBadge.paletteCount, desc: "the pill's picker offers Core's palette")
                let picked = (expected + 3) % TmuxSessionBadge.paletteCount
                guard let swatch = swatches.first(where: { $0.tag == picked }) else {
                    t.expect(false, desc: "the palette holds the colour the reader picks")
                    return
                }
                swatch.performClick(nil)
                t.pump(0.2)
                t.expect(firstBadge.colorIndex == picked, desc: "the pill takes the picked colour")
                t.expect(secondBadge.colorIndex == picked, desc: "and every other window of the session follows it live")
                let stored = UserDefaults.standard.dictionary(forKey: TmuxSessionBadge.colorsDefaultsKey)
                t.expect(
                    (stored?[session] as? NSNumber)?.intValue == picked,
                    desc: "the pick is remembered under the session's name"
                )

                // %session-renamed re-typesets the pill and keeps the colour:
                // the session is the same unit under a new name.
                t.expect(
                    askTmux(socket: socket, ["rename-session", "-t", session, "renamedses"]).status == 0,
                    desc: "the session is renamed on the server"
                )
                t.expect(
                    t.wait(until: { firstBadge.text == "tmux renamedses" }, timeout: 8),
                    desc: "the pill re-typesets to the new session name"
                )
                t.expect(firstBadge.colorIndex == picked, desc: "and keeps the colour the session was given")
            }
        }

        UBUITestRegister("swift_tmux_close_preserves_siblings_and_offers_session_actions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-close"
                let session = "closeunit"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s \(session)"),
                    let shell = waitForShell(t, of: primary),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                shell.splitRight(nil)
                t.expect(t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 10), desc: "the tab to close has two panes")
                t.expect(shell.performTmuxIntent(.newWindow), desc: "the session has a second window")
                t.expect(
                    t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 20),
                    desc: "which surfaced as a second shell"
                )

                guard let survivor = t.tmuxChildren(of: primary).first(where: { $0 !== shell }) as? TerminalWindowController,
                    let survivorWindow = survivor.window
                else {
                    t.expect(false, desc: "the sibling has its own native window")
                    return
                }
                window.addTabbedWindow(survivorWindow, ordered: .above)
                window.tabGroup?.selectedWindow = window
                t.expect((window.tabGroup?.windows.count ?? 1) == 2, desc: "the fixture groups both windows as native tabs")

                window.performClose(nil)
                t.expect(
                    t.wait(until: { window.attachedSheet != nil }, timeout: 4),
                    desc: "closing a tmux tab asks before ending its processes"
                )
                guard let sheet = window.attachedSheet else { return }
                t.expect(sheetButton(sheet, titled: "Close Tab") != nil, desc: "the sheet offers a targeted tab close")
                t.expect(sheetButton(sheet, titled: "Detach") != nil, desc: "the sheet offers Detach")
                t.expect(sheetButton(sheet, titled: "Kill Session") != nil, desc: "and Kill Session")
                t.expect(pressSheetButton(sheet, titled: "Cancel"), desc: "and Cancel")
                t.pump(0.5)
                t.expect(window.isVisible, desc: "cancelling leaves the window open")
                t.expect(
                    askTmux(socket: socket, ["has-session", "-t", session]).status == 0,
                    desc: "and the session running"
                )

                let closingWindowID = shell.hostedWindowID
                guard let survivorPaneID = survivor.boundTmuxPaneIDs().first else {
                    t.expect(false, desc: "the sibling's pane is bound")
                    return
                }
                let process = askTmux(socket: socket, ["display-message", "-p", "-t", "%\(survivorPaneID)", "#{pane_pid}"]).output
                window.performClose(nil)
                guard t.wait(until: { window.attachedSheet != nil }, timeout: 4), let closeSheet = window.attachedSheet else {
                    t.expect(false, desc: "closing again offers a fresh tmux tab close choice")
                    return
                }
                t.expect(pressSheetButton(closeSheet, titled: "Close Tab"), desc: "the reader closes only this tab")
                t.expect(
                    t.wait(until: { shell.isClosedForTesting && t.tmuxChildren(of: primary).count == 1 }, timeout: 10),
                    desc: "only the requested tmux window leaves the projection"
                )
                t.expect(
                    !askTmux(socket: socket, ["list-windows", "-t", session, "-F", "#{window_id}"]).output
                        .split(separator: "\n").contains("@\(closingWindowID)"),
                    desc: "the requested window was removed on the server"
                )
                t.expect(
                    askTmux(socket: socket, ["display-message", "-p", "-t", "%\(survivorPaneID)", "#{pane_pid}"]).output == process,
                    desc: "the sibling keeps its original process"
                )
                t.expect(survivor.performTmuxIntent(.newWindow), desc: "the surviving tab can still use its control connection")
                t.expect(
                    t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 10),
                    desc: "the connection projects another tab"
                )
                guard let lastPaneTab = t.tmuxChildren(of: primary).first(where: { $0 !== survivor }) as? TerminalWindowController else {
                    t.expect(false, desc: "the new tmux tab has its own controller")
                    return
                }
                t.expect(
                    t.wait(until: { lastPaneTab.boundTmuxPaneIDs().count == 1 }, timeout: 10),
                    desc: "the last pane is bound before close"
                )
                lastPaneTab.closePane(nil)
                t.expect(
                    t.wait(until: { lastPaneTab.isClosedForTesting && t.tmuxChildren(of: primary).count == 1 }, timeout: 10),
                    desc: "closing a tab's last pane preserves its sibling tab and connection"
                )
                t.expect(survivor.performTmuxIntent(.newWindow), desc: "the session can create another tab after its sibling closes")
                t.expect(t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 10), desc: "detach will cover both tabs")

                survivorWindow.performClose(nil)
                t.expect(
                    t.wait(until: { survivorWindow.attachedSheet != nil }, timeout: 4),
                    desc: "the question is asked again"
                )
                guard let detachSheet = survivorWindow.attachedSheet else { return }
                t.expect(pressSheetButton(detachSheet, titled: "Detach"), desc: "the reader detaches")
                t.expect(
                    t.wait(until: { t.tmuxChildren(of: primary).isEmpty }, timeout: 10),
                    desc: "every window of the session goes, not just the one that was closed"
                )
                t.expect(
                    askTmux(socket: socket, ["has-session", "-t", session]).status == 0,
                    desc: "and the session is still running on the server, to attach again"
                )

                // Attached again, Kill Session ends it on the server.
                guard let second = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s \(session)"),
                    let reattached = waitForShell(t, of: second),
                    let reattachedWindow = reattached.window
                else {
                    t.expect(false, desc: "the session can be attached again")
                    return
                }
                reattachedWindow.performClose(nil)
                t.expect(
                    t.wait(until: { reattachedWindow.attachedSheet != nil }, timeout: 4),
                    desc: "the close asks again"
                )
                guard let killSheet = reattachedWindow.attachedSheet else { return }
                t.expect(pressSheetButton(killSheet, titled: "Kill Session"), desc: "the reader kills the session")
                t.expect(
                    t.wait(until: { !reattachedWindow.isVisible }, timeout: 10),
                    desc: "the window goes"
                )
                t.expect(
                    t.wait(until: { askTmux(socket: socket, ["has-session", "-t", session]).status != 0 }, timeout: 10),
                    desc: "and the session is gone from the server"
                )
            }
        }

        UBUITestRegister("swift_tmux_window_resize_sizes_the_whole_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Each pane has its own padding; remove it when comparing the
                // sum of visible cells with tmux's grid and divider column.
                let saved = t.configureAppending("[appearance]\npadding_left = 0.0\npadding_right = 0.0\n")
                defer { t.restoreConfiguration(saved) }
                let socket = "ubiquitty-uitest-tmux-resize"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s resizeses"),
                    let shell = waitForShell(t, of: primary),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                // A side-by-side split, so one pane's tile is nothing like the
                // window's own grid.
                t.expect(shell.performTmuxIntent(.splitSideBySide), desc: "the window splits into two panes")
                let didSplit = t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20)
                t.expect(
                    didSplit,
                    desc: "and tmux reports both (bound \(shell.boundTmuxPaneIDs().sorted()) across "
                        + "\(t.tmuxChildren(of: primary).count) hosted windows)"
                )

                // The grid standing before the resize, so what is read back is
                // the resize's own report rather than the one the bind made.
                let spelled = { (grid: (columns: Int, rows: Int)?) in grid.map { "\($0.columns)x\($0.rows)" } }
                let beforeResize = spelled(shell.reportedTmuxClientGridForTesting)
                window.setContentSize(NSSize(width: 900, height: 560))
                t.expect(
                    t.wait(until: { spelled(shell.reportedTmuxClientGridForTesting) != beforeResize }, timeout: 6),
                    desc: "the resize reported a new client grid, not the bind's (\(beforeResize ?? "none"))"
                )
                guard let reported = shell.reportedTmuxClientGridForTesting else {
                    t.expect(false, desc: "the resized window reports a client size to tmux")
                    return
                }
                // Every expectation below is stated relative to `reported`, so
                // one that fell back to the bind's grid would read the server
                // agreeing with a report the resize never made.
                t.expect(
                    spelled(reported) != beforeResize,
                    desc: "and the grid compared against the server is the resize's own (\(spelled(reported) ?? "none"))"
                )
                // The server is the oracle: the client tmux tiles the session
                // across is the grid this window reported. Asked as the client's
                // width and the window's own size, because `#{client_height}`
                // renders empty on tmux 3.7 and a comparison against it would
                // pass for a client of any height at all.
                t.expect(
                    t.wait(
                        until: { askTmux(socket: socket, ["list-clients", "-F", "#{client_width}"]).output == "\(reported.columns)" },
                        timeout: 10
                    ),
                    desc: "tmux sized its control client to the window's whole width (\(reported.columns))"
                )
                t.expect(
                    t.wait(
                        until: {
                            askTmux(socket: socket, ["display-message", "-p", "-t", "resizeses", "#{window_width}x#{window_height}"]).output
                                == "\(reported.columns)x\(reported.rows)"
                        },
                        timeout: 10
                    ),
                    desc: "and laid the session's window out at that whole grid (\(reported.columns)x\(reported.rows))"
                )
                let panes = shell.boundTmuxPaneIDs().sorted()
                // tmux tiles the client's width across the split, minus the
                // divider column between the two panes.
                t.expect(
                    t.wait(until: { paneColumns(of: shell, panes: panes).reduce(0, +) == reported.columns - 1 }, timeout: 10),
                    desc:
                        "tmux tiled the whole reported width across the panes (\(paneColumns(of: shell, panes: panes)), expected total \(reported.columns - 1))"
                )
                let tileColumns = paneColumns(of: shell, panes: panes)
                t.expect(tileColumns.count == 2, desc: "both panes hold a terminal of tmux's own sizing")
                t.expect(
                    tileColumns.allSatisfy { $0 < reported.columns },
                    desc: "and each tile is narrower than the client size: the window reported its content, not a tile"
                )
            }
        }

        UBUITestRegister("swift_tmux_a_font_change_reports_the_reflowed_client_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-font"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the harness runs inside the app")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(13.0)
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s fontses"),
                    let shell = waitForShell(t, of: primary),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                // Split, so Core answers the font change by holding the window
                // and reflowing the grid. That is the classification with no
                // window move in it, and so no content-frame edge: the only
                // thing that can tell tmux is the cell-metric answer itself.
                t.expect(shell.performTmuxIntent(.splitSideBySide), desc: "the window splits into two panes")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and tmux reports both (bound \(shell.boundTmuxPaneIDs().sorted()))"
                )
                let spelled = { (grid: (columns: Int, rows: Int)?) in grid.map { "\($0.columns)x\($0.rows)" } }
                let frameBefore = window.frame
                let beforeFont = spelled(shell.reportedTmuxClientGridForTesting)

                app.settingsSetFontSize(17.0)
                t.expect(
                    t.wait(until: { spelled(shell.reportedTmuxClientGridForTesting) != beforeFont }, timeout: 8),
                    desc: "the bigger cell reports a new client grid, not the one the bind made (\(beforeFont ?? "none"))"
                )
                guard let reported = shell.reportedTmuxClientGridForTesting else {
                    t.expect(false, desc: "the window reports a client size to tmux")
                    return
                }
                t.expect(
                    abs(window.frame.width - frameBefore.width) <= 0.5 && abs(window.frame.height - frameBefore.height) <= 0.5,
                    desc: "while the window held its frame (\(frameBefore.size) to \(window.frame.size))"
                )
                // The server is the oracle, as everywhere here: nothing moved
                // the window, so a client this wide can only have come from
                // the font change reporting the grid it reflowed into.
                t.expect(
                    t.wait(
                        until: { askTmux(socket: socket, ["list-clients", "-F", "#{client_width}"]).output == "\(reported.columns)" },
                        timeout: 10
                    ),
                    desc: "and tmux sized its control client to the reflowed grid (\(reported.columns))"
                )
            }
        }

        UBUITestRegister("swift_tmux_panes_each_own_their_clients") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-panes"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s paneses"),
                    let shell = waitForShell(t, of: primary)
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                t.expect(shell.performTmuxIntent(.splitSideBySide), desc: "the window splits into two panes")
                t.expect(
                    t.wait(until: { shell.boundTmuxPaneIDs().count == 2 }, timeout: 20),
                    desc: "and both panes bind a surface"
                )
                let panes = shell.boundTmuxPaneIDs().sorted()
                guard panes.count == 2,
                    let firstSurface = shell.tmuxSurfaceForTesting(panes[0]),
                    let secondSurface = shell.tmuxSurfaceForTesting(panes[1])
                else {
                    t.expect(false, desc: "both panes are bound to surfaces")
                    return
                }
                // Each pane's terminal carries its own clients, so an OSC 52
                // read from one pane resolves against that pane rather than
                // riding the other's standing grant.
                t.expect(
                    firstSurface.drive.sessionIdentity != secondSurface.drive.sessionIdentity,
                    desc: "the two panes are two consent identities, not one"
                )
                t.expect(
                    TerminalWindowController.surface(forSessionIdentity: firstSurface.drive.sessionIdentity) === firstSurface
                        && TerminalWindowController.surface(forSessionIdentity: secondSurface.drive.sessionIdentity) === secondSurface,
                    desc: "and each resolves to its own pane"
                )
                t.expect(
                    firstSurface.drive.withTerminal { $0.capabilityPolicy.installed() } == true
                        && secondSurface.drive.withTerminal { $0.capabilityPolicy.installed() } == true,
                    desc: "each pane's terminal carries its own capability policy"
                )

                // A pane's clients go before the session reuses its terminal,
                // and only that pane's.
                shell.unbindTmuxPane(panes[0])
                t.expect(
                    TerminalWindowController.surface(forSessionIdentity: firstSurface.drive.sessionIdentity) == nil,
                    desc: "unbinding a pane drops its consent destination"
                )
                t.expect(
                    TerminalWindowController.surface(forSessionIdentity: secondSurface.drive.sessionIdentity) === secondSurface,
                    desc: "and leaves the other pane's standing"
                )
            }
        }

        // tmux sends a -CC client no OSC 52 for a copy-mode copy, so the copy
        // reaches the system clipboard by pulling the pane's paste buffer when
        // the pane leaves copy mode's notification behind. The baseline differs
        // from the sentinel, so a pass proves the pull wrote.
        UBUITestRegister("swift_tmux_copy_mode_pulls_into_the_clipboard") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-copy-pull"
                let sentinel = "UITEST_CLIP_PULL_9F3A"
                let outcome = copyModePull(t, socket: socket, clipboardWrite: "allow", sentinel: sentinel, waitFor: 10)
                t.expect(outcome == .pulled, desc: "the copy-mode buffer reaches the clipboard (\(outcome))")
            }
        }

        // clipboard_write = "deny" binds the copy-mode pull like any other
        // programmatic clipboard write: the pane's terminal is seeded with the
        // configured policy when the hosting window adopts it, and the pull is
        // judged against that pane's policy. The oracle is the sentinel itself,
        // over the whole round-trip budget the allowing case needs.
        UBUITestRegister("swift_tmux_copy_mode_pull_obeys_a_denied_clipboard_write") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-copy-deny"
                let outcome = copyModePull(t, socket: socket, clipboardWrite: "deny", sentinel: "UITEST_CLIP_DENY_7C21", waitFor: 10)
                t.expect(
                    outcome == .withheld,
                    desc: "a denied clipboard write keeps the copy-mode buffer out of the clipboard (\(outcome))"
                )
            }
        }

        // A tmux window behind another restyles with a theme picked as
        // Settings picks one, without being brought to the front.
        UBUITestRegister("swift_tmux_background_tab_restyles_with_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app, let dark = catalogThemeIndex(named: "One Dark"),
                    let light = catalogThemeIndex(named: "One Light")
                else {
                    t.expect(false, desc: "the settings path and both comparison themes exist")
                    return
                }
                let unthemed = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(unthemed)
                    TerminalWindowController.applyThemeToOpenWindows()
                }
                app.settingsSelectTheme(dark)
                let socket = "ubiquitty-uitest-theme-restyle"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -s themed"),
                    let shell = waitForShell(t, of: primary), let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
                    return
                }
                t.expect(shell.performTmuxIntent(.newWindow), desc: "the session has a second window")
                t.expect(t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 20), desc: "which surfaced as a second shell")
                guard let front = t.tmuxChildren(of: primary).first(where: { $0 !== shell }) as? TerminalWindowController,
                    let frontWindow = front.window, let frontPane = front.boundTmuxPaneIDs().first,
                    let frontSurface = front.tmuxSurfaceForTesting(frontPane)
                else {
                    t.expect(false, desc: "the second tmux window has a shell of its own")
                    return
                }
                if window.tabGroup !== frontWindow.tabGroup {
                    window.addTabbedWindow(frontWindow, ordered: .above)
                }
                window.tabGroup?.selectedWindow = frontWindow
                guard let group = window.tabGroup, group.windows.count == 2, group.selectedWindow === frontWindow else {
                    t.expect(false, desc: "both tmux windows stand as native tabs with the second in front")
                    return
                }
                let foreground = { front.themeForeground(of: frontSurface) }
                let darkInk = foreground()
                expectBackgroundTabsWear(t, windows: group.windows, foreground: darkInk, isDark: true, state: "the dark theme on tmux tabs")
                app.settingsSelectTheme(light)
                t.expect(foreground() != darkInk, desc: "the light theme reached the tmux tab in front")
                expectBackgroundTabsWear(
                    t,
                    windows: group.windows,
                    foreground: foreground(),
                    isDark: false,
                    state: "a theme picked over tmux tabs"
                )
            }
        }

        // Two control sessions are two window groups: neither merges into
        // the other's tabs, and input typed into one reaches only its own.
        UBUITestRegister("swift_tmux_two_sessions_keep_separate_tab_groups") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let sockets = ["ubiquitty-uitest-group-a", "ubiquitty-uitest-group-b"]
                sockets.forEach { t.killTmuxServer(onSocket: $0) }
                defer { sockets.forEach { t.killTmuxServer(onSocket: $0) } }
                guard let a = t.launchTmuxArguments("-L \(sockets[0]) -CC new-session -s a0"),
                    let b = t.launchTmuxArguments("-L \(sockets[1]) -CC new-session -s b0"),
                    let shellA = waitForShell(t, of: a), let shellB = waitForShell(t, of: b),
                    let paneA = shellA.boundTmuxPaneIDs().first, let paneB = shellB.boundTmuxPaneIDs().first,
                    let surfaceA = shellA.tmuxSurfaceForTesting(paneA), let surfaceB = shellB.tmuxSurfaceForTesting(paneB)
                else {
                    t.expect(false, desc: "two control sessions each surface a window")
                    return
                }
                t.expect(shellA !== shellB, desc: "the two sessions' windows are distinct")
                t.expect(
                    shellA.window?.tabGroup == nil || shellA.window?.tabGroup !== shellB.window?.tabGroup,
                    desc: "and in separate tab groups"
                )
                surfaceA.send("k=111; echo \"SESS-A-${k}\"\n")
                surfaceB.send("k=222; echo \"SESS-B-${k}\"\n")
                t.expect(
                    t.wait(until: { surfaceA.gridTextForTesting().contains("SESS-A-111") }, timeout: 10),
                    desc: "session A ran its command"
                )
                t.expect(
                    t.wait(until: { surfaceB.gridTextForTesting().contains("SESS-B-222") }, timeout: 10),
                    desc: "session B ran its command"
                )
                t.expect(!surfaceA.gridTextForTesting().contains("SESS-B-222"), desc: "and A's pane is free of B's output")
            }
        }

        // A server that dies while attached ends the control client, and every
        // window the session hosted goes with it; the application carries on.
        UBUITestRegister("swift_tmux_kill_server_closes_every_hosted_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-kill-server"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -s ks0"),
                    let shell = waitForShell(t, of: primary)
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a window")
                    return
                }
                t.expect(shell.performTmuxIntent(.newWindow), desc: "the session opens a second window")
                t.expect(t.wait(until: { t.tmuxChildren(of: primary).count == 2 }, timeout: 20), desc: "which surfaces as a second window")
                let hosted = t.tmuxChildren(of: primary).compactMap { $0 as? TerminalWindowController }
                t.killTmuxServer(onSocket: socket)
                t.expect(
                    t.wait(until: { t.tmuxChildren(of: primary).isEmpty }, timeout: 10),
                    desc: "the server's exit closes every hosted window"
                )
                t.expect(hosted.allSatisfy { $0.window?.isVisible != true }, desc: "and none stays on screen")
                guard let plain = t.newWindowRunning(nil) else {
                    t.expect(false, desc: "a fresh window opens after the session ended")
                    return
                }
                defer { plain.window?.close() }
                t.sendText("echo afterexit=$((40+2))\r", to: plain)
                t.expect(t.wait(forText: "afterexit=42", in: plain, timeout: 10), desc: "and a fresh window still runs commands")
            }
        }

        // A reattach recovers the pane's screen from the server: tmux sends a
        // new client only the bytes written after it attached, so text written
        // before the detach can reach the fresh pane only through the attach's
        // capture of the server's retained screen.
        UBUITestRegister("swift_tmux_reattach_recovers_the_pane_content") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-reattach"
                let attach = "-L \(socket) -CC new-session -A -s dr0"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments(attach), let shell = waitForShell(t, of: primary),
                    let pane = shell.boundTmuxPaneIDs().first, let surface = shell.tmuxSurfaceForTesting(pane)
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a window before the detach")
                    return
                }
                let marker = "UITEST_DR_RECOVER_5E8B=42"
                surface.send("echo UITEST_DR_RECOVER_5E8B=$((6*7))\n")
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains(marker) }, timeout: 10),
                    desc: "the marker ran before the detach"
                )
                t.expect(askTmux(socket: socket, ["detach-client", "-s", "dr0"]).status == 0, desc: "the server detaches the client")
                t.expect(t.wait(until: { t.tmuxChildren(of: primary).isEmpty }, timeout: 10), desc: "the detach closes the hosted window")
                t.expect(askTmux(socket: socket, ["has-session", "-t", "dr0"]).status == 0, desc: "and the session stays on the server")

                guard let second = t.launchTmuxArguments(attach), let reattached = waitForShell(t, of: second),
                    let freshPane = reattached.boundTmuxPaneIDs().first, let fresh = reattached.tmuxSurfaceForTesting(freshPane)
                else {
                    t.expect(false, desc: "the reattach surfaces the session's window again")
                    return
                }
                defer { second.window?.close() }
                t.expect(
                    t.wait(until: { fresh.gridTextForTesting().contains(marker) }, timeout: 10),
                    desc: "the reattached pane shows the text written before the detach"
                )
            }
        }
        // Cmd-K in a tmux window clears the pane it is pressed in. The pane's
        // view is not in the window's local layout model, so a gesture that
        // looked only there reached nothing; the clear runs on the pane's
        // mirror and the shell behind it is asked to redraw through tmux.
        UBUITestRegister("swift_tmux_cmd_k_clears_the_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-uitest-tmux-clear"
                t.killTmuxServer(onSocket: socket)
                defer {
                    t.closeAllWindows()
                    t.killTmuxServer(onSocket: socket)
                }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -A -s clr"),
                    let shell = waitForShell(t, of: primary),
                    let pane = shell.boundTmuxPaneIDs().first,
                    let surface = shell.tmuxSurfaceForTesting(pane),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a tmux -CC session surfaces a window with a pane")
                    return
                }
                surface.send("seq 1 200; echo TMUX_\"\"CLEAR\n")
                let isFilled = t.wait(
                    until: {
                        surface.gridTextForTesting().contains("TMUX_CLEAR") && surface.drive.readSnapshot().scrollbackCount > 60
                    },
                    timeout: 20
                )
                guard isFilled else {
                    t.expect(false, desc: "the tmux pane produced scrollback (got \(surface.drive.readSnapshot().scrollbackCount))")
                    return
                }
                guard let item = RemoteClearScenarios.editMenuItem(key: "k", modifiers: [.command]), let action = item.action
                else {
                    t.expect(false, desc: "the Edit menu holds a Cmd-K item")
                    return
                }
                window.makeFirstResponder(surface)
                guard let target = RemoteClearScenarios.answerer(of: action, from: window.firstResponder) else {
                    t.expect(false, desc: "a responder in the tmux window answers \(NSStringFromSelector(action))")
                    return
                }
                let wasScrollback = surface.drive.readSnapshot().scrollbackCount
                NSApp.sendAction(action, to: target, from: item)
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().scrollbackCount == 0 }, timeout: 10),
                    desc:
                        "Cmd-K empties the tmux pane's history (was \(wasScrollback), now \(surface.drive.readSnapshot().scrollbackCount))"
                )
                t.expect(
                    t.wait(until: { !surface.gridTextForTesting().contains("TMUX_CLEAR") }, timeout: 10),
                    desc: "Cmd-K clears the tmux pane's screen"
                )
                surface.send("echo AFTER_\"\"CLEAR\n")
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains("AFTER_CLEAR") }, timeout: 10),
                    desc: "the cleared tmux pane still answers input"
                )
            }
        }
    }
}

// File scope because a scenario is a block the runner invokes, and the helpers
// below are shared by several of them.

/// Exercises persisted tmux references against a surviving and a replacement server.
///
/// - Parameter t: The native test harness.
@MainActor
private func checkSavedTmuxArrangement(_ t: UBUITestContext) {
    t.closeAllWindows()
    let socket = "ubiquitty-uitest-arrangement-\(ProcessInfo.processInfo.processIdentifier)"
    let store = "/tmp/ubq-arrangement-" + String(UUID().uuidString.prefix(8))
    let previousStore = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
    try? FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    setenv("UBIQUITTY_HOME", store, 1)
    t.killTmuxServer(onSocket: socket)
    defer {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        t.closeAllWindows()
        t.killTmuxServer(onSocket: socket)
        if let previousStore { setenv("UBIQUITTY_HOME", previousStore, 1) } else { unsetenv("UBIQUITTY_HOME") }
        try? FileManager.default.removeItem(atPath: store)
    }
    // The reattach finds its daemon where a complete bundle carries it; see
    // `placeBundledHost`.
    guard let bundled = t.placeBundledHost() else { return }
    defer { bundled.remove() }
    let bundledHost = bundled.path
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: bundledHost)
    daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
    daemon.environment = ProcessInfo.processInfo.environment
    do {
        try daemon.run()
    } catch {
        t.expect(false, desc: "the isolated daemon starts (\(error))")
        return
    }
    defer {
        t.closeAllWindows()
        if daemon.isRunning { daemon.terminate() }
        daemon.waitUntilExit()
    }
    let daemonSocket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(bundledHost)))
    guard t.wait(until: { FileManager.default.fileExists(atPath: daemonSocket) }, timeout: 20),
        let shared = TerminalWindowController.spawn(), let sharedSurface = shared.focusedSurfaceForTesting
    else {
        t.expect(false, desc: "a local shell opens beside the ready daemon")
        return
    }
    sharedSurface.send("UBQ_DAEMON_ARRANGEMENT_MARK=survived; echo daemon-arrangement-ready\n")
    t.expect(
        t.wait(
            until: { sharedSurface.searchScrollbackAndWait("daemon-arrangement-ready", isCaseSensitive: true).totalMatches > 0 },
            timeout: 10
        ),
        desc: "the daemon-bound shell holds its mark before capture"
    )
    shared.shareThisWindow(nil)
    if let window = shared.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
    guard t.wait(until: { sharedSurface.drive.sharedWorkspaceResult.workspaceID != 0 }, timeout: 20) else {
        t.expect(false, desc: "the shell is adopted by the isolated daemon")
        return
    }
    let daemonSessionID = sharedSurface.remoteSessionID
    guard
        let primary = TerminalWindowController.spawn(
            arguments: [tmuxPath(), "-L", socket, "-f", "/dev/null", "-CC", "new-session", "-s", "saved"],
            localePolicy: .auto,
            sessionLifetime: .endsWithChild,
            tmuxControlHost: ""
        )
    else {
        t.expect(false, desc: "the control client launches")
        return
    }
    t.expect(
        t.wait(
            until: {
                primary.liveHostedWindows.first?.savedTmuxWindow?.canReconnectLocally == true
            },
            timeout: 20
        ),
        desc: "the runtime confirms the local server identity"
    )
    guard let original = primary.liveHostedWindows.first else { return }
    t.expect(askTmux(socket: socket, ["split-window", "-h", "-l", "25", "-t", "saved"]).status == 0, desc: "the server splits its window")
    t.expect(askTmux(socket: socket, ["new-window", "-t", "saved", "-n", "logs"]).status == 0, desc: "the server creates a second window")
    t.expect(
        t.wait(
            until: {
                primary.liveHostedWindows.count == 2 && original.boundTmuxPaneIDs().count == 2
            },
            timeout: 20
        ),
        desc: "both windows and the split are rendered"
    )
    guard let paneID = original.boundTmuxPaneIDs().sorted().first,
        let surface = original.tmuxSurfaceForTesting(paneID)
    else { return }
    surface.send("UBQ_ARRANGEMENT_MARK=survived; echo arrangement-ready\n")
    t.expect(
        t.wait(
            until: {
                askTmux(socket: socket, ["capture-pane", "-p", "-t", "%\(paneID)"]).output.contains("arrangement-ready")
            },
            timeout: 10
        ),
        desc: "the original tmux process is ready"
    )
    original.setCustomTitles(tab: "Saved tmux tab")
    original.handSetTags = ["saved-tmux"]
    primary.liveHostedWindows.first(where: { $0 !== original })?.setCustomTitles(tab: "Saved tmux logs")
    let persisted = LayoutSession()
    persisted.identifier = "tmux-arrangement"
    persisted.name = "Tmux arrangement"
    persisted.groups = TerminalWindows.capturedGroupsForSavedWorkspace()
    do { try SessionLayout.save([persisted]) } catch {
        t.expect(false, desc: "the arrangement can be saved")
        return
    }
    guard let groups = SessionLayout.namedWorkspaces().first(where: { $0.identifier == persisted.identifier })?.groups else {
        t.expect(false, desc: "the saved arrangement can be read back")
        return
    }
    let liveGroups = groups.compactMap { group -> LayoutGroup? in
        let result = LayoutGroup()
        result.frame = group.frame
        result.tabs = group.tabs.filter { SavedTerminalPresentation.decoded($0.paneLayout ?? "")?.tmuxWindow != nil }
        return result.tabs.isEmpty ? nil : result
    }
    t.expect(liveGroups.flatMap(\.tabs).count == 2, desc: "every hosted window is captured")
    t.expect(groups.flatMap(\.tabs).count == 4, desc: "the arrangement captures a local recipe, a daemon reference, and both tmux windows")
    let session = LayoutSession()
    session.groups = liveGroups
    t.expect(TerminalWindows.summary(for: session).contains("2 hosted tabs: reconnect"), desc: "tmux references are labelled as reconnects")

    primary.window?.close()
    shared.window?.close()
    t.pump(0.5)
    t.expect(askTmux(socket: socket, ["has-session", "-t", "saved"]).status == 0, desc: "the session outlives its client")
    guard let existing = TerminalWindowController.spawn() else { return }
    var didRestore: Bool?
    Task { @MainActor in didRestore = await TerminalWindows.restoreArrangementGroups(groups) }
    t.expect(t.wait(until: { didRestore != nil }, timeout: 40), desc: "the mixed local and hosted arrangement finishes")
    t.expect(didRestore == true, desc: "all saved tabs reopen")
    t.expect(!existing.isClosedForTesting, desc: "additive restoration preserves an existing local window")
    guard
        let restoredShared = TerminalWindowController.spawnedControllers.first(where: { $0.remoteAttachment?.sessionID == daemonSessionID }
        ),
        let restoredSharedSurface = restoredShared.remoteSurface
    else {
        t.expect(false, desc: "the daemon-backed window is restored with its session identity")
        return
    }
    restoredSharedSurface.send("echo daemon-restored-$UBQ_DAEMON_ARRANGEMENT_MARK\n")
    t.expect(
        t.wait(
            until: { restoredSharedSurface.searchScrollbackAndWait("daemon-restored-survived", isCaseSensitive: true).totalMatches > 0 },
            timeout: 10
        ),
        desc: "the mixed arrangement reconnects to the original daemon-owned process"
    )
    let hosted = TerminalWindowController.spawnedControllers.filter { $0.savedTmuxWindow?.canReconnectLocally == true }
    t.expect(hosted.count == 2, desc: "one client restores both hosted windows")
    t.expect(
        hosted.contains(where: { $0.customTabTitle == "Saved tmux logs" }),
        desc: "a sibling created by the same attach also receives its saved presentation"
    )
    guard let restoredOriginal = hosted.first(where: { $0.hostedWindowID == original.hostedWindowID }),
        let restoredSurface = restoredOriginal.tmuxSurfaceForTesting(paneID)
    else { return }
    t.expect(restoredOriginal.boundTmuxPaneIDs().count == 2, desc: "the server's split survives")
    t.expect(
        restoredOriginal.customTabTitle == "Saved tmux tab" && restoredOriginal.handSetTags == ["saved-tmux"],
        desc: "presentation follows the correct hosted window"
    )
    restoredSurface.send("echo restored-$UBQ_ARRANGEMENT_MARK\n")
    t.expect(
        t.wait(
            until: {
                restoredSurface.searchScrollbackAndWait("restored-survived").totalMatches > 0
            },
            timeout: 10
        ),
        desc: "the restored terminal still runs the original shell"
    )

    var didRepeat: Bool?
    Task { @MainActor in didRepeat = await TerminalWindows.restoreArrangementGroups(liveGroups) }
    t.expect(t.wait(until: { didRepeat != nil }, timeout: 10) && didRepeat == true, desc: "repeated activation reuses live windows")
    t.expect(
        TerminalWindowController.spawnedControllers.filter { $0.savedTmuxWindow?.canReconnectLocally == true }.count == 2,
        desc: "repeated activation creates no duplicate windows"
    )
    var didReplace: Bool?
    Task { @MainActor in didReplace = await TerminalWindows.replaceWindows(with: liveGroups) }
    t.expect(t.wait(until: { didReplace != nil }, timeout: 10) && didReplace == true, desc: "explicit replacement completes")
    t.expect(!restoredOriginal.isClosedForTesting, desc: "replacement keeps the control client needed by reused hosted tabs")
    t.expect(
        askTmux(socket: socket, ["list-clients", "-F", "#{client_pid}"]).output.split(separator: "\n").count == 1,
        desc: "one control client owns the restored views"
    )

    t.closeAllWindows()
    t.pump(0.5)
    t.killTmuxServer(onSocket: socket)
    t.expect(
        askTmux(socket: socket, ["new-session", "-d", "-s", "replacement"]).status == 0,
        desc: "a replacement server reuses the socket"
    )
    guard let kept = TerminalWindowController.spawn(), let keptWindow = kept.window else { return }
    var didRestoreStale: Bool?
    Task { @MainActor in didRestoreStale = await TerminalWindows.restoreArrangementGroups(liveGroups) }
    t.expect(t.wait(until: { didRestoreStale != nil }, timeout: 40), desc: "stale identities finish with a refusal")
    t.expect(didRestoreStale == false, desc: "a restarted server cannot substitute its sessions")
    t.expect(
        !kept.isClosedForTesting && TerminalWindows.keptBySession().count == 1,
        desc: "refusal keeps the existing shell without launching a replacement"
    )
    if let sheet = keptWindow.attachedSheet { keptWindow.endSheet(sheet) }
}

/// The Swift-shell window a tmux -CC session's first window surfaced as.
///
/// - Parameters:
///   - t: The harness.
///   - primary: The control window the launch returned.
/// - Returns: The shell, or nil when none surfaced with a bound pane in time.
@MainActor
private func waitForShell(_ t: UBUITestContext, of primary: TerminalWindowController) -> TerminalWindowController? {
    var shell: TerminalWindowController?
    _ = t.wait(
        until: {
            shell = t.tmuxChildren(of: primary).first as? TerminalWindowController
            return shell?.boundTmuxPaneIDs().isEmpty == false
        },
        timeout: 10
    )
    return shell
}

/// What became of a copy-mode pull.
private enum CopyModePullOutcome: Equatable {
    /// The pane's paste buffer reached the clipboard.
    case pulled
    /// The clipboard kept its baseline for the whole wait.
    case withheld
    /// The session never surfaced a pane to copy from.
    case noPane
    /// The pane never entered copy mode, so no pull was owed.
    case neverEnteredCopyMode
}

/// Puts a sentinel in a fresh session's paste buffer, enters copy mode, and
/// watches the clipboard for it.
///
/// The configured `clipboard_write` is set before the session launches, so the
/// pane's terminal is seeded with it the way a window seeds any pane.
///
/// - Parameters:
///   - t: The native test harness.
///   - socket: The private server's socket name.
///   - clipboardWrite: The `clipboard_write` policy the pane runs under.
///   - sentinel: The text put in the paste buffer.
///   - waitFor: How long the clipboard is watched.
/// - Returns: Whether the sentinel arrived, and whether a pull was owed.
@MainActor
private func copyModePull(
    _ t: UBUITestContext,
    socket: String,
    clipboardWrite: String,
    sentinel: String,
    waitFor timeout: TimeInterval
) -> CopyModePullOutcome {
    let savedText = NSPasteboard.general.string(forType: .string)
    let saved = t.configureAppending("[security]\nclipboard_write = \(tomlQuoted(clipboardWrite))\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("UITEST_CLIP_BASELINE", forType: .string)
    t.killTmuxServer(onSocket: socket)
    defer {
        // The server goes before the policy is restored: a pull answered after
        // the restore would be judged under the old policy.
        t.killTmuxServer(onSocket: socket)
        t.restoreConfiguration(saved)
        NSPasteboard.general.clearContents()
        if let savedText { NSPasteboard.general.setString(savedText, forType: .string) }
    }
    guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -s pull"),
        let shell = waitForShell(t, of: primary),
        let pane = shell.boundTmuxPaneIDs().first,
        let surface = shell.tmuxSurfaceForTesting(pane)
    else {
        return .noPane
    }
    t.pump(0.5)
    surface.send("\(tmuxPath()) set-buffer '\(sentinel)'; \(tmuxPath()) copy-mode\n")
    let arrived = t.wait(
        until: { (NSPasteboard.general.string(forType: .string) ?? "").contains(sentinel) },
        timeout: timeout
    )
    // A withheld pull means something only if one was owed: the pane has to
    // have entered copy mode, which is the notification the pull answers.
    let inMode = askTmux(socket: socket, ["display-message", "-p", "-t", "%\(pane)", "#{pane_in_mode}"]).output == "1"
    if arrived { return .pulled }
    return inMode ? .withheld : .neverEnteredCopyMode
}

/// Where tmux is, the way the product resolves it: an app launched from the
/// Dock inherits a minimal PATH, so the common install locations are tried
/// before falling back to the name.
///
/// - Returns: An absolute path, or "tmux" for PATH to resolve.
private func tmuxPath() -> String {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
}

/// Asks the scenario's own tmux server a question, outside the app.
///
/// The server is the oracle for what a scenario's window actually did: what
/// this side believes it sent is not evidence that tmux acted on it.
///
/// - Parameters:
///   - socket: The private server's socket name.
///   - arguments: The tmux command and its arguments.
/// - Returns: The exit status and the trimmed output.
private func askTmux(socket: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let task = Process()
    let path = tmuxPath()
    if path.hasPrefix("/") {
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-L", socket] + arguments
    } else {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "-L", socket] + arguments
    }
    let output = Pipe()
    task.standardOutput = output
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return (-1, "")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// The columns tmux sized each of a window's panes to, read from the session
/// terminals the panes' surfaces adopt.
///
/// - Parameters:
///   - shell: The hosting window.
///   - panes: The pane ids to read, in order.
/// - Returns: One column count per pane that still holds a terminal.
@MainActor
private func paneColumns(of shell: TerminalWindowController, panes: [Int32]) -> [Int] {
    panes.compactMap { pane in
        shell.tmuxSurfaceForTesting(pane)?.drive.withTerminal { terminal in Int(terminal.columns) }
    }
}

/// Core's default palette index for a session name, the answer the pill takes
/// when nobody has picked one.
///
/// - Parameter session: The session's name.
/// - Returns: A palette index.
@MainActor
private func defaultColorIndex(for session: String) -> Int {
    session.withCString { bytes in
        Int(Ubiquitty.Runtime.defaultTmuxSessionBadgeColorIndex(std.string_view(bytes)))
    }
}

/// A button of a sheet, by the title a reader reads on it.
///
/// - Parameters:
///   - sheet: The sheet standing on a window.
///   - title: The button's title.
/// - Returns: The button, or nil when the sheet has none by that title.
@MainActor
private func sheetButton(_ sheet: NSWindow, titled title: String) -> NSButton? {
    guard let root = sheet.contentView else { return nil }
    var found: NSButton?
    func walk(_ view: NSView) {
        if let button = view as? NSButton, button.title == title {
            found = button
            return
        }
        for child in view.subviews where found == nil {
            walk(child)
        }
    }
    walk(root)
    return found
}

/// Presses a sheet's button the way a reader does.
///
/// - Parameters:
///   - sheet: The sheet standing on a window.
///   - title: The button's title.
/// - Returns: Whether a button by that title was pressed.
@MainActor
private func pressSheetButton(_ sheet: NSWindow, titled title: String) -> Bool {
    guard let button = sheetButton(sheet, titled: title) else { return false }
    button.performClick(nil)
    return true
}
