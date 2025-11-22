
local kConfigFileName = "UnrealNvim.json"
local kCurrentVersion = "0.0.2"

local kLogLevel_Error = 1
local kLogLevel_Warning = 2
local kLogLevel_Log = 3
local kLogLevel_Verbose = 4
local kLogLevel_VeryVerbose = 5

local TaskState =
{
    scheduled = "scheduled",
    inprogress = "inprogress",
    completed = "completed"
}

-- Platform detection
local path_separator = package.config:sub(1,1)
local is_windows = path_separator == '\\'
local is_macos = vim.fn.has('mac') == 1 or vim.fn.has('macunix') == 1
local is_linux = vim.fn.has('unix') == 1 and not is_macos

-- Platform-specific constants
local platform_name = "Win64"
if is_macos then
    platform_name = "Mac"
elseif is_linux then
    platform_name = "Linux"
end

-- fix false diagnostic about vim
if not vim then
    vim = {}
end


local logFilePath = vim.fn.stdpath("data") .. '/unrealnvim.log'

local function logWithVerbosity(verbosity, message)
    if not vim.g.unrealnvim_debug then return end
    local cfgVerbosity = kLogLevel_Log
    if vim.g.unrealnvim_loglevel then
        cfgVerbosity = vim.g.unrealnvim_loglevel
    end
    if verbosity > cfgVerbosity then return end

    local file = nil
    if Commands.logFile then
        file = Commands.logFile
    else
        file = io.open(logFilePath, "a")
    end

    if file then
        local time = os.date('%m/%d/%y %H:%M:%S');
        file:write("["..time .. "]["..verbosity.."]: " .. message .. '\n')
    end
end

local function log(message)
    if not message then
        logWithVerbosity(kLogLevel_Error, "message was nill")
        return
    end

    logWithVerbosity(kLogLevel_Log, message)
end

local function logError(message)
    logWithVerbosity(kLogLevel_Error, message)
end

local function PrintAndLogMessage(a,b)
    if a and b then
        log(tostring(a)..tostring(b))
    elseif a then
        log(tostring(a))
    end
end

local function PrintAndLogError(a,b)
    if a and b then
        local msg = "Error: "..tostring(a)..tostring(b)
        print(msg)
        log(msg)
    elseif a then
        local msg = "Error: ".. tostring(a)
        print(msg)
        log(msg)
    end
end

local function MakeUnixPath(win_path)
    if not win_path then
        logError("MakeUnixPath received a nil argument")
        return;
    end
    -- Convert backslashes to forward slashes
    local unix_path = win_path:gsub("\\", "/")

    -- Remove duplicate slashes
    unix_path = unix_path:gsub("//+", "/")

    return unix_path
end

-- Cross-platform path normalization
local function NormalizePath(path)
    if not path then
        logError("NormalizePath received a nil argument")
        return nil
    end

    -- Always use forward slashes internally for consistency
    local normalized = path:gsub("\\", "/")

    -- Remove duplicate slashes
    normalized = normalized:gsub("//+", "/")

    return normalized
end

-- Get platform-appropriate path separator for shell commands
local function GetPathSeparator()
    return path_separator
end

-- Get platform-specific UnrealBuildTool path
local function GetUnrealBuildToolPath(engineDir, engineVer)
    local ubtName = is_windows and "UnrealBuildTool.exe" or "UnrealBuildTool"
    local ubtPath

    if engineVer and engineVer < 5.0 then
        ubtPath = engineDir .. "/Engine/Binaries/DotNET/" .. ubtName
    else
        ubtPath = engineDir .. "/Engine/Binaries/DotNET/UnrealBuildTool/" .. ubtName
    end

    return "\"" .. ubtPath .. "\""
end

-- Get platform-specific build script path
local function GetBuildScriptPath(engineDir)
    local scriptPath

    if is_windows then
        scriptPath = engineDir .. "/Engine/Build/BatchFiles/Build.bat"
    elseif is_macos then
        scriptPath = engineDir .. "/Engine/Build/BatchFiles/Mac/Build.sh"
    else -- Linux
        scriptPath = engineDir .. "/Engine/Build/BatchFiles/Linux/Build.sh"
    end

    return "\"" .. scriptPath .. "\""
