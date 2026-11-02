// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

import enum UbiquittyRenderKit.HostOutlineBlockKind
import enum UbiquittyRenderKit.HostOutlineStatus

// The rules every screen of the app draws by, held in one place so a screen
// cannot drift from them by spelling its own: how a sheet is confirmed and
// canceled, which colour says what, which symbol names which thing, and when
// the device answers a touch with a haptic. The iOS 26 and 27 components
// every screen uses in place of drawing its own (glass, toolbar groups and
// overflow, item-driven dialogs, toolbar search, sheet placement) are listed
// in Docs/ios-interface.md.

/// The symbol for each thing the app names, one per concept.
///
/// A symbol is a word: `rectangle.split.2x1` says "split", so it appears only
/// on the actions that split, and a list of tabs is not drawn with it.
enum InterfaceSymbol {
    /// A terminal session, and the pane that shows one.
    static let session = "terminal"
    /// The tabs of a workspace.
    static let tabs = "square.on.square"
    /// Splitting a pane side by side.
    static let splitRight = "rectangle.split.2x1"
    /// Splitting a pane one above the other.
    static let splitDown = "rectangle.split.1x2"
    /// A workspace on a host.
    static let workspace = "macwindow"
    /// The workspaces of a host, as a list.
    static let workspaces = "rectangle.stack"
    /// Something that went wrong, always red and never without text.
    static let error = "exclamationmark.circle.fill"
    /// More about the row it sits in.
    static let info = "info.circle"
    /// A program waiting for the person's answer.
    static let attention = "hand.raised.fill"
    /// A connection that could not be made, at the head of what explains it.
    static let connectionFailed = "exclamationmark.triangle.fill"
    /// A step that went through, in a list of steps.
    static let stepSucceeded = "checkmark.circle.fill"
    /// A step that failed, in a list of steps.
    static let stepFailed = "xmark.circle.fill"
    /// Sharing what the app knows, as a file or text.
    static let share = "square.and.arrow.up"
}

/// What a line of status means, and so the colour it is drawn in.
///
/// Red is for what went wrong and green only for a live connection; any other
/// state is secondary text. A program's status is the one exception, and it
/// is drawn by ``ProgramStatusMark``, whose symbol says the state before its
/// colour does. The accent colour is left to what can be tapped,
/// so a coloured word is never mistaken for a control and orange says nothing.
enum StatusTone {
    case state
    case error
    case connected

    var color: Color {
        switch self {
        case .state: .secondary
        case .error: .red
        case .connected: .green
        }
    }
}

/// A program's status as a mark of its own shape and colour, so two states
/// are told apart in grayscale and by a person who does not see the colour.
///
/// Shape first: each state has its own symbol, and the colour repeats what
/// the shape says. Red says failed, orange says waiting for the person, green
/// says running, blue says working; a state that asks nothing is secondary.
struct ProgramStatusMark: View {
    @ScaledMetric(relativeTo: .body)
    private var iconColumnWidth = 22.0
    let status: HostOutlineStatus
    var isSaved = false
    /// What a blocked program waits for, which its symbol says.
    var blockKind: HostOutlineBlockKind = .none

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tone)
            .frame(width: iconColumnWidth)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if isSaved { return "clock.arrow.circlepath" }
        return Self.symbol(for: status, blockKind: blockKind)
    }

    private var tone: Color {
        if isSaved { return .secondary }
        return Self.tone(for: status)
    }

    /// The symbol for a status, and for a blocked one, for what it waits for.
    static func symbol(for status: HostOutlineStatus, blockKind: HostOutlineBlockKind = .none) -> String {
        status.symbolName(blockKind: blockKind)
    }

    /// The colour that repeats what the symbol says.
    static func tone(for status: HostOutlineStatus) -> Color {
        switch status {
        case .failed: StatusTone.error.color
        case .blocked, .attention: .orange
        case .working: .blue
        case .done, .running: StatusTone.connected.color
        case .idle, .none: StatusTone.state.color
        }
    }
}

