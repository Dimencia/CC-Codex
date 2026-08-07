local Harness = require("tests.harness")
local ConversationCatalog = require("lib.codex.storage.conversation_catalog")

local function fileSystem(files)
    files = files or {}
    return {
        files = files,
        exists = function(path) return files[path] ~= nil end,
        isDir = function() return false end,
        open = function(path, mode)
            if mode == "r" then
                if files[path] == nil then return nil, "missing" end
                return {
                    readAll = function() return files[path] end,
                    close = function() end
                }
            end
            local parts = {}
            return {
                write = function(value) parts[#parts + 1] = value end,
                close = function() files[path] = table.concat(parts) end
            }
        end,
        delete = function(path) files[path] = nil end,
        move = function(from, to)
            if files[to] ~= nil then error("destination exists") end
            files[to] = files[from]
            files[from] = nil
        end
    }
end

local function codec()
    local stored
    return {
        encode = function(value) stored = value; return "catalog" end,
        decode = function() return stored end
    }
end

return {
    {
        name = "persists names, cursors, active selection, and recent ordering",
        fn = function()
            local fs = fileSystem()
            local json = codec()
            local now = 10
            local catalog = ConversationCatalog.new({
                path = "data/conversations.json",
                fs = fs,
                json = json,
                epoch = function() now = now + 1; return now end
            })
            Harness.truthy(catalog:ensure("conversation-1", "Commands", "resp-1"))
            Harness.truthy(catalog:update("conversation-1", "resp-2"))
            Harness.truthy(catalog:ensure("conversation-2", "Building", nil))
            Harness.truthy(catalog:rename("conversation-2", "Base building"))
            Harness.truthy(catalog:select("conversation-1"))
            Harness.equal("conversation-1", catalog:active().id)
            Harness.equal("Base building", catalog:find("building").name)
            Harness.equal("resp-2", catalog:get("conversation-1").responseId)
            Harness.equal("catalog\n", fs.files["data/conversations.json"])
        end
    },
    {
        name = "loads a catalog and resolves exact names before partial names",
        fn = function()
            local fs = fileSystem()
            local json = codec()
            local writer = ConversationCatalog.new({
                path = "data/conversations.json", fs = fs, json = json, epoch = function() return 1 end
            })
            Harness.truthy(writer:ensure("conversation-1", "Commands", "resp-1"))
            local reader = ConversationCatalog.new({
                path = "data/conversations.json", fs = fs, json = json, epoch = function() return 2 end
            })
            Harness.truthy(reader:load())
            Harness.equal("Commands", reader:find("Commands").name)
            Harness.equal("conversation-1", reader:active().id)
        end
    }
}