end

-- Get platform-specific editor executable path
local function GetEditorPath(engineDir, projectDir, projectName, editorSuffix)
    local editorPath

    if is_windows then
        if projectDir and projectName then
            editorPath = projectDir .. "/Binaries/Win64/" .. projectName .. editorSuffix .. ".exe"
        else
            editorPath = engineDir .. "/Engine/Binaries/Win64/UnrealEditor" .. editorSuffix .. ".exe"
        end
    elseif is_macos then
        if projectDir and projectName then
            editorPath = projectDir .. "/Binaries/Mac/" .. projectName .. editorSuffix .. ".app/Contents/MacOS/" .. projectName .. editorSuffix
        else
            editorPath = engineDir .. "/Engine/Binaries/Mac/UnrealEditor" .. editorSuffix .. ".app/Contents/MacOS/UnrealEditor" .. editorSuffix
        end
    else -- Linux
        if projectDir and projectName then
            editorPath = projectDir .. "/Binaries/Linux/" .. projectName .. editorSuffix
        else
            editorPath = engineDir .. "/Engine/Binaries/Linux/UnrealEditor" .. editorSuffix
        end
    end

    return "\"" .. editorPath .. "\""
end

-- Get path to unreal-codegen CLI tool
local function GetCodegenCLIPath()
    -- The CLI is in bin/unreal-codegen relative to the plugin root
    local plugin_root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h")
    local cli_path = plugin_root .. "/bin/unreal-codegen"
    return cli_path
end

-- Call the CLI tool and return parsed JSON result
local function CallCLI(command, args)
    local cli_path = GetCodegenCLIPath()
    local cmd = cli_path .. " " .. command

    -- Add arguments
    for key, value in pairs(args or {}) do
        if type(value) == "boolean" then
            if value then
                cmd = cmd .. " --" .. key
            end
        else
            cmd = cmd .. " --" .. key .. " \"" .. tostring(value) .. "\""
        end
    end

    PrintAndLogMessage("Calling CLI: " .. cmd)

    -- Execute and capture output
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        return nil, "Failed to execute CLI command"
    end

    local output = handle:read("*a")
    handle:close()

    -- Parse JSON output
    local success, result = pcall(vim.fn.json_decode, output)
    if not success then
        return nil, "Failed to parse CLI output: " .. output
    end

    return result
end

local function FuncBind(func, data)
    return function()
        func(data)
    end
end

if not vim.g.unrealnvim_loaded then
    Commands = {}

    CurrentGenData =
    {
        config = {},
        target = nil,
        prjName = nil,
        targetNameSuffix = nil,
        prjDir = nil,
        tasks = {},
        currentTask = "",
        ubtPath = "",
        ueBuildBat = "",
        projectPath = "",
        logFile = nil
    }
    -- clear the log
    CurrentGenData.logFile = io.open(logFilePath, "w")

    if CurrentGenData.logFile then
        CurrentGenData.logFile:write("")
        CurrentGenData.logFile:close()

        CurrentGenData.logFile = io.open(logFilePath, "a")
    end
    vim.g.unrealnvim_loaded = true
end

Commands.LogLevel_Error = kLogLevel_Error
Commands.LogLevel_Warning = kLogLevel_Warning
Commands.LogLevel_Log = kLogLevel_Log
Commands.LogLevel_Verbose = kLogLevel_Verbose
Commands.LogLevel_VeryVerbose = kLogLevel_VeryVerbose

function Commands.Log(msg)
    PrintAndLogError(msg)
end

Commands.onStatusUpdate = function()
end

