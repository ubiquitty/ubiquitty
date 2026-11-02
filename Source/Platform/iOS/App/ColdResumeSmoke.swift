// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if UBIQUITTY_IOS_UI_TESTS
import Foundation
import Security
import UbiquittyCore
import UbiquittyRenderKit
import UbiquittySSH

/// Real protected platform storage and owner replacement, using only a fresh
/// test host UUID and in-process fixture. It never dials an address.
enum ColdResumeSmoke {
    private enum ProcessPhase: String { case write, read }

    @MainActor
    static func run() async -> Bool {
        let hasHistory = ProcessInfo.processInfo.arguments.contains("--cold-resume-history")
        _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, hasHistory))
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--cold-resume-phase") {
            guard index + 2 < arguments.count, let phase = ProcessPhase(rawValue: arguments[index + 1]),
                let hostID = UUID(uuidString: arguments[index + 2])
            else { return fail("process fixture arguments") }
            return runAcrossProcess(phase: phase, hostID: hostID)
        }
        let host = HostRecord(
            hostName: "cold-smoke.invalid",
            username: "fixture",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            prefersQUIC: true,
            workspaceName: "cold-fixture"
        )
        let secret = "fixture-\(UUID().uuidString)"
        defer { SecretStore.remove(for: host.id) }
        guard SecretStore.save(secret, for: host.id) else { return fail("credential") }
        do {
            var first = try ColdResumeSession.prepare(host: host, secret: secret, workspace: host.workspaceName, stop: { _ in })
            guard let owner = first else { return fail("first owner") }
            let identity = owner.descriptor.clientID
            owner.noteBootstrap(
                .ready(port: 443, token: [1], certificateSHA256: [7] + Array(repeating: 0, count: 31), reachedAddress: "192.0.2.7"),
                fingerprint: host.pinnedHostKeyFingerprint
            )
            if let refusal = owner.populateForTesting() { return fail("protected durable fixture commit (\(refusal))") }
            owner.abandonPreparation()
            first = nil
            // The abandoned object may still be held by this local binding,
            // but it owns no store. A new process has no such local binding.
            guard try checkReplacement(host: host, secret: secret, identity: identity) else { return false }
            guard try await checkRefusedRetirement(host: host, secret: secret) else { return false }
            return try checkHistoryPolicy()
        } catch { return fail("protected preparation \(error)") }
    }

    /// The write process exits with no live owner. The read process has no
    /// path that populates a fixture or reconstructs its secret from arguments.
    @MainActor
    private static func runAcrossProcess(phase: ProcessPhase, hostID: UUID) -> Bool {
        let host = HostRecord(
            id: hostID,
            hostName: "cold-process.invalid",
            username: "fixture",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            prefersQUIC: true,
            workspaceName: "cold-process-fixture"
        )
        do {
            switch phase {
            case .write:
                guard case .missing = ColdResumeDescriptors().read(hostID), SecretStore.secret(for: hostID) == nil else {
                    return fail("process fixture already exists")
                }
                let secret = "fixture-\(UUID().uuidString)"
                guard SecretStore.save(secret, for: hostID),
                    let owner = try ColdResumeSession.prepare(host: host, secret: secret, workspace: host.workspaceName, stop: { _ in })
                else { return fail("process write owner") }
                owner.noteBootstrap(
                    .ready(port: 443, token: [1], certificateSHA256: [7] + Array(repeating: 0, count: 31), reachedAddress: "192.0.2.7"),
                    fingerprint: host.pinnedHostKeyFingerprint
                )
                if let refusal = owner.populateForTesting() { return fail("process durable fixture commit (\(refusal))") }
                let identity = owner.descriptor.clientID
                owner.abandonPreparation()
                SmokeLaunch.report("cold-resume: process write client=\(identity.uuidString) PASS")
                return true
            case .read:
                defer { SecretStore.remove(for: hostID) }
                guard let secret = SecretStore.secret(for: hostID),
                    case .value(let descriptor) = ColdResumeDescriptors().read(hostID), descriptor.state == .ready,
                    let index = CommandLine.arguments.firstIndex(of: "--cold-resume-client"), index + 1 < CommandLine.arguments.count,
                    UUID(uuidString: CommandLine.arguments[index + 1]) == descriptor.clientID
                else { return fail("process protected identity") }
                guard try checkReplacement(host: host, secret: secret, identity: descriptor.clientID) else { return false }
                SmokeLaunch.report("cold-resume: process read client=\(descriptor.clientID.uuidString) PASS")
                return true
            }
        } catch { return fail("process protected preparation \(error)") }
    }

    @MainActor
    private static func checkReplacement(host: HostRecord, secret: String, identity: UUID) throws -> Bool {
        let model = TerminalSessionModel()
        guard
            let restored = try ColdResumeSession.prepare(
                host: host,
                secret: secret,
                workspace: host.workspaceName,
                stop: { [weak model] owner in model?.retireColdResume(owner) }
            ),
            restored.descriptor.clientID == identity, restored.isRestoredForTesting,
            let surface = model.surfaceForDrawing()
        else { return fail("cold identity/picture") }
        let drive = surface.drive
        defer {
            model.disconnect()
            drive.close()
            restored.abandonPreparation()
        }
        guard model.installColdResume(restored) else { return fail("owner transfer") }
        drive.lockForRead()
        let term = drive.borrowTerminal()
        let isPicture =
            term.map { $0.rows == 4 && $0.columns == 24 && Ubiquitty.Screen.visibleCell($0, 0, 0, 0)?.pointee.codePoint == 112 } ?? false
        let isHistory =
            term.map {
                Ubiquitty.Screen.scrollbackCount($0) == (restored.descriptor.target.shouldPersistHistory == true ? 3 : 0)
            } ?? false
        drive.unlockForRead()
        guard isPicture && isHistory else { return fail("surface picture/history before network") }
        guard ColdResumeSession.retireBeforeEdit(host.id),
            case .value(let retired) = ColdResumeDescriptors().read(host.id), retired.state == .retirementRequired
        else { return fail("durable retirement") }
        guard surface.isHidden, drive.borrowTerminal() == nil, model.surfaceForDrawing() !== surface else {
            return fail("retired local view")
        }
        SmokeLaunch.report("cold-resume: protected descriptor + sealed picture + new owner + pre-network surface + retirement PASS")
        return true
    }

    @MainActor
    private static func checkRefusedRetirement(host: HostRecord, secret: String) async throws -> Bool {
        let model = TerminalSessionModel()
        defer { model.disconnect() }
        func prepare() throws -> ColdResumeSession? {
            try ColdResumeSession.prepare(
                host: host,
                secret: secret,
                workspace: host.workspaceName,
                stop: { [weak model] owner in model?.retireColdResume(owner) }
            )
        }
        guard let refused = try prepare(), model.installColdResume(refused), let old = model.surfaceForDrawing() else {
            return fail("refusal owner")
        }
        refused.refuseRetirementForTesting()
        guard refused.isLocallyDenied, !old.isHidden, old.drive.borrowTerminal() != nil,
            case .value(let denied) = ColdResumeDescriptors().read(host.id), denied.state == .retirementRequired
        else { return fail("synchronous refusal without reentrant teardown") }
        for _ in 0..<8 { await Task.yield() }
        guard old.isHidden, old.drive.borrowTerminal() == nil else { return fail("deferred refused view retirement") }

        // A second refused owner is replaced before its queued UI callback.
        // That callback must not retarget the replacement's surface.
        guard let superseded = try prepare(), model.installColdResume(superseded) else { return fail("superseded owner") }
        superseded.refuseRetirementForTesting()
        model.disconnect()
        guard let current = try prepare(), model.installColdResume(current), let visible = model.surfaceForDrawing() else {
            return fail("replacement owner")
        }
        for _ in 0..<8 { await Task.yield() }
        guard !visible.isHidden, visible.drive.borrowTerminal() != nil, model.surfaceForDrawing() === visible else {
            return fail("stale retirement callback")
        }
        SmokeLaunch.report("cold-resume: refused retirement is non-reentrant and cannot hide a replacement PASS")
        return true
    }

    @MainActor
    private static func checkHistoryPolicy() throws -> Bool {
        let originalPolicy = Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory()
        _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, true))
        defer {
            _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, originalPolicy))
        }
        let identifiers = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let hosts = identifiers.map {
            HostRecord(
                id: $0,
                hostName: "cold-policy.invalid",
                username: "fixture",
                pinnedHostKeyFingerprint: "SHA256:fixture",
                prefersQUIC: true,
                workspaceName: "cold-policy-fixture"
            )
        }
        let secret = "fixture-\(UUID().uuidString)"
        defer { for host in hosts { SecretStore.remove(for: host.id) } }
        var stopped: [UUID] = []
        var owners: [ColdResumeSession] = []
        defer { for owner in owners { owner.abandonPreparation() } }
        for host in hosts {
            guard SecretStore.save(secret, for: host.id),
                let owner = try ColdResumeSession.prepare(
                    host: host,
                    secret: secret,
                    workspace: host.workspaceName,
                    stop: {
                        stopped.append($0.descriptor.target.hostID)
                    }
                )
            else { return fail("history policy owner") }
            owner.noteBootstrap(
                .ready(port: 443, token: [1], certificateSHA256: [7] + Array(repeating: 0, count: 31), reachedAddress: "192.0.2.7"),
                fingerprint: host.pinnedHostKeyFingerprint
            )
            if let refusal = owner.populateForTesting() { return fail("history policy commit (\(refusal))") }
            owners.append(owner)
        }
        let firstIdentity = owners[0].descriptor.clientID
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let oldPath = support.appendingPathComponent("ColdResume").appendingPathComponent(firstIdentity.uuidString)
            .appendingPathExtension("sealed")
        let copiedCiphertext = try Data(contentsOf: oldPath)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.Ubiquitty.cold-resume-descriptor.v1",
            kSecAttrAccount as String: hosts[1].id.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
        let originalDescriptor = try JSONEncoder().encode(owners[1].descriptor)
        defer { _ = SecItemUpdate(query as CFDictionary, [kSecValueData as String: originalDescriptor] as CFDictionary) }
        guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data([0])] as CFDictionary) == errSecSuccess else {
            return fail("history policy refusal setup")
        }
        guard !ColdResumeSession.setHistoryPersistence(false), Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory(),
            stopped == [hosts[0].id], case .value(let retired) = ColdResumeDescriptors().read(hosts[0].id),
            retired.state == .retirementRequired
        else { return fail("partial history retirement preserves setting and committed denial") }
        guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: originalDescriptor] as CFDictionary) == errSecSuccess,
            ColdResumeSession.retireBeforeEdit(hosts[1].id)
        else { return fail("history policy refusal recovery") }
        try copiedCiphertext.write(to: oldPath, options: [.atomic, .completeFileProtection])
        _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, false))
        guard
            let optedOut = try ColdResumeSession.prepare(host: hosts[0], secret: secret, workspace: hosts[0].workspaceName, stop: { _ in }),
            optedOut.descriptor.clientID != firstIdentity, !optedOut.isRestoredForTesting
        else { return fail("opt-out refuses copied history ciphertext") }
        optedOut.abandonPreparation()

        _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, true))
        let model = TerminalSessionModel()
        defer { model.disconnect() }
        guard
            let live = try ColdResumeSession.prepare(
                host: hosts[0],
                secret: secret,
                workspace: hosts[0].workspaceName,
                stop: { [weak model] in model?.retireColdResume($0) }
            ), let surface = model.surfaceForDrawing(), model.installColdResume(live)
        else { return fail("live history policy owner") }
        _ = Ubiquitty.Preferences.configureKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, false))
        guard surface.isHidden, surface.drive.borrowTerminal() == nil,
            case .value(let denied) = ColdResumeDescriptors().read(hosts[0].id), denied.state == .retirementRequired
        else { return fail("external history policy reload retires live view") }
        SmokeLaunch.report("cold-resume: partial retirement + opt-out ciphertext refusal + live configuration reload PASS")
        return true
    }

    private static func fail(_ stage: String) -> Bool {
        SmokeLaunch.report("cold-resume: \(stage) FAIL")
        return false
    }
}
#endif
