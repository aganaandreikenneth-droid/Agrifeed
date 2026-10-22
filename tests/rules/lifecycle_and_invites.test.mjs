// Phase 2A rules: archived feeders, invitation summaries, backend-only nodes.
import { beforeEach, describe, test } from 'vitest';
import { F, NOW, S, arrange, as, assertFails, assertSucceeds, createCommand, schedule, useRulesEnv } from './fixture.mjs';

useRulesEnv();

const P = (sub, id = F) => `feeders/${id}/${sub}`;
const OLD = 1000;

describe('archived feeder: read-only for people', () => {
  beforeEach(async () => {
    await arrange((db) =>
      db.ref().update({
        [`${P('meta')}/archivedAt`]: OLD,
        [`${P('meta')}/archivedBy`]: 'owner1',
        [`${P('meta', S)}/archivedAt`]: OLD,
      }),
    );
  });

  test('owner cannot change settings', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref(P('meta/name')).set('Renamed'));
    await assertFails(db.ref(P('meta/timezone')).set('UTC'));
    await assertFails(db.ref(P('config/capacityG')).set(2800));
    await assertFails(db.ref(P('config/lowThresholdG')).set(400));
    await assertFails(db.ref(P('config/maxDispenseG')).set(150));
    await assertFails(db.ref(P('config/schedulesPaused')).set(true));
  });

  test('owner and members cannot create, edit or delete schedules', async () => {
    for (const uid of ['owner1', 'feeder2']) {
      const db = as.user(uid);
      await assertFails(db.ref(P('schedules/new1')).set(schedule(uid)));
      await assertFails(db.ref(P('schedules/s1')).update({ enabled: false, updatedAt: NOW, updatedBy: uid }));
      await assertFails(db.ref(P('schedules/s1')).remove());
    }
  });

  test('nobody can request feeding', async () => {
    await assertFails(createCommand(as.user('owner1'), F, 'c1', 'owner1'));
    await assertFails(createCommand(as.user('feeder2'), F, 'c2', 'feeder2'));
  });

  test('simulator controls are frozen', async () => {
    await assertFails(as.user('owner1').ref(P('simulator/controls/jam', S)).set(true));
  });

  test('clean-up of a stale command is still allowed', async () => {
    await assertSucceeds(as.user('feeder2').ref(P('commands/cOld/status')).set('expired'));
  });

  test('clients cannot archive or restore by writing meta', async () => {
    await assertFails(as.user('owner1').ref(P('meta/archivedAt')).remove());
    await assertFails(as.user('owner1').ref(P('meta/archivedAt', 'fd_otherFeederCCCCCCCCCCC')).set(NOW));
  });

  test('history and dashboard data stay readable for those allowed', async () => {
    await assertSucceeds(as.user('owner1').ref(P('meta')).get());
    await assertSucceeds(as.user('owner1').ref(P('history')).get());
    await assertSucceeds(as.user('owner1').ref(P('audit')).get());
    await assertSucceeds(as.user('viewer1').ref(P('status')).get());
    await assertFails(as.user('outsider').ref(P('meta')).get());
  });
});

describe('a non-archived feeder accepts the same writes', () => {
  test('owner can still edit settings and schedules on the live fixture', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref(P('meta/name')).set('Renamed'));
    await assertSucceeds(db.ref(P('schedules/new1')).set(schedule('owner1')));
    await assertSucceeds(as.user('owner1').ref(P('simulator/controls/jam', S)).set(true));
  });
});

describe('invitation summaries', () => {
  beforeEach(async () => {
    await arrange((db) =>
      db.ref(P('invites/inv1')).set({ createdBy: 'owner1', createdAt: OLD, expiresAt: OLD, status: 'open', permissions: { viewDashboard: true } }),
    );
  });

  test('only the owner can read them', async () => {
    await assertSucceeds(as.user('owner1').ref(P('invites')).get());
    for (const uid of ['viewer1', 'feeder2', 'fakeowner1', 'outsider']) {
      await assertFails(as.user(uid).ref(P('invites')).get());
    }
    await assertFails(as.admin().ref(P('invites')).get());
  });

  test('nobody writes them from the app', async () => {
    await assertFails(as.user('owner1').ref(P('invites/inv1/status')).set('revoked'));
    await assertFails(as.user('owner1').ref(P('invites/inv2')).set({ status: 'open' }));
    await assertFails(as.user('owner1').ref(P('invites/inv1')).remove());
  });
});

describe('Phase 2 backend-only nodes', () => {
  beforeEach(async () => {
    await arrange((db) =>
      db.ref().update({
        'inviteCodes/abc': 'inv1',
        'userQuotas/owner1/virtualFeeders': { [S]: { requestId: 'r1', reservedAt: OLD } },
        'rateLimits/acceptInvite/owner1': { windowStart: OLD, count: 9 },
        'platformConfig/limits': { virtualFeedersPerOwner: 3 },
      }),
    );
  });

  test('users cannot read or change codes, quotas or rate limits', async () => {
    const db = as.user('owner1');
    for (const path of ['inviteCodes', 'inviteCodes/abc', 'userQuotas/owner1', 'rateLimits/acceptInvite/owner1', 'platformConfig']) {
      await assertFails(db.ref(path).get());
    }
    await assertFails(db.ref('userQuotas/owner1/virtualFeeders').remove());
    await assertFails(db.ref('rateLimits/acceptInvite/owner1').remove());
    await assertFails(db.ref('inviteCodes/new').set('inv9'));
    await assertFails(db.ref('platformConfig/limits/virtualFeedersPerOwner').set(100));
  });

  test('admin can read platform config but not change it or read quotas', async () => {
    const db = as.admin();
    await assertSucceeds(db.ref('platformConfig').get());
    await assertFails(db.ref('platformConfig/limits/virtualFeedersPerOwner').set(100));
    await assertFails(db.ref('userQuotas').get());
    await assertFails(db.ref('inviteCodes').get());
  });
});
