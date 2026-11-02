-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- Typed effect validation and once-only receipt state. u64 values remain their
-- eight wire bytes: Lua numbers cannot distinguish adjacent values above 2^53.
local M = {}
local wire = require("ubiquitty_sync.wire")
local zero = string.rep("\0", 8)
M.zero = zero

function M.compare(first, second)
    for index = 8, 1, -1 do
        local a, b = first:byte(index), second:byte(index)
        if a ~= b then return a < b and -1 or 1 end
    end
    return 0
end

local function utf8(text)
    local at = 1
    while at <= #text do
        local first = text:byte(at)
        local count, value, minimum
        if first < 128 then count, value, minimum = 0, first, 0
        elseif first >= 194 and first <= 223 then count, value, minimum = 1, first - 192, 128
        elseif first >= 224 and first <= 239 then count, value, minimum = 2, first - 224, 2048
        elseif first >= 240 and first <= 244 then count, value, minimum = 3, first - 240, 65536
        else return false end
        for index = 1, count do
            local next_byte = text:byte(at + index)
            if not next_byte or next_byte < 128 or next_byte > 191 then return false end
            value = value * 64 + next_byte - 128
        end
        if value < minimum or value > 1114111 or (value >= 55296 and value <= 57343) then return false end
        at = at + count + 1
    end
    return true
end
M.valid_utf8 = utf8

local function reader(bytes)
    local at = 1
    local r = {}
    function r.take(count)
        if count < 0 or count > #bytes - at + 1 then error("truncated Effect", 0) end
        local value = bytes:sub(at, at + count - 1)
        at = at + count
        return value
    end
    function r.number(count)
        local value, scale = 0, 1
        for byte in r.take(count):gmatch(".") do value = value + byte:byte() * scale; scale = scale * 256 end
        return value
    end
    function r.varint(maximum)
        local value, scale = 0, 1
        for index = 1, 10 do
            local byte = r.number(1)
            value = value + (byte % 128) * scale
            if value > maximum then error("oversized Effect field", 0) end
            if byte < 128 then
                if index > 1 and byte == 0 then error("noncanonical Effect varint", 0) end
                return value
            end
            scale = scale * 128
        end
        error("oversized Effect varint", 0)
    end
    function r.text(maximum)
        local value = r.take(r.varint(maximum))
        if not utf8(value) then error("invalid Effect UTF-8", 0) end
        return value
    end
    function r.ended() return at == #bytes + 1 end
    return r
end

-- Decodes the request only; it grants no access to local clipboard sources.
function M.clipboard_request(bytes)
    if #bytes > wire.max_frame_body then error("oversized clipboard request", 0) end
    local r = reader(bytes)
    local request = { id = r.number(4), buffer = r.number(1), kind = r.number(1),
        mime = r.text(wire.max_effect_clipboard_mime_bytes) }
    if request.id == 0 or request.buffer >= wire.clipboard_buffer.count
        or (request.kind ~= wire.effect_clipboard_request.types and request.kind ~= wire.effect_clipboard_request.item)
        or (request.kind == wire.effect_clipboard_request.types) ~= (request.mime == "")
        or request.mime:find("\0", 1, true) or not r.ended() then error("invalid clipboard request", 0) end
    return request
end

local function sample_identity(r)
    local value = { serial = r.number(4), frames = r.number(4), digest = r.take(32) }
    if value.frames > wire.sample_max_frames or (value.frames == 0 and value.digest ~= string.rep("\0", 32)) then
        error("invalid sample identity", 0)
    end
    return value
end

