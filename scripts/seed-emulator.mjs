// Creates repeatable test accounts and feeders in the LOCAL emulator.
//
//   npm run seed
//
// Emulator only (see emulator-admin.mjs). A fresh random password is
// generated on every run and printed once; nothing secret is stored in
// source. Re-running resets the seeded accounts and data.
import { randomBytes } from 'node:crypto';
import { assertEmulatorRunning, auth, db, makeAdmin } from './emulator-admin.mjs';

const PASSWORD = process.env.SEED_PASSWORD || randomBytes(9).toString('base64url');
const ACCOUNTS = [
  { key: 'admin', email: 'admin@agrifeed.test', name: 'Platform Admin', verified: true },
  { key: 'owner', email: 'owner@agrifeed.test', name: 'Farm Owner', verified: true },
  { key: 'member', email: 'member@agrifeed.test', name: 'Farm Helper', verified: true },
  { key: 'outsider', email: 'outsider@agrifeed.test', name: 'Unrelated User', verified: true },
  { key: 'suspended', email: 'suspended@agrifeed.test', name: 'Suspended User', verified: true },
  { key: 'unverified', email: 'unverified@agrifeed.test', name: 'Unverified User', verified: false },
];

const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const feederId = () => 'fd_' + [...randomBytes(20)].map((b) => BASE62[b % 62]).join('');

await assertEmulatorRunning();

const uids = {};
for (const a of ACCOUNTS) {
  try {
    await auth.deleteUser((await auth.getUserByEmail(a.email)).uid);
  } catch {}
  const u = await auth.createUser({
    email: a.email,
    password: PASSWORD,
    displayName: a.name,
    emailVerified: a.verified,
  });
  uids[a.key] = u.uid;
}

await db.ref().set(null);
const now = Date.now();
const live = feederId();
const sim = feederId();

const profiles = {};
for (const a of ACCOUNTS.filter((x) => x.verified)) {
  profiles[uids[a.key]] = { displayName: a.name, createdAt: now };
}

await db.ref().update({
  users: profiles,
  accountStatus: { [uids.suspended]: { suspended: true, reason: 'Seeded test suspension', updatedAt: now, updatedBy: 'seed' } },
  userFeeders: {
    [uids.owner]: { [live]: { role: 'owner', addedAt: now }, [sim]: { role: 'owner', addedAt: now } },
    [uids.member]: { [live]: { role: 'member', addedAt: now } },
  },
  deviceRegistry: {
    [live]: { status: 'provisioned', mode: 'live', ownerUid: uids.owner, credentialVersion: 1, provisionedAt: now },
    [sim]: { status: 'provisioned', mode: 'simulated', ownerUid: uids.owner, credentialVersion: 1, provisionedAt: now },
  },
  feeders: {
    [live]: {
      meta: { name: 'Seeded coop (live)', ownerUid: uids.owner, mode: 'live', timezone: 'Asia/Manila', createdAt: now },
      config: { capacityG: 3000, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200, calibrationStatus: 'uncalibrated' },
      members: {
        [uids.owner]: { role: 'owner', status: 'active', addedAt: now },
        [uids.member]: { role: 'member', status: 'active', addedAt: now, addedBy: uids.owner, permissions: { viewDashboard: true, viewHistory: true } },
      },
    },
    [sim]: {
      meta: { name: 'Seeded virtual feeder', ownerUid: uids.owner, mode: 'simulated', timezone: 'Asia/Manila', createdAt: now },
      config: { capacityG: 3000, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200, calibrationStatus: 'uncalibrated' },
      members: { [uids.owner]: { role: 'owner', status: 'active', addedAt: now } },
    },
  },
});

await makeAdmin(uids.admin, 'seed-script');

console.log('Seeded the emulator. Password for every account (this run only):', PASSWORD);
for (const a of ACCOUNTS) console.log(`  ${a.key.padEnd(10)} ${a.email.padEnd(26)} uid=${uids[a.key]}`);
console.log(`  live feeder      ${live}`);
console.log(`  virtual feeder   ${sim}`);
process.exit(0);
