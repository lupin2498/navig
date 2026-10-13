import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';
import { Store } from './store.js';
import { distanceMeters } from './geo.js';

const MAX_BODY_BYTES = 256 * 1024;
const MAX_GROUP_MEMBERS = 50;
const MAX_GROUPS_PER_USER = 20;
const STAY_RADIUS_M = 100;
const MOVING_SPEED_MS = 1.5;
const HISTORY_MIN_DISTANCE_M = 25;
const HISTORY_MIN_INTERVAL_MS = 5 * 60 * 1000;
const HISTORY_MAX_POINTS = 5000;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const COLORS = ['#FF4D6D', '#7B61FF', '#00B4D8', '#2EC4B6', '#FF9F1C', '#8AC926', '#F15BB5', '#3A86FF'];

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const newId = () => crypto.randomUUID();

function cleanText(value, max) {
  if (typeof value !== 'string') return '';
  return value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, max);
}

function num(value, min, max) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || n > max) return null;
  return n;
}

export function createApp({
  dataDir = null,
  historyHours = 24,
  now = () => Date.now(),
} = {}) {
  const store = new Store(dataDir);
  const db = store.data;
  const tokenIndex = new Map(); // tokenHash -> userId
  const sockets = new Map(); // userId -> Set<WebSocket>

  for (const user of Object.values(db.users)) {
    if (user.tokenHash) tokenIndex.set(user.tokenHash, user.id);
  }

  // ---------------------------------------------------------------- helpers

  const publicUser = (u) => ({
    id: u.id,
    name: u.name,
    color: u.color,
    emoji: u.emoji,
    sharing: u.sharing !== false,
  });

  function publicLocation(userId) {
    const user = db.users[userId];
    const loc = db.locations[userId];
    if (!user || !loc || user.sharing === false) return null;
    return {
      lat: loc.lat,
      lng: loc.lng,
      accuracy: loc.accuracy,
      speed: loc.speed,
      heading: loc.heading,
      battery: loc.battery,
      charging: loc.charging,
      ts: loc.ts,
      stayStart: loc.stayStart,
      moving: loc.speed !== null && loc.speed >= MOVING_SPEED_MS,
    };
  }

  const isOnline = (userId) => (sockets.get(userId)?.size ?? 0) > 0;

  function groupView(group) {
    return {
      id: group.id,
      name: group.name,
      code: group.code,
      ownerId: group.ownerId,
      createdAt: group.createdAt,
      members: group.memberIds
        .filter((id) => db.users[id])
        .map((id) => ({
          ...publicUser(db.users[id]),
          online: isOnline(id),
          lastSeen: db.users[id].lastSeen ?? null,
          location: publicLocation(id),
        })),
    };
  }

  const groupsOf = (userId) =>
    Object.values(db.groups).filter((g) => g.memberIds.includes(userId));

  function contactsOf(userId) {
    const ids = new Set([userId]);
    for (const g of groupsOf(userId)) for (const id of g.memberIds) ids.add(id);
    return ids;
  }

  function send(userIds, message) {
    const payload = JSON.stringify(message);
    for (const id of userIds) {
      for (const ws of sockets.get(id) ?? []) {
        if (ws.readyState === ws.OPEN) ws.send(payload);
      }
    }
  }

  const broadcastGroup = (group) =>
    send(group.memberIds, { type: 'group', group: groupView(group) });

  function uniqueCode() {
    const taken = new Set(Object.values(db.groups).map((g) => g.code));
    for (;;) {
      let code = '';
      const bytes = crypto.randomBytes(6);
      for (const b of bytes) code += CODE_ALPHABET[b % CODE_ALPHABET.length];
      if (!taken.has(code)) return code;
    }
  }

  function authenticate(token) {
    if (!token) return null;
    const userId = tokenIndex.get(sha256(token));
    return userId ? db.users[userId] : null;
  }

  function requireGroupMember(user, groupId) {
    const group = db.groups[groupId];
    if (!group || !group.memberIds.includes(user.id)) {
      throw new HttpError(404, 'Không tìm thấy nhóm');
    }
    return group;
  }

  function removeMember(group, userId) {
    group.memberIds = group.memberIds.filter((id) => id !== userId);
    if (group.memberIds.length === 0) {
      delete db.groups[group.id];
      return;
    }
    if (group.ownerId === userId) group.ownerId = group.memberIds[0];
    broadcastGroup(group);
  }

  // --------------------------------------------------------------- location

  function recordLocation(user, input) {
    const lat = num(input.lat, -90, 90);
    const lng = num(input.lng, -180, 180);
    if (lat === null || lng === null) throw new HttpError(400, 'Toạ độ không hợp lệ');

    const serverNow = now();
    let ts = num(input.ts, 0, Number.MAX_SAFE_INTEGER) ?? serverNow;
    if (ts > serverNow) ts = serverNow;

    const prev = db.locations[user.id];
    if (prev && ts < prev.ts) return false; // stale point from an offline queue

    const point = {
      lat,
      lng,
      accuracy: num(input.accuracy, 0, 100000),
      speed: num(input.speed, 0, 500),
      heading: num(input.heading, 0, 360),
      altitude: num(input.altitude, -1000, 100000),
      battery: num(input.battery, 0, 100),
      charging: typeof input.charging === 'boolean' ? input.charging : null,
      ts,
    };
    if (point.battery !== null) point.battery = Math.round(point.battery);

    // "Stayed here for ..." – keep the anchor while the user remains nearby.
    const radius = Math.max(STAY_RADIUS_M, Math.min(point.accuracy ?? 0, 500));
    const moving = point.speed !== null && point.speed >= MOVING_SPEED_MS;
    if (prev && !moving && distanceMeters(prev.anchor, point) <= radius) {
      point.anchor = prev.anchor;
      point.stayStart = prev.stayStart;
    } else {
      point.anchor = { lat, lng };
      point.stayStart = ts;
    }
    db.locations[user.id] = point;

    const history = (db.history[user.id] ??= []);
    const last = history[history.length - 1];
    if (
      !last ||
      distanceMeters(last, point) >= HISTORY_MIN_DISTANCE_M ||
      ts - last.ts >= HISTORY_MIN_INTERVAL_MS
    ) {
      history.push({ lat, lng, ts, speed: point.speed });
    }
    const cutoff = serverNow - historyHours * 3600 * 1000;
    while (history.length && (history[0].ts < cutoff || history.length > HISTORY_MAX_POINTS)) {
      history.shift();
    }
    return true;
  }

  function handleLocations(user, body) {
    const points = Array.isArray(body?.points) ? body.points : [body];
    let changed = false;
    for (const p of points.slice(-500)) {
      if (p && typeof p === 'object' && recordLocation(user, p)) changed = true;
    }
    user.lastSeen = now();
    store.save();
    if (changed && user.sharing !== false) {
      send(contactsOf(user.id), {
        type: 'location',
        userId: user.id,
        location: publicLocation(user.id),
      });
    }
    return { ok: true, location: db.locations[user.id] ? publicLocation(user.id) : null };
  }

  // ------------------------------------------------------------------ routes

  const routes = [];
  const route = (method, pattern, handler, { auth = true } = {}) =>
    routes.push({ method, pattern, handler, auth });

  route('GET', /^\/(health)?$/, () => ({ ok: true, service: 'navig', time: now() }), {
    auth: false,
  });

  route(
    'POST',
    /^\/api\/register$/,
    ({ body }) => {
      const name = cleanText(body?.name, 40);
      if (!name) throw new HttpError(400, 'Vui lòng nhập tên');
      const token = crypto.randomBytes(32).toString('base64url');
      const user = {
        id: newId(),
        name,
        color: /^#[0-9a-fA-F]{6}$/.test(body?.color ?? '')
          ? body.color
          : COLORS[crypto.randomInt(COLORS.length)],
        emoji: cleanText(body?.emoji, 16),
        sharing: true,
        createdAt: now(),
        lastSeen: now(),
        tokenHash: sha256(token),
      };
      db.users[user.id] = user;
      tokenIndex.set(user.tokenHash, user.id);
      store.save();
      return { token, user: publicUser(user) };
    },
    { auth: false },
  );

  route('GET', /^\/api\/me$/, ({ user }) => ({
    user: publicUser(user),
    groups: groupsOf(user.id).map(groupView),
  }));

  route('PATCH', /^\/api\/me$/, ({ user, body }) => {
    if (body?.name !== undefined) {
      const name = cleanText(body.name, 40);
      if (!name) throw new HttpError(400, 'Tên không được để trống');
      user.name = name;
    }
    if (body?.color !== undefined && /^#[0-9a-fA-F]{6}$/.test(body.color)) user.color = body.color;
    if (body?.emoji !== undefined) user.emoji = cleanText(body.emoji, 16);
    if (typeof body?.sharing === 'boolean') user.sharing = body.sharing;
    store.save();
    const contacts = contactsOf(user.id);
    send(contacts, { type: 'profile', user: publicUser(user) });
    send(contacts, { type: 'location', userId: user.id, location: publicLocation(user.id) });
    return { user: publicUser(user) };
  });

  route('DELETE', /^\/api\/me$/, ({ user }) => {
    for (const g of groupsOf(user.id)) removeMember(g, user.id);
    tokenIndex.delete(user.tokenHash);
    delete db.users[user.id];
    delete db.locations[user.id];
    delete db.history[user.id];
    for (const ws of sockets.get(user.id) ?? []) ws.close(4001, 'deleted');
    store.save();
    return { ok: true };
  });

  route('GET', /^\/api\/groups$/, ({ user }) => ({ groups: groupsOf(user.id).map(groupView) }));

  route('POST', /^\/api\/groups$/, ({ user, body }) => {
    const name = cleanText(body?.name, 50);
    if (!name) throw new HttpError(400, 'Vui lòng nhập tên nhóm');
    if (groupsOf(user.id).length >= MAX_GROUPS_PER_USER) {
      throw new HttpError(400, `Tối đa ${MAX_GROUPS_PER_USER} nhóm`);
    }
    const group = {
      id: newId(),
      name,
      code: uniqueCode(),
      ownerId: user.id,
      memberIds: [user.id],
      createdAt: now(),
    };
    db.groups[group.id] = group;
    store.save();
    return { group: groupView(group) };
  });

  route('POST', /^\/api\/groups\/join$/, ({ user, body }) => {
    const code = cleanText(body?.code, 12).toUpperCase().replace(/\s/g, '');
    const group = Object.values(db.groups).find((g) => g.code === code);
    if (!group) throw new HttpError(404, 'Mã mời không đúng');
    if (!group.memberIds.includes(user.id)) {
      if (group.memberIds.length >= MAX_GROUP_MEMBERS) {
        throw new HttpError(400, `Nhóm đã đủ ${MAX_GROUP_MEMBERS} thành viên`);
      }
      if (groupsOf(user.id).length >= MAX_GROUPS_PER_USER) {
        throw new HttpError(400, `Tối đa ${MAX_GROUPS_PER_USER} nhóm`);
      }
      group.memberIds.push(user.id);
      store.save();
      broadcastGroup(group);
    }
    return { group: groupView(group) };
  });

  route('GET', /^\/api\/groups\/([\w-]+)$/, ({ user, params }) => ({
    group: groupView(requireGroupMember(user, params[0])),
  }));

  route('PATCH', /^\/api\/groups\/([\w-]+)$/, ({ user, params, body }) => {
    const group = requireGroupMember(user, params[0]);
    const name = cleanText(body?.name, 50);
    if (name) group.name = name;
    if (body?.regenerateCode === true) {
      if (group.ownerId !== user.id) throw new HttpError(403, 'Chỉ trưởng nhóm được đổi mã');
      group.code = uniqueCode();
    }
    store.save();
    broadcastGroup(group);
    return { group: groupView(group) };
  });

  route('POST', /^\/api\/groups\/([\w-]+)\/leave$/, ({ user, params }) => {
    const group = requireGroupMember(user, params[0]);
    removeMember(group, user.id);
    send([user.id], { type: 'group_removed', groupId: group.id });
    store.save();
    return { ok: true };
  });

  route('DELETE', /^\/api\/groups\/([\w-]+)\/members\/([\w-]+)$/, ({ user, params }) => {
    const group = requireGroupMember(user, params[0]);
    if (group.ownerId !== user.id) throw new HttpError(403, 'Chỉ trưởng nhóm được xoá thành viên');
    const targetId = params[1];
    if (targetId === user.id || !group.memberIds.includes(targetId)) {
      throw new HttpError(400, 'Thành viên không hợp lệ');
    }
    removeMember(group, targetId);
    send([targetId], { type: 'group_removed', groupId: group.id });
    store.save();
    return { group: groupView(group) };
  });

  route('POST', /^\/api\/location$/, ({ user, body }) => handleLocations(user, body));

  route('GET', /^\/api\/users\/([\w-]+)\/history$/, ({ user, params, query }) => {
    const targetId = params[0];
    if (!contactsOf(user.id).has(targetId) || !db.users[targetId]) {
      throw new HttpError(404, 'Không tìm thấy người dùng');
    }
    if (db.users[targetId].sharing === false) return { points: [] };
    const hours = num(query.get('hours'), 1, historyHours) ?? historyHours;
    const since = now() - hours * 3600 * 1000;
    const points = (db.history[targetId] ?? []).filter((p) => p.ts >= since);
    const latest = db.locations[targetId];
    if (latest && (!points.length || points[points.length - 1].ts < latest.ts)) {
      points.push({ lat: latest.lat, lng: latest.lng, ts: latest.ts, speed: latest.speed });
    }
    return { points };
  });

  route('POST', /^\/api\/users\/([\w-]+)\/nudge$/, ({ user, params, body }) => {
    const targetId = params[0];
    if (targetId === user.id || !contactsOf(user.id).has(targetId)) {
      throw new HttpError(404, 'Không tìm thấy người dùng');
    }
    const message = cleanText(body?.message, 100) || '👋';
    send([targetId], { type: 'nudge', from: publicUser(user), message, ts: now() });
    return { ok: true, delivered: isOnline(targetId) };
  });

  // ------------------------------------------------------------- http server

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let size = 0;
      const chunks = [];
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          reject(new HttpError(413, 'Dữ liệu quá lớn'));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on('end', () => {
        if (!chunks.length) return resolve({});
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch {
          reject(new HttpError(400, 'JSON không hợp lệ'));
        }
      });
      req.on('error', reject);
    });
  }

  function reply(res, status, payload) {
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    });
    res.end(payload === undefined ? '' : JSON.stringify(payload));
  }

  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === 'OPTIONS') return reply(res, 204);
      const url = new URL(req.url, 'http://localhost');
      let pathMatched = false;
      for (const r of routes) {
        const m = r.pattern.exec(url.pathname);
        if (!m) continue;
        pathMatched = true;
        if (r.method !== req.method) continue;
        let user = null;
        if (r.auth) {
          const header = req.headers.authorization ?? '';
          user = authenticate(header.startsWith('Bearer ') ? header.slice(7) : null);
          if (!user) throw new HttpError(401, 'Phiên đăng nhập không hợp lệ');
        }
        const body = ['POST', 'PATCH', 'PUT'].includes(req.method) ? await readBody(req) : {};
        const result = await r.handler({ user, body, params: m.slice(1), query: url.searchParams });
        return reply(res, 200, result);
      }
      throw new HttpError(pathMatched ? 405 : 404, 'Không tìm thấy');
    } catch (err) {
      if (!(err instanceof HttpError)) console.error('[http]', err);
      const status = err instanceof HttpError ? err.status : 500;
      reply(res, status, { error: status === 500 ? 'Lỗi máy chủ' : err.message });
    }
  });

  // -------------------------------------------------------------- websocket

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY_BYTES });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/ws') return socket.destroy();
    const user = authenticate(url.searchParams.get('token'));
    if (!user) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return socket.destroy();
    }
    wss.handleUpgrade(req, socket, head, (ws) => onConnection(ws, user.id));
  });

  function onConnection(ws, userId) {
    const set = sockets.get(userId) ?? new Set();
    const wasOnline = set.size > 0;
    set.add(ws);
    sockets.set(userId, set);
    ws.isAlive = true;

    const user = db.users[userId];
    user.lastSeen = now();
    ws.send(
      JSON.stringify({
        type: 'hello',
        user: publicUser(user),
        groups: groupsOf(userId).map(groupView),
      }),
    );
    if (!wasOnline) send(contactsOf(userId), { type: 'presence', userId, online: true });

    ws.on('pong', () => {
      ws.isAlive = true;
    });

    ws.on('message', (raw) => {
      const current = db.users[userId];
      if (!current) return ws.close(4001, 'deleted');
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      try {
        if (msg.type === 'location') {
          const result = handleLocations(current, msg);
          ws.send(JSON.stringify({ type: 'ack', id: msg.id ?? null, ok: result.ok }));
        } else if (msg.type === 'ping') {
          current.lastSeen = now();
          ws.send(JSON.stringify({ type: 'pong', time: now() }));
        }
      } catch (err) {
        ws.send(JSON.stringify({ type: 'error', id: msg.id ?? null, error: err.message }));
      }
    });

    ws.on('close', () => {
      set.delete(ws);
      if (set.size === 0) {
        sockets.delete(userId);
        if (db.users[userId]) {
          db.users[userId].lastSeen = now();
          store.save();
          send(contactsOf(userId), { type: 'presence', userId, online: false });
        }
      }
    });
  }

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      ws.ping();
    }
  }, 30000);
  heartbeat.unref();

  server.on('close', () => {
    clearInterval(heartbeat);
    store.flush();
  });

  return {
    server,
    store,
    close: () =>
      new Promise((resolve) => {
        for (const ws of wss.clients) ws.terminate();
        server.close(() => resolve());
      }),
  };
}
