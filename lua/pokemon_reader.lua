-- Decodes a Gen III party Pokemon struct (species/level/nickname/nature/
-- IVs/shiny/status/HP/experience) from game memory. Struct layout is an engine
-- constant, identical regardless of ROM language -- adapted from
-- Ironmon-Tracker's Program.lua:readNewPokemon (MIT licensed). See
-- https://bulbapedia.bulbagarden.net/wiki/Pok%C3%A9mon_data_structure_(Generation_III)
local Memory = require("memory")
local Bit = require("bit_utils")
local CharMap = require("charmap")
local SpeciesMap = require("species_map")

local PokemonReader = {}

PokemonReader.SIZEOF_POKEMON_STRUCT = 0x64
local OFFSET_SUBSTRUCT = 0x20
local OFFSET_STATUS = 0x50
local OFFSET_STATS_LV_CURHP = 0x54
local OFFSET_STATS_MAXHP_ATK = 0x58
local SIZEOF_NICKNAME = 0xA
local NICKNAME_CHAR_END = 0xFF
local SHINY_ODDS = 8 -- n/65536

-- ROM data tables backing the experience-bar math (see configureRomTables).
local SIZEOF_BASE_STATS = 0x1C
local OFFSET_BASE_STATS_GROWTH_RATE = 0x13
local MAX_LEVEL = 100
local EXP_TABLE_ROW_ENTRIES = MAX_LEVEL + 1 -- one u32 per level, 0..100
local NUM_GROWTH_RATES = 6
local MAX_INTERNAL_SPECIES = 411

-- Total exp at level 100 for each growth rate, in the Gen III enum order
-- (medium-fast, erratic, fluctuating, medium-slow, fast, slow). Used as a
-- fingerprint that pins down gExperienceTables' base address, row stride
-- and row ordering in one check.
local EXP_AT_MAX_LEVEL = { 1000000, 600000, 1640000, 1059860, 800000, 1250000 }

-- Set by configureRomTables(); nil until then, which disables exp reporting.
local romTables = nil

-- Permutation order of the encrypted 12-byte substructures (growth/misc are
-- the only ones this reader needs; attack/effort are part of the same
-- scheme but unused here), indexed by personality % 24.
local SUBSTRUCT_ORDER = {
	growth = { 1, 1, 1, 1, 1, 1, 2, 2, 3, 4, 3, 4, 2, 2, 3, 4, 3, 4, 2, 2, 3, 4, 3, 4 },
	misc   = { 4, 3, 4, 3, 2, 2, 4, 3, 4, 3, 2, 2, 4, 3, 4, 3, 2, 2, 1, 1, 1, 1, 1, 1 },
}

local function decryptDword(startAddress, substructOffset, magicword)
	return Bit.bXor(Memory.readdword(startAddress + OFFSET_SUBSTRUCT + substructOffset), magicword)
end

local function readNickname(startAddress)
	local nickname = ""
	for i = 0, SIZEOF_NICKNAME - 1 do
		local charByte = Memory.readbyte(startAddress + 8 + i)
		if charByte == NICKNAME_CHAR_END then break end
		nickname = nickname .. (CharMap[charByte] or "?")
	end
	return nickname
end

local function ivsFromMisc2(misc2)
	return {
		hp = Bit.getBits(misc2, 0, 5),
		atk = Bit.getBits(misc2, 5, 5),
		def = Bit.getBits(misc2, 10, 5),
		spe = Bit.getBits(misc2, 15, 5),
		spa = Bit.getBits(misc2, 20, 5),
		spd = Bit.getBits(misc2, 25, 5),
	}
end

-- Points the reader at gBaseStats / gExperienceTables so read() can report
-- how far a mon is through its current level. These are the only ROM reads
-- the tracker does, and the two base addresses have no other consumer to
-- catch a bad value, so both tables are fingerprinted here before being
-- trusted. On mismatch the exp fields are simply omitted -- a wrong address
-- costs you the exp bars, it doesn't corrupt the rest of the state file.
-- Returns true if the tables checked out.
function PokemonReader.configureRomTables(baseStatsAddress, expTablesAddress)
	romTables = nil
	if not baseStatsAddress or not expTablesAddress then return false end

	for growthRate = 0, NUM_GROWTH_RATES - 1 do
		local index = growthRate * EXP_TABLE_ROW_ENTRIES + MAX_LEVEL
		local actual = Memory.readdword(expTablesAddress + index * 4)
		local expected = EXP_AT_MAX_LEVEL[growthRate + 1]
		if actual ~= expected then
			print(("!! gExperienceTables check failed at growth rate %d: expected %d, got %d")
				:format(growthRate, expected, actual))
			print("!! Experience bars disabled. Everything else is unaffected.")
			return false
		end
	end

	-- Bulbasaur (internal id 1) has 45 base HP and is medium-slow, which
	-- pins down gBaseStats' base address and its 0x1C stride together.
	local baseHp = Memory.readbyte(baseStatsAddress + SIZEOF_BASE_STATS)
	local growthRate = Memory.readbyte(baseStatsAddress + SIZEOF_BASE_STATS + OFFSET_BASE_STATS_GROWTH_RATE)
	if baseHp ~= 45 or growthRate ~= 3 then
		print(("!! gBaseStats check failed for Bulbasaur: expected baseHp=45 growthRate=3, got baseHp=%d growthRate=%d")
			:format(baseHp, growthRate))
		print("!! Experience bars disabled. Everything else is unaffected.")
		return false
	end

	romTables = { baseStats = baseStatsAddress, experienceTables = expTablesAddress }
	return true
