-- Splits a virtualized 32-bit GBA address into a BizHawk memory domain +
-- offset, then reads through BizHawk's `memory` library. Technique adapted
-- from Ironmon-Tracker's Memory.lua (MIT licensed), BizHawk-only (no mGBA
-- branch, since this tracker only targets BizHawk).
local Memory = {}

local function splitDomainAndAddress(addr)
	local domain = math.floor(addr / 0x1000000)
	local offset = addr % 0x1000000
	if domain == 0 then
		return "BIOS", offset
	elseif domain == 2 then
		return "EWRAM", offset
	elseif domain == 3 then
		return "IWRAM", offset
	elseif domain == 8 then
		return "ROM", offset
	end
	return nil, addr
end

function Memory.readbyte(addr)
	local domain, offset = splitDomainAndAddress(addr)
	return memory.read_u8(offset, domain)
end

function Memory.readword(addr)
	local domain, offset = splitDomainAndAddress(addr)
	return memory.read_u16_le(offset, domain)
end

function Memory.readdword(addr)
	local domain, offset = splitDomainAndAddress(addr)
	return memory.read_u32_le(offset, domain)
end

-- Reads `len` raw bytes starting at `addr`, returned as a plain array.
function Memory.readbytes(addr, len)
	local bytes = {}
	for i = 0, len - 1 do
		bytes[i + 1] = Memory.readbyte(addr + i)
	end
	return bytes
end

return Memory
