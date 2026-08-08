---@class ToolDescriptor
---@field type string
---@field name string
---@field description string|nil
---@field parameters table|nil

---@class ToolCall
---@field callId string|nil
---@field name string|nil
---@field arguments string|table|nil

---@alias ToolHandler fun(call: ToolCall, context: table|nil): string|table|nil, string|nil
---@alias ToolAvailability fun(context: table|nil): boolean|nil, string|nil

---@class ToolRegistration
---@field descriptor ToolDescriptor
---@field handler ToolHandler
---@field available ToolAvailability|nil

---@class ToolRegistry
---@field private ordered ToolRegistration[]
---@field private byName table<string, ToolRegistration>
local Registry = {}
Registry.__index = Registry

---@return ToolRegistry
function Registry.new()
    return setmetatable({ ordered = {}, byName = {} }, Registry)
end

---@param descriptor ToolDescriptor
---@param handler ToolHandler
---@param available ToolAvailability|nil
---@return boolean|nil registered
---@return string|nil error
function Registry:register(descriptor, handler, available)
    if type(descriptor) ~= "table"
        or type(descriptor.name) ~= "string"
        or descriptor.name == "" then
        return nil, "Tool descriptor requires a non-empty name."
    end
    if type(handler) ~= "function" then
        return nil, "Tool handler must be a function."
    end
    if available ~= nil and type(available) ~= "function" then
        return nil, "Tool availability check must be a function."
    end
    if self.byName[descriptor.name] then
        return nil, "Tool is already registered: " .. descriptor.name
    end
    local registration = {
        descriptor = descriptor,
        handler = handler,
        available = available
    }
    self.ordered[#self.ordered + 1] = registration
    self.byName[descriptor.name] = registration
    return true
end

---@param context table|nil
---@return ToolDescriptor[]
function Registry:snapshotSchemas(context)
    local descriptors = {}
    for _, registration in ipairs(self.ordered) do
        local enabled = true
        if registration.available then
            local ok, result = pcall(registration.available, context)
            enabled = ok and result == true
        end
        if enabled then descriptors[#descriptors + 1] = registration.descriptor end
    end
    return descriptors
end

---@param call ToolCall
---@param context table|nil
---@return string|table|nil result
---@return string|nil error
function Registry:dispatch(call, context)
    if type(call) ~= "table" or type(call.name) ~= "string" then
        return nil, "Tool call requires a name."
    end
    local registration = self.byName[call.name]
    if not registration then
        return nil, "Unknown local tool: " .. call.name
    end
    if registration.available then
        local ok, available, availabilityError = pcall(registration.available, context)
        if not ok then
            return nil, "Tool availability check failed for " .. call.name .. ": " .. tostring(available)
        end
        if available ~= true then
            return nil, availabilityError or ("Tool is currently unavailable: " .. call.name)
        end
    end
    local ok, result, handlerError = pcall(registration.handler, call, context)
    if not ok then
        return nil, "Tool handler failed for " .. call.name .. ": " .. tostring(result)
    end
    return result, handlerError
end

return Registry
