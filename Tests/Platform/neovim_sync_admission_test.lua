-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- Memory-only Welcome/own-consent boundaries: no bridge, buffer, socket or host.
local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(script, ":p:h")
local lua_root = here .. "/../../Source/Platform/Neovim/lua"
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path
local sync = require("ubiquitty_sync")
local wire = require("ubiquitty_sync.wire")
local fixture = dofile(here .. "/editor_wire_fixture.lua")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message)
end
local function denied(action, ...)
    check(not pcall(action, ...), "an invalid Welcome was accepted")
end
local function little(value, count)
    local bytes = {}
    for index = 1, count do bytes[index], value = string.char(value % 256), math.floor(value / 256) end
    return table.concat(bytes)
end
local function welcome(admission, question, session, tail, selection)
    selection = selection or {}
    return little(wire.wire_version, 2) .. "\0" .. string.rep("\0", 32)
        .. string.rep("h", 16) .. string.rep("a", 16) .. string.rep("\0", 16)
        .. string.char(wire.role.owner, selection.target or wire.admission_target.session)
        .. little(selection.session or 9, 4) .. little(selection.workspace or 0, 4)
        .. little(selection.daemon or 1, 8) .. "\12fixture.sock\0\0" .. little(selection.restored or 0, 8)
        .. string.char(admission) .. little(question, 4) .. little(session, 4)
        .. "\7fixture" .. little(8, 2) .. little(16 * 1024 * 1024, 4) .. little(8, 2) .. "\0" .. little(42, 8)
        .. (tail or "\0\0\0")
end
local function notify_body(kind, record)
    return string.char(kind) .. record
end
-- An unknown phase word is written as the first number past the known ones.
local function status(phase, question, session)
    return notify_body(wire.notify_kind.consent_status,
        little(question or 7, 4) .. little(session or 9, 4) .. string.char(wire.consent_status_phase[phase] or 4))
end
local attachments = notify_body(wire.notify_kind.attachments, little(4, 8) .. "\0")
local function receive(connection, kind, body, channel)
    connection.admission_request = connection.admission_request or {
        target = wire.admission_target.session, session_id = 0, workspace_id = 0, expected_daemon = 0,
    }
    sync.feed(connection, sync.sync_frame(kind, channel or 0, body))
end
local function connection()
    local value, sent = sync.new_connection(-1), {}
    value.stdin = { is_closing = function() return false end, write = function(_, bytes) sent[#sent + 1] = bytes end }
    value.facts_owed = true
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.awaiting_consent, 7, 9))
    return value, sent
end
local function sent_kind(sent, kind)
    local count = 0
    for _, bytes in ipairs(sent) do if bytes:byte(1) == kind then count = count + 1 end end
    return count
end
local notify = vim.notify
vim.notify = function() end

-- All current fields, explicit booleans, binding invariants and exact ending.
do
    local body = welcome(wire.attachment_admission.granted, 0, 0)
    check(sync.read_welcome(body).admission == wire.attachment_admission.granted, "granted admission not read")
    for cut = 0, #body - 1 do denied(sync.read_welcome, body:sub(1, cut)) end
    denied(sync.read_welcome, body .. "x")
    for _, tail in ipairs({ "\2\0\0", "\0\0\2", "\0\0\1" }) do
        denied(sync.read_welcome, welcome(wire.attachment_admission.granted, 0, 0, tail))
    end
    for _, binding in ipairs({ { wire.attachment_admission.awaiting_consent, 0, 9 },
        { wire.attachment_admission.awaiting_consent, 7, 0 }, { wire.attachment_admission.granted, 7, 0 },
        { wire.attachment_admission.granted, 0, 9 }, { 2, 7, 9 } }) do
        denied(sync.read_welcome, welcome(unpack(binding)))
    end
    local tail = "\0\1" .. string.rep("p", 16) .. string.char(wire.resume_outcome.checkpointed, 0, 0)
    check(#sync.read_welcome(welcome(wire.attachment_admission.granted, 0, 0, tail)).resumed == 1,
        "a granted Welcome lost its valid resumed pane")
    denied(sync.read_welcome, welcome(wire.attachment_admission.awaiting_consent, 7, 9, tail))
end

