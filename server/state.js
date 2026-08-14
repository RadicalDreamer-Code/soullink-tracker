const fs = require('fs');
const path = require('path');
const SPECIES_NAMES = require('./species_names');
const NATURE_NAMES = require('./nature_names');

const CSV_HEADER = [
  'run_id', 'seq', 'player_id', 'event_type', 'timestamp_utc', 'route_map_id', 'route_name',
  'species_national_dex_id', 'species_name', 'nickname', 'level', 'nature_id',
  'is_shiny', 'iv_hp', 'iv_atk', 'iv_def', 'iv_spa', 'iv_spd', 'iv_spe', 'personality_id',
].join(',');

const STALE_AFTER_MS = 5000;
const TRACKED_EVENT_TYPES = new Set(['catch', 'received']);

function csvField(value) {
  const s = String(value);
  return `"${s.replace(/"/g, '""')}"`;
}

function eventKey(playerId, personality) {
  return `${playerId}:${personality}`;
}

class RunState {
  constructor(runId, runsDir) {
    this.runId = runId;
    this.runsDir = runsDir;
    this.csvPath = path.join(runsDir, `${runId}.csv`);
    this.snapshotPath = path.join(runsDir, `${runId}-state.json`);

    this.players = { player1: null, player2: null };
    this.lastUpdateAt = { player1: 0, player2: 0 };
    this.seenEventKeys = new Set();
    this.csvRowCount = 0;

    fs.mkdirSync(runsDir, { recursive: true });
    this._loadSnapshotIfExists();
    this._ensureCsvHeader();
  }

  _ensureCsvHeader() {
    if (!fs.existsSync(this.csvPath)) {
      fs.writeFileSync(this.csvPath, CSV_HEADER + '\n');
    }
  }

  _loadSnapshotIfExists() {
    if (!fs.existsSync(this.snapshotPath)) return;
    try {
      const snapshot = JSON.parse(fs.readFileSync(this.snapshotPath, 'utf8'));
      this.players = snapshot.players || this.players;
      this.seenEventKeys = new Set(snapshot.seenEventKeys || []);
      console.log(`[state] restored snapshot for run ${this.runId} (${this.seenEventKeys.size} known catches)`);
    } catch (err) {
      console.warn(`[state] failed to load snapshot, starting fresh: ${err.message}`);
    }
  }

  saveSnapshot() {
    const snapshot = {
      runId: this.runId,
      players: this.players,
      seenEventKeys: Array.from(this.seenEventKeys),
    };
    const tmpPath = this.snapshotPath + '.tmp';
    fs.writeFileSync(tmpPath, JSON.stringify(snapshot));
    fs.renameSync(tmpPath, this.snapshotPath);
  }

  // Ingests a freshly-read player state JSON (already parsed). Appends any
  // genuinely new catch/received events to the CSV, deduped by
  // (playerId, personality) rather than the Lua-side seq counter, since a
  // Lua script reload resets seq but personality is durable across reloads.
  ingestPlayerState(playerId, rawState) {
    this.players[playerId] = rawState;
    this.lastUpdateAt[playerId] = Date.now();

    const events = Array.isArray(rawState.events) ? rawState.events : [];
    let wroteRow = false;
    for (const event of events) {
      if (!TRACKED_EVENT_TYPES.has(event.type) || !event.pokemon) continue;
      const key = eventKey(playerId, event.pokemon.personality);
      if (this.seenEventKeys.has(key)) continue;
      this.seenEventKeys.add(key);
      this._appendCsvRow(playerId, event);
      wroteRow = true;
    }

    this.saveSnapshot();
    return wroteRow;
  }

  _appendCsvRow(playerId, event) {
    const mon = event.pokemon;
    const ivs = mon.ivs || {};
    const row = [
      this.runId,
      event.seq,
      playerId,
      event.type,
      event.timestamp,
      event.route ? event.route.mapId : '',
      event.route ? event.route.name : '',
      mon.species,
      SPECIES_NAMES[mon.species] || `#${mon.species}`,
      mon.nickname,
      mon.level,
      mon.nature,
      NATURE_NAMES[mon.nature] || mon.nature,
      mon.isShiny,
      ivs.hp, ivs.atk, ivs.def, ivs.spa, ivs.spd, ivs.spe,
      mon.personality,
    ].map(csvField).join(',');

    fs.appendFileSync(this.csvPath, row + '\n');
    this.csvRowCount += 1;
  }

