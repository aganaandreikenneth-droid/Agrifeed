# Handoff Summary (for the next developer / AI)

**Project:** AgriFeed — one automatic chicken feeder. Flutter app ⇄ Firebase RTDB ⇄ ESP32. Repo `C:\dev\agrifeed`;
firmware `C:\Users\Lenovo\Downloads\AgriFeed_code\AgriFeed_code.ino` (not in git). Audit date 2026-10-31. Read
`INTEGRATION_ISSUES.md` first.

## Architecture
* All feeder data under `feeders/{fd_id}/`. App writes requests: `commands/{id}` + `activeCommand` (atomic), `gate/request`, `schedules/{id}`, `config/schedulesPaused`, `meta/name|timezone`. Device writes facts: `status`, `telemetry/current`, `measurements`, `history`, `alerts/{type}`, `gate/state`, command progress, `config/calibrationStatus`. Rules (`rules/rules.mjs` → `database.rules.json`, generated) enforce roles, device identity and payloads.
* Device identity: email/password Firebase account bound in `deviceRegistry/{fd}` (`deviceUid`, `status: active`, `mode: live`, `authMethod: password`) + `deviceAccounts/{uid}`. Simulator (emulator only) uses custom-token claims instead.
* Environments: app defaults to emulator (`demo-agrifeed`, 9099/9000/5001, 127.0.0.1); production by `--dart-define=AGRIFEED_ENV=production` (`agrifeed-dda82`). **Firmware is production-only** (HTTPS, pinned GTS roots, WiFiManager portal "AgriFeed-Setup"); it cannot talk to the emulator.
* Firmware: core 1 hardware loop (never blocks on network, gate auto-close local), core 0 network task: GET `gate/request` + `activeCommand` every 1 s, PUT `status`/`telemetry` every 5 s, GET `config`/`schedules` every 15 s. Schedules cached in NVS, run from clock/RTC offline. Feeding = open gate until hopper weight drops by target; reports measured grams.
* Pins (do not change): servo 18, buzzer 27, LCD 25/26, RTC 21/22, HX711 16/17.

## Working (verified this audit)
* `flutter analyze` clean; `flutter test` 65/65; rules tests 122/124 (2 = audit config artifact); rules file in sync.
* `audit/tests/firmware_contract.test.mjs` **44/44**: every firmware REST call with exact payloads is accepted by the rules; app writes/reads round-trip with the device side (manual feed, gate, schedules incl. weekdays-as-array, pause, alerts, history); role and device-identity restrictions hold.
* No path/field mismatch between app, firmware and rules.

## Confirmed problems
| ID | Sev | Summary | Where |
|---|---|---|---|
| C-1 | CRIT | Production rules not deployed; live rules unknown (legacy data present) | Console / `scripts/deploy-production-rules.mjs` |
| C-2 | CRIT | Production feeder/device not provisioned | `scripts/provision-production.mjs` |
| C-3 | CRIT | Firmware never compiled; 5 libraries missing; no CLI | Arduino toolchain |
| H-1 | HIGH | 401 treated as final → stuck `dispensing`, lost history, Feed button stays disabled | firmware l.896, 1039–1042; app `feeding_tab.dart:479` |
| H-2 | HIGH | `dispensing` PATCH unchecked; rules refuse `accepted→completed` | firmware l.1015–1017 |
| H-3 | HIGH | Google sign-in not configured for production (`oauth_client: []`) | `android/app/google-services.json` |
| H-4 | HIGH | Firmware not in version control | — |
| M-1…M-8 | MED | skipped schedules when busy; 4 unmapped time zones; offline timestamps; default portal password; phone-clock online check; polling load; health fields not shown; outdated `provision-device.mjs` | see issues file |

## Missing information
* Current live production rules (Console only).
* Whether the board compiles/runs; real HX711 calibration; whether the load cell carries the hopper; servo flow behaviour; actual Wi-Fi RSSI at the coop.
* Owner and device UIDs for provisioning; owner's chosen device-account email.
* Spark-plan bandwidth after a day of real polling.

## Exact files that need changes (after approval)
* `AgriFeed_code.ino`: l.87 (portal password), l.649–664 + 886–897 + 1029–1048 (H-1), l.1010–1017 (H-2), l.1066–1100 (M-1), l.733–743 (M-2), l.865 (L-1), l.788 (L-2). Then move into `firmware/` in the repo.
* `android/app/google-services.json` (re-download after adding SHA-1).
* Optional app: `lib/services/feeder_live.dart` (server time offset, M-5), `lib/features/feeder/tabs/settings_tab.dart` (health + hopper settings, M-7/L-5), `lib/features/feeder/tabs/feeding_tab.dart` (stuck-command display, H-1 safeguard), comments in `lib/main.dart:13`, `lib/core/env.dart:22`.
* Optional tooling: `scripts/provision-device.mjs` (retire or switch to password device).
* **No rules change is required** for the integration. Optional later: additive `history.occurredAt`.

## Recommended next actions (in order)
1. Stop orphan emulator PID 13140; re-run `npm run test:rules`.
2. Install libraries, compile the sketch (no upload).
3. Get approval → apply firmware fixes H-1, H-2, M-1, M-2, portal password; re-run the contract test.
4. Get approval → back up live rules, `npm run production:rules -- --confirm`.
5. Owner signs up in the production app; create device account; `npm run production:provision … --confirm`.
6. Upload firmware, configure via portal, calibrate, run the acceptance table in `RECOMMENDED_IMPLEMENTATION_PLAN.md` Phase 5.

## Tests still required
Firmware compile · first boot/TLS/sign-in on the board · monitoring, manual feed, gate, schedule, offline schedule, connectivity loss/recovery on real hardware · token refresh over > 1 h · second-account isolation in production · bandwidth after 24 h · `npm run test:functions` when Functions change.

## Rules for whoever continues
Emulator only unless the owner approves production; never deploy rules or provision without explicit approval; never upload firmware automatically; never change pins; one milestone at a time; do not commit without approval; PC is RAM-constrained (run emulator suites one at a time).
