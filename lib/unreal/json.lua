-- Simple JSON encoder/decoder
-- Uses standard Lua patterns for basic JSON operations

local M = {}

function M.encode(obj)
    local json_type = type(obj)

    if json_type == "string" then
        return '"' .. obj:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif json_type == "number" or json_type == "boolean" then
        return tostring(obj)
    elseif json_type == "table" then
        local is_array = true
        local max_index = 0

        -- Check if it's an array
        for k, v in pairs(obj) do
            if type(k) ~= "number" then
                is_array = false
                break
            end
            max_index = math.max(max_index, k)
        end

        if is_array and max_index == #obj then
            -- Encode as array
            local result = {}
            for i, v in ipairs(obj) do
                table.insert(result, M.encode(v))
            end
            return "[" .. table.concat(result, ",") .. "]"
        else
            -- Encode as object
            local result = {}
            for k, v in pairs(obj) do
                table.insert(result, M.encode(tostring(k)) .. ":" .. M.encode(v))
            end
            return "{" .. table.concat(result, ",") .. "}"
        end
    elseif obj == nil then
        return "null"
    else
        error("Cannot encode type: " .. json_type)
    end
end

function M.decode(str)
    -- Try loading with loadstring (Lua 5.1) or load (Lua 5.2+)
    local loadfn = loadstring or load

    -- Convert JSON to Lua table notation
    str = str:gsub("null", "nil")
    str = str:gsub("true", "true")
    str = str:gsub("false", "false")

    local fn, err = loadfn("return " .. str)
    if not fn then
        error("JSON decode error: " .. tostring(err))
    end

    return fn()
end

return M
