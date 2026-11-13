// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/Web/WebTerminal.cpp — see WebTerminal.h.
//

#include "Platform/Web/WebTerminal.h"
#include "Core/Protocol/Control/JSONSchema.h"
#include "Core/Protocol/Control/MethodRegistry.h"
#include "Core/Protocol/Sync/Notify.h"
#include "Core/Protocol/Sync/StructureConsent.h"
#include "Core/RichText/Blocks.h"
#include "Core/Security/CapabilityConsentText.h"
#include "Core/Session/BackgroundEvents.h"

#include "Core/App/SessionOutlineText.h"
#include "Core/App/TitleCompose.h"
#include "Core/Input/BeamKey.h"
#include "Core/Themes/ChromeStyle.h"

#include "Core/Accessibility/Palette.h"
#include "Core/Attributes/LinkRun.h"
#include "Core/Cell.h"
#include "Core/CellPen.h"
#include "Core/Codec/JSON.h"
#include "Core/Cursor/RenderState.h"
#include "Core/Input/Keybindings.h"
#include "Core/Input/PointerInput.h"
#include "Core/Keys/Keymap.h"
#include "Core/Modes/DisplayIdle.h"
#include "Core/Modes/Focus.h"
#include "Core/Modes/Scroll.h"
#include "Core/Modes/SyncOutput.h"
#include "Core/Mouse/Mouse.h"
#include "Core/OSC/Dispatch.h"
#include "Core/OSC/MousePointerShape.h"
#include "Core/OSC/TextSizing.h"
#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/CursorPreferences.h"
#include "Core/Preferences/EffectiveValue.h"
#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Preferences/PreferencesDefaults.h"
#include "Core/Preferences/RenderStyle.h"
#include "Core/Preferences/Schema.h"
#include "Core/Protocol/Control/SessionTermination.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Rendering/OverlayGeometry.h"
#include "Core/Rendering/OverlaySpanGather.h"
#include "Core/Rendering/StatusRow.h"
#include "Core/Runtime/KeyEncode.h"
#include "Core/Runtime/LaunchTheme.h"
#include "Core/Runtime/TabStripChrome.h"
#include "Core/Runtime/TerminalLaunchSeed.h"
#include "Core/Runtime/TriggerConfig.h"
#include "Core/Screen/Addressing.h"
#include "Core/Screen/ClearBuffer.h"
#include "Core/Screen/CommandBlocks.h"
#include "Core/Screen/Marks.h"
#include "Core/Screen/ScrollSearch.h"
#include "Core/Screen/Scrollback.h"
#include "Core/Screen/ViewPlacement.h"
#include "Core/Selection/SelectionSpans.h"
#include "Core/Selection/SelectionText.h"
#include "Core/Selection/TerminalSelection.h"
#include "Core/Themes/TermPaletteFromTheme.h"
#include "Core/Themes/ThemePreferences.h"
#include "Core/Themes/Themes.h"
#include "Core/Title/Format.h"
#include "Core/Unicode/UTF8Encoder.h"

#include "PAL/PAL.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <format>
#include <limits>
#include <optional>
#include <string>

#include <charconv>
#include <span>
#include <string_view>

namespace Ubiquitty::Web {

// Core calls this on the parse path and expects an answer now; the browser
// answers a clipboard read with a promise. The gap is bridged by staging: a
// write waits to be pulled, a read is requested and served only once the page
// has answered.
class WebTerminal::Clipboard : public ClipboardClient {
public:
    void writeClipboard(ClipboardBuffer buffer, std::span<const char> data) override
    {
        // Only the system clipboard leaves the page. X11's primary and the cut
        // buffers have no browser equivalent, and inventing one would let a
        // program clobber the user's real clipboard through a selector they did
        // not think they were addressing.
        if (buffer != ClipboardBuffer::Clipboard)
            return;
        m_pendingItems.clear();
        m_pendingWrite.assign(data.begin(), data.end());
        m_hasPendingWrite = true;
    }

    // The page cannot answer a read inline, so Core must route every read —
    // even an allowed one — through requestClipboardRead and wait.
    [[nodiscard]] bool requiresAsynchronousClipboardRead() override { return true; }

    [[nodiscard]] bool requestClipboardRead(ClipboardBuffer buffer, std::string_view setSpec, ClipboardReadConfirmation confirmation) override
    {
        if (buffer != ClipboardBuffer::Clipboard)
            return false;
        m_readPending = true;
        // Carried, not discarded. Core's default read policy is Prompt, and it
        // says so by asking for Required here; a frontend that drops the argument
        // turns a policy of "ask the user" into "read it" without either the user
        // or Core learning that the answer was never sought.
        m_needsConfirmation = (confirmation == ClipboardReadConfirmation::Required);
        m_readSet.assign(setSpec.begin(), setSpec.end());
        return true;
    }

    [[nodiscard]] int readClipboard(ClipboardBuffer buffer, std::span<char> out) override
    {
        if (buffer != ClipboardBuffer::Clipboard || m_staged.size() > out.size())
            return -1;
        std::ranges::copy(m_staged, out.begin());
        return static_cast<int>(m_staged.size());
    }

    void provideClipboardReadBytes(ClipboardBuffer buffer, std::span<const char> data) override
    {
        if (buffer == ClipboardBuffer::Clipboard)
            m_staged.assign(data.begin(), data.end());
    }

    // The typed set waits for the page the way the text does: staged whole,
    // pulled by the pump, written through the Async Clipboard API. The same
    // buffer rule as the untyped write — only the system clipboard leaves
    // the page — and the text item also rides the string staging, so a
    // browser that refuses a typed write still lands the text.
    void writeClipboardItems(ClipboardBuffer buffer, std::span<const ClipboardItem> items) override
    {
        if (buffer != ClipboardBuffer::Clipboard)
            return;
        m_pendingItems.clear();
        m_pendingWrite.clear();
        m_hasPendingWrite = items.empty();
        for (const ClipboardItem& item : items) {
            m_pendingItems.push_back({ std::string { item.mime }, std::string(item.bytes.data(), item.bytes.size()) });
            if (mimeIsTextPlain(item.mime)) {
                m_pendingWrite.assign(item.bytes.begin(), item.bytes.end());
                m_hasPendingWrite = true;
            }
        }
    }

    void provideClipboardReadItems(ClipboardBuffer buffer, std::span<const ClipboardItem> items) override
    {
        if (buffer == ClipboardBuffer::Clipboard)
            m_typedStaged.stage(items);
    }

    // No buffer guard on the serves: requestClipboardRead admits only the
    // system clipboard, so every read Core completes through this client is
    // for it.
    [[nodiscard]] int readClipboardTypes(ClipboardBuffer /*buffer*/, std::span<char> out) override
    {
        return m_typedStaged.serveTypes(out);
    }

    [[nodiscard]] int readClipboardItem(ClipboardBuffer /*buffer*/, std::string_view mime, std::span<char> out) override
    {
        return m_typedStaged.serveItem(mime, out);
    }

