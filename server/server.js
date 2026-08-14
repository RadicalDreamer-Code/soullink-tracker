const fs = require('fs');
const path = require('path');
const http = require('http');
const express = require('express');
const chokidar = require('chokidar');
const { WebSocketServer } = require('ws');
const { RunManager } = require('./run');

const PORT = process.env.PORT || 3070;
const DATA_STATE_DIR = path.join(__dirname, '..', 'data', 'state');
const DATA_RUNS_DIR = path.join(__dirname, '..', 'data', 'runs');
const BROADCAST_INTERVAL_MS = 2000; // also catches staleness with no file-change events

fs.mkdirSync(DATA_STATE_DIR, { recursive: true });
fs.mkdirSync(DATA_RUNS_DIR, { recursive: true });

const runManager = new RunManager(DATA_RUNS_DIR);

const app = express();
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());

app.get('/api/state', (req, res) => {
  res.json(runManager.current.buildBroadcastPayload());
});

app.post('/api/runs/new', (req, res) => {
  const run = runManager.startNewRun(req.body && req.body.runId);
  broadcast();
  res.json({ runId: run.runId });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

function broadcast() {
  const payload = JSON.stringify({ type: 'state', data: runManager.current.buildBroadcastPayload() });
  for (const client of wss.clients) {
    if (client.readyState === client.OPEN) {
      client.send(payload);
    }
  }
}

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'state', data: runManager.current.buildBroadcastPayload() }));
});

// PLAYER_ID.json -> playerId, ignoring the .tmp files the Lua side writes
// mid-rename (atomic write pattern: write to <file>.tmp, then os.rename).
function playerIdFromPath(filePath) {
  const base = path.basename(filePath);
  const match = base.match(/^(player[12])\.json$/);
  return match ? match[1] : null;
}

function handleStateFileChange(filePath) {
  const playerId = playerIdFromPath(filePath);
  if (!playerId) return;

  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    return; // file briefly missing mid-rename; next event will catch it
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`[watch] skipping unparsable ${filePath}: ${err.message}`);
    return; // self-heals on the next write
  }

  runManager.current.ingestPlayerState(playerId, parsed);
  broadcast();
}

// ignoreInitial: false is required -- otherwise a server started after the
// Lua scripts have already written their first state file misses the
// initial 'add' event and sits blank until the next in-game change.
const watcher = chokidar.watch(DATA_STATE_DIR, {
  ignoreInitial: false,
  ignored: /\.tmp$/,
});
watcher.on('add', handleStateFileChange);
watcher.on('change', handleStateFileChange);

setInterval(broadcast, BROADCAST_INTERVAL_MS);

server.listen(PORT, () => {
  console.log(`Soul Link Tracker server listening on http://localhost:${PORT}`);
  console.log(`Active run: ${runManager.current.runId}`);
  console.log(`Watching ${DATA_STATE_DIR} for player1.json / player2.json`);
});
