---@class ResponseInputTokensDetails
---@field cached_tokens integer|nil
---@field [string] unknown

---@class ResponseOutputTokensDetails
---@field reasoning_tokens integer|nil
---@field [string] unknown

---@class ResponseUsage
---@field input_tokens integer|nil
---@field input_tokens_details ResponseInputTokensDetails|nil
---@field output_tokens integer|nil
---@field output_tokens_details ResponseOutputTokensDetails|nil
---@field total_tokens integer|nil
---@field [string] unknown

---@class SessionSnapshot
---@field previousResponseId string|nil
---@field lastGeneratedImagePath string|nil
---@field preferencesModifiedAt number|nil Last sent preferences modification time.
---@field instructionsRefresh boolean|nil
---@field checkpoint ContinuationCheckpoint|nil
---@field conversationLogId string|nil

---@class Session
---@field previousResponseId string|nil
---@field lastGeneratedImagePath string|nil
---@field lastUsage ResponseUsage|nil
---@field pendingCompactThreshold integer|nil
---@field activeTurnId integer|nil
---@field conversationLogId string|nil
---@field private preferencesModifiedAt number|nil Last sent preferences modification time.
---@field private instructionsRefresh boolean
---@field private continuation ContinuationCheckpoint|nil
local Session = {}
Session.__index = Session

---@param checkpoint ContinuationCheckpoint|nil
---@return boolean|nil
---@return string|nil
local function validCheckpoint(checkpoint)
    if checkpoint == nil then return true end
    if type(checkpoint) ~= "table"
        or type(checkpoint.turnId) ~= "number"
        or type(checkpoint.previousResponseId) ~= "string"
        or checkpoint.previousResponseId == ""
        or type(checkpoint.input) ~= "table"
        or type(checkpoint.replyRoutes) ~= "table" then
        return nil, "Continuation checkpoint is incomplete."
    end
    return true
end

---@param snapshot SessionSnapshot|nil
---@return Session
function Session.new(snapshot)
    snapshot = snapshot or {}
    local responseId = type(snapshot.previousResponseId) == "string"
        and snapshot.previousResponseId ~= ""
        and snapshot.previousResponseId
        or nil
    return setmetatable({
        previousResponseId = responseId,
        lastGeneratedImagePath = snapshot.lastGeneratedImagePath,
        lastUsage = nil,
        pendingCompactThreshold = nil,
        activeTurnId = nil,
        conversationLogId = type(snapshot.conversationLogId) == "string"
            and snapshot.conversationLogId ~= "" and snapshot.conversationLogId or nil,
        preferencesModifiedAt = snapshot.preferencesModifiedAt,
        instructionsRefresh = snapshot.instructionsRefresh == true,
        continuation = snapshot.checkpoint
    }, Session)
end

---@param turnId integer
---@return boolean|nil
---@return string|nil
function Session:beginTurn(turnId)
    if self.activeTurnId ~= nil then
        return nil, "A conversation turn is already active."
    end
    self.activeTurnId = turnId
    return true
end

---@param turnId integer
---@return boolean
function Session:endTurn(turnId)
    if self.activeTurnId ~= turnId then return false end
    self.activeTurnId = nil
    return true
end

---@param checkpoint ContinuationCheckpoint|nil
---@return boolean|nil
---@return string|nil
function Session:checkpoint(checkpoint)
    local valid, errorMessage = validCheckpoint(checkpoint)
    if not valid then return nil, errorMessage end
    self.continuation = checkpoint
    return true
end

---@return ContinuationCheckpoint|nil
function Session:pending()
    return self.continuation
end

---@param responseId string
---@param usage ResponseUsage|nil
---@param latestImage string|nil
---@return boolean|nil
---@return string|nil
function Session:commit(responseId, usage, latestImage)
    if type(responseId) ~= "string" or responseId == "" then
        return nil, "Cannot commit a completed turn without a response ID."
    end
    self.previousResponseId = responseId
    self.lastUsage = usage
    -- A text-only continuation still needs the most recently generated artifact.
    if type(latestImage) == "string" then self.lastGeneratedImagePath = latestImage end
    self.continuation = nil
    return true
end

---@alias InstructionUpdate "full"|"preferences"

---@param preferencesModifiedAt number
---@return InstructionUpdate|nil
function Session:instructionUpdate(preferencesModifiedAt)
    if self.preferencesModifiedAt == nil or self.instructionsRefresh then return "full" end
    if self.preferencesModifiedAt ~= preferencesModifiedAt then return "preferences" end
    return nil
end

---@param preferencesModifiedAt number
function Session:markInstructionsSent(preferencesModifiedAt)
    self.preferencesModifiedAt = preferencesModifiedAt
    self.instructionsRefresh = false
end

function Session:markCompacted()
    self.instructionsRefresh = true
end

---@param conversationLogId string
---@return boolean|nil
---@return string|nil
function Session:setConversationLogId(conversationLogId)
    if type(conversationLogId) ~= "string" or conversationLogId == "" then
        return nil, "Conversation log ID must be a non-empty string."
    end
    self.conversationLogId = conversationLogId
    return true
end

---@param responseId string|nil
---@param latestImage string|nil
---@param conversationLogId string
---@return boolean|nil
---@return string|nil
function Session:selectConversation(responseId, latestImage, conversationLogId)
    if responseId ~= nil and (type(responseId) ~= "string" or responseId == "") then
        return nil, "Conversation response ID must be a non-empty string or nil."
    end
    if type(conversationLogId) ~= "string" or conversationLogId == "" then
        return nil, "Conversation log ID must be a non-empty string."
    end
    self.previousResponseId = responseId
    self.lastGeneratedImagePath = latestImage
    self.conversationLogId = conversationLogId
    -- A different provider branch may not contain the latest preferences.
    self.instructionsRefresh = true
    self.continuation = nil
    self.pendingCompactThreshold = nil
    return true
end

function Session:reset()
    self.previousResponseId = nil
    self.lastGeneratedImagePath = nil
    self.lastUsage = nil
    self.pendingCompactThreshold = nil
    self.activeTurnId = nil
    self.conversationLogId = nil
    self.preferencesModifiedAt = nil
    self.instructionsRefresh = false
    self.continuation = nil
end

---@return SessionSnapshot|nil
function Session:durableState()
    if not self.previousResponseId and not self.continuation and not self.conversationLogId then return nil end
    return {
        previousResponseId = self.previousResponseId,
        lastGeneratedImagePath = self.lastGeneratedImagePath,
        preferencesModifiedAt = self.preferencesModifiedAt,
        instructionsRefresh = self.instructionsRefresh,
        checkpoint = self.continuation,
        conversationLogId = self.conversationLogId
    }
end

return Session
