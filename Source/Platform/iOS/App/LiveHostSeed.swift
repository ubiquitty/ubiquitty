// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LiveHostSeed.swift — writes one QUIC-preferring host from the launch
// environment, for the automated live-QUIC lane.
//
// The lane's contract is the CARRIER: a real QUIC session, driven. Reaching it
// through the host editor would first spend the run typing a 555-character PEM
// through the simulator keyboard and flicking a switch that lives below the
// fold — two fragile steps that prove the editor, which its own cases already
// cover, and not the carrier this lane exists for. So the lane hands the host
// in through the same store the editor writes to, and the record it seeds is
// the editor's own value type: the attach, the transport, and every byte the
// session carries still go through the real stack.
//
// Gated on both a launch argument and a full set of environment variables, so a
// build a person launches by hand seeds nothing. The lane sets both.

import Foundation

/// Seeds the live-QUIC host when the launch arguments ask for it.
enum LiveHostSeed {
    /// The host name the lane opens; shared with the UI test so the two agree.
    static let name = "ui-live-quic"

    /// The record's fixed identifier, so the lane can name it to
    /// `UBIQUITTY_IOS_OPEN_HOST` and have the app open it on launch without a
    /// row tap that races the list settling. The UI test carries the same
    /// string; the two are kept in step by hand, the way the host name is.
    static let identifier = UUID(uuidString: "00000000-0000-0000-0000-0000000C0DEC")!

    /// Writes the host and its key when `--seed-live-host` is passed with a
    /// complete `UBQ_LIVE_SSH_*` environment. `UBQ_LIVE_SSH_PORT` is optional
    /// and defaults to 22. `UBQ_LIVE_WORKSPACE`, when set, names the workspace
    /// the host attaches to, so a lane can join one it started; set empty, it
    /// clears the name, and unset, it leaves the stored record's name alone.
    ///
    /// Runs before the host list loads its store, so the seeded record is
    /// there when the list first reads the file.
    @MainActor
    static func seedIfRequested() {
        guard CommandLine.arguments.contains("--seed-live-host") else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["UBQ_LIVE_SSH_HOST"], !host.isEmpty,
            let user = environment["UBQ_LIVE_SSH_USER"], !user.isEmpty,
            let key = environment["UBQ_LIVE_SSH_KEY"], !key.isEmpty
        else {
            return
        }
        let store = HostStore.shared
        // Named so the UI test's row query finds it, and kept apart from any
        // host a person running the simulator has saved. A prior seed of the
        // same name is replaced rather than duplicated: the lane reinstalls a
        // clean app, but a store shared with a hand-run build should not grow
        // a row per launch.
        var record =
            store.hosts.first { $0.id == identifier }
            ?? HostRecord(id: identifier, name: name)
        record.hostName = host
        // The port is optional so the lane can reach an sshd of its own: a
        // throwaway daemon behind a private sshd keeps the run away from the
        // daemon a person's own sessions live in.
        record.port = environment["UBQ_LIVE_SSH_PORT"].flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22
        record.username = user
        record.authenticationKind = .privateKey
        record.prefersQUIC = true
        if let workspaceName = environment["UBQ_LIVE_WORKSPACE"] {
            record.workspaceName = workspaceName
        }
        store.save(record)
        SecretStore.save(key, for: record.id)
    }
}
