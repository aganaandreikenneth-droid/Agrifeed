# Integration Issues (prioritised)

Labels: **CONFIRMED** = proven by code reading plus a test or an unambiguous code path · **RISK** = can happen, not observed ·
**UNVERIFIED** = depends on something the audit could not see (hardware, production).
Fix type: CODE (app/firmware/rules), CONFIG, OPS (one-off action), HW (hardware test).

Firmware lines refer to `AgriFeed_code.ino`.

---

## CRITICAL — the integration cannot work until these are done

### C-1 Production rules not deployed; live rules unknown — UNVERIFIED (state) / CONFIRMED (not deployed by this project)
* **Evidence:** firmware and production app use `agrifeed-dda82` (l.80, `firebase_options.dart`). The deploy script exists (`scripts/deploy-production-rules.mjs`) but approval is pending; `lib/core/env.dart:22` comment wrongly says "rules are deployed". Production contains legacy data (`feeders/feeder1/logs`, `hopper/weightG`, `test/counter`) written by an older client, which suggests the live rules are permissive or legacy.
* **Why it matters:** with legacy/locked rules the ESP32 and the app are refused; with permissive (test-mode) rules anyone with the public API key can read/write the whole database.
* **Affects:** everything in production.
* **Fix (OPS, needs approval):** check Console → Realtime Database → Rules (copy the current text as a backup), then `npm run production:rules -- --confirm`. Rollback is available in the Console history.

### C-2 Production feeder and device not provisioned — CONFIRMED
* **Evidence:** backup shows no `deviceRegistry`, `deviceAccounts`, `userFeeders`, or `fd_…` feeder. `isDevice` (`rules.mjs:71–92`) needs registry `deviceUid`, `status: active`, `authMethod: password`, `mode: live`; contract test G proves writes fail without them.
* **Affects:** ESP32 writes (all refused, Serial prints "Firebase refused feeder … is this device account provisioned"), app shows no feeder.
* **Fix (OPS, needs approval):** (1) owner signs in once with the production app (verified email) to get a UID; (2) create the ESP32 email/password user in Console → Authentication; (3) `npm run production:provision -- --owner-uid <UID> --device-uid <UID>` (dry run), then with `--confirm`; (4) enter the printed feeder ID + device email/password in the "AgriFeed-Setup" portal.

### C-3 Firmware never compiled; libraries missing — CONFIRMED (not verified)
* **Evidence:** no arduino-cli/PlatformIO; ESP32Servo, LiquidCrystal_I2C, HX711, ArduinoJson, WiFiManager absent from `Documents\Arduino\libraries` (esp32 core 3.3.11 present). The sketch uses core-3.x-only APIs (`NetworkClientSecure`) and ArduinoJson 7 syntax.
* **Affects:** whether the board runs at all.
* **Fix (CONFIG/HW):** install the 5 libraries (versions in the sketch header), board "ESP32 Dev Module", Verify, then upload manually.

---

## HIGH

### H-1 A 401 is treated as permanent, so a feeding result can be lost and the app's Feed button stays blocked — CONFIRMED (code path) / RISK (trigger)
* **Where:** `postHistory` l.896 (`return code == 200 || code == 401`); `reportJob` l.1039–1042 (on 401: no history, lock deleted anyway).
* **Why:** `dbCall` returns 401 both for "refused by rules" and "token expired" (l.660). After an expired-token 401 the final command PATCH is not retried, so the command stays `dispensing` while the lock is removed.
* **Effect in the app:** `feeding_tab.dart:479` `busy = locked || (c != null && !c.finished)` → the newest command is stuck at `dispensing`, so the Manual Feed button stays **disabled** indefinitely. The "Give up" button only appears for `pending` (`feeding_tab.dart:480–484`), and the rules only let the user expire `pending` commands. The history entry for a real feeding is lost.
* **Trigger likelihood:** low (token refreshed 5 min early), but any 401 at that moment (e.g. H-2, registry edit) causes it.
* **Fix (CODE, firmware, minimal):** in `dbCall` expose whether the 401 was "expired"; in `postHistory` and `reportJob` return *retry* when it was. Optional app safeguard: treat `accepted/dispensing` older than e.g. 10 min as stale in the UI (display only — rules unchanged).

