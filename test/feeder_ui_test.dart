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
  FakeFeederRepository? feeders,
}) async {
  final src = FakeFeederSource(saved: saved);
  final c = FeederSelectionController(src, 'u1')..start();
  await tester.pumpWidget(
    MaterialApp(
      theme: agrifeedTheme(),
      home: HomeShell(
        selection: c,
        feeders: feeders ?? FakeFeederRepository(),
        live: FakeFeederLive(),
        uid: 'u1',
      ),
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
  testWidgets('loading, then a plain notice when no machine is assigned', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    src.index.add({});
    await tester.pump();
    expect(find.byKey(const ValueKey('no-feeder-assigned')), findsOneWidget);
    // Assignment is backend-only: nothing to create or register here.
    expect(find.textContaining('Create'), findsNothing);
    expect(find.textContaining('Register'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await done(tester, c);
  });

  testWidgets('the assigned feeder opens Home directly, labelled SIMULATION', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA', name: 'Backyard coop');
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);
    expect(find.text('Backyard coop'), findsOneWidget);
    expect(find.text('SIMULATION'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-greeting')), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('a controller feeder (live) has no SIMULATION label', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA', mode: 'live');
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);
    expect(find.text('SIMULATION'), findsNothing);
    await done(tester, c);
  });

  testWidgets('several feeders (old data): one opens, no chooser or switcher', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fB': 'owner', 'fA': 'owner'});
    src.feeder('fA', name: 'Alpha');
    src.feeder('fB', name: 'Bravo');
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);
    expect(c.selected?.feederId, 'fA'); // first by name
    expect(find.text('Choose a feeder'), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(src.savedWrites, ['fA']);
    await done(tester, c);
  });

  testWidgets('several feeders: the last used one opens', (tester) async {
    final (src, c) = await pumpHome(tester, saved: 'fB');
    src.index.add({'fA': 'owner', 'fB': 'owner'});
    src.feeder('fA', name: 'Alpha');
    src.feeder('fB', name: 'Bravo');
    await tester.pump();
    expect(c.selected?.feederId, 'fB');
    expect(find.text('Bravo'), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('the feed button opens the Feeding tab and sends nothing', (
    tester,
  ) async {
    final feeders = FakeFeederRepository();
    final (src, c) = await pumpHome(tester, feeders: feeders);
    src.index.add({'fA': 'owner'});
    src.feeder('fA');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.grain));
    await tester.pump();
    expect(find.text('Feeding'), findsOneWidget);
    expect(find.byKey(const ValueKey('section-gate')), findsOneWidget);
    expect(src.savedWrites, ['fA']); // the only write: the selection
    expect(feeders.writes, isEmpty);
    await done(tester, c);
  });

  testWidgets('tabs follow the permissions, live', (tester) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fM': 'member'});
    src.feeder('fM', owner: false, permissions: {'viewDashboard': true});
    await tester.pump();
    await tester.tap(find.byIcon(Icons.bar_chart_rounded).last);
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

  testWidgets('access lost while open: back to the notice with a message', (
    tester,
  ) async {
    final (src, c) = await pumpHome(tester);
    src.index.add({'fA': 'owner'});
    src.feeder('fA', name: 'Shared coop');
    await tester.pump();
    expect(find.byType(FeederShell), findsOneWidget);

    src.meta('fA').addError(Exception('permission-denied'));
    await tester.pump();
    await tester.pump(); // post-frame snackbar
    expect(
      find.text('You no longer have access to "Shared coop".'),
      findsOneWidget,
    );
    src.index.add({});
    await tester.pump();
    expect(find.byKey(const ValueKey('no-feeder-assigned')), findsOneWidget);
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
    expect(find.textContaining('Could not load your feeder'), findsOneWidget);
    src.index.add({}); // the cause is fixed (e.g. connection back)
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byKey(const ValueKey('no-feeder-assigned')), findsOneWidget);
    await done(tester, c);
  });
}
