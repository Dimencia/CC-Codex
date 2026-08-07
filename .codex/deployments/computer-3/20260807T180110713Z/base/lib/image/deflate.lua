local Deflate = {}

---@param message string
local function fail(message)
  error(message, 0)
end

---@param source string
---@param checkpoint? fun(work: integer)
---@return string
function Deflate.inflate(source, checkpoint)
  if #source < 6 then fail("short PNG zlib stream") end
  local position, bitPosition = 3, 0

  ---@param count integer
  ---@return integer
  local function bits(count)
    if checkpoint then checkpoint(count) end
    local value = 0
    for index = 0, count - 1 do
      local sourceByte = string.byte(source, position) or 0
      local bit = math.floor(sourceByte / 2 ^ bitPosition) % 2
      value = value + bit * 2 ^ index
      bitPosition = bitPosition + 1
      if bitPosition == 8 then
        bitPosition = 0
        position = position + 1
      end
    end
    return value
  end

  local function align()
    if bitPosition ~= 0 then
      bitPosition = 0
      position = position + 1
    end
  end

  ---@param value integer
  ---@param count integer
  ---@return integer
  local function reverseBits(value, count)
    local reversed = 0
    for _ = 1, count do
      reversed = reversed * 2 + (value % 2)
      value = math.floor(value / 2)
    end
    return reversed
  end

  ---@param lengths integer[]
  ---@return table<integer, table<integer, integer>>
  local function huffman(lengths)
    local counts = {}
    for index = 1, 15 do counts[index] = 0 end
    for _, length in ipairs(lengths) do
      if length > 0 then counts[length] = counts[length] + 1 end
    end
    local nextCode = {}
    local code = 0
    for length = 1, 15 do
      code = (code + (counts[length - 1] or 0)) * 2
      nextCode[length] = code
    end
    local result = {}
    for symbolIndex, length in ipairs(lengths) do
      if length > 0 then
        result[length] = result[length] or {}
        result[length][reverseBits(nextCode[length], length)] = symbolIndex - 1
        nextCode[length] = nextCode[length] + 1
      end
    end
    return result
  end

  ---@param tree table<integer, table<integer, integer>>
  ---@return integer
  local function symbol(tree)
    local value = 0
    for length = 1, 15 do
      value = value + bits(1) * 2 ^ (length - 1)
      if tree[length] and tree[length][value] ~= nil then return tree[length][value] end
    end
    fail("invalid deflate huffman code")
    return 0
  end

  local fixedLiteral, fixedDistance
  do
    local literals, distances = {}, {}
    for index = 0, 287 do
      literals[index + 1] = index <= 143 and 8 or index <= 255 and 9 or index <= 279 and 7 or 8
    end
    for index = 0, 31 do distances[index + 1] = 5 end
    fixedLiteral, fixedDistance = huffman(literals), huffman(distances)
  end

  local lengthBase = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
  local lengthExtra = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
  local distanceBase = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
  local distanceExtra = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
  local output = {}
  local last = false
  while not last do
    last = bits(1) == 1
    local blockType = bits(2)
    if blockType == 0 then
      align()
      local length = bits(8) + bits(8) * 256
      local inverseLength = bits(8) + bits(8) * 256
      if (length + inverseLength) % 65536 ~= 65535 then fail("bad stored deflate block") end
      for _ = 1, length do output[#output + 1] = bits(8) end
    elseif blockType == 1 or blockType == 2 then
      local literalTree, distanceTree
      if blockType == 1 then
        literalTree, distanceTree = fixedLiteral, fixedDistance
      else
        local literalCount, distanceCount, codeLengthCount = bits(5) + 257, bits(5) + 1, bits(4) + 4
        local order = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
        local codeLengths = {}
        for index = 1, 19 do codeLengths[index] = 0 end
        for index = 1, codeLengthCount do codeLengths[order[index] + 1] = bits(3) end
        local codeLengthTree = huffman(codeLengths)
        local allLengths = {}
        while #allLengths < literalCount + distanceCount do
          local value = symbol(codeLengthTree)
          if value <= 15 then
            allLengths[#allLengths + 1] = value
          elseif value == 16 then
            if #allLengths == 0 then fail("bad deflate repeat") end
            local previous = allLengths[#allLengths]
            for _ = 1, bits(2) + 3 do allLengths[#allLengths + 1] = previous end
          elseif value == 17 then
            for _ = 1, bits(3) + 3 do allLengths[#allLengths + 1] = 0 end
          elseif value == 18 then
            for _ = 1, bits(7) + 11 do allLengths[#allLengths + 1] = 0 end
          else
            fail("bad deflate length code")
          end
        end
        local literalLengths, distanceLengths = {}, {}
        for index = 1, literalCount do literalLengths[index] = allLengths[index] or 0 end
        for index = 1, distanceCount do distanceLengths[index] = allLengths[literalCount + index] or 0 end
        literalTree, distanceTree = huffman(literalLengths), huffman(distanceLengths)
      end

      while true do
        local value = symbol(literalTree)
        if value < 256 then
          output[#output + 1] = value
        elseif value == 256 then
          break
        elseif value <= 285 then
          local lengthIndex = value - 256
          local runLength = lengthBase[lengthIndex] + bits(lengthExtra[lengthIndex])
          local distanceSymbol = symbol(distanceTree)
          if distanceSymbol < 0 or distanceSymbol > 29 then fail("bad deflate distance") end
          local distance = distanceBase[distanceSymbol + 1] + bits(distanceExtra[distanceSymbol + 1])
          if distance > #output then fail("deflate distance beyond output") end
          for _ = 1, runLength do
            output[#output + 1] = output[#output - distance + 1]
            if checkpoint then checkpoint(1) end
          end
        else
          fail("bad deflate literal/length")
        end
      end
    else
      fail("reserved deflate block")
    end
  end

  local parts, chunk = {}, {}
  for _, value in ipairs(output) do
    chunk[#chunk + 1] = string.char(value)
    if #chunk == 4096 then
      parts[#parts + 1] = table.concat(chunk)
      chunk = {}
    end
    if checkpoint then checkpoint(1) end
  end
  if #chunk > 0 then parts[#parts + 1] = table.concat(chunk) end
  return table.concat(parts)
end

return Deflate
