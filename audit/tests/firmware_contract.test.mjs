// AUDIT TEST (emulator only, not part of the app's test suites).
//
// Replays the exact HTTP REST calls of the ESP32 sketch
// (C:\Users\Lenovo\Downloads\AgriFeed_code\AgriFeed_code.ino) and the exact
// multi-path writes of the Flutter app (lib/services/feeder_live.dart,
// FeederControls) against the Auth + Realtime Database emulators with the
// repository's database.rules.json. Uses only throw-away emulator accounts.
//
// Run (from the repo root, isolated ports 9199/9400 — see firebase.audit.json):
//   firebase --config audit/tests/firebase.audit.json emulators:start --project demo-agrifeed --only auth,database
//   FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9199 FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9400 \
//     npx vitest run audit/tests/firmware_contract.test.mjs
import { initializeApp, getApps } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { beforeAll, describe, expect, test } from 'vitest';

const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const DB_HOST = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
if (!/^127\.0\.0\.1:\d+$/.test(AUTH_HOST ?? '') || !/^127\.0\.0\.1:\d+$/.test(DB_HOST ?? '')) {
  throw new Error('Emulator hosts must be set to 127.0.0.1 (refusing to run against anything else).');
}
const NS = 'demo-agrifeed';
const KEY = 'fake-api-key'; // the Auth emulator accepts any key
const SV = { '.sv': 'timestamp' };
const F = 'fd_auditLiveFeederAAAAA'.slice(0, 23).padEnd(23, 'A'); // fd_ + 20 chars
const G = 'fd_auditOtherFeederBBBB'.slice(0, 23).padEnd(23, 'B');
const PASS = 'audit-' + Math.random().toString(36).slice(2, 12);

const app = getApps()[0] ?? initializeApp({ projectId: NS, databaseURL: `https://${NS}.firebaseio.com` });
const adminAuth = getAuth(app);
const adminDb = getDatabase(app);

// ---- the ESP32's HTTP calls (same endpoints, emulator host) -----------------
async function signInWithPassword(email, password) {
  const r = await fetch(`http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });
  return { code: r.status, body: await r.json() };
}
async function refreshToken(rt) {
  const r = await fetch(`http://${AUTH_HOST}/securetoken.googleapis.com/v1/token?key=${KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=refresh_token&refresh_token=${rt}`,
  });
  return { code: r.status, body: await r.json() };
}
/** One RTDB REST call, as dbCall() in the sketch builds it (+ ?ns= for the emulator). */
async function rest(method, path, token, body, query = '') {
  const url = `http://${DB_HOST}/${path}.json?ns=${NS}&auth=${token}${query}`;
  const init = { method };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers = { 'Content-Type': 'application/json' };
  }
  const r = await fetch(url, init);
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { code: r.status, json, text };
}

const tok = {};
const uid = {};
const dev = (method, sub, body, query) => rest(method, `feeders/${F}/${sub}`, tok.device, body, query);
const as = (who, method, sub, body, query) => rest(method, `feeders/${F}/${sub}`, tok[who], body, query);
/** Flutter's FeederLive.update(): one atomic multi-path PATCH at the root. */
const appUpdate = (who, values) => rest('PATCH', '', tok[who], values);
const pushId = () => '-Audit' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

let serverOffset = 0; // learned like learnServerTime() in the sketch

