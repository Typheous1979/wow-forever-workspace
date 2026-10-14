# Lua environment on WoW Forever

WoW runs a **modified Lua 5.1** with taint tracking. Lint rules LUA001–004 and API001 enforce this page.

## Not available (Lua 5.2+ or stripped)
- Syntax: `goto` / `::label::`, `//`, `&`, `|`, `~` (as xor/not), `<<`, `>>`, `_ENV`, integer types, `\x`/`\z`/`\u{}` string escapes (5.1 keeps the letter: `"\x41"` becomes `"x41"`).
- Libraries:
  - `io`, `package` and `debug` (except `debugstack`/`debuglocals`);
  - `require`, `dofile`, `loadfile`, `module`;
  - `os` except `os.time`, `os.date`, `os.clock`, `os.difftime`.
- `string.gfind` and `table.setn` error.

## Module loading
- The **TOC is the loader**. Files share state through the namespace table: `local addonName, ns = ...`.
- **`import(moduleName)`** exists on Forever (70291+, renamed from `require`) [F-033]:
  - it returns the value a module file *returned*;
  - it **cannot load** files;
  - cross-addon imports need a direct `## Dep`.

  It's Forever-only, so prefer `ns` for portability.

## Base functions
`assert error getmetatable setmetatable ipairs pairs next pcall xpcall select tonumber tostring type unpack rawequal rawget rawset getfenv setfenv loadstring collectgarbage print time date difftime tostringall newproxy`

## WoW additions (use freely)
- **string:** `strsplit(sep, s)`, `strjoin`, `strtrim`, `strconcat`, `strsplittable`, `strlenutf8`, `strcmputf8i`. As methods (12.1.5): `s:startswith(p)`, `s:endswith(p)`, `s:contains(p)`, `s:trim()`, `s:ltrim()`, `s:rtrim()`.
- **table:** `tinsert`, `tremove`, `wipe(t)`, `tContains`, `tIndexOf`, `CountTable`. 12.1.5: `table.isempty`, `table.contains`, `table.indexof`, `table.keys`, `table.values`, `table.removevalue`, `table.removeunordered`, `table.freeze`/`isfrozen`.
- **math:** the usual functions plus `math.clamp`, `math.round`, `math.lerp`, `math.saturate`, `math.sign`, `math.remap`, `math.wrap`, `math.isnan`/`isinf`/`isfinite`, and `fastrandom`. The global `sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`atan2` work in **degrees**.
- **bit:** `bit.band bor bxor bnot lshift rshift arshift mod` (32-bit).
- **Mixins:** `Mixin(obj, ...)`, `CreateFromMixins(...)` (engine functions since 11.2.0).
- **Timers:** `C_Timer.After(sec, fn)` returns **nothing**. `C_Timer.NewTimer(sec, fn)` and `C_Timer.NewTicker(sec, fn[, n])` return a handle with `:Cancel()`. `RunNextFrame(fn)`. `C_Timer.NewTimedSignalMap` (12.1.5).
- **Time:** `GetTime()` (seconds, float), `time()`, `date()`, `GetServerTime()`.
- **Script throttling:** heavy loops can be throttled. `GetScriptBucketThrottleLimits()` shows the budget. Spread work with `C_Timer.After(0, ...)` or coroutines.

## Idioms
```lua
local addonName, ns = ...                -- every file
local L = ns.L                           -- locale table set up in Locales\enUS.lua
local function Print(msg)                -- local helpers; never globals
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[" .. addonName .. "]|r " .. msg)
end
ns.Print = Print                          -- share across files via ns
```
