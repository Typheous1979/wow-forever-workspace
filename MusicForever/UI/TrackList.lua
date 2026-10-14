local addonName, ns = ...

-- A scrolling list of tracks: favorite star, name, where it is from, length.
-- Double-click plays (the list becomes the queue); right-click opens a menu.
-- Used by the Library and Playlists tabs.

local UI = ns.UI
local Library = ns.Library

local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local PLAYING_COLOR = { 0.4, 1, 0.4 }

function UI.TrackList(parent, options)
    options = options or {}
    local list = { ids = {}, label = nil, showWhere = false }

    local function InitRow(row, data)
        UI.SetupRow(row)
        if not row.star then
            row.star = CreateFrame("Button", nil, row)
            row.star:SetSize(14, 14)
            row.star:SetPoint("LEFT", 4, 0)
            row.star.icon = row.star:CreateTexture(nil, "ARTWORK")
            row.star.icon:SetAllPoints()
            row.star.icon:SetTexture(STAR)
            row.star:SetScript("OnClick", function(self)
                Library.ToggleFavorite(self:GetParent().fileID)
            end)
            row.left:ClearAllPoints()
            row.left:SetPoint("LEFT", row.star, "RIGHT", 6, 0)
            row.left:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
            row.where = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.where:SetJustifyH("RIGHT")
            row.where:SetWordWrap(false)
            row.where:SetPoint("RIGHT", row.right, "LEFT", -10, 0)
            row:SetScript("OnDoubleClick", function(self)
                list.Play(self.index)
            end)
            row:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    list.ShowMenu(self, self.fileID, self.index)
                end
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(Library.TrackName(self.fileID), 1, 1, 1)
                GameTooltip:AddLine(Library.Where(self.fileID), 0.7, 0.7, 0.7)
                if Library.IsForeverTrack(self.fileID) then
                    GameTooltip:AddLine(ns.L["Forever music"], 0.4, 0.8, 1)
                end
                GameTooltip:AddLine(ns.L["Double-click to play. Right-click for more."], 1, 0.82, 0, true)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", GameTooltip_Hide)
        end
        row.fileID, row.index = data.id, data.index
        local playingID = ns.Player.IsPlaying() and ns.Player.GetNowPlaying()
        local name = Library.TrackName(data.id)
        if Library.IsForeverTrack(data.id) then
            name = name .. " |cff66ccff*|r"
        end
        row.left:SetText(name)
        if playingID == data.id then
            row.left:SetTextColor(unpack(PLAYING_COLOR))
        else
            row.left:SetTextColor(1, 1, 1)
        end
        row.right:SetText(Library.FormatTime(Library.TrackSeconds(data.id)))
        -- name runs up to the "where" column when it is shown, else up to the length
        row.left:SetPoint("RIGHT", list.showWhere and row.where or row.right, "LEFT", -8, 0)
        row.where:SetWidth(list.showWhere and 190 or 1)
        row.where:SetText(list.showWhere and Library.Where(data.id) or "")
        local fav = Library.IsFavorite(data.id)
        row.star.icon:SetDesaturated(not fav)
        row.star.icon:SetAlpha(fav and 1 or 0.25)
    end

    local view = CreateScrollBoxListLinearView(2, 2, 2, 2, 0)
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    local box = UI.ScrollList(parent, view)
    list.box = box

    function list.SetTracks(ids, label, showWhere)
        list.ids, list.label, list.showWhere = ids or {}, label, showWhere and true or false
        local dp = CreateDataProvider()
        for i, id in ipairs(list.ids) do
            dp:Insert({ id = id, index = i })
        end
        box:SetDataProvider(dp, ScrollBoxConstants.DiscardScrollPosition)
    end

    function list.Refresh()
        if not box:IsVisible() then return end
        box:ForEachFrame(function(row, data)
            InitRow(row, data)
        end)
    end

    function list.Play(index)
        if #list.ids == 0 then return end
        ns.Player.PlayList(list.ids, index or 1, list.label)
    end

    function list.ShowMenu(owner, fileID, index)
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(Library.TrackName(fileID))
            root:CreateButton(ns.L["Play"], function() list.Play(index) end)
            root:CreateButton(ns.L["Play only this track"], function()
                ns.Player.PlayTrack(fileID, Library.Where(fileID))
            end)
            root:CreateButton(Library.IsFavorite(fileID) and ns.L["Remove from Favorites"] or ns.L["Add to Favorites"],
                function() Library.ToggleFavorite(fileID) end)
            UI.AddPlaylistSubmenu(root, ns.L["Add to playlist"], { fileID })
            if options.extendMenu then options.extendMenu(root, fileID, index) end
        end)
    end

    ns.On("LIBRARY_CHANGED", list.Refresh)
    ns.On("PLAYER_STATE", list.Refresh)
    return list
end

-- "Add to playlist" submenu: existing playlists plus "New playlist…" (named after
-- the tracks' location, renamable later on the Playlists tab).
function UI.AddPlaylistSubmenu(root, text, fileIDs)
    local sub = root:CreateButton(text)
    for _, pl in ipairs(Library.Playlists()) do
        sub:CreateButton(pl.name, function()
            local added = Library.AddToPlaylist(pl, fileIDs)
            ns.Print(string.format(ns.L["Added %d track(s) to %s."], added, pl.name))
        end)
    end
    sub:CreateDivider()
    sub:CreateButton(ns.L["New playlist"], function()
        local base = fileIDs[1] and Library.Where(fileIDs[1]) or ns.L["Playlist"]
        local name, n = base, 1
        while Library.FindPlaylist(name) do
            n = n + 1
            name = base .. " " .. n
        end
        local pl = Library.CreatePlaylist(name)
        if pl then
            Library.AddToPlaylist(pl, fileIDs)
            ns.Print(string.format(ns.L["Created playlist %s."], name))
        end
    end)
end
