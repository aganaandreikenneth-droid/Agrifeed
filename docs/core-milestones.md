# AgriFeed: single-feeder, functionality-first milestones (M1–M6)

Approved 2026-10-23. AgriFeed has **one** feeding machine per account. Priority: a working system
in software before more security work or hardware:

```
Development:  Flutter app ↔ Firebase Emulator ↔ simulated feeder controller
Later:        Flutter app ↔ Firebase ↔ ESP32 controller → AgriFeed machine
```

The app's screens are identical in both; a **SIMULATION** label in the top bar marks data from the
simulator. Everything runs on the Firebase Emulator Suite (`demo-agrifeed`); production
(`agrifeed-dda82`) is untouched, nothing is deployed, no billing changes, no ESP32 work yet.

| # | Milestone | Status |
|---|---|---|
| M1 | Single-feeder navigation and dashboard foundation | **Implemented, awaiting review** |
| M2 | Simulator and Firebase communication | Not started |
| M3 | Real-time dashboard (+ hopper capacity / threshold settings) | Not started |
| M4 | Feeding controls: 4a gate, 4b manual feeding, 4c schedules | Not started |
| M5 | Activity and notifications | Not started |
| M6 | Final testing and improvements | Not started |

## Owner decisions

- **Gate:** default open time 5 s in simulation, adjustable up to 15 s. The controller closes the
  gate when the time expires, independently of Firebase connectivity. CLOSE has priority over OPEN.
  For real hardware the limit must come from safe mechanical testing; 15 s is not assumed safe.
- **Command timeout:** the app shows "No response" after 10 s without acknowledgment; the
  controller rejects OPEN commands older than 10 s. A timeout is never shown as a confirmed failure
  or a confirmed closure (state UNKNOWN if needed). Expired OPEN commands are never resent
  automatically, and retries cannot execute twice.
- **Hopper:** 2,500 g provisional simulated capacity, 500 g low-feed threshold, editable in M3
  (not physically calibrated).
- **SIMULATION label** whenever the simulator provides the data; simulated and real results are
  never mixed.
- History gets `reason` and `scheduledFor` in M4 (device-written only, with rules tests).

## Planned Firebase shape for the gate (M4)

- `feeders/{id}/gateCommands/{cid}`: `{action: open|close, requestedBy, requestedAt, status,
  reason?, completedAt?, executedBy}`; app creates `pending` only; the controller advances it.
- `feeders/{id}/gate`: controller-written `{state: closed|opening|open|closing|unknown|error,
  verified: false, openedAt?, autoCloseAt?, commandId?, updatedAt, source}`. Without position
  feedback the app says "controller-reported".
- OPEN and manual feeding share the existing `activeCommand` lock; CLOSE needs no lock.
  `config.gateMaxOpenS` (default 5, rules cap 15).

---

## M1: Single-feeder navigation and dashboard foundation

### What works

- **Login opens Home directly.** The feeder ID comes from `userFeeders/{uid}` (written only by
  the backend); nothing is hardcoded. With old data holding several feeders, the last used one
  (else the first) opens; there is no chooser.
