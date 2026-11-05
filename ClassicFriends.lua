local ADDON_NAME = ...

-- ClassicFriends draws a classic friends list over the Friends tab of Forever's
-- Social UI (SocialUIFrame.FriendsList, Blizzard_SocialUI/Mainline/SocialUI.lua).
--
-- Taint rules this file keeps:
--   * No Blizzard frame is hidden, moved, re-parented or hooked. The list is a
--     child frame drawn above Blizzard's content frame and hidden with it.
--   * Party invites and menus run from the click that asked for them.
--   * Only plain booleans go into SavedVariables.
--
-- Layout, textures and colours follow the Classic Era friends list
-- (Blizzard_UIPanels_Game/Classic/FriendsFrame.xml, FriendsFrameButtonTemplate).
-- The colours are restated here because the Mainline family that Forever loads
-- does not define all of the classic FRIENDS_* constants.

local ROW_HEIGHT = 34
local DIVIDER_HEIGHT = 16
local LIST_INSET = 8
local SCROLLBAR_GUTTER = 30
local BUTTON_AREA = 40
local NAME_LEFT = 20
local ROW_RIGHT_CONTROLS = 51 -- game icon (24) + invite button (24) + spacing
local FAVORITE_SIZE = 12

local OFFLINE_NAME_COLOR = CreateColor(0.486, 0.518, 0.541)
local BNET_BACKGROUND = CreateColor(0, 0.694, 0.941, 0.05)
local OFFLINE_BACKGROUND = CreateColor(0.588, 0.588, 0.588, 0.05)
local HIGHLIGHT_TINT = CreateColor(0.243, 0.570, 1)
local WOW_NAME_CODE = "|cfffde05c"
local OTHER_NAME_CODE = "|cff7b8489"

local TEXTURE_ONLINE = "Interface\\FriendsFrame\\StatusIcon-Online"
local TEXTURE_AFK = "Interface\\FriendsFrame\\StatusIcon-Away"
local TEXTURE_DND = "Interface\\FriendsFrame\\StatusIcon-DnD"
local TEXTURE_OFFLINE = "Interface\\FriendsFrame\\StatusIcon-Offline"
local TEXTURE_DIVIDER = "Interface\\FriendsFrame\\UI-FriendsFrame-OnlineDivider"
local TEXTURE_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestLogTitleHighlight"
local TEXTURE_SCROLL_TRACK = "Interface\\PaperDollInfoFrame\\UI-Character-ScrollBar"

local EVENTS = {
	"BN_FRIEND_LIST_SIZE_CHANGED",
	"BN_FRIEND_INFO_CHANGED",
	"BN_FRIEND_ACCOUNT_ONLINE",
	"BN_FRIEND_ACCOUNT_OFFLINE",
	"BN_CONNECTED",
	"BN_DISCONNECTED",
	"GROUP_ROSTER_UPDATE",
	"PARTY_LEADER_CHANGED",
}

-- Methods taken from Blizzard's own friend card and party button, so the
-- tooltip, right-click menu and invite flow behave exactly like the stock list.
-- Both mixins live in Blizzard_FriendsFrame/Mainline/FriendsListTemplates.lua.
local CARD_METHODS = { "IsOnline", "HasNote", "HasTags", "BuildTooltip", "ShowTooltip", "HideTooltip", "OpenMenu" }
local PARTY_METHODS = { "RefreshDynamicData", "HasInviteRestriction", "BuildTooltip", "ShowTooltip", "TryInviteFriend" }

local overlay, scrollFrame, scrollChild, divider, unavailableText, addFriendButton, sendMessageButton
local rows = {}
local selectedAccountID
local refreshQueued = false

local function HasMethods(source, names)
	if type(source) ~= "table" then
		return false
	end
	for _, name in ipairs(names) do
		if type(source[name]) ~= "function" then
			return false
		end
	end
	return true
end

local function Borrow(target, source, names)
	for _, name in ipairs(names) do
		target[name] = source[name]
	end
end

local function GetTooltip()
	return GetAppropriateTooltip and GetAppropriateTooltip() or GameTooltip
end

local function HideOwnedTooltip(owner)
	local tooltip = GetTooltip()
	if tooltip:IsOwned(owner) then
		tooltip:Hide()
	end
end

local function IsBattleNetConnected()
	if BNConnected then
		return BNConnected()
	end
	return true
end

