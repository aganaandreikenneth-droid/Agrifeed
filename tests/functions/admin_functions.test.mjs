// Integration tests for the Phase 1 Cloud Functions, run against the Auth,
// Database and Functions emulators (demo project, no real Firebase access).
import { randomBytes } from 'node:crypto';
import { deleteApp, initializeApp as initClient } from 'firebase/app';
import { connectAuthEmulator, getAuth as getClientAuth, signInWithEmailAndPassword } from 'firebase/auth';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { afterEach, beforeEach, describe, expect, test } from 'vitest';

const PROJECT = 'demo-agrifeed';
const PASSWORD = randomBytes(12).toString('base64url'); // per run, never stored

const adminApp = getApps()[0] ?? initializeApp({ projectId: PROJECT, databaseURL: `https://${PROJECT}.firebaseio.com` });
const auth = getAuth(adminApp);
const db = getDatabase(adminApp);

const clientApps = [];

async function createUser(key, { verified = true, admin = false } = {}) {
  const u = await auth.createUser({ uid: key, email: `${key}@agrifeed.test`, password: PASSWORD, emailVerified: verified });
  if (admin) {
    await db.ref(`platformAdmins/${u.uid}`).set(true);
    await auth.setCustomUserClaims(u.uid, { admin: true });
  }
  return u.uid;
}

/** Signs in as the user and returns a caller for the callable functions. */
async function signIn(key) {
  const app = initClient({ projectId: PROJECT, apiKey: 'fake-api-key', appId: '1:1:web:1' }, `c${clientApps.length}`);
  clientApps.push(app);
  const a = getClientAuth(app);
  connectAuthEmulator(a, 'http://127.0.0.1:9099', { disableWarnings: true });
  await signInWithEmailAndPassword(a, `${key}@agrifeed.test`, PASSWORD);
  const fns = getFunctions(app, 'us-central1');
  connectFunctionsEmulator(fns, '127.0.0.1', 5001);
  return (name, data) => httpsCallable(fns, name)(data);
}

async function anonymousCaller() {
  const app = initClient({ projectId: PROJECT, apiKey: 'fake-api-key', appId: '1:1:web:1' }, `c${clientApps.length}`);
  clientApps.push(app);
  const fns = getFunctions(app, 'us-central1');
  connectFunctionsEmulator(fns, '127.0.0.1', 5001);
  return (name, data) => httpsCallable(fns, name)(data);
}

const codeOf = (p) => p.then(() => 'ok', (e) => e.code);
const audit = async () => Object.values((await db.ref('platformAudit').get()).val() ?? {});

beforeEach(async () => {
  await fetch(`http://127.0.0.1:9099/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
  await db.ref().set(null);
});

afterEach(async () => {
  await Promise.all(clientApps.splice(0).map((a) => deleteApp(a)));
});

describe('emulator wiring', () => {
  test('firebase.json rules are enforced on the namespace the app and functions use', async () => {
    await db.ref('feeders/fd_x/meta/name').set('secret');
    for (const ns of [PROJECT, `${PROJECT}-default-rtdb`]) {
      const read = await fetch(`http://127.0.0.1:9000/feeders.json?ns=${ns}`);
      expect(read.status).toBe(401);
      const write = await fetch(`http://127.0.0.1:9000/users/evil.json?ns=${ns}`, { method: 'PUT', body: '{"x":1}' });
      expect(write.status).toBe(401);
    }
  });
});

describe('caller checks (all functions)', () => {
  test('signed-out callers are rejected', async () => {
    await createUser('target');
    const call = await anonymousCaller();
    expect(await codeOf(call('setAdminRole', { uid: 'target', admin: true }))).toBe('functions/unauthenticated');
    expect(await codeOf(call('suspendUser', { uid: 'target', reason: 'x' }))).toBe('functions/unauthenticated');
  });

  test('ordinary users cannot use admin functions', async () => {
    await createUser('user1');
    await createUser('target');
    const call = await signIn('user1');
    expect(await codeOf(call('setAdminRole', { uid: 'user1', admin: true }))).toBe('functions/permission-denied');
    expect(await codeOf(call('suspendUser', { uid: 'target', reason: 'x' }))).toBe('functions/permission-denied');
    expect(await codeOf(call('reactivateUser', { uid: 'target' }))).toBe('functions/permission-denied');
    expect((await auth.getUser('user1')).customClaims?.admin).toBeUndefined();
    expect(await audit()).toHaveLength(0);
  });

  test('an admin claim without the registry entry is rejected', async () => {
    await createUser('stale');
    await auth.setCustomUserClaims('stale', { admin: true });
    await createUser('target');
    const call = await signIn('stale');
    expect(await codeOf(call('suspendUser', { uid: 'target', reason: 'x' }))).toBe('functions/permission-denied');
  });

  test('a suspended administrator is rejected', async () => {
    await createUser('admin1', { admin: true });
    await createUser('target');
    const call = await signIn('admin1');
    await db.ref('accountStatus/admin1/suspended').set(true);
    expect(await codeOf(call('setAdminRole', { uid: 'target', admin: true }))).toBe('functions/permission-denied');
  });

  test('unverified administrators are rejected', async () => {
    await createUser('admin1', { admin: true, verified: false });
    await createUser('target');
    const call = await signIn('admin1');
    expect(await codeOf(call('suspendUser', { uid: 'target', reason: 'x' }))).toBe('functions/permission-denied');
  });

  test('input is validated', async () => {
    await createUser('admin1', { admin: true });
    const call = await signIn('admin1');
    expect(await codeOf(call('setAdminRole', { uid: '../bad', admin: true }))).toBe('functions/invalid-argument');
    expect(await codeOf(call('setAdminRole', { uid: 'admin1', admin: 'yes' }))).toBe('functions/invalid-argument');
    expect(await codeOf(call('setAdminRole', { uid: 'nobody', admin: true }))).toBe('functions/not-found');
    expect(await codeOf(call('suspendUser', { uid: 'admin1' }))).toBe('functions/invalid-argument');
    expect(await codeOf(call('suspendUser', { uid: 'x', reason: 'r'.repeat(201) }))).toBe('functions/invalid-argument');
  });
});

