// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AVFAudio
import Observation
import Speech
import SwiftUI
import UIKit

/// Converts microphone buffers on the serial audio tap before yielding immutable audio.
private final class DictationAudioInput: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onFailure: @Sendable () -> Void
    private var pendingBuffer: AVAudioPCMBuffer?

    init?(
        source: AVAudioFormat,
        destination: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onFailure: @escaping @Sendable () -> Void
    ) {
        guard let converter = AVAudioConverter(from: source, to: destination) else { return nil }
        self.converter = converter
        format = destination
        self.continuation = continuation
        self.onFailure = onFailure
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            onFailure()
            return
        }
        pendingBuffer = buffer
        defer { pendingBuffer = nil }
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, status in
            guard let buffer = self.pendingBuffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.pendingBuffer = nil
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, failure == nil else {
            onFailure()
            return
        }
        guard converted.frameLength > 0 else { return }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: converted)) { onFailure() }
    }
}

@Observable
@MainActor
final class TerminalDictation {
    enum Phase { case idle, preparing, listening, finishing }
    private(set) var phase: Phase = .idle
    private(set) var message = ""
    private(set) var transcript = TerminalVoiceTranscript()
    private(set) var uninsertedText = ""
    private(set) var needsMicrophoneSettings = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var hasAudioSession = false
    /// What to run once the last spoken phrase has been inserted, when a
    /// submit was asked for while speech was still being finalized.
    private var submitAfterFinish: (() -> Void)?

    func start(insert: @escaping (String) -> Void) {
        guard phase == .idle, uninsertedText.isEmpty else { return }
        let generation = UUID()
        self.generation = generation
        transcript = TerminalVoiceTranscript()
        phase = .preparing
        needsMicrophoneSettings = false
        message = "Preparing dictation…"
        task = Task { [weak self] in await self?.run(generation: generation, insert: insert) }
    }

    private func run(generation: UUID, insert: @escaping (String) -> Void) async {
        defer {
            if self.generation == generation {
                stopAudio()
                analyzer = nil
                task = nil
                phase = .idle
            }
        }
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                try Task.checkCancellation()
                needsMicrophoneSettings = true
                throw Failure.message("Allow microphone access in Settings to dictate.")
            }
            try Task.checkCancellation()
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
                throw Failure.message("Dictation is unavailable for this language.")
            }
            try Task.checkCancellation()
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                message = "Downloading the dictation language…"
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            hasAudioSession = true
            let engine = AVAudioEngine()
            let source = engine.inputNode.outputFormat(forBus: 0)
            guard source.sampleRate > 0, source.channelCount > 0,
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source)
            else { throw Failure.message("No microphone input is available.") }
            try Task.checkCancellation()
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
            guard
                let audio = DictationAudioInput(
                    source: source,
                    destination: format,
                    continuation: continuation,
                    onFailure: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            self.cancel(preservingSpeech: true)
                            self.message = "Dictation could not keep up with the microphone. Try again."
                        }
                    }
                )
            else { throw Failure.message("The microphone’s audio format isn’t supported.") }
            self.engine = engine
            input = continuation
            // `@Sendable`, so the tap is not main-actor isolated: the engine
            // calls it on its own realtime messenger queue, and a closure that
            // inherited this method's isolation traps on the first buffer.
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: source) { @Sendable buffer, _ in
                audio.append(buffer)
            }
            engine.prepare()
            try engine.start()
            phase = .listening
            message = "Listening — you can keep typing"
            try await analyzer.start(inputSequence: stream)
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                if let text = transcript.accept(String(result.text.characters), endingAt: result.range.end.seconds, isFinal: result.isFinal)
                {
                    insert(text)
                }
            }
            message = ""
            // After the loop, not inside it: the last phrase is inserted by
            // the final result, and a submit that ran on the one before would
            // send the line without it.
            if self.generation == generation, let submit = submitAfterFinish {
                submitAfterFinish = nil
                submit()
            }
        } catch is CancellationError {
        } catch {
            if self.generation == generation {
                submitAfterFinish = nil
                uninsertedText = transcript.preview
                transcript = TerminalVoiceTranscript()
                message = error.localizedDescription
                await analyzer?.cancelAndFinishNow()
            }
        }
    }

    /// Submits what was dictated: `send` runs once every spoken phrase is in
    /// the pane.
    ///
    /// The one tap a person talking to a program on the host needs: with
    /// nothing in flight it sends at once, and while speech is still being
    /// recognized it finishes the recognition first, so the line that goes is
    /// the whole of what was said. Preparation has heard nothing yet, so it is
    /// cancelled rather than waited for.
    ///
    /// - Parameter send: What submits the line, typically the Return key.
    func submit(_ send: @escaping () -> Void) {
        switch phase {
        case .idle:
            send()
        case .preparing:
            cancel()
            send()
        case .listening:
            submitAfterFinish = send
            finish()
        case .finishing:
            submitAfterFinish = send
        }
    }

    /// Stops capture and lets the recognizer finalize the last spoken phrase.
    func finish() {
        guard phase == .listening, let analyzer else { return }
        phase = .finishing
        message = "Finishing dictation…"
        stopAudio()
        let generation = generation
        Task {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
                guard self.generation == generation else { return }
                cancel(preservingSpeech: true)
                message = error.localizedDescription
            }
        }
    }

    /// Cancels recognition and optionally preserves speech for explicit insertion.
    ///
    /// - Parameter preservingSpeech: Whether unsent words still belong to the current pane.
    func cancel(preservingSpeech: Bool = false) {
        uninsertedText = preservingSpeech ? (transcript.preview.isEmpty ? uninsertedText : transcript.preview) : ""
        submitAfterFinish = nil
        generation = UUID()
        task?.cancel()
        task = nil
        stopAudio()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        phase = .idle
        transcript = TerminalVoiceTranscript()
        message = ""
    }

    func takeUninsertedText() -> String {
        defer { uninsertedText = "" }
        return uninsertedText
    }

    func discardUninsertedText() {
        uninsertedText = ""
    }

    var actionTitle: String {
        switch phase {
        case .idle: "Dictate"
        case .listening: "Stop Dictation"
        case .preparing, .finishing: "Cancel Dictation"
        }
    }

    private func stopAudio() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        input?.finish()
        input = nil
        if hasAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasAudioSession = false
        }
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): text
            }
        }
    }
}

