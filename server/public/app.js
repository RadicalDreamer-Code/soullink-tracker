function iconUrl(species) {
  return `icons/${species || 0}.gif`;
}

function animatedIconUrl(species) {
  return `animated/${species || 0}.gif`;
}

function renderPlayerStatus(elId, player) {
  const el = document.getElementById(elId);
  el.classList.toggle('connected', !!(player && player.connected));
  el.classList.toggle('stale', !(player && player.connected));
}

function monCell(mon) {
  if (!mon) {
    return '<span class="empty-cell">&mdash;</span>';
  }
  const shinyClass = mon.isShiny ? ' shiny' : '';
  const defeatedClass = mon.isDefeated ? ' defeated' : '';
  const notes = [];
  if (mon.isDefeated) notes.push('<div class="defeated-note">&#9760; defeated</div>');
  if (!mon.inParty) notes.push('<div class="boxed">boxed/gone</div>');
  return `
    <div class="mon-cell${shinyClass}${defeatedClass}">
      <img src="${iconUrl(mon.species)}" alt="" />
      <div>
        <div class="name">${escapeHtml(mon.nickname)} <span class="empty-cell">Lv.${mon.level}</span></div>
        ${notes.join('')}
      </div>
    </div>
  `;
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function renderRoutes(routes) {
  const rows = document.getElementById('route-rows');
  const empty = document.getElementById('routes-empty');

  if (!routes || routes.length === 0) {
    rows.innerHTML = '';
    empty.style.display = 'block';
    return;
  }
  empty.style.display = 'none';

  rows.innerHTML = routes.map((r) => `
    <tr>
      <td>${escapeHtml(r.routeName)}</td>
      <td>${monCell(r.player1)}</td>
      <td>${monCell(r.player2)}</td>
    </tr>
  `).join('');
}

function renderLinkedPairs(linkedPairs) {
  const container = document.getElementById('linked-pairs');
  const empty = document.getElementById('linked-empty');

  if (!linkedPairs || linkedPairs.length === 0) {
    container.innerHTML = '';
    empty.style.display = 'block';
    return;
  }
  empty.style.display = 'none';

  container.innerHTML = linkedPairs.map((pair) => `
    <div class="pair-wrap">
      <div class="route-label">${escapeHtml(pair.routeName)}</div>
      <div class="pair-card">
        <div class="mon${pair.player1.isShiny ? ' shiny' : ''}">
          <img src="${animatedIconUrl(pair.player1.species)}" alt="" />
          <span class="name">${escapeHtml(pair.player1.nickname)}</span>
          <span class="name">Lv.${pair.player1.level}</span>
        </div>
        <span class="link-icon">&#128279;</span>
        <div class="mon${pair.player2.isShiny ? ' shiny' : ''}">
          <img src="${animatedIconUrl(pair.player2.species)}" alt="" />
          <span class="name">${escapeHtml(pair.player2.nickname)}</span>
          <span class="name">Lv.${pair.player2.level}</span>
        </div>
      </div>
    </div>
  `).join('');
}

// Debug mode: fabricates a full dashboard payload client-side so the UI can
// be visually tested (shiny, defeated, boxed/gone, missing-partner cells)
// without touching the real run's event log/CSV on the server.
const DEBUG_SPECIES_NAMES = {
  1: 'Bulbasaur', 4: 'Charmander', 7: 'Squirtle', 25: 'Pikachu', 133: 'Eevee',
  130: 'Gyarados', 143: 'Snorlax', 149: 'Dragonite', 131: 'Lapras', 197: 'Umbreon',
  359: 'Absol', 6: 'Charizard',
};

function debugMon(species, nickname, level, opts = {}) {
  return {
    species,
    speciesName: DEBUG_SPECIES_NAMES[species] || `#${species}`,
    level,
    nickname,
    isShiny: !!opts.shiny,
    inParty: opts.inParty !== false,
    isDefeated: !!opts.defeated,
  };
}

function buildDebugState() {
  const routes = [
    // A full 6-slot soul-linked party: both players alive & in-party on every route.
    { routeName: 'Route 1', player1: debugMon(1, 'Bulby', 14), player2: debugMon(4, 'Charry', 14) },
    { routeName: 'Route 2', player1: debugMon(7, 'Squirt', 16), player2: debugMon(25, 'Sparky', 15, { shiny: true }) },
    { routeName: 'Route 3', player1: debugMon(133, 'Eevee', 18, { shiny: true }), player2: debugMon(130, 'Gary', 20) },
    { routeName: 'Route 4', player1: debugMon(143, 'Snorly', 22), player2: debugMon(149, 'Dennis', 24) },
    { routeName: 'Route 5', player1: debugMon(131, 'Icy', 21), player2: debugMon(197, 'Umbra', 23) },
    { routeName: 'Route 6', player1: debugMon(359, 'Absol', 25), player2: debugMon(6, 'Blaze', 26, { shiny: true }) },
    // Extra rows showing other states, appended after the full party above.
    { routeName: 'Route 7 (defeated)', player1: debugMon(19, 'Ratty', 12, { defeated: true, inParty: false }), player2: debugMon(21, 'Peckish', 13) },
    { routeName: 'Route 8 (boxed)', player1: debugMon(16, 'Birdy', 8, { inParty: false }), player2: debugMon(23, 'Snake', 11) },
    { routeName: 'Route 9 (both defeated)', player1: debugMon(41, 'Batty', 15, { defeated: true, inParty: false }), player2: debugMon(46, 'Shroom', 15, { defeated: true, inParty: false }) },
    { routeName: 'Route 10 (missing partner)', player1: debugMon(129, 'Fishy', 5), player2: null },
  ];

  const linkedPairs = routes
    .filter((r) => r.player1 && r.player1.inParty && !r.player1.isDefeated
      && r.player2 && r.player2.inParty && !r.player2.isDefeated)
    .map((r) => ({ routeName: r.routeName, player1: r.player1, player2: r.player2 }));

  return {
    runId: 'debug-preview',
    players: {
      player1: { connected: true, map: null, party: routes.filter((r) => r.player1 && r.player1.inParty).map((r) => r.player1), generatedAt: Date.now() },
      player2: { connected: true, map: null, party: routes.filter((r) => r.player2 && r.player2.inParty).map((r) => r.player2), generatedAt: Date.now() },
    },
    routes,
    linkedPairs,
  };
}

let debugMode = localStorage.getItem('soullink-debug-mode') === '1';
let latestLiveState = null;

function setDebugMode(enabled) {
  debugMode = enabled;
  localStorage.setItem('soullink-debug-mode', enabled ? '1' : '0');
  document.getElementById('debug-toggle-btn').classList.toggle('active', enabled);
  document.getElementById('debug-banner').classList.toggle('visible', enabled);
  render(enabled ? buildDebugState() : latestLiveState);
}

function render(state) {
  if (!state) return;
  document.getElementById('run-id').textContent = state.runId || '';
  renderPlayerStatus('conn-p1', state.players && state.players.player1);
  renderPlayerStatus('conn-p2', state.players && state.players.player2);
  renderLinkedPairs(state.linkedPairs);
  renderRoutes(state.routes);
}

async function loadInitialState() {
  try {
    const res = await fetch('/api/state');
    const state = await res.json();
    latestLiveState = state;
    if (!debugMode) render(state);
  } catch (err) {
    console.error('Failed to load initial state', err);
  }
}

function connectWebSocket() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const ws = new WebSocket(`${proto}//${location.host}`);

  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'state') {
      latestLiveState = msg.data;
      if (!debugMode) render(msg.data);
    }
  });

  ws.addEventListener('close', () => {
    setTimeout(connectWebSocket, 2000);
  });
}

let toastTimer = null;
function showToast(msg) {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    el.className = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('visible'), 3000);
}

document.getElementById('new-run-btn').addEventListener('click', async () => {
  if (!confirm('Start a new run? The current run data will be preserved in its CSV, but the dashboard will reset.')) return;
  try {
    const res = await fetch('/api/runs/new', { method: 'POST' });
    const data = await res.json();
    showToast(`New run started: ${data.runId}`);
  } catch (err) {
    showToast('Failed to start new run.');
  }
});

document.getElementById('debug-toggle-btn').addEventListener('click', () => {
  setDebugMode(!debugMode);
});

loadInitialState();
connectWebSocket();

// Apply any persisted debug preference once the initial live state (or lack
// thereof) has been requested, so a refresh while toggled on stays on.
if (debugMode) setDebugMode(true);
