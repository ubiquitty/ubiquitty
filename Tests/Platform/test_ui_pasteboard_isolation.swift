// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ObjectiveC.runtime

// The outer guard owns a second private board. Broken or disabled isolation
// reaches that sentinel, never the operator's general pasteboard.
private final class SentinelGuard: @unchecked Sendable {
    private struct Hook {
        let original: Method
        let replacement: Method
        let originalImplementation: IMP
        let replacementImplementation: IMP
    }

    static let shared = SentinelGuard()
    private let lock = NSRecursiveLock()
    private var board: NSPasteboard?
    private var hooks: [Hook] = []
    private var accessCount = 0

    func install(board: NSPasteboard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        precondition(self.board == nil)
        let selectors = [
            ("generalPasteboard", "isolationControlGeneralPasteboard"),
            ("pasteboardWithName:", "isolationControlPasteboardWithName:"),
        ]
        var prepared: [Hook] = []
        for (originalName, replacementName) in selectors {
            guard let original = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(originalName)),
                let replacement = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(replacementName))
            else { return false }
            prepared.append(
                Hook(
                    original: original,
                    replacement: replacement,
                    originalImplementation: method_getImplementation(original),
                    replacementImplementation: method_getImplementation(replacement)
                )
            )
        }
        self.board = board
        hooks = prepared
        for hook in hooks { method_exchangeImplementations(hook.original, hook.replacement) }
        return ownsImplementations()
    }

    func restore() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ownsImplementations() else { return false }
        for hook in hooks.reversed() { method_exchangeImplementations(hook.original, hook.replacement) }
        let restored = hooks.allSatisfy {
            Self.address(method_getImplementation($0.original)) == Self.address($0.originalImplementation)
                && Self.address(method_getImplementation($0.replacement)) == Self.address($0.replacementImplementation)
        }
        hooks = []
        board = nil
        return restored
    }

    func ownsImplementations() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hooks.isEmpty
            && hooks.allSatisfy {
                Self.address(method_getImplementation($0.original)) == Self.address($0.replacementImplementation)
                    && Self.address(method_getImplementation($0.replacement)) == Self.address($0.originalImplementation)
            }
    }

    func general() -> NSPasteboard {
        lock.lock()
        defer { lock.unlock() }
        accessCount += 1
        guard let board else { preconditionFailure("The sentinel guard has no private board") }
        return board
    }

    var accesses: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessCount
    }

    private static func address(_ implementation: IMP) -> UInt {
        unsafeBitCast(implementation, to: UInt.self)
    }
}

extension NSPasteboard {
    @objc
    dynamic class func isolationControlGeneralPasteboard() -> NSPasteboard {
        SentinelGuard.shared.general()
    }

    @objc(isolationControlPasteboardWithName:)
    dynamic class func isolationControlPasteboard(withName name: NSPasteboard.Name) -> NSPasteboard {
        if name == .general { return SentinelGuard.shared.general() }
        return isolationControlPasteboard(withName: name)
    }
}

private final class PromisedData: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var requestCount = 0
    let bytes = Data([0, 1, 127, 128, 255])

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock()
        requestCount += 1
        lock.unlock()
        item.setData(bytes, forType: type)
    }
}

