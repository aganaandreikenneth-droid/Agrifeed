// Phase 2A: an owner's membership revocation can never be undone by a
// retried, interrupted or concurrent invitation acceptance. Kept in its own
// file so it runs in a fresh emulator session (see package.json test:functions).
import { get, ref } from 'firebase/database';
import { describe, expect, test } from 'vitest';
import {
  ALL_PERMS, codeOf, createUser, db, join, ownerWithFeeder, requestId, rulesCode, signIn, useCleanEmulators, val,
} from './helpers.mjs';

useCleanEmulators();

describe('membership revocation cannot be undone by invitation retries', () => {
  /**
   * Leaves the database exactly as acceptInvite does when it is interrupted
   * after creating the membership (step 3) and before finalizing (step 4).
   */
  async function interruptedJoin(owner, feederId, key) {
    await createUser(key, { name: key });
    const user = await signIn(key);
    const { code, inviteId } = await owner.call('createInvite', { feederId });
    const rid = requestId();
    const now = Date.now();
    await db.ref().update({
      [`invitations/${inviteId}/status`]: 'accepted',
      [`invitations/${inviteId}/acceptedBy`]: key,
      [`invitations/${inviteId}/acceptedAt`]: now,
      [`invitations/${inviteId}/acceptRequestId`]: rid,
      [`feeders/${feederId}/members/${key}`]: {
        role: 'member', status: 'active', addedAt: now, addedBy: 'owner1', inviteId,
        permissions: Object.fromEntries(ALL_PERMS.map((p) => [p, p === 'viewDashboard'])),
      },
    });
    return { user, code, rid, inviteId };
  }

  /** The user has no access left: marker only, no index, rules deny. */
  async function expectRevoked(user, feederId, key) {
    const m = await val(`feeders/${feederId}/members/${key}`);
    expect(m.status).toBe('removed');
    expect(m.permissions).toBeUndefined();
    expect(await val(`userFeeders/${key}/${feederId}`)).toBeNull();
    expect(await rulesCode(get(ref(user.db, `feeders/${feederId}/meta`)))).toBe('denied');
    expect(await rulesCode(get(ref(user.db, `feeders/${feederId}/status`)))).toBe('denied');
  }

  test('an interrupted acceptance is completed by its retry when nothing intervened', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const { user, code, rid, inviteId } = await interruptedJoin(owner, feederId, 'u1');
    expect(await user.call('acceptInvite', { code, requestId: rid })).toEqual({ feederId, role: 'member' });
    expect(await val(`userFeeders/u1/${feederId}`)).toMatchObject({ role: 'member' });
    expect(typeof (await val(`invitations/${inviteId}/finalizedAt`))).toBe('number');
  });

  test('removal during an interrupted acceptance: the retry does not re-add the member', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const { user, code, rid, inviteId } = await interruptedJoin(owner, feederId, 'u1');
    expect(await owner.call('removeMember', { feederId, memberUid: 'u1' })).toEqual({ ok: true });

    expect(await codeOf(user.call('acceptInvite', { code, requestId: rid }))).toBe('functions/failed-precondition');
    expect(await codeOf(user.call('acceptInvite', { code, requestId: requestId() }))).toBe('functions/failed-precondition');
    await expectRevoked(user, feederId, 'u1');
    expect(await val(`invitations/${inviteId}/status`)).toBe('accepted'); // still single-use
  });

  test('removal racing the retry of an interrupted acceptance always ends revoked', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    for (let round = 0; round < 5; round++) {
      const key = `racer${round}`;
      const { user, code, rid } = await interruptedJoin(owner, feederId, key);
      const [removed] = await Promise.all([
        codeOf(owner.call('removeMember', { feederId, memberUid: key })),
        codeOf(user.call('acceptInvite', { code, requestId: rid })),
      ]);
      expect(removed).toBe('ok');
      await expectRevoked(user, feederId, key);
      expect(await codeOf(user.call('acceptInvite', { code, requestId: rid }))).toBe('functions/failed-precondition');
      await expectRevoked(user, feederId, key);
    }
  });

  test('removal racing a retry of a completed acceptance always ends revoked', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    for (let round = 0; round < 3; round++) {
      const key = `joined${round}`;
      await createUser(key);
      const user = await signIn(key);
      const { code } = await owner.call('createInvite', { feederId });
      const rid = requestId();
      await user.call('acceptInvite', { code, requestId: rid });
      await Promise.all([
        codeOf(owner.call('removeMember', { feederId, memberUid: key })),
        codeOf(user.call('acceptInvite', { code, requestId: rid })),
      ]);
      await expectRevoked(user, feederId, key);
    }
  });

  test('only a NEW invitation re-admits a removed user, with default permissions', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewDashboard: true, manualFeed: true } });
    await owner.call('removeMember', { feederId, memberUid: 'member1' });

    expect(await codeOf(owner.call('removeMember', { feederId, memberUid: 'member1' }))).toBe('functions/not-found');
    expect(await codeOf(owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { manualFeed: true } })))
      .toBe('functions/not-found');
    expect(await codeOf(member.call('leaveFeeder', { feederId }))).toBe('functions/not-found');

    const { code } = await owner.call('createInvite', { feederId });
    expect(await member.call('acceptInvite', { code, requestId: requestId() })).toEqual({ feederId, role: 'member' });
    const m = await val(`feeders/${feederId}/members/member1`);
    expect(m.status).toBe('active');
    expect(m.permissions).toEqual(Object.fromEntries(ALL_PERMS.map((p) => [p, p === 'viewDashboard'])));
    expect(await rulesCode(get(ref(member.db, `feeders/${feederId}/meta`)))).toBe('ok');
  });

  test('membership changes are audited separately from feeding history', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await join(owner, feederId, 'member1');
    await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewHistory: true } });
    await owner.call('removeMember', { feederId, memberUid: 'member1' });
    const actions = Object.values(await val(`feeders/${feederId}/audit`)).map((e) => e.action);
    expect(actions).toEqual(expect.arrayContaining(['invite_created', 'member_joined', 'member_permissions_updated', 'member_removed']));
    expect(await val(`feeders/${feederId}/history`)).toBeNull(); // feeding history untouched
  });

  test('permanent deletion leaves no membership, index or reference behind', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await join(owner, feederId, 'active1');
    await join(owner, feederId, 'removed1');
    await owner.call('removeMember', { feederId, memberUid: 'removed1' });
    const { user: half } = await interruptedJoin(owner, feederId, 'half1');
    await db.ref('users/active1/lastSelectedFeederId').set(feederId);
    await owner.call('archiveFeeder', { feederId });
    await owner.call('deleteFeederPermanently', { feederId, confirmName: 'Coop A' });

    const root = (await db.ref().get()).val();
    expect(JSON.stringify(root.feeders ?? {})).not.toContain(feederId);
    expect(JSON.stringify(root.userFeeders ?? {})).not.toContain(feederId);
    expect(JSON.stringify(root.users ?? {})).not.toContain(feederId);
    expect(JSON.stringify(root.invitations ?? {})).not.toContain(feederId);
    expect(JSON.stringify(root.userQuotas ?? {})).not.toContain(feederId);
    expect(root.deviceRegistry[feederId].status).toBe('deleted');
    const deleted = Object.values(root.platformAudit).find((e) => e.action === 'feeder_deleted');
    expect(deleted.memberCount).toBe(3); // owner, active1, half1 (not the removed one)
    expect(await rulesCode(get(ref(half.db, `feeders/${feederId}/meta`)))).toBe('denied');
  });
});
