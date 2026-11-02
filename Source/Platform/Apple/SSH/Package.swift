// swift-tools-version: 5.9
// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// UbiquittySSH — the in-process SSH carrier for Apple frontends.
//
// A SwiftPM package rather than a CMake target because swift-nio-ssh ships no
// CMake build; the C++ Core keeps its own CMake build and the app links both.
// Nothing here decides policy: the bootstrap command, the host characterSet, the
// host-key verdict and the QUIC bootstrap line are Core's, and reach this
// package as values.
//
// The connect runs through NIOTransportServices, which is Network.framework.
// On iOS a BSD-socket connect neither triggers VPN On Demand nor brings up a
// cellular interface, and fails at once on a path that is still coming up;
// Network.framework does both and waits for the path to become usable.
//
// The direct dependencies are exact, and Package.resolved, which is tracked,
// pins the packages they bring with them. Each pinned version has a row in
// Docs/third-party-inventory.json and third-party-notices.md, and
// Scripts/check-licenses.py holds the two together.
//
// Build with the scratch path outside Source/:
//
//   swift build --scratch-path <repo>/build/swiftpm-ssh
//   swift test --scratch-path <repo>/build/swiftpm-ssh
//
// A default in-tree .build checks out third-party sources under Source/, where
// check-boundaries.py walks every file and reads a vendored Foundation import
// as Core reaching for an Apple framework.

import PackageDescription

let package = Package(
    name: "UbiquittySSH",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UbiquittySSH", targets: ["UbiquittySSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        // The version swift-nio-ssh already resolves to; named here because the
        // key reader builds curve keys from their raw scalars itself.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "UbiquittySSH",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
                // The pipeline probe builds the connection path's handlers on
                // an EmbeddedChannel, so handler ORDER is read from a real
                // pipeline rather than asserted about the source.
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        // Signs in against scripted servers: one that drives the negotiation
        // the way NIOSSH does, and NIOSSH's own server role over a pair of
        // embedded channels, so `none` and each method cross a real wire.
        .testTarget(
            name: "UbiquittySSHTests",
            dependencies: [
                "UbiquittySSH",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ],
    // The Swift 6 language mode, which every Swift target of the apps builds
    // in. Declared here rather than passed as a compiler flag, which SwiftPM's
    // build system warns may disagree with the code it generates for each
    // target. It reaches this package's own targets and none of its
    // dependencies, which build in the modes their packages declare. SwiftPM
    // uses the newest version listed here that its compiler supports, so the
    // tools version, and with it the format of the tracked Package.resolved,
    // stays 5.9.
    swiftLanguageVersions: [.version("6")]
)