@MainActor
private final class IsolationDriver {
    private var failures = 0
    private var assertions = 0
    private let binaryType = NSPasteboard.PasteboardType("org.ubiquitty.test.isolation.binary")
    private let promisedType = NSPasteboard.PasteboardType("org.ubiquitty.test.isolation.promised")

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    func run() -> Int32 {
        let sentinel = NSPasteboard.withUniqueName()
        let unrelated = NSPasteboard.withUniqueName()
        defer {
            sentinel.releaseGlobally()
            unrelated.releaseGlobally()
        }
        guard SentinelGuard.shared.install(board: sentinel) else {
            print("FAIL: private sentinel guard installation failed; no clipboard access attempted")
            return 2
        }
        let sentinelProvider = PromisedData()
        let sentinelItem = NSPasteboardItem()
        expect(sentinelItem.setString("operator sentinel", forType: .string), "seed sentinel string")
        expect(sentinelItem.setData(Data([255, 0, 33]), forType: binaryType), "seed sentinel binary")
        expect(sentinelItem.setDataProvider(sentinelProvider, forTypes: [promisedType]), "seed sentinel promise")
        sentinel.clearContents()
        expect(sentinel.writeObjects([sentinelItem]), "write sentinel item")
        let sentinelChangeCount = sentinel.changeCount

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--real-mode-control") {
            expect(PasteboardIsolation.install(), "marked real-board mode installs without interception")
            expect(PasteboardIsolation.usesRealGeneralPasteboard, "marked mode reports system-wide integration")
            let accesses = SentinelGuard.shared.accesses
            let board = NSPasteboard.general
            expect(board === sentinel, "real-board mode passes through to the outer AppKit accessor")
            expect(SentinelGuard.shared.accesses == accesses + 1, "the outer sentinel observes real-board pass-through")
            expect(
                SelectionPasteboard.write(
                    plain: "real control",
                    rtf: "{\\rtf1 real control}",
                    html: "<b>real control</b>",
                    to: board
                ),
                "the product writer reaches the pass-through board"
            )
            expect(sentinel.string(forType: .string) == "real control", "the pass-through board receives product text")
            PasteboardIsolation.finish()
            expect((sentinel.pasteboardItems ?? []).isEmpty, "real-board teardown empties its disposable board")
            expect(PasteboardIsolation.restoreAfterQuiescence(), "real-board state restores after quiescence")
            expect(SentinelGuard.shared.ownsImplementations(), "real-board mode never changes the outer accessors")
            expect(SentinelGuard.shared.restore(), "real-board control restores native implementations")
            print("clipboard real-mode control: \(assertions) assertions, \(failures) failures")
            return failures == 0 ? 0 : 1
        }
        if arguments.contains("--ordinary") || arguments.contains("--expect-install-refusal") {
            expect(!PasteboardIsolation.install(), "installation must refuse this invocation")
            expect(!PasteboardIsolation.failureDescription.isEmpty, "refusal explains its cause")
            expect(SentinelGuard.shared.ownsImplementations(), "refusal changes neither accessor implementation")
            if arguments.contains("--ordinary") {
                let accesses = SentinelGuard.shared.accesses
                expect(NSPasteboard.general === sentinel, "an unisolated general accessor passes through to AppKit")
                expect(SentinelGuard.shared.accesses == accesses + 1, "the outer sentinel observes the pass-through")
            }
        } else {
            exerciseIsolation(sentinel: sentinel, unrelated: unrelated, arguments: arguments)
        }

