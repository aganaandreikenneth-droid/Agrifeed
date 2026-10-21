import { describe, test } from 'vitest';
import { F, G, NOW, as, assertFails, assertSucceeds, createCommand, schedule, useRulesEnv } from './fixture.mjs';

useRulesEnv();

const P = (sub) => `feeders/${F}/${sub}`;

describe('owner: READ access per resource', () => {
  for (const path of ['meta', 'config', 'members', 'status', 'telemetry', 'measurements', 'history', 'alerts', 'audit', 'schedules', 'commands', 'activeCommand']) {
    test(`owner can read ${path}`, async () => {
      await assertSucceeds(as.user('owner1').ref(P(path)).get());
    });
  }
  test('owner cannot read the whole feeder node in one listener (no parent grant)', async () => {
    await assertFails(as.user('owner1').ref(`feeders/${F}`).get());
  });
});

describe('owner: allowed WRITES', () => {
  test('settings', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref(P('meta/name')).set('Coop B'));
    await assertSucceeds(db.ref(P('meta/timezone')).set('Asia/Manila'));
    await assertSucceeds(db.ref(P('config/capacityG')).set(2800));
    await assertSucceeds(db.ref(P('config/lowThresholdG')).set(400));
    await assertSucceeds(db.ref(P('config/maxDispenseG')).set(150));
    await assertSucceeds(db.ref(P('config/schedulesPaused')).set(true));
  });

  test('schedules: create, edit, delete', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref(P('schedules/new1')).set(schedule('owner1')));
    await assertSucceeds(db.ref(P('schedules/s1')).update({ enabled: false, updatedAt: NOW, updatedBy: 'owner1' }));
    await assertSucceeds(db.ref(P('schedules/s1')).remove());
  });

  test('manual feeding request together with the lock', async () => {
    await assertSucceeds(createCommand(as.user('owner1'), F, 'c1', 'owner1'));
  });
});

describe('owner: DENIED writes on device data, outcomes and audit', () => {
  const cases = {
    'forge live status': (db) => db.ref(P('status')).set({ lastSeen: NOW, condition: 'ok', source: 'device' }),
    'forge weight reading': (db) => db.ref(P('telemetry/current')).set({ weightG: 3000, measuredAt: NOW, quality: 'ok', source: 'device' }),
    'add a measurement': (db) => db.ref(P('measurements/m2')).set({ weightG: 10, ts: NOW, source: 'device' }),
    'create a feeding record': (db) =>
      db.ref(P('history/h2')).set({ method: 'manual', requestedG: 50, actualG: 50, status: 'completed', ts: NOW, source: 'device' }),
    'edit a verified outcome': (db) => db.ref(P('history/h1/actualG')).set(50),
    'delete a feeding record': (db) => db.ref(P('history/h1')).remove(),
    'wipe history': (db) => db.ref(P('history')).remove(),
    'write an alert': (db) => db.ref(P('alerts/a1/state')).set('resolved'),
    'write audit': (db) => db.ref(P('audit/x')).set({ action: 'fake', ts: NOW }),
    'delete audit': (db) => db.ref(P('audit/au1')).remove(),
    'set load-cell rating': (db) => db.ref(P('config/loadCellMaxG')).set(10000),
    'set calibration status': (db) => db.ref(P('config/calibrationStatus')).set('calibrated'),
    'mark a command completed': (db) => db.ref(P('commands/cOld/status')).set('completed'),
    'add actual grams to a command': (db) => db.ref(P('commands/cOld/actualG')).set(50),
    'delete a command': (db) => db.ref(P('commands/cDone')).remove(),
    'delete the feeder name': (db) => db.ref(P('meta/name')).remove(),
    'delete the whole feeder': (db) => db.ref(`feeders/${F}`).remove(),
    'delete all schedules at once': (db) => db.ref(P('schedules')).remove(),
    'simulator controls on a live feeder': (db) => db.ref(P('simulator/controls')).set({ jam: true }),
  };
  for (const [name, op] of Object.entries(cases)) {
    test(name, async () => assertFails(op(as.user('owner1'))));
  }
});