-- A pending Welcome is not a connected client and discloses no pane data.
for _, kind in ipairs({ sync.kind.pane_bind, sync.kind.pane_listed, sync.kind.workspace_structure,
    sync.kind.checkpoint_head, sync.kind.update, sync.kind.effect, sync.kind.result }) do
    local value, sent = connection()
    check(not value.welcomed and value.consent_phase == "awaiting-status", "pending Welcome appeared connected")
    check(sent_kind(sent, sync.kind.facts) == 0, "pending Welcome released Facts")
    receive(value, kind, "")
    check(value.protocol_failure ~= nil and value.pane == nil, "pending attachment accepted data")
    check(sent_kind(sent, sync.kind.facts) == 0, "refused pending data released Facts")
end

-- One exact Pending then Approved admits the attachment and releases Facts once.
do
    local value, sent = connection()
    receive(value, sync.kind.notify, status("pending"))
    check(value.consent_phase == "pending" and not value.welcomed, "Pending admitted a client")
    check(sent_kind(sent, sync.kind.facts) == 0, "Pending released Facts")
    receive(value, sync.kind.notify, status("approved"))
    check(value.welcomed and value.consent_phase == "approved", "exact approval did not admit")
    check(sent_kind(sent, sync.kind.facts) == 1 and not value.facts_owed, "approval did not release exactly one Facts")
    check(#value.notifies == 0, "own status leaked into general notifications")
    receive(value, sync.kind.pane_bind, "\1" .. string.rep("p", 16))
    check(value.pane == 1 and value.protocol_failure == nil, "approved attachment could not bind its pane")
    receive(value, sync.kind.notify, status("approved"))
    check(value.protocol_failure ~= nil and sent_kind(sent, sync.kind.facts) == 1, "replayed approval acted twice")
end

-- Mismatch, terminal-before-Pending, another kind, a malformed record and
-- oversize refuse.
for _, body in ipairs({ status("approved"), status("pending", 8, 9), status("pending", 7, 10), status("pending", 0, 9),
    status("unknown"), attachments, notify_body(127, ""), status("pending"):sub(1, -2), status("pending") .. "\0",
    string.rep("x", wire.max_consent_status_bytes + 1) }) do
    local value = connection()
    receive(value, sync.kind.notify, body)
    check(value.protocol_failure ~= nil and not value.welcomed and value.pane == nil, "invalid own status granted admission")
end
do
    local value = connection()
    receive(value, sync.kind.notify, status("pending"), 1)
    check(value.protocol_failure ~= nil and not value.welcomed, "pane-addressed status admitted")
    value = connection()
    receive(value, sync.kind.notify, status("pending"))
    receive(value, sync.kind.notify, status("pending"))
    check(value.protocol_failure ~= nil and not value.welcomed, "repeated Pending admitted")
end

-- Denial and expiry wait only for NoConsent; neither restores observation.
for _, phase in ipairs({ "denied", "expired" }) do
    local value = connection()
    receive(value, sync.kind.notify, status("pending"))
    receive(value, sync.kind.notify, status(phase))
    check(value.consent_phase == phase and not value.welcomed and value.pane == nil, "terminal denial granted admission")
    local reason
    for number, name in pairs(wire.bye_reasons) do if name == "NoConsent" then reason = number end end
    receive(value, sync.kind.bye, string.char(reason, 0, 0))
    check(value.bye_reason == "NoConsent" and value.protocol_failure == nil, "matching NoConsent was refused")
    check(value.consent_verdict == phase, "NoConsent erased the denied/expired verdict")
    receive(value, sync.kind.notify, status("approved"))
    check(value.transport_closed and not value.welcomed, "a status after NoConsent reopened admission")
    value = connection()
    receive(value, sync.kind.notify, status("pending"))
    receive(value, sync.kind.notify, status(phase))
    receive(value, sync.kind.bye, "\0\0\0")
    check(value.protocol_failure ~= nil and not value.welcomed, "denial accepted a different terminal Bye")
end

-- An ordinary grant cannot acquire an own question from an unsolicited Notify.
do
    local value = sync.new_connection(-1)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0))
    check(value.welcomed and value.consent_phase == nil, "ordinary grant is pending")
    receive(value, sync.kind.notify, status("pending"))
    check(value.protocol_failure ~= nil, "ordinary grant accepted unsolicited own status")
    value = sync.new_connection(-1)
    local body = welcome(wire.attachment_admission.granted, 0, 0)
    receive(value, sync.kind.welcome, body)
    receive(value, sync.kind.welcome, body)
    check(value.protocol_failure ~= nil, "duplicate Welcome was accepted")