        expect(sentinel.changeCount == sentinelChangeCount, "isolation never changes the sentinel ownership")
        expect(sentinel.string(forType: .string) == "operator sentinel", "sentinel text remains exact")
        expect(sentinel.data(forType: binaryType) == Data([255, 0, 33]), "sentinel eager binary remains exact")
        expect(sentinelProvider.requests == 0, "isolation never materializes a sentinel promise")
        let changedItem = NSPasteboardItem()
        expect(changedItem.setString("new operator sentinel", forType: .string), "seed a simulated concurrent clipboard change")
        expect(changedItem.setData(Data([9, 0, 255]), forType: binaryType), "seed changed sentinel binary")
        sentinel.clearContents()
        expect(sentinel.writeObjects([changedItem]), "simulate an independent clipboard owner update")
        let changedCount = sentinel.changeCount
        PasteboardIsolation.finish()
        expect(PasteboardIsolation.restoreAfterQuiescence(), "quiescent restoration succeeds")
        expect(sentinel.changeCount == changedCount, "teardown preserves the independent owner's change count")
        expect(sentinel.string(forType: .string) == "new operator sentinel", "teardown never restores stale operator text")
        expect(sentinel.data(forType: binaryType) == Data([9, 0, 255]), "teardown never restores stale operator binary")
        expect(SentinelGuard.shared.ownsImplementations(), "both captured original accessors are restored exactly")
        expect(SentinelGuard.shared.restore(), "outer guard restores native implementations exactly")
        // No general getter is called after the outer guard restores AppKit.
        print("clipboard isolation: \(assertions) assertions, \(failures) failures")
        return failures == 0 ? 0 : 1
    }

    private func exerciseIsolation(sentinel: NSPasteboard, unrelated: NSPasteboard, arguments: [String]) {
        guard PasteboardIsolation.install() else {
            expect(false, "private clipboard installation: \(PasteboardIsolation.failureDescription)")
            return
        }
        let disabledRoute: (String, String)? =
            if arguments.contains("--disable-general-route") {
                ("generalPasteboard", "uiTestGeneralPasteboard")
            } else if arguments.contains("--disable-named-route") {
                ("pasteboardWithName:", "uiTestPasteboardWithName:")
            } else { nil }
        if let disabledRoute {
            guard let original = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(disabledRoute.0)),
                let replacement = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(disabledRoute.1))
            else {
                expect(false, "negative route control requires both native selector implementations")
                return
            }
            method_exchangeImplementations(original, replacement)
            defer { method_exchangeImplementations(original, replacement) }
            let board = disabledRoute.0 == "generalPasteboard" ? NSPasteboard.general : NSPasteboard(name: .general)
            expect(board !== sentinel, "negative route control detects sentinel access")
            expect(SentinelGuard.shared.accesses == 0, "negative route control detects original accessor invocation")
            return
        }

        let board = NSPasteboard.general
        let firstName = board.name
        expect(board !== sentinel, "general accessor returns an isolated native board")
        expect(NSPasteboard(name: .general) === board, "named general accessor shares the isolated board")
        expect(SentinelGuard.shared.accesses == 0, "neither accessor invokes the original general route")
        expect(PasteboardIsolation.install(), "active installation is idempotent")
        expect(NSPasteboard.general === board, "idempotence retains the same clipboard")
        unrelated.clearContents()
        expect(unrelated.setString("unrelated", forType: .string), "seed unrelated private board")
        expect(NSPasteboard(name: unrelated.name).string(forType: .string) == "unrelated", "other named boards preserve native routing")

        let itemOne = NSPasteboardItem()
        let itemTwo = NSPasteboardItem()
        expect(itemOne.setString("first π", forType: .string), "first native item text")
        expect(itemOne.setData(Data([0, 255, 1]), forType: binaryType), "first native item binary")
        expect(itemTwo.setString("second 🐈", forType: .string), "second native item text")
        board.clearContents()
        expect(board.writeObjects([itemOne, itemTwo]), "native multiple-item write")
        let items = board.pasteboardItems ?? []
        expect(items.count == 2, "native item boundaries remain distinct")
        expect(items.first?.data(forType: binaryType) == Data([0, 255, 1]), "native custom bytes round trip")
        expect(items.last?.string(forType: .string) == "second 🐈", "native second item text round trips")

        let richText = "{\\rtf1\\ansi clipboard}"
        let html = "<b>clipboard</b>"
        expect(
            SelectionPasteboard.write(plain: "clipboard", rtf: richText, html: html, to: .general),
            "real selection writer uses isolated board"
        )
        expect(board.data(forType: .rtf) == Data(richText.utf8), "native RTF bytes round trip")
        expect(board.data(forType: .html) == Data(html.utf8), "native HTML bytes round trip")
        expect(board.string(forType: .string) == "clipboard", "native selection text round trips")
        let richChangeCount = board.changeCount
        expect(!SelectionPasteboard.write(plain: "", rtf: "", html: "", to: .general), "empty selection does not write")
        expect(board.changeCount == richChangeCount, "empty selection leaves native ownership unchanged")

        // The PAL clipboard seam (Source/Platform/macOS/ClipboardPasteboard.swift).
        // Core's OSC 52 dispatch reaches it from C++, so it is the one clipboard
        // writer in the app that is not Swift calling Swift, and it is the one
        // whose board is chosen inside the seam rather than passed to it. It
        // lands on the isolated board like the rest.
        board.clearContents()
        let seamText = "osc52 π🐈"
        seamText.withCString { ubiquittyClipboardSetText($0, strlen($0)) }
        expect(board.string(forType: .string) == seamText, "the PAL clipboard seam writes the isolated board")
        var seamBuffer = [CChar](repeating: 0, count: 64)
        let seamCount = seamBuffer.withUnsafeMutableBufferPointer {
            ubiquittyClipboardGetText($0.baseAddress, Int32($0.count))
        }
        expect(Int(seamCount) == Array(seamText.utf8).count, "the seam reads back every byte it wrote")
        let seamRead = seamBuffer.prefix(Int(max(0, seamCount))).map { UInt8(bitPattern: $0) }
        expect(String(decoding: seamRead, as: UTF8.self) == seamText, "the seam's bytes survive the round trip verbatim")
        // A capacity shorter than the text is the seam's clamp, and this is the
        // only binary that compiles the clamp: the C++ half hands the capacity
        // over untouched. The cut is on a raw byte boundary, so the answer is
        // the payload's first bytes whether or not one of them ends a character.
        let shortCapacity = 5
        var shortBuffer = [CChar](repeating: 0x7f, count: shortCapacity + 1)
        let shortCount = shortBuffer.withUnsafeMutableBufferPointer {
            ubiquittyClipboardGetText($0.baseAddress, Int32(shortCapacity))
        }
        expect(Int(shortCount) == shortCapacity, "a capacity below the text's length answers the capacity")
        let shortRead = shortBuffer.prefix(shortCapacity).map { UInt8(bitPattern: $0) }
        expect(Array(shortRead) == Array(seamText.utf8.prefix(shortCapacity)), "the clamped read is the text's first bytes")
        expect(shortBuffer[shortCapacity] == 0x7f, "the clamp writes nothing past the capacity")
        // Bytes that are not UTF-8 leave the board alone, which is what makes a
        // malformed OSC 52 payload a no-op rather than a cleared clipboard.
        let seamChangeCount = board.changeCount
        let invalidUTF8: [CChar] = [-1, -2]
        invalidUTF8.withUnsafeBufferPointer { ubiquittyClipboardSetText($0.baseAddress, $0.count) }
        expect(board.changeCount == seamChangeCount, "bytes that are not UTF-8 leave the clipboard's ownership alone")
        expect(board.string(forType: .string) == seamText, "and leave the text that was already there")
        // A board holding no string refuses, and a refusal is -1 rather than
        // zero: that is what lets Core tell "no clipboard" from "the clipboard
        // holds nothing".
        board.clearContents()
        let emptyCount = seamBuffer.withUnsafeMutableBufferPointer {
            ubiquittyClipboardGetText($0.baseAddress, Int32($0.count))
        }
        expect(emptyCount == -1, "a pasteboard with no string answers -1")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = [directory.appendingPathComponent("one space"), directory.appendingPathComponent("two-π")]
        board.clearContents()
        expect(board.writeObjects(urls.map { $0 as NSURL }), "native URL objects write")
        let readURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        expect(readURLs == urls, "multiple native file URLs round trip")

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            ), let bitmapData = bitmap.bitmapData
        else {
            expect(false, "native bitmap allocation succeeds")
            return
        }
        bitmapData.update(from: [255, 0, 128, 255], count: 4)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            expect(false, "native PNG encoding succeeds")
            return
        }
        board.clearContents()
        expect(board.setData(png, forType: .png), "native PNG write")
        expect(board.data(forType: .png) == png, "native PNG bytes round trip")
        expect((board.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.count == 1, "native image reader consumes isolated PNG")

        let provider = PromisedData()
        let promisedItem = NSPasteboardItem()
        expect(promisedItem.setDataProvider(provider, forTypes: [promisedType]), "native promise registers")
        board.clearContents()
        expect(board.writeObjects([promisedItem]), "native promised item write")
        expect(provider.requests == 0, "writing a promise does not request bytes")
        expect(board.data(forType: promisedType) == provider.bytes, "explicit isolated read redeems the promise")
        expect(provider.requests == 1, "native data provider executes once")
        let unrequestedProvider = PromisedData()
        let unrequestedItem = NSPasteboardItem()
        expect(unrequestedItem.setDataProvider(unrequestedProvider, forTypes: [promisedType]), "unrequested promise registers")
        board.clearContents()
        expect(board.writeObjects([unrequestedItem]), "unrequested promised item write")
        PasteboardIsolation.reset()
        expect((board.pasteboardItems ?? []).isEmpty, "scenario reset empties only the isolated board")
        expect(unrequestedProvider.requests == 0, "scenario reset never materializes promised bytes")
        expect(unrelated.string(forType: .string) == "unrelated", "scenario reset preserves unrelated boards")
        let unfinishedProvider = PromisedData()
        let unfinishedItem = NSPasteboardItem()
        expect(unfinishedItem.setDataProvider(unfinishedProvider, forTypes: [promisedType]), "teardown promise registers")
        expect(board.writeObjects([unfinishedItem]), "teardown promised item write")
        PasteboardIsolation.finish()
        PasteboardIsolation.finish()
        expect(unfinishedProvider.requests == 0, "teardown never materializes promised bytes")
        expect(NSPasteboard.general === board, "finished routing still contains late general callbacks")
        expect(NSPasteboard(name: .general) === board, "finished routing still contains late named callbacks")
        expect(!PasteboardIsolation.install(), "a finished session cannot resume producers")
        expect(PasteboardIsolation.restoreAfterQuiescence(), "finished routing restores after quiescence")
        expect(SentinelGuard.shared.ownsImplementations(), "quiescence restores both outer sentinel accessors")
        expect(PasteboardIsolation.install(), "a quiescent new session can install")
        expect(NSPasteboard.general.name != firstName, "a new session gets a unique native board")
        expect(SentinelGuard.shared.accesses == 0, "all normal operations avoid both original general routes")
    }
}

