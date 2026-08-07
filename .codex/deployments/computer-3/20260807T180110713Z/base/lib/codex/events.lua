---@alias EventOrigin 'cc'|'codex'

---@class PackedValues
---@field n integer

---@class EventEnvelope
---@field sequence integer
---@field origin EventOrigin
---@field name string
---@field args PackedValues

local Events = {}

---@param ... unknown
---@return PackedValues
function Events.pack(...)
    return { n = select("#", ...), ... }
end

---@param values PackedValues
---@return PackedValues
function Events.copyPacked(values)
    local copy = { n = values.n }
    for index = 1, values.n do
        copy[index] = values[index]
    end
    return copy
end

---@param sequence integer
---@param origin EventOrigin
---@param name string
---@param args PackedValues|nil
---@return EventEnvelope
function Events.new(sequence, origin, name, args)
    if type(sequence) ~= "number" or sequence < 1 or sequence % 1 ~= 0 then
        error("event sequence must be a positive integer", 2)
    end
    if origin ~= "cc" and origin ~= "codex" then
        error("event origin must be 'cc' or 'codex'", 2)
    end
    if type(name) ~= "string" or name == "" then
        error("event name must be a non-empty string", 2)
    end

    args = args or Events.pack()
    if type(args.n) ~= "number" or args.n < 0 or args.n % 1 ~= 0 then
        error("event args must be packed values", 2)
    end

    return {
        sequence = sequence,
        origin = origin,
        name = name,
        args = Events.copyPacked(args)
    }
end

---@param envelope EventEnvelope
---@return EventEnvelope
function Events.copy(envelope)
    return Events.new(
        envelope.sequence,
        envelope.origin,
        envelope.name,
        envelope.args
    )
end

return Events