    struct PendingItem {
        std::string mime;
        std::string bytes;
    };
    std::string m_pendingWrite;
    bool m_hasPendingWrite = false;
    std::vector<PendingItem> m_pendingItems;
    ClipboardReadItemStaging m_typedStaged;
    std::string m_staged;
    std::string m_readSet;
    bool m_readPending = false;
    bool m_needsConfirmation = false;
};

// 8 x 16 is Unifont's own cell, so the fallback is scaled to whatever em size
// the face is drawing at and the two stay interchangeable.
WebTerminal::FontStack::FontStack(int pixelSize, int deviceScale, double lineSpacingCssPixels, int characterSpacingInPixels, const Rendering::Font::FontFallbackPreferences& preferences, const std::string& fontVariations, Rendering::Font::WeightSettings weights, WebFontRasterizer::RunSubstitution runSubstitution)
    // Passed in rather than read from the defaults here. Held as a default, the
    // setting was one no caller could change: a page could ask for a spacing and
    // the stack would rebuild at Core's.
    //
    // CSS pixels times the scale, so it grows with the display like the em size
    // does — the same conversion the other frontends make from a value they read
    // from disk.
    : lineSpacingInPixels(static_cast<int>(lineSpacingCssPixels * deviceScale + 0.5))
    // Core's rule, not a division. Unifont's cell is a fixed 8x16 bitmap and a
    // larger size is drawn by upscaling it; truncating the division draws every
    // size from 16 to 31 at 1x, so `size = 20` renders identically to `size = 16`
    // here and two steps larger on a frontend that rounds up.
    , unifont(Rendering::unifontScaleForRequestedSize(pixelSize, 1.0), lineSpacingInPixels, characterSpacingInPixels)
    , face(unifont, pixelSize, lineSpacingInPixels, characterSpacingInPixels, preferences, deviceScale, fontVariations, weights, runSubstitution)
    // Wraps whichever rasterizer actually draws, so the decorator applies to the
    // Unifont path too. Unifont's own box bitmaps already tile, and the
    // decorator leaves them alone: it edge-stretches a FONT glyph and falls back
    // to procedural only when the font ships none, so a bitmap that already
    // reaches its cell edges is unchanged.
    , boxes(face.isAvailable()
              ? static_cast<Rendering::GlyphRasterizer&>(face)
              : static_cast<Rendering::GlyphRasterizer&>(unifont))
    , renderer(boxes)
    , boxStrokeProfile(Rendering::BoxDrawing::measureBoxStrokeProfile(boxes, renderer.cellWidth(), renderer.cellHeight()))
{
}

WebTerminal::WebTerminal(int rows, int columns, int glyphScale, ConnectionMode mode, WebTerminal* workspace, std::uint32_t sessionID)
    : m_fontRoutePreferences(Preferences::buildFontRoutePreferences(Preferences::values()))
    , m_workspace(workspace)
    , m_workspaceSessionID(sessionID)
    , m_connectionMode(mode)
    , m_ownedSync(workspace ? nullptr : std::make_unique<Protocol::Sync::SyncClientCore>(mode == ConnectionMode::Workspace ? nullptr : &m_terminal, &m_syncObserver))
    , m_sync(workspace ? workspace->m_sync : *m_ownedSync)
    , m_glyphScale(glyphScale > 0 ? glyphScale : 1)
{
    // The delivered settings, taken as one bundle rather than key by key. The
    // page hands Core its config.toml before `create()`, so these are live here,
    // and a member initialiser naming `Defaults::` reads the same number whether
    // or not the person wrote one — so a browser terminal would accept a
    // `line_spacing` and draw rows at the default anyway.
    //
    // Core's fold is what every frame below reads. Taking the same struct here
    // is what makes them one answer: two reads of the same file can resolve a
    // key differently.
    m_configuration = Preferences::Effective::liveRenderConfiguration();
    m_configurationEpoch = Preferences::configurationEpoch();
    // The page is the host's own code, served with its settings: a gate here
    // would be the host's to write, so the host's admission of an effect is
    // the one that stands.
    m_sync.setHostLocation(Protocol::Sync::HostLocation::ServedThisClient);

    // Unifont's 16px cell height, multiplied by the device scale the page passes
    // as glyphScale. The browser's size is not Core's 12pt: a page draws at the
    // bitmap's own cell unless a person names a size.
    // native-default: the browser draws at Unifont's own 16px cell, not Core's 12pt.
    m_fontSize = Preferences::values().fontSize.has_value() ? m_configuration.fontSizePoints : 16.0;
    m_initialFontSize = m_fontSize;
    m_lineSpacing = m_configuration.lineSpacingPoints;
    m_characterSpacingInPixels = Preferences::Effective::characterSpacingInPixels(m_configuration, static_cast<double>(m_glyphScale));
    m_fontWeights = { m_configuration.fontWeight, m_configuration.boldFontWeight };
    m_paddingInsets = { static_cast<float>(m_configuration.paddingLeftPoints), static_cast<float>(m_configuration.paddingRightPoints),
        static_cast<float>(m_configuration.paddingTopPoints), static_cast<float>(m_configuration.paddingBottomPoints) };
    // Both halves before the composition runs: `setLigatures` recomposes, so a
    // seed order that set features first would compose once without the policy
    // and once with it, and the intermediate value would be handed to nothing.
    m_ligatures = m_configuration.hasLigatures ? Rendering::Ligatures::Enabled : Rendering::Ligatures::Disabled;
    setFontFeatures(m_configuration.fontFeatures.string());
    recomposeFontFeatureSettingsCSS();
    m_beamSurface = Preferences::Effective::beamSurface(Preferences::values());
    // Scaled first, rounded once — the arithmetic `setFontSize` already uses.
    // Truncating the POINTS and multiplying after spends the fraction before
    // the device scale can express it: `size = 15.5` drew at 15pt, and at 2x
    // gave 30px where 31 is what it asks for. A fractional size is a size the
    // reader accepts and the field holds, so the raster is the only place it
    // was being lost.
    m_fontPixelSize = static_cast<int>(m_fontSize * m_glyphScale + 0.5);
    m_fonts = std::make_unique<FontStack>(m_fontPixelSize, m_glyphScale, m_lineSpacing, m_characterSpacingInPixels, m_fontRoutePreferences.view(), m_fontVariations, m_fontWeights,
        WebFontRasterizer::runSubstitutionFor(m_ligatures, m_fontFeatures));
    (void)m_terminal.fontRequests.publishActualFont(m_fonts->face.familyName(), m_fontSize);
    m_clipboard = std::make_unique<Clipboard>();
    m_terminal.clipboardClient = m_clipboard.get();
    m_measurer.owner = this;
    m_terminal.textMeasureClient = CheckedPtr<TextMeasureClient>(&m_measurer);
    // Seed the per-Terminal OSC 52 policy from the live preferences, as the
    // other frontends do at pane creation. Without it the fields keep their
    // in-class values — the policy would be whatever Terminal.h happens to
    // declare rather than what was configured.
    Runtime::seedOSC52Policy(m_terminal, Preferences::values());
    // The `[cursor]` block, as the state `Cursor::resolve` falls back to while
    // no program has sent DECSCUSR. A terminal that never receives it answers
    // with its struct defaults — shape zero, a block — so the shape the page
    // handed in through the blob is read here or it reaches nothing.
    Preferences::Effective::applyCursorPreferences(m_terminal, Preferences::values());
    Runtime::seedTekColorPreference(m_terminal, Preferences::values());
    // The reader's colour-vision mode, written where every theme application
    // reads it. The page names the theme later, through setThemeByName, and
    // that application substitutes the palette only if the mode is already
    // here: written after it, the substitution waits for the next theme change.
    Accessibility::paletteAdaptation().mode = Preferences::Effective::colorblindMode(Preferences::values());
    // The configuration's own `[[themes]]` join the registry and its
    // `[appearance] theme` colours the grid, as at every other arm's launch:
    // a page handed a config.toml naming a theme otherwise opened on the
    // palette a fresh Terminal is constructed with. A theme the page names
    // later through setThemeByName applies over this one.
    Themes::registerThemesFromValues(Preferences::values());
    if (const int configured = Runtime::configuredThemeIndex(Preferences::values()); configured >= 0 && Themes::applyThemeToTerminal(m_terminal, configured))
        m_themeIndex = configured;
    // The configuration's trigger rules. They fire as lines complete, so they
    // are installed before any byte arrives; a refused rule renders exactly
    // like one nobody wrote, which is why the refusals reach the console.
    const std::string triggerRejections
        = Runtime::describeTriggerConfig(Runtime::applyTriggerConfig(m_terminal, Preferences::values()));
    if (!triggerRejections.empty())
        PAL::diagWrite("web: " + triggerRejections + "\n");
    // Attached, this grid is a mirror of the host's, so Core must be able to tell
    // the sync client whenever it moves rows out from under it.
    m_terminal.mirrorClient = &m_sync;
    m_terminal.windowClient = &m_window;
    m_terminal.shellClient = &m_shell;
    // Bells reach the page through this terminal's own route, one call per bell,
    // as every frontend's pane receives them.
    m_terminal.effectRoute = &m_bellRoute;
    // Installed with the clients rather than after them: on a null policy
    // Core's gate answers PAL's defaults, not this frontend's.
    m_terminal.capabilityPolicy = &m_capabilityPolicy;
    // The password-prompt heuristic is a per-Terminal capability with the same
    // shape: left unseeded it keeps Terminal.h's in-class value and the badge
    // this frontend draws into its frame has nothing to report. Seeded from the
    // LIVE preferences, which the page has delivered before this runs — an
    // empty `Values` here reads every key at its default and silently discards
    // the one the person wrote, and this key decides whether their typing is
    // masked. TerminalLaunchSeed and TerminalSession seed it the same way; a
    // frontend reading a different set is a fork of the policy, not a shortcut.
    Ubiquitty::setPasswordDetect(&m_terminal, Preferences::Effective::passwordDetect(Preferences::values()));
    // The history depth, seeded as TerminalLaunchSeed seeds every other
    // frontend's terminal. Left at Terminal.h's fallback, the page holds
    // fewer rows than a host backfills, so a reader reached the top of a
    // ring already full of the newest lines and could pull nothing older.
    Ubiquitty::setScrollbackLimit(&m_terminal, Preferences::Effective::scrollbackLines(Preferences::values()));
    // The pairing's store. Core keeps the rule and none of the bytes, so two
    // function pointers over a map are the whole of what a browser supplies:
    // the page fills the map from its own storage and reads it back out.
    m_rememberedSessions.setPersistence(
        [](void* context, const std::string& hostKey, std::string& bytesOut) {
            auto* records = static_cast<std::unordered_map<std::string, std::string>*>(context);
            const auto found = records->find(hostKey);
            if (found == records->end())
                return false;
            bytesOut = found->second;
            return true;
        },
        [](void* context, const std::string& hostKey, const std::string& bytes) {
            auto* records = static_cast<std::unordered_map<std::string, std::string>*>(context);
            if (bytes.empty()) {
                records->erase(hostKey);
                return;
            }
            (*records)[hostKey] = bytes;
        },
        &m_hostRecords);
    Ubiquitty::resize(m_terminal, rows > 0 ? rows : 1, columns > 0 ? columns : 1);
    publishPixelGeometry();
    publishRichTextTypography();
    if (m_workspace) {
        m_isHostMirror = true;
        m_workspace->m_workspacePanes.push_back(this);
        m_sync.setSessionTerminal(m_workspaceSessionID, m_terminal);
        if (const auto* facts = m_sync.paneFacts(m_workspaceSessionID))
            m_currentDirectory = facts->currentDirectory;
    }
}

WebTerminal::~WebTerminal()
{
    if (m_workspace) {
        m_sync.releaseSessionTerminal(m_workspaceSessionID);
        m_sync.withdrawTerminal(m_terminal);
        std::erase(m_workspace->m_workspacePanes, this);
    }
    if (m_searchController)
        m_searchController->detach();
    // m_ownedSync is declared after m_terminal, so it is destroyed first and the
    // Terminal would outlive the client it points at. Cleared here because a
    // destructor body runs before any member is destroyed; the members cannot be
    // reordered, since the client is constructed from the Terminal's address.
    m_terminal.mirrorClient = nullptr;
    m_terminal.windowClient = nullptr;
    m_terminal.shellClient = nullptr;
}

void WebTerminal::resize(int rows, int columns)
{
    if (rows <= 0 || columns <= 0 || m_isHostMirror)
        return;
    // Sampled across the call rather than tested against the dimensions: a
    // resize to the size already in use returns before Core renumbers anything,
    // so the epoch decides and this path needs no guard of its own.
    const std::uint32_t epochBefore = m_terminal.absoluteRowEpoch;
    Selection::noteViewportBeforeResize(m_selection, m_terminal, m_viewOffset);
    Ubiquitty::resize(m_terminal, rows, columns);
    m_viewOffset = Selection::viewportAfterResize(m_selection, m_terminal, m_viewOffset);
    // A rectangle's columns, and the alternate screen's rows, mean nothing at
    // the new size; a flowing selection on the primary screen follows its
    // characters through the rewrap.
    Selection::dropSelectionAcrossResize(m_selection.state, epochBefore, m_terminal);
    publishPixelGeometry();
}

void WebTerminal::publishPixelGeometry()
{
    if (!m_fonts)
        return;
    const auto scale = static_cast<float>(m_glyphScale);
    // The padding rounded an edge at a time, as `renderPage` rounds it into
    // the page, so the drawable Core reports is the page a viewer sees.
    const auto edge = [scale](float cssPixels) { return std::max(static_cast<int>(std::lround(cssPixels * scale)), 0); };
    const IntSize textArea { cellWidth() * m_terminal.columns, cellHeight() * m_terminal.rows };
    Ubiquitty::publishPixelGeometry(m_terminal,
        { { cellWidth(), cellHeight() },
            textArea,
            { textArea.width + edge(m_paddingInsets.left) + edge(m_paddingInsets.right),
                textArea.height + edge(m_paddingInsets.top) + edge(m_paddingInsets.bottom) } });
}

void WebTerminal::feed(std::string_view bytes)
{
    if (bytes.empty())
        return;
    if (m_richText.needsConfiguration())
        publishRichTextTypography();
    // Stated rather than left to the default, which happens to be the same
    // value. `currentCapabilityOrigin` initialises to Local, so a reader cannot
    // tell a page that decided from a page that never asked — and the whole
    // question of what Web should stamp turned on nobody being able to.
    //
    // Local is the truth here. The parser is reached by this export and by
    // feedKey, and both carry bytes the page itself produced: a keystroke it
    // encoded, or content it fed while running with no host. Host bytes arrive
    // at feedFromHost instead, which routes to SyncClientCore and applies
    // checkpoints and updates without ever calling processBytes — so no
    // host-driven byte reaches a capability gate site, and there is no principal
    // here but the user.
    m_terminal.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    (void)Modes::DisplayIdle::noteInput(m_terminal, PAL::monotonicTicks());
    Ubiquitty::processBytes(&m_terminal, bytes);
    if (resolveBellEvent(&m_terminal, PAL::monotonicTicks()) != BellMode::Off) {
        noteBell();
    }
    followTailOrHoldViewport();
}

void WebTerminal::followTailOrHoldViewport()
{
    // The page is single-threaded, so nothing holds the lock against the
    // try-lock Core takes to read the mode off the terminal; Core keeps the
    // baseline the growth is measured from, and decides. The page supplies
    // the history it just wrote, where its view sits, and applies the verdict.
    m_viewOffset = static_cast<int>(Ubiquitty::Selection::updateAfterOutput(m_selection, m_terminal, m_modelLock, m_viewOffset, Screen::historyFacts(&m_terminal)).viewport.viewOffset);
}

void WebTerminal::refreshConfiguration()
{
    const std::uint64_t epoch = Preferences::configurationEpoch();
    if (epoch == m_configurationEpoch)
        return;
    m_configurationEpoch = epoch;
    m_configuration = Preferences::Effective::liveRenderConfiguration();
    auto routePreferences = Preferences::buildFontRoutePreferences(Preferences::values());
    const int characterSpacing = Preferences::Effective::characterSpacingInPixels(m_configuration, static_cast<double>(m_glyphScale));
    // Font metrics, feature descriptors and proportional faces all depend on
    // the document. Settings are infrequent; rebuild once per published epoch.
    m_fonts.reset();
    m_fontRoutePreferences = std::move(routePreferences);
    m_characterSpacingInPixels = characterSpacing;
    m_fontWeights = { m_configuration.fontWeight, m_configuration.boldFontWeight };
    m_ligatures = m_configuration.hasLigatures ? Rendering::Ligatures::Enabled : Rendering::Ligatures::Disabled;
    m_fontFeatures = m_configuration.fontFeatures.string();
    recomposeFontFeatureSettingsCSS();
    rebuildFontStack();
    // The terminal's own share of a new document — the cursor, the bell, the
    // OSC 52 policy, the password heuristic — as every other arm re-seeds it.
    Runtime::reseedTerminalConfiguration(m_terminal, Preferences::values(), Runtime::EncodingReseed::FollowConfiguration);
}

void WebTerminal::applyConfiguredFrameStyle(Rendering::TerminalSnapshotOptions& options)
{
    refreshConfiguration();
    updatePresentation();
    // The page supplies configuration as bytes under a name and Core folds
    // them, so the browser answers every renderer key from the same struct as
    // every other arm.
    Preferences::Effective::applyRuleSettings(options.style, m_configuration, static_cast<double>(m_glyphScale));
    Preferences::Effective::applyCursorSettings(options, m_configuration);
    Preferences::Effective::applyLinkSettings(options, m_configuration, &m_terminal);
    Preferences::Effective::applyTekSettings(options, m_configuration);
    options.tekDeviceScale = static_cast<float>(m_glyphScale);
    Preferences::Effective::applyBackgroundImageSettings(options, m_configuration, &m_backgroundImage);
    options.style.shouldEnhanceTextContrast = m_configuration.shouldEnhanceTextContrast;
    options.style.backgroundOpacity = static_cast<float>(m_configuration.backgroundOpacity);
    options.shouldResolveBlink = true;
    options.blinkTicks = m_presentationTicks ? *m_presentationTicks : PAL::monotonicTicks().count;
    auto cursor = Cursor::appearanceInputs(&m_terminal);
    // A replay clock begins at zero; wall-clock activity is outside its timeline.
    if (m_presentationTicks)
        cursor.lastActivityTick = 0;
    options.cursorMixAlpha = Cursor::resolveAppearance(cursor, options.blinkTicks).blinkAlpha;
}

void WebTerminal::updatePresentation()
{
    m_presentation = Rendering::remoteViewportPlacement({
        .policy = m_configuration.nonOwnerPresentation,
        .viewport = m_presentationViewport,
        .cell = { static_cast<float>(cellWidth()), static_cast<float>(cellHeight()) },
        .grid = { columns(), rows() },
        .cursor = { cursorRow(), cursorColumn() },
        .previousPanOffset = m_presentation.panOffset,
        .minimumScale = static_cast<float>(std::min(1.0, Preferences::Zoom::clampFontZoom(0.0) / m_fontSize)),
        .isGeometryOwnedElsewhere = m_sync.isGeometryOwnedElsewhere(this->sessionID()),
        .isProgramViewport = m_terminal.isTekModeActive || m_terminal.modes.fullscreenContent,
        .shouldFollowCursor = m_viewOffset == 0 && m_terminal.modes.isCursorVisible != 0,
    });
}

bool WebTerminal::shouldCursorInvertText() const { return Preferences::Effective::cursorInvertText(Preferences::values()); }

void WebTerminal::setCursorTextContrast(CursorTextContrast contrast)
{
    (void)Preferences::configureKey(Preferences::Key::CursorInvertText,
        Preferences::Value::ofBool(Preferences::SerializeKind::Bool, contrast == CursorTextContrast::Invert));
}

int WebTerminal::serviceDisplayIdle(Ticks now)
{
    if (m_isHostMirror)
        return -1;
    (void)Modes::DisplayIdle::advance(m_terminal, now);
    const auto remaining = Modes::DisplayIdle::ticksUntilDeadline(m_terminal, now);
    return remaining ? static_cast<int>(*remaining) : -1;
}

const std::vector<std::uint8_t>& WebTerminal::render()
{
    m_image = renderFrame({}, m_imageWidth, m_imageHeight);
    return m_image;
}

std::vector<std::uint8_t> WebTerminal::renderFrame(Rendering::EdgeInsets paddingInPixels, int& widthOut, int& heightOut)
{
    Rendering::TerminalSnapshotOptions options;
    options.style.paddingInPixels = paddingInPixels;
    options.style.unifontScale = m_fonts->face.isAvailable() ? 0 : m_glyphScale;
    applyConfiguredFrameStyle(options);
    Rendering::applyPointSpace(options, static_cast<float>(cellHeight()), m_glyphScale, m_lineSpacing);
    options.viewOffset = m_viewOffset;
    options.isFocused = m_isFocused;
    // No view layer here: the badge that says the terminal is taking a
    // password has to be part of the frame or it does not exist.
    options.shouldDrawPasswordLock = true;
    // The same spans the instance path draws. Without them this composite is a
    // renderer that silently drops the selection, so ?gpu=0 highlights nothing
    // while the GPU path highlights correctly.
    buildSelectionSpans();
    options.selectionSpans = m_selectionSpans.empty() ? nullptr : m_selectionSpans.data();
    options.selectionSpanCount = static_cast<int>(m_selectionSpans.size());
    options.richTextSelections = m_richTextSelections;
    options.richTextSelectionCount = static_cast<int>(m_richTextSelections.size());
    buildHiliteSpans();
    options.hiliteRegionSpans = m_hiliteSpans.empty() ? nullptr : m_hiliteSpans.data();
    options.hiliteRegionSpanCount = static_cast<int>(m_hiliteSpans.size());
    // The trigger tints as well, for the same reason: one gather serves both
    // renderers, or a rule that fired draws on one backend and not the other.
    Rendering::collectTriggerHighlightRowSpans(m_terminal, m_viewOffset, m_triggerHighlightSpans);
    options.triggerHighlightSpans = m_triggerHighlightSpans.empty() ? nullptr : m_triggerHighlightSpans.data();
    options.triggerHighlightSpanCount = static_cast<int>(m_triggerHighlightSpans.size());
    applySearchMatchSpans(options);
    // The same chrome the instance path composites. Passing it to one renderer
    // and not the other would make the palette appear and vanish with the
    // backend, which reads as a rendering fault rather than a missing argument.
    layoutBeamForFrame();
    layoutHintForFrame();
    // The rasterizer the instance path draws with, so this raster and that one
    // differ in the renderer and nothing else. Without it the CPU fallback draws
    // the embedded Unifont while the GPU draws the page's face — two typefaces,
    // and every pixel between them a difference the parity check attributes to
    // the shaders.
    // The FontStack's renderer, not a fresh one: it is built over the same
    // rasterizer and rebuilt whenever the fonts are, so its glyph cache lives
    // as long as the face it holds glyphs for. This is the page's per-frame
    // render, and a renderer built per call allocates and zeroes its atlases
    // every frame and rasterises every glyph on screen again.
    const Rendering::ChromePlacement layers[] = { hintPlacement(), beamPlacement() };
    return Rendering::renderTerminalSnapshotRGBA(m_terminal, options, widthOut, heightOut, layers, &m_fonts->boxes, &m_fonts->renderer);
}

// The hint drawn for this frame, and the retirement of a transient one whose
// time is up. The frame that finds the tick passed is the frame that would
// otherwise have drawn it, so a stale hint never survives a repaint.
void WebTerminal::layoutHintForFrame()
{
    const Input::Hint hint = Input::hintShowing(m_pointerLadder, static_cast<std::uint32_t>(PAL::monotonicTicks().count));
    if (hint == Input::Hint::None) {
        m_hintGeometry = Rendering::HintToastGeometry {};
        return;
    }
    m_hintGeometry = Rendering::layoutHintToast(Input::hintText(hint, m_modifierVocabulary),
        Themes::resolveChromeStyle(m_terminal.palette), m_terminal.rows, m_terminal.columns);
}

// The two chrome layers this arm draws, in the order they composite: the hint
// first and the palette over it, because an open palette is what the user is
// looking at.
Input::PointerLockVerdict WebTerminal::pointerLockVerdict(const Input::PointerLockFacts& facts) const
{
    const auto mode = m_terminal.modes.mouseRelativePointerLock ? Input::PointerLockMode::Set : Input::PointerLockMode::Clear;
    return Input::resolvePointerLock(mode, facts);
}

void WebTerminal::notePointerLockGrab(Input::PointerLockGrab grab)
{
    Input::notePointerLockGrab(m_pointerLadder, grab);
}

void WebTerminal::notePointerLockChord(const Input::PointerLockKeyState& keys)
{
    Input::notePointerLockChord(m_pointerLadder, keys, static_cast<std::uint32_t>(PAL::monotonicTicks().count));
}

Input::PointerLockChordVerdict WebTerminal::tickPointerLockChord(const Input::PointerLockKeyState& keysNow)
{
    const Input::PointerLockChordVerdict verdict = Input::tickPointerLockChord(m_pointerLadder, keysNow, static_cast<std::uint32_t>(PAL::monotonicTicks().count));
    // The mode is cleared here, not by the page: a hung application that never
    // resets 7403 must not be able to re-trap the pointer on the next click.
    if (verdict == Input::PointerLockChordVerdict::BreakOut)
        m_terminal.modes.mouseRelativePointerLock = false;
    return verdict;
}

std::uint32_t WebTerminal::pointerLockChordTicksUntilDeadline() const
{
    return Input::pointerLockChordTicksUntilDeadline(m_pointerLadder, static_cast<std::uint32_t>(PAL::monotonicTicks().count));
}

std::uint32_t WebTerminal::hintTicksUntilExpiry() const
{
    const std::uint32_t expiry = Input::hintExpiryTicks(m_pointerLadder);
    if (expiry == 0)
        return 0;
    const auto left = static_cast<std::int32_t>(expiry - static_cast<std::uint32_t>(PAL::monotonicTicks().count));
    return left > 0 ? static_cast<std::uint32_t>(left) : 0;
}

Rendering::ChromePlacement WebTerminal::hintPlacement() const
{
    return { &m_hintGeometry.canvas, m_hintGeometry.originRow, m_hintGeometry.originColumn };
}

Rendering::ChromePlacement WebTerminal::beamPlacement() const
{
    return { &m_beamGeometry.canvas, m_beamGeometry.originRow, m_beamGeometry.originColumn };
}

void WebTerminal::layoutBeamForFrame()
{
    // Laid out per frame from the live palette, so a theme change or a resize is
    // reflected without the session knowing either happened. Closed, layoutBeam
    // returns an empty canvas and the composite is skipped — the cost of a
    // palette nobody opened is one branch.
    //
    // A frontend drawing its own palette draws nothing here. Resolving rather
    // than assuming is what makes [appearance] beam_surface = "in-terminal" mean
    // something on a frontend that has a native palette, which is the case the
    // setting was asked for.
    // The browser composites chrome into the frame it renders, so the in-grid
    // surface is always available here. Stated rather than assumed, because it
    // is not true of every frontend: macOS's shipping frame is a hand-written
    // cell walk that composites none.
    if (Preferences::resolveBeamSurface(m_beamSurface, m_nativeBeam, Preferences::InGridBeam::Available)
        != Preferences::BeamPresentation::InTerminal) {
        m_beamGeometry = Rendering::BeamGeometry {};
        return;
    }
    m_beamGeometry = Rendering::layoutBeam(m_beam.state(),
        Themes::resolveChromeStyle(m_terminal.palette), m_terminal.rows, m_terminal.columns);

    // Hand the drawn row count back, so the session scrolls against the box that
    // is actually on screen. Without it the window is whatever the session
    // defaulted to, and on a short grid the selection walks off the bottom and
    // never scrolls into view — arrow-down does nothing visible and the palette
    // reads as frozen.
    //
    // Only when it drew something: an empty result set has nothing to scroll,
    // and setting a window of zero on the way past would leave the session
    // unable to scroll the next list until another frame corrected it.
    if (m_beamGeometry.bodyRows > 0)
        m_beam.setViewportRows(m_beamGeometry.bodyRows);
}

bool WebTerminal::restoreResume(std::unique_ptr<Session::ResumeRecordSlot> slot, Protocol::Sync::ID128 clientInstance)
{
    if (!slot || m_resumeSlot)
        return false;
    const Protocol::Sync::ID128 instance = clientInstance == Protocol::Sync::ID128 {} ? m_sync.clientInstance() : clientInstance;
    auto store = std::make_shared<Session::EncodedResumeRecordStore>(*slot, Protocol::Sync::measuredClientPolicy().maxCheckpointBytes);
    m_resumeSlot = std::move(slot);
    if (!m_sync.restoreResumeStore(std::move(store), instance)) {
        m_resumeSlot.reset();
        return false;
    }
    // The stored picture is a host's: this terminal mirrors it from here on,
    // and only the host's pictures size its cells.
    if (m_sync.hasRestoredPicture())
        m_isHostMirror = true;
    return true;
}

bool WebTerminal::feedFromHost(std::string_view bytes)
{
    if (bytes.empty())
        return !m_sync.faulted();
    if (m_richText.needsConfiguration())
        publishRichTextTypography();
    for (auto* pane : m_workspacePanes) {
        if (pane->m_richText.needsConfiguration())
            pane->publishRichTextTypography();
    }
    const bool isAccepted = m_sync.feed(std::as_bytes(std::span { bytes }));
    if (m_areProportionalFacesOwed)
        publishProportionalFaces();
    serviceHostListing();
    for (auto* pane : m_workspacePanes) {
        if (pane->m_areProportionalFacesOwed)
            pane->publishProportionalFaces();
        pane->serviceResize();
    }
    serviceResize();
    // Host output moves the tail the same way local output does, and a thin
    // client's reader is reading the same history.
    followTailOrHoldViewport();
    return isAccepted;
}

const std::vector<std::uint8_t>& WebTerminal::takePendingHostFrame(std::size_t pendingOutboundBytes)
{
    m_pendingHostFrame.clear();
    serviceResize();
    m_sync.tickScreen();
    if (m_pasteSource.hasBytesToSend()) {
        const auto maximum = std::min(Protocol::Sync::bulkChunkPayloadBytes, m_pasteSource.heldBytes() - m_pasteSource.queuedBytes())
            + Protocol::Sync::bulkChunkOverheadBytes + Protocol::Sync::maxEnvelopeHeaderBytes;
        if (pendingOutboundBytes <= Transport::guaranteedOutboundFrameBytes
            && maximum <= Transport::guaranteedOutboundFrameBytes - pendingOutboundBytes) {
            // Only canonical memory-queue writes run inside this callback;
            // JavaScript sends the returned frame after the owner advanced.
            (void)m_pasteSource.sendOne([this](const Protocol::Sync::BulkChunk& chunk) { return m_sync.sendControlUploadChunk(chunk); });
        }
    }
    m_sync.takeScreenOutput(m_pendingHostFrame);
    return m_pendingHostFrame;
}

int WebTerminal::screenTickDelayMilliseconds() const
{
    const std::optional<std::uint64_t> delay = m_sync.screenTickDelayMicroseconds();
    const auto normal = delay ? static_cast<int>(std::min<std::uint64_t>((*delay + 999) / 1000, std::numeric_limits<int>::max())) : -1;
    return m_pasteSource.hasBytesToSend() ? (normal < 0 ? 10 : std::min(normal, 10)) : normal;
}

const std::vector<std::uint8_t>& WebTerminal::buildHello(
    const char* authToken, std::uint32_t sessionID, ClipboardServing clipboardServing,
    const char* workspaceName, SessionLifetime lifetime)
{
    // Greet is the first envelope of a connection, so the state that belongs to
    // the connection before it ends here rather than at a call the page has to
    // remember to make. Four things ride on that.
    //
    // The decoder's fault latch is permanent by design — framing cannot be
    // resynchronised once a length is impossible — and the page answers a fault
    // by closing the socket and reattaching. Held across, it refuses the first
    // bytes of every connection after it, so the retry that is the recovery
    // becomes a loop that reads as a dead tab.
    //
    // Its partial-frame residue goes with it: a link that dies mid-checkpoint
    // leaves a body with no rest coming, and prefixed to the next connection's
    // stream it consumes that connection's handshake and checkpoint as its own
    // payload.
    //
    // The screen plane goes too: its generations and acknowledgements are the
    // connection's, and the Greet below greets a fresh one.
    //
    // So does the host's verdict. A refusal or a held attach answers the
    // connection that earned it; carried across, the page could not tell the
    // Bye that refuses this connection from the one that refused the last.
    //
    // And the history the reader's scrolling asked for: the host's wants are
    // the connection's, so one the old connection never answered is asked of
    // the new one again.
    //
    // The Terminal's cells are kept: they are what the page draws until the new
    // checkpoint lands.
    noteTerminateTransportLost();
    m_pasteSource.clear();
    m_pendingWebCalls.clear();
    m_webCallResults.clear();
    m_webConsentQuestions.clear();
    for (auto* pane : m_workspacePanes) {
        pane->m_pasteSource.clear();
        pane->m_resizeCallID.reset();
        pane->m_sentViewport.reset();
        pane->m_historyPull.reset();
    }
    m_sync.resetForReconnect();
    m_hostNotice.clear();
    m_consentStatus.reset();
    m_isHostMirror = true;
    m_resizeCallID.reset();
    m_sentViewport.reset();
    m_historyPull.reset();

    Protocol::Sync::HandshakeRequest hello;
    hello.columns = m_requestedViewport ? m_requestedViewport->columns : static_cast<std::uint16_t>(m_terminal.columns);
    hello.rows = m_requestedViewport ? m_requestedViewport->rows : static_cast<std::uint16_t>(m_terminal.rows);
    hello.sessionID = sessionID; // 0 = fresh; nonzero = reattach
    if (m_connectionMode == ConnectionMode::Workspace) {
        hello.intents.add(Protocol::Sync::HelloIntent::AttachesWorkspace);
        hello.workspaceID = m_requestedWorkspaceID;
        if (!m_requestedWorkspaceID && !sessionID && (!workspaceName || !workspaceName[0]))
            hello.target = Protocol::Sync::HandshakeTarget::Control;
    }
    if (sessionID)
        hello.sessionFlags |= Protocol::Sync::helloSessionAttachOnly;
    if (workspaceName)
        hello.workspaceName = workspaceName;
    if (lifetime == SessionLifetime::EndsWhenDetached)
        hello.sessionFlags |= Protocol::Sync::helloSessionEndWhenDetached;
    // Latched rather than re-read when a request arrives: the host records what
    // its Greet stated, so a page answering a request it never offered to serve
    // would be replying to a question the host does not believe it asked.
    m_didClaimClipboardServe = clipboardServing == ClipboardServing::Enabled;
    if (m_didClaimClipboardServe)
        hello.intents.add(Protocol::Sync::HelloIntent::ServesClipboard);
    if (authToken && authToken[0])
        hello.authToken = authToken;
    m_frame.clear();
    m_sync.buildHello(hello, m_frame);
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildPaste(std::string_view text)
{
    if (reportsPasteEvents())
        return buildPasteNotification("text/plain");
    m_frame.clear();
    if (text.empty())
        return m_frame;

    // The text travels as one paste, which the host fences and normalises
    // under the modes live when it writes it.
    appendIntent(Protocol::Sync::PasteInput { .text = { text.begin(), text.end() }, .offset = 0, .end = Protocol::Sync::PasteEnd::Final });
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildPasteNotification(std::string_view types)
{
    m_frame.clear();
    if (!reportsPasteEvents())
        return m_frame;
    const bool mayRead = m_terminal.isOSC52Allowed && m_terminal.osc52ClipboardReadPolicy != OSC::ClipboardReadPolicy::Deny;
    const auto notification = mayRead ? OSC::clipboardPasteNotification(types, ClipboardBuffer::Clipboard)
                                      : std::string("\033]5522;type=read:status=EPERM\033\\");
    appendRawInput(notification);
    return m_frame;
}

const Session::InputInDoubtNotice& WebTerminal::inputInDoubtNotice()
{
    m_inputInDoubtNotice = Session::inputInDoubtNotice(m_sync.paneInputStatus(this->sessionID())).value_or(Session::InputInDoubtNotice {});
    return m_inputInDoubtNotice;
}

const std::vector<std::uint8_t>& WebTerminal::resendInputInDoubt()
{
    m_frame.clear();
    m_sync.resendInDoubt(this->sessionID());
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::discardInputInDoubt()
{
    m_frame.clear();
    m_sync.discardInDoubt(this->sessionID());
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

void WebTerminal::appendIntent(Protocol::Sync::InputIntent intent)
{
    // Numbered and sent, or kept for the pane's bind when the host has not
    // bound it yet; what is ready to leave joins the frame the page sends.
    (void)m_sync.sendIntent(this->sessionID(), std::move(intent));
    m_sync.takeScreenOutput(m_frame);
}

void WebTerminal::appendRawInput(std::string_view bytes)
{
    constexpr std::size_t maxRawEventBytes = 16 * 1024;
    for (; !bytes.empty(); bytes.remove_prefix(std::min(bytes.size(), maxRawEventBytes))) {
        const std::string_view piece = bytes.substr(0, maxRawEventBytes);
        appendIntent(Protocol::Sync::RawInput { .bytes = { piece.begin(), piece.end() } });
    }
}

std::optional<Runtime::KeyPress> WebTerminal::keyPress(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, Keys::VirtualKey physicalKey)
{
    if (keyCode == 0 && text == 0 && physicalKey == Keys::VirtualKey::None)
        return std::nullopt;

    // `keyCode` is what the browser says the key TYPED — `event.key`, so `:` for
    // Shift+`;` — while `baseLayoutKey` is the standard layout's code point for
    // the physical position. Core takes the unshifted key as the identity and
    // the typed glyph as the shifted alternate, so the two cross over here. The
    // names line up and the meanings do not: assigning across by name compiles,
    // and puts `;` on the wire for a typed `:`.
    Runtime::KeyPress press;
    press.virtualKey = physicalKey;
    press.unshiftedCodePoint = baseLayoutKey != 0 ? baseLayoutKey : keyCode;
    press.shiftedCodePoint = keyCode;
    press.baseLayoutCodePoint = baseLayoutKey;
    press.modifiers = modifiers;
    press.wasModified = (modifiers & Keys::characterModifierMask) != 0;
    // Reported, not decided. Whether a release or a repeat produces bytes is
    // the terminal's: reportsNonPressEvent wants REPORT_EVENTS on and an
    // escape-code channel for the key, and the encoder answers nothing
    // otherwise. A page that filtered releases itself would have to mirror the
    // kitty flag stack, and a mirror of live parser state is the thing this
    // frontend exists not to keep.
    press.eventType = eventType;
    press.isRepeat = eventType == Keys::KeyEventType::Repeat;
    if (text != 0) {
        press.text[0] = text;
        press.textLength = 1;
    }

    return press;
}

int WebTerminal::encodeKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, std::span<char> output, Keys::VirtualKey physicalKey)
{
    const std::optional<Runtime::KeyPress> press = keyPress(keyCode, baseLayoutKey, modifiers, text, eventType, physicalKey);
    if (!press || output.empty())
        return 0;
    // DECCKM, DECPAM, VT52, LNM, the modifyOtherKeys levels and the kitty flag
    // stack are live parser state, so the terminal is handed itself rather than
    // read field by field here. Reading it field by field means naming an index
    // per category — modifyOtherKeys is 4, not 0 — and a wrong one is a mode
    // that silently does nothing rather than a compile error.
    return Runtime::encodeKey(m_terminal, *press, output).length;
}

int WebTerminal::scrollbackRows() const
{
    return Ubiquitty::Screen::scrollbackCount(&m_terminal);
}

const std::vector<std::uint8_t>& WebTerminal::buildClearScreen()
{
    m_frame.clear();
    if (this->sessionID()) {
        if (m_sync.clearPane(this->sessionID(), Screen::ClearCommand::Screen))
            m_sync.takeScreenOutput(m_frame);
        return m_frame;
    }
    // The frame comes back empty on the scrolling path — nothing is sent when
    // nothing needs repairing. It carries Ctrl-L only when Core hands off.
    Ubiquitty::Screen::clearScreen(
        &m_terminal, Ubiquitty::Screen::ClearBoundary::CurrentPrompt, &m_selection.state,
        [this] { m_viewOffset = 0; },
        [this](std::span<const char> bytes) { appendRawInput({ bytes.data(), bytes.size() }); });
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildClearBuffer()
{
    m_frame.clear();
    if (this->sessionID()) {
        if (m_sync.clearPane(this->sessionID(), Screen::ClearCommand::Buffer))
            m_sync.takeScreenOutput(m_frame);
        return m_frame;
    }
    Ubiquitty::Screen::clearBuffer(
        &m_terminal, &m_selection.state,
        [this] { m_viewOffset = 0; },
        [this](std::span<const char> bytes) { appendRawInput({ bytes.data(), bytes.size() }); });
    return m_frame;
}

void WebTerminal::clearScrollback()
{
    if (this->sessionID()) {
        (void)m_sync.clearPane(this->sessionID(), Screen::ClearCommand::Scrollback);
        return;
    }
    Ubiquitty::Screen::clearScrollback(&m_terminal, &m_selection.state, [this] { m_viewOffset = 0; });
}

bool WebTerminal::addKeybinding(const char* spec, const char* action)
{
    if (!spec || !action)
        return false;
    return m_bindings.add(spec, action);
}

int WebTerminal::resolveBinding(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers)
{
    m_bindingBytes.clear();
    if (m_bindings.empty())
        return 0;

    // Bindings are written in ASCII, so a non-Latin layout matches on the
    // character the same physical key carries under an ASCII one.
    Input::KeyChord chord;
    chord.modifiers = modifiers & Input::bindModMask;
    chord.key = Input::resolveChordKey(keyCode, baseLayoutKey, chord.modifiers);

    Input::BindingAction action;
    switch (m_chords.feed(chord, action)) {
    case Input::ResolveResult::Pending:
        return -1; // a leader key: swallowed, not encoded
    case Input::ResolveResult::Matched:
        if (action.kind == Input::ActionKind::SendBytes)
            m_bindingBytes.assign(action.bytes.begin(), action.bytes.end());
        return static_cast<int>(action.kind);
    case Input::ResolveResult::NoMatch:
        break;
    }
    return 0;
}

const std::vector<std::uint8_t>& WebTerminal::buildKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, Keys::VirtualKey physicalKey)
{
    m_frame.clear();
    // The host decides whether this transition produces bytes. This mirror
    // may not yet have seen a mode that enables releases or suppresses repeats.
    // Only a missing key identity is rejected here; standalone input keeps
    // using the local encoder through feedKey.
    const std::optional<Runtime::KeyPress> press = keyPress(keyCode, baseLayoutKey, modifiers, text, eventType, physicalKey);
    if (press)
        appendIntent(Protocol::Sync::KeyInput { .events = { Runtime::keyEventOf(*press) } });
    return m_frame;
}

bool WebTerminal::feedKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text, Keys::KeyEventType eventType, Keys::VirtualKey physicalKey)
{
    if (!m_isHostMirror)
        (void)Modes::DisplayIdle::noteInput(m_terminal, PAL::monotonicTicks());
    char encoded[64];
    const int length = encodeKey(keyCode, baseLayoutKey, modifiers, text, eventType, encoded, physicalKey);
    if (length <= 0)
        return false;
    // The user's own keystroke, encoded three lines above. Stamped for the reason
    // ``feed`` states: the default is this value, and saying it is what separates
    // a decision from an omission.
    m_terminal.currentCapabilityOrigin = Ubiquitty::CapabilityOrigin::Local;
    Ubiquitty::processBytes(&m_terminal, std::string_view(encoded, static_cast<std::size_t>(length)));
    return true;
}

std::uint32_t WebTerminal::pendingClipboardServeID() const
{
    return m_clipboardServeRequests.empty() ? 0 : m_clipboardServeRequests.front().id;
}

bool WebTerminal::pendingClipboardServeWantsTypes() const
{
    return !m_clipboardServeRequests.empty()
        && m_clipboardServeRequests.front().kind == Protocol::Sync::ClipboardRequestKind::Types;
}

const char* WebTerminal::pendingClipboardServeMime() const
{
    return m_clipboardServeRequests.empty() ? "" : m_clipboardServeRequests.front().mime.c_str();
}

void WebTerminal::beginClipboardServeItems() { m_clipboardServeItems.clear(); }

void WebTerminal::addClipboardServeItem(std::string_view mime, std::span<const char> bytes)
{
    if (m_clipboardServeItems.size() >= Protocol::Sync::maxClipboardServeItems)
        return;
    Protocol::Sync::ClipboardServeItem item;
    item.mime = std::string(mime);
    item.data.assign(reinterpret_cast<const std::uint8_t*>(bytes.data()),
        reinterpret_cast<const std::uint8_t*>(bytes.data()) + bytes.size());
    m_clipboardServeItems.push_back(std::move(item));
}

const std::vector<std::uint8_t>& WebTerminal::buildClipboardServeAnswer(int status)
{
    m_frame.clear();
    if (m_clipboardServeRequests.empty())
        return m_frame;

    // The status crosses the wasm boundary as an integer, so one this build
    // does not know becomes a refusal rather than an accidental OK. That check
    // is the page boundary's alone; what an answer may CARRY is Core's, and
    // both clients ask it the same way.
    const int highest = static_cast<int>(Protocol::Sync::ClipboardServeStatus::TooLarge);
    Protocol::Sync::ClipboardServeStatus asked = (status < 0 || status > highest)
        ? Protocol::Sync::ClipboardServeStatus::Refused
        : static_cast<Protocol::Sync::ClipboardServeStatus>(status);

    // The same two gates the native client asks, and for the same reason: a
    // program on the host reads a clipboard by shelling out, or by writing an
    // OSC 52 query, whichever works — so a route that consulted only its own
    // switch would be the way around the other. `clipboardRead = deny` is a
    // person saying programs may not read their clipboard, and the sentence
    // does not name a transport.
    //
    // Applied here rather than trusted to the page, because the page is the
    // side that would have to remember: this file already refuses a status it
    // does not recognise for the same reason.
    const ::Ubiquitty::Clipboard::ServeFacts gate { .didClaimServe = m_didClaimClipboardServe,
        .isClipboardReadDenied = m_terminal.osc52ClipboardReadPolicy == OSC::ClipboardReadPolicy::Deny };
    if (::Ubiquitty::Clipboard::serveDecisionFor(gate) == ::Ubiquitty::Clipboard::ServeDecision::Refuse) {
        asked = Protocol::Sync::ClipboardServeStatus::Refused;
        m_clipboardServeItems.clear(); // a refusal carries nothing, whatever the page staged
    }
    // Moved rather than copied: a pasteboard image runs to megabytes, the
    // staged items are cleared below either way, and the copy bought nothing.
    const Protocol::Sync::ClipboardDataMessage message = Protocol::Sync::makeClipboardData(
        m_clipboardServeRequests.front().id, asked, std::move(m_clipboardServeItems));

    m_sync.buildClipboardData(message, m_frame);
    // The question is answered, so the next one becomes the one the page reads
    // for. Its own staging starts empty.
    m_clipboardServeRequests.pop_front();
    m_clipboardServeItems.clear(); // a moved-from vector is valid but unspecified; this pins it empty
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildPastePush(std::string_view mime, std::span<const std::uint8_t> bytes)
{
    m_frame.clear();
    if (!m_sync.isScreenAttached() || m_pasteSource.isActive() || m_nextPastePushID == std::numeric_limits<std::uint32_t>::max())
        return m_frame;
    const auto pane = m_sync.paneHandle(this->sessionID());
    const auto correlation = "paste.web:" + std::to_string(++m_nextPastePushID);
    if (!m_pasteSource.begin(pane, mime, correlation, bytes, [](std::size_t amount) {
            return amount <= Protocol::Control::maxPastePushBytes + Protocol::Control::PasteUploadSource::metadataReservationBytes;
        }))
        return m_frame;
    if (!m_sync.call(m_pasteSource.call())) {
        m_pasteSource.clear();
        return m_frame;
    }
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildInput(std::string_view bytes)
{
    m_frame.clear();
    if (!bytes.empty())
        appendRawInput(bytes);
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::buildResize(int rows, int columns)
{
    m_frame.clear();
    if (rows <= 0 || columns <= 0 || rows > maxRows || columns > maxColumns)
        return m_frame;
    // Desired browser geometry is not the host picture's current geometry.
    // Keep it independently while waiting for the authoritative resize.
    const auto pixels = [](std::uint32_t value) { return static_cast<std::uint16_t>(std::min<std::uint32_t>(value, UINT16_MAX)); };
    const std::uint32_t textWidth = static_cast<std::uint32_t>(columns) * m_terminal.cellPixelWidth;
    const std::uint32_t textHeight = static_cast<std::uint32_t>(rows) * m_terminal.cellPixelHeight;
    const auto paddingWidth = static_cast<std::uint32_t>(std::max(0, static_cast<int>(m_terminal.drawablePixelWidth) - m_terminal.textAreaPixelWidth));
    const auto paddingHeight = static_cast<std::uint32_t>(std::max(0, static_cast<int>(m_terminal.drawablePixelHeight) - m_terminal.textAreaPixelHeight));
    m_requestedViewport = Protocol::Sync::Viewport { .rows = static_cast<std::uint16_t>(rows), .columns = static_cast<std::uint16_t>(columns), .cellPixelWidth = m_terminal.cellPixelWidth, .cellPixelHeight = m_terminal.cellPixelHeight, .textAreaPixelWidth = pixels(textWidth), .textAreaPixelHeight = pixels(textHeight), .drawablePixelWidth = pixels(textWidth + paddingWidth), .drawablePixelHeight = pixels(textHeight + paddingHeight) };
    serviceResize();
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

void WebTerminal::serviceResize()
{
    // The carrier has no visible terminal. Its hidden canvas must never size
    // the first pane in a workspace; each retained pane supplies its viewport.
    if (m_connectionMode == ConnectionMode::Workspace)
        return;
    const Protocol::Sync::ClientConnection* screen = m_sync.screen();
    if (!m_requestedViewport || !screen || !screen->welcome()
        || screen->state() != Protocol::Sync::ConnectionState::Attached
        || !screen->handleForPane({ .low = this->sessionID(), .high = m_sync.daemonInstanceID() }))
        return;
    if (!m_workspace)
        m_sync.setWindowViewport(*m_requestedViewport);
    if (m_resizeCallID || m_sentViewport == m_requestedViewport)
        return;
    switch (screen->welcome()->grantedRole) {
    case Protocol::Sync::Role::Agent:
        // The proxy's verified identity wins over the browser's Human claim.
        // This explicit call is still checked for Drive by the host registry.
        m_resizeCallID = m_sync.overridePaneGeometry(this->sessionID(), m_requestedViewport->rows, m_requestedViewport->columns);
        if (!m_resizeCallID)
            return;
        break;
    case Protocol::Sync::Role::Owner:
    case Protocol::Sync::Role::Driver:
        m_sync.setPaneViewport(this->sessionID(), *m_requestedViewport);
        break;
    case Protocol::Sync::Role::Viewer:
        break;
    }
    m_sentViewport = m_requestedViewport;
}

const std::vector<std::uint8_t>& WebTerminal::buildListSessions()
{
    m_frame.clear();
    if (subscribeHostListing())
        m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

namespace {

/// This machine's wall clock, in milliseconds since the Unix epoch.
std::uint64_t wallNowUnixMilliseconds()
{
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

} // namespace

bool WebTerminal::subscribeHostListing()
{
    // A new subscription is a new answer to read: the previous connection's
    // tree describes a host this one has not been told of.
    if (!m_sync.screen() || !m_sync.screen()->welcome() || !m_sync.isScreenAttached() || m_sessionListRequestID == UINT32_MAX)
        return false;
    const std::string id = "ubiquitty.host-listing." + std::to_string(m_sessionListRequestID + 1);
    if (!m_sync.call(Session::HostListing::subscribeRequest(id)))
        return false;
    ++m_sessionListRequestID;
    m_hostListing = Session::HostListing(id);
    // What was asked on the connection before this one will not be answered.
    for (Runtime::StructureResult& unanswered : m_structureCalls.failAll("The connection to this host was replaced before it answered."))
        noteHostStructureSettled(std::move(unanswered));
    return true;
}

void WebTerminal::noteHostStructureSettled(Runtime::StructureResult result)
{
    m_structureResult = std::move(result);
    ++m_hostStructureGeneration;
}

std::uint32_t WebTerminal::requestHostStructureChange(int operation, const char* target, const char* text, const char* tags, const char* window, int index)
{
    return requestConfirmedHostStructureChange(operation, target, text, tags, window, index, 0);
}

std::uint32_t WebTerminal::closeHostWindow(const char* window, std::uint32_t confirmationToken)
{
    return requestConfirmedHostStructureChange(std::to_underlying(Runtime::StructureOperation::CloseWindow), window, "", "", "", 0, confirmationToken);
}

const char* WebTerminal::hostDestructiveConfirmationJSON(int request, const char* target, const char* hostName)
{
    using Codec::JSON::Value;
    using Runtime::DestructiveRequest;
    Runtime::DestructiveConfirmation asked;
    const std::optional<Session::Identity::ObjectID> named = Session::Identity::parseObjectID(target ? target : "");
    if (request < std::to_underlying(DestructiveRequest::CloseWindow) || request > std::to_underlying(DestructiveRequest::TerminateWorkspace) || !named)
        asked.whyNot = "This is not a request this build asks about.";
    else
        asked = m_structureCalls.confirmations().ask(m_hostListing.isListing() ? &m_hostListing.tree() : nullptr, static_cast<DestructiveRequest>(request), *named, hostName ? hostName : "");
    Value question = Value::object();
    question.set("token", Value::number(static_cast<double>(asked.token)));
    question.set("title", Value::string(asked.title));
    question.set("body", Value::string(asked.body));
    question.set("safeButton", Value::string(asked.safeButton));
    question.set("destructiveButton", Value::string(asked.destructiveButton));
    // The two in the order they are added, each with what it does.
    Value buttons = Value::array();
    for (std::size_t index = 0; index < Runtime::DestructiveConfirmation::buttonCount; ++index) {
        Value button = Value::object();
        button.set("title", Value::string(asked.buttonTitle(index)));
        button.set("role", Value::string(Runtime::DestructiveConfirmation::buttonRole(index) == Runtime::ConfirmationButtonRole::Destructive ? "destructive" : "safeDefault"));
        buttons.push(std::move(button));
    }
    question.set("buttons", std::move(buttons));
    question.set("sessionCount", Value::number(asked.sessionCount()));
    question.set("whyNot", Value::string(asked.whyNot));
    m_hostDestructiveConfirmationJSON = Codec::JSON::serialize(question);
    return m_hostDestructiveConfirmationJSON.c_str();
}

const std::vector<std::uint8_t>& WebTerminal::buildConfirmedTerminate(int request, const char* target, std::uint32_t confirmationToken)
{
    using Runtime::DestructiveRequest;
    m_frame.clear();
    m_hostTerminateRefusal.clear();
    const std::optional<Session::Identity::ObjectID> named = Session::Identity::parseObjectID(target ? target : "");
    const bool isTerminate = request == std::to_underlying(DestructiveRequest::TerminateSession) || request == std::to_underlying(DestructiveRequest::TerminateWorkspace); // bool-ok: a local verdict
    if (!isTerminate || !named) {
        m_hostTerminateRefusal = "This is not a request this build sends.";
        return m_frame;
    }
    if (!m_owedTerminations.empty() || (m_terminateSessionID != 0 && m_terminateOutcome == TerminateOutcome::Pending)) {
        m_hostTerminateRefusal = "This host is still ending what was asked before. Try again in a moment.";
        return m_frame;
    }
    Runtime::DestructiveConfirmations::Redemption redemption = m_structureCalls.confirmations().redeem(confirmationToken, static_cast<DestructiveRequest>(request), *named, m_hostListing.isListing() ? &m_hostListing.tree() : nullptr);
    if (!redemption.refusal.empty()) {
        m_hostTerminateRefusal = std::move(redemption.refusal);
        return m_frame;
    }
    m_owedTerminations = std::move(redemption.sessionIDs);
    return buildOwedTerminate();
}

const std::vector<std::uint8_t>& WebTerminal::buildOwedTerminate()
{
    m_frame.clear();
    if (m_owedTerminations.empty() || !m_terminateRequestID.empty())
        return m_frame;
    const std::uint32_t next = m_owedTerminations.front();
    (void)buildTerminateSession(next);
    if (!m_frame.empty())
        m_owedTerminations.erase(m_owedTerminations.begin());
    return m_frame;
}

std::uint32_t WebTerminal::requestConfirmedHostStructureChange(int operation, const char* target, const char* text, const char* tags, const char* window, int index, std::uint64_t confirmationToken)
{
    using Runtime::StructureOperation;
    const std::optional<Session::Identity::ObjectID> named = Session::Identity::parseObjectID(target ? target : "");
    if (operation < std::to_underlying(StructureOperation::SetLabel) || operation > std::to_underlying(StructureOperation::CloseWindow) || !named || index < 0)
        return 0;
    Runtime::StructureRequest request;
    request.operation = static_cast<StructureOperation>(operation);
    request.target = *named;
    request.text = text ? text : "";
    request.index = static_cast<std::uint32_t>(index);
    request.confirmationToken = confirmationToken;
    if (const std::optional<Session::Identity::ObjectID> standing = Session::Identity::parseObjectID(window ? window : ""))
        request.window = *standing;
    for (std::string_view rest = tags ? tags : ""; !rest.empty();) {
        const std::size_t end = rest.find('\n');
        request.tags.emplace_back(rest.substr(0, end));
        rest = end == std::string_view::npos ? std::string_view() : rest.substr(end + 1);
    }
    Runtime::StructureCalls::Admission admission = m_structureCalls.admit(request, m_hostListing.isListing() ? &m_hostListing.tree() : nullptr);
    if (!admission.refusal && !m_sync.call(admission.call))
        admission.refusal = m_structureCalls.withdraw(admission.requestID, "This host is not connected. Try again once it is.");
    if (admission.refusal)
        noteHostStructureSettled(std::move(*admission.refusal));
    return static_cast<std::uint32_t>(admission.requestID);
}

const char* WebTerminal::hostStructureResultJSON()
{
    using Codec::JSON::Value;
    Value result = Value::object();
    result.set("requestID", Value::number(static_cast<double>(m_structureResult.requestID)));
    if (m_structureResult.requestID != 0) {
        const char* outcome = "unanswered";
        switch (m_structureResult.outcome) {
        case Runtime::StructureOutcome::Served:
            outcome = "served";
            break;
        case Runtime::StructureOutcome::RefusedByHost:
            outcome = "refusedByHost";
            break;
        case Runtime::StructureOutcome::RefusedHere:
            outcome = "refusedHere";
            break;
        case Runtime::StructureOutcome::Unanswered:
            break;
        }
        result.set("operation", Value::number(std::to_underlying(m_structureResult.operation)));
        result.set("target", Value::string(Session::Identity::format(m_structureResult.target)));
        result.set("outcome", Value::string(outcome));
        result.set("reason", Value::string(m_structureResult.reason));
    }
    m_hostStructureResultJSON = Codec::JSON::serialize(result);
    return m_hostStructureResultJSON.c_str();
}

void WebTerminal::serviceHostListing()
{
    const std::uint64_t now = wallNowUnixMilliseconds();
    bool didMove = false; // bool-ok: a local verdict
    std::vector<WebTerminal*> views { this };
    views.insert(views.end(), m_workspacePanes.begin(), m_workspacePanes.end());
    for (const Protocol::Sync::Notify& notify : m_sync.takeHostNotifies()) {
        using Codec::JSON::Value;
        using Protocol::Sync::NotifyKind;
        const auto kindName = [](Protocol::Sync::ConsentKind kind) -> std::string {
            switch (kind) {
            case Protocol::Sync::ConsentKind::Attach:
                return "attach";
            case Protocol::Sync::ConsentKind::Terminate:
                return "terminate";
            case Protocol::Sync::ConsentKind::Capability:
                return "capability";
            case Protocol::Sync::ConsentKind::Structure:
                return "structure";
            }
            return {};
        };
        Value question = Value::object();
        if (notify.kind == NotifyKind::ConsentQuestion) {
            if (const auto request = Protocol::Sync::decodeConsentQuestion(notify.record)) {
                const auto kind = static_cast<Protocol::Sync::ConsentKind>(request->action);
                question.set("request", Value::number(request->requestID));
                question.set("session", Value::number(request->sessionID));
                question.set("kind", Value::string(kindName(kind)));
                question.set("process", Value::string(Title::sanitizedBannerText(request->peerProcess, Title::LevelMarks::Remove)));
                question.set("label", Value::string(Title::sanitizedBannerText(request->agentLabel, Title::LevelMarks::Remove)));
                question.set("question", Value::string(kind == Protocol::Sync::ConsentKind::Attach ? "Allow this agent to join the session?" : kind == Protocol::Sync::ConsentKind::Terminate ? "Allow this agent to end the session?"
                                                                                                                                                                                              : Security::capabilityConsentTitle(request->capabilityCode)));
            }
        } else if (notify.kind == NotifyKind::StructureConsent) {
            if (const auto request = Protocol::Sync::decodeStructureConsent(notify.record)) {
                question.set("request", Value::number(request->requestID));
                question.set("session", Value::number(request->sessionID));
                question.set("kind", Value::string("structure"));
                question.set("process", Value::string(Title::sanitizedBannerText(request->peerProcess, Title::LevelMarks::Remove)));
                question.set("label", Value::string(Title::sanitizedBannerText(request->agentLabel, Title::LevelMarks::Remove)));
                question.set("question", Value::string("Allow this agent to change the workspace?"));
                question.set("method", Value::string(request->method));
                question.set("parameters", Value::string(Title::sanitizedBannerText(request->parameters, Title::LevelMarks::Remove)));
            }
        } else if (notify.kind == NotifyKind::ConsentResolved) {
            if (const auto resolved = Protocol::Sync::decodeConsentResolved(notify.record)) {
                std::erase_if(m_webConsentQuestions, [&](const auto& held) {
                    return held.numberOr("request") == resolved->requestID && held.numberOr("session") == resolved->sessionID
                        && held.stringOr("kind") == kindName(resolved->kind);
                });
            }
        }
        if (question.find("request")) {
            const auto held = std::ranges::find_if(m_webConsentQuestions, [&](const auto& item) {
                return item.numberOr("request") == question.numberOr("request") && item.stringOr("kind") == question.stringOr("kind");
            });
            if (held != m_webConsentQuestions.end())
                *held = std::move(question);
            else if (m_webConsentQuestions.size() < 32)
                m_webConsentQuestions.push_back(std::move(question));
            // Overflow cannot grant: the host's deadline retires unanswered requests.
        }
        if (notify.kind == Protocol::Sync::NotifyKind::Attachments) {
            if (auto list = Protocol::Sync::decodeAttachments(notify.record))
                m_sync.noteAttachments(std::move(*list));
        }
        if (notify.kind != Protocol::Sync::NotifyKind::PasteReady)
            continue;
        if (const auto ready = Protocol::Control::decodePasteReady(notify.record)) {
            for (auto* view : views) {
                if (view->m_pasteSource.credit(*ready) == Protocol::Control::PasteCreditDisposition::Refused)
                    view->m_pasteSource.clear();
            }
        }
    }
    for (const std::string& response : m_sync.takeCallResults()) {
        bool isWebJSON = false;
        const auto webAnswer = Codec::JSON::parse(response, isWebJSON);
        const auto webID = isWebJSON ? webAnswer.stringOr("id") : std::string();
        const auto pendingWeb = std::ranges::find(m_pendingWebCalls, webID);
        if (pendingWeb != m_pendingWebCalls.end()) {
            m_webCallResults.push_back(response);
            m_pendingWebCalls.erase(pendingWeb);
            continue;
        }
        bool didSettleView = false;
        for (auto* view : views) {
            if (view->m_pasteSource.isActive() && isWebJSON) {
                const auto settled = Protocol::Control::decodePastePushReply(webAnswer, view->m_pasteSource.requestID(), view->m_pasteSource.request().pane);
                if (settled || settled.error() != Protocol::Control::PasteReplyFailure::Unrelated) {
                    view->m_pasteSource.clear();
                    didSettleView = true;
                }
            }
            const auto* id = webAnswer.find("id");
            if (view->m_resizeCallID && isWebJSON && id && id->isNumber()
                && id->asNumber() == static_cast<double>(*view->m_resizeCallID)) {
                view->m_resizeCallID.reset();
                didSettleView = true;
            }
        }
        if (didSettleView)
            continue;
        if (m_terminateOutcome == TerminateOutcome::Pending && !m_terminateRequestID.empty()) {
            bool isJSON = false;
            const auto answer = Codec::JSON::parse(response, isJSON);
            const auto outcome = isJSON ? Protocol::Control::terminationOutcome(answer, m_terminateRequestID, m_terminateSessionID) : std::nullopt;
            if (outcome) {
                using Protocol::Control::TerminationOutcome;
                switch (*outcome) {
                case TerminationOutcome::Terminated:
                case TerminationOutcome::Forgotten:
                    settleTerminate(TerminateOutcome::Terminated);
                    break;
                case TerminationOutcome::Denied:
                    settleTerminate(TerminateOutcome::Denied);
                    break;
                case TerminationOutcome::TimedOut:
                    settleTerminate(TerminateOutcome::TimedOut);
                    break;
                case TerminationOutcome::Refused:
                    settleTerminate(TerminateOutcome::Refused);
                    break;
                case TerminationOutcome::Failed:
                    settleTerminate(TerminateOutcome::Failed);
                    break;
                }
                continue;
            }
        }
        // An answer is a change's or the listing's, by the id it carries.
        if (std::optional<Runtime::StructureResult> settled = m_structureCalls.noteAnswer(response)) {
            noteHostStructureSettled(std::move(*settled));
            continue;
        }
        didMove = m_hostListing.noteAnswer(response, now) != Session::HostListing::Answer::NotThisCall || didMove;
    }
    // A structure this build cannot read leaves the tree as it last stood.
    if (const Protocol::Sync::ClientConnection* screen = m_sync.screen())
        didMove = m_hostListing.refresh(*screen, m_sync.listingRevision(), now) == Session::HostListing::Change::Assembled || didMove;
    if (didMove) {
        ++m_hostOutlineGeneration;
        if (m_hostListing.isListing() && m_hostListing.isWhole())
            ++m_hostAnswerGeneration;
    }
}

const char* WebTerminal::hostOutlineJSON(const char* query)
{
    // The page is a terminal: with no theme applied its marks are drawn in
    // what its own palette derives, as its grid is.
    m_hostOutlineRequest.query = query ? query : "";
    m_hostOutlineRequest.themeIndex = m_themeIndex;
    m_hostOutlineJSON = Codec::JSON::serialize(App::outlineJSON(Runtime::buildHostOutline(m_hostListing.tree(), Preferences::values(),
        m_themeIndex < 0 ? Themes::StatusColors {} : Runtime::readerStatusColors(Preferences::values(), m_themeIndex), m_hostOutlineRequest, m_hostListing.isListing() ? std::optional(m_hostListing.hostNowUnixMilliseconds(wallNowUnixMilliseconds())) : std::nullopt)));
    return m_hostOutlineJSON.c_str();
}

const std::vector<std::uint8_t>& WebTerminal::buildHostCall(const char* method, const char* parameters, std::uint32_t requestID)
{
    namespace Control = Protocol::Control;
    using Codec::JSON::Value;
    m_frame.clear();
    m_hostCallRefusal.clear();
    const auto refuse = [&](std::string reason) -> const std::vector<std::uint8_t>& {
        m_hostCallRefusal = std::move(reason);
        return m_frame;
    };
    if (!requestID || m_pendingWebCalls.size() + m_webCallResults.size() >= 16)
        return refuse("Too many host requests are waiting for an answer.");
    if (!parameters || std::string_view(parameters).size() > Protocol::Sync::maxFrameBodyBytes)
        return refuse("The host request is too large.");
    const auto* descriptor = Control::findSyncMethod(method ? method : "");
    if (!descriptor)
        return refuse("This build does not know that host operation.");
    bool isJSON = false;
    auto params = Codec::JSON::parse(parameters, isJSON);
    if (!isJSON)
        return refuse("Host parameters must be JSON.");
    if (const auto violation = Control::validate(params, Control::parseRegistryJSON(descriptor->parametersSchema)))
        return refuse(violation->path + ": " + violation->message);
    const std::string id = "ubiquitty.web-call." + std::to_string(requestID);
    if (std::ranges::find(m_pendingWebCalls, id) != m_pendingWebCalls.end())
        return refuse("That host request is already pending.");
    Value request = Value::object();
    request.set("jsonrpc", Value::string("2.0"));
    request.set("id", Value::string(id));
    request.set("method", Value::string(method));
    request.set("params", std::move(params));
    if (!m_sync.call(Codec::JSON::serialize(request)))
        return refuse("The host is not connected.");
    m_pendingWebCalls.push_back(id);
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

const char* WebTerminal::takeHostCallResultJSON()
{
    m_webCallResultJSON.clear();
    if (!m_webCallResults.empty()) {
        m_webCallResultJSON = std::move(m_webCallResults.front());
        m_webCallResults.erase(m_webCallResults.begin());
    }
    return m_webCallResultJSON.c_str();
}

const char* WebTerminal::hostWorkspaceJSON()
{
    using Codec::JSON::Value;
    const auto topology = [](const auto& self, const Protocol::Sync::TopologyNode& node) -> Value {
        Value result = Value::object();
        if (node.isLeaf())
            result.set("sessionID", Value::number(static_cast<double>(node.paneID.low)));
        else {
            result.set("axis", Value::string(node.axis == Protocol::Sync::SplitAxis::Horizontal ? "horizontal" : "vertical"));
            result.set("ratio", Value::number(node.ratio));
            Value children = Value::array();
            for (const auto& child : node.children)
                children.push(self(self, child));
            result.set("children", std::move(children));
        }
        return result;
    };
    Value result = Value::object();
    result.set("complete", Value::boolean(m_hostListing.isWhole()));
    result.set("refused", Value::boolean(isHostListingRefused()));
    result.set("daemonInstanceID", Value::string(std::to_string(m_sync.daemonInstanceID())));
    Value workspaces = Value::array();
    for (const auto& workspace : m_hostListing.tree().workspaces) {
        Value entry = Value::object();
        entry.set("id", Value::number(workspace.id));
        entry.set("revision", Value::string(std::to_string(workspace.revision)));
        entry.set("name", Value::string(workspace.name));
        entry.set("label", Value::string(workspace.label));
        entry.set("defaultName", Value::string(workspace.defaultName()));
        entry.set("restorable", Value::boolean(workspace.isRestorable()));
        entry.set("activeWindow", Value::number(static_cast<double>(workspace.hostActiveWindow)));
        Value windows = Value::array();
        for (const auto& window : workspace.windows) {
            Value windowEntry = Value::object();
            windowEntry.set("id", Value::number(std::to_underlying(window.id)));
            windowEntry.set("label", Value::string(window.label));
            windowEntry.set("activeTab", Value::number(static_cast<double>(window.hostActiveTab)));
            Value tabs = Value::array();
            for (const auto& tab : window.tabs) {
                Value tabEntry = Value::object();
                tabEntry.set("id", Value::number(std::to_underlying(tab.id)));
                tabEntry.set("name", Value::string(tab.name));
                tabEntry.set("label", Value::string(tab.label));
                tabEntry.set("focusedPane", Value::number(static_cast<double>(tab.hostFocusedPane)));
                tabEntry.set("split", topology(topology, tab.split));
                Value panes = Value::array();
                for (const auto& pane : tab.panes) {
                    const auto& facts = pane.facts;
                    Value paneEntry = Value::object();
                    paneEntry.set("id", Value::number(std::to_underlying(pane.id)));
                    paneEntry.set("sessionID", Value::number(pane.sessionID));
                    paneEntry.set("label", Value::string(pane.label.empty() ? pane.sessionLabel : pane.label));
                    paneEntry.set("title", Value::string(facts.programTitle));
                    paneEntry.set("tabTitle", Value::string(App::composeTitle(pane.title, App::TitleViewerFacts {}, Preferences::Effective::tabTitleComposition(Preferences::values()), Session::TitleSurface::Tab).title));
                    paneEntry.set("directory", Value::string(facts.currentDirectory));
                    paneEntry.set("homeDirectory", Value::string(facts.homeDirectory));
                    paneEntry.set("processChain", Value::string(facts.processChain));
                    paneEntry.set("processChainWithArguments", Value::string(facts.processChainWithArguments));
                    paneEntry.set("foreground", Value::string(facts.foreground.name));
                    paneEntry.set("rows", Value::number(facts.rows));
                    paneEntry.set("columns", Value::number(facts.columns));
                    paneEntry.set("ended", Value::boolean(facts.end.didEnd));
                    paneEntry.set("zoomed", Value::boolean(pane.isHostZoomed));
                    paneEntry.set("status", Value::string(std::string(App::statusKindWord(pane.status.kind))));
                    Value attendees = Value::array();
                    for (const auto& attendee : pane.attendees) {
                        Value person = Value::object();
                        person.set("id", Value::number(attendee.clientID));
                        person.set("agent", Value::boolean(attendee.kind == Session::TreeAttendeeKind::Agent));
                        attendees.push(std::move(person));
                    }
                    paneEntry.set("attendees", std::move(attendees));
                    panes.push(std::move(paneEntry));
                }
                tabEntry.set("panes", std::move(panes));
                tabs.push(std::move(tabEntry));
            }
            windowEntry.set("tabs", std::move(tabs));
            windows.push(std::move(windowEntry));
        }
        entry.set("windows", std::move(windows));
        workspaces.push(std::move(entry));
    }
    result.set("workspaces", std::move(workspaces));
    Value attendees = Value::array();
    if (const auto* attachment = m_sync.attachment()) {
        for (const auto& peer : attachment->attachments()) {
            Value item = Value::object();
            item.set("id", Value::string(Session::backgroundPaneID(peer.attachmentID.high, peer.attachmentID.low)));
            item.set("agent", Value::boolean(peer.clientKind == Protocol::Sync::ClientKind::Agent));
            item.set("self", Value::boolean(peer.isSelf));
            item.set("live", Value::boolean(peer.state == Protocol::Sync::AttachmentState::Live));
            item.set("driver", Value::boolean(peer.role == Protocol::Sync::AttachmentRole::Driver));
            item.set("geometryOwner", Value::boolean(peer.isGeometryOwner));
            if (peer.presence) {
                item.set("label", Value::string(peer.presence->claimedLabel));
                item.set("process", Value::string(peer.presence->process));
                item.set("identity", Value::string(peer.presence->grantIdentity));
            }
            Value sessions = Value::array();
            for (const auto& pane : peer.panes)
                sessions.push(Value::number(static_cast<double>(pane.low)));
            item.set("sessions", std::move(sessions));
            attendees.push(std::move(item));
        }
    }
    result.set("attendees", std::move(attendees));
    Value questions = Value::array();
    for (const auto& question : m_webConsentQuestions)
        questions.push(question);
    result.set("questions", std::move(questions));
    m_hostWorkspaceJSON = Codec::JSON::serialize(result);
    return m_hostWorkspaceJSON.c_str();
}

bool WebTerminal::collapseHostOutlineRow(const char* id)
{
    const std::optional<Session::Identity::ObjectID> row = Session::Identity::parseObjectID(id ? id : "");
    return row && m_hostOutlineRequest.close(std::to_underlying(row->kind), row->number);
}

bool WebTerminal::expandHostOutlineRow(const char* id)
{
    const std::optional<Session::Identity::ObjectID> row = Session::Identity::parseObjectID(id ? id : "");
    return row && m_hostOutlineRequest.open(std::to_underlying(row->kind), row->number);
}

bool WebTerminal::expandAllUnderHostOutlineRow(const char* id)
{
    const std::optional<Session::Identity::ObjectID> row = Session::Identity::parseObjectID(id ? id : "");
    return row && m_hostListing.isListing() && m_hostOutlineRequest.openAllUnder(m_hostListing.tree(), std::to_underlying(row->kind), row->number);
}

bool WebTerminal::expandAllUnderRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab)
{
    return level >= 0 && level <= 0xFF && window >= 0 && tab >= 0 && m_hostListing.isListing()
        && m_hostOutlineRequest.openAllUnderRecorded(m_hostListing.tree(), workspaceID, static_cast<std::uint8_t>(level), static_cast<std::size_t>(window), static_cast<std::size_t>(tab));
}

bool WebTerminal::collapseRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab)
{
    return level >= 0 && level <= 0xFF && window >= 0 && tab >= 0
        && m_hostOutlineRequest.closeRecorded(workspaceID, static_cast<std::uint8_t>(level), static_cast<std::size_t>(window), static_cast<std::size_t>(tab));
}

bool WebTerminal::expandRecordedHostOutlineRow(std::uint32_t workspaceID, int level, int window, int tab)
{
    return level >= 0 && level <= 0xFF && window >= 0 && tab >= 0
        && m_hostOutlineRequest.openRecorded(workspaceID, static_cast<std::uint8_t>(level), static_cast<std::size_t>(window), static_cast<std::size_t>(tab));
}

const std::vector<std::uint8_t>& WebTerminal::buildTerminateSession(std::uint32_t sessionID)
{
    m_frame.clear();
    if (!sessionID || !m_sync.isScreenAttached() || m_nextTerminateRequestID == std::numeric_limits<std::uint64_t>::max()
        || (m_terminateSessionID && m_terminateOutcome == TerminateOutcome::Pending))
        return m_frame;
    const auto requestID = "ubiquitty.terminate." + std::to_string(++m_nextTerminateRequestID);
    if (!m_sync.call(Protocol::Control::terminationRequest(sessionID, requestID)))
        return m_frame;
    m_terminateSessionID = sessionID;
    m_terminateRequestID = requestID;
    m_terminateOutcome = TerminateOutcome::Pending;
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

void WebTerminal::settleTerminate(TerminateOutcome outcome)
{
    // The first answer is the answer. A deadline elapsing behind a
    // correlated result already read, or a frame still in flight when the row
    // settled, would otherwise report a second outcome for one ask.
    if (m_terminateSessionID == 0 || m_terminateOutcome != TerminateOutcome::Pending || outcome == TerminateOutcome::Pending)
        return;
    m_terminateOutcome = outcome;
    m_terminateRequestID.clear();
    ++m_terminateGeneration;
}

void WebTerminal::noteTerminateGraceElapsed()
{
    // The page's short liveness interval cannot settle a destructive call.
}

void WebTerminal::noteTerminateDeadlineElapsed()
{
    settleTerminate(TerminateOutcome::TimedOut);
}

void WebTerminal::noteTerminateTransportLost()
{
    settleTerminate(TerminateOutcome::Failed);
    m_sync.noteTransportLost();
}

void WebTerminal::loadHostRecord(const char* hostKey, const char* bytes, int length)
{
    if (!hostKey || length < 0 || (!bytes && length > 0))
        return;
    // Nothing stored is not an empty record: an empty one would answer recall
    // with bytes that decode to no pairing, which reads as a corrupt store
    // rather than as a host never visited.
    if (length == 0) {
        m_hostRecords.erase(hostKey);
        return;
    }
    m_hostRecords[hostKey].assign(bytes, bytes + length);
}

Session::AttachPlan WebTerminal::decideAttach(const char* hostKey, const char* predefinedWorkspaceName)
{
    const std::string key = hostKey ? hostKey : "";
    // A host that has not answered on this page yet, or whose tree is not
    // whole, has no tree for the rule to read: it is never a host holding
    // nothing.
    const bool isAnswer = m_hostAnswerGeneration != 0 && m_hostListing.isListing() && m_hostListing.isWhole(); // bool-ok: names the one state it reports
    m_decision = Session::RememberedSessions::decide(m_rememberedSessions.recall(key),
        predefinedWorkspaceName ? std::string(predefinedWorkspaceName) : std::string(), isAnswer ? &m_hostListing.tree() : nullptr);
    return m_decision.plan;
}

void WebTerminal::rememberHostSession(const char* hostKey, std::uint32_t sessionID, const char* workspaceName)
{
    if (!hostKey)
        return;
    m_rememberedSessions.remember(hostKey, sessionID, workspaceName ? std::string(workspaceName) : std::string());
}

void WebTerminal::forgetHostSession(const char* hostKey)
{
    if (!hostKey)
        return;
    m_rememberedSessions.forget(hostKey);
}

const char* WebTerminal::hostRecordBytes(const char* hostKey) const
{
    if (!hostKey)
        return "";
    const auto found = m_hostRecords.find(hostKey);
    return found == m_hostRecords.end() ? "" : found->second.c_str();
}

int WebTerminal::hostRecordLength(const char* hostKey) const
{
    if (!hostKey)
        return 0;
    const auto found = m_hostRecords.find(hostKey);
    return found == m_hostRecords.end() ? 0 : static_cast<int>(found->second.size());
}

const std::vector<std::uint8_t>& WebTerminal::pointer(Input::PointerFact fact)
{
    m_frame.clear();
    m_localPointerInput.clear();
    m_pointerVerdict = 0;
    fact.viewOffset = m_viewOffset;
    auto policy = Input::pointerPolicyFromPreferences(Preferences::values());
    if (m_terminal.modes.shouldDeleteReadlineSelection && fact.button == Input::PointerButton::Right) {
        const auto* screen = m_sync.screen();
        const auto context = screen ? screen->echoContext(m_sync.paneHandle(this->sessionID())) : std::nullopt;
        if (context)
            policy.readlineEraseCharacter = context->eraseCharacter;
    }
    const Input::PointerRoute route = Input::routePointer(m_pointerLadder, m_terminal, &m_selection, fact,
        policy, static_cast<std::uint32_t>(PAL::monotonicTicks().count));
    const auto sendBytes = [&](std::string_view bytes) {
        if (m_isHostMirror)
            appendRawInput(bytes);
        else
            m_localPointerInput.insert(m_localPointerInput.end(), bytes.begin(), bytes.end());
    };
    if (route.locatorReportLength > 0)
        sendBytes({ route.locatorReport.data(), static_cast<std::size_t>(route.locatorReportLength) });
    if (route.reportLength > 0) {
        // The host encodes a pointer event under the modes live when it
        // writes it; a report with no event behind it travels as its bytes.
        if (m_isHostMirror && route.reported)
            appendIntent(Protocol::Sync::PointerInput { .events = { Runtime::pointerEventOf(*route.reported) } });
        else
            sendBytes({ route.report.data(), static_cast<std::size_t>(route.reportLength) });
    }
    if (!route.readlineInput.empty())
        sendBytes({ route.readlineInput.data(), route.readlineInput.size() });
    if (route.wasConsumed)
        m_pointerVerdict |= PointerVerdictConsumed;
    if (route.needsDisplay || route.needsRepublish)
        m_pointerVerdict |= PointerVerdictNeedsDisplay;
    if (route.didOpenSelectionGesture)
        m_pointerVerdict |= PointerVerdictOpenedGesture;
    if (route.didFinishSelectionGesture)
        m_pointerVerdict |= PointerVerdictFinishedGesture;
    return m_frame;
}

const std::vector<std::uint8_t>& WebTerminal::scroll(const Input::ScrollFact& fact)
{
    m_frame.clear();
    m_localPointerInput.clear();
    m_pointerVerdict = 0;
    // A pixel delta normalises by the live cell height, which is the
    // points-per-line the tuning wants.
    const Screen::ScrollTuning::Policy tuning = Preferences::Effective::wheelPolicy(Preferences::values(),
        static_cast<double>(cellHeight() > 0 ? cellHeight() : 1));
    const Input::ScrollRoute route = Input::routeScroll(m_pointerLadder, m_terminal, fact, tuning);
    if (route.byteLength > 0) {
        if (m_isHostMirror)
            appendRawInput({ route.bytes.data(), static_cast<std::size_t>(route.byteLength) });
        else
            m_localPointerInput.insert(m_localPointerInput.end(), route.bytes.data(), route.bytes.data() + route.byteLength);
    }
    if (route.linesToOffsetView != 0) {
        m_viewOffset = Ubiquitty::Screen::clampViewOffset(m_viewOffset + static_cast<int>(route.linesToOffsetView), Ubiquitty::Screen::scrollbackCount(&m_terminal));
        m_pointerVerdict |= PointerVerdictNeedsDisplay;
        // The history the move reached past rides with the gesture's frame.
        if (pullHistory())
            m_sync.takeScreenOutput(m_frame);
    }
    if (route.wasConsumed)
        m_pointerVerdict |= PointerVerdictConsumed;
    return m_frame;
}

namespace {

} // namespace

int WebTerminal::historyRows() const
{
    // The alternate screen keeps no scrollable history (its view offset is
    // forced to 0), so absolute and visible coincide there.
    return Ubiquitty::Screen::scrollableRowCount(&m_terminal);
}

void WebTerminal::clearSelection()
{
    (void)Selection::clearSelection(m_selection);
}

bool WebTerminal::hasSelection() const
{
    return Selection::hasSelection(m_selection);
}

const char* WebTerminal::selectionText()
{
    // The facade's copy walk: wide glyphs whole, soft-wrapped rows joined,
    // trailing blanks trimmed — byte-identical to the other frontends.
    m_selectionText = Selection::copiedText(m_selection, m_terminal);
    return m_selectionText.c_str();
}

// One span per selected visible row, after Core's per-row void rule: a row whose
// selection covers only trailing blanks contributes nothing, so the highlight
// stops at the text rather than running to the window edge.
void WebTerminal::buildSelectionSpans()
{
    m_selectionSpans.clear();
    m_richTextSelections.resize(RichText::maxBlocksPerScreen);
    const int blockCount = Selection::blockSelections(m_selection, m_terminal, m_richTextSelections);
    m_richTextSelections.resize(static_cast<std::size_t>(blockCount));
    if (m_terminal.rows <= 0)
        return;
    // Core resolves the wide-aware bounds, the per-row void rule and the
    // absolute-to-viewport mapping; this side only sizes the scratch, to the
    // room Core says holds every span and piece of the grid.
    m_selectionSpans.resize(static_cast<size_t>(Selection::viewportSpanCapacity(m_terminal.rows, m_terminal.columns)));
    const int spanCount = Selection::viewportSpans(m_selection, m_terminal, m_viewOffset,
        Selection::ViewportSpans { m_selectionSpans.data(), m_selectionSpans.size() });
    m_selectionSpans.resize(static_cast<size_t>(spanCount > 0 ? spanCount : 0));
}

// The DEC mode 1001 hilite band the host asked to track. The band's shape is
// Core's, so this supplies the terminal's four scalars and nothing else: a
// frontend deriving the rows itself is how the same region ends up drawn three
// slightly different ways.
void WebTerminal::buildHiliteSpans()
{
    m_hiliteSpans.clear();
    if (!m_terminal.modes.hiliteRegionValid || m_terminal.rows <= 0 || m_terminal.columns <= 0)
        return;
    m_hiliteSpans.resize(static_cast<std::size_t>(m_terminal.rows));
    const int count = Rendering::hiliteRegionRowSpans(m_terminal.modes.hiliteStartX, m_terminal.modes.hiliteStartY,
        m_terminal.modes.hiliteFirstRow, m_terminal.modes.hiliteLastRow, m_terminal.rows, m_terminal.columns,
        m_viewOffset, m_hiliteSpans.data(), m_terminal.rows);
    m_hiliteSpans.resize(static_cast<std::size_t>(count));
}

void WebTerminal::scrollBy(int rows)
{
    m_viewOffset = Ubiquitty::Screen::clampViewOffset(m_viewOffset + rows, Ubiquitty::Screen::scrollbackCount(&m_terminal));
    (void)pullHistory();
}

void WebTerminal::scrollToAbsoluteRow(int absoluteRow)
{
    const int history = historyRows();
    m_viewOffset = Ubiquitty::Screen::viewOffsetToReveal(
        history, m_terminal.rows, absoluteRow, Ubiquitty::Screen::RevealPlacement::CommandBlock);
    (void)pullHistory();
}

bool WebTerminal::pullHistory()
{
    const Protocol::Sync::ClientConnection* screen = m_sync.screen();
    if (!screen || screen->state() != Protocol::Sync::ConnectionState::Attached)
        return false;
    const std::uint32_t sessionID = this->sessionID();
    const std::uint32_t handle = m_sync.paneHandle(sessionID);
    const Protocol::Sync::HistoryCache* history = handle ? screen->historyCache(handle) : nullptr;
    if (!history)
        return false;
    const std::optional<Protocol::Sync::HistoryPull::Want> want = m_historyPull.wantFor(*history, m_terminal, m_viewOffset);
    if (!want || !m_sync.wantPaneHistory(sessionID, Protocol::Sync::HistoryPriority::Viewport, want->gaps))
        return false;
    m_historyPull.noteSent(*want);
    return true;
}

bool WebTerminal::setBackgroundImage(std::span<const std::uint8_t> fileBytes)
{
    m_backgroundImage = fileBytes.empty() ? Rendering::BackgroundImagePixels {} : Rendering::decodeBackgroundImage(fileBytes);
    return fileBytes.empty() || !m_backgroundImage.isEmpty();
}

void WebTerminal::selectAll()
{
    // Oldest scrollback row through the live screen's last cell; the facade
    // applies the alternate screen's no-history rule itself.
    Selection::selectAllText(m_selection, m_terminal);
}

void WebTerminal::selectVisibleRectangle(const SelectionBounds& visible)
{
    m_selection.state = Selection::characterSelectionOverVisibleRows(m_terminal, visible);
}

void WebTerminal::selectBetweenPoints(double fromX, double fromY, double toX, double toY)
{
    Selection::selectBetweenPoints(m_selection, m_terminal, fromX, fromY, toX, toY);
}

bool WebTerminal::searchLiteral(const char* literal)
{
    const auto controller = searchController();
    if (!controller)
        return false;
    if (controller->setQuery(literalSearchRequest(literal)))
        m_searchExecutor.schedule(controller);
    return true;
}

Search::Request WebTerminal::literalSearchRequest(const char* literal)
{
    return { .pattern = literal ? literal : "", .sensitivity = CaseSensitivity::Sensitive, .normalization = Screen::ScrollSearch::normalizationForm() };
}

std::shared_ptr<Search::SearchController> WebTerminal::searchController()
{
    if (!m_searchController) {
        m_searchController = Search::SearchController::make(m_terminal, m_modelLock, m_searchExecutor);
        if (m_searchController)
            m_searchController->setChangedCallback([](void* context) { static_cast<WebTerminal*>(context)->searchDidChange(); }, this);
        m_searchExecutor.schedule(m_searchController);
    }
    return m_searchController;
}

bool WebTerminal::pumpSearch()
{
    if (m_searchController) {
        const std::scoped_lock hold(m_modelLock);
        m_searchController->noteModelChanged(m_terminal);
    }
    return m_searchExecutor.pump(std::chrono::steady_clock::now() + std::chrono::milliseconds(4));
}

Search::Status WebTerminal::searchStatus() const
{
    if (m_searchController && m_searchController->requestedGeneration() != m_searchStatus.generation)
        return { .generation = m_searchController->requestedGeneration() };
    return m_searchStatus;
}

const char* WebTerminal::searchStatusJSON()
{
    using Codec::JSON::Value;
    const Search::Status status = searchStatus();
    Value result = Value::object();
    result.set("generation", Value::string(std::to_string(status.generation)));
    result.set("screenGeneration", Value::string(std::to_string(status.screenGeneration)));
    result.set("foundCount", Value::number(status.foundCount));
    result.set("activeIndex", Value::number(status.activeIndex));
    result.set("activeEpoch", Value::number(status.activeEpoch));
    result.set("revealEpoch", Value::number(status.revealEpoch));
    result.set("revealViewOffset", Value::number(status.revealViewOffset));
    result.set("isComplete", Value::boolean(status.isComplete));
    result.set("isPatternInvalid", Value::boolean(status.isPatternInvalid));
    result.set("isTruncated", Value::boolean(status.isTruncated));
    m_searchStatusJSON = Codec::JSON::serialize(result);
    return m_searchStatusJSON.c_str();
}

bool WebTerminal::stepSearch(Search::StepDirection direction)
{
    if (!m_searchController || m_searchController->status().generation != m_searchController->requestedGeneration())
        return false;
    {
        const std::scoped_lock hold(m_modelLock);
        if (!m_searchController->step(direction))
            return false;
    }
    searchDidChange();
    return true;
}

bool WebTerminal::searchLiteralAndWait(const char* literal)
{
    const auto controller = searchController();
    if (!controller)
        return false;
    const Search::Status status = controller->searchAndWait(literalSearchRequest(literal), std::chrono::seconds(30));
    return status.isComplete && !status.isPatternInvalid;
}

void WebTerminal::searchDidChange()
{
    const std::scoped_lock hold(m_modelLock);
    Search::Status status = m_searchController->status();
    if (status.generation != m_searchController->requestedGeneration())
        return;
    const bool shouldReveal = status.generation != m_searchStatus.generation || status.revealEpoch != m_searchStatus.revealEpoch;
    m_searchStatus = status;
    if (shouldReveal && status.revealViewOffset >= 0)
        scrollBy(status.revealViewOffset - m_viewOffset);
}

void WebTerminal::clearToPreviousMark()
{
    if (this->sessionID()) {
        (void)m_sync.clearPane(this->sessionID(), Screen::ClearCommand::ToPreviousMark);
        return;
    }
    (void)Screen::clearToMarkOrFull(&m_terminal, &m_viewOffset);
}

void WebTerminal::clearPreservingInput()
{
    clearBufferPreserveInput(&m_terminal);
}

bool WebTerminal::clearSelectionForUserInput()
{
    return Selection::clearSelectionForUserInput(m_selection);
}

// OSC 50. Core has already resolved the three axes, so this applies what it can
// and stages what it cannot: the size is this object's to change, the family
// reaches the rasterizer through a page-owned JavaScript global.
bool WebTerminal::Window::setFont(std::string_view family, double sizePoints, double sizeDelta)
{
    if (!family.empty())
        m_owner->m_pendingFontFamily.assign(family.begin(), family.end());
    // Absolute wins over relative, as Core's contract states; a request carrying
    // neither is a family-only change, or a reset the page resolves.
    if (sizePoints > 0.0)
        m_owner->setFontSize(sizePoints);
    else if (sizeDelta != 0.0)
        m_owner->setFontSize(m_owner->fontSize() + sizeDelta);
    else if (family.empty())
        m_owner->resetFontSize();
    return true;
}

// mintty's empty OSC 7770 / 7777 operand: the configured size alone, the
// family the page draws left as it is.
bool WebTerminal::Window::resetFontSize()
{
    m_owner->resetFontSize();
    return true;
}

int WebTerminal::cursorRow() const
{
    // The visible row: the cursor is on the live grid, so a scrolled-back view
    // puts it below the viewport and the clamp keeps the element on screen.
    // The same mapping the capture makes: the cursor sits on the live grid, so a
    // scrolled-back view moves it down the viewport.
    const int row = m_terminal.screens.active->cursorY + m_viewOffset;
    if (row < 0)
        return 0;
    return row < m_terminal.rows ? row : m_terminal.rows - 1;
}

int WebTerminal::cursorColumn() const
{
    const int column = m_terminal.screens.active->cursorX;
    if (column < 0)
        return 0;
    return column < m_terminal.columns ? column : m_terminal.columns - 1;
}

const std::vector<std::uint8_t>& WebTerminal::buildFocusChanged()
{
    m_frame.clear();
    // This frontend can always observe focus, so it never reports Unknown —
    // that state is for a client which genuinely cannot, and claiming it here
    // would tell the host to leave the mode alone.
    // The screen plane's facts carry it: the host turns a driver's focus
    // into the pane's, and writes the program its report under DECSET 1004.
    const Modes::FocusState focus = m_isFocused ? Modes::FocusState::Focused : Modes::FocusState::Unfocused;
    m_sync.setScreenFocus(focus);
    m_sync.setPaneFocus(this->sessionID(), focus);
    m_sync.takeScreenOutput(m_frame);
    return m_frame;
}

void WebTerminal::setFocus(Modes::FocusState focus)
{
    m_isFocused = focus == Modes::FocusState::Focused;
    if (m_isFocused) {
        m_hasUnheardBell = false;
    }
    // Core gates the CSI I / CSI O emission on the application having enabled
    // mode 1004 and records the state either way, so this is called on every
    // transition rather than only when something asked to hear about it.
    Ubiquitty::Modes::focusChanged(&m_terminal, focus);
}

const char* WebTerminal::pendingNotificationTitle() const { return m_notificationTitle.c_str(); }
const char* WebTerminal::pendingNotificationBody() const { return m_notificationBody.c_str(); }

const char* WebTerminal::pendingNotificationTag() const { return m_notificationTag.c_str(); }

void WebTerminal::takeNotification()
{
    m_notificationTitle.clear();
    m_notificationBody.clear();
    m_notificationTag.clear();
}

void WebTerminal::stageNotification(const NotificationRequest& request)
{
    // One terminal fills the page, so there is no place to state and the pane
    // is always the focused one. The page reports its focus and nothing finer,
    // so focus stands for the pane being looked at.
    const OSC::Banner banner = OSC::composeBanner(std::string(request.title), std::string(request.body), {});
    const OSC::BannerAudience audience { .isAppActive = m_isFocused, .isWindowKey = m_isFocused, .isPaneFocused = true, .isPaneVisible = m_isFocused };
    if (!banner.shouldPost || !OSC::isBannerWanted(audience, request.occasion))
        return;
    m_notificationTitle = banner.title;
    m_notificationBody = OSC::bannerRunningText(banner);
    m_notificationTag = OSC::bannerRequestIdentifier(OSC::BannerSource::Program, "page", 0, std::string(request.identifier));
}

const char* WebTerminal::currentDirectory() const { return m_currentDirectory.c_str(); }

const char* WebTerminal::pendingFontFamily() const
{
    return m_pendingFontFamily.c_str();
}

const char* WebTerminal::currentThemeName() const
{
    if (m_themeIndex < 0)
        return "";
    const Themes::Theme* theme = Themes::get(m_themeIndex);
    return theme && theme->name ? theme->name : "";
}

bool WebTerminal::setThemeByName(const char* name)
{
    if (!name || !*name)
        return false;
    const int index = Themes::indexForName(name);
    if (index < 0)
        return false;
    if (!Themes::applyThemeToTerminal(m_terminal, index))
        return false;
    m_themeIndex = index;
    return true;
}

void WebTerminal::followHostTheme()
{
    m_themeIndex = -1;
    m_sync.requestPaneCheckpoint(this->sessionID());
}

void WebTerminal::reapplyTheme()
{
    if (m_themeIndex < 0)
        return;
    // Unconditional on what the host sent. The screen plane carries a
    // palette that may itself hold a program's OSC 4/10/11 overrides, and this
    // does overwrite those — a program that recoloured the terminal loses that
    // when the user has also chosen a theme. The alternative is the user's
    // explicit choice silently reverting every few seconds, which is what was
    // reported. The palette does not distinguish an overridden slot from a
    // default one, so the two cannot both be honoured without a wire change.
    // A false return means the index no longer names a theme; nothing to do,
    // and the host's palette stands.
    (void)Themes::applyThemeToTerminal(m_terminal, m_themeIndex);
}

void WebTerminal::setFontOptions(std::vector<std::string> families, int currentIndex)
{
    m_fontOptions = std::move(families);
    m_fontIndex = currentIndex;
}

void WebTerminal::takeFontFamily()
{
    m_pendingFontFamily.clear();
}

void WebTerminal::noteBell()
{
    m_hasUnheardBell = m_hasUnheardBell || Runtime::doesBellMarkUnheard(m_isFocused);
}

const char* WebTerminal::title() const
{
    const auto* hostFacts = m_sync.paneFacts(this->sessionID());
    const std::string_view programTitle = hostFacts ? std::string_view(hostFacts->programTitle) : m_terminal.titleUTF8.view();
    const std::string_view status(m_terminal.tabStatusText.data(), m_terminal.tabStatusSet ? m_terminal.tabStatusTextLength : 0);
    // A browser tab has the program's title and its status to go on, and none
    // of the process facts a local pane supplies; a part with no input is
    // dropped whatever its switch says, so Core composes it as it would any
    // tab, from the reader's tab composition.
    App::PaneTitleFacts facts;
    facts.programTitle = programTitle;
    facts.programStatus = status;
    m_composedTitle = App::composeTitle(facts, App::TitleViewerFacts {}, Preferences::Effective::tabTitleComposition(Preferences::values()), Session::TitleSurface::Tab).title;
    if (m_hasUnheardBell) {
        m_composedTitle = "🔔 " + (m_composedTitle.empty() ? std::string("Ubiquitty") : m_composedTitle);
    }
    return m_composedTitle.c_str();
}

namespace {

/// A palette entry as `[r, g, b]`, eight bits a component.
Codec::JSON::Value capturedPaletteColor(const PaletteRGB& color)
{
    Codec::JSON::Value components = Codec::JSON::Value::array();
    components.push(Codec::JSON::Value::number(color.red >> 8));
    components.push(Codec::JSON::Value::number(color.green >> 8));
    components.push(Codec::JSON::Value::number(color.blue >> 8));
    return components;
}

/// A pen colour as the capture states it: null for the default, a palette index
/// as a number, a direct colour as `[r, g, b]`.
Codec::JSON::Value capturedColor(std::uint16_t index, std::uint8_t red, std::uint8_t green, std::uint8_t blue)
{
    if (index == colorDefault)
        return Codec::JSON::Value::null();
    if (index != colorRGB)
        return Codec::JSON::Value::number(index);
    Codec::JSON::Value components = Codec::JSON::Value::array();
    components.push(Codec::JSON::Value::number(red));
    components.push(Codec::JSON::Value::number(green));
    components.push(Codec::JSON::Value::number(blue));
    return components;
}

} // namespace

const char* WebTerminal::captureProgramState()
{
    const Screen::State& screen = *m_terminal.screens.active;
    Codec::JSON::Value rows = Codec::JSON::Value::array();
    std::array<std::uint32_t, clusterPoolMaximumCodePoints> cluster {};
    const auto cellText = [&](const Cell& cell) {
        std::string text;
        const int length = isTextContinuation(cell) ? 0 : cellClusterCodePoints(&m_terminal, &cell, cluster.data(), static_cast<int>(cluster.size()));
        for (const std::uint32_t codePoint : std::span(cluster).first(static_cast<std::size_t>(length)))
            Unicode::appendUTF8(text, codePoint);
        return text;
    };
    for (int row = 0; row < m_terminal.rows; ++row) {
        const Screen::VisibleRow source = Screen::resolveVisibleRow(&m_terminal, 0, row);
        Codec::JSON::Value cells = Codec::JSON::Value::array();
        for (int column = 0; column < m_terminal.columns; ++column) {
            const Cell& cell = *Screen::cellInResolvedRow(source, column, m_terminal.columns);
            const auto has = [&](VT::Attribute attribute) { return Codec::JSON::Value::boolean(cell.pen.attributes.contains(attribute)); };
            Codec::JSON::Value style = Codec::JSON::Value::object();
            style.set("fg", capturedColor(cell.pen.foregroundIndex, cell.pen.foregroundRed, cell.pen.foregroundGreen, cell.pen.foregroundBlue));
            style.set("bg", capturedColor(cell.pen.backgroundIndex, cell.pen.backgroundRed, cell.pen.backgroundGreen, cell.pen.backgroundBlue));
            style.set("bold", has(VT::Attribute::Bold));
            style.set("faint", has(VT::Attribute::Dim));
            style.set("italic", has(VT::Attribute::Italic));
            style.set("blink", has(VT::Attribute::Blink));
            style.set("inverse", has(VT::Attribute::Reverse));
            style.set("invisible", has(VT::Attribute::Hidden));
            style.set("strikethrough", has(VT::Attribute::Strike));
            style.set("overline", has(VT::Attribute::Overline));
            style.set("underline", Codec::JSON::Value::number(cell.pen.attributes.contains(VT::Attribute::Underline) ? penUnderlineShape(&cell.pen) : VT::underlineNone));
            style.set("link", Codec::JSON::Value::boolean(cell.linkID() != 0));
            style.set("semantic", Codec::JSON::Value::string(cell.pen.semanticRole == SemanticRole::Prompt ? "prompt" : cell.pen.semanticRole == SemanticRole::Input ? "input"
                                                                                                                                                                     : "output"));
            Codec::JSON::Value captured = Codec::JSON::Value::object();
            captured.set("text", Codec::JSON::Value::string(cellText(cell)));
            if (cell.pen.attributes.contains(VT::Attribute::Wide))
                captured.set("wide", Codec::JSON::Value::string("lead"));
            else if (cell.pen.attributes.contains(VT::Attribute::WideContinuation))
                captured.set("wide", Codec::JSON::Value::string("continuation"));
            captured.set("style", std::move(style));
            cells.push(std::move(captured));
        }
        rows.push(std::move(cells));
    }
    Codec::JSON::Value cursor = Codec::JSON::Value::object();
    cursor.set("row", Codec::JSON::Value::number(screen.cursorY));
    cursor.set("column", Codec::JSON::Value::number(screen.cursorX));
    cursor.set("pendingWrap", Codec::JSON::Value::boolean(screen.wrapPending));
    cursor.set("visible", Codec::JSON::Value::boolean(m_terminal.modes.isCursorVisible));
    Codec::JSON::Value state = Codec::JSON::Value::object();
    state.set("rows", std::move(rows));
    // The host-writable status line is outside the data-screen rows. Null
    // distinguishes its absence from an allocated but blank status row.
    Codec::JSON::Value statusRowText = Codec::JSON::Value::null();
    if (m_terminal.statusLineType == 2) {
        statusRowText = Codec::JSON::Value::array();
        for (int column = 0; column < m_terminal.columns; ++column)
            statusRowText.push(Codec::JSON::Value::string(cellText(Rendering::statusCellAt(m_terminal, column))));
    }
    state.set("statusRowText", std::move(statusRowText));
    Codec::JSON::Value promptRows = Codec::JSON::Value::array();
    const int history = Screen::scrollbackCount(&m_terminal);
    for (int row = 0; row < m_terminal.rows; ++row) {
        if (Screen::rowMark(&m_terminal, history + row) & Screen::osc133MarkPromptStart)
            promptRows.push(Codec::JSON::Value::number(row + 1));
    }
    state.set("promptRows", std::move(promptRows));
    state.set("cursor", std::move(cursor));
    state.set("title", Codec::JSON::Value::string(std::string(m_terminal.titleUTF8.view())));
    state.set("pwd", Codec::JSON::Value::string(std::string(m_terminal.currentDirectory.view())));
    Codec::JSON::Value palette = Codec::JSON::Value::array();
    for (const PaletteRGB& entry : m_terminal.palette.indexed)
        palette.push(capturedPaletteColor(entry));
    state.set("palette", std::move(palette));
    state.set("foreground", capturedPaletteColor(m_terminal.palette.defaultForeground));
    state.set("background", capturedPaletteColor(m_terminal.palette.defaultBackground));
    state.set("pointer", Codec::JSON::Value::string(OSC::isAppPointerShapeSet(m_terminal) ? OSC::pointerShapeWireName(OSC::appRequestedPointerShape(m_terminal)) : ""));
    m_capturedProgramState = Codec::JSON::serialize(state);
    return m_capturedProgramState.c_str();
}

void WebTerminal::advanceGraphicsClock(std::uint32_t elapsedMilliseconds)
{
    Image::advanceFrames(&m_terminal, elapsedMilliseconds);
}

std::uint32_t WebTerminal::cursorTicksUntilAlphaChange() const
{
    if (m_presentationTicks || !m_isFocused || !m_terminal.modes.isCursorVisible)
        return 0;
    return Cursor::ticksUntilAlphaChange(&m_terminal, PAL::monotonicTicks().count);
}

void WebTerminal::setPresentationTime(std::uint32_t milliseconds)
{
    m_presentationTicks = static_cast<std::uint32_t>(static_cast<std::uint64_t>(milliseconds) * Cursor::Blink::caretPeriodTicks / 1000);
}

const char* WebTerminal::captureGraphicsState(std::size_t pixelByteLimit)
{
    namespace JSON = Codec::JSON;
    std::size_t remainingBytes = std::min(pixelByteLimit, std::size_t { 1024 * 1024 });
    JSON::Value images = JSON::Value::array();
    for (const Image::TerminalImage& image : m_terminal.images.stored) {
        if (!image.used)
            continue;
        JSON::Value captured = JSON::Value::object();
        captured.set("id", JSON::Value::number(image.imageID));
        captured.set("width", JSON::Value::number(image.width));
        captured.set("height", JSON::Value::number(image.height));
        captured.set("frames", JSON::Value::number(image.frameCount));
        captured.set("frame", JSON::Value::number(image.currentFrame));
        const std::size_t pixelCount = static_cast<std::size_t>(image.width) * image.height;
        const std::size_t components = image.format == 24 ? 3 : 4;
        const Image::TerminalImageFrame* frame = image.currentFrame < image.frameCount ? &image.frames[image.currentFrame] : nullptr;
        const unsigned char* framePixels = frame ? frame->pixels : nullptr;
        JSON::Value pixels = JSON::Value::null();
        if (framePixels && (image.format == 24 || image.format == 32)
            && pixelCount <= remainingBytes / 4 && frame->pixelLength == pixelCount * components) {
            constexpr std::string_view digits = "0123456789abcdef";
            std::string rgba;
            rgba.reserve(pixelCount * 8);
            for (std::size_t pixel = 0; pixel < pixelCount; ++pixel) {
                for (std::size_t component = 0; component < 4; ++component) {
                    const unsigned char value = component < components ? framePixels[pixel * components + component] : 255;
                    rgba.push_back(digits[value >> 4]);
                    rgba.push_back(digits[value & 15]);
                }
            }
            pixels = JSON::Value::string(std::move(rgba));
            remainingBytes -= pixelCount * 4;
        }
        captured.set("rgba", std::move(pixels));
        images.push(std::move(captured));
    }
    JSON::Value placements = JSON::Value::array();
    for (const Image::TerminalImagePlacement& placement : m_terminal.images.placements) {
        if (!placement.used || !Image::placementIsOnActiveScreen(placement, m_terminal.screens.isUsingAlternateScreen))
            continue;
        JSON::Value captured = JSON::Value::object();
        captured.set("image", JSON::Value::number(placement.imageID));
        captured.set("id", JSON::Value::number(placement.placementID));
        captured.set("row", JSON::Value::number(placement.cursorY + 1));
        captured.set("col", JSON::Value::number(placement.cursorX + 1));
        captured.set("columns", JSON::Value::number(placement.cellColumns));
        captured.set("rows", JSON::Value::number(placement.cellRows));
        captured.set("x", JSON::Value::number(placement.pixelOffsetX));
        captured.set("y", JSON::Value::number(placement.pixelOffsetY));
        captured.set("sourceX", JSON::Value::number(placement.sourceX));
        captured.set("sourceY", JSON::Value::number(placement.sourceY));
        captured.set("sourceWidth", JSON::Value::number(placement.sourceWidth));
        captured.set("sourceHeight", JSON::Value::number(placement.sourceHeight));
        captured.set("z", JSON::Value::number(placement.zIndex));
        placements.push(std::move(captured));
    }
    JSON::Value state = JSON::Value::object();
    state.set("images", std::move(images));
    state.set("placements", std::move(placements));
    m_capturedGraphicsState = JSON::serialize(state);
    return m_capturedGraphicsState.c_str();
}

const char* WebTerminal::programMetadataJSON()
{
    namespace JSON = Codec::JSON;
    JSON::Value metadata = JSON::Value::object();
    metadata.set("foreground", capturedPaletteColor(m_terminal.palette.defaultForeground));
    metadata.set("background", capturedPaletteColor(m_terminal.palette.defaultBackground));
    const auto* hostFacts = m_sync.sawHelloAck() ? m_sync.paneFacts(this->sessionID()) : nullptr;
    metadata.set("programTitle", JSON::Value::string(hostFacts ? hostFacts->programTitle : std::string(m_terminal.titleUTF8.view())));
    metadata.set("currentDirectory", JSON::Value::string(m_currentDirectory));
    metadata.set("isReadingCommand", JSON::Value::boolean(m_terminal.isReadingCommand));
    JSON::Value host = JSON::Value::null();
    if (hostFacts) {
        host = JSON::Value::object();
        host.set("paneHandle", JSON::Value::number(m_sync.paneHandle(this->sessionID())));
        host.set("foregroundName", JSON::Value::string(hostFacts->foreground.name));
        host.set("foregroundProcessID", hostFacts->foreground.processID ? JSON::Value::number(hostFacts->foreground.processID) : JSON::Value::null());
        host.set("processChain", JSON::Value::string(hostFacts->processChain));
        host.set("processChainWithArguments", JSON::Value::string(hostFacts->processChainWithArguments));
        host.set("shellCommandName", JSON::Value::string(hostFacts->shellCommandName));
        host.set("terminalName", JSON::Value::string(hostFacts->terminalName));
        host.set("hostName", JSON::Value::string(hostFacts->hostName));
        host.set("isAtPrompt", JSON::Value::boolean(hostFacts->isAtPrompt));
        host.set("didEnd", JSON::Value::boolean(hostFacts->end.didEnd));
    }
    metadata.set("host", std::move(host));
    const auto exitStatus = hostFacts                                                  ? hostFacts->exitStatus
        : m_terminal.commandCompletedGeneration && m_terminal.lastCommandExitCode >= 0 ? std::optional { m_terminal.lastCommandExitCode }
                                                                                       : std::nullopt;
    metadata.set("exitStatus", exitStatus ? JSON::Value::number(*exitStatus) : JSON::Value::null());

    const auto stateName = [](OSC::ProgramState state) -> std::string {
        switch (state) {
        case OSC::ProgramState::Idle:
            return "idle";
        case OSC::ProgramState::Working:
            return "working";
        case OSC::ProgramState::Done:
            return "done";
        case OSC::ProgramState::Blocked:
            return "blocked";
        case OSC::ProgramState::Error:
            return "error";
        case OSC::ProgramState::None:
            return "none";
        }
        return "none";
    };
    const auto kindName = [](OSC::ProgramBlockKind kind) -> std::string {
        switch (kind) {
        case OSC::ProgramBlockKind::Permission:
            return "permission";
        case OSC::ProgramBlockKind::Question:
            return "question";
        case OSC::ProgramBlockKind::Auth:
            return "auth";
        case OSC::ProgramBlockKind::None:
            return "";
        }
        return "";
    };
    JSON::Value records = JSON::Value::array();
    JSON::Value primaryIndex = JSON::Value::null();
    const auto* screen = m_sync.screen();
    const auto remoteStatus = screen ? screen->paneStatus(m_sync.paneHandle(this->sessionID())) : std::nullopt;
    const auto& store = remoteStatus ? remoteStatus->store : m_terminal.programStatus;
    const auto* primary = store.primary();
    for (const auto& record : store.records) {
        if (&record == primary)
            primaryIndex = JSON::Value::number(static_cast<double>(records.items().size()));
        JSON::Value item = JSON::Value::object();
        item.set("id", JSON::Value::string(std::string(record.id.view())));
        item.set("app", JSON::Value::string(std::string(record.app.view())));
        item.set("effectiveApp", JSON::Value::string(std::string(store.effectiveApp(record))));
        item.set("title", JSON::Value::string(std::string(record.title.view())));
        item.set("message", JSON::Value::string(std::string(record.message.view())));
        item.set("state", JSON::Value::string(stateName(record.state)));
        item.set("kind", JSON::Value::string(kindName(record.kind)));
        item.set("progress", record.progress >= 0 ? JSON::Value::number(record.progress) : JSON::Value::null());
        records.push(std::move(item));
    }
    metadata.set("records", std::move(records));
    metadata.set("primaryRecord", std::move(primaryIndex));
    JSON::Value progress = JSON::Value::object();
    progress.set("state", JSON::Value::number(hostFacts ? hostFacts->progress.state : m_terminal.progressState));
    progress.set("value", JSON::Value::number(hostFacts ? hostFacts->progress.value : m_terminal.progressValue));
    metadata.set("progress", std::move(progress));
    m_programMetadataJSON = JSON::serialize(metadata);
    return m_programMetadataJSON.c_str();
}

const char* WebTerminal::takeProgressReports()
{
    Codec::JSON::Value reports = Codec::JSON::Value::array();
    for (const auto& report : m_progressReports) {
        Codec::JSON::Value entry = Codec::JSON::Value::array();
        entry.push(Codec::JSON::Value::number(report[0]));
        entry.push(Codec::JSON::Value::number(report[1]));
        reports.push(std::move(entry));
    }
    Codec::JSON::Value result = Codec::JSON::Value::object();
    result.set("reports", std::move(reports));
    result.set("overflow", Codec::JSON::Value::boolean(m_hasProgressReportOverflow));
    m_takenProgressReports = Codec::JSON::serialize(result);
    m_progressReports.clear();
    m_hasProgressReportOverflow = false;
    return m_takenProgressReports.c_str();
}

int WebTerminal::takeReplies(std::span<char> output)
{
    return Ubiquitty::drainOutput(&m_terminal, output);
}

void WebTerminal::setFontSize(double cssPixels)
{
    // The bounds are Core's, so a size out of range clamps here exactly as it
    // does on a frontend with a preferences pane rather than being refused.
    const double clamped = Preferences::Zoom::clampFontZoom(cssPixels);
    const int pixelSize = static_cast<int>(clamped * m_glyphScale + 0.5);
    if (pixelSize <= 0 || (m_fonts && pixelSize == m_fontPixelSize))
        return;
    m_fontSize = clamped;
    m_fontPixelSize = pixelSize;
    // Rebuilt rather than resized: both rasterizers and the renderer cache
    // metrics taken at construction, and the renderer's rasterizer reference is
    // fixed there. Replacing the three together is what keeps them agreeing.
    rebuildFontStack();
}

void WebTerminal::rebuildFontStack()
{
    if (m_fontPixelSize > 0) {
        m_fonts = std::make_unique<FontStack>(m_fontPixelSize, m_glyphScale, m_lineSpacing, m_characterSpacingInPixels, m_fontRoutePreferences.view(), m_fontVariations, m_fontWeights,
            WebFontRasterizer::runSubstitutionFor(m_ligatures, m_fontFeatures));
        (void)m_terminal.fontRequests.publishActualFont(m_fonts->face.familyName(), m_fontSize);
        ++m_fontResourceGeneration;
    }
    publishPixelGeometry();
    publishRichTextTypography();
    publishProportionalFaces();
}

void WebTerminal::publishRichTextTypography()
{
    if (!m_fonts)
        return;
    const double size = Rendering::proportionalFacePointSize(m_fontSize, m_configuration.proportionalFontSizePoints);
    m_fonts->face.setProportionalFont(m_configuration.proportionalFontFamily.string(), static_cast<int>(std::lround(size * m_glyphScale)));
    const auto facts = m_richText.configure(std::string(m_fonts->face.familyName()), m_configuration.proportionalFontFamily.string(),
        activeRasterizer().cellMetrics(), size, m_fontSize, m_glyphScale);
    if (!facts.faceCount)
        return;
    m_terminal.typography.shaper = m_richText.shaper();
    m_terminal.typography.fontCatalog = m_richText.fontCatalog();
    (void)RichText::adoptTypography(m_terminal, facts);
    m_sync.publishTypography(this->sessionID(), facts);
}

void WebTerminal::publishProportionalFaces()
{
    if (!m_fonts || !m_terminal.drawsProportionalText)
        return;
    const auto* screen = m_sync.screen();
    if (!m_sync.isScreenAttached() || !screen || !screen->welcome()) {
        m_areProportionalFacesOwed = true;
        return;
    }
    const auto role = screen->welcome()->grantedRole;
    if (role != Protocol::Sync::Role::Owner && role != Protocol::Sync::Role::Driver) {
        m_areProportionalFacesOwed = true;
        return;
    }
    auto faces = std::unique_ptr<OSC::TextSizing::ProportionalFaceFacts>(new (std::nothrow) OSC::TextSizing::ProportionalFaceFacts());
    if (faces && OSC::TextSizing::measureProportionalFaces(m_measurer, *faces)) {
        m_sync.publishProportionalFaces(*faces);
        m_areProportionalFacesOwed = false;
    }
}

int WebTerminal::backgroundColor() const
{
    // `TermPalette` carries 16 bits per channel — OSC 4 states colours at that
    // width — and CSS takes eight, so the narrowing goes through Core's own
    // converter. A plain `>> 8` agrees with it on every value that arrived
    // through `channel8To16`, which is every seeded and theme-applied colour,
    // and disagrees on a quarter of the 16-bit space: exactly the values an
    // OSC 4 `rgb:` spec at full width produces. A conversion that is right for
    // all the colours anyone tests with is the kind that ships.
    // The frame's default ground, which under DECSCNM is the configured
    // foreground: the page's margin and the composite's padding both take
    // this, so a reversed screen sits in a reversed border as it does on
    // every other arm.
    const PaletteRGB& color = isReverseVideo(&m_terminal) ? m_terminal.palette.defaultForeground : m_terminal.palette.defaultBackground;
    return (static_cast<int>(channel16To8(color.red)) << 16)
        | (static_cast<int>(channel16To8(color.green)) << 8)
        | static_cast<int>(channel16To8(color.blue));
}

void WebTerminal::setPadding(double cssPixels)
{
    // Core's own bounds for `[appearance] padding`, so the browser accepts
    // exactly what a config file accepts. A frontend carrying its own numbers
    // is a second schema, and the one that drifts is whichever is edited less.
    const auto clamped = static_cast<float>(Preferences::Schema::clampToRange(cssPixels, "appearance", "padding"));
    m_paddingInsets = { clamped, clamped, clamped, clamped };
    publishPixelGeometry();
}

void WebTerminal::setPaddingInsets(Rendering::EdgeInsets insets)
{
    const auto clamp = [](float edge) {
        return static_cast<float>(Preferences::Schema::clampToRange(static_cast<double>(edge), "appearance", "padding"));
    };
    m_paddingInsets = { clamp(insets.left), clamp(insets.right), clamp(insets.top), clamp(insets.bottom) };
    publishPixelGeometry();
}

const char* WebTerminal::fontFeatureSettingsCSS() const
{
    return m_fontFeatureSettingsCSS.c_str();
}

void WebTerminal::setFontFeatures(const std::string& specification)
{
    if (specification == m_fontFeatures)
        return;
    m_fontFeatures = specification;
    recomposeFontFeatureSettingsCSS();
}

void WebTerminal::setLigatures(Rendering::Ligatures ligatures)
{
    if (ligatures == m_ligatures)
        return;
    m_ligatures = ligatures;
    recomposeFontFeatureSettingsCSS();
}

void WebTerminal::recomposeFontFeatureSettingsCSS()
{

    m_fontFeatureSettingsCSS.clear();
    // Core resolves the ligature policy and the specification into one ordered
    // list; this maps it to the descriptor's syntax. The browser is the shaper
    // on this arm and applies `liga`, `clig` and `calt` by default, exactly as
    // HarfBuzz does on the Linux one — so `[font] ligatures = false` is inert
    // unless a suppression is REQUESTED, and a descriptor is the only place
    // here to request one.
    for (const Rendering::FontFeatureSetting& setting : Rendering::resolveFontFeatures(m_ligatures, m_fontFeatures)) {
        if (!m_fontFeatureSettingsCSS.empty())
            m_fontFeatureSettingsCSS += ", ";
        // The quoted-tag form `"liga" 1`, which is what the descriptor takes.
        // A value of zero is spelled rather than omitted: the descriptor's
        // default for an unnamed feature is the face's own, so leaving a
        // disabled tag out would enable it.
        m_fontFeatureSettingsCSS += '"';
        m_fontFeatureSettingsCSS += setting.tag;
        m_fontFeatureSettingsCSS += "\" " + std::to_string(setting.value);
    }
}

const char* WebTerminal::fontVariationSettingsCSS() const
{
    return m_fontVariationSettingsCSS.c_str();
}

void WebTerminal::setFontVariations(const std::string& specification)
{
    if (specification == m_fontVariations)
        return;
    m_fontVariations = specification;

    // The CSS half of the same list, for the face the page registers. Composed
    // here, from Core's parse, so the page never learns the grammar: it receives
    // a value it can only paste into a descriptor.
    //
    // `wght` is left out, and that is the whole reason there are two halves. A
    // `font-variation-settings` descriptor outranks `font-weight` for the axis
    // it names, so a weight baked into the registered face would pin every cell
    // to it — the SGR tier and the bold face would both stop moving. Weight
    // travels the other route, per glyph, where the tiers can be applied.
    m_fontVariationSettingsCSS.clear();
    for (const Rendering::FontVariationSetting& axis : Rendering::parseFontVariationSpecification(specification)) {
        if (axis.tag == "wght")
            continue;
        if (!m_fontVariationSettingsCSS.empty())
            m_fontVariationSettingsCSS += ", ";
        // `%g` rather than a fixed precision: an axis value is a design-space
        // number and a trailing zero on it is noise a reader has to skip.
        m_fontVariationSettingsCSS += std::format("\"{}\" {:g}", axis.tag, axis.value);
    }
    // Rebuilt for the reason a spacing change rebuilds it: the axes are read
    // once when the rasterizer is constructed, and the renderer holds metrics
    // taken at that moment.
    rebuildFontStack();
}

void WebTerminal::setLineSpacing(double cssPixels)
{
    const double clamped = Preferences::Schema::clampToRange(cssPixels, "font", "line_spacing");
    if (clamped == m_lineSpacing)
        return;
    m_lineSpacing = clamped;
    // The spacing is baked into the cell the rasterizers report, so the stack is
    // rebuilt for the same reason a size change rebuilds it: the renderer holds
    // metrics taken at construction.
    rebuildFontStack();
}

const std::vector<std::uint8_t>& WebTerminal::renderPage()
{
    // CSS pixels times the scale, which is the conversion the grid division
    // makes for the same value — an inset applied in the wrong unit looks right
    // at scale 1 and half-size on a retina display. The frame draws the margin,
    // the prompt marks in it and every overlay that reaches into it.
    const auto scale = static_cast<float>(m_glyphScale);
    m_pageImage = renderFrame(Rendering::EdgeInsets { m_paddingInsets.left * scale, m_paddingInsets.right * scale,
                                  m_paddingInsets.top * scale, m_paddingInsets.bottom * scale },
        m_pageWidth, m_pageHeight);
    return m_pageImage;
}

Ubiquitty::GridSize WebTerminal::gridForViewport(double viewportWidth, double viewportHeight, double scale) const
{
    // The padding is stated in CSS pixels and the viewport arrives in device
    // pixels, which is the mismatch that makes an inset look right at scale 1
    // and half-size on a retina display.
    const auto deviceScale = static_cast<float>(scale);
    const Rendering::EdgeInsets insets { m_paddingInsets.left * deviceScale, m_paddingInsets.right * deviceScale,
        m_paddingInsets.top * deviceScale, m_paddingInsets.bottom * deviceScale };
    Ubiquitty::GridSize dimensions = Rendering::gridFromViewport({ static_cast<float>(viewportWidth), static_cast<float>(viewportHeight) }, insets, insets.top + insets.bottom, { static_cast<float>(cellWidth()), static_cast<float>(cellHeight()) });
    if (dimensions.columns < minColumns)
        dimensions.columns = minColumns;
    if (dimensions.rows < minRows)
        dimensions.rows = minRows;
    return dimensions;
}

void WebTerminal::stepFontSize(int steps)
{
    if (steps == 0)
        return;
    setFontSize(m_fontSize + Preferences::Zoom::fontZoomStep * steps);
}

void WebTerminal::resetFontSize()
{
    setFontSize(m_initialFontSize);
}

void WebTerminal::scrollToTop()
{
    m_viewOffset = Ubiquitty::Screen::scrollbackCount(&m_terminal);
    (void)pullHistory();
}

void WebTerminal::scrollToBottom()
{
    m_viewOffset = 0;
}

const char* WebTerminal::linkAtCell(int row, int column, LinkModifier modifier)
{
    m_linkURI[0] = '\0';
    // A wrapped link can reach every visible row, so the scratch is sized for
    // the whole grid. Grown on demand rather than at construction because a
    // resize changes what the whole grid is.
    const std::size_t cells = static_cast<std::size_t>(m_terminal.rows) * static_cast<std::size_t>(m_terminal.columns);
    if (cells == 0)
        return m_linkURI.data();
    if (m_linkScanCodePoints.size() < cells) {
        m_linkScanCodePoints.resize(cells);
        m_linkScanIDs.resize(cells);
    }
    const Screen::LinkScanBuffer scratch { m_linkScanCodePoints.data(), m_linkScanIDs.data(), static_cast<int>(cells) };
    Screen::VisibleLink link {};
    if (!Screen::linkAtVisibleCell(&m_terminal, m_viewOffset, row, column, scratch, m_linkURI, &link)) {
        m_linkURI[0] = '\0';
        return m_linkURI.data();
    }
    // A path resolves against a working directory the browser does not have.
    if (link.isFilePath) {
        m_linkURI[0] = '\0';
        return m_linkURI.data();
    }
    // The program writes the escape, so the URI is attacker-controlled: in a
    // browser `javascript:` runs in the page's own origin. Gated here rather
    // than at the click, so a scheme that cannot be opened never shows the
    // affordance saying it can.
    //
    // `file:` is on the shared allowlist for a frontend with an OS handler to
    // hand it to. A page has none — the browser refuses the navigation, and a
    // link that named a local path would have disclosed one for nothing.
    static constexpr std::string_view fileScheme = "file:";
    const std::string_view uri { m_linkURI.data() };
    if (!Attributes::LinkRun::isLaunchableURLScheme(uri) || uri.starts_with(fileScheme))
        m_linkURI[0] = '\0';
    // A connection to a host the program named waits for the reader to ask
    // for it with the modifier, as it does on every other frontend.
    else if (modifier == LinkModifier::Up && Attributes::LinkRun::requiresLinkModifier(uri))
        m_linkURI[0] = '\0';
    return m_linkURI.data();
}

int WebTerminal::pointerShape(bool isOverLink, bool isRectangularSelectArmed, bool selectionBypassesMouseReporting, bool isOverTextVoid)
{
    Input::PointerContext context;
    // Supplied rather than resolved here: the caller has just asked linkAtCell
    // to decide what to open, and resolving it again would walk the wrap group
    // a second time on every pointer move.
    context.isOverLink = isOverLink;
    context.isRectangularSelectArmed = isRectangularSelectArmed;
    context.selectionBypassesMouseReporting = selectionBypassesMouseReporting;
    context.isOverTextVoid = isOverTextVoid;
    // A page cannot lock the pointer from here and has no chromeless window to
    // drag, so those two ranks stay false rather than becoming arguments no
    // caller could set.
    return static_cast<int>(Input::pointerShape(&m_terminal, context));
}

// Whichever rasterizer the renderer was constructed over: the decoration
// metrics must come from the face the glyphs were drawn with, not from the
// fallback that may never be reached.
int WebTerminal::ProportionalMeasurer::shapeProportionalRun(std::span<const std::uint32_t> codePoints, ProportionalRunStyle style, std::span<ProportionalShapedGlyph> glyphsOut)
{
    return owner->activeRasterizer().shapeProportionalRun(codePoints, static_cast<Rendering::FontFace>(style.faceBits), glyphsOut);
}

float WebTerminal::ProportionalMeasurer::proportionalCellAdvanceInPixels() { return static_cast<float>(owner->cellWidth()); }

Rendering::GlyphRasterizer& WebTerminal::activeRasterizer()
{
    if (m_fonts->face.isAvailable())
        return m_fonts->face;
    return m_fonts->unifont;
}

bool WebTerminal::isFrameWithheld()
{
    return Modes::SyncOutput::shouldWithholdFrame(m_terminal, PAL::monotonicTicks());
}

void WebTerminal::applySearchMatchSpans(Rendering::TerminalSnapshotOptions& options)
{
    // The terminal's search state, gathered the way every other arm gathers
    // it: the focused match as the pill, the others as their dim tier. Both
    // renderers take it, or a match would draw on one backend and not the other.
    Rendering::collectSearchMatchRowSpans(m_terminal, m_viewOffset, m_searchMatchSpans);
    Rendering::collectOtherSearchMatchRowSpans(m_terminal, m_viewOffset, m_otherSearchMatchSpans);
    if (!m_searchMatchSpans.empty()) {
        options.searchMatchSpans = m_searchMatchSpans.data();
        options.searchMatchSpanCount = static_cast<int>(m_searchMatchSpans.size());
        const Rendering::OverlayColor highlight = Rendering::focusedSearchMatchColor();
        options.searchMatchHighlight = { highlight.red, highlight.green, highlight.blue, highlight.alpha };
    }
    if (!m_otherSearchMatchSpans.empty()) {
        options.otherSearchMatchSpans = m_otherSearchMatchSpans.data();
        options.otherSearchMatchSpanCount = static_cast<int>(m_otherSearchMatchSpans.size());
    }
}

bool WebTerminal::buildFrame()
{
    if (m_richText.needsConfiguration())
        publishRichTextTypography();
    // The counts below stay valid while a frame is withheld: a caller
    // re-presents the last complete frame, and has nothing to show if this
    // zeroes them first.
    if (Modes::SyncOutput::shouldWithholdFrame(m_terminal, PAL::monotonicTicks()))
        return false;

    m_cellCount = 0;
    m_glyphCount = 0;
    m_overlayCount = 0;
    m_boxFillCount = 0;
    m_decorationCount = 0;
    m_cursorTier = {};
    m_proportionalGlyphCount = 0;
    m_proportionalStripCount = 0;
    m_ligatureGlyphCount = 0;
    m_hasImages = false;

    Rendering::TerminalSnapshotOptions options;
    options.style.unifontScale = m_fonts->face.isAvailable() ? 0 : m_glyphScale;
    applyConfiguredFrameStyle(options);
    Rendering::applyPointSpace(options, static_cast<float>(cellHeight()), m_glyphScale, m_lineSpacing);
    options.viewOffset = m_viewOffset;
    options.isFocused = m_isFocused;
    // No view layer here: the badge that says the terminal is taking a
    // password has to be part of the frame or it does not exist.
    options.shouldDrawPasswordLock = true;
    buildSelectionSpans();
    options.selectionSpans = m_selectionSpans.empty() ? nullptr : m_selectionSpans.data();
    options.selectionSpanCount = static_cast<int>(m_selectionSpans.size());
    options.richTextSelections = m_richTextSelections;
    options.richTextSelectionCount = static_cast<int>(m_richTextSelections.size());
    buildHiliteSpans();
    options.hiliteRegionSpans = m_hiliteSpans.empty() ? nullptr : m_hiliteSpans.data();
    options.hiliteRegionSpanCount = static_cast<int>(m_hiliteSpans.size());
    // The trigger tints, from the ring the rules fill as lines complete: the
    // gather the native arms make each frame, so a rule that fired draws here
    // as it draws there.
    Rendering::collectTriggerHighlightRowSpans(m_terminal, m_viewOffset, m_triggerHighlightSpans);
    options.triggerHighlightSpans = m_triggerHighlightSpans.empty() ? nullptr : m_triggerHighlightSpans.data();
    options.triggerHighlightSpanCount = static_cast<int>(m_triggerHighlightSpans.size());
    applySearchMatchSpans(options);
    layoutBeamForFrame();
    layoutHintForFrame();
    // The margins stay ZERO: they are what switches the subpixel glyph pass on,
    // and this frontend has no such pass — setting them would route every
    // ordinary glyph off its cell into a stream nothing draws.
    Rendering::GlyphSlotGeometry slot {};
    slot.columns = 16;
    slot.slotWidthInPixels = cellWidth();
    slot.slotHeightInPixels = cellHeight();
    // The ink advance, not the pitch: tracking moves the column and leaves
    // the glyph the size the face drew it.
    slot.glyphWidthInPixels = std::max(1, cellWidth() - m_characterSpacingInPixels);
    slot.wideSlotWidthInPixels = cellWidth() * 2;
    slot.wideSlotHeightInPixels = cellHeight();
    slot.boxStrokeProfile = m_fonts->boxStrokeProfile;
    const Rendering::ChromePlacement layers[] = { hintPlacement(), beamPlacement() };
    // The DECSSDT status row. The image path above reaches Core's whole-terminal
    // entry, which derives the row itself; this one hands the capture a terminal
    // and its own options, so the row has to be asked for here or the page draws
    // the last row as whatever the grid holds there. The scratch outlives the
    // capture, which only borrows it.
    Rendering::StatusRowStorage statusRowScratch;
    if (Rendering::fillStatusRow(&m_terminal, m_terminal.rows, m_terminal.columns, options.viewOffset,
            Rendering::StatusRowCells { statusRowScratch.cells.data(), statusRowScratch.cells.size() })) {
        options.statusRowCells = statusRowScratch.cells.data();
        options.statusRowColumns = m_terminal.columns;
    }
    if (!m_frameInputs.capture(m_terminal, options, activeRasterizer().cellMetrics(), slot, layers))
        return false;
    // The capture clamps the request to the scrollback that exists, so the
    // frontend's offset follows it rather than drifting past the end.
    m_viewOffset = m_frameInputs.viewOffset();

    // Start with one instance per cell, one more for the cursor tier, and a
    // quad per row. Box decompositions and packed runs can need more; their
    // reported counts below drive an exact growth and rebuild. The extra cell is the
    // focused block's re-emitted claim at the tail of every stream
    // (InstanceCounts::cursorTier); every ceiling below is a multiple of this
    // one, so the tier's ink and rules ride along. Sized to the grid alone, the
    // tail is the one instance that does not fit, and the clamp below drops it
    // — a focused block silently not drawn on exactly the grids that fill
    // their buffer.
    // One more a row as well: a row laid out as letters (LetterLayout.h)
    // paints the pane past its last cell with a quad of its own.
    const std::size_t maxCells = static_cast<std::size_t>(m_terminal.rows) * m_terminal.columns + 1 + static_cast<std::size_t>(m_terminal.rows);
    if (m_cells.size() < maxCells)
        m_cells.resize(maxCells);
    const std::size_t maxOverlays = Rendering::maxOverlaysForRows(m_terminal.rows, 0, m_triggerHighlightSpans.size(), m_hiliteSpans.size());
    if (m_overlays.size() < maxOverlays)
        m_overlays.resize(maxOverlays);
    if (m_boxFills.size() < maxCells)
        m_boxFills.resize(maxCells);
    // A cell carries an underline, a strikethrough and an overline at once, so
    // the decoration ceiling is a multiple of the grid rather than equal to it.
    const std::size_t maxDecorations = maxCells * 4;
    if (m_decorations.size() < maxDecorations)
        m_decorations.resize(maxDecorations);

    // A two-cell glyph per two columns is the ceiling, but a row of them is rare
    // and the buffer is cheap, so this sizes to the grid rather than to half of
    // it — a wide glyph dropped for want of room is a blank cell in the middle
    // of a word, which reads as a font failure.
    if (m_glyphs.size() < maxCells)
        m_glyphs.resize(maxCells);
    if (m_wideGlyphs.size() < maxCells)
        m_wideGlyphs.resize(maxCells);

    m_fonts->renderer.beginFrame();
    Rendering::InstanceBuffers out;
    out.cells = m_cells.data();
    out.cellCapacity = m_cells.size();
    out.overlays = m_overlays.data();
    out.overlayCapacity = m_overlays.size();
    out.boxFills = m_boxFills.data();
    out.boxFillCapacity = m_boxFills.size();
    out.decorations = m_decorations.data();
    out.decorationCapacity = m_decorations.size();
    out.glyphs = m_glyphs.data();
    out.glyphCapacity = m_glyphs.size();
    out.wideGlyphs = m_wideGlyphs.data();
    out.wideGlyphCapacity = m_wideGlyphs.size();
    if (m_fonts->renderer.proportionalAtlas().pixels) {
        if (m_proportionalGlyphs.size() < maxCells) {
            m_proportionalGlyphs.resize(maxCells);
        }
        out.proportionalGlyphs = m_proportionalGlyphs.data();
        out.proportionalGlyphCapacity = m_proportionalGlyphs.size();
    }
    if (m_fonts->renderer.proportionalStripAtlas().pixels) {
        if (m_proportionalStrips.size() < maxCells)
            m_proportionalStrips.resize(maxCells);
        out.proportionalStrips = m_proportionalStrips.data();
        out.proportionalStripCapacity = m_proportionalStrips.size();
    }
    if (m_fonts->renderer.ligatureAtlas().pixels) {
        if (m_ligatureGlyphs.size() < maxCells) {
            m_ligatureGlyphs.resize(maxCells);
        }
        out.ligatureGlyphs = m_ligatureGlyphs.data();
        out.ligatureGlyphCapacity = m_ligatureGlyphs.size();
    }
    // Offered only with a colour source. The builder reads this pointer as the
    // question "does this caller keep emoji on a sheet of their own", so handing
    // it a buffer the backend cannot fill routes every emoji into a stream that
    // stays empty — a blank cell where the mono path would at least have drawn
    // the glyph in the foreground colour.
    if (m_fonts->renderer.colorAtlas().pixels) {
        if (m_colorGlyphs.size() < maxCells)
            m_colorGlyphs.resize(maxCells);
        out.colorGlyphs = m_colorGlyphs.data();
        out.colorGlyphCapacity = m_colorGlyphs.size();
    }

    // The capture carries the selection and its tint, so both this path and the
    // CPU composite draw from one description of it.
    const Rendering::BuildInputs& inputs = m_frameInputs.inputs();

    // Before the backend is bound: a sheet that grows here is the one the
    // build faults into.
    m_fonts->renderer.reserveSheetsForScreen(inputs.rows * inputs.columns);
    const Rendering::GlyphBackend backend = m_fonts->renderer.glyphBackend();
    // The pointer resolves its column against the letters this frame lays
    // out, which the renderer keeps (pointerCell).
    m_fonts->renderer.lendLetters(inputs, out);
    Rendering::InstanceCounts counts = Rendering::buildCellInstances(inputs, backend, out);
    // A packed run or box decomposition can emit more quads than grid cells.
    if (counts.proportionalGlyphs > m_proportionalGlyphs.size()
        || counts.proportionalStrips > m_proportionalStrips.size()
        || counts.ligatureGlyphs > m_ligatureGlyphs.size()
        || counts.boxFills > m_boxFills.size()) {
        m_proportionalGlyphs.resize(std::max(counts.proportionalGlyphs, m_proportionalGlyphs.size()));
        m_proportionalStrips.resize(std::max(counts.proportionalStrips, m_proportionalStrips.size()));
        m_ligatureGlyphs.resize(std::max(counts.ligatureGlyphs, m_ligatureGlyphs.size()));
        out.proportionalGlyphs = m_proportionalGlyphs.data();
        out.proportionalGlyphCapacity = m_proportionalGlyphs.size();
        out.proportionalStrips = m_proportionalStrips.data();
        out.proportionalStripCapacity = m_proportionalStrips.size();
        out.ligatureGlyphs = m_ligatureGlyphs.data();
        out.ligatureGlyphCapacity = m_ligatureGlyphs.size();
        m_boxFills.resize(std::max(counts.boxFills, m_boxFills.size()));
        out.boxFills = m_boxFills.data();
        out.boxFillCapacity = m_boxFills.size();
        counts = Rendering::buildCellInstances(inputs, backend, out);
    }
    // A count past capacity means the builder had more to write than room;
    // report what the buffer holds, not a length a reader would run past.
    m_cellCount = static_cast<int>(counts.cells < m_cells.size() ? counts.cells : m_cells.size());
    m_overlayCount = static_cast<int>(counts.overlays < m_overlays.size() ? counts.overlays : m_overlays.size());
    m_boxFillCount = static_cast<int>(std::min(counts.boxFills, m_boxFills.size()));
    m_decorationCount = static_cast<int>(counts.decorations < m_decorations.size() ? counts.decorations : m_decorations.size());
    m_glyphCount = static_cast<int>(std::min(counts.glyphs, m_glyphs.size()));
    m_wideGlyphCount = static_cast<int>(counts.wideGlyphs < m_wideGlyphs.size() ? counts.wideGlyphs : m_wideGlyphs.size());
    m_proportionalGlyphCount = static_cast<int>(std::min(counts.proportionalGlyphs, m_proportionalGlyphs.size()));
    m_proportionalStripCount = static_cast<int>(std::min(counts.proportionalStrips, m_proportionalStrips.size()));
    m_ligatureGlyphCount = static_cast<int>(std::min(counts.ligatureGlyphs, m_ligatureGlyphs.size()));
    m_colorGlyphCount = static_cast<int>(counts.colorGlyphs < m_colorGlyphs.size() ? counts.colorGlyphs : m_colorGlyphs.size());
    // A tail longer than the stream that fits is the whole of it.
    const auto tailOf = [](std::size_t tail, int drawn) { return std::min(tail, static_cast<std::size_t>(drawn)); };
    m_cursorTier = counts.cursorTier;
    m_cursorTier.cells = tailOf(counts.cursorTier.cells, m_cellCount);
    m_cursorTier.glyphs = tailOf(counts.cursorTier.glyphs, m_glyphCount);
    m_cursorTier.wideGlyphs = tailOf(counts.cursorTier.wideGlyphs, m_wideGlyphCount);
    m_cursorTier.proportionalGlyphs = tailOf(counts.cursorTier.proportionalGlyphs, m_proportionalGlyphCount);
    m_cursorTier.proportionalStrips = tailOf(counts.cursorTier.proportionalStrips, m_proportionalStripCount);
    m_cursorTier.ligatureGlyphs = tailOf(counts.cursorTier.ligatureGlyphs, m_ligatureGlyphCount);
    m_cursorTier.colorGlyphs = tailOf(counts.cursorTier.colorGlyphs, m_colorGlyphCount);
    m_cursorTier.decorations = tailOf(counts.cursorTier.decorations, m_decorationCount);
    m_cursorTier.boxFills = tailOf(counts.cursorTier.boxFills, m_boxFillCount);

    // A placement with a live image behind it has no GPU pass, so the frame is
    // marked for the CPU compositor.
    const Rendering::BuildInputs& in = m_frameInputs.inputs();
    for (int i = 0; i < in.placementCount && !m_hasImages; ++i) {
        if (in.placements[i].imageID != 0)
            m_hasImages = true;
    }
    return true;
}

const char* WebTerminal::pendingClipboardWrite() const
{
    return m_clipboard->m_pendingWrite.c_str();
}

bool WebTerminal::hasPendingClipboardWrite() const
{
    return m_clipboard->m_hasPendingWrite;
}

void WebTerminal::takeClipboardWrite()
{
    m_clipboard->m_pendingWrite.clear();
    m_clipboard->m_hasPendingWrite = false;
}

int WebTerminal::pendingClipboardItemCount() const
{
    return static_cast<int>(m_clipboard->m_pendingItems.size());
}

const char* WebTerminal::pendingClipboardItemMime(int index) const
{
    if (index < 0 || index >= pendingClipboardItemCount())
        return "";
    return m_clipboard->m_pendingItems[static_cast<std::size_t>(index)].mime.c_str();
}

const char* WebTerminal::pendingClipboardItemBytes(int index) const
{
    if (index < 0 || index >= pendingClipboardItemCount())
        return "";
    return m_clipboard->m_pendingItems[static_cast<std::size_t>(index)].bytes.data();
}

int WebTerminal::pendingClipboardItemLength(int index) const
{
    if (index < 0 || index >= pendingClipboardItemCount())
        return 0;
    return static_cast<int>(m_clipboard->m_pendingItems[static_cast<std::size_t>(index)].bytes.size());
}

void WebTerminal::takeClipboardItems()
{
    m_clipboard->m_pendingItems.clear();
}

void WebTerminal::beginClipboardReadItems()
{
    m_readItemMimes.clear();
    m_readItemBytes.clear();
}

void WebTerminal::addClipboardReadItem(std::string_view mime, std::span<const char> bytes)
{
    m_readItemMimes.emplace_back(mime);
    m_readItemBytes.emplace_back(bytes.data(), bytes.size());
}

bool WebTerminal::wantsClipboardRead() const
{
    return m_clipboard->m_readPending;
}

bool WebTerminal::clipboardReadNeedsConfirmation() const
{
    return m_clipboard->m_readPending && m_clipboard->m_needsConfirmation;
}

void WebTerminal::provideClipboardRead(const char* text)
{
    if (!m_clipboard->m_readPending)
        return;
    const std::string_view answer = text ? std::string_view(text) : std::string_view {};
    m_clipboard->provideClipboardReadBytes(ClipboardBuffer::Clipboard, { answer.data(), answer.size() });
    // The typed capture the page accumulated rides beside the text; a page
    // that added none stages the empty set, which is the clear that keeps a
    // stale capture from answering a later read.
    std::vector<ClipboardItem> items;
    items.reserve(m_readItemMimes.size());
    for (std::size_t i = 0; i < m_readItemMimes.size(); ++i)
        items.push_back({ m_readItemMimes[i], { m_readItemBytes[i].data(), m_readItemBytes[i].size() } });
    m_clipboard->provideClipboardReadItems(ClipboardBuffer::Clipboard, items);
    m_readItemMimes.clear();
    m_readItemBytes.clear();
    m_clipboard->m_readPending = false;
    m_clipboard->m_needsConfirmation = false;
    // Approved even when empty: a program that asked and is told nothing gets an
    // empty reply, where silence would leave it waiting for a response that the
    // page has already decided not to give.
    OSC::completeClipboardReadQuery(m_terminal, m_clipboard->m_readSet, Ubiquitty::OSC::ClipboardReadDecision::Approved);
}

// --- Beam -------------------------------------------------------------------

namespace {

// The id the theme drill is registered and matched under. Named once because it
// is written in three places and a typo in any of them yields a command that
// lists nothing and applies nothing, with no diagnostic.
constexpr const char* themeCommandID = "beam.theme";
constexpr const char* fontCommandID = "beam.font";
constexpr const char* paddingCommandID = "beam.padding";
constexpr const char* lineSpacingCommandID = "beam.lineSpacing";
constexpr const char* fontSizeCommandID = "beam.fontSize";

// What a Blocks row's id begins with, before the block's absolute prompt row.
//
// The row carries the jump target rather than the palette recovering it from a
// position: ranking reorders the rows against every keystroke, so a position is
// a different block a moment later, and the id is the one thing that travels
// with the row the user is looking at.
//
// Outside the `beam.<name>` shape the rest of this file registers, because these
// ids are not page actions: the id names a row of this buffer, and a page that
// received one could only hand it back. `Scripts/build-web.sh` reads that shape
// to find a command with no handler, and a per-block id has no handler to find.
constexpr std::string_view blockCommandPrefix = "block.";

// The browser's Blocks scope: the terminal's OSC 133 command history as rows.
//
// The walk is Core's whole — the order, the bound, how a multi-row command
// becomes one label, the whitespace, the empty-prompt rule and the
// alternate-screen rule. What is decided here is the glyph a failed command
// wears, which is why Core reports the failure as a bool and names no
// presentation for it.
//
// - Parameter terminal: The buffer to enumerate.
// - Returns: One command per block, newest first.
CommandPalette::PaletteCommandList blockCommands(const Ubiquitty::Terminal& terminal)
{
    const Screen::CommandBlockList blocks = Screen::commandBlocks(&terminal, Screen::maxCommandBlocks);
    CommandPalette::PaletteCommandList commands;
    commands.reserve(blocks.size());
    for (const Screen::CommandBlock& block : blocks) {
        CommandPalette::PaletteCommand command;
        command.id = std::string(blockCommandPrefix) + std::to_string(block.promptRow);
        command.title = block.command;
        // Read back as the row's dim trailing text: `BeamRow::detail` takes the
        // group when a command declares no shortcut, and a block has none.
        command.group = block.didFail ? "✗" : "";
        commands.push_back(std::move(command));
    }
    return commands;
}

// The absolute prompt row a Blocks command id names, or -1 when the id is not
// one.
//
// -1 rather than 0: row 0 is the oldest retained row and a legitimate jump
// target, so an unparsed id answering 0 would scroll the view to the top of the
// history and look like a working feature aimed at the wrong block.
//
// - Parameter commandID: The id a palette row was accepted under.
// - Returns: The row, or -1 for any id this frontend did not build here.
int blockRowFor(std::string_view commandID)
{
    if (!commandID.starts_with(blockCommandPrefix))
        return -1;
    const std::string_view digits = commandID.substr(blockCommandPrefix.size());
    int row = -1;
    const auto* end = digits.data() + digits.size();
    const std::from_chars_result parsed = std::from_chars(digits.data(), end, row);
    if (parsed.ec != std::errc {} || parsed.ptr != end)
        return -1;
    return row;
}

// The browser's own commands. Actions the page can perform without a host, so
// the palette is useful in the standalone demo as well as attached — and so a
// frontend with no catalogue of its own still shows something real rather than
// an empty box.
CommandPalette::PaletteCommandList browserCommands(bool hasFontOptions)
{
    CommandPalette::PaletteCommandList commands;
    // `keywords` are extra fuzzy-match terms, never displayed. Without them a
    // command is findable only by the words someone happened to title it with:
    // "Choose Theme" did not answer "select theme" or "color", because fuzzy
    // matching is a subsequence test and "select" shares no run with "Choose".
    const auto add = [&](const char* id, const char* title, const char* group, const char* shortcut,
                         std::vector<std::string> keywords = {}) {
        CommandPalette::PaletteCommand command;
        command.id = id;
        command.title = title;
        command.group = group;
        command.shortcut = shortcut;
        command.keywords = std::move(keywords);
        commands.push_back(std::move(command));
    };
    // The actions come from Core's named-action catalog rather than a list
    // written out here. That catalog is already what [keys] parses and what the
    // settings UIs show, so a command listed here is one this page can genuinely
    // run, and adding an action to Core reaches every frontend's palette without
    // a second edit. A private list drifts the moment one of the two is touched:
    // this page offered no scroll-line or scroll-page entry while binding both
    // to keys, and nothing could notice.
    //
    // Four are dropped rather than listed, each because the page cannot perform
    // it — a palette entry that does nothing is worse than an absent one:
    //   new_tab / close_tab / next_tab / prev_tab  — one page, one terminal.
    //   new_window                                 — same.
    //   toggle_beam                                — you are looking at it.
    //   toggle_fullscreen                          — the browser gives it to the
    //       user through the browser's own chrome, and a page cannot enter it
    //       without a user gesture the palette has already consumed.
    const auto pageCannotRun = [](std::string_view token) {
        return token == "new_tab" || token == "close_tab" || token == "next_tab" || token == "prev_tab"
            || token == "new_window" || token == "toggle_beam" || token == "toggle_fullscreen";
    };
    // The group and the extra fuzzy terms are this page's presentation choice;
    // the token and the label are Core's.
    struct ActionPresentation {
        std::string_view token;
        const char* group;
        const char* shortcut;
        std::vector<std::string> keywords;
    };
    const ActionPresentation presentation[] = {
        { "copy", "Edit", "Cmd+C", { "clipboard", "yank" } },
        { "paste", "Edit", "Cmd+V", { "clipboard", "insert" } },
        { "select_all", "Edit", "Cmd+A", { "everything" } },
        { "clear_screen", "Terminal", "Cmd+K", { "erase", "wipe", "top" } },
        { "clear", "Terminal", "", { "erase", "reset", "wipe" } },
        { "clear_scrollback", "Terminal", "Opt+Cmd+K", { "erase", "history" } },
        { "increase_font_size", "Appearance", "Cmd++", { "zoom", "larger", "bigger", "text" } },
        { "decrease_font_size", "Appearance", "Cmd+-", { "zoom", "smaller", "text" } },
        { "reset_font_size", "Appearance", "Cmd+0", { "zoom", "actual", "text" } },
        { "scroll_to_top", "Navigate", "", { "beginning", "start", "home" } },
        { "scroll_to_bottom", "Navigate", "", { "end", "latest" } },
        { "scroll_line_up", "Navigate", "", { "up" } },
        { "scroll_line_down", "Navigate", "", { "down" } },
        { "scroll_page_up", "Navigate", "", { "up", "page" } },
        { "scroll_page_down", "Navigate", "", { "down", "page" } },
    };
    int catalogCount = 0;
    const Input::NamedActionEntry* catalog = Input::namedActionCatalog(catalogCount);
    for (int i = 0; i < catalogCount; ++i) {
        const std::string_view token = catalog[i].token;
        if (pageCannotRun(token))
            continue;
        const ActionPresentation* chrome = nullptr;
        for (const ActionPresentation& candidate : presentation) {
            if (candidate.token == token) {
                chrome = &candidate;
                break;
            }
        }
        // An action Core grows that this page has no presentation for still
        // appears, ungrouped: showing it is how the omission becomes visible,
        // and hiding it is how a private list starts over.
        add(catalog[i].token, catalog[i].label, chrome != nullptr ? chrome->group : "Terminal",
            chrome != nullptr ? chrome->shortcut : "", chrome != nullptr ? chrome->keywords : std::vector<std::string> {});
    }

    // A drill rather than an action: the values are Core's theme table, so the
    // browser lists exactly what every other frontend lists without carrying a
    // copy and without asking the host. Right arrow enters it.
    CommandPalette::PaletteCommand theme;
    theme.id = themeCommandID;
    theme.title = "Choose Theme";
    theme.group = "Appearance";
    // Whole PHRASES, not just words: bestMatch tests the query against each
    // keyword entire, so "select theme" has to be a subsequence of one of them —
    // a bare "select" keyword does not answer it.
    theme.keywords = { "select theme", "change theme", "set theme", "pick theme", "switch theme",
        "colors", "colours", "colorscheme", "color scheme", "appearance", "dark mode", "light mode" };
    theme.kind = CommandPalette::CommandKind::DrillOptions;
    commands.push_back(std::move(theme));

    // A number rather than a value list: the range is 0-64 in whole points, and
    // sixty-five rows to scroll is a worse way to pick one than typing it.
    CommandPalette::PaletteCommand padding;
    padding.id = paddingCommandID;
    padding.title = "Window Padding";
    padding.group = "Appearance";
    padding.keywords = { "window padding", "inset", "margin", "border", "gap", "breathing room",
        "edge spacing", "appearance" };
    padding.kind = CommandPalette::CommandKind::DrillNumber;
    commands.push_back(std::move(padding));

    // Beside the padding, because they are the same question asked of the two
    // axes a reader notices: how much room around the text, and how much
    // between the lines. The spacing was reachable through a configuration file
    // on every other frontend and through nothing at all here.
    CommandPalette::PaletteCommand lineSpacing;
    lineSpacing.id = lineSpacingCommandID;
    lineSpacing.title = "Line Spacing";
    lineSpacing.group = "Appearance";
    lineSpacing.keywords = { "line spacing", "line height", "leading", "row height",
        "vertical spacing", "density", "appearance" };
    lineSpacing.kind = CommandPalette::CommandKind::DrillNumber;
    commands.push_back(std::move(lineSpacing));

    // The size as a NUMBER, beside the three step actions rather than instead of
    // them. Stepping is right when the target is "a bit bigger"; typing is right
    // when it is 14, and reaching 14 from 16 by pressing a key twice is the
    // interaction a value editor exists to replace.
    CommandPalette::PaletteCommand fontSize;
    fontSize.id = fontSizeCommandID;
    fontSize.title = "Font Size";
    fontSize.group = "Appearance";
    fontSize.keywords = { "font size", "text size", "point size", "type size", "zoom", "appearance" };
    fontSize.kind = CommandPalette::CommandKind::DrillNumber;
    commands.push_back(std::move(fontSize));

    // Listed only when the page has said what it can render. A drill with
    // nothing behind it is worse than no command: it looks like a feature and
    // opens an empty box.
    if (hasFontOptions) {
        CommandPalette::PaletteCommand font;
        font.id = fontCommandID;
        font.title = "Choose Font";
        font.group = "Appearance";
        font.keywords = { "select font", "change font", "set font", "pick font", "switch font",
            "typeface", "font family", "monospace", "appearance" };
        font.kind = CommandPalette::CommandKind::DrillOptions;
        commands.push_back(std::move(font));
    }
    return commands;
}

// A numeric drill's schema, read from Core's settings table rather than from
// numbers written here — the same row the TOML parse clamps against, so the
// palette cannot offer a value a config file would refuse. A key absent from the
// table yields an unbounded editor, which is why every caller names a row that
// exists rather than a plausible one.
CommandPalette::PaletteNumber schemaNumber(const char* section, const char* key, double current)
{
    CommandPalette::PaletteNumber number;
    number.value = current;
    const Preferences::Schema::NumericRange* range = Preferences::Schema::rangeFor(section, key);
    if (range) {
        number.minimum = range->minimum;
        number.maximum = range->maximum;
        number.step = range->step;
        number.unit = range->unit;
    }
    return number;
}

// Core's theme table, in its own order. Built fresh per open so a theme
// registered since the last one is listed.
std::vector<CommandPalette::PaletteOption> themeOptions()
{
    std::vector<CommandPalette::PaletteOption> options;
    const int count = Themes::count();
    options.reserve(static_cast<std::size_t>(count > 0 ? count : 0));
    for (int i = 0; i < count; ++i) {
        const Themes::Theme* theme = Themes::get(i);
        options.push_back(CommandPalette::PaletteOption { theme && theme->name ? theme->name : "" });
    }
    return options;
}

} // namespace

bool WebTerminal::toggleBeam()
{
    if (!m_beam.isOpen()) {
        m_beam.setCommands(CommandPalette::Scope::Actions, browserCommands(!m_fontOptions.empty()));
        // Registered on every open, and registered EMPTY when no shell
        // integration has marked a prompt. A scope with no list ranks nothing
        // either way, but availability is what decides whether '@' is a prefix
        // or a character, and a browser always has a terminal to read — local or
        // mirrored from a host. Refusing the scope here would refuse a
        // capability this frontend has, and the user would be told so by a
        // literal '@' appearing in the query.
        m_beam.setTerminalAvailability(CommandPalette::TerminalAvailability::Available);
        m_beam.setCommands(CommandPalette::Scope::Blocks, blockCommands(m_terminal));
        m_beam.setOptions(themeCommandID, themeOptions(), m_themeIndex);
        m_beam.setNumber(paddingCommandID, schemaNumber("appearance", "padding", padding()));
        m_beam.setNumber(lineSpacingCommandID, schemaNumber("font", "line_spacing", m_lineSpacing));
        m_beam.setNumber(fontSizeCommandID, schemaNumber("font", "size", m_fontSize));
        if (!m_fontOptions.empty()) {
            std::vector<CommandPalette::PaletteOption> fonts;
            fonts.reserve(m_fontOptions.size());
            for (const std::string& family : m_fontOptions)
                fonts.push_back(CommandPalette::PaletteOption { family });
            m_beam.setOptions(fontCommandID, std::move(fonts), m_fontIndex);
        }
    }
    m_beam.apply(CommandPalette::BeamEvent::Toggle);
    return m_beam.isOpen();
}

bool WebTerminal::feedBeamKey(std::uint32_t keyCode, std::uint32_t baseLayoutKey, std::uint32_t modifiers, std::uint32_t text)
{
    if (!m_beam.isOpen())
        return false;
    const std::uint32_t chord = Input::resolveChordKey(keyCode, baseLayoutKey, modifiers & Input::bindModMask);
    const Input::BeamKeyOutcome outcome = Input::classifyBeamKey(chord, modifiers & Input::bindModMask, text);
    if (!outcome.handled)
        return false;
    const CommandPalette::BeamAction action = m_beam.apply(outcome.event, outcome.codePoint);
    if (action.kind == CommandPalette::BeamAction::Kind::Run) {
        // A block jump moves the viewport, which is this object's own state and
        // the same state the wheel and the scroll actions move. The page's part
        // is the repaint it does after every palette key anyway, so the id is
        // consumed here rather than handed out — handing it out would give the
        // page a row index of a buffer it does not address.
        const int blockRow = blockRowFor(action.commandID);
        if (blockRow >= 0) {
            scrollToAbsoluteRow(blockRow);
            return true;
        }
        // A theme is applied here rather than handed to the page. It is a change
        // to the terminal's palette, which this object owns; routing it out to
        // JavaScript and back would put the one frontend-agnostic setting behind
        // a frontend-specific hop, and every other frontend would need its own.
        if (action.commandID == themeCommandID && action.optionIndex >= 0) {
            if (Themes::applyThemeToTerminal(m_terminal, action.optionIndex))
                m_themeIndex = action.optionIndex;
            return true;
        }
        // Applied here for the reason the theme is: the value is this object's,
        // and the page's part is re-fitting a grid it re-fits after a zoom
        // anyway. The id still reaches the page, because the window geometry
        // that follows from it is the page's to change.
        // Applied here for the reason the theme is: the value is this object's, and
        // the page's part is re-fitting a grid it re-fits after a step anyway.
        if (action.commandID == fontSizeCommandID) {
            setFontSize(action.numberValue);
            m_beamCommand = action.commandID;
            return true;
        }
        if (action.commandID == paddingCommandID) {
            setPadding(action.numberValue);
            m_beamCommand = action.commandID;
            return true;
        }
        // Changes the cell, so the page refits its grid after it — the same
        // sequence a font-size change already runs.
        if (action.commandID == lineSpacingCommandID) {
            setLineSpacing(action.numberValue);
            m_beamCommand = action.commandID;
            return true;
        }
        // A font is STAGED, not applied: the family lives in the page's own
        // rasterizer bridge and the metrics cached here belong to the family
        // being replaced. Staging it puts the choice through the identical path
        // OSC 50 already uses, so there is one rebuild sequence rather than two
        // that have to be kept agreeing.
        if (action.commandID == fontCommandID && action.optionIndex >= 0
            && action.optionIndex < static_cast<int>(m_fontOptions.size())) {
            m_pendingFontFamily = m_fontOptions[static_cast<std::size_t>(action.optionIndex)];
            m_fontIndex = action.optionIndex;
            return true;
        }
        m_beamCommand = action.commandID;
    }
    return true;
}

const char* WebTerminal::takeBeamCommand()
{
    m_beamTakenCommand = std::move(m_beamCommand);
    m_beamCommand.clear();
    return m_beamTakenCommand.c_str();
}

} // namespace Ubiquitty::Web
