// Shared plumbing for the Cloud Functions integration tests (emulators only).
import { randomBytes } from 'node:crypto';
import { deleteApp, initializeApp as initClient } from 'firebase/app';
import { connectAuthEmulator, getAuth as getClientAuth, signInWithEmailAndPassword } from 'firebase/auth';
import { connectDatabaseEmulator, getDatabase as getClientDatabase } from 'firebase/database';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { afterEach, beforeEach } from 'vitest';

export const PROJECT = 'demo-agrifeed';
const DB_URL = `https://${PROJECT}.firebaseio.com`;
const PASSWORD = randomBytes(12).toString('base64url'); // per run, never stored

const adminApp = getApps()[0] ?? initializeApp({ projectId: PROJECT, databaseURL: DB_URL });
export const auth = getAuth(adminApp);
export const db = getDatabase(adminApp);

const clientApps = [];

export function useCleanEmulators() {
  beforeEach(async () => {
    await fetch(`http://127.0.0.1:9099/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
    await db.ref().set(null);
  });
  afterEach(async () => {
    await Promise.all(clientApps.splice(0).map((a) => deleteApp(a)));
  });
}

export async function createUser(key, { verified = true, admin = false, name } = {}) {
  const u = await auth.createUser({ uid: key, email: `${key}@agrifeed.test`, password: PASSWORD, emailVerified: verified });
  if (name) await db.ref(`users/${key}`).set({ displayName: name, createdAt: Date.now() });
  if (admin) {
    await db.ref(`platformAdmins/${u.uid}`).set(true);
    await auth.setCustomUserClaims(u.uid, { admin: true });
  }
  return u.uid;
}

function clientApp() {
  const app = initClient({ projectId: PROJECT, apiKey: 'fake-api-key', appId: '1:1:web:1', databaseURL: DB_URL }, `c${clientApps.length}`);
  clientApps.push(app);
  const fns = getFunctions(app, 'us-central1');
  connectFunctionsEmulator(fns, '127.0.0.1', 5001);
  return { app, call: (name, data) => httpsCallable(fns, name)(data).then((r) => r.data) };
}

/**
 * Signs in as the user. `call` invokes a callable function; `db` is a client
 * database handle that goes through the Security Rules like the app does.
 */
export async function signIn(key) {
  const { app, call } = clientApp();
  const a = getClientAuth(app);
  connectAuthEmulator(a, 'http://127.0.0.1:9099', { disableWarnings: true });
  await signInWithEmailAndPassword(a, `${key}@agrifeed.test`, PASSWORD);
  const cdb = getClientDatabase(app, DB_URL);
  connectDatabaseEmulator(cdb, '127.0.0.1', 9000);
  return { call, db: cdb };
}

export const anonymousCaller = () => clientApp().call;

/** Resolves to 'ok' or the error code (e.g. 'functions/permission-denied'). */
export const codeOf = (p) => p.then(() => 'ok', (e) => e.code);

export const val = async (path) => (await db.ref(path).get()).val();

let seq = 0;
export const requestId = () => `req-${Date.now()}-${++seq}`;

// --- Phase 2 feeder fixtures ---------------------------------------------

export const TZ = 'Asia/Manila';
export const ALL_PERMS = ['viewDashboard', 'viewHistory', 'viewAnalytics', 'manualFeed', 'manageSchedules', 'downloadReports', 'receiveAlerts'];
export const rulesCode = (p) => p.then(() => 'ok', (e) => (/permission/i.test(e.message) ? 'denied' : e.message));

/** owner1 signed in, with one virtual feeder. */
export async function ownerWithFeeder(name = 'Coop A') {
  await createUser('owner1', { name: 'Owner One' });
  const owner = await signIn('owner1');
  const { feederId } = await owner.call('createVirtualFeeder', { name, timezone: TZ, requestId: requestId() });
  return { owner, feederId };
}

/** Adds `key` as a member of the feeder through a real invitation. */
export async function join(owner, feederId, key) {
  await createUser(key, { name: key });
  const user = await signIn(key);
  const { code } = await owner.call('createInvite', { feederId });
  await user.call('acceptInvite', { code, requestId: requestId() });
  return user;
}
