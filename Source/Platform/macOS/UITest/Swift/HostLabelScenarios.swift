// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// HostLabelScenarios.swift — every kind of remote window names its machine,
// and a `match_host` rule tags it.
//
// The chip, the tab's host mark and the window's tags all read Core's one
// `PaneHost`, so the claims are made together, per kind of remote pane: a
// ubiquitty-host session on this machine's socket, one launched over ssh, a
// plain shell whose far side reports a host, and a tmux control-mode client
// reached over ssh. QUIC differs from the ssh-launched host only in its
// carrier, which needs a QUIC daemon to reach and is pinned in Core.
//
// A rule that tags a host fills that host's chip: the chip becomes the tag's
// capsule, with the tag's icon in the globe's place, and the tag is not drawn
// a second time as a marker; the window's tab wears the same icon.
//
// The tag strength setting dims every tag's colour at once, in every open
// window: the chip's capsule, the markers beside it and the tab's mark. One
// scenario drives the Settings slider's own write and reads all three back,
// and one draws the capsule at two strengths, in three colours, over an
// opaque and a translucent window. Another draws the title row's tag stack,
// the markers tucked under one another and under the chip, the same ways.
//
// Each scenario writes a picture of what it asserted to /tmp/host-labels,
// named for the phase in UBQ_HOST_LABELS_PHASE, without ordering a window in
// front of the reader's.