beforeAll(async () => {
  const people = {
    owner: { verified: true }, viewer: { verified: true }, feeder: { verified: true },
    outsider: { verified: true }, suspended: { verified: true },
    device: { verified: false }, otherdevice: { verified: false }, rogue: { verified: false },
  };
  for (const [k, v] of Object.entries(people)) {
    const email = `${k}@audit.test`;
    try { await adminAuth.deleteUser((await adminAuth.getUserByEmail(email)).uid); } catch {}
    const u = await adminAuth.createUser({ email, password: PASS, emailVerified: v.verified });
    uid[k] = u.uid;
  }
  const now = Date.now();
  await adminDb.ref().set({
    accountStatus: { [uid.suspended]: { suspended: true } },
    deviceRegistry: {
      [F]: { status: 'active', mode: 'live', ownerUid: uid.owner, deviceUid: uid.device, authMethod: 'password', credentialVersion: 1 },
      [G]: { status: 'active', mode: 'live', ownerUid: uid.outsider, deviceUid: uid.otherdevice, authMethod: 'password', credentialVersion: 1 },
    },
    deviceAccounts: { [uid.device]: { feederId: F }, [uid.otherdevice]: { feederId: G } },
    userFeeders: { [uid.owner]: { [F]: { role: 'owner' } } },
    feeders: {
      [F]: {
        meta: { name: 'Audit', ownerUid: uid.owner, mode: 'live', timezone: 'Asia/Manila', createdAt: now },
        config: { capacityG: 2500, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200, calibrationStatus: 'uncalibrated', schedulesPaused: false },
        members: {
          [uid.owner]: { role: 'owner', status: 'active' },
          [uid.viewer]: { role: 'member', status: 'active', permissions: { viewDashboard: true, viewHistory: true } },
          [uid.feeder]: { role: 'member', status: 'active', permissions: { viewDashboard: true, manualFeed: true, manageSchedules: true } },
          [uid.suspended]: { role: 'member', status: 'active', permissions: { viewDashboard: true, manualFeed: true } },
        },
      },
      [G]: { meta: { name: 'Other', ownerUid: uid.outsider, mode: 'live', timezone: 'UTC', createdAt: now } },
    },
  });
  for (const k of Object.keys(people)) {
    const r = await signInWithPassword(`${k}@audit.test`, PASS);
    if (r.code !== 200) throw new Error(`sign-in ${k} failed: ${r.code}`);
    tok[k] = r.body.idToken;
    if (k === 'device') tok.deviceRefresh = r.body.refreshToken;
  }
});

describe('A. ESP32 authentication (signIn() in the sketch)', () => {
  test('signInWithPassword returns idToken, refreshToken and expiresIn as a string', async () => {
    const r = await signInWithPassword('device@audit.test', PASS);
    expect(r.code).toBe(200);
    expect(typeof r.body.idToken).toBe('string');
    expect(typeof r.body.refreshToken).toBe('string');
    expect(typeof r.body.expiresIn).toBe('string'); // sketch reads res["expiresIn"] | "3600"
  });
  test('wrong password gives HTTP 400 (sketch sets accountRejected)', async () => {
    const r = await signInWithPassword('device@audit.test', 'wrong-password');
    expect(r.code).toBe(400);
  });
  test('refresh_token grant returns id_token / refresh_token / expires_in, usable for writes', async () => {
    const r = await refreshToken(tok.deviceRefresh);
    expect(r.code).toBe(200);
    expect(typeof r.body.id_token).toBe('string');
    expect(typeof r.body.refresh_token).toBe('string');
    expect(typeof r.body.expires_in).toBe('string');
    const w = await rest('PUT', `feeders/${F}/status`, r.body.id_token,
      { lastSeen: SV, condition: 'ok', rssi: -60, firmware: 'esp32-2.0', source: 'device' });
    expect(w.code).toBe(200);
  });
});

