local harness = require("tests.harness")
local ExecuteLua = require("tools.execute_lua")

local function newTool(maxCharacters, encoder)
    return ExecuteLua.new({
        maxCharacters = maxCharacters or 1000,
        json = {
            encode = encoder or function(result)
                return result.ok and "encoded-success" or "encoded-failure"
            end,
            decode = function(value)
                if value == '{"code":"return 1"}' then
                    return { code = "return 1" }
                end
                return nil, "invalid JSON"
            end
        },
        loadChunk = load,
        globals = { answer = 41, error = error, tostring = tostring },
        serializeValue = function(value)
            return value.x and ("{x=" .. tostring(value.x) .. "}") or "{}"
        end
    })
end

return {
    {
        name = "descriptor keeps the legacy execute_cc_lua contract",
        fn = function()
            local tool = newTool()
            harness.equal("execute_cc_lua", tool.descriptor.name)
            harness.equal("code", tool.descriptor.parameters.required[1])
        end
    },
    {
        name = "captures print write errors globals and every returned value",
        fn = function()
            local result = newTool():executeResult(table.concat({
                "print('a', {x=1})",
                "write('b')",
                "printError('c')",
                "return answer + 1, nil, {x=2}"
            }, ";"))
            harness.truthy(result.ok)
            harness.equal("a\t{x=1}\nbc\n", result.output)
            harness.falsy(result.output_truncated)
            harness.arrayEqual({ "42", "nil", "{x=2}" }, result.returned)
        end
    },
    {
        name = "reports compile errors with capture state",
        fn = function()
            local result = newTool():executeResult("this is not lua")
            harness.falsy(result.ok)
            harness.truthy(result.error:find("Lua compile error", 1, true))
            harness.equal("", result.output)
            harness.falsy(result.output_truncated)
        end
    },
    {
        name = "preserves output before runtime failures",
        fn = function()
            local result = newTool():executeResult("print('before'); error('boom')")
            harness.falsy(result.ok)
            harness.equal("before\n", result.output)
            harness.truthy(result.error:find("Lua runtime error", 1, true))
            harness.truthy(result.error:find("boom", 1, true))
        end
    },
    {
        name = "truncates at the exact configured byte budget",
        fn = function()
            local result = newTool(5):executeResult("print('abcdef')")
            harness.equal("abcde", result.output)
            harness.truthy(result.output_truncated)
        end
    },
    {
        name = "rejects invalid source and returns encoded tool results",
        fn = function()
            local tool = newTool()
            local result = tool:executeResult(12)
            harness.falsy(result.ok)
            harness.truthy(result.error:find("non%-empty string"))
            harness.equal("encoded-success", tool:execute("return true"))
        end
    },
    {
        name = "falls back when tool result JSON encoding fails",
        fn = function()
            local tool = newTool(100, function() return nil, "failed" end)
            harness.equal(
                '{"ok":false,"error":"Could not encode the Lua result."}',
                tool:execute("return true")
            )
        end
    },
    {
        name = "owns raw function-call argument decoding",
        fn = function()
            local tool = newTool()
            harness.equal("encoded-success", tool:handle({
                name = "execute_cc_lua",
                arguments = '{"code":"return 1"}'
            }))
            harness.equal("encoded-failure", tool:handle({
                name = "execute_cc_lua",
                arguments = "not-json"
            }))
        end
    }
}
