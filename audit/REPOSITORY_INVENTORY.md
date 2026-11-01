# Repository Inventory

Git: branch history `ac3253a → 30a5990` (5 commits). **Large uncommitted working tree** (≈40 modified, 3 deleted,
several untracked files incl. `docs/core-milestones.md`, `assets/`). Nothing here was committed by the audit.

Platform folders `ios/ macos/ linux/ windows/ web/` are Flutter defaults and not relevant to the integration.

## 1. Flutter app — `lib/` (46 Dart files)

### Core
| File | Responsibility |
|---|---|
| `lib/main.dart` | Splash, `startBackend()`, Google Sign-In init, `MyApp`. Header comment still says "connects only to the Emulator Suite" (outdated). |
| `lib/core/env.dart` | `AGRIFEED_ENV` (default `emulator`), `EMULATOR_HOST`, `kProductionEnabled = true`, project IDs, ports 9099/9000/5001, Android default host `10.0.2.2`. |
| `lib/core/backend.dart` | Creates Auth/DB/Functions instances. Emulator: named app `agrifeed-emulator`, DB URL `http://<host>:9000/?ns=demo-agrifeed`, probes ports first, never falls back to production. Production: `DefaultFirebaseOptions` (`agrifeed-dda82`, RTDB URL). |
| `lib/core/emulator_probe*.dart` | TCP probe of emulator ports (IO) / stub (web). |
| `lib/firebase_options.dart` | FlutterFire config for `agrifeed-dda82` (API keys are public identifiers, not secrets). |
| `lib/core/format.dart`, `timezones.dart` | `toMap`, `ago`, weight labels; 8 selectable time zones. |
| `lib/design.dart`, `lib/core/widgets/*` | Theme and shared widgets. |
| `lib/app.dart`, `lib/app_scope.dart` | App root, EMULATOR banner, service wiring (`FirebaseFeederLive`, `FirebaseFeederRepository`, `FeederActions`, `AdminService`). |

### Services
| File | Responsibility | Firebase paths |
|---|---|---|
| `services/auth_service.dart` | Email/password + Google sign-in, verification email, refresh `email_verified`. | Auth |
| `services/session.dart` | `SessionController`: auth state + claims + `accountStatus/{uid}` (suspension). | `accountStatus/{uid}` |
| `services/profile_repository.dart` | Create/rename profile. | `users/{uid}` |
| `services/feeder_selection.dart` | Feeder list from `userFeeders/{uid}`, meta, own membership, `.info/connected`, last selection. | `userFeeders`, `feeders/{id}/meta`, `members/{uid}`, `users/{uid}/lastSelectedFeederId` |
| `services/feeder_live.dart` | `FeederLive` / `FirebaseFeederLive` (watch + atomic multi-path update), models (`FeederReading`, `FeedEvent`, `FeedSchedule`, `GateReport`, `FeedCommand`), **`FeederControls`** (all app → device requests). | `commands`, `activeCommand`, `gate/request`, `schedules`, `config/schedulesPaused`, `simulator/controls` |
| `services/feeder_repository.dart` | Alerts stream, rename, time zone. | `alerts`, `meta/name`, `meta/timezone` |
| `services/feeder_actions.dart` | Callable `createVirtualFeeder` (not used by current single-feeder UI). | Functions |
| `services/admin_service.dart` | Callables `setAdminRole`, `suspendUser`, `reactivateUser`; reads `platformAudit`. | Functions, `platformAudit` |

### Features
| File | Responsibility |
|---|---|
| `features/auth/*` | Get Started, login, verify email, blocked/suspended pages, `AuthGate`. |
| `features/home/home_shell.dart`, `account_panel.dart` | Loads the one feeder; account panel. |
| `features/feeder/feeder_shell.dart`, `feeder_scope.dart`, `feeder_badge.dart` | Four-tab shell, `FeederScope` (controls, permissions, online), SIMULATION badge. |
| `features/feeder/live_values.dart` | `LiveValues`: subscribes to `feeders/{id}/<sub>` queries; **denied reads silently show "no data"** (`onError: (_) {}`). |
| `features/feeder/tabs/home_tab.dart` | Dashboard: `status`, `telemetry/current`, `config`, `schedules`, `history` (last 200 by `ts`). |
| `features/feeder/tabs/feeding_tab.dart` | Gate, Manual, Automatic sections: `status`, `telemetry/current`, `config`, `gate/state`, `activeCommand`, `commands` (last 1 by `requestedAt`), `schedules`. 10 s gate ack timeout, 120 s command TTL. |
| `features/feeder/tabs/activity_tab.dart` | `history` (last 100 by `ts`). |
| `features/feeder/tabs/settings_tab.dart` | Profile, rename, time zone, controller info. **No hopper capacity/threshold editing.** |
| `features/feeder/simulation_panel.dart` | `simulator/controls` (simulated feeders only). |
| `features/feeder/alerts_sheet.dart` | Alert bell/sheet. |
| `features/admin/admin_shell.dart` | Admin UI (needs Cloud Functions). |

