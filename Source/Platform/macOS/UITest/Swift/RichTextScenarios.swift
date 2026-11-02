// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// RichTextScenarios.swift — an OSC 7404 rich text block in a real window
// (Docs/rich-text.md): a real shell prints the block, the window's renderer
// draws it from the typography table it published, and real mouse events
// select its characters, which copy as plain text.
//
// Core's tests prove the layout, the caret and the copy against a synthetic
// table; this is the proof that the published table, the drawn raster and the
// pointer ladder meet in a running app. A press or a drag aimed at a
// character is aimed through Core's own layout of the block, so a scenario
// asserts which characters the pointer ladder took, never where a glyph
// happened to fall.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// A mouse event at a point in the window.
///
/// - Parameters:
///   - type: Which mouse event.
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
///   - clickCount: The click's number in a multiple click.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint, clickCount: Int = 1) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// A block on a surface, with the geometry to aim the pointer at its
/// characters.
@MainActor
private struct PlacedBlock {
    let surface: TerminalSurface
    let row: Int
    let column: Int
    /// The block's top-left corner, in view coordinates.
    let origin: CGPoint
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Core's layout of the block, which the pointer ladder hit-tests.
    let layout: Ubiquitty.RichText.Layout

    /// Reads the first block on a surface's primary screen.
    ///
    /// - Parameter surface: The surface.
    /// - Returns: The block, or nil when there is none or no cell is measured.
    static func first(on surface: TerminalSurface) -> PlacedBlock? {
        let read = surface.drive.withTerminal { terminal -> (Int, Int, Ubiquitty.RichText.Layout)? in
            guard let block = terminal.richTextBlocks.blocks(.Primary).first else { return nil }
            return (Int(block.row), Int(block.column), Ubiquitty.RichText.layoutOf(terminal, block).pointee)
        }
        guard let found = read.flatMap({ $0 }) else { return nil }
        let (row, column, layout) = found
        guard let centre = surface.viewPoint(forRow: row, column: column),
            let right = surface.viewPoint(forRow: row, column: column + 1),
            let below = surface.viewPoint(forRow: row + 1, column: column)
        else { return nil }
        let cellWidth = right.x - centre.x
        let cellHeight = below.y - centre.y
        return PlacedBlock(
            surface: surface,
            row: row,
            column: column,
            origin: CGPoint(x: centre.x - cellWidth / 2, y: centre.y - cellHeight / 2),
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            layout: layout
        )
    }

    /// A point a fraction of the way across a character, on its line's
    /// middle, in window coordinates.
    ///
    /// - Parameters:
    ///   - index: The character's index in the block's text.
    ///   - fraction: How far across the character, from 0 to 1.
    /// - Returns: The point, or nil when no shown line holds the character.
    func windowPoint(atCharacter index: Int, fraction: Double) -> CGPoint? {
        for lineIndex in 0..<layout.visibleLineCount() {
            let line = layout.line(lineIndex)
            guard Int(line.first) <= index, index < Int(line.end) else { continue }
            let left = Double(layout.leftEdge(line, index))
            let right = Double(layout.rightEdge(index))
            let across = Double(line.origin) + left + (right - left) * fraction
            let down = Double(line.top) + Double(line.height) / 2
            let point = CGPoint(
                x: origin.x + CGFloat(across / Double(layout.cellWidth())) * cellWidth,
                y: origin.y + CGFloat(down / Double(layout.cellHeight())) * cellHeight
            )
            return surface.convert(point, to: nil)
        }
        return nil
    }
}

