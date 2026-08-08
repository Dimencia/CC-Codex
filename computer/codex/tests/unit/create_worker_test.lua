local Harness = require("tests.harness")
local Registry = require("tools.registry")
local Worker = require("tools.create_worker")

local function dependencies(options)
    options = options or {}
    local files = options.files or {
        ["platform/cc/remote_bootstrap.lua"] = "bootstrap-source"
    }
    local directories = options.directories or {}
    local jsonValues = {}
    local jsonCounter = 0
    local randomValue = 10

    local fs = {
        exists = function(path) return files[path] ~= nil or directories[path] == true end,
        isDir = function(path) return directories[path] == true end,
        isReadOnly = function() return options.readOnly == true end,
        combine = function(left, right)
            return left == "" and right or left .. "/" .. right
        end,
        makeDir = function(path) directories[path] = true end,
        delete = function(path)
            files[path] = nil
            directories[path] = nil
        end,
        move = function(from, to)
            files[to] = files[from]
            files[from] = nil
        end,
        open = function(path, mode)
            if mode == "r" then
                if files[path] == nil then return nil, "missing" end
                local content = files[path]
                return {
                    readAll = function() return content end,
                    close = function() end
                }
            end
            if mode == "w" then
                local parts = {}
                return {
                    write = function(value) parts[#parts + 1] = value end,
                    close = function() files[path] = table.concat(parts) end
                }
            end
            return nil, "unsupported mode"
        end
    }

    local json = {
        encode = function(value)
            jsonCounter = jsonCounter + 1
            local encoded = "json-" .. tostring(jsonCounter)
            jsonValues[encoded] = value
            return encoded
        end,
        decode = function(value) return jsonValues[value] end
    }

    return {
        files = files,
        directories = directories,
        jsonValues = jsonValues,
        fs = fs,
        disk = {
            hasData = function(name) return name == (options.drive or "drive_0") end,
            getMountPath = function(name)
                if name ~= (options.drive or "drive_0") then return nil end
                return options.mount or "disk"
            end
        },
        peripheral = {
            getNames = function() return { options.drive or "drive_0" } end
        },
        json = json,
        sourcePath = "platform/cc/remote_bootstrap.lua",
        credentialPath = "data/remote_workers.json",
        computerId = function() return 7 end,
        epoch = function() return 1000 end,
        random = function()
            randomValue = randomValue + 1
            return randomValue
        end
    }
end

local function createCall(drive, target, replace)
    return {
        name = "create_worker",
        arguments = { drive = drive or "drive_0", target = target or 42, replace = replace }
    }
end

return {
    {
        name = "registers only when a writable data disk is present",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies()
            Harness.truthy(Worker.register(registry, deps))
            Harness.equal(1, #registry:snapshotSchemas({}))
            deps.readOnly = true
            local readOnlyDeps = dependencies({ readOnly = true })
            local readOnlyRegistry = Registry.new()
            Harness.truthy(Worker.register(readOnlyRegistry, readOnlyDeps))
            Harness.equal(0, #readOnlyRegistry:snapshotSchemas({}))
        end
    },
    {
        name = "writes the bootstrap and authority config under disk startup",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies()
            Harness.truthy(Worker.register(registry, deps))
            local result = assert(registry:dispatch(createCall(), {}))
            Harness.truthy(result.ok)
            Harness.equal("disk/startup/remote_bootstrap.lua", result.mount .. "/" .. result.bootstrap)
            Harness.equal("bootstrap-source", deps.files["disk/startup/remote_bootstrap.lua"])
            Harness.truthy(deps.files["disk/worker.json"])
            Harness.truthy(deps.files["data/remote_workers.json"])
            local config = deps.jsonValues[deps.files["disk/worker.json"]]
            local credentials = deps.jsonValues[deps.files["data/remote_workers.json"]]
            Harness.equal(1, config.version)
            Harness.equal(7, config.parent_id)
            Harness.equal(42, config.target_id)
            Harness.equal(config.capability, credentials.workers["42"].capability)
            Harness.truthy(result.restartRequired)
        end
    },
    {
        name = "refuses to replace an unrelated worker without an explicit rotation",
        fn = function()
            local deps = dependencies({
                files = {
                    ["platform/cc/remote_bootstrap.lua"] = "bootstrap-source",
                    ["disk/startup/remote_bootstrap.lua"] = "other-bootstrap",
                    ["disk/worker.json"] = "existing-config"
                },
                directories = { ["disk/startup"] = true }
            })
            deps.jsonValues["existing-config"] = {
                version = 1,
                parent_id = 99,
                target_id = 42,
                capability = "other-capability"
            }
            local registry = Registry.new()
            Harness.truthy(Worker.register(registry, deps))
            local result = assert(registry:dispatch(createCall(), {}))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("replace=true", 1, true))
        end
    }
}