-- Online friends first, offline after; favorites lead each group, then
-- Blizzard's own friend order.
local function CompareEntries(a, b)
	local aFavorite = a.accountInfo.isFavorite and 1 or 0
	local bFavorite = b.accountInfo.isFavorite and 1 or 0
	if aFavorite ~= bFavorite then
		return aFavorite > bFavorite
	end
	return a.friendIndex < b.friendIndex
end

local function CollectFriends()
	local online, offline = {}, {}
	local numFriends = BNGetNumFriends() or 0
	for friendIndex = 1, numFriends do
		local accountInfo = C_BattleNet.GetFriendAccountInfo(friendIndex)
		if accountInfo and accountInfo.gameAccountInfo then
			local entry = { friendIndex = friendIndex, accountInfo = accountInfo }
			if accountInfo.gameAccountInfo.isOnline then
				online[#online + 1] = entry
			else
				offline[#offline + 1] = entry
			end
		end
	end
	table.sort(online, CompareEntries)
	table.sort(offline, CompareEntries)
	return online, offline
end

local function GetStatusTexture(accountInfo)
	local game = accountInfo.gameAccountInfo
	if not game.isOnline then
		return TEXTURE_OFFLINE
	elseif accountInfo.isAFK or game.isGameAFK then
		return TEXTURE_AFK
	elseif accountInfo.isDND or game.isGameBusy then
		return TEXTURE_DND
	end
	return TEXTURE_ONLINE
end

-- Gold when the character can be grouped with, grey otherwise (classic rule).
local function GetCharacterNameCode(game)
	if FriendsListUtil.IsPlayingSameWoWProject(game)
		and FriendsListUtil.GetGameAccountPartyInviteRestriction(game) == BattleNetFriendPartyInviteRestrictionType.None then
		return WOW_NAME_CODE
	end
	return OTHER_NAME_CODE
end

-- "Account (Character), Level 15 Rogue" for an online WoW friend, otherwise
-- just the account name.
local function BuildNameText(accountInfo)
	local game = accountInfo.gameAccountInfo
	local accountName = BNet_GetBNetAccountName(accountInfo) or UNKNOWN
	if not game.isOnline then
		return OFFLINE_NAME_COLOR:WrapTextInColorCode(accountName)
	end

	local nameColor = FriendsListUtil.GetFriendNameColorForFriendType(accountInfo)
	local text = nameColor:WrapTextInColorCode(accountName)
	if not game.characterName or game.characterName == "" then
		return text
	end

	local detail = "(" .. FriendsListUtil.GetFormattedCharacterName(accountInfo) .. ")"
	local hasLevelAndClass = game.characterLevel and game.characterLevel > 0 and game.className and game.className ~= ""
	if FriendsListUtil.IsPlayingSameWoWProject(game) and hasLevelAndClass then
		detail = detail .. ", " .. FRIENDS_LEVEL_TEMPLATE:format(game.characterLevel, game.className)
	end
	return text .. " " .. GetCharacterNameCode(game) .. detail .. FONT_COLOR_CODE_CLOSE
end

-- Fixed width, never measured: Battle.net account names are protected
-- |K...|k strings that the client resolves only when drawing, so measuring
-- them returns 0 and would shrink the name to nothing. The favorite star
-- has its own fixed spot next to the game icon.
local function LayoutName(row, contentWidth, showFavorite)
	local reserve = NAME_LEFT + ROW_RIGHT_CONTROLS + FAVORITE_SIZE + 4
	row.name:SetWidth(math.max(40, contentWidth - reserve))
	row.favorite:SetShown(showFavorite)
end

local function UpdateRowSelection(row)
	if row.accountID and row.accountID == selectedAccountID then
		row:LockHighlight()
	else
		row:UnlockHighlight()
	end
end

local function UpdateButtons()
	local friendsDisabled = C_SocialRestrictions and C_SocialRestrictions.IsFriendsDisabled and C_SocialRestrictions.IsFriendsDisabled()
	addFriendButton:SetEnabled(not friendsDisabled)

	local canMessage = false
	for _, row in ipairs(rows) do
		if row:IsShown() and row.accountID and row.accountID == selectedAccountID then
			canMessage = row.elementData.accountInfo.gameAccountInfo.isOnline
			break
		end
	end
	sendMessageButton:SetEnabled(canMessage)
end

local function SetRowData(row, entry, contentWidth)
	local accountInfo = entry.accountInfo
	local game = accountInfo.gameAccountInfo
	local isOnline = game.isOnline

	row.elementData = entry
	row.accountID = accountInfo.bnetAccountID

	local background = isOnline and BNET_BACKGROUND or OFFLINE_BACKGROUND
	row.background:SetColorTexture(background:GetRGBA())
	row.status:SetTexture(GetStatusTexture(accountInfo))

	row.name:SetText(BuildNameText(accountInfo))
	LayoutName(row, contentWidth, accountInfo.isFavorite)
	row.favorite:SetDesaturated(not isOnline)
	row.info:SetText(FriendsListUtil.BuildLocationDisplayText(accountInfo))

	if isOnline then
		C_Texture.SetTitleIconTexture(row.gameIcon, game.clientProgram, Enum.TitleIconVersion.Medium, game.subIcon)
		row.gameIcon:SetAlpha(FriendsListUtil.IsPlayingDifferentWoWProject(game) and 0.6 or 1)
		row.gameIcon:Show()
	else
		row.gameIcon:Hide()
	end

	local invite = row.inviteButton
	invite.friendIndex = entry.friendIndex
	invite.playerGUID = game.playerGuid
	invite.isOnline = isOnline
	-- Keeps Blizzard's invite code away from its cross-faction tutorial
	-- HelpTip; the tooltip still shows cross-faction details.
	invite.isCrossFactionFriend = false
	if isOnline then
		invite:RefreshDynamicData()
		invite:SetEnabled(not invite:HasInviteRestriction())
		invite:Show()
	else
		invite:Hide()
	end

	UpdateRowSelection(row)
end

local function OnRowClick(row, mouseButton)
	if not row.elementData then
		return
	end
	if mouseButton == "RightButton" then
		row:OpenMenu()
		return
	end

	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	selectedAccountID = row.accountID
	for _, other in ipairs(rows) do
		UpdateRowSelection(other)
	end
	UpdateButtons()
end

local function CreateInviteButton(row)
	local invite = CreateFrame("Button", nil, row)
	invite:SetSize(24, 32)
	invite:SetPoint("TOPRIGHT", 1, -1)
	invite:SetNormalAtlas("friendslist-invitebutton-default-normal")
	invite:SetPushedAtlas("friendslist-invitebutton-default-pressed")
	invite:SetDisabledAtlas("friendslist-invitebutton-default-disabled")
	invite:SetHighlightAtlas("friendslist-invitebutton-highlight", "ADD")
	invite:SetMotionScriptsWhileDisabled(true)
	Borrow(invite, FriendsListSocialCardPartyButtonMixin, PARTY_METHODS)
	invite:SetScript("OnEnter", function(self) self:ShowTooltip() end)
	invite:SetScript("OnLeave", HideOwnedTooltip)
	invite:SetScript("OnClick", function(self) self:TryInviteFriend() end)
	return invite
end

local function CreateRow()
	local row = CreateFrame("Button", nil, scrollChild)
	row:SetHeight(ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	Borrow(row, FriendsListSocialCardMixin, CARD_METHODS)

	row.background = row:CreateTexture(nil, "BACKGROUND")
	row.background:SetPoint("TOPLEFT", 0, -1)
	row.background:SetPoint("BOTTOMRIGHT", 0, 1)

	row:SetHighlightTexture(TEXTURE_HIGHLIGHT, "ADD")
	local highlight = row:GetHighlightTexture()
	highlight:ClearAllPoints()
	highlight:SetPoint("TOPLEFT", 0, -1)
	highlight:SetPoint("BOTTOMRIGHT", 0, 1)
	highlight:SetVertexColor(HIGHLIGHT_TINT:GetRGB())

	row.status = row:CreateTexture(nil, "ARTWORK")
	row.status:SetSize(16, 16)
	row.status:SetPoint("TOPLEFT", 4, -3)

	row.inviteButton = CreateInviteButton(row)

	row.gameIcon = row:CreateTexture(nil, "ARTWORK")
	row.gameIcon:SetSize(24, 24)
	row.gameIcon:SetPoint("TOPRIGHT", -25, -5)

	row.name = row:CreateFontString(nil, "ARTWORK", "FriendsFont_Normal")
	row.name:SetHeight(12)
	row.name:SetPoint("TOPLEFT", NAME_LEFT, -4)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.name:SetTextColor(1, 1, 1)

	row.favorite = row:CreateTexture(nil, "ARTWORK")
	row.favorite:SetAtlas("friendslist-favorite")
	row.favorite:SetSize(FAVORITE_SIZE, FAVORITE_SIZE)
	row.favorite:SetPoint("TOPRIGHT", row, "TOPRIGHT", -ROW_RIGHT_CONTROLS - 2, -4)

	row.info = row:CreateFontString(nil, "ARTWORK", "FriendsFont_Small")
	row.info:SetHeight(10)
	row.info:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
	row.info:SetPoint("RIGHT", row, "RIGHT", -ROW_RIGHT_CONTROLS - 4, 0)
	row.info:SetJustifyH("LEFT")
	row.info:SetWordWrap(false)
	row.info:SetTextColor(OFFLINE_NAME_COLOR:GetRGB())

	row:SetScript("OnClick", OnRowClick)
	row:SetScript("OnEnter", function(self)
		if self.elementData then
			self:ShowTooltip()
		end
	end)
	row:SetScript("OnLeave", HideOwnedTooltip)
	return row
end

local function Refresh()
	refreshQueued = false
	if not overlay or not overlay:IsVisible() then
		return
	end

	local contentWidth = scrollFrame:GetWidth()
	if contentWidth < 1 then
		return -- not laid out yet; OnSizeChanged queues the next refresh
	end
	scrollChild:SetWidth(contentWidth)

	local connected = IsBattleNetConnected()
	local online, offline = {}, {}
	if connected then
		online, offline = CollectFriends()
	end
	unavailableText:SetShown(not connected)

	local y, used = 0, 0
	local selectionStillListed = false
	local function Place(entry)
		used = used + 1
		local row = rows[used]
		if not row then
			row = CreateRow()
			rows[used] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		row:SetPoint("TOPRIGHT", 0, -y)
		SetRowData(row, entry, contentWidth)
		row:Show()
		if row.accountID == selectedAccountID then
			selectionStillListed = true
		end
		y = y + ROW_HEIGHT
	end

	for _, entry in ipairs(online) do
		Place(entry)
	end
	if #online > 0 and #offline > 0 then
		divider:ClearAllPoints()
		divider:SetPoint("TOPLEFT", 0, -y)
		divider:SetPoint("TOPRIGHT", 0, -y)
		divider:Show()
		y = y + DIVIDER_HEIGHT
	else
		divider:Hide()
	end
	for _, entry in ipairs(offline) do
		Place(entry)
	end

	for index = used + 1, #rows do
		local row = rows[index]
		HideOwnedTooltip(row)
		HideOwnedTooltip(row.inviteButton)
		row:Hide()
		row.elementData = nil
		row.accountID = nil
	end
	scrollChild:SetHeight(math.max(y, 1))

	if not selectionStillListed then
		selectedAccountID = nil
	end
	UpdateButtons()

	-- A refresh can change the friend under the cursor; rebuild its tooltip.
	local tooltip = GetTooltip()
	for index = 1, used do
		local row = rows[index]
		if tooltip:IsOwned(row) then
			row:ShowTooltip()
		elseif tooltip:IsOwned(row.inviteButton) and row.inviteButton:IsShown() then
			row.inviteButton:ShowTooltip()
		end
	end
end

local function QueueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	C_Timer.After(0, Refresh)
end

local function SendMessageToSelected()
	for _, row in ipairs(rows) do
		if row:IsShown() and row.accountID and row.accountID == selectedAccountID then
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
			ChatFrameUtil.SendBNetTell(row.elementData.accountInfo.accountName)
			return
		end
	end
end

local function CreateScrollTrack()
	-- The classic scroll bar track, drawn behind the scroll bar.
	local top = scrollFrame:CreateTexture(nil, "BACKGROUND")
	top:SetTexture(TEXTURE_SCROLL_TRACK)
	top:SetSize(29, 102)
	top:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", -6, 5)
	top:SetTexCoord(0, 0.445, 0, 0.4)

	local bottom = scrollFrame:CreateTexture(nil, "BACKGROUND")
	bottom:SetTexture(TEXTURE_SCROLL_TRACK)
	bottom:SetSize(29, 106)
	bottom:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", -6, -5)
	bottom:SetTexCoord(0.515625, 0.960625, 0, 0.4140625)

	local middle = scrollFrame:CreateTexture(nil, "BACKGROUND")
	middle:SetTexture(TEXTURE_SCROLL_TRACK)
	middle:SetWidth(29)
	middle:SetPoint("TOP", top, "BOTTOM")
	middle:SetPoint("BOTTOM", bottom, "TOP")
	middle:SetTexCoord(0, 0.445, 0.75, 1)
end

local function CreateOverlay(host)
	overlay = CreateFrame("Frame", "ClassicFriendsListFrame", host)
	overlay:SetAllPoints(host)
	overlay:SetFrameLevel(math.min(host:GetFrameLevel() + 100, 9000))
	-- Swallow clicks and wheel input so nothing reaches Blizzard's list underneath.
	overlay:EnableMouse(true)
	overlay:EnableMouseWheel(true)
	overlay:SetScript("OnMouseWheel", function() end)

	local background = overlay:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 1)

	scrollFrame = CreateFrame("ScrollFrame", "ClassicFriendsScrollFrame", overlay, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", LIST_INSET, -LIST_INSET)
	scrollFrame:SetPoint("BOTTOMRIGHT", -SCROLLBAR_GUTTER, BUTTON_AREA)
	scrollFrame.ScrollBar.scrollStep = ROW_HEIGHT * 2
	scrollFrame:HookScript("OnSizeChanged", QueueRefresh)
	CreateScrollTrack()

	scrollChild = CreateFrame("Frame", nil, scrollFrame)
	scrollChild:SetSize(1, 1)
	scrollFrame:SetScrollChild(scrollChild)

	divider = scrollChild:CreateTexture(nil, "ARTWORK")
	divider:SetTexture(TEXTURE_DIVIDER)
	divider:SetHeight(DIVIDER_HEIGHT)
	divider:Hide()

	unavailableText = overlay:CreateFontString(nil, "ARTWORK", "FriendsFont_Normal")
	unavailableText:SetPoint("CENTER", scrollFrame, "CENTER")
	unavailableText:SetTextColor(OFFLINE_NAME_COLOR:GetRGB())
	unavailableText:SetText(BATTLENET_UNAVAILABLE)
	unavailableText:Hide()

	addFriendButton = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
	addFriendButton:SetHeight(22)
	addFriendButton:SetPoint("BOTTOMLEFT", LIST_INSET, 10)
	addFriendButton:SetPoint("RIGHT", overlay, "CENTER", -4, 0)
	addFriendButton:SetText(ADD_FRIEND)
	addFriendButton:SetScript("OnClick", function()
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		AddFriendFrame_Show()
	end)

	sendMessageButton = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
	sendMessageButton:SetHeight(22)
	sendMessageButton:SetPoint("BOTTOMRIGHT", -LIST_INSET, 10)
	sendMessageButton:SetPoint("LEFT", overlay, "CENTER", 4, 0)
	sendMessageButton:SetText(SEND_MESSAGE)
	sendMessageButton:SetScript("OnClick", SendMessageToSelected)

	overlay:SetScript("OnShow", function(self)
		for _, event in ipairs(EVENTS) do
			self:RegisterEvent(event)
		end
		scrollFrame.ScrollBar:SetValue(0)
		Refresh()
	end)
	overlay:SetScript("OnHide", function(self)
		self:UnregisterAllEvents()
	end)
	overlay:SetScript("OnEvent", QueueRefresh)
end

local function ApplyEnabled()
	if overlay then
		overlay:SetShown(ClassicFriendsDB.enabled)
	end
end

local function Install()
	local host = SocialUIFrame and SocialUIFrame.FriendsList
	if not host then
		return -- this client has no Battle.net friends tab
	end
	local ready = FriendsListUtil and BattleNetFriendPartyInviteRestrictionType and C_BattleNet
		and HasMethods(FriendsListSocialCardMixin, CARD_METHODS)
		and HasMethods(FriendsListSocialCardPartyButtonMixin, PARTY_METHODS)
	if not ready then
		print("ClassicFriends: this client's friends list has changed; showing Blizzard's list instead.")
		return
	end
	CreateOverlay(host)
	ApplyEnabled()
end

SLASH_CLASSICFRIENDS1 = "/classicfriends"
SlashCmdList.CLASSICFRIENDS = function()
	ClassicFriendsDB.enabled = not ClassicFriendsDB.enabled
	ApplyEnabled()
	if ClassicFriendsDB.enabled then
		print("ClassicFriends: classic friends list on.")
	else
		print("ClassicFriends: off. Blizzard's friends list is shown.")
	end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
	if type(ClassicFriendsDB) ~= "table" then
		ClassicFriendsDB = {}
	end
	if type(ClassicFriendsDB.enabled) ~= "boolean" then
		ClassicFriendsDB.enabled = true
	end
	EventUtil.ContinueOnAddOnLoaded("Blizzard_SocialUI", Install)
end)
