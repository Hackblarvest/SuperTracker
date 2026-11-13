-- SuperTracker: turns on WoW's in-world navigation marker on WoW: Forever.
-- The client ships the full retail feature (C_Navigation + Blizzard_QuestNavigation), but the
-- showInGameNavigation CVar defaults to 0 and the option is not in the menus.

local ADDON = ...
local CVAR = "showInGameNavigation"
local PREFIX = "|cff33ff99SuperTracker|r: "

local db
local setting -- the Settings panel checkbox

local function say(msg)
	print(PREFIX .. msg)
end

local function applyCVar()
	local wanted = db.enabled and "1" or "0"
	if C_CVar.GetCVar(CVAR) ~= wanted then
		C_CVar.SetCVar(CVAR, wanted)
	end
end

local function setEnabled(value)
	db.enabled = value and true or false
	applyCVar()
	if setting and setting:GetValue() ~= db.enabled then
		setting:SetValue(db.enabled)
	end
end

---------------------------------------------------------------------------------------------------
-- Auto-track: when nothing is super-tracked (quest turned in or abandoned, map pin cleared or reached),
-- track the nearest quest in the log. Blizzard already tracks a newly accepted quest when nothing is
-- tracked (QuestUtil.CheckAutoSuperTrackQuest) and clears the quest on turn-in, but never picks a new one.

local function isPlain(v)
	return v ~= nil and not (issecretvalue and issecretvalue(v))
end

local function nearestQuest()
	local bestID, bestDist
	for i = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(i)
		local questID = info and not info.isHeader and not info.isHidden and info.questID
		if questID and isPlain(questID) and questID > 0 and not C_QuestLog.IsQuestTask(questID) then
			local distSq, onContinent = C_QuestLog.GetDistanceSqToQuest(questID)
			if isPlain(distSq) and isPlain(onContinent) and onContinent and (not bestDist or distSq < bestDist) then
				bestID, bestDist = questID, distSq
			end
		end
	end
	return bestID
end

local pendingAutoTrack = false

-- Nothing tracked, or only a quest that has left the quest log (abandoned).
local function needsTarget()
	if not C_SuperTrack.IsSuperTrackingAnything() then return true end
	if C_SuperTrack.IsSuperTrackingQuest() then
		local questID = C_SuperTrack.GetSuperTrackedQuestID()
		return isPlain(questID) and questID > 0 and not C_QuestLog.GetLogIndexForQuestID(questID)
	end
	return false
end

local function autoTrack()
	pendingAutoTrack = false
	if not db.autoTrack or not needsTarget() then return end
	local questID = nearestQuest()
	if questID then
		C_SuperTrack.SetSuperTrackedQuestID(questID)
	end
end

-- Wait a moment so the quest log and Blizzard's own tracking logic settle first.
local function scheduleAutoTrack(delay)
	if pendingAutoTrack or not db.autoTrack then return end
	pendingAutoTrack = true
	C_Timer.After(delay or 1, autoTrack)
end

---------------------------------------------------------------------------------------------------
-- Follow the RestedXP arrow (optional). RestedXP super-tracks the quest of a quest step itself, but the
-- target of its own arrow (go-to steps) never reaches Blizzard. This mirrors that target into a map pin
-- so the in-world marker follows the guide. RXPG_ARROW.element and RXP.hideArrow are RestedXP internals,
-- not an API: if they change shape the check does nothing, and an error turns following off.
-- A pin set by anyone else (/way, a map click, another add-on) is never replaced; once it is cleared the
-- marker goes back to the arrow target.

local FOLLOW_INTERVAL = 0.5
local followTicker
local lastElement, lastActive, lastZone, lastX, lastY -- arrow target seen on the previous check
local pinZone, pinX, pinY -- the pin we set, so we only ever clear our own

local function isOurPin()
	if not pinZone then return false end
	local point = C_Map.GetUserWaypoint()
	return point ~= nil and point.uiMapID == pinZone
		and math.abs(point.position.x - pinX) < 1e-4 and math.abs(point.position.y - pinY) < 1e-4
end

local function clearOurPin()
	if isOurPin() then C_Map.ClearUserWaypoint() end
	pinZone, pinX, pinY = nil, nil, nil
end

-- Runs every FOLLOW_INTERVAL seconds: a few table reads and no allocations unless the target changed.
local function checkRXPArrow()
	local arrow = _G.RXPG_ARROW
	if not arrow then return end
	local element = type(arrow.element) == "table" and arrow.element or nil

	-- RestedXP keeps the last target in .element and flags "no target" with hideArrow; this also works
	-- when the player has switched the RestedXP arrow itself off.
	local rxp = _G.RXP
	local active
	if type(rxp) == "table" and rxp.hideArrow ~= nil then
		active = not rxp.hideArrow
	else
		active = arrow:IsShown()
	end

	local zone, x, y
	if element then zone, x, y = element.zone, element.zx, element.zy end
	if element == lastElement and active == lastActive and zone == lastZone and x == lastX and y == lastY then
		return
	end
	lastElement, lastActive, lastZone, lastX, lastY = element, active, zone, x, y

	if active and type(zone) == "number" and type(x) == "number" and type(y) == "number"
		and x >= 0 and x <= 1 and y >= 0 and y <= 1 and C_Map.CanSetUserWaypointOnMap(zone) then
		if C_Map.HasUserWaypoint() and not isOurPin() then
			return -- someone else's pin: leave it, onUserWaypointUpdated brings us back when it is gone
		end
		if C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(zone, x, y)) then
			pinZone, pinX, pinY = zone, x, y
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		end
	else
		clearOurPin()
	end
