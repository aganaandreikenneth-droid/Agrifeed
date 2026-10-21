import { describe, test } from 'vitest';
import { F, G, NOW, S, arrange, as, assertFails, assertSucceeds, createCommand, devF, devS, useRulesEnv } from './fixture.mjs';

useRulesEnv();

const P = (sub) => `feeders/${F}/${sub}`;

describe('manual feeding commands', () => {
  test('a command cannot be created without taking the lock', async () => {
    const db = as.user('feeder2');
    await assertFails(
      db.ref(P('commands/c1')).set({ amountG: 40, requestedBy: 'feeder2', requestedAt: NOW, status: 'pending', source: 'app' }),
    );
    await assertFails(db.ref(P('activeCommand')).set({ commandId: 'cDone', requestedAt: NOW }));
  });

  test('only one active command at a time', async () => {
    await assertSucceeds(createCommand(as.user('feeder2'), F, 'c1', 'feeder2'));
    await assertFails(createCommand(as.user('owner1'), F, 'c2', 'owner1'));
  });

  test('new commands must be honest pending requests', async () => {
    const db = as.user('feeder2');
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { status: 'completed' }));
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { actualG: 40 }));
    await assertFails(createCommand(db, F, 'c1', 'owner1')); // requestedBy someone else
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { amountG: 0 }));
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { amountG: 600 }));
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { amountG: 201 })); // above feeder max 200
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { source: 'device' }));
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { requestedAt: 5 }));
    await assertFails(createCommand(db, F, 'c1', 'feeder2', { executedBy: 'device' }));
  });

  test('requesters cannot alter or advance their command', async () => {
    const db = as.user('feeder2');
    await assertFails(db.ref(P('commands/cOld/amountG')).set(100));
    await assertFails(db.ref(P('commands/cOld/status')).set('accepted'));
    await assertFails(db.ref(P('commands/cOld/requestedBy')).set('owner1'));
    await assertFails(db.ref(P('commands/cDone/status')).set('failed'));
  });

  test('a stale pending command can be expired by its requester and the lock released', async () => {
    await arrange((db) => db.ref(P('activeCommand')).set({ commandId: 'cOld', requestedAt: 1000 }));
    const db = as.user('feeder2');
    await assertFails(db.ref(P('activeCommand')).remove()); // still pending
    await assertSucceeds(db.ref(P('')).update({ 'commands/cOld/status': 'expired', activeCommand: null }));
  });

  test('a fresh pending command cannot be expired early', async () => {
    const db = as.user('feeder2');
    await createCommand(db, F, 'c1', 'feeder2');
    await assertFails(db.ref(P('commands/c1/status')).set('expired'));
  });

  test("members cannot expire someone else's command", async () => {
    await assertFails(as.user('viewer1').ref(P('commands/cOld/status')).set('expired'));
  });

  test('nobody deletes commands from the app', async () => {
    await assertFails(as.user('owner1').ref(P('commands/cOld')).remove());
    await assertFails(devF().ref(P('commands/cOld')).remove());
  });
});

describe('device reporting (live feeder)', () => {
  test('device advances a command through valid states only', async () => {
    const db = devF();
    await assertSucceeds(db.ref(P('commands/cOld')).update({ status: 'accepted', acceptedAt: NOW }));
    await assertFails(db.ref(P('commands/cAcc/status')).set('completed')); // skips dispensing
    await assertSucceeds(db.ref(P('commands/cDisp')).update({ status: 'completed', actualG: 48, completedAt: NOW, executedBy: 'device' }));
    await assertFails(db.ref(P('commands/cDone/status')).set('pending')); // terminal is final
  });

  test('device cannot claim a live result came from the simulator, or change the request', async () => {
    const db = devF();
    await assertFails(db.ref(P('commands/cDisp')).update({ status: 'completed', executedBy: 'simulator' }));
    await assertFails(db.ref(P('commands/cOld/amountG')).set(10));
  });

  test('device writes status, readings and history', async () => {
    await arrange((a) => a.ref(P('activeCommand')).set({ commandId: 'cDisp', requestedAt: 1000 }));
    const db = devF();
    await assertSucceeds(db.ref(P('status')).set({ lastSeen: NOW, condition: 'ok', rssi: -60, source: 'device' }));
    await assertSucceeds(db.ref(P('telemetry/current')).set({ weightG: 1100, measuredAt: NOW, quality: 'ok', source: 'device' }));
    await assertSucceeds(
      db.ref(P('history/h2')).set({ method: 'manual', requestedG: 50, actualG: 47, status: 'partial', ts: NOW, commandId: 'cDisp', source: 'device' }),
    );
    await assertSucceeds(db.ref(P('activeCommand')).remove());
  });

  test('device data is validated', async () => {
    const db = devF();
    await assertFails(db.ref(P('status')).set({ lastSeen: 5, condition: 'ok', source: 'device' }));
    await assertFails(db.ref(P('status')).set({ lastSeen: NOW, condition: 'great', source: 'device' }));
    await assertFails(db.ref(P('status')).set({ lastSeen: NOW, condition: 'ok', source: 'simulator' }));
    await assertFails(db.ref(P('telemetry/current')).set({ weightG: 'heavy', measuredAt: NOW, quality: 'ok', source: 'device' }));
  });

  test('device history is append-only', async () => {
    const db = devF();
    await assertFails(db.ref(P('history/h1/actualG')).set(10));
    await assertFails(db.ref(P('history/h1')).remove());
    await assertFails(db.ref(P('measurements/m1')).remove());
    await assertFails(db.ref(P('status')).remove());
  });

  test('device cannot change user-controlled data', async () => {
    const db = devF();
    await assertFails(db.ref(P('schedules/s1/amountG')).set(100));
    await assertFails(db.ref(P('config/capacityG')).set(2000));
    await assertFails(db.ref(P('meta/name')).set('x'));
    await assertFails(db.ref(P('members')).get());
    await assertFails(db.ref(P('audit')).get());
  });
});

