import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app.dart';
import 'core/backend.dart';
import 'services/auth_service.dart';

// ---------------------------------------------------------------------------
// AgriFeed: Flutter app <-> Firebase Realtime Database <-> feeder devices
//
// Phase 1 build: connects only to the Firebase Emulator Suite (see core/env.dart).
// Feeder data lives under feeders/{feederId}; IDs come from userFeeders/{uid}.
// The previous single-feeder screens are kept in features/legacy/ for Phase 2.
// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final boot = await startBackend();
  if (boot is BootReady && !kIsWeb) {
    try {
      await GoogleSignIn.instance.initialize(
        serverClientId: googleServerClientId,
      );
    } catch (e) {
      debugPrint('Google Sign-In init failed: $e');
    }
  }
  runApp(MyApp.fromBoot(boot));
}
