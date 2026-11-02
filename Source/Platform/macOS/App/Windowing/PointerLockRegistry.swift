// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// PointerLockRegistry.swift — every surface in the process that can hold the
// OS cursor grab.
//
// The grab is process-global: one hide counter, one dissociation, one cursor.
// A surface can reconcile its own, and does on every focus and window edge,
// but the cases that strand a pointer are the ones where no surface is asked
// — the app quits without a pane's teardown running, or a lock-holding pane
// sits behind and never sees a resign-key. Both shells report here, the app
// delegate reports its transitions here, and what a transition costs the
// grabs is `Input::pointerLockSweep`.
//
// Held weakly, so a closed pane falls out by itself.
//
import AppKit
internal import UbiquittyCore

/// A surface that can hold the OS cursor grab.
///
/// Two methods rather than one because the sweep distinguishes them: a release
/// needs no answer from the surface, while a reconcile asks it whether it
/// still wants the grab.
@MainActor
@objc(UBPointerLockHolder)
public protocol PointerLockHolder: AnyObject {
    /// Releases the grab if this surface holds one.
    @objc
    func releasePointerLockGrab()

    /// Re-asks whether this surface should hold the grab, and acts on it.
    @objc
    func reconcilePointerLockGrab()
}

/// The surfaces that can hold the OS cursor grab.
@MainActor
@objc(UBPointerLockRegistry)
public final class PointerLockRegistry: NSObject {
    /// The one registry.
    @objc
    public static let shared = PointerLockRegistry()

    private let holders = NSHashTable<AnyObject>.weakObjects()

    /// How many surfaces could be holding a grab.
    ///
    /// The table is weak, so this falls as panes close without anyone saying
    /// so — which is the property a caller wants to know is still true.
    package var registeredHolderCount: Int {
        holders.allObjects.count
    }

    /// Adds a surface. Registering twice is the same as registering once.
    ///
    /// - Parameter holder: The surface, held weakly.
    @objc
    public func add(_ holder: PointerLockHolder) {
        holders.add(holder)
    }

    /// Applies what an application transition asks of every grab.
    ///
    /// The mapping is Core's, so the two shells cannot disagree about whether
    /// leaving the foreground releases or merely reconciles.
    ///
    /// - Parameter event: The transition, as the app delegate saw it.
    // Package rather than public: the module interface cannot name a C++
    // enum; Objective-C callers reach this through applyRawEvent.
    package func apply(_ event: Ubiquitty.Input.AppLifecycle) {
        let sweep = Ubiquitty.Input.pointerLockSweep(event)
        for holder in holders.allObjects.compactMap({ $0 as? PointerLockHolder }) {
            switch sweep {
            case .releaseEveryGrab:
                holder.releasePointerLockGrab()
            case .reconcileEveryGrab:
                holder.reconcilePointerLockGrab()
            @unknown default:
                holder.releasePointerLockGrab()
            }
        }
    }

    /// Applies the transition named by its raw value, for a caller that has
    /// no way to name a C++ enumerator.
    ///
    /// Objective-C cannot carry `Ubiquitty::Input::AppLifecycle` across the
    /// generated header, and a second spelling of the three transitions would
    /// be a second place for them to drift. The raw value is the one they
    /// already share.
    ///
    /// - Parameter rawEvent: The transition's raw value; an unknown one is
    ///   treated as a release, which is the answer that strands nothing.
    @objc
    public func applyRawEvent(_ rawEvent: UInt8) {
        apply(Ubiquitty.Input.AppLifecycle(rawValue: rawEvent) ?? .terminating)
    }
}