/// Opens a shell window and has its shell print a block, then waits for the
/// block to be placed and drawn.
///
/// - Parameters:
///   - t: The scenario's context.
///   - keys: The placement's keys.
///   - body: The block's RTF, which printf's %s passes through unescaped.
///   - after: A shell command run after the block is printed, or empty.
/// - Returns: The window, its surface and the block, or nil after a failed
///   expectation.
@MainActor
private func openWindowWithBlock(
    _ t: UBUITestContext,
    keys: String,
    body: String,
    after: String = ""
) -> (window: NSWindow, surface: TerminalSurface, block: PlacedBlock)? {
    guard let shell = TerminalWindowController.spawn(),
        let window = shell.window,
        let content = window.contentView,
        let surface = terminalSurface(under: content)
    else {
        t.expect(false, desc: "a Swift-shell window opens with a surface")
        return nil
    }
    t.pump(0.3)
    let tail = after.isEmpty ? "" : "; " + after
    surface.send("clear; printf '\\033]7404;\(keys);%s\\033\\\\' '\(body)'\(tail)\n")
    let placed = t.wait(
        until: { (surface.drive.withTerminal { Int($0.richTextBlocks.blocks(.Primary).size()) } ?? 0) == 1 },
        timeout: 6
    )
    t.expect(placed, desc: "the shell's printf placed one block")
    let drawn = t.wait(until: { surface.frameRenderers.values.reduce(0) { $0 + $1.richTextStore.rasterCount } > 0 }, timeout: 3)
    t.expect(drawn, desc: "the renderer drew the block's raster")
    if !after.isEmpty {
        t.pump(0.5)
    }
    guard placed, drawn, let block = PlacedBlock.first(on: surface) else {
        window.close()
        return nil
    }
    return (window, surface, block)
}

/// Drags from one window point to another with real mouse events.
@MainActor
private func drag(_ surface: TerminalSurface, in window: NSWindow, from start: CGPoint, to end: CGPoint, _ t: UBUITestContext) -> Bool {
    guard let down = mouseEvent(.leftMouseDown, in: window, at: start),
        let dragged = mouseEvent(.leftMouseDragged, in: window, at: end),
        let up = mouseEvent(.leftMouseUp, in: window, at: end)
    else { return false }
    surface.mouseDown(with: down)
    t.pump(0.05)
    surface.mouseDragged(with: dragged)
    t.pump(0.05)
    surface.mouseUp(with: up)
    t.pump(0.1)
    return true
}

