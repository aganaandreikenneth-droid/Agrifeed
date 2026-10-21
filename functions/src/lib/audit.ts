import { ServerValue } from "firebase-admin/database";
import { db } from "./firebase";

export type PlatformAction =
  | "admin_bootstrap"
  | "admin_role_granted"
  | "admin_role_revoked"
  | "account_suspended"
  | "account_reactivated";

/** Append-only platform audit record (clients cannot write platformAudit). */
export async function writePlatformAudit(entry: {
  action: PlatformAction;
  actorUid: string;
  targetUid: string;
  reason?: string;
}): Promise<void> {
  await db.ref("platformAudit").push({
    ...entry,
    ts: ServerValue.TIMESTAMP,
  });
}
