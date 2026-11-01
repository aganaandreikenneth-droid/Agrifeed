# AgriFeed: Project Handoff

Last updated: 2026-10-22. Current commit: `cc91ad0` (Phase 1).

AgriFeed is an IoT poultry feeder for about 4–5 chickens. It is a Flutter app with a Firebase
backend (Auth, Realtime Database, Cloud Functions, FCM later), designed for a future ESP32
feeder (MG996R servo, HX711 + load cell, DS3231 RTC, I2C LCD, push button, buzzer).
**Current priority: the Flutter app and Firebase backend only.** ESP32 work starts only when the
project owner explicitly approves it.

---

## 1. Phase 1 status: complete and committed

Phase 1 (Authentication and Role-Based Security) is implemented, verified on the Firebase
Emulator Suite, accepted by the project owner, and committed.

| Item | Status |
|---|---|
| Implementation | Done |
| Automated tests | All passing (section 3) |
| Manual smoke tests (Android emulator, Pixel 8) | 18 executed and passing, 2 pending (section 7) |
| Committed | Yes: `cc91ad0f67528ae7b899aff359e451e1d42a2b2d`, "feat: complete AgriFeed Phase 1 authentication and security" |
| Baseline before Phase 1 | `ac3253a` "Baseline: existing AgriFeed app before Phase 1" |
| Working tree at handoff | Clean except this handoff file (uncommitted) |
| Production Firebase (`agrifeed-dda82`) | **Untouched.** No deploys, no data changes, no billing changes |
| ESP32 / hardware | Not started |

## 2. npm installation

