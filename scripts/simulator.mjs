// Simulated AgriFeed controller for the LOCAL emulator. Stands in for the
// ESP32 so the whole app can be tried without a machine.
//
//   npm run simulator                 (the seeded owner's feeder)
//   npm run simulator -- fd_XXXX      (a specific feeder)
//
// It signs in as the feeder's own device identity (custom token with
// device claims) and writes through the Security Rules exactly like the
// real controller will: status, telemetry, measurements, history, alerts,
// gate state and command outcomes, all marked source 'simulator'.
//
// Behaviour:
//  * hopper weight in grams, reported every 5 s; low-feed alert below the
//    configured threshold, resolved after a refill;
//  * manual feeding: pending -> accepted -> dispensing -> completed at
//    ~25 g/s, limited by what is in the hopper (partial / rejected);
//  * schedules run at their HH:MM in the feeder's time zone, once per day;
//  * gate: OPEN for durationS (max 15 s), closed by the controller itself;
//    CLOSE wins; requests older than 10 s are rejected; feed drops while open;
//  * simulator/controls (owner, simulated feeders only): hopperWeightG
//    refills, connected=false goes silent, jam=true fails dispensing.
import { initializeApp } from 'firebase/app';
import { connectAuthEmulator, getAuth as getClientAuth, signInWithCustomToken } from 'firebase/auth';
import {
  connectDatabaseEmulator,
  get,
  getDatabase as getClientDatabase,
  onChildAdded,
  onChildChanged,
  onValue,
  push,
  ref,
  remove,
  serverTimestamp,
  set,
  update,
} from 'firebase/database';
import { assertEmulatorRunning, auth, db as adminDb, PROJECT_ID } from './emulator-admin.mjs';

const TICK_MS = 5000;
const MEASURE_EVERY_MS = 60000;
const DISPENSE_G_PER_S = 25;
const GATE_G_PER_S = 20;
const GATE_MAX_S = 15;
const GATE_MAX_AGE_MS = 10000;

await assertEmulatorRunning();

// --- which feeder ------------------------------------------------------------
let feederId = process.argv[2];
if (!feederId) {
  const owner = await auth.getUserByEmail('owner@agrifeed.test').catch(() => null);
  const index = owner ? (await adminDb.ref(`userFeeders/${owner.uid}`).get()).val() : null;
  feederId = index ? Object.keys(index)[0] : null;
}
if (!feederId) {
  console.error('No feeder found. Run "npm run seed" first, or pass a feeder ID.');
  process.exit(1);
}

// --- device identity (emulator registration step, done by the backend later) --
const regRef = adminDb.ref(`deviceRegistry/${feederId}`);
const reg = (await regRef.get()).val();
if (!reg) {
  console.error(`Feeder ${feederId} has no deviceRegistry entry.`);
  process.exit(1);
}
if (reg.mode !== 'simulated') {
  console.error(`Feeder ${feederId} is a live feeder; the simulator only drives simulated feeders.`);
  process.exit(1);
}
const deviceUid = `sim-${feederId}`;
await regRef.update({ status: 'active', deviceUid });
const token = await auth.createCustomToken(deviceUid, {
  device: true,
  feederId,
  mode: 'simulated',
  credVersion: reg.credentialVersion ?? 1,
});

