// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/Alerts.h"

#include <adwaita.h>

#include <memory>
#include <string_view>

namespace Ubiquitty::Linux::GTK {

namespace {

constexpr const char* declineResponse = "decline";
constexpr const char* acceptResponse = "accept";

struct Answer {
    std::function<void()> onAccept;
    std::function<void()> onDecline;
    bool isAnswered = false; // bool-ok: names the one state it reports
};

void onResponse(AdwAlertDialog*, const char* response, gpointer data)
{
    auto& answer = *static_cast<Answer*>(data);
    if (answer.isAnswered)
        return;
    answer.isAnswered = true;
    if (std::string_view(response) == acceptResponse) {
        if (answer.onAccept)
            answer.onAccept();
    } else if (answer.onDecline) {
        answer.onDecline();
    }
}

void releaseAnswer(gpointer data, GClosure*)
{
    std::unique_ptr<Answer> answer(static_cast<Answer*>(data));
    if (!answer->isAnswered && answer->onDecline)
        answer->onDecline();
}

} // namespace

void ask(GtkWidget* parent, const AlertQuestion& question, std::function<void()> onAccept, std::function<void()> onDecline)
{
    AdwDialog* dialog = adw_alert_dialog_new(question.heading.c_str(), question.body.c_str());
    AdwAlertDialog* alert = ADW_ALERT_DIALOG(dialog);
    adw_alert_dialog_add_response(alert, declineResponse, question.declineLabel.c_str());
    adw_alert_dialog_add_response(alert, acceptResponse, question.acceptLabel.c_str());
    const bool isDestructive = question.acceptStyle == AcceptStyle::Destructive;
    adw_alert_dialog_set_response_appearance(alert, acceptResponse, isDestructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(alert, question.isAcceptTheDefault && !isDestructive ? acceptResponse : declineResponse);
    adw_alert_dialog_set_close_response(alert, declineResponse);
    if (!question.preview.empty()) {
        GtkWidget* text = gtk_text_view_new();
        gtk_text_view_set_editable(GTK_TEXT_VIEW(text), FALSE);
        gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(text), FALSE);
        gtk_text_view_set_monospace(GTK_TEXT_VIEW(text), TRUE);
        gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text), GTK_WRAP_CHAR);
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(text)), question.preview.c_str(), static_cast<int>(question.preview.size()));
        GtkWidget* scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), text);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 120);
        gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 240);
        gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
        gtk_widget_add_css_class(scroll, "card");
        adw_alert_dialog_set_extra_child(alert, scroll);
    }
    auto answer = std::make_unique<Answer>(Answer { std::move(onAccept), std::move(onDecline) });
    g_signal_connect_data(dialog, "response", G_CALLBACK(onResponse), answer.release(), releaseAnswer, G_CONNECT_DEFAULT);
    adw_dialog_present(dialog, parent);
}

void tell(GtkWidget* parent, const std::string& heading, const std::string& body)
{
    AdwDialog* dialog = adw_alert_dialog_new(heading.c_str(), body.c_str());
    adw_alert_dialog_add_response(ADW_ALERT_DIALOG(dialog), "ok", "_OK");
    adw_dialog_present(dialog, parent);
}

bool isShowingDialog(GtkWidget* window)
{
    return window && ADW_IS_APPLICATION_WINDOW(window) && adw_application_window_get_visible_dialog(ADW_APPLICATION_WINDOW(window));
}

} // namespace Ubiquitty::Linux::GTK
