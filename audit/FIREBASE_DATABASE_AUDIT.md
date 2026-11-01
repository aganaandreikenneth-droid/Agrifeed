# Firebase Realtime Database Audit

Source of truth for the schema: `rules/rules.mjs` (the rules define every allowed field) plus the writers
(`scripts/provision-production.mjs`, `scripts/seed-emulator.mjs`, `lib/services/*`, firmware).

## 1. Top-level structure

| Node | Written by | Read by | Used by firmware? |
|---|---|---|---|
| `users/{uid}` | app (own profile) | own / admin | no |
| `accountStatus/{uid}` | Functions / scripts | own, admin | no |
| `userFeeders/{uid}/{feederId}` | provisioning / Functions | own | no |
| `feeders/{feederId}/…` | app, device, backend | members, device | **yes** |
| `deviceRegistry/{feederId}` | provisioning only | admin (and rules) | indirectly (rules check it) |
| `deviceAccounts/{uid}` | provisioning only | admin (and rules) | indirectly |
| `platformAdmins`, `platformAudit`, `platformConfig` | backend | admin | no |
| `notifications/{uid}`, `notificationPreferences/{uid}` | backend / own | own | no (nothing generates notifications yet) |
| `deviceClaims`, `invitations`, `inviteCodes`, `userQuotas`, `rateLimits` | Functions only | nobody (client) | no |

## 2. `feeders/{feederId}` — field-by-field comparison

✔ = matches; ⚠ = mismatch or gap. "App" = Flutter.

### meta (backend; owner may change `name`, `timezone`)
| Field | Writer | App reads | Device reads | Notes |
|---|---|---|---|---|
| name | provisioning, owner | ✔ | — | |
| ownerUid, mode, createdAt | provisioning | ✔ (mode → SIMULATION badge) | — | rules use `meta/ownerUid` for owner check |
| timezone | provisioning, owner | ✔ | ✔ `meta/timezone` | ⚠ app offers 8 zones (`lib/core/timezones.dart`); firmware maps only Asia/Manila, UTC, Asia/Singapore, Asia/Tokyo (+ a few unoffered). **Australia/Sydney, Europe/London, America/New_York, America/Los_Angeles fall back to PHT-8** → schedules at the wrong hour; DST not handled. |
| archivedAt | Functions | ✔ | — | firmware ignores; device writes still allowed for archived feeders (by design, comment `rules.mjs:97`). |

### config
| Field | Writer | App reads | Device reads | Notes |
|---|---|---|---|---|
| capacityG | provisioning (2500), owner | ✔ fill % | — | ⚠ no app UI to edit (M3 said "editable"). |
| lowThresholdG | provisioning (500), owner | ✔ | ✔ low-feed alert/condition | ⚠ no app UI to edit. |
| maxDispenseG | provisioning (200), owner | ✔ presets | — (rules enforce on commands/schedules) | firmware has its own 15 s gate cap. |
| loadCellMaxG | provisioning (3000) | — | — | backend-only. |
| schedulesPaused | `manageSchedules` | ✔ | ✔ | ✔ |
| calibrationStatus | device | ✗ not displayed | — | ⚠ app never shows it. Factor/offset stay in ESP32 flash. |

### status (device)
`{lastSeen, condition, rssi, firmware, source}` — ✔ exact match between firmware, simulator and rules.
App uses `lastSeen`, `source`, and `condition` — but only the value `jam` is shown (`home_tab.dart:143`); ⚠ `condition: "error"` / `"unknown"` and `rssi` / `firmware` are written by the device but never displayed (grep of `lib/features` finds no other use).

### telemetry/current (device)
`{weightG, measuredAt, quality, source}` — ✔ match. ⚠ app ignores `quality` ("unstable" while the gate is open). When the HX711 fails the firmware **stops** writing telemetry; the app keeps showing the last weight, but labels it "Measured x ago" and `status.condition = "error"` plus a `sensor_error` alert are written, so the failure is visible.

### measurements (device, POST)
`{weightG, ts, source}` — ✔ rules. ⚠ **No app reader** (analytics not built). Firmware writes 1 per minute ≈ 1,440 records/day forever — no retention/cleanup exists.