- **No machine assigned:** a plain notice ("No AgriFeed machine is assigned to this account
  yet.") with no actions. The app cannot assign itself a feeder (tested against the rules).
- **Top bar:** feeder name, **SIMULATION** label for simulator-driven feeders, alerts bell
  (`feeders/{id}/alerts`, device-written; empty state until the simulator writes alerts).
- **Four tabs** on the original `PillNav` (design.dart unchanged). The centre button opens Feeding.
- **Feeding:** Gate Control (state **UNKNOWN**, "controller-reported, not physically verified";
  OPEN GATE / CLOSE GATE **disabled**), Manual Feeding ("Feed now" **disabled**), Automatic
  Feeding ("Add schedule" **disabled**). Each says it arrives in Milestone 4 and that nothing is
  sent.
- **Settings:** profile and account (name, sign out); feeder name and time zone (owner, not
  archived, online); controller type; feeder ID; what comes next (simulation controls M2, hopper
  M3, feeding preferences M4, notifications M5).
- **Removed from the app:** feeder chooser, switcher, create / register buttons, archive /
  restore / delete, invitation, member and permission screens. The backend for them (Cloud
  Functions, rules) is unchanged and unused by the app.

### Files

New: `lib/core/timezones.dart`, `lib/services/feeder_repository.dart`,
`lib/features/feeder/feeder_badge.dart`, `lib/features/feeder/alerts_sheet.dart`,
`lib/features/feeder/tabs/{tab_page,home_tab,feeding_tab,activity_tab,settings_tab}.dart`,
`test/feeder_tabs_test.dart`, `docs/review/core/m1/`.

Changed: `lib/features/home/home_shell.dart` (direct to Home, no-machine notice),
`lib/features/feeder/feeder_shell.dart` (four tabs, title, bell), `lib/services/feeder_selection.dart`
(`timezone` in `FeederSummary`; several feeders resolve to one; `clearSelection` removed),
`lib/app_scope.dart`, `scripts/seed-emulator.mjs` (one simulated feeder "AgriFeed" for the owner,
2,500 g / 500 g; no member, no second feeder), `test/feeder_ui_test.dart`,
`test/feeder_selection_test.dart`, `test/widget_test.dart`, `test/fake_feeder_source.dart`,
`tests/functions/app_contract.test.mjs`.

Removed: `lib/features/feeder/feeder_switcher.dart`, `lib/features/feeder/create_feeder_dialog.dart`.

Unchanged: `lib/design.dart`, Security Rules, Cloud Functions, authentication.

### Firebase paths used by the app in M1

Read: `userFeeders/{uid}`, `feeders/{id}/meta`, `feeders/{id}/members/{uid}`,
`feeders/{id}/alerts`, `.info/connected`. Write: `users/{uid}/lastSelectedFeederId`,
`users/{uid}/displayName`, `feeders/{id}/meta/name`, `feeders/{id}/meta/timezone`.
**Never written:** `commands`, `activeCommand`, `schedules`, gate or device paths.

### Tests (2026-10-23)

| Command | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | **64 / 64** |
| `flutter build apk --debug` | Builds |
| `npm run test:rules` | **120 / 120** |
| `npm run test:functions:app` | **11 / 11** (includes 5 M1 contract tests) |
| `npm run test:functions:feeders` / `:races` | **27 / 27**, **7 / 7** |
| `npm run test:functions:admin` | **15 / 15** on re-run. First run: 14/15, the concurrent "two admins revoking each other" test timed out at 30 s on a cold Functions emulator; no functions code changed in M1 |

M1 contract tests (real Auth, Database, Functions emulators): a new account has no feeder and
**cannot assign itself one** (not `userFeeders`, `members`, `deviceRegistry` or
`lastSelectedFeederId`); the owner renames and changes the time zone and open listeners see it;
invalid values and backend-only meta fields are refused; **another owner cannot change, archive,
restore or delete the feeder or read its alerts**; an archived feeder is read-only until
restored; the alerts listener starts empty, the app cannot write an alert, and a device alert
reaches it live.

Manual test on Pixel_8: see `docs/review/core/m1/manual-m1.md`.

### Known limitations after M1

- Home, Feeding and Activity are layouts and placeholders until M3–M5; every control is disabled.
- `createVirtualFeeder`, archive/restore/delete and the invitation/member functions remain in the
  backend, unused by the app. Account-to-machine assignment for real accounts is M6.
- The Functions emulator occasionally times out on its first concurrent calls on this PC
  (low memory); re-runs pass.
- Pre-existing (Phase 1 start-up path, not M1): once, after Back closed the activity and it was
  relaunched in the same process, the app stayed on the start-up spinner; a force-stop fixed it.
  To be investigated separately.

---

## Redesign completion and simulation demo (2026-10-28)

The PoultryPro-style redesign is finished and the Feeding, Activity and Settings screens now work
against the simulator (`npm run simulator`) through the real emulator paths and Security Rules:

- **Feeding:** Gate Control (OPEN with 1-15 s slider, default 5 s; CLOSE always allowed; live
  controller-reported state and countdown; "No response" after 10 s, never resent), Manual Feeding
  (presets up to `maxDispenseG`, confirm dialog, live pending -> dispensing -> completed/failed;
  "Give up" once a command is older than 120 s), Automatic Feeding (add / enable / delete
  schedules, pause all). Gate and manual feeding are disabled while the controller is offline.
- **Activity:** today / feedings / 7-day totals and the controller's history list.
- **Settings -> Simulation** (simulated feeders, owner only): refill, set low (400 g), disconnect,
  feed jam. Replaces the "Simulation controls" placeholder.
- Removed: `lib/features/legacy/legacy_feeder_screens.dart` (unused, hardcoded `feeders/feeder1`),
  JVM crash dumps (`hs_err_pid*.log`, `replay_pid*.log`) and emulator debug logs.

Pixel_8 run: Get Started -> Login -> Home live hopper 2.00 kg Online; gate opened 5 s and the
simulator closed it; manual 100 g completed; schedule at 10:17 ran (50 g completed); 400 g
triggered the low-feed banner, red gauge and bell badge; Activity listed both feedings.
Screenshots: `docs/review/core/demo/`. `flutter analyze` clean; `flutter test` 65/65.

Known: schedule times are in the feeder's time zone, while the "new feeding time" default uses
the phone's clock; they differ when the phone is in another zone (the emulator was set to
Asia/Manila for the demo).