describe('B. ESP32 first-contact sequence and reporting (networkTask/report/measure)', () => {
  test('GET gate/state/lastRequestId (nothing yet) is allowed', async () => {
    const r = await dev('GET', 'gate/state/lastRequestId');
    expect(r.code).toBe(200);
    expect(r.json).toBeNull();
  });
  test('PUT config/calibrationStatus "uncalibrated"', async () => {
    expect((await dev('PUT', 'config/calibrationStatus', 'uncalibrated')).code).toBe(200);
  });
  test('GET meta/timezone, config, schedules', async () => {
    expect((await dev('GET', 'meta/timezone')).json).toBe('Asia/Manila');
    const c = await dev('GET', 'config');
    expect(c.code).toBe(200);
    expect(c.json.lowThresholdG).toBe(500);
    expect((await dev('GET', 'schedules')).code).toBe(200);
  });
  test('PUT status returns lastSeen resolved to a number (used to learn server time)', async () => {
    const r = await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', rssi: -55, firmware: 'esp32-2.0', source: 'device' });
    expect(r.code).toBe(200);
    expect(typeof r.json.lastSeen).toBe('number');
    serverOffset = r.json.lastSeen - Date.now();
  });
  test('PUT telemetry/current', async () => {
    const r = await dev('PUT', 'telemetry/current', { weightG: 1834, measuredAt: SV, quality: 'ok', source: 'device' });
    expect(r.code).toBe(200);
  });
  test('alert: PATCH without firstAt on a NEW alert is refused, then PUT with firstAt succeeds', async () => {
    const a = { type: 'low_feed', severity: 'warning', state: 'active', lastAt: SV, source: 'device' };
    expect((await dev('PATCH', 'alerts/low_feed', a)).code).toBe(401);
    expect((await dev('PUT', 'alerts/low_feed', { ...a, firstAt: SV })).code).toBe(200);
  });
  test('alert: PATCH resolve keeps firstAt', async () => {
    const r = await dev('PATCH', 'alerts/low_feed', { type: 'low_feed', severity: 'warning', state: 'resolved', lastAt: SV, source: 'device' });
    expect(r.code).toBe(200);
    const back = (await adminDb.ref(`feeders/${F}/alerts/low_feed`).get()).val();
    expect(typeof back.firstAt).toBe('number');
    expect(back.state).toBe('resolved');
  });
  test('alert: resolving an alert that never existed returns 401 (sketch treats this as done)', async () => {
    const r = await dev('PATCH', 'alerts/stuck_feed', { type: 'stuck_feed', severity: 'critical', state: 'resolved', lastAt: SV, source: 'device' });
    expect(r.code).toBe(401);
  });
  test('PUT gate/state (boot report, no request id)', async () => {
    expect((await dev('PUT', 'gate/state', { position: 'closed', reportedAt: SV, source: 'device' })).code).toBe(200);
  });
  test('POST measurements', async () => {
    const r = await dev('POST', 'measurements', { weightG: 1834, ts: SV, source: 'device' });
    expect(r.code).toBe(200);
    expect(typeof r.json.name).toBe('string');
  });
});

describe('C. Firebase -> Flutter: what the app can read of the device data', () => {
  test('owner reads status / telemetry / alerts / measurements / config / gate', async () => {
    for (const sub of ['status', 'telemetry/current', 'config', 'gate/state', 'measurements']) {
      const r = await as('owner', 'GET', sub);
      expect(r.code, sub).toBe(200);
    }
    const s = (await as('owner', 'GET', 'status')).json;
    expect(s.source).toBe('device');
    expect((await as('owner', 'GET', 'telemetry/current')).json.weightG).toBe(1834);
    const a = await as('owner', 'GET', 'alerts', undefined, '&orderBy=%22lastAt%22&limitToLast=50');
    expect(a.code).toBe(200);
  });
  test('viewer member (viewDashboard + viewHistory) reads status and history', async () => {
    expect((await as('viewer', 'GET', 'status')).code).toBe(200);
    expect((await as('viewer', 'GET', 'history', undefined, '&orderBy=%22ts%22&limitToLast=100')).code).toBe(200);
  });
  test('outsider, suspended member and the ESP32 of ANOTHER feeder cannot read the dashboard', async () => {
    expect((await as('outsider', 'GET', 'status')).code).toBe(401);
    expect((await as('suspended', 'GET', 'status')).code).toBe(401);
    expect((await as('otherdevice', 'GET', 'status')).code).toBe(401);
  });
});