const DB_URL = `https://${PROJECT_ID}.firebaseio.com`;
const app = initializeApp({ projectId: PROJECT_ID, apiKey: 'fake-api-key', appId: '1:1:web:sim', databaseURL: DB_URL }, 'simulator');
const clientAuth = getClientAuth(app);
connectAuthEmulator(clientAuth, `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, { disableWarnings: true });
await signInWithCustomToken(clientAuth, token);
const db = getClientDatabase(app, DB_URL);
const [dbHost, dbPort] = process.env.FIREBASE_DATABASE_EMULATOR_HOST.split(':');
connectDatabaseEmulator(db, dbHost, Number(dbPort));

const F = (path) => ref(db, `feeders/${feederId}/${path}`);
const SOURCE = 'simulator';
const log = (...a) => console.log(new Date().toLocaleTimeString(), ...a);

// --- state ---------------------------------------------------------------------
let config = (await get(F('config'))).val() ?? {};
let timezone = (await get(F('meta/timezone'))).val() ?? 'UTC';
const controls = (await get(F('simulator/controls'))).val() ?? {};
let hopperG = typeof controls.hopperWeightG === 'number' ? controls.hopperWeightG : Math.round((config.capacityG ?? 2500) * 0.8);
let connected = controls.connected !== false;
let jam = controls.jam === true;
let lastControlsAt = controls.updatedAt ?? 0;
let busy = false; // one dispense at a time
let gate = { position: 'closed', closesAt: null, timer: null };
// Devices may write alerts but not read them; the emulator admin reads the
// previous one so firstAt is kept.
const alertRef = adminDb.ref(`feeders/${feederId}/alerts/low_feed`);
let lowAlert = (await alertRef.get()).val();
const ranToday = new Set(); // `${scheduleId}@${date}`

onValue(F('config'), (s) => (config = s.val() ?? {}));
onValue(F('meta/timezone'), (s) => (timezone = s.val() ?? 'UTC'));
onValue(F('simulator/controls'), (s) => {
  const c = s.val() ?? {};
  connected = c.connected !== false;
  jam = c.jam === true;
  if (typeof c.hopperWeightG === 'number' && (c.updatedAt ?? 0) > lastControlsAt) {
    lastControlsAt = c.updatedAt ?? Date.now();
    hopperG = c.hopperWeightG;
    log(`Hopper set to ${hopperG} g (simulation control)`);
    report();
  }
});

// --- reporting -------------------------------------------------------------------
const lowThreshold = () => config.lowThresholdG ?? 500;

async function report() {
  if (!connected) return;
  hopperG = Math.max(0, Math.round(hopperG));
  const low = hopperG <= lowThreshold();
  await Promise.all([
    set(F('status'), {
      lastSeen: serverTimestamp(),
      condition: jam ? 'jam' : low ? 'low_feed' : 'ok',
      rssi: -55 - Math.round(Math.random() * 10),
      firmware: 'sim-1.0',
      source: SOURCE,
    }),
    set(F('telemetry/current'), { weightG: hopperG, measuredAt: serverTimestamp(), quality: 'ok', source: SOURCE }),
    syncLowAlert(low),
  ]);
}

async function syncLowAlert(low) {
  const active = lowAlert?.state === 'active';
  if (low === active) return;
  const next = {
    type: 'low_feed',
    severity: 'warning',
    state: low ? 'active' : 'resolved',
    firstAt: lowAlert?.firstAt ?? serverTimestamp(),
    lastAt: serverTimestamp(),
    source: SOURCE,
  };
  await set(F('alerts/low_feed'), next);
  lowAlert = (await alertRef.get()).val();
  log(low ? `Low feed alert (${hopperG} g)` : 'Low feed alert resolved');
}

async function measure() {
  if (!connected) return;
  await push(F('measurements'), { weightG: Math.round(hopperG), ts: serverTimestamp(), source: SOURCE });
}

// --- dispensing --------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Runs the auger for [requestedG]; returns { status, actualG, reason }. */
async function dispense(requestedG) {
  if (jam) return { status: 'failed', actualG: 0, reason: 'Auger jammed (simulated)' };
  if (hopperG <= 0) return { status: 'rejected', actualG: 0, reason: 'Hopper is empty' };
  const target = Math.min(requestedG, hopperG);
  let given = 0;
  while (given < target) {
    await sleep(1000);
    const step = Math.min(DISPENSE_G_PER_S, target - given);
    given += step;
    hopperG -= step;
    await report();
  }
  // A real load cell is not exact: +-2 %.
  const actualG = Math.max(0, Math.round(given * (0.98 + Math.random() * 0.04)));
  return { status: given < requestedG ? 'partial' : 'completed', actualG };
}

async function recordHistory(entry) {
  await push(F('history'), { ...entry, ts: serverTimestamp(), source: SOURCE });
}

async function runCommand(cid, cmd) {
  if (busy || !connected || cmd.status !== 'pending') return;
  busy = true;
  const C = F(`commands/${cid}`);
  try {
    if (Date.now() - (cmd.requestedAt ?? 0) > 120000) return; // the app expires it
    log(`Manual feed ${cmd.amountG} g requested`);
    if (hopperG <= 0 || jam) {
      const reason = jam ? 'Auger jammed (simulated)' : 'Hopper is empty';
      await update(C, { status: 'rejected', reason, executedBy: SOURCE, completedAt: serverTimestamp() });
      await recordHistory({ method: 'manual', requestedG: cmd.amountG, actualG: 0, status: 'rejected', commandId: cid });
      log(`  rejected: ${reason}`);
      return;
    }
    await update(C, { status: 'accepted', acceptedAt: serverTimestamp(), executedBy: SOURCE });
    await update(C, { status: 'dispensing' });
    const r = await dispense(cmd.amountG);
    const out = { status: r.status, actualG: r.actualG, completedAt: serverTimestamp() };
    if (r.reason) out.reason = r.reason;
    await update(C, out);
    await recordHistory({ method: 'manual', requestedG: cmd.amountG, actualG: r.actualG, status: r.status, commandId: cid });
    log(`  ${r.status}: ${r.actualG} g`);
  } catch (e) {
    log(`  command ${cid} error: ${e.message}`);
  } finally {
    await remove(F('activeCommand')).catch(() => {});
    busy = false;
  }
}

const onCommand = (s) => runCommand(s.key, s.val() ?? {});
onChildAdded(F('commands'), onCommand);
onChildChanged(F('commands'), onCommand);

// --- schedules -----------------------------------------------------------------------
let schedules = {};
onValue(F('schedules'), (s) => (schedules = s.val() ?? {}));

function feederClock() {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      weekday: 'short',
    })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  );
  const weekday = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(parts.weekday);
  return { date: `${parts.year}-${parts.month}-${parts.day}`, hhmm: `${parts.hour}:${parts.minute}`, weekday };
}

async function checkSchedules() {
  if (!connected || busy || config.schedulesPaused) return;
  const now = feederClock();
  for (const [sid, s] of Object.entries(schedules)) {
    if (!s?.enabled || s.time !== now.hhmm) continue;
    if (s.weekdays && s.weekdays[now.weekday] !== true) continue;
    const key = `${sid}@${now.date}`;
    if (ranToday.has(key)) continue;
    ranToday.add(key);
    busy = true;
    try {
      log(`Scheduled feed ${s.time}: ${s.amountG} g`);
      const r = await dispense(s.amountG);
      await recordHistory({ method: 'scheduled', requestedG: s.amountG, actualG: r.actualG, status: r.status, scheduleId: sid });
      log(`  ${r.status}: ${r.actualG} g`);
    } finally {
      busy = false;
    }
    return;
  }
}

// --- gate ----------------------------------------------------------------------------
let lastGateRequest = (await get(F('gate/state/lastRequestId'))).val();
let gateFlow = null;

async function writeGate(extra = {}) {
  const state = { position: gate.position, reportedAt: serverTimestamp(), source: SOURCE, ...extra };
  if (lastGateRequest && !state.lastRequestId) state.lastRequestId = lastGateRequest;
  if (gate.position === 'open' && gate.closesAt) state.closesAt = gate.closesAt;
  await set(F('gate/state'), state);
}

async function closeGate(extra = {}) {
  clearTimeout(gate.timer);
  clearInterval(gateFlow);
  gate = { position: 'closed', closesAt: null, timer: null };
  await writeGate(extra);
  log('Gate closed');
}

onValue(F('gate/request'), async (s) => {
  const r = s.val();
  if (!r || r.id === lastGateRequest || !connected) return;
  lastGateRequest = r.id;
  if (Date.now() - r.requestedAt > GATE_MAX_AGE_MS) {
    await writeGate({ lastRequestId: r.id, lastResult: 'rejected', reason: 'Request older than 10 s' });
    log('Gate request rejected (too old)');
    return;
  }
  if (r.action === 'close') {
    await closeGate({ lastRequestId: r.id, lastResult: 'done' });
    return;
  }
  const secs = Math.min(Math.max(1, r.durationS ?? 5), GATE_MAX_S);
  clearTimeout(gate.timer);
  clearInterval(gateFlow);
  gate = { position: 'open', closesAt: Date.now() + secs * 1000, timer: null };
  gate.timer = setTimeout(() => closeGate(), secs * 1000);
  gateFlow = setInterval(() => {
    hopperG = Math.max(0, hopperG - GATE_G_PER_S);
    report();
  }, 1000);
  await writeGate({ lastRequestId: r.id, lastResult: 'done' });
  log(`Gate open for ${secs} s`);
});

// --- main loop -------------------------------------------------------------------------
await closeGate();
await report();
await measure();
setInterval(() => report().catch((e) => log('report failed:', e.message)), TICK_MS);
setInterval(() => measure().catch((e) => log('measure failed:', e.message)), MEASURE_EVERY_MS);
setInterval(() => checkSchedules().catch((e) => log('schedule failed:', e.message)), TICK_MS);
// A request that arrived while the auger was busy is picked up here.
setInterval(async () => {
  if (busy || !connected) return;
  const lock = (await get(F('activeCommand'))).val();
  if (!lock?.commandId) return;
  const cmd = (await get(F(`commands/${lock.commandId}`))).val();
  if (cmd) await runCommand(lock.commandId, cmd);
}, TICK_MS);

log(`Simulator running for feeder ${feederId} (${timezone}). Hopper ${hopperG} g. Ctrl+C to stop.`);
