# Recommended Implementation Plan (minimal changes)

Principle: the architecture is already correct and verified (one database, app writes requests, device writes facts,
rules enforce it). **No new schema, no second channel, no UI redesign, no pin change.** What is missing is mostly
*operations* (compile, deploy rules, provision) plus four small firmware fixes.

Every step marked 🔒 changes production or project code and needs your explicit approval first.

## Phase 0 — Local housekeeping (no approval needed, your PC only)
1. Stop the orphaned emulator and idle daemons: `taskkill /PID 13140 /T /F`, `cd android && gradlew --stop`.
2. Re-run `npm run test:rules` to confirm 124/124 with the project's own config.

## Phase 1 — Get the firmware building (no production impact)
3. Arduino IDE 2 (or `arduino-cli`) → Library Manager: **ESP32Servo** (Kevin Harrington), **LiquidCrystal I2C** (Frank de Brabander), **HX711** (bogde), **ArduinoJson 7.x**, **WiFiManager 2.0.x** (tzapu). RTClib already installed. Board package **esp32 by Espressif 3.x** (3.3.11 installed). Board: *ESP32 Dev Module*.
4. Verify (compile). Record warnings. Do not upload yet.
5. 🔒 Change `PORTAL_PASSWORD` (l.87) to a unit-specific value (M-4).

## Phase 2 — Small firmware fixes (🔒 firmware code; each a few lines)
6. **H-1:** make `dbCall` report "token expired" separately; in `postHistory` (l.896) and `reportJob` (l.1040) retry on expired-401 instead of treating it as final.
7. **H-2:** check the `dispensing` PATCH (l.1017); on failure retry once, else PATCH `failed` with a reason and do not dispense.
8. **M-1:** if a schedule is due while `job.active`, keep it pending and start it as soon as the job ends (same minute/next minute), or record `rejected` with a reason.
9. **M-2:** add DST-aware POSIX strings for Australia/Sydney, Europe/London, America/New_York, America/Los_Angeles to `tzToPosix`.
10. **L-1 / L-2:** clamp measurement weight ≥ −500; skip schedules with `amountG < 1`.
11. Re-run `audit/tests/firmware_contract.test.mjs` (payloads must stay identical) and compile again.
12. 🔒 Put the sketch under version control: `firmware/AgriFeed_code/AgriFeed_code.ino` (H-4).

## Phase 3 — Production preparation (🔒 every step)
13. Console → Realtime Database → Rules: copy the current live rules into a private file (backup). Confirm the data backup `backup-agrifeed-2026-10-31.json` is still current (or take a fresh one).
14. `npm run production:rules` (shows the check) → `npm run production:rules -- --confirm` (C-1).
15. Production app: `flutter run --dart-define=AGRIFEED_ENV=production`; owner creates an account with email/password, verifies the email, signs in once → note the UID (Console → Authentication).
16. Console → Authentication → Add user: device account (e.g. `feeder-01@<your-domain>`; long random password). Note its UID.
17. `npm run production:provision -- --owner-uid <owner> --device-uid <device>` (dry run, review output) → add `--confirm` (C-2). Note the printed `fd_…` feeder ID.
18. Optional (H-3): add SHA-1, enable Google provider, re-download `google-services.json`.

## Phase 4 — First hardware run (🔒 upload; HW tests)
19. Upload the sketch. Serial Monitor 115200: expect `RTC: OK`, `HX711: OK`.
20. Join Wi-Fi "AgriFeed-Setup" → farm Wi-Fi, feeder ID, device email, password → Save.
21. Expect Serial: `Signed in to Firebase as …`, `Clock synced from Firebase`, `Firebase: connected, feeder fd_…`. LCD shows `*`.
    If you see `Firebase refused feeder …` → registry/provisioning (step 17). `sign-in failed (400 …)` → email/password.
22. Calibrate: `t` with empty hopper on the cell, then `c` with a known weight.

## Phase 5 — End-to-end acceptance (the four scenarios from the brief)
| Scenario | Steps | Pass criteria |
|---|---|---|
| 1 Monitoring | put/remove a known weight | app weight changes within ~5 s; "Measured x ago" fresh; status online |
| 2 Manual feed | Feed 50 g | app: Waiting → Accepted → Dispensing → Completed/Partial with measured g; Activity shows entry; LCD "Feed x/50 g"; lock cleared |
| 2b Rejection | Feed with empty hopper / scale unplugged | `rejected`/`failed` with reason shown; no gate movement when rejected |
| Gate | OPEN 5 s, then CLOSE during open | ack < 2 s; countdown; auto-close; CLOSE wins; unplug Wi-Fi during open → gate still closes |
| 3 Schedule | schedule 2 min ahead, 50 g | ESP32 fetches ≤ 15 s; runs at HH:MM (phone & feeder both Asia/Manila); history `scheduled`; then pause → does not run |
| 3b Offline schedule | disconnect router, let a schedule run, reconnect | feeding happens; history appears after reconnect (timestamp = upload time — known limitation M-3) |
| 4 Connection | power the router off | app shows offline within ~30 s; controls disabled; router on → online again without reboot |
| Security | sign in as a second, unrelated account | sees no feeder; cannot read the feeder's data |
| Token | leave running > 2 h | no `401` loops in Serial; data keeps flowing |
| Usage | after 24 h | Console → RTDB → Usage: download per day × 30 < 10 GB |

## Phase 6 — Small app improvements (optional, 🔒 app code)
23. M-5: use `.info/serverTimeOffset` for online/countdown.
24. M-7: show condition (`error`/`unknown`), RSSI, firmware, calibration status in Settings → Controller.
25. L-5: hopper capacity / low threshold / max dispense fields for the owner (rules already allow).
26. H-1 safeguard: show "Give up" (display-only reset) for `accepted/dispensing` older than ~10 min — needs a decision, since rules do not let users change those statuses.
27. Update stale comments/docs (L-8).

## Deferred (decide later)
* Offline feeding timestamps (`occurredAt`) and NVS-backed history queue (M-3) — additive rules + app + firmware change.
* Emulator bench mode for the real ESP32 (M-8).
* Flash encryption for the device credential.
* Cloud Functions in production (needs Blaze) for admin/suspension; not needed for feeding.
