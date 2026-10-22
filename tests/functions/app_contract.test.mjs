// Phase 2B: the Flutter app's feeder-selection data contract, checked
// against the real emulators. FirebaseFeederDataSource
// (lib/services/feeder_selection.dart) opens exactly these listeners:
//   userFeeders/{uid}, feeders/{id}/meta, feeders/{id}/members/{uid}
// and writes users/{uid}/lastSelectedFeederId. The Flutter widget tests use
// a fake of this source; this file proves the real paths, rules and
// functions behave the way that fake assumes.
import { onValue, ref, set } from 'firebase/database';
import { describe, expect, test } from 'vitest';
import { createUser, db, join, ownerWithFeeder, requestId, rulesCode, signIn, TZ, useCleanEmulators } from './helpers.mjs';

useCleanEmulators();

/**
 * Opens an onValue listener like the app does and records every value and
 * the cancellation (the rules denying the listener).
 */
function listen(cdb, path) {
  const values = [];
  let denied = null;
  let wake = () => {};
  const unsubscribe = onValue(
    ref(cdb, path),
    (snap) => {
      values.push(snap.val());
      wake();
    },
    (err) => {
      denied = err;
      wake();
    },
  );
  /** Waits until `pred(values, denied)` holds (or 10 s pass). */
  const until = (pred) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout waiting on ${path}: ${JSON.stringify(values)}`)), 10000);
      const check = () => {
        if (pred(values, denied)) {
          clearTimeout(timer);
          resolve();
        }
      };
      wake = check;
      check();
    });
  return { values, get denied() { return denied; }, until, unsubscribe, last: () => values[values.length - 1] };
}

describe('the app creates and lists feeders through the real backend', () => {
  test('createVirtualFeeder returns dynamic IDs that appear live in userFeeders/{uid}', async () => {
    await createUser('owner1', { name: 'Owner One' });
    const owner = await signIn('owner1');
    const index = listen(owner.db, 'userFeeders/owner1');
    await index.until((v) => v.length >= 1); // empty index first, like the app

    const a = await owner.call('createVirtualFeeder', { name: 'Alpha', timezone: TZ, requestId: requestId() });
    const b = await owner.call('createVirtualFeeder', { name: 'Bravo', timezone: 'UTC', requestId: requestId() });
    for (const { feederId } of [a, b]) expect(feederId).toMatch(/^fd_[0-9A-Za-z]{20}$/);
    expect(a.feederId).not.toBe(b.feederId);

    await index.until((v) => Object.keys(v.at(-1) ?? {}).length === 2);
    expect(index.last()).toMatchObject({ [a.feederId]: { role: 'owner' }, [b.feederId]: { role: 'owner' } });

    // What the app reads for each feeder.
    const meta = listen(owner.db, `feeders/${a.feederId}/meta`);
    const me = listen(owner.db, `feeders/${a.feederId}/members/owner1`);
    await meta.until((v) => v.length > 0);
    await me.until((v) => v.length > 0);
    expect(meta.last()).toMatchObject({ name: 'Alpha', ownerUid: 'owner1', mode: 'simulated' });
    expect(me.last()).toMatchObject({ role: 'owner', status: 'active' });
    [index, meta, me].forEach((l) => l.unsubscribe());
  });

  test('the remembered selection accepts only the user’s own feeders', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await createUser('owner2');
    const o2 = await signIn('owner2');
    const other = await o2.call('createVirtualFeeder', { name: 'Other', timezone: 'UTC', requestId: requestId() });

    expect(await rulesCode(set(ref(owner.db, 'users/owner1/lastSelectedFeederId'), feederId))).toBe('ok');
    expect(await rulesCode(set(ref(owner.db, 'users/owner1/lastSelectedFeederId'), other.feederId))).toBe('denied');
    expect(await rulesCode(set(ref(owner.db, 'users/owner1/lastSelectedFeederId'), 'feeder1'))).toBe('denied');
  });
});

describe('isolation between users', () => {
  test('another owner, an outsider and the admin are refused every listener the app opens', async () => {
    const { feederId } = await ownerWithFeeder();
    await createUser('owner2');
    await createUser('admin1', { admin: true });
    for (const key of ['owner2', 'admin1']) {
      const u = await signIn(key);
      for (const path of [`feeders/${feederId}/meta`, `feeders/${feederId}/members/owner1`, 'userFeeders/owner1']) {
        const l = listen(u.db, path);
        await l.until((_, denied) => denied !== null);
        expect(l.values).toEqual([]);
        expect(l.denied.message).toMatch(/permission/i);
      }
    }
  });
});

describe('access lost while the app is open', () => {
  test('removal: the member record turns into a marker, meta is denied, the index entry goes', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    const index = listen(member.db, 'userFeeders/member1');
    const meta = listen(member.db, `feeders/${feederId}/meta`);
    const me = listen(member.db, `feeders/${feederId}/members/member1`);
    await Promise.all([index, meta, me].map((l) => l.until((v) => v.length > 0)));
    expect(me.last()).toMatchObject({ status: 'active', permissions: { viewDashboard: true, manualFeed: false } });

    await owner.call('removeMember', { feederId, memberUid: 'member1' });

    await meta.until((_, denied) => denied !== null);
    await me.until((v) => v.at(-1)?.status === 'removed');
    await index.until((v) => !(feederId in (v.at(-1) ?? {})));
    expect(me.last().permissions).toBeUndefined();
    expect(await rulesCode(set(ref(member.db, 'users/member1/lastSelectedFeederId'), feederId))).toBe('denied');
    [index, me].forEach((l) => l.unsubscribe());
  });

  test('permission changes and archiving reach open listeners', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const member = await join(owner, feederId, 'member1');
    const meta = listen(member.db, `feeders/${feederId}/meta`);
    const me = listen(member.db, `feeders/${feederId}/members/member1`);
    await Promise.all([meta, me].map((l) => l.until((v) => v.length > 0)));

    await owner.call('updateMemberPermissions', { feederId, memberUid: 'member1', permissions: { viewDashboard: true, viewHistory: true } });
    await me.until((v) => v.at(-1)?.permissions?.viewHistory === true);

    await owner.call('archiveFeeder', { feederId });
    await meta.until((v) => typeof v.at(-1)?.archivedAt === 'number');
    expect(meta.denied).toBeNull(); // still readable, read-only
    [meta, me].forEach((l) => l.unsubscribe());
  });

  test('permanent deletion: the owner’s listeners lose the feeder', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const index = listen(owner.db, 'userFeeders/owner1');
    const meta = listen(owner.db, `feeders/${feederId}/meta`);
    await Promise.all([index, meta].map((l) => l.until((v) => v.length > 0)));
    await owner.call('archiveFeeder', { feederId });
    await owner.call('deleteFeederPermanently', { feederId, confirmName: 'Coop A' });
    await index.until((v) => !(feederId in (v.at(-1) ?? {})));
    await meta.until((v, denied) => denied !== null || v.at(-1) === null);
    expect((await db.ref(`feeders/${feederId}`).get()).exists()).toBe(false);
    [index, meta].forEach((l) => l.unsubscribe());
  });
});
