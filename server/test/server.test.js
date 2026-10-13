import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import { createApp } from '../src/server.js';

let app;
let base;
let clock = Date.now();
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'navig-test-'));

before(async () => {
  app = createApp({ dataDir, now: () => clock });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  await app.close();
  fs.rmSync(dataDir, { recursive: true, force: true });
});

async function api(method, url, { token, body } = {}) {
  const res = await fetch(base + url, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  return { status: res.status, ...json };
}

function connect(token) {
  const ws = new WebSocket(`${base.replace('http', 'ws')}/ws?token=${token}`);
  const queue = [];
  const waiters = [];
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    const i = waiters.findIndex((w) => w.match(msg));
    if (i >= 0) waiters.splice(i, 1)[0].resolve(msg);
    else queue.push(msg);
  });
  ws.next = (type, pred = () => true) =>
    new Promise((resolve, reject) => {
      const match = (m) => m.type === type && pred(m);
      const i = queue.findIndex(match);
      if (i >= 0) return resolve(queue.splice(i, 1)[0]);
      const timer = setTimeout(() => reject(new Error(`timeout waiting for ${type}`)), 3000);
      waiters.push({ match, resolve: (m) => (clearTimeout(timer), resolve(m)) });
    });
  return ws;
}

test('full group location sharing flow', async () => {
  const alice = await api('POST', '/api/register', { body: { name: 'Alice', emoji: '🐱' } });
  const bob = await api('POST', '/api/register', { body: { name: 'Bob' } });
  assert.equal(alice.status, 200);
  assert.ok(alice.token);
  assert.equal(alice.user.name, 'Alice');

  const unauth = await api('GET', '/api/me');
  assert.equal(unauth.status, 401);

  const created = await api('POST', '/api/groups', { token: alice.token, body: { name: 'Hội bạn thân' } });
  assert.equal(created.group.members.length, 1);
  assert.match(created.group.code, /^[A-Z2-9]{6}$/);

  const wrong = await api('POST', '/api/groups/join', { token: bob.token, body: { code: 'XXXXXX' } });
  assert.equal(wrong.status, 404);

  const aliceWs = connect(alice.token);
  const hello = await aliceWs.next('hello');
  assert.equal(hello.groups.length, 1);

  const joined = await api('POST', '/api/groups/join', {
    token: bob.token,
    body: { code: created.group.code.toLowerCase() },
  });
  assert.equal(joined.group.members.length, 2);
  const groupMsg = await aliceWs.next('group');
  assert.equal(groupMsg.group.members.length, 2);

  // Bob shares his location -> Alice gets it in realtime.
  const t0 = clock;
  await api('POST', '/api/location', {
    token: bob.token,
    body: { lat: 21.0285, lng: 105.8542, accuracy: 10, speed: 0, battery: 76.4, charging: false, ts: t0 },
  });
  const loc = await aliceWs.next('location');
  assert.equal(loc.userId, bob.user.id);
  assert.equal(loc.location.battery, 76);
  assert.equal(loc.location.stayStart, t0);
  assert.equal(loc.location.moving, false);

  // Small jitter keeps the stay anchor.
  clock += 10 * 60 * 1000;
  await api('POST', '/api/location', {
    token: bob.token,
    body: { lat: 21.0287, lng: 105.8543, speed: 0, ts: clock },
  });
  const loc2 = await aliceWs.next('location');
  assert.equal(loc2.location.stayStart, t0);

  // Moving fast resets it.
  clock += 60 * 1000;
  await api('POST', '/api/location', {
    token: bob.token,
    body: { lat: 21.04, lng: 105.86, speed: 12, ts: clock },
  });
  const loc3 = await aliceWs.next('location');
  assert.equal(loc3.location.moving, true);
  assert.equal(loc3.location.stayStart, clock);

  // Location over websocket from Alice reaches Bob.
  const bobWs = connect(bob.token);
  await bobWs.next('hello');
  aliceWs.send(JSON.stringify({ type: 'location', id: 1, lat: 10.77, lng: 106.7, battery: 50 }));
  const ack = await aliceWs.next('ack');
  assert.equal(ack.ok, true);
  const fromAlice = await bobWs.next('location', (m) => m.userId === alice.user.id);
  assert.equal(fromAlice.location.lat, 10.77);

  // History
  const hist = await api('GET', `/api/users/${bob.user.id}/history`, { token: alice.token });
  assert.ok(hist.points.length >= 2);

  // Nudge
  const nudge = await api('POST', `/api/users/${bob.user.id}/nudge`, {
    token: alice.token,
    body: { message: 'Đang ở đâu đó?' },
  });
  assert.equal(nudge.delivered, true);
  const nudgeMsg = await bobWs.next('nudge');
  assert.equal(nudgeMsg.from.name, 'Alice');

  // Pausing hides the location from others.
  await api('PATCH', '/api/me', { token: bob.token, body: { sharing: false } });
  const hidden = await aliceWs.next('location', (m) => m.userId === bob.user.id);
  assert.equal(hidden.location, null);
  const g = await api('GET', `/api/groups/${created.group.id}`, { token: alice.token });
  assert.equal(g.group.members.find((m) => m.id === bob.user.id).location, null);

  // Strangers cannot see history.
  const eve = await api('POST', '/api/register', { body: { name: 'Eve' } });
  const denied = await api('GET', `/api/users/${alice.user.id}/history`, { token: eve.token });
  assert.equal(denied.status, 404);

  // Owner removes Bob.
  const removed = await api('DELETE', `/api/groups/${created.group.id}/members/${bob.user.id}`, {
    token: alice.token,
  });
  assert.equal(removed.group.members.length, 1);
  await bobWs.next('group_removed');

  // Leaving the last member deletes the group.
  await api('POST', `/api/groups/${created.group.id}/leave`, { token: alice.token });
  const gone = await api('GET', `/api/groups/${created.group.id}`, { token: alice.token });
  assert.equal(gone.status, 404);

  aliceWs.close();
  bobWs.close();
});

test('data survives restart and deleted accounts lose access', async () => {
  const carol = await api('POST', '/api/register', { body: { name: 'Carol' } });
  await api('POST', '/api/groups', { token: carol.token, body: { name: 'Team' } });
  app.store.flush();

  const reloaded = createApp({ dataDir, now: () => clock });
  await new Promise((resolve) => reloaded.server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${reloaded.server.address().port}/api/me`;
  const me = await fetch(url, { headers: { Authorization: `Bearer ${carol.token}` } }).then((r) => r.json());
  assert.equal(me.user.name, 'Carol');
  assert.equal(me.groups[0].name, 'Team');
  await reloaded.close();

  const del = await api('DELETE', '/api/me', { token: carol.token });
  assert.equal(del.ok, true);
  const after = await api('GET', '/api/me', { token: carol.token });
  assert.equal(after.status, 401);
});

test('rejects invalid coordinates', async () => {
  const dan = await api('POST', '/api/register', { body: { name: 'Dan' } });
  const bad = await api('POST', '/api/location', { token: dan.token, body: { lat: 200, lng: 0 } });
  assert.equal(bad.status, 400);
});
