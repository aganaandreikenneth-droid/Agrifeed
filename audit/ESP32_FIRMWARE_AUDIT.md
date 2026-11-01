# ESP32 Firmware Audit

File: `C:\Users\Lenovo\Downloads\AgriFeed_code\AgriFeed_code.ino` (1,408 lines, `FIRMWARE "esp32-2.0"`, modified 2026-10-31 19:37).
Not in the git repository. **Not compiled and not run on hardware during this audit** (see TEST_RESULTS).

## 1. Hardware (unchanged from the original test sketch)

| Part | Pins / bus | Firmware handling |
|---|---|---|
| Servo gate | GPIO18, 50 Hz, 500–2500 µs, 0° closed / 90° open | starts closed; `openGate/closeGate` non-blocking; beep on each move |
| Buzzer | GPIO27 (active-high by default) | non-blocking beeps |
| LCD 16×2 I2C 0x27 | SDA 25 / SCL 26 (`Wire`) | line 1 time + gate + link (`*` online, `!` offline, `W` portal); line 2 weight/progress |
| RTC DS3231 | SDA 21 / SCL 22 (`Wire1`) | set to compile time on power loss; seeds the clock at boot; corrected from server time every 60 s when > 2 s off |
| HX711 | DT 16 / SCK 17 | non-blocking `is_ready()`; light smoothing; tare + factor saved in NVS; "stopped responding" after 2 s |
| BOOT button | GPIO0 | hold 3 s → Wi-Fi portal |

Pins match the brief exactly (l.143–150). **No pin change is proposed.**

## 2. Structure

* **Core 1 `loop()`**: Serial commands (`t c r s w x`), BOOT button, `updateWeight`, `updateGate` (state machine `IDLE/GATE/DISPENSE/SETTLE/CALIBRATING`), buzzer, LCD. Never touches the network. Gate auto-close and dispense limits run here, so they work with no Wi-Fi.
* **Core 0 `networkTask`** (20 KB stack): WiFiManager, sign-in, polling, reporting, schedules. Talks to core 1 through `cmdQueue` (8), `resultQueue` (4) and a spin-locked `Snapshot`.
* `calibrate()` blocks `loop()` while waiting on Serial input (servo closed first) — acceptable, it is a bench operation.

## 3. Feeding logic (load cell under the hopper)

`handleHwCommand/updateGate` (l.307–387): open gate; stop when `given ≥ target − 5 g`, or no flow (`< 3 g` after 4 s), or 15 s, or scale lost, or CLOSE; settle 2 s; `actual = start − now`.
Result: `completed` (≥ 90 %), `partial`, `failed` (no flow → also `stuckFeed`, 800 ms beep). Busy/unready → `rejected`.

Hardware assumptions still to confirm physically (HARDWARE TEST): the load cell really carries the hopper; feed actually flows within 4 s at 90°; `DISPENSE_LEAD_G = 5` matches the falling-feed overshoot; servo torque at 90°; 3 kg cell vs 2.5 kg capacity + hopper tare (tare is taken once on the very first boot with whatever is on the scale).

## 4. Configuration and provisioning

| Item | Value / source | Notes |
|---|---|---|
| Project / DB | `agrifeed-dda82-default-rtdb.firebaseio.com` (l.80) | **production only**; no emulator mode |
| Web API key | hard-coded (l.79), equals the Android key in `lib/firebase_options.dart` | public identifier, not a secret (redacted in this report) |
| TLS | GTS Root R1 + R4 pinned (valid to 2036) | correct roots for `*.firebaseio.com` / `*.googleapis.com` |
| Wi-Fi, feeder ID, device email/password | WiFiManager portal "AgriFeed-Setup", saved in NVS | portal password: a fixed default hard-coded at l.87 (value not repeated here) |
| Time zone | `meta/timezone` → `tzToPosix()` | 8 names; fallback `PHT-8` |

## 5. Authentication (task 6 of the brief)

