// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit

/// Embeds a process-free terminal specimen in Settings.
struct RenderedSettingsSample: NSViewRepresentable {
    var sample: String
    var family: String?
    var features: String?
    var showsCursor = false
    var isActive = true
    var cursorStep = 0

    final class Coordinator {
        var cursorStep: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalSettingsPreview {
        TerminalSettingsPreview(frame: .zero)
    }

    static func dismantleNSView(_ view: TerminalSettingsPreview, coordinator: Coordinator) {
        view.releaseSurface()
    }

    func updateNSView(_ view: TerminalSettingsPreview, context: Context) {
        view.familyOverride = family
        view.featuresOverride = features
        view.showsCursor = showsCursor
        view.isPreviewActive = isActive
        view.sample = sample
        if showsCursor, context.coordinator.cursorStep != cursorStep {
            context.coordinator.cursorStep = cursorStep
            view.moveCursor(to: [4, 5, 22, 21][cursorStep % 4])
        }
    }
}

/// Keeps the comparison text independent of the font page being edited.
@MainActor
final class FontSettingsPreviewState: ObservableObject {
    @Published
    var selectedSample = FontPreviewSample.ID.code
}

/// Keeps the result visible while the related controls scroll below it.
struct FontSettingsPreview: View {
    enum Kind { case font, features, routing, rendering, cursor }
    let kind: Kind
    @EnvironmentObject
    private var previewState: FontSettingsPreviewState
    @State
    private var cursorStep = 0
    @State
    private var isActive = true
    @State
    private var pointSize = settingDouble(.FontSize)

    private var samples: [FontPreviewSample] {
        [Self.code, Self.characters, Self.languages, Self.drawing, Self.underlines, Self.mixed] + FontRoutePreview.samples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                if kind == .cursor {
                    Picker("Preview focus", selection: $isActive) {
                        Text("Active").tag(true)
                        Text("Inactive").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button("Move Cursor") { cursorStep += 1 }
                        .disabled(!isActive)
                        .help("Alternate short steps and long jumps, then pause to see the blink delay.")
                } else {
                    Picker("Preview sample", selection: $previewState.selectedSample) {
                        ForEach(samples) { sample in
                            Text(sample.title).tag(sample.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
            RenderedSettingsSample(
                sample: kind == .cursor
                    ? Self.cursorSample : samples.first(where: { $0.id == previewState.selectedSample })?.text ?? Self.code.text,
                showsCursor: kind == .cursor,
                isActive: isActive,
                cursorStep: cursorStep
            )
            .frame(height: kind == .cursor ? 78 : 108)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityIdentifier("settings-terminal-preview")
            Text(
                kind == .cursor
                    ? "Move the cursor to compare motion and the pause before blinking."
                    : "Terminal rendering at actual size · \(pointSize.formatted()) pt"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .padding(.horizontal, SettingsStyle.pageInset)
        .padding(.vertical, 12)
        .frame(maxWidth: SettingsStyle.contentWidth)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .terminalAppearanceChanged)) { _ in
            pointSize = settingDouble(.FontSize)
        }
    }

    static let code = FontPreviewSample(
        .code,
        title: "Code",
        text:
            "\u{1b}[36mfunc\u{1b}[0m greet(name: String) {\r\n"
            + "  \u{1b}[32mprint\u{1b}[0m(\"Hello, world!\")\r\n"
            + "}  \u{1b}[2m// -> => != <= >= ===\u{1b}[0m\r\n"
            + "\u{1b}[1mBold\u{1b}[0m  \u{1b}[3mItalic\u{1b}[0m  \u{1b}[4mUnderline gyjp\u{1b}[0m"
    )
    static let characters = FontPreviewSample(
        .characters,
        title: "Characters",
        text:
            "abcdefghijklmnopqrstuvwxyz\r\nABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n"
            + "0123456789  O0 o0 iIl1  {} [] ()\r\n-> => != <= >= === |> /// aefgilmrtwy"
    )
    static let languages = FontPreviewSample(
        .languages,
        title: "Languages & Symbols",
        text:
            "東京 가나다 オペレーション\r\nسلام دنیا  שלום עולם\r\n"
            + "Привет γειά नमस्ते ภาษาไทย\r\n😀 👨‍👩‍👧‍👦    ◆ ∑ ∞"
    )
    static let drawing = FontPreviewSample(
        .drawing,
        title: "Terminal Graphics",
        text:
            "┌──────┬──────┐  ╭──────╮\r\n│ ░▒▓█ │ ▀▄▌▐ │  ╰──────╯\r\n"
            + "└──────┴──────┘   \r\n⠁⠂⠄⡀⠈⠐⠠⢀ ⣀⣤⣶⣿ ⠿⠛⠋⠉ ⣿⣿⣿⣿"
    )
    /// Proportional runs beside grid text: what a program sets with the
    /// sizing protocol's `p=1`, in the proportional family and size, on the
    /// row's own baseline.
    static let mixed = FontPreviewSample(
        .mixed,
        title: "Mixed Faces",
        text:
            "grid: the quick brown fox  \u{1b}]66;p=1:c=26;run: the quick brown fox\u{7}\r\n"
            + "\u{1b}[1m\u{1b}]66;p=1:c=14;Bold heading\u{7}\u{1b}[22m  grid text after it, on one baseline\r\n"
            + "\u{1b}[7m \u{1b}]66;p=1:c=10:h=2;centred\u{7} \u{1b}[0m  \u{1b}[4m\u{1b}]66;p=1:c=12;underlined\u{7}\u{1b}[24m  "
            + "\u{1b}]66;p=1:c=4;iiii\u{7}|\u{1b}]66;p=1:c=8;WWWW\u{7}|"
    )
    static let underlines = FontPreviewSample(
        .underlines,
        title: "Underlines & Weight",
        text:
            "\u{1b}[4mUnderline gyjpq\u{1b}[0m\r\n\u{1b}[1;4mBold underline gyjpq\u{1b}[0m\r\n"
            + "\u{1b}[3;4mItalic underline gyjpq\u{1b}[0m\r\n"
            + "\u{1b}[31mNormal red\u{1b}[1m  Bold red\u{1b}[0m"
    )
    static let cursorSample = "Compare the cursor over text\r\n$ echo hello, world!        \r\n\u{1b}[5mBlinking text\u{1b}[0m\u{1b}[2;4H"
}

/// Uses the same native pop-up menu as the other settings selectors.
struct SettingsFontPicker: View {
    let options: [String]
    let get: () -> Int
    let set: (Int) -> Void

    var body: some View {
        MenuControl(options: options, get: get, set: set)
    }
}
