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

-- Simple JSON decoder using pattern matching
function M.decode(str)
    -- Remove whitespace and newlines for easier parsing
    str = str:gsub("%s+", " ")
    str = str:gsub("^ ", "")
    str = str:gsub(" $", "")

    -- Simple recursive descent parser
    local function parse_value(s, pos)
        -- Skip whitespace
        while s:sub(pos, pos):match("%s") do
            pos = pos + 1
        end

        local char = s:sub(pos, pos)

        -- Parse string
        if char == '"' then
            local endpos = pos + 1
            while s:sub(endpos, endpos) ~= '"' or s:sub(endpos-1, endpos-1) == '\\' do
                endpos = endpos + 1
            end
            return s:sub(pos+1, endpos-1), endpos + 1
        end

        -- Parse number
        if char:match("[%-0-9]") then
            local endpos = pos
            while s:sub(endpos, endpos):match("[0-9%.]") do
                endpos = endpos + 1
            end
            return tonumber(s:sub(pos, endpos-1)), endpos
        end

        -- Parse true/false/null
        if s:sub(pos, pos+3) == "true" then
            return true, pos + 4
        end
        if s:sub(pos, pos+4) == "false" then
            return false, pos + 5
        end
        if s:sub(pos, pos+3) == "null" then
            return nil, pos + 4
        end

        -- Parse object
        if char == '{' then
            local obj = {}
            pos = pos + 1
            while s:sub(pos, pos) ~= '}' do
                -- Skip whitespace and commas
                while s:sub(pos, pos):match("[%s,]") do
                    pos = pos + 1
                end
                if s:sub(pos, pos) == '}' then break end

                -- Parse key
                local key, newpos = parse_value(s, pos)
                pos = newpos

                -- Skip colon
                while s:sub(pos, pos):match("[%s:]") do
                    pos = pos + 1
                end

                -- Parse value
                local value
                value, pos = parse_value(s, pos)
                obj[key] = value
            end
            return obj, pos + 1
        end

        -- Parse array
        if char == '[' then
            local arr = {}
            pos = pos + 1
            while s:sub(pos, pos) ~= ']' do
                -- Skip whitespace and commas
                while s:sub(pos, pos):match("[%s,]") do
                    pos = pos + 1
                end
                if s:sub(pos, pos) == ']' then break end

                local value
                value, pos = parse_value(s, pos)
                table.insert(arr, value)
            end
            return arr, pos + 1
        end

        error("Unexpected character at position " .. pos .. ": " .. char)
    end

    local result, _ = parse_value(str, 1)
    return result
end

return M
