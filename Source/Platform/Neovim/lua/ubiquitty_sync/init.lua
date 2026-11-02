-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- ubiquitty_sync — a Neovim client for the ubiquitty-host Sync protocol.
--
-- The terminal Core runs in the daemon. This module attaches to it through the
-- host's own attach bridge (`ubiquitty-host --attach`), turns each Sync
-- checkpoint and update into escape sequences, and hands those to a Neovim
-- terminal buffer, whose libvterm draws the screen. What is typed into that
-- buffer goes back as Sync input, numbered per pane: the bytes the embedded
-- terminal encoded as Raw, and a bracketed paste as Paste pieces the host
-- brackets itself.
--
-- The bridge rather than the daemon's socket: the daemon admits a tokenless
-- local peer only when the peer's kernel-verified executable is one of its own
-- binaries, so a socket opened from nvim itself receives a typed refusal.
-- The bridge's stdout carries the frame stream; its stderr is read apart from
-- it and its last line is what a disconnect reports.
--
-- Usage: require("ubiquitty_sync").setup({ host_program = "..." }), then
-- :UbiquittySync. Keys are Neovim's terminal-mode keys; <C-\><C-n> leaves
-- terminal mode and :UbiquittySync detach ends this attach.

local M = {}

local uv = vim.uv or vim.loop
local band = bit.band
local byte = string.byte
local char = string.char
local floor = math.floor

-- ---- protocol constants -----------------------------------------------------
--
-- The numbers this client shares with the host are in ubiquitty_sync/wire.lua,
-- written from the host's headers by Scripts/gen-wire-tables.py: the wire
-- version, the frame tags and kinds, the capability and attribute bits, the
-- reasons. None of them is typed here. What follows them is this client's own:
-- what it chooses, and layouts no header declares.
local wire = require("ubiquitty_sync.wire")
local sha256 = require("ubiquitty_sync.sha256")
local effects = require("ubiquitty_sync.effects")

-- The Sync wire version this client speaks; a host at any other is refused.
local wire_version = wire.wire_version
local pen_wire = wire.pen_wire
local text_size_table_capacity = wire.text_size_table_capacity
local text_size_spec_wire = wire.text_size_spec_wire_bytes
local text_size_spec_proportional_offset = wire.text_size_spec_proportional_offset
-- Aggregate retained asset allowance, not a transport frame bound.
local retained_asset_budget = 72 * 1024 * 1024
-- Update bytes held while a checkpoint is in flight, the cap Docs/sync.md
-- section 7.9 states; past it the client asks for a fresh checkpoint instead.
local max_buffered_update_bytes = 1024 * 1024

local max_frame_body = wire.max_frame_body
-- Typed bytes go a piece at a time, each well inside one frame.
local raw_piece_bytes = 4096
-- A paste is handed to the transport at most this much at once (Docs/sync.md
-- section 6.7), below the host's chunk cap, so a key behind one piece waits
-- for little.
local paste_piece_bytes = wire.paste_piece_bytes

M.wire_version = wire_version

local kind = wire.kind

-- The kinds only a client sends. One arriving from the host is a protocol
-- error, not a frame to step over. A client calls and a host answers: no
-- client serves a method, so a Call is among them.
local client_only_kind = wire.client_only_kind

-- The kinds a host sends that this client asked for nothing of: it keeps no
-- history, shows its one pane always, draws no program-status records,
-- lays out no workspace and lists no host, so these
-- are read past by their frame length. A shown pane's palette arrives in its
-- updates; a PanePalette is sent only for a pane held Dormant. A structure
-- too large for a frame follows as a bulk transfer nothing here is waiting
-- for, and its chunks are dropped when the last one arrives.
local unsolicited_kind = {
    [kind.workspace_structure] = true, [kind.pane_listed] = true,
    [kind.pane_dirty] = true, [kind.pane_palette] = true, [kind.history_inline] = true, [kind.history_head] = true, [kind.history_reset] = true,
    [kind.status_records] = true,
}

-- Greet capability bits. This client names the echo context alone: it takes
-- whole checkpoints and whole rows.
local capability = wire.capability
M.capability = capability

-- A paste piece's state.
local paste_more, paste_final = wire.paste_state.more, wire.paste_state.final

-- The interrupt, quit and suspend characters of a terminal nobody has
-- described yet: a pane whose echo context is unknown.
local default_interrupt_characters = wire.default_interrupt_characters

local bye_reasons = wire.bye_reasons

-- Every kind byte the wire defines at this version.
M.known_kind = {}
for _, value in pairs(kind) do
    M.known_kind[value] = true
end

-- The view state that has the host send a pane's screen.
local view_live = wire.view_state.live
M.kind = kind

local resync_reason = wire.resync_reason
M.resync_reason = resync_reason

-- Pen colour-index sentinels.
local color_default = wire.color_default -- the terminal default
local color_rgb = wire.color_rgb -- the direct RGB bytes

-- SGR attribute bits.
local attribute = wire.attribute

-- The state blocks a checkpoint carries, by StateBlock number, and the order
-- they travel in (`checkpointBlockOrder` in
-- Source/Core/Protocol/Sync/ScreenPlane.cpp).
local block = wire.block
local checkpoint_block_order = {
    block.modes, block.palette, block.cursor, block.screen_states, block.text_state, block.activity, block.rich_text,
}

-- The modes block leads with this many one-byte flags (`modeFlags` in
-- Source/Core/Protocol/Sync/ScreenPlane.cpp); seven integers follow them,
-- then the alternate-scroll flag.
local mode_flag_count = 57
local mode_flag = {
    cursor_visible = 0,
    application_cursor = 2,
    application_keypad = 3,
    bracketed_paste = 4,
    reverse_video = 16,
    mouse_x10 = 24,
    mouse_button_tracking = 25,
    mouse_sgr = 26,
    mouse_cell_motion = 27,
    mouse_any_event = 28,
    mouse_utf8 = 29,
    mouse_urxvt = 30,
    mouse_sgr_pixels = 31,
}

-- The modes the embedded terminal mirrors, so the keys and mouse reports it
-- encodes are the ones the host's program asked for. A mode the embedded
-- terminal does not implement ignores its sequence, which leaves the encoding
-- where it was rather than claiming one nobody chose.
local mirrored_modes = {
    { flag = mode_flag.mouse_button_tracking, set = "\27[?1000h", reset = "\27[?1000l" },
    { flag = mode_flag.mouse_cell_motion, set = "\27[?1002h", reset = "\27[?1002l" },
    { flag = mode_flag.mouse_any_event, set = "\27[?1003h", reset = "\27[?1003l" },
    { flag = mode_flag.mouse_sgr, set = "\27[?1006h", reset = "\27[?1006l" },
    { flag = mode_flag.mouse_sgr_pixels, set = "\27[?1016h", reset = "\27[?1016l" },
    { flag = mode_flag.mouse_utf8, set = "\27[?1005h", reset = "\27[?1005l" },
    { flag = mode_flag.mouse_urxvt, set = "\27[?1015h", reset = "\27[?1015l" },
    { flag = "alternate_scroll", set = "\27[?1007h", reset = "\27[?1007l" },
    { flag = mode_flag.application_cursor, set = "\27[?1h", reset = "\27[?1l" },
    { flag = mode_flag.application_keypad, set = "\27=", reset = "\27>" },
    { flag = mode_flag.bracketed_paste, set = "\27[?2004h", reset = "\27[?2004l" },
    { flag = mode_flag.mouse_x10, set = "\27[?9h", reset = "\27[?9l" },
}

-- ---- little-endian readers (zero-based offsets into a byte string) ---------

local function u8(s, at)
    return byte(s, at + 1)
end

local function u16(s, at)
    local a, b = byte(s, at + 1, at + 2)
    return a + b * 256
end

