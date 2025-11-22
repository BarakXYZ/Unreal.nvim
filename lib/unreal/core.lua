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

-- Escape path for command line
function M.escape_path(path)
    path = path:gsub("\\\\", "/")
    path = path:gsub("\\", "/")
    path = path:gsub("\"", "\\\"")
    return path
end

-- Check if file is from engine
function M.is_engine_file(file_path, engine_dir)
    local normalized_path = M.normalize_path(file_path)
    local normalized_engine = M.normalize_path(engine_dir)
    return normalized_path:find(normalized_engine, 1, true) ~= nil
end

-- Ensure directory exists
function M.ensure_dir(path)
    local cmd
    if M.is_windows then
        cmd = 'mkdir "' .. path:gsub("/", "\\") .. '" 2>nul'
    else
        cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
    end
    os.execute(cmd)
end

-- Process compile_commands.json and generate RSP files
function M.process_compile_commands(input_json, output_dir, engine_dir, skip_engine, verbose)
    local contentLines = {}
    local files_processed = 0
    local errors = {}

    -- Ensure output directory exists
    M.ensure_dir(output_dir)

    local currentFilename = ""
    local file = io.open(input_json, "r")
    if not file then
        return nil, "Cannot open compile_commands.json: " .. input_json
    end

    for line in file:lines() do
        local i,j = line:find("\"command\":")
        if i then
            local isEngineFile = M.is_engine_file(currentFilename, engine_dir)
            local shouldSkipFile = isEngineFile and skip_engine

            if verbose and not shouldSkipFile then
                print("Processing: " .. currentFilename)
            end

            -- Extract compiler command (with or without .exe extension)
            local compiler_pattern = M.is_windows and ":.+%.exe\\\"" or ":.+clang%+%+\\\""
            local startCmd, endCmd = line:find(compiler_pattern)

            if startCmd and endCmd then
                local command = line:sub(startCmd + 1, endCmd)

                -- Check for @ rsp reference
                i,j = line:find("%@\\\"")
                if i then
                    local _,endpos = line:find("\\\"", j)
                    local rsppath = line:sub(j+1, endpos-2)

                    if rsppath and M.file_exists(rsppath) then
                        -- Use platform-specific rsp extension
                        local newrsppath
                        if M.is_windows then
                            newrsppath = rsppath .. ".cl.rsp"
                        else
                            if rsppath:match("%.rsp$") then
                                newrsppath = rsppath .. ".clang.rsp"
                            else
                                newrsppath = rsppath .. ".rsp"
                            end
                        end

                        -- Process RSP file
                        if not shouldSkipFile then
                            local rspcontent, err = M.extract_rsp(rsppath, engine_dir)
                            if rspcontent then
                                local rspfile = io.open(newrsppath, "w")
                                if rspfile then
                                    rspfile:write(rspcontent)
                                    rspfile:close()
                                    files_processed = files_processed + 1
                                else
                                    table.insert(errors, "Cannot write RSP: " .. newrsppath)
                                end
                            else
                                table.insert(errors, "RSP extract failed: " .. (err or "unknown"))
                            end
                        end

                        table.insert(contentLines, string.format("\t\t\"command\": %s @\\\"" ..newrsppath .."\\\"\",\n", command))
                    end
                else
                    -- No RSP, create one
                    local exe_pattern = M.is_windows and "%.exe\\\"" or "clang%+%+\\\""
                    local _, endArgsPos = line:find(exe_pattern)
                    if endArgsPos then
                        local args = line:sub(endArgsPos+1, -1)
                        local rspfilename = currentFilename:gsub("\\\\","/")
                        rspfilename = rspfilename:gsub(":","")
                        rspfilename = rspfilename:gsub("\"","")
                        rspfilename = rspfilename:gsub(",","")
                        rspfilename = rspfilename:gsub("\\","/")
                        rspfilename = rspfilename:gsub("/","_")
                        rspfilename = rspfilename .. ".rsp"
                        local rspfilepath = output_dir .. rspfilename

                        if not shouldSkipFile then
                            -- Process and write args
                            args = args:gsub("-D\\\"", "-D\"")
                            args = args:gsub("-I\\\"", "-I\"")
                            args = args:gsub("\\\"\\\"\\\"", "__3Q_PLACEHOLDER__")
                            args = args:gsub("\\\"\\\"", "\\\"\"")
                            args = args:gsub("\\\" ", "\" ")
                            args = args:gsub("\\\\", "/")
                            args = args:gsub(",%s*$", "")
                            args = args:gsub("\" ", "\"\n")
                            args = args:gsub("__3Q_PLACEHOLDER__", "\\\"\\\"\\\"")

                            local rspfile = io.open(rspfilepath, "w")
                            if rspfile then
                                rspfile:write(args)
                                rspfile:close()
                                files_processed = files_processed + 1
                            end
                        end

                        table.insert(contentLines, string.format("\t\t\"command\": %s @\\\"" .. M.escape_path(rspfilepath) .."\\\""
                            .. " ".. M.escape_path(currentFilename) .."\",\n", command))
                    end
                end
            end
        else
            local fbegin, fend = line:find("\"file\": ")
            if fbegin then
                local comma_pos = line:find(",", fend)
                if comma_pos then
                    currentFilename = line:sub(fend+2, comma_pos-2)
                end
            end
            table.insert(contentLines, line .. "\n")
        end
    end

    file:close()
    return table.concat(contentLines), files_processed, errors
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

    -- Use opts.engine if provided, otherwise use config
    local engine_dir = opts.engine or config.EngineDir
    if not engine_dir or engine_dir == "" then
        result.message = "Engine directory not specified"
        return result
    end

    -- Get target index
    local target_idx = opts.target or config.DefaultTarget or 1
    local target = config.Targets[target_idx]
    if not target then
        result.message = "Invalid target index: " .. tostring(target_idx)
        return result
    end

    if opts.verbose then
        print("Project: " .. project_name)
        print("Engine: " .. engine_dir)
        print("Target: " .. target.TargetName .. " " .. target.Configuration)
    end

    -- Build UnrealBuildTool command
    local ubt_path = M.get_ubt_path(engine_dir, config.EngineVer)
    local editor_flag = target.withEditor and "-editor" or ""

    local ubt_cmd = string.format('"%s" -mode=GenerateClangDatabase -project="%s/%s.uproject" -game -engine %s %s %s %s %s',
        ubt_path,
        project_dir,
        project_name,
        target.UbtExtraFlags or "",
        editor_flag,
        target.TargetName,
        target.Configuration,
        target.PlatformName
    )

    if opts.verbose then
        print("Running UnrealBuildTool...")
        print(ubt_cmd)
    end

    -- Execute UnrealBuildTool
    local ubt_result = os.execute(ubt_cmd)
    if not ubt_result then
        result.message = "UnrealBuildTool execution failed"
        return result
    end

    -- Process compile_commands.json
    local input_json = engine_dir .. "/compile_commands.json"
    local output_dir = string.format("%s/Intermediate/clangRsp/%s/%s/",
        project_dir,
        target.PlatformName,
        target.Configuration
    )

    if opts.verbose then
        print("Processing compile_commands.json...")
    end

    local processed, files_count, proc_errors = M.process_compile_commands(
        input_json,
        output_dir,
        engine_dir,
        not opts.with_engine,
        opts.verbose
    )

    if not processed then
        result.message = files_count or "Failed to process compile_commands.json"
        return result
    end

    -- Write output
    local output_json = project_dir .. "/compile_commands.json"
    local outfile = io.open(output_json, "w")
    if not outfile then
        result.message = "Cannot write output: " .. output_json
        return result
    end

    outfile:write(processed)
    outfile:close()

    result.success = true
    result.message = "Generation completed successfully"
    result.files_processed = files_count
    result.errors = proc_errors
    result.output_file = output_json

    return result