end

-- A malformed own status after grant is refused, not kept as another kind.
for _, body in ipairs({
    status("unknown"),
    status("pending"):sub(1, -2),
    status("pending") .. "\0",
    "\128",
}) do
    local value = sync.new_connection(-1)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0))
    receive(value, sync.kind.notify, body)
    check(value.protocol_failure ~= nil and not value.welcomed, "a malformed reserved status was treated as generic")
    check(#value.notifies == 0 and value.consent_phase == nil and value.pane == nil, "malformed own status escaped or established a question")
end
do
    local value = sync.new_connection(-1)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0))
    -- A kind this client does not know is skipped by its length.
    receive(value, sync.kind.notify, notify_body(127, "opaque"))
    check(value.protocol_failure == nil and #value.notifies == 0, "an unknown Notify kind was refused or kept")
    receive(value, sync.kind.notify, attachments)
    check(value.protocol_failure == nil and value.welcomed and #value.notifies == 1
        and value.notifies[1].kind == wire.notify_kind.attachments, "an unrelated Notify was refused")
end

-- One Greet owns the exact client identity, selection and viewport.
do
    local value, sent = sync.new_connection(-1), {}
    value.columns, value.rows = 137, 43
    value.stdin = { is_closing = function() return false end, write = function(_, bytes) sent[#sent + 1] = bytes end }
    sync.send_greet(value)
    local version = little(wire.wire_version, 2)
    local body = version .. "\0" .. wire.wire_fingerprint .. value.client_instance
        .. string.char(wire.client_kind.human, wire.role.owner, wire.admission_target.session)
        .. string.rep("\0", 23) .. little(43, 2) .. little(137, 2) .. string.rep("\0", 14) .. "\1"
        .. string.rep("\0", 8) .. fixture.varint(wire.capability.echo_context + wire.capability.shows_no_questions) .. "\0"
    check(#sent == 1 and sent[1] == sync.sync_frame(sync.kind.greet, 0, body), "Greet was not the only authoritative request")
    check(value.admission_request.client_instance == value.client_instance, "Greet identity was recovered from an offset")
    local saved = fixture.request()
    saved.session_id = 9
    local expected = version .. "\0" .. wire.wire_fingerprint .. saved.client_instance
        .. string.char(wire.client_kind.human, wire.role.owner, wire.admission_target.session)
        .. little(9, 4) .. string.rep("\0", 12) .. "\0\0\0\1\0\0\0"
        .. little(24, 2) .. little(80, 2) .. string.rep("\0", 14) .. "\1"
        .. string.rep("\0", 8) .. fixture.varint(wire.capability.echo_context + wire.capability.shows_no_questions) .. "\0"
    check(sync.greet_body(saved) == expected, "saved numeric IDs did not carry attach-only")
    saved.session_id = 0x100000000
    denied(sync.greet_body, saved)
end

-- A selected owner must answer the exact fresh request, not retarget saved IDs.
for _, mismatch in ipairs({ "session_id", "workspace_id", "expected_daemon", "target" }) do
    local value = sync.new_connection(-1)
    value.admission_request = fixture.request()
    value.admission_request[mismatch] = mismatch == "target" and wire.admission_target.workspace or 8
    if mismatch == "workspace_id" then value.admission_request.target = wire.admission_target.workspace end
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil,
        mismatch == "workspace_id" and { target = wire.admission_target.workspace, workspace = 7 } or nil))
    check(value.protocol_failure ~= nil and value.welcome == nil and value.pane == nil, "Welcome changed the requested selection")
end
do
    local value = sync.new_connection(-1)
    value.admission_request = fixture.request()
    value.admission_request.session_id, value.admission_request.expected_daemon = 9, little(1, 8)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0))
    check(value.protocol_failure == nil and value.welcomed and value.session_id == 9, "exact selected owner was refused")
end

