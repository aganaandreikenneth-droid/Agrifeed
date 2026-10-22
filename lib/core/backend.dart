import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'emulator_probe.dart';
import 'env.dart';

/// The Firebase services used by the app. Every service gets its instances
/// from here, never from the `.instance` singletons, so nothing can quietly
/// talk to the default (production) Firebase app.
class Backend {
  Backend({
    required this.auth,
    required this.db,
    required this.functions,
    required this.isEmulator,
  });

  final FirebaseAuth auth;
  final FirebaseDatabase db;
  final FirebaseFunctions functions;
  final bool isEmulator;
}

sealed class BootResult {
  const BootResult();
}

class BootReady extends BootResult {
  const BootReady(this.backend);
  final Backend backend;
}

class BootBlocked extends BootResult {
  const BootBlocked(this.title, this.details);
  final String title;
  final List<String> details;
}

const _emulatorAppName = 'agrifeed-emulator';

// Placeholder identifiers for the local emulator only. They belong to the
// "demo-agrifeed" project, which does not exist in Firebase.
const _emulatorOptions = FirebaseOptions(
  apiKey: 'AIzaSyDemoAgriFeedEmulatorKey0000000000',
  appId: '1:000000000000:android:0000000000000000',
  messagingSenderId: '000000000000',
  projectId: kEmulatorProjectId,
  // The emulator's default namespace is the project ID (the same one Cloud
  // Functions and the firebase.json rules use).
  databaseURL: 'https://$kEmulatorProjectId.firebaseio.com',
);

/// The emulator database for [host]: same namespace as the Cloud Functions
/// and the firebase.json rules (`demo-agrifeed`), plain HTTP to the emulator.
String emulatorDatabaseUrl(String host) =>
    'http://$host:$kDatabasePort/?ns=$kEmulatorProjectId';

Future<BootResult> startBackend() async {
  switch (decideEnvironment(kEnvName, productionEnabled: kProductionEnabled)) {
    case EnvDecision.productionBlocked:
      return const BootBlocked('Production is disabled in this build', [
        'This development build only connects to the Firebase Emulator Suite.',
        'Production access will be enabled after deployment is approved.',
      ]);
    case EnvDecision.invalid:
      return const BootBlocked('Unknown environment', [
        'AGRIFEED_ENV must be "emulator". Nothing was connected.',
      ]);
    case EnvDecision.emulator:
      break;
  }

  final host = emulatorHost();
  final down = await unreachablePorts(host, {
    'Auth': kAuthPort,
    'Database': kDatabasePort,
    'Functions': kFunctionsPort,
  });
  if (down.isNotEmpty) {
    return BootBlocked('Firebase Emulator not reachable', [
      ...down,
      'Start it with: firebase emulators:start --project $kEmulatorProjectId',
      'The app does not fall back to production.',
    ]);
  }

  final app = Firebase.apps.any((a) => a.name == _emulatorAppName)
      ? Firebase.app(_emulatorAppName)
      : await Firebase.initializeApp(
          name: _emulatorAppName,
          options: _emulatorOptions,
        );

  final auth = FirebaseAuth.instanceFor(app: app);
  await auth.useAuthEmulator(host, kAuthPort);
  // The database URL names the emulator directly (namespace via ?ns=) instead
  // of calling useDatabaseEmulator(). On Android, useEmulator rewrites the
  // instance's lookup key, so every later getInstance() call by the plugin
  // created a new instance with its own connection (11 in one session), and
  // `.info/connected` then reported an idle one as offline.
  final db = FirebaseDatabase.instanceFor(
    app: app,
    databaseURL: emulatorDatabaseUrl(host),
  );
  final functions = FirebaseFunctions.instanceFor(
    app: app,
    region: kFunctionsRegion,
  );
  functions.useFunctionsEmulator(host, kFunctionsPort);

  return BootReady(
    Backend(auth: auth, db: db, functions: functions, isEmulator: true),
  );
}