- **Finished successfully.** A clean reinstall was done after adding the scoped gRPC override.
- The first install, which regenerated the lockfile, left out vitest's native Windows binding
  (npm bug npm/cli#4828: "Cannot find native binding"). The lockfile itself was correct;
  **`npm ci`** installed the missing binding without changing the lockfile.
- **Always use `npm ci`** to install the root tooling (do not delete the lockfile and run `npm install`).
- `functions/` installs cleanly with `npm --prefix functions ci`.
- `npm audit`: **0 vulnerabilities** in the root tooling and in `functions/`.
- The `@grpc/grpc-js` advisories (GHSA-m9gg-hp2v-232j, GHSA-f596-whhp-79r4) are resolved by
  `"overrides": { "@firebase/firestore": { "@grpc/grpc-js": "1.14.6" } }` in `package.json`.
  This only affected local test tooling, never the app or Cloud Functions.

## 3. Final test results (last run before commit `cc91ad0`)

| Command | Result |
|---|---|
| `npm run test:rules` | **108 / 108 passed** (Security Rules + emulator-configuration tests) |
| `npm run test:functions` | **15 / 15 passed** (Cloud Functions integration tests) |
| `flutter test` | **26 / 26 passed** |
| `flutter analyze` | **No issues** |
| `flutter build apk --debug` | Builds |

Logs are in `docs/review/phase1/evidence/`. **No failures remain.**

Failures found and fixed during verification:
1. Unauthenticated reads were allowed on the emulator's `demo-agrifeed` namespace. Fixed by
   binding the rules to both emulator namespaces in `firebase.json`; `rules_config.test.mjs` guards it.
2. App crash (`'_dependents.isEmpty'`) after saving a dialog: the controller was disposed
   during the exit animation. Fixed with `lib/core/widgets/text_prompt.dart` and regression tests.
3. Admin function calls hung on Android: the unused `firebase_messaging` made the Functions
   SDK wait for an FCM token the demo project cannot get. Fixed by removing it (it returns in Phase 7).
4. Duplicate `@firebase/app-compat` copies broke the rules tests. Fixed by an npm `overrides` entry.
5. On Windows, `firebase emulators:exec` left Java running. Replaced by `scripts/run-with-emulators.mjs`.

## 4. Git

```
cc91ad0 feat: complete AgriFeed Phase 1 authentication and security   <- HEAD (master)
ac3253a Baseline: existing AgriFeed app before Phase 1
```

`git diff ac3253a cc91ad0` shows the full Phase 1 change (99 files: 89 added, 10 modified).
Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## 5. Project structure (Phase 1)

```
lib/
  main.dart                    startup only: startBackend() -> MyApp
  app.dart                     MaterialApp + theme (cream/peach/charcoal), EMULATOR banner
  app_scope.dart               AppServices (created once) + AppScope InheritedWidget
  design.dart                  ORIGINAL theme widgets (SegmentGauge, IconBox, PillNav). UNCHANGED, do not reformat
  firebase_options.dart        FlutterFire production config (used only with AGRIFEED_ENV=production)
  core/
    env.dart                   AGRIFEED_ENV (default "emulator"), kProductionEnabled=true, emulator host/ports
    backend.dart               emulator: named app "agrifeed-emulator" (demo-agrifeed), probe, no fallback; production: default app from firebase_options.dart
    emulator_probe*.dart       TCP reachability check (io) / unsupported on web (stub)
    format.dart                toMap, two, fmtTs, ago, weightLabel
    widgets/panel.dart         Panel, HeroIcon, NarrowPage, colour constants
    widgets/text_prompt.dart   safe single-field dialog (owns its controller)
  services/
    auth_service.dart          email/password, Google, reset, verification, form validation
    session.dart               resolveSession() (pure) + SessionController (auth, claims, accountStatus)
    profile_repository.dart    users/{uid} create-once, display name
    feeder_index_repository.dart  userFeeders/{uid} -> feeder list (no hardcoded IDs)
    admin_service.dart         callable admin functions + platformAudit stream
  features/
    auth/                      auth_gate, login, verify email, suspended/error, boot-blocked pages
    home/                      home_shell (feeder list or "No feeder registered"), account_panel
    admin/                     admin_shell (account access actions, audit list)
    legacy/legacy_feeder_screens.dart  ORIGINAL Dashboard/Schedule/History/Settings, NOT MOUNTED
                               (still uses legacy feeders/feeder1; to be rebuilt in Phase 2)
functions/                     Cloud Functions (TypeScript, Node 22, firebase-functions 7.4, firebase-admin 14.5)
  src/index.ts                 exports setAdminRole, suspendUser, reactivateUser (us-central1)
  src/lib/guards.ts            requireActiveAdmin (claim + platformAdmins + not suspended), input validators
  src/lib/audit.ts             platformAudit writer
  src/admin/roles.ts           setAdminRole (transaction prevents removing the last admin)
  src/admin/accountStatus.ts   suspendUser / reactivateUser
rules/rules.mjs                rules SOURCE (named conditions) -> rules/build.mjs -> database.rules.json
database.rules.json            GENERATED; do not edit by hand (npm run rules:check detects drift)
scripts/
  run-with-emulators.mjs       start emulators -> run command -> kill process tree (used by npm test scripts)
  emulator-admin.mjs           Admin SDK guard: localhost + demo- project only, refuses real credentials
  seed-emulator.mjs            test accounts + 1 live + 1 virtual feeder; random password per run
  bootstrap-admin.mjs          first admin in the emulator (refuses if an admin exists)
  emulators-lan.mjs            temporary LAN mode (requires --confirm-lan)
tests/rules/*.test.mjs         rules tests on the app's namespace (fixture.mjs = seeded world)
tests/functions/*.test.mjs     Cloud Functions integration tests
test/*.dart                    Flutter unit/widget tests
docs/phase1.md                 Phase 1 technical doc (safety, run, R/W matrix, Phase 2 claim design)
docs/phase1-manual-tests.md    manual smoke-test procedure and results
docs/review/phase1/            verification evidence logs + sanitized screenshots
firebase.json                  database rules for instances demo-agrifeed + demo-agrifeed-default-rtdb,
                               functions, emulators (all 127.0.0.1)
.firebaserc                    default = demo-agrifeed (a stray deploy cannot hit production)
package.json                   root tooling (vitest 5, @firebase/rules-unit-testing 5, firebase 12.19, firebase-admin 14.5)
```

Flutter: 3.47.5 / Dart 3.13.4. App dependencies: `firebase_core ^4.15.0`, `firebase_auth ^6.7.0`,
`firebase_database ^12.6.0`, `cloud_functions ^6.5.0`, `google_sign_in ^7.2.0`
(`cloud_firestore` and `firebase_messaging` removed). Tooling on this PC: Node 22.19, Java 21,
Firebase CLI 15.32, Android emulator "Pixel_8".

## 6. Firebase security architecture and environment

### Environment safety
- The app defaults to **emulator**. Production (agrifeed-dda82) is used only when asked for by name,
  `--dart-define=AGRIFEED_ENV=production`; it needs the production rules deployed and the feeder provisioned.
- All services use a **named app** with project `demo-agrifeed` (a `demo-` project cannot reach real
  resources), never the `.instance` singletons. If the Auth, Database or Functions emulator is
  unreachable, the app shows a blocking page and **does not fall back to production**.
- Database URL everywhere (app, functions, tests): `https://demo-agrifeed.firebaseio.com`
  (namespace `demo-agrifeed`). `firebase.json` loads `database.rules.json` for `demo-agrifeed` and
  `demo-agrifeed-default-rtdb`.
- Emulators bind to **127.0.0.1**. Android emulator: `10.0.2.2`. Physical phone: prefer
  `adb reverse` + `--dart-define=EMULATOR_HOST=127.0.0.1`; LAN only via
  `npm run emulators:lan -- --confirm-lan` with the documented firewall precautions.
- Debug Android manifest allows cleartext (emulator); release does not.
- No service-account keys exist in or for this project. Test passwords are generated per run.

### Identities and roles
| Role | Source of truth | Notes |
|---|---|---|
| System Admin | custom claim `admin: true` **and** `platformAdmins/{uid}: true` (backend-only) | Revoking the registry entry takes effect immediately. **No automatic access to feeder data.** |
| Feeder Owner | `feeders/{id}/members/{uid}.role == 'owner'` **and** `meta.ownerUid == uid` | Holds every permission |
| Authorized Member | `members/{uid}` with `status: 'active'`, optional `expiresAt`, `permissions{}` | Permissions: viewDashboard, viewHistory, viewAnalytics, manualFeed, manageSchedules, downloadReports, receiveAlerts |
| Device (ESP32 / simulator) | custom token `{device, feederId, mode, credVersion}` checked live against `deviceRegistry/{id}` (deviceUid, status `active`, mode, credentialVersion) | Revocation and credential rotation take effect immediately |

All human access requires `email_verified == true` and `accountStatus/{uid}.suspended != true`.

### Database layout (one Realtime Database)
`users/{uid}` (profile: displayName, createdAt, lastSelectedFeederId) ·
`accountStatus/{uid}` (backend) · `platformAdmins` (backend) · `platformAudit` (backend) ·
`userFeeders/{uid}/{feederId}` (backend) · `deviceRegistry/{feederId}` (backend; admin-readable) ·
`deviceClaims`, `invitations` (backend only) · `notifications/{uid}` · `notificationPreferences/{uid}` ·
`feeders/{feederId}/` { `meta`, `config`, `members`, `status`, `telemetry/current`, `measurements`,
`history`, `alerts`, `audit`, `schedules`, `commands`, `activeCommand`, `simulator/controls` }.

Feeder IDs: `fd_` + 20 random base-62 characters, generated server-side only.
Legacy `feeders/feeder1` (production) has no members, so the new rules make it unreachable.

### Rules principles (`rules/rules.mjs`)
- Deny by default; **no grants on parent nodes** (`feeders`, `feeders/{id}`, `users`, `userFeeders`).
- `.validate` does not run on deletes, so every `.write` spells out create, update and delete.
- Owners **cannot** write device data (status, telemetry, measurements), verified outcomes
  (history, command results), alerts or audit; nobody deletes history, audit, commands or whole feeders.
- Commands: created only as `pending` together with the `activeCommand` lock; only the device advances
  the status (pending→accepted|rejected|expired; accepted→dispensing|failed|expired;
  dispensing→completed|partial|failed); only a device writes `actualG`/`executedBy`; a stale pending
  command (>120 s) may be expired by the requester or owner; 500 g platform cap and per-feeder `maxDispenseG`.
- Simulated feeders: device data must say `source: 'simulator'`; simulator identities cannot write to
  live feeders; a simulated result can never be labelled as a device result.
- Full owner/member read-write matrix: `docs/phase1.md` §5.

### Cloud Functions (Phase 1)
`setAdminRole`, `suspendUser`, `reactivateUser`: active, verified admin only; input validated;
platformAudit records. Suspension writes `accountStatus` first, then disables the account and revokes
refresh tokens. Deploying needs the **Blaze plan** and approval. Until then they run in the emulator.

## 7. Remaining issues and pending tests
- **Pending (not executed, never claimed as passed):** M19 Google Sign-In; M20 physical-phone testing.
- A live suspension signs the user out (by design of Auth disable + token revocation). The
  Suspended page shows when only the database status is suspended.
- The Functions emulator can time out loading definitions on a busy PC; run `npm run functions:build` to reload.
- Windows desktop builds need Windows Developer Mode (plugin symlinks). Web is unsupported in emulator mode.
- App ID is still `com.example.agrifeed` (change before any store release; register SHA-1/256 for Google Sign-In).
- Not done yet: App Check, production rules/functions deployment, Blaze decision, legacy `feeder1` decision.
- `lib/features/legacy/legacy_feeder_screens.dart` keeps the old default capacity 9000 g, which exceeds
  the 3 kg load cell. The new schema caps capacity at `config.loadCellMaxG` (3000 g, needs calibration).

## 8. Approved requirements for Phases 2–10

Global rules that apply to every phase:
- Realtime Database only; one production database; dynamic `feeders/{feederId}`; no hardcoded feeder IDs.
- Authorization enforced in rules/backend, not only in the UI; least privilege; no `.read/.write: true`.
- Never put Admin SDK credentials in Flutter; no hardcoded admin accounts or passwords.
- Never confuse simulated and real results; a Firebase write is never proof of dispensing.
- Preserve the existing design (`design.dart`, cream/peach/charcoal) and working features.
- No production deploys, data changes or billing changes without explicit approval; no ESP32 work until approved.
- Run real tests; never claim untested results; small, verifiable milestones; explain deviations first.

### Phase 2: Dynamic virtual feeders, ownership, members, feeder selection (PLAN AWAITING APPROVAL)
1. Secure server-generated feeder IDs (`fd_` + 20 base-62, uniqueness via a create-only transaction on `deviceRegistry/{id}`).
2. `createVirtualFeeder({name, timezone, requestId})`: verified active users; per-user limit
   (proposed 3) enforced by a committed transaction on backend `userQuotas/{uid}`; idempotent via
   `requests/{uid}/{requestId}`; one atomic multi-path write (registry `mode: simulated`, meta, config
   defaults 3000 g / 500 g / 200 g / uncalibrated, owner member, userFeeders, audit, platformAudit).
   `deleteVirtualFeeder` (owner, type-name confirmation; cleans every member's index).
3. Owner permissions per the rules matrix; no live feeders until the hardware phase.
4. Invitations: `createInvite` (one-time 10-character code, hash stored, 72 h default, shown once, shared
   manually), `acceptInvite` (per-user rate-limit counter committed in its own transaction; invite
   open→accepted transaction so only one acceptance succeeds; idempotent retry; atomic finalize; no
   self-invite or duplicate membership), `revokeInvite`, `updateMemberPermissions` (whitelisted keys),
   `removeMember`, `leaveFeeder`; a displayName snapshot in `members/{uid}`; no email exposure.
   Ownership transfer deferred.
5. Multiple feeders per user.
6. `FeederSelectionController` (userFeeders stream, persisted `lastSelectedFeederId`, fallback when
   access is removed) + app-bar switcher with a VIRTUAL badge; `FeederScope` providing feederId, role and permissions.
7. Secure database operations (rules mostly unchanged; new backend-only nodes covered by tests).
8. Simulation isolation (virtual feeders only `mode: simulated`; badges; existing source/mode rules).
9. Conditional legacy `feeder1`: read-only production inspection **only after approval**, then either
   a clean start (leave `feeder1` untouched) or a migration script tested on an emulator copy
   (production run only with a separate approval at deployment).
10. Rebuild Dashboard, Schedule, History and Settings on the selected feeder: per-child listeners,
    permission gating, honest "no data / unavailable" states (never fake 0 g).

**Open decisions:**
(a) virtual feeder limit 3?
(b) manual sharing of invite codes?
(c) default invite permission `viewDashboard` only?
(d) dispense button disabled until Phase 5 (recommended) or a minimal version now?
(e) port the basic daily schedule add/edit/delete now (recommended) or read-only until Phase 4?
(f) approve the read-only `feeder1` inspection (needs `firebase login`), or a clean start?

**Physical device pairing (hardware phase, design agreed):** a `deviceClaims/{id}` transaction that
commits failed-attempt counts and lockouts rather than aborting; a per-user rate limit; hashed claim
codes; commit then idempotent finalize; device custom tokens; registry checks for
revocation and rotation. See `docs/phase1.md` §6.

### Phase 3: Real-time dashboard (Module 2)
Selected feeder name; online/offline from `status.lastSeen` (server time); last connection; remaining
feed in g and kg; capacity and % (configurable, ≤ load-cell rating, calibration status); low-feed warning
(default 500 g); device condition; next scheduled feeding; last completed feeding; today's count and
consumption (from confirmed data); manual-feed shortcut; alerts. Distinguish live, stale, offline,
unavailable and simulated readings; never show missing data as 0.

### Phase 4: Advanced scheduling (Module 3)
Add, edit, delete; time; grams; daily and specific weekdays; enable/disable; pause/resume all
(`config.schedulesPaused`); next feeding; conflict and duplicate checks (rules cannot query, so use the
app plus a backend check); time-zone aware (`meta.timezone`, IANA); change history (audit); prepare for
ESP32 local sync with the DS3231 RTC, which keeps feeding offline while powered.

### Phase 5: Advanced manual feeding (Module 4)
Preset and custom amounts, validation, confirmation, loading states; unique command IDs; the full
status lifecycle (pending/accepted/dispensing/completed/partial/failed/rejected/expired); duplicate
prevention (`activeCommand` lock); timeout and expiry feedback (plus a backend sweeper for stuck
accepted/dispensing); request history. Submission is never shown as dispensed; only device-confirmed
measured results count as success; simulated outcomes are labelled.

### Phase 6: IoT simulation (Module 9)
Virtual feeder (in-app owner controls in `simulator/controls` + a headless Node "virtual device" using a
simulated device token and the same protocol as the future ESP32): adjustable hopper weight,
dispensing, command progress, success/failure, disconnect/reconnect, blockage, low feed, schedule
execution, notification triggers, history generation, test logs, scenario reset. It never controls
hardware, is isolated from production, is labelled, repeatable, and uses the emulator or a dev project.

### Phase 7: Smart notifications (Module 5)
FCM (re-add `firebase_messaging` with real configuration); in-app notification center (read/unread,
timestamps, categories, user- and feeder-specific); alerts for low feed, possible stuck feed,
offline/online, feeding completed/failed, critical warnings; preferences
(`notificationPreferences/{uid}`); role-based delivery (`receiveAlerts`); deduplication and recovery;
sent only by a trusted backend (Cloud Functions, so Blaze is needed for deployed triggers).

### Phase 8: History, analytics and reports (Module 6)
Full history (manual vs scheduled, requested vs actual, timestamps, status); filters (date, method,
status), search; daily, weekly, monthly and custom-range consumption; trend charts; frequency and
success-rate statistics; PDF and CSV export; role-based access (`viewHistory`, `viewAnalytics`,
`downloadReports`); use confirmed measured data; never mix simulated and real data; exports follow the same rules.

### Phase 9: System Admin dashboard (Module 8)
Overview, registered users, account status administration (Phase 1 functions), registered device
oversight (`deviceRegistry` summary, not private feeder data), platform statistics, security activity
logs, admin action history, maintenance functions; all privileged operations through Cloud Functions.

### Phase 10: Integration and QA
Functional, security (rules), regression, performance and compatibility testing; documentation;
alignment with selected ISO/IEC 25010:2023 characteristics from the proposal (functional suitability,
performance efficiency, compatibility, interaction capability, reliability, security, maintainability,
flexibility, safety), with acceptance criteria, procedures and limitations, and **no claim of formal
certification**.

### Also in scope across phases (Modules 1 and 7)
Profile and account settings, device naming, multiple feeders, ownership, invitations, member
acceptance and removal, custom permissions, device connectivity info, device settings, notification
preferences, privacy notice, account deletion and data retention plan, App Check (monitor, then
enforce), production deployment (needs approval and the Blaze plan for functions).

### Future (only after explicit approval): ESP32 hardware integration.

## 9. Next steps to continue

1. **Read this file, `docs/phase1.md` and `docs/phase1-manual-tests.md`.**
2. Check the state: `git log --oneline -3` (HEAD should be `cc91ad0`, plus this handoff file if committed).
3. Install: `npm ci` and `npm --prefix functions ci` (do not use `npm install` on a deleted lockfile).
4. Re-verify: `npm test` (rules + functions) and `flutter analyze && flutter test`.
   Expected: 108 + 15 + 26 passing, no analyzer issues.
5. **Get the project owner's answers to Phase 2 decisions (a)–(f)** and explicit approval of the Phase 2 plan.
6. Only then implement Phase 2 in milestones:
   - 2A: functions + tests
   - 2B: feeder selection + `FeederScope`
   - 2C: members and invites UI
   - 2D: port the screens
   - 2E: `feeder1` decision
   - 2F: verification, manual tests on the Pixel 8 emulator, evidence in `docs/review/phase2/`,
     commit only after the owner approves.
7. Run the app locally: `npm run emulators`; in a second terminal `npm run seed` (prints a one-time
   password); then `flutter emulators --launch Pixel_8` and `flutter run`.
8. Keep the boundaries: no production deploys, data changes or billing changes; no ESP32;
   don't reformat `lib/design.dart` (format only the files you change).
