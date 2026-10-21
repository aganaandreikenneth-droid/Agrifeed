// Shared fixture for the Realtime Database rules tests.
import { createRequire } from 'node:module';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { afterAll, beforeAll, beforeEach } from 'vitest';

export { assertFails, assertSucceeds };

// rules-unit-testing is loaded as CommonJS; register the compat database
// module on that same instance so ctx.database() exists.
createRequire(import.meta.url)('firebase/compat/database');

export const NOW = { '.sv': 'timestamp' }; // server timestamp
export const F = 'fd_liveFeederAAAAAAAAAAAA'; // live feeder, owner1
export const S = 'fd_simFeederBBBBBBBBBBBBB'; // simulated feeder, owner1
export const G = 'fd_otherFeederCCCCCCCCCCC'; // someone else's feeder (revoked device)

const OLD = 1000; // a timestamp far in the past

export const seed = () => ({
  accountStatus: { suspended1: { suspended: true, reason: 'test' } },
  platformAdmins: { admin1: true },
  platformAudit: { pa1: { action: 'account_suspended', actorUid: 'admin1', targetUid: 'suspended1', ts: OLD } },
  users: {
    owner1: { displayName: 'Owner', createdAt: OLD },
    viewer1: { displayName: 'Viewer', createdAt: OLD },
  },
  userFeeders: {
    owner1: { [F]: { role: 'owner' }, [S]: { role: 'owner' } },
    viewer1: { [F]: { role: 'member' } },
    owner2: { [G]: { role: 'owner' } },
  },
  deviceRegistry: {
    [F]: { status: 'active', mode: 'live', deviceUid: 'dev_F', credentialVersion: 2, ownerUid: 'owner1' },
    [S]: { status: 'active', mode: 'simulated', deviceUid: 'dev_S', credentialVersion: 1, ownerUid: 'owner1' },
    [G]: { status: 'revoked', mode: 'live', deviceUid: 'dev_G', credentialVersion: 1, ownerUid: 'owner2' },
  },
  deviceClaims: { [F]: { state: 'finalized', codeHash: 'x' } },
  invitations: { inv1: { feederId: F, codeHash: 'y' } },
  notifications: { viewer1: { n1: { type: 'low_feed', title: 'Low feed', ts: OLD } } },
  feeders: {
    [F]: {
      meta: { name: 'Coop A', ownerUid: 'owner1', mode: 'live', timezone: 'Asia/Manila', createdAt: OLD },
      config: { capacityG: 3000, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200 },
      members: {
        owner1: { role: 'owner', status: 'active' },
        viewer1: { role: 'member', status: 'active', permissions: { viewDashboard: true, viewHistory: true } },
        feeder2: { role: 'member', status: 'active', permissions: { viewDashboard: true, manualFeed: true, manageSchedules: true } },
        expired1: {
          role: 'member', status: 'active', expiresAt: OLD,
          permissions: { viewDashboard: true, viewHistory: true, manualFeed: true, manageSchedules: true },
        },
        invited1: { role: 'member', status: 'invited', permissions: { viewDashboard: true } },
        suspended1: { role: 'member', status: 'active', permissions: { viewDashboard: true } },
        fakeowner1: { role: 'owner', status: 'active' }, // owner record without meta.ownerUid
      },
      status: { lastSeen: OLD, condition: 'ok', source: 'device' },
      telemetry: { current: { weightG: 1200, measuredAt: OLD, quality: 'ok', source: 'device' } },
      measurements: { m1: { weightG: 1200, ts: OLD, source: 'device' } },
      history: { h1: { method: 'manual', requestedG: 50, actualG: 48, status: 'completed', ts: OLD, source: 'device' } },
      alerts: { a1: { type: 'low_feed', severity: 'warning', state: 'active', firstAt: OLD, lastAt: OLD, source: 'device' } },
      audit: { au1: { action: 'schedule_added', actorUid: 'owner1', ts: OLD } },
      schedules: {
        s1: { time: '07:00', weekdays: { 0: true, 1: true }, amountG: 50, enabled: true, createdAt: OLD, updatedAt: OLD, updatedBy: 'owner1' },
      },
      commands: {
        cDone: { amountG: 50, requestedBy: 'feeder2', requestedAt: OLD, status: 'completed', source: 'app', actualG: 49, executedBy: 'device' },
        cOld: { amountG: 50, requestedBy: 'feeder2', requestedAt: OLD, status: 'pending', source: 'app' },
        cAcc: { amountG: 50, requestedBy: 'feeder2', requestedAt: OLD, status: 'accepted', source: 'app' },
        cDisp: { amountG: 50, requestedBy: 'feeder2', requestedAt: OLD, status: 'dispensing', source: 'app' },
      },
    },
    [S]: {
      meta: { name: 'Virtual', ownerUid: 'owner1', mode: 'simulated', timezone: 'UTC', createdAt: OLD },
      config: { capacityG: 3000, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200 },
      members: { owner1: { role: 'owner', status: 'active' } },
      commands: {
        sDisp: { amountG: 30, requestedBy: 'owner1', requestedAt: OLD, status: 'dispensing', source: 'app' },
      },
      simulator: { controls: { hopperWeightG: 2000, connected: true, jam: false } },
    },
    [G]: {
      meta: { name: 'Other farm', ownerUid: 'owner2', mode: 'live', timezone: 'UTC', createdAt: OLD },
      members: { owner2: { role: 'owner', status: 'active' } },
      status: { lastSeen: OLD, condition: 'ok', source: 'device' },
    },
  },
});

