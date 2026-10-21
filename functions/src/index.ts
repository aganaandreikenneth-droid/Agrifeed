// AgriFeed Cloud Functions (Phase 1: platform administration).
//
// These run with the Admin SDK and bypass the Security Rules, so every entry
// point validates its caller and input itself. Phase 1 only runs them in the
// local Functions emulator; deploying needs the Blaze plan and approval.
import { setGlobalOptions } from "firebase-functions/v2";

setGlobalOptions({ region: "us-central1", maxInstances: 5 });

export { setAdminRole } from "./admin/roles";
export { reactivateUser, suspendUser } from "./admin/accountStatus";
