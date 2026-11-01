# Firebase Rules Audit

Rules source: `rules/rules.mjs` (475 lines) → `database.rules.json` (generated; `node rules/build.mjs --check` = up to date,
SHA-256 `958ac106…5829321`). Verification: repo suite `tests/rules` (122/124 pass) and the audit contract test
`audit/tests/firmware_contract.test.mjs` (44/44 pass), both on the emulator. **Nothing was deployed.**

## 1. Identity model (as implemented)

| Identity | Definition (`rules.mjs`) | Notes |
|---|---|---|
| Person (`isHuman`, l.33) | signed in, not `token.device`, `email_verified == true`, **not** in `deviceAccounts` | Google accounts are verified automatically; email/password users must verify. |
| User (`isUser`, l.41) | person and `accountStatus/{uid}/suspended != true` | suspension takes effect on the next request. |
| Admin (l.44) | user + `admin` claim + `platformAdmins/{uid} == true` | claims need Admin SDK/Functions. |
| Active member / owner / `hasPerm(p)` (l.50–64) | `members/{uid}.status == active`, not expired; owner also needs `meta/ownerUid == uid` | owner has all permissions. |
| Device (`isDevice`, l.71) | `auth.uid == deviceRegistry/{id}/deviceUid` and registry `status == active`, **and either** (a) custom-token claims `device, feederId, mode, credVersion` matching the registry, **or** (b) `sign_in_provider == 'password'` and registry `authMethod == 'password'` | (a) = Node simulator (emulator); (b) = the real ESP32. Checked live → revocation immediate. |
| Source match (l.104) | registry `mode == live` ⇒ `source == 'device'`; `simulated` ⇒ `'simulator'` | keeps simulated and real data apart. |

## 2. Permissions matrix

Legend: ✔ allowed and used · ✔ₙ allowed but not used · ✗ denied · — not applicable. "Verified" = exercised in emulator tests this audit.

| Feature / path | Flutter read | Flutter write | ESP32 read | ESP32 write | Current rule | Verified |
|---|---|---|---|---|---|---|
| `meta` | ✔ active member | owner: `name`, `timezone` | ✔ `meta/timezone` | ✗ | `.read: member‖device` | ✔ |
| `config` | ✔ member | owner: capacity/threshold/max (✔ₙ, no UI); `schedulesPaused`: manageSchedules | ✔ | `calibrationStatus` only | per-field | ✔ |
| `status` | viewDashboard | ✗ | ✔ₙ | ✔ PUT | device + source match, `lastSeen == now` | ✔ |
| `telemetry/current` | viewDashboard | ✗ | ✔ₙ | ✔ PUT | same | ✔ |
| `measurements` | viewAnalytics‖viewHistory (✔ₙ, no reader) | ✗ | ✗ | ✔ POST (create only) | | ✔ |
| `history` | viewHistory‖viewAnalytics | ✗ | ✗ | ✔ POST (create only) | `ts == now`, requestedG 1–500 | ✔ |
| `alerts` | viewDashboard | ✗ | **✗** (not needed) | ✔ PUT/PATCH | `firstAt` set once | ✔ |
| `schedules` | viewDashboard‖manageSchedules | manageSchedules (create/edit/delete) | ✔ | ✗ | amount ≤ maxDispenseG ≤ 500 | ✔ |
| `activeCommand` | manualFeed‖viewDashboard | manualFeed: create with its command; release when terminal | ✔ | DELETE only | | ✔ |
| `commands` | manualFeed‖viewHistory | create `pending` (with lock); expire after 120 s | ✔ | PATCH existing (status machine, outcome fields device-only) | | ✔ |
| `gate/request` | viewDashboard | manualFeed | ✔ | ✗ | durationS 1–15, `requestedAt == now` | ✔ |
| `gate/state` | viewDashboard | ✗ | ✔ | ✔ PUT | | ✔ |
| `simulator/controls` | owner (simulated only) | owner (simulated only) | device (simulated only) | ✗ | | ✔ |
| `members` | owner (all) / self | ✗ (Functions) | ✗ | ✗ | | ✔ (repo tests) |
| `userFeeders/{uid}` | own | ✗ | ✗ | ✗ | | ✔ |
| `users/{uid}` | own | own create + displayName + lastSelectedFeederId | ✗ | ✗ (device is not a person) | | ✔ |
| `accountStatus/{uid}` | own (even if suspended) | ✗ | ✗ | ✗ | | ✔ |
| `deviceRegistry`, `deviceAccounts` | admin | ✗ | ✗ | ✗ | backend-only | ✔ |

