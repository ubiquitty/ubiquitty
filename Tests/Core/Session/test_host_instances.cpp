// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Core/Session/HostInstanceInfo.h"
#include "Harness.h"

TEST(discoveredHostsRejectUnboundedMalformedAndDuplicateEndpoints)
{
    using namespace Ubiquitty;
    using Codec::JSON::Value;
    const auto endpoint = [](std::string socket, std::string executable, double time) {
        auto value = Value::object();
        value.set("socket", Value::string(std::move(socket)));
        value.set("executable", Value::string(std::move(executable)));
        value.set("startedUnixSeconds", Value::number(time));
        return value;
    };
    auto list = Value::array();
    list.push(endpoint("host-0123456789abcdef.sock", "/tmp/ubiquitty-host", 7));
    list.push(endpoint("host-0123456789abcdef.sock", "/tmp/another/ubiquitty-host", 8));
    list.push(endpoint("../host-0123456789abcdef.sock", "/tmp/ubiquitty-host", 7));
    list.push(endpoint("host-1111111111111111.sock", "relative/ubiquitty-host", 7));
    list.push(endpoint("host-2222222222222222.sock", "/tmp/ubiquitty-host", 7.5));
    const auto read = Session::readHostInstances(&list);
    CHECK_EQ(read.size(), 1u);
    CHECK(read.front().executable == "/tmp/ubiquitty-host");
    CHECK_EQ(read.front().startedUnixSeconds, 7u);
    for (std::size_t i = list.items().size(); i <= Session::maxDiscoveredHostInstances; ++i)
        list.push(Value::object());
    CHECK(Session::readHostInstances(&list).empty());
}

UBIQUITTY_TEST_MAIN()
