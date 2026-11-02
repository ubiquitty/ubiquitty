// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
internal import UbiquittyCore

/// The queue owns descriptors; the lock protects cancellation across callers.
internal final class DropFileWorker: @unchecked Sendable {
    internal struct Chunk: Sendable {
        let data: Data
        let kind: Int64
        let error: UInt8
        let isComplete: Bool
    }

    private let queue = DispatchQueue(label: "app.ubiquitty.drag-files", qos: .utility)
    private let cancellation = NSLock()
    private var isCancelled = false
    private let capacity = DispatchSemaphore(value: 1)
    private var files = Ubiquitty.PAL.DropFiles()
    private var error: UInt8 = 0

    internal init(paths: [String]) {
        queue.async { [self] in
            for path in paths {
                let result = path.withCString { files.addPath(std.string_view($0)) }
                if result != .None {
                    error = result.rawValue
                    break
                }
            }
        }
    }

    internal func cancel() {
        cancellation.lock()
        isCancelled = true
        cancellation.unlock()
        capacity.signal()
        queue.async { [self] in files = Ubiquitty.PAL.DropFiles() }
    }

    private var shouldStop: Bool {
        cancellation.lock()
        defer { cancellation.unlock() }
        return isCancelled
    }

    internal func closeDirectory(_ handle: Int64) {
        queue.async { [self] in files.closeDirectory(handle) }
    }

    internal func read(
        root: Int,
        directory: Int64,
        child: Int,
        deliver: @escaping @MainActor @Sendable (Chunk, @escaping @Sendable () -> Void) -> Void
    ) {
        queue.async { [self] in
            guard !shouldStop else { return }
            let request = directory == 0 ? files.readRoot(root) : files.readChild(directory, child)
            let failure = error != 0 ? error : request.error.rawValue
            if failure != 0 {
                let result = Chunk(data: Data(), kind: 0, error: failure, isComplete: true)
                DispatchQueue.main.async { deliver(result, {}) }
                return
            }
            var bytes = [CChar](repeating: 0, count: 3072)
            while !shouldStop {
                capacity.wait()
                guard !shouldStop else {
                    capacity.signal()
                    return
                }
                let part = bytes.withUnsafeMutableBufferPointer { files.read(request.token, Ubiquitty.PAL.DropFileBuffer($0)) }
                let data = bytes.withUnsafeBytes { Data($0.prefix(part.size)) }
                let result = Chunk(data: data, kind: request.kind, error: part.error.rawValue, isComplete: part.isComplete)
                DispatchQueue.main.async { [self] in
                    if shouldStop {
                        capacity.signal()
                    } else {
                        deliver(result) { [self] in capacity.signal() }
                    }
                }
                if part.isComplete || part.error != .None { return }
            }
        }
    }
}
