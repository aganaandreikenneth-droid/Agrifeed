import { CallableRequest, HttpsError } from "firebase-functions/v2/https";
import { db } from "./firebase";

const UID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * The caller must be a verified, non-suspended administrator. Both the
 * custom claim and the platformAdmins registry are required, so revoking the
 * registry entry takes effect before the caller's ID token expires.
 */
export async function requireActiveAdmin(req: CallableRequest): Promise<string> {
  const a = req.auth;
  if (!a) throw new HttpsError("unauthenticated", "Sign in first.");
  if (a.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email first.");
  }
  if (a.token.admin !== true) {
    throw new HttpsError("permission-denied", "Administrator role required.");
  }
  const [registered, suspended] = await Promise.all([
    db.ref(`platformAdmins/${a.uid}`).get(),
    db.ref(`accountStatus/${a.uid}/suspended`).get(),
  ]);
  if (registered.val() !== true) {
    throw new HttpsError("permission-denied", "Administrator role required.");
  }
  if (suspended.val() === true) {
    throw new HttpsError("permission-denied", "This account is suspended.");
  }
  return a.uid;
}

/**
 * The caller must be a person (not a device token) with a verified email
 * whose account is not suspended: the same test as isUser in the rules.
 */
export async function requireActiveUser(req: CallableRequest): Promise<string> {
  const a = req.auth;
  if (!a) throw new HttpsError("unauthenticated", "Sign in first.");
  if (a.token.device === true) {
    throw new HttpsError("permission-denied", "Devices cannot use this function.");
  }
  if (a.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email first.");
  }
  if ((await db.ref(`accountStatus/${a.uid}/suspended`).get()).val() === true) {
    throw new HttpsError("permission-denied", "This account is suspended.");
  }
  return a.uid;
}

const FEEDER_ID_PATTERN = /^fd_[0-9A-Za-z]{20}$/;
const KEY_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
// Same pattern as feeders/$feederId/meta/timezone in the rules.
const TIMEZONE_PATTERN = /^(UTC|[A-Za-z]+\/[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+)?)$/;

export function requireFeederId(value: unknown): string {
  if (typeof value !== "string" || !FEEDER_ID_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", "feederId is not a valid feeder ID.");
  }
  return value;
}

/** Client-generated idempotency keys and database push keys. */
export function requireKey(value: unknown, field: string): string {
  if (typeof value !== "string" || !KEY_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", `${field} must be 8-64 letters, digits, - or _.`);
  }
  return value;
}

/** An IANA time zone that this runtime recognises (or UTC). */
export function requireTimezone(value: unknown): string {
  if (typeof value === "string" && TIMEZONE_PATTERN.test(value)) {
    try {
      new Intl.DateTimeFormat("en", { timeZone: value });
      return value;
    } catch {
      // fall through
    }
  }
  throw new HttpsError("invalid-argument", "timezone must be an IANA time zone such as Asia/Manila.");
}

export function requireUid(value: unknown, field = "uid"): string {
  if (typeof value !== "string" || !UID_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", `${field} must be a valid user ID.`);
  }
  return value;
}

export function requireText(value: unknown, field: string, max: number): string {
  const s = typeof value === "string" ? value.trim() : "";
  if (s.length < 1 || s.length > max) {
    throw new HttpsError("invalid-argument", `${field} must be 1-${max} characters.`);
  }
  return s;
}

export function requireBool(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `${field} must be true or false.`);
  }
  return value;
}
