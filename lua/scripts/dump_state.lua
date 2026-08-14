-- Throwaway Phase-0 verification script. Load this directly in BizHawk's
-- Lua Console (with the German Fire Red ROM running) to sanity-check the
-- addresses in ../addresses/firered_de.json before trusting them for the
-- real tracker. Prints ROM header, party contents, and map ID once a
-- second. Not used by the server/dashboard -- delete once Phase 0 passes.

local pathLookup = debug.getinfo(1, "S").source:sub(2)
local scriptDir = pathLookup:match("(.*[/\\])") or "./"
local luaDir = scriptDir .. "../"
package.path = luaDir .. "?.lua;" .. package.path

local Memory = require("memory")
local Json = require("json")
local PokemonReader = require("pokemon_reader")
local RouteData = require("route_data")

console.clear()

local file = io.open(luaDir .. "addresses/firered_de.json", "r")
assert(file, "Could not open addresses/firered_de.json")
local AddressTable = Json.decode(file:read("*a"))
file:close()

local function addr(name)
	return tonumber(AddressTable.Addresses[name], 16)
end

local ADDR_PSTATS = addr("pstats")
local ADDR_MAP_HEADER = addr("gMapHeader")
local OFFSET_MAP_HEADER_LAYOUT_ID = 0x12

local function reverseEndian32(value)
	local b1 = value % 256
	local b2 = math.floor(value / 256) % 256
	local b3 = math.floor(value / 65536) % 256
	local b4 = math.floor(value / 16777216) % 256
	return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

print("=== ROM header ===")
local gameCode = reverseEndian32(Memory.readdword(0x080000AC))
local softwareVersion = reverseEndian32(Memory.readdword(0x080000BC))
print(("gameCode=%08X softwareVersion=%08X"):format(gameCode, softwareVersion))
print(("expected gameCode=%s softwareVersion=%s (%s)")
	:format(AddressTable.RomHeader.gameCode, AddressTable.RomHeader.softwareVersion, AddressTable.RomHeader.versionName))
print("")

local framesSincePrint = 999

while true do
	framesSincePrint = framesSincePrint + 1
	if framesSincePrint >= 60 then
		framesSincePrint = 0
		console.clear()

		local mapId = Memory.readword(ADDR_MAP_HEADER + OFFSET_MAP_HEADER_LAYOUT_ID)
		print(("mapId = %d (%s)"):format(mapId, RouteData.getName(mapId)))
		print("")

		local party = PokemonReader.readParty(ADDR_PSTATS)
		if #party == 0 then
			print("(party empty)")
		end
		for _, mon in ipairs(party) do
			print(("slot %d: species=%d lvl=%d nickname=%q nature=%d shiny=%s hp=%d/%d")
				:format(mon.slot, mon.species, mon.level, mon.nickname, mon.nature,
					tostring(mon.isShiny), mon.currentHp, mon.maxHp))
			print(("         ivs: hp=%d atk=%d def=%d spa=%d spd=%d spe=%d")
				:format(mon.ivs.hp, mon.ivs.atk, mon.ivs.def, mon.ivs.spa, mon.ivs.spd, mon.ivs.spe))
		end
	end
	emu.frameadvance()
end
