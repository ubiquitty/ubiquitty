-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- Incremental SHA-256 for binary transfers. Only the unfinished 64-byte block
-- and fixed working words survive update(); a text-only reader retains no pixels.
local M = {}
local band, bxor, bnot, rshift, ror = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.ror
local constants = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function block(state, bytes, offset)
    local words = state.words
    for index = 1, 16 do
        local a, b, c, d = bytes:byte(offset + (index - 1) * 4, offset + index * 4 - 1)
        words[index] = bit.tobit(a * 16777216 + b * 65536 + c * 256 + d)
    end
    for index = 17, 64 do
        local a, b = words[index - 15], words[index - 2]
        words[index] = bit.tobit(words[index - 16] + bxor(ror(a, 7), ror(a, 18), rshift(a, 3))
            + words[index - 7] + bxor(ror(b, 17), ror(b, 19), rshift(b, 10)))
    end
    local h = state.hash
    local a, b, c, d, e, f, g, last = unpack(h)
    for index = 1, 64 do
        local first = last + bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            + bxor(band(e, f), band(bnot(e), g)) + constants[index] + words[index]
        local second = bxor(ror(a, 2), ror(a, 13), ror(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))
        last, g, f, e, d, c, b, a = g, f, e, bit.tobit(d + first), c, b, a, bit.tobit(first + second)
    end
    local values = { a, b, c, d, e, f, g, last }
    for index = 1, 8 do h[index] = bit.tobit(h[index] + values[index]) end
end

-- A fresh owner, with no retained caller bytes or process-global mutable state.
function M.new()
    return { hash = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
        words = {}, tail = "", bytes = 0 }
end

-- Consume arbitrary binary bytes. The length ceiling keeps the bit count exact
-- in Lua numbers; image transfers have a much smaller independently checked cap.
function M.update(state, bytes)
    if state.finished or state.bytes + #bytes > 4294967295 then error("invalid SHA-256 stream", 0) end
    state.bytes = state.bytes + #bytes
    local offset = 1
    if #state.tail > 0 then
        local needed = math.min(64 - #state.tail, #bytes)
        state.tail = state.tail .. bytes:sub(1, needed)
        offset = needed + 1
        if #state.tail == 64 then block(state, state.tail, 1); state.tail = "" end
    end
    while offset + 63 <= #bytes do block(state, bytes, offset); offset = offset + 64 end
    if offset <= #bytes then state.tail = bytes:sub(offset) end
end

local function big_endian(value)
    return string.char(band(rshift(value, 24), 255), band(rshift(value, 16), 255), band(rshift(value, 8), 255), band(value, 255))
end

-- Complete once and return the raw 32-byte digest, including embedded zeros.
function M.finish(state)
    if state.finished then error("SHA-256 stream already finished", 0) end
    local bits = state.bytes * 8
    local tail = state.tail .. "\128" .. string.rep("\0", (55 - state.bytes) % 64)
        .. big_endian(math.floor(bits / 4294967296)) .. big_endian(bits % 4294967296)
    for offset = 1, #tail, 64 do block(state, tail, offset) end
    state.finished, state.tail = true, ""
    local result = {}
    for index = 1, 8 do result[index] = big_endian(state.hash[index]) end
    return table.concat(result)
end

return M
