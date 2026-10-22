import { HttpsError, onCall } from "firebase-functions/v2/https";
import { feederAuditEntry, newKey } from "../lib/audit";
import {
  endMembershipPaths,
  isActive,
  Member,
  PERMISSIONS,
  Permissions,
  requireNotArchived,
  requireOwner,
} from "../lib/feeders";
import { db } from "../lib/firebase";
import { requireActiveUser, requireFeederId, requireUid } from "../lib/guards";

/** Only the whitelisted keys, each a boolean; the stored map always lists all of them. */
function requirePermissions(value: unknown): Permissions {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "permissions must be an object.");
  }
  const input = value as Record<string, unknown>;
  for (const key of Object.keys(input)) {
    if (!(PERMISSIONS as readonly string[]).includes(key)) {
      throw new HttpsError("invalid-argument", `Unknown permission: ${key}.`);
    }
    if (typeof input[key] !== "boolean") {
      throw new HttpsError("invalid-argument", `${key} must be true or false.`);
    }
  }
  return Object.fromEntries(PERMISSIONS.map((p) => [p, input[p] === true])) as Permissions;
}

async function requireMemberTarget(feederId: string, memberUid: string): Promise<Member> {
  const target = (await db.ref(`feeders/${feederId}/members/${memberUid}`).get()).val() as Member | null;
  if (!target || !isActive(target)) throw new HttpsError("not-found", "That user is not a member of this feeder.");
  if (target.role !== "member") {
    throw new HttpsError("failed-precondition", "The owner's access cannot be changed here.");
  }
  return target;
}

/**
 * Replaces an Authorized Member's permissions. Runs as a transaction on the
 * member record so it can never recreate a membership removed meanwhile.
 */
export const updateMemberPermissions = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const memberUid = requireUid(req.data?.memberUid, "memberUid");
  const permissions = requirePermissions(req.data?.permissions);
  requireNotArchived(await requireOwner(uid, feederId));
  await requireMemberTarget(feederId, memberUid);

  let before: Member["permissions"] = {};
  const res = await db.ref(`feeders/${feederId}/members/${memberUid}`).transaction((cur: Member | null) => {
    if (cur === null) return null;
    if (cur.role !== "member" || !isActive(cur)) return;
    before = cur.permissions ?? {};
    return { ...cur, permissions };
  });
  const after = res.snapshot.val() as Member | null;
  if (!res.committed || after?.role !== "member" || !isActive(after)) {
    throw new HttpsError("not-found", "That user is not a member of this feeder.");
  }
  await db.ref(`feeders/${feederId}/audit/${newKey()}`).set(
    feederAuditEntry("member_permissions_updated", uid, { targetUid: memberUid, before, after: permissions }),
  );
  return { ok: true, permissions };
});

/** The owner removes an Authorized Member (also allowed on an archived feeder: it only reduces access). */
export const removeMember = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const memberUid = requireUid(req.data?.memberUid, "memberUid");
  await requireOwner(uid, feederId);
  const target = await requireMemberTarget(feederId, memberUid);

  await db.ref().update({
    ...(await endMembershipPaths(memberUid, feederId, target, "removed", uid)),
    [`feeders/${feederId}/audit/${newKey()}`]: feederAuditEntry("member_removed", uid, { targetUid: memberUid }),
  });
  return { ok: true };
});

/** An Authorized Member leaves a feeder. Owners cannot leave (ownership transfer comes later). */
export const leaveFeeder = onCall(async (req) => {
  const uid = await requireActiveUser(req);
  const feederId = requireFeederId(req.data?.feederId);
  const me = (await db.ref(`feeders/${feederId}/members/${uid}`).get()).val() as Member | null;
  if (!me || !isActive(me)) throw new HttpsError("not-found", "You are not a member of this feeder.");
  if (me.role !== "member") {
    throw new HttpsError("failed-precondition", "Owners cannot leave their own feeder.");
  }

  await db.ref().update({
    ...(await endMembershipPaths(uid, feederId, me, "left", uid)),
    [`feeders/${feederId}/audit/${newKey()}`]: feederAuditEntry("member_left", uid),
  });
  return { ok: true };
});
