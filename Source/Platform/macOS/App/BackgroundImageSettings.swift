// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BackgroundImageSettings.swift — the Background Image card's preview well,
// chooser and the three preferences behind it.
//
// The preview is the terminal at actual size over the chosen picture, composed
// by the renderer's rules rather than an approximation of them: the image is
// placed by Core's `backgroundImagePlacement`, decoded by the same ImageIO path
// and size refusal as `BackdropImage`, and covered by the theme's background at
// the alpha Core's `backgroundEffects` gives default cells. A preview that drew
// its own idea of Fill or of the tint would show a picture the window does not.
//
// The app is not sandboxed, so a chosen file stays readable where it is, and
// the stored value is the file's own path: a plain path in the TOML, which is
// Core's contract for the key.
//

import AppKit
import ImageIO
import SwiftUI
import UbiquittyAppBridge
import UbiquittyCore
import UbiquittyKit
import UniformTypeIdentifiers

/// Reads and writes the three `[appearance] background_image*` preferences.
@MainActor
enum BackgroundImageSettings {
    /// The configured file, or empty for no image.
    static var path: String { settingText(.AppearanceBackgroundImage) }

    /// Persists the file. An empty path removes the image, as an emptied key
    /// already does for every renderer.
    static func setPath(_ path: String) {
        setSetting(.AppearanceBackgroundImage, text: path)
    }

    /// Whether an image is configured, whether or not its file can be read.
    static var isSet: Bool { !path.isEmpty }

    /// The placement mode's row in the vocabulary.
    static var modeIndex: Int { settingTermIndex(.AppearanceBackgroundImageMode) }

    static func setModeIndex(_ index: Int) {
        setSetting(.AppearanceBackgroundImageMode, termIndex: index)
    }

    /// The placement mode as the renderer reads it.
    static var mode: Ubiquitty.Rendering.BackgroundImageMode {
        Ubiquitty.Preferences.backgroundImageModeFromString(std.string(settingText(.AppearanceBackgroundImageMode))).value ?? .Fill
    }

    static var opacity: Double { settingDouble(.AppearanceBackgroundImageOpacity) }

    /// Persists the image's opacity, clamped by the schema row the parser
    /// clamps a hand-edited value with.
    static func setOpacity(_ opacity: Double) {
        let bounded = Ubiquitty.Preferences.Schema.clampToRange(opacity, "appearance", "background_image_opacity")
        setSetting(.AppearanceBackgroundImageOpacity, double: bounded)
    }

    /// One sentence for the chosen placement, under the Mode menu.
    static func modeDescription(_ mode: Ubiquitty.Rendering.BackgroundImageMode) -> String {
        switch mode {
        case .Fill: "Covers the window, cropping what overflows."
        case .Fit: "Shows the whole image, scaled to fit inside the window."
        case .Stretch: "Fills the window exactly, ignoring the image’s proportions."
        case .Tile: "Repeats the image at its actual size."
        case .Center: "Shows the image once at its actual size, centered."
        @unknown default: "How the image is placed in the window."
        }
    }

    /// The file types the background decode reads: whatever ImageIO opens
    /// that is a picture (PNG, JPEG, TIFF, HEIC, GIF, WebP and more), so the
    /// chooser offers exactly what the renderer can show.
    static let supportedTypes: [UTType] = {
        let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let types = identifiers.compactMap(UTType.init).filter { $0.conforms(to: .image) }
        return types.isEmpty ? [.png, .jpeg, .tiff, .heic] : types
    }()

    /// Whether `url` is a file the decode can read, by its declared type.
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL,
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }
}

