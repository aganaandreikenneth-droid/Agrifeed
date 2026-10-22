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
