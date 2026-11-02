// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyKit

/// Covers route changes, connectivity returning on the same interface, and a
/// move between two networks on the same interface.
enum NetworkPathSmokeEntry {
    @MainActor
    static func run() -> Bool {
        typealias Path = NetworkPathWatch.Path
        let wifi = Path(interfaces: ["en0"], isSatisfied: true)
        let offlineWifi = Path(interfaces: ["en0"], isSatisfied: false)
        let cellular = Path(interfaces: ["pdp_ip0"], isSatisfied: true)
        let tunnel = Path(interfaces: ["en0", "utun0"], isSatisfied: true)
        let unavailable = Path(interfaces: [], isSatisfied: false)
        let homeWifi = Path(interfaces: ["en0"], gateways: ["192.168.1.1"], isSatisfied: true)
        let officeWifi = Path(interfaces: ["en0"], gateways: ["10.20.0.1"], isSatisfied: true)
        let cases: [(String, Path?, Path, Bool)] = [
            ("initial path", nil, wifi, false),
            ("initial unavailable path", nil, unavailable, false),
            ("unchanged route", wifi, wifi, false),
            ("Wi-Fi to cellular", wifi, cellular, true),
            ("tunnel becomes active", wifi, tunnel, true),
            ("all interfaces disappear", wifi, unavailable, true),
            ("connectivity lost on the same interface", wifi, offlineWifi, true),
            ("connectivity returns on the same interface", offlineWifi, wifi, true),
            ("unchanged unavailable route", offlineWifi, offlineWifi, false),
            ("one Wi-Fi network to another on the same interface", homeWifi, officeWifi, true),
            ("unchanged gateway", homeWifi, homeWifi, false),
        ]
        var failures = 0
        for (name, previous, current, expected) in cases where NetworkPathWatch.isAMove(from: previous, to: current) != expected {
            failures += 1
            SmokeLaunch.report("network-path: FAIL: \(name)")
        }
        SmokeLaunch.report("network-path: \(cases.count - failures)/\(cases.count) checks held")
        return failures == 0
    }
}