describe('owner: invalid values are rejected', () => {
  test('config limits', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref(P('config/capacityG')).set(9000)); // above 3 kg load cell
    await assertFails(db.ref(P('config/lowThresholdG')).set(3000)); // not below capacity
    await assertFails(db.ref(P('config/maxDispenseG')).set(600)); // above platform cap
    await assertFails(db.ref(P('config/unknown')).set(1));
    await assertFails(db.ref(P('meta/timezone')).set('Not a zone!'));
    await assertFails(db.ref(P('meta/name')).set('x'.repeat(41)));
  });

  test('schedule fields', async () => {
    const db = as.user('owner1');
    const bad = {
      'hour 24': schedule('owner1', { time: '24:00' }),
      'missing leading zero': schedule('owner1', { time: '7:00' }),
      'weekday 7': schedule('owner1', { weekdays: { 7: true } }),
      'zero grams': schedule('owner1', { amountG: 0 }),
      'above feeder max': schedule('owner1', { amountG: 250 }),
      'written for someone else': schedule('owner1', { updatedBy: 'viewer1' }),
      'client timestamp': schedule('owner1', { updatedAt: 5 }),
      'unknown field': schedule('owner1', { extra: 1 }),
      'string amount': schedule('owner1', { amountG: '50' }),
    };
    for (const v of Object.values(bad)) await assertFails(db.ref(P('schedules/bad')).set(v));
    const { weekdays, ...noDays } = schedule('owner1');
    await assertFails(db.ref(P('schedules/bad')).set(noDays));
    await assertFails(db.ref(P('schedules/s1/createdAt')).set(NOW));
  });
});

describe('member permissions are enforced per path', () => {
  test('viewer (viewDashboard + viewHistory)', async () => {
    const db = as.user('viewer1');
    await assertSucceeds(db.ref(P('status')).get());
    await assertSucceeds(db.ref(P('schedules')).get());
    await assertSucceeds(db.ref(P('history')).get());
    await assertSucceeds(db.ref(P('commands')).get());
    await assertSucceeds(db.ref(P('members/viewer1')).get());
    await assertFails(db.ref(P('members')).get());
    await assertFails(db.ref(P('members/owner1')).get());
    await assertFails(db.ref(P('audit')).get());
    await assertSucceeds(db.ref(P('measurements')).get()); // viewHistory is enough
  });

  test('viewer cannot change anything', async () => {
    const db = as.user('viewer1');
    await assertFails(db.ref(P('schedules/x')).set(schedule('viewer1')));
    await assertFails(db.ref(P('schedules/s1')).remove());
    await assertFails(db.ref(P('config/schedulesPaused')).set(true));
    await assertFails(db.ref(P('config/capacityG')).set(2000));
    await assertFails(db.ref(P('meta/name')).set('Mine'));
    await assertFails(createCommand(db, F, 'c1', 'viewer1'));
  });

  test('operator (manualFeed + manageSchedules) gets exactly those', async () => {
    const db = as.user('feeder2');
    await assertSucceeds(db.ref(P('schedules/x')).set(schedule('feeder2')));
    await assertSucceeds(db.ref(P('schedules/s1')).remove());
    await assertSucceeds(db.ref(P('config/schedulesPaused')).set(true));
    await assertSucceeds(createCommand(db, F, 'c1', 'feeder2'));
    await assertFails(db.ref(P('config/capacityG')).set(2000));
    await assertFails(db.ref(P('meta/name')).set('Mine'));
    await assertFails(db.ref(P('history')).get());
    await assertFails(db.ref(P('audit')).get());
  });

  test('expired membership grants nothing', async () => {
    const db = as.user('expired1');
    await assertFails(db.ref(P('status')).get());
    await assertFails(db.ref(P('schedules/x')).set(schedule('expired1')));
    await assertFails(createCommand(db, F, 'c1', 'expired1'));
  });

  test('pending (not accepted) invitation grants nothing', async () => {
    await assertFails(as.user('invited1').ref(P('status')).get());
  });

  test('removed / never-added users get nothing', async () => {
    const db = as.user('outsider');
    await assertFails(db.ref(P('meta')).get());
    await assertFails(db.ref(P('status')).get());
  });

  test('suspended member is denied despite a valid membership', async () => {
    await assertFails(as.user('suspended1').ref(P('status')).get());
  });
});

describe('cross-feeder isolation', () => {
  test("an owner cannot read or write another owner's feeder", async () => {
    const db = as.user('owner1');
    await assertFails(db.ref(`feeders/${G}/meta`).get());
    await assertFails(db.ref(`feeders/${G}/status`).get());
    await assertFails(db.ref(`feeders/${G}/schedules/x`).set(schedule('owner1')));
    await assertFails(createCommand(db, G, 'c1', 'owner1'));
  });

  test('feeders and the user index cannot be listed or browsed', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('feeders').get());
    await assertFails(db.ref('userFeeders').get());
    await assertFails(db.ref('userFeeders/owner2').get());
    await assertSucceeds(db.ref('userFeeders/owner1').get());
  });
});
