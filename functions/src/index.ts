// AgriFeed Cloud Functions.
//
// These run with the Admin SDK and bypass the Security Rules, so every entry
// point validates its caller and input itself. They only run in the local
// Functions emulator; deploying needs the Blaze plan and approval.
import { setGlobalOptions } from "firebase-functions/v2";

setGlobalOptions({ region: "us-central1", maxInstances: 5 });

// Phase 1: platform administration.
export { setAdminRole } from "./admin/roles";
export { reactivateUser, suspendUser } from "./admin/accountStatus";

// Phase 2: virtual feeders, invitations and membership.
export { archiveFeeder, createVirtualFeeder, deleteFeederPermanently, restoreFeeder } from "./feeders/lifecycle";
export { acceptInvite, createInvite, revokeInvite } from "./feeders/invites";
export { leaveFeeder, removeMember, updateMemberPermissions } from "./feeders/members";