/// Registers the host-label scenarios with the UI-test runner.
enum HostLabelScenarios {
    /// The machine names the rules are written against. Synthetic: nothing
    /// resolves them, and nothing has to.
    private static let labRule = "[[tags]]\nname = \"lab\"\ncolor = \"purple\"\nmatch_host = \"lab-mac*\"\n"

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("host_labels_tag_every_kind_of_remote_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyEveryKind(t) }
        }
        UBUITestRegister("host_labels_share_the_title_row_without_covering_it") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyPlacement(t) }
        }
        UBUITestRegister("host_labels_tabs_carry_the_host_and_its_tag_colour") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyTabs(t) }
        }
        UBUITestRegister("host_labels_sync_tabs_leave_the_host_tag_to_the_chip") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifySyncTabs(t) }
        }
        UBUITestRegister("host_labels_mixed_panes_name_each_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyMixedPanes(t) }
        }
        UBUITestRegister("host_labels_a_rule_fills_the_chip_with_its_tag") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyRuleCapsule(t) }
        }
        UBUITestRegister("host_labels_tag_strength_slider_redraws_every_mark_live") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyStrengthSlider(t) }
        }
        UBUITestRegister("host_labels_tag_strength_pictures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { drawStrengthPictures(t) }
        }
        UBUITestRegister("host_labels_tag_stack_pictures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { drawStackPictures(t) }
        }
    }

    // MARK: - Reading the chrome

    /// What the host chip reads, empty when it is not on screen.
    @MainActor
    private static func chipReading(_ controller: TerminalWindowController) -> String {
        guard let chip = controller.remoteConnectionIndicator, chip.window != nil, !chip.isHiddenOrHasHiddenAncestor,
            chip.frame.width > 0
        else { return "" }
        return chip.readingForTesting
    }

    /// Whether the chip names the host, and says the carrier it is reached
    /// over: the title row shows the host's name alone, and the chip's
    /// description, its tooltip and spoken label, names the carrier.
    @MainActor
    private static func chipNames(_ controller: TerminalWindowController, host: String, carrier: String) -> Bool {
        guard chipReading(controller) == host, let chip = controller.remoteConnectionIndicator else { return false }
        return chip.accessibilityLabel()?.hasPrefix("Session on \(host) over \(carrier).") == true
    }

    /// The names of the tags the window's title row wears.
    @MainActor
    private static func titleTags(_ controller: TerminalWindowController) -> String {
        guard let window = controller.window, let strip = titlebarStrip(of: window),
            let label = titleField(in: strip)?.accessibilityLabel(), label.hasPrefix("Tagged ")
        else { return "" }
        // "Tagged lab, prod. <the title>": the names run to the first full stop.
        let names = label.dropFirst("Tagged ".count)
        return String(names.components(separatedBy: ". ").first ?? "")
    }

    /// A line naming everything a failure needs.
    @MainActor
    private static func describe(_ controller: TerminalWindowController) -> String {
        "chip '\(chipReading(controller))' ('\(controller.remoteConnectionIndicator?.accessibilityLabel() ?? "")'), "
            + "tags '\(titleTags(controller))', tab '\(controller.window?.tab.title ?? "")', "
            + "subtitle '\(controller.window?.subtitle ?? "")'"
    }

    /// The colour a tab's title-leading tag mark paints at its centre, read
    /// off the image the strip's title field holds; nil when the tab's title
    /// leads with none.
    ///
    /// - Parameter window: The tab's window.
    /// - Returns: The painted colour.
    @MainActor
    private static func drawnTabTagDotColor(_ window: NSWindow) -> NSColor? {
        guard let index = window.tabGroup?.windows.firstIndex(where: { $0 === window }) else { return nil }
        let marks = drawnTabTagMarks(inGroupOf: window)
        guard index < marks.count, let mark = marks[index], let image = mark.image else { return nil }
        return paintedColor(of: image, atX: mark.markSide / 2, y: mark.markSide / 2)
    }

    /// The colour an image paints at one of its points, drawn at twice its
    /// size over a clear backing.
    ///
    /// - Parameters:
    ///   - image: The image.
    ///   - x: The point's x, in the image's own unflipped coordinates.
    ///   - y: The point's y.
    /// - Returns: The colour, nil when the image cannot be drawn.
    @MainActor
    private static func paintedColor(of image: NSImage, atX x: CGFloat, y: CGFloat) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / max(image.size.width, 1)
        let column = Int(x * scale)
        let row = rep.pixelsHigh - 1 - Int(y * scale)
        guard column >= 0, column < rep.pixelsWide, row >= 0, row < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: column, y: row)
    }

    /// Whether two colours carry the same components, to within a rounding.
    ///
    /// Compared as stored rather than converted: a disc read back from its
    /// bitmap comes out tagged with a calibrated space but holding the bytes
    /// it was drawn with, and a conversion would move them.
    private static func isSameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingType(.componentBased), let b = b?.usingType(.componentBased),
            a.numberOfComponents >= 3, b.numberOfComponents >= 3
        else { return false }
        return abs(a.redComponent - b.redComponent) < 0.04 && abs(a.greenComponent - b.greenComponent) < 0.04
            && abs(a.blueComponent - b.blueComponent) < 0.04
    }

    /// The purple a `color = "purple"` rule resolves to, by Core's palette.
    private static var purple: NSColor { paletteColor("purple") }

    /// The colour a `color = "<name>"` rule resolves to, by Core's palette.
    ///
    /// - Parameter name: The palette's name for it.
    /// - Returns: The colour, opaque.
    private static func paletteColor(_ name: String) -> NSColor {
        var color = Ubiquitty.Preferences.ColorEntry()
        _ = name.withCString { Ubiquitty.Session.tagColorFromName(std.string_view($0), &color) }
        return NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    /// Writes a picture of a window as the window server composites it,
    /// without bringing it forward.
    ///
    /// - Parameters:
    ///   - window: The window.
    ///   - name: What the picture shows, which names its file.
    @MainActor
    private static func capture(_ window: NSWindow, _ name: String) {
        let phase = ProcessInfo.processInfo.environment["UBQ_HOST_LABELS_PHASE"] ?? "run"
        let directory = "/tmp/host-labels"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(name)-\(phase).png"
        try? FileManager.default.removeItem(atPath: path)
        window.displayIfNeeded()
        // The window server's picture needs the screen-capture grant; a
        // process without it asks nothing of the window server.
        if CGPreflightScreenCaptureAccess() {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { return }
        }
        // No window-server picture to be had: the frame view drawn by AppKit,
        // which carries the title row's controls if not its material, each
        // text field drawn once, as the window shows it.
        guard let frame = window.contentView?.superview, let rep = drawnBitmap(of: frame) else {
            return
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Opens a host window over a silent transport: the marks a host session
    /// wears are its from the first moment, steady or not.
    @MainActor
    private static func openHost(label: String, key: String) -> TerminalWindowController? {
        let controller = TerminalWindowController.spawnRemoteWindow(
            shellCommand: "/bin/sleep 60",
            hostLabel: label,
            quicHost: "",
            quicBootstrapCommand: "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: 0,
            workspaceName: "",
            hostKey: key
        )
        controller?.refreshTitles()
        return controller
    }

    /// Opens a plain local shell whose far side has reported a host, the way a
    /// shell on the far side of `ssh` does with OSC 7.
    @MainActor
    private static func openReportingShell(_ host: String, _ t: UBUITestContext) -> TerminalWindowController? {
        guard let controller = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
        else { return nil }
        t.pump(0.3)
        controller.shellSendProbe("printf '\\033]7;file://\(host)/tmp\\007'\r")
        return controller
    }

    // MARK: - Every kind

    @MainActor
    private static func verifyEveryKind(_ t: UBUITestContext) {
        // The name this machine goes by, as the platform reports it to Core.
        var nameBytes = [CChar](repeating: 0, count: 256)
        gethostname(&nameBytes, nameBytes.count)
        let machine = String(decoding: nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let saved = configureAppendingToLiveDocument(
            labRule + "\n[[tags]]\nname = \"this-machine\"\ncolor = \"green\"\nmatch_host = \"\(machine)\"\n"
        )
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }

        // A ubiquitty-host session on this machine's own socket.
        if let thisMac = openHost(label: "Ubiquitty Host", key: "local") {
            t.pump(0.5)
            t.expect(
                t.wait(until: { titleTags(thisMac) == "this-machine" }, timeout: 8),
                desc: "a session on this machine's daemon is tagged by this machine's name (\(describe(thisMac)))"
            )
            t.expect(chipReading(thisMac).hasSuffix("This Mac"), desc: "and its chip says This Mac (\(describe(thisMac)))")
            capture(thisMac.window!, "kind-this-mac")
        } else {
            t.expect(false, desc: "a window on this machine's daemon opened")
        }

        // A ubiquitty-host launched over ssh, saved under a label of its own.
        if let studio = openHost(label: "Studio", key: "ada@lab-mac-studio") {
            t.pump(0.5)
            t.expect(
                t.wait(until: { titleTags(studio) == "lab" }, timeout: 8),
                desc: "an ssh-launched host is tagged by its machine (\(describe(studio)))"
            )
            t.expect(chipReading(studio).hasSuffix("Studio"), desc: "and its chip names the label it was saved under (\(describe(studio)))")
            t.expect(
                studio.window?.tab.title.hasSuffix("Studio") == true
                    && studio.window?.tab.title.contains("Studio — Studio") == false,
                desc: "and its tab names the host once (\(describe(studio)))"
            )
            capture(studio.window!, "kind-ssh-host")
        } else {
            t.expect(false, desc: "a window on an ssh-launched host opened")
        }

        // A plain shell on another machine, which no link of ours reaches.
        if let pro = openReportingShell("lab-mac-pro", t) {
            t.expect(
                t.wait(until: { titleTags(pro) == "lab" }, timeout: 8),
                desc: "a plain ssh session is tagged by the machine its far side reported (\(describe(pro)))"
            )
            t.expect(
                t.wait(until: { chipNames(pro, host: "lab-mac-pro", carrier: "SSH") }, timeout: 8),
                desc: "and its title row wears the host chip, naming the machine and the tool (\(describe(pro)))"
            )
            t.expect(
                t.wait(
                    until: { pro.window?.tab.title.isEmpty == false && pro.window?.tab.title.contains("lab-mac-pro — ") == false },
                    timeout: 8
                ),
                desc: "and its one tab leaves the host to the chip (\(describe(pro)))"
            )
            capture(pro.window!, "kind-plain-ssh")
        } else {
            t.expect(false, desc: "a plain shell opened")
        }

        verifyTmuxControlMode(t)
    }

    /// tmux control mode reached over ssh: the hosted windows run no process
    /// of their own, and the transport stamp names the host for them.
    @MainActor
    private static func verifyTmuxControlMode(_ t: UBUITestContext) {
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tmux else {
            t.expect(false, desc: "tmux is installed for the control-mode case")
            return
        }
        let socket = "ubiquitty-uitest-host-labels"
        t.killTmuxServer(onSocket: socket)
        defer { t.killTmuxServer(onSocket: socket) }
        guard
            let primary = TerminalWindowController.spawn(
                arguments: ["/bin/sh", "-c", "exec \"$1\" -L \"$2\" -f /dev/null -CC new-session -s lab", "host-labels", tmux, socket],
                localePolicy: .auto,
                sessionLifetime: .endsWithChild,
                tmuxControlHost: "ada@lab-mac-air"
            )
        else {
            t.expect(false, desc: "the control client opened")
            return
        }
        var hosted: TerminalWindowController?
        t.expect(
            t.wait(
                until: {
                    hosted = primary.liveHostedWindows.first
                    return hosted?.boundTmuxPaneIDs().isEmpty == false
                },
                timeout: 20
            ),
            desc: "the control client's tmux window opens as a hosted window"
        )
        guard let hosted else { return }
        hosted.refreshTitles()
        t.expect(
            t.wait(until: { titleTags(hosted) == "lab" }, timeout: 8),
            desc: "a tmux control-mode window is tagged by the host its client reached (\(describe(hosted)))"
        )
        t.expect(
            t.wait(until: { chipNames(hosted, host: "lab-mac-air", carrier: "SSH") }, timeout: 8),
            desc: "and wears that host's chip (\(describe(hosted)))"
        )
        t.expect(
            t.wait(
                until: { hosted.window?.tab.title.isEmpty == false && hosted.window?.tab.title.contains("lab-mac-air — ") == false },
                timeout: 8
            ),
            desc: "and its one tab leaves the host to the chip (\(describe(hosted)))"
        )
        if let window = hosted.window { capture(window, "kind-tmux-control-mode") }
    }

    // MARK: - Placement

    @MainActor
    private static func verifyPlacement(_ t: UBUITestContext) {
        let saved = configureAppendingToLiveDocument(labRule)
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard let studio = openHost(label: "lab-mac-studio.example.internal", key: "ada@lab-mac-studio"),
            let window = studio.window
        else {
            t.expect(false, desc: "a host window opened")
            return
        }
        studio.setCustomTitles(window: "a window title long enough to reach the chips on either side of it")
        studio.refreshTitles()
        for width in [900.0, 560.0, 380.0] {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            t.pump(0.5)
            guard let chip = studio.remoteConnectionIndicator, let strip = titlebarStrip(of: window),
                let field = titleField(in: strip)
            else {
                t.expect(false, desc: "the title row has a chip and a title at \(Int(width))pt")
                continue
            }
            let chipFrame = chip.convert(chip.bounds, to: nil)
            let fieldFrame = field.convert(field.bounds, to: nil)
            let zoom = window.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
            let isChipShown = !chip.isHiddenOrHasHiddenAncestor && chipFrame.width > 0
            t.expect(isChipShown, desc: "at \(Int(width))pt the host chip stands (\(describe(studio)))")
            t.expect(titleTags(studio) == "lab", desc: "and the tag chip with it (\(describe(studio)))")
            t.expect(
                chipFrame.minX >= zoom.maxX,
                desc: "at \(Int(width))pt the host chip clears the window buttons (chip \(chipFrame), zoom \(zoom))"
            )
            // The chip leads the title inside the title field, in a span the
            // field reserves for it; the title's words begin past it.
            let words = studio.titleWordsFrameForTesting
            t.expect(
                !isChipShown || (chip.superview === field && field.bounds.contains(chip.frame)),
                desc: "at \(Int(width))pt the title reserves the host chip's span (chip \(chip.frame), title \(field.bounds))"
            )
            t.expect(
                !isChipShown || words.map { chip.frame.maxX <= $0.minX + 0.5 } == true,
                desc:
                    "at \(Int(width))pt the host chip clears the title's words (chip \(chip.frame), words \(words.map { "\($0)" } ?? "none"))"
            )
            t.expect(
                fieldFrame.minX >= zoom.maxX,
                desc: "at \(Int(width))pt the title and its tag clear the window buttons (title \(fieldFrame), zoom \(zoom))"
            )
            capture(window, "placement-\(Int(width))")
        }
    }

    // MARK: - Tabs

    /// Three tabs attached to one host over Sync: the chip carries the host's
    /// tag and no tab draws it again, while each tab's tooltip still names it.
    /// A tab on another host joining the group gives the tags back to every
    /// tab, since they are then how the tabs are told apart.
    @MainActor
    private static func verifySyncTabs(_ t: UBUITestContext) {
        let saved = configureAppendingToLiveDocument(
            "[[tags]]\nname = \"lab\"\ncolor = \"purple\"\nicon = \"flask\"\nmatch_host = \"lab-mac*\"\n\n"
                + "[appearance]\ntag_color_opacity = 1.0\n"
        )
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard PhosphorIcons.icon(named: "flask") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let controllers = (0..<3).compactMap { _ in openHost(label: "Studio", key: "ada@lab-mac-studio") }
        let windows = controllers.compactMap(\.window)
        guard controllers.count == 3, windows.count == 3, let front = windows.first else {
            t.expect(false, desc: "three windows attached to one host opened")
            return
        }
        for window in windows.dropFirst() {
            front.addTabbedWindow(window, ordered: .above)
        }
        front.tabGroup?.selectedWindow = front
        t.pump(0.5)
        for controller in controllers {
            controller.refreshTitles()
        }
        let marks = { windows.map { tabTagMark(of: $0)?.iconNames ?? [] } }
        t.expect(
            t.wait(until: { controllers[0].remoteConnectionIndicator?.tagTitleForTesting == "lab" }, timeout: 8),
            desc: "the chip wears the host's tag (\(describe(controllers[0])))"
        )
        t.expect(
            t.wait(
                until: { windows.allSatisfy { tabTagMark(of: $0).map { $0.iconNames.isEmpty && $0.bounds.width == 0 } == true } },
                timeout: 4
            ),
            desc: "no tab on the connection's host draws its tag again (\(marks()))"
        )
        t.expect(
            windows.allSatisfy { tabTagMark(of: $0)?.image?.accessibilityDescription == "Tagged lab" },
            desc:
                "each tab's title still names it for a screen reader (\(windows.map { tabTagMark(of: $0)?.image?.accessibilityDescription ?? "nil" }))"
        )
        t.expect(
            windows.allSatisfy { ($0.tab.toolTip ?? "").contains("Tagged lab") },
            desc: "and its tooltip names it (\(windows.map { $0.tab.toolTip ?? "" }))"
        )

        // A tab on another host joins the group.
        guard let build = openHost(label: "build", key: "build-01"), let buildWindow = build.window else {
            t.expect(false, desc: "a window on another host opened")
            return
        }
        front.addTabbedWindow(buildWindow, ordered: .above)
        front.tabGroup?.selectedWindow = front
        t.pump(0.5)
        for controller in controllers + [build] {
            controller.refreshTitles()
        }
        t.expect(
            t.wait(until: { windows.allSatisfy { tabTagMark(of: $0)?.iconName == "flask" } }, timeout: 6),
            desc: "among tabs on another host, each tab on the first draws its tag again (\(marks()))"
        )
    }

    @MainActor
    private static func verifyTabs(_ t: UBUITestContext) {
        // At full strength, so the colour the strip paints is the tag's own;
        // the strength is the slider scenario's to vary.
        let saved = configureAppendingToLiveDocument(labRule + "\n[appearance]\ntag_color_opacity = 1.0\n")
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard let studio = openHost(label: "Studio", key: "ada@lab-mac-studio"),
            let build = openHost(label: "build", key: "build-01"),
            let thisMac = openHost(label: "Ubiquitty Host", key: "local"),
            let studioWindow = studio.window, let buildWindow = build.window, let thisMacWindow = thisMac.window
        else {
            t.expect(false, desc: "three host windows opened")
            return
        }
        studioWindow.addTabbedWindow(buildWindow, ordered: .above)
        studioWindow.addTabbedWindow(thisMacWindow, ordered: .above)
        t.pump(0.5)
        for controller in [studio, build, thisMac] {
            controller.refreshTitles()
        }
        t.pump(0.3)
        // A silent host sets no title: each label is its host's name, said
        // once rather than marked with itself.
        t.expect(
            studioWindow.tab.title.hasSuffix("Studio") && !studioWindow.tab.title.contains("Studio — Studio"),
            desc: "the tagged host's tab names it once ('\(studioWindow.tab.title ?? "")')"
        )
        t.expect(buildWindow.tab.title == "build", desc: "the untagged host's tab names it once ('\(buildWindow.tab.title ?? "")')")
        t.expect(thisMacWindow.tab.title.contains("This Mac — "), desc: "this machine's tab names it ('\(thisMacWindow.tab.title ?? "")')")
        t.expect(
            tabTagMark(of: studioWindow).map { $0.iconName.isEmpty && $0.opacity == 1 } == true,
            desc: "the tagged host's tab title leads with its tag's dot, at full strength"
        )
        t.expect(
            tabTagMark(of: buildWindow) == nil,
            desc: "an untagged host's tab title leads with no mark ('\(buildWindow.tab.title ?? "")')"
        )
        // What the strip draws, not only what the tab was handed.
        t.pump(0.5)
        t.expect(
            isSameColor(drawnTabTagDotColor(studioWindow), purple),
            desc: "and the strip draws the dot in its tag's colour (\(String(describing: drawnTabTagDotColor(studioWindow))))"
        )
        capture(studioWindow, "tabs")
    }

    // MARK: - The chip as the rule's capsule

    @MainActor
    private static func verifyRuleCapsule(_ t: UBUITestContext) {
        let saved = configureAppendingToLiveDocument(
            "[[tags]]\nname = \"lab\"\ncolor = \"purple\"\nicon = \"flask\"\nmatch_host = \"lab-mac*\"\n\n"
                + "[[tags]]\nname = \"prod\"\ncolor = \"red\"\nprominence = \"loud\"\nmatch_host = \"lab-mac-studio\"\n\n"
                + "[[tags]]\nname = \"ci\"\ncolor = \"green\"\nprominence = \"loud\"\nicon = \"gear\"\nmatch_host = \"build-*\"\n"
        )
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard PhosphorIcons.icon(named: "flask") != nil, PhosphorIcons.icon(named: "gear") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        guard let studio = openHost(label: "Studio", key: "ada@lab-mac-studio"),
            let build = openHost(label: "build", key: "build-01"),
            let studioWindow = studio.window, let buildWindow = build.window
        else {
            t.expect(false, desc: "two host windows opened")
            return
        }
        studioWindow.addTabbedWindow(buildWindow, ordered: .above)
        t.pump(0.5)
        for controller in [studio, build] {
            controller.refreshTitles()
        }

        // The first rule fills the chip; the second, loud, is a marker and the wash.
        t.expect(
            t.wait(until: { studio.remoteConnectionIndicator?.capsuleFillForTesting != nil }, timeout: 8),
            desc: "a host a rule colours wears the rule's capsule (\(describe(studio)))"
        )
        if let chip = studio.remoteConnectionIndicator, let strip = titlebarStrip(of: studioWindow) {
            let field = titleField(in: strip)
            t.expect(isSameColor(chip.capsuleFillForTesting, purple), desc: "filled with the rule's colour")
            let strength = CGFloat(Ubiquitty.Preferences.Effective.tagColorOpacity(Ubiquitty.Preferences.values().pointee))
            t.expect(
                chip.capsuleFillOpacityForTesting.map { abs($0 - strength) < 0.001 } == true,
                desc: "laid down at the configured strength (\(String(describing: chip.capsuleFillOpacityForTesting)) vs \(strength))"
            )
            t.expect(abs(chip.frame.height - TitlebarCapsuleGeometry.standardHeight) <= 0.01, desc: "as tall as every tag capsule")
            t.expect(
                chip.tagIconNameForTesting == "flask" && chip.symbolNameForTesting.isEmpty,
                desc: "with the rule's icon in the globe's place (\(chip.tagIconNameForTesting))"
            )
            t.expect(
                chip.readingForTesting == "Studio" && chip.tagTitleForTesting == "lab",
                desc: "holding the machine's name and the rule's title (\(describe(studio)))"
            )
            t.expect(
                chip.accessibilityLabel()?.hasPrefix("Session on Studio over SSH. Tagged lab.") == true,
                desc: "and saying both (\(chip.accessibilityLabel() ?? "nil"))"
            )
            let markers = titleMarks(field)
            t.expect(markers.count, equals: 1, desc: "the chip's tag is not drawn again as a marker; the second rule is")
            t.expect(titleTags(studio) == "lab, prod", desc: "the title still names every tag (\(describe(studio)))")
            t.expect(
                !chip.hasCapsuleBorderForTesting,
                desc: "a capsule on another tag's wash is told apart by its own colour, without an outline"
            )
        } else {
            t.expect(false, desc: "the tagged host's title row has a chip and a title")
        }
        capture(studioWindow, "rule-capsule")

        // A loud rule that fills the chip washes the row in the chip's own colour.
        t.expect(
            t.wait(until: { build.remoteConnectionIndicator?.hasCapsuleBorderForTesting == true }, timeout: 8),
            desc: "a capsule on a wash of its own colour is outlined (\(describe(build)))"
        )
        if let chip = build.remoteConnectionIndicator, let strip = titlebarStrip(of: buildWindow) {
            t.expect(chip.tagIconNameForTesting == "gear", desc: "and wears its rule's icon")
            t.expect(
                titleMarks(titleField(in: strip)).isEmpty,
                desc: "a window whose one tag the chip wears draws no marker"
            )
            // The row wears the colour mixed into its ground, and the chip the
            // colour itself.
            t.expect(
                isSameColor(build.loudTagColorsForTesting.color, chip.capsuleFillForTesting)
                    && isSameColor(titlebarWash(of: buildWindow), build.loudTagColorsForTesting.wash),
                desc: "under a wash of the same colour (\(String(describing: titlebarWash(of: buildWindow))))"
            )
        }

        // The tab's title leads with the window's first tag's icon in place of
        // its dot.
        t.pump(0.5)
        for (window, icon) in [(studioWindow, "flask"), (buildWindow, "gear")] {
            let mark = tabTagMark(of: window)
            t.expect(
                mark?.iconName == icon,
                desc: "the tab's title leads with the \(icon) icon in its tag's colour (\(mark?.iconName ?? "no mark"))"
            )
        }
        capture(studioWindow, "rule-capsule-tabs")
    }

    // MARK: - Tag strength

    /// The rules the strength scenarios draw: a titled rule the chip wears as
    /// its capsule, a second titled rule drawn as a marker, and an untitled
    /// one drawn as a dot, all three in one colour.
    ///
    /// - Parameters:
    ///   - color: The palette name the three share.
    ///   - icon: The chip's icon, empty for the place's symbol.
    /// - Returns: The rules, as TOML.
    private static func strengthRules(color: String, icon: String) -> String {
        let chipIcon = icon.isEmpty ? "" : "icon = \"\(icon)\"\n"
        return "[[tags]]\nname = \"lab\"\ncolor = \"\(color)\"\n\(chipIcon)match_host = \"lab-mac*\"\n\n"
            + "[[tags]]\nname = \"prod\"\ncolor = \"\(color)\"\nmatch_host = \"lab-mac-pro\"\n\n"
            + "[[tags]]\ncolor = \"\(color)\"\nmatch_host = \"lab-mac-pro\"\n"
    }

    /// Opens two shells whose far side reports `lab-mac-pro`, in one tab
    /// group, and waits for the chip to wear its capsule and both tabs to
    /// carry their mark.
    ///
    /// - Parameter t: The running context.
    /// - Returns: The selected window's controller and the two windows.
    @MainActor
    private static func openTaggedPair(_ t: UBUITestContext) -> (TerminalWindowController, NSWindow, NSWindow)? {
        guard let first = openReportingShell("lab-mac-pro", t), let second = openReportingShell("lab-mac-pro", t),
            let firstWindow = first.window, let secondWindow = second.window
        else {
            t.expect(false, desc: "two shells opened")
            return nil
        }
        firstWindow.addTabbedWindow(secondWindow, ordered: .above)
        firstWindow.tabGroup?.selectedWindow = firstWindow
        t.pump(0.5)
        t.expect(
            t.wait(
                until: {
                    first.remoteConnectionIndicator?.capsuleFillForTesting != nil
                        && tabTagMark(of: firstWindow) != nil && tabTagMark(of: secondWindow) != nil
                },
                timeout: 8
            ),
            desc: "the host's rule fills the chip and leads both tabs' titles (\(describe(first)))"
        )
        return (first, firstWindow, secondWindow)
    }

    /// The Settings slider's own write dims every mark in every open window
    /// at once: the chip's fill, the marker capsule, the untitled dot and the
    /// tabs' marks, as drawn, not only as told.
    @MainActor
    private static func verifyStrengthSlider(_ t: UBUITestContext) {
        let saved = configureAppendingToLiveDocument(strengthRules(color: "purple", icon: ""))
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard let row = SettingsCatalog.tagStrengthCard().rows.first(where: { $0.id == "appearance.tag_color_opacity" }),
            case .slider(let minimum, let maximum, _, let get, let set) = row.control
        else {
            t.expect(false, desc: "Settings > Tags leads with the Tag Color Strength slider")
            return
        }
        t.expect(row.label == "Tag Color Strength", desc: "the slider is labelled Tag Color Strength")
        t.expect(
            abs(minimum - 0.1) < 0.001 && abs(maximum - 1) < 0.001,
            desc: "it runs from 10% to 100% (\(minimum)...\(maximum))"
        )
        guard let (controller, window, otherWindow) = openTaggedPair(t), let chip = controller.remoteConnectionIndicator,
            let strip = titlebarStrip(of: window)
        else { return }

        for strength in [0.3, 1.0, 0.5] {
            set(strength)
            t.expect(abs(get() - strength) < 0.001, desc: "the slider reads back \(Int(strength * 100))%")
            let isApplied = t.wait(
                until: {
                    chip.capsuleFillOpacityForTesting.map { abs($0 - CGFloat(strength)) < 0.001 } == true
                        && [window, otherWindow]
                            .allSatisfy { tabTagMark(of: $0).map { abs($0.opacity - CGFloat(strength)) < 0.001 } == true }
                },
                timeout: 4
            )
            t.expect(isApplied, desc: "at \(Int(strength * 100))% the chip and both tabs take the strength (\(describe(controller)))")
            t.pump(0.3)
            let label = "at \(Int(strength * 100))%"
            let chipAlpha = drawnAlpha(of: chip, at: NSPoint(x: chip.bounds.maxX - 3, y: chip.bounds.midY)) ?? 0
            t.expect(abs(chipAlpha - CGFloat(strength)) <= 0.06, desc: "\(label) the chip paints its fill at that alpha (\(chipAlpha))")
            let markers = titleMarks(titleField(in: strip))
            t.expect(
                markers.count == 2 && markers.allSatisfy { abs($0.fillOpacity - CGFloat(strength)) < 0.001 },
                desc: "\(label) the marker and the dot take it (\(markers.map(\.fillOpacity)))"
            )
            if let capsule = markers.first?.image {
                let markerAlpha = drawnAlpha(of: capsule, at: NSPoint(x: 3, y: capsule.size.height / 2)) ?? 0
                t.expect(abs(markerAlpha - CGFloat(strength)) <= 0.06, desc: "\(label) the marker paints at that alpha (\(markerAlpha))")
            }
            if let dot = markers.last?.image {
                let dotAlpha = drawnAlpha(of: dot, at: NSPoint(x: 8, y: dot.size.height / 2)) ?? 0
                t.expect(abs(dotAlpha - CGFloat(strength)) <= 0.06, desc: "\(label) the dot paints at that alpha (\(dotAlpha))")
            }
            for (index, mark) in drawnTabTagMarks(inGroupOf: window).enumerated() {
                guard let mark, let image = mark.image else {
                    t.expect(false, desc: "\(label) tab \(index)'s title shows its mark")
                    continue
                }
                let markAlpha = drawnAlpha(of: image, at: NSPoint(x: mark.markSide / 2, y: mark.markSide / 2)) ?? 0
                t.expect(
                    abs(markAlpha - CGFloat(strength)) <= 0.06,
                    desc: "\(label) tab \(index) paints its dot at that alpha (\(markAlpha))"
                )
            }
        }
        capture(window, "strength-slider")
    }

    /// Writes the capsule at half and full strength, in gray, red and
    /// yellow, over an opaque window and over a translucent, blurred one, for
    /// the eye: whether the fill reads as the tag's colour, whether the ink
    /// stays legible, and whether the blurred desktop shows through.
    @MainActor
    private static func drawStrengthPictures(_ t: UBUITestContext) {
        guard PhosphorIcons.icon(named: "flask") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        configureAppendingToLiveDocument(strengthRules(color: "gray", icon: "flask"))
        guard let (controller, window, _) = openTaggedPair(t), let chip = controller.remoteConnectionIndicator else { return }
        var drawn = 0
        for isTranslucent in [false, true] {
            for color in ["gray", "red", "yellow"] {
                for strength in [0.5, 1.0] {
                    restoreLiveDocument(saved)
                    let ground =
                        isTranslucent
                        ? "background_opacity = 0.6\nblur_radius = \(Ubiquitty.Preferences.Defaults.blurRadius)\n"
                        : "background_opacity = 1.0\nblur_radius = 0\n"
                    configureAppendingToLiveDocument(
                        strengthRules(color: color, icon: "flask") + "\n[appearance]\ntag_color_opacity = \(strength)\n" + ground
                    )
                    let name = "strength-\(Int(strength * 100))-\(color)-\(isTranslucent ? "translucent" : "opaque")"
                    let isShown = t.wait(
                        until: {
                            isSameColor(chip.capsuleFillForTesting, paletteColor(color))
                                && chip.capsuleFillOpacityForTesting.map { abs($0 - CGFloat(strength)) < 0.001 } == true
                        },
                        timeout: 6
                    )
                    t.expect(isShown, desc: "\(name): the chip wears the rule at the strength (\(describe(controller)))")
                    t.pump(0.8)
                    capture(window, name)
                    drawn += isShown ? 1 : 0
                }
            }
        }
        t.expect(drawn, equals: 12, desc: "twelve pictures drawn under /tmp/host-labels")
    }

    /// One arrangement of the title row's tag stack a picture shows.
    /// One tag's place in a stack picture.
    private enum StackRole {
        /// The tag the host chip wears.
        case chip
        /// The marker nearest the window buttons.
        case firstMarker
        /// The marker beside it.
        case secondMarker
    }

    private enum StackPicture: CaseIterable {
        /// An untitled tag's circle, a titled pill, and the chip wearing a
        /// third tag.
        case dotTitledChip
        /// Two circles, one holding an icon, and the chip.
        case twoDotsChip
        /// One titled pill, on a local window with no chip.
        case titledAlone
        /// The chip alone, wearing the window's one tag.
        case chipAlone

        /// The name the picture's file carries.
        var name: String {
            switch self {
            case .dotTitledChip: "dot-titled-chip"
            case .twoDotsChip: "two-dots-chip"
            case .titledAlone: "titled-alone"
            case .chipAlone: "chip-alone"
            }
        }

        /// How many markers the stack draws before the chip.
        var markerCount: Int {
            switch self {
            case .dotTitledChip, .twoDotsChip: 2
            case .titledAlone: 1
            case .chipAlone: 0
            }
        }

        /// Whether the chip stands, wearing a capsule.
        var hasChip: Bool { self != .titledAlone }

        /// The palette name one tag of the stack wears: the shared colour,
        /// or under `mixed`, blue for the chip, red for the first marker and
        /// yellow for the second, as a window carrying several rules wears
        /// them.
        ///
        /// - Parameters:
        ///   - color: The shared palette name, or `mixed`.
        ///   - role: The chip, the first marker or the second.
        /// - Returns: The palette name.
        static func tint(_ color: String, _ role: StackRole) -> String {
            guard color == "mixed" else { return color }
            switch role {
            case .chip: return "blue"
            case .firstMarker: return "red"
            case .secondMarker: return "yellow"
            }
        }

        /// The palette names of the markers, in the order the stack draws
        /// them.
        ///
        /// - Parameter color: The shared palette name, or `mixed`.
        /// - Returns: One name per marker.
        func markerColors(_ color: String) -> [String] {
            switch self {
            case .dotTitledChip, .twoDotsChip: [Self.tint(color, .firstMarker), Self.tint(color, .secondMarker)]
            case .titledAlone: [Self.tint(color, .secondMarker)]
            case .chipAlone: []
            }
        }

        /// The rules the picture draws: the chip's rule first, since the chip
        /// wears the first coloured rule, then the markers in the order the
        /// stack draws them. The lone pill is a hand-set tag whose colour a
        /// rule matching nothing declares.
        ///
        /// - Parameter color: The palette name every tag shares, or `mixed`.
        /// - Returns: The rules, as TOML.
        func rules(color: String) -> String {
            let chipColor = Self.tint(color, .chip)
            let firstColor = Self.tint(color, .firstMarker)
            let secondColor = Self.tint(color, .secondMarker)
            let chip = "[[tags]]\nname = \"lab\"\ncolor = \"\(chipColor)\"\nicon = \"flask\"\nmatch_host = \"lab-mac*\"\n\n"
            let dot = "[[tags]]\ncolor = \"\(firstColor)\"\nmatch_host = \"lab-mac-pro\"\n\n"
            let iconDot = "[[tags]]\ncolor = \"\(secondColor)\"\nicon = \"star\"\nmatch_host = \"lab-mac-pro\"\n\n"
            let titled = "[[tags]]\nname = \"prod\"\ncolor = \"\(secondColor)\"\nmatch_host = \"lab-mac-pro\"\n\n"
            let declared = "[[tags]]\nname = \"prod\"\ncolor = \"\(secondColor)\"\n\n"
            switch self {
            case .dotTitledChip: return chip + dot + titled
            case .twoDotsChip: return chip + dot + iconDot
            case .titledAlone: return declared
            case .chipAlone: return chip
            }
        }
    }

    /// Writes the title row's tag stack for the eye: a circle, a titled pill
    /// and the chip; two circles and the chip; a titled pill alone; and the
    /// chip alone. Each in gray, red and yellow, and in a mix of blue, red
    /// and yellow, at half and full strength,
    /// over an opaque and a translucent window, under `/tmp/host-labels` as
    /// `stack-*`.
    @MainActor
    private static func drawStackPictures(_ t: UBUITestContext) {
        guard PhosphorIcons.icon(named: "flask") != nil, PhosphorIcons.icon(named: "star") != nil else {
            t.expect(false, desc: "the app bundle carries the Phosphor catalog")
            return
        }
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        configureAppendingToLiveDocument(StackPicture.chipAlone.rules(color: "gray"))
        guard let remote = openReportingShell("lab-mac-pro", t), let remoteWindow = remote.window,
            let local = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild),
            let localWindow = local.window
        else {
            t.expect(false, desc: "a shell on lab-mac-pro and a local shell opened")
            return
        }
        setManualTags(["prod"], on: localWindow)
        var drawn = 0
        for picture in StackPicture.allCases {
            let (controller, window) = picture.hasChip ? (remote, remoteWindow) : (local, localWindow)
            for isTranslucent in [false, true] {
                for color in ["gray", "red", "yellow", "mixed"] {
                    for strength in [0.5, 1.0] {
                        restoreLiveDocument(saved)
                        let ground =
                            isTranslucent
                            ? "background_opacity = 0.6\nblur_radius = \(Ubiquitty.Preferences.Defaults.blurRadius)\n"
                            : "background_opacity = 1.0\nblur_radius = 0\n"
                        configureAppendingToLiveDocument(
                            picture.rules(color: color) + "[appearance]\ntag_color_opacity = \(strength)\n" + ground
                        )
                        let name =
                            "stack-\(picture.name)-\(Int(strength * 100))-\(color)-\(isTranslucent ? "translucent" : "opaque")"
                        let chipColor = paletteColor(StackPicture.tint(color, .chip))
                        let markerColors = picture.markerColors(color).map(paletteColor)
                        let isShown = t.wait(
                            until: {
                                guard let strip = titlebarStrip(of: window) else { return false }
                                let marks = titleMarks(titleField(in: strip))
                                let chip = controller.remoteConnectionIndicator
                                let chipIsRight =
                                    picture.hasChip
                                    ? isSameColor(chip?.capsuleFillForTesting, chipColor)
                                        && chip?.capsuleFillOpacityForTesting.map { abs($0 - CGFloat(strength)) < 0.001 } == true
                                    : chip?.isWearingTagCapsule != true
                                return chipIsRight && marks.count == picture.markerCount
                                    && zip(marks, markerColors)
                                        .allSatisfy { mark, markerColor in
                                            isSameColor(mark.fill, markerColor) && abs(mark.fillOpacity - CGFloat(strength)) < 0.001
                                        }
                            },
                            timeout: 6
                        )
                        t.expect(isShown, desc: "\(name): the stack wears the rules at the strength (\(describe(controller)))")
                        t.pump(0.8)
                        capture(window, name)
                        drawn += isShown ? 1 : 0
                    }
                }
            }
        }
        t.expect(drawn, equals: 64, desc: "sixty-four stack pictures drawn under /tmp/host-labels")
    }

    // MARK: - Mixed panes

    @MainActor
    private static func verifyMixedPanes(_ t: UBUITestContext) {
        let saved = configureAppendingToLiveDocument(labRule)
        defer {
            restoreLiveDocument(saved)
            t.closeAllWindows()
        }
        guard let controller = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild),
            let window = controller.window
        else {
            t.expect(false, desc: "a local window opened")
            return
        }
        t.pump(0.3)
        let first = controller.focusedSurfaceForTesting
        controller.splitRight(nil)
        var second: TerminalSurface?
        t.expect(
            t.wait(
                until: {
                    second = controller.focusedSurfaceForTesting
                    return second != nil && second !== first
                },
                timeout: 8
            ),
            desc: "the split opened a second pane and focused it"
        )
        // The new pane is the one that goes elsewhere. Its login shell
        // reports this Mac at every prompt, as a shell with integration does,
        // so it hands over to a plain one first, as a session that ran `ssh`
        // hands over to the far side's.
        t.pump(1.5)
        second?.send("exec /bin/sh\n")
        t.pump(0.5)
        second?.send("printf '\\033]7;file://lab-mac-pro/tmp\\007'\n")
        t.expect(
            t.wait(until: { controller.paneHeadersNameHost() }, timeout: 8),
            desc: "a window mixing a local pane and a remote one names each pane's host"
        )
        t.expect(
            t.wait(until: { chipNames(controller, host: "lab-mac-pro", carrier: "SSH") && titleTags(controller) == "lab" }, timeout: 8),
            desc: "the title row speaks for the focused pane, chip and tags alike (\(describe(controller)))"
        )
        capture(window, "mixed-panes")
    }
}
