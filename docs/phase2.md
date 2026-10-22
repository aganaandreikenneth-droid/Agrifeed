# AgriFeed — Phase 2: Virtual feeders, ownership, members, feeder selection

Phase 2 is delivered in milestones 2A–2F (see `AGRIFEED_HANDOFF.md` §9). This file records each
milestone as it is completed. Everything runs in the local Firebase Emulator Suite
(`demo-agrifeed`); production (`agrifeed-dda82`) is untouched and nothing is deployed.

Owner decisions applied: (a) up to 3 virtual feeders per owner, configurable, enforced in the
backend; (b) invitation codes are shared manually; (c) an accepted invitation grants `viewDashboard`
only; (d) manual feeding stays disabled until Phase 5; (e) basic schedule CRUD returns in 2D;
(f) start clean in the emulator, with no access to the production `feeder1`.

---

## Milestone 2A: backend (Cloud Functions, rules, tests)

### Callable functions (us-central1, emulator only)

All of them require a signed-in person (not a device token) with a verified email whose account
is not suspended (`requireActiveUser`, the same test as `isUser` in the rules). "Owner" means
`members/{uid}.role == 'owner'`, `status == 'active'` **and** `meta.ownerUid == uid`, which is
the same test as `isOwner`. A missing feeder and someone else's feeder give the same
`permission-denied`, so feeder IDs cannot be probed. A System Admin gets **no** special access.

| Function | Caller | What it does |
|---|---|---|
| `createVirtualFeeder({name, timezone, requestId})` | any active user | Reserves a quota slot, claims a unique ID, then creates the feeder atomically. Idempotent per `requestId`. |
| `archiveFeeder({feederId})` | owner | Sets `meta.archivedAt/By`, sets the registry to `archived` (stops any device) and revokes open invitations. Deletes nothing. |
| `restoreFeeder({feederId})` | owner | Reverses the archive (registry status restored). Revoked invitations stay revoked. |
| `deleteFeederPermanently({feederId, confirmName})` | owner | Only for an **archived** feeder and only with the **exact** name. Removes the data in one atomic write. |
| `createInvite({feederId, expiresInHours?})` | owner, feeder not archived | Returns `{inviteId, code, expiresAt}`. The code is shown once and only its hash is stored. Default 72 h, maximum 168 h; at most 10 open invitations per feeder. |
| `acceptInvite({code, requestId})` | any active user | Rate-limited. Single use. Joins as a member with `viewDashboard` only. |
| `revokeInvite({feederId, inviteId})` | owner | Changes an open invitation to revoked (idempotent). |
| `updateMemberPermissions({feederId, memberUid, permissions})` | owner, not archived | Replaces the permission map. Only the 7 whitelisted keys are accepted, all booleans; the stored map lists all 7. |
| `removeMember({feederId, memberUid})` | owner | Ends the membership with a revocation marker (see below) and removes the member's index entry and last selection. Allowed on archived feeders. |
| `leaveFeeder({feederId})` | member (not owner) | The same for the caller themself (marker status `left`). |

Ownership transfer is deferred, as agreed. Live (physical) feeders can't be created, archived
or deleted yet (`failed-precondition`); that comes in the hardware phase.

### Concurrency and idempotency

- **Feeder limit.** A transaction on `userQuotas/{uid}/virtualFeeders` holds one entry per feeder
  (`{requestId, reservedAt}`). It adds the slot, finds an earlier slot with the same `requestId`
  (a retry), or leaves the data unchanged when the user is at the limit. The result is read from
  the committed snapshot. Test: 6 parallel requests produce exactly 3 feeders.
  **Archived feeders keep their slot**; permanent deletion frees it.
- **Unique ID.** `fd_` + 20 base-62 characters from `crypto.randomInt`, claimed with a create-only
  transaction on `deviceRegistry/{id}`.
- **Creation** is one multi-path update (meta, config, owner member, `userFeeders`, feeder audit,
  platformAudit). The audit records use fixed keys, so a racing retry can't duplicate them.
- **Invitation acceptance:**
  1. A rate-limit transaction counts the attempt and **commits it** before the code is checked.
  2. An `invitations/{id}` transaction moves the invitation from open to accepted, so exactly one
     acceptance wins (tested with two users at the same time).
  3. A create-only transaction on `members/{uid}` never overwrites an existing membership. If the
     user turns out to be a member already, the invitation is reopened.
  4. An atomic finalize write records `finalizedAt`.
  5. A re-check after finalize: if a removal landed between steps 3 and 4, the index entry that
     step 4 wrote is removed again.

  After finalize, a retry with the used code succeeds only while that membership is still active.
