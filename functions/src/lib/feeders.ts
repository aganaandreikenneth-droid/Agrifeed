import { ServerValue } from "firebase-admin/database";
import { HttpsError } from "firebase-functions/v2/https";
import { db } from "./firebase";

export const PERMISSIONS = [
  "viewDashboard",
  "viewHistory",
  "viewAnalytics",
  "manualFeed",
  "manageSchedules",
  "downloadReports",
  "receiveAlerts",
] as const;

export type Permissions = Record<(typeof PERMISSIONS)[number], boolean>;

/** Decision (c): an accepted invitation grants viewDashboard only. */
export const DEFAULT_MEMBER_PERMISSIONS: Permissions = {
  viewDashboard: true,
  viewHistory: false,
  viewAnalytics: false,
  manualFeed: false,
  manageSchedules: false,
  downloadReports: false,
  receiveAlerts: false,
};

/** Defaults for a new virtual feeder; capacity is capped at the 3 kg load-cell rating. */
export const DEFAULT_CONFIG = {
  capacityG: 3000,
  loadCellMaxG: 3000,
  lowThresholdG: 500,
  maxDispenseG: 200,
  calibrationStatus: "uncalibrated",
  schedulesPaused: false,
};

export interface FeederMeta {
  name: string;
  ownerUid: string;
  mode: "simulated" | "live";
  timezone: string;
  createdAt: number;
  archivedAt?: number;
  archivedBy?: string;
}

export interface Member {
  role: "owner" | "member";
  /** 'active' grants access; 'removed' and 'left' are revocation markers. */
  status: string;
  permissions?: Partial<Permissions>;
  inviteId?: string;
  displayName?: string;
}

export const isActive = (m: Member | null | undefined): boolean => m?.status === "active";

export const isArchived = (meta: FeederMeta) => meta.archivedAt !== undefined;

/**
 * The caller must be the feeder's active owner: the same test as isOwner in
 * the rules. A missing feeder gives the same answer as someone else's, so
 * the function does not reveal which feeder IDs exist.
 */
export async function requireOwner(uid: string, feederId: string): Promise<FeederMeta> {
  const [meta, me] = await Promise.all([
    db.ref(`feeders/${feederId}/meta`).get(),
    db.ref(`feeders/${feederId}/members/${uid}`).get(),
  ]);
  const m = meta.val() as FeederMeta | null;
  const member = me.val() as Member | null;
  if (!m || m.ownerUid !== uid || member?.role !== "owner" || !isActive(member)) {
    throw new HttpsError("permission-denied", "Only the feeder owner can do this.");
  }
  return m;
}

export function requireNotArchived(meta: FeederMeta) {
  if (isArchived(meta)) {
    throw new HttpsError("failed-precondition", "This feeder is archived. Restore it first.");
  }
}

export function requireSimulated(meta: FeederMeta) {
  if (meta.mode !== "simulated") {
    throw new HttpsError("failed-precondition", "Physical feeders are managed in the hardware phase.");
  }
}

/**
 * Multi-path entries that end a membership: the member record becomes a
 * revocation marker (no permissions, status not 'active', so the rules deny
 * access at once) and the index entry and last selection are removed.
 *
 * The marker is not deleted on purpose. acceptInvite creates memberships
 * with a transaction on this same path and never overwrites a marker that
 * carries the same inviteId, so a retried or interrupted acceptance of the
 * old invitation cannot bring the membership back. A NEW invitation from the
 * owner can still re-admit the user.
 */
export async function endMembershipPaths(
  uid: string,
  feederId: string,
  member: Member,
  status: "removed" | "left",
  actorUid: string,
): Promise<Record<string, unknown>> {
  const paths: Record<string, unknown> = {
    [`feeders/${feederId}/members/${uid}`]: {
      role: "member",
      status,
      endedAt: ServerValue.TIMESTAMP,
      endedBy: actorUid,
      ...(member.inviteId ? { inviteId: member.inviteId } : {}),
      ...(member.displayName ? { displayName: member.displayName } : {}),
    },
    [`userFeeders/${uid}/${feederId}`]: null,
  };
  const last = await db.ref(`users/${uid}/lastSelectedFeederId`).get();
  if (last.val() === feederId) paths[`users/${uid}/lastSelectedFeederId`] = null;
  return paths;
}
