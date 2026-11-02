// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ObjectiveC.runtime

/// Routes UI-test clipboard operations through a native, privately owned pasteboard.
///
/// Only the accessors change. Items, declared types, data providers, and ownership
/// retain AppKit's behavior without reading or rewriting the operator's clipboard.
/// An explicit marked mode leaves the accessors intact for a disposable desktop's
/// cross-process general-clipboard integration run.
@objc(UBUITestPasteboardIsolation)
public final class PasteboardIsolation: NSObject {
    private struct Hook {
        let original: Method
        let replacement: Method
        let originalImplementation: IMP
        let replacementImplementation: IMP
    }

    private struct Session {
        let pasteboard: NSPasteboard
        let hooks: [Hook]
        let usesRealGeneralPasteboard: Bool
        var finished = false
    }

    // Accessors can be reached from Objective-C without Swift actor checking.
    // The lock protects the routing state; native pasteboard operations retain
    // the caller's existing threading contract.
    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var session: Session?
        var failure = ""
    }

    private static let state = State()

    /// Describes why the latest installation or restoration was refused.
    @objc
    public static var failureDescription: String {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.failure
    }

    /// Reports whether this marked test process is using the system-wide board.
    @objc
    public static var usesRealGeneralPasteboard: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.session?.usesRealGeneralPasteboard == true
    }

    /// Installs routing before the UI-test runner creates the application.
    ///
    /// A missing selector refuses the run before any implementation is exchanged.
    /// Ordinary app execution never installs this test-only interception.
    @objc
    public static func install() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.failure = ""
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ui-test") else {
            state.failure = "the process is not running UI tests"
            return false
        }
        if let session = state.session {
            guard !session.finished,
                session.usesRealGeneralPasteboard || ownsImplementations(session.hooks)
            else {
                state.failure = "clipboard routing no longer owns its active implementations"
                return false
            }
            return true
        }

        if process.arguments.contains("--ui-test-real-general-pasteboard") {
            guard process.environment["UBIQUITTY_DISPOSABLE_GUI_SESSION"] == "ubiquitty-pasteboard-integration-v1" else {
                state.failure = "real general-pasteboard tests require a marked disposable GUI session"
                return false
            }
            state.session = Session(pasteboard: .general, hooks: [], usesRealGeneralPasteboard: true)
            return true
        }

        let selectors = [
            ("generalPasteboard", "uiTestGeneralPasteboard"),
            ("pasteboardWithName:", "uiTestPasteboardWithName:"),
        ]
        var hooks: [Hook] = []
        for (originalName, replacementName) in selectors {
            guard let original = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(originalName)),
                let replacement = class_getClassMethod(NSPasteboard.self, NSSelectorFromString(replacementName))
            else {
                state.failure = "required clipboard selector is unavailable: \(originalName) / \(replacementName)"
                return false
            }
            hooks.append(
                Hook(
                    original: original,
                    replacement: replacement,
                    originalImplementation: method_getImplementation(original),
                    replacementImplementation: method_getImplementation(replacement)
                )
            )
        }

        let pasteboard = NSPasteboard.withUniqueName()
        state.session = Session(pasteboard: pasteboard, hooks: hooks, usesRealGeneralPasteboard: false)
        for hook in hooks {
            method_exchangeImplementations(hook.original, hook.replacement)
        }
        guard ownsImplementations(hooks) else {
            for hook in hooks.reversed() {
                method_setImplementation(hook.original, hook.originalImplementation)
                method_setImplementation(hook.replacement, hook.replacementImplementation)
            }
            state.session = nil
            pasteboard.releaseGlobally()
            state.failure = "clipboard accessor installation could not be verified"
            return false
        }
        return true
    }

    /// Starts the next scenario with an empty private clipboard.
    @objc
    public static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let session = state.session, !session.finished else {
            preconditionFailure("UI-test clipboard isolation is not active")
        }
        session.pasteboard.clearContents()
    }

    /// Releases test data while keeping late callbacks away from the operator.
    ///
    /// The runner exits immediately afterward. It does not restore the accessors:
    /// closing windows does not establish that every clipboard producer has joined.
    @objc
    public static func finish() {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard var session = state.session, !session.finished else { return }
        session.finished = true
        state.session = session
        session.pasteboard.clearContents()
        if !session.usesRealGeneralPasteboard {
            session.pasteboard.releaseGlobally()
        }
    }

    /// Restores the exact implementations after all test-owned callers are quiescent.
    ///
    /// The standalone contract driver owns that lifetime. The app runner keeps
    /// its routing through process exit instead of reopening the global clipboard.
    @discardableResult
    static func restoreAfterQuiescence() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let session = state.session else { return true }
        guard session.usesRealGeneralPasteboard || ownsImplementations(session.hooks) else {
            state.failure = "clipboard routing no longer owns the implementations to restore"
            return false
        }
        if !session.usesRealGeneralPasteboard {
            for hook in session.hooks.reversed() {
                method_exchangeImplementations(hook.original, hook.replacement)
            }
        }
        state.session = nil
        if !session.finished {
            session.pasteboard.clearContents()
            if !session.usesRealGeneralPasteboard {
                session.pasteboard.releaseGlobally()
            }
        }
        return true
    }

    private static func ownsImplementations(_ hooks: [Hook]) -> Bool {
        hooks.allSatisfy { hook in
            implementationAddress(method_getImplementation(hook.original)) == implementationAddress(hook.replacementImplementation)
                && implementationAddress(method_getImplementation(hook.replacement)) == implementationAddress(hook.originalImplementation)
        }
    }

    private static func implementationAddress(_ implementation: IMP) -> UInt {
        unsafeBitCast(implementation, to: UInt.self)
    }

    fileprivate static func privatePasteboard() -> NSPasteboard {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let session = state.session else {
            preconditionFailure("A clipboard interception has no owning test session")
        }
        return session.pasteboard
    }
}

extension NSPasteboard {
    @objc
    dynamic class func uiTestGeneralPasteboard() -> NSPasteboard {
        PasteboardIsolation.privatePasteboard()
    }

    @objc(uiTestPasteboardWithName:)
    dynamic class func uiTestPasteboard(withName name: NSPasteboard.Name) -> NSPasteboard {
        if name == .general {
            return PasteboardIsolation.privatePasteboard()
        }
        // Objective-C dispatch reaches the original implementation after exchange.
        return uiTestPasteboard(withName: name)
    }
}