end

local function totalExpForLevel(growthRate, level)
	local index = growthRate * EXP_TABLE_ROW_ENTRIES + level
	return Memory.readdword(romTables.experienceTables + index * 4)
end

-- Numerator/denominator of an exp bar: exp earned into the current level,
-- and how much that level spans in total. A level-100 mon has nowhere left
-- to go and reports a span of 0, which the dashboard draws as a full bar.
-- Returns nil whenever the answer would be a guess (tables unverified, or
-- a species/level outside the tables), and the exp fields are then omitted.
local function readExpProgress(internalSpecies, level, experience)
	if not romTables then return nil end
	if internalSpecies < 1 or internalSpecies > MAX_INTERNAL_SPECIES then return nil end
	if level < 1 or level > MAX_LEVEL then return nil end

	local growthRate = Memory.readbyte(
		romTables.baseStats + internalSpecies * SIZEOF_BASE_STATS + OFFSET_BASE_STATS_GROWTH_RATE)
	if growthRate >= NUM_GROWTH_RATES then return nil end

	if level == MAX_LEVEL then
		return { earned = 0, span = 0 }
	end

	local levelStart = totalExpForLevel(growthRate, level)
	local levelEnd = totalExpForLevel(growthRate, level + 1)
	if levelEnd <= levelStart then return nil end

	-- Clamped because exp is read asynchronously from a running game: a poll
	-- can land between the exp gain and the level-up that consumes it.
	local earned = math.max(0, math.min(experience - levelStart, levelEnd - levelStart))
	return { earned = earned, span = levelEnd - levelStart }
end

-- Reads and decrypts one Pokemon struct starting at `startAddress`.
-- `personality` must already be known (caller reads it first as a cheap
-- "is this slot occupied" check before doing the full decode).
function PokemonReader.read(startAddress, personality)
	local otid = Memory.readdword(startAddress + 4)
	local magicword = Bit.bXor(personality, otid)

	local order = personality % 24 + 1
	local growthOffset = (SUBSTRUCT_ORDER.growth[order] - 1) * 12
	local miscOffset = (SUBSTRUCT_ORDER.misc[order] - 1) * 12

	local growth1 = decryptDword(startAddress, growthOffset, magicword)
	local experience = decryptDword(startAddress, growthOffset + 4, magicword)
	local misc2 = decryptDword(startAddress, miscOffset + 4, magicword)

	local internalSpecies = Bit.getBits(growth1, 0, 16)

	local trainerIdLow = Bit.getBits(otid, 0, 16)
	local secretId = Bit.getBits(otid, 16, 16)
	local pHigh = math.floor(personality / 65536)
	local pLow = personality % 65536
	local isShiny = Bit.bXor(Bit.bXor(Bit.bXor(trainerIdLow, secretId), pHigh), pLow) < SHINY_ODDS

	local statusAux = Memory.readdword(startAddress + OFFSET_STATUS)
	local status = 0
	if statusAux == 0 then status = 0
	elseif statusAux < 8 then status = 1 -- sleep
	elseif statusAux == 8 then status = 2 -- poison
	elseif statusAux == 16 then status = 3 -- burn
	elseif statusAux == 32 then status = 4 -- freeze
	elseif statusAux == 64 then status = 5 -- paralyze
	elseif statusAux == 128 then status = 6 -- toxic
	end

	local levelAndCurHp = Memory.readdword(startAddress + OFFSET_STATS_LV_CURHP)
	local maxHpAndAtk = Memory.readdword(startAddress + OFFSET_STATS_MAXHP_ATK)
	local level = Bit.getBits(levelAndCurHp, 0, 8)

	local mon = {
		personality = personality,
		nickname = readNickname(startAddress),
		species = SpeciesMap.toNationalDex(internalSpecies),
		level = level,
		nature = personality % 25,
		isShiny = isShiny,
		isEgg = Bit.getBits(misc2, 30, 1) == 1,
		status = status,
		currentHp = Bit.getBits(levelAndCurHp, 16, 16),
		maxHp = Bit.getBits(maxHpAndAtk, 0, 16),
		experience = experience,
		ivs = ivsFromMisc2(misc2),
	}

	local expProgress = readExpProgress(internalSpecies, level, experience)
	if expProgress then
		mon.expEarnedThisLevel = expProgress.earned
		mon.expSpanThisLevel = expProgress.span
	end

	return mon
end

-- Reads all 6 party slots starting at `baseAddress` (GameSettings.pstats or
-- .estats). Empty slots (personality == 0 and otid == 0) are omitted.
function PokemonReader.readParty(baseAddress)
	local party = {}
	for slot = 0, 5 do
		local addr = baseAddress + slot * PokemonReader.SIZEOF_POKEMON_STRUCT
		local personality = Memory.readdword(addr)
		local otid = Memory.readdword(addr + 4)
		if personality ~= 0 or otid ~= 0 then
			local mon = PokemonReader.read(addr, personality)
			mon.slot = slot
			table.insert(party, mon)
		end
	end
	return party
end

return PokemonReader
