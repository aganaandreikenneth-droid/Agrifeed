import { ServerValue } from "firebase-admin/database";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { feederAuditEntry, newKey } from "../lib/audit";
import {
  DEFAULT_MEMBER_PERMISSIONS,
  FeederMeta,
  isActive,
  isArchived,
  Member,
  requireNotArchived,
  requireOwner,
} from "../lib/feeders";
import { db } from "../lib/firebase";
import { requireActiveUser, requireFeederId, requireKey } from "../lib/guards";
import { hashInviteCode, newInviteCode, normalizeInviteCode } from "../lib/ids";
import { getLimits, Limits } from "../lib/limits";

/**
 * Data layout (all written only by these functions):
 *   invitations/{inviteId}            full record incl. codeHash (no client access)
 *   inviteCodes/{codeHash}            -> inviteId, for lookup (no client access)
 *   feeders/{id}/invites/{inviteId}   status summary the owner can read (no hash)
 *   rateLimits/acceptInvite/{uid}     attempt counter (no client access)
 * The plain code is returned once by createInvite and never stored. Email
 * addresses play no part: whoever holds the code may join, once.
 */
interface Invitation {
  feederId: string;
  codeHash: string;
  createdBy: string;
  createdAt: number;
  expiresAt: number;
  status: "open" | "accepted" | "revoked" | "expired";
  permissions: Record<string, boolean>;
  acceptedBy?: string;
  acceptedAt?: number;
  acceptRequestId?: string;
  finalizedAt?: number;
}

export const createInvite = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const meta = await requireOwner(uid, feederId);
  requireNotArchived(meta);
  const limits = await getLimits();

  const hours = req.data?.expiresInHours ?? limits.inviteDefaultHours;
  if (!Number.isInteger(hours) || hours < 1 || hours > limits.inviteMaxHours) {
    throw new HttpsError("invalid-argument", `expiresInHours must be 1-${limits.inviteMaxHours}.`);
  }

  const now = Date.now();
  const open = await db.ref(`feeders/${feederId}/invites`).orderByChild("status").equalTo("open").get();
  let openCount = 0;
  open.forEach((inv) => {
    if (inv.child("expiresAt").val() > now) openCount++;
  });
  if (openCount >= limits.openInvitesPerFeeder) {
    throw new HttpsError(
      "resource-exhausted",
      `This feeder already has ${openCount} open invitations. Revoke one first.`,
    );
  }

  const inviteId = newKey();
  // Claim the code hash create-only, so two invitations never share a code.
  let code = "";
  let codeHash = "";
  for (let attempt = 0; attempt < 3 && !codeHash; attempt++) {
    const candidate = newInviteCode();
    const hash = hashInviteCode(normalizeInviteCode(candidate));
    const res = await db.ref(`inviteCodes/${hash}`).transaction((cur) => (cur === null ? inviteId : undefined));
    if (res.committed) {
      code = candidate;
      codeHash = hash;
    }
  }
  if (!codeHash) throw new HttpsError("aborted", "Could not create an invitation. Please try again.");

  const expiresAt = now + hours * 3600_000;
  const permissions = DEFAULT_MEMBER_PERMISSIONS;
  await db.ref().update({
    [`invitations/${inviteId}`]: {
      feederId,
      codeHash,
      createdBy: uid,
      createdAt: ServerValue.TIMESTAMP,
      expiresAt,
      status: "open",
      permissions,
    },
    [`feeders/${feederId}/invites/${inviteId}`]: {
      createdBy: uid,
      createdAt: ServerValue.TIMESTAMP,
      expiresAt,
      status: "open",
      permissions,
    },
    [`feeders/${feederId}/audit/${newKey()}`]: feederAuditEntry("invite_created", uid, { inviteId, expiresAt }),
  });
  return { inviteId, code, expiresAt };
});

/**
 * Counts one attempt in a committed transaction BEFORE the code is checked,
 * so wrong guesses are limited per account even when the call then fails.
 */
