import { ServerValue } from "firebase-admin/database";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { writePlatformAudit } from "../lib/audit";
import { auth, db } from "../lib/firebase";
import { requireActiveAdmin, requireBool, requireUid } from "../lib/guards";

async function getUserOrThrow(uid: string) {
  try {
    return await auth.getUser(uid);
  } catch {
    throw new HttpsError("not-found", "No account with that user ID.");
  }
}

/**
 * Grants or revokes the platform administrator role.
 *
 * Order of writes:
 *  - grant:  registry, then claim. The role only works once both exist.
 *  - revoke: registry first, so access ends immediately; the stale claim
 *            alone grants nothing. Retrying after a partial failure is safe.
 * The registry update runs in a transaction so concurrent revocations can
 * never remove the last administrator.
 */
export const setAdminRole = onCall(async (req) => {
  const actorUid = await requireActiveAdmin(req);
  const uid = requireUid(req.data?.uid);
  const admin = requireBool(req.data?.admin, "admin");
  const target = await getUserOrThrow(uid);

  if (admin) {
    if (!target.emailVerified) {
      throw new HttpsError("failed-precondition", "The account's email must be verified first.");
    }
    const suspended = await db.ref(`accountStatus/${uid}/suspended`).get();
    if (suspended.val() === true) {
      throw new HttpsError("failed-precondition", "Reactivate the account first.");
    }
  }

  let lastAdmin = false;
  const result = await db.ref("platformAdmins").transaction((current: Record<string, boolean> | null) => {
    lastAdmin = false;
    const admins = { ...(current ?? {}) };
    if (admin) {
      admins[uid] = true;
      return admins;
    }
    if (!admins[uid]) return admins;
    if (Object.keys(admins).length <= 1) {
      lastAdmin = true;
      return undefined; // abort: nothing is written
    }
    delete admins[uid];
    return admins;
  });
  if (!result.committed) {
    throw new HttpsError(
      "failed-precondition",
      lastAdmin ? "Cannot remove the last administrator." : "Could not update the administrator list.",
    );
  }

  const claims = { ...(target.customClaims ?? {}) };
  if (admin) claims.admin = true;
  else delete claims.admin;
  await auth.setCustomUserClaims(uid, claims);
  // Tells the signed-in app to refresh its ID token.
  await db.ref(`accountStatus/${uid}/claimsUpdatedAt`).set(ServerValue.TIMESTAMP);

  await writePlatformAudit({
    action: admin ? "admin_role_granted" : "admin_role_revoked",
    actorUid,
    targetUid: uid,
  });
  return { ok: true };
});
