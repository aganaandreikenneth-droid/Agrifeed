// Admin SDK connection that can ONLY reach the local Firebase Emulator Suite.
//
// Phase 1 scripts must never touch production, so this refuses to run when
// the project is not a "demo-" project or when the emulator hosts point
// anywhere other than this machine.
import { getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase, ServerValue } from 'firebase-admin/database';

export const PROJECT_ID = 'demo-agrifeed';

const LOCAL = /^(127\.0\.0\.1|localhost|0\.0\.0\.0):\d+$/;

process.env.FIREBASE_AUTH_EMULATOR_HOST ||= '127.0.0.1:9099';
process.env.FIREBASE_DATABASE_EMULATOR_HOST ||= '127.0.0.1:9000';
for (const key of ['FIREBASE_AUTH_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST']) {
  if (!LOCAL.test(process.env[key])) {
    console.error(`Refusing to run: ${key}=${process.env[key]} is not a local emulator.`);
    process.exit(1);
  }
}
if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error('Refusing to run: GOOGLE_APPLICATION_CREDENTIALS is set. Emulator scripts never use real credentials.');
  process.exit(1);
}

const app = getApps()[0] ?? initializeApp({
  projectId: PROJECT_ID,
  databaseURL: `https://${PROJECT_ID}.firebaseio.com`, // emulator default namespace
});
if (!app.options.projectId.startsWith('demo-')) {
  console.error('Refusing to run against a non-demo project.');
  process.exit(1);
}

export const auth = getAuth(app);
export const db = getDatabase(app);
export { ServerValue };

/** Fails with a clear message when the emulator is not running. */
export async function assertEmulatorRunning() {
  const host = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  try {
    await fetch(`http://${host}/`);
  } catch {
    console.error(`Auth emulator not reachable at ${host}. Start it with: npm run emulators`);
    process.exit(1);
  }
}

/** Same steps as setAdminRole, used for bootstrapping and seeding. */
export async function makeAdmin(uid, actorUid) {
  await db.ref(`platformAdmins/${uid}`).set(true);
  const user = await auth.getUser(uid);
  await auth.setCustomUserClaims(uid, { ...(user.customClaims ?? {}), admin: true });
  await db.ref(`accountStatus/${uid}/claimsUpdatedAt`).set(ServerValue.TIMESTAMP);
  await db.ref('platformAudit').push({
    action: 'admin_bootstrap',
    actorUid,
    targetUid: uid,
    ts: ServerValue.TIMESTAMP,
  });
}