async function countAttempt(uid: string, limits: Limits) {
  const windowMs = limits.inviteAttemptWindowMinutes * 60_000;
  const res = await db.ref(`rateLimits/acceptInvite/${uid}`).transaction((cur) => {
    const now = Date.now();
    if (!cur || typeof cur.windowStart !== "number" || now - cur.windowStart >= windowMs) {
      return { windowStart: now, count: 1 };
    }
    if (cur.count >= limits.inviteAttemptsPerWindow) return; // locked until the window ends
    return { windowStart: cur.windowStart, count: cur.count + 1 };
  });
  if (!res.committed) {
    throw new HttpsError(
      "resource-exhausted",
      `Too many invitation attempts. Try again in ${limits.inviteAttemptWindowMinutes} minutes.`,
    );
  }
}

/**
 * Joins the feeder behind a code as an Authorized Member.
 *  1. Rate limit (committed).
 *  2. invitations/{id} transaction open -> accepted: exactly one caller wins;
 *     the same caller retrying finds it already accepted by them.
 *  3. members/{uid} transaction: creates the membership only if there is no
 *     active membership (never overwrites one, e.g. with more permissions)
 *     AND no revocation marker from this same invitation. removeMember and
 *     leaveFeeder write that marker to the same path, so the database orders
 *     a removal and an acceptance (first attempt or retry) one after the
 *     other: whichever runs second sees the other's result, and a removal can
 *     never be undone by this invitation.
 *  4. Atomic multi-path finalize: index entry, owner-visible status, audit,
 *     finalizedAt. Fixed keys make a retry write the same records again.
 *  5. Re-check: if a removal landed between steps 3 and 4, the index entry
 *     written in step 4 is removed again, so no stale index remains.
 */
