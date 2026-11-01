// Deploys database.rules.json to the production Realtime Database
// (agrifeed-dda82-default-rtdb). firebase.json only names the emulator
// namespaces, so this writes a temporary config for the real instance.
//
//   npm run production:rules -- --confirm
//
// The Firebase Console (Realtime Database > Rules) keeps the previous
// version, so a deploy can be rolled back there.
import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';

const check = spawnSync('node', ['rules/build.mjs', '--check'], { stdio: 'inherit' });
if (check.status !== 0) process.exit(1);

if (!process.argv.includes('--confirm')) {
  console.error('This replaces the rules of the PRODUCTION database. Re-run with --confirm.');
  process.exit(2);
}

const TEMP = '.firebase-production-rules.json';
const config = JSON.parse(readFileSync('firebase.json', 'utf8'));
writeFileSync(
  TEMP,
  JSON.stringify({ database: [{ instance: 'agrifeed-dda82-default-rtdb', rules: 'database.rules.json' }], flutter: config.flutter }, null, 2),
);
try {
  const r = spawnSync('firebase', ['--config', TEMP, 'deploy', '--only', 'database', '--project', 'agrifeed-dda82'], {
    shell: true,
    stdio: 'inherit',
  });
  process.exitCode = r.status ?? 1;
} finally {
  rmSync(TEMP, { force: true });
}