function Commands:Inspect(objToInspect)
    if not vim.g.unrealnvim_debug then return end
    if not objToInspect then
        log(objToInspect)
        return
    end

    if not self._inspect then
        local inspect_path = vim.fn.stdpath("data") .. "/site/pack/packer/start/inspect.lua/inspect.lua"
        if Commands._inspect == nil then
            return
        end
        self._inspect = loadfile(inspect_path)(Commands._inspect)
        if  self._inspect then
            log("Inspect loaded.")
        else
            logError("Inspect failed to load from path" .. inspect_path)
            return
        end
        if self._inspect.inspect then
            log("inspect method exists")
        else
            logError("inspect method doesn't exist")
            return
        end
    end
    return self._inspect.inspect(objToInspect)
end

function SplitString(str)
    -- Split a string into lines
    local lines = {}
    for line in string.gmatch(str, "[^\r\n]+") do
        table.insert(lines, line)
    end
    return lines
end

function Commands._CreateConfigFile(configFilePath, projectName)
    -- Get project directory from config file path
    local projectDir = configFilePath:match("(.+)/[^/]+$")

    -- Call CLI to create config with auto-detection
    local result = CallCLI("init", { project = projectDir })

    if not result or not result.success then
        local error_msg = result and result.message or "Failed to create config"
        PrintAndLogError("CLI init failed: " .. error_msg)

        -- If auto-detection failed, inform the user
        if error_msg:match("auto%-detect") then
            PrintAndLogMessage("Could not auto-detect engine. Please run with --engine manually or check your .uproject file.")
        end
        return
    end

    -- Log success and auto-detection info
    if result.auto_detected then
        PrintAndLogMessage("Config created with auto-detected engine:")
        PrintAndLogMessage("  Engine: " .. (result.detected_engine or "unknown"))
        PrintAndLogMessage("  Version: " .. (result.detected_version or "unknown"))
    else
        PrintAndLogMessage("Config created successfully")
    end

    -- Open the config file for viewing/editing
    vim.cmd('new ' .. configFilePath)
    vim.cmd('setlocal buftype=')
    vim.cmd('edit')
end

function Commands._EnsureConfigFile(projectRootDir, projectName)
    local configFilePath = projectRootDir.."/".. kConfigFileName
    local configFile = io.open(configFilePath, "r")


    if (not configFile) then
        Commands._CreateConfigFile(configFilePath, projectName)
        PrintAndLogMessage("created config file")
        return nil
    end

    local content = configFile:read("*all")
    configFile:close()

    local data = vim.fn.json_decode(content)
    Commands:Inspect(data)
    if data and (data.version ~= kCurrentVersion) then
        PrintAndLogError("Your " .. configFilePath .. " format is incompatible. Please back up this file somewhere and then delete this one, you will be asked to create a new one")
        data = nil
    end

    if data then
        data.EngineDir = MakeUnixPath(data.EngineDir)
    end

    return data
end

function Commands._GetDefaultProjectNameAndDir(filepath)
    logWithVerbosity(kLogLevel_Verbose, "buffer name: " .. filepath)
    local uprojectPath, projectDir
    projectDir, uprojectPath = Commands._find_file_with_extension(filepath, "uproject")
    if not uprojectPath then
        PrintAndLogMessage("Failed to determine project name, could not find the root of the project that contains the .uproject")
        return nil, nil
    end
    local projectName = vim.fn.fnamemodify(uprojectPath, ":t:r")
    return projectName, projectDir
end

local CurrentCompileCommandsTargetFilePath = ""
function CurrentGenData:GetTaskAndStatus()
    if not self or not self.currentTask or self.currentTask == "" then
        return "[No Task]"
    end
    local status = self:GetTaskStatus(self.currentTask)
    return self.currentTask.."->".. status
end

function CurrentGenData:GetTaskStatus(taskName)
    local status = self.tasks[taskName]

    if not status then
       status = "none"
    end
    return status
end

