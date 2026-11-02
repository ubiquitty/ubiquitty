-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- Memory-only fixture models. No bridge, host, socket or native adapter calls.
local sync, wire = require("ubiquitty_sync"), require("ubiquitty_sync.wire")
local M = {}
function M.little(value, count)
    local out = {}
    for index = 1, count do out[index], value = string.char(value % 256), math.floor(value / 256) end
    return table.concat(out)
end
function M.varint(value)
    if value < 128 then return string.char(value) end
    return string.char(value % 128 + 128) .. M.varint(math.floor(value / 128))
end
function M.text(value) return M.varint(#value) .. value end
function M.welcome(role, admission, question, session, tail)
    return M.little(wire.wire_version, 2) .. "\0" .. string.rep("\0", 32)
        .. string.rep("h", 16) .. string.rep("a", 16) .. string.rep("s", 16)
        .. string.char(role or wire.role.owner, wire.admission_target.session)
        .. M.little(9, 4) .. M.little(0, 4) .. M.little(1, 8) .. M.text("fixture.sock") .. "\0\0" .. string.rep("\0", 8)
        .. string.char(admission or wire.attachment_admission.granted)
        .. M.little(question or 0, 4) .. M.little(session or 0, 4) .. M.text("fixture")
        .. M.little(8, 2) .. M.little(16 * 1024 * 1024, 4) .. M.little(8, 2) .. "\0" .. M.little(42, 8)
        .. (tail or "\0\0\0")
end
function M.request()
    return { columns = 80, rows = 24, client_instance = string.rep("c", 16), target = wire.admission_target.session,
        session_id = 0, workspace_id = 0, expected_daemon = 0, workspace_name = "", ends_when_detached = false }
end
function M.connection(buffer, role)
    local value = sync.new_connection(buffer)
    value.admission_request, value.welcome = M.request(), sync.read_welcome(M.welcome(role))
    value.welcomed = true
    return value
end
return M
