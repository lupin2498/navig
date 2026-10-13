import fs from 'node:fs';
import path from 'node:path';

const EMPTY = () => ({ users: {}, groups: {}, locations: {}, history: {} });

/**
 * Tiny JSON-file backed store. Everything lives in memory and is flushed to
 * disk (atomically, debounced) after each mutation. Good enough for groups of
 * friends; swap for a real database if you need to scale.
 */
export class Store {
  constructor(dataDir) {
    this.file = dataDir ? path.join(dataDir, 'db.json') : null;
    this.data = EMPTY();
    this.saveTimer = null;
    if (this.file) {
      fs.mkdirSync(dataDir, { recursive: true });
      this.load();
    }
  }

  load() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8');
      this.data = { ...EMPTY(), ...JSON.parse(raw) };
    } catch (err) {
      if (err.code !== 'ENOENT') {
        console.error(`[store] cannot read ${this.file}:`, err.message);
      }
    }
  }

  save() {
    if (!this.file || this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      this.flush();
    }, 1000);
  }

  flush() {
    if (!this.file) return;
    if (this.saveTimer) {
      clearTimeout(this.saveTimer);
      this.saveTimer = null;
    }
    const tmp = `${this.file}.tmp`;
    try {
      fs.writeFileSync(tmp, JSON.stringify(this.data));
      fs.renameSync(tmp, this.file);
    } catch (err) {
      console.error('[store] save failed:', err.message);
    }
  }
}