function CurrentGenData:SetTaskStatus(taskName, newStatus)
    if (self.currentTask ~= "" and self.currentTask ~= taskName) and (self:GetTaskStatus(self.currentTask) ~= TaskState.completed) then
        PrintAndLogMessage("Cannot start a new task. Current task still in progress " .. self.currentTask)
        PrintAndLogError("Cannot start a new task. Current task still in progress " .. self.currentTask)
        return
    end
    PrintAndLogMessage("SetTaskStatus: " .. taskName .. "->" .. newStatus)
    self.currentTask = taskName
    self.tasks[taskName] = newStatus
end

function CurrentGenData:ClearTasks()
    self.tasks = {}
    self.currentTask = ""
end

local function file_exists(name)
   local f = io.open(name, "r")
   if f then
      io.close(f)
      return true
   end

   return false
end

-- Note: ExtractRSP, EscapePath, EnsureDirPath functions removed
-- These are now handled by the CLI tool (unreal-codegen)

local function IsEngineFile(path, start)
    local unixPath = MakeUnixPath(path)
    local unixStart = MakeUnixPath(start)
    local startIndex, _ = string.find(unixPath, unixStart, 1, true)
    return startIndex ~= nil
end

local function IsQuickfixWin(winid)
    if not vim.api.nvim_win_is_valid(winid) then return false end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')

    return buftype == 'quickfix'
end

local function GetQuickfixWinId()
    local quickfix_winid = nil

    for _, winid in ipairs(vim.api.nvim_list_wins()) do

        if IsQuickfixWin(winid) then
            quickfix_winid = winid
            break
        end
    end
    return quickfix_winid
end

Commands.QuickfixWinId = 0

local function ScrollQF()
    if not IsQuickfixWin(Commands.QuickfixWinId) then
        Commands.QuickfixWinId = GetQuickfixWinId()
    end

    local qf_list = vim.fn.getqflist()
    local last_line = #qf_list
    if last_line > 0 then
        vim.api.nvim_win_set_cursor(Commands.QuickfixWinId, {last_line, 0})
    end
end

local function AppendToQF(entry)
    vim.fn.setqflist({}, 'a', { items = { entry } })
    ScrollQF()
end

local function DeleteAutocmd(AutocmdId)
    local success, _ = pcall(function()
        vim.api.nvim_del_autocmd(AutocmdId)
    end)
end

function Stage_UbtGenCmd()
    coroutine.yield()
    Commands.BeginTask("gencmd")
    PrintAndLogMessage("Processing compile_commands.json with CLI...")

    -- Call the CLI to process compile_commands.json
    -- Convert to absolute path for CLI (CLI might run from different working directory)
    local abs_project_dir = vim.fn.fnamemodify(CurrentGenData.prjDir, ":p"):gsub("/$", "")

    PrintAndLogMessage("DEBUG: Original prjDir: " .. CurrentGenData.prjDir)
    PrintAndLogMessage("DEBUG: Absolute prjDir: " .. abs_project_dir)

    local cli_args = {
        project = abs_project_dir,
        engine = CurrentGenData.config.EngineDir,
        target = CurrentGenData.config.DefaultTarget or 1,
    }

    if CurrentGenData.WithEngine then
        cli_args["with-engine"] = true
    end

    if vim.g.unrealnvim_debug then
        cli_args.verbose = true
    end

    local qflistentry = {text = "Processing compile_commands.json..." }
    if CurrentGenData.WithEngine then
        qflistentry.text = qflistentry.text .. " Engine source files included, process will take longer"
    end
    AppendToQF(qflistentry)

    -- Call CLI (this blocks but we're in a coroutine so it's okay)
    local result, err = CallCLI("gen", cli_args)

    if not result or not result.success then
        PrintAndLogError("CLI gen command failed: " .. (err or (result and result.message) or "unknown error"))
        Commands.EndTask("gencmd")
        DeleteAutocmd(Commands.gencmdAutocmdid)
        return
    end

    PrintAndLogMessage(string.format("Processed %d files successfully", result.files_processed or 0))
    if result.errors and #result.errors > 0 then
        for _, error_msg in ipairs(result.errors) do
            PrintAndLogMessage("Warning: " .. error_msg)
        end
    end

    CurrentCompileCommandsTargetFilePath = result.output_file or (CurrentGenData.prjDir .. "/compile_commands.json")
    PrintAndLogMessage("Generated: " .. CurrentCompileCommandsTargetFilePath)

    PrintAndLogMessage("finished processing compile_commands.json")
    PrintAndLogMessage("generating header files with Unreal Header Tool...")
    Commands.EndTask("gencmd")
    DeleteAutocmd(Commands.gencmdAutocmdid)

    Commands.ScheduleTask("headers")
    Commands.BeginTask("headers")
    Commands.headersAutocmdid = vim.api.nvim_create_autocmd("ShellCmdPost",{
        pattern = "*",
        callback = FuncBind(DispatchUnrealnvimCb, "headers")
    })

    local cmd = CurrentGenData.ubtPath .. " -project=" ..
        CurrentGenData.projectPath .. " " .. CurrentGenData.target.UbtExtraFlags .. " " ..
        CurrentGenData.target.TargetName .. CurrentGenData.targetNameSuffix .. " " .. CurrentGenData.target.Configuration .. " " ..
        CurrentGenData.target.PlatformName .. " -headers"

    vim.cmd("compiler msvc")
    vim.cmd("Dispatch " .. cmd)
