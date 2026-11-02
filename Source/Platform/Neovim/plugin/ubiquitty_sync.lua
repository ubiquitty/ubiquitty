-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- Registers :UbiquittySync. The module loads on first use, so a runtimepath
-- entry costs nothing until the command runs.

if vim.g.loaded_ubiquitty_sync then
    return
end
vim.g.loaded_ubiquitty_sync = true

vim.api.nvim_create_user_command("UbiquittySync", function(invocation)
    require("ubiquitty_sync").command(invocation.args)
end, {
    nargs = "?",
    complete = function()
        return { "detach" }
    end,
    desc = "Attach a Ubiquitty terminal session in a terminal buffer (detach: end this buffer's attach)",
})
