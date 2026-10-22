# Phase 2B manual test: Pixel_8 Android emulator + Firebase Emulator Suite

Date: 2026-10-22. Debug APK installed with `adb`. Firebase emulators: `auth,database,functions`,
project `demo-agrifeed` only. Accounts from `npm run seed` (random password per run). No physical
device, no ESP32, no production access. Database state was checked with a read-only Admin SDK
script that uses `scripts/emulator-admin.mjs` (localhost and `demo-` only). Backend actions that
have no UI yet (archive, permission change, removal) were sent through the real callables,
signed in as the owner.

| # | Scenario | Result | Evidence |
|---|---|---|---|
| 1 | Verified user with no feeder signs in | PASS | `outsider` account |
| 2 | Onboarding screen | PASS: *Create virtual feeder* enabled, *Register a device* disabled | 2b-01 |
| 3 | Create a virtual feeder | PASS: dialog with name, time zone and VIRTUAL note; loading state | |
| 4 | Created by the trusted Cloud Function | PASS: emulator log `createVirtualFeeder` finished in 716 ms | |
| 5 | Feeder appears in the account | PASS: `userFeeders/{uid}/fd_N0jp…` role owner; meta mode `simulated`; registry `provisioned/simulated`; quota 1 | |
| 6 | Single feeder selected automatically | PASS: opened directly; `lastSelectedFeederId` saved | 2b-02 |
| 7 | Second virtual feeder | PASS after one retry. The first attempt failed with `UNAVAILABLE` while the device switched from Wi-Fi to mobile data; the retry with the same requestId created exactly one feeder (2 feeders, 2 quota slots) | |
| 8 | Switcher shows both feeders | PASS: check mark on the selected one; switching saves `lastSelectedFeederId` | 2b-05 |
| 9 | VIRTUAL and ARCHIVED badges | PASS: VIRTUAL on simulated feeders only (the seeded live feeder has none); ARCHIVED appears live after `archiveFeeder` | 2b-06, 2b-10 |
| 10 | Last selection restored after restart | PASS: force-stop and relaunch, session kept, same feeder | 2b-04 |
| 11 | Archived restricted state | PASS: "archived and read-only" banner within 3 s of the callable (write denial is covered by the rules tests) | 2b-06 |
| 12 | Membership revoked while open | PASS: within 1.5 s of `removeMember`, notice "You no longer have access to "Seeded coop (live)"." and back to onboarding; DB has a `removed` marker, no index entry, last selection cleared | 2b-09 |
| 13 | Network / database errors | PARTIAL: real network drops (emulated Wi-Fi and mobile data cycling) and a failed callable were handled without a crash, with retry. They exposed bugs A and B below (fixed). The airplane-mode recheck on the fixed build was not completed: Claude Code stopped the run because the PC was critically low on memory | |
| 14 | Permission-aware tabs | PASS: owner Settings lists all 7 permissions; member History switched live from content to "You don't have permission…" when the owner revoked `viewHistory` | 2b-07, 2b-08 |
| 15 | Feed button sends nothing | PASS: snackbar "Manual feeding will be enabled in Phase 5. No feeding command was sent."; feeder has no `commands` or `activeCommand` | 2b-03 |

## Bugs found and fixed

**A. False "Offline" banner (root cause in the emulator wiring).** On Android,
`useDatabaseEmulator()` rewrites the database instance's lookup key. After that, every
`FirebaseDatabase.getInstance()` call by the plugin created a new instance with its own WebSocket:
the SDK log showed connections `pc_0` to `pc_10` in one session. `.info/connected` landed on a
connection without server traffic, which idles out after 60 s (`Connection interrupted for:
connection_idle`). It then reported offline while data still arrived on the other connections.

Fix: `lib/core/backend.dart` points the instance straight at the emulator,
`http://<host>:9000/?ns=demo-agrifeed`, with no `useDatabaseEmulator` call. That gives one instance
and one connection. `rules_config.test.mjs` asserts the URL and that no such call is made. After
the fix the app connected, created and listed feeders normally, and showed no banner about a
minute into the session. A full 75 s idle recheck and an airplane-mode toggle are still to be
repeated when memory allows.

**B. Raw error text.** The create dialog showed "UNAVAILABLE". `describeFunctionsError` now shows
"Could not reach the server. Check the connection and try again." for connection codes, and
keeps messages the backend wrote for users (for example the 3-feeder limit). Unit-tested.

## Environment notes
- The emulated device repeatedly failed Android's internet check ("validation failed", DNS
  timeouts) and switched between Wi-Fi and mobile data. Wi-Fi was turned off on the emulated
  device mid-test to reduce this.
- Free RAM was usually 1–2.7 GB (Chrome about 3.8 GB, the Android emulator about 1.8 GB). Gradle
  builds and the Firebase emulators were run one at a time. Two background runs were stopped by
  Claude Code for low memory; neither was a test failure.
