-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- The Neovim client against a live daemon.
--
-- Attaches through the host's attach bridge, waits for the first checkpoint, and
-- prints whether one was decoded. Then what the client sends, against the
-- host that reads it: typed bytes as Raw, a paste as Paste pieces, and a new
-- size in a Facts, each seen come back on the screen, with the host's count
-- of input written catching up with the count sent. The session is created
-- to end with this attach, and the EXIT frame at the end is what ends it:
-- nothing is left running that was not running before.
--
--     nvim --headless -l Tests/Platform/neovim_live_check.lua <ubiquitty-host> [seconds]

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(script, ":p:h")
local lua_root = here .. "/../../Source/Platform/Neovim/lua"
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path

local function say(line)
    io.stdout:write(line, "\n")
end

local host = arg[1]
if not host or host == "" then
    say("usage: nvim --headless -l neovim_live_check.lua <ubiquitty-host> [seconds]")
    os.exit(2)
end
local seconds = tonumber(arg[2]) or 2

local sync = require("ubiquitty_sync")
-- The client instance and resume record go to a scratch directory.
sync.setup({ host_program = host, end_when_detached = true, state_directory = vim.fn.tempname() })

local ok, buffer = pcall(sync.start)
if not ok then
    say("neovim_live_check: " .. tostring(buffer))
    os.exit(1)
end

vim.wait(seconds * 1000, function()
    local status = sync.status(buffer)
    return status == nil or status.checkpoints > 0 or status.refusal ~= nil
end, 50)

local decoded = ((sync.status(buffer) or {}).checkpoints or 0) > 0

-- With a screen in hand, type a command whose output names a marker the typed
-- line itself does not contain, and wait for the marker to reach the buffer:
-- Sync input up and the screen plane's updates down, against the real daemon.
local marker = "UBIQUITTY-NEOVIM-LIVE"
local echoed = false
if decoded then
    sync.send_input(buffer, "echo UBIQUITTY-NEO''VIM-LIVE\r")
    echoed = vim.wait(seconds * 1000, function()
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
            if line:find(marker, 1, true) then
                return true
            end
        end
        return false
    end, 50)
end

local function on_screen(text)
    return vim.wait(seconds * 1000, function()
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
            if line:find(text, 1, true) then
                return true
            end
        end
        return false
    end, 50)
end

-- A paste: the host brackets it if the shell asked, and the line runs on the
-- Enter typed after it.
local pasted = false
if echoed then
    sync.paste(buffer, "echo UBIQUITTY-NEO''VIM-PASTE")
    sync.send_input(buffer, "\r")
    pasted = on_screen("UBIQUITTY-NEOVIM-PASTE")
end

-- A new size, in a Facts: the shell's terminal is the window's width.
local resized = false
if echoed then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 53)
    vim.api.nvim_win_set_buf(0, buffer)
    vim.wo.number = false
    vim.wo.signcolumn = "no"
    sync.resize(buffer)
    sync.send_input(buffer, "echo COLS-$(stty size | cut -d' ' -f2)-END\r")
    resized = on_screen("COLS-53-END")
end

-- The host's count of this client's input written reaches the count sent,
-- and the pane's echo context arrived.
local counted = vim.wait(seconds * 1000, function()
    local now = sync.status(buffer)
    return now ~= nil and now.input_sent > 0 and now.input_written == now.input_sent
end, 50)
-- A resize checkpoint can clear the previous context before its following
-- update supplies the current one. Wait for that update as for the screen.
local described = vim.wait(seconds * 1000, function()
    return (sync.status(buffer) or {}).echo ~= nil
end, 50)

local status = sync.status(buffer) or {}
say(string.format("neovim_live_check: input sent %s, written %s, discarded %s",
    tostring(status.input_sent), tostring(status.input_written), tostring(status.input_discarded)))
say(string.format("neovim_live_check: session %s, checkpoints applied %d, updates applied %d%s",
    tostring(status.session_id), status.checkpoints or 0, status.updates or 0,
    status.refusal and (", refused: AUTH_DENIED " .. status.refusal) or ""))

-- EXIT, then wait for the bridge to leave so the daemon has read it.
sync.detach(buffer)
vim.wait(3000, function()
    return sync.status(buffer) == nil
end, 50)

say(decoded and "neovim_live_check: checkpoint applied" or "neovim_live_check: no checkpoint applied")
say(echoed and "neovim_live_check: typed input came back on screen" or "neovim_live_check: typed input did not come back")
say(pasted and "neovim_live_check: a paste came back on screen" or "neovim_live_check: a paste did not come back")
say(resized and "neovim_live_check: the new size reached the shell" or "neovim_live_check: the new size did not reach the shell")
say(counted and "neovim_live_check: the host counted every event written" or "neovim_live_check: the host's count did not reach the events sent")
say(described and "neovim_live_check: the echo context arrived" or "neovim_live_check: no echo context arrived")
os.exit((decoded and echoed and pasted and resized and counted and described) and 0 or 1)
