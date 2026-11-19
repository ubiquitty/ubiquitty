// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Presentation/WindowTitleContent.h"

#include "Core/Title/Directory.h"

#include <utility>

namespace Ubiquitty::Linux::Presentation {

WindowTitleContent windowTitleContent(const App::PaneTitleFacts& pane, App::TitleViewerFacts viewer,
    const Preferences::Effective::TitleComposition& composition)
{
    WindowTitleContent content;
    const bool showsDirectory = composition.showsDirectory && !pane.currentDirectory.empty() && !App::isDirectoryHidden(pane, composition);
    if (showsDirectory)
        content.directory = Title::titleDirectorySegment(pane.currentDirectory, pane.homeDirectory, Title::PathFormat::FullPath);
    if (composition.showsProgramStatus && !pane.end.didEnd)
        content.status = pane.programStatus;

    // The header draws the directory and the status on their own line, so the
    // top line is composed without them; every other part stays the reader's.
    Preferences::Effective::TitleComposition topLine = composition;
    topLine.showsDirectory = false;
    topLine.showsProgramStatus = false;
    viewer.windowTitleForm = App::WindowTitleForm::PlainText;
    const std::string fallbackName = viewer.fallbackName;
    const App::ComposedTitle composed = App::composeTitle(pane, std::move(viewer), topLine, Session::TitleSurface::Window);
    content.title = composed.title;
    if (composed.usesFallbackName && showsDirectory)
        content.title = Title::titleDirectorySegment(pane.currentDirectory, pane.homeDirectory, Title::PathFormat::BasenameOnly);
    if (content.title.empty())
        content.title = fallbackName;
    return content;
}

} // namespace Ubiquitty::Linux::Presentation
