local addonName, ns = ...

-- Playlists tab: Favorites plus the player's own playlists (account-wide).
-- Left: the lists, with a name box to create or rename. Right: the tracks, with
-- move up/down and remove on right-click.

local UI = ns.UI
local Library = ns.Library
local PlaylistView = {}
ns.PlaylistView = PlaylistView

local LIST_WIDTH = 240
local FAVORITES = {}   -- sentinel for the Favorites entry

function PlaylistView.Build(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    local selected = FAVORITES

    -- left: playlists -----------------------------------------------------------
    local left = UI.Panel(frame)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetWidth(LIST_WIDTH)

    local nameBox = UI.Input(left, LIST_WIDTH - 28, ns.L["Playlist name"])
    nameBox:SetPoint("TOPLEFT", 14, -10)
    local create = UI.Button(left, ns.L["New"], 100)
    create:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", -6, -4)
    local rename = UI.Button(left, ns.L["Rename"], 100)
    rename:SetPoint("LEFT", create, "RIGHT", 6, 0)

    local listHolder = CreateFrame("Frame", nil, left)
    listHolder:SetPoint("TOPLEFT", 0, -62)
    listHolder:SetPoint("BOTTOMRIGHT")

    -- right: tracks ---------------------------------------------------------------
    local right = UI.Panel(frame)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
    right:SetPoint("BOTTOMRIGHT")
    local header = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 10, -10)
    header:SetPoint("RIGHT", -10, 0)
    header:SetJustifyH("LEFT")
    local sub = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)

    local trackHolder = CreateFrame("Frame", nil, right)
    trackHolder:SetPoint("TOPLEFT", 4, -72)
    trackHolder:SetPoint("BOTTOMRIGHT", -4, 4)

    local tracks = UI.TrackList(trackHolder, {
        extendMenu = function(root, fileID, index)
            if selected == FAVORITES then return end
            root:CreateDivider()
            root:CreateButton(ns.L["Move up"], function() Library.MoveInPlaylist(selected, index, -1) end)
            root:CreateButton(ns.L["Move down"], function() Library.MoveInPlaylist(selected, index, 1) end)
            root:CreateButton(ns.L["Remove from playlist"], function() Library.RemoveFromPlaylist(selected, index) end)
        end,
    })

    local playAll = UI.Button(right, ns.L["Play all"], 90, function() tracks.Play(1) end)
    playAll:SetPoint("TOPLEFT", 8, -44)
    local shuffleAll = UI.Button(right, ns.L["Shuffle"], 80, function()
        ns.Player.SetShuffle(true)
        tracks.Play(math.random(math.max(1, #tracks.ids)))
    end)
    shuffleAll:SetPoint("LEFT", playAll, "RIGHT", 6, 0)

    local function ShowSelected()
        local ids, name
        if selected == FAVORITES then
            ids, name = Library.Favorites(), ns.L["Favorites"]
        else
            ids, name = {}, selected.name
            for _, id in ipairs(selected.tracks) do
                if Library.GetTrack(id) then ids[#ids + 1] = id end
            end
        end
        header:SetText(name)
        local total = 0
        for _, id in ipairs(ids) do total = total + Library.TrackSeconds(id) end
        sub:SetText(string.format("%d %s   ·   %s", #ids, #ids == 1 and ns.L["track"] or ns.L["tracks"],
            Library.FormatTime(total)))
        tracks.SetTracks(ids, name, true)
    end

    -- playlist rows
    local listBox
    local function InitRow(row, data)
        UI.SetupRow(row)
        local pl = data.pl
        local isFav = pl == FAVORITES
        row.left:SetText(isFav and ("|cffffd100" .. ns.L["Favorites"] .. "|r") or pl.name)
        row.right:SetText(isFav and #Library.Favorites() or #pl.tracks)
        row.selected:SetShown(pl == selected)
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" and not isFav then
                MenuUtil.CreateContextMenu(self, function(_, root)
                    root:CreateTitle(pl.name)
                    root:CreateButton(ns.L["Play"], function()
                        selected = pl; ShowSelected(); tracks.Play(1)
                    end)
                    root:CreateButton(ns.L["Rename"], function()
                        selected = pl
                        PlaylistView.Refresh()
                        nameBox:SetText(pl.name)
                        nameBox:SetFocus()
                        nameBox:HighlightText()
                    end)
                    root:CreateButton("|cffff6060" .. ns.L["Delete playlist"] .. "|r", function()
                        Library.DeletePlaylist(pl)
                        if selected == pl then selected = FAVORITES end
                    end)
                end)
                return
            end
            selected = pl
            PlaylistView.Refresh()
        end)
    end

    local view = CreateScrollBoxListLinearView(2, 2, 2, 2, 0)
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    listBox = UI.ScrollList(listHolder, view)

    function PlaylistView.Refresh()
        local dp = CreateDataProvider()
        dp:Insert({ pl = FAVORITES })
        for _, pl in ipairs(Library.Playlists()) do dp:Insert({ pl = pl }) end
        listBox:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)
        if selected ~= FAVORITES and not Library.FindPlaylist(selected.name) then
            selected = FAVORITES
        end
        ShowSelected()
        rename:SetEnabled(selected ~= FAVORITES)
    end

    local function CreateFromBox()
        local text = strtrim(nameBox:GetText() or "")
        if text == "" then
            ns.Print(ns.L["Type a name for the playlist first."])
            return
        end
        local pl = Library.CreatePlaylist(text)
        if not pl then
            ns.Print(ns.L["A playlist with that name already exists."])
            return
        end
        selected = pl
        nameBox:SetText("")
        nameBox:ClearFocus()
        PlaylistView.Refresh()
    end

    local function RenameFromBox()
        local text = strtrim(nameBox:GetText() or "")
        if selected == FAVORITES or text == "" or text == selected.name then return end
        if not Library.RenamePlaylist(selected, text) then
            ns.Print(ns.L["A playlist with that name already exists."])
            return
        end
        nameBox:SetText("")
        nameBox:ClearFocus()
        PlaylistView.Refresh()
    end

    create:SetScript("OnClick", CreateFromBox)
    rename:SetScript("OnClick", RenameFromBox)
    nameBox:SetScript("OnEnterPressed", CreateFromBox)

    ns.On("LIBRARY_CHANGED", function()
        if frame:IsVisible() then PlaylistView.Refresh() end
    end)

    return {
        frame = frame,
        OnShow = PlaylistView.Refresh,
    }
end
