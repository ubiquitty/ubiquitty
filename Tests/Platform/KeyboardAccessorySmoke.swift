// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

/// Exercises software modifiers and UIKit editing through the real terminal encoder.
enum KeyboardAccessorySmokeEntry {
    @MainActor
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ detail: String) {
            if !condition { failures.append(detail) }
        }
        let session = TerminalSessionModel()
        guard let surface = session.surfaceForDrawing(),
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return false }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let input = TerminalKeyInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        input.session = session
        controller.view.addSubview(input)
        window.makeKeyAndVisible()
        let clipboard = UIPasteboard.general.items
        let configuration = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            surface.observer = session
            session.disconnect()
            input.resignFirstResponder()
            window.isHidden = true
            previousWindow?.makeKey()
            UIPasteboard.general.items = clipboard
            _ = Ubiquitty.Preferences.configureOwnDocument(std.string(configuration))
        }
        let capture = KeyboardTransmissionCapture(session: session)
        surface.observer = capture
        // The screen asks for the keyboard before it takes first responder:
        // the view refuses focus while no request stands.
        input.wantsFirstResponder = true
        check(input.becomeFirstResponder(), "keyboard responder was not installed")
        input.resignFirstResponder()
        input.removeFromSuperview()
        input.applyWantedFirstResponder()
        controller.view.addSubview(input)
        try? await Task.sleep(for: .milliseconds(50))
        check(input.isFirstResponder, "returning to the screen did not restore the requested keyboard responder")
        func expect(_ wanted: String, _ detail: String) {
            let actual = capture.take()
            check(actual == wanted, "\(detail): got \(actual.debugDescription), wanted \(wanted.debugDescription)")
        }

        session.keyboardModifiers.toggle(.control)
        input.insertText("c")
        expect("\u{3}", "one-shot Control-C")
        check(session.keyboardModifiers.bits == 0, "one-shot modifier survived its key")
        input.insertText("c")
        expect("c", "plain text after one-shot")
        session.keyboardModifiers.toggle(.alternate)
        session.keyboardModifiers.toggle(.alternate)
        input.insertText("x")
        input.insertText("y")
        expect("\u{1b}x\u{1b}y", "locked Alt")
        session.keyboardModifiers.toggle(.alternate)
        session.keyboardModifiers.toggle(.shift)
        input.insertText("a")
        expect("A", "Shift character uses Core")
        surface.feed(Data("\u{1b}[?1h".utf8))
        session.sendAccessoryKey(.UpArrow)
        expect("\u{1b}OA", "application cursor mode")
        session.keyboardModifiers.toggle(.control)
        session.sendAccessoryKey(.UpArrow)
        expect("\u{1b}[1;5A", "modified arrow uses Core")
        if let command = input.keyCommands?.first(where: { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags == .shift }),
            let action = command.action
        {
            check(command.wantsPriorityOverSystemBehavior, "Shift-Left lets UIKit select its empty input document")
            check(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil), "Shift-Left has no responder action")
            expect("\u{1b}[1;2D", "hardware Shift-Left reaches the terminal")
        } else {
            check(false, "Shift-Left is not registered with the responder chain")
        }
        session.keyboardModifiers.beginPress(.shift)
        session.sendAccessoryKey(.LeftArrow)
        session.sendAccessoryKey(.RightArrow)
        expect("\u{1b}[1;2D\u{1b}[1;2C", "held Shift applies to every arrow before release")
        check(session.keyboardModifiers.isHeld(.shift), "sending a key released the held Shift")
        session.keyboardModifiers.endPress(.shift, .activate)
        check(session.keyboardModifiers.bits == 0, "a used hold became a sticky modifier on release")
        session.sendAccessoryKey(.UpArrow)
        expect("\u{1b}OA", "an arrow after releasing Shift is unmodified")
        session.keyboardModifiers.beginPress(.shift)
        session.keyboardModifiers.endPress(.shift, .activate)
        check(session.keyboardModifiers.state(of: .shift) == .once, "a short unused press did not latch the next key")
        session.sendAccessoryKey(.DownArrow)
        expect("\u{1b}[1;2B", "tapped Shift applies to one arrow")
        check(session.keyboardModifiers.bits == 0, "the tapped Shift survived its arrow")
        session.keyboardModifiers.beginPress(.alternate)
        session.keyboardModifiers.endPress(.alternate, .cancel)
        check(session.keyboardModifiers.bits == 0, "a cancelled modifier touch latched Alt")
        session.sendAccessoryKey(.F12)
        expect("\u{1b}[24~", "function key uses Core")
        session.sendAccessory(.tab)
        expect("\t", "Tab from the row")
        for (key, wanted) in zip(TerminalAccessoryKey.symbols.prefix(4), ["~", "/", "|", "-"]) {
            session.sendAccessory(key)
            expect(wanted, "\(key.spokenName) from the row")
        }
        session.keyboardModifiers.toggle(.alternate)
        session.sendAccessory(TerminalAccessoryKey.symbols[1])
        expect("\u{1b}/", "latched Alt applies to a symbol key")
        session.sendControlChord(TerminalControlChord.common[0])
        expect("\u{3}", "Control-C chord")
        session.keyboardModifiers.toggle(.control)
        session.sendControlChord(TerminalControlChord.common[1])
        expect("\u{4}", "a chord with Control already latched")
        check(session.keyboardModifiers.bits == 0, "a chord left its latched Control behind")
        surface.feed(Data("\u{1b}[>1u".utf8))
        session.keyboardModifiers.toggle(.control)
        input.insertText("c")
        expect("\u{1b}[99;5u", "Kitty Control-C is not a raw control byte")
        surface.feed(Data("\u{1b}[<u".utf8))

        session.keyboardModifiers.toggle(.control)
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        session.sendAccessoryKey(.LeftArrow)
        input.deleteBackward()
        expect("", "composition owns accessory and Delete")
        input.insertText("日本")
        expect("日本", "IME commits remain text")
        check(session.keyboardModifiers.bits != 0, "composition consumed a terminal modifier")
        input.insertText("d")
        expect("\u{4}", "modifier follows composition")
        input.insertText("\n")
        expect("\r", "ordinary Return")

        surface.feed(Data("\u{1b}[?2004h".utf8))
        UIPasteboard.general.string = "paste me"
        check(
            input.keyCommands?
                .contains(where: { $0.input == "v" && $0.action == #selector(input.paste(_:)) && $0.modifierFlags == .command }) == true,
            "Command-V is not registered"
        )
        check(UIApplication.shared.sendAction(#selector(input.paste(_:)), to: nil, from: nil, for: nil), "responder Paste was not handled")
        expect("\u{1b}[200~paste me\u{1b}[201~", "responder paste uses bracketed mode")
        _ = Ubiquitty.Preferences.configureOwnDocument(std.string("[paste]\nconfirm_multiline = true\nconfirm_multiline_threshold = 1\n"))
        var requested = ""
        session.onPasteRequested = { requested = $0 }
        UIPasteboard.general.string = "first\nsecond"
        _ = UIApplication.shared.sendAction(#selector(input.paste(_:)), to: nil, from: nil, for: nil)
        check(requested == "first\nsecond" && session.requiresPasteConfirmation(requested), "responder paste missed confirmation")
        expect("", "unconfirmed paste sent bytes")
        session.pasteText(requested)
        expect("\u{1b}[200~first\rsecond\u{1b}[201~", "confirmed paste retains normalization and fencing")
        session.onPasteRequested = nil

        surface.feed(Data("\r\nselected terminal text".utf8))
        surface.serviceIngestEvents()
        check(
            UIApplication.shared.sendAction(#selector(input.selectAll(_:)), to: nil, from: nil, for: nil),
            "responder Select All was not handled"
        )
        check(session.hasSelection && input.canPerformAction(#selector(input.copy(_:)), withSender: nil), "selection did not enable Copy")
        check(UIApplication.shared.sendAction(#selector(input.copy(_:)), to: nil, from: nil, for: nil), "responder Copy was not handled")
        check(UIPasteboard.general.string?.contains("selected terminal text") == true, "Copy missed terminal selection")
        expect("", "Copy was sent as Control-C")

        // A selected grid owns first responder with the software keyboard hidden.
        input.resignFirstResponder()
        surface.observer = session
        let gridHost = PaneSurfaceContainer(hosted: session.controller(for: surface))
        gridHost.editingSession = session
        controller.addChild(gridHost)
        gridHost.view.frame = controller.view.bounds
        controller.view.addSubview(gridHost.view)
        gridHost.didMove(toParent: controller)
        surface.observer = capture
        check(surface.becomeFirstResponder(), "grid responder was not installed")
        UIPasteboard.general.string = "grid paste"
        check(
            UIApplication.shared.sendAction(#selector(input.paste(_:)), to: nil, from: nil, for: nil),
            "grid responder did not forward Paste"
        )
        expect("\u{1b}[200~grid paste\u{1b}[201~", "hidden-keyboard paste")
        _ = surface.resignFirstResponder()

        // One row at every width a phone gives it: iPhone SE, iPhone 16 Pro,
        // iPhone Duo folded and unfolded, and landscape.
        for (width, page) in [(320, .symbols), (402, .symbols), (402, .function), (466, .symbols), (669, .function), (874, .symbols)]
            as [(CGFloat, TerminalKeyboardAccessory.Page)]
        {
            let accessory = UIHostingController(
                rootView: TerminalKeyboardAccessory(session: session, hideKeyboard: nil, page: page)
            )
            // The production row is already placed by safeAreaInset. This
            // isolated size measurement must not count the window's status bar.
            accessory.safeAreaRegions = []
            controller.addChild(accessory)
            accessory.view.frame = CGRect(x: 0, y: 0, width: width, height: 120)
            controller.view.addSubview(accessory.view)
            accessory.didMove(toParent: controller)
            // Let SwiftUI commit the hosted controls before measuring or drawing.
            try? await Task.sleep(for: .milliseconds(100))
            accessory.view.layoutIfNeeded()
            let size = accessory.sizeThatFits(in: CGSize(width: width, height: 1000))
            check(size.width <= width + 1 && size.height >= 43 && size.height <= 44.5, "the row is not one row at width \(width): \(size)")
            if width == 402, page == .symbols {
                func modifierButton(in view: UIView, named identifier: String) -> UIButton? {
                    if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
                    for child in view.subviews {
                        if let button = modifierButton(in: child, named: identifier) { return button }
                    }
                    return nil
                }
                if let control = modifierButton(in: accessory.view, named: "terminal-modifier-Ctrl") {
                    control.sendActions(for: .touchDown)
                    check(session.keyboardModifiers.isHeld(.control), "UIKit touch-down did not hold Control")
                    session.sendAccessoryKey(.LeftArrow)
                    session.sendAccessoryKey(.RightArrow)
                    expect("\u{1b}[1;5D\u{1b}[1;5C", "UIKit-held Control arrow chord")
                    control.sendActions(for: .touchUpInside)
                    check(session.keyboardModifiers.bits == 0, "UIKit release left Control active after its chord")
                    control.sendActions(for: .touchDown)
                    control.sendActions(for: .touchCancel)
                    check(session.keyboardModifiers.bits == 0, "UIKit cancellation left Control active")
                    check(control.accessibilityLabel == "Control", "Control is not read by name")
                    check(
                        control.accessibilityCustomActions?.count == TerminalControlChord.common.count,
                        "Control offers VoiceOver no chords"
                    )
                } else {
                    check(false, "the hosted row did not contain the native Control key")
                }
                let renderer = UIGraphicsImageRenderer(bounds: accessory.view.bounds)
                var didDraw = false
                let image = renderer.image { _ in
                    didDraw = accessory.view.drawHierarchy(in: accessory.view.bounds, afterScreenUpdates: true)
                }
                check(didDraw && accessory.view.window === window, "the row did not draw in its real window")
                if let data = image.pngData(), let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                {
                    try? data.write(to: documents.appendingPathComponent("keyboard-accessory-smoke.png"))
                }
            }
            accessory.willMove(toParent: nil)
            accessory.view.removeFromSuperview()
            accessory.removeFromParent()
        }
        for failure in failures { SmokeLaunch.report("keyboard-accessory: \(failure)") }
        return failures.isEmpty
    }
}

private final class KeyboardTransmissionCapture: TerminalSurfaceObserver {
    weak var session: TerminalSessionModel?
    private var bytes: [UInt8] = []

    init(session: TerminalSessionModel) { self.session = session }

    func terminalSurface(_ surface: TerminalSurface, didTransmit output: [CChar], count: Int) {
        bytes.append(contentsOf: output.prefix(count).map { UInt8(bitPattern: $0) })
    }

    func terminalSurfaceSelectionDidChange(_ surface: TerminalSurface) { session?.terminalSurfaceSelectionDidChange(surface) }

    func take() -> String {
        defer { bytes.removeAll() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