end

function Stage_GenHeadersCompleted()
    PrintAndLogMessage("Finished generating header files with Unreal Header Tool...")
    vim.api.nvim_command('autocmd! ShellCmdPost * lua DispatchUnrealnvimCb()')
    vim.api.nvim_command('LspRestart')
    Commands.EndTask("headers")
    Commands.EndTask("final")
    Commands:SetCurrentAnimation("kirbyIdle")
    DeleteAutocmd(Commands.headersAutocmdid)
end

Commands.renderedAnim = ""

 function Commands.GetStatusBar()
     local status = "unset"
    if CurrentGenData:GetTaskStatus("final") == TaskState.completed then
        status = Commands.renderedAnim .. " Build completed!"
    elseif CurrentGenData.currentTask ~= "" then
        status = Commands.renderedAnim .. " Building... Step: " .. CurrentGenData.currentTask .. "->".. CurrentGenData:GetTaskStatus(CurrentGenData.currentTask)
    else
        status = Commands.renderedAnim .. " Idle"
    end
    return status
end

function DispatchUnrealnvimCb(data)
     log("DispatchUnrealnvimCb()")
     Commands.taskCoroutine = coroutine.create(FuncBind(DispatchCallbackCoroutine, data))
 end

function DispatchCallbackCoroutine(data)
    coroutine.yield()
    if not data then
        log("data was nil")
    end
    PrintAndLogMessage("DispatchCallbackCoroutine()")
    PrintAndLogMessage("DispatchCallbackCoroutine() task="..CurrentGenData:GetTaskAndStatus())
    if data == "gencmd" and CurrentGenData:GetTaskStatus("gencmd") == TaskState.scheduled then
        CurrentGenData:SetTaskStatus("gencmd", TaskState.inprogress)
        Commands.taskCoroutine = coroutine.create(Stage_UbtGenCmd)
    elseif data == "headers" and CurrentGenData:GetTaskStatus("headers") == TaskState.inprogress then
        Commands.taskCoroutine = coroutine.create(Stage_GenHeadersCompleted)
    end
end

function PromptBuildTargetIndex()
    print("target to build:")
    for i, x in ipairs(CurrentGenData.config.Targets) do
        local configName = x.Configuration
        if x.withEditor then
            configName = configName .. "-Editor"
        end
       print(tostring(i) .. ". " .. configName)
    end
    return tonumber(vim.fn.input "<number> : ")
end

function Commands.GetCurrentFilePath()
    local current_file_path = vim.api.nvim_buf_get_name(0)
    if current_file_path == nil or current_file_path == "" then
        current_file_path = vim.fn.getcwd() .. path_separator
    end
    return current_file_path
end

