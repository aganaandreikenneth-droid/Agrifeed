import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

// ---------------------------------------------------------------------------
// Build environment
//
//   flutter run                                  -> emulator (default)
//   flutter run --dart-define=AGRIFEED_ENV=emulator --dart-define=EMULATOR_HOST=192.168.1.20
//   flutter run --dart-define=AGRIFEED_ENV=production   -> blocked in this build
//
// Production is switched off until a deployment is explicitly approved, so a
// development build can never read or write the live database.
// ---------------------------------------------------------------------------

const String kEnvName = String.fromEnvironment(
  'AGRIFEED_ENV',
  defaultValue: 'emulator',
);
const String _hostOverride = String.fromEnvironment('EMULATOR_HOST');

/// Flip only after production rules and functions are approved and deployed.
const bool kProductionEnabled = false;

/// Emulator project. Projects starting with "demo-" can never reach real
/// Firebase resources, even if a request escapes the emulator.
const String kEmulatorProjectId = 'demo-agrifeed';
const String kFunctionsRegion = 'us-central1';

const int kAuthPort = 9099;
const int kDatabasePort = 9000;
const int kFunctionsPort = 5001;

enum EnvDecision { emulator, productionBlocked, invalid }

EnvDecision decideEnvironment(String name, {required bool productionEnabled}) {
  switch (name) {
    case 'emulator':
      return EnvDecision.emulator;
    case 'production':
      // Even when enabled later, production wiring must be added explicitly.
      return EnvDecision.productionBlocked;
    default:
      return EnvDecision.invalid;
  }
}

/// Android emulators reach the host PC through 10.0.2.2.
/// A physical phone needs `--dart-define=EMULATOR_HOST=<your PC's LAN IP>`.
String emulatorHost() {
  if (_hostOverride.isNotEmpty) return _hostOverride;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return '10.0.2.2';
  }
  return '127.0.0.1';
}
