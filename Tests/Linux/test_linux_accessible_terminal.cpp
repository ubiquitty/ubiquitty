// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"
#include "Harness.h"
#include "Platform/Linux/AccessibleTerminal.h"

#include <limits>
#include <string>

namespace {

struct WidgetOwner {
    GtkWidget* widget = Ubiquitty::Linux::Accessibility::createTerminal();
    WidgetOwner() { g_object_ref_sink(widget); }
    ~WidgetOwner() { g_object_unref(widget); }
};

std::string textOf(GBytes* bytes)
{
    gsize size = 0;
    const auto* data = static_cast<const char*>(g_bytes_get_data(bytes, &size));
    std::string text(data ? data : "", size);
    g_bytes_unref(bytes);
    return text;
}

TEST(accessibleTerminalAnswersTextAndCoordinatesWithoutATextView)
{
    REQUIRE(gtk_init_check());
    WidgetOwner owner;
    CHECK(!GTK_IS_TEXT_VIEW(owner.widget));
    CHECK(GTK_IS_ACCESSIBLE_TEXT(owner.widget));
    CHECK_EQ(gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(owner.widget)), GTK_ACCESSIBLE_ROLE_TERMINAL);
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 2, 8, Ubiquitty::Modes::ReflowMode::Fixed);
    Ubiquitty::processBytes(&terminal, "A\xF0\x9F\x98\x80"
                                       "e\xCC\x81");
    Ubiquitty::Linux::Accessibility::updateTerminal(owner.widget,
        Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, nullptr), { 8, 12 }, { 10, 19 });
    auto* accessible = GTK_ACCESSIBLE_TEXT(owner.widget);
    auto* interface = GTK_ACCESSIBLE_TEXT_GET_IFACE(accessible);
    CHECK(textOf(interface->get_contents(accessible, 1, 2)) == "\xF0\x9F\x98\x80");
    CHECK(textOf(interface->get_contents(accessible, 0, std::numeric_limits<unsigned int>::max())) == "A\xF0\x9F\x98\x80"
                                                                                                      "e\xCC\x81\n");
    CHECK_EQ(interface->get_caret_position(accessible), 4u);
    unsigned int start = 0, end = 0;
    CHECK(textOf(interface->get_contents_at(accessible, 3, GTK_ACCESSIBLE_TEXT_GRANULARITY_CHARACTER, &start, &end)) == "e\xCC\x81");
    CHECK_EQ(start, 2u);
    CHECK_EQ(end, 4u);
    graphene_rect_t extents;
    REQUIRE(interface->get_extents(accessible, 1, 2, &extents));
    CHECK_EQ(extents.origin.x, 18.0f);
    CHECK_EQ(extents.origin.y, 12.0f);
    CHECK_EQ(extents.size.width, 20.0f);
    CHECK_EQ(extents.size.height, 19.0f);
    const graphene_point_t continuation { 35.0f, 15.0f };
    unsigned int offset = 99;
    REQUIRE(interface->get_offset(accessible, &continuation, &offset));
    CHECK_EQ(offset, 1u);
    CHECK(textOf(interface->get_contents(accessible, 9000, 0)).empty());
}

TEST(accessibleQueriesSeeTheNewestTextWhileNotificationsAreCoalesced)
{
    REQUIRE(gtk_init_check());
    WidgetOwner owner;
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 2, 8, Ubiquitty::Modes::ReflowMode::Fixed);
    for (const char* text : { "before", "after" }) {
        Ubiquitty::processBytes(&terminal, "\x1b[H\x1b[2J");
        Ubiquitty::processBytes(&terminal, text);
        Ubiquitty::Linux::Accessibility::updateTerminal(owner.widget,
            Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, nullptr), {}, { 10, 19 });
    }
    auto* accessible = GTK_ACCESSIBLE_TEXT(owner.widget);
    auto* interface = GTK_ACCESSIBLE_TEXT_GET_IFACE(accessible);
    CHECK(textOf(interface->get_contents(accessible, 0, std::numeric_limits<unsigned int>::max())) == "after\n");
    gsize ranges = 99;
    GtkAccessibleTextRange* selection = nullptr;
    CHECK(!interface->get_selection(accessible, &ranges, &selection));
    CHECK_EQ(ranges, 0u);
    CHECK(selection == nullptr);
    // Disposal removes a pending trailing notification before its context dies.
}

} // namespace

UBIQUITTY_TEST_MAIN()