-- A workspace the host recreated from its record answers the saved reference
-- with fresh sessions under a new instance, naming the one the client pinned:
-- Core's isRestoredReferenceAnswer, and only that answer.
do
    local restored = { target = wire.admission_target.workspace, session = 5, workspace = 7, daemon = 2, restored = 1 }
    local value = sync.new_connection(-1)
    value.admission_request = fixture.request()
    value.admission_request.target, value.admission_request.workspace_id = wire.admission_target.workspace, 7
    value.admission_request.session_id, value.admission_request.expected_daemon = 9, little(1, 8)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil, restored))
    check(value.protocol_failure == nil and value.welcomed and value.session_id == 5, "restored workspace answer was refused")

    local unpinned = sync.new_connection(-1)
    unpinned.admission_request = fixture.request()
    unpinned.admission_request.target, unpinned.admission_request.workspace_id = wire.admission_target.workspace, 7
    receive(unpinned, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil, restored))
    check(unpinned.protocol_failure ~= nil and unpinned.welcome == nil, "a restored answer to an unpinned request was accepted")

    -- The restoring host lists the workspace under an id of its own when the
    -- one asked for is another workspace's there; only a restore may move it.
    local renumbered = sync.new_connection(-1)
    renumbered.admission_request = fixture.request()
    renumbered.admission_request.target, renumbered.admission_request.workspace_id = wire.admission_target.workspace, 7
    renumbered.admission_request.session_id, renumbered.admission_request.expected_daemon = 9, little(1, 8)
    receive(renumbered, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil,
        { target = wire.admission_target.workspace, session = 5, workspace = 8, daemon = 2, restored = 1 }))
    check(renumbered.protocol_failure == nil and renumbered.welcomed and renumbered.welcome.workspace_id == 8,
        "a workspace restored under the restoring host's own id was refused")
    local moved = sync.new_connection(-1)
    moved.admission_request = fixture.request()
    moved.admission_request.target, moved.admission_request.workspace_id = wire.admission_target.workspace, 7
    moved.admission_request.session_id, moved.admission_request.expected_daemon = 9, little(1, 8)
    receive(moved, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil,
        { target = wire.admission_target.workspace, session = 9, workspace = 8, daemon = 1 }))
    check(moved.protocol_failure ~= nil and moved.welcome == nil, "another workspace was accepted with no restore behind it")

    denied(sync.read_welcome, welcome(wire.attachment_admission.granted, 0, 0, nil, { restored = 1, daemon = 2 }))
    denied(sync.read_welcome, welcome(wire.attachment_admission.granted, 0, 0, nil,
        { target = wire.admission_target.workspace, session = 5, workspace = 7, daemon = 1, restored = 1 }))
end

-- Unbound targets have neither resumed pane authority nor later PaneBind.
for _, target in ipairs({ wire.admission_target.control, wire.admission_target.management }) do
    local selection = { target = target, session = 0 }
    local tail = "\0\1" .. string.rep("p", 16) .. string.char(wire.resume_outcome.checkpointed, 0, 0)
    denied(sync.read_welcome, welcome(wire.attachment_admission.granted, 0, 0, tail, selection))
    local value = sync.new_connection(-1)
    value.admission_request = fixture.request()
    value.admission_request.target = target
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0, nil, selection))
    check(value.welcomed and value.welcome.target == target, "valid unbound target refused")
    receive(value, sync.kind.pane_bind, "")
    check(value.protocol_failure ~= nil and value.pane == nil, "unbound target received pane authority")
end

-- Bye's peer presence is mandatory; peer metadata preserves exact refusal UX.
do
    local body = string.char(wire.bye_reason.version_mismatch) .. fixture.text("update host") .. "\1"
        .. little(99, 2) .. fixture.text("fixture") .. fixture.text("linux")
    local closing = sync.read_bye(body)
    check(closing.reason == wire.bye_reason.version_mismatch and closing.detail == "update host"
        and closing.peer.version == 99 and closing.peer.platform == "linux", "Bye lost its peer metadata")
    for cut = 0, #body - 1 do denied(sync.read_bye, body:sub(1, cut)) end
    denied(sync.read_bye, body .. "x")
    local value = sync.new_connection(-1)
    receive(value, sync.kind.bye, body)
    receive(value, sync.kind.welcome, welcome(wire.attachment_admission.granted, 0, 0))
    check(value.transport_closed and value.welcome == nil and not value.welcomed, "a post-Bye Welcome reopened the carrier")