/// Presents the open panel for a background image.
@MainActor
enum BackgroundImageChooser {
    /// Asks for an image file and hands its path to `choose`.
    ///
    /// A sheet on the window in front when there is one, so the panel belongs
    /// to the Settings window that asked; a free-standing panel otherwise, as
    /// from the command palette with no window key.
    ///
    /// - Parameters:
    ///   - currentPath: The configured file, whose folder the panel opens in.
    ///   - choose: Receives the chosen file's path.
    static func present(currentPath: String, choose: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Background Image"
        panel.prompt = "Choose"
        panel.message = "Choose a picture to show behind the terminal."
        panel.allowedContentTypes = BackgroundImageSettings.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        } else if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pictures
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            choose(url.path)
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            Task { @MainActor in finish(await panel.beginSheetModal(for: window)) }
        } else {
            finish(panel.runModal())
        }
    }
}

/// A background image decoded for the preview.
///
/// A thumbnail stands in for the picture, but placement is computed from
/// the file's own pixel size, which is what the renderer places by: Center and
/// Tile show the picture at its actual size, and a thumbnail's size would
/// show it larger or smaller than the window does.
final class BackgroundImagePicture: @unchecked Sendable {
    /// What a decode of the configured path found.
    enum Outcome: Sendable {
        case picture(BackgroundImagePicture)
        /// Nothing is at the path.
        case missing
        /// A file is there, but ImageIO cannot read it as an image.
        case unreadable
        /// The image is larger than the decoder accepts for any picture.
        case tooLarge
    }

    let thumbnail: CGImage
    let pixelWidth: Int
    let pixelHeight: Int

    private init(thumbnail: CGImage, pixelWidth: Int, pixelHeight: Int) {
        self.thumbnail = thumbnail
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The longest side of the thumbnail: past a preview's backing size at
    /// 2x, so Fill's crop of a large picture stays sharp.
    private static let thumbnailSide = 2048

    /// Reads `path` the way the renderer's decode does.
    ///
    /// The EXIF orientation is not applied, because the renderer's
    /// `CGImageSourceCreateImageAtIndex` does not apply it either, and the
    /// size limit is the renderer's too: Core's axis limit, without the byte
    /// budget an image a program sends is also held to.
    nonisolated static func decode(path: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return .unreadable }
        guard !Ubiquitty.Image.isDecodedImageSizeRefused(Int64(width), Int64(height)) else { return .tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .unreadable
        }
        return .picture(BackgroundImagePicture(thumbnail: thumbnail, pixelWidth: width, pixelHeight: height))
    }
}

/// What the preview shows, read from the live preferences.
@MainActor
final class BackgroundImagePreviewModel: ObservableObject {
    /// Why the theme's background hides the image completely, if it does.
    enum Concealment: Equatable {
        /// Background Opacity is 100%.
        case opaqueBackground
        /// Reduce Transparency keeps every window opaque.
        case reducedTransparency
    }

    @Published
    private(set) var path = ""
    /// The decode of `path`; nil while it runs or when no image is set.
    @Published
    private(set) var outcome: BackgroundImagePicture.Outcome?
    @Published
    private(set) var mode = Ubiquitty.Rendering.BackgroundImageMode.Fill
    @Published
    private(set) var imageOpacity = 1.0
    @Published
    private(set) var theme: ThemeSnapshot?
    /// The alpha default-background cells are drawn with over the image.
    @Published
    private(set) var groundOpacity = 1.0
    @Published
    private(set) var concealment: Concealment?
    @Published
    private(set) var fontFamily = ""
    @Published
    private(set) var fontSize = 13.0

    /// The last few decoded files, so returning to the pane, a theme change
    /// or going back to a previous choice does not decode the picture again.
    /// Keyed by path and modification date: a file replaced in place is
    /// decoded afresh.
    private static var cache: [String: BackgroundImagePicture.Outcome] = [:]
    private static let cacheLimit = 4

    private static func remember(_ outcome: BackgroundImagePicture.Outcome, for key: String) {
        if cache.count >= cacheLimit, cache[key] == nil { cache.removeAll() }
        cache[key] = outcome
    }
    private var decoding: Task<Void, Never>?