local function u32(s, at)
    local a, b, c, d = byte(s, at + 1, at + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- A generation or a host time as a Lua number; exact below 2^53.
local function u64(s, at)
    return u32(s, at) + u32(s, at + 4) * 4294967296
end

-- A reader over `s` from `start` to `stop`. Every read checks the end, so a
-- body shorter than its fields claim raises rather than reading the next
-- frame's bytes as this one's.
local function reader(s, start, stop)
    return { s = s, at = start or 0, stop = stop or #s }
end

local function take(r, count)
    local at = r.at
    if at + count > r.stop then
        error(string.format("ubiquitty_sync: a Sync body ends at %d, a field runs to %d", r.stop, at + count), 0)
    end
    r.at = at + count
    return at
end

local function r_u8(r)
    return u8(r.s, take(r, 1))
end

local function r_u16(r)
    return u16(r.s, take(r, 2))
end

local function r_u32(r)
    return u32(r.s, take(r, 4))
end

local function r_u64(r)
    return u64(r.s, take(r, 8))
end

-- An unsigned LEB128 of at most ten bytes.
local function r_varint(r)
    local value, scale = 0, 1
    for _ = 1, 10 do
        local b = r_u8(r)
        value = value + (b % 128) * scale
        if b < 128 then
            return value
        end
        scale = scale * 128
    end
    error("ubiquitty_sync: a varint runs past ten bytes", 0)
end

local function r_svarint(r)
    local value = r_varint(r)
    if value % 2 == 0 then
        return value / 2
    end
    return -(value + 1) / 2
end

-- A varint-length byte run.
local function r_bytes(r)
    local count = r_varint(r)
    local at = take(r, count)
    return r.s:sub(at + 1, at + count)
end

local function r_text(r, maximum)
    local before = r.at
    local size = r_varint(r)
    local groups, remaining = 1, size
    while remaining >= 128 do groups, remaining = groups + 1, floor(remaining / 128) end
    if size > maximum or r.at - before ~= groups then error("invalid text length", 0) end
    local at = take(r, size)
    local value = r.s:sub(at + 1, at + size)
    if value:find("\0", 1, true) or not effects.valid_utf8(value) then
        error("invalid wire text", 0)
    end
    return value
end

local function r_count(r, maximum)
    local before = r.at
    local count, groups = r_varint(r), 1
    local remaining = count
    while remaining >= 128 do groups, remaining = groups + 1, floor(remaining / 128) end
    if count > maximum or r.at - before ~= groups then error("invalid bounded count", 0) end
    return count
end

local function at_end(r)
    return r.at == r.stop
end

-- This frontend embeds Neovim's text terminal, not an image renderer. It
-- validates the image grammar but never caches pixels or requests an asset.
-- Freshly pushed pixels are consumed one bounded frame at a time, not joined.
local function read_image_asset(r)
    local at = take(r, 16)
    local asset = { hash = r.s:sub(at + 1, at + 16), format = r_u8(r), width = r_u32(r), height = r_u32(r) }
    if (asset.format ~= 24 and asset.format ~= 32) or asset.width == 0 or asset.height == 0
        or asset.width > wire.max_image_dimension or asset.height > wire.max_image_dimension then
        error("ubiquitty_sync: invalid decoded image dimensions or format", 0)
    end
    asset.pixel_bytes = asset.width * asset.height * (asset.format / 8)
    if asset.pixel_bytes > wire.max_image_bytes then error("ubiquitty_sync: decoded image exceeds its byte limit", 0) end
    return asset
end

local function same_image_asset(first, second)
    return first.hash == second.hash and first.format == second.format and first.width == second.width and first.height == second.height
end

function M.read_image_head(body)
    local r = reader(body)
    local asset = read_image_asset(r)
    local transfer = r_u32(r)
    if not at_end(r) then error("ubiquitty_sync: trailing ImageHead bytes", 0) end
    return { asset = asset, transfer = transfer }
end

function M.read_image_placements(body)
    local r = reader(body)
    local revision = r_u32(r)
    local images, assets = {}, {}
    local function count(maximum, minimum_bytes)
        local start = r.at
        local value = r_varint(r)
        if value > maximum or value * minimum_bytes > r.stop - r.at or r.at - start ~= (value < 128 and 1 or 2) then
            error("ubiquitty_sync: invalid image record count", 0)
        end
        return value
    end
    local function flag()
        if r_u8(r) > 1 then error("ubiquitty_sync: unknown image flag", 0) end
    end
    if revision == 0 then error("ubiquitty_sync: zero image revision", 0) end
    for _ = 1, count(wire.max_image_count, wire.image_binding_record_bytes) do
        local start = r.at
        local id = r_u32(r)
        take(r, 4) -- program image number
        local asset = read_image_asset(r)
        flag() -- virtual placement
        take(r, 8) -- virtual columns, rows and placement ID
        if r.at - start ~= wire.image_binding_record_bytes then
            error("ubiquitty_sync: an image binding is not the host's record length", 0)
        end
        if id == 0 or images[id] or (assets[asset.hash] and not same_image_asset(assets[asset.hash], asset)) then
            error("ubiquitty_sync: inconsistent image binding", 0)
        end
        images[id], assets[asset.hash] = asset, asset
    end
    local placements = {}
    for _ = 1, count(wire.max_image_placements, wire.image_placement_record_bytes) do
        local at = take(r, 16)
        local hash = r.s:sub(at + 1, at + 16)
        local id = r_u32(r)
        take(r, 4) -- placement ID
        flag() -- whether the placement ID is present
        local placement = { id = id }
        placement.column, placement.row = r_u16(r), r_u16(r)
        if placement.row >= 32768 then placement.row = placement.row - 65536 end
        placement.columns, placement.rows = r_u16(r), r_u16(r)
        take(r, 12) -- pixel offset and source rectangle
        placement.drawn_width, placement.drawn_height = r_u16(r), r_u16(r)
        take(r, 4) -- z-index
        flag() -- cursor policy
        flag() -- alternate screen
        if r.at - at ~= wire.image_placement_record_bytes then
            error("ubiquitty_sync: an image placement is not the host's record length", 0)
        end
        if (placement.drawn_width == 0) ~= (placement.drawn_height == 0) then
            error("ubiquitty_sync: a placement states half a drawn size", 0)
        end
        if not images[id] or images[id].hash ~= hash then error("ubiquitty_sync: placement names an absent image", 0) end
        placements[#placements + 1] = placement
    end
    if not at_end(r) then error("ubiquitty_sync: trailing ImagePlacements bytes", 0) end
    return { revision = revision, images = images, assets = assets, placements = placements }
end

-- Consume the whole fixed-layout record before publishing its title. Bounds
-- come from the host headers; unused fields are checked, not trusted tails.
function M.read_pane_facts(body)
    local r = reader(body)
    local function text(maximum)
        local length = r_varint(r)
        if length > maximum then error("ubiquitty_sync: PaneFacts text exceeds its limit", 0) end
        local at = take(r, length)
        return r.s:sub(at + 1, at + length)
    end
    local function flags(known)
        local value = r_u8(r)
        if value > known then error("ubiquitty_sync: unknown PaneFacts flag", 0) end
        return value
    end
    local function signed32()
        local value = r_svarint(r)
        if value < -2147483648 or value > 2147483647 then
            error("ubiquitty_sync: PaneFacts integer exceeds int32", 0)
        end
    end
    local facts = { revision = r_u32(r) }
    facts.title = text(wire.max_title_bytes)
    facts.directory = text(wire.max_directory_bytes)
    text(wire.max_home_bytes)
    text(wire.max_file_url_bytes)
    text(wire.max_process_chain_bytes)
    text(wire.max_process_arguments_bytes)
    for _ = 1, 3 do text(wire.max_process_name_bytes) end
    take(r, 4) -- rows, columns
    flags(7) -- ended, has status, signalled
    signed32()
    take(r, 4) -- foreground pid
    facts.foreground = text(wire.max_process_name_bytes)
    take(r, 4) -- foreground generation
    local pane = flags(63)
    facts.at_prompt = band(pane, 1) ~= 0
    local progress, percent = r_u8(r), r_u8(r)
    if progress > wire.max_progress_state or percent > 100 then error("ubiquitty_sync: invalid PaneFacts progress", 0) end
    if band(pane, 2) ~= 0 then take(r, 3); text(wire.max_indicator_bytes) end
    if band(pane, 4) ~= 0 then take(r, 3) end
    text(wire.max_badge_bytes)
    local count, names = r_varint(r), {}
    if count > wire.max_user_variables then error("ubiquitty_sync: too many PaneFacts variables", 0) end
    for _ = 1, count do
        local name = text(wire.max_user_name_bytes)
        if name == "" or names[name] then error("ubiquitty_sync: duplicate or empty PaneFacts variable", 0) end
        names[name] = true
        text(wire.max_user_value_bytes)
    end
    if band(pane, 8) ~= 0 then signed32() end
    take(r, 8) -- pixel dimensions
    local geometry = flags(15)
    if band(geometry, 1) ~= 0 then take(r, 16) end
    if band(geometry, 8) ~= 0 then
        if band(geometry, 2) == 0 then error("ubiquitty_sync: PaneFacts pin without a pin state", 0) end
        take(r, 16)
    end
    take(r, 24) -- last output, last input, creation
    local attention = flags(3)
    local title, message = text(wire.max_attention_bytes), text(wire.max_attention_bytes)
    if band(attention, 2) == 0 and (title ~= "" or message ~= "") then
        error("ubiquitty_sync: PaneFacts notification text without a notification", 0)
    end
    if not at_end(r) then error("ubiquitty_sync: trailing PaneFacts bytes", 0) end
    return facts
end

-- ---- little-endian writers -------------------------------------------------

local function put_u16(n)
    return char(n % 256, floor(n / 256) % 256)
end

local function put_u32(n)
    return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

local function put_u64(n)
    return put_u32(n % 4294967296) .. put_u32(floor(n / 4294967296))
end

local function exact_u64(value)
    if type(value) == "string" and #value == 8 then return value end
    if type(value) ~= "number" or value < 0 or value > 9007199254740991 or value ~= floor(value) then
        error("an exact u64 requires eight bytes", 0)
    end
    return put_u64(value)
end

local function put_varint(n)
    local out = {}
    while n >= 128 do
        out[#out + 1] = char(128 + n % 128)
        n = floor(n / 128)
    end
    out[#out + 1] = char(n)
    return table.concat(out)
end

-- One direct canonical envelope.
local function sync_frame(frame_kind, channel, body)
    if #body > max_frame_body then error("oversized envelope body", 0) end
    return char(frame_kind) .. put_varint(channel) .. put_varint(#body) .. body
end
M.sync_frame = sync_frame

-- Header-only validation. Incomplete headers return nil; malformed headers
-- fail permanently before the stream reader retains any body bytes.
local function envelope_header(bytes)
    if #bytes == 0 then return nil end
    local frame_kind, at = byte(bytes, 1), 2
    if not M.known_kind[frame_kind] then error("unknown envelope kind " .. frame_kind, 0) end
    local values = {}
    for field, limit in ipairs({ { 5, wire.max_channel }, { 3, max_frame_body } }) do
        local value, scale, done = 0, 1, false
        for index = 1, limit[1] do
            if at > #bytes then return nil end
            local value_byte = byte(bytes, at)
            at = at + 1
            value = value + (value_byte % 128) * scale
            if value > limit[2] then error("oversized envelope varint", 0) end
            if value_byte < 128 then
                if index > 1 and value_byte == 0 then error("nonminimal envelope varint", 0) end
                done = true
                break
            end
            scale = scale * 128
        end
        if not done then error("unterminated envelope varint", 0) end
        values[field] = value
        if field == 1 and ((value == 0) ~= (wire.connection_kind[frame_kind] == true)) then
            error("wrong envelope scope", 0)
        end
    end
    return { kind = frame_kind, channel = values[1], size = values[2], bytes = at - 1 }
end
M.envelope_header = envelope_header

local function admit_header(connection, header)
    local frame_kind, size = header.kind, header.size
    if connection.transport_closed then error("data after Bye", 0) end
    if client_only_kind[frame_kind] then error("kind " .. frame_kind .. " from the host, which only a client sends", 0) end
    if not connection.welcome and frame_kind ~= kind.welcome and frame_kind ~= kind.bye then
        error("data before Welcome", 0)
    end
    if connection.welcome and frame_kind == kind.welcome then error("duplicate Welcome", 0) end
    if connection.welcome and frame_kind == kind.pane_bind and connection.welcome.target >= wire.admission_target.control then
        error("PaneBind on an unbound target", 0)
    end
    if connection.consent_phase and connection.consent_phase ~= "approved" then
        if frame_kind ~= kind.probe and frame_kind ~= kind.echo and frame_kind ~= kind.bye and frame_kind ~= kind.notify then
            error("data before own consent", 0)
        end
        if (frame_kind == kind.notify and (size > wire.max_consent_status_bytes
                or connection.consent_phase == "denied" or connection.consent_phase == "expired"))
            or (frame_kind == kind.probe and size ~= 8) or (frame_kind == kind.echo and size ~= 12) then
            error("invalid pending-consent frame", 0)
        end
    end
end

-- ---- text -------------------------------------------------------------------

local function utf8_char(code_point)
    if code_point < 0x80 then
        return char(code_point)
    end
    if code_point < 0x800 then
        return char(0xC0 + floor(code_point / 64), 0x80 + code_point % 64)
    end
    if code_point < 0x10000 then
        return char(0xE0 + floor(code_point / 4096), 0x80 + floor(code_point / 64) % 64, 0x80 + code_point % 64)
    end
    if code_point < 0x110000 then
        return char(0xF0 + floor(code_point / 262144), 0x80 + floor(code_point / 4096) % 64,
            0x80 + floor(code_point / 64) % 64, 0x80 + code_point % 64)
    end
    return " "
end

-- A code-point list: a varint count, then each point as a varint. An unwritten
-- point is a space, which is what a cell holding one draws.
local function r_code_points(r)
    local parts = {}
    for index = 1, r_varint(r) do
        local code_point = r_varint(r)
        parts[index] = (code_point == 0) and " " or utf8_char(code_point)
    end
    return table.concat(parts)
end

-- The code points of a UTF-8 string, each as its own substring with its value.
local function code_points(text)
    local points = {}
    local at = 1
    while at <= #text do
        local lead = byte(text, at)
        local length = lead < 0x80 and 1 or lead < 0xE0 and 2 or lead < 0xF0 and 3 or 4
        local value = lead
        if length > 1 then
            value = lead % (2 ^ (7 - length))
            for index = 1, length - 1 do
                value = value * 64 + byte(text, at + index) % 64
            end
        end
        points[#points + 1] = { text = text:sub(at, at + length - 1), value = value }
        at = at + length
    end
    return points
end

-- A run's text in the cells the host says the run claims: clipped to them, and
-- padded to them so the columns after the run stand where the host put them.
local function fit_to_cells(text, cells)
    local width = vim.api.nvim_strwidth(text)
    while width > cells do
        text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
        width = vim.api.nvim_strwidth(text)
    end
    return text .. string.rep(" ", cells - width)
end

-- ---- rows -------------------------------------------------------------------
--
-- A row travels as a RowRecord (Source/Core/Protocol/Sync/RowForm.h): the
-- line attribute, the wrap flag and mark, the extent past which every cell is
-- the canonical blank, the text of each unit's lead cell, and run-length and
-- gap-coded lists over units. A unit is one cell, or a wide lead and the
-- continuation the Core writes beside it, whose continuation never travels.

local function r_runs(r)
    local runs = {}
    for index = 1, r_varint(r) do
        local units = r_varint(r)
        if units == 0 then
            error("ubiquitty_sync: a run of no units", 0)
        end
        runs[index] = { units = units, value = r_varint(r) }
    end
    return runs
end

-- A gap-coded list as a table from unit to value; an entry without a value
-- maps to true.
local function r_gaps(r, valued)
    local entries = {}
    local unit = 0
    for index = 1, r_varint(r) do
        local gap = r_varint(r)
        if index > 1 and gap == 0 then
            error("ubiquitty_sync: a gap list that does not ascend", 0)
        end
        unit = unit + gap
        entries[unit] = valued and r_varint(r) or true
    end
    return entries
end

-- The text-size spec id a pen names: bits 1-4 of its extended attributes.
local function pen_spec(pen)
    return floor(u8(pen, 18) / 2) % 16
end

-- The text a unit draws: its lead cell's code points, unless its cluster
-- reference names a store entry. The two stores share one id space, and the
-- pen's text-size spec is what says which the id reads: a proportional spec
-- reads the run-text store, any other the cluster pool. An unwritten cell, a
-- control code and a kitty image placeholder draw as a space.
local function unit_text(connection, points, pen, cluster, run_width)
    if cluster then
        local spec = pen_spec(pen)
        if spec ~= 0 and connection.proportional[spec] then
            local run = connection.runs[cluster]
            if run then
                return fit_to_cells(run, run_width)
            end
        end
        local pooled = connection.clusters[cluster]
        if pooled then
            return pooled
        end
    end
    local lead = points[1] and points[1].value or 0
    if lead < 32 or lead == 0x10EEEE then
        return " "
    end
    local parts = {}
    for index, point in ipairs(points) do
        parts[index] = point.text
    end
    return table.concat(parts)
end

-- Decodes one RowRecord into `columns` cells, each nil past the extent (the
-- canonical blank) or { text, pen, continuation }; a continuation cell draws
-- nothing, since the glyph before it covers its column.
--
-- - Returns: the cells and the row's line attribute.
local function decode_row(connection, record, columns)
    local r = reader(record)
    local line_attribute = r_u8(r)
    r_u8(r) -- the wrap flag
    r_u8(r) -- the OSC 133 mark
    local extent = r_varint(r)
    local points = code_points(r_bytes(r))
    local runs = r_runs(r)
    r_runs(r) -- the OSC 8 links, which a terminal buffer does not draw
    local clusters = r_gaps(r, true)
    local references = r_gaps(r, true)
    local kept = r_gaps(r, false)
    if not at_end(r) then
        error("ubiquitty_sync: a RowRecord longer than its lists", 0)
    end
    if extent > columns then
        error(string.format("ubiquitty_sync: a row of extent %d on a %d-column screen", extent, columns), 0)
    end

    local entries = {}
    local column = 0
    local offset = 1
    local unit = 0
    for _, run in ipairs(runs) do
        local pen = connection.pens[run.value]
        if not pen then
            error(string.format("ubiquitty_sync: a run names pen %d, which is not defined", run.value), 0)
        end
        local attributes = u16(pen, 0)
        for _ = 1, run.units do
            local count = clusters[unit] or 1
            local unit_points = {}
            for index = 1, count do
                unit_points[index] = points[offset + index - 1]
                if not unit_points[index] then
                    error("ubiquitty_sync: a RowRecord's units outrun its text", 0)
                end
            end
            offset = offset + count
            local span = (band(attributes, attribute.wide) ~= 0 and not kept[unit]) and 2 or 1
            entries[#entries + 1] = {
                column = column,
                points = unit_points,
                pen = pen,
                cluster = references[unit],
                continuation = band(attributes, attribute.wide_continuation) ~= 0,
                span = span,
            }
            column = column + span
            unit = unit + 1
        end
    end
    if column ~= extent or offset ~= #points + 1 then
        error(string.format("ubiquitty_sync: a RowRecord whose units fill %d of %d cells", column, extent), 0)
    end

    local cells = {}
    for index, entry in ipairs(entries) do
        if entry.continuation then
            cells[entry.column + 1] = { continuation = true, pen = entry.pen }
        else
            -- A run claims its anchor and the continuation cells after it.
            local run_width = entry.span
            local next = index + 1
            while entries[next] and entries[next].continuation do
                run_width = run_width + 1
                next = next + 1
            end
            cells[entry.column + 1] = {
                text = unit_text(connection, entry.points, entry.pen, entry.cluster, run_width),
                pen = entry.pen,
            }
            if entry.span == 2 then
                cells[entry.column + 2] = { continuation = true, pen = entry.pen }
            end
        end
    end
    return cells, line_attribute
end

-- ---- SGR --------------------------------------------------------------------

-- The colour parameters for one channel: 256-colour for an index, direct RGB
-- for the sentinel, and nothing for the default, which is the buffer's own
-- Normal colour.
local function color_parameters(select, index, red, green, blue)
    if index == color_rgb then
        return ";" .. select .. ";2;" .. red .. ";" .. green .. ";" .. blue
    end
    if index < 256 then
        return ";" .. select .. ";5;" .. index
    end
    return ""
end

-- The SGR sequence that sets the terminal's pen to one pen. A reset leads so
-- the sequence is the whole pen rather than an edit of the previous one.
local function pen_sgr(pen, screen_reversed)
    local attributes = u16(pen, 0)
    local parts = { "\27[0" }
    if band(attributes, attribute.bold) ~= 0 then
        parts[#parts + 1] = ";1"
    end
    if band(attributes, attribute.dim) ~= 0 then
        parts[#parts + 1] = ";2"
    end
    if band(attributes, attribute.italic) ~= 0 then
        parts[#parts + 1] = ";3"
    end
    if band(attributes, attribute.underline) ~= 0 then
        parts[#parts + 1] = ";4"
    end
    local reversed = band(attributes, attribute.reverse) ~= 0
    if screen_reversed then
        reversed = not reversed
    end
    if reversed then
        parts[#parts + 1] = ";7"
    end
    if band(attributes, attribute.hidden) ~= 0 then
        parts[#parts + 1] = ";8"
    end
    if band(attributes, attribute.strike) ~= 0 then
        parts[#parts + 1] = ";9"
    end
    parts[#parts + 1] = color_parameters("38", u16(pen, 2), u8(pen, 8), u8(pen, 9), u8(pen, 10))
    parts[#parts + 1] = color_parameters("48", u16(pen, 4), u8(pen, 11), u8(pen, 12), u8(pen, 13))
    parts[#parts + 1] = "m"
    return table.concat(parts)
end

-- A cell the terminal's erase produces on its own: past the extent, or a space
-- with the default background and no decoration the erase would drop. A wide
-- glyph's continuation cell is not one of these: the glyph before it already
-- covers the column, and an erase from there takes the half the lead painted.
local function is_default_blank(cell)
    if cell == nil then
        return true
    end
    if cell.continuation or cell.text ~= " " then
        return false
    end
    if band(u16(cell.pen, 0), attribute.underline + attribute.reverse + attribute.strike) ~= 0 then
        return false
    end
    return u16(cell.pen, 4) == color_default
end

local function cursor_position(row, column)
    return "\27[" .. (row + 1) .. ";" .. (column + 1) .. "H"
end

-- Places the cursor and applies its DECSCUSR shape and DECTCEM visibility.
local function cursor_sequence(connection)
    local cursor = connection.cursor
    return cursor_position(cursor.row, cursor.column)
        .. "\27[" .. cursor.style .. " q"
        .. (connection.cursor_visible and "\27[?25h" or "\27[?25l")
end

-- Appends the sequences painting one row from its first column: a run of one
-- pen carries one SGR, a continuation cell draws nothing and the cell after it
-- is positioned explicitly because the lead glyph's width is the terminal's to
-- decide, and the row's trailing default blanks are one erase.
local function paint_row(out, cells, row, columns, state)
    local last = columns
    if not state.screen_reversed then
        while last > 0 and is_default_blank(cells[last]) do
            last = last - 1
        end
    end
    out[#out + 1] = cursor_position(row, 0)
    local needs_position = false
    for column = 1, last do
        local cell = cells[column]
        if cell and cell.continuation then
            needs_position = true
        else
            if needs_position then
                out[#out + 1] = cursor_position(row, column - 1)
                needs_position = false
            end
            if cell then
                if cell.pen ~= state.pen then
                    state.pen = cell.pen
                    out[#out + 1] = pen_sgr(cell.pen, state.screen_reversed)
                end
                out[#out + 1] = cell.text
            else
                if state.pen ~= false then
                    state.pen = false
                    out[#out + 1] = state.screen_reversed and "\27[0;7m" or "\27[0m"
                end
                out[#out + 1] = " "
            end
        end
    end
    if last < columns then
        out[#out + 1] = "\27[0m\27[K"
        state.pen = false
    end
end

-- The text of one row of the shown screen as a reader sees it, continuation
-- cells omitted.
function M.row_text(connection, row)
    local cells = connection.screens[connection.active + 1][row + 1].cells
    local out = {}
    for column = 1, connection.columns_held do
        local cell = cells[column]
        if not (cell and cell.continuation) then
            out[#out + 1] = cell and cell.text or " "
        end
    end
    return table.concat(out)
end

-- ---- state blocks -----------------------------------------------------------
--
-- A checkpoint carries seven state blocks, each a length-prefixed byte run, and
-- an update the ones whose bytes moved. This client reads the mode flags, the
-- cursor and the text-size table, and steps over the rest by the block's own
-- length; colours render through the embedded terminal's palette.

-- The leading mode flags and the alternate-scroll flag after them.
local function read_modes_block(bytes)
    local r = reader(bytes)
    local flags = {}
    for index = 0, mode_flag_count - 1 do
        local value = r_u8(r)
        if value > 1 then
            error("ubiquitty_sync: a mode flag of " .. value, 0)
        end
        flags[index] = value == 1
    end
    for _ = 1, 7 do -- sace, the sync-output clock, four hilite fields, the hilite deadline
        r_varint(r)
    end
    flags.alternate_scroll = r_u8(r) == 1
    return flags
end

local function read_cursor_block(bytes)
    local r = reader(bytes)
    local column = r_svarint(r)
    local row = r_svarint(r)
    r_u8(r) -- the deferred-wrap latch
    local style = r_varint(r) -- raw DECSCUSR; 0 = the application set none
    if not at_end(r) then
        error("ubiquitty_sync: a cursor block longer than its fields", 0)
    end
    return { row = row, column = column, style = style }
end

-- The proportional specs the text-state block's text-size table names. The
-- table sits after the character sets, the titles and their stacks, the
-- pointer-shape stack, the sixel registers, the tab stops and the user-defined
-- keys, so those are walked to reach it.
local function read_text_size_specs(bytes)
    local r = reader(bytes)
    for _ = 1, 8 do -- G0-G3, GL, GR, the single shift, the open link
        r_varint(r)
    end
    for _ = 1, 22 do -- title, icon name, and their two stacks of ten
        r_bytes(r)
    end
    for _ = 1, 39 do -- title masks, two pointer stacks, line role, home
        r_varint(r)
    end
    for _ = 1, r_varint(r) do -- the sixel registers that moved
        r_varint(r)
        r_varint(r)
    end
    for _ = 1, r_varint(r) do -- the tab stops that are set
        r_varint(r)
        r_u8(r)
    end
    for _ = 1, 2 do -- tab alignments and target characters
        for _ = 1, r_varint(r) do
            r_varint(r)
            r_varint(r)
        end
    end
    for _ = 1, r_varint(r) do -- line tabulation stops
        r_varint(r)
        r_u8(r)
    end
    if r_u8(r) == 1 then -- the user-defined keys
        r_u8(r)
        for _ = 1, r_varint(r) do
            r_u16(r)
            r_bytes(r)
        end
    end
    local live = r_u16(r)
    local proportional = {}
    for slot = 0, text_size_table_capacity - 1 do
        local at = take(r, text_size_spec_wire)
        if band(floor(live / 2 ^ slot), 1) == 1 and u8(bytes, at + text_size_spec_proportional_offset) ~= 0 then
            proportional[slot + 1] = true
        end
    end
    return proportional
end

-- Takes one state block. Returns true when every cell has to be laid out
-- again: the text-size table decides which store a cell's cluster reads, and
-- reverse video inverts every pen.
local function apply_block(connection, index, bytes)
    if index == block.cursor then
        connection.cursor = read_cursor_block(bytes)
    elseif index == block.modes then
        local flags = read_modes_block(bytes)
        connection.cursor_visible = flags[mode_flag.cursor_visible]
        connection.modes = flags
        local reversed = flags[mode_flag.reverse_video]
        -- Suffix: CRT blanking, key-position mode, reported and disabled modifiers.
        local blanked = bytes:byte(-4)
        if blanked ~= 0 and blanked ~= 1 then
            error("ubiquitty_sync: invalid CRT blanking flag", 0)
        end
        local is_blanked = blanked == 1
        local changed = reversed ~= connection.reverse_video or is_blanked ~= connection.crt_blanked
        connection.reverse_video = reversed
        connection.crt_blanked = is_blanked
        return changed
    elseif index == block.text_state then
        connection.proportional = read_text_size_specs(bytes)
        return true
    end
    return false
end

-- Steps over one rich text block's definition (Sync/RichTextForm.h): its
-- serial and document. This client draws the cells a block covers and not the
-- block.
local function skip_rich_text_definition(r)
    r_varint(r) -- serial
    for _ = 1, r_varint(r) do -- text
        r_varint(r)
    end
    for _ = 1, r_varint(r) do -- runs: length, half-points, font, colour, styles, alignment
        r_varint(r)
        r_u16(r)
        take(r, 4)
    end
    for _ = 1, r_varint(r) do -- fonts: class, name
        r_u8(r)
        r_bytes(r)
    end
    for _ = 1, r_varint(r) do -- colours
        take(r, 4)
    end
end

-- ---- screens ----------------------------------------------------------------

-- Lays out every row of both screens again from their records.
local function lay_out_screens(connection)
    for screen = 1, 2 do
        local rows = {}
        for row, record in ipairs(connection.records[screen]) do
            local cells, line_attribute = decode_row(connection, record, connection.columns_held)
            rows[row] = { cells = cells, line_attribute = line_attribute }
        end
        connection.screens[screen] = rows
    end
end

-- The escape sequences that paint the shown screen's rows `rows` (every row
-- when nil), the modes the embedded terminal mirrors, and the cursor last.
local function render(connection, rows)
    local out = { M.mode_sequence(connection, connection.modes), "\27[?25l\27[0m" }
    if connection.crt_blanked then
        out[#out + 1] = "\27[40m\27[2J"
        return table.concat(out)
    end
    local state = { pen = false, screen_reversed = connection.reverse_video }
    local shown = connection.screens[connection.active + 1]
    for row = 1, #shown do
        if rows == nil or rows[row] then
            paint_row(out, shown[row].cells, row - 1, connection.columns_held, state)
        end
    end
    out[#out + 1] = "\27[0m"
    out[#out + 1] = cursor_sequence(connection)
    return table.concat(out)
end

-- Replaces the held screens with a checkpoint body.
--
-- - Returns: the escape sequences that paint it.
function M.apply_checkpoint(connection, body)
    local r = reader(body)
    local generation = r_u64(r)
    local epoch = r_u32(r)
    local rows = r_u16(r)
    local columns = r_u16(r)
    local active = r_u8(r)
    if rows == 0 or columns == 0 or active > 1 then
        error(string.format("ubiquitty_sync: a checkpoint of %dx%d, screen %d", rows, columns, active), 0)
    end
    local blocks = {}
    for slot = 1, 7 do
        blocks[checkpoint_block_order[slot]] = r_bytes(r)
    end
    local pens = {}
    local pen_count = r_varint(r)
    for id = 0, pen_count - 1 do
        local at = take(r, pen_wire)
        pens[id] = body:sub(at + 1, at + pen_wire)
    end
    -- What arrived is kept as it arrived as well, so the screen held can be
    -- stored as the host's own checkpoint body (`held_checkpoint`).
    local links = {}
    for _ = 1, r_varint(r) do -- the link ring: id, key, URI
        local at = r.at
        local id = r_u16(r)
        r_bytes(r)
        r_bytes(r)
        links[#links + 1] = { id = id, bytes = body:sub(at + 1, r.at) }
    end
    local clusters, held_clusters = {}, {}
    local cluster_count = r_varint(r)
    for id = 1, cluster_count do
        local at = r.at
        clusters[id] = r_code_points(r)
        held_clusters[id] = body:sub(at + 1, r.at)
    end
    local runs = {}
    local runs_at = r.at
    for _ = 1, r_varint(r) do
        local id = r_varint(r)
        runs[id] = r_code_points(r)
    end
    local held_runs = body:sub(runs_at + 1, r.at)
    local rich_texts = {}
    for _ = 1, r_varint(r) do
        local at = r.at
        skip_rich_text_definition(r)
        rich_texts[#rich_texts + 1] = body:sub(at + 1, r.at)
    end
    -- The active screen's rows, then the other's.
    local records = { {}, {} }
    for slot = 0, 1 do
        local screen = (slot == 0) and active or (1 - active)
        for row = 1, rows do
            records[screen + 1][row] = r_bytes(r)
        end
    end
    -- The history's epoch and head; its lines travel on the history plane, and
    -- this client draws the screen and keeps no history of its own.
    local history_at = take(r, 12)
    local ground = r_bytes(r) -- the parser's ground state
    local digest_at = take(r, 16) -- the state digest
    if not at_end(r) then
        error("ubiquitty_sync: a checkpoint longer than its digest", 0)
    end
    connection.held = {
        blocks = blocks, links = links, clusters = held_clusters, runs = held_runs, rich_texts = rich_texts,
        history_epoch = body:sub(history_at + 1, history_at + 4), history_head = body:sub(history_at + 5, history_at + 12),
        ground = ground, digest = body:sub(digest_at + 1, digest_at + 16),
    }
    connection.generation = generation
    connection.generation_bytes = body:sub(1, 8)
    connection.epoch = epoch
    connection.pens, connection.pen_count = pens, pen_count
    connection.clusters, connection.cluster_count = clusters, cluster_count
    connection.runs = runs
    connection.records = records
    connection.columns_held = columns
    connection.active = active
    connection.proportional = {}
    connection.screens = {}
    -- A checkpoint replaces everything held of the pane, the echo context
    -- with it: it is unknown until the next update states it.
    connection.echo = nil
    for index = 0, 6 do
        apply_block(connection, index, blocks[index])
    end
    lay_out_screens(connection)
    connection.checkpoints = connection.checkpoints + 1
    return render(connection, nil)
end

-- What to do with an update of `mode` from `base` to `generation`: apply one
-- that builds on the screen held, drop one the screen is already past, and ask
-- for a checkpoint on any other gap. A chained update names exactly the
-- generation it builds on, a superset update any generation at or before it.
--
-- - Returns: "apply", "stale" or "resync".
function M.update_disposition(held, mode, base, generation)
    if held == nil then
        return "resync"
    end
    if generation <= held then
        return "stale"
    end
    if (mode == 0 and base == held) or (mode ~= 0 and base <= held) then
        return "apply"
    end
    return "resync"
end

-- Reads an update's EchoContext op, past its op byte: the modes revision and
-- the foreground-process generation, the flags, and the pane's live interrupt,
-- quit and suspend characters, each present or not.
function M.read_echo_context(r)
    local modes_revision = r_u32(r)
    local foreground_generation = r_u32(r)
    local flags = r_u8(r)
    local present = r_u8(r)
    local interrupt, quit, suspend = r_u8(r), r_u8(r), r_u8(r)
    if flags >= 8 or present >= 32 or (band(present, 8) ~= 0 and band(present, 16) == 0) then
        error(string.format("ubiquitty_sync: an echo context with flags %d and presence %d", flags, present), 0)
    end
    return {
        modes_revision = modes_revision,
        foreground_generation = foreground_generation,
        secure_entry = band(flags, 1) ~= 0,
        foreign_input = band(flags, 2) ~= 0,
        at_prompt = band(flags, 4) ~= 0,
        interrupt = band(present, 1) ~= 0 and interrupt or nil,
        quit = band(present, 2) ~= 0 and quit or nil,
        suspend = band(present, 4) ~= 0 and suspend or nil,
        erase = band(present, 16) == 0 and 127 or (band(present, 8) ~= 0 and r_u8(r) or nil),
    }
end

-- Applies an update body onto the held screens.
--
-- - Returns: "apply", "stale" or "resync", and when applied the escape
--   sequences that paint what moved.
function M.apply_update(connection, body)
    local r = reader(body)
    local mode = r_u8(r)
    local base = r_u64(r)
    local generation = r_u64(r)
    r_u8(r) -- the frame class
    local host_time = r_u64(r)
    r_varint(r) -- lagMicros
    -- How much of this client's input the host has written to the program and
    -- how much has settled; the counts stand whether or not the rows apply.
    local input_written = r_u64(r)
    local input_settled = r_u64(r)
    local history_head_at = take(r, 8) -- historyHead
    r_u64(r) -- effectsThrough
    M.note_input_written(connection, input_written, input_settled)
    local disposition = M.update_disposition(connection.generation, mode, base, generation)
    if disposition ~= "apply" then
        return disposition
    end
    local active = r_u8(r)
    local rows = r_u16(r)
    local columns = r_u16(r)
    local epoch = r_u32(r)
    if rows ~= #connection.records[1] or columns ~= connection.columns_held or epoch ~= connection.epoch or active > 1 then
        return "resync"
    end
    -- Every op is read before any is kept, so a body that fails half way
    -- leaves the screens as they were.
    local pens, pen_count = setmetatable({}, { __index = connection.pens }), connection.pen_count
    local clusters, cluster_count = setmetatable({}, { __index = connection.clusters }), connection.cluster_count
    local blocks, writes = {}, {}
    local links, held_clusters, rich_texts = {}, {}, {}
    local echo
    for _ = 1, r_varint(r) do
        local op = r_u8(r)
        if op == 1 then
            local id = r_varint(r)
            local at = take(r, pen_wire)
            local pen = body:sub(at + 1, at + pen_wire)
            if id < pen_count then
                if pens[id] ~= pen then
                    error("ubiquitty_sync: pen " .. id .. " restated differently", 0)
                end
            elseif id == pen_count then
                pens[id] = pen
                pen_count = pen_count + 1
            else
                error("ubiquitty_sync: pen " .. id .. " defined out of order", 0)
            end
        elseif op == 2 then
            local at = r.at
            local id = r_u16(r)
            r_bytes(r)
            r_bytes(r)
            links[#links + 1] = { id = id, bytes = body:sub(at + 1, r.at) }
        elseif op == 3 then
            local id = r_varint(r)
            local at = r.at
            local text = r_code_points(r)
            if id == cluster_count + 1 then
                clusters[id] = text
                held_clusters[id] = body:sub(at + 1, r.at)
                cluster_count = id
            elseif id > cluster_count + 1 or id == 0 then
                error("ubiquitty_sync: cluster " .. id .. " defined out of order", 0)
            end
        elseif op == 4 or op == 5 then
            local row = r_varint(r)
            if row >= rows then
                error(string.format("ubiquitty_sync: an update row %d of %d", row, rows), 0)
            end
            writes[#writes + 1] = { screen = (op == 4) and active or (1 - active), row = row, record = r_bytes(r) }
        elseif op == 6 then
            local index = r_u8(r)
            blocks[#blocks + 1] = { index = index, bytes = r_bytes(r) }
        elseif op == 8 then
            local at = r.at
            skip_rich_text_definition(r)
            rich_texts[#rich_texts + 1] = body:sub(at + 1, r.at)
        elseif op == 11 then
            echo = M.read_echo_context(r)
        else
            -- Ops 9 and 10, a row by its spans and a scrolled rectangle, go
            -- only to a client whose Greet named them; this one names neither.
            error("ubiquitty_sync: update op " .. op, 0)
        end
    end
    local digest_at = take(r, 16) -- the state digest
    if not at_end(r) then
        error("ubiquitty_sync: an update longer than its digest", 0)
    end
    local held = connection.held
    if held then
        for _, entry in ipairs(blocks) do
            held.blocks[entry.index] = entry.bytes
        end
        for _, link in ipairs(links) do
            for index = #held.links, 1, -1 do
                if held.links[index].id == link.id then table.remove(held.links, index) end
            end
            held.links[#held.links + 1] = link
        end
        for id, bytes in pairs(held_clusters) do
            held.clusters[id] = bytes
        end
        for _, definition in ipairs(rich_texts) do
            held.rich_texts[#held.rich_texts + 1] = definition
        end
        held.history_head = body:sub(history_head_at + 1, history_head_at + 8)
        held.digest = body:sub(digest_at + 1, digest_at + 16)
    end

    for id, pen in pairs(pens) do
        connection.pens[id] = pen
    end
    connection.pen_count = pen_count
    for id, text in pairs(clusters) do
        connection.clusters[id] = text
    end
    connection.cluster_count = cluster_count
    connection.generation = generation
    connection.generation_bytes = body:sub(10, 17)
    connection.host_time = math.max(connection.host_time, host_time)
    if echo then
        connection.echo = echo
    end
    local relayout = active ~= connection.active
    connection.active = active
    for _, entry in ipairs(blocks) do
        if apply_block(connection, entry.index, entry.bytes) then
            relayout = true
        end
    end
    local dirty = {}
    for _, write in ipairs(writes) do
        connection.records[write.screen + 1][write.row + 1] = write.record
        if not relayout then
            local cells, line_attribute = decode_row(connection, write.record, columns)
            connection.screens[write.screen + 1][write.row + 1] = { cells = cells, line_attribute = line_attribute }
            if write.screen == active then
                dirty[write.row + 1] = true
            end
        end
    end
    if relayout then
        lay_out_screens(connection)
        dirty = nil
    end
    connection.updates = connection.updates + 1
    return "apply", render(connection, dirty)
end

-- ---- configuration ----------------------------------------------------------

M.options = {
    host_program = "ubiquitty-host", -- name on PATH or absolute path of the daemon binary
    socket = nil, -- daemon socket leaf (host-<hash>.sock) handed to --socket; nil lets the host derive it
    auto_start = true, -- run --ensure-daemon before attaching
    end_when_detached = false, -- the created session ends with this attach instead of outliving it
    -- Optional function(buffer selector, complete MIME items). Return true only
    -- after applying the exact write. No system clipboard adapter is enabled.
    clipboard_write_handler = nil,
    -- Where the client instance and the resume record are kept; nil is the
    -- ubiquitty_sync directory under stdpath("data").
    state_directory = nil,
}

function M.setup(options)
    M.options = vim.tbl_extend("force", M.options, options or {})
end

-- ---- connections ------------------------------------------------------------

local connections = {} -- buffer number -> connection

local function connection_owner(connection)
    return { stdin = connection.stdin, process = connection.process,
        generation = connection.transport_generation or 0, registered = connections[connection.buffer] }
end

local function same_connection_owner(connection, owner)
    return owner.stdin == connection.stdin and owner.process == connection.process
        and owner.generation == (connection.transport_generation or 0)
        and owner.registered == connections[connection.buffer]
end

local function chan_send(connection, data)
    if connection.terminal and vim.api.nvim_buf_is_valid(connection.buffer) then
        pcall(vim.api.nvim_chan_send, connection.terminal, data)
    end
end

local function send_sync(connection, frame_kind, channel, body)
    if #body > max_frame_body then
        error(string.format("ubiquitty_sync: a Sync body of %d bytes, past the %d one frame carries", #body, max_frame_body), 0)
    end
    local stdin = connection.stdin
    if stdin and not stdin:is_closing() and not connection.input_closed and not connection.transport_closed then
        stdin:write(sync_frame(frame_kind, channel, body))
    end
end

-- The Greet a human client sends: the fingerprint is the wire's these tables
-- were written at, which a host of another build refuses; the client instance is this Neovim's, kept across restarts, and the facts name the
-- viewport and leave the pixel sizes unknown. The client keeps no history, so
-- the host sends it none.
local function greet_body(request)
    local function u32(value) return type(value) == "number" and value >= 0 and value <= 0xFFFFFFFF and value == floor(value) end
    if not u32(request.target) or request.target > wire.admission_target.management
        or not u32(request.session_id) or not u32(request.workspace_id)
        or type(request.client_instance) ~= "string" or #request.client_instance ~= 16
        or type(request.workspace_name) ~= "string" or #request.workspace_name > wire.max_workspace_name_bytes
        or request.workspace_name:find("\0", 1, true) or not effects.valid_utf8(request.workspace_name)
        or (request.target == wire.admission_target.session and request.workspace_id ~= 0)
        or (request.target >= wire.admission_target.control and (request.session_id ~= 0 or request.workspace_id ~= 0
            or request.workspace_name ~= "" or request.ends_when_detached)) then error("invalid admission request", 0) end
    return put_u16(wire_version)
        .. put_varint(0) -- appVersion: not an app build
        .. wire.wire_fingerprint .. request.client_instance
        .. char(wire.client_kind.human, wire.role.owner)
        .. char(request.target) .. put_u32(request.session_id) .. put_u32(request.workspace_id)
        .. exact_u64(request.expected_daemon)
        .. put_varint(#request.workspace_name) .. request.workspace_name
        .. "\0\0" -- empty agentLabel and sshHost
        .. char((request.session_id ~= 0 or request.workspace_id ~= 0) and 1 or 0,
            request.ends_when_detached and 1 or 0, 0, 0) -- no clipboard service or credential
        .. put_u16(request.rows) .. put_u16(request.columns)
        .. string.rep("\0", 8) -- cell and text-area pixels
        .. put_u32(0) -- no refresh cap
        .. "\0\0\1" -- unmetered, normal power, focused
        .. put_u32(0) -- no history lines kept
        .. put_u32(0) -- and none backfilled
        -- The echo context, and that no consent question is shown here, so a
        -- host asks it none; the two bits are distinct, so their sum is both.
        .. put_varint(capability.echo_context + capability.shows_no_questions)
        .. (request.resume or "\0") -- the stored attachment's resume, as Core wrote it, or none
end
M.greet_body = greet_body

-- The Facts a client sends of its own once attached: the viewport and whether
-- its window holds the focus, and from version 12 the theme palette it draws
-- in, present or not. A terminal buffer draws in the editor's own highlight
-- colours and states none.
local function facts_body(connection)
    return put_u16(connection.rows) .. put_u16(connection.columns)
        .. string.rep("\0", 8) -- cell and text-area pixels
        .. put_u32(0) -- no refresh cap
        .. "\0\0" -- unmetered, normal power
        .. char(connection.focused and 1 or 0)
        .. "\0" -- no theme palette
end
M.facts_body = facts_body

-- ---- input -----------------------------------------------------------------
--
-- What a client types travels as numbered events on its pane's handle
-- (Docs/sync.md section 6.7): one count per pane, from 1, shared by every
-- input kind, which the host writes in order and reports back as
-- inputWritten. The embedded terminal has already encoded keys and mouse
-- reports under the modes this client mirrors into it, so they go as Raw. A
-- paste goes as Paste pieces, which the host brackets and normalises under
-- the modes live when it writes them.

local function next_input_seq(connection)
    connection.input_seq = connection.input_seq + 1
    return connection.input_seq
end

-- A paste that the host has not finished writing: one still holding pieces,
-- or sent whole and not yet counted by inputWritten.
local function unfinished_paste(connection)
    for _, paste in ipairs(connection.pastes) do
        if paste.seq > connection.input_written then
            return paste
        end
    end
    return nil
end

-- Sends the pieces of the oldest paste the host's window has room for.
--
-- From version 15 the host states a window in its Welcome and reports how
-- much of an unfinished paste it has written; a piece goes only while what
-- was sent is less than the window past that. A program that reads nothing
-- therefore holds one window of the paste, and the rest stays here.
local function pump_pastes(connection)
    local limits = connection.paste_limits
    if not connection.pane or not limits then
        return
    end
    local piece_bytes = math.min(paste_piece_bytes, limits.chunk_bytes)
    for _, paste in ipairs(connection.pastes) do
        while paste.sent < #paste.text do
            if limits.window_bytes > 0 and paste.sent - paste.written >= limits.window_bytes then
                return
            end
            local piece = paste.text:sub(paste.sent + 1, paste.sent + piece_bytes)
            local state = (paste.sent + #piece == #paste.text) and paste_final or paste_more
            send_sync(connection, kind.paste, connection.pane,
                put_u64(paste.seq) .. put_u64(paste.sent) .. char(state) .. put_varint(#piece) .. piece)
            paste.sent = paste.sent + #piece
        end
        -- A paste's pieces go in order, so the next paste starts only when
        -- this one has none left.
    end
end

-- Forgets the pastes the host has written whole.
local function retire_pastes(connection)
    local kept = {}
    for _, paste in ipairs(connection.pastes) do
        if paste.seq > connection.input_written or paste.sent < #paste.text then
            kept[#kept + 1] = paste
        end
    end
    connection.pastes = kept
end

-- Takes the host's counts of this client's input, from an update's header or
-- a Receipt.
function M.note_input_written(connection, input_written, input_settled)
    if input_written > connection.input_written then
        connection.input_written = input_written
        retire_pastes(connection)
    end
    connection.input_settled = math.max(connection.input_settled, input_settled)
end

-- Gives up a paste: its unsent pieces are dropped and the host is told on the
-- interactive lane, where the abort does not wait behind the pieces it
-- cancels.
local function abort_paste(connection, paste)
    local kept = {}
    for _, held in ipairs(connection.pastes) do
        if held ~= paste then
            kept[#kept + 1] = held
        end
    end
    connection.pastes = kept
    send_sync(connection, kind.paste_abort, connection.pane, put_u64(paste.seq))
    connection.pastes_aborted = connection.pastes_aborted + 1
end

-- Whether `bytes` is one key that is the pane's interrupt, quit or suspend
-- character: the live ones the echo context states, or a new terminal's
-- before it has.
local function is_interrupt_key(connection, bytes)
    if #bytes ~= 1 then
        return false
    end
    local characters = connection.echo or default_interrupt_characters
    local value = byte(bytes)
    return value == characters.interrupt or value == characters.quit or value == characters.suspend
end

-- Sends typed bytes as Raw, numbered. Before the pane is bound they wait.
local function send_raw(connection, bytes)
    if bytes == "" then
        return
    end
    if not connection.pane then
        connection.queued_input[#connection.queued_input + 1] = { raw = bytes }
        return
    end
    -- An interrupt typed during an unfinished paste ends the paste first:
    -- Ctrl-C never waits behind megabytes of it.
    if is_interrupt_key(connection, bytes) then
        local paste = unfinished_paste(connection)
        while paste do
            abort_paste(connection, paste)
            paste = unfinished_paste(connection)
        end
    end
    for at = 1, #bytes, raw_piece_bytes do
        local piece = bytes:sub(at, at + raw_piece_bytes - 1)
        send_sync(connection, kind.raw, connection.pane, put_u64(next_input_seq(connection)) .. put_varint(#piece) .. piece)
    end
end

-- Sends text as a paste. The host states the most one paste may hold; a
-- longer one is refused here rather than cut.
function M.paste_on(connection, text)
    if text == "" then
        return true
    end
    if not connection.pane then
        connection.queued_input[#connection.queued_input + 1] = { paste = text }
        return true
    end
    local limits = connection.paste_limits
    if not limits then
        -- A host that states no paste caps is sent no Paste: the text goes
        -- as typed.
        send_raw(connection, text)
        return true
    end
    if #text > limits.paste_bytes then
        vim.notify(string.format("ubiquitty_sync: a paste of %d bytes, past the %d the host takes", #text, limits.paste_bytes), vim.log.levels.ERROR)
        return false
    end
    connection.pastes[#connection.pastes + 1] = { seq = next_input_seq(connection), text = text, sent = 0, written = 0 }
    pump_pastes(connection)
    return true
end

local bracket_open, bracket_close = "\27[200~", "\27[201~"

-- The longest tail of `data` that is a proper prefix of `marker`.
local function partial_marker(data, marker)
    for length = math.min(#marker - 1, #data), 1, -1 do
        if data:sub(-length) == marker:sub(1, length) then
            return length
        end
    end
    return 0
end

-- Takes what the embedded terminal hands back: typed keys and mouse reports
-- as it encoded them, and a paste between the bracket it writes when the
-- program asked for bracketed paste. The brackets are the embedded
-- terminal's, taken off here, and the text between them goes as a paste; a
-- marker cut between two calls is held until the rest of it arrives.
function M.feed_typed(connection, data)
    data = connection.typed_carry .. data
    connection.typed_carry = ""
    while data ~= "" do
        if connection.paste_text then
            local stop = data:find(bracket_close, 1, true)
            if stop then
                connection.paste_text[#connection.paste_text + 1] = data:sub(1, stop - 1)
                local text = table.concat(connection.paste_text)
                connection.paste_text = nil
                M.paste_on(connection, text)
                data = data:sub(stop + #bracket_close)
            else
                local held = partial_marker(data, bracket_close)
                connection.paste_text[#connection.paste_text + 1] = data:sub(1, #data - held)
                connection.typed_carry = data:sub(#data - held + 1)
                return
            end
        else
            local start = data:find(bracket_open, 1, true)
            if start then
                send_raw(connection, data:sub(1, start - 1))
                connection.paste_text = {}
                data = data:sub(start + #bracket_open)
            else
                -- A lone ESC is a key; only a longer prefix of the marker waits.
                local held = partial_marker(data, bracket_open)
                if held < 2 then
                    held = 0
                end
                send_raw(connection, data:sub(1, #data - held))
                connection.typed_carry = data:sub(#data - held + 1)
                return
            end
        end
    end
end

-- Sends what was typed before the pane was bound, in the order it was typed.
local function flush_queued_input(connection)
    local queued = connection.queued_input
    connection.queued_input = {}
    for _, entry in ipairs(queued) do
        if entry.raw then
            send_raw(connection, entry.raw)
        else
            M.paste_on(connection, entry.paste)
        end
    end
end

-- Tells the host whether this buffer holds the keyboard focus: the pane's
-- Focus, which the host turns into a focus report when the program asked for
-- them, and the window's in a Facts of its own.
function M.set_focus(buffer, focused)
    local connection = connections[buffer]
    if connection then
        M.focus_connection(connection, focused)
    end
end

function M.focus_connection(connection, focused)
    if connection.focused == focused then
        return
    end
    connection.focused = focused
    if connection.welcomed then
        send_sync(connection, kind.facts, 0, facts_body(connection))
    end
    if connection.pane then
        send_sync(connection, kind.focus, connection.pane, char(focused and 1 or 0))
    end
end

-- Reads every mandatory field of the current Welcome, with no positional tail
-- inferred from an early end or ignored after the final presence flag.
function M.read_welcome(body)
    if #body > max_frame_body then error("oversized Welcome", 0) end
    local r = reader(body)
    local welcome = { version = r_u16(r) }
    welcome.app_version = r_text(r, wire.max_app_version_bytes)
    take(r, 32) -- the engine fingerprint
    welcome.host_instance = body:sub(r.at + 1, r.at + 16)
    take(r, 16)
    welcome.attachment = body:sub(r.at + 1, r.at + 16)
    take(r, 16)
    welcome.resume_secret = body:sub(r.at + 1, r.at + 16)
    take(r, 16)
    welcome.granted_role = r_u8(r)
    if welcome.granted_role > wire.role.agent then error("invalid Welcome role", 0) end
    welcome.target, welcome.session_id, welcome.workspace_id = r_u8(r), r_u32(r), r_u32(r)
    -- Preserve incarnation as its exact eight bytes, never a rounded Lua number.
    local daemon = take(r, 8)
    welcome.daemon_instance = body:sub(daemon + 1, daemon + 8)
    welcome.socket_name = r_text(r, wire.max_daemon_socket_name_bytes)
    welcome.build_flags, welcome.host_platform = r_u8(r), r_text(r, wire.max_host_platform_bytes)
    -- The instance a workspace recreated from its record was restored from:
    -- zero for a live selection, else a workspace's, never the serving one.
    local restored = take(r, 8)
    welcome.restored_from_daemon = body:sub(restored + 1, restored + 8)
    if welcome.restored_from_daemon ~= effects.zero
        and (welcome.target ~= wire.admission_target.workspace or welcome.restored_from_daemon == welcome.daemon_instance) then
        error("invalid Welcome selection", 0)
    end
    if welcome.version == 0
        or welcome.target > wire.admission_target.management or welcome.daemon_instance == effects.zero
        or not welcome.socket_name:match("^[A-Za-z0-9._-]+$")
        or bit.band(welcome.build_flags, bit.bnot(wire.known_serving_build_flags)) ~= 0
        or (welcome.target == wire.admission_target.session and welcome.session_id == 0)
        or (welcome.target == wire.admission_target.workspace and (welcome.session_id == 0 or welcome.workspace_id == 0))
        or (welcome.target >= wire.admission_target.control and (welcome.session_id ~= 0 or welcome.workspace_id ~= 0)) then
        error("invalid Welcome selection", 0)
    end
    welcome.admission, welcome.consent_request, welcome.consent_session = r_u8(r), r_u32(r), r_u32(r)
    if welcome.admission == wire.attachment_admission.awaiting_consent then
        if welcome.consent_request == 0 or welcome.consent_session == 0 or welcome.consent_session ~= welcome.session_id then
            error("invalid Welcome consent binding", 0)
        end
    elseif welcome.admission ~= wire.attachment_admission.granted or welcome.consent_request ~= 0 or welcome.consent_session ~= 0 then
        error("invalid Welcome admission binding", 0)
    end
    welcome.principal = r_text(r, max_frame_body)
    welcome.max_outstanding_calls = r_u16(r)
    welcome.max_queued_bulk_bytes = r_u32(r)
    welcome.max_pending_ranges = r_u16(r)
    local steps = r_count(r, wire.max_probe_steps)
    if steps > wire.max_probe_steps then
        error("ubiquitty_sync: a Welcome with " .. steps .. " probe steps", 0)
    end
    for _ = 1, steps do
        r_u32(r)
    end
    welcome.host_time = r_u64(r)
    welcome.resumed = {}
    local predecessor = r_u8(r)
    if predecessor > 1 then error("invalid Welcome predecessor flag", 0) end
    if predecessor == 1 then
        welcome.predecessor = body:sub(r.at + 1, r.at + 16)
        take(r, 16)
    end
    local count = r_count(r, wire.max_panes_per_connection)
    if count > wire.max_panes_per_connection then error("too many resumed panes", 0) end
    if count ~= 0 and (welcome.admission == wire.attachment_admission.awaiting_consent or welcome.target >= wire.admission_target.control) then
        error("resumed panes without bound admission", 0)
    end
    for index = 1, count do
        local at = take(r, 16)
        local resumed = { pane = body:sub(at + 1, at + 16), outcome = r_u8(r) }
        local present = r_u8(r)
        if resumed.outcome > wire.resume_outcome.gone or present > 1 then error("invalid Welcome resume outcome", 0) end
        if present == 1 then
            resumed.input_written = r_u64(r)
        end
        welcome.resumed[index] = resumed
    end
    local present = r_u8(r)
    if present > 1 then error("invalid Welcome paste flag", 0) end
    if present == 1 then
        welcome.paste_limits = { chunk_bytes = r_u32(r), paste_bytes = r_u32(r), window_bytes = r_u32(r) }
    end
    if not at_end(r) then error("trailing Welcome bytes", 0) end
    return welcome
end

function M.read_bye(body)
    if #body > max_frame_body then error("oversized Bye", 0) end
    local r = reader(body)
    local closing = { reason = r_u8(r), detail = r_text(r, max_frame_body) }
    local present = r_u8(r)
    if not bye_reasons[closing.reason] or present > 1 then error("invalid Bye", 0) end
    if present == 1 then
        closing.peer = { version = r_u16(r) }
        if closing.peer.version == 0 then error("invalid peer version", 0) end
        closing.peer.app_version = r_text(r, wire.max_app_version_bytes)
        closing.peer.platform = r_text(r, wire.max_host_platform_bytes)
    end
    if not at_end(r) then error("trailing Bye bytes", 0) end
    return closing
end

local consent_status_phases = {
    [wire.consent_status_phase.pending] = "pending",
    [wire.consent_status_phase.approved] = "approved",
    [wire.consent_status_phase.denied] = "denied",
    [wire.consent_status_phase.expired] = "expired",
}

-- A Notify body as its kind and the record after it.
local function read_notify(body)
    if #body > max_frame_body then error("oversized Notify", 0) end
    local r = reader(body)
    local notify_kind = r_varint(r)
    return notify_kind, body:sub(r.at + 1)
end

-- The own-consent status a Notify carries, or nil for another kind; an
-- awaiting attachment (required) receives nothing else.
local function read_consent_status(body, required)
    if required and #body > wire.max_consent_status_bytes then error("oversized own-consent status", 0) end
    local notify_kind, record = read_notify(body)
    if notify_kind ~= wire.notify_kind.consent_status then
        if required then error("awaiting exact own-consent status", 0) end
        return nil
    end
    local r = reader(record)
    local request = r_u32(r)
    local session = r_u32(r)
    local phase = consent_status_phases[r_u8(r)]
    if r.at ~= r.stop or request == 0 or session == 0 or not phase then
        error("invalid own-consent status", 0)
    end
    return { request = request, session = session, phase = phase }
end

local function receive_consent_status(connection, status)
    local welcome = connection.welcome
    if not connection.consent_phase or status.request ~= welcome.consent_request or status.session ~= welcome.consent_session
        or (status.phase == "pending" and connection.consent_phase ~= "awaiting-status")
        or (status.phase ~= "pending" and connection.consent_phase ~= "pending") then
        error("unsolicited or repeated own-consent status", 0)
    end
    connection.consent_phase = status.phase
    if status.phase == "denied" or status.phase == "expired" then
        connection.consent_verdict = status.phase
        connection.refusal = status.phase == "denied" and "Consent denied" or "Consent request expired"
    end
    if status.phase == "approved" then
        connection.welcomed = true
        if connection.facts_owed then
            connection.facts_owed = false
            send_sync(connection, kind.facts, 0, facts_body(connection))
        end
    end
end

-- ---- the window across a restart -------------------------------------------
--
-- Core owns the resume record, its proof and its rules (Docs/sync.md 6.9);
-- this client owns only where the bytes live, a private file under the state
-- directory. The host program reads and writes it (`ubiquitty-host
-- resume-record`): handed the picture this buffer holds as the host's own wire
-- bytes, it stores the record a Core client would, and reads back the picture
-- to draw and the tail the next Greet ends with.

-- The checkpoint body of the screen held, in the host's numbering, or "" when
-- no picture may be stored: before a checkpoint, and after the host cleared
-- the history until the screen is newer than the generation it cleared.
function M.held_checkpoint(connection)
    local held = connection.held
    if not (held and connection.generation and connection.generation_bytes and connection.records)
        or (connection.reset_generation and connection.generation <= connection.reset_generation) then
        return ""
    end
    local function bytes(value) return put_varint(#value) .. value end
    local active = connection.active
    local out = {
        connection.generation_bytes, put_u32(connection.epoch), put_u16(#connection.records[1]),
        put_u16(connection.columns_held), char(active),
    }
    for slot = 1, 7 do
        out[#out + 1] = bytes(held.blocks[checkpoint_block_order[slot]])
    end
    out[#out + 1] = put_varint(connection.pen_count)
    for id = 0, connection.pen_count - 1 do
        out[#out + 1] = connection.pens[id]
    end
    out[#out + 1] = put_varint(#held.links)
    for _, link in ipairs(held.links) do
        out[#out + 1] = link.bytes
    end
    out[#out + 1] = put_varint(connection.cluster_count)
    for id = 1, connection.cluster_count do
        out[#out + 1] = held.clusters[id]
    end
    out[#out + 1] = held.runs
    out[#out + 1] = put_varint(#held.rich_texts)
    for _, definition in ipairs(held.rich_texts) do
        out[#out + 1] = definition
    end
    for _, screen in ipairs({ active + 1, 2 - active }) do
        for _, record in ipairs(connection.records[screen]) do
            out[#out + 1] = bytes(record)
        end
    end
    out[#out + 1] = held.history_epoch .. held.history_head .. bytes(held.ground) .. held.digest
    return table.concat(out)
end

-- A file in the state directory, which is made private to its owner first.
local function state_file(name)
    local directory = M.options.state_directory or (vim.fn.stdpath("data") .. "/ubiquitty_sync")
    if vim.fn.isdirectory(directory) == 0 then
        vim.fn.mkdir(directory, "p", tonumber("700", 8))
    end
    uv.fs_chmod(directory, tonumber("700", 8))
    return directory .. "/" .. name
end

-- This Neovim's client instance as its 16 wire bytes, kept across restarts.
function M.stored_client_instance()
    local file = state_file("client-instance")
    local handle = io.open(file, "rb")
    local stored = handle and handle:read("*a") or ""
    if handle then handle:close() end
    stored = vim.trim(stored)
    if stored:match("^%x+$") and #stored == 32 and not stored:match("^0+$") then
        return (stored:lower():gsub("%x%x", function(pair) return char(tonumber(pair, 16)) end))
    end
    local instance = {}
    for index = 1, 16 do instance[index] = char(math.random(0, 255)) end
    instance = table.concat(instance)
    local old = uv.fs_umask and uv.fs_umask(tonumber("077", 8))
    local out = io.open(file, "wb")
    if old then uv.fs_umask(old) end
    if out then
        out:write((instance:gsub(".", function(c) return string.format("%02x", byte(c)) end)), "\n")
        out:close()
    end
    return instance
end

-- Runs the host program's resume-record `verb` on this Neovim's record, with
-- `input` on its standard input. Returns the exit code and standard output, or
-- nothing for a connection `start` did not make, which keeps no record.
local function record_tool(connection, verb, input)
    if not connection.host then return nil end
    local result = vim.system({ connection.host, "resume-record", verb, state_file("resume.record") },
        { stdin = input or false, text = false }):wait()
    return result.code, result.stdout or ""
end

-- Stores this buffer's resume record: the attachment and the screen held. Only
-- once a Welcome named the attachment; the bytes are Core's to check.
function M.persist(connection)
    local welcome = connection.welcome
    if not (welcome and connection.welcomed and connection.effect_pane and connection.client_instance and welcome.resume_secret) then
        return
    end
    local picture = M.held_checkpoint(connection)
    local cursor = connection.effect_cursor or effects.new()
    record_tool(connection, "write", welcome.host_instance .. connection.client_instance .. welcome.attachment
        .. welcome.resume_secret .. connection.effect_pane .. put_u64(connection.input_seq) .. char(255)
        .. cursor.acknowledged .. cursor.consumed .. put_u32(#picture) .. picture)
end

-- Removes this Neovim's resume record.
function M.purge_record(connection)
    record_tool(connection, "purge")
end

-- The stored record of `instance`, or nil. A record of another instance is
-- purged rather than drawn.
function M.read_record(connection, instance)
    local code, bytes = record_tool(connection, "read")
    if code ~= 0 then return nil end
    local ok, record = pcall(function()
        local r = reader(bytes)
        local at = take(r, 16)
        local stored = bytes:sub(at + 1, at + 16)
        local tail_size = r_u32(r)
        local tail_at = take(r, tail_size)
        local record = { stored = stored, tail = bytes:sub(tail_at + 1, tail_at + tail_size), panes = {} }
        for index = 1, r_u16(r) do
            local pane_at = take(r, 16)
            local seq = r_u64(r)
            local acknowledged_at = take(r, 16)
            local picture_size = r_u32(r)
            local picture_at = take(r, picture_size)
            record.panes[index] = {
                id = bytes:sub(pane_at + 1, pane_at + 16), input_seq = seq,
                acknowledged = bytes:sub(acknowledged_at + 1, acknowledged_at + 8),
                consumed = bytes:sub(acknowledged_at + 9, acknowledged_at + 16),
                picture = bytes:sub(picture_at + 1, picture_at + picture_size),
            }
        end
        if not at_end(r) then error("trailing record reply", 0) end
        return record
    end)
    if not ok then return nil end
    if record.stored ~= instance then
        M.purge_record(connection)
        return nil
    end
    return record
end

-- Draws the stored screen and arranges for the Greet to resume its
-- attachment. Nothing is sent: the host's diff brings it up to date once the
-- Greet is answered.
function M.restore(connection, record)
    local pane = record.panes[1]
    if not pane then return end
    local ok = pcall(function()
        if pane.picture ~= "" then
            chan_send(connection, M.apply_checkpoint(connection, pane.picture))
        end
        connection.effect_pane = pane.id
        connection.effect_cursor = effects.new({ acknowledged = pane.acknowledged, consumed = pane.consumed })
        connection.input_seq = pane.input_seq
        connection.resume_tail = record.tail
    end)
    if ok then
        vim.notify("ubiquitty_sync: showing the stored screen; reconnecting", vim.log.levels.INFO)
    else
        M.forget_restored(connection)
    end
end

-- Lets go of a restored attachment the host did not continue: the pane it
-- binds next starts from its own checkpoint.
function M.forget_restored(connection)
    connection.effect_pane, connection.effect_cursor = nil, effects.new()
    connection.generation, connection.generation_bytes = nil, nil
    connection.input_seq, connection.resume_tail = 0, nil
end

local function handshake_request(connection)
    -- A connection `start` made is this Neovim's window; any other greets as a
    -- fresh client.
    local instance
    if connection.host then
        instance = M.stored_client_instance()
    else
        local bytes = {}
        for index = 1, 16 do bytes[index] = char(math.random(0, 255)) end
        instance = table.concat(bytes)
    end
    -- A resume asks for the session its pane is, and nothing new: a pane's
    -- identity is its session and its daemon.
    local resuming = connection.resume_tail and connection.effect_pane
    return {
        columns = connection.columns,
        rows = connection.rows,
        client_instance = instance, target = wire.admission_target.session,
        session_id = resuming and u32(connection.effect_pane, 0) or 0, workspace_id = 0,
        expected_daemon = resuming and connection.effect_pane:sub(9, 16) or 0, workspace_name = "",
        ends_when_detached = connection.end_when_detached == true,
        resume = connection.resume_tail,
    }
end

local function send_greet(connection)
    local request = handshake_request(connection)
    connection.transport_generation = (connection.transport_generation or 0) + 1
    connection.admission_request, connection.client_instance = request, request.client_instance
    send_sync(connection, kind.greet, 0, greet_body(request))
end
M.send_greet = send_greet

-- Sends the viewport the connection holds, as a resize does once it has
-- measured the window.
function M.send_facts(connection)
    if connection.welcomed then
        send_sync(connection, kind.facts, 0, facts_body(connection))
    else
        connection.facts_owed = true
    end
end

-- Sends the size the buffer shows its pane at, once the host has bound the
-- pane. A size is said twice and the two frames mean different things: the
-- Facts names the window's, and the Viewport the pane's. The buffer is the
-- whole window, so they agree. The pixel sizes are zero: a buffer measures
-- none.
local function send_viewport(connection)
    if connection.pane then
        send_sync(connection, kind.viewport, connection.pane,
            put_u16(connection.rows) .. put_u16(connection.columns) .. string.rep("\0", 12))
    end
end
M.send_viewport = send_viewport

-- The first window showing the buffer, or nil.
local function window_for(buffer)
    for _, window in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(window) == buffer then
            return window
        end
    end
    return nil
end

-- The terminal size a window offers: its text columns, past any number or
-- sign column, by its height.
local function geometry(window)
    local info = vim.fn.getwininfo(window)[1]
    local text_offset = info and info.textoff or 0
    return math.max(1, vim.api.nvim_win_get_width(window) - text_offset), math.max(1, vim.api.nvim_win_get_height(window))
end

local function set_title(connection, title)
    connection.title = title
    local buffer = connection.buffer
    if not vim.api.nvim_buf_is_valid(buffer) then
        return
    end
    local name = "ubiquitty://" .. (title ~= "" and title or "session")
    local previous = vim.api.nvim_buf_get_name(buffer)
    if previous == name then
        return
    end
    -- Two sessions may share a title; the second carries its buffer number.
    if not pcall(vim.api.nvim_buf_set_name, buffer, name) then
        if not pcall(vim.api.nvim_buf_set_name, buffer, name .. " (" .. buffer .. ")") then
            return
        end
    end
    -- A rename leaves the old name behind as an unlisted, unloaded buffer.
    if previous == "" then
        return
    end
    for _, leftover in ipairs(vim.api.nvim_list_bufs()) do
        if leftover ~= buffer and not vim.api.nvim_buf_is_loaded(leftover)
            and vim.api.nvim_buf_get_name(leftover) == previous then
            pcall(vim.api.nvim_buf_delete, leftover, { force = true })
        end
    end
end

-- The mode sequences that bring the embedded terminal to the mode flags the
-- host's modes block carries; nil means unchanged. The flags become the ones
-- the terminal holds, so a second call over the same flags says nothing.
function M.mode_sequence(connection, flags)
    if flags == nil then
        return ""
    end
    local out = {}
    local previous = connection.mirrored
    for _, mode in ipairs(mirrored_modes) do
        local now = flags[mode.flag] == true
        if previous == nil or now ~= (previous[mode.flag] == true) then
            out[#out + 1] = now and mode.set or mode.reset
        end
    end
    connection.mirrored = flags
    return table.concat(out)
end


-- Asks the host for a checkpoint of the pane, once per gap.
local function request_resync(connection, reason)
    if not connection.pane or connection.resync_outstanding then
        return
    end
    connection.resync_outstanding = true
    connection.buffered_updates, connection.buffered_bytes = {}, 0
    send_sync(connection, kind.resync, connection.pane,
        char(reason) .. put_u64(connection.generation or 0) .. put_varint(0))
end

local function take_update(connection, body)
    local ok, disposition, sequence = pcall(M.apply_update, connection, body)
    if not ok then
        vim.notify("ubiquitty_sync: " .. tostring(disposition), vim.log.levels.WARN)
        request_resync(connection, resync_reason.decode_failed)
    elseif disposition == "apply" then
        connection.ack_owed = true
        chan_send(connection, sequence)
    elseif disposition == "resync" then
        request_resync(connection, resync_reason.base_missing)
    end
end

-- Takes one BulkChunk; the last chunk of the checkpoint announced applies it.
-- Its SHA-256 is not checked here: the bytes arrive on the bridge's reliable
-- stream, and the checkpoint is checked field by field as it is read.
local drain_effects
local function take_chunk(connection, body)
    local r = reader(body)
    local transfer = r_u32(r)
    local index = r_u32(r)
    local last = r_u8(r)
    if last > 1 then error("ubiquitty_sync: invalid BulkChunk final flag", 0) end
    local bytes = r_bytes(r)
    local digest
    if last == 1 then
        local at = take(r, 32)
        digest = body:sub(at + 1, at + 32)
    end
    if not at_end(r) then
        error("ubiquitty_sync: a BulkChunk longer than its fields", 0)
    end
    local sample = connection.sample_transfers and connection.sample_transfers[transfer]
    local clipboard = connection.clipboard_transfers and connection.clipboard_transfers[transfer]
    if clipboard then
        if clipboard.ready or index ~= clipboard.next or #bytes == 0
            or clipboard.received + #bytes > clipboard.payload.encoded_bytes then error("invalid clipboard chunk", 0) end
        clipboard.next, clipboard.received = index + 1, clipboard.received + #bytes
        table.insert(clipboard.parts, bytes)
        sha256.update(clipboard.hash, bytes)
        if last == 1 then
            if clipboard.received ~= clipboard.payload.encoded_bytes or sha256.finish(clipboard.hash) ~= digest then
                error("clipboard digest or size mismatch", 0)
            end
            clipboard.payload.items = effects.clipboard_bundle(table.concat(clipboard.parts), wire.max_effect_clipboard_write_bytes)
            clipboard.parts, clipboard.ready = nil, true
            drain_effects(connection)
        elseif clipboard.received == clipboard.payload.encoded_bytes then error("clipboard payload has no final marker", 0) end
        return
    end
    if sample then
        if index ~= sample.next or #bytes == 0 or sample.received + #bytes > sample.identity.frames * 2 then
            error("ubiquitty_sync: invalid raw sample chunk", 0)
        end
        sample.next, sample.received = index + 1, sample.received + #bytes
        sha256.update(sample.hash, bytes)
        if last == 1 then
            if sample.received ~= sample.identity.frames * 2 or sha256.finish(sample.hash) ~= digest
                or digest ~= sample.identity.digest then error("ubiquitty_sync: sample digest or size mismatch", 0) end
            connection.sample_transfers[transfer] = nil
            sample.ready = true
            drain_effects(connection)
        elseif sample.received == sample.identity.frames * 2 then
            error("ubiquitty_sync: sample payload has no final marker", 0)
        end
        return -- editors validate samples but do not claim a PCM audio sink
    end
    local image = connection.image_transfers[transfer]
    if image then
        if index ~= image.next or #bytes == 0 or image.received + #bytes > image.asset.pixel_bytes then
            error("ubiquitty_sync: invalid raw image chunk", 0)
        end
        image.next, image.received = index + 1, image.received + #bytes
        sha256.update(image.raw_hash, bytes)
        sha256.update(image.content_hash, bytes)
        if last == 1 then
            connection.image_transfers[transfer] = nil
            if image.received ~= image.asset.pixel_bytes then error("ubiquitty_sync: incomplete raw image", 0) end
            if sha256.finish(image.raw_hash) ~= digest or sha256.finish(image.content_hash):sub(1, 16) ~= image.asset.hash then
                error("ubiquitty_sync: image pixels fail their transfer or content digest", 0)
            end
        end
        return -- no pixel owner and no verified cache entry are created
    end
    if not connection.pending_checkpoint or connection.pending_checkpoint.transfer ~= transfer then
        return -- an unrequested or retired transfer never accumulates a body
    end
    local held = connection.transfers[transfer] or { next = 0, chunks = {} }
    if index ~= held.next then
        error(string.format("ubiquitty_sync: chunk %d of transfer %d out of order", index, transfer), 0)
    end
    held.next = index + 1
    held.chunks[#held.chunks + 1] = bytes
    connection.transfers[transfer] = held
    if last ~= 1 then
        return
    end
    connection.transfers[transfer] = nil
    local pending = connection.pending_checkpoint
    if not pending or pending.transfer ~= transfer then
        return
    end
    connection.pending_checkpoint = nil
    connection.resync_outstanding = false
    local ok, sequence = pcall(M.apply_checkpoint, connection, table.concat(held.chunks))
    if not ok then
        vim.notify("ubiquitty_sync: " .. tostring(sequence), vim.log.levels.WARN)
        request_resync(connection, resync_reason.checkpoint_refused)
        return
    end
    connection.ack_owed = true
    chan_send(connection, sequence)
    local buffered = connection.buffered_updates
    connection.buffered_updates, connection.buffered_bytes = {}, 0
    for _, update in ipairs(buffered) do
        take_update(connection, update)
    end
end


-- Retain bounded typed event data for editor consumers. Posting is restricted
-- to the immutable human primary; secondary clients expose a badge only.
local function present_effect(connection, record)
    local role = connection.welcome and connection.welcome.granted_role
    if role == wire.role.agent then return end -- an agent has no presentation side effect
    record.disposition = (role == wire.role.owner or role == wire.role.driver) and connection.client_instance
        and connection.client_instance ~= string.rep("\0", 16) and record.primary == connection.client_instance and "post" or "badge"
    if record.clipboard then
        -- Receipt means validated delivery, not successful external writing.
        -- Keep secrets out of the general recent-events list and badge state.
        connection.clipboard_write_status = "disabled"
        if record.disposition == "post" and type(connection.clipboard_write_handler) == "function" then
            local owner = connection_owner(connection)
            connection.clipboard_write_status = "refused"
            local ok, applied = pcall(connection.clipboard_write_handler, record.clipboard.buffer, record.clipboard.items)
            if not same_connection_owner(connection, owner) then return end
            if not ok then error("ubiquitty_sync: local clipboard handler failed", 0) end
            connection.clipboard_write_status = applied == true and "applied" or "refused"
        end
        return
    end
    table.insert(connection.effects, 1, record)
    if #connection.effects > 8 then table.remove(connection.effects) end
    if vim.api.nvim_buf_is_valid(connection.buffer) then
        vim.b[connection.buffer].ubiquitty_attention = record.kind
    end
    if record.disposition == "post" then
        if record.kind == wire.effect_kind.bell or record.kind == wire.effect_kind.attention then
            chan_send(connection, "\7")
        elseif record.kind == wire.effect_kind.notification then
            local occasion = record.occasion
            if occasion == wire.notification_occasion.always
                or (occasion == wire.notification_occasion.unfocused and not connection.focused)
                or (occasion == wire.notification_occasion.invisible and not window_for(connection.buffer)) then
                vim.notify(record.body, vim.log.levels.INFO, { title = record.title })
            end
        end
    end
end

local function same_sample(first, second)
    return first and second and first.serial == second.serial and first.frames == second.frames and first.digest == second.digest
end

drain_effects = function(connection)
    if connection.is_draining_effects then return end
    local owner = connection_owner(connection)
    connection.is_draining_effects = true
    local queue = connection.deferred_effects or {}
    local index, blocked = 1, {}
    while index <= #queue do
        local held = queue[index]
        local packet, channel = held.packet, held.channel
        local cursor = connection.effect_cursors[channel]
        if not cursor then error("deferred Effect lost its bound cursor", 0) end
        local record = packet.record
        local consumed = connection.effect_cursor.consumed
        local sound = record and record.sound
        local ready = not blocked[channel]
        local role = connection.welcome and connection.welcome.granted_role
        local posts = record and (role == wire.role.owner or role == wire.role.driver)
            and record.primary == connection.client_instance and connection.client_instance ~= string.rep("\0", 16)
        if record and record.clipboard and not posts then error("clipboard recipient retired before delivery", 0) end
        if ready and record and record.clipboard and effects.compare(record.sequence, consumed) > 0 then
            ready = record.clipboard.items ~= nil
        end
        if ready and posts and effects.compare(record.sequence, consumed) > 0 and sound and sound.identity and sound.identity.frames > 0 then
            local sample = connection.sample_slots[channel] and connection.sample_slots[channel][sound.sample]
            if not sample or not same_sample(sample.identity, sound.identity) then error("Effect has no exact sample owner", 0) end
            ready = sample.ready
        end
        if not ready then blocked[channel] = true; index = index + 1
        else
            record = effects.accept(cursor, packet, connection.generation_bytes or effects.zero)
            for _, field in ipairs({ "acknowledged", "consumed" }) do
                if effects.compare(cursor[field], connection.effect_cursor[field]) > 0 then connection.effect_cursor[field] = cursor[field] end
            end
            if packet.remaining == 0 then connection.effect_ack_handles[channel] = true end
            table.remove(queue, index)
            connection.deferred_effect_bytes = connection.deferred_effect_bytes - held.bytes
            -- Detach the active owner from all cancellation tables before a
            -- user handler can unbind/reset. Keep its full charge until return.
            connection.delivering_effect_bytes = (connection.delivering_effect_bytes or 0) + held.bytes
            if held.clipboard_charge then
                connection.clipboard_transfers[held.packet.record.clipboard.transfer] = nil
                connection.delivering_clipboard_bytes = (connection.delivering_clipboard_bytes or 0) + held.clipboard_charge
            end
            local ok, failure = true, nil
            if record and effects.compare(record.sequence, consumed) > 0 then ok, failure = pcall(present_effect, connection, record) end
            -- Held packet/sample locals release normally on return. Their old
            -- delivery charges never decrement or reset a replacement owner.
            if not same_connection_owner(connection, owner) then return end
            connection.delivering_effect_bytes = connection.delivering_effect_bytes - held.bytes
            if held.clipboard_charge then
                connection.delivering_clipboard_bytes = connection.delivering_clipboard_bytes - held.clipboard_charge
                connection.clipboard_reserved_bytes = connection.clipboard_reserved_bytes - held.clipboard_charge
            end
            if not ok then connection.is_draining_effects = false; error(failure, 0) end
            if connection.deferred_effects ~= queue then break end
        end
    end
    connection.is_draining_effects = false
end

local function retire_sample_binding(connection, handle)
    if connection.sample_slots then connection.sample_slots[handle] = nil end
    for transfer, sample in pairs(connection.sample_transfers or {}) do
        if sample.channel == handle then connection.sample_transfers[transfer] = nil end
    end
    for transfer, clipboard in pairs(connection.clipboard_transfers or {}) do
        if clipboard.channel == handle then
            connection.clipboard_reserved_bytes = connection.clipboard_reserved_bytes - clipboard.charge
            connection.clipboard_transfers[transfer] = nil
        end
    end
    local queue = connection.deferred_effects or {}
    for index = #queue, 1, -1 do
        if queue[index].channel == handle then
            connection.deferred_effect_bytes = connection.deferred_effect_bytes - queue[index].bytes
            table.remove(queue, index)
        end
    end
end

-- Acts on one exact canonical envelope.
local function on_sync(connection, payload)
    connection.stream_received = connection.stream_received + #payload
    local header = envelope_header(payload)
    if not header or #payload ~= header.bytes + header.size then error("incomplete or trailing envelope bytes", 0) end
    admit_header(connection, header)
    local frame_kind, channel, size, start = header.kind, header.channel, header.size, header.bytes
    local body = payload:sub(start + 1, start + size)
    if client_only_kind[frame_kind] then
        error("ubiquitty_sync: Sync kind " .. frame_kind .. " from the host, which only a client sends", 0)
    end
    if connection.consent_phase and connection.consent_phase ~= "approved" then
        if connection.consent_phase == "closed" then error("data after pending-consent Bye", 0) end
        if channel ~= 0 or (frame_kind ~= kind.probe and frame_kind ~= kind.echo and frame_kind ~= kind.bye and frame_kind ~= kind.notify) then
            error("pane or connection data before own consent", 0)
        end
        if (frame_kind == kind.probe and #body ~= 8) or (frame_kind == kind.echo and #body ~= 12) then
            error("invalid pending-consent transport frame", 0)
        end
        if (connection.consent_phase == "denied" or connection.consent_phase == "expired") and frame_kind == kind.notify then
            error("status after own consent ended", 0)
        end
        if frame_kind == kind.bye then
            local closing = M.read_bye(body)
            if (connection.consent_phase == "denied" or connection.consent_phase == "expired")
                and bye_reasons[closing.reason] ~= "NoConsent" then
                error("invalid pending-consent Bye", 0)
            end
        end
    end
    if frame_kind == kind.welcome then
        if channel ~= 0 then error("Welcome on a pane", 0) end
        -- A host at another version is refused by name, so a skew is never
        -- an empty buffer. The version is read before the rest: a host of
        -- another version lays the rest out its own way.
        local version = u16(body, 0)
        if version ~= wire_version then
            error(string.format("ubiquitty_sync: host speaks wire version %d, this client speaks %d",
                version, wire_version), 0)
        end
        if connection.welcome then error("duplicate Welcome", 0) end
        local welcome = M.read_welcome(body)
        local request = connection.admission_request
        -- Core's isRestoredReferenceAnswer: a host that recreated the
        -- referenced workspace from its record answers with fresh sessions,
        -- naming the instance the client pinned, under the id it gave the
        -- workspace, which need not be the one asked for.
        local restored = request ~= nil and welcome.restored_from_daemon ~= effects.zero
            and request.target == wire.admission_target.workspace and welcome.target == wire.admission_target.workspace
            and exact_u64(request.expected_daemon) == welcome.restored_from_daemon
            and welcome.daemon_instance ~= welcome.restored_from_daemon
            and request.workspace_id ~= 0 and welcome.workspace_id ~= 0
        if not request or welcome.target ~= request.target
            or (welcome.restored_from_daemon ~= effects.zero and not restored)
            or (request.session_id ~= 0 and not restored and welcome.session_id ~= request.session_id)
            or (request.workspace_id ~= 0 and not restored and welcome.workspace_id ~= request.workspace_id)
            or (exact_u64(request.expected_daemon) ~= effects.zero and not restored
                and welcome.daemon_instance ~= exact_u64(request.expected_daemon)) then
            error("Welcome changed the requested selection", 0)
        end
        connection.welcome = welcome
        connection.session_id = welcome.session_id
        connection.welcomed = welcome.admission == wire.attachment_admission.granted
        connection.consent_phase = nil
        if not connection.welcomed then connection.consent_phase = "awaiting-status" end
        connection.paste_limits = welcome.paste_limits
        -- A restored pane the host did not continue is let go of; the record
        -- is rewritten for the fresh secret before any input goes.
        if connection.resume_tail then
            local continued = false
            for _, resumed in ipairs(welcome.resumed) do
                if resumed.pane == connection.effect_pane
                    and (resumed.outcome == wire.resume_outcome.diffed or resumed.outcome == wire.resume_outcome.checkpointed) then
                    continued = true
                end
            end
            if not continued then M.forget_restored(connection) end
            connection.resume_tail = nil
        end
        if connection.effect_pane then M.persist(connection) else M.purge_record(connection) end
        if connection.welcomed and connection.facts_owed then
            connection.facts_owed = false
            send_sync(connection, kind.facts, 0, facts_body(connection))
        end
    elseif frame_kind == kind.probe then
        send_sync(connection, kind.echo, 0, body:sub(1, 8) .. put_u32(0))
    elseif frame_kind == kind.pane_bind then
        connection.pane_ended = false
        local binding = reader(body)
        local handle = r_varint(binding)
        local at = take(binding, 16)
        local pane_id = body:sub(at + 1, at + 16)
        if handle == 0 or handle >= wire.first_listed_handle or pane_id == string.rep("\0", 16) or not at_end(binding) then error("invalid PaneBind", 0) end
        if connection.effect_pane and connection.effect_pane ~= pane_id then error("multiple distinct panes in a single-pane client", 0) end
        if connection.pane_bindings[handle] then error("repeated PaneBind handle", 0) end
        local bound = 0
        for _ in pairs(connection.pane_bindings) do bound = bound + 1 end
        if bound >= wire.max_panes_per_connection then error("too many pane bindings", 0) end
        local first_binding = not connection.effect_pane
        connection.pane_bindings[handle] = pane_id
        if first_binding then connection.effect_cursor = effects.new() end
        connection.effect_cursors[handle] = effects.new(connection.effect_cursor)
        connection.effect_pane, connection.pane = pane_id, handle
        if first_binding then
            connection.pane_facts = nil
            connection.image_assets, connection.image_transfers, connection.image_revision = {}, {}, 0
            connection.generation, connection.generation_bytes = nil, nil
            connection.pending_checkpoint = nil
            connection.buffered_updates, connection.buffered_bytes = {}, 0
            connection.resync_outstanding = false
        end
        -- The host starts a pane Dormant, sending no screen until the client
        -- says it shows it; this buffer is the pane, so it does at once.
        send_sync(connection, kind.view, connection.pane, string.char(view_live))
        -- The host holds no size for a pane it has only now bound.
        send_viewport(connection)
        if not connection.focused then
            send_sync(connection, kind.focus, connection.pane, char(0))
        end
        -- A fresh attachment names its pane here: its record is stored before
        -- the first input goes.
        M.persist(connection)
        flush_queued_input(connection)
    elseif frame_kind == kind.pane_unbind then
        local binding = reader(body)
        local handle = r_varint(binding)
        r_u8(binding) -- the existing PaneUnbind reason
        if not connection.pane_bindings[handle] or not at_end(binding) then error("invalid or unbound PaneUnbind", 0) end
        connection.pane_bindings[handle], connection.effect_ack_handles[handle] = nil, nil
        connection.effect_cursors[handle] = nil
        retire_sample_binding(connection, handle)
        if handle ~= connection.pane then return end
        connection.pane = next(connection.pane_bindings)
        if connection.pane then return end -- another handle owns the same stable pane receipt
        connection.pane_ended = true
        -- The pane ended, and nothing of it is left to resume.
        M.purge_record(connection)
        connection.effect_cursor, connection.effect_pane = effects.new(), nil
        connection.pane_facts = nil
        connection.pending_checkpoint = nil
        connection.image_assets, connection.image_transfers, connection.image_revision = {}, {}, 0
    elseif frame_kind == kind.clipboard_request then
        local role = connection.welcome and connection.welcome.granted_role
        if not connection.effect_pane or connection.pane_bindings[channel] ~= connection.effect_pane
            or (role ~= wire.role.owner and role ~= wire.role.driver) then
            error("clipboard request without a privileged bound pane", 0)
        end
        local request = effects.clipboard_request(body)
        -- No ServesClipboard intent is advertised. A configured write handler
        -- grants no read access to editor registers or operating-system data.
        send_sync(connection, kind.clipboard_data, channel, put_u32(request.id) .. string.char(wire.effect_clipboard_status.refused))
    elseif frame_kind == kind.effect then
        if not connection.effect_pane or (channel ~= connection.pane and connection.pane_bindings[channel] ~= connection.effect_pane) then
            error("Effect for an unbound pane", 0)
        end
        connection.deferred_effects = connection.deferred_effects or {}
        connection.deferred_effect_bytes = connection.deferred_effect_bytes or 0
        if #connection.deferred_effects >= wire.max_effect_records then error("too many deferred Effects", 0) end
        if connection.deferred_effect_bytes + #body + (connection.delivering_effect_bytes or 0)
            + (connection.clipboard_reserved_bytes or 0) > retained_asset_budget then error("Effect bytes exceed retained allowance", 0) end
        -- Peek only bounded envelope metadata before the MIME decoder can
        -- allocate strings from an inline clipboard operation.
        local metadata = reader(body)
        take(metadata, 18) -- generation, through-sequence, remaining count
        if not at_end(metadata) then
            take(metadata, 16) -- record generation and sequence
            local at = take(metadata, 16)
            local primary = body:sub(at + 1, at + 16)
            local record_kind = r_u8(metadata)
            local role = connection.welcome and connection.welcome.granted_role
            if record_kind == wire.effect_kind.clipboard_write and not ((role == wire.role.owner or role == wire.role.driver)
                and connection.client_instance ~= string.rep("\0", 16) and primary == connection.client_instance) then
                error("clipboard disclosed to another recipient", 0)
            end
        end
        local packet = effects.decode(body)
        local held = { packet = packet, channel = channel, bytes = #body }
        local clipboard = packet.record and packet.record.clipboard
        if clipboard then
            local role = connection.welcome and connection.welcome.granted_role
            if not ((role == wire.role.owner or role == wire.role.driver) and connection.client_instance ~= string.rep("\0", 16)
                and packet.record.primary == connection.client_instance) then error("clipboard disclosed to another recipient", 0) end
            if clipboard.transfer ~= 0 and effects.compare(packet.record.sequence, connection.effect_cursor.consumed) > 0 then
                connection.clipboard_transfers = connection.clipboard_transfers or {}
                local reserved = connection.clipboard_reserved_bytes or 0
                -- Chunk strings, joined bytes and decoded item strings can
                -- coexist; reserve all three bounded owners before accepting.
                local charge = 3 * clipboard.encoded_bytes
                if reserved + charge + connection.deferred_effect_bytes + #body + (connection.delivering_effect_bytes or 0) > retained_asset_budget
                    or connection.clipboard_transfers[clipboard.transfer]
                    or connection.sample_transfers[clipboard.transfer] or connection.image_transfers[clipboard.transfer]
                    or connection.transfers[clipboard.transfer]
                    or (connection.pending_checkpoint and connection.pending_checkpoint.transfer == clipboard.transfer) then
                    error("clipboard transfer capacity or identity refused", 0)
                end
                connection.clipboard_transfers[clipboard.transfer] = { channel = channel, payload = clipboard,
                    parts = {}, next = 0, received = 0, hash = sha256.new(), charge = charge }
                connection.clipboard_reserved_bytes, held.clipboard_charge = reserved + charge, charge
            end
        end
        table.insert(connection.deferred_effects, held)
        connection.deferred_effect_bytes = connection.deferred_effect_bytes + #body
        drain_effects(connection)
    elseif frame_kind == kind.sample_head then
        if not connection.pane_bindings[channel] then error("SampleHead for an unbound pane", 0) end
        local head = effects.sample_head(body)
        connection.sample_slots, connection.sample_transfers = connection.sample_slots or {}, connection.sample_transfers or {}
        local slots = connection.sample_slots[channel] or {}
        connection.sample_slots[channel] = slots
        local old = slots[head.slot]
        if old and not old.ready then error("SampleHead replaced an incomplete sample", 0) end
        for _, held in ipairs(connection.deferred_effects or {}) do
            local sound = held.packet.record and held.packet.record.sound
            if held.channel == channel and sound and sound.sample == head.slot and sound.identity
                and not same_sample(sound.identity, head.identity) then error("SampleHead replaced a queued sound", 0) end
        end
        local sample = { channel = channel, identity = head.identity, next = 0, received = 0, ready = head.transfer == 0 }
        if head.transfer ~= 0 then
            local count = 0
            for _ in pairs(connection.sample_transfers) do count = count + 1 end
            if count >= wire.sample_slot_count * wire.max_panes_per_connection or connection.sample_transfers[head.transfer]
                or (connection.clipboard_transfers and connection.clipboard_transfers[head.transfer])
                or connection.image_transfers[head.transfer] or connection.transfers[head.transfer]
                or (connection.pending_checkpoint and connection.pending_checkpoint.transfer == head.transfer) then
                error("too many or repeated sample transfers", 0)
            end
            sample.hash = sha256.new()
            connection.sample_transfers[head.transfer] = sample
        end
        slots[head.slot] = sample
        drain_effects(connection)
    elseif frame_kind == kind.image_placements then
        if channel == connection.pane then
            local state = M.read_image_placements(body)
            if state.revision > connection.image_revision then
                connection.image_revision, connection.image_assets = state.revision, state.assets
                for transfer, image in pairs(connection.image_transfers) do
                    if not state.assets[image.asset.hash] or not same_image_asset(state.assets[image.asset.hash], image.asset) then
                        connection.image_transfers[transfer] = nil
                    end
                end
            end
        end
    elseif frame_kind == kind.image_head then
        if channel == connection.pane then
            local head = M.read_image_head(body)
            local asset = connection.image_assets[head.asset.hash]
            if not asset or not same_image_asset(asset, head.asset) then error("ubiquitty_sync: ImageHead names an absent asset", 0) end
            if head.transfer ~= 0 then
                local count = 0
                for _ in pairs(connection.image_transfers) do count = count + 1 end
                if count >= wire.max_image_count or connection.image_transfers[head.transfer]
                    or (connection.clipboard_transfers and connection.clipboard_transfers[head.transfer])
                    or (connection.sample_transfers and connection.sample_transfers[head.transfer])
                    or connection.transfers[head.transfer] then
                    error("ubiquitty_sync: too many or repeated image transfers", 0)
                end
                local raw_hash, content_hash = sha256.new(), sha256.new()
                sha256.update(content_hash, "Ubiquitty.Image\0" .. char(asset.format) .. put_u32(asset.width) .. put_u32(asset.height))
                connection.image_transfers[head.transfer] = { asset = asset, next = 0, received = 0,
                    raw_hash = raw_hash, content_hash = content_hash }
            end
        end
    elseif frame_kind == kind.pane_facts then
        if channel == connection.pane then
            local facts = M.read_pane_facts(body)
            connection.pane_facts = facts
            set_title(connection, facts.title)
        end
    elseif frame_kind == kind.checkpoint_head then
        local generation = u64(body, 0)
        if (connection.sample_transfers and connection.sample_transfers[u32(body, 8)])
            or (connection.clipboard_transfers and connection.clipboard_transfers[u32(body, 8)]) then
            error("checkpoint reused an effect transfer", 0)
        end
        connection.pending_checkpoint = { generation = generation, transfer = u32(body, 8) }
        -- Updates chained before this checkpoint can never apply after it.
        local kept, bytes = {}, 0
        for _, update in ipairs(connection.buffered_updates) do
            if u64(update, 9) > generation then
                kept[#kept + 1] = update
                bytes = bytes + #update
            end
        end
        connection.buffered_updates, connection.buffered_bytes = kept, bytes
    elseif frame_kind == kind.bulk_chunk then
        take_chunk(connection, body)
    elseif frame_kind == kind.bulk_abort then
        -- The checkpoint in flight is abandoned; a fresh one follows when the
        -- host has one to send, and the updates chained after this one never
        -- apply.
        local transfer = u32(body, 0)
        if connection.clipboard_transfers and connection.clipboard_transfers[transfer] then error("required clipboard transfer aborted", 0) end
        if connection.sample_transfers and connection.sample_transfers[transfer] then error("required sample transfer aborted", 0) end
        connection.transfers[transfer] = nil
        connection.image_transfers[transfer] = nil
        if connection.pending_checkpoint and connection.pending_checkpoint.transfer == transfer then
            connection.pending_checkpoint = nil
            connection.buffered_updates, connection.buffered_bytes = {}, 0
        end
    elseif frame_kind == kind.update then
        if connection.pending_checkpoint then
            -- An update past the checkpoint in flight builds on it, so it waits.
            if connection.buffered_bytes + #body > max_buffered_update_bytes then
                request_resync(connection, resync_reason.buffer_overflow)
            else
                connection.buffered_updates[#connection.buffered_updates + 1] = body
                connection.buffered_bytes = connection.buffered_bytes + #body
            end
        elseif not connection.resync_outstanding then
            take_update(connection, body)
        end
    elseif frame_kind == kind.receipt then
        -- The host's counts when no update left to carry them.
        local receipt = reader(body)
        local input_written, input_settled = r_u64(receipt), r_u64(receipt)
        if not at_end(receipt) then
            error("ubiquitty_sync: a Receipt longer than its counts", 0)
        end
        M.note_input_written(connection, input_written, input_settled)
    elseif frame_kind == kind.paste_receipt then
        -- How much of an unfinished paste the program has been written, which
        -- is what opens the window for its next pieces.
        local receipt = reader(body)
        local seq, written = r_u64(receipt), r_u64(receipt)
        if not at_end(receipt) then
            error("ubiquitty_sync: a PasteReceipt longer than its counts", 0)
        end
        for _, paste in ipairs(connection.pastes) do
            if paste.seq == seq then
                paste.written = math.max(paste.written, written)
            end
        end
        pump_pastes(connection)
    elseif frame_kind == kind.input_discarded then
        -- A signal character discarded the input the pane held unwritten:
        -- every event above inputWritten and at or below throughSeq. They are
        -- counted, and no more of a paste among them is sent.
        local discarded = reader(body)
        local input_written, through = r_u64(discarded), r_u64(discarded)
        if not at_end(discarded) or through <= input_written then
            error("ubiquitty_sync: an InputDiscarded that names no run", 0)
        end
        connection.input_discarded = connection.input_discarded + math.max(0, math.min(through, connection.input_seq) - input_written)
        local kept = {}
        for _, paste in ipairs(connection.pastes) do
            if paste.seq <= input_written or paste.seq > through then
                kept[#kept + 1] = paste
            end
        end
        connection.pastes = kept
        M.note_input_written(connection, through, connection.input_settled)
        pump_pastes(connection)
    elseif frame_kind == kind.notify then
        local status = read_consent_status(body, connection.consent_phase and connection.consent_phase ~= "approved")
        if status then
            if channel ~= 0 then error("own consent on a pane", 0) end
            receive_consent_status(connection, status)
        else
            -- A kind this client does not know is skipped by the frame's
            -- length; the rest are kept as { kind, record }.
            local notify_kind, record = read_notify(body)
            if notify_kind >= wire.notify_kind.attachments and notify_kind <= wire.notify_kind.paste_ready then
                connection.notifies[#connection.notifies + 1] = { kind = notify_kind, record = record }
                if #connection.notifies > 8 then table.remove(connection.notifies, 1) end
            end
        end
    elseif frame_kind == kind.result then
        -- The answer to a Call. This client makes none; one that arrives is
        -- kept for whoever sent a Call of their own on this connection.
        local result = reader(body)
        local transfer = r_varint(result)
        connection.last_result = { transfer = transfer, text = body:sub(result.at + 1) }
    elseif frame_kind == kind.bye then
        local closing = M.read_bye(body)
        connection.bye, connection.bye_reason = closing.reason, bye_reasons[closing.reason]
        connection.peer_metadata, connection.refusal_detail = closing.peer, closing.detail
        if closing.reason ~= wire.bye_reason.normal and not connection.consent_verdict then connection.refusal = connection.bye_reason end
        if connection.consent_phase and connection.consent_phase ~= "approved" then connection.consent_phase = "closed" end
        connection.welcomed = false
        connection.transport_closed = true
    elseif frame_kind == kind.history_reset then
        -- A cleared history takes the stored record with it, inside the read
        -- that says so: the screen before the clear is never stored again.
        M.purge_record(connection)
        connection.reset_generation = connection.generation or 0
    elseif not unsolicited_kind[frame_kind] and not M.known_kind[frame_kind] then
        error("ubiquitty_sync: Sync kind " .. frame_kind .. ", which no version this client speaks defines", 0)
    end
end

-- Acknowledges what the connection took since the last Ack. Stream bytes are
-- acknowledged whether or not they completed a generation: the host's window
-- retires bytes only on an Ack, so the chunks of a checkpoint larger than the
-- window wait on one.
local function send_owed_ack(connection)
    if connection.transport_closed then return end
    if connection.stream_received <= connection.stream_acknowledged then
        return
    end
    connection.stream_acknowledged = connection.stream_received
    local handles = connection.effect_ack_handles
    if connection.ack_owed and connection.pane then
        handles[connection.pane] = true
    end
    local pane_acks = {}
    for handle in pairs(handles) do
        -- Picture identity is shared; only this handle's completed effect
        -- batch may be acknowledged. This client keeps no history.
        pane_acks[#pane_acks + 1] = put_varint(handle) .. (connection.generation_bytes or effects.zero) .. put_u64(0)
            .. (connection.effect_cursors[handle] and connection.effect_cursors[handle].acknowledged or effects.zero)
    end
    local panes = put_varint(#pane_acks) .. table.concat(pane_acks)
    connection.effect_ack_handles = {}
    connection.ack_owed = false
    send_sync(connection, kind.ack, 0,
        put_u64(connection.host_time) .. put_u32(0) .. put_u64(connection.stream_received) .. panes)
end


local function refuse_frame(connection, tag, length, failure)
    connection.protocol_failure, connection.input_closed = tostring(failure), true
    connection.welcomed = false
    connection.accumulator = ""
    connection.envelope_state = nil
    connection.transfers, connection.image_transfers = {}, {}
    connection.sample_slots, connection.sample_transfers = {}, {}
    connection.clipboard_transfers = {}
    connection.clipboard_reserved_bytes = connection.delivering_clipboard_bytes or 0
    connection.deferred_effects, connection.deferred_effect_bytes = {}, 0
    if connection.stdin and connection.stdin.close and not connection.stdin:is_closing() then connection.stdin:close() end
    vim.notify(string.format("ubiquitty_sync: refused frame 0x%02x (%d bytes): %s", tag, length, tostring(failure)), vim.log.levels.WARN)
end

-- Lua strings are immutable. Coalesce at 1KiB so byte-at-a-time input keeps
-- at most 1024 current fragment references and ceil(bodyBytes/1024) completed
-- block references (at most 64). These slot bounds are checked before retaining
-- a fragment; they are metadata bounds, not an estimate of Lua allocator bytes.
-- Each byte participates in one block join and one final envelope join, giving
-- linear copying without a table node for every byte of the whole body.
local fragment_block_bytes = 1024

function M.feed(connection, data)
    if connection.protocol_failure or connection.detaching or connection.transport_closed then return end
    local registered = connections[connection.buffer]
    if registered and registered ~= connection then return end
    if connection.active_feed and same_connection_owner(connection, connection.active_feed) then
        return refuse_frame(connection, 0, 0, "recursive transport feed")
    end
    local ticket = connection_owner(connection)
    connection.active_feed = ticket
    local state = connection.envelope_state or { header = "", received = 0 }
    connection.envelope_state = state
    local at = 1
    local ok, failure = pcall(function()
        while at <= #data do
            if not state.info then
                if #state.header >= wire.max_envelope_header then error("oversized envelope header", 0) end
                state.header = state.header .. data:sub(at, at)
                at = at + 1
                local header = envelope_header(state.header)
                if header then
                    admit_header(connection, header)
                    state.info, state.parts, state.blocks = header, {}, {}
                    state.received, state.block_bytes = 0, 0
                    state.part_limit = math.min(header.size, fragment_block_bytes)
                    state.block_limit = math.ceil(header.size / fragment_block_bytes)
                end
            end
            if state.info then
                local size = state.info.size
                local count = math.min(size - state.received, #data - at + 1, fragment_block_bytes - state.block_bytes)
                if count > 0 then
                    if #state.parts >= state.part_limit then error("envelope fragment metadata exceeded", 0) end
                    state.parts[#state.parts + 1] = data:sub(at, at + count - 1)
                    at, state.received = at + count, state.received + count
                    state.block_bytes = state.block_bytes + count
                    if state.block_bytes == fragment_block_bytes or state.received == size then
                        if #state.blocks >= state.block_limit then error("envelope block metadata exceeded", 0) end
                        state.blocks[#state.blocks + 1] = table.concat(state.parts)
                        state.parts, state.block_bytes = {}, 0
                    end
                end
                if state.received == size then
                    -- One extra, bounded header slot avoids copying the joined
                    -- body again just to prepend its at-most-nine-byte header.
                    state.blocks[0] = state.header
                    local envelope = table.concat(state.blocks, "", 0, #state.blocks)
                    state = { header = "", received = 0 }
                    connection.envelope_state = state
                    on_sync(connection, envelope)
                    -- A callback may retire this owner, begin another generation,
                    -- replace its pipes, or synchronously refuse recursive input.
                    if not same_connection_owner(connection, ticket) or connection.protocol_failure or connection.transport_closed
                        or connection.detaching or connection.input_closed then break end
                end
            end
        end
    end)
    if connection.active_feed == ticket then connection.active_feed = nil end
    if not same_connection_owner(connection, ticket) then return end
    if not ok then return refuse_frame(connection, #state.header > 0 and byte(state.header, 1) or 0, state.received, failure) end
    if connection.protocol_failure then return end
    connection.accumulator = state.header
    connection.envelope_state = state.header ~= "" and state or nil
    if not connection.transport_closed and not connection.detaching and not connection.input_closed then send_owed_ack(connection) end
end

local function close_handle(handle)
    if handle and not handle:is_closing() then
        handle:close()
    end
end

local function on_bridge_exit(connection, code, signal)
    -- A bridge that went without a detach leaves the attachment to resume.
    if not connection.detaching and not connection.pane_ended then
        pcall(M.persist, connection)
    end
    connections[connection.buffer] = nil
    if connection.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, connection.augroup)
    end
    close_handle(connection.stdin)
    -- The pipes drain their tails through their own EOF callbacks; whatever is
    -- still open a moment later is closed here.
    vim.defer_fn(function()
        close_handle(connection.stdout)
        close_handle(connection.stderr)
        close_handle(connection.process)
    end, 100)
    local why
    if connection.refusal then
        why = connection.refusal .. (connection.refusal_detail and connection.refusal_detail ~= "" and (": " .. connection.refusal_detail) or "")
        if connection.peer_metadata then
            local peer = connection.peer_metadata
            why = why .. string.format(" [host %s %s, wire %d]", peer.app_version, peer.platform, peer.version)
        end
    elseif connection.last_stderr_line then
        why = connection.last_stderr_line
    end
    local note
    if connection.detaching then
        note = "detached"
    elseif connection.session_ended then
        note = "the session ended"
    else
        note = string.format("bridge exited (code %d%s)", code, signal ~= 0 and (", signal " .. signal) or "")
    end
    if why then
        note = note .. ": " .. why
    end
    chan_send(connection, "\r\n[ubiquitty_sync: " .. note .. "]\r\n")
    if not connection.detaching then
        vim.notify("ubiquitty_sync: " .. note, connection.session_ended and vim.log.levels.INFO or vim.log.levels.WARN)
    end
    connection.exited = true
end

local function spawn_bridge(connection, host, socket)
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local args = { "--attach" }
    if socket then
        args[#args + 1] = "--socket"
        args[#args + 1] = socket
    end
    local process, failure = uv.spawn(host, { args = args, stdio = { stdin, stdout, stderr } }, function(code, signal)
        vim.schedule(function()
            on_bridge_exit(connection, code, signal)
        end)
    end)
    if not process then
        close_handle(stdin)
        close_handle(stdout)
        close_handle(stderr)
        error("ubiquitty_sync: cannot run " .. host .. " --attach: " .. tostring(failure), 0)
    end
    connection.process, connection.stdin, connection.stdout, connection.stderr = process, stdin, stdout, stderr
    stdout:read_start(function(_, data)
        if data then
            vim.schedule(function()
                M.feed(connection, data)
            end)
        else
            close_handle(stdout)
        end
    end)
    stderr:read_start(function(_, data)
        if data then
            for line in data:gmatch("[^\r\n]+") do
                connection.last_stderr_line = line
            end
        else
            close_handle(stderr)
        end
    end)
end

-- Sends the window's terminal size when it differs from the one the host has.
function M.resize(buffer)
    local connection = connections[buffer]
    if not connection then
        return
    end
    local window = window_for(buffer)
    if not window then
        return
    end
    local columns, rows = geometry(window)
    if columns ~= connection.columns or rows ~= connection.rows then
        connection.columns, connection.rows = columns, rows
        -- The viewport travels in a Facts of the client's own. A buffer has no
        -- pixel geometry: the pixel fields are zero, which the host reads as
        -- not measured. Before the Welcome the Greet's facts are still to be
        -- read, so the size waits for it. The pane's own size follows in
        -- its Viewport.
        M.send_facts(connection)
        send_viewport(connection)
    end
end

-- Ends this buffer's attach: Normal Bye tells the daemon the client is not coming
-- back, and closing the bridge's stdin lets it exit. The session stays unless
-- it was created with end_when_detached.
function M.detach(buffer)
    buffer = buffer or vim.api.nvim_get_current_buf()
    local connection = connections[buffer]
    if not connection then
        return false
    end
    if connection.detaching then
        -- A second request ends a bridge that did not leave on its own.
        if connection.process then
            pcall(connection.process.kill, connection.process, "sigterm")
        end
        return true
    end
    connection.detaching = true
    -- A detach ends the attachment, so there is nothing left to resume.
    M.purge_record(connection)
    send_sync(connection, kind.bye, 0, char(wire.bye_reason.normal) .. "\0\0")
    connection.input_closed = true -- Bye is the last envelope sent up the bridge.
    local stdin = connection.stdin
    if stdin and not stdin:is_closing() then
        stdin:shutdown(function()
            close_handle(stdin)
        end)
    end
    return true
end

-- Sends bytes to the session as if typed into the buffer.
function M.send_input(buffer, bytes)
    local connection = connections[buffer]
    if not connection then
        return false
    end
    send_raw(connection, bytes)
    return true
end

-- Pastes text into the session: the host brackets it when the program asked
-- for bracketed paste, and it is sent no faster than the program reads it.
function M.paste(buffer, text)
    local connection = connections[buffer]
    if not connection then
        return false
    end
    return M.paste_on(connection, text)
end

-- What the attach in a buffer has seen, for a caller that waits on it.
function M.status(buffer)
    local connection = connections[buffer]
    if not connection then
        return nil
    end
    return {
        session_id = connection.session_id,
        admission = connection.consent_phase or (connection.welcomed and "granted" or "greeting"),
        consent_verdict = connection.consent_verdict,
        checkpoints = connection.checkpoints,
        updates = connection.updates,
        input_sent = connection.input_seq,
        input_written = connection.input_written,
        input_settled = connection.input_settled,
        input_discarded = connection.input_discarded,
        pastes_unfinished = #connection.pastes,
        echo = connection.echo,
        bye = connection.bye_reason,
        pane_ended = connection.pane_ended,
        refusal = connection.refusal,
        peer_metadata = connection.peer_metadata,
        last_stderr_line = connection.last_stderr_line,
        generation = connection.generation,
        stream_received = connection.stream_received,
        resumed = connection.welcome and connection.welcome.resumed,
        client_instance = connection.client_instance,
    }
end

-- The text of the screen the buffer holds, row by row, as the client decoded
-- it: what the terminal shows once it has drawn what it was sent.
function M.screen_text(buffer)
    local connection = connections[buffer]
    if not connection or not connection.records then
        return nil
    end
    local lines = {}
    for row = 0, #connection.records[1] - 1 do
        lines[#lines + 1] = M.row_text(connection, row)
    end
    return table.concat(lines, "\n")
end

-- A connection's state before any frame: the frame loop's accumulator, the
-- screen plane's acknowledgement counters, and the screens it holds.
function M.new_connection(buffer)
    return {
        buffer = buffer,
        accumulator = "", -- at most one canonical header; body pieces have their own bounded owner
        transport_generation = 0,
        stream_received = 0,
        stream_acknowledged = 0,
        host_time = 0,
        transfers = {},
        image_assets = {},
        image_transfers = {},
        sample_slots = {},
        sample_transfers = {},
        clipboard_transfers = {},
        clipboard_reserved_bytes = 0,
        clipboard_write_handler = M.options.clipboard_write_handler,
        deferred_effects = {},
        deferred_effect_bytes = 0,
        image_revision = 0,
        effect_cursor = effects.new(),
        effect_cursors = {},
        pane_bindings = {},
        effect_ack_handles = {},
        effects = {},
        buffered_updates = {},
        buffered_bytes = 0,
        checkpoints = 0,
        updates = 0,
        cursor = { row = 0, column = 0, style = 0 },
        cursor_visible = true,
        reverse_video = false,
        crt_blanked = false,
        columns = 80,
        rows = 24,
        focused = true, -- what the Greet says until a focus event says otherwise
        input_seq = 0, -- the number of the newest input event sent to the pane
        input_written = 0, -- the newest the host has written to the program
        input_settled = 0,
        input_discarded = 0, -- events a signal character dropped unwritten
        queued_input = {}, -- typed before the pane was bound
        pastes = {}, -- pastes the host has not written whole, oldest first
        pastes_aborted = 0,
        typed_carry = "", -- the head of a bracket marker cut by a read
        notifies = {},
    }
end

-- Runs the daemon on demand, opens a terminal buffer in the current window and
-- attaches it through the bridge.
--
-- - Returns: the attached buffer number.
function M.start()
    local options = M.options
    local host = vim.fn.exepath(options.host_program)
    if host == "" then
        error("ubiquitty_sync: no executable " .. options.host_program
            .. "; set host_program to the daemon binary (the app bundle's Helpers/ubiquitty-host,"
            .. " a host from https://ubiquitty.org/docs/remote-hosts/, or Scripts/build-host.sh)", 0)
    end
    local socket = options.socket and vim.fs.basename(options.socket) or nil
    if options.auto_start then
        local args = { host, "--ensure-daemon" }
        if socket then
            args[#args + 1] = "--socket"
            args[#args + 1] = socket
        end
        local result = vim.system(args, { text = true }):wait()
        if result.code ~= 0 then
            error(string.format("ubiquitty_sync: %s --ensure-daemon exited %d: %s", host, result.code, vim.trim(result.stderr or "")), 0)
        end
    end

    local buffer = vim.api.nvim_create_buf(true, false)
    local connection = M.new_connection(buffer)
    connection.end_when_detached = options.end_when_detached
    connection.terminal = vim.api.nvim_open_term(buffer, {
        on_input = function(_, _, _, data)
            M.feed_typed(connection, data)
        end,
    })
    vim.bo[buffer].bufhidden = "hide"
    connections[buffer] = connection
    set_title(connection, "")
    pcall(vim.api.nvim_set_current_buf, buffer)

    local window = window_for(buffer)
    if window then
        connection.columns, connection.rows = geometry(window)
    else
        connection.columns, connection.rows = 80, 24
    end

    connection.augroup = vim.api.nvim_create_augroup("ubiquitty_sync_" .. buffer, { clear = true })
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = connection.augroup,
        callback = function()
            M.resize(buffer)
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = connection.augroup,
        buffer = buffer,
        callback = function()
            M.resize(buffer)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = connection.augroup,
        buffer = buffer,
        callback = function()
            M.detach(buffer)
        end,
    })
    vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
        group = connection.augroup,
        callback = function()
            if vim.api.nvim_get_current_buf() == buffer then
                M.set_focus(buffer, true)
            end
        end,
    })
    vim.api.nvim_create_autocmd("FocusLost", {
        group = connection.augroup,
        callback = function()
            M.set_focus(buffer, false)
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        group = connection.augroup,
        buffer = buffer,
        callback = function()
            M.set_focus(buffer, false)
        end,
    })
    for _, mode in ipairs({ "t", "n" }) do
        vim.keymap.set(mode, "<C-\\><C-q>", function()
            M.detach(buffer)
        end, { buffer = buffer, desc = "ubiquitty_sync: detach" })
    end
    -- Neovim exiting stores the record; the bridge then goes without a Bye.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = connection.augroup,
        callback = function()
            if connections[buffer] == connection then
                pcall(M.persist, connection)
            end
        end,
    })

    -- The stored screen is drawn before the bridge starts, so before any
    -- packet can arrive.
    connection.host = host
    local record = M.read_record(connection, M.stored_client_instance())
    if record then
        M.restore(connection, record)
    end
    spawn_bridge(connection, host, socket)
    send_greet(connection)
    if window then
        vim.cmd.startinsert()
    end
    return buffer
end

-- The :UbiquittySync command: no argument attaches, `detach` ends the current
-- buffer's attach.
function M.command(argument)
    argument = vim.trim(argument or "")
    if argument == "" then
        M.start()
    elseif argument == "detach" then
        if not M.detach(vim.api.nvim_get_current_buf()) then
            vim.notify("ubiquitty_sync: this buffer is not attached", vim.log.levels.WARN)
        end
    else
        vim.notify("ubiquitty_sync: unknown argument " .. argument .. " (accepted: detach)", vim.log.levels.ERROR)
    end
end

return M