  isStale(playerId) {
    const last = this.lastUpdateAt[playerId];
    if (!last) return true;
    return Date.now() - last > STALE_AFTER_MS;
  }

  // Builds the payload broadcast to dashboard clients: per-player party +
  // connection status, and the derived route-linking view.
  buildBroadcastPayload() {
    const playerView = {};
    for (const playerId of ['player1', 'player2']) {
      const raw = this.players[playerId];
      playerView[playerId] = {
        connected: raw != null && !this.isStale(playerId),
        map: raw ? raw.map : null,
        party: raw ? raw.party : [],
        generatedAt: raw ? raw.generatedAt : null,
      };
    }

    const routes = this._deriveRoutes();
    const linkedPairs = routes.filter((r) => r.player1 && r.player1.inParty && r.player2 && r.player2.inParty);

    return {
      runId: this.runId,
      players: playerView,
      routes,
      linkedPairs,
    };
  }

  // For each player, finds their most-recently-caught mon per route, then
  // checks whether that mon is still alive in the current party (in which
  // case its *current* species/level/nickname are shown, reflecting
  // evolution) or has been boxed/removed (in which case the catch-time
  // snapshot is shown instead).
  _deriveRoutes() {
    const routeOrder = new Map(); // routeName -> { mapId, firstSeenAt }
    const perPlayerRouteCatch = { player1: new Map(), player2: new Map() };

    for (const playerId of ['player1', 'player2']) {
      const raw = this.players[playerId];
      if (!raw || !Array.isArray(raw.events)) continue;

      const partyByPersonality = new Map();
      for (const mon of raw.party || []) {
        partyByPersonality.set(mon.personality, mon);
      }

      for (const event of raw.events) {
        if (!TRACKED_EVENT_TYPES.has(event.type) || !event.route) continue;
        const routeName = event.route.name;

        if (!routeOrder.has(routeName) || event.timestamp < routeOrder.get(routeName).firstSeenAt) {
          const existing = routeOrder.get(routeName);
          routeOrder.set(routeName, {
            mapId: event.route.mapId,
            firstSeenAt: existing ? Math.min(existing.firstSeenAt, event.timestamp) : event.timestamp,
          });
        }

        const existingForRoute = perPlayerRouteCatch[playerId].get(routeName);
        if (!existingForRoute || event.seq > existingForRoute.seq) {
          perPlayerRouteCatch[playerId].set(routeName, event);
        }
      }
    }

    const routeNames = Array.from(routeOrder.keys()).sort((a, b) => {
      return routeOrder.get(a).firstSeenAt < routeOrder.get(b).firstSeenAt ? -1 : 1;
    });

    return routeNames.map((routeName) => {
      const info = routeOrder.get(routeName);
      const row = { routeName, mapId: info.mapId, player1: null, player2: null };

      for (const playerId of ['player1', 'player2']) {
        const event = perPlayerRouteCatch[playerId].get(routeName);
        if (!event) continue;

        const raw = this.players[playerId];
        const partyMon = (raw.party || []).find((m) => m.personality === event.pokemon.personality);

        if (partyMon) {
          row[playerId] = {
            species: partyMon.species,
            speciesName: SPECIES_NAMES[partyMon.species] || `#${partyMon.species}`,
            level: partyMon.level,
            nickname: partyMon.nickname,
            isShiny: partyMon.isShiny,
            inParty: true,
          };
        } else {
          row[playerId] = {
            species: event.pokemon.species,
            speciesName: SPECIES_NAMES[event.pokemon.species] || `#${event.pokemon.species}`,
            level: event.pokemon.level,
            nickname: event.pokemon.nickname,
            isShiny: event.pokemon.isShiny,
            inParty: false,
          };
        }
      }

      return row;
    });
  }
}

module.exports = { RunState };