-- A complete binary bundle is never reduced to a text/plain fallback.
function M.clipboard_bundle(bytes, maximum)
    local metadata = 1 + wire.max_effect_clipboard_items * (3 + wire.max_effect_clipboard_mime_bytes + 4)
    if maximum > wire.max_effect_clipboard_read_bytes or #bytes > metadata + maximum then error("oversized clipboard bundle", 0) end
    local r, items, seen, total = reader(bytes), {}, {}, 0
    local count = r.varint(wire.max_effect_clipboard_items)
    for index = 1, count do
        local mime = r.text(wire.max_effect_clipboard_mime_bytes)
        if #mime == 0 or mime:find("\0", 1, true) or seen[mime] then error("invalid clipboard MIME inventory", 0) end
        seen[mime] = true
        local size = r.varint(maximum - total)
        total = total + size
        items[index] = { mime = mime, bytes = r.take(size) }
    end
    if not r.ended() then error("trailing clipboard bundle", 0) end
    return items
end

local function clipboard_payload(r, maximum)
    local value = { transfer = r.number(4), encoded_bytes = r.number(4) }
    local metadata = 1 + wire.max_effect_clipboard_items * (3 + wire.max_effect_clipboard_mime_bytes + 4)
    if value.encoded_bytes == 0 or value.encoded_bytes > metadata + maximum then error("invalid clipboard descriptor", 0) end
    if value.transfer == 0 then value.items = M.clipboard_bundle(r.take(value.encoded_bytes), maximum) end
    return value
end

function M.sample_head(bytes)
    if #bytes ~= wire.sample_head_bytes then error("invalid SampleHead length", 0) end
    local r = reader(bytes)
    local value = { slot = r.number(1), identity = sample_identity(r), transfer = r.number(4) }
    if value.slot < 1 or value.slot > wire.sample_slot_count
        or (value.identity.frames == 0) ~= (value.transfer == 0) then error("invalid SampleHead", 0) end
    return value
end

local function sound(r)
    local value = { volume = r.number(1), wave = r.number(1), channel = r.number(1),
        attack = r.number(2), release = r.number(2), semitones = r.number(1), duration = r.number(4),
        gap = r.number(4), sample = r.number(1), decay = r.number(2), sustain = r.number(1),
        reverb = r.number(1), grid = r.number(1), lowpass = r.number(2), highpass = r.number(2),
        pan = r.number(1), repeat_count = r.number(1), count = r.number(1), notes = {} }
    local function envelope(n) return n == wire.tone_default_envelope or n <= wire.max_tone_envelope_milliseconds end
    if value.volume > wire.max_tone_volume or value.wave > wire.max_tone_wave or value.channel >= wire.tone_channel_count
        or not envelope(value.attack) or not envelope(value.release) or value.semitones > wire.max_tone_semitones_down
        or value.duration > math.floor(wire.max_tone_duration_units * 1000 / 32) or value.gap > value.duration
        or value.sample > wire.sample_slot_count or value.decay > wire.max_tone_envelope_milliseconds
        or value.sustain > wire.max_tone_volume or value.reverb > wire.max_tone_volume
        or value.lowpass > wire.max_tone_cutoff_hertz or value.highpass > wire.max_tone_cutoff_hertz
        or value.pan > wire.max_tone_pan or value.count > wire.max_tone_notes then error("invalid sound Effect", 0) end
    for index = 1, value.count do
        local note = { frequency = r.number(4), volume = r.number(1), effect = r.number(1), parameter = r.number(1) }
        if note.volume > wire.max_tone_volume or note.effect > wire.max_tone_effect then error("invalid sound note", 0) end
        value.notes[index] = note
    end
    if value.wave == 6 then
        value.identity = sample_identity(r)
        if value.sample == 0 and value.identity.frames ~= 0 then error("sample sound has no slot", 0) end
    end
    return value
end