Role checks verified in the emulator: owner ✔, member with `manualFeed` ✔, viewer (no `manualFeed`) ✗ feed / ✗ gate,
suspended member ✗ read and ✗ write, outsider ✗ read, unbound password account ✗, ESP32 of another feeder ✗,
registry `disabled` ✗ (immediate), registry without `authMethod` ✗, registry `simulated` + `source:device` ✗.

## 3. Can every legitimate operation happen?

**Firmware → rules: yes.** Every request in the sketch (14 distinct path/method pairs, exact payloads) is accepted when the
registry is provisioned (`status: active`, `mode: live`, `deviceUid`, `authMethod: password`). No rule blocks a
legitimate firmware operation. The two "refusals" the sketch relies on are intentional and verified:
`PATCH alerts/<new>` without `firstAt` → 401 → falls back to PUT; resolving a never-created alert → 401 → treated as done.

**App → rules: yes** for every feature present in the UI (feed, expire, gate, schedules CRUD, pause, rename, time zone,
simulator controls, profile).

## 4. Rule findings (no rule change is required for the integration)

| # | Finding | Severity | Evidence | Smallest secure fix |
|---|---|---|---|---|
| R-1 | Rules are **not deployed to production**; live production rules are unknown and the production DB holds legacy data written by an old client (suggests permissive/legacy rules). | CRITICAL (production) | `env.dart:22` comment claims deployed; memory/handoff: not approved; backup shows `feeders/feeder1/logs…` | Owner checks Console → Rules, then `npm run production:rules -- --confirm` (approval needed). |
| R-2 | `commands` status machine has no `accepted → completed/partial`. Firmware sends `dispensing` as a separate unchecked PATCH; if it is lost the final result is refused. | HIGH (combined with firmware) | `rules.mjs:405–407`; contract test D "RISK CHECK" → 401 | Fix in **firmware** (send `accepted`→`dispensing` and check, or retry `dispensing`) — no rule change needed. Alternative rule change (allow `accepted → completed|partial` for device) is acceptable but not preferred. |
| R-3 | `history.ts` and all device timestamps must be server `now`; offline schedule results lose their real time. | MEDIUM | `rules.mjs:294`; contract test F | Optional, additive: allow device field `occurredAt` (number, `<= now`, `> now - 7 days`) in `history` and have the app prefer it. Requires app + firmware + rule change; propose only after approval. |
| R-4 | `history.requestedG` min 1 rejects a "rejected" record for a schedule with amount 0/missing. | LOW | `rules.mjs:291`; contract test F | Firmware: skip schedules with `amountG < 1` when parsing. |
| R-5 | `isDevice` (password variant) does not check `credentialVersion`; rotation relies on changing the password (which revokes refresh tokens) or on changing `deviceUid`/`status`. Existing ID tokens remain valid up to 1 h after a password change **unless** the registry is changed too. | LOW | `rules.mjs:86–90` | Document: on compromise set registry `status: disabled` first (immediate), then rotate password. No change needed. |
| R-6 | Device may write to an **archived** feeder (by design). | INFO | `rules.mjs:97` comment | none |
| R-7 | `firebase.json` names only emulator instances; production instance appears only in the deploy script's temp config. | INFO | `firebase.json:27–36`, `deploy-production-rules.mjs:22–25` | none (deliberate safety). |
| R-8 | Simulator path still requires custom-token claims (Admin SDK). Works in emulator only; production has no service account → only the password path is usable in production. | INFO | `rules.mjs:77–82` | none |

## 5. Things checked and found correct

* No `.read`/`.write` granted on `feeders/$feederId` itself (no cascading grants).
* Every `.write` states create/update/delete explicitly; deletes are restricted (`activeCommand`, `schedules`, `notifications`).
* Outcome fields (`actualG`, `acceptedAt`, `completedAt`, `reason`, `executedBy`) can only be written by the device.
* `requestedBy`, `updatedBy`, gate `requestedBy` are bound to `auth.uid`.
* Device accounts are excluded from being treated as people (`deviceAccounts` check), so an ESP32 credential cannot read user data.
* Indexes exist for every ordered query the app issues.