| Question | Answer (evidence) |
|---|---|
| 1. How does the ESP32 obtain its credential? | A dedicated **email/password Firebase Auth account** created by the owner in the Console; email + password typed into the WiFiManager portal, stored in NVS (`saveParams` l.547). No custom token any more. |
| 2. How is it validated? | `POST identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=…` (l.625). 400 → `accountRejected`, retry every 60 s; other failures every 10 s. |
| 3. Custom-token exchange? | **None** in the current sketch. Custom tokens remain only for the Node simulator (emulator) and the outdated `scripts/provision-device.mjs`. |
| 4. Where is the ID token stored? | RAM (`String idToken, refreshToken`, l.526); never in flash; not printed. |
| 5. Refresh | `POST securetoken.googleapis.com/v1/token` with `grant_type=refresh_token`, 5 min before `expiresIn` (l.600–617); falls back to password sign-in. Verified response field names in the emulator. |
| 6. Expired token | `dbCall` sees `401` with "expired" in the body → `tokenRefreshAt = now` (l.660). ⚠ The *current* request is not retried; for history POST and final command PATCH a 401 is treated as permanent (ISSUE H-1). |
| 7. Identity ↔ feeder | Rules: `auth.uid == deviceRegistry/{feederId}/deviceUid`, `status == active`, `authMethod == 'password'`, provider `password`. The feeder ID typed in the portal only selects the URL; the rules decide. |
| 8. deviceRegistry validation | Live on every request (revocation immediate — verified). |
| 9. Claims vs rules | Match (verified with the emulator's real tokens: provider `password`, no `device` claim). |
| 10. Emulator vs production | Rules accept the same password flow in both, but **the firmware can only reach production** (hard-coded HTTPS host, Google endpoints, pinned CA). Emulator testing of the real board is impossible without a firmware change; the audit's contract test replays the calls instead. |

Security assessment:
* ✔ Least privilege: the device account can write only its own feeder's device paths and cannot read alerts, members, users.
* ✔ Passwords are not printed (`s` prints the email only); tokens are not printed.
* ⚠ NVS is not encrypted: anyone with physical access + USB can read the device password (flash dump). Mitigation: enable flash encryption later, or revoke via registry if a unit is lost.
* ⚠ Portal password is a fixed default in source and the portal **opens automatically after 60 s without Wi-Fi**; a nearby person who knows the default can change the Wi-Fi/feeder ID (denial of service; they cannot read the stored password — the field is blank = keep). Change `PORTAL_PASSWORD` per unit.
* ✔ The ID token travels in the URL query (`?auth=`) over pinned TLS — standard for the RTDB REST API.

## 6. Reads, writes, intervals

See `DATA_FLOW_MAP.md` §A/§B for the full tables. Summary of network load when idle:
`GET gate/request` + `GET activeCommand` every 1 s, `PUT status` + `PUT telemetry/current` every 5 s,
`GET config` + `GET schedules` every 15 s, `POST measurements` + `GET meta/timezone` every 60 s.
≈ 2.5 requests/s ≈ 215 k requests/day. Possible risk (unverified): RTDB download quota on the Spark plan (10 GB/month)
— the REST responses are small, but per-request overhead is counted; estimate 2–4 GB/month. Measure in the Console
(Usage tab) during the first live day.

## 7. Offline / reconnect behaviour

* Wi-Fi retry every 20 s; after 60 s offline the portal also opens (5 min timeout). Feeding and schedules continue.
* `netOnline` = a successful DB call within 15 s; on reconnect the full first-contact sequence runs again.
* History queue: 10 entries in RAM — **lost on reboot/power cut**; oldest dropped when full.
* Schedules, tz, low threshold, paused flag cached in NVS → schedules run after a reboot with no network (RTC time).

## 8. Findings specific to the firmware (details in INTEGRATION_ISSUES.md)

| ID | Line(s) | Summary |
|---|---|---|
| H-1 | 896, 1040–1042 | 401 treated as permanent for history and final command result → can leave a command stuck in `dispensing` and lose history. |
| H-2 | 1014–1017 | `dispensing` PATCH result ignored; final status then refused by rules. |
| M-1 | 1067 | A schedule whose minute falls while another feeding/gate job is active is skipped with no record. |
| M-2 | 733–743 | 4 of the app's 8 time zones are unmapped (fallback PHT-8); no DST. |
| M-3 | 708–712, 917 | Offline history stamped with upload time; RAM-only queue. |
| M-4 | 87, 1204–1206 | Default portal password + auto-open portal. |
| L-1 | 865 | Measurement weight not clamped to ≥ −500 (rules reject). |
| L-2 | 788 | Schedule with missing/0 `amountG` accepted and then cannot be recorded. |
| L-3 | 780 | >16 schedules silently ignored. |
| L-4 | 1284 | RTC set to compile time on power loss (PC local time) until server time is known. |
| — | — | Not in version control. |
