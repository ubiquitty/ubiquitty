// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Codec/JSON.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace Ubiquitty::Session {

/// A live same-user daemon found by the host, with its own attach executable.
/// Numeric workspace and session IDs are meaningful only within this endpoint.
struct HostInstanceInfo {
    std::string socketName;
    std::string executable;
    std::uint64_t startedUnixSeconds = 0;
};

/// An owned endpoint list for language bridges; never borrows a changing tree.
struct HostInstanceList {
    std::vector<HostInstanceInfo> entries;
    [[nodiscard]] std::size_t count() const { return entries.size(); }
    [[nodiscard]] HostInstanceInfo instanceAt(std::size_t index) const { return index < entries.size() ? entries[index] : HostInstanceInfo {}; }
};

inline constexpr std::size_t maxDiscoveredHostInstances = 32;

/// Checks endpoint names before any frontend uses them in a transport command.
[[nodiscard]] inline bool isValidHostInstance(const HostInstanceInfo& instance)
{
    const auto& socket = instance.socketName;
    return socket.size() == 26 && socket.starts_with("host-") && socket.ends_with(".sock")
        && std::ranges::all_of(socket.substr(5, 16), [](char digit) { return (digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f'); })
        && !instance.executable.empty() && instance.executable.size() <= 4096 && instance.executable.front() == '/'
        && instance.executable.ends_with("/ubiquitty-host")
        && std::ranges::none_of(instance.executable, [](unsigned char byte) { return byte < 32 || byte == 127; });
}

/// Reads only complete bounded endpoint records, ignoring duplicate socket names.
[[nodiscard]] inline std::vector<HostInstanceInfo> readHostInstances(const Codec::JSON::Value* value)
{
    std::vector<HostInstanceInfo> result;
    if (!value || !value->isArray() || value->items().size() > maxDiscoveredHostInstances)
        return result;
    for (const auto& item : value->items()) {
        HostInstanceInfo instance { item.stringOr("socket"), item.stringOr("executable"), 0 };
        const auto started = item.numberOr("startedUnixSeconds");
        if (!(started >= 0 && started <= 9007199254740991.0) || std::floor(started) != started || !isValidHostInstance(instance))
            continue;
        instance.startedUnixSeconds = static_cast<std::uint64_t>(started);
        if (std::ranges::find(result, instance.socketName, &HostInstanceInfo::socketName) == result.end())
            result.push_back(std::move(instance));
    }
    return result;
}

} // namespace Ubiquitty::Session
