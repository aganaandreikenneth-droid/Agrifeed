// Integration tests for the Phase 2A Cloud Functions: virtual feeders,
// invitations and membership. Emulators only (demo project).
import { get, ref, remove, set, update } from 'firebase/database';
import { describe, expect, test } from 'vitest';
import {
  ALL_PERMS, TZ, anonymousCaller, auth, codeOf, createUser, db, join, ownerWithFeeder, requestId, rulesCode, signIn, useCleanEmulators, val,
} from './helpers.mjs';

useCleanEmulators();

describe('createVirtualFeeder', () => {
  test('rejects signed-out, unverified and suspended callers', async () => {
    const data = { name: 'X', timezone: TZ, requestId: requestId() };
    expect(await codeOf(anonymousCaller()('createVirtualFeeder', data))).toBe('functions/unauthenticated');
    await createUser('unv', { verified: false });
    expect(await codeOf((await signIn('unv')).call('createVirtualFeeder', data))).toBe('functions/permission-denied');
    await createUser('susp');
    const s = await signIn('susp');
    await db.ref('accountStatus/susp/suspended').set(true);
    expect(await codeOf(s.call('createVirtualFeeder', data))).toBe('functions/permission-denied');
    expect(await val('feeders')).toBeNull();
  });

  test('validates input', async () => {
    await createUser('u1');
    const { call } = await signIn('u1');
    const ok = { name: 'Coop', timezone: TZ, requestId: requestId() };
    for (const bad of [
      { ...ok, name: '   ' },
      { ...ok, name: 'x'.repeat(41) },
      { ...ok, timezone: 'Mars/Phobos' },
      { ...ok, timezone: 'not a zone' },
      { ...ok, requestId: 'short' },
      { ...ok, requestId: '../../etc/x' },
    ]) {
      expect(await codeOf(call('createVirtualFeeder', bad))).toBe('functions/invalid-argument');
    }
  });

  test('creates the feeder, ownership, index, registry, quota and audit atomically', async () => {
    const { feederId } = await ownerWithFeeder('  My Coop  ');
    expect(feederId).toMatch(/^fd_[0-9A-Za-z]{20}$/);

    const f = await val(`feeders/${feederId}`);
    expect(f.meta).toMatchObject({ name: 'My Coop', ownerUid: 'owner1', mode: 'simulated', timezone: TZ });
    expect(typeof f.meta.createdAt).toBe('number');
    expect(f.config).toEqual({
      capacityG: 3000, loadCellMaxG: 3000, lowThresholdG: 500, maxDispenseG: 200,
      calibrationStatus: 'uncalibrated', schedulesPaused: false,
    });
    expect(f.members.owner1).toMatchObject({ role: 'owner', status: 'active', displayName: 'Owner One' });
    expect(f.audit.created).toMatchObject({ action: 'feeder_created', actorUid: 'owner1' });
    expect(await val(`userFeeders/owner1/${feederId}`)).toMatchObject({ role: 'owner' });

    const reg = await val(`deviceRegistry/${feederId}`);
    expect(reg).toMatchObject({ status: 'provisioned', mode: 'simulated', ownerUid: 'owner1', credentialVersion: 1 });
    expect(reg.deviceUid).toBeUndefined(); // no device can act for it yet
    expect(Object.keys(await val('userQuotas/owner1/virtualFeeders'))).toEqual([feederId]);

    const pa = Object.values(await val('platformAudit'));
    expect(pa).toHaveLength(1);
    expect(pa[0]).toMatchObject({ action: 'virtual_feeder_created', actorUid: 'owner1', feederId });
    expect(JSON.stringify(pa)).not.toContain('My Coop'); // no private feeder data in the platform log
  });

  test('the new feeder works through the Security Rules for its owner only', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('outsider');
    await createUser('admin1', { admin: true });
    const outsider = await signIn('outsider');
    const admin = await signIn('admin1');

    expect((await get(ref(owner.db, `feeders/${feederId}/meta/name`))).val()).toBe('Coop A');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'Renamed'))).toBe('ok');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/mode`), 'live'))).toBe('denied');
    for (const other of [outsider, admin]) {
      expect(await rulesCode(get(ref(other.db, `feeders/${feederId}/meta`)))).toBe('denied');
    }
  });

  test('retrying with the same requestId returns the same feeder', async () => {
    await createUser('owner1');
    const { call } = await signIn('owner1');
    const data = { name: 'Coop', timezone: 'UTC', requestId: requestId() };
    const [a, b] = await Promise.all([call('createVirtualFeeder', data), call('createVirtualFeeder', data)]);
    const c = await call('createVirtualFeeder', data);
    expect(b.feederId).toBe(a.feederId);
    expect(c.feederId).toBe(a.feederId);
    expect(Object.keys(await val('feeders'))).toEqual([a.feederId]);
    expect(Object.keys(await val('userQuotas/owner1/virtualFeeders'))).toHaveLength(1);
  });

  test('limit of 3 per owner holds under concurrent requests', async () => {
    await createUser('owner1');
    const { call } = await signIn('owner1');
    const results = await Promise.all(
      Array.from({ length: 5 }, (_, i) => codeOf(call('createVirtualFeeder', { name: `F${i}`, timezone: 'UTC', requestId: requestId() }))),
    );
    expect(results.filter((r) => r === 'ok')).toHaveLength(3);
    expect(results.filter((r) => r === 'functions/resource-exhausted')).toHaveLength(2);
    expect(Object.keys(await val('feeders'))).toHaveLength(3);
    expect(Object.keys(await val('userFeeders/owner1'))).toHaveLength(3);
    expect(Object.keys(await val('userQuotas/owner1/virtualFeeders'))).toHaveLength(3);
    expect(Object.keys(await val('deviceRegistry'))).toHaveLength(3);
  });

  test('the limit is per owner and configurable from platformConfig', async () => {
    await db.ref('platformConfig/limits/virtualFeedersPerOwner').set(1);
    await createUser('owner1');
    await createUser('owner2');
    const o1 = await signIn('owner1');
    const o2 = await signIn('owner2');
    const mk = (c) => codeOf(c.call('createVirtualFeeder', { name: 'F', timezone: 'UTC', requestId: requestId() }));
    expect(await mk(o1)).toBe('ok');
    expect(await mk(o1)).toBe('functions/resource-exhausted');
    expect(await mk(o2)).toBe('ok');
  });
});

describe('archive, restore and permanent deletion', () => {
  test('only the owner can manage the lifecycle', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    await createUser('admin1', { admin: true });
    const admin = await signIn('admin1');
    for (const c of [member, admin]) {
      expect(await codeOf(c.call('archiveFeeder', { feederId }))).toBe('functions/permission-denied');
    }
    expect(await codeOf(owner.call('archiveFeeder', { feederId: 'fd_AAAAAAAAAAAAAAAAAAAA' }))).toBe('functions/permission-denied');
    expect(await codeOf(owner.call('archiveFeeder', { feederId: 'feeder1' }))).toBe('functions/invalid-argument');
    expect(await val(`feeders/${feederId}/meta/archivedAt`)).toBeNull();
  });

  test('archiving freezes app writes, stops the device and revokes open invitations; restore undoes it', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    const { inviteId } = await owner.call('createInvite', { feederId });

    expect(await owner.call('archiveFeeder', { feederId })).toEqual({ ok: true, archived: true });
    expect(typeof (await val(`feeders/${feederId}/meta/archivedAt`))).toBe('number');
    expect(await val(`deviceRegistry/${feederId}/status`)).toBe('archived');
    expect(await val(`invitations/${inviteId}/status`)).toBe('revoked');
    expect(await val(`feeders/${feederId}/invites/${inviteId}/status`)).toBe('revoked');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'X'))).toBe('denied');
    const ts = { '.sv': 'timestamp' };
    const sched = { time: '07:00', weekdays: { 1: true }, amountG: 50, enabled: true, createdAt: ts, updatedAt: ts, updatedBy: 'owner1' };
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/schedules/s1`), sched))).toBe('denied');
    expect(await rulesCode(update(ref(owner.db, `feeders/${feederId}`), {
      'commands/c1': { amountG: 40, requestedBy: 'owner1', requestedAt: ts, status: 'pending', source: 'app' },
      activeCommand: { commandId: 'c1', requestedAt: ts },
    }))).toBe('denied');
    // Members keep read access; nothing was deleted.
    expect((await get(ref(member.db, `feeders/${feederId}/meta/name`))).val()).toBe('Coop A');
    expect(await codeOf(owner.call('createInvite', { feederId }))).toBe('functions/failed-precondition');

    expect(await owner.call('restoreFeeder', { feederId })).toEqual({ ok: true, archived: false });
    expect(await val(`feeders/${feederId}/meta/archivedAt`)).toBeNull();
    expect(await val(`deviceRegistry/${feederId}/status`)).toBe('provisioned');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'X'))).toBe('ok');

    const actions = Object.values(await val(`feeders/${feederId}/audit`)).map((e) => e.action);
    expect(actions).toEqual(expect.arrayContaining(['feeder_archived', 'feeder_restored']));
  });

  test('an archived feeder still counts toward the limit', async () => {
    await db.ref('platformConfig/limits/virtualFeedersPerOwner').set(1);
    const { owner, feederId } = await ownerWithFeeder();
    await owner.call('archiveFeeder', { feederId });
    expect(await codeOf(owner.call('createVirtualFeeder', { name: 'B', timezone: 'UTC', requestId: requestId() })))
      .toBe('functions/resource-exhausted');
  });

  test('permanent deletion requires archiving and the exact name', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    expect(await codeOf(owner.call('deleteFeederPermanently', { feederId, confirmName: 'Coop A' }))).toBe('functions/failed-precondition');
    await owner.call('archiveFeeder', { feederId });
    for (const confirmName of [undefined, 'coop a', 'Coop', 'Coop A ']) {
      expect(await codeOf(owner.call('deleteFeederPermanently', { feederId, confirmName }))).toBe('functions/invalid-argument');
    }
    expect(await val(`feeders/${feederId}/meta/name`)).toBe('Coop A');
  });

  test('members cannot delete; the owner deletion cleans every link and keeps an audit trail', async () => {
    await db.ref('platformConfig/limits/virtualFeedersPerOwner').set(1);
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    await db.ref('users/member1/lastSelectedFeederId').set(feederId);
    const { inviteId } = await owner.call('createInvite', { feederId });
    const codeHash = await val(`invitations/${inviteId}/codeHash`);
    await owner.call('archiveFeeder', { feederId });

    expect(await codeOf(member.call('deleteFeederPermanently', { feederId, confirmName: 'Coop A' }))).toBe('functions/permission-denied');
    expect(await owner.call('deleteFeederPermanently', { feederId, confirmName: 'Coop A' })).toEqual({ ok: true });

    expect(await val(`feeders/${feederId}`)).toBeNull();
    expect(await val(`userFeeders/owner1/${feederId}`)).toBeNull();
    expect(await val(`userFeeders/member1/${feederId}`)).toBeNull();
    expect(await val('users/member1/lastSelectedFeederId')).toBeNull();
    expect(await val('users/member1/displayName')).toBe('member1'); // profile untouched
    expect(await val(`invitations/${inviteId}`)).toBeNull();
    expect(await val(`inviteCodes/${codeHash}`)).toBeNull();
    expect(await val(`deviceRegistry/${feederId}`)).toMatchObject({ status: 'deleted', ownerUid: 'owner1', deletedBy: 'owner1' });
    const deleted = Object.values(await val('platformAudit')).find((e) => e.action === 'feeder_deleted');
    expect(deleted).toMatchObject({ actorUid: 'owner1', feederId, memberCount: 2 });

    // The slot is free again.
    expect(await codeOf(owner.call('createVirtualFeeder', { name: 'New', timezone: 'UTC', requestId: requestId() }))).toBe('ok');
  });
});

