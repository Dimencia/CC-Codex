---@class ChatEngineConfig : ResponsesRequestConfig
---@field maxToolRounds integer
---@field maxComponentRetries integer

---@class ChatTelemetry
---@field now fun(): integer
---@field retryCount fun(): integer
---@field record fun(record: UsageRecord): boolean|nil, string|nil

---@class DeliveryMetadata
---@field format 'plain'|'minecraft_component'|nil
---@field forcePlain boolean|nil
---@field reasoningSummary string|nil

---@alias DeliverReply fun(route: ReplyRoute, text: string, kind: string, metadata: DeliveryMetadata|nil): boolean|nil, string|nil, string|nil
---@alias DrainSteering fun(): TurnRequest[]|nil, string|nil

---@class ConversationEvent
---@field type 'user'|'assistant'|'tool'|'error'
---@field phase? 'initial'|'steering'|'commentary'|'final'
---@field turn_id integer
---@field response_id? string
---@field text? string
---@field call_id? string
---@field name? string
---@field input? table
---@field raw_input? string
---@field output? string

---@class ChatEngineOptions
---@field config ChatEngineConfig
---@field gateway ResponsesClient
---@field requestBuilder table
---@field reader ResponseReader
---@field json StateJsonCodec
---@field tools ToolRegistry
---@field session Session
---@field stateStore StateStore
---@field instructionStore InstructionStore
---@field artifactStore ArtifactStore
---@field deliver DeliverReply
---@field drainSteering DrainSteering
---@field restart RestartController
---@field onWarning? fun(message: string)
---@field onToolActivity? fun(call: LocalFunctionCall, result: string)
---@field onConversationEvent? fun(record: ConversationEvent)
---@field verboseToolLogging? boolean|fun(): boolean
---@field capabilitySchemas? table[]|fun(): table[]
---@field telemetry? ChatTelemetry

---@class TurnResult
---@field answer string|nil
---@field responseId string
---@field imagePaths string[]
---@field saveError string|nil
---@field restartPending boolean|nil

---@class ActiveTurnState
---@field turnId integer
---@field requestInput table[]
---@field previousResponseId string|nil
---@field routes ReplyRoute[]
---@field imagePaths string[]
---@field latestReasoningSummary string|nil
---@field toolBatches integer
---@field toolChoice string|table|nil
---@field correctionRoutes ReplyRoute[]|nil
---@field correctionAttempts integer
---@field acceptedFinalRoutes integer
---@field notifiedImageCount integer

---@class ChatEngine
---@field config ChatEngineConfig
---@field gateway ResponsesClient
---@field requestBuilder table
---@field reader ResponseReader
---@field json StateJsonCodec
---@field tools ToolRegistry
---@field session Session
---@field stateStore StateStore
---@field instructionStore InstructionStore
---@field artifactStore ArtifactStore
---@field deliver DeliverReply
---@field drainSteering DrainSteering
---@field restart RestartController
---@field onWarning fun(message: string)|nil
---@field onToolActivity fun(call: LocalFunctionCall, result: string)|nil
---@field onConversationEvent fun(record: ConversationEvent)|nil
---@field verboseToolLogging boolean|fun(): boolean|nil
---@field capabilitySchemas table[]|fun(): table[]|nil
---@field telemetry ChatTelemetry|nil
local ChatEngine = {}
ChatEngine.__index = ChatEngine

local TurnMetrics = require("lib.codex.turn_metrics")
local MAX_REASONING_HOVER_BYTES = 160
local MAX_MODEL_COMPONENT_CHARACTERS = 600
local TOOL_PROGRESS_CHUNK_BYTES = 300

local TOOL_BUDGET_NOTICE = table.concat({
    "The local tool-call budget is exhausted for this turn. Do not request more tools. ",
    "Give the player the best useful final response from the results obtained so far, ",
    "including unfinished work, in the required Minecraft text component JSON format."
})

