-- Bitwise helpers. BizHawk's bundled Lua doesn't reliably expose native
-- bitwise operators across versions, so these use portable arithmetic
-- (same technique Ironmon-Tracker's Utils.lua uses).
local BitUtils = {}

-- operand: 1 = OR, 3 = XOR, 4 = AND
local function bitOper(a, b, operand)
	local r, m = 0, 2 ^ 31
	local s
	repeat
		s, a, b = a + b + m, a % m, b % m
		r, m = r + m * operand % (s - a - b), m / 2
	until m < 1
	return math.floor(r)
end

function BitUtils.bAnd(a, b)
	return bitOper(a, b, 4)
end

function BitUtils.bOr(a, b)
	return bitOper(a, b, 1)
end

function BitUtils.bXor(a, b)
	return bitOper(a, b, 3)
end

function BitUtils.lshift(value, n)
	return math.floor(value) * (2 ^ n)
end

function BitUtils.rshift(value, n)
	return math.floor(value / (2 ^ n))
end

-- Extracts `numBits` bits from `value`, starting at `startIndex` (LSB = 0).
function BitUtils.getBits(value, startIndex, numBits)
	return math.floor(BitUtils.rshift(value, startIndex) % BitUtils.lshift(1, numBits))
end

return BitUtils
