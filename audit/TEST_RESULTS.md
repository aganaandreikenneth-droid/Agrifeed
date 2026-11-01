# Test Results — 2026-10-31

All tests ran locally on the emulator. Nothing touched production, no firmware was uploaded, no project file was changed.

| # | Test | Command | Result |
|---|---|---|---|
| 1 | Rules file in sync with source | `node rules/build.mjs --check` | ✔ "database.rules.json is up to date." |
| 2 | Static analysis | `flutter analyze` | ✔ **No issues found** (82.6 s). 21 packages have newer, constraint-incompatible versions (informational). |
| 3 | Flutter unit/widget tests | `flutter test` | ✔ **65 / 65 passed** |
| 4 | Repository rules tests | `npx vitest run tests/rules` (env: `FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9400`, `FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9199`) | **122 passed, 2 failed** — see note A |
| 5 | **ESP32 ⇄ rules ⇄ app contract** (new, audit) | `npx vitest run audit/tests/firmware_contract.test.mjs` (same env) | ✔ **44 / 44 passed** |
| 6 | Emulator / port probe | curl + TCP probes | see ENVIRONMENT_CONNECTIVITY_AUDIT §2 |

Emulator used for 4 and 5: `firebase --config audit/tests/firebase.audit.json emulators:start --project demo-agrifeed --only auth,database`
(127.0.0.1:9199 / :9400, rules = byte-identical copy `audit/tests/database.rules.json`, SHA-256 `958ac106…5829321`).
Separate ports were needed because an orphaned database emulator holds :9000 (not stopped by the audit). The audit emulator was stopped after the run.

**Note A — the 2 failures are caused by the audit setup, not the project.** `tests/rules/rules_config.test.mjs` checks that the
second namespace `demo-agrifeed-default-rtdb` has rules loaded. The audit config loaded rules only into `demo-agrifeed`.
The project's own `npm run test:rules` loads both namespaces from `firebase.json`; the last recorded run of the full suite
(`docs/review/phase2/evidence/01-rules-tests.txt`) shows 120/120 passed (fewer tests existed then). Re-run `npm run test:rules` after stopping PID 13140 to confirm.

## Contract test coverage (test 5)

| Group | What is verified |
|---|---|
| A. Auth (3) | `signInWithPassword` response fields (`idToken`, `refreshToken`, `expiresIn` as string); wrong password → 400; refresh grant (`id_token`, `refresh_token`, `expires_in`) gives a working token. |
| B. First contact + reporting (10) | Every boot/periodic call of the sketch with its exact payload: lastRequestId GET, calibrationStatus PUT, timezone/config/schedules GET, status PUT (response `lastSeen` is a number → clock sync works), telemetry PUT, alert PATCH→PUT fallback, alert resolve keeps `firstAt`, resolve-of-nothing → 401, gate/state PUT, measurements POST. |
| C. Firebase → Flutter (3) | Owner reads all device data incl. ordered alerts query; viewer member reads status + ordered history; outsider, suspended member and another feeder's ESP32 are refused. |
| D. Manual feed (10) | App multi-path command+lock; second command refused while locked; device reads and checks freshness; `accepted→dispensing→completed` with `actualG`; history POST + lock DELETE; app sees result via `orderBy requestedAt limitToLast 1` and history; early reject path; **risk: accepted→completed refused**; member with `manualFeed` ✔, viewer ✗, suspended ✗; device cannot create commands or pose as simulator. |
| E. Gate (3) | request → device read within 10 s by server time → state with `lastRequestId`/`closesAt`; rejection report; `durationS 20` and viewer request refused. |
| F. Schedules (8) | App schedule write; **device receives weekdays as a JSON array**; amount > maxDispenseG refused; pause/resume round trip; scheduled history; **risk: requestedG 0 refused; device-side timestamp refused**; delete round trip. |
| G. Device identity (7) | Unbound password account ✗; other feeder's device ✗; device cannot read alerts/members/userFeeders; device not treated as a person; registry `disabled` revokes immediately; missing `authMethod` ✗; `mode: simulated` + `source: device` ✗. |

## Tests NOT performed, and why

| Test | Reason | What is needed |
|---|---|---|
| Firmware compile | No `arduino-cli`/PlatformIO/Arduino IDE CLI on this PC; libraries ESP32Servo, LiquidCrystal_I2C, HX711, ArduinoJson 7, WiFiManager 2.0 are not installed (esp32 core 3.3.11 is). Installing tools was not part of the authorised scope. | Arduino IDE (or `arduino-cli`) + Library Manager installs, board "ESP32 Dev Module", then Verify. |
| Upload / run on ESP32 | Forbidden in this phase; no board attached. | Owner uploads manually. |
| Physical hardware ⇄ Firebase | No hardware, and the firmware only talks to production (not authorised). | **Unverified.** Compile success alone would not prove it. |
| TLS handshake with the pinned roots on the ESP32 | needs the board | Serial log "Signed in to Firebase as …" on first run. |
| Production rules / data | Not authorised. Live production rules could not be read from the CLI earlier. | Owner checks Console. |
| Cloud Functions suites (`npm run test:functions`) | Not needed for device integration (Functions never touch device paths); heavy on this RAM-constrained PC. Last recorded run: `docs/review/phase2/evidence/02-functions-tests.txt`. | Run when Functions change. |
| Flutter on a device/emulator against the emulator + simulator | Not part of the safe automated set; requires an Android emulator/phone. Recorded earlier in `docs/core-milestones.md`. | Manual test M6. |
| Token expiry (1 h) behaviour of the firmware | Needs a long-running board. | Leave the board running > 1 h; watch for `401 expired` in Serial. |
| Spark-plan bandwidth | Needs live traffic. | Check Console → Realtime Database → Usage after day 1. |

## Files created by the tests
`audit/tests/firebase.audit.json`, `audit/tests/database.rules.json` (copy), `audit/tests/firmware_contract.test.mjs`.
Emulator data was in-memory only (no export).
