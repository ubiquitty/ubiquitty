// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyRenderKit
import UbiquittySSH

extension ColdResumeTarget {
    init?(host: HostRecord, secret: String, workspace: String) {
        guard host.prefersQUIC, host.canOfferSavedCredential,
            !host.username.isEmpty, !host.pinnedHostKeyFingerprint.isEmpty,
            !secret.isEmpty, !workspace.isEmpty, workspace == host.workspaceName,
            workspace.utf8.count <= 4096, host.isComplete
        else { return nil }
        var credential = Data("ubiquitty-resume-credential-v1\0".utf8)
        credential.append(contentsOf: host.authenticationIdentity.utf8)
        credential.append(0)
        credential.append(contentsOf: secret.utf8)
        self.init(
            hostID: host.id,
            endpoint: host.hostName,
            port: host.port,
            username: host.username,
            authentication: host.authenticationIdentity,
            credentialDigest: Data(SHA256.hash(data: credential)),
            hostKeyFingerprint: host.pinnedHostKeyFingerprint,
            workspace: workspace,
            shouldPersistHistory: Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory() ? true : nil
        )
    }

    /// Compares only fields whose edits must retire a cached authorization.
    func matchesConfiguration(_ host: HostRecord) -> Bool {
        hostID == host.id && endpoint == host.hostName && port == host.port
            && username == host.username && authentication == host.authenticationIdentity
            && hostKeyFingerprint == host.pinnedHostKeyFingerprint && workspace == host.workspaceName && host.prefersQUIC
    }
}

/// Owns one saved workspace's protected metadata while Core owns its store.
/// Every callback is synchronous on the session thread. Revocation is performed
/// by the settings owner, never from a storage callback into the attachment.
@MainActor
final class ColdResumeSession {
    enum Failure: Error { case protectedStorageUnavailable, ownerAlreadyOpen, preparationRefused }
    private final class WeakOwner {
        weak var value: ColdResumeSession?
        init(_ value: ColdResumeSession) { self.value = value }
    }
    private static var owners: [UUID: WeakOwner] = [:]
    private let descriptors: ColdResumeDescriptors
    private(set) var descriptor: ColdResumeDescriptor
    private var owner: OpaquePointer?
    private var stop: ((ColdResumeSession) -> Void)?
    private(set) var isLocallyDenied = false
    private var reach: (address: String, port: UInt16, pin: Data)?
    private let recordPath: String

    private init(
        _ descriptor: ColdResumeDescriptor,
        directory: URL,
        descriptors: ColdResumeDescriptors,
        stop: @escaping (ColdResumeSession) -> Void
    ) {
        self.descriptor = descriptor
        self.descriptors = descriptors
        self.stop = stop
        recordPath = directory.appendingPathComponent(descriptor.clientID.uuidString).appendingPathExtension("sealed").path
        if let peer = descriptor.peer { reach = (peer.address, peer.port, peer.certificatePin) }
    }

    /// Opens only explicitly pinned, saved-credential named workspaces.
    /// Refused protected access is an error, not a request for an unprotected attach.
    static func prepare(
        host: HostRecord,
        secret: String,
        workspace: String,
        stop: @escaping (ColdResumeSession) -> Void
    ) throws -> ColdResumeSession? {
        guard let target = ColdResumeTarget(host: host, secret: secret, workspace: workspace) else { return nil }
        guard SecretStore.secret(for: host.id) == secret else { throw Failure.protectedStorageUnavailable }
        if owners[host.id]?.value != nil { throw Failure.ownerAlreadyOpen }
        let descriptors = ColdResumeDescriptors()
        let directory = try privateDirectory()
        let descriptor: ColdResumeDescriptor
        switch descriptors.read(host.id) {
        case .refused: throw Failure.protectedStorageUnavailable
        case .missing:
            descriptor = ColdResumeDescriptor(target: target)
            guard descriptors.write(descriptor) else { throw Failure.protectedStorageUnavailable }
        case .value(let previous):
            if previous.target == target && previous.state == .ready {
                descriptor = previous
            } else {
                guard descriptors.requireRetirement(host.id), retire(previous, directory: directory) else {
                    throw Failure.protectedStorageUnavailable
                }
                descriptor = ColdResumeDescriptor(target: target)
                guard descriptors.write(descriptor) else { throw Failure.protectedStorageUnavailable }
            }
        }
        let context = ColdResumeSession(descriptor, directory: directory, descriptors: descriptors, stop: stop)
        let retained = Unmanaged.passRetained(context).toOpaque()
        let hooks = UbiquittyIOSResumeHooks(
            context: retained,
            mayUse: { pointer in
                guard let pointer else { return false }
                return MainActor.assumeIsolated {
                    Unmanaged<ColdResumeSession>.fromOpaque(pointer).takeUnretainedValue().mayUse()
                }
            },
            bind: { pointer, low, high, principal, length, pin, pinLength in
                guard let pointer, let principal, let pin, length <= 4096, pinLength == 32,
                    let identity = String(data: Data(bytes: principal, count: Int(length)), encoding: .utf8)
                else { return false }
                return MainActor.assumeIsolated {
                    Unmanaged<ColdResumeSession>.fromOpaque(pointer).takeUnretainedValue()
                        .bind(hostLow: low, hostHigh: high, principal: identity, pin: Data(bytes: pin, count: 32))
                }
            },
            retirementRefused: { pointer in
                guard let pointer else { return }
                MainActor.assumeIsolated {
                    Unmanaged<ColdResumeSession>.fromOpaque(pointer).takeUnretainedValue().retirementRefused()
                }
            },
            release: { pointer in
                guard let pointer else { return }
                MainActor.assumeIsolated {
                    let retained = Unmanaged<ColdResumeSession>.fromOpaque(pointer)
                    retained.takeUnretainedValue().storeDidRelease()
                    retained.release()
                }
            }
        )
        context.owner = withIdentity(descriptor) { identity in
            context.recordPath.withCString { ubiquittyIOSResumeCreate($0, identity, hooks) }
        }
        guard context.owner != nil else {
            Unmanaged<ColdResumeSession>.fromOpaque(retained).release()
            throw Failure.preparationRefused
        }
        owners[host.id] = WeakOwner(context)
        return context
    }

