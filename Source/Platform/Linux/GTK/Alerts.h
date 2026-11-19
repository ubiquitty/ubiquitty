// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <gtk/gtk.h>

#include <cstdint>
#include <functional>
#include <string>

namespace Ubiquitty::Linux::GTK {

/// How the button that accepts a question is drawn.
enum class AcceptStyle : std::uint8_t {
    /// The action the reader most likely wants, drawn as libadwaita's
    /// suggested response.
    Suggested,
    /// An action that destroys something, drawn as libadwaita's destructive
    /// response. It is never the default.
    Destructive,
};

/// A question a window asks before it does something the reader should agree to.
struct AlertQuestion {
    std::string heading {};
    std::string body {};
    /// The button that agrees.
    std::string acceptLabel {};
    AcceptStyle acceptStyle = AcceptStyle::Suggested;
    /// The button that declines, which Escape and closing the alert also pick.
    std::string declineLabel = "_Cancel";
    /// Whether Return picks the accepting button. Never for a destructive one.
    bool isAcceptTheDefault = false; // bool-ok: names the one choice it makes
    /// Text shown in a monospace, scrolling preview under the body — what a
    /// paste would type, say; empty for none. The caller bounds it.
    std::string preview {};
};

/// Asks a question as a libadwaita alert over a window.
///
/// Exactly one of the callbacks runs: the decline one also when the alert goes
/// away unanswered, so whatever waits on the answer is always told.
///
/// - Parameters:
///   - parent: The window the alert belongs to.
///   - question: What is asked.
///   - onAccept: Runs if the reader agrees.
///   - onDecline: Runs otherwise; may be empty.
void ask(GtkWidget* parent, const AlertQuestion& question, std::function<void()> onAccept, std::function<void()> onDecline = {});

/// Tells the reader something that needs no answer, with one OK button.
///
/// - Parameters:
///   - parent: The window the alert belongs to.
///   - heading: What happened.
///   - body: The detail.
void tell(GtkWidget* parent, const std::string& heading, const std::string& body);

/// Whether a window shows an alert (or any libadwaita dialog) now.
[[nodiscard]] bool isShowingDialog(GtkWidget* window);

} // namespace Ubiquitty::Linux::GTK
