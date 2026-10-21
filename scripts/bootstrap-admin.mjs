// Grants the FIRST platform administrator in the local emulator.
//
//   npm run bootstrap-admin -- --email you@example.com
//
// The account must already exist (register in the app) and be verified.
// Refuses to run once any administrator exists: further admins are granted
// from the app through the setAdminRole function. Emulator only in Phase 1;
// production bootstrapping is a separate, approved step.
import { assertEmulatorRunning, auth, db, makeAdmin } from './emulator-admin.mjs';

const i = process.argv.indexOf('--email');
const email = i > 0 ? process.argv[i + 1] : undefined;
if (!email) {
  console.error('Usage: npm run bootstrap-admin -- --email you@example.com');
  process.exit(1);
}

await assertEmulatorRunning();

const existing = await db.ref('platformAdmins').get();
if (existing.exists()) {
  console.error('An administrator already exists. Use the admin screen in the app instead.');
  process.exit(1);
}

let user;
try {
  user = await auth.getUserByEmail(email);
} catch {
  console.error('No account with that email. Register it in the app first.');
  process.exit(1);
}
if (!user.emailVerified) {
  console.error('Verify the email first (the link is shown in the Emulator UI > Authentication).');
  process.exit(1);
}

await makeAdmin(user.uid, 'bootstrap-script');
console.log(`Administrator granted to ${user.uid}. Sign out and in again (or wait for the app to refresh).`);
process.exit(0);