/// An error, in red beside the symbol that marks it, so it is not told by
/// colour alone.
struct ErrorMessage: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: InterfaceSymbol.error)
        }
        .foregroundStyle(StatusTone.error.color)
    }
}

/// A sheet's buttons, by their system roles, where the system puts them.
///
/// Cancellation leads and confirmation trails. Cancel, Close and Done are
/// role-only buttons: the system draws each one's glass glyph (an xmark for
/// cancel and close, a checkmark for confirm) and supplies its accessibility
/// label, so the app spells none of them. A sheet that only shows something,
/// or applies each change as it is made, is closed with the close role and
/// has no confirmation. A verb that starts an operation rather than finishing
/// the form (Connect, Sign In) keeps its word, with the confirm role so it
/// still takes the prominent style; so does a refusal a request names (Deny).
///
/// A verb is disabled only when the form says why beside the field at fault.
/// The buttons carry no identifier: a test finds them by the label the system
/// gives the role (Cancel, Close, Done) or by the word a verb shows.
struct SheetToolbar: ToolbarContent {
    /// The word for a verb that starts an operation; nil for Done and Save,
    /// which are the system's confirm glyph.
    var confirmTitle: LocalizedStringKey?
    var isConfirmEnabled = true
    var confirm: (() -> Void)?
    /// The word for a refusal a request names (Deny); nil for the system's
    /// cancel glyph.
    var cancelTitle: Text?
    var cancel: (() -> Void)?
    /// Closes a sheet that has nothing to confirm.
    var close: (() -> Void)?

    var body: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close, action: close)
            }
        } else if let cancel {
            ToolbarItem(placement: .cancellationAction) {
                if let cancelTitle {
                    Button(role: .cancel, action: cancel) { cancelTitle }
                } else {
                    Button(role: .cancel, action: cancel)
                }
            }
        }
        if let confirm {
            ToolbarItem(placement: .confirmationAction) {
                Group {
                    if let confirmTitle {
                        Button(confirmTitle, role: .confirm, action: confirm)
                    } else {
                        Button(role: .confirm, action: confirm)
                    }
                }
                .disabled(!isConfirmEnabled)
            }
        }
    }
}

extension SheetToolbar {
    /// A sheet that only shows something, or applies each change as it is
    /// made: nothing is lost by closing it.
    static func close(_ action: @escaping () -> Void) -> SheetToolbar {
        SheetToolbar(close: action)
    }
}

extension EnvironmentValues {
    /// The system's appearance, kept beside `colorScheme` where a screen
    /// over the terminal's ground overrides that one; nil where nothing does.
    ///
    /// A sheet inherits its presenter's environment but draws its ground in
    /// the window's appearance, so a sheet presented from the terminal sets
    /// its scheme back to this one; otherwise a dark terminal in a light
    /// system draws white text on a white sheet.
    @Entry
    var systemColorScheme: ColorScheme?
}

extension View {
    /// Dresses a sheet's content by the sheet rules: drawn in the system's
    /// appearance rather than its presenter's, with its bar, and so its
    /// Cancel and verb, held on screen while the form scrolls.
    ///
    /// A short display minimizes a bar on scroll, as iPhone Duo's folded
    /// display does; in a sheet that takes the only way to finish or cancel
    /// it off screen. The folded display also lays a window's bar items on
    /// a vertical rail, and takes a sheet's lone Cancel or Close glyph there,
    /// out of the sheet it closes; a sheet's bar stays horizontal so its
    /// buttons stay in it.
    func sheetChrome() -> some View {
        modifier(SheetChrome())
    }
}

private struct SheetChrome: ViewModifier {
    @Environment(\.systemColorScheme)
    private var systemColorScheme
    @Environment(\.colorScheme)
    private var colorScheme

    func body(content: Content) -> some View {
        let dressed = content.environment(\.colorScheme, systemColorScheme ?? colorScheme)
        if #available(iOS 27.1, *) {
            dressed
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
                .toolbarVerticalBehavior(.disabled)
        } else if #available(iOS 27.0, *) {
            dressed.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            dressed
        }
    }
}

