-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- The Neovim client across a restart.
--
-- Two Neovim processes against one live daemon, as a person restarting Neovim
-- sees them. The first attaches, puts a marker on the screen, starts a line
-- that prints while no client is attached, and exits, which stores the record
-- and lets the bridge go without a Bye. The second draws the stored screen
-- before the bridge has delivered a byte, greets as the same client instance,
-- is continued by the host with a diff rather than a checkpoint, and shows
-- what was printed meanwhile. It then ends the session.
--
--     nvim --headless -l Tests/Platform/neovim_resume_check.lua \
--         <ubiquitty-host> <state-directory> <first|second> [seconds]
--
-- Run with UBIQUITTY_HOME set to a scratch directory, so the daemon is the
-- check's own.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(script, ":p:h")
local lua_root = here .. "/../../Source/Platform/Neovim/lua"
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path

local host, state, phase = arg[1], arg[2], arg[3]
local seconds = tonumber(arg[4]) or 10
local function say(line)
    io.stdout:write(line, "\n")
end
if not host or not state or (phase ~= "first" and phase ~= "second") then
    say("usage: nvim --headless -l neovim_resume_check.lua <ubiquitty-host> <state-directory> <first|second> [seconds]")
    os.exit(2)
end

local failures = 0
local function check(ok, what)
    say(string.format("neovim_resume_check %s: %s%s", phase, ok and "" or "FAILED: ", what))
    if not ok then failures = failures + 1 end
end

local sync = require("ubiquitty_sync")
sync.setup({ host_program = host, state_directory = state })

local stored_instance
if phase == "second" then
    local handle = io.open(state .. "/client-instance", "rb")
    stored_instance = handle and vim.trim(handle:read("*a")) or nil
    if handle then handle:close() end
end

local ok, buffer = pcall(sync.start)
if not ok then
    say("neovim_resume_check: " .. tostring(buffer))
    os.exit(1)
end

local function screen_has(text)
    local screen = sync.screen_text(buffer)
    return screen ~= nil and screen:find(text, 1, true) ~= nil
end
local function wait(predicate)
    return vim.wait(seconds * 1000, predicate, 50)
end

if phase == "first" then
    check(wait(function() return ((sync.status(buffer) or {}).checkpoints or 0) > 0 end), "a checkpoint was applied")
    sync.send_input(buffer, "echo BEFORE-THE-REST''ART; (sleep 2; echo WHILE-NEOVIM-WAS-GO''NE) &\r")
    check(wait(function() return screen_has("BEFORE-THE-RESTART") end), "the marker came back on screen")
    check(wait(function()
        local now = sync.status(buffer)
        return now ~= nil and now.input_sent > 0 and now.input_written == now.input_sent
    end), "the host wrote every event")
    -- Neovim exits: its VimLeavePre stores the record, and the bridge's pipe
    -- closes without a Bye, which leaves the attachment to resume.
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    check(vim.uv.fs_stat(state .. "/resume.record") ~= nil, "the record was stored")
    io.stdout:flush()
    os.exit(failures == 0 and 0 or 1)
end

-- The second Neovim: nothing has been read from the bridge yet.
local before = sync.status(buffer) or {}
check(before.stream_received == 0 and before.checkpoints == 1, "the stored screen was drawn before the bridge delivered a byte")
check(screen_has("BEFORE-THE-RESTART"), "the stored screen is the one Neovim left")
local stored_checkpoints = before.checkpoints
check(wait(function() return (sync.status(buffer) or {}).resumed ~= nil end), "the host answered")
local resumed = (sync.status(buffer) or {}).resumed or {}
check(resumed[1] ~= nil and resumed[1].outcome == 0, "the host continued the pane with a diff")
local instance = (sync.status(buffer) or {}).client_instance or ""
check(stored_instance == (instance:gsub(".", function(c) return string.format("%02x", c:byte()) end)),
    "the Greet named the stored client instance")
check(wait(function() return screen_has("WHILE-NEOVIM-WAS-GONE") end), "what was printed meanwhile came in the diff")
check(screen_has("BEFORE-THE-RESTART"), "the stored screen is kept")
check(((sync.status(buffer) or {}).checkpoints or 0) == stored_checkpoints, "no checkpoint followed the resume")
sync.send_input(buffer, "exit\r")
check(wait(function()
    local now = sync.status(buffer)
    return now == nil or now.pane_ended
end), "the shell's exit ended the pane")
check(wait(function() return sync.status(buffer) == nil end), "the bridge left")
check(vim.uv.fs_stat(state .. "/resume.record") == nil, "the ended session took its record with it")
io.stdout:flush()
os.exit(failures == 0 and 0 or 1)
