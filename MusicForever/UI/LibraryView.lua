local addonName, ns = ...

-- Library tab: folder tree on the left (Zones › Eastern Kingdoms › Elwynn Forest ›
-- Day…), the selected folder's tracks on the right. Search replaces the right
-- side with matches from every level.

local UI = ns.UI
local Library = ns.Library
local LibraryView = {}
ns.LibraryView = LibraryView

local TREE_WIDTH = 290

function LibraryView.Build(parent, searchBox)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local selectedNode, searchText

    -- left: tree -------------------------------------------------------------
    local treePanel = UI.Panel(frame)
    treePanel:SetPoint("TOPLEFT")
    treePanel:SetPoint("BOTTOMLEFT")
    treePanel:SetWidth(TREE_WIDTH)

    -- right: header, buttons, track list ---------------------------------------
    local right = UI.Panel(frame)
    right:SetPoint("TOPLEFT", treePanel, "TOPRIGHT", 6, 0)
    right:SetPoint("BOTTOMRIGHT")

    local header = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 10, -10)
    header:SetPoint("RIGHT", -10, 0)
    header:SetJustifyH("LEFT")
    header:SetWordWrap(false)
    local sub = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
    sub:SetPoint("RIGHT", -10, 0)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)

    local listHolder = CreateFrame("Frame", nil, right)
    listHolder:SetPoint("TOPLEFT", 4, -72)
    listHolder:SetPoint("BOTTOMRIGHT", -4, 4)
    local tracks = UI.TrackList(listHolder)

    local playAll = UI.Button(right, ns.L["Play all"], 90, function() tracks.Play(1) end)
    playAll:SetPoint("TOPLEFT", 8, -44)
    local shuffleAll = UI.Button(right, ns.L["Shuffle"], 80, function()
        ns.Player.SetShuffle(true)
        tracks.Play(math.random(math.max(1, #tracks.ids)))
    end)
    shuffleAll:SetPoint("LEFT", playAll, "RIGHT", 6, 0)
    local addAll = UI.Button(right, ns.L["Add to playlist"], 120, nil)
    addAll:SetPoint("LEFT", shuffleAll, "RIGHT", 6, 0)
    addAll:SetScript("OnClick", function(self)
        if #tracks.ids == 0 then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            UI.AddPlaylistSubmenu(root, ns.L["Add all to playlist"], tracks.ids, tracks.label)
        end)
    end)

    local function ShowNode(node)
        selectedNode = node
        if not node then
            header:SetText(ns.L["Music library"])
            sub:SetText(ns.L["Pick a folder on the left, or search."])
            tracks.SetTracks({})
            return
        end
        local ids = Library.Collect(node)
        header:SetText(node.name)
        sub:SetText(string.format("%s   ·   %d %s", Library.PathOf(node), #ids,
            #ids == 1 and ns.L["track"] or ns.L["tracks"]))
        local label = node.name
        if node.parent and node.parent.parent and (node.name == "Music" or node.name == "Day"
                or node.name == "Night" or node.name == "Intro") then
            label = node.parent.name .. " · " .. node.name
        end
        tracks.SetTracks(ids, label, #node.children > 0)
    end

    local function ShowSearch(text)
        local ids = Library.Search(text)
        header:SetText(string.format(ns.L["Search: %s"], text))
        sub:SetText(string.format("%d %s", #ids, #ids == 1 and ns.L["track"] or ns.L["tracks"]))
        tracks.SetTracks(ids, string.format(ns.L["Search: %s"], text), true)
    end

    -- tree rows
    local treeBox
    local function RefreshTreeSelection()
        treeBox:ForEachFrame(function(row, treeNode)
            row.selected:SetShown(treeNode:GetData().node == selectedNode and not searchText)
        end)
    end

    local function InitTreeRow(row, treeNode)
        UI.SetupRow(row)
        local node = treeNode:GetData().node
        local hasKids = #node.children > 0
        local glyph = hasKids and (treeNode:IsCollapsed() and "|cffffd100+|r " or "|cffffd100-|r ") or "   "
        row.left:SetFontObject(node.depth == 1 and "GameFontNormal" or "GameFontHighlight")
        row.left:SetText(glyph .. node.name)
        row.right:SetText(node.total > 0 and node.total or "")
        row.selected:SetShown(node == selectedNode and not searchText)
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                local ids = Library.Collect(node)
                MenuUtil.CreateContextMenu(self, function(_, root)
                    root:CreateTitle(node.name)
                    root:CreateButton(ns.L["Play all"], function() ns.Player.PlayList(ids, 1, node.name) end)
                    root:CreateButton(ns.L["Shuffle"], function()
                        ns.Player.SetShuffle(true)
                        ns.Player.PlayList(ids, math.random(math.max(1, #ids)), node.name)
                    end)
                    UI.AddPlaylistSubmenu(root, ns.L["Add all to playlist"], ids, node.name)
                end)
                return
            end
            if searchText then
                searchBox:SetText("")
                searchBox:ClearFocus()
            end
            if hasKids then treeNode:ToggleCollapsed() end
            ShowNode(node)
            RefreshTreeSelection()
        end)
    end

    local treeView = CreateScrollBoxListTreeListView(12, 2, 2, 2, 2, 0)
    treeView:SetElementExtent(UI.ROW_HEIGHT)
    treeView:SetElementInitializer("Button", InitTreeRow)
    treeBox = UI.ScrollList(treePanel, treeView)

    local function BuildTree()
        local dp = CreateTreeDataProvider()
        local function add(parentTreeNode, node)
            local tn = parentTreeNode:Insert({ node = node })
            for _, c in ipairs(node.children) do add(tn, c) end
            if #node.children > 0 then
                local affectChildren, skipInvalidate = false, true
                tn:SetCollapsed(true, affectChildren, skipInvalidate)
            end
        end
        for _, top in ipairs(Library.root and Library.root.children or {}) do
            add(dp, top)
        end
        treeBox:SetDataProvider(dp)
    end

    -- search (debounced)
    local searchTimer
    searchBox:HookScript("OnTextChanged", function(self)
        if searchTimer then searchTimer:Cancel() end
        searchTimer = C_Timer.NewTimer(0.25, function()
            searchTimer = nil
            local text = strtrim(self:GetText() or "")
            if text == "" then
                searchText = nil
                ShowNode(selectedNode)
            else
                searchText = text
                ShowSearch(text)
            end
            RefreshTreeSelection()
        end)
    end)

    BuildTree()
    ShowNode(nil)

    return {
        frame = frame,
        OnShow = function() tracks.Refresh() end,
    }
end