    /// Re-reads every input the preview draws from.
    ///
    /// - Parameter isDark: Whether the Settings window is in dark appearance,
    ///   which picks the theme when the terminal follows the system.
    func refresh(isDark: Bool) {
        mode = BackgroundImageSettings.mode
        imageOpacity = BackgroundImageSettings.opacity
        fontFamily = settingText(.FontFamily)
        fontSize = settingDouble(.FontSize)
        let index = Self.shownThemeIndex(isDark: isDark)
        theme = index >= 0 ? ThemeSnapshot.load(index, name: "", builtInCount: 0) : nil
        let appearance = Ubiquitty.Themes.get(Int32(index))?.pointee.appearance ?? Ubiquitty.Themes.ThemeAppearance()
        let isReduced = SystemDisplayOptions.shouldReduceTransparency
        let effects = Ubiquitty.Preferences.Effective.backgroundEffects(
            Ubiquitty.Preferences.values().pointee,
            isReduced ? .Reduced : .Allowed,
            appearance
        )
        // The renderer's rule for a default-background cell: the frame's
        // opacity times the default cells' own (CellInstanceBuilder).
        groundOpacity = effects.rendererOpacity * effects.defaultBackgroundOpacity
        if groundOpacity < 1 {
            concealment = nil
        } else if isReduced && settingDouble(.AppearanceBackgroundOpacity) < 1 {
            concealment = .reducedTransparency
        } else {
            concealment = .opaqueBackground
        }
        load(BackgroundImageSettings.path)
    }

    /// Decodes `newPath` off the main thread, unless it is the decode on show.
    ///
    /// - Parameter newPath: The configured file.
    func load(_ newPath: String) {
        guard !newPath.isEmpty else {
            decoding?.cancel()
            path = newPath
            outcome = nil
            return
        }
        let key = Self.cacheKey(newPath)
        if let cached = Self.cache[key] {
            decoding?.cancel()
            path = newPath
            outcome = cached
            return
        }
        if newPath != path { outcome = nil }
        path = newPath
        decoding?.cancel()
        decoding = Task { [weak self] in
            let decoded =
                await Task.detached(priority: .userInitiated) {
                    BackgroundImagePicture.decode(path: newPath)
                }
                .value
            guard !Task.isCancelled, let self, self.path == newPath else { return }
            Self.remember(decoded, for: key)
            self.outcome = decoded
        }
    }

    /// Decodes `path` now and keeps it for the next preview: for a caller that
    /// renders the preview at once and cannot wait for the decode.
    static func prime(_ path: String) {
        remember(BackgroundImagePicture.decode(path: path), for: cacheKey(path))
    }

    private static func cacheKey(_ path: String) -> String {
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(path)\u{0}\(modified)"
    }

    /// The theme a terminal opened now would show: the pinned theme, or the
    /// automatic appearance's for the current light or dark mode.
    private static func shownThemeIndex(isDark: Bool) -> Int {
        let name = settingText(.AppearanceTheme)
        if settingBool(.AppearanceFollowSystem) || name.isEmpty {
            return Int(isDark ? Ubiquitty.SwiftBridge.systemDarkTheme() : Ubiquitty.SwiftBridge.systemLightTheme())
        }
        return Int(Ubiquitty.Themes.indexForName(name))
    }
}

/// The terminal at actual size over the background image.
struct BackgroundImagePreview: View {
    @ObservedObject
    var model: BackgroundImagePreviewModel

