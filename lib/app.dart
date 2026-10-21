import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'core/backend.dart';
import 'core/widgets/panel.dart';
import 'design.dart';
import 'features/auth/auth_gate.dart';
import 'features/auth/boot_blocked_page.dart';

ThemeData agrifeedTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: kField)
      .copyWith(primary: kSoil, onPrimary: Colors.white, secondary: kGrain),
  scaffoldBackgroundColor: kBg,
  appBarTheme: const AppBarTheme(
    backgroundColor: kBg,
    foregroundColor: kSoil,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
);

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.services, this.blocked})
    : assert((services == null) != (blocked == null));

  /// Set when the backend started; null when startup was blocked.
  final AppServices? services;
  final BootBlocked? blocked;

  factory MyApp.fromBoot(BootResult boot) => switch (boot) {
    BootReady(:final backend) => MyApp(services: AppServices.create(backend)),
    BootBlocked() => MyApp(blocked: boot),
  };

  @override
  Widget build(BuildContext context) {
    final services = this.services;
    final app = MaterialApp(
      title: 'AgriFeed',
      debugShowCheckedModeBanner: false,
      theme: agrifeedTheme(),
      builder: (context, child) =>
          services != null && services.backend.isEmulator
          ? Banner(
              message: 'EMULATOR',
              location: BannerLocation.topEnd,
              color: kGrain,
              child: child!,
            )
          : child!,
      home: services != null
          ? const AuthGate()
          : BootBlockedPage(title: blocked!.title, details: blocked!.details),
    );
    return services != null ? AppScope(services: services, child: app) : app;
  }
}