describe('invitations', () => {
  test('only the owner can create one; the code is shown once and never stored', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    expect(await codeOf(member.call('createInvite', { feederId }))).toBe('functions/permission-denied');

    const res = await owner.call('createInvite', { feederId });
    expect(res.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/);
    const hours = (res.expiresAt - Date.now()) / 3600_000;
    expect(hours).toBeGreaterThan(71.9);
    expect(hours).toBeLessThanOrEqual(72);
    const dump = JSON.stringify((await db.ref().get()).val());
    expect(dump).not.toContain(res.code.replace('-', ''));
    expect(dump).not.toContain(res.code);

    const summary = (await get(ref(owner.db, `feeders/${feederId}/invites/${res.inviteId}`))).val();
    expect(summary).toMatchObject({ status: 'open', createdBy: 'owner1', permissions: { viewDashboard: true } });
    expect(summary.codeHash).toBeUndefined();
  });

  test('validates expiry and caps open invitations per feeder', async () => {
    await db.ref('platformConfig/limits/openInvitesPerFeeder').set(2);
    const { owner, feederId } = await ownerWithFeeder();
    for (const expiresInHours of [0, 169, 1.5, '24']) {
      expect(await codeOf(owner.call('createInvite', { feederId, expiresInHours }))).toBe('functions/invalid-argument');
    }
    await owner.call('createInvite', { feederId, expiresInHours: 1 });
    const { inviteId } = await owner.call('createInvite', { feederId });
    expect(await codeOf(owner.call('createInvite', { feederId }))).toBe('functions/resource-exhausted');
    await owner.call('revokeInvite', { feederId, inviteId });
    expect(await codeOf(owner.call('createInvite', { feederId }))).toBe('ok');
  });

  test('accepting grants viewDashboard only and links the feeder', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('member1', { name: 'Helper' });
    const member = await signIn('member1');
    const { code, inviteId } = await owner.call('createInvite', { feederId });
    const typed = code.toLowerCase().replace('-', ' ');
    expect(await member.call('acceptInvite', { code: typed, requestId: requestId() })).toEqual({ feederId, role: 'member' });

    const m = await val(`feeders/${feederId}/members/member1`);
    expect(m).toMatchObject({ role: 'member', status: 'active', addedBy: 'owner1', inviteId, displayName: 'Helper' });
    expect(m.permissions).toEqual(Object.fromEntries(ALL_PERMS.map((p) => [p, p === 'viewDashboard'])));
    expect(await val(`userFeeders/member1/${feederId}`)).toMatchObject({ role: 'member' });
    expect(await val(`invitations/${inviteId}`)).toMatchObject({ status: 'accepted', acceptedBy: 'member1' });
    expect(await val(`feeders/${feederId}/invites/${inviteId}`)).toMatchObject({ status: 'accepted', acceptedBy: 'member1' });
    expect(await val(`feeders/${feederId}/audit/joined_${inviteId}`)).toMatchObject({ action: 'member_joined', actorUid: 'member1' });

    // Through the rules: may read meta and status, may NOT read history, schedule or feed.
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/meta`)))).toBe('ok');
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/status`)))).toBe('ok');
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/history`)))).toBe('denied');
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/members`)))).toBe('denied');
    expect(await rulesCode(set(ref(member.db, `feeders/${feederId}/config/schedulesPaused`), true))).toBe('denied');
  });

  test('a code works once: concurrent acceptance has exactly one winner', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('u1');
    await createUser('u2');
    const [u1, u2] = await Promise.all([signIn('u1'), signIn('u2')]);
    const { code } = await owner.call('createInvite', { feederId });
    const results = await Promise.all([
      codeOf(u1.call('acceptInvite', { code, requestId: requestId() })),
      codeOf(u2.call('acceptInvite', { code, requestId: requestId() })),
    ]);
    expect(results.sort()).toEqual(['functions/failed-precondition', 'ok']);
    const members = Object.keys(await val(`feeders/${feederId}/members`));
    expect(members).toHaveLength(2); // owner + one winner
  });

  test('the same user retrying is idempotent', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('u1');
    const u1 = await signIn('u1');
    const { code } = await owner.call('createInvite', { feederId });
    const rid = requestId();
    expect(await u1.call('acceptInvite', { code, requestId: rid })).toEqual({ feederId, role: 'member' });
    expect(await u1.call('acceptInvite', { code, requestId: rid })).toEqual({ feederId, role: 'member' });
    const joined = Object.values(await val(`feeders/${feederId}/audit`)).filter((e) => e.action === 'member_joined');
    expect(joined).toHaveLength(1);
  });

  test('a removed or departed member cannot rejoin with their used code', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    for (const leave of [
      () => owner.call('removeMember', { feederId, memberUid: 'u1' }),
      (u) => u.call('leaveFeeder', { feederId }),
    ]) {
      await db.ref('rateLimits').remove();
      if (!(await auth.getUser('u1').catch(() => null))) await createUser('u1');
      const u1 = await signIn('u1');
      const { code } = await owner.call('createInvite', { feederId });
      const rid = requestId();
      await u1.call('acceptInvite', { code, requestId: rid });
      await leave(u1);
      expect(await codeOf(u1.call('acceptInvite', { code, requestId: rid }))).toBe('functions/failed-precondition');
      expect(await codeOf(u1.call('acceptInvite', { code, requestId: requestId() }))).toBe('functions/failed-precondition');
      expect((await val(`feeders/${feederId}/members/u1`)).status).not.toBe('active');
      expect(await val(`userFeeders/u1/${feederId}`)).toBeNull();
    }
  });

  test('no self-invite, no duplicate membership, no permission downgrade', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const { code: own } = await owner.call('createInvite', { feederId });
    expect(await codeOf(owner.call('acceptInvite', { code: own, requestId: requestId() }))).toBe('functions/failed-precondition');

    const member = await join(owner, feederId, 'member1');
    await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewDashboard: true, manualFeed: true } });
    const { code, inviteId } = await owner.call('createInvite', { feederId });
    expect(await codeOf(member.call('acceptInvite', { code, requestId: requestId() }))).toBe('functions/already-exists');
    expect(await val(`feeders/${feederId}/members/member1/permissions/manualFeed`)).toBe(true);
    expect(await val(`invitations/${inviteId}/status`)).toBe('open');
  });

  test('expired and revoked invitations are refused', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('u1');
    const u1 = await signIn('u1');

    const a = await owner.call('createInvite', { feederId });
    await db.ref(`invitations/${a.inviteId}/expiresAt`).set(Date.now() - 1000);
    expect(await codeOf(u1.call('acceptInvite', { code: a.code, requestId: requestId() }))).toBe('functions/deadline-exceeded');
    expect(await val(`invitations/${a.inviteId}/status`)).toBe('expired');
    expect(await val(`feeders/${feederId}/invites/${a.inviteId}/status`)).toBe('expired');

    const b = await owner.call('createInvite', { feederId });
    expect(await codeOf(u1.call('revokeInvite', { feederId, inviteId: b.inviteId }))).toBe('functions/permission-denied');
    expect(await owner.call('revokeInvite', { feederId, inviteId: b.inviteId })).toEqual({ ok: true });
    expect(await owner.call('revokeInvite', { feederId, inviteId: b.inviteId })).toEqual({ ok: true }); // idempotent
    expect(await codeOf(u1.call('acceptInvite', { code: b.code, requestId: requestId() }))).toBe('functions/failed-precondition');
    expect(await val(`feeders/${feederId}/members/u1`)).toBeNull();
  });

  test('guessing is rate-limited per account, and the counter persists', async () => {
    await db.ref('platformConfig/limits/inviteAttemptsPerWindow').set(3);
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('guesser');
    const g = await signIn('guesser');
    const { code } = await owner.call('createInvite', { feederId });

    expect(await codeOf(g.call('acceptInvite', { code: 'AAAAA-AAAAA', requestId: requestId() }))).toBe('functions/not-found');
    expect(await codeOf(g.call('acceptInvite', { code: 'BBBBB-BBBBB', requestId: requestId() }))).toBe('functions/not-found');
    expect(await codeOf(g.call('acceptInvite', { code: 'not-a-code!', requestId: requestId() }))).toBe('functions/invalid-argument');
    // Locked now, even with the right code.
    expect(await codeOf(g.call('acceptInvite', { code, requestId: requestId() }))).toBe('functions/resource-exhausted');
    expect(await val('rateLimits/acceptInvite/guesser')).toMatchObject({ count: 3 });
    expect(await val(`feeders/${feederId}/members/guesser`)).toBeNull();

    // Once the window has passed, the right code works.
    await db.ref('rateLimits/acceptInvite/guesser/windowStart').set(Date.now() - 16 * 60_000);
    expect(await codeOf(g.call('acceptInvite', { code, requestId: requestId() }))).toBe('ok');
  });
});

