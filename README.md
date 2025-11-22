# Unreal.nvim
Unreal Engine support for Neovim with cross-platform support (Windows, MacOS, Linux)
![image](https://raw.githubusercontent.com/zadirion/Unreal.nvim/main/image.png)

**Requirements**

**Windows:**
- Install the clangd support component through Visual Studio Setup
- Ensure clang++.exe is in your system PATH environment variable (needs to be added manually)

**MacOS:**
- Install Xcode Command Line Tools: `xcode-select --install`
- clang/clang++ will be available automatically

**Linux:**
- Install clang: `sudo apt install clang` (Ubuntu/Debian) or equivalent for your distro

**All Platforms:**
- Tested with Unreal Engine 4.27, 5.1, 5.2, and 5.3
- Neovim >= 0.7.0
- (optional) vim-dispatch plugin for async build execution
- (optional) If you don't already have your own configuration, I recommend you use neovim configuration specialized for development in Unreal Engine https://github.com/zadirion/UnrealHero.nvim

**Installation**

Install with packer:
```
  use {'zadirion/Unreal.nvim',
    requires =
    {
        {"tpope/vim-dispatch"}
    }
  }
```
After installing with packer, open one of your Unreal project's source files, and run `UnrealGenWithEngine`. This will go through all the engine source files and will generate a compatible clang compile-command for each, so that the lsp can properly parse them.
It will take a long time to go through all of them, but you only need to run this command once, for your engine.
After running it for the first time, it will open a configuration file in a new buffer. In this buffer set the value of the `"EngineDir"` key to the path to Unreal Engine on your system. For example,

```jsonc
// UnrealNvim.json
{
  "version": "0.0.2",
  "EngineDir": "C:\\Program Files\\Epic Games\\UE_5.4\\"
  "Targets": [
    // ...
  ]
}
```

After doing that and saving the file, run `:UnrealGenWithEngine` again.

From here onwards, you can use `:UnrealGen` to generate the compile commands for just your project files. Feel free to do so every time you feel like the lsp is not picking up your symbols, such as when you added new source code files to your project or if you updated to latest changelist/commig in your version control. 
`:UnrealGen` will always ask you which target to generate compile_commands.json for. Just input the number corresponding to the desired configuration, and it will generate the json right next to the uproject

This should cause your LSP to start recognizing the Unreal types, including the ones from .generated.h files.

**Commands**
- `:UnrealGenWithEngine` generates the compile_commands.json and the compiler rsp files for the engine source code, so your LSP can properly parse the source code
- `:UnrealGen` generates the compile_commands.json and the compiler rps files for your project, so your LSP can properly parse the source code
- `:UnrealBuild` builds the project with unreal
- `:UnrealRun` runs the project. It does not build it even if the source is out of date
- `:UnrealCD` sets the current directory to the root folder of the unreal project (the one with the .uproject in it). I personally use this so Telescope only searches in the project directory, making it faster, especially for live_grep

**Known Limitations**
- Debugger support not yet implemented. On Windows, use Visual Studio for debugging. On MacOS, use Xcode or lldb. On Linux, use gdb/lldb.
- You can only abort a build using `:AbortDispatch` and it will only work for the actual unreal build step, it won't work for the RSP generation build step

**Platform-Specific Notes**

**MacOS:**
- Unreal Editor is launched from `.app` bundles automatically
- Build scripts use `.sh` files from `Engine/Build/BatchFiles/Mac/`
- Default platform in config is set to `Mac` automatically

**Linux:**
- Build scripts use `.sh` files from `Engine/Build/BatchFiles/Linux/`
- Default platform in config is set to `Linux` automatically
- Make sure build scripts are executable: `chmod +x Engine/Build/BatchFiles/Linux/*.sh`

**Windows:**
- Uses MSVC-style compiler flags (`/FI`, `/I`, etc.) natively
- Default platform in config is set to `Win64` automatically

**Troubleshooting**

**General:**
- If symbols are not recognized/found, clangd's index cache may be broken. Find the `.cache` directory next to your `.uproject`, close Neovim, delete `.cache`, reopen and navigate to a project file to trigger reindexing.
- Enable logging with `vim.g.unrealnvim_debug = true`. Unreal.Nvim's log is in nvim-data folder.
- clangd's LSP log location:
  - Windows: `%localappdata%/nvim-data/lsp.log`
  - MacOS/Linux: `~/.local/share/nvim/lsp.log`

**MacOS-Specific:**
- If UnrealBuildTool fails, ensure Xcode Command Line Tools are installed: `xcode-select --install`
- If editor won't launch, verify the `.app` bundle exists in `Engine/Binaries/Mac/` or `ProjectName/Binaries/Mac/`

**Linux-Specific:**
- If build scripts fail with permission errors, make them executable: `chmod +x Engine/Build/BatchFiles/Linux/*.sh`
- Ensure clang is installed and in PATH: `which clang++`
