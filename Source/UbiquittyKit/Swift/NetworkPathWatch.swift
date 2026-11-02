// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// Reports route and reachability changes so Core can retime reconnect attempts,
/// and what the path costs so Core can tell the host the link is metered.
///
/// Shared by both Apple shells: what counts as a move is the same question on a
/// phone and on a laptop.
@MainActor
public final class NetworkPathWatch {
    /// What a path is compared by.
    ///
    /// Interface names alone cannot tell one Wi-Fi network from the next: both
    /// are en0, and both are satisfied. The gateways can, and a tunnel the
    /// default path does not route through still carries the hosts it does, so
    /// its coming and going is a move too.
    public struct Path: Equatable {
        public let interfaces: Set<String>
        public let gateways: Set<String>
        public let isSatisfied: Bool

        public init(interfaces: Set<String>, gateways: Set<String> = [], isSatisfied: Bool) {
            self.interfaces = interfaces
            self.gateways = gateways
            self.isSatisfied = isSatisfied
        }
    }

    /// What the path costs, as `NWPath` says: the fact Core turns into
    /// `Facts.link`.
    public enum Cost: Equatable, Sendable {
        /// Nothing says the path costs anything.
        case unmetered
        /// Cellular, or a hotspot tethered over it (`isExpensive`).
        case expensive
        /// Low Data Mode is on for the path (`isConstrained`).
        case constrained

        /// Reads a path's cost. Low Data Mode is the person's own word, so it
        /// outranks what the interface is.
        ///
        /// - Parameters:
        ///   - isExpensive: `NWPath.isExpensive`.
        ///   - isConstrained: `NWPath.isConstrained`.
        public init(isExpensive: Bool, isConstrained: Bool) {
            self = isConstrained ? .constrained : isExpensive ? .expensive : .unmetered
        }
    }

    private let onMove: () -> Void
    private let onCost: (Cost) -> Void
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.ubiquitty.Ubiquitty.network-path")
    private var lastPath: Path?
    private var lastCost: Cost?
    private var isWatching = false
    private var hasStarted = false

    /// - Parameters:
    ///   - onMove: Called when the route or reachability changed after the
    ///     first observation.
    ///   - onCost: Called with the first observation's cost and whenever it
    ///     changes, a move or not.
    public init(onMove: @escaping () -> Void, onCost: @escaping (Cost) -> Void = { _ in }) {
        self.onMove = onMove
        self.onCost = onCost
    }

    /// The cost of the path last observed, or nil before the first.
    public var cost: Cost? { lastCost }

    deinit { monitor.cancel() }

    /// Begins watching once; a cancelled monitor cannot be restarted.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isWatching = true
        monitor.pathUpdateHandler = { [weak self] path in
            let observation = Path(
                interfaces: Set(
                    path.availableInterfaces.filter { path.usesInterfaceType($0.type) || $0.type == .other }.map(\.name)
                ),
                gateways: Set(path.gateways.map { String(describing: $0) }),
                isSatisfied: path.status == .satisfied
            )
            let cost = Cost(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor in self?.observe(observation, cost: cost) }
        }
        monitor.start(queue: queue)
    }

    /// Cancels monitoring and ignores callbacks already queued on the main actor.
    public func stop() {
        isWatching = false
        monitor.cancel()
    }

    private func observe(_ path: Path, cost: Cost) {
        guard isWatching else { return }
        let previous = lastPath
        lastPath = path
        // The cost first: a session the move redials greets with the new one.
        if cost != lastCost {
            lastCost = cost
            onCost(cost)
        }
        if Self.isAMove(from: previous, to: path) { onMove() }
    }

    /// Reports a route or availability change after the initial observation.
    ///
    /// - Parameters:
    ///   - previous: The last path, or nil before monitoring began.
    ///   - current: The current route and reachability.
    /// - Returns: Whether Core should reconsider its reconnect backoff.
    public static func isAMove(from previous: Path?, to current: Path) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}