### history (device, create-only)
`{method, requestedG, actualG?, status, ts, source, commandId|scheduleId}` — ✔ match.
⚠ `ts` must equal server `now` → offline schedule results get the **upload** time, not the feeding time (documented in firmware l.708–709; verified in contract test F).
⚠ `requestedG` must be 1–500; a schedule with missing `amountG` (firmware default 0) cannot be recorded (verified).
App: missing `actualG` → shown as 0 g (`feeder_live.dart:141`).

### alerts/{type} (device)
Device uses fixed keys `low_feed`, `stuck_feed`, `sensor_error`. ✔ rules (type list also allows `dispense_failed`, which nothing writes). Device cannot read alerts; PATCH-then-PUT pattern verified working.

### schedules/{sid} (app)
`{time, weekdays{"0".."6"}, amountG, enabled, label?, createdAt, updatedAt, updatedBy}` — ✔.
Weekdays are written as an object with keys "0"–"6" but **RTDB returns them as a JSON array** (verified). Both app (`feeder_live.dart:202`) and firmware (l.790–793) handle both shapes. ✔
Firmware limit: 16 schedules (extra ones silently ignored); app has no limit.

### activeCommand / commands/{cid}
✔ exact match of field names and status transitions between app, firmware and rules:
`pending → accepted|rejected|expired`, `accepted → dispensing|failed|expired`, `dispensing → completed|partial|failed`.
⚠ The firmware sends `accepted` and `dispensing` as two separate PATCHes and does not check the second one (l.1015–1017). If it fails, the final `completed/partial` is invalid (`accepted → completed` not allowed — verified 401) — see ISSUE H-2.

### gate/request (app) and gate/state (device)
✔ exact match. `id` is an RTDB push id (20 chars, within `str(8,64)`). `closesAt` is computed from the learned server offset.

### simulator/controls
Simulated feeders only; production provisioning sets `mode: live`, so it is unused for the real machine. ✔ isolation verified (contract test G).

### members, invites, audit
Backend only. Not used by firmware.

## 3. Indexes required by ordered queries

| Query | Index in rules | Status |
|---|---|---|
| `history` orderBy `ts` | `history/.indexOn: ['ts']` | ✔ |
| `commands` orderBy `requestedAt` | `commands/.indexOn: ['requestedAt']` | ✔ |
| `alerts` orderBy `lastAt` | `alerts/.indexOn: ['lastAt']` | ✔ |
| `measurements` by `ts` (none yet) | ✔ present | |
| `notifications/{uid}` by `ts` | ✔ | |
| `platformAudit` by `ts` | ✔ | |
| `invites` by `status` | ✔ | |

## 4. Production database (from the 2026-10-31 backup, read-only)

`backup-agrifeed-2026-10-31.json` (git-ignored) shows production currently contains only a **legacy schema**:
`feeders/feeder1/{history, hopper/weightG, logs, schedules, status{condition,lastSeen,rssi}}` and `test/counter`.
None of `deviceRegistry`, `deviceAccounts`, `userFeeders`, `meta`, `config`, `members` exist yet.
Consequences:
* The current app and firmware cannot use `feeder1` (no meta/members/registry; different field names, e.g. `hopper/weightG` vs `telemetry/current/weightG`, `logs` vs `history`).
* The legacy data was apparently written by an older client, which suggests the **currently live production rules are permissive or legacy** — unverified (live rules could not be read from the CLI; must be checked in the Console).
* `provision-production.mjs` creates a **new** `fd_…` feeder; legacy `feeder1` stays untouched (good) but becomes inaccessible once the new rules are deployed (no rule grants it).

## 5. Data-type check (firmware JSON vs rules)

| Field | Firmware type | Rule | OK |
|---|---|---|---|
| weightG | `int` (lround), clamped ≥ -500 for telemetry; **not clamped for measurements** | number −500…100000 | ✔ / ⚠ measurement rejected if tare drifts below −500 g |
| rssi | int clamped −150…0 | number −150…0 | ✔ |
| actualG | int ≥ 0, omitted if −1 | 0…2000 | ✔ |
| requestedG | int from command/schedule | 1…500 | ✔ (⚠ 0 if schedule lacks amountG) |
| closesAt | long long ms | number | ✔ |
| timestamps | `{".sv":"timestamp"}` | `== now` | ✔ |
| calibrationStatus | JSON string | enum | ✔ |
| commandId/scheduleId | push id ≤ 39 chars buffer | str 1–64 | ✔ |
