# AgriFeed — Phase 1: Authentication and Role-Based Security

Local development only. Nothing in this phase is deployed, and the app build
cannot connect to the production Firebase project.

## 1. Environment safety

| Layer | Protection |
|---|---|
| Flutter app | `lib/core/env.dart`: defaults to `emulator`; `production` is blocked (`kProductionEnabled = false`). |
| Flutter app | Uses a separate named Firebase app with project `demo-agrifeed`; services never use the default (production) app. |
| Flutter app | Probes the Auth, Database and Functions emulators first. If any is unreachable it shows a blocking screen — no fallback. |
| Android | Debug manifest allows cleartext HTTP (emulator only). `firebase_messaging` is not included until Phase 7 (see §7). |
| Network | All emulators bind to `127.0.0.1` (firebase.json). LAN access only via the explicit, temporary `npm run emulators:lan -- --confirm-lan`. |
| Firebase CLI | `.firebaserc` default project is `demo-agrifeed` (a `demo-` project cannot reach real resources). |
| Scripts | `scripts/emulator-admin.mjs` refuses non-local hosts, non-`demo-` projects and any real service-account credentials. |
| Namespaces | App, Cloud Functions and tests all use `https://demo-agrifeed.firebaseio.com` (ns `demo-agrifeed`). firebase.json loads `database.rules.json` for `demo-agrifeed` and `demo-agrifeed-default-rtdb`; `tests/rules/rules_config.test.mjs` verifies both. |

## 2. Run it locally

Prerequisites (already present on this PC): Flutter 3.47, Node 22, Java 21, Firebase CLI 15.

```bash
npm install                  # once (tooling)
npm --prefix functions install   # once (Cloud Functions)

npm run emulators            # builds rules + functions, starts Auth/Database/Functions + UI at http://127.0.0.1:4000
npm run seed                 # (second terminal) test accounts + one live and one virtual feeder
flutter run                  # Android emulator: 10.0.2.2 reaches the PC's 127.0.0.1
```

Physical phone, preferred (USB, nothing exposed on the network):

```bash
adb reverse tcp:9099 tcp:9099 && adb reverse tcp:9000 tcp:9000 && adb reverse tcp:5001 tcp:5001
flutter run --dart-define=EMULATOR_HOST=127.0.0.1
```

Physical phone over Wi-Fi (temporary, explicit): `npm run emulators:lan -- --confirm-lan`,
then `flutter run --dart-define=EMULATOR_HOST=<PC LAN IP>`. Without the flag the script
prints the precautions: trusted private network only, Windows profile "Private",
a temporary firewall rule limited to the phone's IP, stop and remove the rule afterwards.
The emulators accept unauthenticated admin-style REST calls, so only seeded test data may live there.

`npm run seed` generates a new random password on every run and prints it once
(or set `SEED_PASSWORD` for a session). No password is stored in the repository.
Accounts: `admin@`, `owner@`, `member@`, `outsider@`, `suspended@`, `unverified@` + `agrifeed.test`.

First admin without seeding: register in the app, open the verification link
shown in the Emulator UI → Authentication, then
`npm run bootstrap-admin -- --email you@example.com` (refuses if an admin exists).

Windows desktop builds need Windows Developer Mode (symlinks for plugins).
Web is not supported in emulator mode in Phase 1 (the emulator probe needs sockets).

## 3. Automated tests

```bash
npm run test:rules       # 108 Security Rules + configuration tests (Database emulator, app namespace)
npm run test:functions   # 15 Cloud Functions tests (Auth + Database + Functions emulators)
npm test                 # both
flutter analyze && flutter test   # 26 Flutter unit/widget tests
```

`scripts/run-with-emulators.mjs` replaces `firebase emulators:exec` because on
Windows the latter can leave the Java database emulator running.
The rules tests do not load rules themselves: the emulator loads them from
firebase.json exactly as for the app, on the app's namespace.
Rules are generated from `rules/rules.mjs` (`npm run rules:build`);
`npm run rules:check` fails if `database.rules.json` is stale.

## 4. Sign-up → profile sequence (rules-compatible)

1. Register (email/password) → Auth account + verification email. **No database writes.**
2. Verify screen polls `reload()`. Unverified users are denied by every rule.
3. Once verified: `getIdToken(true)` so the token's `email_verified` claim is true.
4. Read `accountStatus/{uid}` (allowed for verified users, even when suspended).
5. Not suspended → create `users/{uid}` `{displayName, createdAt}` (create-only, no role fields).
6. Route: suspended → Suspended page; admin claim → Admin shell; otherwise Home.

Google sign-in follows the same path from step 3.

## 5. Owner / member read-write matrix (`feeders/{feederId}/…`)

R = read, W = write (create/update), D = delete. "—" = denied. Members need the listed permission.

