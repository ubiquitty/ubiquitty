// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns one refresh lifetime and completes it once across success, expiration, and cancellation.
@MainActor
final class BackgroundRefreshRun {
    let isBackground: Bool
    private let cancelOperation: () -> Void
    private var completion: ((Bool) -> Void)?
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(isBackground: Bool, cancelOperation: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        self.isBackground = isBackground
        self.cancelOperation = cancelOperation
        self.completion = completion
    }

    /// Starts bounded work; the platform may expire it before the local deadline.
    func start(timeout: Duration = .seconds(20), work: @escaping @MainActor () async -> Bool) {
        guard operation == nil, completion != nil else { return }
        operation = Task { [weak self] in
            let success = await work()
            self?.finish(success: success)
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.cancel()
        }
    }

    /// Cancels the carrier before releasing the platform's background execution allowance.
    func cancel() {
        guard completion != nil else { return }
        cancelOperation()
        finish(success: false)
    }

    private func finish(success: Bool) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel()
        deadline = nil
        operation?.cancel()
        operation = nil
        completion(success)
    }
}
