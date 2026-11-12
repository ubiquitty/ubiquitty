// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// LinkOpener.swift — what happens when a clicked link is opened.
//
// The order of the layers is the security property, so it is written once and
// both shells run it: a Welcome screen action never reaches a program, a target
// that does not read as written reaches nothing, a user-configured handler
// receives the link as one inert argument, and anything with no handler must
// pass the launchable-scheme allowlist and, for a local file, be something the
// opener can only display before the system opener sees it.
//
// The rules themselves are Core's — `LinkRun::schemeOfURI`,
// `LinkRun::linkHandlerArgv`, `LinkRun::hasDeceptiveLinkCharacters`,
// `LinkRun::isLaunchableURLScheme`, `Session::localFileLinkPath`,
// `Session::fileLinkLine`, `LinkRun::localLinkAction`,
// `LinkRun::lineHandlerTakes`, `LinkRun::lineHandlerArgv`,
// `Preferences::linkHandlerCommand` and `Preferences::linkLineHandler`. What
// is left here is the part only a Mac can do: run a program, read a file's
// resource values, and hand a URL to the workspace or to Finder.

import AppKit
import CoreServices
internal import UbiquittyCore
import UniformTypeIdentifiers

@MainActor
@objc(UBLinkOpener)
public final class LinkOpener: NSObject {
    /// What the plate says before a target a click would refuse.
    nonisolated public static let refusalMarker = "Won\u{2019}t open: "

    /// What a click on one target would actually open, as a reader sees it,
    /// read without touching the filesystem.
    ///
    /// A link's visible text and its target are two different strings, and an
    /// OSC 8 link can make them say anything — so what is shown is the target.
    /// A `file:` URI is shown as the bare path it names, because a reader
    /// checking where a link goes reads `/Users/…` faster than
    /// `file:///Users/…` and the scheme adds nothing they can act on; anything
    /// else is shown verbatim, scheme included, since the scheme is exactly
    /// what a reader is checking on a link they did not write. A target a
    /// `[link_handlers]` entry takes is shown as written, because that is what
    /// the handler receives.
    ///
    /// The path is read the way a click reads it, through Core's
    /// `Session::localFileLinkPath`, so percent-encoded slashes, a line
    /// fragment and the host are what the click sees, and its dot segments
    /// are collapsed. A target the click would refuse before looking at the
    /// filesystem (a hidden character, a scheme off the allowlist, another
    /// machine, a query, a fragment that names no line) carries
    /// ``refusalMarker``. The symbolic links are left to
    /// ``resolvedPreviewText(forPath:)``, which a hung network volume can hold.
    /// Every character that hides part of a target is spelled out
    /// (`LinkRun::escapedDeceptiveLinkCharacters`), so a target cannot hide
    /// part of itself or draw a second line.
    ///
    /// - Parameter target: The resolved target — a `file:` URI for a path
    ///   match, or the URI the program declared.
    /// - Returns: The line to show.
    @objc(previewTextForTarget:)
    public static func previewText(forTarget target: String) -> String {
        previewReading(of: target, onHost: nil).text
    }

    /// What a click on one target would open, as a reader sees it, in a pane
    /// that may be attached to a host.
    ///
    /// A pane attached to a host hands a `file:` target to the host download
    /// before the opener sees it, so such a target names the host's file. It
    /// is read against the host's name, as that click asks the host for it
    /// (`Session::hostFileLinkPath`), and nothing on this machine is looked
    /// at. A fragment that names a line is set aside, as the download sets it
    /// aside, so a line link shows the file it fetches; ``refusalMarker``
    /// comes before a target the host would not be asked for: a third
    /// machine's, or one carrying a query or any other fragment. Any other
    /// target, and every target in a pane of this machine, is read as
    /// ``previewText(forTarget:)`` reads it.
    ///
    /// - Parameters:
    ///   - target: The resolved target.
    ///   - host: The connected host's name when the pane is attached to one,
    ///     or nil for a pane of this machine.
    ///   - isPath: Whether Core identified a bare file path, already resolved
    ///     against the host's directory, rather than a declared URI.
    /// - Returns: The line to show.
    public static func previewText(forTarget target: String, onHost host: String?, isPath: Bool = false) -> String {
        previewReading(of: target, onHost: host, isPath: isPath).text
    }

    /// The plate's line for a local path once its symbolic links are resolved
    /// and the file is looked at, as a click resolves it and looks at it.
    ///
    /// Reads the filesystem, which a hung network volume can hold for as long
    /// as its server is gone, so it is asked off the main thread.
    ///
    /// - Parameter path: The path a `file:` target names.
    /// - Returns: The canonical path, after ``refusalMarker`` when nothing a
    ///   click could open is there.
    nonisolated public static func resolvedPreviewText(forPath path: String) -> String {
        let inspected = inspectedFile(atPath: path)
        let action = inspected.canonical.path.withCString {
            Ubiquitty.Attributes.LinkRun.localLinkAction(std.string_view($0), inspected.facts)
        }
        let shown = escapedForPlate(inspected.canonical.path)
        return action == .refuse ? refusalMarker + shown : shown
    }