describe('D. Manual feeding round trip (FeederControls.feedNow -> pollCommand/reportJob)', () => {
  let cid;
  test('owner creates command + activeCommand lock in one multi-path update', async () => {
    cid = pushId();
    const r = await appUpdate('owner', {
      [`feeders/${F}/commands/${cid}`]: { amountG: 50, requestedBy: uid.owner, requestedAt: SV, status: 'pending', source: 'app' },
      [`feeders/${F}/activeCommand`]: { commandId: cid, requestedAt: SV },
    });
    expect(r.code).toBe(200);
  });
  test('a second command while the lock is held is refused', async () => {
    const c2 = pushId();
    const r = await appUpdate('owner', {
      [`feeders/${F}/commands/${c2}`]: { amountG: 50, requestedBy: uid.owner, requestedAt: SV, status: 'pending', source: 'app' },
      [`feeders/${F}/activeCommand`]: { commandId: c2, requestedAt: SV },
    });
    expect(r.code).toBe(401);
  });
  test('device reads the lock and the command; command is fresh by server time', async () => {
    const lock = await dev('GET', 'activeCommand');
    expect(lock.json.commandId).toBe(cid);
    const c = await dev('GET', `commands/${cid}`);
    expect(c.json.status).toBe('pending');
    expect(Date.now() + serverOffset - c.json.requestedAt).toBeLessThan(120000);
  });
  test('device: accepted -> dispensing -> completed with measured actualG', async () => {
    expect((await dev('PATCH', `commands/${cid}`, { status: 'accepted', acceptedAt: SV, executedBy: 'device' })).code).toBe(200);
    expect((await dev('PATCH', `commands/${cid}`, { status: 'dispensing' })).code).toBe(200);
    expect((await dev('PATCH', `commands/${cid}`, { status: 'completed', actualG: 48, completedAt: SV })).code).toBe(200);
  });
  test('device: POST history (manual, commandId) and DELETE activeCommand', async () => {
    const h = await dev('POST', 'history', { method: 'manual', requestedG: 50, actualG: 48, status: 'completed', ts: SV, source: 'device', commandId: cid });
    expect(h.code).toBe(200);
    expect((await dev('DELETE', 'activeCommand')).code).toBe(200);
  });
  test('app sees the result: latest command by requestedAt and the history entry', async () => {
    const c = await as('owner', 'GET', 'commands', undefined, '&orderBy=%22requestedAt%22&limitToLast=1');
    expect(c.code).toBe(200);
    expect(Object.values(c.json)[0]).toMatchObject({ status: 'completed', actualG: 48 });
    const h = await as('owner', 'GET', 'history', undefined, '&orderBy=%22ts%22&limitToLast=100');
    expect(Object.values(h.json).some((e) => e.commandId === cid && e.actualG === 48)).toBe(true);
  });
  test('device rejects a command early (pending -> rejected, history with actualG 0)', async () => {
    const c = pushId();
    await appUpdate('owner', {
      [`feeders/${F}/commands/${c}`]: { amountG: 30, requestedBy: uid.owner, requestedAt: SV, status: 'pending', source: 'app' },
      [`feeders/${F}/activeCommand`]: { commandId: c, requestedAt: SV },
    });
    expect((await dev('PATCH', `commands/${c}`, { status: 'rejected', reason: 'Hopper is empty', executedBy: 'device', completedAt: SV })).code).toBe(200);
    expect((await dev('POST', 'history', { method: 'manual', requestedG: 30, actualG: 0, status: 'rejected', ts: SV, source: 'device', commandId: c })).code).toBe(200);
    expect((await dev('DELETE', 'activeCommand')).code).toBe(200);
  });
  test('RISK CHECK: if the "dispensing" PATCH is lost, accepted -> completed is refused', async () => {
    const c = pushId();
    await appUpdate('owner', {
      [`feeders/${F}/commands/${c}`]: { amountG: 30, requestedBy: uid.owner, requestedAt: SV, status: 'pending', source: 'app' },
      [`feeders/${F}/activeCommand`]: { commandId: c, requestedAt: SV },
    });
    expect((await dev('PATCH', `commands/${c}`, { status: 'accepted', acceptedAt: SV, executedBy: 'device' })).code).toBe(200);
    expect((await dev('PATCH', `commands/${c}`, { status: 'completed', actualG: 30, completedAt: SV })).code).toBe(401);
    // clean up as the sketch would after a restart
    expect((await dev('PATCH', `commands/${c}`, { status: 'failed', reason: 'audit cleanup', executedBy: 'device', completedAt: SV })).code).toBe(200);
    expect((await dev('DELETE', 'activeCommand')).code).toBe(200);
  });
  test('member with manualFeed may feed; viewer and suspended member may not', async () => {
    const mk = (who) => {
      const c = pushId();
      return appUpdate(who, {
        [`feeders/${F}/commands/${c}`]: { amountG: 20, requestedBy: uid[who], requestedAt: SV, status: 'pending', source: 'app' },
        [`feeders/${F}/activeCommand`]: { commandId: c, requestedAt: SV },
      });
    };
    expect((await mk('viewer')).code).toBe(401);
    expect((await mk('suspended')).code).toBe(401);
    expect((await mk('feeder')).code).toBe(200);
    const lock = (await dev('GET', 'activeCommand')).json;
    await dev('PATCH', `commands/${lock.commandId}`, { status: 'rejected', reason: 'audit cleanup', executedBy: 'device', completedAt: SV });
    expect((await dev('DELETE', 'activeCommand')).code).toBe(200);
  });
  test('device can neither create commands nor claim to be the simulator on a live feeder', async () => {
    expect((await dev('PUT', `commands/${pushId()}`, { amountG: 20, requestedBy: uid.device, requestedAt: SV, status: 'pending', source: 'app' })).code).toBe(401);
    expect((await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'simulator' })).code).toBe(401);
  });
});

