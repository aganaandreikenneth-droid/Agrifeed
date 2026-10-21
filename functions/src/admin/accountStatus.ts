import { ServerValue } from "firebase-admin/database";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { writePlatformAudit } from "../lib/audit";
import { auth, db } from "../lib/firebase";
import { requireActiveAdmin, requireText, requireUid } from "../lib/guards";

async function assertExists(uid: string) {
  try {
    await auth.getUser(uid);
  } catch {
    throw new HttpsError("not-found", "No account with that user ID.");
  }
}

/**
 * Suspends an account. accountStatus is written first: the Security Rules
 * check it on every request, so access stops immediately even though the
 * user's current ID token stays valid for up to an hour. The Auth account is
 * then disabled and its refresh tokens revoked so no new token can be issued.
 */
export const suspendUser = onCall(async (req) => {
  const actorUid = await requireActiveAdmin(req);
  const uid = requireUid(req.data?.uid);
  const reason = requireText(req.data?.reason, "reason", 200);
  if (uid === actorUid) {
    throw new HttpsError("failed-precondition", "You cannot suspend your own account.");
  }
  await assertExists(uid);
  if ((await db.ref(`platformAdmins/${uid}`).get()).val() === true) {
    throw new HttpsError("failed-precondition", "Revoke the administrator role before suspending.");
  }

  await db.ref(`accountStatus/${uid}`).update({
    suspended: true,
    reason,
    updatedAt: ServerValue.TIMESTAMP,
    updatedBy: actorUid,
  });
  await auth.updateUser(uid, { disabled: true });
  await auth.revokeRefreshTokens(uid);

  await writePlatformAudit({ action: "account_suspended", actorUid, targetUid: uid, reason });
  return { ok: true };
});

export const reactivateUser = onCall(async (req) => {
  const actorUid = await requireActiveAdmin(req);
  const uid = requireUid(req.data?.uid);
  await assertExists(uid);

  await auth.updateUser(uid, { disabled: false });
  await db.ref(`accountStatus/${uid}`).update({
    suspended: false,
    reason: null,
    updatedAt: ServerValue.TIMESTAMP,
    updatedBy: actorUid,
  });

  await writePlatformAudit({ action: "account_reactivated", actorUid, targetUid: uid });
  return { ok: true };
});