- **Membership revocation (fixes the removal/retry race).** Removing a member, or a member
  leaving, does **not** delete `feeders/{id}/members/{uid}`. It replaces it, in the same atomic
  write that removes `userFeeders/{uid}/{id}`, with a **revocation marker**:
  `{role: 'member', status: 'removed' | 'left', inviteId, endedAt, endedBy}`, with **no
  permissions**. The rules grant nothing unless `status == 'active'`, so access ends on the next
  request.

  `acceptInvite` creates memberships with a transaction on that **same path**, and the
  transaction refuses to overwrite either an active membership or a marker carrying the same
  `inviteId`. A Realtime Database transaction is compare-and-set on its path, so a removal and an
  acceptance (first attempt or retry) are applied one after the other, and whichever runs second
  sees the other's result:
  - If the acceptance runs second, it finds the marker and stops with "no longer valid".
  - If the removal runs second, it overwrites the new membership with the marker. Step 5 then
    cleans up any index entry the acceptance wrote.

  Either way the end state is revoked. Only a **new** invitation from the owner can re-admit the
  user, and it grants default (`viewDashboard`-only) permissions again. Tests cover an interrupted
  acceptance followed by removal, and removal racing the retry (5 rounds from an interrupted state,
  3 rounds from a completed join). Every case ends with a marker, no index entry and denied reads.
- **Permission updates** run as a transaction on the member record, so they can never recreate a
  membership that was removed in the meantime.

### Invitation codes

10 characters from the Crockford base-32 alphabet (no I, L, O or U; 50 bits), shown as
`XXXXX-XXXXX`. Input is normalized (case, spaces, dashes, O→0, I/L→1). Storage:

| Path | Content | Client access |
|---|---|---|
| `invitations/{inviteId}` | feederId, codeHash, createdBy, createdAt, expiresAt, status, permissions, acceptedBy/At, finalizedAt | none |
| `inviteCodes/{sha256}` | inviteId | none |
| `feeders/{id}/invites/{inviteId}` | status summary **without** the code or hash | owner read |
| `rateLimits/acceptInvite/{uid}` | `{windowStart, count}`: 10 attempts per 15 min per account | none |

Email addresses are never used for authorization: whoever holds a valid code may join, once.

### Configurable limits (`functions/src/lib/limits.ts`)

The code defaults (`virtualFeedersPerOwner: 3`, `openInvitesPerFeeder: 10`, `inviteDefaultHours: 72`,
`inviteMaxHours: 168`, `inviteAttemptsPerWindow: 10`, `inviteAttemptWindowMinutes: 15`) can be
overridden with positive integers in `platformConfig/limits`. Admins can read that node; only the
backend can write it (an admin function for this belongs in Phase 9).

### New feeder defaults

`config`: `capacityG 3000`, `loadCellMaxG 3000` (the 3 kg load-cell rating), `lowThresholdG 500`,
`maxDispenseG 200`, `calibrationStatus 'uncalibrated'`, `schedulesPaused false`. Registry:
`status 'provisioned'`, `mode 'simulated'`, no `deviceUid`. **No device identity can act for the
feeder** until the simulator is provisioned in Phase 6.

### Permanent deletion

This is one atomic multi-path write. It removes `feeders/{id}`, every member's
`userFeeders/{uid}/{id}`, any `users/{uid}/lastSelectedFeederId` pointing at the feeder, the
feeder's `invitations` and `inviteCodes`, and the owner's quota slot. `deviceRegistry/{id}`
becomes a **tombstone** (`status 'deleted'`, deletedAt/By), so the ID is never reused.
`platformAudit` records `feeder_deleted` with the member count. User profiles are untouched.

### Rules changes (`rules/rules.mjs` → `database.rules.json`)

- `notArchived`: every app **write** grant on a feeder now also requires that `meta.archivedAt`
  does not exist. That covers name, timezone, capacity, threshold, max dispense, pause, schedule
  create/edit/delete, command and lock creation, and simulator controls. Releasing a finished lock
  and expiring a stale pending command remain allowed (clean-up only). Reads are unchanged:
  members can still see the history of an archived feeder.
- `feeders/{id}/invites`: `.read` owner only, `.indexOn status`. No client writes.
- `platformConfig`: `.read` admin only. `inviteCodes`, `userQuotas` and `rateLimits` have no
  client access at all.

### Tooling change

`scripts/run-with-emulators.mjs` now:
- passes `FUNCTIONS_DISCOVERY_TIMEOUT=60` to the emulator (the CLI's default of 10 s timed out once
  on this PC, which made every callable return `not-found`);
- fails immediately with the emulator log if the functions were not loaded, instead of running
  the tests against an empty Functions emulator.

