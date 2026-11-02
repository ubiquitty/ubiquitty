// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import CryptoKit
import IOKit
import ImageIO
import UniformTypeIdentifiers
internal import UbiquittyCore
internal import UbiquittyRenderKit

@MainActor
internal final class TerminalDragDrop: NSObject {
    weak var surface: TerminalSurface?
    private(set) var acceptsDrops = false
    private(set) var offersDrags = false
    private var acceptedTypes: [String] = []
    private var dropMachine = ""
    private var offerMachine = ""
    private let machineID = TerminalDragDrop.localMachineID()
    private var dropID: UInt64 = 0
    private var dropSequence = -1
    private var dropOperation = NSDragOperation()
    private var dropTypes: [(String, NSPasteboard.PasteboardType)] = []
    private var dropBoard: NSPasteboard?
    private var dropBoardGeneration = 0
    private var dropURLs: [URL] = []
    private var fileRoots: [Int: Int] = [:]
    private var fileWorker: DropFileWorker?
    private var promises: [NSFilePromiseReceiver] = []
    private var promiseDirectory: URL?
    private var arePromisesPending = false
    private var deferredReads: [RuntimeDrive.DragCommand] = []
    private var promiseError = false
    private var gesture: NSEvent?
    private var didSendGesture = false
    private var offerID: UInt64 = 0
    private var offerTypes: [String] = []
    private var offerOperation: UInt32 = 0
    private var prepared: [Int64: Data] = [:]
    private var images: [NSImage] = []
    private var nativeDrag: NSDraggingSession?
    private var pasteboardItem: NSPasteboardItem?
    private var dataProvider: DragDataProvider?
    private var streamedData: [Int64: Data] = [:]
    private var receivedOfferBytes = 0
    private var requestedTypes = Set<Int>()
    private var pendingTypes = Set<Int>()
    private var imageError: Ubiquitty.DragDrop.Error = .Invalid
    private var promiseRemaining = 0
    private var remoteFiles: DropFileReceiver?
    private var remoteRoots: [Int64: Int] = [:]
    private var completedRoots = Set<Int>()
    private var finishedOperation: NSDragOperation?

    init(surface: TerminalSurface) { self.surface = surface }