    /// Transfers the already-restored owner exactly once and draws before dial.
    func install(on drive: RuntimeDrive) -> Bool {
        guard let owner else { return false }
        guard
            drive.prepareRemoteResume(
                ownerAddress: ubiquittyIOSResumeCoreAddress(owner),
                paneLow: ubiquittyIOSResumePreviewLow(owner),
                paneHigh: ubiquittyIOSResumePreviewHigh(owner)
            )
        else { return false }
        self.owner = nil
        ubiquittyIOSResumeDestroy(owner)
        return true
    }

    /// Releases only an unused owner. A transferred store lives with Core.
    func abandonPreparation() {
        if let owner {
            self.owner = nil
            ubiquittyIOSResumeDestroy(owner)
        }
        stop = nil
    }

    /// A local Swift reference does not keep a retired Core owner registered.
    /// Conversely, installing the store must retain its exclusive owner until
    /// Core releases it, even if the presentation has already disappeared.
    private func storeDidRelease() {
        if Self.owners[descriptor.target.hostID]?.value === self {
            Self.owners.removeValue(forKey: descriptor.target.hostID)
        }
        stop = nil
    }

    #if UBIQUITTY_IOS_UI_TESTS
    /// Nil when the fixture committed; otherwise the step that refused.
    func populateForTesting() -> String? {
        guard let owner else { return "no prepared owner" }
        return ubiquittyIOSResumePopulateForTest(owner).map { String(cString: $0) }
    }
    var isRestoredForTesting: Bool { owner.map { ubiquittyIOSResumeRestoredForTest($0) } ?? false }
    func refuseRetirementForTesting() { retirementRefused() }
    #endif

    /// Seeds a proof dial from metadata authenticated on the preceding launch.
    func seed(_ factory: OpaquePointer) -> Bool {
        guard let peer = descriptor.peer else { return true }
        if let socketName = peer.daemonSocketName,
            !socketName.withCString({ ubiquittyIOSQUICFactoryPinDaemonOwner(factory, $0) })
        {
            return false
        }
        return peer.certificatePin.withUnsafeBytes { pin in
            peer.address.withCString {
                ubiquittyIOSQUICFactorySeedResume(factory, $0, peer.port, pin.bindMemory(to: UInt8.self).baseAddress, pin.count)
            }
        }
    }

    /// Called only for a connected session, after Welcome bound the protected
    /// peer. A directory row or a bootstrap alone cannot replace this owner.
    func noteConnectedDaemonOwner(_ socketName: String) -> Bool {
        guard !isLocallyDenied, var peer = descriptor.peer else { return false }
        if peer.daemonSocketName == socketName { return true }
        guard mayUse() else { return false }
        peer.daemonSocketName = socketName
        guard peer.hasValidDaemonSocketName else { return false }
        var replacement = descriptor
        replacement.peer = peer
        guard descriptors.write(replacement) else { return false }
        descriptor = replacement
        return true
    }

    /// Records only a bootstrap obtained over the configured, verified SSH key.
    func noteBootstrap(_ outcome: QUICBootstrapProbe.Outcome, fingerprint: String) {
        guard fingerprint == descriptor.target.hostKeyFingerprint,
            case .ready(let port, _, let certificate, let address) = outcome,
            certificate.count == 32, port != 0
        else {
            reach = nil
            return
        }
        reach = (address, port, Data(certificate))
    }

    private func mayUse() -> Bool {
        guard !isLocallyDenied,
            (descriptor.target.shouldPersistHistory == true) == Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory(),
            case .value(let current) = descriptors.read(descriptor.target.hostID)
        else { return false }
        return current.state == .ready && current.clientID == descriptor.clientID && current.target == descriptor.target
    }

    /// Withholds this owner immediately but never reenters Core from its
    /// synchronous store callback. A failed durable denial is not reported as
    /// committed; this process still discards the view and remains refused.
    private func retirementRefused() {
        guard !isLocallyDenied else { return }
        isLocallyDenied = true
        _ = descriptors.requireRetirement(descriptor.target.hostID)
        let retire = stop
        Task { @MainActor in retire?(self) }
    }