describe('member management', () => {
  test('owner grants permissions (whitelisted booleans) and they take effect in the rules', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    const sched = { time: '07:00', weekdays: { 1: true }, amountG: 50, enabled: true, createdAt: { '.sv': 'timestamp' }, updatedAt: { '.sv': 'timestamp' }, updatedBy: 'member1' };
    expect(await rulesCode(set(ref(member.db, `feeders/${feederId}/schedules/s1`), sched))).toBe('denied');

    const bad = [{ admin: true }, { manualFeed: 'yes' }, ['viewDashboard'], null];
    for (const permissions of bad) {
      expect(await codeOf(owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions }))).toBe('functions/invalid-argument');
    }
    const res = await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewDashboard: true, manageSchedules: true } });
    expect(res.permissions).toEqual(Object.fromEntries(ALL_PERMS.map((p) => [p, ['viewDashboard', 'manageSchedules'].includes(p)])));
    expect(await rulesCode(set(ref(member.db, `feeders/${feederId}/schedules/s1`), sched))).toBe('ok');

    const entry = Object.values(await val(`feeders/${feederId}/audit`)).find((e) => e.action === 'member_permissions_updated');
    expect(entry).toMatchObject({ actorUid: 'owner1', targetUid: 'member1', before: { viewDashboard: true }, after: { manageSchedules: true } });

    // Revoking takes effect immediately.
    await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewDashboard: true } });
    expect(await rulesCode(remove(ref(member.db, `feeders/${feederId}/schedules/s1`)))).toBe('denied');
  });

  test('members, outsiders and admins cannot change permissions; the owner record is protected', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    await createUser('admin1', { admin: true });
    const admin = await signIn('admin1');
    const grant = { feederId, memberUid: 'member1', permissions: { manualFeed: true } };
    expect(await codeOf(member.call('updateMemberPermissions', grant))).toBe('functions/permission-denied');
    expect(await codeOf(admin.call('updateMemberPermissions', grant))).toBe('functions/permission-denied');
    expect(await codeOf(owner.call('updateMemberPermissions', { ...grant, memberUid: 'owner1' }))).toBe('functions/failed-precondition');
    expect(await codeOf(owner.call('updateMemberPermissions', { ...grant, memberUid: 'nobody' }))).toBe('functions/not-found');
    expect(await codeOf(owner.call('removeMember', { feederId, memberUid: 'owner1' }))).toBe('functions/failed-precondition');
    expect(await val(`feeders/${feederId}/members/member1/permissions/manualFeed`)).toBe(false);
  });

  test('a suspended owner cannot manage the feeder', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await join(owner, feederId, 'member1');
    await db.ref('accountStatus/owner1/suspended').set(true);
    expect(await codeOf(owner.call('removeMember', { feederId, memberUid: 'member1' }))).toBe('functions/permission-denied');
    expect(await codeOf(owner.call('createInvite', { feederId }))).toBe('functions/permission-denied');
  });

  test('removing a member ends their access immediately', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    await db.ref('users/member1/lastSelectedFeederId').set(feederId);
    expect(await codeOf(member.call('removeMember', { feederId, memberUid: 'member1' }))).toBe('functions/permission-denied');

    expect(await owner.call('removeMember', { feederId, memberUid: 'member1' })).toEqual({ ok: true });
    const marker = await val(`feeders/${feederId}/members/member1`);
    expect(marker).toMatchObject({ role: 'member', status: 'removed', endedBy: 'owner1', displayName: 'member1' });
    expect(marker.permissions).toBeUndefined();
    expect(await val(`userFeeders/member1/${feederId}`)).toBeNull();
    expect(await val('users/member1/lastSelectedFeederId')).toBeNull();
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/meta`)))).toBe('denied');
    const entry = Object.values(await val(`feeders/${feederId}/audit`)).find((e) => e.action === 'member_removed');
    expect(entry).toMatchObject({ actorUid: 'owner1', targetUid: 'member1' });
  });

  test('a member can leave; the owner cannot', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    expect(await codeOf(owner.call('leaveFeeder', { feederId }))).toBe('functions/failed-precondition');
    expect(await member.call('leaveFeeder', { feederId })).toEqual({ ok: true });
    expect(await val(`feeders/${feederId}/members/member1`)).toMatchObject({ status: 'left', endedBy: 'member1' });
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/meta`)))).toBe('denied');
    expect(await val(`userFeeders/member1/${feederId}`)).toBeNull();
    expect(await codeOf(member.call('leaveFeeder', { feederId }))).toBe('functions/not-found');
  });

  test('one owner cannot touch another owner’s feeder', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('owner2');
    const o2 = await signIn('owner2');
    const mine = await o2.call('createVirtualFeeder', { name: 'Mine', timezone: 'UTC', requestId: requestId() });
    for (const [fn, data] of [
      ['archiveFeeder', { feederId }],
      ['createInvite', { feederId }],
      ['removeMember', { feederId, memberUid: 'owner1' }],
      ['updateMemberPermissions', { feederId, memberUid: 'owner1', permissions: {} }],
    ]) {
      expect(await codeOf(o2.call(fn, data))).toBe('functions/permission-denied');
    }
    expect(await rulesCode(get(ref(owner.db, `feeders/${mine.feederId}/meta`)))).toBe('denied');
    expect(await rulesCode(get(ref(o2.db, `feeders/${feederId}/meta`)))).toBe('denied');
  });
});
