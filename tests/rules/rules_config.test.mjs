// Verifies that the emulator configuration matches what the app uses:
//  * the database namespace in the Flutter app is one firebase.json loads rules for;
//  * the rules the emulator actually loaded are exactly database.rules.json;
//  * unauthenticated REST access is denied on every configured namespace;
//  * the emulators are bound to localhost and the default project is a demo project.
import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { PROJECT_ID } from './fixture.mjs';

const firebaseJson = JSON.parse(readFileSync('firebase.json', 'utf8'));
const instances = firebaseJson.database.map((d) => d.instance);
const host = process.env.FIREBASE_DATABASE_EMULATOR_HOST ?? '127.0.0.1:9000';
const rulesFile = JSON.parse(readFileSync('database.rules.json', 'utf8'));

describe('emulator configuration', () => {
  test('the Flutter app targets a namespace that firebase.json protects', () => {
    const env = readFileSync('lib/core/env.dart', 'utf8');
    const backend = readFileSync('lib/core/backend.dart', 'utf8');
    expect(env).toContain(`kEmulatorProjectId = '${PROJECT_ID}'`);
    expect(backend).toContain("databaseURL: 'https://$kEmulatorProjectId.firebaseio.com'");
    expect(instances).toContain(PROJECT_ID); // app + Cloud Functions namespace
    expect(instances).toContain(`${PROJECT_ID}-default-rtdb`); // SDK default naming, also protected
    for (const d of firebaseJson.database) expect(d.rules).toBe('database.rules.json');
  });

  for (const ns of instances) {
    test(`namespace ${ns} has database.rules.json loaded`, async () => {
      const res = await fetch(`http://${host}/.settings/rules.json?ns=${ns}`, {
        headers: { Authorization: 'Bearer owner' },
      });
      expect(res.status).toBe(200);
      expect(JSON.parse(await res.text())).toEqual(rulesFile);
    });

    test(`namespace ${ns} denies unauthenticated REST reads and writes`, async () => {
      for (const path of ['', 'users', 'feeders', 'platformAudit', 'accountStatus']) {
        expect((await fetch(`http://${host}/${path}.json?ns=${ns}`)).status).toBe(401);
      }
      const write = await fetch(`http://${host}/users/evil.json?ns=${ns}`, { method: 'PUT', body: '{"x":1}' });
      expect(write.status).toBe(401);
    });
  }

  test('emulators listen on localhost only, and the default project is a demo project', () => {
    const emu = firebaseJson.emulators;
    for (const k of ['auth', 'database', 'functions', 'ui', 'hub', 'logging']) expect(emu[k].host).toBe('127.0.0.1');
    const rc = JSON.parse(readFileSync('.firebaserc', 'utf8'));
    expect(rc.projects.default.startsWith('demo-')).toBe(true);
  });
});
