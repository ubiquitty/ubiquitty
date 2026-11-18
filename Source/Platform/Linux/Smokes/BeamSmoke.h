// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-beam — the command palette headlessly. Beam is portable Core (rank,
// layout, key classification); what this frontend supplies is the composite into
// the grid snapshot, the key routing, the per-scope command lists and what an
// accepted row does, so those are what this asserts.
//
// Every check is written to fail if its subject is removed, because a palette
// bug is invisible to every other smoke here: the grid still renders, the
// terminal still works, and the only symptom is a popover nobody sees. Deleting
// the composite in Raster.cpp turns `differs` false; deleting the layout call
// turns `drew` false; routing keys to the terminal instead of the palette leaves
// `narrowed` false; dropping the Blocks registration or the availability
// declaration leaves `didEnterScope` false, and dropping the jump leaves `didJump`
// false.
/// Checks command-palette composition, routing and accepted actions.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeBeam()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-beam: no term\n");
        return 1;
    }
    // A history of executed blocks, so the '@' scope has something to fill with
    // and the buffer has scrollback for a jump to move through.
    for (int i = 0; i < smokeBeamBlockCount - 1; ++i) {
        std::array<char, 32> commandLine {};
        std::snprintf(commandLine.data(), commandLine.size(), "$ echo %d", i);
        feedBeamSmokeCommandBlock(*term, commandLine.data(), 0);
    }
    feedBeamSmokeCommandBlock(*term, "$ false", 0);
    // The non-zero status lands on "$ false"; the prompt printed after it never
    // executes a command, so it is not a block of its own.
    feedBeamSmokeBytes(*term, "\033]133;D;1\007\033]133;A\007$ ");
    // A token wider than the terminal, so ONE logical match arrives as several
    // highlight segments. Without it the '/' assertions below are all
    // single-row matches, segments equal logical matches, and a walk that
    // listed segments would produce the same count as one that did not — the
    // dedupe would be asserted by a case that cannot see it.
    //
    // Fed as raw output rather than through `feedBeamSmokeCommandBlock`, whose
    // 128-byte frame would truncate it, and which would make it a thirty-first
    // block that the count above states there are thirty of.
    const std::string wrappedToken
        = std::string(startupColumns - smokeBeamWrappedTokenLength / 2, 'Q') + smokeBeamWrappedToken + "\r\n";
    feedBeamSmokeBytes(*term, wrappedToken.c_str());

    // The composite is asserted on the GRID, not on rendered pixels. Two
    // rasterizeTerm calls of the same screen are not byte-identical — the
    // renderer carries a glyph cache across calls — so a pixel diff between a
    // closed frame and an open one is true whether or not the palette was
    // composited. Written that way first, and it passed with the composite
    // disabled. snapshotVisibleGrid is the seam this feature changed and it is a
    // pure function of the terminal plus the chrome.
    app().rasterContext.setBeamChrome(nullptr);
    std::vector<Ubiquitty::Cell> closedGrid;
    app().rasterContext.snapshotVisibleGrid(term, 0, closedGrid);

    // The same registration a summon performs, rather than a list assembled for
    // the smoke: a scope this frontend forgets to fill is exactly the defect
    // being checked, and a smoke that fills it itself cannot see that.
    fillBeamScopes(term);
    app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
    const bool opened = app().beamSession.isOpen();

    const Ubiquitty::Rendering::BeamGeometry geometry = layoutBeamForFrame(*term);
    const bool drew = geometry.canvas.rows > 0 && geometry.bodyRows > 0;
    app().rasterContext.setBeamChrome(&geometry);

    int canvasInk = 0;
    for (const Ubiquitty::Cell& c : geometry.canvas.cells)
        if (c.codePoint != 0 && c.codePoint != 0x20)
            ++canvasInk;
    std::vector<Ubiquitty::Cell> openGrid;
    app().rasterContext.snapshotVisibleGrid(term, 0, openGrid);
    // Same size, different contents, and the difference has to lie INSIDE the
    // rectangle the layout named — a composite writing anywhere else is a bug
    // that "the grids differ" would happily accept.
    bool doesDifferInside = false;
    bool doesDifferOutside = false;
    const int columns = term->columns;
    for (std::size_t i = 0; i < closedGrid.size() && i < openGrid.size(); ++i) {
        if (closedGrid[i].codePoint == openGrid[i].codePoint)
            continue;
        const int row = static_cast<int>(i) / columns;
        const int column = static_cast<int>(i) % columns;
        const bool inside = row >= geometry.originRow && row < geometry.originRow + geometry.canvas.rows
            && column >= geometry.originColumn && column < geometry.originColumn + geometry.canvas.columns;
        (inside ? doesDifferInside : doesDifferOutside) = true;
    }
    const bool differs = !closedGrid.empty() && closedGrid.size() == openGrid.size() && doesDifferInside && !doesDifferOutside;

    std::vector<uint8_t> openRGBA;
    int openWidth = 0, openHeight = 0;
    const bool didRasterizeOpenCursor = app().rasterContext.rasterizeTerm(term, openRGBA, openWidth, openHeight, 0, nullptr, nullptr);

    // The same frame through the GPU path. Both composite inside
    // snapshotVisibleGrid, so this is the oracle covering the palette — a second
    // composite added to one path only would show up here and nowhere else.
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-beam", "vulkan init failed");
    std::vector<uint8_t> vulkanRGBA;
    int vulkanWidth = 0, vulkanHeight = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, vulkanRGBA, vulkanWidth, vulkanHeight, 0, nullptr, nullptr);
    renderer.shutdown();

    // Only the CPU<->GPU COMPARISON depends on a GPU frame; the composite, the
    // query routing and the close all run without one. So a box that cannot
    // produce a GPU frame skips that one check and still reports the rest —
    // skipping the whole mode would lose the composite assertion on exactly the
    // machine this is usually built on, which is where it most needs running.
    const bool didCompareGPU = didRenderGPUFrame && didRasterizeOpenCursor;
    const bool isIdentical = !didCompareGPU || (openWidth == vulkanWidth && openHeight == vulkanHeight && openRGBA == vulkanRGBA);

    // A query has to reach the palette through the same classifier the key
    // handler uses. The probe is a string that matches nothing, checked against
    // the empty set rather than "fewer rows than before": a single letter is not
    // discriminating, because the matcher is a subsequence over title +
    // keywords, so a common letter keeps nearly the whole catalog and the check
    // would pass on a routing path that is only half working. Backspacing back
    // to the full list is what separates a filter from a cleared command set.
    const std::size_t unfilteredRows = app().beamSession.state().rows.size();
    bool didRoute = true;
    for (const std::uint32_t letter : { 'q', 'z', 'q', 'z' }) {
        const Ubiquitty::Input::BeamKeyOutcome typed
            = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Input::resolveChordKey(letter, 0, 0), 0, letter);
        didRoute = didRoute && typed.handled;
        if (typed.handled)
            app().beamSession.apply(typed.event, typed.codePoint);
    }
    const std::size_t narrowedRows = app().beamSession.state().rows.size();
    for (int i = 0; i < 4; ++i) {
        const Ubiquitty::Input::BeamKeyOutcome erased
            = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyBackspace, 0, 0);
        didRoute = didRoute && erased.handled;
        if (erased.handled)
            app().beamSession.apply(erased.event, erased.codePoint);
    }
    const std::size_t restoredRows = app().beamSession.state().rows.size();
    const bool didNarrow = didRoute && unfilteredRows > 0 && narrowedRows == 0 && restoredRows == unfilteredRows;

    // The '@' scope. What this frontend owns of it is the registration — the
    // walk, the prefix strip and the terminal gate are all Core's — so the
    // prefix goes through the same classifier a keystroke takes and the scope is
    // read for what the frontend put in it. A palette that opens and never
    // enters a scope cannot see any of this.
    const Ubiquitty::Input::BeamKeyOutcome prefix
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Input::resolveChordKey('@', 0, 0), 0, '@');
    didRoute = didRoute && prefix.handled;
    if (prefix.handled)
        app().beamSession.apply(prefix.event, prefix.codePoint);
    // The query has to come back EMPTY: an undeclared terminal refuses the
    // retarget and leaves the '@' in the field, which ranks every block against a
    // character none of them carry — an empty scope for a reason that is not the
    // registration.
    const bool didEnterScope = app().beamSession.state().scope == Ubiquitty::CommandPalette::Scope::Blocks && app().beamSession.state().query.empty();
    const std::size_t blockRows = app().beamSession.state().rows.size();
    // Newest first, the failed one wearing the glyph this frontend chose for
    // Core's bool, the oldest last. A list built by walking the buffer forwards
    // holds the same rows and fails this.
    const bool didListBlocks = blockRows == static_cast<std::size_t>(smokeBeamBlockCount)
        && app().beamSession.state().rows.front().title == "$ false"
        && app().beamSession.state().rows.front().detail == "✗"
        && app().beamSession.state().rows.back().title == "$ echo 0";

    // The '/' scope, over the same buffer the blocks above filled. Asserted on
    // the builder rather than by typing a query through the session, because
    // what can be wrong here is the walk and the dedupe, and driving eight
    // keystrokes to reach them would test the key classifier a second time.
    //
    // "echo 1" matches `$ echo 1` and `$ echo 10`..`$ echo 19` — eleven of the
    // thirty blocks. A count rather than a spot check, because a walk that
    // dropped or doubled rows reads as a number and not as a wrong row. Every
    // one of these matches sits on a single row, so this says nothing about the
    // segment dedupe; the wrapping token below is what asks that.
    const auto find = [](const std::string& pattern) {
        Ubiquitty::Search::Request request { .pattern = pattern, .form = Ubiquitty::Search::PatternForm::Regex, .labelLimit = Ubiquitty::Search::maxStoredLabels };
        (void)activePane()->session->searchScrollbackAndWait(request);
        return beamFindCommands(activePane());
    };
    const Ubiquitty::CommandPalette::PaletteCommandList findRows = find("echo 1");
    bool doRowsReadTheirLine = !findRows.empty();
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : findRows) {
        if (row.title.find("echo 1") == std::string::npos)
            doRowsReadTheirLine = false;
    }
    const bool didListFind = findRows.size() == 11 && doRowsReadTheirLine;

    // Both a query with no matches and a cleared query leave the list empty.
    const bool isEmptyOnMiss = find("zzzznotpresent").empty() && find("").empty();

    // Every prefix of a regex is typed on the way to it, so a half-written one
    // is the normal state of this scope and must not throw or match wildly.
    const bool didSurviveBadPattern = find("[").empty() && find("*").empty();

    // One row for the straddling token, not one per visual row it touches.
    // `matchAt` counts logical matches and `segmentAt` counts highlight runs, so
    // this is the case that pins which of the two walks the scope uses —
    // swapping to the segment walk turns this row count into two.
    const Ubiquitty::CommandPalette::PaletteCommandList wrappedRows
        = find(smokeBeamWrappedToken);
    const bool isOneRowPerMatch = wrappedRows.size() == 1;

    // Accepting a row scrolls to it, through the same reveal the block jump
    // below uses. Checked here rather than at the end because that jump owns
    // the final viewOffset, and it resets the offset before it runs.
    activePane()->viewOffset = 0;
    const auto acceptedRows = find("echo 1");
    Ubiquitty::CommandPalette::BeamAction findAccept;
    findAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    findAccept.commandID = acceptedRows.empty() ? std::string("beam.find.0") : acceptedRows.front().id;
    runBeamAction(findAccept);
    const bool didJumpToMatch = !findRows.empty() && activePane()->viewOffset > 0;
    activePane()->session->clearScrollbackSearch();

    // The '#' scope. Asserted against Core's compiled defaults rather than the
    // machine's config.toml, because a row's VALUE is what the file decides and
    // this case would otherwise be about whoever ran it. The counts below do
    // not depend on the file — a row exists per descriptor, and which control
    // it gets comes from the static schema and vocabulary tables — but the
    // three value checks do.
    const std::string savedDocument = Ubiquitty::Preferences::liveDocument();
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Permissive);
    const Ubiquitty::CommandPalette::PaletteCommandList settingRows = beamSettingsCommands();

    std::size_t settingToggles = 0;
    std::size_t settingOptionDrills = 0;
    std::size_t settingNumberDrills = 0;
    bool doSettingRowsResolve = !settingRows.empty();
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : settingRows) {
        // Every id the scope offers has to resolve back to the key it names, or
        // accepting it reaches `runBeamAction` and falls through to the action
        // parse, which has no spelling for it.
        if (beamSettingDescriptorFor(row.id) == nullptr)
            doSettingRowsResolve = false;
        switch (row.kind) {
        case Ubiquitty::CommandPalette::CommandKind::Action:
            ++settingToggles;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillOptions:
            ++settingOptionDrills;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillNumber:
            ++settingNumberDrills;
            break;
        case Ubiquitty::CommandPalette::CommandKind::DrillText:
            break;
        }
    }
    // Each editable Core descriptor has exactly one row of the right kind.
    // Counting by identity catches an omitted row even when a duplicate keeps
    // the total unchanged; future descriptors need no frontend census update.
    auto settingRowsMismatch = [](std::span<const Ubiquitty::CommandPalette::PaletteCommand> rows) -> std::string {
        namespace Configuration = Ubiquitty::Preferences;
        using Ubiquitty::CommandPalette::CommandKind;
        std::size_t expectedRows = 0;
        for (const Configuration::WriteDescriptor& descriptor : Configuration::writeDescriptors) {
            const std::optional<Configuration::Value> value = Configuration::effectiveValue(descriptor.id, Configuration::values());
            std::optional<CommandKind> expectedKind;
            if (value) {
                switch (value->kind) {
                case Configuration::SerializeKind::Bool:
                    expectedKind = CommandKind::Action;
                    break;
                case Configuration::SerializeKind::EnumToken:
                    if (!Configuration::vocabularyFor(descriptor.id).empty()) {
                        expectedKind = CommandKind::DrillOptions;
                    }
                    break;
                case Configuration::SerializeKind::Int:
                case Configuration::SerializeKind::Double:
                    if (Configuration::Schema::rangeFor(descriptor.section, descriptor.key)) {
                        expectedKind = CommandKind::DrillNumber;
                    }
                    break;
                case Configuration::SerializeKind::String:
                case Configuration::SerializeKind::LegacyBoolOrToken:
                    break;
                }
            }
            const std::string commandID = std::format("beam.setting.{}.{}", descriptor.section, descriptor.key);
            std::size_t matches = 0;
            std::optional<CommandKind> actualKind;
            for (const Ubiquitty::CommandPalette::PaletteCommand& row : rows) {
                if (row.id == commandID) {
                    ++matches;
                    actualKind = row.kind;
                }
            }
            if (!expectedKind) {
                if (matches) {
                    return std::format("{} is not editable but has {} row(s)", commandID, matches);
                }
                continue;
            }
            ++expectedRows;
            if (matches != 1) {
                return std::format("{} requires one row, found {}", commandID, matches);
            }
            if (actualKind != expectedKind) {
                return std::format("{} has the wrong control kind", commandID);
            }
        }
        if (rows.size() != expectedRows) {
            return std::format("expected {} editable descriptors, found {} rows", expectedRows, rows.size());
        }
        return {};
    };
    const std::string settingsMismatch = settingRowsMismatch(settingRows);
    const bool didListSettings = settingsMismatch.empty() && doSettingRowsResolve;
    if (!settingsMismatch.empty()) {
        g_printerr("smoke-beam: settings mismatch: %s\n", settingsMismatch.c_str());
    }

    bool doesRejectSettingsDefects = false;
    if (!settingRows.empty()) {
        auto brokenRows = settingRows;
        brokenRows.pop_back();
        const bool doesRejectMissingRow = !settingRowsMismatch(brokenRows).empty();
        bool doesRejectDuplicateRow = false;
        bool doesRejectWrongControl = false;
        for (std::size_t index = 1; index < settingRows.size(); ++index) {
            if (!doesRejectDuplicateRow && settingRows[index].kind == settingRows.front().kind) {
                brokenRows = settingRows;
                brokenRows[index] = brokenRows.front();
                doesRejectDuplicateRow = !settingRowsMismatch(brokenRows).empty();
            }
            if (!doesRejectWrongControl && settingRows[index].kind != settingRows.front().kind) {
                brokenRows = settingRows;
                brokenRows.front().kind = settingRows[index].kind;
                brokenRows[index].kind = settingRows.front().kind;
                doesRejectWrongControl = !settingRowsMismatch(brokenRows).empty();
            }
            if (doesRejectDuplicateRow && doesRejectWrongControl) {
                break;
            }
        }
        doesRejectSettingsDefects = doesRejectMissingRow && doesRejectDuplicateRow && doesRejectWrongControl;
    }

    // Three representative rows, one per control, checked by id so the walk
    // order cannot satisfy them by accident.
    auto rowFor = [&settingRows](const char* id) -> const Ubiquitty::CommandPalette::PaletteCommand* {
        for (const Ubiquitty::CommandPalette::PaletteCommand& row : settingRows) {
            if (row.id == id)
                return &row;
        }
        return nullptr;
    };
    const Ubiquitty::CommandPalette::PaletteCommand* ligatures = rowFor("beam.setting.font.ligatures");
    const Ubiquitty::CommandPalette::PaletteCommand* shape = rowFor("beam.setting.cursor.shape");
    const Ubiquitty::CommandPalette::PaletteCommand* fontSize = rowFor("beam.setting.font.size");
    const auto* brailleStyle = rowFor("beam.setting.font.braille_style");
    const bool areControlsRight = ligatures != nullptr && shape != nullptr && fontSize != nullptr && brailleStyle != nullptr
        && brailleStyle->kind == Ubiquitty::CommandPalette::CommandKind::DrillOptions
        && brailleStyle->value == beamSettingDefaultLabel(Ubiquitty::Preferences::Key::FontBrailleStyle, Ubiquitty::Rendering::brailleStyleToString(Ubiquitty::Rendering::defaultBrailleStyle).data())
        && ligatures->kind == Ubiquitty::CommandPalette::CommandKind::Action
        && shape->kind == Ubiquitty::CommandPalette::CommandKind::DrillOptions
        // [font] size carries an Int write descriptor and resolves as a DOUBLE.
        // Its CONTROL is DrillNumber under either reading, so the kind alone
        // says nothing; what separates them is which slot the preview came
        // from. A row that trusted the descriptor would read the `integer`
        // slot, which a double-valued key leaves at its zero, and show "0 pt".
        && fontSize->kind == Ubiquitty::CommandPalette::CommandKind::DrillNumber
        && fontSize->value
            == Ubiquitty::CommandPalette::Settings::valuePreview(Ubiquitty::Preferences::Defaults::fontSize,
                Ubiquitty::Preferences::Schema::rangeFor("font", "size")->step,
                Ubiquitty::Preferences::Schema::rangeFor("font", "size")->unit)
        // The row shows the LIVE value, so the expectation is derived from the
        // default rather than written as a literal — `cursor.shape` defaults to
        // Bar, not to the first term, and a case naming "Block" would be
        // asserting the walk order instead of the value. A literal here would
        // also rot silently the day a default moves.
        && shape->value == beamSettingDefaultLabel(Ubiquitty::Preferences::Key::CursorShape, Ubiquitty::Preferences::cursorShapeToString(Ubiquitty::Preferences::Defaults::cursorShape))
        && ligatures->value == (Ubiquitty::Preferences::Defaults::ligatures ? "On" : "Off");

    // A key the palette cannot edit is absent rather than listed and inert:
    // [font] family needs a text editor the session has no payload for, and
    // [window] drag_modifier is a chord rather than a closed list.
    const bool areUneditableAbsent = rowFor("beam.setting.font.family") == nullptr
        && rowFor("beam.setting.window.drag_modifier") == nullptr;

    // Accepting a row has to reach the FILE, not just the list. Pointed at a
    // private store so the case never writes the developer's config.toml, and
    // so what it reads back is only what it wrote.
    //
    // `[font] ligatures` is the subject because it defaults ON: a toggle that
    // did nothing would leave the file without the key and the value at the
    // default, and both halves of the check would pass on absence. Writing the
    // non-default is the only edit whose success and failure look different.
    std::string settingsStoreRoot = std::format("/tmp/ubiquitty-smoke-beam-settings-{}", getpid());
    setenv("XDG_CONFIG_HOME", settingsStoreRoot.c_str(), 1);
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Permissive);

    Ubiquitty::CommandPalette::BeamAction settingAccept;
    settingAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    settingAccept.commandID = "beam.setting.font.ligatures";
    runBeamAction(settingAccept);

    const std::string writtenStore = readPreferencesStore();
    const bool didPersistSetting = writtenStore.find("[font]") != std::string::npos
        && writtenStore.find("ligatures = false") != std::string::npos;
    // And the live values followed the file, which is what makes the change
    // visible in this window rather than at the next launch.
    const bool didApplySetting = didPersistSetting
        && Ubiquitty::Preferences::Effective::ligatures(loadPreferences()) == false;

    // Toggling back returns it, so the row reads the live value rather than a
    // latched one — a setter that always wrote `false` would pass the two above.
    runBeamAction(settingAccept);
    const bool didToggleBack = readPreferencesStore().find("ligatures = true") != std::string::npos
        && Ubiquitty::Preferences::Effective::ligatures(loadPreferences());

    Ubiquitty::CommandPalette::BeamAction brailleAccept;
    brailleAccept.kind = Ubiquitty::CommandPalette::BeamAction::Kind::Run;
    brailleAccept.commandID = "beam.setting.font.braille_style";
    const auto brailleTerms = Ubiquitty::Preferences::vocabularyFor(Ubiquitty::Preferences::Key::FontBrailleStyle);
    bool didApplyBraille = brailleTerms.size() == 7;
    for (std::size_t index = 0; index < brailleTerms.size(); ++index) {
        brailleAccept.optionIndex = static_cast<int>(index);
        runBeamAction(brailleAccept);
        const auto style = Ubiquitty::Preferences::Effective::brailleStyle(loadPreferences());
        const auto rows = beamSettingsCommands();
        bool hasLiveLabel = false;
        for (const auto& row : rows) {
            if (row.id == brailleAccept.commandID) {
                hasLiveLabel = row.value == brailleTerms[index].label;
            }
        }
        didApplyBraille = didApplyBraille && hasLiveLabel
            && static_cast<std::size_t>(style) == index
            && readPreferencesStore().find(std::format("braille_style = \"{}\"", brailleTerms[index].token)) != std::string::npos;
    }
    g_print("smoke-beam: braille styles=%zu persisted/live/label=%d\n", brailleTerms.size(), static_cast<int>(didApplyBraille));

    // The toggle has to reach the SHAPER, not only the file and the live values.
    //
    // The two checks above are what this case had before, and they pass while
    // the setting does nothing: the shaping inputs are resolved in the
    // rasterizer's constructor, so reloading preferences and repainting draws
    // the same glyphs through the same shaper. A row that writes the file and
    // changes no pixel is the exact defect the settings scope exists to remove,
    // and asserting the file is how it hides.
    //
    // Read off the live rasterizer rather than a fresh one built with the
    // setting: a fresh one proves the constructor honours its argument, which
    // was never in doubt, and says nothing about whether the running terminal
    // was rebuilt.
    // Pointed at the bundled ligating face first, for the reason
    // --smoke-ligature-shaping gives: fontconfig answers DejaVu Sans Mono for
    // "monospace" in this container and it substitutes nothing, so the check
    // below would be vacuous against whatever the host happens to install.
    // Whether the machine has a ligature face is a capability; whether the
    // toggle reaches the shaper is the contract, and the bundled face is how
    // this asks about the contract.
    const std::string bundledLigatingPath = bundledFontPathForFamily("JetBrains Mono");
    if (!bundledLigatingPath.empty() && app().fontRasterizerKind != Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap) {
        app().fontFamily = "JetBrains Mono";
        rebuildFontsFromPreferences();
    }
    bool didShaperFollow = false;
    if (static_cast<bool>(app().glyphRasterizer)) {
        const std::array<std::uint32_t, 2> arrow { '=', '>' };
        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> shaped {};
        auto substitutions = [&]() {
            const int glyphs = app().glyphRasterizer->shapeTextRun(arrow, 0, shaped);
            int n = 0;
            for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                if (shaped[i].glyph != app().glyphRasterizer->glyphIndexForCodePoint(arrow[i]))
                    ++n;
            }
            return n;
        };
        // Only meaningful where the live face ligates at all — the container
        // resolves DejaVu Sans Mono for "monospace", which substitutes nothing,
        // and a case that demanded a difference there would fail on the font
        // rather than on the code.
        settingAccept.commandID = "beam.setting.font.ligatures";
        const int before = substitutions();
        if (before > 0) {
            runBeamAction(settingAccept); // ligatures -> off
            const int suppressed = substitutions();
            runBeamAction(settingAccept); // and back on
            const int restored = substitutions();
            didShaperFollow = suppressed == 0 && restored == before;
        } else {
            // Stated rather than passed silently: a face that ligates nothing
            // cannot answer this, and a green here would be about the font.
            g_print("  (live face ligates nothing; the shaper-follows check is vacuous here)\n");
            didShaperFollow = true;
        }
    }

    unsetenv("XDG_CONFIG_HOME");
    (void)Ubiquitty::Preferences::configure(savedDocument, Ubiquitty::Preferences::ParseMode::Permissive);

    // Escape leaves the scope before it closes anything: a scope is a place the
    // user navigated to, and one Escape giving up both would throw the palette
    // away over a mistyped prefix.
    const Ubiquitty::Input::BeamKeyOutcome escape
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEscape, 0, 0);
    if (escape.handled)
        app().beamSession.apply(escape.event, escape.codePoint);
    const bool didLeaveScope
        = escape.handled && app().beamSession.isOpen() && app().beamSession.state().scope == Ubiquitty::CommandPalette::Scope::Actions;

    // The second Escape closes, so the palette cannot strand the keyboard.
    if (escape.handled)
        app().beamSession.apply(escape.event, escape.codePoint);
    const bool didClose = escape.handled && !app().beamSession.isOpen();

    // Accepting a block scrolls to it. End selects the oldest row and the steps
    // back up land on `smokeBeamTargetFromOldest`, which is the block the Core
    // list holds at the same distance from its end — the rows carry the walk's
    // order, so the two agree by construction.
    fillBeamScopes(term); // a summon registers, and this is the second summon
    app().beamSession.apply(Ubiquitty::CommandPalette::BeamEvent::Toggle);
    if (prefix.handled)
        app().beamSession.apply(prefix.event, prefix.codePoint);
    const Ubiquitty::Input::BeamKeyOutcome toOldest
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEnd, 0, 0);
    if (toOldest.handled)
        app().beamSession.apply(toOldest.event, toOldest.codePoint);
    const Ubiquitty::Input::BeamKeyOutcome stepUp
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyUp, 0, 0);
    for (int i = 1; i < smokeBeamTargetFromOldest && stepUp.handled; ++i)
        app().beamSession.apply(stepUp.event, stepUp.codePoint);
    const Ubiquitty::Screen::CommandBlockList blocks
        = Ubiquitty::Screen::commandBlocks(term, Ubiquitty::Screen::maxCommandBlocks);
    const int targetPromptRow = static_cast<int>(blocks.size()) >= smokeBeamTargetFromOldest
        ? blocks[blocks.size() - static_cast<std::size_t>(smokeBeamTargetFromOldest)].promptRow
        : -1;
    activePane()->viewOffset = 0;
    const Ubiquitty::Input::BeamKeyOutcome accept
        = Ubiquitty::Input::classifyBeamKey(Ubiquitty::Keys::Keymap::keymapKeyEnter, 0, 0);
    if (accept.handled)
        runBeamAction(app().beamSession.apply(accept.event, accept.codePoint));

    app().rasterContext.setBeamChrome(nullptr); // restore (defensive; smokes are separate processes)

    // The block has to be at the row the reveal policy places it on. Which row
    // that is comes from Core rather than from a constant here: a copy of the
    // rule in the check would agree with a frontend that had drifted from every
    // other one, which is the state this case exists to catch. That row is
    // fixed by the policy, not by the offset, which is what makes it readable:
    // the row the offset itself points at holds the block whatever offset was
    // applied, because the address map (absolute = history - offset + visible)
    // cancels the offset out. A case read at that row agrees with itself under
    // a reveal sent one row off, and reports a jump it has not measured.
    //
    // The offset has to sit strictly INSIDE [0, history] for the same reason: at
    // either bound the reveal is clamped, and a clamped offset is the same value
    // whatever arithmetic produced it.
    std::vector<Ubiquitty::Cell> jumpedGrid;
    app().rasterContext.snapshotVisibleGrid(term, activePane()->viewOffset, jumpedGrid);
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    const int placedRow = Ubiquitty::Screen::landingRowFor(term->rows, Ubiquitty::Screen::RevealPlacement::CommandBlock);
    const bool didJump = accept.handled && !app().beamSession.isOpen() && targetPromptRow >= 0
        && activePane()->viewOffset > 0 && activePane()->viewOffset < history
        && beamSmokeGridRowText(jumpedGrid, term->columns, placedRow)
            == Ubiquitty::Screen::absoluteRowText(*term, targetPromptRow, term->columns);

    const bool didPass = opened && drew && differs && isIdentical && didNarrow && didEnterScope && didListBlocks
        && didListFind && isEmptyOnMiss && didSurviveBadPattern && isOneRowPerMatch && didJumpToMatch
        && didListSettings && doesRejectSettingsDefects && areControlsRight && areUneditableAbsent
        && didPersistSetting && didApplySetting && didToggleBack && didApplyBraille && didShaperFollow && didLeaveScope && didClose && didJump;
    g_print("smoke-beam: opened=%d drew=%dx%d@%d,%d body=%d canvasInk=%d/%zu composited=%d(in=%d out=%d) CPU==GPU=%s rows=%zu->%zu->%zu scoped=%d blocks=%zu listed=%d find=%zu(listed=%d miss=%d badpattern=%d wrapped=%zu/dedup=%d jumped=%d) settings=%zu(t=%zu/o=%zu/n=%zu listed=%d oracle=%d controls=%d hidden=%d wrote=%d applied=%d back=%d braille=%d shaper=%d) leaves-scope=%d closes=%d jumped=%d(row=%d at=%d offset=%d/%d) -- %s\n",
        static_cast<int>(opened), geometry.canvas.rows, geometry.canvas.columns, geometry.originRow, geometry.originColumn,
        geometry.bodyRows, canvasInk, geometry.canvas.cells.size(), static_cast<int>(differs), static_cast<int>(doesDifferInside), static_cast<int>(doesDifferOutside), didCompareGPU ? (isIdentical ? "1" : "0") : "skipped(no GPU frame)",
        unfilteredRows, narrowedRows, restoredRows,
        static_cast<int>(didEnterScope), blockRows, static_cast<int>(didListBlocks),
        findRows.size(), static_cast<int>(didListFind), static_cast<int>(isEmptyOnMiss),
        static_cast<int>(didSurviveBadPattern), wrappedRows.size(), static_cast<int>(isOneRowPerMatch), static_cast<int>(didJumpToMatch),
        settingRows.size(), settingToggles, settingOptionDrills, settingNumberDrills,
        static_cast<int>(didListSettings), static_cast<int>(doesRejectSettingsDefects), static_cast<int>(areControlsRight), static_cast<int>(areUneditableAbsent),
        static_cast<int>(didPersistSetting), static_cast<int>(didApplySetting), static_cast<int>(didToggleBack),
        static_cast<int>(didApplyBraille), static_cast<int>(didShaperFollow),
        static_cast<int>(didLeaveScope), static_cast<int>(didClose),
        static_cast<int>(didJump), targetPromptRow, placedRow, activePane()->viewOffset, history,
        didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