/// Registers the rich text block scenarios with the UI-test runner.
enum RichTextScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_rich_text_paragraph_takes_its_indents_and_spacing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                // A 24-point left indent with the first line hanging twelve
                // points left of it, exact 24-point lines and twelve points
                // before the paragraph: lengths in points, whatever the cell.
                surface.send(
                    "clear; printf '\\033]7404;w=20:h=8:p=0,0,0,6;%s\\033\\\\' '{\\rtf1\\li480\\fi-240\\sb240\\sl-480 aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa}'\n"
                )
                var lines = 0
                for _ in 0..<60 {
                    t.pump(0.1)
                    if let terminal = surface.drive.borrowTerminal(), let block = terminal.richTextBlocks.blocks(.Primary).first {
                        lines = Ubiquitty.RichText.layoutOf(terminal, block).pointee.lineCount()
                        if lines > 1 { break }
                    }
                }
                guard let terminal = surface.drive.borrowTerminal(), let block = terminal.richTextBlocks.blocks(.Primary).first else {
                    t.expect(false, desc: "the shell's printf placed one block")
                    return
                }
                let layout = Ubiquitty.RichText.layoutOf(terminal, block).pointee
                t.expect(layout.isShaped(), desc: "CoreText shaped the block")
                t.expect(layout.lineCount() > 1, desc: "the paragraph wrapped (\(layout.lineCount()) lines)")
                guard layout.lineCount() > 1 else { return }
                let point: UInt32 = 4096
                let first = layout.line(0)
                let second = layout.line(1)
                t.expect(
                    first.origin == 18 * point,
                    desc: "the first line hangs at twelve points inside six of padding (\(Double(first.origin) / 4096))"
                )
                t.expect(
                    second.origin == 30 * point,
                    desc: "the next line starts at the left indent inside the padding (\(Double(second.origin) / 4096))"
                )
                t.expect(
                    first.height == 36 * point,
                    desc: "the first line box is 24 points and the 12 before it (\(Double(first.height) / 4096))"
                )
                t.expect(
                    second.top == first.height && second.height == 24 * point,
                    desc: "later lines are exactly 24 points (\(Double(second.height) / 4096))"
                )
                t.expect(first.baseline > 12 * point, desc: "the first baseline sits below the space before")
            }
        }
        UBUITestRegister("swift_shell_rich_text_block_renders_and_copies_as_text") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // The body goes through printf's %s, which processes no
                // escapes, so the RTF's backslashes arrive as written.
                surface.send("clear; printf '\\033]7404;w=30:h=3;%s\\033\\\\' '{\\rtf1\\b Rich\\b0\\par plain copy}'\n")
                var blocks = 0
                for _ in 0..<60 {
                    t.pump(0.1)
                    blocks = surface.drive.borrowTerminal().map { Int($0.richTextBlocks.blocks(.Primary).size()) } ?? 0
                    if blocks > 0 { break }
                }
                t.expect(blocks == 1, desc: "the shell's printf placed one block (got \(blocks))")
                t.pump(0.5)
                let rasters = surface.frameRenderers.values.reduce(0) { $0 + $1.richTextStore.rasterCount }
                t.expect(rasters > 0, desc: "the renderer drew the block's raster (\(rasters) drawn)")

                guard let terminal = surface.drive.borrowTerminal(), let block = terminal.richTextBlocks.blocks(.Primary).first else {
                    t.expect(false, desc: "the block can be read back")
                    return
                }
                let blockRow = Int(block.row)
                let blockColumn = Int(block.column)
                guard let topLeft = surface.viewPoint(forRow: blockRow, column: blockColumn),
                    let nextColumn = surface.viewPoint(forRow: blockRow, column: blockColumn + 1),
                    let farRight = surface.viewPoint(forRow: blockRow + 2, column: blockColumn + 28)
                else {
                    t.expect(false, desc: "the surface has measured cell geometry")
                    return
                }
                // The press a third of a cell left of the first cell's centre,
                // which is left of the block's first letter; the drag to the
                // block's last row, past the end of its text.
                let cellWidth = nextColumn.x - topLeft.x
                let pressPoint = surface.convert(CGPoint(x: topLeft.x - cellWidth / 3, y: topLeft.y - 1), to: nil)
                let dragPoint = surface.convert(farRight, to: nil)
                guard let down = mouseEvent(.leftMouseDown, in: window, at: pressPoint),
                    let dragged = mouseEvent(.leftMouseDragged, in: window, at: dragPoint),
                    let up = mouseEvent(.leftMouseUp, in: window, at: dragPoint)
                else {
                    t.expect(false, desc: "AppKit synthesises the press, drag and release")
                    return
                }
                surface.mouseDown(with: down)
                t.pump(0.05)
                surface.mouseDragged(with: dragged)
                t.pump(0.05)
                surface.mouseUp(with: up)
                t.pump(0.1)

                let copied = surface.selectedText ?? ""
                t.expect(
                    copied.hasPrefix("Rich\nplain copy"),
                    desc: "a drag over the block copies its characters as plain text, styles dropped (got \(copied.debugDescription))"
                )
            }
        }

        // "alpha beta gamma" holds `b` at 6 and the second `m` at 14: a press
        // on b's left quarter stands the caret before it, a release on m's
        // right quarter after it.
        UBUITestRegister("swift_shell_rich_text_drag_inside_a_block_copies_the_characters_between") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let opened = openWindowWithBlock(t, keys: "w=36:h=4", body: "{\\rtf1\\fs28 alpha beta gamma\\par delta}")
                else { return }
                let (window, surface, block) = opened
                defer { window.close() }
                guard let start = block.windowPoint(atCharacter: 6, fraction: 0.25),
                    let end = block.windowPoint(atCharacter: 14, fraction: 0.75),
                    drag(surface, in: window, from: start, to: end, t)
                else {
                    t.expect(false, desc: "the pointer can be aimed at the block's characters")
                    return
                }
                let copied = surface.selectedText ?? ""
                t.expect(
                    copied == "beta gamm",
                    desc: "a drag between two letters copies exactly the letters between (got \(copied.debugDescription))"
                )
            }
        }
        // The drag leaves the block through its bottom edge into the line the
        // shell printed below it: the copy is the block's text from the press,
        // then the grid in reading order up to the release.
        UBUITestRegister("swift_shell_rich_text_drag_across_a_block_edge_continues_into_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let opened = openWindowWithBlock(
                        t,
                        keys: "w=36:h=3",
                        body: "{\\rtf1\\fs28 alpha beta gamma\\par delta}",
                        after: "echo tail words"
                    )
                else { return }
                let (window, surface, block) = opened
                defer { window.close() }
                let tailRow = block.row + 3
                guard let start = block.windowPoint(atCharacter: 11, fraction: 0.25),
                    let tailCell = surface.viewPoint(forRow: tailRow, column: 4),
                    drag(surface, in: window, from: start, to: surface.convert(tailCell, to: nil), t)
                else {
                    t.expect(false, desc: "the pointer can be aimed at the block and the row below it")
                    return
                }
                let copied = surface.selectedText ?? ""
                t.expect(
                    copied.hasPrefix("gamma\ndelta") && copied.contains("tail") && !copied.contains("words") && !copied.contains("alpha"),
                    desc: "the copy is the block's text from the press, then the grid up to the release (got \(copied.debugDescription))"
                )
            }
        }
        UBUITestRegister("swift_shell_rich_text_double_click_selects_a_word_in_a_block") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let opened = openWindowWithBlock(t, keys: "w=36:h=4", body: "{\\rtf1\\fs28 alpha beta gamma\\par delta}")
                else { return }
                let (window, surface, block) = opened
                defer { window.close() }
                guard let point = block.windowPoint(atCharacter: 8, fraction: 0.5),
                    let firstDown = mouseEvent(.leftMouseDown, in: window, at: point, clickCount: 1),
                    let firstUp = mouseEvent(.leftMouseUp, in: window, at: point, clickCount: 1),
                    let secondDown = mouseEvent(.leftMouseDown, in: window, at: point, clickCount: 2),
                    let secondUp = mouseEvent(.leftMouseUp, in: window, at: point, clickCount: 2)
                else {
                    t.expect(false, desc: "AppKit synthesises a double click on the block")
                    return
                }
                surface.mouseDown(with: firstDown)
                surface.mouseUp(with: firstUp)
                surface.mouseDown(with: secondDown)
                surface.mouseUp(with: secondUp)
                t.pump(0.1)
                let copied = surface.selectedText ?? ""
                t.expect(
                    copied == "beta",
                    desc: "a double click on `t` takes the word around it, bounded by the block (got \(copied.debugDescription))"
                )
            }
        }
        // A narrower window rewraps the rows the block covers: its cells no
        // longer form its rectangle, so Core removes it, leaves the cells as
        // plain spaces, and widening back does not bring it back.
        UBUITestRegister("swift_shell_rich_text_block_whose_cells_reflow_apart_is_removed") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let opened = openWindowWithBlock(
                        t,
                        keys: "w=40:h=2",
                        body: "{\\rtf1 reflowed apart}",
                        after: "echo still here"
                    )
                else { return }
                let (window, surface, block) = opened
                defer { window.close() }
                guard let contentView = window.contentView else { return }
                let wide = contentView.frame.size
                let insets = wide.width - CGFloat(surface.publishedGrid.columns) * block.cellWidth
                window.setContentSize(NSSize(width: block.cellWidth * 24 + insets, height: wide.height))
                surface.needsDisplay = true
                let narrowed = t.wait(until: { surface.publishedGrid.columns <= 24 }, timeout: 3)
                t.expect(narrowed, desc: "the window narrowed the grid to 24 columns (\(surface.publishedGrid.columns))")
                let removed = t.wait(
                    until: { (surface.drive.withTerminal { Int($0.richTextBlocks.blocks(.Primary).size()) } ?? 1) == 0 },
                    timeout: 3
                )
                t.expect(removed, desc: "the block whose cells the rewrap separated is gone")
                window.setContentSize(wide)
                surface.needsDisplay = true
                t.pump(0.5)
                let blocks = surface.drive.withTerminal { Int($0.richTextBlocks.blocks(.Primary).size()) } ?? -1
                t.expect(blocks == 0, desc: "and widening back does not bring it back (\(blocks) blocks)")
                t.expect(surface.gridTextForTesting().contains("still here"), desc: "the grid's own text survived the rewrap")
            }
        }
        UBUITestRegister("swift_remote_rich_text_block_renders_with_the_clients_metrics") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyRemoteBlock(t) }
        }
    }
}