    var body: some View {
        let background = model.theme.map { ColorPack.color($0.background) } ?? Color(nsColor: .textBackgroundColor)
        ZStack(alignment: .topLeading) {
            if case .picture(let picture) = model.outcome {
                BackgroundImagePlacementCanvas(picture: picture, mode: model.mode)
                    .opacity(model.imageOpacity)
            }
            // The theme's tint over the picture, at the alpha the window
            // gives it: what decides how much of the image shows through.
            background.opacity(isPictureShown ? model.groundOpacity : 1)
            sampleText
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private var isPictureShown: Bool {
        if case .picture = model.outcome { return true }
        return false
    }

    private var font: Font {
        let size = CGFloat(model.fontSize)
        if !model.fontFamily.isEmpty, NSFontManager.shared.availableMembers(ofFontFamily: model.fontFamily) != nil {
            return .custom(model.fontFamily, fixedSize: size)
        }
        return .system(size: size, design: .monospaced)
    }

    @ViewBuilder
    private var sampleText: some View {
        if let theme = model.theme {
            let foreground = ColorPack.color(theme.foreground)
            let blue = ColorPack.color(theme.ansi[4])
            let green = ColorPack.color(theme.ansi[2])
            let red = ColorPack.color(theme.ansi[1])
            let magenta = ColorPack.color(theme.ansi[5])
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("~/Projects/site").foregroundColor(blue)) \(Text("main").foregroundColor(magenta)) $ ls")
                Text(
                    "\(Text("assets").foregroundColor(blue))   \(Text("pages").foregroundColor(blue))   index.html   \(Text("deploy.sh").foregroundColor(green))"
                )
                Text("\(Text("~/Projects/site").foregroundColor(blue)) \(Text("main").foregroundColor(magenta)) $ git status --short")
                Text("\(Text(" M").foregroundColor(red)) pages/about.md")
                Text("\(Text("A ").foregroundColor(green)) assets/hero.jpg")
                HStack(spacing: 0) {
                    Text("\(Text("~/Projects/site").foregroundColor(blue)) \(Text("main").foregroundColor(magenta)) $ ")
                    Rectangle()
                        .fill(ColorPack.color(theme.cursor))
                        .frame(width: CGFloat(model.fontSize) * 0.6, height: CGFloat(model.fontSize) * 1.2)
                }
            }
            .foregroundStyle(foreground)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
        }
    }
}

/// Draws the picture where the renderer would put it in a window this size.
private struct BackgroundImagePlacementCanvas: View {
    let picture: BackgroundImagePicture
    let mode: Ubiquitty.Rendering.BackgroundImageMode
    @Environment(\.displayScale)
    private var displayScale

    var body: some View {
        Canvas { context, size in
            // Core places in device pixels, as the renderer does: a picture
            // at actual size covers its pixels, not its pixels in points.
            let scale = max(displayScale, 1)
            let placement = Ubiquitty.Rendering.backgroundImagePlacement(
                mode,
                Float(size.width * scale),
                Float(size.height * scale),
                Float(picture.pixelWidth),
                Float(picture.pixelHeight)
            )
            let thumbnail = picture.thumbnail
            if placement.shouldRepeat {
                let tile = CGSize(
                    width: CGFloat(picture.pixelWidth) / scale,
                    height: CGFloat(picture.pixelHeight) / scale
                )
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .tiledImage(
                        Image(decorative: thumbnail, scale: 1),
                        origin: .zero,
                        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                        scale: tile.width / CGFloat(thumbnail.width)
                    )
                )
                return
            }
            let destination = CGRect(
                x: CGFloat(placement.leftInPixels) / scale,
                y: CGFloat(placement.topInPixels) / scale,
                width: CGFloat(placement.rightInPixels - placement.leftInPixels) / scale,
                height: CGFloat(placement.bottomInPixels - placement.topInPixels) / scale
            )
            let width = CGFloat(thumbnail.width)
            let height = CGFloat(thumbnail.height)
            let crop = CGRect(
                x: CGFloat(placement.u0) * width,
                y: CGFloat(placement.v0) * height,
                width: CGFloat(placement.u1 - placement.u0) * width,
                height: CGFloat(placement.v1 - placement.v0) * height
            )
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !crop.isEmpty, let cropped = thumbnail.cropping(to: crop) else { return }
            context.draw(Image(decorative: cropped, scale: 1), in: destination)
        }
    }
}

/// The Background Image row: the preview well, the chooser beneath it, and
/// what the reader needs to know when the image cannot show.
struct BackgroundImageField: View {
    let label: String
    let get: @MainActor () -> String
    let set: @MainActor (String) -> Void
    @StateObject
    private var model = BackgroundImagePreviewModel()
    @State
    private var isTargeted = false
    @FocusState
    private var isWellFocused: Bool
    @Environment(\.colorScheme)
    private var colorScheme

