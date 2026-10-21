# AgriFeed Phase 1: Manual smoke tests

Environment of the recorded run: 2026-10-21, Android emulator "Pixel 8" (API image
`sdk gphone64 x86 64`), debug build, Firebase Emulator Suite bound to 127.0.0.1
(project `demo-agrifeed`), data from `npm run seed` with a session-only password.
Each test was driven through the real UI (adb taps and text input) with screenshots, and
backend state was checked through the emulator REST APIs. No production project was used.

## Setup (to repeat the run)

1. `npm run emulators` (terminal 1).
2. `npm run seed` (terminal 2). Note the printed password.
3. Start an Android emulator, then `flutter run`.
4. Verification links and password-reset links: Emulator UI → Authentication
   (http://127.0.0.1:4000/auth), or
   `curl http://127.0.0.1:9099/emulator/v1/projects/demo-agrifeed/oobCodes`.
5. Database inspection: Emulator UI → Realtime Database, namespace `demo-agrifeed`.

## Procedure and results

| # | Test | Steps | Expected | Result |
|---|---|---|---|---|
| M1 | Emulator down | Stop the emulators, start the app | "Firebase Emulator not reachable" page listing the 3 services and "does not fall back to production"; no login screen | **Passed** |
| M2 | Registration validation | Create account with a 5-character password | "Password must be at least 8 characters."; no account created | **Passed** |
| M3 | Registration | Create account with name, new email, 8+ char password | Verify-email page; **no** `users/{uid}` record yet | **Passed** (`users/{uid}` = null) |
| M4 | Early "I have verified" | Tap "I have verified my email" before opening the link | "Not verified yet…" and stays on the page | **Passed** |
| M5 | Email verification | Open the VERIFY_EMAIL link from the emulator | App advances on its own; `users/{uid}` = `{displayName, createdAt}` with no email or role | **Passed** |
| M6 | No-feeder onboarding | (continues M5) | "No feeder registered. Create a virtual feeder or register a device to continue."; buttons disabled and labelled; no permission errors | **Passed** |
| M7 | Profile editing | Pencil → new name → Save | Name updated on screen, in `users/{uid}/displayName` and in Auth | **Failed, fixed, re-run Passed.** The first run saved the data but the app crashed (`'_dependents.isEmpty'`). Root cause reproduced in a widget test and fixed (see below). |
| M8 | Sign-out | Tap Sign out | Login page | **Passed** |
| M9 | Forgot password | Login page → Forgot password? → Send link | Neutral "If that email is registered…" message; emulator holds a PASSWORD_RESET code | **Passed** |
| M10 | Wrong password | Sign in with a wrong password | "Email or password is incorrect…" | **Passed** |
| M11 | Owner home | Sign in as `owner@agrifeed.test` | "Your feeders" lists both seeded feeders (names from `feeders/{id}/meta`) with role Owner | **Passed** |
| M12 | Live suspension | While the owner is signed in, an admin calls `suspendUser` | Access ends immediately | **Passed with note:** the app signed the user out (Auth disabled + tokens revoked); signing in again shows "This account has been suspended. Contact the AgriFeed administrator." |
| M13 | Suspended (status only) | Sign in as `suspended@agrifeed.test` (database status suspended, Auth enabled) | "Account suspended" page with the reason; only Sign out | **Passed** |
| M14 | System Admin routing | Sign in as `admin@agrifeed.test` | System Admin screen; note that admins cannot view feeders; recent audit actions listed | **Passed** |
| M15 | Admin action from the UI | Enter the owner's UID → Reactivate account → Confirm | "Reactivate account: done."; audit list shows `account_reactivated`; backend: suspended=false, Auth enabled | **Failed, fixed, re-run Passed.** The first run hung (request never sent). Root cause found and fixed (see below). |
| M16 | Reactivated user | Sign in as the owner again | Owner home with both feeders | **Passed** |
| M17 | Unverified account | Sign in as `unverified@agrifeed.test` | Verify-email page; no profile written | **Passed** (`users/{uid}` = null) |
| M18 | Use a different account | On the verify page tap "Use a different account" | Login page | **Passed** |
| M19 | Google Sign-In | Continue with Google | Account chooser → signed in → profile → home | **PENDING, not executed.** It needs a Google account on the device. The emulator's only account is a personal one, which was deliberately not used. |
| M20 | Physical phone (USB / LAN mode) | See docs/phase1.md §2 | Same as M3–M18 | **PENDING, not executed** (no physical device connected) |

## Defects found by manual testing (both fixed in Phase 1)

1. **Crash after saving a dialog (M7, also affected Forgot password).** A
   `TextEditingController` was disposed right after `showDialog` returned while the dialog's
   exit animation still used it. Fix: `lib/core/widgets/text_prompt.dart`, a dialog that owns
   and disposes its controller. Regression tests: `test/widget_test.dart` ("text prompt returns
   the value and closes cleanly", "forgot password sends the reset…").
2. **Admin function calls hung on Android (M15).** The unused `firebase_messaging` plugin made
   the Functions SDK request an FCM token for the demo project. Google's Installations API
   rejected the fake demo API key (`API_KEY_INVALID`). That confirms the demo identity cannot
   reach real projects, but the call never got sent. Fix: removed the unused dependency (it
   returns in Phase 7 with real configuration). Re-run M15 passed.

## Observations (not defects)

- The first Functions emulator start timed out loading definitions while the Android
  emulator was booting. A rebuild (`npm run functions:build`) reloaded them.
- A Google account chooser appeared once during setup without being triggered by the
  test run (the emulator window was in use at the same time). It was dismissed without
  selecting an account.
