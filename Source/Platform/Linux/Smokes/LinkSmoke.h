// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Clickable-hyperlink self-test. Feeds an OSC 8 hyperlink around some text,
// finds the stamped cell, and asserts its link id resolves back to the URI
// through the Terminal's link table — the OSC 8 resolve path the click/hover use.
// Then asserts the portable launch allowlist (the gate the click applies before
// gtk_show_uri): safe network schemes and file accepted, javascript rejected.
// Then what a press does with what it finds (linkDispatchAtCell): a plain click
// opens a declared link and not a guessed one, Ctrl opens either, and a second
// press opens nothing. Then what a click may do with a file link
// (linkDispatchForURI), over real files in a scratch directory: a document, a
// directory, text with a stray execute bit, extensionless names a repository
// holds, media, a Latin-1 name and file:/path open, a script, a desktop entry
// and a symbolic link to a script are only revealed, and a pipe, a missing
// path, a query, a
// fragment that names no line, another machine's authority and a hidden
// character are refused, while a name spelled with a joiner opens. Then a link
// that names a line: the ordinary rule with no line handler, and with one the
// handler's argv, built from the canonical path, which it is started with.
// Nothing is opened: each decision is asked for and not acted on, but for the
// line handler, which is `ln -s` recording the argument it receives.
/// Checks hyperlink resolution, safe launch schemes and click dispatch.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeLink()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-link: no term\n");
        return 1;
    }

    // OSC 8 open (uri https://example.com) → "link" → OSC 8 close. The stamped
    // cells carry the interned link id; the closing sequence clears it.
    const char osc8[] = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(osc8, sizeof(osc8) - 1));

    // Cell (0, 0) is the 'l' of "link"; it must carry a non-zero link id that
    // resolves to the OSC 8 URI.
    const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const uint16_t id = (cell != nullptr) ? cell->linkID() : 0;
    const char* resolved = (id != 0) ? Ubiquitty::Attributes::Hyperlinks::uri(term, id) : nullptr;
    const std::string uri = (resolved != nullptr) ? resolved : "";
    const bool didDecodeOSC8 = uri == "https://example.com";

    // Allowlist gate — the one portable helper both frontends share.
    const bool isHTTPSLaunchAllowed = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("https://x");
    const bool isHTTPLaunchAllowed = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("http://x");
    const bool acceptFile = Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("file:///etc/passwd");
    const bool didRejectJavaScript = !Ubiquitty::Attributes::LinkRun::isLaunchableURLScheme("javascript:alert(1)");

    g_print("smoke-link: OSC 8 cell linkID=%u resolved=\"%s\" -- %s\n", static_cast<unsigned>(id), uri.c_str(), didDecodeOSC8 ? "PASS" : "FAIL");
    g_print("smoke-link: allowlist https://x=%s http://x=%s "
            "file:///etc/passwd=%s javascript:alert(1)=%s\n",
        isHTTPSLaunchAllowed ? "accept" : "reject", isHTTPLaunchAllowed ? "accept" : "reject", acceptFile ? "accept" : "reject", didRejectJavaScript ? "reject" : "accept");

    bool didPass = didDecodeOSC8 && isHTTPSLaunchAllowed && isHTTPLaunchAllowed && acceptFile && didRejectJavaScript;
    using Ubiquitty::Attributes::LinkRun::LocalLinkAction;
    const auto expect = [&](bool isMet, const char* what) {
        g_print("smoke-link: %s -- %s\n", what, isMet ? "PASS" : "FAIL");
        didPass = didPass && isMet;
    };

    // Row 1 carries a URL the program never declared.
    Ubiquitty::processBytes(term, "\r\nsee https://example.com/guess here");
    const GdkModifierType plain = static_cast<GdkModifierType>(0);
    expect(linkDispatchAtCell(0, 1, plain, 1).action == LocalLinkAction::Open, "a plain click opens a declared link");
    expect(linkDispatchAtCell(1, 8, plain, 1).action == LocalLinkAction::Refuse, "a plain click leaves a guessed link alone");
    expect(linkDispatchAtCell(1, 8, GDK_SUPER_MASK, 1).action == LocalLinkAction::Refuse, "Super leaves a guessed link to the window manager");
    expect(linkDispatchAtCell(1, 8, GDK_CONTROL_MASK, 1).target == "https://example.com/guess", "Ctrl opens a guessed link");
    expect(linkDispatchAtCell(0, 1, plain, 2).action == LocalLinkAction::Refuse, "the second press of a double-click opens nothing");
    // The hand over the guess follows Ctrl as it goes down and up, as the
    // click does: the hover re-asks with the key's edge applied.
    std::array<char, Ubiquitty::VT::maxLinkURILength> guessed {};
    const LinkSource guess = linkURIAtCell(1, 8, guessed.data(), static_cast<int>(guessed.size()));
    using Ubiquitty::Keys::KeyEventType;
    expect(linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Control_L, plain, KeyEventType::Press)),
        "pressing Ctrl over a guess raises the hand");
    expect(!linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Control_R, GDK_CONTROL_MASK, KeyEventType::Release)),
        "and letting it go lowers it");
    expect(!linkClickOpens(guess, guessed.data(), modifiersAfterKey(GDK_KEY_Shift_L, plain, KeyEventType::Press)), "while Shift is not Ctrl");
    // And through the key handlers GTK calls, which is where the re-ask is
    // wired: a pointer resting over the guess, then Ctrl down and up as the
    // key controller delivers them. A picture with no window takes the cursor,
    // and making one takes GTK, which takes a display.
    if (!gtk_init_check()) {
        expect(false, "GTK has a display for the key handlers; run under xvfb-run");
    } else {
        GtkWidget* picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
        app().focusedPicture = picture;
        const auto savedPresentation = activePane()->presentation;
        const Ubiquitty::FloatSize hitCell { static_cast<float>(app().rasterContext.cellWidth()), static_cast<float>(app().rasterContext.cellHeight()) };
        const auto hitViewport = Ubiquitty::Rendering::viewportForGrid({ term->columns, term->rows }, hitCell, { 4, 4, 6, 6 }, 0);
        activePane()->presentation = Ubiquitty::Linux::Presentation::PaneGeometry::resolve(hitViewport, { 4, 4, 6, 6 }, hitCell, { term->columns, term->rows });
        const double paddingX = 1.0 / app().scale;
        const double textY = (6 + 0.5 * hitCell.height) / app().scale;
        int paddingRow = -1, paddingColumn = -1;
        cellAtPoint(paddingX, textY, paddingRow, paddingColumn);
        expect(paddingRow == 0 && paddingColumn == 0 && !strictCellAtPanePoint(*activePane(), paddingX, textY),
            "padding clamps mouse reports but is not a cell for a link press");
        updateHoverCursor(paddingX, textY, GDK_CONTROL_MASK);
        expect(!activePane()->hoveredLink.isActive && activePane()->hoverCursorShape == Ubiquitty::MousePointerShape::Default,
            "padding beside a declared link shows neither a hand nor text cursor");
        updateHoverCursor((4 + 0.5 * hitCell.width) / app().scale, textY, GDK_CONTROL_MASK);
        expect(activePane()->hoveredLink.isActive && activePane()->hoveredLink.linkID == id,
            "the same declared link remains hoverable inside the padded content");
        activePane()->presentation = savedPresentation;
        publishHoveredLink(*activePane(), {});
        app().hoverX = (8.5 * app().rasterContext.cellWidth()) / app().scale;
        app().hoverY = (1.5 * app().rasterContext.cellHeight()) / app().scale;
        app().isHoverPointKnown = true;
        activePane()->pointerX = app().hoverX;
        activePane()->pointerY = app().hoverY;
        activePane()->isPointerPositionKnown = true;
        updateHoverCursor(app().hoverX, app().hoverY, plain);
        expect(!activePane()->hoveredLink.isActive && app().hoverCursorShape != Ubiquitty::MousePointerShape::Pointer
                && activePane()->hoverCursorShape != Ubiquitty::MousePointerShape::Pointer,
            "a resting pointer over the guess shows no link hand or underline");
        int hoverRow = -1;
        int hoverColumn = -1;
        cellAtPoint(app().hoverX, app().hoverY, hoverRow, hoverColumn);
        expect(hoverRow == 1 && hoverColumn == 8, "the resting pointer is over the guess");
        std::vector<std::uint8_t> restingPixels;
        std::vector<std::uint8_t> hoveredPixels;
        int pixelWidth = 0;
        int pixelHeight = 0;
        app().rasterContext.setFrameHoverLink({});
        const bool didDrawResting = app().rasterContext.rasterizeTerm(term, restingPixels, pixelWidth, pixelHeight);
        const auto blinkStart = app().caretBlinkCycleStartMicros;
        onKeyPressed(nullptr, GDK_KEY_Control_L, 0, plain, nullptr);
        expect(activePane()->hoveredLink.isActive && activePane()->hoveredLink.linkID == 0,
            "Ctrl publishes a verified guessed-link span to the renderer");
        app().rasterContext.setFrameHoverLink(activePane()->hoveredLink);
        const bool didDrawHover = app().rasterContext.rasterizeTerm(term, hoveredPixels, pixelWidth, pixelHeight);
        const auto metrics = currentRasterizer().cellMetrics();
        const int firstRuleRow = std::clamp(app().rasterContext.cellHeight() + static_cast<int>(std::ceil(metrics.baselineFromTop)),
            0, std::max(pixelHeight - 1, 0));
        const int lastRuleRow = std::min(pixelHeight, app().rasterContext.cellHeight() * 2);
        bool hasVisibleRule = false;
        if (didDrawResting && didDrawHover && restingPixels.size() == hoveredPixels.size()) {
            for (int y = firstRuleRow; y < lastRuleRow; ++y) {
                for (int x = 4 * app().rasterContext.cellWidth(); x < 29 * app().rasterContext.cellWidth() && x < pixelWidth; ++x) {
                    const auto pixel = static_cast<std::size_t>(y * pixelWidth + x) * 4;
                    hasVisibleRule |= std::memcmp(restingPixels.data() + pixel, hoveredPixels.data() + pixel, 4) != 0;
                }
            }
        }
        expect(hasVisibleRule, "Ctrl hover draws the guessed URL underline below the text baseline");
        expect(app().caretBlinkCycleStartMicros == blinkStart, "link-modifier hover does not restart cursor blinking");
        expect(app().hoverCursorShape == Ubiquitty::MousePointerShape::Pointer, "Ctrl going down over a guess raises the hand");
        onKeyReleased(nullptr, GDK_KEY_Control_L, 0, GDK_CONTROL_MASK, nullptr);
        expect(app().hoverCursorShape != Ubiquitty::MousePointerShape::Pointer, "and Ctrl coming up lowers it");
        expect(!activePane()->hoveredLink.isActive, "Ctrl release clears the underline without pointer motion");
        GtkGesture* cancelledGesture = gtk_gesture_click_new();
        g_object_ref_sink(cancelledGesture);
        windowSignalConnect(cancelledGesture, "cancel", G_CALLBACK(onMouseGestureCancelled), activePane());
        app().isLinkPressClaimed = true;
        app().heldPointerButton = Ubiquitty::Input::PointerButton::Left;
        g_signal_emit_by_name(cancelledGesture, "cancel", nullptr);
        expect(!app().isLinkPressClaimed && app().heldPointerButton == Ubiquitty::Input::PointerButton::Other,
            "canceling a locally claimed link gesture releases its native pointer state");
        onKeyPressed(nullptr, GDK_KEY_Control_L, 0, plain, nullptr);
        expect(activePane()->hoveredLink.isActive, "a cancelled link gesture permits modifier hover without another click");
        onKeyReleased(nullptr, GDK_KEY_Control_L, 0, GDK_CONTROL_MASK, nullptr);
        g_object_unref(cancelledGesture);
        const auto feedModes = [](std::string_view bytes) {
            activePane()->session->feedBytes({ bytes.data(), bytes.size() });
        };
        feedModes("\x1b[?1003h");
        updateHoverCursor(app().hoverX, app().hoverY, GDK_CONTROL_MASK);
        expect(activePane()->hoveredLink.isActive && app().hoverCursorShape == Ubiquitty::MousePointerShape::Pointer,
            "Ctrl hover reaches detected links while the application tracks every motion");
        updateHoverCursor(app().hoverX, app().hoverY, plain);
        const auto& preferences = Ubiquitty::Preferences::values();
        const bool shouldRevealPlainReportedLink = Ubiquitty::Preferences::Effective::osc8ClickOpens(preferences)
            && Ubiquitty::Preferences::Effective::linksOverrideReporting(preferences);
        expect(activePane()->hoveredLink.isActive == shouldRevealPlainReportedLink,
            "plain reported-link hover follows the shared reporting override preference");
        feedModes("\x1b[?1003l\x1b[?1049h\x1b[2;1Hsee https://example.com/guess here");
        updateHoverCursor(app().hoverX, app().hoverY, plain);
        expect(!activePane()->hoveredLink.isActive, "alternate screen alone leaves detected links modifier-gated");
        updateHoverCursor(app().hoverX, app().hoverY, GDK_CONTROL_MASK);
        expect(activePane()->hoveredLink.isActive, "Ctrl hover works on the alternate screen without mouse reporting");
        feedModes("\x1b[?1003h");
        updateHoverCursor(app().hoverX, app().hoverY, plain);
        expect(activePane()->hoveredLink.isActive == shouldRevealPlainReportedLink,
            "alternate-screen mouse reporting uses the same plain-link preference");
        feedModes("\x1b[?1003l\x1b[?1049l");
        updateHoverCursor(app().hoverX, app().hoverY, plain);
        onKeyPressed(nullptr, GDK_KEY_Super_L, 0, plain, nullptr);
        expect(!activePane()->hoveredLink.isActive,
            "Super preserves the desktop's window gesture without revealing guessed links");
        onKeyReleased(nullptr, GDK_KEY_Super_L, 0, GDK_SUPER_MASK, nullptr);
        expect(!activePane()->hoveredLink.isActive, "Super release preserves the resting underline state");
        updateHoverCursor((1.5 * app().rasterContext.cellWidth()) / app().scale,
            (0.5 * app().rasterContext.cellHeight()) / app().scale, GDK_SUPER_MASK);
        expect(activePane()->hoveredLink.isActive && activePane()->hoveredLink.linkID == id,
            "OSC 8 hover preserves its declaring ID for discontiguous runs");
        onMouseLeave(nullptr, activePane());
        expect(!activePane()->hoveredLink.isActive, "leaving a pane removes link emphasis");
        LinuxPane* const focusedBeforeHover = activePane();
        auto other = std::make_unique<LinuxPane>();
        other->headlessSession.reset(Ubiquitty::Runtime::TerminalSession::make());
        other->session = other->headlessSession.get();
        other->session->start(startupRows, startupColumns);
        other->picture = GTK_WIDGET(g_object_ref_sink(gtk_picture_new()));
        Ubiquitty::processBytes(other->session->terminal(), "https://background.example");
        LinuxPane* const otherPane = other.get();
        app().panes.push_back(std::move(other));
        onMouseEnter(nullptr, app().rasterContext.cellWidth() * 2.5 / app().scale,
            app().rasterContext.cellHeight() * 0.5 / app().scale, otherPane);
        onKeyPressed(nullptr, GDK_KEY_Control_L, 0, plain, nullptr);
        expect(otherPane->hoveredLink.isActive && otherPane->hoverCursorShape == Ubiquitty::MousePointerShape::Pointer,
            "Ctrl hover resolves a nonfocused pane at its own pointer position");
        expect(activePane() == focusedBeforeHover, "hovering another split preserves keyboard focus");
        onKeyReleased(nullptr, GDK_KEY_Control_L, 0, GDK_CONTROL_MASK, nullptr);
        expect(!otherPane->hoveredLink.isActive, "modifier release clears a nonfocused pane underline");
        onMouseLeave(nullptr, otherPane);
        auto previousLetters = std::move(focusedBeforeHover->presentedLetters);
        const auto previousGrid = focusedBeforeHover->presentedGridSize;
        const auto previousCell = focusedBeforeHover->presentedCellPixels;
        focusedBeforeHover->presentedLetters = { { { 0, 10 }, { 10, 2 } } };
        otherPane->presentedLetters = { { { 0, 2 }, { 2, 10 } } };
        focusedBeforeHover->presentedGridSize = otherPane->presentedGridSize = { 2, 1 };
        focusedBeforeHover->presentedCellPixels = otherPane->presentedCellPixels = { 12, 20 };
        int inactiveRow = -1, inactiveColumn = -1, focusedRow = -1, focusedColumn = -1;
        cellAtPanePoint(*otherPane, 3.0 / app().scale, 1.0 / app().scale, inactiveRow, inactiveColumn);
        cellAtPanePoint(*focusedBeforeHover, 3.0 / app().scale, 1.0 / app().scale, focusedRow, focusedColumn);
        expect(inactiveRow == 0 && inactiveColumn == 1 && focusedRow == 0 && focusedColumn == 0,
            "each pane hit-tests its displayed proportional letters independently of focus and the last renderer");
        expect(std::abs(xInCellsAtPanePoint(*otherPane, 3.0 / app().scale, 1.0 / app().scale, 0) - 1.1) < 1e-6,
            "inactive-pane insertion fractions follow the displayed letter advance");
        focusedBeforeHover->presentedLetters = std::move(previousLetters);
        focusedBeforeHover->presentedGridSize = previousGrid;
        focusedBeforeHover->presentedCellPixels = previousCell;
        g_object_unref(otherPane->picture);
        otherPane->picture = nullptr;
        app().panes.pop_back();
        app().rasterContext.setFrameHoverLink({});
        app().isHoverPointKnown = false;
        app().focusedPicture = nullptr;
        g_object_unref(picture);
    }
    // A declared connection to a host waits for Ctrl.
    Ubiquitty::processBytes(term, "\r\n\x1b]8;;ssh://build.example\x1b\\SSH\x1b]8;;\x1b\\");
    expect(linkDispatchAtCell(2, 1, plain, 1).action == LocalLinkAction::Refuse, "a plain click leaves a declared ssh link alone");
    expect(linkDispatchAtCell(2, 1, GDK_CONTROL_MASK, 1).target == "ssh://build.example", "Ctrl opens it");

    // Real files, so the stat and the content type are the ones a click reads.
    GError* error = nullptr;
    gchar* scratch = g_dir_make_tmp("ubq-smoke-link-XXXXXX", &error);
    if (scratch == nullptr) {
        g_printerr("smoke-link: no scratch directory: %s\n", error != nullptr ? error->message : "unknown");
        g_clear_error(&error);
        g_print("smoke-link: FAIL\n");
        return 1;
    }
    std::array<char, PATH_MAX> canonicalScratch {};
    const bool hasCanonicalScratch = realpath(scratch, canonicalScratch.data()) != nullptr;
    const std::string directory = hasCanonicalScratch ? canonicalScratch.data() : scratch;
    const auto writeFile = [&](const char* name, const char* contents, mode_t mode) {
        const std::string path = directory + "/" + name;
        g_file_set_contents(path.c_str(), contents, -1, nullptr);
        chmod(path.c_str(), mode);
        return path;
    };
    const auto uriFor = [](const std::string& path) {
        gchar* uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
        std::string result = uri != nullptr ? uri : "";
        g_free(uri);
        return result;
    };
    const std::string notes = writeFile("notes.txt", "notes\n", 0644);
    const std::string runnable = writeFile("run.txt", "notes\n", 0755);
    const std::string launcher = writeFile("launch", "#!/bin/sh\necho launched\n", 0755);
    const std::string entry = writeFile("tool.desktop", "[Desktop Entry]\nType=Application\nExec=true\n", 0644);
    const std::string folder = directory + "/folder";
    const std::string disguise = directory + "/innocent.txt";
    const std::string pipe = directory + "/pipe.txt";
    const bool isScratchReady = hasCanonicalScratch && mkdir(folder.c_str(), 0755) == 0
        && symlink(launcher.c_str(), disguise.c_str()) == 0 && mkfifo(pipe.c_str(), 0644) == 0;
    expect(isScratchReady, "the scratch files are in place");

    // Exercise the scanner and click adapter together: a detected path is
    // literal text, whereas an OSC 8 target is already a URI. The file policy
    // below must receive a native file URI for either source.
    const auto dispatchPrinted = [&](const std::string& printed) {
        Ubiquitty::processBytes(term, "\033[2J\033[H" + printed);
        return linkDispatchAtCell(0, 0, GDK_CONTROL_MASK, 1);
    };
    const auto declaredFile = [&](const std::string& path) {
        return "\033]8;;" + uriFor(path) + "\033\\file\033]8;;\033\\";
    };
    expect(!activePane()->session->isFilesystemLocal(), "a passive session has no local-filesystem provenance");
    expect(dispatchPrinted(notes).action == LocalLinkAction::Refuse,
        "unknown filesystem provenance refuses a detected client-local path");
    expect(dispatchPrinted(declaredFile(notes)).action == LocalLinkAction::Refuse,
        "unknown filesystem provenance refuses a declared client-local file URI");
    expect(dispatchPrinted("https://example.com").target == "https://example.com",
        "unknown filesystem provenance leaves an external URL openable");
    const bool didLaunchLocalPTY = activePane()->session->launchShellCommand("while IFS= read -r line; do :; done");
    expect(didLaunchLocalPTY && activePane()->session->isFilesystemLocal(), "a launched local PTY establishes filesystem provenance");
    const auto reportDirectory = [&](const std::string& path) {
        Ubiquitty::processBytes(term, "\033]7;" + uriFor(path) + "\007");
    };
    reportDirectory(directory);
    expect(dispatchPrinted(notes).target == uriFor(notes), "Ctrl-click opens a detected absolute path");
    expect(dispatchPrinted("./notes.txt").target == uriFor(notes), "Ctrl-click resolves a detected path in the pane's directory");
    expect(dispatchPrinted("./notes.txt:12:5").target == uriFor(notes),
        "the shared scanner leaves a colon line suffix outside its literal path");
    const std::string nestedNotes = writeFile("folder/notes.txt", "nested notes\n", 0644);
    reportDirectory(folder);
    expect(dispatchPrinted("./notes.txt").target == uriFor(nestedNotes), "a changed pane directory changes a relative click target");
    const char* home = g_get_home_dir();
    const std::string homeRelative = home ? std::filesystem::path(notes).lexically_relative(home).generic_string() : std::string {};
    expect(!homeRelative.empty() && dispatchPrinted("~/" + homeRelative).target == uriFor(notes),
        "Ctrl-click expands a detected tilde path through the shared resolver");
    expect(dispatchPrinted("./missing.txt").action == LocalLinkAction::Refuse, "a missing detected file remains refused");
    const std::string spacedNotes = writeFile("my notes.txt", "spaced notes\n", 0644);
    expect(dispatchPrinted(declaredFile(spacedNotes)).target == uriFor(spacedNotes), "a declared file URI preserves native space encoding");

    const LinkDispatch document = linkDispatchForURI(uriFor(notes));
    expect(document.action == LocalLinkAction::Open && document.target == uriFor(notes), "a document opens");
    expect(linkDispatchForURI(uriFor(folder)).action == LocalLinkAction::Open, "a directory opens");
    const LinkDispatch strayBit = linkDispatchForURI(uriFor(runnable));
    expect(strayBit.action == LocalLinkAction::Open && strayBit.target == uriFor(runnable),
        "a stray execute bit on a file GIO types as text does not make it reveal-only");
    const LinkDispatch executable = linkDispatchForURI(uriFor(launcher));
    expect(executable.action == LocalLinkAction::Reveal && executable.target == launcher, "a script with no extension is revealed");
    expect(linkDispatchForURI(uriFor(entry)).action == LocalLinkAction::Reveal, "a desktop entry is revealed");
    const LinkDispatch followed = linkDispatchForURI(uriFor(disguise));
    expect(followed.action == LocalLinkAction::Reveal && followed.target == launcher, "a link is judged by what it points at");
    expect(linkDispatchForURI(uriFor(pipe)).action == LocalLinkAction::Refuse, "a pipe is refused");
    expect(linkDispatchForURI(uriFor(directory + "/missing.txt")).action == LocalLinkAction::Refuse, "a missing path is refused");
    expect(linkDispatchForURI(uriFor(notes) + "?open").action == LocalLinkAction::Refuse, "a query is refused");
    expect(linkDispatchForURI(uriFor(notes) + "#run").action == LocalLinkAction::Refuse, "a fragment is refused");
    const std::string own = "file://" + Ubiquitty::PAL::systemHostName() + notes;
    expect(linkDispatchForURI(own).action == LocalLinkAction::Open, "this machine's name in the authority opens");
    expect(linkDispatchForURI("file://elsewhere.invalid" + notes).action == LocalLinkAction::Refuse, "another machine's name is refused");
    expect(linkDispatchForURI("https://example.com/\xE2\x80\xAEtxt.exe").action == LocalLinkAction::Refuse, "a hidden character is refused");
    expect(linkDispatchForURI("javascript:alert(1)").action == LocalLinkAction::Refuse, "an unlisted scheme is refused");
    // A joiner spells a name rather than hiding part of one: an emoji ZWJ
    // file name, linked raw as a program prints it, opens.
    const std::string joined = writeFile("\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x92\xBB notes.txt", "notes\n", 0644);
    const LinkDispatch joinedDispatch = linkDispatchForURI("file://" + joined);
    expect(joinedDispatch.action == LocalLinkAction::Open && joinedDispatch.target == uriFor(joined), "an emoji ZWJ file name opens");
    // U+0645 U+06CC U+200C U+062E U+0648 U+0627 U+0647 U+0645, a Persian word.
    expect(linkDispatchForURI("https://fa.wikipedia.org/wiki/\xD9\x85\xDB\x8C\xE2\x80\x8C\xD8\xAE\xD9\x88\xD8\xA7\xD9\x87\xD9\x85").action
            == LocalLinkAction::Open,
        "a Persian page written with a non-joiner opens");

    // Ordinary files the display-only rule reaches: names a repository holds
    // with no extension, video, a name that is Latin-1 rather than UTF-8, and
    // the file:/path form Java writes.
    std::vector<std::string> ordinary;
    for (const char* name : { "README", "Makefile", ".gitignore", ".env", "clip.mp4", "caf\xE9.txt" })
        ordinary.push_back(writeFile(name, "plain\n", 0644));
    for (const std::string& path : ordinary) {
        const LinkDispatch dispatch = linkDispatchForURI(uriFor(path));
        const std::string what = "an ordinary " + Ubiquitty::Attributes::LinkRun::escapedDeceptiveLinkCharacters(path.substr(directory.size() + 1)) + " opens";
        expect(dispatch.action == LocalLinkAction::Open && dispatch.target == uriFor(path), what.c_str());
    }
    // Audio is revealed: the rule is Core's, and a Mac's handler for it
    // imports what it opens into the reader's library.
    const std::string song = writeFile("song.mp3", "plain\n", 0644);
    expect(linkDispatchForURI(uriFor(song)).action == LocalLinkAction::Reveal, "an mp3 is revealed");
    expect(linkDispatchForURI("file:" + notes).target == uriFor(notes), "file:/path with no authority opens");
    // A page is revealed wherever its name came from: GIO reads a .conf
    // holding HTML as text/html, and the browser that type opens in runs it.
    const std::string page = writeFile("report.conf", "<html><script>alert(1)</script></html>\n", 0644);
    const std::string feed = writeFile("pom.xml", "<project/>\n", 0644);
    expect(linkDispatchForURI(uriFor(page)).action == LocalLinkAction::Reveal, "HTML under a configuration name is revealed");
    expect(linkDispatchForURI(uriFor(feed)).action == LocalLinkAction::Reveal, "XML, which a browser runs as XHTML, is revealed");
    // The volume rule: a scratch directory keeps permissions, and the EFI
    // system partition, where a machine mounts one, is FAT and keeps none.
    expect(!isOnVolumeWithoutPermissions(directory.c_str()), "the scratch volume keeps permissions");
    struct statfs efi {};
    if (statfs("/boot/efi", &efi) == 0 && efi.f_type == MSDOS_SUPER_MAGIC)
        expect(isOnVolumeWithoutPermissions("/boot/efi"), "a FAT volume keeps none");

    // A link that names a line. With no line handler it meets the ordinary
    // rule; with one, the handler is handed the canonical path the click
    // judged and the line, never the URI as printed.
    const LinkDispatch plainLine = linkDispatchForURI(uriFor(notes) + "#L12-L20");
    expect(plainLine.action == LocalLinkAction::Open && plainLine.target == uriFor(notes) && plainLine.lineHandler.empty(),
        "a line link opens the file when no line handler is configured");
    const std::string script = writeFile("build.sh", "#!/bin/sh\necho built\n", 0755);
    const std::string scriptLink = directory + "/latest.sh";
    const std::string recorded = directory + "/received";
    const bool isScriptLinked = symlink(script.c_str(), scriptLink.c_str()) == 0;
    (void)Ubiquitty::Preferences::configure("[links]\nline_handler = \"/bin/ln -s {path}:{line}:{column} " + recorded + "\"\n",
        Ubiquitty::Preferences::ParseMode::Strict);
    const LinkDispatch atLine = linkDispatchForURI(uriFor(scriptLink) + "#12:5");
    const Ubiquitty::Attributes::LinkRun::HandlerArgv expectedHandler { "/bin/ln", "-s", script + ":12:5", recorded };
    expect(isScriptLinked && atLine.lineHandler == expectedHandler && atLine.action == LocalLinkAction::Reveal && atLine.target == script,
        "a script a search found goes to the line handler at its canonical path, which the opener would only reveal");
    expect(linkDispatchForURI(uriFor(folder) + "#12").lineHandler.empty(), "a line names nothing in a directory");
    expect(linkDispatchForURI(uriFor(script) + "#run").action == LocalLinkAction::Refuse, "a fragment that is not a line is refused");
    // The handler runs through no shell, and `ln -s` records the one argument
    // it was handed as the link's destination.
    expect(spawnWithoutShell(atLine.lineHandler, "line handler"), "the line handler starts");
    std::array<char, PATH_MAX> received {};
    for (int attempt = 0; attempt < 100 && readlink(recorded.c_str(), received.data(), received.size() - 1) < 0; ++attempt)
        g_usleep(20'000);
    expect(std::string(received.data()) == script + ":12:5", "the line handler received the checked path and the line as one argument");
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);

    for (const std::string& path : { notes, runnable, launcher, entry, disguise, pipe, joined, script, scriptLink, recorded, page, feed, nestedNotes, spacedNotes })
        unlink(path.c_str());
    for (const std::string& path : ordinary)
        unlink(path.c_str());
    rmdir(folder.c_str());
    rmdir(scratch);
    g_free(scratch);

    Ubiquitty::processBytes(term, "\033[2J\033[H");
    const std::string wrappedURL = "https://example.com/" + std::string(static_cast<std::size_t>(startupColumns), 'a');
    Ubiquitty::processBytes(term, wrappedURL);
    const auto superWrapped = linkDispatchAtCell(1, 1, GDK_SUPER_MASK, 1);
    expect(superWrapped.action == LocalLinkAction::Refuse && superWrapped.target.empty(),
        "Super-click leaves a soft-wrapped URL to the window manager");
    expect(linkDispatchAtCell(1, 1, GDK_CONTROL_MASK, 1).target == wrappedURL,
        "Ctrl-click resolves the same wrapped URL through Core");

    if (didLaunchLocalPTY)
        activePane()->session->close();
    g_print("smoke-link: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
