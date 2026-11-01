# Environment and Network Connectivity Audit

## 1. Environment selection (verified in source)

`lib/core/env.dart:16–19` — `AGRIFEED_ENV` defaults to **`emulator`**; `production` must be named explicitly.
`kProductionEnabled = true` (l.23). Unknown values → `BootBlocked` (`backend.dart:68`). The app never falls back from
emulator to production (`backend.dart:84–90`). An **EMULATOR** banner is shown in emulator builds (`app.dart:66`).

| Command | Result |
|---|---|
| `flutter run` | emulator, host `10.0.2.2` on Android emulator, `127.0.0.1` elsewhere |
| `flutter run --dart-define=EMULATOR_HOST=192.168.x.y` | emulator on a LAN host (physical phone) |
| `flutter run --dart-define=AGRIFEED_ENV=production` | `agrifeed-dda82` via `lib/firebase_options.dart` |

## 2. Emulator environment

| Item | Configured value | Source | Assessment |
|---|---|---|---|
| Project | `demo-agrifeed` | `.firebaserc`, `env.dart:30` | ✔ demo project cannot reach real resources |
| Auth | 9099 @ 127.0.0.1 | `firebase.json:52` | ✔ |
| Database | 9000 @ 127.0.0.1, namespace `demo-agrifeed` (`?ns=`) | `firebase.json:56`, `backend.dart:58` | ✔ rules loaded for `demo-agrifeed` and `demo-agrifeed-default-rtdb` |
| Functions | 5001 @ 127.0.0.1, `us-central1` | | ✔ |
| UI / hub / logging | 4000 / default @ 127.0.0.1 | | ✔ |
| Bind address | **127.0.0.1 only** | `firebase.json` | only this PC can connect. LAN access requires `npm run emulators:lan -- --confirm-lan` (temp config, Auth/DB/Functions on 0.0.0.0) |
| Android emulator | `10.0.2.2` | `env.dart:56` | ✔ works with the localhost binding |
| Physical phone (USB) | `adb reverse tcp:9099/9000/5001` + `EMULATOR_HOST=127.0.0.1` | `emulators-lan.mjs:5–7` | ✔ recommended, no network exposure |
| Physical phone (Wi-Fi) | LAN mode + firewall rule for the phone IP, Private profile | `emulators-lan.mjs` | ✔ documented |

### ESP32 ↔ emulator
**Not possible with the current firmware.** It is hard-wired to `https://agrifeed-dda82-default-rtdb.firebaseio.com`
and Google's Auth endpoints with pinned TLS (l.79–80, 609, 625, 651). The previously used `192.168.254.102:9099/9000`,
namespace `demo-agrifeed` and custom-token flow are **gone** from the sketch.

What it would take (only if you want bench tests without touching production — needs your approval, firmware change):
1. A compile-time switch, e.g. `#define AGRIFEED_EMULATOR_HOST "192.168.254.102"`, that uses plain `WiFiClient`/HTTP,
   `http://<host>:9099/identitytoolkit.googleapis.com/v1/...` and `.../securetoken.googleapis.com/v1/token` for Auth, and
   `http://<host>:9000/feeders/<id>/<sub>.json?ns=demo-agrifeed&auth=...` for the database.
2. Emulator started with `npm run emulators:lan -- --confirm-lan` (binds 0.0.0.0).
3. Windows Firewall: inbound TCP 9099, 9000 from the ESP32's IP only, Private profile (the existing node/java rules are program rules; their scope was not inspected).
4. In the emulator: create an email/password account for the ESP32, then set `deviceRegistry/{id}` (`status: active`, `mode: live`, `deviceUid`, `authMethod: password`) and `deviceAccounts/{uid}` — `provision-device.mjs` would need updating because it writes a custom-token header instead.
5. Use a static/DHCP-reserved PC address; this PC has three IPv4 addresses (192.168.40.1, 192.168.253.1 — likely virtual adapters — and 192.168.254.102, the probable LAN address). Confirm with `ipconfig` which one the ESP32's network uses.

### Local state found during the audit
* Something answers on **127.0.0.1:9000** (RTDB emulator response header `X-Firebase-Project-Id: fake-server`), traced to an orphaned `java.exe` (PID 13140, started 19:01, database emulator). It blocks `npm run test:rules` / `npm run emulators` ("port in use"). It was **not stopped** by the audit — stop it yourself (`taskkill /PID 13140 /T /F`) before using the normal scripts.
* Port 9100 is also occupied by another local service.
* 7 Gradle daemons + VS Code Java language servers ≈ 3.5 GB RAM (`gradlew --stop` frees most).

## 3. Production environment

| Item | Value | Source | Assessment |
|---|---|---|---|
| Project | `agrifeed-dda82` | `firebase_options.dart`, `.firebaserc`, firmware | ✔ consistent everywhere |
| RTDB URL | `https://agrifeed-dda82-default-rtdb.firebaseio.com` | same | ✔ consistent (app and firmware) |
| Namespace | `agrifeed-dda82-default-rtdb` | `deploy-production-rules.mjs:24` | ✔ |
| Transport | HTTPS (app SDK; firmware pinned GTS R1/R4) | | ✔ |
| App auth | email/password (verification required by rules) + Google | `auth_service.dart` | ⚠ Google: `google-services.json` has `oauth_client: []` (no SHA-1 registered) → Google sign-in fails on Android in production. Email/password works. |
| Device auth | email/password device account | firmware | ✔ compatible with rules (verified on emulator) |
| Rules | **unknown / not deployed** | memory + handoff; CLI could not read live rules | ⛔ blocks or endangers everything (see INTEGRATION_ISSUES C-1) |
| Provisioning | **not done** (no `deviceRegistry`, `deviceAccounts`, `userFeeders`, new feeder) | backup file | ⛔ ESP32 writes refused, app shows no feeder (C-2) |
| Cloud Functions | not deployed (Spark plan) | memory | Admin/suspension/membership functions unavailable in production; **the feeding integration does not need them**. Admin screen calls will fail. |
| Existing data | legacy `feeders/feeder1`, `test/counter` | backup (git-ignored) | left untouched by the plan |

### Emulator vs production differences that matter
| | Emulator | Production |
|---|---|---|
| Device that plays the feeder | Node simulator (custom token) | ESP32 (password account) |
| Rules | always the repo version | whatever is live (unknown) |
| Functions | available | not available |
| Google sign-in | emulator accepts | needs SHA-1 + OAuth client |
| Email verification | seeded accounts pre-verified | real verification email needed |
| Phone time zone note | `adb shell cmd alarm set-timezone Asia/Manila` for schedules | real phone clock |

## 4. Network tests performed
* TCP/HTTP probe of 9000/9099/5001/4000 on 127.0.0.1 (results above).
* Isolated emulator started on 127.0.0.1:9199 (Auth) and :9400 (DB) — reachable; used for all emulator tests; stopped afterwards.
* **No** test from the ESP32 (no board attached) and **no** connection to production (not authorised).