/// A block a program on a host prints into a remote pane: the host lays it
/// out and answers its queries by the table this client publishes, and the
/// client draws it from the same table.
///
/// The host is a daemon forked with a home of its own; it has no renderer,
/// so an exact reply (`x=1`) can only come from a table a client sent it.
@MainActor
private func verifyRemoteBlock(_ t: UBUITestContext) {
    guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
        FileManager.default.isExecutableFile(atPath: hostBinary)
    else {
        t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
        return
    }
    // Under /tmp: the daemon's socket lives in this home, and a Unix socket
    // path is capped at 103 bytes.
    let root = "/tmp/ubq-rich-text-" + String(UUID().uuidString.prefix(8))
    let home = root + "/.ubiquitty"
    do {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The query and the reply's read, as a script so the shell the host
        // runs is told nothing it has to parse. The reply arrives as input;
        // its leading ESC ] and trailing ESC are cut so the line it prints
        // starts no control string.
        let script = """
            printf '\\033]7404;a=q:i=5:w=0:h=0;%s\\033\\\\' '{\\rtf1\\fs24 measured on the client}'
            IFS= read -r -s -t 5 -d '\\' reply
            reply=${reply#*a=r:}
            printf 'reply:[%s]\\n' "${reply%?}"
            """
        try script.write(toFile: root + "/query.sh", atomically: true, encoding: .utf8)
    } catch {
        t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
        return
    }
    defer {
        t.closeAllWindows()
        try? FileManager.default.removeItem(atPath: root)
    }
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: hostBinary)
    daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
    daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
    do {
        try daemon.run()
    } catch {
        t.expect(false, desc: "the daemon started (\(error))")
        return
    }
    defer {
        if daemon.isRunning { daemon.terminate() }
        daemon.waitUntilExit()
    }
    guard
        t.wait(
            until: {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
            },
            timeout: 20
        )
    else {
        t.expect(false, desc: "the daemon opened its socket")
        return
    }
    let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    guard
        let controller = TerminalWindowController.spawnRemoteWindow(
            shellCommand: "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach",
            hostLabel: "rich text host",
            quicHost: "",
            quicBootstrapCommand: "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: 0
        ), let surface = controller.remoteSurface
    else {
        t.expect(false, desc: "a window attached to the forked daemon")
        return
    }
    guard t.wait(until: { surface.drive.remoteState == Ubiquitty.Session.State.Connected }, timeout: 20) else {
        t.expect(false, desc: "the window reached the daemon (\(surface.remoteFailureDetail))")
        return
    }
    surface.needsDisplay = true
    t.pump(0.5)
    surface.send("clear; printf '\\033]7404;w=30:h=3;%s\\033\\\\' '{\\rtf1\\fs32\\b Remote\\b0\\par\\fs24 drawn in the client faces}'\r")
    let placed = t.wait(
        until: { (surface.drive.withTerminal { Int($0.richTextBlocks.blocks(.Primary).size()) } ?? 0) == 1 },
        timeout: 10
    )
    t.expect(placed, desc: "the host's block reached the client's mirror")
    let drawn = t.wait(until: { surface.frameRenderers.values.reduce(0) { $0 + $1.richTextStore.rasterCount } > 0 }, timeout: 5)
    t.expect(drawn, desc: "the client drew the block's raster")
    // The client publishes its table when its first frame is cut, and it
    // reaches the host over the connection after that: the query is asked
    // until an answer is exact, which only a published table makes it.
    // The exactness key is followed by the reply's later keys or by the
    // bracket the query script closes it with.
    func isExact(_ reply: String) -> Bool { reply.contains(":x=1:") || reply.contains(":x=1]") }
    var reply = "no reply"
    for attempt in 0..<10 {
        surface.send("bash \(root)/query.sh\r")
        _ = t.wait(until: { surface.gridTextForTesting().contains("reply:[") }, timeout: 5)
        reply = surface.gridTextForTesting().split(separator: "\n").last { $0.contains("reply:[") }.map(String.init) ?? "no reply"
        if isExact(reply) || attempt == 9 { break }
        t.pump(0.5)
    }
    t.expect(isExact(reply), desc: "the host measured the body exactly, by the table this client published (\(reply))")
    let summary = surface.drive.withTerminal { Ubiquitty.RichText.typographySummary($0) }
    let cell = surface.drawnCellSizeForTesting ?? .zero
    t.expect(
        summary.map { $0.faceCount == 12 && abs(Double($0.cellWidth) / 64 - Double(cell.width)) < 0.5 } ?? false,
        desc: "the mirror lays the block out by the client's own table, measured at its cell (\(cell.width) pt)"
    )
}
