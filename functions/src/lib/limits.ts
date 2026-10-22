import { db } from "./firebase";

/**
 * Platform limits. The defaults apply unless the backend-only node
 * platformConfig/limits overrides a value with a positive integer, so a
 * limit can be changed later without redeploying (clients cannot write it).
 */
export const DEFAULT_LIMITS = {
  virtualFeedersPerOwner: 3,
  openInvitesPerFeeder: 10,
  inviteDefaultHours: 72,
  inviteMaxHours: 168,
  inviteAttemptsPerWindow: 10,
  inviteAttemptWindowMinutes: 15,
};

export type Limits = typeof DEFAULT_LIMITS;

export async function getLimits(): Promise<Limits> {
  const stored = (await db.ref("platformConfig/limits").get()).val() ?? {};
  const limits = { ...DEFAULT_LIMITS };
  for (const key of Object.keys(limits) as (keyof Limits)[]) {
    const v = stored[key];
    if (Number.isInteger(v) && v > 0) limits[key] = v;
  }
  return limits;
}
