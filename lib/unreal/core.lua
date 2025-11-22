--[[
Unreal.nvim Core Module
Platform-independent core logic for Unreal Engine integration.
]]

local M = {}

-- Platform detection
local path_separator = package.config:sub(1,1)
M.is_windows = path_separator == '\\'
M.is_macos = (os.getenv("HOME") and io.popen("uname"):read("*l") == "Darwin") or false
M.is_linux = (path_separator == '/' and not M.is_macos) or false

M.platform_name = "Win64"
if M.is_macos then
    M.platform_name = "Mac"
elseif M.is_linux then
    M.platform_name = "Linux"
end

-- Get platform name
function M.get_platform()
    return M.platform_name
end

-- Path normalization
function M.normalize_path(path)
    if not path then
        return nil
    end
    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("//+", "/")
    return normalized
end

-- Check if file exists
function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        io.close(f)
        return true
    end
    return false
end

-- Get UnrealBuildTool path
function M.get_ubt_path(engine_dir, engine_ver)
    local ubt_name = M.is_windows and "UnrealBuildTool.exe" or "UnrealBuildTool"
    local ubt_path

    if engine_ver and engine_ver < 5.0 then
        ubt_path = engine_dir .. "/Engine/Binaries/DotNET/" .. ubt_name
    else
        ubt_path = engine_dir .. "/Engine/Binaries/DotNET/UnrealBuildTool/" .. ubt_name
    end

    return ubt_path
end

-- Get build script path
function M.get_build_script_path(engine_dir)
    local script_path

    if M.is_windows then
        script_path = engine_dir .. "/Engine/Build/BatchFiles/Build.bat"
    elseif M.is_macos then
        script_path = engine_dir .. "/Engine/Build/BatchFiles/Mac/Build.sh"
    else
        script_path = engine_dir .. "/Engine/Build/BatchFiles/Linux/Build.sh"
    end

    return script_path
end

-- Find .uproject file
function M.find_uproject(start_dir)
    -- Look in current directory
    local handle = io.popen('find "' .. start_dir .. '" -maxdepth 1 -name "*.uproject" 2>/dev/null')
    if handle then
        local result = handle:read("*a")
        handle:close()

        for line in result:gmatch("[^\r\n]+") do
            if line:match("%.uproject$") then
                return line
            end
        end
    end

    return nil
end

-- Load config file
function M.load_config(project_dir)
    local config_path = project_dir .. "/UnrealNvim.json"

    if not M.file_exists(config_path) then
        return nil, "Config file not found: " .. config_path
    end

    local file = io.open(config_path, "r")
    if not file then
        return nil, "Cannot open config file"
    end

    local content = file:read("*a")
    file:close()

    -- Simple JSON decode (we'll improve this later)
    local json = require("unreal.json")
    local success, config = pcall(json.decode, content)
    if not success then
        return nil, "Invalid JSON in config file: " .. tostring(config)
    end

    return config
end

-- Extract and convert RSP file
function M.extract_rsp(rsp_path, engine_dir)
    local extra_includes = {
        "Engine/Source/Runtime/CoreUObject/Public/UObject/ObjectMacros.h",
        "Engine/Source/Runtime/Core/Public/Misc/EnumRange.h",
        "Engine/Source/Runtime/Engine/Public/EngineMinimal.h",
    }

    if not M.file_exists(rsp_path) then
        return nil, "RSP file doesn't exist: " .. rsp_path
    end

    local lines = {}
    local line_num = 0

    for line in io.lines(rsp_path) do
        -- On Unix systems, convert MSVC flags to clang format
        if not M.is_windows then
            line = line:gsub("^/FI", "-include ")
            line = line:gsub("^/I ", "-I ")
            line = line:gsub("^/D", "-D")
            line = line:gsub("^/W", "-W")
        end

        lines[line_num] = line .. "\n"
        line_num = line_num + 1
    end

    -- Add extra includes with platform-specific syntax
    for _, incl in ipairs(extra_includes) do
        if M.is_windows then
            lines[line_num] = "\n/FI\"" .. engine_dir .. "/" .. incl .. "\""
        else
            lines[line_num] = "\n-include \"" .. engine_dir .. "/" .. incl .. "\""
        end
        line_num = line_num + 1
    end

    return table.concat(lines)
end

-- Main command generation function
function M.generate_commands(opts)
    local result = {
        success = false,
        message = "",
        files_processed = 0,
        errors = {},
    }

    -- Validate inputs
    if not opts.project then
        result.message = "Project path is required"
        return result
    end

    -- Find .uproject file
    local uproject_path = opts.project
    if not uproject_path:match("%.uproject$") then
        uproject_path = M.find_uproject(opts.project)
        if not uproject_path then
            result.message = "Could not find .uproject file in: " .. opts.project
            return result
        end
    end

    local project_dir = uproject_path:match("(.+)/[^/]+%.uproject$")
    local project_name = uproject_path:match("/([^/]+)%.uproject$")

    -- Load config
    local config, err = M.load_config(project_dir)
    if not config then
        result.message = err or "Failed to load config"
        return result
    end

    -- TODO: Implement full generation logic
    -- For now, return structure that shows it's working
    result.success = true
    result.message = "Generation initiated (implementation in progress)"
    result.project = project_name
    result.project_dir = project_dir
    result.config_loaded = true

    return result
end

-- Build project
function M.build_project(opts)
    return {
        success = false,
        message = "Build command not yet implemented in standalone CLI"
    }
end

-- Run project
function M.run_project(opts)
    return {
        success = false,
        message = "Run command not yet implemented in standalone CLI"
    }
end

return M