-- A complete bounded packet, with no mutation or presentation on refusal.
function M.decode(bytes)
    if #bytes > wire.max_frame_body then error("oversized Effect", 0) end
    local r = reader(bytes)
    local packet = { generation = r.take(8), through = r.take(8), remaining = r.number(2) }
    if packet.through == zero or packet.remaining >= wire.max_effect_records then error("invalid Effect batch", 0) end
    if r.ended() then
        if packet.remaining ~= 0 then error("unfinished empty Effect batch", 0) end
        return packet
    end
    local record = { generation = r.take(8), sequence = r.take(8), primary = r.take(16), kind = r.number(1), count = r.number(4) }
    if record.sequence == zero or record.count == 0 or M.compare(record.generation, packet.generation) > 0
        or M.compare(record.sequence, packet.through) > 0 then error("invalid Effect identity", 0) end
    -- Prove sequence + remaining <= through without rounding or u64 overflow.
    local carry, sum = packet.remaining, {}
    for index = 1, 8 do
        local byte = record.sequence:byte(index) + carry
        sum[index], carry = string.char(byte % 256), math.floor(byte / 256)
    end
    if carry ~= 0 or M.compare(table.concat(sum), packet.through) > 0 then error("invalid Effect countdown", 0) end
    local kinds = wire.effect_kind
    if record.kind == kinds.notification then
        record.title, record.body = r.text(wire.max_attention_bytes), r.text(wire.max_attention_bytes)
        record.identifier, record.occasion = r.text(wire.max_notification_identifier_bytes), r.number(1)
        if record.occasion > wire.notification_occasion.invisible then error("invalid notification occasion", 0) end
    elseif record.kind == kinds.command_finished then
        local status = r.varint(4294967295)
        record.exit_status = status % 2 == 0 and status / 2 or -(status + 1) / 2
        record.duration, record.directory, record.command = r.take(8), r.text(wire.max_directory_bytes), r.text(wire.max_command_line_bytes)
    elseif record.kind == kinds.sound then
        record.sound = sound(r)
    elseif record.kind == kinds.clipboard_write then
        local buffer = r.number(1)
        if buffer >= wire.clipboard_buffer.count then error("invalid clipboard selector", 0) end
        record.clipboard = clipboard_payload(r, wire.max_effect_clipboard_write_bytes)
        record.clipboard.buffer = buffer
    elseif record.kind ~= kinds.bell and record.kind ~= kinds.attention then
        error("unsupported Effect body", 0)
    end
    if not r.ended() then error("trailing Effect bytes", 0) end
    packet.record = record
    return packet
end

-- Restore only locally retained receipts for the same authenticated host/pane.
-- The caller owns that binding; a host-supplied cursor is never a receipt.
function M.new(receipt)
    local state = { acknowledged = zero, consumed = zero }
    if receipt then
        if type(receipt.acknowledged) ~= "string" or #receipt.acknowledged ~= 8
            or type(receipt.consumed) ~= "string" or #receipt.consumed ~= 8
            or M.compare(receipt.acknowledged, receipt.consumed) > 0 then error("invalid effect receipt", 0) end
        state.acknowledged, state.consumed = receipt.acknowledged, receipt.consumed
    end
    return state
end

-- Accept after payload readiness, preserving the partial-batch consumed cursor
-- before a reentrant application callback. Only the final packet advances ACK.
function M.accept(state, packet, applied_generation)
    if not applied_generation or M.compare(packet.generation, applied_generation) > 0
        or M.compare(packet.through, state.consumed) < 0 then error("Effect outside its picture boundary", 0) end
    if state.pending and (packet.through ~= state.pending or packet.generation ~= state.generation
        or packet.remaining ~= state.remaining or not packet.record) then error("Effect batch changed", 0) end
    if packet.record and state.pending and M.compare(packet.record.sequence, state.last) <= 0 then error("Effect sequence out of order", 0) end
    local record = packet.record
    local deliver = record and M.compare(record.sequence, state.consumed) > 0
    if deliver then state.consumed = record.sequence end
    if packet.remaining > 0 then
        state.pending, state.generation, state.remaining, state.last = packet.through, packet.generation, packet.remaining - 1, record.sequence
    else
        state.acknowledged, state.consumed = packet.through, packet.through
        state.pending, state.generation, state.remaining, state.last = nil, nil, nil, nil
    end
    return deliver and record or nil
end

return M
