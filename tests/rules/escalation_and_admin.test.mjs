import { describe, test } from 'vitest';
import { F, G, NOW, as, assertFails, assertSucceeds, useRulesEnv } from './fixture.mjs';

useRulesEnv();

describe('privilege escalation is blocked', () => {
  test('users cannot touch account status', async () => {
    await assertFails(as.user('suspended1').ref('accountStatus/suspended1/suspended').set(false));
    await assertFails(as.user('suspended1').ref('accountStatus/suspended1').remove());
    await assertFails(as.user('owner1').ref('accountStatus/viewer1').set({ suspended: true }));
  });

  test('users cannot make themselves administrators', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('platformAdmins/owner1').set(true));
    await assertFails(db.ref('platformAdmins').get());
  });

  test('users cannot read or forge the platform audit', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('platformAudit').get());
    await assertFails(db.ref('platformAudit/x').set({ action: 'admin_role_granted', ts: NOW }));
  });

  test('users cannot grant themselves feeder access', async () => {
    await assertFails(as.user('owner1').ref(`userFeeders/owner1/${G}`).set({ role: 'owner' }));
    await assertFails(as.user('owner1').ref(`feeders/${G}/members/owner1`).set({ role: 'owner', status: 'active' }));
  });

  test('members cannot change their own role or permissions', async () => {
    const db = as.user('viewer1');
    await assertFails(db.ref(`feeders/${F}/members/viewer1/role`).set('owner'));
    await assertFails(db.ref(`feeders/${F}/members/viewer1/permissions/manualFeed`).set(true));
    await assertFails(db.ref(`feeders/${F}/members/viewer1/expiresAt`).remove());
  });

  test('owners cannot write membership directly (backend only)', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref(`feeders/${F}/members/newbie`).set({ role: 'member', status: 'active' }));
    await assertFails(db.ref(`feeders/${F}/members/viewer1`).remove());
    await assertFails(db.ref(`feeders/${F}/members/viewer1/permissions/manualFeed`).set(true));
  });

  test('ownership and mode cannot be changed by anyone in the app', async () => {
    await assertFails(as.user('owner1').ref(`feeders/${F}/meta/ownerUid`).set('viewer1'));
    await assertFails(as.user('viewer1').ref(`feeders/${F}/meta/ownerUid`).set('viewer1'));
    await assertFails(as.user('owner1').ref(`feeders/${F}/meta/mode`).set('simulated'));
  });

  test('an owner record without matching meta.ownerUid grants nothing extra', async () => {
    await assertFails(as.user('fakeowner1').ref(`feeders/${F}/config/capacityG`).set(2000));
    await assertFails(as.user('fakeowner1').ref(`feeders/${F}/audit`).get());
  });

  test('registry, claims and invitations are backend-only', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('deviceRegistry').get());
    await assertFails(db.ref(`deviceRegistry/${F}/status`).set('active'));
    await assertFails(db.ref(`deviceClaims/${F}`).get());
    await assertFails(db.ref('invitations/inv1').get());
    await assertFails(db.ref('invitations/new').set({ feederId: F }));
  });
});

describe('System Admin scope', () => {
  test('admin reads platform data', async () => {
    const db = as.admin();
    await assertSucceeds(db.ref('platformAudit').get());
    await assertSucceeds(db.ref('accountStatus').get());
    await assertSucceeds(db.ref('deviceRegistry').get());
    await assertSucceeds(db.ref('platformAdmins').get());
  });

  test('admin cannot write or delete trusted platform data from the app', async () => {
    const db = as.admin();
    await assertFails(db.ref('platformAudit/pa1').remove());
    await assertFails(db.ref('platformAudit/x').set({ action: 'x', ts: NOW }));
    await assertFails(db.ref('accountStatus/viewer1/suspended').set(true));
    await assertFails(db.ref('platformAdmins/owner1').set(true));
  });

  test('admin has NO access to private feeder data or control', async () => {
    const db = as.admin();
    for (const path of ['meta', 'status', 'telemetry', 'schedules', 'history', 'commands', 'members', 'audit']) {
      await assertFails(db.ref(`feeders/${F}/${path}`).get());
    }
    await assertFails(db.ref(`feeders/${F}/schedules/x`).set({ time: '07:00' }));
    await assertFails(db.ref('userFeeders/owner1').get());
  });

  test('a stale admin claim without the registry entry is rejected', async () => {
    const db = as.staleAdmin();
    await assertFails(db.ref('platformAudit').get());
    await assertFails(db.ref('accountStatus').get());
  });
});