    /// Shows what a click on one target would open on a window's plate, or
    /// takes the plate away.
    ///
    /// The plate is raised at once with ``previewText(forTarget:onHost:isPath:)``. A
    /// local path is then resolved on a queue of its own, and its answer
    /// replaces the line only while the plate is still about the same target,
    /// so a pointer that has moved on is not shown a late one. A host's path
    /// is not resolved here: the file is the host's.
    ///
    /// - Parameters:
    ///   - target: The hovered link's target, or nil for none.
    ///   - host: The connected host's name when the hovered pane is attached
    ///     to one, or nil for a pane of this machine.
    ///   - isPath: Whether the target is Core's resolved bare path.
    ///   - window: The window whose plate shows it.
    public static func showPreview(forTarget target: String?, onHost host: String? = nil, isPath: Bool = false, in window: NSWindow?) {
        guard let target else {
            LinkPreviewBubble.show(nil, in: window)
            return
        }
        let reading = previewReading(of: target, onHost: host, isPath: isPath)
        LinkPreviewBubble.show(reading.text, about: target, in: window)
        guard let path = reading.pathToResolve else {
            return
        }
        LinkPreviewBubble.resolve(path: path, about: target, in: window)
    }

    /// One serial queue for every plate's resolution, so a volume that hangs
    /// holds one thread rather than one per pointer move.
    nonisolated static let previewResolution = DispatchQueue(label: "org.ubiquitty.link-preview", qos: .userInitiated)

    #if UBIQUITTY_UI_TESTS
    /// Holds the worker so queue admission can be checked without filesystem timing.
    ///
    /// - Returns: The release action, which the scenario must call before draining.
    package static func holdPreviewResolutionForTesting() -> @Sendable () -> Void {
        let release = DispatchSemaphore(value: 0)
        previewResolution.async { release.wait() }
        return { release.signal() }
    }

    /// Waits until every admitted plate resolution has finished.
    ///
    /// Each one posts its answer to the main actor, so a scenario that pumps
    /// the main run loop after this has seen every answer land or be turned
    /// away.
    package static func drainPreviewResolutionForTesting() {
        previewResolution.sync {}
    }
    #endif

    /// What the plate can say about a target without the filesystem.
    private struct PreviewReading {
        /// The line to show.
        let text: String
        /// The local path still to resolve, or nil when the line is final.
        let pathToResolve: String?
    }

    /// Reads a target for the plate the way a click reads it, stopping short
    /// of the filesystem.
    ///
    /// - Parameters:
    ///   - target: The link target.
    ///   - host: The connected host's name when the pane is attached to one,
    ///     or nil for a pane of this machine.
    ///   - isPath: Whether the target is Core's resolved bare path.
    /// - Returns: The line, and the path still to resolve.
    private static func previewReading(of target: String, onHost host: String?, isPath: Bool = false) -> PreviewReading {
        let asWritten = PreviewReading(text: escapedForPlate(target), pathToResolve: nil)
        let refused = PreviewReading(text: refusalMarker + asWritten.text, pathToResolve: nil)
        if let host, isPath {
            // A host's '~' belongs to that host. No URL conversion or local
            // home expansion may reinterpret a path Core already resolved.
            return host.isEmpty ? refused : asWritten
        }
        // `TerminalSurface.handleFileLink` takes a host's file link before
        // ``open(_:from:)`` is called, and asks the host for it.
        if let host, isFileTarget(target) {
            let path = target.withCString { rawURI in
                host.withCString { rawHost in
                    String(Ubiquitty.Session.hostFileLinkPath(std.string_view(rawURI), std.string_view(rawHost)))
                }
            }
            return path.isEmpty ? refused : PreviewReading(text: escapedForPlate(path), pathToResolve: nil)
        }
        if target.withCString({ Ubiquitty.App.Welcome.isActionURI(std.string_view($0)) }) {
            return asWritten
        }
        // In ``open(_:from:)``'s order: a hidden character is refused before
        // a configured handler is asked, so a target a handler would take
        // still carries the marker.
        if hasDeceptiveCharacters(target) {
            return refused
        }
        if !configuredHandlerCommand(for: target).isEmpty {
            return asWritten
        }
        guard launchableURL(for: target) != nil else {
            return refused
        }
        guard isFileTarget(target) else {
            return asWritten
        }
        guard let path = localPath(forFileTarget: target) else {
            return refused
        }
        let folded = path.withCString {
            String(Ubiquitty.Attributes.LinkRun.resolveFilePathCandidate(std.string_view($0), std.string_view(), std.string_view()))
        }
        return PreviewReading(text: escapedForPlate(folded), pathToResolve: path)
    }

    /// Text as the plate shows it, every character that hides part of it
    /// spelled out.
    ///
    /// - Parameter text: A target or a path.
    /// - Returns: The escaped text.
    nonisolated private static func escapedForPlate(_ text: String) -> String {
        text.withCString { String(Ubiquitty.Attributes.LinkRun.escapedDeceptiveLinkCharacters(std.string_view($0))) }
    }