end

-- Initialize project with config file
function M.init_project(opts)
    local result = {
        success = false,
        message = "",
    }

    -- Validate inputs
    if not opts.project then
        result.message = "Project path is required"
        return result
    end

    if not opts.engine then
        result.message = "Engine path is required (use --engine)"
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

    -- Check if config already exists
    local config_path = project_dir .. "/UnrealNvim.json"
    if M.file_exists(config_path) then
        result.message = "Config already exists: " .. config_path
        result.warning = true
        return result
    end

    -- Detect engine version from path (rough estimate)
    local engine_ver = 5.0
    local ver_match = opts.engine:match("UE[_%-]?(%d+)%.(%d+)")
    if ver_match then
        engine_ver = tonumber(ver_match)
    end

    -- Create config content
    local json = require("unreal.json")
    local config = {
        version = "0.0.2",
        _comment = "Generated by unreal-codegen init",
        EngineDir = opts.engine,
        EngineVer = engine_ver,
        DefaultTarget = 1,
        Targets = {
            {
                TargetName = project_name,
                Configuration = "DebugGame",
                withEditor = true,
                UbtExtraFlags = "",
                PlatformName = M.platform_name
            },
            {
                TargetName = project_name,
                Configuration = "Development",
                withEditor = true,
                UbtExtraFlags = "",
                PlatformName = M.platform_name
            },
            {
                TargetName = project_name,
                Configuration = "Shipping",
                withEditor = true,
                UbtExtraFlags = "",
                PlatformName = M.platform_name
            }
        }
    }

    -- Write config file
    local config_json = json.encode(config)

    -- Format JSON nicely (add indentation manually for readability)
    config_json = config_json:gsub(',', ',\n    ')
    config_json = config_json:gsub('{', '{\n    ')
    config_json = config_json:gsub('}', '\n}')
    config_json = config_json:gsub('%[', '[\n        ')
    config_json = config_json:gsub('%]', '\n    ]')

    local file = io.open(config_path, "w")
    if not file then
        result.message = "Cannot write config file: " .. config_path
        return result
    end

    file:write(config_json)
    file:close()

    result.success = true
    result.message = "Config created successfully"
    result.config_path = config_path
    result.project = project_name
    result.platform = M.platform_name

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