    private static func localMachineID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard
            let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? String
        else { return "" }
        let digest = HMAC<SHA256>
            .authenticationCode(for: Data(uuid.utf8), using: SymmetricKey(data: Data("tty-dnd-protocol-machine-id".utf8)))
        return "1:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pasteboardType(_ mime: String) -> NSPasteboard.PasteboardType {
        if mime == "text/plain" { return .string }
        if mime == "text/uri-list" { return .fileURL }
        if let type = UTType(mimeType: mime), !type.isDynamic { return NSPasteboard.PasteboardType(type.identifier) }
        return NSPasteboard.PasteboardType(mime)
    }

    private func mimeType(_ type: NSPasteboard.PasteboardType) -> String? {
        if type == .URL || type == .fileURL || NSFilePromiseReceiver.readableDraggedTypes.contains(type.rawValue) { return "text/uri-list" }
        if type == .string { return "text/plain" }
        if let known = acceptedTypes.first(where: { Self.pasteboardType($0) == type }) { return known }
        if let mime = UTType(type.rawValue)?.preferredMIMEType { return mime }
        return type.rawValue.contains("/") && !type.rawValue.contains(" ") ? type.rawValue : nil
    }

    private func registerTypes() {
        let common: [NSPasteboard.PasteboardType] = [.string, .fileURL, .URL, .png, .tiff, .html, .rtf, .pdf]
        let types =
            acceptsDrops
            ? common + acceptedTypes.map(Self.pasteboardType)
                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } : TerminalSurface.fileDropTypes
        surface?.registerForDraggedTypes(Array(Set(types)))
    }

    private func emit(
        _ kind: Ubiquitty.DragDrop.EventKind,
        session: UInt64,
        request: UInt64 = 0,
        x: Int64 = 0,
        y: Int64 = 0,
        pixelX: Int64 = 0,
        pixelY: Int64 = 0,
        operation: UInt32 = 0,
        data: Data = Data(),
        error: Ubiquitty.DragDrop.Error = .Unknown,
        isFinal: Bool = false,
        isSameWindow: Bool = false
    ) {
        var event = Ubiquitty.DragDrop.NativeEvent()
        event.kind = kind
        event.sessionID = session
        event.requestID = request
        event.x = x
        event.y = y
        event.pixelX = pixelX
        event.pixelY = pixelY
        event.operation = operation
        event.error = error
        event.isFinal = isFinal
        event.isSameWindow = isSameWindow
        if surface?.drive.sendDragEvent(event, data: data) == false, kind != .Cancel {
            surface?.drive.cancelDragDrop()
            clearDrop()
            clearOffer()
        }
    }

    private func emitLocation(
        _ kind: Ubiquitty.DragDrop.EventKind,
        session: UInt64,
        point: NSPoint,
        operation: UInt32 = 0,
        types: [String] = [],
        isSameWindow: Bool = false
    ) {
        guard let surface, let cell = surface.reportCell(atViewPoint: point) else { return }
        let insets = surface.renderer?.gridInsets(for: surface)
        let scale = surface.window?.backingScaleFactor ?? 1
        emit(
            kind,
            session: session,
            x: Int64(cell.column),
            y: Int64(cell.row),
            pixelX: Int64(max(0, (point.x - (insets?.left ?? 0)) * scale)),
            pixelY: Int64(max(0, (point.y - (insets?.top ?? 0)) * scale)),
            operation: operation,
            data: Data(types.joined(separator: " ").utf8),
            isSameWindow: isSameWindow
        )
    }

    private func operations(_ native: NSDragOperation) -> UInt32 {
        (native.contains(.copy) ? 1 : 0) | (native.contains(.move) ? 2 : 0)
    }

    func entered(_ info: any NSDraggingInfo) -> NSDragOperation {
        clearDrop()
        guard let surface else { return [] }
        dropID = surface.drive.nextNativeDragSession()
        dropSequence = info.draggingSequenceNumber
        dropBoard = info.draggingPasteboard
        dropBoardGeneration = info.draggingPasteboard.changeCount
        var seen = Set<String>()
        dropTypes = (info.draggingPasteboard.types ?? [])
            .compactMap { type in
                guard let mime = mimeType(type), seen.insert(mime).inserted else { return nil }
                return (mime, type)
            }
        guard !dropTypes.isEmpty, dropTypes.count <= 128 else {
            clearDrop()
            return []
        }
        let sameWindow = (info.draggingSource as? TerminalDragDrop)?.surface?.window === surface.window
        emitLocation(
            .Enter,
            session: dropID,
            point: surface.convert(info.draggingLocation, from: nil),
            operation: operations(info.draggingSourceOperationMask),
            types: dropTypes.map(\.0),
            isSameWindow: sameWindow
        )
        return dropOperation
    }

    func updated(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard info.draggingSequenceNumber == dropSequence, let surface else { return entered(info) }
        var changedTypes: [String] = []
        if info.draggingPasteboard.changeCount != dropBoardGeneration {
            dropBoardGeneration = info.draggingPasteboard.changeCount
            var seen = Set<String>()
            dropTypes = (info.draggingPasteboard.types ?? [])
                .compactMap { type in
                    guard let mime = mimeType(type), seen.insert(mime).inserted else { return nil }
                    return (mime, type)
                }
            guard !dropTypes.isEmpty, dropTypes.count <= 128 else {
                left()
                return []
            }
            dropOperation = []
            changedTypes = dropTypes.map(\.0)
        }
        emitLocation(
            .Move,
            session: dropID,
            point: surface.convert(info.draggingLocation, from: nil),
            operation: operations(info.draggingSourceOperationMask),
            types: changedTypes
        )
        return dropOperation.intersection(info.draggingSourceOperationMask)
    }

    func left() {
        if dropID != 0 { emit(.Leave, session: dropID) }
        clearDrop()
    }

    func perform(_ info: any NSDraggingInfo) -> Bool {
        guard dropID != 0, !dropOperation.isEmpty, let surface, info.draggingSequenceNumber == dropSequence else { return false }
        dropURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        promises =
            info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard dropURLs.count <= 1024, promises.reduce(0, { $0 + $1.fileNames.count }) <= 1024 else {
            emit(.Cancel, session: dropID)
            clearDrop()
            return false
        }
        if promises.isEmpty { prepareFileWorker() } else { receivePromises() }
        emitLocation(
            .Drop,
            session: dropID,
            point: surface.convert(info.draggingLocation, from: nil),
            operation: operations(info.draggingSourceOperationMask),
            types: dropTypes.map(\.0)
        )
        return true
    }

    private func receivePromises() {
        let id = dropID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ubiquitty-drop-" + UUID().uuidString,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            promiseError = true
            return
        }
        promiseDirectory = directory
        arePromisesPending = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        promiseRemaining = promises.reduce(0) { $0 + $1.fileNames.count }
        if promiseRemaining == 0 {
            arePromisesPending = false
            return
        }
        for promise in promises {
            promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [weak self] url, error in
                let didFail = error != nil
                DispatchQueue.main.async {
                    guard let self, self.dropID == id else { return }
                    self.promiseError = self.promiseError || didFail
                    if !didFail { self.dropURLs.append(url) }
                    self.promiseRemaining -= 1
                    if self.promiseRemaining == 0 {
                        self.arePromisesPending = false
                        self.prepareFileWorker()
                        let requests = self.deferredReads
                        self.deferredReads.removeAll()
                        for request in requests { self.read(request) }
                    }
                }
            }
        }
    }

    private func prepareFileWorker() {
        fileRoots.removeAll()
        var paths: [String] = []
        for (index, url) in dropURLs.enumerated() where url.isFileURL {
            paths.append(url.path)
            fileRoots[index + 1] = paths.count
        }
        fileWorker = DropFileWorker(paths: paths)
    }

    private func clearDrop() {
        fileWorker?.cancel()
        fileWorker = nil
        dropID = 0
        dropSequence = -1
        dropOperation = []
        dropTypes.removeAll()
        dropBoard = nil
        dropURLs.removeAll()
        fileRoots.removeAll()
        promises.removeAll()
        deferredReads.removeAll()
        arePromisesPending = false
        promiseError = false
        if let directory = promiseDirectory {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
        }
        promiseDirectory = nil
    }

    private func read(_ command: RuntimeDrive.DragCommand) {
        guard command.sessionID == dropID else { return }
        if arePromisesPending {
            deferredReads.append(command)
            return
        }
        if promiseError {
            emit(.ReadFailed, session: dropID, request: command.requestID, error: .InputOutput)
            return
        }
        if command.pixelY != 0 || command.y != 0 {
            guard let fileWorker else {
                emit(.ReadFailed, session: dropID, request: command.requestID, error: .NotFound)
                return
            }
            let root: Int
            if command.pixelY != 0 {
                root = 0
            } else {
                guard command.y > 0, command.y <= dropURLs.count else {
                    emit(.ReadFailed, session: dropID, request: command.requestID, error: .NotFound)
                    return
                }
                guard let fileRoot = fileRoots[Int(command.y)] else {
                    emit(.ReadFailed, session: dropID, request: command.requestID, error: .Unknown)
                    return
                }
                root = fileRoot
            }
            let id = dropID
            fileWorker.read(root: root, directory: command.pixelY, child: Int(command.x)) { [weak self] chunk, complete in
                guard let self else {
                    complete()
                    return
                }
                self.deliverFileChunk(chunk, request: command.requestID, session: id, complete: complete)
            }
            return
        }
        guard command.x > 0, command.x <= dropTypes.count, let board = dropBoard, board.changeCount == dropBoardGeneration else {
            emit(.ReadFailed, session: dropID, request: command.requestID, error: .InputOutput)
            return
        }
        let (mime, type) = dropTypes[Int(command.x) - 1]
        if mime == "text/uri-list" {
            let data = Data((dropURLs.map(\.absoluteString).joined(separator: "\r\n") + "\r\n").utf8)
            deliver(data, request: command.requestID, session: dropID, kind: !dropMachine.isEmpty && dropMachine != machineID ? 1 : 0)
        } else if let data = board.data(forType: type) {
            deliver(data, request: command.requestID, session: dropID)
        } else {
            emit(.ReadFailed, session: dropID, request: command.requestID, error: .NotFound)
        }
    }

    private func deliverFileChunk(_ chunk: DropFileWorker.Chunk, request: UInt64, session: UInt64, complete: @escaping @Sendable () -> Void)
    {
        guard dropID == session, let surface else {
            complete()
            return
        }
        guard surface.drive.canSendNativeDragData else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                guard let self else {
                    complete()
                    return
                }
                self.deliverFileChunk(chunk, request: request, session: session, complete: complete)
            }
            return
        }
        if chunk.error != 0 {
            let errors: [Ubiquitty.DragDrop.Error] = [
                .Unknown, .Invalid, .NotFound, .NotPermitted, .NoMemory, .TooManyFiles, .InputOutput,
            ]
            emit(.ReadFailed, session: session, request: request, error: errors[Int(chunk.error)])
        } else {
            emit(.ReadData, session: session, request: request, pixelX: chunk.kind, data: chunk.data, isFinal: chunk.isComplete)
        }
        complete()
    }

    private func deliver(_ data: Data, request: UInt64, session: UInt64, kind: Int64 = 0, offset: Int = 0) {
        guard session == dropID else { return }
        let end = min(data.count, offset + 3072 * 16)
        for start in stride(from: offset, to: end, by: 3072) {
            guard session == dropID else { return }
            guard surface?.drive.canSendNativeDragData == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                    self?.deliver(data, request: request, session: session, kind: kind, offset: start)
                }
                return
            }
            emit(.ReadData, session: session, request: request, pixelX: kind, data: data.subdata(in: start..<min(end, start + 3072)))
        }
        if end == data.count {
            emit(.ReadData, session: session, request: request, pixelX: kind, isFinal: true)
        } else {
            DispatchQueue.main.async { [weak self] in self?.deliver(data, request: request, session: session, kind: kind, offset: end) }
        }
    }

    func pressed(_ event: NSEvent) {
        gesture = event
        didSendGesture = false
    }

    func dragged(_ event: NSEvent) -> Bool {
        guard offersDrags, let gesture, let surface else { return false }
        if didSendGesture { return true }
        guard hypot(event.locationInWindow.x - gesture.locationInWindow.x, event.locationInWindow.y - gesture.locationInWindow.y) >= 4
        else { return false }
        didSendGesture = true
        offerID = surface.drive.nextNativeDragSession()
        emitLocation(.BeginGesture, session: offerID, point: surface.convert(gesture.locationInWindow, from: nil))
        return true
    }

    func released() {
        gesture = nil
        if offerID != 0 { emit(.EndGesture, session: offerID) }
        didSendGesture = false
    }

    func cancel() {
        if dropID != 0 { emit(.Cancel, session: dropID) }
        if offerID != 0 { emit(.Cancel, session: offerID) }
        surface?.drive.cancelDragDrop()
        clearDrop()
        clearOffer()
    }

    func drain() {
        guard let surface else { return }
        while let command = surface.drive.takeDragDropCommand() {
            switch command.kind {
            case .Registration:
                let text = String(decoding: command.data, as: UTF8.self)
                if command.type == 97 {
                    if command.x == 1 {
                        dropMachine = text
                    } else {
                        acceptsDrops = true
                        acceptedTypes = text.split(separator: " ").map(String.init)
                    }
                } else if command.type == 65 {
                    acceptsDrops = false
                    acceptedTypes.removeAll()
                    dropMachine = ""
                    clearDrop()
                } else if command.type == 111 {
                    offersDrags = command.x == 1
                    offerMachine = text
                    if !offersDrags { clearOffer() }
                }
                registerTypes()
            case .AcceptDrop:
                if command.sessionID == dropID {
                    dropOperation = command.operation == 1 ? .copy : command.operation == 2 ? .move : []
                }
            case .ReadDrop: read(command)
            case .CloseDirectory:
                if command.sessionID == dropID { fileWorker?.closeDirectory(command.pixelY) }
            case .FinishDrop:
                if command.sessionID == dropID { clearDrop() }
            case .PrepareDrag:
                guard command.sessionID == offerID, gesture != nil else {
                    failOffer(.NotPermitted)
                    continue
                }
                offerTypes = String(decoding: command.data, as: UTF8.self).split(separator: " ").map(String.init)
                offerOperation = command.operation
            case .PrepareData:
                guard command.sessionID == offerID else { continue }
                prepared[command.x, default: Data()].append(command.data)
                if command.isFinal && command.x < 0 {
                    guard let image = makeImage(command) else {
                        failOffer(imageError)
                        continue
                    }
                    images.append(image)
                    prepared.removeValue(forKey: command.x)
                }
            case .BeginDrag:
                if command.sessionID == offerID { beginDrag() }
            case .SetDragImage:
                if command.sessionID == offerID { setImage(Int(command.x)) }
            case .DragData:
                guard command.sessionID == offerID else { continue }
                if command.type == 69 {
                    guard command.y >= 0, command.y < offerTypes.count else {
                        failOffer(.Invalid)
                        continue
                    }
                    streamedData.removeValue(forKey: command.y)
                    dataProvider?.fail(Self.pasteboardType(offerTypes[Int(command.y)]))
                    pendingTypes.remove(Int(command.y))
                    finishIfReady()
                    continue
                }
                guard command.data.count <= 64 * 1024 * 1024 - receivedOfferBytes else {
                    failOffer(.TooLarge)
                    continue
                }
                receivedOfferBytes += command.data.count
                streamedData[command.y, default: Data()].append(command.data)
                if command.isFinal, command.y >= 0, command.y < offerTypes.count,
                    let data = streamedData.removeValue(forKey: command.y)
                {
                    let type = Self.pasteboardType(offerTypes[Int(command.y)])
                    dataProvider?.complete(type, data: data)
                    pasteboardItem?.setData(data, forType: type)
                    pendingTypes.remove(Int(command.y))
                    finishIfReady()
                }
            case .RemoteFileData:
                if command.sessionID == offerID { receiveRemoteFile(command) }
            case .CancelDrag:
                if command.sessionID == offerID { clearOffer() }
            @unknown default: break
            }
        }
    }

    /// The widest or tallest drag image an offer may show: in pixels for an
    /// image the program sends, in points for one drawn from its text.
    private static let maxImageExtent: Int64 = 8192

    /// The most pixels an image the program sends may hold.
    private static let maxImagePixels: Int64 = 4 * 1024 * 1024

    private func makeImage(_ command: RuntimeDrive.DragCommand) -> NSImage? {
        imageError = .Invalid
        guard let data = prepared[command.x], command.pixelX > 0, command.pixelY > 0 else { return nil }
        if command.y != 0
            && (command.pixelX > Self.maxImageExtent || command.pixelY > Self.maxImageExtent
                || command.pixelX * command.pixelY > Self.maxImagePixels)
        {
            imageError = .TooLarge
            return nil
        }
        if command.y == 100 {
            guard command.pixelX <= Self.maxImageExtent, command.pixelY <= Self.maxImageExtent,
                command.pixelX * command.pixelY <= Self.maxImagePixels,
                let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetType(source) as String? == UTType.png.identifier,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value == command.pixelX,
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value == command.pixelY,
                let representation = NSBitmapImageRep(data: data), representation.pixelsWide == command.pixelX,
                representation.pixelsHigh == command.pixelY
            else { return nil }
            let image = NSImage(size: NSSize(width: representation.pixelsWide, height: representation.pixelsHigh))
            image.addRepresentation(representation)
            return image
        }
        if command.y == 24 || command.y == 32 {
            let samples = Int(command.y / 8)
            guard command.pixelX <= Self.maxImageExtent, command.pixelY <= Self.maxImageExtent,
                data.count == Int(command.pixelX * command.pixelY) * samples,
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let provider = CGDataProvider(data: data as CFData),
                let image = CGImage(
                    width: Int(command.pixelX),
                    height: Int(command.pixelY),
                    bitsPerComponent: 8,
                    bitsPerPixel: samples * 8,
                    bytesPerRow: Int(command.pixelX) * samples,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: (samples == 4 ? CGImageAlphaInfo.last : .none).rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                )
            else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        guard command.y == 0, let text = String(data: data, encoding: .utf8), text.utf8.count <= 65536 else { return nil }
        let fontSize = min(256, max(1, (surface?.renderer?.pointSize ?? 14) * Double(command.pixelX) / Double(command.pixelY)))
        let string = NSAttributedString(
            string: text.replacingOccurrences(of: "\n", with: " "),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.labelColor,
            ]
        )
        let size = string.size()
        let extent = CGFloat(Self.maxImageExtent)
        guard size.width <= extent, size.height <= extent else {
            imageError = .TooLarge
            return nil
        }
        return NSImage(size: size, flipped: false) { bounds in
            NSColor.windowBackgroundColor.withAlphaComponent(Double(command.operation) / 1024).setFill()
            bounds.fill()
            string.draw(in: bounds)
            return true
        }
    }

    private func beginDrag() {
        guard let surface, let gesture, NSEvent.pressedMouseButtons & 1 != 0, !offerTypes.isEmpty else {
            failOffer(.NotPermitted)
            return
        }
        let item = NSPasteboardItem()
        let provider = DragDataProvider()
        let id = offerID
        provider.onRequest = { [weak self] type in
            guard let self, self.offerID == id, let index = self.offerTypes.firstIndex(where: { Self.pasteboardType($0) == type }) else {
                return
            }
            self.emit(.Accepted, session: id, y: Int64(index))
            self.requestData(index)
        }
        provider.onPoll = { [weak self] in
            guard let self, self.offerID == id else { return }
            self.drain()
        }
        provider.onUnavailable = { [weak self] in
            guard let self, self.offerID == id else { return }
            self.failOffer(.InputOutput)
        }
        for (index, mime) in offerTypes.enumerated() {
            let type = Self.pasteboardType(mime)
            if let data = prepared[Int64(index)] {
                if mime == "text/uri-list" {
                    // Each URI is a separate native item; file promises handle remote files.
                    continue
                }
                provider.complete(type, data: data)
                item.setData(data, forType: type)
            } else {
                item.setDataProvider(provider, forTypes: [type])
            }
        }
        var items = nativeFileItems()
        guard offerID != 0 else { return }
        if !item.types.isEmpty { items.insert(NSDraggingItem(pasteboardWriter: item), at: 0) }
        guard !items.isEmpty else {
            failOffer(.Invalid)
            return
        }
        let point = surface.convert(gesture.locationInWindow, from: nil)
        let image =
            images.first ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
        for item in items { item.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image) }
        pasteboardItem = item
        dataProvider = provider
        nativeDrag = surface.beginDraggingSession(with: items, event: gesture, source: self)
    }

    private func setImage(_ index: Int) {
        let image = images.indices.contains(index) ? images[index] : nil
        nativeDrag?
            .enumerateDraggingItems(options: [], for: surface, classes: [NSPasteboardItem.self, NSURL.self], searchOptions: [:]) {
                item,
                _,
                _ in
                item.setDraggingFrame(NSRect(origin: item.draggingFrame.origin, size: image?.size ?? .zero), contents: image)
            }
    }

    private func failOffer(_ error: Ubiquitty.DragDrop.Error) {
        if offerID != 0 { emit(.Failed, session: offerID, error: error) }
        clearOffer()
    }

    private func clearOffer() {
        dataProvider?.cancel()
        dataProvider = nil
        pasteboardItem = nil
        nativeDrag = nil
        prepared.removeAll()
        streamedData.removeAll()
        receivedOfferBytes = 0
        requestedTypes.removeAll()
        pendingTypes.removeAll()
        images.removeAll()
        offerTypes.removeAll()
        offerID = 0
        gesture = nil
        didSendGesture = false
        if finishedOperation?.isEmpty != false { remoteFiles?.cancel() }
        remoteFiles = nil
        remoteRoots.removeAll()
        completedRoots.removeAll()
        finishedOperation = nil
    }

    private func nativeFileItems() -> [NSDraggingItem] {
        guard let index = offerTypes.firstIndex(of: "text/uri-list") else { return [] }
        guard let data = prepared[Int64(index)], data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            failOffer(.Invalid)
            return []
        }
        var urls: [URL] = []
        var lines = text[...]
        while !lines.isEmpty {
            let end = lines.firstIndex(of: "\n") ?? lines.endIndex
            let line = lines[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty && !line.hasPrefix("#") {
                guard urls.count < 1024, let url = URL(string: line), url.scheme != nil else {
                    failOffer(.Invalid)
                    return []
                }
                urls.append(url)
            }
            lines = end == lines.endIndex ? ""[...] : lines[lines.index(after: end)...]
        }
        // A program on a hosted pane names files on the host, not on this Mac,
        // so its URLs are fetched over the carrier and never placed on the
        // drag pasteboard as this Mac's own files — whatever machine id it
        // sent, an empty one included. Only a local pane's offer is this
        // Mac's; a surface that has gone is treated as remote, not trusted.
        let isLocalPane = surface.map { !$0.isRemoteAttached } ?? false
        let isRemote = !isLocalPane || (!offerMachine.isEmpty && offerMachine != machineID)
        if !isRemote { return urls.map { NSDraggingItem(pasteboardWriter: $0 as NSURL) } }
        let fileURLs = urls.enumerated().filter { $0.element.isFileURL }
        for (root, item) in fileURLs.enumerated() { remoteRoots[Int64(item.offset + 1)] = root + 1 }
        let id = offerID
        let receiver = DropFileReceiver(
            names: fileURLs.map { $0.element.lastPathComponent },
            onReady: { [weak self] root in
                guard let self, self.offerID == id else { return }
                self.completedRoots.insert(root)
                self.finishIfReady()
            },
            onFailure: { [weak self] in
                guard let self, self.offerID == id else { return }
                self.failOffer(.InputOutput)
            }
        )
        remoteFiles = receiver
        return urls.enumerated()
            .map { index, url in
                guard let root = remoteRoots[Int64(index + 1)] else { return NSDraggingItem(pasteboardWriter: url as NSURL) }
                let writer = DragFilePromise(receiver: receiver, root: root, name: url.lastPathComponent)
                let type = url.hasDirectoryPath ? UTType.folder : UTType.data
                let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
                provider.userInfo = writer
                return NSDraggingItem(pasteboardWriter: provider)
            }
    }

    private func requestData(_ index: Int) {
        guard requestedTypes.insert(index).inserted else { return }
        pendingTypes.insert(index)
        emit(.RequestData, session: offerID, y: Int64(index))
    }

    private func requestRemoteFiles() {
        for root in remoteRoots.keys.sorted() { emit(.RequestFile, session: offerID, x: root) }
    }

    private func receiveRemoteFile(_ command: RuntimeDrive.DragCommand) {
        guard let receiver = remoteFiles, let root = remoteRoots[command.x],
            receiver.receive(
                root: root,
                parent: command.pixelY,
                child: command.y,
                kind: command.pixelX,
                data: command.data,
                isFinal: command.isFinal
            )
        else {
            failOffer(.Invalid)
            return
        }
    }

    private func finishIfReady() {
        guard let operation = finishedOperation else { return }
        guard operation.isEmpty || (completedRoots.count == remoteRoots.count && pendingTypes.isEmpty) else { return }
        emit(.Finished, session: offerID, y: operation.isEmpty ? 1 : 0)
        clearOffer()
    }
}

