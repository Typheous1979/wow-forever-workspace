local addonName, ns = ...

-- Library: the music catalog as a browsable tree, plus search, favorites and
-- playlists. The catalog itself (Data/Catalog.lua) is generated from the game's
-- own tables; each track is a FileDataID that the client streams.

local Library = {}
ns.Library = Library

local tracks          -- ns.CatalogTracks: [fileID] = { name, seconds, flags }
local homeOf = {}     -- [fileID] = first folder node that lists it (for "where is this from")

-- node = { name, children = { node... }, tracks = { fileID... }, parent, depth, total }
local function BuildNode(raw, parent)
    local node = { name = raw[1], children = {}, tracks = raw[3] or {}, parent = parent,
                   depth = parent and parent.depth + 1 or 0 }
    for _, rawChild in ipairs(raw[2] or {}) do
        node.children[#node.children + 1] = BuildNode(rawChild, node)
    end
    for _, fileID in ipairs(node.tracks) do
        if not homeOf[fileID] then homeOf[fileID] = node end
    end
    return node
end

local function CountTracks(node)
    local seen, n = {}, 0
    local function walk(x)
        for _, id in ipairs(x.tracks) do
            if not seen[id] then seen[id] = true; n = n + 1 end
        end
        for _, c in ipairs(x.children) do walk(c) end
    end
    walk(node)
    return n
end

function Library.Init()
    tracks = ns.CatalogTracks or {}
    local root = { name = "MusicForever", children = {}, tracks = {}, depth = 0 }
    for _, raw in ipairs(ns.CatalogTree or {}) do
        root.children[#root.children + 1] = BuildNode(raw, root)
    end
    Library.root = root
    local function count(x)
        x.total = CountTracks(x)
        for _, c in ipairs(x.children) do count(c) end
    end
    count(root)
    -- forget favorites/playlist entries for files no longer in the catalog? No:
    -- keep them (a later catalog may bring them back); views skip unknown IDs.
end

-- Track info --------------------------------------------------------------

function Library.GetTrack(fileID)
    local t = tracks and tracks[fileID]
    if not t then return nil end
    return t[1], t[2], t[3]
end

function Library.TrackName(fileID)
    local name = Library.GetTrack(fileID)
    return name or ("Track " .. tostring(fileID))
end

function Library.TrackSeconds(fileID)
    local _, seconds = Library.GetTrack(fileID)
    return seconds or 0
end

function Library.IsForeverTrack(fileID)
    local _, _, flags = Library.GetTrack(fileID)
    return flags ~= nil and flags % 2 == 1
end

-- "Elwynn Forest" for a track listed under Zones > Eastern Kingdoms > Elwynn Forest > Music
local SECTION = { Music = true, Day = true, Night = true, Intro = true }
function Library.Where(fileID)
    local node = homeOf[fileID]
    if not node then return "" end
    if SECTION[node.name] and node.parent then
        return node.parent.name .. " · " .. node.name
    end
    return node.name
end

function Library.PathOf(node)
    local parts = {}
    while node and node.parent do
        table.insert(parts, 1, node.name)
        node = node.parent
    end
    return table.concat(parts, " › ")
end

function Library.FormatTime(seconds)
    if not seconds or seconds <= 0 then return "--:--" end
    seconds = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Every track under a node, depth first, without duplicates.
function Library.Collect(node)
    local out, seen = {}, {}
    local function walk(x)
        for _, id in ipairs(x.tracks) do
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
        for _, c in ipairs(x.children) do walk(c) end
    end
    if node then walk(node) end
    return out
end

-- Search: tracks whose name matches, or that sit under a folder whose name matches.
-- Returns a list of fileIDs (no duplicates), best matches (track names) first.
function Library.Search(text)
    text = strtrim(string.lower(text or ""))
    if text == "" or not Library.root then return {} end
    local byName, byFolder, seen = {}, {}, {}
    local function walk(node, folderHit)
        local hit = folderHit or string.find(string.lower(node.name), text, 1, true) ~= nil
        for _, id in ipairs(node.tracks) do
            if not seen[id] then
                if string.find(string.lower(Library.TrackName(id)), text, 1, true) then
                    seen[id] = true; byName[#byName + 1] = id
                elseif hit then
                    seen[id] = true; byFolder[#byFolder + 1] = id
                end
            end
        end
        for _, c in ipairs(node.children) do walk(c, hit) end
    end
    for _, top in ipairs(Library.root.children) do walk(top, false) end
    for _, id in ipairs(byFolder) do byName[#byName + 1] = id end
    return byName
end

-- Favorites -----------------------------------------------------------------

function Library.IsFavorite(fileID)
    return ns.db.favorites[fileID] == true
end

function Library.ToggleFavorite(fileID)
    ns.db.favorites[fileID] = (not Library.IsFavorite(fileID)) or nil
    ns.Fire("LIBRARY_CHANGED")
end

function Library.Favorites()
    local list = {}
    for id in pairs(ns.db.favorites) do
        if Library.GetTrack(id) then list[#list + 1] = id end
    end
    table.sort(list, function(a, b) return Library.TrackName(a) < Library.TrackName(b) end)
    return list
end

-- Playlists -------------------------------------------------------------------

function Library.Playlists()
    return ns.db.playlists
end

function Library.FindPlaylist(name)
    for i, pl in ipairs(ns.db.playlists) do
        if pl.name == name then return pl, i end
    end
end

function Library.CreatePlaylist(name)
    name = strtrim(name or "")
    if name == "" or Library.FindPlaylist(name) then return nil end
    local pl = { name = name, tracks = {} }
    table.insert(ns.db.playlists, pl)
    ns.Fire("LIBRARY_CHANGED")
    return pl
end

function Library.RenamePlaylist(pl, name)
    name = strtrim(name or "")
    if name == "" or Library.FindPlaylist(name) then return false end
    pl.name = name
    ns.Fire("LIBRARY_CHANGED")
    return true
end

function Library.DeletePlaylist(pl)
    local _, index = Library.FindPlaylist(pl.name)
    if index then
        table.remove(ns.db.playlists, index)
        ns.Fire("LIBRARY_CHANGED")
    end
end

function Library.AddToPlaylist(pl, fileIDs)
    local have = {}
    for _, id in ipairs(pl.tracks) do have[id] = true end
    local added = 0
    for _, id in ipairs(fileIDs) do
        if not have[id] then
            pl.tracks[#pl.tracks + 1] = id
            have[id] = true
            added = added + 1
        end
    end
    ns.Fire("LIBRARY_CHANGED")
    return added
end

function Library.RemoveFromPlaylist(pl, index)
    table.remove(pl.tracks, index)
    ns.Fire("LIBRARY_CHANGED")
end

function Library.MoveInPlaylist(pl, index, delta)
    local target = index + delta
    if target < 1 or target > #pl.tracks then return end
    pl.tracks[index], pl.tracks[target] = pl.tracks[target], pl.tracks[index]
    ns.Fire("LIBRARY_CHANGED")
end
