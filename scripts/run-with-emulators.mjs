// Starts the requested emulators (demo project only), runs a command, then
// shuts the emulators down, killing the whole process tree. Replaces
// `firebase emulators:exec`, which on Windows can leave the Java database
// emulator running after it exits.
//
//   node scripts/run-with-emulators.mjs database -- npx vitest run tests/rules
import { spawn, spawnSync } from 'node:child_process';
import net from 'node:net';

const sep = process.argv.indexOf('--');
const only = process.argv[2];
const command = process.argv.slice(sep + 1).join(' ');
if (!only || sep < 0 || !command) {
  console.error('Usage: node scripts/run-with-emulators.mjs <auth,database,functions> -- <command>');
  process.exit(2);
}

const PORTS = { auth: 9099, database: 9000, functions: 5001 };
const wanted = only.split(',');
const isWin = process.platform === 'win32';

const portOpen = (port) =>
  new Promise((resolve) => {
    const s = net.connect({ host: '127.0.0.1', port }, () => {
      s.destroy();
      resolve(true);
    });
    s.on('error', () => resolve(false));
  });

for (const name of wanted) {
  if (await portOpen(PORTS[name])) {
    console.error(`Port ${PORTS[name]} (${name}) is already in use. Stop the running emulator first.`);
    process.exit(1);
  }
}

const emu = spawn('firebase', ['emulators:start', '--project', 'demo-agrifeed', '--only', only], {
  shell: true,
  stdio: ['ignore', 'pipe', 'pipe'],
});
let log = '';
emu.stdout.on('data', (d) => (log += d));
emu.stderr.on('data', (d) => (log += d));

function stopEmulators() {
  if (emu.exitCode !== null) return;
  if (isWin) spawnSync('taskkill', ['/pid', String(emu.pid), '/T', '/F'], { stdio: 'ignore' });
  else emu.kill('SIGINT');
}
process.on('exit', stopEmulators);

const deadline = Date.now() + 120000;
while (!log.includes('All emulators ready')) {
  if (emu.exitCode !== null || Date.now() > deadline) {
    console.error('Emulators failed to start:\n' + log);
    process.exit(1);
  }
  await new Promise((r) => setTimeout(r, 300));
}

const env = {
  ...process.env,
  FIREBASE_DATABASE_EMULATOR_HOST: '127.0.0.1:9000',
  FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
  GCLOUD_PROJECT: 'demo-agrifeed',
};
const result = spawnSync(command, { shell: true, stdio: 'inherit', env });
if (process.env.SHOW_EMULATOR_LOG) console.log('\n--- emulator log ---\n' + log);
stopEmulators();
process.exitCode = result.status ?? 1;
