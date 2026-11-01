import 'package:flutter/widgets.dart';

import 'core/backend.dart';
import 'services/admin_service.dart';
import 'services/auth_service.dart';
import 'services/feeder_actions.dart';
import 'services/feeder_live.dart';
import 'services/feeder_repository.dart';
import 'services/feeder_selection.dart';
import 'services/profile_repository.dart';
import 'services/session.dart';

/// Services for the active environment. Created once at startup.
class AppServices {
  AppServices._(
    this.backend,
    this.auth,
    this.session,
    this.profiles,
    this.feederData,
    this.feederActions,
    this.feeders,
    this.live,
    this.admin,
  );

  factory AppServices.create(Backend backend) {
    final profiles = ProfileRepository(backend.db);
    return AppServices._(
      backend,
      AuthService(backend.auth),
      SessionController(backend.auth, backend.db, profiles),
      profiles,
      FirebaseFeederDataSource(backend.db),
      FeederActions(backend.functions),
      FirebaseFeederRepository(backend.db),
      FirebaseFeederLive(backend.db),
      AdminService(backend.functions, backend.db),
    );
  }

  final Backend backend;
  final AuthService auth;
  final SessionController session;
  final ProfileRepository profiles;
  final FeederDataSource feederData;
  final FeederActions feederActions;
  final FeederRepository feeders;
  final FeederLive live;
  final AdminService admin;
}

/// Hands [AppServices] down the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) => maybeOf(context)!;

  static AppServices? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
