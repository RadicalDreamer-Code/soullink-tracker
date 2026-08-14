# Soul Link Tracker

Live Soul Link dashboard for two BizHawk instances running the German
version of Pokémon Fire Red ("Feuerrote"). Each player's emulator writes a
JSON snapshot of its game state to disk; a local Node server watches both
files, derives which Pokémon are currently linked (caught on the same
route), and pushes updates to a browser dashboard over WebSocket. Every
catch is also logged to a CSV as a permanent run record.

See `/home/sloth/.claude/plans/i-want-to-build-jiggly-willow.md` for the
full design writeup (architecture, schemas, phase rationale).

## Setup

1. **Install server dependencies** (once):
   ```
   npm install
   ```

2. **Phase 0 — verify the German address table against your ROM.** The
   addresses in `lua/addresses/firered_de.json` come from a hand-verified
   community table, but confirm they match your specific ROM dump before
   trusting the tracker:
   - Load `lua/scripts/dump_state.lua` in BizHawk's Lua Console with your
     German Fire Red ROM running.
   - Check the console: the ROM header line should say `gameCode=42505244
     softwareVersion=00690000` and match the "expected" line beneath it.
     If it doesn't match, the addresses may need correcting — see the plan's
     Phase 0 notes for the RAM Search fallback.
   - Walk around and confirm the printed `mapId`/route name changes when you
     cross route borders, and that your starter/party mon's species, level,
     and nickname print correctly.
   - Once confirmed, you can close this script — it's not used by the
     tracker itself.

3. **Start the server:**
   ```
   npm start
   ```
   This watches `data/state/` and serves the dashboard at
   `http://localhost:3000`.

4. **Load the tracker in each BizHawk instance:**
   - Player 1's BizHawk: Lua Console → open `lua/player1.lua`
   - Player 2's BizHawk: Lua Console → open `lua/player2.lua`

5. **Open the dashboard** at `http://localhost:3000` in a browser. It updates
   live as either player catches something.

## Run data

- `data/runs/<run-id>.csv` — append-only ledger of every catch (species,
  level, nickname, nature, IVs, shiny, route, timestamp).
- `data/runs/<run-id>-state.json` — periodic snapshot the server uses to
  resume the same run (no duplicate CSV rows) if it's restarted mid-run.
- `data/runs/current-run.json` — pointer to the active run.

To start a fresh run (new CSV, resets linking state) without restarting the
server: `curl -X POST http://localhost:3000/api/runs/new`.

## Notes

- Both BizHawk instances and the server are expected to run on the same
  machine (no networked/multi-PC support).
- Fainted/boxed Pokémon aren't specially tracked in v1 — a linked pair
  disappears from the "currently in party" section if either mon is
  deposited to the box, which is expected, not a bug.
- Pokémon icons (`server/public/icons/`) and JSON/species-name data are
  adapted from [Ironmon-Tracker](https://github.com/besteon/Ironmon-Tracker)
  (MIT licensed); see `server/public/icons/LICENSE.txt`.
