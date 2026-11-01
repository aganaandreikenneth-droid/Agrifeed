import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app.dart';
import 'core/backend.dart';
import 'features/auth/get_started_page.dart';
import 'services/auth_service.dart';

// ---------------------------------------------------------------------------
// AgriFeed: Flutter app <-> Firebase Realtime Database <-> feeder devices
//
// Phase 1 build: connects only to the Firebase Emulator Suite (see core/env.dart).
// Feeder data lives under feeders/{feederId}; IDs come from userFeeders/{uid}.
// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw the large logo at once instead of keeping the small system splash
  // up while Firebase starts.
  runApp(const StartupSplashApp());
  // The logo stays up at least this long after it is first drawn, so the
  // splash does not just flash.
  final shown = _firstVisibleFrame().then(
    (_) => Future<void>.delayed(const Duration(milliseconds: 2000)),
  );
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
  await shown;
  runApp(MyApp.fromBoot(boot));
}

/// Completes once the splash has been drawn on a real screen. Android may
/// report a 0x0 window for the first frames of a cold start.
Future<void> _firstVisibleFrame() async {
  final binding = WidgetsBinding.instance;
  while (binding.platformDispatcher.views.every(
    (v) => v.physicalSize.isEmpty,
  )) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  binding.scheduleFrame();
  await binding.endOfFrame;
}