| Path | Owner | Member | Device (own feeder, active) | Admin |
|---|---|---|---|---|
| meta | R; W name, timezone | R | R | — |
| meta.ownerUid / mode | R only | R only | R | — |
| config | R; W capacity, threshold, maxDispense, paused | R; W paused (`manageSchedules`) | R; W calibrationStatus | — |
| members | R all | R own record | — | — |
| status, telemetry | R | R (`viewDashboard`) | R, W | — |
| measurements | R | R (`viewHistory`/`viewAnalytics`) | create only | — |
| history | R | R (`viewHistory`/`viewAnalytics`) | create only | — |
| alerts | R | R (`viewDashboard`) | W (no D) | — |
| audit | R | — | — | — |
| schedules | R, W, D (single entries) | R; W, D with `manageSchedules` | R | — |
| commands | R; create with lock; expire stale own/any | R; create with lock (`manualFeed`); expire own stale | R; advance status, outcome fields | — |
| activeCommand | R; release after terminal | same with `manualFeed` | R; D | — |
| simulator/controls | R, W (virtual feeders only) | — | R (virtual only) | — |

No role can delete a whole feeder, a whole collection, history, audit or commands from the app.
Membership, ownership, mode, registry, claims and invitations are written only by Cloud Functions.

## 6. Phase 2 design note — claim attempts and concurrency (corrected)

An aborted RTDB transaction persists nothing, so a wrong claim code must be
**committed**, not aborted. `deviceClaims/{feederId}` transaction handler:

| Current state | Input | Returned value (committed) | Function result |
|---|---|---|---|
| `lockedUntil > now` | any | unchanged | `resource-exhausted` (no attempt counted) |
| `expiresAt <= now` | any | unchanged | `deadline-exceeded` |
| claimable | wrong code | `failedAttempts + 1`; on the 5th, `lockedUntil = now + backoff` and attempts reset | `invalid-argument` |
| claimable | right code | `state: committed, claimId, claimedBy, committedAt` | continue to finalize |
| committed/finalized by same uid + requestId | any | unchanged | idempotent retry → finalize |
| committed by someone else | any | `undefined` (abort — nothing to change) | `already-exists` |

- Outcome is read from the committed snapshot, not from variables set inside the
  handler (the handler can run several times).
- Per-user rate limit: a second transaction on `rateLimits/claim/{uid}`
  (sliding window, e.g. 10 attempts / 15 min) runs first and is committed.
- Codes are compared as SHA-256 hashes; constant-time comparison.
- Finalize is one atomic multi-path update (meta, members, userFeeders,
  registry, audit keyed by `claimId`, claim state `finalized`).
  An unfinalized commit grants no access (rules depend on `members`).
- Tests (Phase 2): concurrent claims → exactly one owner; crash between commit
  and finalize → retry completes; wrong-code counting persists; lockout; expiry.

## 7. Known limitations in Phase 1

- Feeder screens (dashboard, schedules, history, settings) are preserved in
  `lib/features/legacy/` but not mounted; Phase 2 reconnects them to the
  selected feeder. Users without feeders see the onboarding panel.
- Google Sign-In was not tested (manual test M14 pending).
- A live suspension signs the user out (Auth account disabled + tokens revoked);
  the next sign-in shows "This account has been suspended…". The Suspended page is
  shown when the database status is suspended while the Auth account is still enabled.
- `firebase_messaging` was removed from pubspec.yaml: it was unused, and its presence made
  the Android Functions SDK wait for an FCM token that the demo project can never issue,
  so admin calls hung (found in manual testing). Re-add it in Phase 7 with real configuration.
- Functions emulator may time out loading definitions (10 s) on a busy machine; rebuild
  (`npm run functions:build`) to reload.
- See docs/phase1-manual-tests.md for the executed manual smoke tests.
- App Check, push notifications and production deployment are not part of Phase 1.
- Resolved: GHSA-m9gg-hp2v-232j / GHSA-f596-whhp-79r4 affected `@grpc/grpc-js@1.9.16` in the
  local test tooling only (`@firebase/rules-unit-testing → firebase@12.19.0 →
  @firebase/firestore@4.17.2`, which pins ~1.9.0; no 1.9.x fix exists). package.json now has the
  scoped override `"@firebase/firestore": { "@grpc/grpc-js": "1.14.6" }`. After a clean
  install (`npm ci`), `npm audit` reports 0 vulnerabilities and all rules and functions tests pass.
  Cloud Functions (`functions/`) already used 1.14.6. Do not run `npm audit fix --force`
  (it would downgrade firebase to 9.14.0).
- On Windows, regenerating package-lock.json from scratch can leave out vitest's native
  binding (npm bug npm/cli#4828: "Cannot find native binding"). Use `npm ci`.