describe('device authorization is checked live against the registry', () => {
  const statusOk = { lastSeen: NOW, condition: 'ok', source: 'device' };

  test('a device cannot write to another feeder', async () => {
    await assertFails(devF().ref(`feeders/${G}/status`).set(statusOk));
  });

  test('revoked device is rejected even with a token for its own feeder', async () => {
    await assertFails(as.device('dev_G', G, 'live', 1).ref(`feeders/${G}/status`).set(statusOk));
  });

  test('revocation takes effect immediately for an already-issued token', async () => {
    const db = devF();
    await assertSucceeds(db.ref(P('status')).set(statusOk));
    await arrange((a) => a.ref(`deviceRegistry/${F}/status`).set('revoked'));
    await assertFails(db.ref(P('status')).set(statusOk));
  });

  test('rotated credentials invalidate older tokens', async () => {
    await assertFails(as.device('dev_F', F, 'live', 1).ref(P('status')).set(statusOk)); // registry is v2
  });

  test('wrong device UID or wrong mode is rejected', async () => {
    await assertFails(as.device('dev_X', F, 'live', 2).ref(P('status')).set(statusOk));
    await assertFails(as.device('dev_F', F, 'simulated', 2).ref(P('status')).set({ ...statusOk, source: 'simulator' }));
  });
});

describe('simulation is isolated from live feeders', () => {
  const simStatus = { lastSeen: NOW, condition: 'ok', source: 'simulator' };

  test('simulator device writes its own virtual feeder, tagged as simulated', async () => {
    const db = devS();
    await assertSucceeds(db.ref(`feeders/${S}/status`).set(simStatus));
    await assertFails(db.ref(`feeders/${S}/status`).set({ ...simStatus, source: 'device' }));
    await assertSucceeds(
      db.ref(`feeders/${S}/commands/sDisp`).update({ status: 'completed', actualG: 30, completedAt: NOW, executedBy: 'simulator' }),
    );
  });

  test('a simulated result can never be labelled as a real device result', async () => {
    await assertFails(devS().ref(`feeders/${S}/commands/sDisp`).update({ status: 'completed', executedBy: 'device' }));
  });

  test('simulator identity cannot touch a live feeder', async () => {
    const db = devS();
    await assertFails(db.ref(`feeders/${F}/status`).set(simStatus));
    await assertFails(db.ref(`feeders/${F}/status`).set({ ...simStatus, source: 'device' }));
    await assertFails(db.ref(`feeders/${F}/commands/cDisp/status`).set('completed'));
  });

  test('owner drives simulator controls only on virtual feeders', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref(`feeders/${S}/simulator/controls`).set({ hopperWeightG: 400, jam: true, connected: false, updatedAt: NOW }));
    await assertFails(db.ref(`feeders/${F}/simulator/controls`).set({ jam: true }));
    await assertFails(db.ref(`feeders/${S}/simulator/controls`).set({ hopperWeightG: -5 }));
    await assertFails(db.ref(`feeders/${S}/simulator/controls`).set({ teleport: true }));
  });

  test('owner still cannot write device data on a virtual feeder', async () => {
    await assertFails(as.user('owner1').ref(`feeders/${S}/status`).set(simStatus));
  });

  test('simulator controls are private to the owner and the virtual device', async () => {
    await assertSucceeds(devS().ref(`feeders/${S}/simulator/controls`).get());
    await assertFails(as.user('viewer1').ref(`feeders/${S}/simulator/controls`).get());
  });
});
