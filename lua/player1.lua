-- Load this file in Player 1's BizHawk Lua Console.
PLAYER_ID = "player1"

local pathLookup = debug.getinfo(1, "S").source:sub(2)
local scriptDir = pathLookup:match("(.*[/\\])") or "./"
STATE_DIR = scriptDir .. "../data/state"

dofile(scriptDir .. "soullink_tracker.lua")
