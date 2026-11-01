# AgriFeed — Project Overview

Audit date: 2026-10-31 · Repository: `C:\dev\agrifeed` · Firmware: `C:\Users\Lenovo\Downloads\AgriFeed_code\AgriFeed_code.ino`

> Audit only. No application, rules or firmware file was modified. Everything the audit created is in `audit/`.

## 1. What AgriFeed is

AgriFeed is one automatic chicken feeder controlled from a phone:

```
 Flutter app (Android)  ⇄  Firebase Realtime Database  ⇄  ESP32-WROOM controller  →  servo gate, HX711 load cell, RTC, LCD, buzzer
                         ⇄  Firebase Authentication (people + the ESP32's own account)
                         ⇄  Cloud Functions (admin / membership only — emulator only, not deployed)
```

The database is the **only** link between app and hardware. Neither side calls the other. The app writes
*requests* (feed now, open/close gate, schedules, pause). The controller writes *facts*: status, weight,
gate position, measured feeding results, history, alerts. The Security Rules make sure each side can only
write its own part.

## 2. The parts

| Part | Where | Role |
|---|---|---|
| Flutter app | `lib/` | Login → Home / Feeding / Activity / Settings for the one feeder in `userFeeders/{uid}`. Reads live data, writes requests. |
| Environment switch | `lib/core/env.dart`, `lib/core/backend.dart` | `AGRIFEED_ENV` = `emulator` (default) or `production`. |
| Security Rules | `rules/rules.mjs` → `database.rules.json` (generated, 81 KB) | Role-based access, device identity, payload validation. |
| Cloud Functions | `functions/src/` | Admin roles, suspension, virtual feeders, invites, members. **Not deployed to production** (no Blaze plan). |
| Node tooling | `scripts/` | Emulator seed, Node **simulator** (stands in for the ESP32 in development), provisioning (emulator and production), production rules deploy. |
| Tests | `test/` (Flutter), `tests/rules`, `tests/functions` (Vitest + emulators) | |
| ESP32 firmware | **outside the repo**, `Downloads\AgriFeed_code\AgriFeed_code.ino` (1,408 lines) | Hardware control + HTTPS REST to the **production** database. |

## 3. Two environments, two different "devices"

| | Development (emulator) | Production |
|---|---|---|
| Firebase project | `demo-agrifeed` (localhost emulators) | `agrifeed-dda82` |
| App | default `flutter run` | `--dart-define=AGRIFEED_ENV=production` |
| What plays the feeder | **Node simulator** (`npm run simulator`, custom token, `source: 'simulator'`) | **Real ESP32** (email/password device account, `source: 'device'`) |
| Rules | loaded automatically from `database.rules.json` | **not deployed yet** (needs owner approval) |
| Feeder registration | `npm run seed` | `npm run production:provision` (**not run yet**) |

Important correction to the audit brief: the **current firmware no longer talks to the emulator** (no
`192.168.254.102`, no custom token, no `demo-agrifeed` namespace). It was rewritten on 2026-10-31 to use
Firebase *Cloud* over HTTPS with WiFiManager. The older emulator flow survives only in
`scripts/provision-device.mjs`, which the current sketch no longer uses.

## 4. How a feeding works (as coded)

1. User taps **Feed 100 g now** → app writes `commands/{id}` (`pending`) **and** `activeCommand` lock in one atomic update.
2. ESP32 polls `activeCommand` every 1 s, reads the command, checks freshness (≤120 s by server time), load cell, idle state, hopper not empty.
3. ESP32 marks it `accepted` → `dispensing`, opens the servo gate and watches the **hopper weight drop**.
4. It closes the gate at the target (minus a 5 g lead), on no-flow (4 s, <3 g), or after 15 s; waits 2 s; measures.
5. It writes `completed` / `partial` / `failed` with the **measured** `actualG`, adds a `history` entry, deletes the lock.
6. The app's listeners show each status and the result; Activity shows the history entry.

Schedules are copied into the ESP32's flash and run from its clock (NTP/Firebase time, RTC backup), so they
work offline; their history is uploaded later.

## 5. Overall state (evidence in TEST_RESULTS.md)

| Area | State |
|---|---|
| Flutter app | `flutter analyze` clean, 65/65 tests pass. |
| Rules | 122/124 repo rules tests pass (the 2 failures are caused by the audit's own emulator config, see TEST_RESULTS). |
| App ⇄ rules ⇄ firmware **contract** | 44/44 audit checks pass: every REST call the sketch makes, with its exact payload, is accepted by the rules in the emulator, and the app can read the results. |
| Firmware compile | **Not verified** — Arduino CLI not installed, 5 required libraries missing. |
| Physical hardware ⇄ Firebase | **Not verified** — no ESP32 attached to this audit; production not touched. |
| Production | Rules not deployed, feeder not provisioned, Google sign-in not configured. These block the live system. |

See `INTEGRATION_ISSUES.md` for the prioritised list and `RECOMMENDED_IMPLEMENTATION_PLAN.md` for the steps.
