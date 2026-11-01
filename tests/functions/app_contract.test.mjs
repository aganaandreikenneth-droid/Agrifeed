// Phase 2B: the Flutter app's feeder-selection data contract, checked
// against the real emulators. FirebaseFeederDataSource
// (lib/services/feeder_selection.dart) opens exactly these listeners:
//   userFeeders/{uid}, feeders/{id}/meta, feeders/{id}/members/{uid}
// and writes users/{uid}/lastSelectedFeederId. Milestone 1 adds
// FirebaseFeederRepository (lib/services/feeder_repository.dart): the
// feeders/{id}/alerts listener and the owner writes to meta/name and
// meta/timezone. The Flutter widget tests use
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

describe('Milestone 1: Settings writes and the alerts bell', () => {
  test('single feeder: a new account has none, and cannot assign itself one (not even another owner’s)', async () => {
    const { feederId } = await ownerWithFeeder();
    await createUser('newcomer');
    const u = await signIn('newcomer');
    const index = listen(u.db, 'userFeeders/newcomer');
    await index.until((v) => v.length > 0);
    expect(index.last()).toBeNull(); // the app shows "No AgriFeed machine is assigned"

    const now = Date.now();
    expect(await rulesCode(set(ref(u.db, `userFeeders/newcomer/${feederId}`), { role: 'owner', addedAt: now }))).toBe('denied');
    expect(await rulesCode(set(ref(u.db, `feeders/${feederId}/members/newcomer`), { role: 'owner', status: 'active', addedAt: now }))).toBe('denied');
    expect(await rulesCode(set(ref(u.db, `deviceRegistry/${feederId}/ownerUid`), 'newcomer'))).toBe('denied');
    expect(await rulesCode(set(ref(u.db, 'users/newcomer/lastSelectedFeederId'), feederId))).toBe('denied');
    expect((await db.ref('userFeeders/newcomer').get()).exists()).toBe(false);
    index.unsubscribe();
  });

  test('the owner renames the feeder and changes its time zone; open listeners see it', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const meta = listen(owner.db, `feeders/${feederId}/meta`);
    await meta.until((v) => v.length > 0);

    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'North coop'))).toBe('ok');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/timezone`), 'UTC'))).toBe('ok');
    await meta.until((v) => v.at(-1)?.name === 'North coop' && v.at(-1)?.timezone === 'UTC');

    // Invalid values are refused by the rules, not only by the app.
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), ''))).toBe('denied');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'x'.repeat(41)))).toBe('denied');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/timezone`), 'Not a zone!'))).toBe('denied');
    // Backend-only meta fields stay closed.
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/ownerUid`), 'owner1'))).toBe('denied');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/mode`), 'live'))).toBe('denied');
    meta.unsubscribe();
  });

  test('another owner cannot change, archive or delete the feeder, nor read its alerts', async () => {
    const { feederId } = await ownerWithFeeder();
    await createUser('owner2');
    const o2 = await signIn('owner2');
    expect(await rulesCode(set(ref(o2.db, `feeders/${feederId}/meta/name`), 'Mine now'))).toBe('denied');
    expect(await rulesCode(set(ref(o2.db, `feeders/${feederId}/meta/timezone`), 'UTC'))).toBe('denied');
    for (const [fn, data] of [
      ['archiveFeeder', { feederId }],
      ['restoreFeeder', { feederId }],
      ['deleteFeederPermanently', { feederId, confirmName: 'Coop A' }],
    ]) {
      await expect(o2.call(fn, data), fn).rejects.toMatchObject({ code: 'functions/permission-denied' });
    }
    const alerts = listen(o2.db, `feeders/${feederId}/alerts`);
    await alerts.until((_, denied) => denied !== null);
    expect(alerts.values).toEqual([]);
    expect((await db.ref(`feeders/${feederId}/meta/name`).get()).val()).toBe('Coop A');
  });

  test('archived: read-only for the owner until restored', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    await owner.call('archiveFeeder', { feederId });
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'Renamed'))).toBe('denied');
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/timezone`), 'UTC'))).toBe('denied');
    await owner.call('restoreFeeder', { feederId });
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/meta/name`), 'Renamed'))).toBe('ok');
  });

  test('the owner’s alerts listener: empty for a new feeder, then live device alerts', async () => {
    const { owner, feederId } = await ownerWithFeeder();
    const alerts = listen(owner.db, `feeders/${feederId}/alerts`);
    await alerts.until((v) => v.length > 0);
    expect(alerts.last()).toBeNull(); // the bell's "No alerts" state
    // Only a device may write alerts; the app cannot invent one.
    const fake = { type: 'low_feed', severity: 'warning', state: 'active', firstAt: Date.now(), lastAt: Date.now(), source: 'simulator' };
    expect(await rulesCode(set(ref(owner.db, `feeders/${feederId}/alerts/a1`), fake))).toBe('denied');
    // Written here with the Admin SDK, standing in for the simulator (Milestone 2).
    await db.ref(`feeders/${feederId}/alerts/low_feed`).set(fake);
    await alerts.until((v) => v.at(-1)?.low_feed?.state === 'active');
    alerts.unsubscribe();
  });

});
