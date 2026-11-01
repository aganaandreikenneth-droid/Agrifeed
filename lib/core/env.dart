import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

// ---------------------------------------------------------------------------
// Build environment
//
//   flutter run                                  -> emulator (default)
//   flutter run --dart-define=AGRIFEED_ENV=emulator --dart-define=EMULATOR_HOST=192.168.1.20
//   flutter run --dart-define=AGRIFEED_ENV=production   -> Firebase project agrifeed-dda82
//
// Production must be asked for by name, so a development build never reads
// or writes the live database by accident. It uses lib/firebase_options.dart
// (the same project and database the ESP32 talks to).
// ---------------------------------------------------------------------------

const String kEnvName = String.fromEnvironment(
  'AGRIFEED_ENV',
  defaultValue: 'emulator',
);
const String _hostOverride = String.fromEnvironment('EMULATOR_HOST');

/// Production Realtime Database rules are deployed (scripts/deploy-production-rules.mjs).
const bool kProductionEnabled = true;

/// The real Firebase project (lib/firebase_options.dart).
const String kProductionProjectId = 'agrifeed-dda82';

/// Emulator project. Projects starting with "demo-" can never reach real
/// Firebase resources, even if a request escapes the emulator.
const String kEmulatorProjectId = 'demo-agrifeed';
const String kFunctionsRegion = 'us-central1';

const int kAuthPort = 9099;
const int kDatabasePort = 9000;
const int kFunctionsPort = 5001;

enum EnvDecision { emulator, production, productionBlocked, invalid }

EnvDecision decideEnvironment(String name, {required bool productionEnabled}) {
  switch (name) {
    case 'emulator':
      return EnvDecision.emulator;
    case 'production':
      return productionEnabled
          ? EnvDecision.production
          : EnvDecision.productionBlocked;
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
