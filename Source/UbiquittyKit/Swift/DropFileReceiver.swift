// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
internal import UbiquittyCore

/// Files and pending promises are confined to the worker queue.
internal final class DropFileReceiver: @unchecked Sendable {
    private struct Promise: @unchecked Sendable {
        let root: Int
        let destination: URL
        let completion: (Error?) -> Void
    }
    private let queue = DispatchQueue(label: "app.ubiquitty.receive-drag", qos: .utility)
    private final class Storage: @unchecked Sendable {
        var files = Ubiquitty.PAL.ReceivedDropFiles(std.string())
        func clear() { files = Ubiquitty.PAL.ReceivedDropFiles(std.string()) }
    }
    private let storage = Storage()
    private var promises: [Promise] = []
    private var error: Error?
    private let capacity = NSLock()
    private var queuedBytes = 0
    private let onReady: @MainActor @Sendable (Int) -> Void
    private let onFailure: @MainActor @Sendable () -> Void
    private var ready = Set<Int>()
    private var hasCancelled = false

    init(
        names: [String],
        onReady: @escaping @MainActor @Sendable (Int) -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onReady = onReady
        self.onFailure = onFailure
        queue.async { [self] in
            storage.files = Ubiquitty.PAL.ReceivedDropFiles(std.string(FileManager.default.temporaryDirectory.path))
            for name in names {
                let result = name.withCString { storage.files.addRoot(std.string_view($0)) }
                if result != .None {
                    fail()
                    break
                }
            }
        }
    }

    deinit {
        let storage = storage
        queue.async { storage.clear() }
    }

    func cancel() {
        queue.async { [self] in
            hasCancelled = true
            fail()
            storage.clear()
        }
    }

    private func fail() {
        error = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let pending = promises
        promises.removeAll()
        for promise in pending { promise.completion(error) }
        if !hasCancelled { DispatchQueue.main.async { [self] in onFailure() } }
    }

    func receive(root: Int, parent: Int64, child: Int64, kind: Int64, data: Data, isFinal: Bool) -> Bool {
        guard root > 0, child >= 0 else { return false }
        capacity.lock()
        guard data.count <= 8 * 1024 * 1024 - queuedBytes else {
            capacity.unlock()
            return false
        }
        queuedBytes += data.count
        capacity.unlock()
        queue.async { [self] in
            defer {
                capacity.lock()
                queuedBytes -= data.count
                capacity.unlock()
            }
            guard error == nil, !hasCancelled else { return }
            let result = data.withUnsafeBytes {
                storage.files.writeEntry(
                    root,
                    parent,
                    Int(child),
                    kind,
                    Ubiquitty.PAL.DropFileBytes($0.bindMemory(to: CChar.self)),
                    isFinal ? .Complete : .More
                )
            }
            if result != .None {
                fail()
                return
            }
            if storage.files.isComplete(root), ready.insert(root).inserted {
                fulfill()
                DispatchQueue.main.async { [self] in onReady(root) }
            }
        }
        return true
    }

    func copy(root: Int, to destination: URL, completion: @escaping (Error?) -> Void) {
        let promise = Promise(root: root, destination: destination, completion: completion)
        queue.async { [self, promise] in
            if let error {
                promise.completion(error)
                return
            }
            promises.append(promise)
            fulfill()
        }
    }

    private func fulfill() {
        var pending: [Promise] = []
        for promise in promises {
            guard ready.contains(promise.root) else {
                pending.append(promise)
                continue
            }
            let path = String(storage.files.path(promise.root))
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: promise.destination)
                promise.completion(nil)
            } catch { promise.completion(error) }
        }
        promises = pending
    }
}

internal final class DragFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let receiver: DropFileReceiver
    private let root: Int
    private let name: String
    private let work = OperationQueue()

    init(receiver: DropFileReceiver, root: Int, name: String) {
        self.receiver = receiver
        self.root = root
        self.name = name
        work.maxConcurrentOperationCount = 2
        work.qualityOfService = .utility
    }

    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { work }
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        receiver.copy(root: root, to: url, completion: completionHandler)
    }
}
#endif
