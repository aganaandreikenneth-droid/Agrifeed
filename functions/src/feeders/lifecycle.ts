import { ServerValue } from "firebase-admin/database";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { feederAuditEntry, newKey, platformAuditEntry } from "../lib/audit";
import {
  DEFAULT_CONFIG,
  isActive,
  isArchived,
  Member,
  requireOwner,
  requireSimulated,
} from "../lib/feeders";
import { db } from "../lib/firebase";
import { requireActiveUser, requireFeederId, requireKey, requireText, requireTimezone } from "../lib/guards";
import { newFeederId } from "../lib/ids";
import { getLimits } from "../lib/limits";

interface Reservation {
  requestId: string;
  reservedAt: number;
}

/**
 * Registers a virtual (simulated) feeder owned by the caller. No hardware is
 * involved: the registry entry has no device identity until the simulator is
 * provisioned (Phase 6), so nothing can act as this feeder's device yet.
 *
 *  1. userQuotas/{uid}/virtualFeeders transaction: reserves a slot for this
 *     requestId, or finds the earlier reservation (idempotent retry), or finds
 *     the limit reached. The outcome is read from the committed snapshot.
 *  2. deviceRegistry/{feederId} create-only transaction: the ID is unique.
 *  3. One atomic multi-path write creates meta, config, the owner membership,
 *     the user's index entry and both audit records. Skipped when a retry
 *     finds it already done.
 * Archived feeders keep their slot; deleting one permanently frees it.
 */
export const createVirtualFeeder = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const name = requireText(req.data?.name, "name", 40);
  const timezone = requireTimezone(req.data?.timezone);
  const requestId = requireKey(req.data?.requestId, "requestId");
  const { virtualFeedersPerOwner } = await getLimits();

  const candidate = newFeederId();
  const quota = await db.ref(`userQuotas/${uid}/virtualFeeders`).transaction(
    (current: Record<string, Reservation> | null) => {
      const slots = current ?? {};
      if (Object.values(slots).some((s) => s?.requestId === requestId)) return; // retry: keep
      if (Object.keys(slots).length >= virtualFeedersPerOwner) return; // full: keep
      return { ...slots, [candidate]: { requestId, reservedAt: Date.now() } };
    },
  );
  const slots = (quota.snapshot.val() ?? {}) as Record<string, Reservation>;
  const feederId = Object.keys(slots).find((id) => slots[id]?.requestId === requestId);
  if (!feederId) {
    throw new HttpsError(
      "resource-exhausted",
      `You can own up to ${virtualFeedersPerOwner} virtual feeders. Delete an archived one to free a slot.`,
    );
  }

  const reg = await db.ref(`deviceRegistry/${feederId}`).transaction((current) => {
    if (current !== null) return; // exists: keep (ours on a retry, otherwise a collision)
    return {
      status: "provisioned",
      mode: "simulated",
      ownerUid: uid,
      credentialVersion: 1,
      requestId,
      createdAt: Date.now(),
    };
  });
  const entry = reg.snapshot.val();
  if (entry?.ownerUid !== uid || entry?.requestId !== requestId) {
    // ID collision (practically impossible): release the slot and let the client retry.
    await db.ref(`userQuotas/${uid}/virtualFeeders/${feederId}`).remove();
    throw new HttpsError("aborted", "Could not register the feeder. Please try again.");
  }

  const meta = await db.ref(`feeders/${feederId}/meta`).get();
  if (!meta.exists()) {
    const displayName = (await db.ref(`users/${uid}/displayName`).get()).val();
    await db.ref().update({
      [`feeders/${feederId}/meta`]: {
        name,
        ownerUid: uid,
        mode: "simulated",
        timezone,
        createdAt: ServerValue.TIMESTAMP,
      },
      [`feeders/${feederId}/config`]: DEFAULT_CONFIG,
      [`feeders/${feederId}/members/${uid}`]: {
        role: "owner",
        status: "active",
        addedAt: ServerValue.TIMESTAMP,
        ...(typeof displayName === "string" ? { displayName } : {}),
      },
      [`userFeeders/${uid}/${feederId}`]: { role: "owner", addedAt: ServerValue.TIMESTAMP },
      // Fixed keys, so a racing retry cannot add a second record.
      [`feeders/${feederId}/audit/created`]: feederAuditEntry("feeder_created", uid, { mode: "simulated" }),
      [`platformAudit/created_${feederId}`]: platformAuditEntry({
        action: "virtual_feeder_created",
        actorUid: uid,
        targetUid: uid,
        feederId,
      }),
    });
  }
  return { feederId, mode: "simulated" };
});

/**
 * Deactivates a virtual feeder without deleting anything. Members keep read
 * access to its history; the rules reject every app write to an archived
 * feeder, the registry status stops any device, and open invitations are
 * revoked. Reversible with restoreFeeder.
 */
