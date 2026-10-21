import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../services/session.dart';
import '../admin/admin_shell.dart';
import '../home/home_shell.dart';
import 'login_page.dart';
import 'status_pages.dart';
import 'verify_email_page.dart';

/// Routes by session state: login, verify email, suspended, admin or user.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = AppScope.of(context).session;
    if (!session.started) session.start();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.session,
      builder: (context, _) {
        final s = scope.session.state;
        switch (s.stage) {
          case SessionStage.loading:
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          case SessionStage.signedOut:
            return LoginPage(auth: scope.auth);
          case SessionStage.unverified:
            return VerifyEmailPage(
              auth: scope.auth,
              onVerified: scope.session.refresh,
            );
          case SessionStage.suspended:
            return SuspendedPage(
              reason: s.message,
              onSignOut: scope.auth.signOut,
            );
          case SessionStage.error:
            return SessionErrorPage(
              message: s.message ?? 'Unknown error',
              onRetry: scope.session.clearErrorAndRetry,
              onSignOut: scope.auth.signOut,
            );
          case SessionStage.admin:
            return const AdminShell();
          case SessionStage.user:
            return const HomeShell();
        }
      },
    );
  }
}