    private static let wellRadius: CGFloat = 8

    init(
        label: String,
        get: @escaping @MainActor () -> String,
        set: @escaping @MainActor (String) -> Void,
        model: BackgroundImagePreviewModel? = nil
    ) {
        self.label = label
        self.get = get
        self.set = set
        if let model { _model = StateObject(wrappedValue: model) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            well
            controls
            if let note {
                note
            }
        }
        .onAppear { refresh() }
        .onChangeCompatibility(of: colorScheme) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .terminalAppearanceChanged)) { _ in refresh() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A file moved or restored while the app was in the background.
            refresh()
        }
    }

    private func refresh() {
        model.refresh(isDark: colorScheme == .dark)
    }

    private var path: String { model.path }
    private var fileName: String { (path as NSString).lastPathComponent }

    private func choose() {
        BackgroundImageChooser.present(currentPath: get()) { chosen in
            set(chosen)
            refresh()
        }
    }

    private func remove() {
        set("")
        refresh()
    }

    // MARK: - Well

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Self.wellRadius, style: .continuous)
        return ZStack {
            if path.isEmpty {
                emptyState
            } else {
                BackgroundImagePreview(model: model)
                if let problem {
                    problemBadge(problem)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(shape)
        .overlay {
            if path.isEmpty {
                shape.strokeBorder(
                    isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [5, 4])
                )
            } else {
                shape.strokeBorder(
                    isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                    lineWidth: isTargeted ? 2 : 0.5
                )
            }
        }
        .overlay {
            if isWellFocused {
                shape.inset(by: -3).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            }
        }
        .contentShape(shape)
        .onTapGesture(count: 2) { choose() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: BackgroundImageSettings.accepts) else { return false }
            set(url.path)
            refresh()
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isWellFocused)
        .onKeyPress(keys: [.space, .return]) { _ in
            choose()
            return .handled
        }
        .onDeleteCommand {
            if !path.isEmpty { remove() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + " preview")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Drop an image file here, or press to choose one.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose() }
        .accessibilityAction(named: "Remove") { remove() }
        .accessibilityIdentifier("settings-background-image-well")
        .help(path.isEmpty ? "Drop an image here, or double-click to choose one." : path)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text("Drop an image here, or choose one")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    /// What stops a configured image from showing, in the reader's words.
    private var problem: String? {
        switch model.outcome {
        case .missing: "The file can’t be found"
        case .unreadable: "The file isn’t an image Ubiquitty can open"
        case .tooLarge: "The image is too large to show"
        case .picture, .none: nil
        }
    }

    private func problemBadge(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private var accessibilityValue: String {
        if path.isEmpty { return "None" }
        if let problem { return fileName + ", " + problem }
        return fileName
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Choose…", action: choose)
                .accessibilityLabel("Choose Background Image…")
                .accessibilityIdentifier("settings-background-image-choose")
            if !path.isEmpty {
                Button("Remove", action: remove)
                    .accessibilityLabel("Remove Background Image")
                    .accessibilityIdentifier("settings-background-image-remove")
                Text(fileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .padding(.leading, 4)
                    .accessibilityLabel("File: " + fileName)
            }
            Spacer(minLength: 0)
        }
    }

    /// Why a picture that decoded is not visible, when the theme covers it.
    private var note: AnyView? {
        guard case .picture = model.outcome, let concealment = model.concealment else { return nil }
        let text: String
        switch concealment {
        case .opaqueBackground:
            text = "Background Opacity is 100%, so the theme’s color covers the image."
        case .reducedTransparency:
            text = "Reduce Transparency is on, so windows stay opaque and the image is hidden."
        }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if concealment == .opaqueBackground {
                    Button("Adjust…") {
                        SettingsBridge.app?.revealSettingsRow("appearance.background_opacity", inCategory: "appearance")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityLabel("Adjust Background Opacity")
                }
            }
        )
    }
}