@MainActor
private enum RealGeneralPasteboardIntegration {
    static let markerName = "UBIQUITTY_DISPOSABLE_GUI_SESSION"
    static let markerValue = "ubiquitty-pasteboard-integration-v1"

    static func run(arguments: [String]) -> Int32 {
        guard ProcessInfo.processInfo.environment[markerName] == markerValue else {
            print("REFUSED: real general-pasteboard integration requires a dedicated disposable GUI session")
            return 2
        }
        guard let nonce = value(after: "--nonce", in: arguments) else {
            print("FAIL: real general-pasteboard integration has no per-run nonce")
            return 1
        }
        if arguments.contains("--real-general-pasteboard-reader") {
            return read(nonce: nonce)
        }
        return writeAndRead(nonce: nonce, arguments: arguments)
    }

    private static func writeAndRead(nonce: String, arguments: [String]) -> Int32 {
        let board = NSPasteboard.general
        let plain = "ubiquitty real general clipboard \(nonce) π"
        let richText = "{\\rtf1\\ansi ubiquitty real general clipboard \(nonce)}"
        let html = "<b>ubiquitty real general clipboard \(nonce)</b>"
        guard SelectionPasteboard.write(plain: plain, rtf: richText, html: html, to: board) else {
            print("FAIL: product selection writer refused the real general pasteboard payload")
            return 1
        }
        defer { board.clearContents() }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = ["--real-general-pasteboard-reader", "--nonce", nonce]
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.standardOutput = standardOutput
        child.standardError = standardError
        do {
            try child.run()
        } catch {
            print("FAIL: real general-pasteboard reader could not launch: \(error)")
            return 1
        }
        child.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        if let outputText = String(data: output, encoding: .utf8), !outputText.isEmpty {
            print(outputText, terminator: outputText.hasSuffix("\n") ? "" : "\n")
        }
        if let errorText = String(data: errors, encoding: .utf8), !errorText.isEmpty {
            FileHandle.standardError.write(errors)
        }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            print("FAIL: real general-pasteboard reader exited \(child.terminationStatus)")
            return 1
        }
        print("real general-pasteboard integration: PASSED (product writer and independent reader)")
        return 0
    }

    private static func read(nonce: String) -> Int32 {
        let board = NSPasteboard.general
        let plain = "ubiquitty real general clipboard \(nonce) π"
        let richText = "{\\rtf1\\ansi ubiquitty real general clipboard \(nonce)}"
        let html = "<b>ubiquitty real general clipboard \(nonce)</b>"
        let didRead =
            board.string(forType: .string) == plain
            && board.data(forType: .rtf) == Data(richText.utf8)
            && board.data(forType: .html) == Data(html.utf8)
            && NSPasteboard(name: .general).string(forType: .string) == plain
        print(didRead ? "real general-pasteboard reader: PASS" : "real general-pasteboard reader: FAIL")
        return didRead ? 0 : 1
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

@main
private struct PasteboardIsolationMain {
    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--real-general-pasteboard") || arguments.contains("--real-general-pasteboard-reader") {
            exit(RealGeneralPasteboardIntegration.run(arguments: arguments))
        }
        exit(IsolationDriver().run())
    }
}
