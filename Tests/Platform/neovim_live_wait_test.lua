-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

local check_script = arg[1]
local original_vim, original_arg, original_exit, original_sync = vim, arg, os.exit, package.loaded.ubiquitty_sync
local function exercise(delivers_context)
    local elapsed, attached, outcome = 0, true, nil
    local fake = {
        setup = function() end,
        start = function() return 1 end,
        send_input = function() end,
        paste = function() end,
        resize = function() end,
        detach = function() attached = false end,
        status = function()
            if not attached then return nil end
            return {checkpoints=1, updates=1, input_sent=4, input_written=4,
                echo = delivers_context and elapsed >= 700 and {} or nil}
        end,
    }
    vim = {
        fn={fnamemodify=function() return '.' end, tempname=function() return '/tmp/unused-neovim-fixture' end},
        api={nvim_buf_get_lines=function() return {'UBIQUITTY-NEOVIM-LIVE UBIQUITTY-NEOVIM-PASTE COLS-53-END'} end,
            nvim_win_set_width=function() end,nvim_win_set_buf=function() end},
        wo={},cmd=function() end,
        wait=function(limit, predicate, step)
            for i=0,limit,step do
                if predicate() then return true end
                elapsed=elapsed+step
            end
            return false
        end,
    }
    arg={'fixture-host','1'}
    package.loaded.ubiquitty_sync=fake
    os.exit=function(code) outcome=code end
    assert(loadfile(check_script))()
    return outcome
end
assert(exercise(true)==0, 'delayed echo context was rejected')
assert(exercise(false)==1, 'missing echo context was accepted')
vim, arg, os.exit, package.loaded.ubiquitty_sync = original_vim, original_arg, original_exit, original_sync
print('Neovim live fixture: delayed context passes; missing context fails')
