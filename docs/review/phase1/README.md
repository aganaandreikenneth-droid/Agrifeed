# AgriFeed Phase 1: Verification record

Baseline: commit `ac3253a`. This folder preserves the evidence gathered before the Phase 1
commit. Everything was run locally against the Firebase Emulator Suite
(project `demo-agrifeed`). Nothing was deployed to production.

| Path | Contents |
|---|---|
| `evidence/01-rules-tests.txt` | `npm run test:rules`: Security Rules and emulator-configuration tests |
| `evidence/02-functions-tests.txt` | `npm run test:functions`: Cloud Functions integration tests |
| `evidence/03-flutter.txt` | `flutter analyze` and `flutter test` |
| `evidence/04-dependencies.txt` | `@grpc/grpc-js` dependency paths and `npm audit` (tooling and functions) |
| `evidence/05-boundaries.txt` | design.dart unchanged, no `feeder1` outside legacy, no production references, no deploy cache, no ESP32 sources |
| `screenshots/` | Manual smoke tests on the Android emulator (Pixel 8). See `../../phase1-manual-tests.md` for the procedure and results |

Source code is not duplicated here. Use `git diff ac3253a <phase-1 commit>` to view the full change.

Left out on purpose: test passwords (generated per run, never stored), service-account keys
(none exist), emulator data, build output, and a screenshot showing a personal Google account.

Still pending (not executed, not claimed as passed):
- M19 Google Sign-In
- M20 Physical-phone testing
