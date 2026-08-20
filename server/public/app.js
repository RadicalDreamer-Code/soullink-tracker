function iconUrl(species) {
  return `icons/${species || 0}.gif`;
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
          <img src="${iconUrl(pair.player1.species)}" alt="" />
          <span class="name">${escapeHtml(pair.player1.nickname)}</span>
          <span class="name">Lv.${pair.player1.level}</span>
        </div>
        <span class="link-icon">&#128279;</span>
        <div class="mon${pair.player2.isShiny ? ' shiny' : ''}">
          <img src="${iconUrl(pair.player2.species)}" alt="" />
          <span class="name">${escapeHtml(pair.player2.nickname)}</span>
          <span class="name">Lv.${pair.player2.level}</span>
        </div>
      </div>
    </div>
  `).join('');
}

function render(state) {
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
    render(state);
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
      render(msg.data);
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

loadInitialState();
connectWebSocket();
