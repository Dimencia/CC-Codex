---@class ReplyRoute
---@field adapterId string
---@field address? unknown

---@class ContinuationCheckpoint
---@field turnId integer
---@field previousResponseId string
---@field input table[]
---@field replyRoutes ReplyRoute[]

---@class TurnRequest
---@field id integer
---@field text string|nil
---@field replyRoutes ReplyRoute[]
---@field continuation ContinuationCheckpoint|nil

---@class TurnQueue
---@field private values TurnRequest[]
---@field private head integer
---@field private tail integer
---@field private count integer
---@field private closed boolean
local TurnQueue = {}
TurnQueue.__index = TurnQueue

---@return TurnQueue
function TurnQueue.new()
    return setmetatable({
        values = {},
        head = 1,
        tail = 1,
        count = 0,
        closed = false
    }, TurnQueue)
end

---@param request TurnRequest
---@return boolean accepted
---@return string|nil error
function TurnQueue:submit(request)
    if self.closed then return false, "Turn queue is closed." end
    if type(request) ~= "table"
        or type(request.id) ~= "number"
        or request.id % 1 ~= 0
        or type(request.replyRoutes) ~= "table"
        or (type(request.text) ~= "string" and type(request.continuation) ~= "table") then
        return false, "Invalid turn request."
    end

    self.values[self.tail] = request
    self.tail = self.tail + 1
    self.count = self.count + 1
    return true
end

---@return TurnRequest|nil request
function TurnQueue:take()
    if self.count == 0 then return nil end
    local request = self.values[self.head]
    self.values[self.head] = nil
    self.head = self.head + 1
    self.count = self.count - 1
    if self.count == 0 then
        self.head = 1
        self.tail = 1
    end
    return request
end

---Stops before, and leaves queued, the first request for which stopBefore is true.
---@param stopBefore (fun(request: TurnRequest): boolean)|nil
---@return TurnRequest[]
function TurnQueue:drain(stopBefore)
    local drained = {}
    while self.count > 0 do
        local request = self.values[self.head]
        if stopBefore and stopBefore(request) then break end
        drained[#drained + 1] = assert(self:take())
    end
    return drained
end

---@return integer
function TurnQueue:length()
    return self.count
end

---@return boolean
function TurnQueue:isClosed()
    return self.closed
end

function TurnQueue:close()
    self.closed = true
end

return TurnQueue