extension TerminalDragDrop: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        var result: NSDragOperation = []
        if offerOperation & 1 != 0 { result.insert(.copy) }
        if offerOperation & 2 != 0 { result.insert(.move) }
        return offerID != 0 ? result : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard offerID != 0 else { return }
        emit(.Started, session: offerID)
        for (index, mime) in offerTypes.enumerated() where prepared[Int64(index)] == nil && mime != "text/uri-list" {
            requestData(index)
        }
        requestRemoteFiles()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard offerID != 0 else { return }
        emit(.OperationChanged, session: offerID, operation: operations(operation))
        if !operation.isEmpty { emit(.Dropped, session: offerID) }
        finishedOperation = operation
        finishIfReady()
    }
}

/// Data may be requested by AppKit on a pasteboard service thread.
private final class DragDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [NSPasteboard.PasteboardType: Data] = [:]
    private var isCancelled = false
    private var failedTypes = Set<NSPasteboard.PasteboardType>()
    var onRequest: (@MainActor @Sendable (NSPasteboard.PasteboardType) -> Void)?
    var onUnavailable: (@MainActor @Sendable () -> Void)?
    var onPoll: (@MainActor @Sendable () -> Void)?

    func complete(_ type: NSPasteboard.PasteboardType, data: Data) {
        condition.lock()
        values[type] = data
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ type: NSPasteboard.PasteboardType) {
        condition.lock()
        failedTypes.insert(type)
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let deadline = Date(timeIntervalSinceNow: 30)
        if Thread.isMainThread {
            MainActor.assumeIsolated { onRequest?(type) }
            while Date() < deadline {
                MainActor.assumeIsolated { onPoll?() }
                condition.lock()
                let isReady = values[type] != nil || failedTypes.contains(type) || isCancelled
                condition.unlock()
                if isReady { break }
                // AppKit requires data before returning from this callback.
                // Drain the terminal while its native tracking loop is nested.
                RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.01)))
            }
        } else {
            DispatchQueue.main.async { [self] in onRequest?(type) }
            condition.lock()
            while values[type] == nil && !failedTypes.contains(type) && !isCancelled && condition.wait(until: deadline) {}
            condition.unlock()
        }
        condition.lock()
        let data = values[type]
        let hasCancelled = isCancelled
        let hasFailed = failedTypes.contains(type)
        condition.unlock()
        if let data, !hasCancelled, !hasFailed {
            item.setData(data, forType: type)
        } else if !hasCancelled && !hasFailed {
            DispatchQueue.main.async { [self] in onUnavailable?() }
        }
    }
}
#endif
