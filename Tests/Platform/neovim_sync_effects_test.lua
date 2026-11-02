-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/../../Source/Platform/Neovim/lua/?.lua;" .. here .. "/../../Source/Platform/Neovim/lua/?/init.lua;" .. package.path
local sync, effects, sha = require("ubiquitty_sync"), require("ubiquitty_sync.effects"), require("ubiquitty_sync.sha256")
local wire = require("ubiquitty_sync.wire")
local fixture = dofile(here .. "/editor_wire_fixture.lua")
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function le(value, width)
    local bytes = {}
    for index = 1, width do bytes[index] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function hex(bytes) return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)) end
local function from_hex(bytes) return (bytes:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end
local primary, pane = string.rep("p", 16), string.rep("n", 16)
local function record(sequence, kind, payload, generation, count)
    return le(generation or 2, 8) .. (type(sequence) == "string" and sequence or le(sequence, 8)) .. primary
        .. string.char(kind or 0) .. le(count or 1, 4) .. (payload or "")
end
local function packet(through, remaining, body, generation)
    return le(generation or 2, 8) .. (type(through) == "string" and through or le(through, 8)) .. le(remaining, 2) .. (body or "")
end
local function denied(fn, ...) check(not pcall(fn, ...), "expected refusal") end
local function varint(value)
    if value < 128 then return string.char(value) end
    return string.char(value % 128 + 128) .. varint(math.floor(value / 128))
end
local function last_ack(sent)
    for index = #sent, 1, -1 do
        local bytes = sent[index]
        if bytes:byte(1) == sync.kind.ack then
            return bytes:sub(sync.envelope_header(bytes).bytes + 1)
        end
    end
    error("no Ack")
end
check(sync.kind.effect == 50 and sync.kind.image_head == 52 and sync.kind.image_placements == 53 and sync.kind.sample_head == 54 and sync.kind.image_want == 75,
    "numeric wire assignments changed")

-- Independent SHA known answers, binary zeroes, and every block split.
for _, vector in ipairs({ { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { string.rep("a", 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" } }) do
    for split = 0, math.min(#vector[1], 130) do
        local hash = sha.new(); sha.update(hash, vector[1]:sub(1, split)); sha.update(hash, vector[1]:sub(split + 1))
        check(#hash.tail < 64 and hex(sha.finish(hash)) == vector[2], "incremental SHA vector")
        denied(sha.update, hash, "x")
    end
end

local valid = packet(1, 0, record(1))
for length = 0, #valid - 1 do
    -- Exactly the wrapper is a legal empty completion.
    if length ~= 18 then denied(effects.decode, valid:sub(1, length)) end
end
denied(effects.decode, valid .. "x")
denied(effects.decode, packet(0, 0))
denied(effects.decode, packet(1, 256, record(1)))
denied(effects.decode, packet(1, 1, record(1)))
denied(effects.decode, packet(1, 0, record(0)))
denied(effects.decode, packet(1, 0, record(1, 0, "", 3)))
denied(effects.decode, packet(1, 0, record(1, 5)))
denied(effects.decode, packet(1, 0, record(1, 99)))
local notification = "\1T\1B\1I\0"
check(effects.decode(packet(1, 0, record(1, 1, notification))).record.title == "T", "notification metadata")
denied(effects.decode, packet(1, 0, record(1, 1, "\1\255\0\0\0")))
denied(effects.decode, packet(1, 0, record(1, 1, "\2\192\128\0\0\0")))
denied(effects.decode, packet(1, 0, record(1, 1, "\3\237\160\128\0\0\0")))
denied(effects.decode, packet(1, 0, record(1, 1, "\1\194\0\0\0")))
denied(effects.decode, packet(1, 0, record(1, 1, "\128\0\0\0\0")))
denied(effects.decode, packet(1, 0, record(1, 1, "\0\0\0\3")))
local command = "\1" .. le(9, 8) .. "\1/\1x"
check(effects.decode(packet(1, 0, record(1, 2, command))).record.exit_status == -1, "signed command status")
local sound = string.rep("\0", 29)
check(effects.decode(packet(1, 0, record(1, 3, sound))).record.sound.count == 0, "sound metadata")
denied(effects.decode, packet(1, 0, record(1, 3, "\8" .. sound:sub(2))))

local cursor = effects.new()
local first, last = effects.decode(packet(3, 1, record(1))), effects.decode(packet(3, 0, record(3)))
denied(effects.accept, cursor, first, le(1, 8))
check(cursor.consumed == effects.zero, "picture refusal mutated receipt")
check(effects.accept(cursor, first, le(2, 8)) ~= nil and cursor.acknowledged == effects.zero, "partial batch ACKed")
local saved = { acknowledged = cursor.acknowledged, consumed = cursor.consumed }
denied(effects.accept, cursor, effects.decode(packet(3, 0)), le(2, 8))
denied(effects.accept, cursor, effects.decode(packet(3, 0, record(1))), le(2, 8))
check(cursor.consumed == saved.consumed and cursor.acknowledged == saved.acknowledged, "invalid tail mutated receipt")
cursor = effects.new(saved)
check(effects.accept(cursor, first, le(2, 8)) == nil, "reconnect reposted partial record")
check(effects.accept(cursor, last, le(2, 8)) ~= nil and cursor.acknowledged == le(3, 8), "final batch did not ACK")
check(effects.accept(cursor, last, le(2, 8)) == nil, "repeated final reposted")
denied(effects.accept, cursor, effects.decode(packet(2, 0)), le(2, 8))
denied(effects.new, { acknowledged = le(4, 8), consumed = le(3, 8) })
local huge, huge_next = le(0, 4) .. le(2097152, 4), le(1, 4) .. le(2097152, 4)
cursor = effects.new()
check(effects.accept(cursor, effects.decode(packet(huge_next, 1, record(huge))), le(2, 8)) ~= nil, "large sequence missing")
check(effects.accept(cursor, effects.decode(packet(huge_next, 0, record(huge_next))), le(2, 8)) ~= nil,
    "adjacent sequences above 2^53 collapsed")
cursor = effects.new()
for index = 1, 256 do
    check(effects.accept(cursor, effects.decode(packet(256, 256 - index, record(index))), le(2, 8)) ~= nil, "256-record bound")
end
check(cursor.acknowledged == le(256, 8), "full batch completion")

-- Real dispatch, identity retirement, primary presentation, and final-only ACK.
local buffer = vim.api.nvim_create_buf(false, true)
local connection = fixture.connection(buffer)
local sent, posts = {}, 0
connection.stdin = { is_closing = function() return false end, write = function(_, bytes) sent[#sent + 1] = bytes end }
connection.client_instance, connection.welcome = primary, sync.read_welcome(fixture.welcome(0))
local function receive(kind, channel, body) sync.feed(connection, sync.sync_frame(kind, channel, body)) end
local old_notify = vim.notify
-- The client also reports a refused frame through vim.notify; only an
-- effect's own notification counts as a post.
vim.notify = function(message) if not tostring(message):find("^ubiquitty_sync: ") then posts = posts + 1 end end
receive(sync.kind.pane_bind, 0, "\1" .. pane)
connection.generation, connection.generation_bytes = 2, le(2, 8)
receive(sync.kind.effect, 1, packet(1, 0, record(1, 1, notification)))
receive(sync.kind.effect, 1, packet(1, 0, record(1, 1, notification)))
check(posts == 1 and #connection.effects == 1, "typed notification duplicated or not posted")
do
    local unbound = fixture.connection(-1)
    sync.feed(unbound, sync.sync_frame(sync.kind.pane_unbind, 0, "\2\0"))
    check(unbound.protocol_failure ~= nil, "an unbound handle was accepted")
    check(connection.effect_pane == pane, "another carrier retired receipts")
end
receive(sync.kind.pane_bind, 0, "\2" .. pane)
receive(sync.kind.pane_unbind, 0, "\2\0")
check(connection.effect_pane == pane and connection.pane == 1, "one alias retired the live pane receipt")
receive(sync.kind.effect, 1, packet(1, 0, record(1, 1, notification)))
check(posts == 1, "alias lifecycle reposted an acknowledged effect")
receive(sync.kind.effect, 1, packet(4, 1, record(2, 1, notification)))
check(last_ack(sent):sub(21) == "\0", "partial batch acknowledged a pane")
receive(sync.kind.effect, 1, packet(4, 0, record(4, 1, notification)))
check(last_ack(sent):sub(21) == "\1\1" .. le(2, 8) .. le(0, 8) .. le(4, 8), "final effect ACK layout")
receive(sync.kind.pane_bind, 0, "\2" .. pane)
receive(sync.kind.effect, 1, packet(5, 0, record(5, 1, notification)))
check(last_ack(sent):sub(21, 22) == "\1\1", "effect ACK changed its authenticated handle")
receive(sync.kind.pane_unbind, 0, "\2\0")
receive(sync.kind.pane_unbind, 0, "\1\0")
check(connection.effect_pane == nil and connection.effect_cursor.consumed == effects.zero, "unbind retained receipt")
vim.notify = old_notify
vim.api.nvim_buf_delete(buffer, { force = true })

-- Independent handle batches share only stable-pane deduplication.
local aliases = fixture.connection(-1)
local alias_sent = {}
aliases.stdin = { is_closing = function() return false end, write = function(_, bytes) alias_sent[#alias_sent + 1] = bytes end }
aliases.client_instance, aliases.welcome = primary, sync.read_welcome(fixture.welcome(0))
local function alias_receive(kind, handle, body) sync.feed(aliases, sync.sync_frame(kind, handle, body)) end
alias_receive(sync.kind.pane_bind, 0, "\1" .. pane)
alias_receive(sync.kind.pane_bind, 0, "\2" .. pane)
aliases.generation, aliases.generation_bytes = 2, le(2, 8)
alias_receive(sync.kind.effect, 1, packet(2, 1, record(1)))
alias_receive(sync.kind.effect, 2, packet(2, 1, record(1)))
check(not aliases.protocol_failure, "interleaved alias batch refused")
alias_receive(sync.kind.effect, 1, packet(2, 0, record(2)))
check(last_ack(alias_sent):sub(21) == "\1\1" .. le(2, 8) .. le(0, 8) .. le(2, 8), "first alias completion ACK")
check(#aliases.effects == 2, "first alias records not delivered exactly once")
alias_receive(sync.kind.effect, 2, packet(2, 0, record(2)))
check(not aliases.protocol_failure and #aliases.effects == 2, "second alias replayed a consumed record")
check(last_ack(alias_sent):sub(21) == "\1\2" .. le(2, 8) .. le(0, 8) .. le(2, 8), "second alias completion ACK")
alias_receive(sync.kind.effect, 1, packet(4, 1, record(3)))
alias_receive(sync.kind.effect, 2, packet(4, 1, record(3)))
alias_receive(sync.kind.pane_unbind, 0, "\1\0")
alias_receive(sync.kind.effect, 2, packet(4, 0, record(4)))
check(not aliases.protocol_failure and #aliases.effects == 4, "unbind destroyed sibling partial batch")

-- One stable pane, bounded aliases, and no receipt reset on a refused bind.
for _, failure in ipairs({ "distinct", "duplicate", "capacity", "listing" }) do
    local bounded = fixture.connection(-1)
    sync.feed(bounded, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    bounded.effect_cursor.consumed = le(9, 8)
    if failure == "capacity" then
        for handle = 2, wire.max_panes_per_connection do
            sync.feed(bounded, sync.sync_frame(sync.kind.pane_bind, 0, varint(handle) .. pane))
        end
        check(not bounded.protocol_failure, "legal alias capacity refused")
    end
    local bad = failure == "distinct" and ("\2" .. primary)
        or failure == "duplicate" and ("\1" .. pane)
        or failure == "listing" and (varint(wire.first_listed_handle) .. pane) or (varint(wire.max_panes_per_connection + 1) .. pane)
    sync.feed(bounded, sync.sync_frame(sync.kind.pane_bind, 0, bad))
    check(bounded.protocol_failure ~= nil and bounded.effect_cursor.consumed == le(9, 8), "refused binding lost receipt")
end

-- A text-only client validates both image digests without retaining pixels.
local pixels = string.char(255, 0, 0, 127, 0, 255, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255)
local identity = from_hex("d5e7347a4b321df43917c86a75dc2232")
local digest = from_hex("8f513476f27a2d03dd42a52731564a4d695544d5fdddd80e3c65f027d19b09eb")
local asset = identity .. "\32" .. le(2, 4) .. le(2, 4)
local image_state = le(1, 4) .. "\1" .. le(7, 4) .. le(0, 4) .. asset .. string.rep("\0", 9) .. "\0"
for _, corrupt in ipairs({ "none", "raw", "content" }) do
    local image = fixture.connection(-1); image.pane = 1
    local offered_asset = corrupt == "content" and (string.rep("x", 16) .. asset:sub(17)) or asset
    local offered_state = corrupt == "content" and (image_state:sub(1, 13) .. offered_asset .. image_state:sub(39)) or image_state
    sync.feed(image, sync.sync_frame(sync.kind.image_placements, 1, offered_state))
    sync.feed(image, sync.sync_frame(sync.kind.image_head, 1, offered_asset .. le(101, 4)))
    sync.feed(image, sync.sync_frame(sync.kind.bulk_chunk, 0, le(101, 4) .. le(0, 4) .. "\0\8" .. pixels:sub(1, 8)))
    check(image.image_transfers[101].chunks == nil and #image.image_transfers[101].raw_hash.tail < 64, "image retained pixel body")
    sync.feed(image, sync.sync_frame(sync.kind.bulk_chunk, 0, le(101, 4) .. le(1, 4) .. "\1\8" .. pixels:sub(9)
        .. (corrupt == "raw" and string.rep("\0", 32) or digest)))
    check((image.protocol_failure ~= nil) == (corrupt ~= "none"), "image SHA corruption verdict")
end
-- Samples retain a bounded incremental digest, not a mutable slot or audio sink.
local pcm = from_hex("0080ffff0000ff7f")
local pcm_digest = from_hex("a0b3d8f5dbcdc6dac337b3de2e92fe62e1391e6a031d577ca3f7b4b804ac9c79")
local sample_identity = le(7, 4) .. le(4, 4) .. pcm_digest
local sample_head = "\1" .. sample_identity .. le(501, 4)
local sampled_sound = "\0\6" .. string.rep("\0", 14) .. "\1" .. string.rep("\0", 12) .. sample_identity
check(effects.sample_head(sample_head).identity.frames == 4, "sample head fields")
check(effects.decode(packet(1, 0, record(1, 3, sampled_sound))).record.sound.identity.serial == 7, "sampled sound identity")
for length = 0, 44 do denied(effects.sample_head, sample_head:sub(1, length)) end
for _, bad in ipairs({ sample_head .. "x", "\0" .. sample_head:sub(2), "\26" .. sample_head:sub(2),
    "\1" .. le(7, 4) .. le(441001, 4) .. pcm_digest .. le(501, 4),
    "\1" .. le(7, 4) .. le(0, 4) .. pcm_digest .. le(0, 4),
    "\1" .. sample_identity .. le(0, 4) }) do denied(effects.sample_head, bad) end
for _, mode in ipairs({ "complete", "hash", "head-hash", "unbind", "cap", "overwrite" }) do
    local sample = fixture.connection(-1)
    sample.stdin = { is_closing = function() return false end, write = function() end }
    sample.client_instance, sample.welcome = primary, sync.read_welcome(fixture.welcome(0))
    local function feed(kind, handle, bytes) sync.feed(sample, sync.sync_frame(kind, handle, bytes)) end
    feed(sync.kind.pane_bind, 0, "\1" .. pane)
    sample.generation, sample.generation_bytes = 2, le(2, 8)
    local identity_bytes = mode == "head-hash" and (le(7, 4) .. le(4, 4) .. string.rep("x", 32)) or sample_identity
    feed(sync.kind.sample_head, 1, "\1" .. identity_bytes .. le(501, 4))
    local sound_bytes = sampled_sound:sub(1, 29) .. identity_bytes
    feed(sync.kind.effect, 1, packet(1, 0, record(1, 3, sound_bytes)))
    check(not sample.protocol_failure and sample.effect_cursor.consumed == effects.zero and #sample.deferred_effects == 1,
        "unready sample consumed a receipt")
    if mode == "unbind" then
        feed(sync.kind.pane_unbind, 0, "\1\0")
        check(next(sample.sample_transfers) == nil and #sample.deferred_effects == 0 and sample.deferred_effect_bytes == 0,
            "unbind retained sample owners")
    elseif mode == "cap" then
        for sequence = 2, 257 do feed(sync.kind.effect, 1, packet(sequence, 0, record(sequence))) end
        check(sample.protocol_failure ~= nil and sample.effect_cursor.consumed == effects.zero
            and #sample.deferred_effects == 0 and next(sample.sample_transfers) == nil, "deferred bound did not fail closed")
    elseif mode == "overwrite" then
        feed(sync.kind.sample_head, 1, "\1" .. le(8, 4) .. sample_identity:sub(5) .. le(502, 4))
        check(sample.protocol_failure ~= nil and sample.effect_cursor.consumed == effects.zero, "pending sample was replaced")
    else
        feed(sync.kind.effect, 1, packet(2, 0, record(2)))
        check(#sample.effects == 0, "later same-pane effect bypassed the sample")
        feed(sync.kind.bulk_chunk, 0, le(501, 4) .. le(0, 4) .. "\0\3" .. pcm:sub(1, 3))
        check(sample.sample_transfers[501].received == 3 and #sample.sample_transfers[501].hash.tail < 64,
            "sample chunk retained an unbounded owner")
        feed(sync.kind.bulk_chunk, 0, le(501, 4) .. le(1, 4) .. "\1\5" .. pcm:sub(4)
            .. (mode == "hash" and string.rep("x", 32) or pcm_digest))
        if mode == "complete" then
            check(not sample.protocol_failure and #sample.effects == 2 and sample.effect_cursor.acknowledged == le(2, 8),
                "verified sample did not release ordered effects")
            check(sample.sample_slots[1][1].ready and next(sample.sample_transfers) == nil and sample.deferred_effect_bytes == 0,
                "completed sample retained payload or deferred bytes")
        else
            check(sample.protocol_failure ~= nil and #sample.effects == 0 and sample.effect_cursor.consumed == effects.zero,
                "invalid sample digest consumed an effect")
        end
    end
end
local sample_aliases = fixture.connection(-1)
for handle = 1, 26 do
    sync.feed(sample_aliases, sync.sync_frame(sync.kind.pane_bind, 0, varint(handle) .. pane))
    sync.feed(sample_aliases, sync.sync_frame(sync.kind.sample_head, handle, "\1" .. sample_identity .. le(600 + handle, 4)))
end
check(not sample_aliases.protocol_failure and sample_aliases.sample_transfers[626] ~= nil,
    "legal same-pane aliases shared an artificial 25-transfer cap")
for handle = 1, 26 do sync.feed(sample_aliases, sync.sync_frame(sync.kind.pane_unbind, 0, varint(handle) .. "\0")) end
check(next(sample_aliases.sample_transfers) == nil and next(sample_aliases.sample_slots) == nil, "alias sample owners leaked")

local function bundle(items)
    local parts = { varint(#items) }
    for _, item in ipairs(items) do
        parts[#parts + 1] = varint(#item.mime) .. item.mime .. varint(#item.bytes) .. item.bytes
    end
    return table.concat(parts)
end
local representations = { { mime = "text/plain", bytes = "a\0b" }, { mime = "image/png", bytes = "\255\0\127\128" } }
local encoded_bundle = bundle(representations)
local function clipboard_record(sequence, transfer, bytes, selector)
    return record(sequence, wire.effect_kind.clipboard_write, string.char(selector or wire.clipboard_buffer.clipboard)
        .. le(transfer, 4) .. le(#bytes, 4) .. (transfer == 0 and bytes or ""))
end
local decoded_bundle = effects.clipboard_bundle(encoded_bundle, wire.max_effect_clipboard_write_bytes)
check(#decoded_bundle == 2 and decoded_bundle[2].bytes == representations[2].bytes, "binary MIME bundle changed")
for _, bad in ipairs({ "", encoded_bundle .. "x", bundle({ { mime = "", bytes = "x" } }),
    bundle({ { mime = "text/plain", bytes = "x" }, { mime = "text/plain", bytes = "y" } }),
    bundle({ { mime = "bad\0mime", bytes = "x" } }), bundle({ { mime = "\255", bytes = "x" } }) }) do
    denied(effects.clipboard_bundle, bad, wire.max_effect_clipboard_write_bytes)
end
for _, mode in ipairs({ "disabled", "refused", "applied", "wrong-primary", "agent", "recursive-feed", "throws" }) do
    local clipboard = fixture.connection(-1)
    local calls, delivered = 0, nil
    clipboard.client_instance, clipboard.welcome = primary, sync.read_welcome(fixture.welcome(mode == "agent" and wire.role.agent or wire.role.owner))
    local function feed(kind, handle, bytes) sync.feed(clipboard, sync.sync_frame(kind, handle, bytes)) end
    feed(sync.kind.pane_bind, 0, "\1" .. pane)
    clipboard.generation, clipboard.generation_bytes = 2, le(2, 8)
    if mode ~= "disabled" then
        clipboard.clipboard_write_handler = function(selector, items)
            calls, delivered = calls + 1, items
            check(selector == wire.clipboard_buffer.primary, "clipboard selector changed")
            if mode == "recursive-feed" then feed(sync.kind.pane_unbind, 0, "\1\0") end
            if mode == "throws" then error("secret contents") end
            return mode ~= "refused"
        end
    end
    if mode == "wrong-primary" then clipboard.client_instance = string.rep("q", 16) end
    local bytes = packet(1, 0, clipboard_record(1, 0, encoded_bundle, wire.clipboard_buffer.primary))
    feed(sync.kind.effect, 1, bytes)
    if mode == "wrong-primary" or mode == "agent" then
        check(clipboard.protocol_failure ~= nil and calls == 0 and clipboard.effect_cursor.consumed == effects.zero,
            "clipboard reached a non-primary recipient")
    elseif mode == "throws" then
        check(clipboard.protocol_failure ~= nil and calls == 1 and clipboard.effect_cursor.consumed == le(1, 8), "handler failure repeated consumption")
        check(clipboard.protocol_failure == "ubiquitty_sync: local clipboard handler failed" and clipboard.clipboard_write_status == "refused",
            "handler error exposed contents or claimed a successful write")
    elseif mode == "recursive-feed" then
        check(clipboard.protocol_failure ~= nil and calls == 1 and clipboard.pane == 1,
            "recursive transport feed mutated the active pane")
    else
        check(not clipboard.protocol_failure and clipboard.effect_cursor.acknowledged == le(1, 8), "valid clipboard was not consumed")
        check(clipboard.clipboard_write_status == mode, "clipboard claimed the wrong sink result")
        feed(sync.kind.effect, 1, bytes)
        check(calls == (mode == "disabled" and 0 or 1), "clipboard was delivered twice")
        if delivered then check(delivered[1].bytes == "a\0b" and delivered[2].bytes == representations[2].bytes, "clipboard representations changed") end
    end
    check(#clipboard.effects == 0 and clipboard.deferred_effect_bytes == 0 and (clipboard.delivering_effect_bytes or 0) == 0,
        "clipboard secret escaped into recent events or leaked a delivery charge")
end
for _, mode in ipairs({ "complete", "hash", "unbind", "abort", "collision", "recursive-feed" }) do
    local clipboard = fixture.connection(-1)
    clipboard.client_instance, clipboard.welcome = primary, sync.read_welcome(fixture.welcome(wire.role.driver))
    local calls = 0
    local function feed(kind, handle, bytes) sync.feed(clipboard, sync.sync_frame(kind, handle, bytes)) end
    feed(sync.kind.pane_bind, 0, "\1" .. pane)
    clipboard.generation, clipboard.generation_bytes = 2, le(2, 8)
    clipboard.clipboard_write_handler = function(_, items)
        calls = calls + 1
        check(clipboard.clipboard_reserved_bytes > 0 and clipboard.delivering_clipboard_bytes > 0, "active clipboard charge released early")
        if mode == "recursive-feed" then feed(sync.kind.pane_unbind, 0, "\1\0") end
        check(items[2].bytes == representations[2].bytes, "callback lost its MIME owner")
        return true
    end
    feed(sync.kind.effect, 1, packet(1, 0, clipboard_record(1, 701, encoded_bundle)))
    check(not clipboard.protocol_failure and calls == 0 and clipboard.effect_cursor.consumed == effects.zero
        and clipboard.clipboard_reserved_bytes == 3 * #encoded_bundle, "clipboard consumed before transfer")
    if mode == "unbind" then feed(sync.kind.pane_unbind, 0, "\1\0")
    elseif mode == "abort" then feed(sync.kind.bulk_abort, 0, le(701, 4))
    elseif mode == "collision" then feed(sync.kind.sample_head, 1, "\1" .. sample_identity .. le(701, 4))
    else
        feed(sync.kind.bulk_chunk, 0, le(701, 4) .. le(0, 4) .. "\0\3" .. encoded_bundle:sub(1, 3))
        check(calls == 0 and clipboard.effect_cursor.consumed == effects.zero, "partial clipboard consumed")
        local hash = sha.new()
        sha.update(hash, encoded_bundle)
        local digest_bytes = mode == "hash" and string.rep("x", 32) or sha.finish(hash)
        feed(sync.kind.bulk_chunk, 0, le(701, 4) .. le(1, 4) .. "\1" .. varint(#encoded_bundle - 3) .. encoded_bundle:sub(4) .. digest_bytes)
    end
    local succeeds = mode == "complete" or mode == "recursive-feed"
    check(calls == (succeeds and 1 or 0), "bulk clipboard sink count")
    check((clipboard.protocol_failure ~= nil) == (mode == "hash" or mode == "abort" or mode == "collision" or mode == "recursive-feed"),
        "bulk clipboard refusal verdict")
    check(clipboard.clipboard_reserved_bytes == 0 and next(clipboard.clipboard_transfers) == nil
        and clipboard.deferred_effect_bytes == 0, "bulk clipboard owner retained after completion/cancellation")
end
-- The borrowed complete MIME owner lives through the callback, but an old
-- generation may not debit/reset the replacement generation's delivery state.
do
    local clipboard = fixture.connection(-1)
    clipboard.client_instance = primary
    sync.feed(clipboard, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    clipboard.generation, clipboard.generation_bytes = 2, le(2, 8)
    local replacement_queue, replacement_reader = {}, { header = string.char(sync.kind.welcome), received = 0 }
    local calls, writes = 0, 0
    clipboard.clipboard_write_handler = function(_, items)
        calls = calls + 1
        check(items[1].bytes == representations[1].bytes and clipboard.delivering_clipboard_bytes > 0,
            "callback lost its old owner or released its charge before return")
        clipboard.transport_generation = clipboard.transport_generation + 1
        clipboard.stdin = { is_closing = function() return false end, write = function() writes = writes + 1 end }
        clipboard.deferred_effects, clipboard.deferred_effect_bytes = replacement_queue, 19
        clipboard.delivering_effect_bytes, clipboard.delivering_clipboard_bytes, clipboard.clipboard_reserved_bytes = 23, 29, 31
        clipboard.clipboard_write_status, clipboard.is_draining_effects = "replacement", true
        clipboard.envelope_state = replacement_reader
        return true
    end
    sync.feed(clipboard, sync.sync_frame(sync.kind.effect, 1, packet(1, 0, clipboard_record(1, 701, encoded_bundle))))
    local hash = sha.new()
    sha.update(hash, encoded_bundle)
    local final = sync.sync_frame(sync.kind.bulk_chunk, 0,
        le(701, 4) .. le(0, 4) .. "\1" .. varint(#encoded_bundle) .. encoded_bundle .. sha.finish(hash))
    sync.feed(clipboard, final .. sync.sync_frame(sync.kind.pane_unbind, 0, "\1\0"))
    check(calls == 1 and writes == 0 and clipboard.protocol_failure == nil and clipboard.pane == 1,
        "old callback read applied its tail or wrote to the replacement")
    check(clipboard.delivering_effect_bytes == 23 and clipboard.delivering_clipboard_bytes == 29
        and clipboard.clipboard_reserved_bytes == 31 and clipboard.deferred_effect_bytes == 19,
        "old generation debited new delivery counters")
    check(clipboard.clipboard_write_status == "replacement" and clipboard.is_draining_effects == true
        and clipboard.deferred_effects == replacement_queue and clipboard.envelope_state == replacement_reader,
        "old generation reset replacement presentation/reader state")
end
-- Empty inventory is an exact clear operation, not an absent clipboard event.
do
    local clipboard = fixture.connection(-1)
    clipboard.client_instance, clipboard.welcome = primary, sync.read_welcome(fixture.welcome(wire.role.owner))
    sync.feed(clipboard, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    clipboard.generation, clipboard.generation_bytes = 2, le(2, 8)
    local called = false
    clipboard.clipboard_write_handler = function(_, items) called = #items == 0; return true end
    sync.feed(clipboard, sync.sync_frame(sync.kind.effect, 1, packet(1, 0, clipboard_record(1, 0, "\0"))))
    check(called and clipboard.clipboard_write_status == "applied", "empty clipboard clear was suppressed")
end
-- Read requests are validated and refused, never routed to an editor clipboard.
local function clipboard_request(id, selector, request_kind, mime)
    return le(id, 4) .. string.char(selector, request_kind) .. varint(#mime) .. mime
end
check(sync.kind.clipboard_request == 51 and sync.kind.clipboard_data == 74, "clipboard read wire assignments")
for _, role in ipairs({ wire.role.owner, wire.role.driver }) do
    local client, replies = fixture.connection(-1), {}
    client.welcome = sync.read_welcome(fixture.welcome(role))
    sync.feed(client, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    sync.feed(client, sync.sync_frame(sync.kind.pane_bind, 0, "\2" .. pane))
    client.stdin = { is_closing = function() return false end, write = function(_, bytes)
        if bytes:byte(1) == 74 then replies[#replies + 1] = bytes
        else check(bytes:byte(1) == sync.kind.ack, "unexpected response kind") end
    end }
    local old_getreg = vim.fn.getreg
    vim.fn.getreg = function() error("unexpected clipboard read") end
    for selector = 0, wire.clipboard_buffer.count - 1 do
        for _, id in ipairs({ 1, 4294967295 }) do
            for _, mime in ipairs({ "", "text/plain", "text/\195\169" }) do
                sync.feed(client, sync.sync_frame(51, 2, clipboard_request(id, selector, mime == "" and 0 or 1, mime)))
                check(not client.protocol_failure, "valid read request failed")
                local reply = table.remove(replies, 1)
                check(reply == sync.sync_frame(74, 2, le(id, 4) .. "\2"), "read reply mismatch: " .. hex(reply or ""))
            end
        end
    end
    vim.fn.getreg = old_getreg
    check(#replies == 0 and #client.effects == 0 and client.clipboard_reserved_bytes == 0
        and client.effect_cursor.consumed == effects.zero, "read refusal retained payload or mutated effects")
end
local request = clipboard_request(7, 0, 1, "text/plain")
local invalid_requests = { request .. "x", clipboard_request(0, 0, 0, ""), clipboard_request(1, 12, 0, ""),
    clipboard_request(1, 0, 2, ""), clipboard_request(1, 0, 0, "text/plain"), clipboard_request(1, 0, 1, ""),
    clipboard_request(1, 0, 1, "text/\0plain"), clipboard_request(1, 0, 1, "\255"),
    clipboard_request(1, 0, 1, "\192\128"), clipboard_request(1, 0, 1, "\237\160\128"), clipboard_request(1, 0, 1, "\194"),
    le(1, 4) .. "\0\0\128\0", clipboard_request(1, 0, 1, string.rep("x", 65527)) }
for length = 0, #request - 1 do invalid_requests[#invalid_requests + 1] = request:sub(1, length) end
for _, body in ipairs(invalid_requests) do
    local client, replies = fixture.connection(-1), 0
    client.welcome = sync.read_welcome(fixture.welcome(wire.role.owner))
    sync.feed(client, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    client.stdin = { is_closing = function() return false end, write = function() replies = replies + 1 end }
    -- The longest malformed request is past what the encoder frames, so it is
    -- framed by hand: the receiver refuses it at the envelope header.
    sync.feed(client, string.char(51) .. varint(1) .. varint(#body) .. body)
    check(client.protocol_failure ~= nil and replies == 0, "malformed request was answered")
end
check(#effects.clipboard_request(clipboard_request(1, 0, 1, string.rep("x", 65526))).mime == 65526, "maximum request refused")
for _, role in ipairs({ -1, wire.role.owner, wire.role.driver, wire.role.viewer, wire.role.agent }) do
    for _, handle in ipairs({ 0, 1, 2, wire.first_listed_handle }) do
        if not ((role == wire.role.owner or role == wire.role.driver) and handle == 1) then
            local client, replies, decodes = fixture.connection(-1), 0, 0
            client.welcome = role >= 0 and sync.read_welcome(fixture.welcome(role)) or nil
            sync.feed(client, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
            client.stdin = { is_closing = function() return false end, write = function() replies = replies + 1 end }
            local original = effects.clipboard_request
            effects.clipboard_request = function() decodes = decodes + 1; return { id = 1 } end
            sync.feed(client, sync.sync_frame(51, handle, ""))
            effects.clipboard_request = original
            check(client.protocol_failure ~= nil and replies == 0 and decodes == 0, "unauthorized request reached decoder or response")
        end
    end
end
do
    local client, replies = fixture.connection(-1), 0
    client.welcome = sync.read_welcome(fixture.welcome(wire.role.owner))
    sync.feed(client, sync.sync_frame(sync.kind.pane_bind, 0, "\1" .. pane))
    sync.feed(client, sync.sync_frame(sync.kind.pane_unbind, 0, "\1\0"))
    client.stdin = { is_closing = function() return false end, write = function() replies = replies + 1 end }
    sync.feed(client, sync.sync_frame(51, 1, clipboard_request(1, 0, 0, "")))
    check(client.protocol_failure ~= nil and replies == 0, "retired binding answered a clipboard request")
end
-- Obsolete outer framing and Catalog are never accepted as a second grammar.
for _, tag in ipairs({ 0x09, 0x8B, 0x0A, 0x0B, 0x8C, 0x8D, 0x8E, 0x90, 0x91, 0x12, 0x9B, 0x17, 0x1C,
    0x9E, 0xA5, 0x1B, 0xA3, 0xA4, 0x83, 0x84, 0x87, 0x88, 0x8F, 0x98, 0x99, 0x13, 0x19, 0x9D,
    0xA2, 0x9F, 0xA0, 0xA6, 0xA7, 0x89, 0x8A, 0x9A, 0x0E, 0x23 }) do
    local client, writes = sync.new_connection(-1), 0
    client.stdin = { is_closing = function() return false end, write = function() writes = writes + 1 end }
    client.title = "kept title"
    sync.feed(client, string.char(tag) .. le(1048576, 4))
    check(client.protocol_failure ~= nil and writes == 0 and client.title == "kept title", "obsolete header was accepted")
    check(client.accumulator == "", "refused header retained payload capacity")
    local failure = client.protocol_failure
    sync.feed(client, "untrusted suffix")
    check(client.protocol_failure == failure and client.accumulator == "", "a refused record accepted a later read")
end
for _, header in ipairs({ string.char(0xFF), string.char(0x23), string.char(sync.kind.welcome, 1),
    string.char(sync.kind.welcome, 0x80, 0), string.char(sync.kind.welcome, 0, 0x80, 0x80, 4) }) do
    local client = sync.new_connection(-1)
    sync.feed(client, header)
    check(client.protocol_failure ~= nil and client.accumulator == "", "invalid canonical header waited for a body")
end
do
    local frame = sync.sync_frame(sync.kind.welcome, 0, fixture.welcome())
    for split = 0, #frame do
        local active = sync.new_connection(-1)
        active.admission_request = fixture.request()
        sync.feed(active, frame:sub(1, split))
        if split ~= #frame then check(active.welcome == nil, "a partial direct frame dispatched") end
        sync.feed(active, frame:sub(split + 1))
        check(active.protocol_failure == nil and active.session_id == 9 and active.accumulator == "", "a direct split frame did not dispatch whole")
    end
end
print("neovim_sync_effects: " .. checks .. " checks passed")