export const acceptInvite = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const requestId = requireKey(req.data?.requestId, "requestId");
  await countAttempt(uid, await getLimits());

  const codeHash = hashInviteCode(normalizeInviteCode(req.data?.code));
  const inviteId = (await db.ref(`inviteCodes/${codeHash}`).get()).val();
  const invite = typeof inviteId === "string"
    ? ((await db.ref(`invitations/${inviteId}`).get()).val() as Invitation | null)
    : null;
  if (!invite) throw new HttpsError("not-found", "That invitation code is not valid.");
  const feederId = invite.feederId;

  if (invite.createdBy === uid) {
    throw new HttpsError("failed-precondition", "You cannot accept your own invitation.");
  }
  const [metaSnap, memberSnap] = await Promise.all([
    db.ref(`feeders/${feederId}/meta`).get(),
    db.ref(`feeders/${feederId}/members/${uid}`).get(),
  ]);
  const meta = metaSnap.val() as FeederMeta | null;
  if (!meta || isArchived(meta)) {
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }
  const existing = memberSnap.val() as Member | null;
  if (isActive(existing) && existing?.inviteId !== inviteId) {
    throw new HttpsError("already-exists", "You already have access to this feeder.");
  }
  if (!isActive(existing) && existing?.inviteId === inviteId) {
    // Joined with this code before and was removed or left since.
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }

  const res = await db.ref(`invitations/${inviteId}`).transaction((cur: Invitation | null) => {
    if (cur === null) return null; // may be a cold cache: the server re-runs this with real data
    if (cur.status !== "open") return; // used (maybe by us), revoked or expired: keep
    if (cur.expiresAt <= Date.now()) return { ...cur, status: "expired" };
    return { ...cur, status: "accepted", acceptedBy: uid, acceptedAt: Date.now(), acceptRequestId: requestId };
  });
  const after = res.snapshot.val() as Invitation | null;
  if (after?.status === "expired") {
    await db.ref(`feeders/${feederId}/invites/${inviteId}/status`).set("expired");
    throw new HttpsError("deadline-exceeded", "This invitation has expired. Ask the owner for a new one.");
  }
  if (after?.status !== "accepted" || after.acceptedBy !== uid) {
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }
  if (after.finalizedAt !== undefined) {
    // A retry after the join completed. If the membership has since been
    // removed (or the user left), the used code must not bring it back.
    if (isActive(existing) && existing?.inviteId === inviteId) return { feederId, role: "member" };
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }

  const displayName = (await db.ref(`users/${uid}/displayName`).get()).val();
  const memberRef = db.ref(`feeders/${feederId}/members/${uid}`);
  const memberRes = await memberRef.transaction((cur: Member | null) => {
    // Keep an active membership, and keep the marker of a membership that
    // this invitation created and the owner (or the user) has ended.
    if (cur !== null && (isActive(cur) || cur.inviteId === inviteId)) return;
    return {
      role: "member",
      status: "active",
      permissions: after.permissions,
      addedAt: after.acceptedAt,
      addedBy: after.createdBy,
      inviteId,
      ...(typeof displayName === "string" ? { displayName } : {}),
    };
  });
  const member = memberRes.snapshot.val() as (Member & { addedAt: number }) | null;
  if (member?.inviteId === inviteId && !isActive(member)) {
    // Removed (or left) while this acceptance was in progress: stays removed.
    await db.ref(`invitations/${inviteId}/finalizedAt`).set(ServerValue.TIMESTAMP);
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }
  if (!member || !isActive(member) || member.inviteId !== inviteId) {
    // Already a member through another route: give the invitation back.
    await db.ref(`invitations/${inviteId}`).transaction((cur: Invitation | null) => {
      if (cur === null) return null;
      if (cur.status !== "accepted" || cur.acceptedBy !== uid) return;
      const reopened: Partial<Invitation> = { ...cur, status: "open" };
      delete reopened.acceptedBy;
      delete reopened.acceptedAt;
      delete reopened.acceptRequestId;
      return reopened;
    });
    throw new HttpsError("already-exists", "You already have access to this feeder.");
  }

  await db.ref().update({
    [`userFeeders/${uid}/${feederId}`]: { role: "member", addedAt: member.addedAt },
    [`feeders/${feederId}/invites/${inviteId}/status`]: "accepted",
    [`feeders/${feederId}/invites/${inviteId}/acceptedBy`]: uid,
    [`feeders/${feederId}/invites/${inviteId}/acceptedAt`]: after.acceptedAt,
    [`feeders/${feederId}/audit/joined_${inviteId}`]: feederAuditEntry("member_joined", uid, { inviteId }),
    [`invitations/${inviteId}/finalizedAt`]: ServerValue.TIMESTAMP,
  });
  if (!isActive((await memberRef.get()).val())) {
    // A removal landed between the membership and the finalize write.
    await db.ref(`userFeeders/${uid}/${feederId}`).remove();
    throw new HttpsError("failed-precondition", "This invitation is no longer valid.");
  }
  return { feederId, role: "member" };
});

export const revokeInvite = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const inviteId = requireKey(req.data?.inviteId, "inviteId");
  await requireOwner(uid, feederId);

  const res = await db.ref(`invitations/${inviteId}`).transaction((cur: Invitation | null) => {
    if (cur === null) return null;
    if (cur.feederId !== feederId || cur.status !== "open") return;
    return { ...cur, status: "revoked" };
  });
  const after = res.snapshot.val() as Invitation | null;
  if (!after || after.feederId !== feederId) throw new HttpsError("not-found", "No such invitation.");
  if (after.status !== "revoked") {
    throw new HttpsError("failed-precondition", `This invitation is already ${after.status}.`);
  }
  await db.ref().update({
    [`feeders/${feederId}/invites/${inviteId}/status`]: "revoked",
    // Fixed key: revoking twice records it once.
    [`feeders/${feederId}/audit/revoked_${inviteId}`]: feederAuditEntry("invite_revoked", uid, { inviteId }),
  });
  return { ok: true };
});