`npm run test:functions` now runs each functions test file in its **own emulator session**
(`test:functions:admin`, `:feeders`, `:races`; a new test file must be added there). Reason,
measured on this PC: in its normal mode the Functions emulator keeps at least one Node worker
(about 100 MB) per function and never stops idle workers. Each overlapping call adds another
permanent worker. With 13 functions and the concurrency tests, a single session grew to 25
workers (2.7 GB), free RAM fell to 1.3 GB, the Firebase CLI process (which also hosts the Auth
emulator) froze, and every later test timed out. The emulator's sequential mode would avoid this
but would serialize the calls, so the race tests would no longer test real concurrency.

### Tests (2026-10-22)

| Command | Result |
|---|---|
| `npm run test:rules` | **120 / 120** (108 Phase 1 + 12 new in `tests/rules/lifecycle_and_invites.test.mjs`) |
| `npm run test:functions` | **49 / 49**: 15 Phase 1 (`admin_functions`) + 27 (`feeder_functions`) + 7 (`membership_races`), each file in its own emulator session |
| `flutter analyze` / `flutter test` | No issues / **26 / 26** (no Flutter changes in 2A) |

**Mutation check for the revocation fix:** with the old behaviour (deleting the member record)
put temporarily into the compiled output, 3 of the 7 race tests fail (a retry returns `ok` and the
member is `active` again). With the fix, all 7 pass.

Logs: `docs/review/phase2/evidence/`. The functions tests drive the real callables through the
client SDK and check their effect **through the Security Rules** with a client database handle,
for example: a new member can read `status` but not `history`; granting `manageSchedules` lets them
write a schedule and revoking it stops them; a removed member loses read access at once.

### Audit separation

Membership and permission changes (`invite_created`, `invite_revoked`, `member_joined`,
`member_permissions_updated` with before/after, `member_removed`, `member_left`,
`feeder_archived/restored`) are written only by the backend to `feeders/{id}/audit`, which only the
owner can read and no client can write. Platform-level events go to `platformAudit`. Neither is
mixed with poultry feeding records (`history`, `commands`, `measurements`), which only a device can
write.

### Known limitations after 2A

- **Invitation codes need stronger protection before production.** Code hashes are SHA-256 with
  no server secret. Someone who obtained a database export could brute-force an open 50-bit code
  offline within its lifetime. **Required before production deployment:** an HMAC-SHA-256 keyed
  with a server-only secret (Secret Manager, never in the app or the database), so a stolen
  database alone is not enough. This is tracked for the deployment step.
- **The per-account rate limit is not complete protection against distributed guessing.** It
  limits each account to 10 attempts per 15 min. An attacker with many verified accounts multiplies
  that. The remaining protection is the size of the code space (2^50), the expiry (72 h default)
  and single use. Production should add App Check and a global or per-feeder attempt monitor
  (Phase 9/10).
- The per-feeder open-invitation cap is checked without a transaction, so concurrent creation can
  exceed it slightly. It is a spam guard, not a security boundary.
- Revocation markers stay under `feeders/{id}/members` (they grant nothing, and the owner's UI
  in 2C will show only active members). They are removed with the feeder on permanent deletion.
- Invitations are not shown or managed in the app until 2C. The app does not call any 2A function
  until 2B/2C.
- `deviceRegistry` tombstones and `platformAudit` grow without bound. Retention policy: Phase 9.

---

## Milestone 2B: dynamic feeder selection (Flutter)

No backend or rules changes. Production untouched; nothing deployed.

### What the app does now

- **Feeder list from the database.** `FeederSelectionController` (`lib/services/feeder_selection.dart`)
  listens to `userFeeders/{uid}` and, for each feeder, to `feeders/{id}/meta` and the user's own
  `feeders/{id}/members/{uid}`, all live. A feeder counts as accessible only when its meta is
  readable and the membership is `active` (not expired, and for owners `meta.ownerUid` matches).
  These are the same tests the rules apply. Feeder IDs only ever come from the database; there is
  no `feeder1` anywhere outside the unmounted legacy file.
- **Selection** (`resolveSelection`, a pure function): keep the current feeder while it is
  accessible, otherwise the saved `users/{uid}/lastSelectedFeederId`, otherwise the only feeder.
  With several feeders and no valid choice, the user picks from the list. Each choice is saved
  (best effort; the rules only accept IDs present in `userFeeders`).
- **Screens** (`HomeShell`): loading; error with **Retry**; **onboarding** when the user has no
  feeder (*Create virtual feeder* works, *Register a device* stays disabled until the hardware
  phase); a **chooser** for several feeders; otherwise the **feeder shell**.
