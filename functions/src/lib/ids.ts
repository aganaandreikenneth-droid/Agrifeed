import { createHash, randomInt } from "node:crypto";
import { HttpsError } from "firebase-functions/v2/https";

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/** Feeder IDs are generated here only: "fd_" + 20 random base-62 characters (~119 bits). */
export function newFeederId(): string {
  let id = "fd_";
  for (let i = 0; i < 20; i++) id += BASE62[randomInt(62)];
  return id;
}

// Crockford base32: no I, L, O or U, so codes are easy to read aloud and type.
// 10 characters = 50 bits; guessing is also rate-limited per account.
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_PATTERN = /^[0-9A-HJKMNP-TV-Z]{10}$/;

/** A one-time invitation code, formatted for display as XXXXX-XXXXX. */
export function newInviteCode(): string {
  let code = "";
  for (let i = 0; i < 10; i++) code += CODE_ALPHABET[randomInt(32)];
  return `${code.slice(0, 5)}-${code.slice(5)}`;
}

/** Normalises what the user typed (case, spaces, dashes, O/I/L look-alikes). */
export function normalizeInviteCode(value: unknown): string {
  const s = typeof value === "string" ? value.toUpperCase().replace(/[\s-]/g, "") : "";
  const code = s.replace(/O/g, "0").replace(/[IL]/g, "1");
  if (!CODE_PATTERN.test(code)) {
    throw new HttpsError("invalid-argument", "Enter the 10-character invitation code.");
  }
  return code;
}

/** Only this hash is stored; the code itself is shown to the owner once. */
export function hashInviteCode(normalized: string): string {
  return createHash("sha256").update(`agrifeed-invite:${normalized}`).digest("hex");
}
