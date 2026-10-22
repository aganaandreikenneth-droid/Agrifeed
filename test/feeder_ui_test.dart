import 'package:agrifeed/app.dart';
import 'package:agrifeed/features/feeder/feeder_shell.dart';
import 'package:agrifeed/features/home/home_shell.dart';
import 'package:agrifeed/services/feeder_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_feeder_source.dart';

/// Pumps HomeShell on a fake data source (no Firebase).
Future<(FakeFeederSource, FeederSelectionController)> pumpHome(
  WidgetTester tester, {
  String? saved,
}) async {
  final src = FakeFeederSource(saved: saved);
  final c = FeederSelectionController(src, 'u1')..start();
  await tester.pumpWidget(
    MaterialApp(
      theme: agrifeedTheme(),
      home: HomeShell(selection: c),
    ),
  );
  await tester.pump();
  return (src, c);
}

/// Unmounts and disposes (cancels the controller's timer and listeners).
Future<void> done(WidgetTester tester, FeederSelectionController c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
}

void main() {
  testWidgets('loading, then onboarding when no feeder is registered', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    src.index.add({});
    await tester.pump();
    expect(find.text('No feeder registered'), findsOneWidget);
    final create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create virtual feeder'),
    );
    expect(create.onPressed, isNotNull);
    final register = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Register a device'),
    );
    expect(register.onPressed, isNull);
    await done(tester, c);
  });

  testWidgets('one feeder opens directly with its name and VIRTUAL badge', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA', name: 'Backyard coop');
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);
    expect(find.text('Backyard coop'), findsOneWidget);
    expect(find.text('VIRTUAL'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('several feeders: choose one, then switch from the app bar', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner', 'fB': 'member'});
    src.feeder('fA', name: 'Alpha');
    src.feeder('fB', name: 'Bravo', owner: false, mode: 'live');
    await tester.pump();
    expect(find.text('Choose a feeder'), findsOneWidget);
    expect(find.text('VIRTUAL'), findsOneWidget); // Alpha only

    await tester.tap(find.text('Bravo'));
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);
    expect(find.text('VIRTUAL'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('feeder-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feeder-fA')));
    await tester.pumpAndSettle();
    expect(c.selected?.feederId, 'fA');
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('VIRTUAL'), findsOneWidget);
    expect(src.savedWrites, ['fB', 'fA']);
    await done(tester, c);
  });

  testWidgets('the feed button explains Phase 5 and sends nothing', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.grain));
    await tester.pump();
    expect(find.text(kManualFeedDisabledMessage), findsOneWidget);
    expect(src.savedWrites, ['fA']); // the only write: the selection
    await done(tester, c);
  });

  testWidgets('tabs follow the member permissions, live', (tester) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fM': 'member'});
    src.feeder('fM', owner: false, permissions: {'viewDashboard': true});
    await tester.pump();
    await tester.tap(find.byIcon(Icons.history_rounded));
    await tester.pump();
    expect(find.byKey(const ValueKey('no-permission')), findsOneWidget);

    src.member('fM').add({
      'role': 'member',
      'status': 'active',
      'permissions': {'viewDashboard': true, 'viewHistory': true},
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('no-permission')), findsNothing);
    await done(tester, c);
  });

  testWidgets('removed while open: back to onboarding with a message', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fM': 'member'});
    src.feeder('fM', name: 'Shared coop', owner: false);
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);

    src.member('fM').add({'role': 'member', 'status': 'removed'});
    src.meta('fM').addError(Exception('permission-denied'));
    await tester.pump();
    await tester.pump(); // post-frame snackbar
    expect(
      find.text('You no longer have access to "Shared coop".'),
      findsOneWidget,
    );
    src.index.add({});
    await tester.pump();
    expect(find.text('No feeder registered'), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('archived and offline states are shown', (tester) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA', archived: true);
    src.connected.add(true);
    await tester.pump();
    expect(find.text('ARCHIVED'), findsOneWidget);
    expect(find.textContaining('archived and read-only'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
    src.connected.add(false);
    await tester.pump();
    expect(find.textContaining('Offline'), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('an index error offers a retry', (tester) async {
    final (src, c) = await pumpHome(tester);
    src.index.addError(Exception('denied'));
    await tester.pump();
    expect(find.textContaining('Could not load your feeders'), findsOneWidget);
    src.index.add({}); // the cause is fixed (e.g. connection back)
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('No feeder registered'), findsOneWidget);
    await done(tester, c);
  });
}
