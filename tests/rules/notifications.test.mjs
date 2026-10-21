import { describe, test } from 'vitest';
import { NOW, as, assertFails, assertSucceeds, useRulesEnv } from './fixture.mjs';

useRulesEnv();

describe('notifications', () => {
  test('users read only their own notifications', async () => {
    await assertSucceeds(as.user('viewer1').ref('notifications/viewer1').get());
    await assertFails(as.user('owner1').ref('notifications/viewer1').get());
  });

  test('users can mark read and dismiss, nothing else', async () => {
    const db = as.user('viewer1');
    await assertSucceeds(db.ref('notifications/viewer1/n1/read').set(true));
    await assertFails(db.ref('notifications/viewer1/n1/read').set('yes'));
    await assertFails(db.ref('notifications/viewer1/n1/title').set('Changed'));
    await assertFails(db.ref('notifications/viewer1/n2').set({ type: 'x', title: 'Fake', ts: NOW }));
    await assertFails(db.ref('notifications/viewer1/ghost/read').set(true)); // no such notification
    await assertSucceeds(db.ref('notifications/viewer1/n1').remove());
  });

  test("users cannot touch someone else's notifications", async () => {
    const db = as.user('owner1');
    await assertFails(db.ref('notifications/viewer1/n1/read').set(true));
    await assertFails(db.ref('notifications/viewer1/n1').remove());
  });
});

describe('notification preferences', () => {
  test('own preferences are editable and validated', async () => {
    const db = as.user('owner1');
    await assertSucceeds(db.ref('notificationPreferences/owner1').set({ lowFeed: true, push: false }));
    await assertFails(db.ref('notificationPreferences/owner1/lowFeed').set('on'));
    await assertFails(db.ref('notificationPreferences/owner1/spy').set(true));
  });

  test("other users' preferences are off limits", async () => {
    await assertFails(as.user('owner1').ref('notificationPreferences/viewer1').get());
    await assertFails(as.user('owner1').ref('notificationPreferences/viewer1').set({ push: false }));
  });
});