// Same project and database URL as the Flutter app (lib/core/env.dart and
// lib/core/backend.dart). The rules are NOT loaded by the tests: the emulator
// loads them from firebase.json, exactly as when the app runs, so these tests
// exercise the real configuration. rules_config.test.mjs checks that the
// loaded rules match database.rules.json.
export const PROJECT_ID = 'demo-agrifeed';
export const DB_URL = `https://${PROJECT_ID}.firebaseio.com`;

let env;

export function useRulesEnv() {
  beforeAll(async () => {
    const [host, port] = (process.env.FIREBASE_DATABASE_EMULATOR_HOST ?? '127.0.0.1:9000').split(':');
    env = await initializeTestEnvironment({ projectId: PROJECT_ID, database: { host, port: Number(port) } });
  });
  beforeEach(async () => {
    // Replacing the root also clears anything left by a previous test.
    await env.withSecurityRulesDisabled((ctx) => ctx.database(DB_URL).ref().set(seed()));
  });
  afterAll(async () => env?.cleanup());
}

/** Applies extra state with rules disabled (for setting up a scenario). */
export const arrange = (fn) => env.withSecurityRulesDisabled((ctx) => fn(ctx.database(DB_URL)));

const human = (uid, claims = {}) =>
  env.authenticatedContext(uid, { email_verified: true, ...claims }).database(DB_URL);

export const as = {
  anon: () => env.unauthenticatedContext().database(DB_URL),
  user: (uid) => human(uid),
  unverified: (uid) => human(uid, { email_verified: false }),
  admin: () => human('admin1', { admin: true }),
  staleAdmin: () => human('exadmin', { admin: true }), // claim but no registry entry
  device: (uid, feederId, mode, credVersion) =>
    env.authenticatedContext(uid, { device: true, feederId, mode, credVersion }).database(DB_URL),
};

export const devF = () => as.device('dev_F', F, 'live', 2);
export const devS = () => as.device('dev_S', S, 'simulated', 1);

export const schedule = (uid, extra = {}) => ({
  time: '18:30', weekdays: { 1: true, 3: true, 5: true }, amountG: 60, enabled: true,
  createdAt: NOW, updatedAt: NOW, updatedBy: uid, ...extra,
});

/** Multi-path update that creates a command together with the lock. */
export const createCommand = (db, feederId, cid, uid, extra = {}) =>
  db.ref(`feeders/${feederId}`).update({
    [`commands/${cid}`]: { amountG: 40, requestedBy: uid, requestedAt: NOW, status: 'pending', source: 'app', ...extra },
    activeCommand: { commandId: cid, requestedAt: NOW },
  });
