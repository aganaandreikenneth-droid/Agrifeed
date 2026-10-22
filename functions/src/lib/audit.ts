import { ServerValue } from "firebase-admin/database";
import { db } from "./firebase";

export type PlatformAction =
  | "admin_bootstrap"
  | "admin_role_granted"
  | "admin_role_revoked"
  | "account_suspended"
  | "account_reactivated"
  | "virtual_feeder_created"
  | "feeder_archived"
  | "feeder_restored"
  | "feeder_deleted";

/** A platformAudit record. Feeder entries carry IDs only, never feeder data. */
export function platformAuditEntry(entry: {
  action: PlatformAction;
  actorUid: string;
  targetUid: string;
  feederId?: string;
  reason?: string;
}) {
  return { ...entry, ts: ServerValue.TIMESTAMP };
}

/** Append-only platform audit record (clients cannot write platformAudit). */
export async function writePlatformAudit(entry: Parameters<typeof platformAuditEntry>[0]): Promise<void> {
  await db.ref("platformAudit").push(platformAuditEntry(entry));
}

/** A feeders/{id}/audit record (readable by the owner only, written by the backend only). */
export function feederAuditEntry(action: string, actorUid: string, extra: Record<string, unknown> = {}) {
  return { action, actorUid, ...extra, ts: ServerValue.TIMESTAMP };
}

/** A new chronological key for multi-path updates. */
export const newKey = (): string => db.ref().push().key!;