### H-2 `dispensing` PATCH result ignored → final status refused — CONFIRMED (rules test)
* **Where:** l.1015–1017; rules `rules.mjs:405–407` (`accepted → dispensing|failed|expired` only).
* **Evidence:** contract test D "RISK CHECK": `accepted → completed` returns 401.
* **Effect:** same as H-1 (stuck `dispensing`/`accepted`, lost history) whenever that one PATCH fails (Wi-Fi blip).
* **Fix (CODE, firmware):** if the `dispensing` PATCH is not 200, retry it before dispensing, or send `{"status":"failed","reason":"..."}` and do not dispense. No rule change needed.

### H-3 Google sign-in will fail in production — CONFIRMED (config)
* **Where:** `android/app/google-services.json` `"oauth_client": []`.
* **Fix (CONFIG):** add the debug/release SHA-1 in Console → Project settings → Android app, enable Google provider, re-download `google-services.json`. Email/password sign-in works meanwhile.

### H-4 Firmware is not under version control — CONFIRMED
* **Where:** sketch lives in `Downloads\AgriFeed_code\`. Its paths/payloads must match `rules/rules.mjs` exactly.
* **Fix (OPS):** copy to `firmware/AgriFeed_code/AgriFeed_code.ino` in the repo (after approval; no secrets are in the file besides the public API key and the default portal password).

---

## MEDIUM

### M-1 Scheduled feeding silently skipped if its minute coincides with another job — CONFIRMED (code path)
* **Where:** `checkSchedules` l.1067 returns early when `job.active`; matching is exact minute (l.1073). A manual feed (≤ 17 s) or result upload that spans the schedule's minute boundary, or any job lasting through the minute, means the schedule never runs and **no history** is written. (A gate-open state is handled: it records `rejected`.)
* **Fix (CODE, firmware):** remember "due but busy" and run it when idle within the same/next minute, or record `rejected` with reason.

### M-2 Time zone mismatch between app and firmware — CONFIRMED
* **Where:** app list `lib/core/timezones.dart` (8 zones) vs `tzToPosix` l.733–743. Australia/Sydney, Europe/London, America/New_York, America/Los_Angeles → fallback `PHT-8`; DST ignored.
* **Effect:** schedules fire at the wrong local hour for those zones (Asia/Manila — the actual farm — is correct).
* **Fix (CODE, firmware):** add POSIX strings with DST rules for the 4 zones (e.g. `AEST-10AEDT,M10.1.0,M4.1.0/3`, `GMT0BST,M3.5.0/1,M10.5.0`, `EST5EDT,M3.2.0,M11.1.0`, `PST8PDT,M3.2.0,M11.1.0`).

### M-3 Offline feedings get the upload time; queue is RAM-only — CONFIRMED (rules test)
* **Where:** rules `history.ts == now` (`rules.mjs:294`); firmware queue `pending[10]` l.711.
* **Effect:** Activity shows offline schedule results at reconnect time; up to 10 kept; all lost on reboot.
* **Fix:** documented limitation for now. Later: additive `occurredAt` field (rules + app + firmware), NVS-backed queue.

### M-4 Default Wi-Fi portal password and automatic portal — CONFIRMED
* **Where:** l.87 `PORTAL_PASSWORD` is a fixed default in source (value redacted); l.1204–1206 opens after 60 s without Wi-Fi.
* **Effect:** a nearby person who knows the default can reconfigure Wi-Fi/feeder ID (DoS). Stored device password is not revealed.
* **Fix (CONFIG):** set a unit-specific password before flashing.

### M-5 "Online" uses the phone's clock — RISK
* **Where:** `feeder_live.dart:80–83` compares server `lastSeen` with `DateTime.now()`; gate countdown similar (`feeding_tab.dart:271`).
* **Effect:** a phone clock off by > 30 s shows the feeder offline (and disables controls) or online when it is not.
* **Fix (CODE, app, small):** use `.info/serverTimeOffset` in `FirebaseFeederLive`.

### M-6 Polling load vs Spark plan — RISK / UNVERIFIED
* ~2.5 REST requests/s continuously (1 s polls of `gate/request` and `activeCommand`). Estimated 2–4 GB/month download against 10 GB on Spark.
* **Fix:** measure first; if needed, poll `activeCommand`/`gate/request` every 2 s when idle, or use the REST streaming API.

### M-7 Device health shown only partially in the app — CONFIRMED
* `status.condition` `error`/`unknown`, `rssi`, `firmware`, `config/calibrationStatus`, `telemetry.quality` are written but not displayed (only `jam` is, `home_tab.dart:143`). The `sensor_error` alert does reach the bell.
* **Fix (CODE, app, small):** show condition, RSSI and calibration in Settings → Controller.

### M-8 Outdated emulator device tooling — CONFIRMED
* `scripts/provision-device.mjs` writes `agrifeed_device.h` with a custom token; the current sketch does not include it. No supported way to bench-test the real ESP32 against the emulator.
* **Fix:** either retire the script or update it to create an email/password device in the emulator (see ENVIRONMENT_CONNECTIVITY_AUDIT §2), plus an optional firmware emulator switch (approval needed).

---

## LOW

| ID | Issue | Where | Fix |
|---|---|---|---|
| L-1 | Measurement `weightG` not clamped to ≥ −500 → rejected every minute if tare drifts | l.865 | clamp like telemetry (l.850) |
| L-2 | Schedule with missing/0 `amountG` parsed and later cannot be recorded (rules `requestedG ≥ 1`) | l.788, `rules.mjs:291` | skip `amountG < 1` |
| L-3 | Only 16 schedules kept; extra silently ignored; app has no limit | l.780 | note in UI or cap in app |
| L-4 | RTC set to compile time (PC local time) after power loss until online | l.1284 | acceptable; corrected by `syncRtc` |
| L-5 | Hopper capacity / low threshold / max dispense not editable in app (rules allow owner) | `settings_tab.dart` | add fields (planned M3) |
| L-6 | `measurements` grow forever (1/min), never read | firmware l.1259 | retention later |
| L-7 | `dispense_failed` alert type defined in app/rules, never written | `feeder_repository.dart:40` | none / later |
| L-8 | Stale comments: `main.dart:13` ("emulator only"), `env.dart:22` ("rules deployed"); `docs/core-milestones.md` says "no ESP32 work yet" | | update docs |
| L-9 | Legacy production data `feeders/feeder1`, `test/counter` becomes unreachable after rules deploy | backup | keep backup; delete later if wanted |
| L-10 | Orphaned DB emulator (PID 13140) + 7 Gradle daemons on a RAM-constrained PC | local | `taskkill /PID 13140 /T /F`, `gradlew --stop` |

## Explicitly checked and NOT a problem
* Path mismatches between Flutter, firmware and rules: **none** (all 14 firmware calls and all app writes verified).
* Field the app expects that the device never writes: none critical (`weightG`, `measuredAt`, `lastSeen`, `condition`, gate fields, command outcome fields all written).
* Field the firmware expects that the app never creates: none (`time`, `amountG`, `enabled`, `weekdays`, `schedulesPaused`, `lowThresholdG`, `timezone`, `commandId`, `requestedAt`, gate `id/action/durationS/requestedAt`).
* Weekdays object/array: handled on both sides.
* Ordered-query indexes: all present.
* Device claims vs rules: match for the password flow.
* Pins: unchanged.
