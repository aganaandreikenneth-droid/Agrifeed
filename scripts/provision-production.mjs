// Registers the ONE real AgriFeed machine in the production project
// (agrifeed-dda82) and binds the ESP32's own sign-in account to it.
// The backend's registration step, done by hand with your Firebase CLI login
// (no service-account key is created or stored anywhere).
//
//   npm run production:provision -- --owner-uid <UID> --device-uid <UID> --confirm
//     [--name "AgriFeed"] [--timezone Asia/Manila] [--feeder-id fd_...]
//
//   --owner-uid   the owner's Firebase Auth UID (Console > Authentication >
//                 Users; sign in to the app once in production first)
//   --device-uid  UID of the ESP32's email/password account, created in the
//                 Console (Authentication > Users > Add user)
//   --feeder-id   re-bind an existing feeder (e.g. a new device account)
//
// It writes only backend-owned paths: deviceRegistry/{id}, deviceAccounts/{uid},
// feeders/{id}/meta|config|members/{owner}, userFeeders/{owner}/{id}. The
// app and the ESP32 fill in everything else through the Security Rules.
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const PROJECT = 'agrifeed-dda82';
const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};
const ownerUid = opt('owner-uid');
const deviceUid = opt('device-uid');
const UID = /^[A-Za-z0-9]{20,128}$/;
if (!UID.test(ownerUid ?? '') || !UID.test(deviceUid ?? '') || ownerUid === deviceUid) {
  console.error('Usage: npm run production:provision -- --owner-uid <UID> --device-uid <UID> --confirm');
  process.exit(2);
}

function firebase(...cmd) {
  const r = spawnSync('firebase', [...cmd, '--project', PROJECT], { shell: true, encoding: 'utf8' });
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout);
    process.exit(1);
  }
  return r.stdout.trim();
}
const get = (path) => JSON.parse(firebase('database:get', path) || 'null');

const owned = get(`/userFeeders/${ownerUid}`) ?? {};
let feederId = opt('feeder-id') ?? Object.keys(owned)[0];
const isNew = !feederId;
if (isNew) {
  const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  feederId = 'fd_' + [...randomBytes(20)].map((b) => BASE62[b % 62]).join('');
}
if (!/^fd_[A-Za-z0-9]{20}$/.test(feederId)) {
  console.error(`Not a feeder ID: ${feederId}`);
  process.exit(2);
}

const reg = get(`/deviceRegistry/${feederId}`);
if (!isNew && reg && reg.ownerUid !== ownerUid) {
  console.error(`Feeder ${feederId} belongs to another owner.`);
  process.exit(1);
}

const now = Date.now();
const updates = {
  [`deviceRegistry/${feederId}`]: {
    status: 'active',
    mode: 'live',
    ownerUid,
    deviceUid,
    authMethod: 'password',
    credentialVersion: (reg?.credentialVersion ?? 0) + 1,
    provisionedAt: reg?.provisionedAt ?? now,
  },
  [`deviceAccounts/${deviceUid}`]: { feederId, addedAt: now },
};
if (reg?.deviceUid && reg.deviceUid !== deviceUid) updates[`deviceAccounts/${reg.deviceUid}`] = null;
if (isNew) {
  Object.assign(updates, {
    [`feeders/${feederId}/meta`]: {
      name: opt('name') ?? 'AgriFeed',
      ownerUid,
      mode: 'live',
      timezone: opt('timezone') ?? 'Asia/Manila',
      createdAt: now,
    },
    // Capacity is provisional (3 kg load cell); editable in Settings.
    [`feeders/${feederId}/config`]: {
      capacityG: 2500,
      lowThresholdG: 500,
      loadCellMaxG: 3000,
      maxDispenseG: 200,
      calibrationStatus: 'uncalibrated',
      schedulesPaused: false,
    },
    [`feeders/${feederId}/members/${ownerUid}`]: { role: 'owner', status: 'active', addedAt: now },
    [`userFeeders/${ownerUid}/${feederId}`]: { role: 'owner', addedAt: now },
  });
}

console.log(`Project ${PROJECT}: ${isNew ? 'create' : 'update'} feeder ${feederId}`);
for (const [k, v] of Object.entries(updates)) console.log(`  ${k} = ${JSON.stringify(v)}`);
if (!args.includes('--confirm')) {
  console.log('\nDry run. Add --confirm to write this to the production database.');
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), 'agrifeed-'));
const file = join(dir, 'update.json');
try {
  writeFileSync(file, JSON.stringify(updates));
  firebase('database:update', '/', `"${file}"`, '--force');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
console.log(`\nDone. Enter this feeder ID in the ESP32 setup page: ${feederId}`);
