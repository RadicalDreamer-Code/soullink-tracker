-- Soul Link Tracker main entry point (BizHawk).
-- Loaded via a thin per-player launcher (player1.lua / player2.lua) which
-- sets PLAYER_ID and STATE_DIR before dofile-ing this script. Polls party
-- and battle-outcome memory, and periodically rewrites a JSON state file
-- that an external Node server watches -- BizHawk's comm.http*/socketServer*
-- APIs are avoided here since Ironmon-Tracker's own code documents them as
-- crash-prone without special EmuHawk startup flags; file-based IPC is the
-- pattern that project actually ships.

assert(PLAYER_ID, "PLAYER_ID must be set before loading soullink_tracker.lua")
assert(STATE_DIR, "STATE_DIR must be set before loading soullink_tracker.lua")

local pathLookup = debug.getinfo(1, "S").source:sub(2)
local SCRIPT_DIR = pathLookup:match("(.*[/\\])") or "./"
package.path = SCRIPT_DIR .. "?.lua;" .. package.path

local Memory = require("memory")
local Json = require("json")
local PokemonReader = require("pokemon_reader")
local RouteData = require("route_data")

console.clear()
print(("Soul Link Tracker starting for %s"):format(PLAYER_ID))

-- ---------------------------------------------------------------------
-- Address table
-- ---------------------------------------------------------------------

local function loadAddressTable()
	local file = io.open(SCRIPT_DIR .. "addresses/firered_de.json", "r")
	assert(file, "Could not open addresses/firered_de.json")
	local contents = file:read("*a")
	file:close()
	return Json.decode(contents)
end

local AddressTable = loadAddressTable()

local function addr(name)
	local hex = AddressTable.Addresses[name]
	assert(hex, "Missing address for " .. name)
	return tonumber(hex, 16)
end

local ADDR_PSTATS = addr("pstats")
local ADDR_ESTATS = addr("estats")
local ADDR_BATTLE_OUTCOME = addr("gBattleOutcome")
local ADDR_MAP_HEADER = addr("gMapHeader")

local OFFSET_MAP_HEADER_LAYOUT_ID = 0x12
local BATTLE_OUTCOME_CAUGHT = 7

local function reverseEndian32(value)
	local b1 = value % 256
	local b2 = math.floor(value / 256) % 256
	local b3 = math.floor(value / 65536) % 256
	local b4 = math.floor(value / 16777216) % 256
	return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function checkRomHeader()
	local expected = AddressTable.RomHeader
	if not expected then return end
	local gameCode = reverseEndian32(Memory.readdword(0x080000AC))
	local softwareVersion = reverseEndian32(Memory.readdword(0x080000BC))
	local expectedGameCode = tonumber(expected.gameCode, 16)
	local expectedSoftwareVersion = tonumber(expected.softwareVersion, 16)
	if gameCode ~= expectedGameCode or softwareVersion ~= expectedSoftwareVersion then
		print("!! WARNING: ROM header does not match the expected German Fire Red (Feuerrote) revision.")
		print(("!! Expected gameCode=%08X softwareVersion=%08X, got gameCode=%08X softwareVersion=%08X")
			:format(expectedGameCode, expectedSoftwareVersion, gameCode, softwareVersion))
		print("!! Addresses in addresses/firered_de.json may not be correct for this ROM. See plan Phase 0.")
	else
		print("ROM header OK: " .. (expected.versionName or "Feuerrote"))
	end
end

checkRomHeader()

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------

local writeSequence = 0
local eventSequence = 0
local events = {}
local previousBattleOutcome = 0
local previousMapId = nil
local currentRoute = { mapId = 0, name = "Unknown" }
local currentParty = {}

local FULL_PARTY_POLL_INTERVAL = 30 -- frames
local framesSinceFullPoll = FULL_PARTY_POLL_INTERVAL -- force an immediate read on first tick

local function nowIso8601()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function updateRoute()
	local mapId = Memory.readword(ADDR_MAP_HEADER + OFFSET_MAP_HEADER_LAYOUT_ID)
	if mapId ~= previousMapId then
		previousMapId = mapId
		currentRoute = { mapId = mapId, name = RouteData.getName(mapId) }
	end
end

local function refreshParty()
	currentParty = PokemonReader.readParty(ADDR_PSTATS)
end

local function recordCatch()
	-- Enemy/wild party slot 0 holds the mon that was just caught.
	local personality = Memory.readdword(ADDR_ESTATS)
	local otid = Memory.readdword(ADDR_ESTATS + 4)
	if personality == 0 and otid == 0 then return end

	local caughtMon = PokemonReader.read(ADDR_ESTATS, personality)
	eventSequence = eventSequence + 1
	table.insert(events, {
		seq = eventSequence,
		type = "catch",
		timestamp = nowIso8601(),
		route = { mapId = currentRoute.mapId, name = currentRoute.name },
		pokemon = {
			personality = caughtMon.personality,
			species = caughtMon.species,
			nickname = caughtMon.nickname,
			level = caughtMon.level,
			nature = caughtMon.nature,
			isShiny = caughtMon.isShiny,
			ivs = caughtMon.ivs,
		},
	})
	print(("Catch recorded: species #%d, level %d, route %s")
		:format(caughtMon.species, caughtMon.level, currentRoute.name))
end

local function writeStateFile()
	writeSequence = writeSequence + 1
	local state = {
		schemaVersion = 1,
		playerId = PLAYER_ID,
		romInfo = {
			gameCode = AddressTable.RomHeader and AddressTable.RomHeader.gameCode or "",
			softwareVersion = AddressTable.RomHeader and AddressTable.RomHeader.softwareVersion or "",
		},
		generatedAt = nowIso8601(),
		sequence = writeSequence,
		map = { mapId = currentRoute.mapId, routeName = currentRoute.name },
		party = currentParty,
		events = events,
	}

	local finalPath = STATE_DIR .. "/" .. PLAYER_ID .. ".json"
	local tmpPath = finalPath .. ".tmp"
	local file = io.open(tmpPath, "w")
	if not file then
		print("!! Could not open state file for writing: " .. tmpPath)
		return
	end
	file:write(Json.encode(state))
	file:close()
	os.rename(tmpPath, finalPath)
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------

while true do
	updateRoute()

	local battleOutcome = Memory.readbyte(ADDR_BATTLE_OUTCOME)
	if battleOutcome == BATTLE_OUTCOME_CAUGHT and previousBattleOutcome ~= BATTLE_OUTCOME_CAUGHT then
		recordCatch()
		refreshParty()
		writeStateFile()
		framesSinceFullPoll = 0
	end
	previousBattleOutcome = battleOutcome

	framesSinceFullPoll = framesSinceFullPoll + 1
	if framesSinceFullPoll >= FULL_PARTY_POLL_INTERVAL then
		framesSinceFullPoll = 0
		refreshParty()
		writeStateFile()
	end

	emu.frameadvance()
end
