// Creates repeatable test accounts and the one AgriFeed machine (assigned
// to owner@agrifeed.test) in the LOCAL emulator.
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
// One machine, driven by the simulator during development (mode
// 'simulated', so its data must say source 'simulator'). Capacity is
// provisional: 2,500 g usable on a 3 kg load cell, not yet calibrated.
const feeder = feederId();

const profiles = {};
for (const a of ACCOUNTS.filter((x) => x.verified)) {
  profiles[uids[a.key]] = { displayName: a.name, createdAt: now };
}

await db.ref().update({
  users: profiles,
  accountStatus: { [uids.suspended]: { suspended: true, reason: 'Seeded test suspension', updatedAt: now, updatedBy: 'seed' } },
  userFeeders: {
    [uids.owner]: { [feeder]: { role: 'owner', addedAt: now } },
  },
  deviceRegistry: {
    [feeder]: { status: 'provisioned', mode: 'simulated', ownerUid: uids.owner, credentialVersion: 1, provisionedAt: now },
  },
  feeders: {
    [feeder]: {
      meta: { name: 'AgriFeed', ownerUid: uids.owner, mode: 'simulated', timezone: 'Asia/Manila', createdAt: now },
      config: { capacityG: 2500, lowThresholdG: 500, loadCellMaxG: 3000, maxDispenseG: 200, calibrationStatus: 'uncalibrated', schedulesPaused: false },
      members: { [uids.owner]: { role: 'owner', status: 'active', addedAt: now } },
    },
  },
});

await makeAdmin(uids.admin, 'seed-script');

console.log('Seeded the emulator. Password for every account (this run only):', PASSWORD);
for (const a of ACCOUNTS) console.log(`  ${a.key.padEnd(10)} ${a.email.padEnd(26)} uid=${uids[a.key]}`);
console.log(`  feeder           ${feeder}  (owner's machine, simulated)`);
process.exit(0);