function Commands.GetProjectName()
    local current_file_path = Commands.GetCurrentFilePath()
    local prjName, _ = Commands._GetDefaultProjectNameAndDir(current_file_path)
    if not prjName  then
        return "" --"<Unknown.uproject>"
    end

    return CurrentGenData.prjName .. ".uproject"
end

function InitializeCurrentGenData()
    PrintAndLogMessage("initializing")
    local current_file_path = Commands.GetCurrentFilePath()
    CurrentGenData.prjName, CurrentGenData.prjDir = Commands._GetDefaultProjectNameAndDir(current_file_path)
    if not CurrentGenData.prjName then
        PrintAndLogMessage("could not find project. aborting")
        return false
    end

    CurrentGenData.config = Commands._EnsureConfigFile(CurrentGenData.prjDir,
        CurrentGenData.prjName)

    if not CurrentGenData.config then
        PrintAndLogMessage("no config file. aborting")
        return false
    end

    CurrentGenData.ubtPath = GetUnrealBuildToolPath(CurrentGenData.config.EngineDir, CurrentGenData.config.EngineVer)
    CurrentGenData.ueBuildBat = GetBuildScriptPath(CurrentGenData.config.EngineDir)
    CurrentGenData.projectPath = "\"" .. CurrentGenData.prjDir .. "/" ..
        CurrentGenData.prjName .. ".uproject\""

    local desiredTargetIndex = nil
    if CurrentGenData.config.DefaultTarget and CurrentGenData.config.DefaultTarget > 0 then
        desiredTargetIndex = CurrentGenData.config.DefaultTarget
    else
        desiredTargetIndex = PromptBuildTargetIndex()
    end

    if desiredTargetIndex == nil then
        return false
    end

    CurrentGenData.target = CurrentGenData.config.Targets[desiredTargetIndex]

    CurrentGenData.targetNameSuffix = ""
    if CurrentGenData.target.withEditor then
        CurrentGenData.targetNameSuffix = "Editor"
    end

    PrintAndLogMessage("Using engine at:"..CurrentGenData.config.EngineDir)

    return true
end

function Commands.ScheduleTask(taskName)
    PrintAndLogMessage("ScheduleTask: " .. taskName)
    CurrentGenData:SetTaskStatus(taskName, TaskState.scheduled)
end

function Commands.ClearTasks()
    CurrentGenData:ClearTasks()
end

function Commands.BeginTask(taskName)
    PrintAndLogMessage("BeginTask: " .. taskName)
    CurrentGenData:SetTaskStatus(taskName, TaskState.inprogress)
end

function Commands.EndTask(taskName)
    PrintAndLogMessage("EndTask: " .. taskName)
    CurrentGenData:SetTaskStatus(taskName, TaskState.completed)
    Commands.taskCoroutine = nil
end

function BuildComplete()
    Commands.EndTask("build")
    Commands.EndTask("final")
    Commands:SetCurrentAnimation("kirbyIdle")
    DeleteAutocmd(Commands.buildAutocmdid)
end

function Commands.BuildCoroutine()
    Commands.buildAutocmdid = vim.api.nvim_create_autocmd("ShellCmdPost",
        {
            pattern = "*",
            callback = BuildComplete
        })

    -- Call CLI to get build command (dry-run mode)
    local abs_project_dir = vim.fn.fnamemodify(CurrentGenData.prjDir, ":p"):gsub("/$", "")
    local result = CallCLI("build", {
        project = abs_project_dir,
        target = CurrentGenData.config.DefaultTarget,
        ["dry-run"] = true
    })

    if not result or not result.success or not result.command then
        PrintAndLogError("Failed to construct build command: " .. (result and result.message or "unknown error"))
        BuildComplete()
        return
    end

    local cmd = result.command

    vim.cmd("compiler msvc")
    vim.cmd("Dispatch " .. cmd)

end

