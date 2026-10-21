// Generates database.rules.json from rules/rules.mjs.
//   node rules/build.mjs          write the file
//   node rules/build.mjs --check  fail if the committed file is out of date
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { rules } from './rules.mjs';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'database.rules.json');
const text = JSON.stringify(rules, null, 2) + '\n';

if (process.argv.includes('--check')) {
  let current = '';
  try {
    current = readFileSync(out, 'utf8').replace(/\r\n/g, '\n');
  } catch {}
  if (current !== text) {
    console.error('database.rules.json is out of date. Run: node rules/build.mjs');
    process.exit(1);
  }
  console.log('database.rules.json is up to date.');
} else {
  writeFileSync(out, text);
  console.log(`Wrote ${out} (${text.length} bytes)`);
}
