const fs = require('fs');
const path = require('path');
const { RunState } = require('./state');

function generateRunId(date = new Date()) {
  const iso = date.toISOString(); // e.g. 2026-08-15T13:40:00.000Z
  const stamp = iso.slice(0, 19).replace(/:/g, '-');
  return `run-${stamp}`;
}

// Owns which RunState is currently active. The Lua clients are unaware of
// "runs" (their events array is just "everything since script start"); the
// server decides run identity/lifecycle, so switching runs here doesn't
// require touching the BizHawk side at all.
//
// On startup, resumes whichever run a pointer file says was active (loading
// its snapshot/CSV via RunState's own recovery) rather than always minting a
// fresh run-id -- otherwise a server restart mid-run would silently start a
// second CSV and replay every catch as "new" into it.
class RunManager {
  constructor(runsDir) {
    this.runsDir = runsDir;
    this.pointerPath = path.join(runsDir, 'current-run.json');
    fs.mkdirSync(runsDir, { recursive: true });

    const resumedRunId = this._readPointer();
    this.current = new RunState(resumedRunId || generateRunId(), runsDir);
    this._writePointer(this.current.runId);
  }

  _readPointer() {
    try {
      const data = JSON.parse(fs.readFileSync(this.pointerPath, 'utf8'));
      return data.runId || null;
    } catch (err) {
      return null;
    }
  }

  _writePointer(runId) {
    const tmpPath = this.pointerPath + '.tmp';
    fs.writeFileSync(tmpPath, JSON.stringify({ runId }));
    fs.renameSync(tmpPath, this.pointerPath);
  }

  startNewRun(explicitId) {
    const runId = explicitId || generateRunId();
    this.current = new RunState(runId, this.runsDir);
    this._writePointer(runId);
    console.log(`[run] started new run: ${runId}`);
    return this.current;
  }
}

module.exports = { RunManager, generateRunId };