end

-- USER_WAYPOINT_UPDATED: keep track of whose pin is on the map.
local function onUserWaypointUpdated()
	if not followTicker then return end
	if C_Map.HasUserWaypoint() then
		if pinZone and not isOurPin() then
			pinZone, pinX, pinY = nil, nil, nil -- ours was replaced by someone else's pin
		end
	elseif pinZone then
		-- our pin was reached (Blizzard clears it) or cleared by hand: wait for the arrow to move on
		pinZone, pinX, pinY = nil, nil, nil
	else
		lastElement = nil -- someone else's pin is gone: show the arrow target again on the next check
	end
end

local stopFollowing

local function followTick()
	local ok = pcall(checkRXPArrow)
	if not ok then
		pcall(stopFollowing)
		say("could not read the RestedXP arrow (RestedXP may have changed), so following is off for now.")
	end
end

local function startFollowing()
	if followTicker or not db.followRXP then return end
	if not C_AddOns.IsAddOnLoaded("RXPGuides") then return end
	lastElement, lastActive = nil, nil
	followTicker = C_Timer.NewTicker(FOLLOW_INTERVAL, followTick)
	followTick()
end

function stopFollowing()
	if followTicker then
		followTicker:Cancel()
		followTicker = nil
	end
	clearOurPin()
end

---------------------------------------------------------------------------------------------------
-- Settings panel (Options -> AddOns -> SuperTracker)

local category
local rxpSetting

local function registerSettings()
	category = Settings.RegisterVerticalLayoutCategory("SuperTracker")
	setting = Settings.RegisterAddOnSetting(category, "SUPERTRACKER_ENABLED", "enabled", db, "boolean",
		"In-world navigation marker", true)
	setting:SetValueChangedCallback(function(_, value)
		db.enabled = value
		applyCVar()
	end)
	Settings.CreateCheckbox(category, setting,
		"Show the marker and distance for the quest or map pin you are tracking.\n\n"
		.. "Click a quest in the objective tracker to track it. Sets the hidden '" .. CVAR .. "' option.")

	local autoSetting = Settings.RegisterAddOnSetting(category, "SUPERTRACKER_AUTOTRACK", "autoTrack", db,
		"boolean", "Auto-track nearest quest", true)
	autoSetting:SetValueChangedCallback(function(_, value)
		if value then scheduleAutoTrack(0.1) end
	end)
	Settings.CreateCheckbox(category, autoSetting,
		"When nothing is tracked (a quest was turned in or abandoned, or a map pin was cleared or reached), "
		.. "automatically track the nearest quest in your quest log.")

	rxpSetting = Settings.RegisterAddOnSetting(category, "SUPERTRACKER_FOLLOWRXP", "followRXP", db,
		"boolean", "Follow RestedXP arrow", false)
	rxpSetting:SetValueChangedCallback(function(_, value)
		if value then
			startFollowing()
			if not C_AddOns.IsAddOnLoaded("RXPGuides") then
				say("RestedXP Guides is not loaded; following starts once it is.")
			end
		else
			stopFollowing()
		end
	end)
	Settings.CreateCheckbox(category, rxpSetting,
		"Requires RestedXP Guides. The marker follows the RestedXP guide arrow: wherever the arrow points, "
		.. "SuperTracker places a map pin and tracks it. Also works with the RestedXP arrow itself hidden. "
		.. "A pin you set with /way pauses following until you clear it.")

	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------------------------------
-- /way [mapID] x y [description]

