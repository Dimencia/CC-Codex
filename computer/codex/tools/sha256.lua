local Sha256 = {}

local UINT32 = 4294967296

local function add32(a, b, c, d, e)
    return (a + (b or 0) + (c or 0) + (d or 0) + (e or 0)) % UINT32
end

local function packWord(bit, value)
    return string.char(
        bit.rshift(value, 24),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(value, 0xff)
    )
end

local function wordAt(bit, data, index)
    return add32(
        bit.lshift(string.byte(data, index), 24),
        bit.lshift(string.byte(data, index + 1), 16),
        bit.lshift(string.byte(data, index + 2), 8),
        string.byte(data, index + 3)
    )
end

---@param data string
---@param bit table
---@return string|nil digest
---@return string|nil error
function Sha256.hash(data, bit)
    if type(data) ~= "string" then return nil, "SHA-256 input must be a string." end
    if type(bit) ~= "table" then return nil, "SHA-256 requires the ComputerCraft bit32 API." end

    local length = #data
    local bitLength = length * 8
    local highLength = math.floor(bitLength / UINT32)
    local lowLength = bitLength % UINT32
    local paddingLength = (55 - (length % 64)) % 64
    data = data .. string.char(0x80) .. string.rep("\0", paddingLength)
        .. packWord(bit, highLength) .. packWord(bit, lowLength)

    local constants = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local function choose(x, y, z)
        return bit.bxor(bit.band(x, y), bit.band(bit.bnot(x), z))
    end

    local function majority(x, y, z)
        return bit.bxor(bit.band(x, y), bit.band(x, z), bit.band(y, z))
    end

    local function bigSigma0(value)
        return bit.bxor(bit.rrotate(value, 2), bit.rrotate(value, 13), bit.rrotate(value, 22))
    end

    local function bigSigma1(value)
        return bit.bxor(bit.rrotate(value, 6), bit.rrotate(value, 11), bit.rrotate(value, 25))
    end

    local function smallSigma0(value)
        return bit.bxor(bit.rrotate(value, 7), bit.rrotate(value, 18), bit.rshift(value, 3))
    end

    local function smallSigma1(value)
        return bit.bxor(bit.rrotate(value, 17), bit.rrotate(value, 19), bit.rshift(value, 10))
    end

    for offset = 1, #data, 64 do
        local words = {}
        for index = 1, 16 do
            words[index] = wordAt(bit, data, offset + ((index - 1) * 4))
        end
        for index = 17, 64 do
            words[index] = add32(
                words[index - 16],
                smallSigma1(words[index - 2]),
                words[index - 7],
                smallSigma0(words[index - 15])
            )
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 1, 64 do
            local first = add32(h, bigSigma1(e), choose(e, f, g), constants[index], words[index])
            local second = add32(bigSigma0(a), majority(a, b, c))
            h, g, f, e = g, f, e, add32(d, first)
            d, c, b, a = c, b, a, add32(first, second)
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
        h5 = add32(h5, f)
        h6 = add32(h6, g)
        h7 = add32(h7, h)
    end

    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7
    )
end

return Sha256