describe('setAdminRole', () => {
  test('grants the role: registry, claim, refresh signal and audit', async () => {
    await createUser('admin1', { admin: true });
    await createUser('user1');
    const call = await signIn('admin1');
    expect(await codeOf(call('setAdminRole', { uid: 'user1', admin: true }))).toBe('ok');
    expect((await auth.getUser('user1')).customClaims?.admin).toBe(true);
    expect((await db.ref('platformAdmins/user1').get()).val()).toBe(true);
    expect(typeof (await db.ref('accountStatus/user1/claimsUpdatedAt').get()).val()).toBe('number');
    const entries = await audit();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({ action: 'admin_role_granted', actorUid: 'admin1', targetUid: 'user1' });
    expect(typeof entries[0].ts).toBe('number');
  });

  test('refuses unverified or suspended targets', async () => {
    await createUser('admin1', { admin: true });
    await createUser('unv', { verified: false });
    await createUser('susp');
    await db.ref('accountStatus/susp/suspended').set(true);
    const call = await signIn('admin1');
    expect(await codeOf(call('setAdminRole', { uid: 'unv', admin: true }))).toBe('functions/failed-precondition');
    expect(await codeOf(call('setAdminRole', { uid: 'susp', admin: true }))).toBe('functions/failed-precondition');
  });

  test('revokes the role from another admin', async () => {
    await createUser('admin1', { admin: true });
    await createUser('admin2', { admin: true });
    const call = await signIn('admin1');
    expect(await codeOf(call('setAdminRole', { uid: 'admin2', admin: false }))).toBe('ok');
    expect((await auth.getUser('admin2')).customClaims?.admin).toBeUndefined();
    expect((await db.ref('platformAdmins/admin2').get()).exists()).toBe(false);
    expect((await audit())[0]).toMatchObject({ action: 'admin_role_revoked', targetUid: 'admin2' });
  });

  test('the last administrator cannot be removed', async () => {
    await createUser('admin1', { admin: true });
    const call = await signIn('admin1');
    expect(await codeOf(call('setAdminRole', { uid: 'admin1', admin: false }))).toBe('functions/failed-precondition');
    expect((await db.ref('platformAdmins/admin1').get()).val()).toBe(true);
    expect((await auth.getUser('admin1')).customClaims?.admin).toBe(true);
  });

  test('two admins revoking each other at the same time leaves one admin', async () => {
    await createUser('admin1', { admin: true });
    await createUser('admin2', { admin: true });
    const [c1, c2] = await Promise.all([signIn('admin1'), signIn('admin2')]);
    const results = await Promise.all([
      codeOf(c1('setAdminRole', { uid: 'admin2', admin: false })),
      codeOf(c2('setAdminRole', { uid: 'admin1', admin: false })),
    ]);
    const admins = Object.keys((await db.ref('platformAdmins').get()).val() ?? {});
    expect(admins).toHaveLength(1);
    expect(results.filter((r) => r === 'ok')).toHaveLength(1);
  });
});

describe('suspendUser / reactivateUser', () => {
  test('suspension blocks the account at every layer and is audited', async () => {
    await createUser('admin1', { admin: true });
    await createUser('user1');
    await signIn('user1'); // the user has a live session
    const call = await signIn('admin1');
    expect(await codeOf(call('suspendUser', { uid: 'user1', reason: '  Policy violation  ' }))).toBe('ok');

    const status = (await db.ref('accountStatus/user1').get()).val();
    expect(status).toMatchObject({ suspended: true, reason: 'Policy violation', updatedBy: 'admin1' });
    const record = await auth.getUser('user1');
    expect(record.disabled).toBe(true);
    expect(record.tokensValidAfterTime).toBeTruthy();
    expect((await audit())[0]).toMatchObject({ action: 'account_suspended', targetUid: 'user1', reason: 'Policy violation' });

    const signInAgain = await codeOf(signIn('user1'));
    expect(signInAgain).toBe('auth/user-disabled');
  });

  test('admins cannot suspend themselves or another admin', async () => {
    await createUser('admin1', { admin: true });
    await createUser('admin2', { admin: true });
    const call = await signIn('admin1');
    expect(await codeOf(call('suspendUser', { uid: 'admin1', reason: 'x' }))).toBe('functions/failed-precondition');
    expect(await codeOf(call('suspendUser', { uid: 'admin2', reason: 'x' }))).toBe('functions/failed-precondition');
    expect((await auth.getUser('admin2')).disabled).toBe(false);
  });

  test('reactivation restores access and is audited', async () => {
    await createUser('admin1', { admin: true });
    await createUser('user1');
    const call = await signIn('admin1');
    await call('suspendUser', { uid: 'user1', reason: 'temporary' });
    expect(await codeOf(call('reactivateUser', { uid: 'user1' }))).toBe('ok');
    const status = (await db.ref('accountStatus/user1').get()).val();
    expect(status.suspended).toBe(false);
    expect(status.reason).toBeUndefined();
    expect((await auth.getUser('user1')).disabled).toBe(false);
    expect(await codeOf(signIn('user1'))).toBe('ok');
    expect((await audit()).map((e) => e.action).sort()).toEqual(['account_reactivated', 'account_suspended']);
  });
});