export const archiveFeeder = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const meta = await requireOwner(uid, feederId);
  requireSimulated(meta);
  if (isArchived(meta)) return { ok: true, archived: true };

  const [registry, invites] = await Promise.all([
    db.ref(`deviceRegistry/${feederId}/status`).get(),
    db.ref(`feeders/${feederId}/invites`).orderByChild("status").equalTo("open").get(),
  ]);
  const update: Record<string, unknown> = {
    [`feeders/${feederId}/meta/archivedAt`]: ServerValue.TIMESTAMP,
    [`feeders/${feederId}/meta/archivedBy`]: uid,
    [`deviceRegistry/${feederId}/status`]: "archived",
    [`deviceRegistry/${feederId}/statusBeforeArchive`]: registry.val() ?? "provisioned",
    [`feeders/${feederId}/audit/${newKey()}`]: feederAuditEntry("feeder_archived", uid),
    [`platformAudit/${newKey()}`]: platformAuditEntry({
      action: "feeder_archived",
      actorUid: uid,
      targetUid: uid,
      feederId,
    }),
  };
  invites.forEach((inv) => {
    update[`invitations/${inv.key}/status`] = "revoked";
    update[`feeders/${feederId}/invites/${inv.key}/status`] = "revoked";
  });
  await db.ref().update(update);
  return { ok: true, archived: true };
});

export const restoreFeeder = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const meta = await requireOwner(uid, feederId);
  requireSimulated(meta);
  if (!isArchived(meta)) return { ok: true, archived: false };

  const before = (await db.ref(`deviceRegistry/${feederId}/statusBeforeArchive`).get()).val();
  await db.ref().update({
    [`feeders/${feederId}/meta/archivedAt`]: null,
    [`feeders/${feederId}/meta/archivedBy`]: null,
    [`deviceRegistry/${feederId}/status`]: typeof before === "string" ? before : "provisioned",
    [`deviceRegistry/${feederId}/statusBeforeArchive`]: null,
    [`feeders/${feederId}/audit/${newKey()}`]: feederAuditEntry("feeder_restored", uid),
    [`platformAudit/${newKey()}`]: platformAuditEntry({
      action: "feeder_restored",
      actorUid: uid,
      targetUid: uid,
      feederId,
    }),
  });
  return { ok: true, archived: false };
});

/**
 * Permanently deletes an ARCHIVED virtual feeder. The owner must type the
 * feeder's exact name. In one atomic write it removes the feeder's data,
 * every member's index entry, the feeder's invitations and the quota slot.
 * The registry keeps a tombstone (so the ID is never reused) and
 * platformAudit records the deletion.
 */
export const deleteFeederPermanently = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const meta = await requireOwner(uid, feederId);
  requireSimulated(meta);
  if (!isArchived(meta)) {
    throw new HttpsError("failed-precondition", "Archive the feeder before deleting it permanently.");
  }
  if (req.data?.confirmName !== meta.name) {
    throw new HttpsError("invalid-argument", "Type the feeder's exact name to confirm deletion.");
  }

  const [members, invites] = await Promise.all([
    db.ref(`feeders/${feederId}/members`).get(),
    db.ref(`feeders/${feederId}/invites`).get(),
  ]);
  const update: Record<string, unknown> = {
    [`feeders/${feederId}`]: null,
    [`userQuotas/${uid}/virtualFeeders/${feederId}`]: null,
    [`deviceRegistry/${feederId}`]: {
      status: "deleted",
      mode: meta.mode,
      ownerUid: meta.ownerUid,
      deletedAt: ServerValue.TIMESTAMP,
      deletedBy: uid,
    },
  };
  const memberRecords = (members.val() ?? {}) as Record<string, Member>;
  const memberUids = Object.keys(memberRecords); // includes revocation markers: every index is cleaned
  for (const m of memberUids) {
    update[`userFeeders/${m}/${feederId}`] = null;
    const last = await db.ref(`users/${m}/lastSelectedFeederId`).get();
    if (last.val() === feederId) update[`users/${m}/lastSelectedFeederId`] = null;
  }
  for (const inviteId of Object.keys(invites.val() ?? {})) {
    const hash = (await db.ref(`invitations/${inviteId}/codeHash`).get()).val();
    update[`invitations/${inviteId}`] = null;
    if (typeof hash === "string") update[`inviteCodes/${hash}`] = null;
  }
  update[`platformAudit/${newKey()}`] = {
    ...platformAuditEntry({ action: "feeder_deleted", actorUid: uid, targetUid: uid, feederId }),
    memberCount: Object.values(memberRecords).filter(isActive).length,
  };
  await db.ref().update(update);
  return { ok: true };
});
