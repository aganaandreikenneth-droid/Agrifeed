import 'package:agrifeed/app.dart';
import 'package:agrifeed/core/backend.dart';
import 'package:agrifeed/core/widgets/text_prompt.dart';
import 'package:agrifeed/features/auth/login_page.dart';
import 'package:agrifeed/features/home/home_shell.dart';
import 'package:agrifeed/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls; any unexpected Firebase call fails the test via noSuchMethod.
class FakeAuthService implements AuthService {
  int signInCalls = 0;

  @override
  Future<void> signIn(String email, String password) async => signInCalls++;

  final resetRequests = <String>[];

  @override
  Future<void> sendPasswordReset(String email) async =>
      resetRequests.add(email);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget wrap(Widget child) => MaterialApp(theme: agrifeedTheme(), home: child);

void main() {
  testWidgets('blocked startup shows the reason and never builds the login', (
    tester,
  ) async {
    await tester.pumpWidget(
      MyApp.fromBoot(
        const BootBlocked('Firebase Emulator not reachable', [
          'Database emulator at 127.0.0.1:9000',
          'The app does not fall back to production.',
        ]),
      ),
    );
    expect(find.text('Firebase Emulator not reachable'), findsOneWidget);
    expect(
      find.text('The app does not fall back to production.'),
      findsOneWidget,
    );
    expect(find.byType(LoginPage), findsNothing);
  });

  testWidgets('sign-in with empty fields shows a validation error', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(wrap(LoginPage(auth: auth)));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Please type a valid email address.'), findsOneWidget);
    expect(auth.signInCalls, 0);
  });

  testWidgets('create-account mode enforces the minimum password length', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(LoginPage(auth: FakeAuthService())));
    await tester.tap(find.text('New to AgriFeed? Create account'));
    await tester.pump();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Ana');
    await tester.enterText(fields.at(1), 'ana@example.com');
    await tester.enterText(fields.at(2), 'short');
    await tester.enterText(fields.at(3), 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();
    expect(
      find.text('Password must be at least $minNewPasswordLength characters.'),
      findsOneWidget,
    );
  });

  testWidgets('valid sign-in form calls the auth service', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(wrap(LoginPage(auth: auth)));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'ana@example.com');
    await tester.enterText(fields.at(1), 'any-existing-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(auth.signInCalls, 1);
  });

  testWidgets(
    'no-feeder state explains next steps and disables unavailable actions',
    (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(body: NoFeederPanel())));
      expect(find.text('No feeder registered'), findsOneWidget);
      expect(
        find.text('Create a virtual feeder or register a device to continue.'),
        findsOneWidget,
      );
      final create = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create virtual feeder'),
      );
      expect(create.onPressed, isNull);
    },
  );

  // Regression: disposing the dialog's controller right after showDialog
  // returned crashed the app ('_dependents.isEmpty') during manual testing.
  testWidgets('text prompt returns the value and closes cleanly', (
    tester,
  ) async {
    String? result = 'unset';
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showTextPrompt(
              context,
              title: 'Display name',
              label: 'Name',
              initial: 'Old',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  New name  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'New name');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('forgot password sends the reset and shows a neutral message', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(wrap(LoginPage(auth: auth)));
    await tester.enterText(find.byType(TextField).at(0), 'ana@example.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send link'));
    await tester.pumpAndSettle();
    expect(auth.resetRequests, ['ana@example.com']);
    expect(find.textContaining('If that email is registered'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