## 2. Firebase configuration
| File | Notes |
|---|---|
| `firebase.json` | RTDB rules for instances `demo-agrifeed` and `demo-agrifeed-default-rtdb` (emulator only); emulators bound to **127.0.0.1**; Functions codebase. No production DB instance (deploy script writes a temp config). |
| `.firebaserc` | default/emulator = `demo-agrifeed`, production = `agrifeed-dda82`. |
| `database.rules.json` | Generated from `rules/rules.mjs`; `node rules/build.mjs --check` → up to date. |
| `rules/rules.mjs`, `rules/build.mjs` | Rules source and generator. |
| `android/app/google-services.json` | `agrifeed-dda82`, **`oauth_client: []`** (no SHA-1 → Google sign-in will fail in production). |

## 3. Cloud Functions — `functions/src/`
`admin/accountStatus.ts`, `admin/roles.ts`, `feeders/invites.ts`, `feeders/lifecycle.ts`, `feeders/members.ts`, `lib/*` (audit, guards, ids, limits). Compiled output in `functions/lib/` (git-ignored). **None of them touch device data**; the ESP32 integration does not depend on Functions.

## 4. Scripts — `scripts/`
| Script | Env | Purpose | Integration relevance |
|---|---|---|---|
| `seed-emulator.mjs` | emulator | Test accounts + one simulated feeder. | Dev baseline. |
| `simulator.mjs` | emulator | Node stand-in for the ESP32 (custom token, `source: 'simulator'`). | Same paths/payloads as the firmware. |
| `provision-device.mjs` | emulator | Switches seeded feeder to `live`, writes **`agrifeed_device.h` with a custom token**. | **Outdated**: current sketch no longer includes that header or uses custom tokens. |
| `emulators-lan.mjs` | emulator | Temp config binding Auth/DB/Functions to `0.0.0.0` (`--confirm-lan`). | Needed only for LAN devices. |
| `run-with-emulators.mjs`, `emulator-admin.mjs` | emulator | Test runner; admin SDK locked to localhost/demo project. | |
| `provision-production.mjs` | **production** | Writes `deviceRegistry`, `deviceAccounts`, feeder `meta/config/members`, `userFeeders` (dry run without `--confirm`). | **Required** before the ESP32 can write. Not run. |
| `deploy-production-rules.mjs` | **production** | Deploys rules to `agrifeed-dda82-default-rtdb` (`--confirm`). | **Required**. Not run. |
| `bootstrap-admin.mjs` | emulator | First admin. | |

## 5. Tests
| Location | Count / result (this audit) |
|---|---|
| `test/*.dart` (6 files) | 65 passed |
| `tests/rules/*.test.mjs` (7 files) | 122 passed, 2 failed (audit config artifact) |
| `tests/functions/*.test.mjs` (4 files) | not run (see TEST_RESULTS) |
| `audit/tests/firmware_contract.test.mjs` (new, audit) | 44 passed |

## 6. ESP32 firmware (outside the repository)
| File | Notes |
|---|---|
| `C:\Users\Lenovo\Downloads\AgriFeed_code\AgriFeed_code.ino` | Current integrated sketch, `FIRMWARE = "esp32-2.0"`. Libraries: ESP32Servo, LiquidCrystal I2C, RTClib, HX711 (bogde), ArduinoJson 7, WiFiManager 2.0; core esp32 3.x (`NetworkClientSecure`). |
| `...\AgriFeed_code_original_test.txt` | Original standalone hardware test (servo cycling, no network). Same pins. |

Installed locally: esp32 core **3.3.11** (also `arduino:esp32 2.0.18`), RTClib, Servo (AVR). **Missing:** ESP32Servo, LiquidCrystal_I2C, HX711, ArduinoJson, WiFiManager; no `arduino-cli`/PlatformIO.

## 7. Documentation
`docs/AGRIFEED_HANDOFF.md` (Phase 1/2 handoff), `docs/core-milestones.md` (M1–M6 log, untracked), `docs/phase1*.md`, `docs/phase2.md`, `docs/review/**` (evidence). `README.md` is the Flutter template.

## 8. Duplicate / outdated / conflicting items
| Item | Problem |
|---|---|
| Firmware not in the repo | Not versioned with the rules/app it must match; easy to drift. |
| `scripts/provision-device.mjs` | Generates a custom-token header the current sketch ignores; there is no emulator path for the real ESP32 any more. |
| `lib/main.dart` header comment | Says "Phase 1 build: connects only to the Firebase Emulator Suite" — production boot exists. |
| `lib/core/env.dart:22` comment | "Production Realtime Database rules are deployed" — they are not (owner approval pending). |
| `docs/core-milestones.md` | Says "no ESP32 work yet" / M2–M4 "Not started" while code for them exists. |
| `backup-agrifeed-2026-10-31.json` | Production backup: legacy schema `feeders/feeder1/{hopper,logs,history,schedules,status}`, `test/counter` — incompatible with the current schema (git-ignored, keep private). |
| `android/hs_err_pid*.log`, `replay_pid*.log` | JVM crash dumps (RAM pressure), noise. |
| `database-debug.log` | Empty log in repo root (ignored). |
| 7 Gradle daemons + VS Code Java servers + one orphaned DB emulator (PID 13140 on :9000) | ≈3.5 GB RAM in use at audit time. Not touched. |
