# M1 (single-feeder) manual test: Pixel_8 Android emulator + Firebase Emulator Suite

Date: 2026-10-23. Debug APK installed with `adb`; Firebase emulators `auth,database,functions`,
project `demo-agrifeed` only; `npm run seed` (one simulated feeder "AgriFeed" assigned to
`owner@agrifeed.test`; random password per run). No production access, no ESP32. Database state
was read with the Admin SDK through `scripts/emulator-admin.mjs` (localhost and `demo-` only).
The app was driven with `adb` (taps, text, screenshots).

| # | Scenario | Result | Screenshot |
|---|---|---|---|
| 1 | Owner signs in: **Home opens directly**, top bar "AgriFeed" + SIMULATION + bell, no chooser or switcher | PASS | m1-01 |
| 2 | Centre button opens Feeding: Gate Control (Gate: UNKNOWN, controller-reported; OPEN/CLOSE disabled), Manual Feeding (Feed now disabled), Automatic Feeding (Add schedule disabled), in that order | PASS | m1-02, m1-03 |
| 3 | Tapping OPEN GATE, CLOSE GATE, Feed now and Add schedule does nothing; DB afterwards: the feeder has only `config`, `members`, `meta` (no commands, lock, schedules or gate data) | PASS | |
| 4 | Activity tab: feeding and gate history, reports (Milestone 5), no numbers | PASS | m1-04 |
| 5 | Bell: "No alerts…" | PASS | m1-05 |
| 6 | Settings: Profile and account, Feeder (name, time zone, controller "Simulator (development)", ID), coming next. No feeder list, create, archive or delete | PASS | m1-06 |
| 7 | Rename to "AgriFeed Coop" and set Asia/Singapore: top bar and Settings update live; DB `meta.name` / `meta.timezone` updated | PASS | m1-07 |
| 8 | Force-stop and relaunch: opens Home with the same feeder | PASS | m1-08 |
| 9 | An account with no machine (`outsider`) sees only "No AgriFeed machine is assigned to this account yet." and the account panel; no buttons, nothing of the owner's | PASS | m1-09 |

Notes:
- After re-seeding, the session saved from the previous run pointed to a deleted account; the
  app showed "Could not refresh your session" with Sign out, as designed.
- One UI dump taken during the splash screen after a restart was stale; the follow-up dump and
  screenshot show Home (scenario 8).
- The earlier (multi-feeder) M1 manual run of the same day was superseded by this revision; its
  screenshots were removed.
