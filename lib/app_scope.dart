import 'package:flutter/widgets.dart';

import 'core/backend.dart';
import 'services/admin_service.dart';
import 'services/auth_service.dart';
import 'services/feeder_index_repository.dart';
import 'services/profile_repository.dart';
import 'services/session.dart';

/// Services for the active environment. Created once at startup.
class AppServices {
  AppServices._(
    this.backend,
    this.auth,
    this.session,
    this.profiles,
    this.feeders,
    this.admin,
  );

  factory AppServices.create(Backend backend) {
    final profiles = ProfileRepository(backend.db);
    return AppServices._(
      backend,
      AuthService(backend.auth),
      SessionController(backend.auth, backend.db, profiles),
      profiles,
      FeederIndexRepository(backend.db),
      AdminService(backend.functions, backend.db),
    );
  }

  final Backend backend;
  final AuthService auth;
  final SessionController session;
  final ProfileRepository profiles;
  final FeederIndexRepository feeders;
  final AdminService admin;
}

/// Hands [AppServices] down the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
