// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import QuickLook
import SwiftUI
import UbiquittyRenderKit
import UniformTypeIdentifiers

/// A downloaded file exported through the system document picker.
struct TerminalFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let id = UUID()
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Confirms the exact host and path before any file bytes are requested.
struct TerminalFileDownloadView: View {
    let session: TerminalSessionModel
    let request: TerminalFileDownloadRequest
    let onDownload: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Host", value: request.prompt.host)
                Section("File") { Text(request.prompt.path).textSelection(.enabled) }
                Section {
                    Button("Download") {
                        session.answerFileDownload(request, download: true)
                        onDownload()
                    }
                    .accessibilityIdentifier("confirm-file-download")
                } footer: {
                    Text("After downloading, choose where to save the file in Files.")
                }
            }
            .navigationTitle("Download This File?")
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar { SheetToolbar(cancel: { session.answerFileDownload(request, download: false) }) }
            .onDisappear { session.answerFileDownload(request, download: false) }
        }
    }
}

/// Imports and exports files using the system Files interface.
struct TerminalFilesView: View {
    @Bindable
    var session: TerminalSessionModel
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var isImporting = false
    @State
    private var isExporting = false
    @State
    private var remotePath = ""
    @State
    private var previewFile: ReceivedFilePreview?
    @State
    private var previewURL: URL?
    @State
    private var previewError = ""

    var body: some View {
        NavigationStack {
            Group {
                if session.supportsFiles {
                    transferForm
                } else {
                    ContentUnavailableView(
                        "File Transfer Unavailable",
                        systemImage: "folder",
                        description: Text("Connect to a Ubiquitty host to send and receive files.")
                    )
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar { SheetToolbar.close { dismiss() } }
            .sensoryFeedback(trigger: session.fileTransferOutcome, SettledOutcome.feedback)
            .quickLookPreview($previewURL)
            .task(id: session.receivedFile?.id) { preparePreview() }
            .dropDestination(for: URL.self) { urls, _ in
                guard session.supportsFiles, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
                session.uploadFile(url)
                return true
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): session.uploadFile(url)
                case .failure(let error): session.fileMessage = error.localizedDescription
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: session.receivedFile,
                contentType: .data,
                defaultFilename: session.receivedFileName
            ) { result in
                switch result {
                case .success: session.fileMessage = "File saved."
                case .failure(let error): session.fileMessage = error.localizedDescription
                }
            }
        }
    }

    private func preparePreview() {
        previewURL = nil
        previewFile = nil
        previewError = ""
        guard let file = session.receivedFile else { return }
        do {
            previewFile = try ReceivedFilePreview(data: file.data, name: session.receivedFileName)
        } catch {
            previewError = "A preview couldn’t be prepared. You can still save the file to Files."
        }
    }

    private var transferForm: some View {
        Form {
            Section {
                Button("Send File…", systemImage: "square.and.arrow.up") { isImporting = true }
            } footer: {
                Text("The host saves the file and types its path into the terminal.")
            }
            Section {
                TextField("Full path on the host", text: $remotePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("remote-file-path")
                Button("Receive File", systemImage: "square.and.arrow.down") { session.downloadFile(remotePath) }
                    .disabled(!remotePath.hasPrefix("/"))
                if session.receivedFile != nil {
                    LabeledContent("Received", value: session.receivedFileName)
                    if let previewFile {
                        Button("Preview", systemImage: "doc.text.magnifyingglass") { previewURL = previewFile.url }
                        ShareLink(item: previewFile.url)
                    }
                    Button("Save to Files…", systemImage: "folder") { isExporting = true }
                    if !previewError.isEmpty { Text(previewError).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Receive from Host")
            } footer: {
                Text("Files come from the session’s working directory.")
            }
            if !session.fileMessage.isEmpty {
                Section { Text(session.fileMessage).textSelection(.enabled).accessibilityIdentifier("file-transfer-status") }
            }
        }
    }
}

/// Presents the verified requesting process separately from its claimed label.
struct TerminalConsentView: View {
    let session: TerminalSessionModel
    let request: TerminalConsentRequest
    @State
    private var isConfirmingPersistentGrant = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host", value: request.host.isEmpty ? "Unknown" : request.host)
                    LabeledContent("Session", value: request.sessionLabel)
                }
                Section {
                    Label(request.question, systemImage: "hand.raised")
                        .font(.headline)
                    if let structure = request.structurePrompt {
                        Text(structure.detail)
                    } else if let detail = request.ownDeviceDetail {
                        Text(detail)
                    } else {
                        LabeledContent("Verified Process", value: request.actor.isEmpty ? "Unknown" : request.actor)
                        if !request.claimedLabel.isEmpty { LabeledContent("Agent’s Claimed Name", value: request.claimedLabel) }
                    }
                } footer: {
                    Text(
                        request.isClientHeld
                            ? "Approve only if you recognize this request. Nothing happens here until you answer."
                            : "Approve only if you recognize this request. If you don’t answer before the host’s time limit, the request is denied."
                    )
                }
                Section {
                    Button(request.structurePrompt?.allowTitle ?? "Allow Once") { session.answerConsent(request, decision: .allowOnce) }
                    Button(request.structurePrompt?.denyTitle ?? "Deny", role: .cancel) {
                        session.answerConsent(request, decision: .deny)
                    }
                }
                if request.isClientHeld {
                    // The answer stays on this device and nothing is saved, so
                    // the widest allow is the connection's, never "Always".
                    if request.allowsPersistentGrant {
                        Section {
                            Button(TerminalConsentRequest.connectionScopeTitle) {
                                session.answerConsent(request, decision: .allowSession)
                            }
                        }
                    }
                } else if request.allowsPersistentGrant {
                    Section {
                        DisclosureGroup("Allow Future Requests") {
                            Button("Allow for This Session") { session.answerConsent(request, decision: .allowSession) }
                            Button(request.isCapabilityGrant ? "Always Allow" : "Always Allow This Agent") {
                                isConfirmingPersistentGrant = true
                            }
                        }
                    } footer: {
                        Text(
                            "These choices also approve matching requests without asking again. A permanent grant stays on the host after this connection ends."
                        )
                    }
                }
            }
            .navigationTitle("Permission Request")
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .confirmationDialog(
                "Allow Matching Requests Automatically?",
                isPresented: $isConfirmingPersistentGrant,
                titleVisibility: .visible
            ) {
                Button("Always Allow") { session.answerConsent(request, decision: .allowAlways) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permission stays on the host after you disconnect. Choose Allow Once if you only intend to approve this request."
                )
            }
        }
        // Answered by a button and never by the sheet going away. A sheet also
        // goes away when the view presenting it is rebuilt — a window changing
        // width class does that — and an answer read from its disappearance
        // would deny a request the person never saw leave. A request nobody answers
        // is the host's to deny at its deadline, so an unanswered sheet grants
        // nothing, and the screen presents it again when it returns.
        .interactiveDismissDisabled()
    }
}
