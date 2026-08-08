local Harness = require("tests.harness")
local Serializer = require("formatters.serializer")

return {
    {
        name = "keeps scalar values and marks unsupported values",
        fn = function()
            Harness.equal("text", Serializer.serialize("text"))
            Harness.equal(7, Serializer.serialize(7))
            Harness.equal(true, Serializer.serialize(true))
            local nilValue = Serializer.serialize(nil)
            Harness.equal("nil", nilValue.__type)
            local functionValue = Serializer.serialize(function() end)
            Harness.equal("function", functionValue.__type)
        end
    },
    {
        name = "bounds cycles depth and table size",
        fn = function()
            local value = { child = {} }
            value.self = value
            local serialized = Serializer.serialize(value)
            Harness.equal("cycle", serialized.self.__type)

            local nested = {}
            local current = nested
            for _ = 1, 20 do
                current.child = {}
                current = current.child
            end
            local bounded = Serializer.serialize(nested)
            local marker = bounded
            while marker.child do marker = marker.child end
            Harness.equal("max_depth", marker.__type)

            local wide = {}
            for index = 1, 513 do wide[index] = index end
            Harness.truthy(Serializer.serialize(wide).__truncated)
        end
    }
}
