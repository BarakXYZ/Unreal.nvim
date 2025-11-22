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

-- Get absolute path
function M.get_absolute_path(path)
    if not path then
        return nil
    end

    -- If already absolute, return normalized
    if path:match("^/") or path:match("^%a:") then
        return M.normalize_path(path)
    end

    -- Get current directory and combine
    local pwd = io.popen("pwd"):read("*l")
    local abs_path = pwd .. "/" .. path
    return M.normalize_path(abs_path)
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

-- Parse .uproject file and extract engine association
function M.parse_uproject(uproject_path)
    if not M.file_exists(uproject_path) then
        return nil, "Project file not found: " .. uproject_path
    end

    local file = io.open(uproject_path, "r")
    if not file then
        return nil, "Cannot open project file"
    end

    local content = file:read("*a")
    file:close()

    local json = require("unreal.json")
    local success, uproject = pcall(json.decode, content)
    if not success then
        return nil, "Invalid JSON in project file"
    end

    return uproject
end

-- Get default engine path based on OS and version
function M.get_default_engine_path(engine_version)
    if not engine_version then
        return nil
    end

    -- Extract major.minor version (e.g., "5.7" from "5.7" or "5.3.2")
    local major, minor = engine_version:match("^(%d+)%.(%d+)")
    if not major or not minor then
        return nil, "Invalid engine version format: " .. engine_version
    end

    local version_str = major .. "." .. minor
    local engine_path

    if M.is_windows then
        engine_path = "C:/Program Files/Epic Games/UE_" .. version_str
    elseif M.is_macos then
        engine_path = "/Users/Shared/Epic Games/UE_" .. version_str
    else -- Linux
        -- Linux typically uses custom builds, try common locations
        local home = os.getenv("HOME") or "~"
        engine_path = home .. "/UnrealEngine-" .. version_str
    end

    return engine_path
end