## ESP32 controller connected (2026-10-31)

The real machine (`AgriFeed_code.ino`: ESP32, servo gate GPIO18, HX711 hopper load cell
GPIO16/17, DS3231 RTC, I2C LCD, buzzer; pins unchanged) now drives the owner's feeder through the
same emulator paths and Security Rules as the simulator, with `source: 'device'`. No Flutter or
database-structure change was needed; the app already handles `mode: 'live'`.

- `npm run device:provision -- --out <sketch>/agrifeed_device.h`: switches the seeded feeder to
  `live` (`deviceRegistry` + `meta.mode`, removes `simulator/`), activates `esp32-<feederId>` and
  writes the feeder ID and its custom token into the sketch. Re-run after every `npm run seed`.
- The ESP32 reaches the emulator over Wi-Fi (`npm run emulators:lan -- --confirm-lan`), signs in
  with the custom token (Auth emulator REST), and uses Realtime Database REST: status every 5 s
  (1 s while busy), telemetry, measurements every 60 s, alerts (low_feed, stuck_feed,
  sensor_error), gate/state; polls gate/request and activeCommand every 1 s, config and
  schedules every 15 s. Server time comes from the resolved `lastSeen`.
- Feeding uses the gate: open until the hopper has lost the requested grams (5 g lead), close,
  settle 2 s, report the measured loss. No flow after 4 s = failed + stuck_feed; 15 s cap.
- Hardware runs in `loop()` (core 1); the gate auto-closes without the network. Tare and
  calibration are saved in NVS (no re-tare with feed in the hopper after a power cut).
- Verified: every device REST call replayed against the emulator rules (42 checks). Not yet
  verified: compiling and running on the board (no arduino-cli/libraries on this PC).

## ESP32 on Firebase Cloud (2026-10-31)

The ESP32 and the app now share the real project `agrifeed-dda82` / `agrifeed-dda82-default-rtdb`.

- **App:** `--dart-define=AGRIFEED_ENV=production` boots from `lib/firebase_options.dart`
  (`kProductionEnabled = true`, `_startProduction()` in `lib/core/backend.dart`); the default
  build is still the emulator. No UI change. Admin/invite screens need Cloud Functions, which
  are not enabled in the project (Blaze plan); the single-feeder flow uses only Auth + RTDB.
- **Device identity without keys or Functions:** `isDevice` also accepts a dedicated
  email/password account whose UID is `deviceRegistry/{id}/deviceUid` with
  `authMethod: 'password'` and status `active` (custom-token claims path unchanged).
  `deviceAccounts/{uid}` (backend-only) makes `isHuman` false for that account. 4 new rules tests;
  124/124 pass.
- `npm run production:rules -- --confirm` deploys the rules to the production instance;
  `npm run production:provision -- --owner-uid U --device-uid D --confirm` writes the
  backend-owned feeder records with the Firebase CLI login (dry run without `--confirm`).
- **Firmware** (`AgriFeed_code.ino` esp32-2.0): WiFiManager portal `AgriFeed-Setup` (first boot,
  BOOT held 3 s, `w`, or saved Wi-Fi unreachable 60 s) collects Wi-Fi + feeder ID + device
  email/password into NVS; HTTPS with GTS Root R1/R4 pinned roots; kept-alive DB connection;
  schedules cached in NVS and run from the RTC offline, history queued until online.
- Verified: real password-account tokens (Auth emulator) through the full sequence, 37 checks;
  TLS roots verified against the three production hosts. Not verified: compile/run on the board.
- Production holds legacy data from the old app (`feeders/feeder1`, `test`); left untouched.
