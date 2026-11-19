// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_window_chrome.cpp — the GTK-free policy under the Linux window
// chrome: which symbol each program status is drawn with, and how a pane's
// title facts split over a GNOME header bar's title and subtitle.

#include "Platform/Linux/Presentation/ChromeContent.h"
#include "Platform/Linux/Presentation/StatusSymbol.h"
#include "Platform/Linux/Presentation/WindowTitleContent.h"

#include <string>

using namespace Ubiquitty;
using namespace Ubiquitty::Linux::Presentation;
using Preferences::Effective::TitleComposition;

namespace {

TitleComposition showing(bool directory, bool appTitle, bool process, bool programStatus) // bool-ok: a fixture, each flag named at its one definition
{
    return TitleComposition {
        .showsDirectory = directory,
        .showsDirectoryFullPath = false,
        .showsAppTitle = appTitle,
        .showsProcess = process,
        .showsProcessArguments = false,
        .showsShellCommand = false,
        .showsTTYName = false,
        .showsProfileName = false,
        .showsDimensions = false,
        .showsProgramStatus = programStatus,
        .baseTitle = {},
        .directoryHiddenFor = {},
        .hidesDirectoryInFullScreen = false,
    };
}

App::PaneTitleFacts agentPane()
{
    App::PaneTitleFacts pane;
    pane.programTitle = "Fix the parser";
    pane.currentDirectory = "/home/x/src/proj";
    pane.homeDirectory = "/home/x";
    pane.processChain = "claude";
    pane.programStatus = "Claude Code: Working";
    return pane;
}

App::TitleViewerFacts viewer()
{
    App::TitleViewerFacts facts;
    facts.fallbackName = "Ubiquitty";
    return facts;
}

} // namespace

TEST(theTitleLeavesTheDirectoryAndStatusToTheSubtitle)
{
    const WindowTitleContent content = windowTitleContent(agentPane(), viewer(), showing(true, true, false, true));
    CHECK_MSG(content.title == "Fix the parser", content.title.c_str());
    CHECK_MSG(content.directory == "~/src/proj", content.directory.c_str());
    CHECK_MSG(content.status == "Claude Code: Working", content.status.c_str());
}

TEST(aPromptWithNoTitleNamesItsFolderAboveItsPath)
{
    App::PaneTitleFacts pane = agentPane();
    pane.programTitle.clear();
    pane.programStatus.clear();
    const WindowTitleContent content = windowTitleContent(pane, viewer(), showing(true, true, false, true));
    CHECK_MSG(content.title == "proj", content.title.c_str());
    CHECK_MSG(content.directory == "~/src/proj", content.directory.c_str());
    CHECK(content.status.empty());
}

TEST(theCompositionStillDecidesWhatShows)
{
    const WindowTitleContent content = windowTitleContent(agentPane(), viewer(), showing(false, true, false, false));
    CHECK(content.directory.empty());
    CHECK(content.status.empty());
    CHECK_MSG(content.title == "Fix the parser", content.title.c_str());
}

TEST(aPaneWithNothingToSayFallsBackToTheAppName)
{
    App::PaneTitleFacts pane;
    const WindowTitleContent content = windowTitleContent(pane, viewer(), showing(true, true, false, true));
    CHECK_MSG(content.title == "Ubiquitty", content.title.c_str());
    CHECK(content.directory.empty());
}

TEST(anEndedSessionShowsNoStatus)
{
    App::PaneTitleFacts pane = agentPane();
    pane.end.didEnd = true;
    const WindowTitleContent content = windowTitleContent(pane, viewer(), showing(true, true, false, true));
    CHECK(content.status.empty());
}

TEST(everyStatusKindButNoneDrawsAMark)
{
    CHECK(!statusSymbol(App::StatusKind::None, OSC::ProgramBlockKind::None));
    for (const App::StatusKind kind : { App::StatusKind::Idle, App::StatusKind::Running, App::StatusKind::Working, App::StatusKind::Done,
             App::StatusKind::Attention, App::StatusKind::Blocked, App::StatusKind::Failed }) {
        const auto symbol = statusSymbol(kind, OSC::ProgramBlockKind::None);
        CHECK(symbol.has_value());
        // A mark is either the toolkit spinner or a named symbolic icon.
        CHECK(symbol->isSpinner == symbol->iconName.empty());
        CHECK(symbol->isSpinner || symbol->iconName.ends_with("-symbolic"));
        CHECK(!symbol->spokenName.empty());
    }
}

TEST(workInFlightIsTheToolkitSpinner)
{
    CHECK(statusSymbol(App::StatusKind::Working, OSC::ProgramBlockKind::None)->isSpinner);
}

TEST(statusesWearTheThemesStatusColours)
{
    CHECK(statusSymbol(App::StatusKind::Failed, OSC::ProgramBlockKind::None)->tone == StatusTone::Error);
    CHECK(statusSymbol(App::StatusKind::Blocked, OSC::ProgramBlockKind::None)->tone == StatusTone::Warning);
    CHECK(statusSymbol(App::StatusKind::Done, OSC::ProgramBlockKind::None)->tone == StatusTone::Success);
    CHECK(statusSymbol(App::StatusKind::Attention, OSC::ProgramBlockKind::None)->tone == StatusTone::Accent);
}

TEST(aBlockedProgramSaysWhatItWaitsFor)
{
    const auto question = statusSymbol(App::StatusKind::Blocked, OSC::ProgramBlockKind::Question);
    const auto permission = statusSymbol(App::StatusKind::Blocked, OSC::ProgramBlockKind::Permission);
    const auto auth = statusSymbol(App::StatusKind::Blocked, OSC::ProgramBlockKind::Auth);
    CHECK(question->iconName != permission->iconName);
    CHECK(permission->iconName != auth->iconName);
    CHECK(question->iconName == statusSymbol(App::StatusKind::Blocked, OSC::ProgramBlockKind::None)->iconName);
}

TEST(aProgramStatusOutranksAnUnheardBell)
{
    PaneMarks marks;
    CHECK(!marks.shownSymbol());
    marks.hasUnheardBell = true;
    CHECK(marks.shownSymbol() == bellSymbol());
    marks.status = statusSymbol(App::StatusKind::Failed, OSC::ProgramBlockKind::None);
    CHECK(marks.shownSymbol() == marks.status);
}

UBIQUITTY_TEST_MAIN()
