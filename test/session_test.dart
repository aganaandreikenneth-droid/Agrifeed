import 'package:agrifeed/core/env.dart';
import 'package:agrifeed/services/auth_service.dart';
import 'package:agrifeed/services/profile_repository.dart';
import 'package:agrifeed/services/session.dart';
import 'package:flutter_test/flutter_test.dart';

SessionStage stage({
  bool signedIn = true,
  bool emailVerified = true,
  bool? suspended = false,
  bool isAdmin = false,
  bool? profileReady = true,
  String? error,
}) => resolveSession(
  signedIn: signedIn,
  emailVerified: emailVerified,
  suspended: suspended,
  isAdmin: isAdmin,
  profileReady: profileReady,
  error: error,
).stage;

void main() {
  group('resolveSession', () {
    test('signed out wins over everything', () {
      expect(stage(signedIn: false, isAdmin: true), SessionStage.signedOut);
    });
    test('unverified users never reach the database-backed screens', () {
      expect(
        stage(emailVerified: false, isAdmin: true),
        SessionStage.unverified,
      );
    });
    test('waits for account status before routing', () {
      expect(stage(suspended: null), SessionStage.loading);
    });
    test('suspension overrides the admin role', () {
      expect(stage(suspended: true, isAdmin: true), SessionStage.suspended);
    });
    test('suspension reason is passed through', () {
      final s = resolveSession(
        signedIn: true,
        emailVerified: true,
        suspended: true,
        isAdmin: false,
        profileReady: null,
        suspendReason: 'policy',
      );
      expect(s.message, 'policy');
    });
    test('waits for the profile before routing', () {
      expect(stage(profileReady: null), SessionStage.loading);
    });
    test('routes admins and users', () {
      expect(stage(isAdmin: true), SessionStage.admin);
      expect(stage(), SessionStage.user);
    });
    test('errors are shown for verified users', () {
      expect(stage(error: 'x'), SessionStage.error);
    });
  });

  group('environment', () {
    test('emulator is allowed', () {
      expect(
        decideEnvironment('emulator', productionEnabled: false),
        EnvDecision.emulator,
      );
    });
    test('production is blocked in this build', () {
      expect(
        decideEnvironment('production', productionEnabled: false),
        EnvDecision.productionBlocked,
      );
      expect(kProductionEnabled, isFalse);
    });
    test('unknown names are rejected rather than defaulted', () {
      expect(
        decideEnvironment('prod', productionEnabled: false),
        EnvDecision.invalid,
      );
    });
    test('emulator project cannot be a real project', () {
      expect(kEmulatorProjectId.startsWith('demo-'), isTrue);
    });
  });

  group('validateAuthForm', () {
    String? v({
      bool creating = true,
      String name = 'Ana',
      String email = 'ana@example.com',
      String pw = 'longenough',
      String? confirm,
    }) => validateAuthForm(
      creating: creating,
      name: name,
      email: email,
      password: pw,
      confirm: confirm ?? pw,
    );

    test('accepts a valid registration', () => expect(v(), isNull));
    test(
      'requires a name when registering',
      () => expect(v(name: '  '), isNotNull),
    );
    test('rejects malformed email', () => expect(v(email: 'ana@'), isNotNull));
    test(
      'requires 8+ characters for new passwords',
      () => expect(v(pw: '1234567'), isNotNull),
    );
    test(
      'requires matching confirmation',
      () => expect(v(confirm: 'different1'), isNotNull),
    );
    test('existing users may sign in with older short passwords', () {
      expect(v(creating: false, pw: '123456'), isNull);
    });
  });

  test('display names are trimmed, defaulted and capped', () {
    expect(cleanDisplayName('  Ana  '), 'Ana');
    expect(cleanDisplayName(null), 'AgriFeed user');
    expect(cleanDisplayName('x' * 80).length, 60);
  });
}
