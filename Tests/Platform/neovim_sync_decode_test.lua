-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- The Neovim client decodes a real Sync stream.
--
-- Feeds the client the bytes a host connection sent a client that attached
-- (Tests/Platform/sync_stream_fixture.cpp writes them) and asserts what the
-- terminal buffer shows and what the client answers. A decoder that walks one
-- field wrong still paints something, so the assertions are values chosen at
-- capture time — a cursor at row 4 column 8, a first row that reads
-- UBIQUITTY-SYNC-OK — and a version skew is an error rather than an empty
-- buffer.
--
-- Then the client's own half: what it sends for a key, a paste, an interrupt,
-- a focus change and a resize, against the frames a host sends back about
-- its input (the fixture's third file). Everything it sent is written to the
-- fourth path, for the fixture's --verify to read with the host's decoders.
--
--     nvim --headless -l Tests/Platform/neovim_sync_decode_test.lua <attach.bin> <update.bin> <control.bin> <upstream.bin>

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(script, ":p:h")
local lua_root = here .. "/../../Source/Platform/Neovim/lua"
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path

local sync = require("ubiquitty_sync")
local wire = require("ubiquitty_sync.wire")
local fixture = dofile(here .. "/editor_wire_fixture.lua")

local function say(line)
    io.stdout:write(line, "\n")
end

local failures = 0

local function check(ok, what)
    if not ok then
        failures = failures + 1
        say("FAIL " .. what)
    end
end

local function read(path)
    local handle = path and io.open(path, "rb")
    if not handle then
        say("FAIL the fixture was not readable: " .. tostring(path))
        os.exit(1)
    end
    local bytes = handle:read("*a")
    handle:close()
    return bytes
end

local attach = read(arg[1])
local update = read(arg[2])
local control = read(arg[3])
local upstream_path = arg[4]
local pictures = read(arg[5])

local function u32(s, at)
    local a, b, c, d = s:byte(at + 1, at + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(s, at)
    return u32(s, at) + u32(s, at + 4) * 4294967296
end

local function varint(s, at)
    local value, scale = 0, 1
    while true do
        local b = s:byte(at + 1)
        at = at + 1
        value = value + (b % 128) * scale
        if b < 128 then
            return value, at
        end
        scale = scale * 128
    end
end

-- The direct canonical envelopes in a stream, as { kind, channel, body }.
local function sync_frames(stream)
    local frames, at = {}, 1
    while at <= #stream do
        local header = assert(sync.envelope_header(stream:sub(at)), "partial fixture header")
        local start = at + header.bytes
        assert(start + header.size - 1 <= #stream, "partial fixture body")
        frames[#frames + 1] = { kind = header.kind, channel = header.channel, body = stream:sub(start, start + header.size - 1) }
        at = start + header.size
    end
    return frames
end

-- The frames the client sends are recorded rather than written.
local sent = {}
local function sent_sync(kind)
    local bodies = {}
    for _, frame in ipairs(sync_frames(table.concat(sent))) do
        if frame.kind == kind then
            bodies[#bodies + 1] = frame.body
        end
    end
    return bodies
end

-- The terminal is as wide as the host's grid. At any other width the row's
-- last column is not the margin, and an erase that starts inside a wide glyph
-- there lands harmlessly past the text instead.
vim.cmd("vsplit")
vim.api.nvim_win_set_width(0, 20)
vim.wo.number = false
vim.wo.signcolumn = "no"
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)
local terminal = vim.api.nvim_open_term(buffer, {})

local connection = sync.new_connection(buffer)
connection.admission_request = fixture.request()
connection.terminal = terminal
connection.stdin = {
    is_closing = function()
        return false
    end,
    write = function(_, data)
        sent[#sent + 1] = data
    end,
}

local function lines()
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function settle(predicate)
    vim.wait(500, predicate, 10)
end

local function envelope_split_sweeps()
    for _, size in ipairs({ 1, 127, 128, 1023, 1024, 1025, 16383, 16384, 65535 }) do
        local bytes = {}
        for index = 1, size - 1 do
            bytes[index] = string.char((index * 37 + math.floor(index / 251)) % 256)
        end
        local text = table.concat(bytes)
        local probe = "abcdefgh"
        local stream = sync.sync_frame(sync.kind.result, 0, "\0" .. text)
            .. sync.sync_frame(sync.kind.probe, 0, probe)
        local expected_echo = sync.sync_frame(sync.kind.echo, 0, probe .. string.rep("\0", 4))
        local function replay(ends, label)
            local reader = sync.new_connection(buffer)
            reader.welcome = { target = 0 }
            reader.welcomed = true
            local outgoing = {}
            reader.stdin = {
                is_closing = function() return false end,
                write = function(_, data) outgoing[#outgoing + 1] = data end,
            }
            local at = 1
            for _, finish in ipairs(ends) do
                sync.feed(reader, stream:sub(at, finish))
                at = finish + 1
            end
            local echoes = {}
            for _, frame in ipairs(sync_frames(table.concat(outgoing))) do
                if frame.kind == sync.kind.echo then
                    echoes[#echoes + 1] = sync.sync_frame(frame.kind, frame.channel, frame.body)
                end
            end
            local matches = not reader.protocol_failure and reader.accumulator == ""
                and reader.envelope_state == nil and reader.stream_received == #stream
                and reader.last_result and reader.last_result.transfer == 0 and reader.last_result.text == text
                and table.concat(echoes) == expected_echo
            check(matches, string.format("envelope split sweep size=%d %s", size, label))
            return matches
        end
        local function sweep()
            if not replay({ #stream }, "whole") then return end
            local cuts = { [0] = true, [#stream] = true }
            if size <= 128 then
                for cut = 1, #stream - 1 do cuts[cut] = true end
            else
                local quantum = 1
                while quantum <= #stream do
                    for _, cut in ipairs({ quantum - 1, quantum, quantum + 1 }) do
                        if cut <= #stream then cuts[cut], cuts[#stream - cut] = true, true end
                    end
                    quantum = quantum * 2
                end
            end
            local ordered = {}
            for cut in pairs(cuts) do ordered[#ordered + 1] = cut end
            table.sort(ordered)
            for _, cut in ipairs(ordered) do
                if not replay({ cut, #stream }, "split=" .. cut) then return end
            end
            if size <= 128 then
                local ends = {}
                for finish = 1, #stream do ends[#ends + 1] = finish end
                if not replay(ends, "byte-at-a-time") then return end
            end
            for seed = 1, 32 do
                local state, finish, ends = seed, 0, {}
                local maximum = seed % 2 == 1 and 17 or 4096
                while finish < #stream do
                    state = (state * 48271) % 2147483647
                    finish = math.min(#stream, finish + 1 + state % maximum)
                    ends[#ends + 1] = finish
                end
                if not replay(ends, "seed=" .. seed) then return end
            end
        end
        sweep()
    end
end

envelope_split_sweeps()

-- The attach, in reads smaller than the frame header, so the loop is asked for
-- the case where even the length is split.
for at = 1, #attach, 3 do
    sync.feed(connection, attach:sub(at, at + 2))
end
check(connection.checkpoints == 1, string.format("the attach applied %d checkpoints, expected 1", connection.checkpoints))
check(connection.accumulator == "", "the frame loop held bytes back after whole frames")

check(sync.row_text(connection, 0):sub(1, 17) == "UBIQUITTY-SYNC-OK",
    string.format("the first row reads back: %q", sync.row_text(connection, 0)))
check(sync.row_text(connection, 1):sub(1, 9) == "RED plain",
    string.format("the second row reads back: %q", sync.row_text(connection, 1)))
-- Two wide glyphs, a sized cell carrying a grapheme cluster, then a
-- proportional run. The cluster and the run are both id 1, so a decoder that
-- reads the id without the cell's text-size spec shows the run's text where
-- the cluster belongs.
local row_three = sync.row_text(connection, 3)
check(row_three:find("日本👨‍👩PROP", 1, true) == 1,
    string.format("the sized, clustered and proportional row reads back: %q", row_three))
check(row_three:sub(-3) == "世", string.format("the third row does not end on its wide glyph: %q", row_three))
check(connection.cursor.row == 4 and connection.cursor.column == 8,
    string.format("the cursor decoded at %d,%d, expected 4,8", connection.cursor.row, connection.cursor.column))
check(connection.cursor_visible, "the cursor decoded as hidden")

-- The modes the embedded terminal mirrors: mouse tracking in the SGR encoding,
-- and bracketed paste.
local modes = sync.mode_sequence({}, connection.modes)
check(modes:find("\27[?1000h", 1, true) ~= nil, string.format("the mode sequence does not enable mouse tracking: %q", modes))
check(modes:find("\27[?1006h", 1, true) ~= nil, string.format("the mode sequence does not enable the SGR encoding: %q", modes))
check(modes:find("\27[?2004h", 1, true) ~= nil, string.format("the mode sequence does not enable bracketed paste: %q", modes))

settle(function()
    return (lines()[1] or ""):sub(1, 17) == "UBIQUITTY-SYNC-OK"
end)
local shown = lines()
check((shown[1] or ""):sub(1, 17) == "UBIQUITTY-SYNC-OK", string.format("the terminal buffer's first line reads: %q", shown[1]))
check((shown[2] or ""):sub(1, 9) == "RED plain", string.format("the terminal buffer's second line reads: %q", shown[2]))
check((shown[4] or ""):find("👨‍👩", 1, true) ~= nil and (shown[4] or ""):sub(-3) == "世",
    string.format("the terminal buffer's fourth line reads: %q", shown[4]))

-- The checkpoint is acknowledged: its generation on the pane's handle, and
-- every stream byte the attach carried, so the host's window moves.
local stream_bytes = #attach
local acks = sent_sync(sync.kind.ack)
local last = acks[#acks]
check(last ~= nil and u64(last, 12) == stream_bytes,
    string.format("the last Ack counts %s stream bytes, the attach carried %d", last and u64(last, 12) or "no", stream_bytes))
local checkpoint_generation = connection.generation
local named = false
for _, ack in ipairs(acks) do
    local count, at = varint(ack, 20)
    if count == 1 then
        local handle
        handle, at = varint(ack, at)
        named = named or (handle == connection.pane and u64(ack, at) == checkpoint_generation)
    end
end
check(checkpoint_generation and checkpoint_generation > 0 and named,
    "no Ack names the checkpoint's generation on the pane's handle")

-- The pane is shown as soon as it is bound: the host sends a pane's screen
-- only once the client says so.
do
    local views = sent_sync(sync.kind.view)
    check(#views >= 1 and views[1] == string.char(0), "the bound pane was not set Live")
end

-- Whole records come from the C++ encoder, not a second fixture spelling of
-- the layout. They must work without TITLE, and a malformed tail publishes
-- nothing even though its title prefix is complete.
do
    local records = {}
    for _, frame in ipairs(sync_frames(control)) do
        if frame.kind == sync.kind.pane_facts then records[#records + 1] = frame end
    end
    check(#records == 2, "the fixture carries full and empty PaneFacts")
    if #records == 2 then
        local full, cleared = records[1], records[2]
        local facts = sync.read_pane_facts(full.body)
        check(facts.title == "recorded-title" and facts.directory == "/srv/project"
            and facts.foreground == "less" and not facts.at_prompt, "PaneFacts title inputs decode whole")
        for length = 0, #full.body - 1 do
            check(not pcall(sync.read_pane_facts, full.body:sub(1, length)), "truncated PaneFacts accepted at " .. length)
        end
        check(not pcall(sync.read_pane_facts, full.body .. "x"), "PaneFacts accepted trailing bytes")
        sync.feed(connection, sync.sync_frame(full.kind, connection.pane + 1, full.body))
        check(connection.title ~= facts.title, "another pane's facts retitled this buffer")
        sync.feed(connection, sync.sync_frame(full.kind, connection.pane, full.body))
        check(connection.title == facts.title, "PaneFacts alone did not retitle the buffer")
        sync.feed(connection, sync.sync_frame(cleared.kind, connection.pane, cleared.body))
        check(connection.title == "" and connection.pane_facts.directory == "" and connection.pane_facts.at_prompt,
            "an empty whole record did not clear title inputs")
    end
end

-- The text-only frontend validates image records without caching, rendering,
-- requesting or accumulating freshly pushed pixels. The hash is the canonical
-- 2x2 RGBA vector shared with the Core and Emacs tests.
do
    local function le32(value)
        return string.char(value % 256, math.floor(value / 256) % 256,
            math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
    end
    local hash = string.char(0xd5, 0xe7, 0x34, 0x7a, 0x4b, 0x32, 0x1d, 0xf4, 0x39, 0x17, 0xc8, 0x6a, 0x75, 0xdc, 0x22, 0x32)
    local asset = hash .. string.char(32) .. le32(2) .. le32(2)
    local binding = le32(7) .. le32(0) .. asset .. string.rep("\0", 9)
    local state = le32(1) .. "\1" .. binding .. "\0"
    local head = asset .. le32(101)
    local pixels = string.char(255, 0, 0, 127, 0, 255, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255)
    check(sync.read_image_head(head).asset.pixel_bytes == 16, "ImageHead decoded dimensions do not determine its exact pixels")
    check(sync.read_image_placements(state).images[7].hash == hash, "ImagePlacements did not bind its content identity")
    for length = 0, #head - 1 do
        check(not pcall(sync.read_image_head, head:sub(1, length)), "truncated ImageHead accepted at " .. length)
    end
    for length = 0, #state - 1 do
        check(not pcall(sync.read_image_placements, state:sub(1, length)), "truncated ImagePlacements accepted at " .. length)
    end
    check(not pcall(sync.read_image_head, head .. "x"), "ImageHead accepted trailing bytes")
    check(not pcall(sync.read_image_placements, state .. "x"), "ImagePlacements accepted trailing bytes")
    check(not pcall(sync.read_image_head, hash .. "\32" .. le32(0) .. le32(2) .. le32(1)), "zero-width ImageHead was accepted")
    check(not pcall(sync.read_image_placements, le32(1) .. "\2" .. binding .. binding .. "\0"), "duplicate image binding was accepted")
    check(not pcall(sync.read_image_placements, le32(1) .. "\129\0" .. binding .. "\0"), "noncanonical image count was accepted")

    local images = fixture.connection(buffer)
    images.pane = 1
    images.pane_bindings[1] = string.rep("n", 16)
    local image_upstream = {}
    images.stdin = { is_closing = function() return false end, write = function(_, bytes) image_upstream[#image_upstream + 1] = bytes end }
    local function receive(frame_kind, channel, body)
        sync.feed(images, sync.sync_frame(frame_kind, channel, body))
    end
    local function chunk(transfer, index, last, bytes)
        local digest = (("8f513476f27a2d03dd42a52731564a4d695544d5fdddd80e3c65f027d19b09eb"):gsub("..", function(pair)
            return string.char(tonumber(pair, 16))
        end))
        return le32(transfer) .. le32(index) .. string.char(last, #bytes) .. bytes .. (last == 1 and digest or "")
    end
    receive(sync.kind.image_placements, 2, state)
    check(images.image_revision == 0, "another pane's image record changed the current pane")
    receive(sync.kind.image_placements, 1, state)
    receive(sync.kind.image_head, 1, head)
    receive(sync.kind.bulk_chunk, 0, chunk(101, 0, 0, pixels:sub(1, 8)))
    check(images.image_transfers[101] and images.image_transfers[101].received == 8
        and images.image_transfers[101].chunks == nil and images.transfers[101] == nil,
        "text-only image receive accumulated pixel bodies")
    receive(sync.kind.bulk_chunk, 0, chunk(101, 1, 1, pixels:sub(9)))
    check(images.image_transfers[101] == nil and images.transfers[101] == nil, "a discarded image left an assembly behind")
    receive(sync.kind.image_head, 1, asset .. le32(0))
    for _, frame in ipairs(sync_frames(table.concat(image_upstream))) do
        check(frame.kind ~= sync.kind.image_want, "a text-only client requested pixels it cannot render")
    end
    receive(sync.kind.image_head, 1, asset .. le32(102))
    receive(sync.kind.bulk_chunk, 0, chunk(102, 0, 0, pixels:sub(1, 8)))
    receive(sync.kind.image_placements, 1, le32(2) .. "\0\0")
    receive(sync.kind.bulk_chunk, 0, chunk(102, 1, 1, pixels:sub(9)))
    check(images.image_transfers[102] == nil and images.transfers[102] == nil, "deleted image chunks entered the generic reassembler")
    receive(sync.kind.image_placements, 1, le32(3) .. state:sub(5))
    receive(sync.kind.image_head, 1, asset .. le32(103))
    receive(sync.kind.pane_unbind, 0, "\1\0")
    receive(sync.kind.bulk_chunk, 0, chunk(103, 0, 1, pixels))
    check(next(images.image_transfers) == nil and images.transfers[103] == nil, "pane unbind retained late image data")
end

-- An update that does not decode asks for a checkpoint and leaves the screen
-- as it was.
local carried
for _, frame in ipairs(sync_frames(update)) do
    if frame.kind == sync.kind.update then
        carried = frame
    end
end
check(carried ~= nil, "the update fixture carries no Update")
local notify = vim.notify
vim.notify = function() end
sync.feed(connection, sync.sync_frame(sync.kind.update, carried.channel, carried.body:sub(1, #carried.body - 20)))
vim.notify = notify
local resyncs = sent_sync(sync.kind.resync)
check(#resyncs == 1 and resyncs[1]:byte(1) == sync.resync_reason.decode_failed,
    "a truncated update did not ask for a checkpoint")
check(sync.row_text(connection, 5):find("update-row-six", 1, true) == nil, "a truncated update changed the screen")
-- The checkpoint that Resync asks for is the attach again.
connection.resync_outstanding = false

-- The update itself: a row written, the cursor moved, bracketed paste off.
sync.feed(connection, update)
check(connection.updates == 1, string.format("the update applied %d times, expected once", connection.updates))
check(sync.row_text(connection, 5):sub(1, 14) == "update-row-six",
    string.format("the updated row reads back: %q", sync.row_text(connection, 5)))
check(sync.row_text(connection, 0):sub(1, 17) == "UBIQUITTY-SYNC-OK", "an update naming one row disturbed another")
check(connection.cursor.row == 5 and connection.cursor.column == 14,
    string.format("the update's cursor decoded at %d,%d, expected 5,14", connection.cursor.row, connection.cursor.column))
check(connection.generation > checkpoint_generation, "the update's generation is not held")
check(connection.modes[4] == false, "the update's modes block did not turn bracketed paste (flag 4) off")
settle(function()
    for _, line in ipairs(lines()) do
        if line:find("update-row-six", 1, true) then
            return true
        end
    end
    return false
end)
check((lines()[6] or ""):sub(1, 14) == "update-row-six", string.format("the terminal buffer's sixth line reads: %q", lines()[6]))

-- The same update again is behind the screen and asks for nothing; one onto a
-- generation the screen does not hold is a gap only a checkpoint closes.
sync.feed(connection, update)
check(#sent_sync(sync.kind.resync) == 1, "an update the screen is already past asked for a checkpoint")
connection.generation = 0
sync.feed(connection, update)
resyncs = sent_sync(sync.kind.resync)
check(#resyncs == 2 and resyncs[2]:byte(1) == sync.resync_reason.base_missing,
    "an update onto a generation not held did not ask for a checkpoint")

-- The update rule on its own.
check(sync.update_disposition(7, 0, 7, 8) == "apply", "a chained update on the screen held is not applied")
check(sync.update_disposition(7, 1, 5, 8) == "apply", "a superset update from before the screen held is not applied")
check(sync.update_disposition(7, 0, 6, 8) == "resync", "a chained update on another generation does not ask for a checkpoint")
check(sync.update_disposition(7, 1, 3, 7) == "stale", "an update the screen is already at is not dropped")
check(sync.update_disposition(nil, 1, 0, 1) == "resync", "an update before any checkpoint does not ask for one")

-- A header declaring more than the host ever frames ends the attach instead
-- of waiting for bytes that cannot come. Its length varint passes the largest
-- body by its third byte, on a carrier of its own so the attach above stays.
local oversized = sync.new_connection(buffer)
local notices = 0
vim.notify = function() notices = notices + 1 end
sync.feed(oversized, string.char(sync.kind.welcome, 0, 0xFF, 0xFF, 0x7F))
vim.notify = notify
check(notices == 1, "a frame longer than the host frames was not reported")
check(oversized.accumulator == "" and oversized.protocol_failure,
    "a frame longer than the host frames left the stream waiting on bytes that cannot come")

-- A host at another version says so rather than leave a blank buffer.
local skewed = sync.new_connection(buffer)
local welcome = sync.sync_frame(sync.kind.welcome, 0, string.char(99, 0) .. string.rep("\0", 38))
local reported
vim.notify = function(text) reported = text end
sync.feed(skewed, welcome)
vim.notify = notify
check(reported ~= nil and reported:find("wire version 99", 1, true) ~= nil,
    "a Welcome at another wire version is not reported naming the versions")

-- ---- the welcome and the echo context ---------------------------------------

-- The Welcome is read whole: the host's version, what it grants, and every
-- trailing field.
do
    local welcome = connection.welcome
    check(welcome ~= nil and welcome.version == sync.wire_version, "the Welcome's version was not read")
    check(welcome and welcome.principal == "fixture", string.format("the Welcome's principal reads %q", tostring(welcome and welcome.principal)))
    check(welcome and welcome.predecessor == nil and #welcome.resumed == 0, "a fresh attach read a resume out of its Welcome")
    local limits = welcome and welcome.paste_limits
    check(limits ~= nil and limits.chunk_bytes == 32 * 1024 and limits.paste_bytes == 16 * 1024 * 1024,
        string.format("the Welcome's paste caps read %s and %s", tostring(limits and limits.chunk_bytes), tostring(limits and limits.paste_bytes)))
    check(limits ~= nil and limits.window_bytes == 256 * 1024, string.format("the Welcome's paste window reads %s", tostring(limits and limits.window_bytes)))
end
-- Every mandatory Welcome field is present, including the explicit paste flag.
do
    local body
    for _, frame in ipairs(sync_frames(attach)) do
        if frame.kind == sync.kind.welcome then
            body = frame.body
        end
    end
    local full = sync.read_welcome(body)
    local tail = 1 + 1 + 1 + 12 -- no predecessor, no resumed pane, present paste caps
    for cut = 0, #body - 1 do
        check(not pcall(sync.read_welcome, body:sub(1, cut)), "a truncated current Welcome was accepted")
    end
    check(not pcall(sync.read_welcome, body .. "\1\2\3"), "trailing Welcome bytes were accepted")
    local absent = sync.read_welcome(body:sub(1, #body - 13) .. "\0")
    check(absent.paste_limits == nil and absent.host_time == full.host_time, "an explicit absent paste flag was misread")
    -- The predecessor and a resumed pane, when a host states them.
    local resumed = sync.read_welcome(body:sub(1, #body - tail) .. "\1" .. string.rep("\9", 16) .. "\1" .. string.rep("\7", 16) .. "\1\1"
        .. string.char(42, 0, 0, 0, 0, 0, 0, 0) .. "\1" .. body:sub(-12))
    check(resumed.predecessor == string.rep("\9", 16) and #resumed.resumed == 1 and resumed.resumed[1].outcome == 1 and resumed.resumed[1].input_written == 42,
        "a Welcome's resume tail was not read in order")
    check(resumed.paste_limits and resumed.paste_limits.window_bytes == full.paste_limits.window_bytes, "the paste caps after a resume tail were misread")
end

-- The update carried the pane's echo context, which the Greet asked for: a
-- pane nobody has described has a new terminal's interrupt characters.
check(connection.echo ~= nil, "the update's echo context was not read")
if connection.echo then
    check(connection.echo.interrupt == 3 and connection.echo.quit == 0x1c and connection.echo.suspend == 0x1a,
        string.format("the echo context's interrupt characters read %s %s %s", tostring(connection.echo.interrupt), tostring(connection.echo.quit), tostring(connection.echo.suspend)))
    check(connection.echo.secure_entry == false, "the echo context reads as secure entry")
end
-- A checkpoint replaces everything held of the pane, the echo context with
-- it: unknown again until an update states it.
-- Replay the checkpoint, not Welcome/PaneBind: a bound handle cannot be
-- rebound on the same carrier merely to exercise picture replacement.
for _, frame in ipairs(sync_frames(attach)) do
    if frame.kind == sync.kind.checkpoint_head or frame.kind == sync.kind.bulk_chunk then
        sync.feed(connection, sync.sync_frame(frame.kind, frame.channel, frame.body))
    end
end
check(connection.checkpoints == 2 and connection.echo == nil, "a checkpoint left the echo context of the screen before it")
-- An echo context with a flag no version defines is refused.
do
    local ok = pcall(sync.read_echo_context, { s = string.rep("\0", 8) .. "\8" .. "\0\0\0\0", at = 0, stop = 13 })
    check(not ok, "an echo context with an undefined flag was read")
    local context = sync.read_echo_context({ s = "\5\0\0\0" .. "\9\0\0\0" .. "\5" .. "\2" .. "\3\28\26", at = 0, stop = 13 })
    check(context.modes_revision == 5 and context.foreground_generation == 9 and context.secure_entry and context.at_prompt and not context.foreign_input,
        "an echo context's revisions and flags were misread")
    check(context.interrupt == nil and context.quit == 28 and context.suspend == nil, "an interrupt character stated absent was read as present")
    check(context.erase == 127, "an older echo context did not default to DEL")
    for _, byte in ipairs({ 0, 8, 127, 255 }) do
        local bytes = string.rep("\0", 9) .. string.char(24, 0, 0, 0, byte)
        local reader = { s = bytes, at = 0, stop = #bytes }
        local current = sync.read_echo_context(reader)
        check(current.erase == byte and reader.at == #bytes, "the PTY erase character or its boundary was misread")
    end
    local bytes = string.rep("\0", 9) .. string.char(16, 0, 0, 0)
    check(sync.read_echo_context({ s = bytes, at = 0, stop = #bytes }).erase == nil, "disabled erase became DEL")
    for _, presence in ipairs({ 8, 32, 255 }) do
        local invalid = string.rep("\0", 9) .. string.char(presence, 0, 0, 0)
        check(not pcall(sync.read_echo_context, { s = invalid, at = 0, stop = #invalid }), "invalid erase presence was read")
    end
end

-- ---- what the client sends ---------------------------------------------------
--
-- A second attach of its own, so that what it sends is one clean stream.
do
    local request = sync.new_connection(buffer)
    request.columns, request.rows = 137, 43
    request.end_when_detached = true
    local frames = {}
    request.stdin = {
        is_closing = function() return false end,
        write = function(_, data) frames[#frames + 1] = data end,
    }
    sync.send_greet(request)
    check(#frames == 1, "one request sent more than one greeting")
    local greetings = sync_frames(frames[1])
    check(#greetings == 1 and greetings[1].kind == sync.kind.greet and greetings[1].channel == 0,
        "the first envelope is not a control-channel Greet")
    local version = fixture.little(sync.wire_version, 2)
    local expected = version .. "\0" .. wire.wire_fingerprint .. request.client_instance
        .. string.char(wire.client_kind.human, wire.role.owner, wire.admission_target.session)
        .. string.rep("\0", 16) .. "\0\0\0\0\1\0\0"
        .. fixture.little(43, 2) .. fixture.little(137, 2) .. string.rep("\0", 12) .. "\0\0\1"
        .. string.rep("\0", 8) .. fixture.varint(wire.capability.echo_context + wire.capability.shows_no_questions) .. "\0"
    local actual = greetings[1].body
    for offset = 1, math.max(#actual, #expected) do
        if actual:byte(offset) ~= expected:byte(offset) then
            check(false, string.format("Greet byte %d: got %s, expected %s; lengths %d and %d",
                offset, tostring(actual:byte(offset)), tostring(expected:byte(offset)), #actual, #expected))
            break
        end
    end
end

local upstream = {}
local scripted = sync.new_connection(buffer)
scripted.stdin = {
    is_closing = function()
        return false
    end,
    write = function(_, data)
        upstream[#upstream + 1] = data
    end,
}
local function upstream_sync(kind)
    local bodies = {}
    for _, frame in ipairs(sync_frames(table.concat(upstream))) do
        if frame.kind == kind then
            bodies[#bodies + 1] = frame.body
        end
    end
    return bodies
end
local control_frames = sync_frames(control)
local function host_says(kind)
    for _, frame in ipairs(control_frames) do
        if frame.kind == kind then
            sync.feed(scripted, sync.sync_frame(frame.kind, frame.channel, frame.body))
            return
        end
    end
    check(false, "the control fixture carries no frame of kind " .. kind)
end

-- Typed before the pane is bound: held, and sent in order once it is.
sync.feed_typed(scripted, "l")
check(#upstream == 0, "input typed before the pane was bound was sent somewhere")
sync.send_greet(scripted)
sync.feed(scripted, attach)
sync.feed_typed(scripted, "s\r")
do
    local raws = upstream_sync(sync.kind.raw)
    check(#raws == 2 and u64(raws[1], 0) == 1 and raws[1]:sub(9) == "\1l" and u64(raws[2], 0) == 2 and raws[2]:sub(9) == "\2s\r",
        "typed bytes did not go as Raw numbered from 1")
    check(scripted.input_seq == 2, "the input count did not follow the events sent")
end

-- A bracketed paste, its markers cut between reads: the text goes as Paste
-- pieces without the markers, and what was typed after it as Raw. With a
-- window of two pieces the third waits for the host's receipt.
scripted.paste_limits.window_bytes = 16384
local pasted = string.rep("p", 20000)
sync.feed_typed(scripted, "\27[20")
sync.feed_typed(scripted, "0~" .. pasted:sub(1, 5000))
sync.feed_typed(scripted, pasted:sub(5001) .. "\27[2")
check(#upstream_sync(sync.kind.paste) == 0, "a paste was sent before its closing marker arrived")
sync.feed_typed(scripted, "01~x")
do
    local pieces = upstream_sync(sync.kind.paste)
    check(#pieces == 2, string.format("%d pieces of a 20000-byte paste went into a 16384-byte window, expected 2", #pieces))
    check(pieces[1] and u64(pieces[1], 0) == 3 and u64(pieces[1], 8) == 0 and pieces[1]:byte(17) == 0, "the first piece is not numbered 3 at offset 0 with more to come")
    check(pieces[2] and u64(pieces[2], 8) == 8192, "the second piece does not start where the first ended")
    local raws = upstream_sync(sync.kind.raw)
    check(#raws == 3 and u64(raws[3], 0) == 4 and raws[3]:sub(9) == "\1x", "the key typed after the paste was not numbered after it")
end
-- A Receipt for the typing before the paste retires nothing of the paste.
host_says(sync.kind.receipt)
check(scripted.input_written == 1 and scripted.input_settled == 1, "the Receipt's counts were not taken")
check(#upstream_sync(sync.kind.paste) == 2, "a Receipt opened the paste's window")
-- The fixture's PasteReceipt names paste 2; this paste is 3, so it is not its.
host_says(sync.kind.paste_receipt)
check(#upstream_sync(sync.kind.paste) == 2, "a receipt for another paste opened this one's window")
sync.feed(scripted, sync.sync_frame(sync.kind.paste_receipt, scripted.pane, string.char(3, 0, 0, 0, 0, 0, 0, 0) .. string.char(0, 0x20, 0, 0, 0, 0, 0, 0)))
do
    local pieces = upstream_sync(sync.kind.paste)
    check(#pieces == 3 and u64(pieces[3], 8) == 16384 and pieces[3]:byte(17) == 1, "the receipt did not release the paste's final piece")
    local total = 0
    for _, piece in ipairs(pieces) do
        local length, at = varint(piece, 17)
        total = total + length
        check(piece:sub(at + 1) == string.rep("p", length), "a paste piece carries bytes that are not the paste's")
    end
    check(total == 20000, string.format("the pieces carry %d bytes of a 20000-byte paste", total))
end

-- A signal character discarded what the pane held: the events are counted,
-- and no more of a paste among them is sent.
sync.paste_on(scripted, string.rep("q", 30000))
sync.feed_typed(scripted, "y")
check(#upstream_sync(sync.kind.paste) == 5 and scripted.input_seq == 6, "the second paste did not fill its window")
sync.feed(scripted, sync.sync_frame(sync.kind.input_discarded, scripted.pane, string.char(4, 0, 0, 0, 0, 0, 0, 0) .. string.char(6, 0, 0, 0, 0, 0, 0, 0)))
check(scripted.input_discarded == 2, string.format("%d events were counted as discarded, expected 2", scripted.input_discarded))
check(#scripted.pastes == 0 and scripted.input_written == 6, "a discarded paste is still held, or the count did not pass it")
sync.feed(scripted, sync.sync_frame(sync.kind.paste_receipt, scripted.pane, string.char(5, 0, 0, 0, 0, 0, 0, 0) .. string.char(0, 0x40, 0, 0, 0, 0, 0, 0)))
check(#upstream_sync(sync.kind.paste) == 5, "a piece of a discarded paste was sent")
-- The fixture's InputDiscarded, from the host's encoder, names a run already
-- behind this client's count; it decodes and moves nothing back.
host_says(sync.kind.input_discarded)
check(scripted.input_written == 6, "an InputDiscarded behind the count moved it")
-- One that names no run is malformed.
do
    local notices = 0
    local refused = fixture.connection(buffer)
    refused.pane = scripted.pane
    vim.notify = function() notices = notices + 1 end
    sync.feed(refused, sync.sync_frame(sync.kind.input_discarded, refused.pane, string.rep("\0", 16)))
    vim.notify = notify
    check(notices == 1 and refused.protocol_failure and refused.input_closed, "an InputDiscarded naming no run was taken")
end

-- An interrupt typed during an unfinished paste gives the paste up first, on
-- the interactive lane, and then goes itself.
sync.paste_on(scripted, string.rep("r", 20000))
sync.feed_typed(scripted, "\3")
do
    local aborts = upstream_sync(sync.kind.paste_abort)
    check(#aborts == 1 and u64(aborts[1], 0) == 7, "the interrupt did not abort the unfinished paste by its number")
    local frames = sync_frames(table.concat(upstream))
    local last, before = frames[#frames], frames[#frames - 1]
    check(last.kind == sync.kind.raw and u64(last.body, 0) == 8 and last.body:sub(9) == "\1\3" and before.kind == sync.kind.paste_abort,
        "the abort did not go ahead of the interrupt")
    check(#scripted.pastes == 0, "an aborted paste is still held")
    sync.feed(scripted, sync.sync_frame(sync.kind.paste_receipt, scripted.pane, string.char(7, 0, 0, 0, 0, 0, 0, 0) .. string.char(0, 0x40, 0, 0, 0, 0, 0, 0)))
    check(#upstream_sync(sync.kind.paste) == 7, "a piece of an aborted paste was sent")
end
-- The pane's own interrupt character, once its echo context states one, is
-- what aborts; a new terminal's Ctrl-C then is a key like any other.
scripted.echo = { interrupt = 0x07, quit = nil, suspend = nil }
sync.paste_on(scripted, string.rep("s", 20000))
sync.feed_typed(scripted, "\3")
check(#upstream_sync(sync.kind.paste_abort) == 1, "a key that is not the pane's interrupt character aborted a paste")
-- Bytes that only begin with it are not that key.
sync.feed_typed(scripted, "\7x")
check(#upstream_sync(sync.kind.paste_abort) == 1, "bytes beginning with the interrupt character aborted a paste")
sync.feed_typed(scripted, "\7")
check(#upstream_sync(sync.kind.paste_abort) == 2, "the pane's own interrupt character did not abort the paste")
-- With no paste unfinished an interrupt is only a key.
sync.feed_typed(scripted, "\7")
check(#upstream_sync(sync.kind.paste_abort) == 2, "an interrupt with no paste unfinished sent an abort")
-- A paste past what the host takes is refused whole, not cut.
do
    local refused
    vim.notify = function(text) refused = text end
    scripted.paste_limits.paste_bytes = 1000
    local taken = sync.paste_on(scripted, string.rep("t", 1001))
    vim.notify = notify
    check(taken == false and refused ~= nil and #upstream_sync(sync.kind.paste) == 9, "a paste past the host's cap was sent")
    scripted.paste_limits.paste_bytes = 16 * 1024 * 1024
end

-- Losing the focus says so twice: the window's in a Facts, the pane's in a
-- Focus. A new size says so twice as well: the window's in a Facts, the
-- pane's in a Viewport.
sync.focus_connection(scripted, false)
scripted.columns, scripted.rows = 100, 30
sync.send_facts(scripted)
sync.send_viewport(scripted)
do
    local viewports = upstream_sync(sync.kind.viewport)
    check(#viewports == 2 and #viewports[1] == 16 and viewports[1]:byte(1) == 24 and viewports[1]:byte(3) == 80
        and viewports[2]:byte(1) == 30 and viewports[2]:byte(3) == 100 and viewports[2]:sub(5) == string.rep("\0", 12),
        "the pane's Viewport was not sent at its bind and again at the new size")
end
do
    local facts = upstream_sync(sync.kind.facts)
    check(#facts == 2 and facts[1]:byte(19) == 0 and facts[1]:byte(20) == 0, "the Facts after losing the focus does not say unfocused with no palette")
    check(#facts == 2 and facts[2]:byte(1) == 30 and facts[2]:byte(3) == 100, "the Facts after a resize does not carry the new viewport")
    local focus = upstream_sync(sync.kind.focus)
    check(#focus == 1 and focus[1] == "\0", "the pane was not told it lost the focus")
    sync.focus_connection(scripted, false)
    check(#upstream_sync(sync.kind.focus) == 1, "an unchanged focus was sent again")
end

-- The control channel: a notification is kept and a result is kept.
host_says(sync.kind.notify)
check(#scripted.notifies == 1 and scripted.notifies[1].kind == wire.notify_kind.attachments, "the host's notification was not kept")
host_says(sync.kind.result)
check(scripted.last_result ~= nil and scripted.last_result.transfer == 0 and scripted.last_result.text:find('"id":7', 1, true) ~= nil, "the host's result was not read")
do
    -- A Call is a client's to send: one from the host is refused by name and
    -- answered with nothing, since the host closes on a client's Result.
    local refusal
    local refused = fixture.connection(buffer)
    vim.notify = function(text) refusal = text end
    sync.feed(refused, sync.sync_frame(sync.kind.call, 0, '{"jsonrpc":"2.0","id":7,"method":"host.describe"}'))
    vim.notify = notify
    check(refusal ~= nil and refused.protocol_failure and refusal:find("only a client sends", 1, true) ~= nil and #upstream_sync(sync.kind.result) == 0,
        "a Call from the host was not refused, or was answered")
end
-- A Bye ends its own carrier; later transcript input uses the live one.
for _, name in ipairs({ "Superseded", "HandingOver" }) do
    local closing = sync.new_connection(buffer)
    local reason
    for value, word in pairs(wire.bye_reasons) do if word == name then reason = value end end
    sync.feed(closing, sync.sync_frame(sync.kind.bye, 0, string.char(reason, 0, 0)))
    check(closing.bye_reason == name and closing.transport_closed, "the typed Bye did not close its own carrier")
end

-- Typed bytes past one piece go as several events, each numbered.
do
    local before = #upstream_sync(sync.kind.raw)
    sync.feed_typed(scripted, string.rep("z", 5000))
    local raws = upstream_sync(sync.kind.raw)
    check(#raws == before + 2 and #raws[#raws - 1] == 8 + 2 + 4096 and u64(raws[#raws], 0) == scripted.input_seq,
        "5000 typed bytes did not go as two numbered pieces")
end

-- An update's header carries the host's counts of this client's input.
do
    local body = carried.body
    local _, after_lag = varint(body, 26)
    local counted = body:sub(1, after_lag) .. string.char(scripted.input_seq, 0, 0, 0, 0, 0, 0, 0) .. string.char(5, 0, 0, 0, 0, 0, 0, 0) .. body:sub(after_lag + 17)
    sync.feed(scripted, sync.sync_frame(sync.kind.update, carried.channel, counted))
    check(scripted.input_written == scripted.input_seq and scripted.input_settled == 5,
        string.format("an update's input counts read %s written and %s settled", tostring(scripted.input_written), tostring(scripted.input_settled)))
end

-- PaneFacts is decoded, not ignored; a truncated record is reported without
-- publishing even its title prefix.
do
    local reports = {}
    local title, facts = scripted.title, scripted.pane_facts
    local refused = fixture.connection(buffer)
    refused.pane, refused.title, refused.pane_facts = scripted.pane, title, facts
    vim.notify = function(text) reports[#reports + 1] = text end
    sync.feed(refused, sync.sync_frame(sync.kind.pane_facts, refused.pane, string.rep("\0", 40)))
    vim.notify = notify
    check(#reports == 1 and reports[1]:find("a Sync body ends at 40", 1, true) ~= nil,
        "a truncated PaneFacts was not reported exactly once as a bounds error")
    check(refused.title == title and refused.pane_facts == facts and refused.protocol_failure,
        "a truncated PaneFacts changed the published title or record")
end

-- A kind only a client sends, arriving from the host, is refused and named;
-- so is a kind byte no version defines. A kind this client asked nothing of
-- is stepped over.
do
    local reports = {}
    vim.notify = function(text) reports[#reports + 1] = text end
    local bad_direction, unknown = sync.new_connection(buffer), sync.new_connection(buffer)
    sync.feed(bad_direction, sync.sync_frame(sync.kind.raw, scripted.pane, string.rep("\0", 9)))
    sync.feed(unknown, sync.sync_frame(200, 0, ""))
    sync.feed(scripted, sync.sync_frame(sync.kind.pane_dirty, scripted.pane, ""))
    sync.feed(scripted, sync.sync_frame(sync.kind.history_reset, scripted.pane, string.rep("\0", 20)))
    sync.feed(scripted, sync.sync_frame(sync.kind.status_records, scripted.pane, string.rep("\0", 10)))
    vim.notify = notify
    check(bad_direction.protocol_failure and unknown.protocol_failure and #reports == 2
        and reports[1]:find("only a client sends", 1, true) ~= nil and reports[2]:find("kind 200", 1, true) ~= nil,
        string.format("a client-only kind and an unknown kind were reported %d times", #reports))
end

-- A host's attach of a pane holding two pictures, its ImagePlacements body the
-- host's own: a decoder walking another record layout refuses the frame or
-- reads wrong fields, and this fails.
do
    local picture_buffer = vim.api.nvim_create_buf(false, true)
    local picture = sync.new_connection(picture_buffer)
    picture.admission_request = fixture.request()
    picture.terminal = vim.api.nvim_open_term(picture_buffer, {})
    picture.stdin = { is_closing = function() return false end, write = function() end }
    for at = 1, #pictures, 97 do
        sync.feed(picture, pictures:sub(at, at + 96))
    end
    check(not picture.protocol_failure, "the picture pane's attach was refused: " .. tostring(picture.protocol_failure))
    check(picture.image_revision and picture.image_revision > 0, "the picture pane's ImagePlacements was not taken")
    local bodies = {}
    for _, frame in ipairs(sync_frames(pictures)) do
        if frame.kind == sync.kind.image_placements then
            bodies[#bodies + 1] = frame.body
        end
    end
    check(#bodies >= 1, "the picture pane's attach carried no ImagePlacements")
    if #bodies >= 1 then
        local state = sync.read_image_placements(bodies[#bodies])
        local iterm, kitty
        for _, placement in ipairs(state.placements) do
            if placement.drawn_width > 0 then iterm = placement else kitty = placement end
        end
        check(#state.placements == 2, string.format("the picture pane decoded %d placements, not 2", #state.placements))
        -- OSC 1337 width=24px;height=24px at row 0, column 11: drawn at 24x24
        -- device pixels, covering 3x2 of the host's fallback 8x16 cells.
        check(iterm and iterm.column == 11 and iterm.row == 0 and iterm.columns == 3 and iterm.rows == 2
            and iterm.drawn_width == 24 and iterm.drawn_height == 24, "the OSC 1337 placement decoded wrong")
        -- kitty natural size at row 3, column 16: no cell box, no drawn size.
        check(kitty and kitty.column == 16 and kitty.row == 3 and kitty.columns == 0 and kitty.rows == 0
            and kitty.drawn_width == 0 and kitty.drawn_height == 0, "the kitty placement decoded wrong")
    end
end

do
    local checkpoint = sync.held_checkpoint(connection)
    local at, length, shift = 18, 0, 0
    while true do
        local byte = checkpoint:byte(at)
        at = at + 1
        length = length + (byte % 128) * 2 ^ shift
        if byte < 128 then break end
        shift = shift + 7
    end
    local last = at + length - 4
    local blanked = checkpoint:sub(1, last - 1) .. "\1" .. checkpoint:sub(last + 1)
    local probe = sync.new_connection(buffer)
    sync.apply_checkpoint(probe, checkpoint)
    local visible = sync.apply_checkpoint(probe, checkpoint)
    local text = sync.row_text(probe, 0)
    local cover = sync.apply_checkpoint(probe, blanked)
    check(cover:find("\27[40m\27[2J", 1, true) ~= nil, "CRT saving paints a black screen")
    check(not cover:find("\27[?25h", 1, true), "CRT saving hides the cursor")
    check(sync.row_text(probe, 0) == text, "CRT saving retains the held cells")
    check(sync.apply_checkpoint(probe, checkpoint) == visible, "waking repaints the held screen")
end

if upstream_path then
    local handle = io.open(upstream_path, "wb")
    handle:write(table.concat(upstream))
    handle:close()
end

if failures == 0 then
    say("neovim_sync_decode: all passed")
    os.exit(0)
end
os.exit(1)
