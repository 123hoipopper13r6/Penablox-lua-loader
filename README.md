# penablox lua loader

A script loader for the penablox Lua engine. It reads the `luas/` folder of this
repo, fetches every `.lua` file, and shows each one in a small in-game window with
its name and author. Load and unload scripts individually or all at once.

## Install

1. Open the penablox menu, go to Settings, then Lua scripts.
2. Create a script named `loader.lua` and paste the contents of `loader.lua`.
3. Load it. A notification confirms it is running.
4. Press `RightShift` to open or close the window.

If you host `loader.lua` at the repo root, you can bootstrap it with one line instead:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/123hoipopper13r6/Penablox-lua-loader/main/loader.lua"))()