describe('E. Gate round trip (FeederControls.gate -> pollGate/writeGateState)', () => {
  test('owner request -> device reads it within 10 s -> device reports open with lastRequestId', async () => {
    const id = pushId();
    expect((await appUpdate('owner', {
      [`feeders/${F}/gate/request`]: { id, action: 'open', durationS: 5, requestedAt: SV, requestedBy: uid.owner },
    })).code).toBe(200);
    const r = (await dev('GET', 'gate/request')).json;
    expect(r.id).toBe(id);
    expect(Date.now() + serverOffset - r.requestedAt).toBeLessThan(10000);
    const w = await dev('PUT', 'gate/state', {
      position: 'open', reportedAt: SV, source: 'device', lastRequestId: id, lastResult: 'done', closesAt: Date.now() + serverOffset + 5000,
    });
    expect(w.code).toBe(200);
    expect((await as('owner', 'GET', 'gate/state')).json.lastRequestId).toBe(id);
  });
  test('device rejection report (lastResult rejected + reason) is accepted', async () => {
    expect((await dev('PUT', 'gate/state', { position: 'closed', reportedAt: SV, source: 'device', lastRequestId: pushId(), lastResult: 'rejected', reason: 'Request older than 10 s' })).code).toBe(200);
  });
  test('durationS above 15 and a viewer request are refused', async () => {
    expect((await appUpdate('owner', { [`feeders/${F}/gate/request`]: { id: pushId(), action: 'open', durationS: 20, requestedAt: SV, requestedBy: uid.owner } })).code).toBe(401);
    expect((await appUpdate('viewer', { [`feeders/${F}/gate/request`]: { id: pushId(), action: 'open', durationS: 5, requestedAt: SV, requestedBy: uid.viewer } })).code).toBe(401);
  });
});