-- Auto-detect engine path and version from .uproject
function M.detect_engine_info(uproject_path)
    local uproject, err = M.parse_uproject(uproject_path)
    if not uproject then
        return nil, nil, err
    end

    local engine_association = uproject.EngineAssociation
    if not engine_association then
        return nil, nil, "No EngineAssociation found in project file"
    end

    -- Check if it's a version number (e.g., "5.7") or a GUID/custom path
    local is_version = engine_association:match("^%d+%.%d+")
    if not is_version then
        return nil, nil, "EngineAssociation is a custom engine (GUID or path). Please specify --engine manually."
    end

    local engine_path = M.get_default_engine_path(engine_association)
    if not engine_path then
        return nil, nil, "Could not determine default engine path"
    end

    -- Extract numeric version (keep full version like 5.7)
    local major, minor = engine_association:match("^(%d+)%.(%d+)")
    local engine_ver = tonumber(major .. "." .. minor)

    return engine_path, engine_ver, nil
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
            local compiler_pattern = M.is_windows and ":.+%.exe\\\"" or ":.+clang%+%+"
            if verbose and not shouldSkipFile then
                print("  Pattern: " .. compiler_pattern)
                print("  Line: " .. line:sub(1, 150))
            end
            local startCmd, endCmd = line:find(compiler_pattern)
            if verbose and not shouldSkipFile then
                print("  Pattern match: startCmd=" .. tostring(startCmd) .. ", endCmd=" .. tostring(endCmd))
            end

            if startCmd and endCmd then
                local command = line:sub(startCmd + 1, endCmd)
                local commandAdded = false

                if verbose then
                    print("  Command line: " .. line)
                end

                -- Check for @ rsp reference
                i,j = line:find("%@\\\"")
                if verbose then
                    print("  Looking for @ pattern, result: i=" .. tostring(i) .. ", j=" .. tostring(j))
                end
                if i then
                    local _,endpos = line:find("\\\"", j)
                    local rsppath = line:sub(j+1, endpos-2)

                    if verbose then
                        print("  Found RSP reference: " .. rsppath)
                        print("  File exists: " .. tostring(M.file_exists(rsppath)))
                        print("  Should skip: " .. tostring(shouldSkipFile))
                    end

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

                        if verbose then
                            print("  New RSP path: " .. newrsppath)
                        end

                        -- Process RSP file
                        if not shouldSkipFile then
                            if verbose then
                                print("  Processing RSP file...")
                            end
                            local rspcontent, err = M.extract_rsp(rsppath, engine_dir)
                            if rspcontent then
                                if verbose then
                                    print("  RSP content extracted, length: " .. #rspcontent)
                                end
                                local rspfile = io.open(newrsppath, "w")
                                if rspfile then
                                    rspfile:write(rspcontent)
                                    rspfile:close()
                                    files_processed = files_processed + 1
                                    if verbose then
                                        print("  RSP file written successfully!")
                                    end
                                else
                                    local msg = "Cannot write RSP: " .. newrsppath
                                    if verbose then
                                        print("  ERROR: " .. msg)
                                    end
                                    table.insert(errors, msg)
                                end
                            else
                                local msg = "RSP extract failed: " .. (err or "unknown")
                                if verbose then
                                    print("  ERROR: " .. msg)
                                end
                                table.insert(errors, msg)
                            end
                        else
                            if verbose then
                                print("  Skipping RSP processing (engine file)")
                            end
                        end

                        table.insert(contentLines, string.format("\t\t\"command\": %s @\\\"" ..newrsppath .."\\\"\",\n", command))
                        commandAdded = true
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
                        commandAdded = true
                    end
                end

                -- If we couldn't process the command, add original line
                if not commandAdded then
                    table.insert(contentLines, line .. "\n")
                end
            else
                -- No valid compiler pattern found, keep original
                table.insert(contentLines, line .. "\n")
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

    -- Use opts.engine if provided, otherwise use config, otherwise auto-detect
    local engine_dir = opts.engine or config.EngineDir
    if not engine_dir or engine_dir == "" then
        -- Try auto-detection as last resort
        local detected_path, detected_ver, detect_err = M.detect_engine_info(uproject_path)
        if detected_path then
            engine_dir = detected_path
            result.auto_detected = true
            result.detected_engine = detected_path
            if opts.verbose then
                print("Auto-detected engine: " .. detected_path)
            end
        else
            result.message = "Engine directory not specified in config and auto-detection failed: " .. (detect_err or "unknown error")
            return result
        end
    end

    -- Get target index
    local target_idx = opts.target or config.DefaultTarget or 1
    local target = config.Targets[target_idx]
    if not target then
        result.message = "Invalid target index: " .. tostring(target_idx)
        return result
    end

    -- Ensure absolute paths for UnrealBuildTool
    project_dir = M.get_absolute_path(project_dir)
    uproject_path = M.get_absolute_path(uproject_path)

    if opts.verbose then
        print("Project: " .. project_name)
        print("Project Dir: " .. project_dir)
        print("Engine: " .. engine_dir)
        print("Target: " .. target.TargetName .. " " .. target.Configuration)
    end

    -- Build UnrealBuildTool command
    local ubt_path = M.get_ubt_path(engine_dir, config.EngineVer)
    local editor_flag = target.withEditor and "-editor" or ""

    local ubt_cmd = string.format('"%s" -mode=GenerateClangDatabase -project="%s" -game -engine %s %s %s %s %s',
        ubt_path,
        uproject_path,
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

    -- Auto-detect engine path and version if not provided
    local engine_path = opts.engine
    local engine_ver = 5.0

    if not engine_path then
        local detected_path, detected_ver, err = M.detect_engine_info(uproject_path)
        if detected_path then
            engine_path = detected_path
            engine_ver = detected_ver
            result.auto_detected = true
            result.detected_engine = engine_path
            result.detected_version = engine_ver
        else
            result.message = "Could not auto-detect engine: " .. (err or "unknown error") .. ". Please specify --engine manually."
            return result
        end
    else
        -- Detect engine version from path if provided
        local ver_match = engine_path:match("UE[_%-]?(%d+)%.(%d+)")
        if ver_match then
            engine_ver = tonumber(ver_match)
        end
    end

    -- Create config content
    local json = require("unreal.json")
    local config = {
        version = "0.0.2",
        _comment = "Generated by unreal-codegen init",
        EngineDir = engine_path,
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
    local result = {
        success = false,
        message = "",
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

    -- Get engine dir (with auto-detection fallback)
    local engine_dir = opts.engine or config.EngineDir
    if not engine_dir or engine_dir == "" then
        local detected_path, _, detect_err = M.detect_engine_info(uproject_path)
        if detected_path then
            engine_dir = detected_path
        else
            result.message = "Engine directory not specified: " .. (detect_err or "unknown error")
            return result
        end
    end

    -- Get target
    local target_idx = opts.target or config.DefaultTarget or 1
    local target = config.Targets[target_idx]
    if not target then
        result.message = "Invalid target index: " .. tostring(target_idx)
        return result
    end

    if opts.verbose then
        print("Building " .. project_name)
        print("Target: " .. target.TargetName .. " " .. target.Configuration)
        print("Platform: " .. target.PlatformName)
    end

    -- Construct build command
    local build_script = M.get_build_script_path(engine_dir)
    local target_suffix = target.withEditor and "Editor" or ""
    local project_path = project_dir .. "/" .. project_name .. ".uproject"

    local build_cmd = string.format('"%s" %s%s %s %s "%s" -waitmutex',
        build_script,
        target.TargetName,
        target_suffix,
        target.PlatformName,
        target.Configuration,
        project_path
    )

    result.command = build_cmd
    result.target = target.TargetName .. target_suffix
    result.configuration = target.Configuration
    result.platform = target.PlatformName

    -- If dry-run, just return the command without executing
    if opts.dry_run then
        result.success = true
        result.message = "Build command constructed (dry-run)"
        return result
    end

    if opts.verbose then
        print("Executing: " .. build_cmd)
    end

    -- Execute build
    local exit_code = os.execute(build_cmd)

    if exit_code == 0 or exit_code == true then
        result.success = true
        result.message = "Build completed successfully"
    else
        result.message = "Build failed with exit code: " .. tostring(exit_code)
    end

    return result
end

-- Run project
function M.run_project(opts)
    local result = {
        success = false,
        message = "",
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

    -- Get engine dir (with auto-detection fallback)
    local engine_dir = opts.engine or config.EngineDir
    if not engine_dir or engine_dir == "" then
        local detected_path, _, detect_err = M.detect_engine_info(uproject_path)
        if detected_path then
            engine_dir = detected_path
        else
            result.message = "Engine directory not specified: " .. (detect_err or "unknown error")
            return result
        end
    end

    -- Get target
    local target_idx = opts.target or config.DefaultTarget or 1
    local target = config.Targets[target_idx]
    if not target then
        result.message = "Invalid target index: " .. tostring(target_idx)
        return result
    end

    if opts.verbose then
        print("Running " .. project_name)
        print("Target: " .. target.TargetName .. " " .. target.Configuration)
    end

    -- Construct executable path
    local editor_path
    local project_path = project_dir .. "/" .. project_name .. ".uproject"
    local run_cmd

    if target.withEditor then
        -- Running with editor
        local editor_suffix = ""
        if target.Configuration ~= "Development" then
            editor_suffix = "-" .. target.PlatformName .. "-" .. target.Configuration
        end

        if M.is_windows then
            editor_path = engine_dir .. "/Engine/Binaries/Win64/UnrealEditor" .. editor_suffix .. ".exe"
        elseif M.is_macos then
            editor_path = engine_dir .. "/Engine/Binaries/Mac/UnrealEditor" .. editor_suffix .. ".app/Contents/MacOS/UnrealEditor" .. editor_suffix
        else
            editor_path = engine_dir .. "/Engine/Binaries/Linux/UnrealEditor" .. editor_suffix
        end

        run_cmd = string.format('"%s" "%s" -skipcompile', editor_path, project_path)
    else
        -- Running standalone game
        local exe_suffix = ""
        if target.Configuration ~= "Development" then
            exe_suffix = "-" .. target.PlatformName .. "-" .. target.Configuration
        end

        if M.is_windows then
            editor_path = project_dir .. "/Binaries/Win64/" .. project_name .. exe_suffix .. ".exe"
        elseif M.is_macos then
            editor_path = project_dir .. "/Binaries/Mac/" .. project_name .. exe_suffix .. ".app/Contents/MacOS/" .. project_name .. exe_suffix
        else
            editor_path = project_dir .. "/Binaries/Linux/" .. project_name .. exe_suffix
        end

        run_cmd = string.format('"%s"', editor_path)
    end

    result.command = run_cmd
    result.target = target.TargetName
    result.configuration = target.Configuration
    result.with_editor = target.withEditor

    -- If dry-run, just return the command without executing
    if opts.dry_run then
        result.success = true
        result.message = "Run command constructed (dry-run)"
        return result
    end

    if opts.verbose then
        print("Executing: " .. run_cmd)
    end

    -- Execute command
    local exit_code = os.execute(run_cmd)

    if exit_code == 0 or exit_code == true then
        result.success = true
        if target.withEditor then
            result.message = "Editor started successfully"
        else
            result.message = "Game started successfully"
        end
    else
        result.message = "Failed to start with exit code: " .. tostring(exit_code)
    end

    return result
end

return M
