# Load order, events and SavedVariables

## Login sequence
1. Blizzard addons load, then yours (alphabetical unless dependencies say otherwise). Your files run **top to bottom in TOC order**. At this point your SavedVariables globals are **nil**, unless the TOC has `LoadSavedVariablesFirst: 1`.
2. The client loads your SavedVariables, **replacing** anything your files assigned to those names.
3. `ADDON_LOADED(addOnName, containsBindings)` fires **once per addon**. Check `addOnName == addonName`.
4. `PLAYER_LOGIN` fires once every non-LoadOnDemand addon has loaded. It fires on login and after `/reload`.
5. `PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)` fires on **every** loading screen.
6. `SPELLS_CHANGED`, then the zone events.
7. On error, `SAVED_VARIABLES_TOO_LARGE(addOnName)` fires after `ADDON_LOADED`, and your SVs **won't be saved** this session.

`VARIABLES_LOADED` is for CVars and keybindings. Don't use it for SVs.

## Logout sequence
`PLAYER_LEAVING_WORLD` → `PLAYER_LOGOUT` (last chance to modify SVs) → `ADDONS_UNLOADING(closingClient)` → SVs are written.
- Script throttles don't apply during `PLAYER_LOGOUT`/`ADDONS_UNLOADING` (12.0.5).
- Nothing is written on a crash or Alt-F4.

## When SavedVariables are written
- Only on `/reload`, logout, disconnect or quit. **The file on disk lags memory by one reload.**
- To verify persistence, do a full logout and login, not just `/reload`. Then inspect the file with `python tools/wowf/cli.py sv <Addon>` (`wowf-debug`).
- Each save keeps the previous one as `<Addon>.lua.bak`. `cli.py sv <Addon> --diff` compares them.
- Paths:
  - account: `WTF\Account\<acct>\SavedVariables\<Addon>.lua`;
  - per character: `WTF\Account\<acct>\<id>\<Char-Realm>\SavedVariables\` [F-007].

## What can be saved
- Strings, numbers, booleans and tables (no functions, userdata or frames).
- **Never secrets.** They are saved as nil [F-040].
- Shared references are duplicated. Avoid cycles.

## The pattern (copy this)
```lua
local addonName, ns = ...

local DB_VERSION = 2
local defaults = {
    enabled = true,
    volume = 0.8,
    position = { point = "CENTER", x = 0, y = 0 },
}

-- Forward-only migrations keyed by the version they upgrade FROM.
-- Never wipe the table on a mismatch: unknown future versions disable features, keep data.
local migrations = {
    [1] = function(db)            -- v1 stored volume as 0..100
        if type(db.volume) == "number" and db.volume > 1 then db.volume = db.volume / 100 end
    end,
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local events = {}
function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    MyAddonDB = MyAddonDB or {}
    local db = MyAddonDB
    local from = db.dbVersion or 1
    if from > DB_VERSION then
        ns.readOnly = true        -- written by a newer version: don't touch it
    else
        for v = from, DB_VERSION - 1 do
            if migrations[v] then migrations[v](db) end
        end
        db.dbVersion = DB_VERSION
    end
    CopyDefaults(defaults, db)
    ns.db = db
    self:UnregisterEvent("ADDON_LOADED")
    if ns.OnDatabaseReady then ns.OnDatabaseReady() end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
```
- Lint PAT001 flags any SV touched at file scope.
- Bind Settings controls to `MyAddonDB` keys **inside** `ADDON_LOADED` (see ui-patterns.md).

## Debouncing writes
State lives in memory; the file is only written at reload or logout. To limit expensive work after rapid changes (slider drags):
```lua
local pending
local function ScheduleRefresh()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function() pending = false; ns.Refresh() end)
end
```

## History on the beta [F-060]
- Sep 18–21: SVs were written but not restored, which hit addons and Blizzard UI settings alike. **Fixed in 70009.**
- Some later builds reset interface settings.
- If persistence fails, check the build before blaming the code, and keep `.bak` diffs as evidence.