- **Feeder shell** (`lib/features/feeder/`): the app bar title is the switcher (name plus
  **VIRTUAL** and **ARCHIVED** badges, tap for the feeder list and *Create virtual feeder*), with
  an offline banner, an archived banner, and the original `PillNav` from `design.dart`.
  `FeederScope` provides the feeder ID, role, permissions and online flag to the tabs.
- **Tabs (until 2D):** Dashboard, Schedule, History and Settings are wired to the selected feeder
  and gated by permission. A member without the permission sees "You don't have permission…".
  Content placeholders say what returns in 2D and never show numbers. Settings lists the user's
  role and permissions and the account panel.
- **Manual feeding (decision d):** the centre button only shows "Manual feeding will be enabled in
  Phase 5. No feeding command was sent." Nothing is written.
- **Changes while open:**
  - Permissions update live.
  - When a membership becomes a revocation marker, the rules deny the meta listener, or the
    feeder is deleted, the feeder disappears and the user sees "You no longer have access to
    "<name>"." The app then falls back to the remaining feeder, the chooser or onboarding.
  - A user re-added by a new invitation is listened to again.
- **Offline:** `.info/connected` drives the banner, after a 4 s start-up grace period so the first
  connection does not flash it.
- **Create virtual feeder dialog:** name (1–40 characters) and time zone (IANA list, Asia/Manila
  first). One `requestId` per dialog, so pressing *Create* again after a timeout cannot create
  two feeders. The backend errors (for example the 3-feeder limit) are shown as they come.

### Files

New: `lib/services/feeder_selection.dart`, `lib/services/feeder_actions.dart`,
`lib/features/feeder/{feeder_scope,feeder_shell,feeder_switcher,create_feeder_dialog}.dart`,
`test/fake_feeder_source.dart`, `test/feeder_selection_test.dart`, `test/feeder_ui_test.dart`.
Changed: `lib/features/home/home_shell.dart` (rewritten as the router), `lib/app_scope.dart`
(new services, `AppScope.maybeOf`), `lib/features/home/account_panel.dart` (renders nothing
without an `AppScope`, for widget tests). Removed: `lib/services/feeder_index_repository.dart`
(replaced). After manual testing: `lib/core/backend.dart` (direct emulator database URL),
`tests/rules/rules_config.test.mjs` (asserts it), `tests/functions/app_contract.test.mjs` and
`package.json` (`test:functions:app`). `lib/design.dart` is unchanged.

### Tests (2026-10-22, final)

| Command | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | **53 / 53**: 26 existing + 19 `feeder_selection_test` + 8 `feeder_ui_test` |
| `flutter build apk --debug` | Builds (55–108 s; Gradle daemons stopped afterwards to free memory) |
| `npm run test:rules` | **120 / 120** (`rules_config` now also asserts the emulator-only database URL) |
| `npm run test:functions:app` | **6 / 6**: new `tests/functions/app_contract.test.mjs` |
| `npm run test:functions` (admin, feeders, races) | 49 / 49 at the 2A commit; no functions code changed in 2B |

The widget tests run on `FakeFeederSource`, which behaves like RTDB `onValue`. **The real
integration is proven separately** by `app_contract.test.mjs`, which uses the real Auth, Database
and Functions emulators and opens exactly the listeners and writes that `FirebaseFeederDataSource`
uses:
- `createVirtualFeeder` returns dynamic `fd_` IDs that appear live in `userFeeders/{uid}`.
- `lastSelectedFeederId` accepts only the user's own feeders (`feeder1` and another owner's feeder
  are refused).
- Another owner and the admin are refused every listener.
- On removal, the server cancels the member's open `meta` listener, and their member record turns
  into the `removed` marker.
- Permission changes and archiving reach open listeners.
- Deletion removes the feeder from the owner's index.

### Manual test on the Pixel_8 emulator

14 of 15 scenarios passed. Scenario 13 (network errors) passed in part. Details and screenshots:
`docs/review/phase2/evidence/07-manual-2b.md` and `docs/review/phase2/screenshots/`.

Manual testing found two bugs, both fixed:
- **False "Offline" banner.** In emulator mode, `useDatabaseEmulator()` on Android made the plugin
  create a new database instance and connection per call (11 seen). `.info/connected` then
  reported an idle one. The fix is a direct emulator URL (`http://<host>:9000/?ns=demo-agrifeed`)
  in `lib/core/backend.dart`: one instance, one connection, still unable to reach production.
- **Raw `UNAVAILABLE` text** in the create dialog. `describeFunctionsError` now gives a readable
  message for connection problems and keeps the backend's own messages.

### Not yet verified for 2B

- A full re-check of the banner fix on the device (75 s idle plus an airplane-mode toggle). It was
  started, but Claude Code stopped it because the PC was critically low on memory. The fixed build
  connected and worked normally and showed no banner about a minute into the session.