    private func bind(hostLow: UInt64, hostHigh: UInt64, principal: String, pin: Data) -> Bool {
        guard mayUse(), let reach, reach.pin == pin, !principal.isEmpty, hostLow != 0 || hostHigh != 0 else { return false }
        var replacement = descriptor
        replacement.peer = .init(
            hostLow: hostLow,
            hostHigh: hostHigh,
            principal: principal,
            certificatePin: pin,
            address: reach.address,
            port: reach.port,
            daemonSocketName:
                descriptor.peer?.hostLow == hostLow && descriptor.peer?.hostHigh == hostHigh
                ? descriptor.peer?.daemonSocketName : nil
        )
        guard descriptors.write(replacement) else { return false }
        descriptor = replacement
        return true
    }

    /// Commits denial before an edit/deletion is accepted, then stops the exact
    /// in-process owner. Failed key retirement remains denied across restart.
    static func retireBeforeEdit(_ hostID: UUID) -> Bool {
        let descriptors = ColdResumeDescriptors()
        guard descriptors.requireRetirement(hostID) else { return false }
        let active = owners[hostID]?.value
        if let active { active.stop?(active) }
        active?.abandonPreparation()
        if case .value(let record) = descriptors.read(hostID), let directory = try? privateDirectory() {
            _ = retire(record, directory: directory)
        }
        return true
    }

    static func retireForConfigurationChange(_ host: HostRecord) -> Bool {
        switch ColdResumeDescriptors().read(host.id) {
        case .missing: return true
        case .refused: return false
        case .value(let record): return record.target.matchesConfiguration(host) || retireBeforeEdit(host.id)
        }
    }

    /// A live configuration reload must not leave an old policy's picture or
    /// history eligible. The exact owner is stopped outside Core callbacks.
    func reconcileHistoryPreference() {
        guard (descriptor.target.shouldPersistHistory == true) != Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory() else {
            return
        }
        if !Self.retireBeforeEdit(descriptor.target.hostID) { retirementRefused() }
    }

    /// Settings commits protected retirement for every saved identity before
    /// changing the global opt-in. Failure leaves the requested setting alone.
    static func setHistoryPersistence(_ enabled: Bool) -> Bool {
        guard enabled != Ubiquitty.Preferences.Effective.shouldPersistRemoteHistory() else { return true }
        let identifiers = Set(HostStore.shared.hosts.map(\.id)).union(owners.keys).sorted { $0.uuidString < $1.uuidString }
        guard identifiers.allSatisfy({ retireBeforeEdit($0) }) else { return false }
        return Ubiquitty.Preferences.configureOwnKey(.RemoteHistoryCacheOnDisk, Ubiquitty.Preferences.Value.ofBool(.Bool, enabled)).value
            != nil
    }

    private static func retire(_ record: ColdResumeDescriptor, directory: URL) -> Bool {
        let path = directory.appendingPathComponent(record.clientID.uuidString).appendingPathExtension("sealed").path
        return withIdentity(record) { identity in path.withCString { ubiquittyIOSResumeRetire($0, identity) } }
    }

    private static func withIdentity<Result>(_ descriptor: ColdResumeDescriptor, _ use: (UbiquittyIOSResumeIdentity) -> Result) -> Result {
        let principal = descriptor.peer.map { Data(SHA256.hash(data: Data($0.principal.utf8))) } ?? Data(repeating: 0, count: 32)
        let pin = descriptor.peer?.certificatePin ?? Data(repeating: 0, count: 32)
        return principal.withUnsafeBytes { digest in
            pin.withUnsafeBytes { certificate in
                use(
                    UbiquittyIOSResumeIdentity(
                        clientLow: descriptor.clientHalves.low,
                        clientHigh: descriptor.clientHalves.high,
                        hostLow: descriptor.peer?.hostLow ?? 0,
                        hostHigh: descriptor.peer?.hostHigh ?? 0,
                        principalDigest: digest.bindMemory(to: UInt8.self).baseAddress,
                        certificatePin: certificate.bindMemory(to: UInt8.self).baseAddress,
                        digestLength: digest.count,
                        pinLength: certificate.count,
                        shouldPersistHistory: descriptor.target.shouldPersistHistory == true
                    )
                )
            }
        }
    }

    private static func privateDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("ColdResume", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // An existing owner is accepted only by the type, protection and
            // descriptor-relative checks below; existence alone is not trust.
        }
        let kind = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard kind.isSymbolicLink == false, kind.isDirectory == true else { throw Failure.protectedStorageUnavailable }
        try (directory as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let checked = try directory.resourceValues(forKeys: [.fileProtectionKey, .isSymbolicLinkKey, .isDirectoryKey])
        guard checked.fileProtection == .complete, checked.isSymbolicLink == false, checked.isDirectory == true,
            directory.path.withCString({ ubiquittyIOSResumeDirectoryDurable($0) })
        else { throw Failure.protectedStorageUnavailable }
        return directory
    }
}