/// The bar dictation is driven from, above the keyboard or in its place.
///
/// With the keyboard up it is the accessory a person dictates into while
/// typing. Without it, it is how a person talks to a program on the host —
/// an agent waiting on a prompt — with nothing on screen but the grid: one
/// tap on the bar's button opens it listening, speech lands in the pane as
/// it is recognized, and Send puts the Return after the last of it.
struct TerminalDictationBar: View {
    @Environment(\.openURL)
    private var openURL
    let session: TerminalSessionModel
    /// Whether the keyboard is up, which decides what the trailing button
    /// does: put the keyboard away, or close this bar.
    let isKeyboardActive: Bool
    /// Whether to start listening as soon as the bar appears, which is what a
    /// bar opened by the Dictate button does; one opened by the keyboard
    /// waits to be asked.
    let shouldStartListening: Bool
    let hideKeyboard: () -> Void
    let close: () -> Void
    @State
    private var dictation = TerminalDictation()

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !dictation.uninsertedText.isEmpty {
                HStack {
                    Text(dictation.uninsertedText)
                        .font(.callout)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Insert") { session.send(dictation.takeUninsertedText()) }
                        .disabled(!session.isConnected)
                        .accessibilityLabel("Insert Unsent Speech")
                    Button("Discard", systemImage: "xmark") { dictation.discardUninsertedText() }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Discard Unsent Speech")
                }
                .padding(.horizontal, 8)
                .accessibilityIdentifier("terminal-dictation-recovery")
            }
        }
        .background(.bar)
        .task {
            if shouldStartListening, session.isConnected { startListening() }
        }
        .onDisappear { dictation.cancel() }
        .onChange(of: session.activePaneID) { _, _ in dictation.cancel() }
        .onChange(of: session.isConnected) { _, isConnected in
            if !isConnected { dictation.cancel(preservingSpeech: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            dictation.cancel(preservingSpeech: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: rawType) == .began
            else { return }
            dictation.cancel(preservingSpeech: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
            else { return }
            if dictation.phase == .listening { dictation.finish() }
        }
    }

    private func startListening() {
        dictation.start { session.send($0) }
    }

    /// Puts the Return after everything dictated, including speech the
    /// recognizer is still finishing and words a failure left uninserted.
    private func send() {
        let unsent = dictation.takeUninsertedText()
        if !unsent.isEmpty { session.send(unsent) }
        dictation.submit { session.sendKey(named: .Return) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                switch dictation.phase {
                case .idle: startListening()
                case .preparing: dictation.cancel()
                case .listening: dictation.finish()
                case .finishing: dictation.cancel()
                }
            } label: {
                Label(
                    dictation.actionTitle,
                    systemImage: dictation.phase == .idle ? "mic.fill" : "stop.fill"
                )
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!session.isConnected || !dictation.uninsertedText.isEmpty)
            .accessibilityIdentifier("terminal-dictation")
            if dictation.phase == .preparing || dictation.phase == .finishing { ProgressView() }
            Text(
                dictation.transcript.preview.isEmpty
                    ? (dictation.message.isEmpty ? (isKeyboardActive ? "Dictate while typing" : "Dictate, then Send") : dictation.message)
                    : dictation.transcript.preview
            )
            .font(.callout)
            .foregroundStyle(dictation.phase == .listening ? .primary : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("terminal-dictation-preview")
            if dictation.needsMicrophoneSettings {
                Button("Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Open Microphone Settings")
            }
            Button(action: send) {
                Label("Send", systemImage: "return")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!session.isConnected)
            .accessibilityIdentifier("terminal-dictation-send")
            if isKeyboardActive {
                Button(action: hideKeyboard) {
                    Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("terminal-hide-keyboard")
            } else {
                Button(action: close) {
                    Label("Close Dictation", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("terminal-dictation-close")
            }
        }
        .padding(.horizontal, 8)
    }
}
