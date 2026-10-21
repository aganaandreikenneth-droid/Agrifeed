import { describe, test } from 'vitest';
import { F, NOW, arrange, as, assertFails, assertSucceeds, devF, useRulesEnv } from './fixture.mjs';

useRulesEnv();

describe('identity gates', () => {
  test('signed-out: no reads or writes anywhere', async () => {
    const db = as.anon();
    await assertFails(db.ref('users/owner1').get());
    await assertFails(db.ref(`feeders/${F}/meta`).get());
    await assertFails(db.ref('users/anon').set({ displayName: 'x', createdAt: NOW }));
    await assertFails(db.ref().get());
  });

  test('unverified email: denied even for own profile and own feeder', async () => {
    const db = as.unverified('owner1');
    await assertFails(db.ref('users/owner1').get());
    await assertFails(db.ref('users/newbie').set({ displayName: 'x', createdAt: NOW }));
    await assertFails(db.ref(`feeders/${F}/meta`).get());
    await assertFails(db.ref('userFeeders/owner1').get());
  });

  test('suspended: denied on feeder and profile, but can read own status', async () => {
    const db = as.user('suspended1');
    await assertFails(db.ref(`feeders/${F}/status`).get());
    await assertFails(db.ref('users/suspended1').set({ displayName: 'x', createdAt: NOW }));
    await assertSucceeds(db.ref('accountStatus/suspended1').get());
    await assertFails(db.ref('accountStatus/owner1').get());
  });

  test('verified active user reads own profile only', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref('users/owner1').get());
    await assertFails(db.ref('users/viewer1').get());
    await assertFails(db.ref('users').get());
  });

  test('a device token is never treated as a person', async () => {
    const db = devF();
    await assertFails(db.ref('users/dev_F').set({ displayName: 'x', createdAt: NOW }));
    await assertFails(db.ref('userFeeders/dev_F').get());
    await assertFails(db.ref(`feeders/${F}/members`).get());
  });
});

describe('profile creation and editing', () => {
  test('new verified user can create their profile once', async () => {
    const db = as.user('newbie');
    await assertSucceeds(db.ref('users/newbie').set({ displayName: 'New', createdAt: NOW }));
    await assertFails(db.ref('users/newbie').set({ displayName: 'Again', createdAt: NOW }));
  });

  test('profile cannot carry roles, unknown fields or a fake timestamp', async () => {
    const db = as.user('newbie');
    await assertFails(db.ref('users/newbie').set({ displayName: 'x', createdAt: NOW, role: 'admin' }));
    await assertFails(db.ref('users/newbie').set({ displayName: 'x', createdAt: NOW, admin: true }));
    await assertFails(db.ref('users/newbie').set({ displayName: 'x', createdAt: 12345 }));
    await assertFails(db.ref('users/newbie').set({ createdAt: NOW }));
    await assertFails(db.ref('users/newbie').set({ displayName: '', createdAt: NOW }));
  });

  test("cannot create or edit another user's profile", async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('users/someoneelse').set({ displayName: 'x', createdAt: NOW }));
    await assertFails(db.ref('users/viewer1/displayName').set('Hacked'));
  });

  test('display name edits are validated', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref('users/owner1/displayName').set('Farm Owner'));
    await assertFails(db.ref('users/owner1/displayName').set(''));
    await assertFails(db.ref('users/owner1/displayName').set('x'.repeat(61)));
    await assertFails(db.ref('users/owner1/displayName').set(42));
  });

  test('profile and its fields cannot be deleted; createdAt is immutable', async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('users/owner1').remove());
    await assertFails(db.ref('users/owner1/displayName').remove());
    await assertFails(db.ref('users/owner1/createdAt').set(5));
    await assertFails(db.ref('users/owner1/role').set('admin'));
  });

  test('last selected feeder must be one of the user’s feeders', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref('users/owner1/lastSelectedFeederId').set(F));
    await assertFails(db.ref('users/owner1/lastSelectedFeederId').set('fd_notmine'));
  });

  test('an administrator can list profiles (no feeder data)', async () => {
    await assertSucceeds(as.admin().ref('users').get());
  });

  test('suspension check uses live status (reactivation restores access)', async () => {
    await arrange((db) => db.ref('accountStatus/suspended1/suspended').set(false));
    await assertSucceeds(as.user('suspended1').ref(`feeders/${F}/status`).get());
  });
});