end
for _, body in ipairs({ "\0\0", "\0\0\2", "\255\0\0", "\0\1\255\0", "\0\1\0\0" }) do
    denied(sync.read_bye, body)
end

-- Header-first processing updates admission between coalesced envelopes.
do
    local value = sync.new_connection(-1)
    value.admission_request = fixture.request()
    sync.feed(value, sync.sync_frame(sync.kind.welcome, 0, welcome(wire.attachment_admission.awaiting_consent, 7, 9))
        .. sync.sync_frame(sync.kind.notify, 0, status("pending"))
        .. sync.sync_frame(sync.kind.notify, 0, status("approved"))
        .. sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. string.rep("p", 16)))
    check(value.protocol_failure == nil and value.welcomed and value.consent_phase == "approved" and value.pane == 1,
        "coalesced exact approval did not gate the first pane")
end

-- Byte-at-a-time input keeps bounded slot metadata and joins each body byte
-- once into its 1KiB block and once into the final exact envelope.
do
    local value = fixture.connection(-1)
    local body = string.char(wire.notify_kind.events) .. string.rep("x", wire.max_frame_body - 1)
    local frame = sync.sync_frame(sync.kind.notify, 0, body)
    local concat, copied = table.concat, 0
    local max_parts, max_blocks, max_header = 0, 0, 0
    table.concat = function(values, separator, first, last)
        local held = value.envelope_state
        -- Attribute only the reader's two joins; ACK varints have separate owners.
        if held and (values == held.parts or values == held.blocks) then
            for index = first or 1, last or #values do copied = copied + #values[index] end
        end
        return concat(values, separator, first, last)
    end
    for at = 1, #frame do
        sync.feed(value, frame:sub(at, at))
        local held = value.envelope_state
        if held then
            max_header = math.max(max_header, #held.header)
            max_parts = math.max(max_parts, held.parts and #held.parts or 0)
            max_blocks = math.max(max_blocks, held.blocks and #held.blocks or 0)
        end
    end
    table.concat = concat
    check(value.protocol_failure == nil and value.notifies[1] and value.notifies[1].record == body:sub(2), "bytewise exact body failed")
    check(max_header <= wire.max_envelope_header and max_parts <= 1024 and max_blocks <= 64,
        "bytewise fragments retained unbounded metadata")
    check(copied == #body + #frame and value.envelope_state == nil, "body reassembly was not two linear joins")
end

-- A synchronous same-carrier feed is a protocol refusal, not a second reader.
do
    local value = fixture.connection(-1)
    local writes, closed = 0, false
    local tail = sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. string.rep("p", 16))
    value.stdin = { is_closing = function() return closed end, close = function() closed = true end,
        write = function()
            writes = writes + 1
            sync.feed(value, tail)
        end }
    sync.feed(value, sync.sync_frame(sync.kind.probe, 0, string.rep("\0", 8)) .. tail)
    check(value.protocol_failure ~= nil and closed and writes == 1, "same-owner recursive feed was not refused")
    check(value.pane == nil and value.envelope_state == nil and value.active_feed == nil,
        "recursive refusal applied an old tail or retained its reader")
end

-- A callback beginning another owner generation keeps that owner's partial
-- reader. The rest of the old read must never supply its bytes or its ACK.
do
    local value = fixture.connection(-1)
    local next_state = { header = string.char(sync.kind.welcome), received = 0 }
    local writes, replacement_writes = 0, 0
    local replacement = { is_closing = function() return false end,
        write = function() replacement_writes = replacement_writes + 1 end }
    value.stdin = { is_closing = function() return false end, write = function()
        writes = writes + 1
        value.transport_generation = value.transport_generation + 1
        value.stdin, value.envelope_state = replacement, next_state
    end }
    sync.feed(value, sync.sync_frame(sync.kind.probe, 0, string.rep("\0", 8))
        .. sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. string.rep("p", 16)))
    check(value.protocol_failure == nil and writes == 1 and replacement_writes == 0, "old read wrote to the replacement owner")
    check(value.pane == nil and value.envelope_state == next_state and value.active_feed == nil,
        "old tail or cleanup changed the replacement reader")
end

vim.notify = notify
print("neovim_sync_admission: " .. checks .. " checks passed")
