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