    /// What opening one target comes to, decided before anything is opened.
    public indirect enum Disposition: Equatable {
        /// The workspace is handed this URL.
        case open(URL)
        /// Finder selects this file, and nothing is opened.
        case reveal(URL)
        /// The reader's `[links] line_handler` runs with this argv; `otherwise`
        /// is what happens when it cannot be started.
        case openAtLine([String], otherwise: Disposition)
        /// Nothing happens.
        case refuse
    }

    /// Opens a resolved link the way the reader configured, or the way the
    /// system would.
    ///
    /// The layers, in the order that makes them safe:
    ///
    /// 1. A Welcome screen button — any target in the `ubiquitty:action/`
    ///    namespace — is dispatched in-process by ``WelcomeActions`` and stops
    ///    here. It is not a link to anywhere, so no configuration can route it
    ///    to a program or to the workspace, and no shell can forget to offer it.
    /// 2. A target carrying a character that hides, reorders or breaks part of
    ///    it (`LinkRun::hasDeceptiveLinkCharacters`) is refused. A
    ///    `[link_handlers]` entry is consent to a scheme, not to a target its
    ///    reader cannot read, so the refusal comes before it.
    /// 3. A `[link_handlers]` command for this scheme runs with the URI as a
    ///    single argument, through no shell. A configured scheme is not put to
    ///    the allowlist: the allowlist stands in for a reader's consent, and a
    ///    `[link_handlers]` entry is that consent written down.
    /// 4. Everything else is classified, which opens it, shows
    ///    it in Finder, hands a file at a line to the reader's line handler,
    ///    or refuses it. A refusal beeps: the click was taken from the
    ///    selection it would otherwise have started, and a reader who sees
    ///    nothing happen would click again.
    ///
    /// - Parameters:
    ///   - uri: The link target the terminal resolved.
    ///   - window: The window the link was clicked in, which a Welcome button's
    ///     question is attached to.
    /// A local file is inspected off the main actor. Only one filesystem
    /// request is admitted at a time, so an unavailable volume holds one
    /// worker rather than accumulating work for every repeated click. Its
    /// result is discarded if the source window closes before it arrives.
    ///
    /// - Returns: Whether the interaction was handled or its file inspection
    ///   was admitted. A later file refusal beeps; admission is not a promise
    ///   that the inspected target will open.
    @discardableResult
    @objc(openURI:fromWindow:)
    public static func open(_ uri: String, from window: NSWindow?) -> Bool {
        if uri.isEmpty {
            return false
        }
        if WelcomeActions.dispatch(uri, from: window) {
            return true
        }
        if hasDeceptiveCharacters(uri) {
            return carryOut(.refuse)
        }
        if isFileTarget(uri) {
            let command = configuredHandlerCommand(for: uri)
            if !command.isEmpty {
                return openWithConfiguredFileHandler(uri, command: command, from: window)
            }
        } else if launchConfiguredHandler(for: uri) {
            return true
        }
        return openWithoutConfiguredHandler(uri, from: window)
    }

    private static func openWithConfiguredFileHandler(_ uri: String, command: String, from window: NSWindow?) -> Bool {
        let admitted = performFileWork(
            from: window,
            work: {
                let argv = configuredHandlerArgv(for: uri, command: command)
                return .command(argv.first.map { PreparedCommand(argv: argv, executable: executableURL(for: $0)) })
            },
            completion: { [weak window] result in
                guard case .command(let prepared) = result else { return }
                if prepared.map({ launch($0, describing: "link handler for file") }) != true {
                    _ = openWithoutConfiguredHandler(uri, from: window)
                }
            }
        )
        return admitted || carryOut(.refuse)
    }

    private static func openWithoutConfiguredHandler(_ uri: String, from window: NSWindow?) -> Bool {
        guard let url = launchableURL(for: uri) else {
            return carryOut(.refuse)
        }
        guard isFileTarget(uri) else {
            return carryOut(.open(url))
        }
        guard let path = localPath(forFileTarget: uri) else {
            return carryOut(.refuse)
        }
        let lineHandler = configuredLineHandlerCommand()
        let line = uri.withCString { Ubiquitty.Session.fileLinkLine(std.string_view($0)) }
        guard
            inspectFile(
                atPath: path,
                lineHandler: lineHandler,
                line: line.line,
                column: line.column,
                from: window,
                completion: { inspected in
                    _ = carryOut(
                        fileDisposition(for: uri, inspected: inspected, lineHandler: lineHandler),
                        preparedLineHandler: inspected.lineHandler
                    )
                }
            )
        else {
            return carryOut(.refuse)
        }
        return true
    }

    private enum FileWorkResult: Sendable {
        case inspected(InspectedFile)
        case command(PreparedCommand?)
    }

    /// A click owns at most one filesystem lookup, including a lookup whose
    /// source window has closed. It cannot be canceled at the filesystem, so
    /// the admission stays occupied until the worker actually returns.
    @MainActor
    private final class FileInspectionRequest {
        weak var window: NSWindow?
        let needsWindow: Bool
        var isCanceled = false
        var closeObserver: NSObjectProtocol?
        let completion: @MainActor (FileWorkResult) -> Void