local function parseNumbers(msg)
	local nums, rest = {}, msg
	while #nums < 3 do
		local num, after = rest:match("^%s*,?%s*([%d%.]+)(.*)$")
		if not num or not tonumber(num) then break end
		nums[#nums + 1] = tonumber(num)
		rest = after
	end
	return nums, (rest:match("^%s*(.-)%s*$"))
end

local function way(msg)
	msg = msg or ""
	local cmd = msg:lower():match("^%s*(%S*)")
	if cmd == "clear" or cmd == "reset" then
		C_Map.ClearUserWaypoint()
		say("map pin cleared.")
		return
	end

	-- Allow "#1429 42.5 66.6" as well as "1429 42.5 66.6".
	local nums, desc = parseNumbers((msg:gsub("^%s*#", "")))
	local mapID, x, y
	if #nums == 3 then
		mapID, x, y = nums[1], nums[2], nums[3]
	elseif #nums == 2 then
		mapID, x, y = C_Map.GetBestMapForUnit("player"), nums[1], nums[2]
	else
		say("usage: /way [mapID] x y  (for example /way 42.5 66.6), or /way clear")
		return
	end

	if not mapID then
		say("could not find your current map.")
		return
	end
	if x < 0 or x > 100 or y < 0 or y > 100 then
		say("coordinates must be between 0 and 100.")
		return
	end
	if not C_Map.CanSetUserWaypointOnMap(mapID) then
		say("map pins are not allowed on this map.")
		return
	end

	local point = UiMapPoint.CreateFromCoordinates(mapID, x / 100, y / 100)
	if not C_Map.SetUserWaypoint(point) then
		say("the client refused the map pin.")
		return
	end
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)

	local info = C_Map.GetMapInfo(mapID)
	local where = info and info.name or ("map " .. mapID)
	say(("pin set at %.1f, %.1f in %s%s."):format(x, y, where, desc ~= "" and (" (" .. desc .. ")") or ""))
	if not db.enabled then
		say("the in-world marker is off; turn it on with /supertracker on.")
	end
	if followTicker then
		say("following the RestedXP arrow is paused until you clear this pin (/way clear).")
	end
end

---------------------------------------------------------------------------------------------------
-- /supertracker cpu: the client's add-on profiler (times in milliseconds per frame).

local function cpuReport()
	if not (C_AddOnProfiler and C_AddOnProfiler.IsEnabled()) then
		say("the add-on profiler is not available in this client.")
		return
	end
	local M = Enum.AddOnProfilerMetric
	local function line(label, get)
		local ok, session, recent, peak, over1 = pcall(function()
			return get(M.SessionAverageTime), get(M.RecentAverageTime), get(M.PeakTime), get(M.CountTimeOver1Ms)
		end)
		if ok then
			say(("%s: average %.4f ms, last 60 frames %.4f ms, peak %.3f ms, frames over 1 ms: %d")
				:format(label, session, recent, peak, over1))
		else
			say(label .. ": no data.")
		end
	end
	line("SuperTracker", function(m) return C_AddOnProfiler.GetAddOnMetric(ADDON, m) end)
	if C_AddOns.IsAddOnLoaded("RXPGuides") then
		line("RestedXP Guides", function(m) return C_AddOnProfiler.GetAddOnMetric("RXPGuides", m) end)
	end
	line("All add-ons", function(m) return C_AddOnProfiler.GetOverallMetric(m) end)
	say("following the RestedXP arrow: " .. (followTicker and "on" or "off") .. ".")
end

---------------------------------------------------------------------------------------------------
-- /supertracker [on|off|toggle]

local function mainCommand(msg)
	local cmd = (msg or ""):lower():match("^%s*(%S*)")
	if cmd == "on" then
		setEnabled(true)
	elseif cmd == "off" then
		setEnabled(false)
	elseif cmd == "toggle" then
		setEnabled(not db.enabled)
	elseif cmd == "rxp" then
		rxpSetting:SetValue(not db.followRXP)
		say("following the RestedXP arrow " .. (db.followRXP and "on" or "off") .. ".")
		return
	elseif cmd == "cpu" then
		cpuReport()
		return
	elseif cmd == "" then
		Settings.OpenToCategory(category:GetID())
		return
	else
		say("commands: /supertracker on | off | toggle | rxp | cpu, /way [mapID] x y, /way clear")
		return
	end
	say("in-world navigation marker " .. (db.enabled and "on" or "off") .. ".")
end

---------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SUPER_TRACKING_CHANGED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("USER_WAYPOINT_UPDATED")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		SuperTrackerDB = SuperTrackerDB or {}
		db = SuperTrackerDB
		if db.enabled == nil then db.enabled = true end
		if db.autoTrack == nil then db.autoTrack = true end
		if db.followRXP == nil then db.followRXP = false end
		registerSettings()
	elseif event == "ADDON_LOADED" and arg1 == "RXPGuides" then
		if db and IsLoggedIn() then startFollowing() end
	elseif event == "USER_WAYPOINT_UPDATED" then
		onUserWaypointUpdated()
	elseif event == "SUPER_TRACKING_CHANGED" or event == "QUEST_REMOVED" then
		if db then scheduleAutoTrack() end
	elseif event == "PLAYER_LOGIN" then
		applyCVar()
		scheduleAutoTrack(3)
		startFollowing()

		SLASH_SUPERTRACKER1 = "/supertracker"
		SlashCmdList.SUPERTRACKER = mainCommand

		-- /way belongs to TomTom when it is installed; /stway always works.
		SLASH_SUPERTRACKERWAY1 = "/stway"
		if not C_AddOns.IsAddOnLoaded("TomTom") then
			SLASH_SUPERTRACKERWAY2 = "/way"
		end
		SlashCmdList.SUPERTRACKERWAY = way
	end
end)