/// A count that changes each time something settles, and whether it went
/// well: the trigger a success or error haptic answers.
///
/// A count rather than a flag, so two failures in a row are two changes.
struct SettledOutcome: Equatable {
    private(set) var count = 0
    private(set) var succeeded = true

    mutating func record(succeeded: Bool) {
        count += 1
        self.succeeded = succeeded
    }

    /// The haptic the HIG gives an outcome: success or error.
    static func feedback(_: SettledOutcome, _ new: SettledOutcome) -> SensoryFeedback? {
        new.count == 0 ? nil : new.succeeded ? .success : .error
    }
}

/// The haptics UIKit controls play, which have no SwiftUI trigger.
///
/// Both follow the system's System Haptics setting, so a person who turned
/// haptics off feels none of them.
@MainActor
enum InterfaceHaptics {
    /// A choice moved: a modifier toggled, a handle grabbed.
    static func selectionChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// The word for this device in interface text: iPhone or iPad.
///
/// Text that names the device says the one in the person's hand, as
/// Settings does, rather than a generic "device".
@MainActor
enum InterfaceDevice {
    /// "iPad" on an iPad, and "iPhone" on every other device.
    static var name: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// The longer explanation behind a footer's Learn More link.
///
/// A footer says what a control does in a sentence or two; the rest of what
/// a careful reader may want, such as what is kept where and who can use it,
/// is here, one tap away, rather than in a paragraph under every form.
struct LearnMoreTopic: Identifiable, Hashable {
    /// The sheet's title, which names the control the footer belongs to.
    let title: String
    /// The explanation, one paragraph per entry.
    let paragraphs: [String]

    /// The title, which no two topics on one screen share.
    var id: String { title }

    /// A footer's sentence followed by a Learn More link to this topic.
    ///
    /// A footer is one `Text`, so the link is a run inside it; the screen's
    /// `openURL` handler maps its address back to the topic.
    ///
    /// - Parameter sentence: What the control does, in a sentence.
    /// - Returns: The footer text with the link at its end.
    func footer(_ sentence: String) -> AttributedString {
        var link = AttributedString(String(localized: "Learn More…"))
        link.link = url
        return AttributedString(sentence + " ") + link
    }

    /// The address a footer's link carries to open this topic.
    var url: URL {
        URL(string: "ubiquitty-help:" + (title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
            ?? URL(fileURLWithPath: "/")
    }
}

extension View {
    /// Opens the topic a footer's Learn More link names, from the topics
    /// this screen offers.
    ///
    /// - Parameters:
    ///   - topics: The topics the screen's footers link to.
    ///   - shown: The topic on screen, nil when none is.
    func learnMoreLinks(_ topics: [LearnMoreTopic], shown: Binding<LearnMoreTopic?>) -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                guard let topic = topics.first(where: { $0.url == url }) else { return .systemAction }
                shown.wrappedValue = topic
                return .handled
            }
        )
        .sheet(item: shown) { topic in
            LearnMoreSheet(topic: topic)
        }
    }
}

/// A Learn More topic, as a sheet finished with Done.
private struct LearnMoreSheet: View {
    @Environment(\.dismiss)
    private var dismiss

    let topic: LearnMoreTopic

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topic.paragraphs, id: \.self) { paragraph in
                        Text(paragraph).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// Asks before a swipe down discards what the sheet holds unsaved.
    ///
    /// - Parameters:
    ///   - hasUnsavedEdits: Whether dismissing would lose an edit.
    ///   - discard: Dismisses the sheet, once the person says to.
    @ViewBuilder
    func guardingUnsavedEdits(_ hasUnsavedEdits: Bool, discard: @escaping () -> Void) -> some View {
        if #available(iOS 27.0, *) {
            dismissalConfirmationDialog("Discard Changes?", shouldPresent: hasUnsavedEdits) {
                Button("Discard Changes", role: .destructive, action: discard)
            }
        } else {
            interactiveDismissDisabled(hasUnsavedEdits)
        }
    }
}
