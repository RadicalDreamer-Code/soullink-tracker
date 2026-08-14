-- Decodes a Gen III party Pokemon struct (species/level/nickname/nature/
-- IVs/shiny/status/HP) from game memory. Struct layout is an engine
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

	return {
		personality = personality,
		nickname = readNickname(startAddress),
		species = SpeciesMap.toNationalDex(internalSpecies),
		level = Bit.getBits(levelAndCurHp, 0, 8),
		nature = personality % 25,
		isShiny = isShiny,
		isEgg = Bit.getBits(misc2, 30, 1) == 1,
		status = status,
		currentHp = Bit.getBits(levelAndCurHp, 16, 16),
		maxHp = Bit.getBits(maxHpAndAtk, 0, 16),
		ivs = ivsFromMisc2(misc2),
	}
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