function Commands.build(opts)
    CurrentGenData:ClearTasks()
    PrintAndLogMessage("Building uproject")

    if not InitializeCurrentGenData() then
        return
    end
    Commands.EnsureUpdateStarted();

    Commands.ScheduleTask("build")
    Commands:SetCurrentAnimation("kirbyFlip")
    Commands.taskCoroutine = coroutine.create(Commands.BuildCoroutine)

end

function Commands.run(opts)
    CurrentGenData:ClearTasks()
    PrintAndLogMessage("Running uproject")

    if not InitializeCurrentGenData() then
        return
    end

    Commands.ScheduleTask("run")

    -- Call CLI to get run command (dry-run mode)
    local abs_project_dir = vim.fn.fnamemodify(CurrentGenData.prjDir, ":p"):gsub("/$", "")
    local result = CallCLI("run", {
        project = abs_project_dir,
        target = CurrentGenData.config.DefaultTarget,
        ["dry-run"] = true
    })

    if not result or not result.success or not result.command then
        PrintAndLogError("Failed to construct run command: " .. (result and result.message or "unknown error"))
        Commands.EndTask("run")
        Commands.EndTask("final")
        return
    end

    local cmd = result.command

    PrintAndLogMessage(cmd)
    vim.cmd("compiler msvc")
    vim.cmd("Dispatch " .. cmd)
    Commands.EndTask("run")
    Commands.EndTask("final")
end

function Commands.EnsureUpdateStarted()
    if Commands.cbTimer then return end

    Commands.lastUpdateTime = vim.loop.now()
    Commands.updateTimer = 0

    -- UI update loop
    Commands.cbTimer = vim.loop.new_timer()
    Commands.cbTimer:start(1,30, vim.schedule_wrap(Commands.safeUpdateLoop))

    -- coroutine update loop
    vim.schedule(Commands.safeLogicUpdate)
end

function Commands.generateCommands(opts)
    log(Commands.Inspect(opts))

    if not InitializeCurrentGenData() then
        PrintAndLogMessage("init failed")
        return
    end

    if opts.WithEngine then
        CurrentGenData.WithEngine = true
    end

    -- vim.api.nvim_command('autocmd ShellCmdPost * lua DispatchUnrealnvimCb()')
    Commands.gencmdAutocmdid = vim.api.nvim_create_autocmd("ShellCmdPost",
        {
            pattern = "*",
            callback = FuncBind(DispatchUnrealnvimCb, "gencmd")
        })

    PrintAndLogMessage("listening to ShellCmdPost")
    --vim.cmd("compiler msvc")
    PrintAndLogMessage("compiler set to msvc")

    Commands.taskCoroutine = coroutine.create(Commands.generateCommandsCoroutine)
    Commands.EnsureUpdateStarted()
end


function Commands.updateLoop()
    local elapsedTime = vim.loop.now() - Commands.lastUpdateTime
    Commands:uiUpdate(elapsedTime)
    Commands.lastUpdateTime = vim.loop.now()
end

function Commands.safeUpdateLoop()
    local success, errmsg = pcall(Commands.updateLoop)
    if not success then
        vim.api.nvim_err_writeln("Error in update:".. errmsg)
    end
end

local gtimer = 0
local resetCount = 0

function Commands:uiUpdate(delta)
    local animFrameCount = 4
    local animFrameDuration = 200
    local animDuration = animFrameCount * animFrameDuration

    local anim = {
    "▌",
			"▀",
			"▐",
			"▄"
    }
    local anim1 = {
    "1",
			"2",
			"3",
			"4"
    }
    if Commands.animData then
        anim = Commands.animData.frames
        animFrameDuration = Commands.animData.interval
        animFrameCount = #anim
        animDuration = animFrameCount * animFrameDuration
    end

    local index = 1 + (math.floor(math.fmod(vim.loop.now(), animDuration) / animFrameDuration))
    Commands.renderedAnim = (anim[index] or "")
end

function Commands.safeLogicUpdate()
    local success, errmsg = pcall(function() Commands:LogicUpdate() end)

    if not success then
        vim.api.nvim_err_writeln("Error in update:".. errmsg)
    end
    vim.defer_fn(Commands.safeLogicUpdate, 1)