local COMPONENT_CORRECTION_NOTICE = table.concat({
    "The preceding answer was rejected because its Minecraft text component was invalid or too long. ",
    "Return the same answer as one valid Minecraft text component ",
    "JSON value no longer than ", tostring(MAX_MODEL_COMPONENT_CHARACTERS),
    " characters. Return JSON only: no Markdown fence or explanation. Put all visible content ",
    "in text fields. Use suggest_command rather than run_command for commands the player must approve."
})

---@param summary string|nil
---@return string|nil
local function reasoningHover(summary)
    if type(summary) ~= "string" or summary == "" then return nil end
    if #summary > MAX_REASONING_HOVER_BYTES then return nil end
    return summary
end

---@param options ChatEngineOptions
---@return ChatEngine
function ChatEngine.new(options)
    assert(type(options) == "table", "chat engine options are required")
    for _, key in ipairs({
        "config", "gateway", "requestBuilder", "reader", "json", "tools",
        "session", "stateStore", "instructionStore", "artifactStore",
        "deliver", "drainSteering", "restart"
    }) do
        assert(options[key] ~= nil, key .. " is required")
    end
    local engine = setmetatable(options, ChatEngine)
    ---@cast engine ChatEngine
    return engine
end

---@param items table[]
---@return table[]
local function copyItems(items)
    local copy = {}
    for index, item in ipairs(items or {}) do
        copy[index] = item
    end
    return copy
end