describe('F. Schedules (FeederControls.saveSchedule -> pollSchedules / checkSchedules)', () => {
  const sid = pushId();
  test('owner saves a schedule with weekdays as {"0":bool..."6":bool}', async () => {
    const r = await appUpdate('owner', {
      [`feeders/${F}/schedules/${sid}`]: {
        time: '07:30', amountG: 100, weekdays: { 0: false, 1: true, 2: true, 3: true, 4: true, 5: true, 6: false },
        enabled: true, createdAt: SV, updatedAt: SV, updatedBy: uid.owner,
      },
    });
    expect(r.code).toBe(200);
  });
  test('device reads schedules; weekdays come back as a JSON ARRAY (sketch handles both)', async () => {
    const s = (await dev('GET', 'schedules')).json[sid];
    expect(s.time).toBe('07:30');
    expect(Array.isArray(s.weekdays)).toBe(true);
    expect(s.weekdays).toEqual([false, true, true, true, true, true, false]);
  });
  test('schedule amount above config.maxDispenseG (200) is refused', async () => {
    const r = await appUpdate('owner', {
      [`feeders/${F}/schedules/${pushId()}`]: {
        time: '08:00', amountG: 250, weekdays: { 0: true }, enabled: true, createdAt: SV, updatedAt: SV, updatedBy: uid.owner,
      },
    });
    expect(r.code).toBe(401);
  });
  test('pause/resume: owner writes config/schedulesPaused, device reads it', async () => {
    expect((await appUpdate('owner', { [`feeders/${F}/config/schedulesPaused`]: true })).code).toBe(200);
    expect((await dev('GET', 'config')).json.schedulesPaused).toBe(true);
    expect((await appUpdate('owner', { [`feeders/${F}/config/schedulesPaused`]: false })).code).toBe(200);
  });
  test('device records a scheduled feeding in history (scheduleId)', async () => {
    expect((await dev('POST', 'history', { method: 'scheduled', requestedG: 100, actualG: 97, status: 'completed', ts: SV, source: 'device', scheduleId: sid })).code).toBe(200);
  });
  test('RISK CHECK: scheduled history with requestedG 0 is refused (validate num(1,500))', async () => {
    expect((await dev('POST', 'history', { method: 'scheduled', requestedG: 0, actualG: 0, status: 'rejected', ts: SV, source: 'device', scheduleId: sid })).code).toBe(401);
  });
  test('RISK CHECK: history with a device-side timestamp (offline feeding time) is refused; only server "now" is allowed', async () => {
    expect((await dev('POST', 'history', { method: 'scheduled', requestedG: 100, actualG: 97, status: 'completed', ts: Date.now() - 3600000, source: 'device', scheduleId: sid })).code).toBe(401);
  });
  test('owner deletes the schedule; device then reads nothing', async () => {
    expect((await appUpdate('owner', { [`feeders/${F}/schedules/${sid}`]: null })).code).toBe(200);
    const s = (await dev('GET', 'schedules')).json;
    expect(s === null || s[sid] === undefined).toBe(true);
  });
});

describe('G. Device identity restrictions', () => {
  test('a password account NOT bound in deviceRegistry cannot write', async () => {
    expect((await as('rogue', 'PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(401);
  });
  test('the ESP32 account of feeder G cannot write feeder F', async () => {
    expect((await as('otherdevice', 'PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(401);
  });
  test('device cannot read alerts, members, audit or userFeeders (sketch never needs to)', async () => {
    expect((await dev('GET', 'alerts')).code).toBe(401);
    expect((await dev('GET', 'members')).code).toBe(401);
    expect((await rest('GET', `userFeeders/${uid.owner}`, tok.device)).code).toBe(401);
  });
  test('device account is not treated as a person (cannot write users/{uid})', async () => {
    expect((await rest('PUT', `users/${uid.device}`, tok.device, { displayName: 'x', createdAt: SV })).code).toBe(401);
  });
  test('disabling the registry entry revokes the device immediately', async () => {
    await adminDb.ref(`deviceRegistry/${F}/status`).set('disabled');
    expect((await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(401);
    await adminDb.ref(`deviceRegistry/${F}/status`).set('active');
    expect((await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(200);
  });
  test('without authMethod "password" in the registry the email/password device is refused', async () => {
    await adminDb.ref(`deviceRegistry/${F}/authMethod`).remove();
    expect((await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(401);
    await adminDb.ref(`deviceRegistry/${F}/authMethod`).set('password');
  });
  test('registry mode "simulated" makes source "device" invalid (live/sim isolation)', async () => {
    await adminDb.ref(`deviceRegistry/${F}/mode`).set('simulated');
    expect((await dev('PUT', 'status', { lastSeen: SV, condition: 'ok', source: 'device' })).code).toBe(401);
    await adminDb.ref(`deviceRegistry/${F}/mode`).set('live');
  });
});
