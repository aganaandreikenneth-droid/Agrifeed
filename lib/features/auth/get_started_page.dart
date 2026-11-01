import 'package:flutter/material.dart';

import '../../design.dart';

/// The owner's AgriFeed logo, shown on the welcome and login screens. If it
/// cannot be loaded a plain placeholder is drawn instead.
const kAgriFeedLogo = 'assets/images/logo.png';

/// First screen when signed out: artwork on blue, the app's purpose and a
/// Get Started button that opens the login.
class GetStartedPage extends StatelessWidget {
  const GetStartedPage({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBlue,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Center(
                      child: Image.asset(
                        kAgriFeedLogo,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const _ArtPlaceholder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'AgriFeed',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Designed to help you feed your flock on time, keep the '
                    'hopper full and see how much your birds eat.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      key: const ValueKey('get-started'),
                      onPressed: onStart,
                      child: const Text(
                        'Get Started',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stand-in if [kAgriFeedLogo] cannot be loaded.
class _ArtPlaceholder extends StatelessWidget {
  const _ArtPlaceholder();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: const Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.egg_alt_rounded, size: 120, color: kAmber),
            Positioned(
              bottom: 60,
              right: 70,
              child: Icon(Icons.grain, size: 48, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// Start-up screen while the session loads: the logo large on the same blue
/// as the Android launch screen, so start-up flows into Get Started.
class LogoSplash extends StatelessWidget {
  const LogoSplash({super.key, this.grow = false});

  /// Grows the logo from the size of the Android launch icon to full size;
  /// used once, on the first frame after the system splash.
  final bool grow;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBlue,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.78,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: grow ? 0.4 : 1, end: 1),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutBack,
                    builder: (_, s, child) =>
                        Transform.scale(scale: s, child: child),
                    child: Image.asset(
                      kAgriFeedLogo,
                      key: const ValueKey('splash-logo'),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const _ArtPlaceholder(),
                    ),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 48),
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: kAmber,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown by main() while the backend starts, before [MyApp] exists.
class StartupSplashApp extends StatelessWidget {
  const StartupSplashApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: LogoSplash(grow: true),
  );
}