---@param left unknown
---@param right unknown
---@return boolean
local function shallowEqual(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for key, value in pairs(left) do
        if right[key] ~= value then return false end
    end
    for key, value in pairs(right) do
        if left[key] ~= value then return false end
    end
    return true
end

---@param left ReplyRoute
---@param right ReplyRoute
---@return boolean
local function sameRoute(left, right)
    if left.adapterId ~= right.adapterId then return false end
    if left.adapterId == "chat_box" then
        local leftAddress = left.address
        local rightAddress = right.address
        if type(leftAddress) ~= "table" or type(rightAddress) ~= "table" then
            return false
        end
        -- Peripheral discovery may cache a device name on the route. Player
        -- identity must remain stable when that reconnect detail changes.
        return leftAddress.username == rightAddress.username
            and leftAddress.uuid == rightAddress.uuid
    end
    return shallowEqual(left.address, right.address)
end

---Routes cross a restart boundary, so copy the small serializable address rather
---than retaining an adapter-owned table which may later cache a peripheral.
---@param route ReplyRoute
---@return ReplyRoute|nil
local function copyRoute(route)
    if type(route) ~= "table"
        or type(route.adapterId) ~= "string"
        or route.adapterId == "" then
        return nil
    end
    local copy = { adapterId = route.adapterId }
    if type(route.address) == "table" then
        copy.address = {}
        for key, value in pairs(route.address) do
            if type(key) == "string"
                and (type(value) == "string"
                    or type(value) == "number"
                    or type(value) == "boolean") then
                copy.address[key] = value
            end
        end
    end
    return copy
end

---@param routes ReplyRoute[]
---@param additions ReplyRoute[]|nil
local function addRoutes(routes, additions)
    for _, candidate in ipairs(additions or {}) do
        local route = copyRoute(candidate)
        if route then
            local duplicate = false
            for _, existing in ipairs(routes) do
                if sameRoute(existing, route) then
                    duplicate = true
                    break
                end
            end
            if not duplicate then routes[#routes + 1] = route end
        end
    end
end

---@param self ChatEngine
---@param message string
local function warn(self, message)
    if self.onWarning then self.onWarning(message) end
end

---@param self ChatEngine
---@param record ConversationEvent
local function emitConversationEvent(self, record)
    if self.onConversationEvent then pcall(self.onConversationEvent, record) end
end

---@param self ChatEngine
---@param routes ReplyRoute[]
---@param text string
---@param kind string
---@param metadata DeliveryMetadata|nil
---@return integer delivered
---@return ReplyRoute[] componentRejected
local function deliverToRoutes(self, routes, text, kind, metadata)
    local delivered = 0
    local componentRejected = {}
    for _, route in ipairs(routes) do
        local ok, accepted, deliveryError, deliveryReason = pcall(
            self.deliver,
            route,
            text,
            kind,
            metadata
        )
        if ok and accepted then
            delivered = delivered + 1
        else
            local reason = ok and deliveryError or accepted
            if ok and deliveryReason == "component_rejected" then
                componentRejected[#componentRejected + 1] = route
            else
                warn(self, string.format(
                    "Could not deliver %s through %s: %s",
                    kind,
                    route.adapterId,
                    tostring(reason or "delivery was rejected")
                ))
            end
        end
    end
    return delivered, componentRejected
end

---@param self ChatEngine
---@return boolean
local function verboseToolLogging(self)
    local configured = self.verboseToolLogging
    if type(configured) == "function" then
        local ok, enabled = pcall(configured)
        return ok and enabled == true
    end
    return configured == true
end

---@param self ChatEngine
---@param routes ReplyRoute[]
---@param label string
---@param value string
local function deliverToolDetail(self, routes, label, value)
    local total = math.max(1, math.ceil(#value / TOOL_PROGRESS_CHUNK_BYTES))
    for index = 1, total do
        local first = (index - 1) * TOOL_PROGRESS_CHUNK_BYTES + 1
        local chunk = value:sub(first, first + TOOL_PROGRESS_CHUNK_BYTES - 1)
        local heading = total == 1
            and ("[" .. label .. "]")
            or string.format("[%s %d/%d]", label, index, total)
        deliverToRoutes(self, routes, heading .. "\n" .. chunk, "progress", {
            format = "plain"
        })
    end
end

---A Chat Box route identifies the speaker, not merely where the answer goes.
---Keeping that fact in provider input prevents simultaneous players from being
---collapsed into one anonymous user while terminal input stays uncluttered.
---@param request TurnRequest
---@return string
local function providerUserText(request)
    local text = tostring(request.text or "")
    for _, route in ipairs(request.replyRoutes or {}) do
        local address = route.adapterId == "chat_box" and route.address or nil
        if type(address) == "table"
            and type(address.username) == "string"
            and address.username ~= "" then
            if type(address.uuid) == "string" and address.uuid ~= "" then
                return string.format(
                    "Minecraft chat from %s (UUID %s):\n%s",
                    address.username,
                    address.uuid,
                    text
                )
            end
            return string.format("Minecraft chat from %s:\n%s", address.username, text)
        end
    end
    return text
end

---@param self ChatEngine
---@return ToolDescriptor[]
---@return integer encodedBytes
local function snapshotSchemas(self)
    local schemas = self.tools:snapshotSchemas()
    local configured = self.capabilitySchemas
    ---@type table[]
    local capabilities = {}
    if type(configured) == "function" then
        capabilities = configured() or {}
    elseif type(configured) == "table" then
        capabilities = configured
    end
    for _, schema in ipairs(capabilities) do
        schemas[#schemas + 1] = schema
    end
    local encoded = self.json.encode(schemas)
    return schemas, encoded and #encoded or 0
end

---@param self ChatEngine
---@param value unknown
---@return string
local function encodeToolValue(self, value)
    if type(value) == "string" then return value end
    local encoded = self.json.encode(value)
    return encoded or '{"ok":false,"error":"Could not encode the tool result."}'
end

---@param self ChatEngine
---@param value string|table|nil
---@return string
local function displayToolInput(self, value)
    if type(value) == "string" then return value end
    local ok, encoded = pcall(self.json.encode, value)
    if ok and type(encoded) == "string" then return encoded end
    return tostring(value)
end

---@param self ChatEngine
---@param call LocalFunctionCall
---@param responseUsage ResponseUsage|nil
---@param turnId integer
---@param requestRestart fun(): boolean
---@return string
local function dispatchTool(self, call, responseUsage, turnId, requestRestart)
    local arguments, argumentError = self.reader:decodeToolArguments(call.arguments)
    if not arguments then
        return encodeToolValue(self, { ok = false, error = argumentError })
    end
    call.arguments = arguments
    ---@type ToolCall
    local dispatchCall = {
        callId = call.callId,
        name = call.name,
        arguments = arguments
    }
    local result, dispatchError = self.tools:dispatch(dispatchCall, {
        session = self.session,
        turnId = turnId,
        usage = responseUsage,
        responseUsage = responseUsage,
        requestRestart = requestRestart
    })
    if dispatchError then
        return encodeToolValue(self, { ok = false, error = dispatchError })
    end
    return encodeToolValue(self, result)
end

---@param self ChatEngine
---@param routes ReplyRoute[]
---@param turnId integer
---@return table[]|nil input
---@return string|nil error
local function drainSteering(self, routes, turnId)
    local requests, drainError = self.drainSteering()
    if requests == nil then
        return nil, "Could not drain queued steering: " .. tostring(drainError)
    end
    local input = {}
    for _, request in ipairs(requests) do
        if type(request.text) == "string" then
            local text = providerUserText(request)
            input[#input + 1] = self.requestBuilder.makeInputMessage(
                "user",
                text
            )
            emitConversationEvent(self, {
                type = "user",
                phase = "steering",
                turn_id = turnId,
                text = text
            })
            addRoutes(routes, request.replyRoutes)
        end
    end
    return input
end

---@param target table[]
---@param additions table[]
local function appendItems(target, additions)
    for _, item in ipairs(additions) do target[#target + 1] = item end
end

---@param imagePaths string[]
---@return string
local function imageOnlyAnswer(imagePaths)
    if #imagePaths == 1 then
        return "Generated image saved to " .. imagePaths[1]
    end
    return "Generated images saved to:\n" .. table.concat(imagePaths, "\n")
end

---@param content string
---@return string
local function preferencesInputText(content)
    local current = content:find("%S") and content or "No additional preferences are set."
    return table.concat({
        "Latest CC Codex preferences. These replace all earlier preferences:",
        "",
        current
    }, "\n")
end

---@param self ChatEngine
---@param metrics TurnMetrics
---@param input table[]
---@param previousResponseId string|nil
---@param toolChoice string|table|nil
---@return ResponsesDto|nil response
---@return string|nil error
local function requestResponse(self, metrics, input, previousResponseId, toolChoice)
    local preferences, preferencesError = self.instructionStore:readPreferences()
    if type(preferences) ~= "table"
        or type(preferences.content) ~= "string"
        or type(preferences.modifiedAt) ~= "number" then
        return nil, "Could not read preferences: " .. tostring(
            preferencesError or "the preferences document was invalid"
        )
    end

    local update = self.session:instructionUpdate(preferences.modifiedAt)
    local selected = {}
    if update == "full" then
        local systemPrompt, systemError = self.instructionStore:readSystemPrompt()
        if type(systemPrompt) ~= "string" or systemPrompt == "" then
            return nil, "Could not read system prompt: " .. tostring(
                systemError or "the system prompt was invalid or empty"
            )
        end
        selected[#selected + 1] = self.requestBuilder.makeInputMessage(
            "developer",
            systemPrompt
        )
    end
    if update then
        selected[#selected + 1] = self.requestBuilder.makeInputMessage(
            "developer",
            preferencesInputText(preferences.content)
        )
    end
    appendItems(selected, input)

    local schemas, schemaBytes = snapshotSchemas(self)
    metrics:addSchemaBytes(schemaBytes)
    local body = self.requestBuilder.build(self.config, selected, {
        previousResponseId = previousResponseId,
        toolChoice = toolChoice,
        compactThresholdOverride = self.session.pendingCompactThreshold,
        tools = schemas
    })
    local response, responseError = self.gateway:createResponse(body)
    if not response then return nil, responseError end

    if update then self.session:markInstructionsSent(preferences.modifiedAt) end
    self.session.pendingCompactThreshold = nil
    return response
end

---@param self ChatEngine
---@param metrics TurnMetrics
---@param response ResponsesDto
---@param routes ReplyRoute[]
---@param imagePaths string[]
---@param turnId integer
---@return table[]|nil steeringInput
---@return string|nil error
---@return string|nil latestReasoningSummary
local function processResponse(self, metrics, response, routes, imagePaths, turnId)
    metrics:addResponse(response)
    local saved, imageError = self.artifactStore:saveGeneratedImages(response)
    if not saved then return nil, imageError end
    for _, path in ipairs(saved) do
        imagePaths[#imagePaths + 1] = path
        self.session.lastGeneratedImagePath = path
    end

    local reasoningSummary = reasoningHover(self.reader:reasoningSummary(response))

    if self.reader:hasCompaction(response) then
        -- Server compaction can discard developer items, so force the system
        -- prompt and latest preferences back into the next API boundary.
        self.session:markCompacted()
        metrics:markCompacted()
    end

    -- CC HTTP yields while waiting. Draining only after its response preserves
    -- provider ordering while still letting chat gathered in parallel steer the
    -- next continuation.
    local steeringInput, steeringError = drainSteering(self, routes, turnId)
    if not steeringInput then return nil, steeringError end

    local commentary = self.reader:commentaryText(response)
    if commentary then
        emitConversationEvent(self, {
            type = "assistant",
            phase = "commentary",
            turn_id = turnId,
            response_id = response.id,
            text = commentary
        })
        deliverToRoutes(self, routes, commentary, "progress", {
            format = "plain",
            reasoningSummary = reasoningSummary
        })
    end
    local finalText = self.reader:finalText(response)
    if finalText then
        emitConversationEvent(self, {
            type = "assistant",
            phase = "final",
            turn_id = turnId,
            response_id = response.id,
            text = finalText
        })
    end
    return steeringInput, nil, reasoningSummary
end

---@param self ChatEngine
---@param turnId integer
---@param responseId string
---@param input table[]
---@param routes ReplyRoute[]
---@return boolean restartPending
---@return string|nil continuationNotice
local function requestImmediateRestart(self, turnId, responseId, input, routes)
    local checkpoint = {
        turnId = turnId,
        previousResponseId = responseId,
        input = copyItems(input),
        replyRoutes = copyItems(routes)
    }
    local checkpointed, checkpointError = self.session:checkpoint(checkpoint)
    local state = checkpointed and self.session:durableState() or nil
    local saved, saveError
    if checkpointed and state then
        saved, saveError = self.stateStore:save(state)
    end
    if not checkpointed or not state or not saved then
        local reason = checkpointError or saveError or "durable session state was unavailable"
        return false, table.concat({
            "Immediate restart was cancelled because the continuation checkpoint could not be saved: ",
            tostring(reason),
            ". Continue in this process and report or fix the problem."
        })
    end

    -- The marker is intentionally last: a new process must never start unless
    -- every function output needed to resume this exact boundary is durable.
    local ok, requested, restartError = pcall(self.restart.request, self.restart)
    if ok and requested then return true end
    local reason = ok and restartError or requested
    return false, table.concat({
        "Immediate restart could not be requested after the continuation was saved: ",
        tostring(reason or "the restart request was rejected"),
        ". Continue in this process; the pending checkpoint will clear after the final answer is saved."
    })
end

---@param self ChatEngine
---@param response ResponsesDto
---@param answer string
---@param imagePaths string[]
---@return TurnResult
local function commitTurn(self, response, answer, imagePaths)
    local saveError
    local committed, commitError = self.session:commit(
        response.id,
        response.usage,
        self.session.lastGeneratedImagePath
    )
    if not committed then
        saveError = commitError
    else
        local state = self.session:durableState()
        if not state then
            saveError = "Completed turn did not produce durable session state."
        else
            local _, stateError = self.stateStore:save(state)
            saveError = stateError
        end
    end
    return {
        answer = answer,
        responseId = response.id,
        imagePaths = imagePaths,
        saveError = saveError
    }
end

---@param response ResponsesDto
---@param reader ResponseReader
---@param imagePaths string[]
---@return string|nil answer
---@return boolean hostAuthored
---@return string|nil error
local function finalAnswer(response, reader, imagePaths)
    if type(response.id) ~= "string" or response.id == "" then
        return nil, false, "API returned a final response without an ID."
    end
    local answer, textError = reader:finalText(response)
    if answer then
        return answer, false
    elseif #imagePaths > 0 then
        -- Image generation can validly end without an assistant message. The
        -- artifact path is still a complete, useful host-authored answer.
        return imageOnlyAnswer(imagePaths), true
    end
    return nil, false, textError
end

---@param self ChatEngine
---@param routes ReplyRoute[]
---@param imagePaths string[]
---@param notified integer
---@return integer
local function notifyArtifacts(self, routes, imagePaths, notified)
    if #imagePaths <= notified then return notified end
    local paths = {}
    for index = notified + 1, #imagePaths do
        paths[#paths + 1] = imagePaths[index]
    end
    deliverToRoutes(self, routes, imageOnlyAnswer(paths), "progress", { format = "plain" })
    return #imagePaths
end

---@param self ChatEngine
---@param state ActiveTurnState
---@param response ResponsesDto
---@param steeringInput table[]
---@return boolean continue
---@return TurnResult|nil result
---@return string|nil error
local function handleFinalResponse(self, state, response, steeringInput)
    if #steeringInput > 0 then
        if type(response.id) ~= "string" or response.id == "" then
            return false, nil, "API returned a steered response without an ID."
        end
        -- A response produced before queued input was observed is not final
        -- for the conversation; continue from it without displaying stale text.
        state.requestInput = steeringInput
        state.previousResponseId = response.id
        state.toolChoice = nil
        state.correctionRoutes = nil
        state.correctionAttempts = 0
        state.acceptedFinalRoutes = 0
        return true
    end

    local answer, hostAuthored, answerError = finalAnswer(
        response,
        self.reader,
        state.imagePaths
    )
    if not answer then return false, nil, answerError end

    local targets = state.correctionRoutes or state.routes
    if not hostAuthored then
        state.notifiedImageCount = notifyArtifacts(
            self,
            state.routes,
            state.imagePaths,
            state.notifiedImageCount
        )
    end
    local metadata = {
        format = hostAuthored and "plain" or "minecraft_component",
        reasoningSummary = state.latestReasoningSummary
    }
    local delivered, rejected = deliverToRoutes(
        self,
        targets,
        answer,
        "final",
        metadata
    )
    state.acceptedFinalRoutes = state.acceptedFinalRoutes + delivered

    if not hostAuthored and #rejected > 0 then
        local lateSteering, lateSteeringError = drainSteering(self, state.routes, state.turnId)
        if not lateSteering then return false, nil, lateSteeringError end
        if #lateSteering > 0 then
            -- A newly arrived player message supersedes presentation correction
            -- of the now-stale answer.
            state.requestInput = lateSteering
            state.previousResponseId = response.id
            state.toolChoice = nil
            state.correctionRoutes = nil
            state.correctionAttempts = 0
            state.acceptedFinalRoutes = 0
            return true
        end
        if state.correctionAttempts < self.config.maxComponentRetries then
            state.correctionAttempts = state.correctionAttempts + 1
            state.correctionRoutes = rejected
            state.requestInput = {
                self.requestBuilder.makeInputMessage(
                    "developer",
                    COMPONENT_CORRECTION_NOTICE
                )
            }
            state.previousResponseId = response.id
            state.toolChoice = "none"
            return true
        end

        local fallbackDelivered = deliverToRoutes(
            self,
            rejected,
            answer,
            "final",
            {
                format = metadata.format,
                forcePlain = true,
                reasoningSummary = metadata.reasoningSummary
            }
        )
        state.acceptedFinalRoutes = state.acceptedFinalRoutes + fallbackDelivered
    end

    if state.acceptedFinalRoutes == 0 then
        return false, nil, "The final response could not be delivered to any reply route."
    end
    return false, commitTurn(self, response, answer, state.imagePaths)
end

---@param self ChatEngine
---@param state ActiveTurnState
---@param request TurnRequest
---@param metrics TurnMetrics
---@param response ResponsesDto
---@param calls LocalFunctionCall[]
---@param steeringInput table[]
---@return boolean continue
---@return TurnResult|nil result
---@return string|nil error
local function handleToolBatch(self, state, request, metrics, response, calls, steeringInput)
    if state.toolChoice == "none" then
        return false, nil, "API returned tool calls after tools were disabled."
    end
    if type(response.id) ~= "string" or response.id == "" then
        return false, nil, "API returned a tool call without a response ID."
    end

    state.toolBatches = state.toolBatches + 1
    metrics:incrementToolRound()
    local restartAccepted = false
    local function acceptRestart()
        restartAccepted = true
        return true
    end

    state.requestInput = {}
    for _, call in ipairs(calls) do
        if type(call.callId) ~= "string" or call.callId == "" then
            return false, nil, "API returned a tool call without a call ID."
        end
        -- Tool activity belongs to the active conversation routes. Keeping
        -- only the name here avoids exposing arguments or results in chat.
        deliverToRoutes(
            self,
            state.routes,
            "[tool: " .. tostring(call.name) .. "]",
            "progress"
        )
        local rawArguments = displayToolInput(self, call.arguments)
        if verboseToolLogging(self) then
            deliverToolDetail(
                self,
                state.routes,
                "tool input: " .. tostring(call.name),
                rawArguments
            )
        end
        local result = dispatchTool(
            self,
            call,
            response.usage,
            request.id,
            acceptRestart
        )
        metrics:addResultBytes(#result)
        local decodedArguments
        if type(call.arguments) == "table" then decodedArguments = call.arguments end
        ---@cast decodedArguments table|nil
        emitConversationEvent(self, {
            type = "tool",
            turn_id = request.id,
            response_id = response.id,
            call_id = call.callId,
            name = call.name,
            input = decodedArguments,
            raw_input = rawArguments,
            output = result
        })
        if verboseToolLogging(self) then
            deliverToolDetail(
                self,
                state.routes,
                "tool output: " .. tostring(call.name),
                result
            )
        end
        if self.onToolActivity then pcall(self.onToolActivity, call, result) end
        state.requestInput[#state.requestInput + 1] = self.reader:makeFunctionCallOutput(
            call.callId,
            result
        )
    end
    -- Function outputs retain response order. Steering follows the whole
    -- batch so the provider never sees an interleaved tool cycle.
    appendItems(state.requestInput, steeringInput)
    local lateSteering, lateSteeringError = drainSteering(self, state.routes, request.id)
    if not lateSteering then return false, nil, lateSteeringError end
    -- Tools may yield long enough for another player message to arrive. Drain
    -- again before continuing so it does not wait through another provider call.
    appendItems(state.requestInput, lateSteering)
    state.previousResponseId = response.id

    if restartAccepted then
        local restartPending, notice = requestImmediateRestart(
            self,
            request.id,
            response.id,
            state.requestInput,
            state.routes
        )
        if restartPending then
            return false, {
                responseId = response.id,
                imagePaths = state.imagePaths,
                restartPending = true
            }
        end
        state.requestInput[#state.requestInput + 1] = self.requestBuilder.makeInputMessage(
            "developer",
            assert(notice)
        )
    end

    if state.toolBatches >= self.config.maxToolRounds then
        state.requestInput[#state.requestInput + 1] = self.requestBuilder.makeInputMessage(
            "developer",
            TOOL_BUDGET_NOTICE
        )
        state.toolChoice = "none"
    end
    return true
end

---@param self ChatEngine
---@param request TurnRequest
---@param metrics TurnMetrics
---@return TurnResult|nil result
---@return string|nil error
local function runActiveTurn(self, request, metrics)
    local continuation = request.continuation
    local routes = {}
    local requestInput
    local previousResponseId
    if continuation then
        requestInput = copyItems(continuation.input)
        previousResponseId = continuation.previousResponseId
        addRoutes(routes, continuation.replyRoutes)
    else
        local text = providerUserText(request)
        requestInput = {
            self.requestBuilder.makeInputMessage("user", text)
        }
        previousResponseId = self.session.previousResponseId
        emitConversationEvent(self, {
            type = "user",
            phase = "initial",
            turn_id = request.id,
            text = text
        })
    end
    addRoutes(routes, request.replyRoutes)

    ---@type ActiveTurnState
    local state = {
        turnId = request.id,
        requestInput = requestInput,
        previousResponseId = previousResponseId,
        routes = routes,
        imagePaths = {},
        toolBatches = 0,
        correctionAttempts = 0,
        acceptedFinalRoutes = 0,
        notifiedImageCount = 0
    }
    while true do
        local response, requestError = requestResponse(
            self,
            metrics,
            state.requestInput,
            state.previousResponseId,
            state.toolChoice
        )
        if not response then return nil, requestError end

        local steeringInput, responseError, reasoningSummary = processResponse(
            self,
            metrics,
            response,
            state.routes,
            state.imagePaths,
            request.id
        )
        if not steeringInput then return nil, responseError end
        state.latestReasoningSummary = reasoningSummary

        local calls = self.reader:functionCalls(response)
        local continue, result, transitionError
        if #calls == 0 then
            continue, result, transitionError = handleFinalResponse(
                self,
                state,
                response,
                steeringInput
            )
        else
            continue, result, transitionError = handleToolBatch(
                self,
                state,
                request,
                metrics,
                response,
                calls,
                steeringInput
            )
        end
        if not continue then return result, transitionError end
    end
end

---@param self ChatEngine
---@param request TurnRequest
---@param metrics TurnMetrics
---@param failure string|nil
local function finishTurn(self, request, metrics, failure)
    self.session:endTurn(request.id)
    if not self.telemetry then return end
    local endedAt = self.telemetry.now()
    local ok, _, telemetryError = pcall(
        self.telemetry.record,
        metrics:buildRecord(endedAt, self.telemetry.retryCount(), failure)
    )
    if not ok then
        warn(self, "Could not record usage telemetry: " .. tostring(_))
    elseif telemetryError then
        warn(self, "Could not record usage telemetry: " .. tostring(telemetryError))
    end
end

---@param request TurnRequest
---@return TurnResult|nil result
---@return string|nil error
function ChatEngine:runTurn(request)
    local began, beginError = self.session:beginTurn(request.id)
    if not began then return nil, beginError end

    local metrics = TurnMetrics.new({
        turnId = request.id,
        startedAt = self.telemetry and self.telemetry.now() or 0,
        initialRetries = self.telemetry and self.telemetry.retryCount() or 0,
        model = self.config.model,
        serviceTier = self.config.serviceTier
    })
    local ok, result, failure = pcall(runActiveTurn, self, request, metrics)
    if not ok then
        failure = tostring(result)
        result = nil
    end
    if failure then
        emitConversationEvent(self, {
            type = "error",
            turn_id = request.id,
            text = tostring(failure)
        })
    end
    finishTurn(self, request, metrics, failure)
    return result, failure
end

return ChatEngine