        init(window: NSWindow?, completion: @escaping @MainActor (FileWorkResult) -> Void) {
            self.window = window
            needsWindow = window != nil
            self.completion = completion
            if let window {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isCanceled = true
                        self?.stopObserving()
                    }
                }
            }
        }

        func stopObserving() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
        }
    }

    nonisolated private static let fileInspection = DispatchQueue(label: "org.ubiquitty.link-open", qos: .userInitiated)
    private static var activeFileInspection: FileInspectionRequest?

    private static func inspectFile(
        atPath path: String,
        lineHandler: String = "",
        line: UInt32 = 0,
        column: UInt32 = 0,
        from window: NSWindow?,
        completion: @escaping @MainActor (InspectedFile) -> Void
    ) -> Bool {
        performFileWork(
            from: window,
            work: { .inspected(inspectedFile(atPath: path, lineHandler: lineHandler, line: line, column: column)) },
            completion: { result in
                guard case .inspected(let inspected) = result else { return }
                completion(inspected)
            }
        )
    }

    private static func performFileWork(
        from window: NSWindow?,
        work: @escaping @Sendable () -> FileWorkResult,
        completion: @escaping @MainActor (FileWorkResult) -> Void
    ) -> Bool {
        guard activeFileInspection == nil else { return false }
        let request = FileInspectionRequest(window: window, completion: completion)
        activeFileInspection = request
        fileInspection.async { [weak request] in
            let result = work()
            Task { @MainActor [weak request] in
                guard let request, activeFileInspection === request else { return }
                activeFileInspection = nil
                request.stopObserving()
                guard !request.isCanceled, !request.needsWindow || request.window != nil else { return }
                request.completion(result)
            }
        }
        return true
    }

    #if UBIQUITTY_UI_TESTS
    /// Holds filesystem inspection without involving a slow or unavailable mount.
    package static func holdFileInspectionForTesting() -> @Sendable () -> Void {
        let release = DispatchSemaphore(value: 0)
        fileInspection.async { release.wait() }
        return { release.signal() }
    }

    package static var admittedFileInspectionCountForTesting: Int { activeFileInspection == nil ? 0 : 1 }

    /// Completes worker work; its main-actor completion still needs a run-loop turn.
    package static func drainFileInspectionForTesting() {
        fileInspection.sync {}
    }
    #endif

    /// Whether a target carries a character that hides, reorders or breaks
    /// part of it.
    ///
    /// Asked of the string as printed, because `URL(string:)` percent-encodes
    /// exactly those characters.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: Whether a click on it must reach nothing.
    private static func hasDeceptiveCharacters(_ uri: String) -> Bool {
        uri.withCString { Ubiquitty.Attributes.LinkRun.hasDeceptiveLinkCharacters(std.string_view($0)) }
    }

    /// Carries out one decision: starts the reader's line handler, or hands
    /// the workspace step what is left.
    ///
    /// - Parameter decision: What the click comes to.
    /// - Returns: Whether anything was opened, started or shown in Finder.
    private static func carryOut(_ decision: Disposition, preparedLineHandler: PreparedCommand? = nil) -> Bool {
        if case .openAtLine(_, let otherwise) = decision {
            // A handler that cannot be started leaves the file to the rule it
            // would have met with none configured, as a mistyped
            // `[link_handlers]` entry does.
            let didLaunch = preparedLineHandler.map { launch($0, describing: "line handler") } ?? false
            return didLaunch || carryOut(otherwise)
        }
        #if UBIQUITTY_UI_TESTS
        if let workspaceForTesting {
            workspaceForTesting(decision)
            return decision != .refuse
        }
        #endif
        return performInWorkspace(decision)
    }

    /// Opens a URL, shows a file in Finder, or beeps for a refusal.
    ///
    /// - Parameter decision: What ``disposition(for:)`` decided, a line
    ///   handler's fallback in place of the handler.
    /// - Returns: Whether anything was opened or shown in Finder.
    private static func performInWorkspace(_ decision: Disposition) -> Bool {
        switch decision {
        case .open(let url):
            return NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        case .openAtLine(_, let otherwise):
            // ``carryOut(_:)`` starts a line handler itself and passes on
            // only its fallback, which is the workspace step's part of it.
            return performInWorkspace(otherwise)
        case .refuse:
            NSSound.beep()
            return false
        }
    }

    #if UBIQUITTY_UI_TESTS
    /// What the workspace step was asked to do, in place of doing it.
    ///
    /// A scenario that sets it receives each decision ``open(_:from:)``
    /// reached past the Welcome step, a refused hidden character included,
    /// and every one the `[link_handlers]` step left to it, and nothing is
    /// opened, shown in Finder or beeped. So a scenario can drive the opener a
    /// click drives and assert where a link went without launching anything.
    /// A line handler is the one program still started, because whether it
    /// starts is what decides its fallback; what it falls back to arrives here.
    package static var workspaceForTesting: (@MainActor (Disposition) -> Void)?
    #endif

    /// What the workspace step would do with a link no configured handler
    /// took.
    ///
    /// A program printed the target, so it is asked three things before
    /// anything opens. It must read as written: a target carrying a character
    /// that hides or reorders part of it is refused outright, asked of the
    /// string as printed because `URL(string:)` percent-encodes exactly those
    /// characters. It must pass ``launchableURL(for:)``. And a `file:` target
    /// must name something on this machine that the opener can only display:
    /// Core reads the URI into a path, refusing a query, a fragment that names
    /// no line, or another machine's name in its authority; the path's symbolic links are
    /// resolved here, so what is classified is what would be opened; and
    /// Core's `LinkRun::localLinkAction` decides from the file's resource
    /// values whether it opens, is shown in Finder, or is refused. An
    /// application, a script, an executable, a Finder alias, a file carrying
    /// its own Open With choice and a directory some program other than
    /// Finder claims are only ever shown: Launch Services follows an alias to
    /// its target, opens an Open With file in the program it names, and opens
    /// a `.mbox` folder in Mail, and resolving symbolic links sees none of it.
    ///
    /// A fragment naming a line (`#L12`, `#L12-L20`, `#L12:5`) is set aside
    /// before the path is read. When the reader configured a `[links]
    /// line_handler` and the file is one Core's `LinkRun::lineHandlerTakes`
    /// hands it, the handler is given the canonical path that was judged and
    /// the line, never the URI as printed; otherwise the file meets the rule
    /// any file link does.
    ///
    /// This synchronous diagnostic reads the filesystem and can block on an
    /// unavailable volume. Interactive clicks use the bounded worker in
    /// ``open(_:from:)`` instead.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: What opening it comes to.
    public static func disposition(for uri: String) -> Disposition {
        guard !hasDeceptiveCharacters(uri), let url = launchableURL(for: uri) else {
            return .refuse
        }
        guard isFileTarget(uri) else {
            return .open(url)
        }
        guard let path = localPath(forFileTarget: uri) else {
            return .refuse
        }
        return fileDisposition(for: uri, inspected: inspectedFile(atPath: path), lineHandler: configuredLineHandlerCommand())
    }

    private static func fileDisposition(for uri: String, inspected: InspectedFile, lineHandler: String) -> Disposition {
        let canonical = inspected.canonical
        let facts = inspected.facts
        let action = canonical.path.withCString {
            Ubiquitty.Attributes.LinkRun.localLinkAction(std.string_view($0), facts)
        }
        let decided: Disposition
        switch action {
        case .open:
            decided = .open(canonical)
        case .reveal:
            decided = .reveal(canonical)
        case .refuse:
            decided = .refuse
        @unknown default:
            decided = .refuse
        }
        let line = uri.withCString { Ubiquitty.Session.fileLinkLine(std.string_view($0)) }
        guard line.line > 0, Ubiquitty.Attributes.LinkRun.lineHandlerTakes(facts) else {
            return decided
        }
        let argv =
            inspected.lineHandler?.argv
            ?? lineHandlerArgv(for: canonical.path, line: line.line, column: line.column, command: lineHandler)
        return argv.isEmpty ? decided : .openAtLine(argv, otherwise: decided)
    }

    /// Opens a file fetched from a host at the line its link named, in the
    /// reader's `[links] line_handler`.
    ///
    /// A pane attached to a host fetches a `file:` link rather than opening
    /// it, and the line a fragment such as `#L12` names travels with the
    /// request. The copy that lands is a regular file this machine wrote, so
    /// the handler takes it as it takes any regular file
    /// (`LinkRun::lineHandlerTakes`), and is handed the copy's canonical path
    /// and the line.
    ///
    /// - Parameters:
    ///   - url: The landed copy.
    ///   - line: The line, counted from 1, or 0 when the link named none.
    ///   - column: The column, counted from 1, or 0 when the link named none.
    ///   - window: The source window; closing it cancels the eventual launch.
    ///   - ifUnhandled: The usual download open/reveal rule, called when the
    ///     inspected file cannot use the handler or the handler cannot start.
    /// - Returns: Whether line-handler inspection was admitted. False when
    ///   the link named no line, no handler is configured, or the worker is
    ///   busy; the caller then applies its usual download rule immediately.
    @discardableResult
    public static func openDownloadedCopy(
        _ url: URL,
        atLine line: UInt32,
        column: UInt32,
        from window: NSWindow?,
        ifUnhandled: @escaping @MainActor () -> Void
    ) -> Bool {
        let command = configuredLineHandlerCommand()
        guard line > 0, !command.isEmpty else {
            return false
        }
        return inspectFile(atPath: url.path, lineHandler: command, line: line, column: column, from: window) { inspected in
            guard let handler = inspected.lineHandler, launch(handler, describing: "line handler") else {
                ifUnhandled()
                return
            }
        }
    }

    /// Whether a target is a `file:` URI, whatever its spelling.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: Whether its scheme is `file`.
    private static func isFileTarget(_ uri: String) -> Bool {
        uri.withCString { Ubiquitty.Session.isFileLinkURI(std.string_view($0)) }
    }

    /// The path a `file:` target names on this machine, read as Core reads it.
    ///
    /// - Parameter uri: The `file:` URI.
    /// - Returns: The decoded path, or nil when it names nothing here.
    private static func localPath(forFileTarget uri: String) -> String? {
        let path = uri.withCString { rawURI in
            // The kernel's name, read at the click: what ls --hyperlink writes.
            // ProcessInfo.hostName asks the resolver for a canonical name and
            // can wait on the network.
            String(Ubiquitty.PAL.systemHostName())
                .withCString { rawHost in
                    // Every name on a macOS volume is UTF-8, so a path that is
                    // not names nothing here.
                    String(Ubiquitty.Session.localFileLinkPath(std.string_view(rawURI), std.string_view(rawHost), .utf8))
                }
        }
        return path.isEmpty ? nil : path
    }

    /// The worker's value snapshot. The C++ facts are reconstructed where
    /// consumed, rather than carried across an actor boundary.
    private struct InspectedFile: Sendable {
        let canonical: URL
        let isDirectory: Bool
        let isPackage: Bool
        let isRegularFile: Bool
        let isExecutable: Bool
        let isLaunchableType: Bool
        let isDisplayOnlyType: Bool
        let isOnVolumeWithoutPermissions: Bool
        let isAlias: Bool
        let hasOwnOpener: Bool
        let isOpenedOutsideFileManager: Bool
        let lineHandler: PreparedCommand?

        nonisolated init(canonical: URL, facts: Ubiquitty.Attributes.LinkRun.LocalFileFacts, lineHandler: PreparedCommand?) {
            self.canonical = canonical
            isDirectory = facts.isDirectory
            isPackage = facts.isPackage
            isRegularFile = facts.isRegularFile
            isExecutable = facts.isExecutable
            isLaunchableType = facts.isLaunchableType
            isDisplayOnlyType = facts.isDisplayOnlyType
            isOnVolumeWithoutPermissions = facts.isOnVolumeWithoutPermissions
            isAlias = facts.isAlias
            hasOwnOpener = facts.hasOwnOpener
            isOpenedOutsideFileManager = facts.isOpenedOutsideFileManager
            self.lineHandler = lineHandler
        }

        nonisolated var facts: Ubiquitty.Attributes.LinkRun.LocalFileFacts {
            var facts = Ubiquitty.Attributes.LinkRun.LocalFileFacts()
            facts.isDirectory = isDirectory
            facts.isPackage = isPackage
            facts.isRegularFile = isRegularFile
            facts.isExecutable = isExecutable
            facts.isLaunchableType = isLaunchableType
            facts.isDisplayOnlyType = isDisplayOnlyType
            facts.isOnVolumeWithoutPermissions = isOnVolumeWithoutPermissions
            facts.isAlias = isAlias
            facts.hasOwnOpener = hasOwnOpener
            facts.isOpenedOutsideFileManager = isOpenedOutsideFileManager
            return facts
        }
    }

    /// Resolves a local path and reads its file, type, volume and opener facts.
    /// Filesystem access stays together here, off the main actor for clicks.
    ///
    /// - Parameter path: The path a file target names.
    /// - Returns: Its canonical URL and the facts read there.
    nonisolated private static func inspectedFile(
        atPath path: String,
        lineHandler command: String = "",
        line: UInt32 = 0,
        column: UInt32 = 0
    ) -> InspectedFile {
        let canonical = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        var facts = Ubiquitty.Attributes.LinkRun.LocalFileFacts()
        // Reading every key in one call is also the existence check: a path
        // with nothing at it throws, and its facts stay all false.
        if let values = try? canonical.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .isRegularFileKey, .isExecutableKey, .contentTypeKey, .isAliasFileKey,
        ]) {
            facts.isDirectory = values.isDirectory ?? false
            facts.isPackage = values.isPackage ?? false
            facts.isRegularFile = values.isRegularFile ?? false
            facts.isExecutable = values.isExecutable ?? false
            facts.isLaunchableType = values.contentType.map(isLaunchableType) ?? false
            facts.isDisplayOnlyType = values.contentType.map(isDisplayOnlyType) ?? false
            facts.isOnVolumeWithoutPermissions = isOnVolumeWithoutPermissions(canonical)
            // The key also answers for a symbolic link, and the path's links
            // are resolved, so what it finds here is a Finder alias.
            facts.isAlias = values.isAliasFile ?? false
            facts.hasOwnOpener = hasOwnOpener(canonical)
            if facts.isDirectory, !facts.isPackage {
                facts.isOpenedOutsideFileManager = !opensInFinder(canonical)
            }
        }
        var handler: PreparedCommand?
        if line > 0, !command.isEmpty, Ubiquitty.Attributes.LinkRun.lineHandlerTakes(facts) {
            let argv = lineHandlerArgv(for: canonical.path, line: line, column: column, command: command)
            if let program = argv.first {
                handler = PreparedCommand(argv: argv, executable: executableURL(for: program))
            }
        }
        return InspectedFile(canonical: canonical, facts: facts, lineHandler: handler)
    }

    /// The argv the reader's `[links] line_handler` runs for one file at a
    /// line, or empty when none is configured.
    ///
    /// - Parameters:
    ///   - path: The canonical path the click judged.
    ///   - line: The line and column the link names.
    /// - Returns: The argv.
    private static func configuredLineHandlerCommand() -> String {
        String(Ubiquitty.Preferences.Effective.linkLineHandler(Ubiquitty.Preferences.values().pointee))
    }

    nonisolated private static func lineHandlerArgv(for path: String, line: UInt32, column: UInt32, command: String) -> [String] {
        var argv: [String] = []
        command.withCString { commandBytes in
            path.withCString { pathBytes in
                for argument in Ubiquitty.Attributes.LinkRun.lineHandlerArgv(
                    std.string_view(commandBytes),
                    std.string_view(pathBytes),
                    line,
                    column
                ) {
                    argv.append(String(argument))
                }
            }
        }
        return argv
    }

    /// Whether the system would run a file of this type rather than show it.
    ///
    /// The broad system types rather than a list of their subtypes, so an
    /// application bundle, a shell script or a `.command` file conforms
    /// without being named here. A page is among them: the browser a page
    /// opens in runs its script under a `file:` origin. A makefile is not:
    /// `public.make-source` conforms to `public.script`, but nothing runs one
    /// on open (editors and Xcode claim it, and `make` reads it only when
    /// invoked), and a `Makefile` with an execute bit and a `#!` line still
    /// types as one and opens in Xcode.
    ///
    /// - Parameter type: The file's content type.
    /// - Returns: Whether it is an application, an executable or a script
    ///   other than a makefile, or HTML, XHTML or SVG.
    nonisolated private static func isLaunchableType(_ type: UTType) -> Bool {
        let isPage = type.conforms(to: .html) || type.conforms(to: .svg) || UTType("public.xhtml").map { type.conforms(to: $0) } == true
        let isMakefile = UTType("public.make-source").map { type.conforms(to: $0) } == true
        let isScript = type.conforms(to: .script) && !isMakefile
        return type.conforms(to: .application) || type.conforms(to: .executable) || isScript || isPage
    }

    /// Whether the system hands a file of this type to a viewer, whatever its
    /// permissions say.
    ///
    /// Launch Services picks the program by type, so a `.txt` with a stray
    /// execute bit still opens in a text editor and a photo in Preview. A
    /// script is text to the type system too; ``isLaunchableType(_:)`` is what
    /// reveals it.
    ///
    /// - Parameter type: The file's content type.
    /// - Returns: Whether it is text, an image, audio or video, or a PDF.
    nonisolated private static func isDisplayOnlyType(_ type: UTType) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
    }

    /// Whether a file sits on a volume that keeps no permissions.
    ///
    /// FAT and exFAT report every file as executable, and the volume says it
    /// keeps no permissions through `VOL_CAP_FMT_NO_PERMISSIONS`, which APFS
    /// and HFS+ leave clear.
    ///
    /// - Parameter url: The file, its symbolic links resolved.
    /// - Returns: Whether its volume reports the capability.
    nonisolated private static func isOnVolumeWithoutPermissions(_ url: URL) -> Bool {
        /// The buffer `getattrlist` fills: its length, then the capabilities.
        struct VolumeCapabilities {
            var length: UInt32 = 0
            var capabilities = vol_capabilities_attr_t()
        }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.volattr = attrgroup_t(truncatingIfNeeded: ATTR_VOL_INFO) | attrgroup_t(truncatingIfNeeded: ATTR_VOL_CAPABILITIES)
            var reply = VolumeCapabilities()
            let status = withUnsafeMutableBytes(of: &reply) { getattrlist(path, &request, $0.baseAddress, $0.count, 0) }
            let noPermissions = UInt32(truncatingIfNeeded: VOL_CAP_FMT_NO_PERMISSIONS)
            // The format capabilities are the first word of each set.
            return status == 0 && reply.capabilities.valid.0 & noPermissions != 0
                && reply.capabilities.capabilities.0 & noPermissions != 0
        }
    }

    /// Whether the workspace hands a directory to Finder.
    ///
    /// A directory that is not a package can still carry a type another
    /// program claims by its name: a `.mbox`, `.imapmbox` or `.ewsmbox`
    /// folder opens in Mail, a `.storekit` one in Xcode, and a `.framework`
    /// has no program at all. Each of those is the name's choice rather than
    /// the reader's.
    ///
    /// - Parameter url: The directory, its symbolic links resolved.
    /// - Returns: Whether Finder is the program that opens it.
    nonisolated private static func opensInFinder(_ url: URL) -> Bool {
        guard let application = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() else {
            return false
        }
        return Bundle(url: application as URL)?.bundleIdentifier == "com.apple.finder"
    }

    /// Whether a file carries its own Open With choice.
    ///
    /// Finder writes a per-file choice into this extended attribute, and
    /// Launch Services then opens the file in the program it names rather
    /// than its type's, so a `notes.txt` can name an interpreter that runs
    /// the text as a script. An unpacked archive keeps the attribute and
    /// nothing quarantines it. Only its presence is asked, so a reader's own
    /// choice is shown in Finder too, where it opens the way they chose.
    ///
    /// - Parameter url: The file, its symbolic links resolved.
    /// - Returns: Whether the attribute is present.
    nonisolated private static func hasOwnOpener(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return getxattr(path, "com.apple.LaunchServices.OpenWith", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Runs the reader's `[link_handlers]` command for this URI's scheme.
    ///
    /// The argv is Core's, and the reason it is Core's is that this is where a
    /// mistake becomes a command injection: the URI is attacker-controllable
    /// output, and it stays one argv element from the template's `%s` to the
    /// program's `argv[1]`. `Process` execs the program itself, so nothing ever
    /// parses that element as a command line.
    ///
    /// A failure to launch is reported as not handled, so a link with a
    /// mistyped handler still opens the way it would have with none.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: Whether a handler was launched.
    private static func launchConfiguredHandler(for uri: String) -> Bool {
        let command = configuredHandlerCommand(for: uri)
        if command.isEmpty {
            return false
        }
        let argv = configuredHandlerArgv(for: uri, command: command)
        let scheme = uri.withCString { String(Ubiquitty.Attributes.LinkRun.schemeOfURI(std.string_view($0))) }
        return launch(argv, describing: "link handler for " + scheme)
    }

    nonisolated private static func configuredHandlerArgv(for uri: String, command: String) -> [String] {
        var argv: [String] = []
        command.withCString { commandBytes in
            uri.withCString { uriBytes in
                for argument in Ubiquitty.Attributes.LinkRun.linkHandlerArgv(
                    std.string_view(commandBytes),
                    std.string_view(uriBytes)
                ) {
                    argv.append(String(argument))
                }
            }
        }
        return argv
    }

    /// The reader's `[link_handlers]` command for this URI's scheme.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: The command template, or empty when none is configured.
    private static func configuredHandlerCommand(for uri: String) -> String {
        let scheme = uri.withCString { String(Ubiquitty.Attributes.LinkRun.schemeOfURI(std.string_view($0))) }
        if scheme.isEmpty {
            return ""
        }
        return scheme.withCString {
            String(
                Ubiquitty.Preferences.Effective.linkHandlerCommand(
                    Ubiquitty.Preferences.values().pointee,
                    std.string_view($0)
                )
            )
        }
    }

    /// Runs a handler's argv as a program, through no shell.
    ///
    /// A bare name is looked up on `PATH` here rather than by a program
    /// started to look it up, such as `env`: that program starts whether or
    /// not the name is found, so a handler missing from the app's `PATH`
    /// would read as started and its fallback would never run.
    ///
    /// - Parameters:
    ///   - argv: The program, then its arguments.
    ///   - what: What the handler is, for the log line a failure leaves.
    /// - Returns: Whether the program was started.
    private struct PreparedCommand: Sendable {
        let argv: [String]
        let executable: URL?
    }

    private static func launch(_ argv: [String], describing what: String) -> Bool {
        guard let program = argv.first else {
            return false
        }
        return launch(PreparedCommand(argv: argv, executable: executableURL(for: program)), describing: what)
    }

    private static func launch(_ command: PreparedCommand, describing what: String) -> Bool {
        guard let program = command.argv.first else {
            return false
        }
        guard let executable = command.executable else {
            NSLog("%@ failed to launch: %@ is not on PATH", what, program)
            return false
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(command.argv.dropFirst())
        do {
            try process.run()
        } catch {
            NSLog("%@ failed to launch: %@", what, String(describing: error))
            return false
        }
        return true
    }

    /// The file a handler's program name runs.
    ///
    /// A name with a slash in it is a path, read against the current
    /// directory when it is relative. Any other name is looked for in each
    /// directory the app's `PATH` names, in order, or in `/usr/bin` and
    /// `/bin` when it has none, and the first executable file found is the
    /// program. An empty entry names no directory here, though `execvp`
    /// would read it as the current one.
    ///
    /// - Parameter program: The first word of the handler's command.
    /// - Returns: The file to run, or nil when a bare name is found nowhere.
    nonisolated private static func executableURL(for program: String) -> URL? {
        if program.contains("/") {
            return URL(fileURLWithPath: program, isDirectory: false)
        }
        let files = FileManager.default
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(program, isDirectory: false)
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                files.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }

    /// The URL the workspace would be handed, or nil when this URI may not be
    /// opened at all.
    ///
    /// Terminal output is bytes, not a URL: a link can carry a byte `NSURL`
    /// refuses to parse, and percent-encoding it is what makes a real link with
    /// a space or a bracket in it open at all. The allowlist is applied after
    /// the retry, so the encoding never smuggles a scheme past it.
    ///
    /// Answerable on its own so a caller — or a test — can ask what a link
    /// would open as without opening it.
    ///
    /// - Parameter uri: The link target.
    /// - Returns: A launchable URL, or nil.
    public static func launchableURL(for uri: String) -> URL? {
        var url = URL(string: uri)
        if url == nil, let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url = URL(string: encoded)
        }
        guard let url, let scheme = url.scheme else {
            return nil
        }
        let isLaunchable = (scheme.lowercased() + ":")
            .withCString {
                Ubiquitty.Attributes.LinkRun.isLaunchableURLScheme(std.string_view($0))
            }
        return isLaunchable ? url : nil
    }
}
