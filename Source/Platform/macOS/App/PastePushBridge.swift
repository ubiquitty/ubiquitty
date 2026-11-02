// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

/// The paste-push decisions: what a pasted image becomes on the way to the
/// host, and what the host's answer shows.
///
/// A free-standing class rather than an extension on the window controller.
/// An `@objc` extension on a class the bridging header declares makes the
/// generated header import that bridging header, so a translation unit
/// including both sees two declarations of the class and the compiler
/// refuses the duplicate. The controller is being replaced by the Swift
/// shell, so its behaviour reaches Swift by call-in rather than by earning
/// a refactor of its header.
///
/// Objects from the project are typed as `NSObject` here for the same
/// reason — naming their classes in a signature the generated header carries
/// pulls the bridging header in — which is the convention the clipboard
/// prompt already follows.
@objc(UBPastePush)
@MainActor
public final class PastePush: NSObject {
    /// The general pasteboard's image as PNG, or nil when it holds none.
    ///
    /// A screenshot to the clipboard lands as PNG; a region grab and several
    /// apps leave TIFF instead. The host wants the format a program opens,
    /// so TIFF is re-encoded here rather than shipped as-is.
    /// Gives the Kit's windows this shell's paste-progress panel.
    ///
    /// The Kit decides when a push starts and settles; the panel is window
    /// furniture only a shell has, so it arrives as closures rather than as a
    /// dependency the Kit could not satisfy on its own.
    ///
    /// Called once at launch. A Kit with no presenter sends no image push,
    /// which is the right answer for an embedder with no panel to show.
    @objc
    public static func installPastePushPresenter() {
        SelectionPasteboard.didCopyText = { text in
            ClipboardStore.shared().recordRecentCopy(text)
        }
        TerminalWindowController.disableMultilinePasteConfirmation = {
            SettingsBridge.app?.settingsSetConfirmMultilinePaste(false)
        }
        TerminalWindowController.pastePushPresenter = PastePushPresenter(
            imageFromPasteboard: { MainActor.assumeIsolated { pngFromGeneralPasteboard() } },
            began: { destination, mime, window, progress in
                MainActor.assumeIsolated {
                    showPasting(toDestination: destination, mime: mime, over: window, progress: progress)
                }
            },
            settled: { status, path in MainActor.assumeIsolated { finish(status: status, path: path) } },
            dismissed: { MainActor.assumeIsolated { dismissPanel() } }
        )
    }

    @objc
    public static func pngFromGeneralPasteboard() -> Data? {
        pngFromPasteboard(.general)
    }

    /// The image bytes on one pasteboard, as PNG.
    ///
    /// - Parameter pasteboard: The pasteboard to read.
    /// - Returns: PNG bytes, or nil when it carries no image.
    static func pngFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff),
            let representation = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    /// Raises the progress panel for a paste now crossing to `destination`.
    ///
    /// - Parameters:
    ///   - destination: The machine's name; empty reads as "the host".
    ///   - mime: The payload's MIME name, which picks the document icon.
    ///   - window: The window it belongs to; nil centres the panel.
    ///   - progress: Answers what fraction of the payload has left, or a
    ///     negative number when the sender cannot say.
    @objc
    public static func showPasting(
        toDestination destination: String,
        mime: String,
        over window: NSWindow?,
        progress: @escaping () -> Double
    ) {
        PastePushPanel.shared.showPasting(toDestination: destination, mime: mime, over: window, progress: progress)
    }

    /// Reports the host's answer on the panel.
    ///
    /// The landed path is already typed into the program, so the panel names
    /// the file and goes; a refusal is the only place its reason is said, so
    /// it stays up longer.
    ///
    /// - Parameters:
    ///   - status: The wire's paste-push status value.
    ///   - path: Where it landed, empty on a refusal.
    @objc
    public static func finish(status: UInt8, path: String) {
        switch PastePushOutcome(rawValue: status) {
        case .landed:
            PastePushPanel.shared.finishLanded(atPath: path)
        case .tooLarge:
            PastePushPanel.shared.finishFailed(reason: "The image is too large to paste to this host. Try a smaller image.")
        case .ioError:
            PastePushPanel.shared.finishFailed(reason: "The host couldn’t save the pasted image. Try again.")
        case .busy:
            PastePushPanel.shared.finishFailed(reason: "The host saved the image, but the program there isn’t reading its input.")
        case .unsupported, .none:
            PastePushPanel.shared.finishFailed(reason: "This host doesn’t accept pasted images.")
        }
    }

    /// Hides the panel now — a window closing under a paste in flight.
    @objc
    public static func dismissPanel() {
        PastePushPanel.shared.dismissNow()
    }
}

/// Retains the paste panel's destination while the panel owns keyboard focus.
@objc(UBPasteBufferActions)
@MainActor
final class PasteBufferActions: NSObject {
    private static let shared = PasteBufferActions()
    private weak var target: NSWindowController?

    @objc
    static func captureTarget(_ window: NSWindow?) {
        shared.target = window?.windowController
    }

    @objc
    static func pasteText(_ text: String) {
        let target = shared.target ?? NSApp.keyWindow?.windowController
        if let controller = target as? TerminalWindowController {
            controller.pasteText(text)
        }
    }
}

/// The wire's PastePushStatus, as the delegate hook carries it.
///
/// Spelled here rather than imported: the C++ enum reaches Swift only through
/// an interop module this file does not import, and the wire values are the
/// contract either way — the frame catalog test pins them.
enum PastePushOutcome: UInt8 {
    case landed = 0
    case tooLarge = 1
    case ioError = 2
    case unsupported = 3
    case busy = 4
}
