// TEMPORARY LAN mode for testing on a physical phone over Wi-Fi.
//
//   npm run emulators:lan -- --confirm-lan
//
// Prefer USB instead (no network exposure at all):
//   adb reverse tcp:9099 tcp:9099 && adb reverse tcp:9000 tcp:9000 && adb reverse tcp:5001 tcp:5001
//   flutter run --dart-define=EMULATOR_HOST=127.0.0.1
//
// This script writes a temporary copy of firebase.json in which only the
// Auth, Database and Functions emulators listen on all interfaces (the
// Emulator UI, hub and logging stay on 127.0.0.1), starts the emulators, and
// deletes the copy when stopped. firebase.json itself stays localhost-only.
import { spawn } from 'node:child_process';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';

if (!process.argv.includes('--confirm-lan')) {
  console.error(`Refusing to expose the emulators on the network without --confirm-lan.

Before using LAN mode:
  * Use a trusted private network only (home Wi-Fi), never public/school/cafe Wi-Fi.
  * Keep the Windows network profile set to "Private", not "Public".
  * Allow only the phone's IP, only while testing, e.g. (admin PowerShell):
      New-NetFirewallRule -DisplayName "AgriFeed emulators (temp)" -Direction Inbound -Protocol TCP \`
        -LocalPort 9099,9000,5001 -RemoteAddress <PHONE_IP> -Profile Private -Action Allow
    and remove it afterwards:
      Remove-NetFirewallRule -DisplayName "AgriFeed emulators (temp)"
  * The emulators accept unauthenticated admin-style requests (e.g. the Auth
    emulator REST API), so anyone who can reach these ports can read and
    change emulator data. Only seeded test data may be stored there.
  * Stop with Ctrl+C as soon as testing is finished.`);
  process.exit(1);
}

const TEMP = '.firebase-lan.json';
const config = JSON.parse(readFileSync('firebase.json', 'utf8'));
for (const k of ['auth', 'database', 'functions']) config.emulators[k].host = '0.0.0.0';
writeFileSync(TEMP, JSON.stringify(config, null, 2));

const cleanup = () => rmSync(TEMP, { force: true });
process.on('exit', cleanup);
process.on('SIGINT', () => process.exit(130));

console.log('LAN MODE: Auth 9099, Database 9000, Functions 5001 are reachable from the network.');
console.log('Run the app with: flutter run --dart-define=EMULATOR_HOST=<this PC LAN IP>\n');
const child = spawn('firebase', ['--config', TEMP, 'emulators:start', '--project', 'demo-agrifeed'], {
  shell: true,
  stdio: 'inherit',
});
child.on('exit', (code) => process.exit(code ?? 0));