end

function Commands:LogicUpdate()
    if self.taskCoroutine then
        if coroutine.status(self.taskCoroutine) ~= "dead"  then
            local ok, errmsg = coroutine.resume(self.taskCoroutine)
            if not ok then
                self.taskCoroutine = nil
                error(errmsg)
            end
        else
            self.taskCoroutine = nil
        end
    end
    vim.defer_fn(Commands.onStatusUpdate, 1)
end

 local function GetInstallDir()
    local packer_install_dir = vim.fn.stdpath('data') .. '/site/pack/packer/start/'
    return packer_install_dir .. "Unreal.nvim//"
end

local mydbg = true
function Commands:SetCurrentAnimation(animationName)
    local jsonPath = GetInstallDir() .. "lua/spinners.json"
    local file = io.open(jsonPath, "r")
    if file then
        local content = file:read("*all")
        local json = vim.fn.json_decode(content)
        Commands.animData = json[animationName]
    end
end

function Commands.generateCommandsCoroutine()
    PrintAndLogMessage("Generating clang-compatible compile_commands.json")
    Commands:SetCurrentAnimation("kirbyFlip")
    coroutine.yield()
    Commands.ClearTasks()

    local editorFlag = ""
    if CurrentGenData.config.withEditor then
        PrintAndLogMessage("Building editor")
        editorFlag = "-Editor"
    end

    Commands.ScheduleTask("gencmd")
    -- local cmd = CurrentGenData.ubtPath .. " -mode=GenerateClangDatabase -StaticAnalyzer=Clang -project=" ..
    local cmd = CurrentGenData.ubtPath .. " -mode=GenerateClangDatabase -project=" ..
    CurrentGenData.projectPath .. " -game -engine " .. CurrentGenData.target.UbtExtraFlags .. " " ..
    editorFlag .. " " ..
    CurrentGenData.target.TargetName .. CurrentGenData.targetNameSuffix .. " " .. CurrentGenData.target.Configuration .. " " ..
    CurrentGenData.target.PlatformName

    PrintAndLogMessage("Dispatching command:")
    PrintAndLogMessage(cmd)
    CurrentCompileCommandsTargetFilePath =  CurrentGenData.prjDir .. "/compile_commands.json"
    vim.api.nvim_command("Dispatch " .. cmd)
    PrintAndLogMessage("Dispatched")
end

function Commands.SetUnrealCD()
    local current_file_path = Commands.GetCurrentFilePath()
    local prjName, prjDir = Commands._GetDefaultProjectNameAndDir(current_file_path)
    if prjDir then
        vim.cmd("cd " .. prjDir)
    else
        PrintAndLogMessage("Could not find unreal project root directory, make sure you have the correct buffer selected")
    end
end


function Commands._check_extension_in_directory(directory, extension)
    local dir = vim.loop.fs_opendir(directory)
    if not dir then
        return nil
    end

    local handle = vim.loop.fs_scandir(directory)
    local name, typ

    while handle do
        name, typ = vim.loop.fs_scandir_next(handle)
        if not name then break end
        local ext = vim.fn.fnamemodify(name, ":e")
        if ( ext == "uproject" ) then
            return directory.."/"..name
        end
    end
    return nil
end

function Commands._find_file_with_extension(filepath, extension)
    local current_dir = vim.fn.fnamemodify(filepath, ":h")
    local parent_dir = vim.fn.fnamemodify(current_dir, ":h")
    -- Check if the file exists in the current directory
    local filename = vim.fn.fnamemodify(filepath, ":t")

    local full_path = Commands._check_extension_in_directory(current_dir, extension)
    if full_path then
        return current_dir, full_path
    end

    -- Recursively check parent directories until we find the file or reach the root directory
    if current_dir ~= parent_dir then
        return Commands._find_file_with_extension(parent_dir .. "/" .. filename, extension)
    end

    -- File not found
    return nil
end


return Commands
