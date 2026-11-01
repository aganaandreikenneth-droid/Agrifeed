import 'package:agrifeed/app.dart';
import 'package:agrifeed/design.dart';
import 'package:agrifeed/features/feeder/tabs/feeding_tab.dart' show kGateMaxS;
import 'package:agrifeed/features/home/home_shell.dart';
import 'package:agrifeed/services/feeder_repository.dart';
import 'package:agrifeed/services/feeder_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_feeder_source.dart';

/// Milestone 1 (single feeder): the four tabs, the Feeding sections, the
/// alerts bell and Settings, on fakes (no Firebase).
class World {
  final src = FakeFeederSource();
  final feeders = FakeFeederRepository();
  final live = FakeFeederLive();
  late final FeederSelectionController c;
}

Future<World> pumpOwner(
  WidgetTester tester, {
  bool archived = false,
  String mode = 'simulated',
}) async {
  // Tall surface: whole tabs are built at once.
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final w = World();
  w.c = FeederSelectionController(w.src, 'u1')..start();
  await tester.pumpWidget(
    MaterialApp(
      theme: agrifeedTheme(),
      home: HomeShell(
        selection: w.c,
        feeders: w.feeders,
        live: w.live,
        uid: 'u1',
      ),
    ),
  );
  w.src.index.add({'fA': 'owner'});
  w.src.feeder('fA', name: 'AgriFeed', archived: archived, mode: mode);
  w.src.connected.add(true);
  await tester.pump();
  return w;
}

Future<void> done(WidgetTester tester, World w) async {
  await tester.pumpWidget(const SizedBox());
  w.c.dispose();
}

Finder navIcon(IconData icon) =>
    find.descendant(of: find.byType(PillNav), matching: find.byIcon(icon));

Future<void> openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(navIcon(icon));
  await tester.pump();
}

const tabIcons = [
  Icons.home_rounded,
  Icons.schedule_rounded,
  Icons.bar_chart_rounded,
  Icons.person_rounded,
];

FeederAlert alert(String type, {bool active = true}) => FeederAlert(
  id: type,
  type: type,
  severity: 'warning',
  active: active,
  lastAt: DateTime.now().millisecondsSinceEpoch,
  simulated: true,
);

void main() {
  testWidgets('the four tabs navigate from the PillNav', (tester) async {
    final w = await pumpOwner(tester);
    String title() => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;
    expect(find.byKey(const ValueKey('home-greeting')), findsOneWidget);
    for (final (icon, name) in [
      (Icons.schedule_rounded, 'Feeding'),
      (Icons.bar_chart_rounded, 'Activity'),
      (Icons.person_rounded, 'Settings'),
    ]) {
      await openTab(tester, icon);
      expect(title(), name);
    }
    await openTab(tester, Icons.home_rounded);
    expect(find.byKey(const ValueKey('home-greeting')), findsOneWidget);
    await done(tester, w);
  });

  testWidgets('Feeding: nothing is sent while the controller is silent', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    await openTab(tester, Icons.schedule_rounded);

    double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
    expect(top('section-gate'), lessThan(top('section-manual')));
    expect(top('section-manual'), lessThan(top('section-schedules')));

    // No status report: gate and manual feeding stay disabled.
    for (final key in ['gate-open', 'gate-close', 'manual-feed']) {
      final b = tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key)));
      expect(b.onPressed, isNull, reason: key);
    }
    // Schedules are stored for the controller, so they can still be edited.
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const ValueKey('add-schedule')))
          .onPressed,
      isNotNull,
    );
    // The state is never inferred: UNKNOWN until a controller reports it.
    expect(find.text('Gate: UNKNOWN'), findsOneWidget);
    expect(find.textContaining('controller is offline'), findsNWidgets(2));

    await tester.tap(find.text('OPEN GATE'), warnIfMissed: false);
    await tester.pump();
    expect(w.live.updates, isEmpty);
    await done(tester, w);
  });

  testWidgets('Feeding: gate request and controller report', (tester) async {
    final w = await pumpOwner(tester);
    w.live
        .at('feeders/fA/status')
        .add({'lastSeen': DateTime.now().millisecondsSinceEpoch});
    await openTab(tester, Icons.schedule_rounded);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('gate-open')));
    await tester.pump();
    final req = w.live.updates.single['feeders/fA/gate/request'] as Map;
    expect(req['action'], 'open');
    // OPEN holds until CLOSE; durationS is only the rules-required value.
    expect(req['durationS'], kGateMaxS);
    expect(find.byKey(const ValueKey('gate-seconds')), findsNothing);
    expect(find.text('Waiting for the controller...'), findsOneWidget);

    w.live.at('feeders/fA/gate/state').add({
      'position': 'open',
      'lastRequestId': req['id'],
      'lastResult': 'done',
    });
    await tester.pump();
    expect(find.text('Gate: OPEN'), findsOneWidget);
    expect(find.textContaining('until you press CLOSE GATE'), findsWidgets);

    // While open, OPEN is disabled and CLOSE can be sent.
    final open = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('gate-open')),
    );
    expect(open.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('gate-close')));
    await tester.pump();
    final close = w.live.updates.last['feeders/fA/gate/request'] as Map;
    expect(close['action'], 'close');
    await done(tester, w);
  });

  testWidgets('no selection, registration, invitation or member UI anywhere', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    final banned = RegExp(
      r'invit|member|share|switch|choose a feeder|create virtual|'
      r'register|archive|restore|delete|my feeders',
      caseSensitive: false,
    );
    for (final icon in tabIcons) {
      await openTab(tester, icon);
      expect(find.textContaining(banned), findsNothing, reason: '$icon');
    }
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    await done(tester, w);
  });

  testWidgets('no measurement is shown before the controller reports', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    final grams = RegExp(r'\d\s?(g|kg)\b|\d+\s?%');
    // Feeding and Settings show request amounts (presets), not readings.
    for (final icon in [Icons.home_rounded, Icons.bar_chart_rounded]) {
      await openTab(tester, icon);
      expect(find.textContaining(grams), findsNothing, reason: '$icon');
    }
    await done(tester, w);
  });

  testWidgets('Manual feeding: blocked without enough verified feed', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    final now = DateTime.now().millisecondsSinceEpoch;
    w.live.at('feeders/fA/status').add({'lastSeen': now, 'condition': 'ok'});
    w.live.at('feeders/fA/config').add({
      'calibrationStatus': 'calibrated',
      'maxDispenseG': 200,
    });
    w.live.at('feeders/fA/telemetry/current').add({
      'weightG': 60,
      'measuredAt': now,
      'quality': 'ok',
    });
    await openTab(tester, Icons.schedule_rounded);
    await tester.pump(const Duration(milliseconds: 100));

    ButtonStyleButton feedButton() =>
        tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('manual-feed')));
    bool chipEnabled(int g) => tester
        .widget<ChoiceChip>(find.byKey(ValueKey('preset-$g')))
        .onSelected != null;
    Future<void> hopper(int grams) async {
      w.live.at('feeders/fA/telemetry/current').add({
        'weightG': grams,
        'measuredAt': DateTime.now().millisecondsSinceEpoch,
        'quality': 'ok',
      });
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 60 g: 25 g and 50 g only; the 100 g default moves to 50 g.
    expect(find.text('In the hopper: 60 g'), findsOneWidget);
    expect([for (final g in [25, 50, 100, 150, 200]) chipEnabled(g)],
        [true, true, false, false, false]);
    expect(find.text('Feed 50 g now'), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-limited')), findsOneWidget);
    expect(feedButton().onPressed, isNotNull);

    // 40 g: only 25 g.
    await hopper(40);
    expect([for (final g in [25, 50, 100, 150, 200]) chipEnabled(g)],
        [true, false, false, false, false]);
    expect(find.text('Feed 25 g now'), findsOneWidget);

    // 278 g: every amount.
    await hopper(278);
    expect([for (final g in [25, 50, 100, 150, 200]) chipEnabled(g)],
        [true, true, true, true, true]);
    expect(find.byKey(const ValueKey('manual-limited')), findsNothing);

    // Empty hopper: nothing can be chosen or sent.
    await hopper(2);
    expect([for (final g in [25, 50, 100, 150, 200]) chipEnabled(g)],
        [false, false, false, false, false]);
    expect(find.textContaining('hopper is empty'), findsOneWidget);
    expect(feedButton().onPressed, isNull);

    // Back to 60 g: 50 g is sent after confirming.
    await hopper(60);
    await tester.tap(find.byKey(const ValueKey('preset-50')));
    await tester.pump();
    expect(find.byKey(const ValueKey('manual-warning')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('manual-feed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-feed')));
    await tester.pumpAndSettle();
    expect(w.live.updates.last.keys, contains('feeders/fA/activeCommand'));

    // Not calibrated: the weight cannot be verified, so feeding is blocked.
    w.live.at('feeders/fA/config').add({
      'calibrationStatus': 'uncalibrated',
      'maxDispenseG': 200,
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('not calibrated'), findsOneWidget);
    expect(feedButton().onPressed, isNull);
    await done(tester, w);
  });

  testWidgets('Manual feeding: blocked when the load cell stops reporting', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    final now = DateTime.now().millisecondsSinceEpoch;
    w.live.at('feeders/fA/status').add({'lastSeen': now, 'condition': 'error'});
    w.live.at('feeders/fA/config').add({'calibrationStatus': 'calibrated'});
    // Last weight is 40 s old: the HX711 stopped sending.
    w.live.at('feeders/fA/telemetry/current').add({
      'weightG': 1500,
      'measuredAt': now - 40000,
      'quality': 'ok',
    });
    await openTab(tester, Icons.schedule_rounded);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('load cell is not responding'), findsOneWidget);
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const ValueKey('manual-feed')))
          .onPressed,
      isNull,
    );
    await done(tester, w);
  });

  testWidgets('Home: a negative hopper reading is shown as 0 g and 0%', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    final now = DateTime.now().millisecondsSinceEpoch;
    w.live.at('feeders/fA/status').add({'lastSeen': now});
    w.live.at('feeders/fA/telemetry/current').add({
      'weightG': -12,
      'measuredAt': now,
      'quality': 'ok',
    });
    await openTab(tester, Icons.home_rounded);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('0 g'), findsOneWidget);
    expect(find.textContaining('0% of'), findsOneWidget);
    expect(find.textContaining(RegExp(r'-\s?\d')), findsNothing); // no "-12 g"
    await done(tester, w);
  });

  testWidgets('Home: the feeder RTC time from status/rtcTime', (tester) async {
    final w = await pumpOwner(tester);
    await openTab(tester, Icons.home_rounded);
    expect(find.text('No RTC reading yet'), findsOneWidget);

    w.live.at('feeders/fA/status').add({
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
      'rtcTime': '2026-11-01T14:05:09',
    });
    await tester.pump(const Duration(milliseconds: 100));
    final time = tester.widget<Text>(find.byKey(const ValueKey('home-rtc-time')));
    expect(time.data, matches(RegExp(r'^14:05:(09|1\d)$')));
    expect(find.textContaining('Sun, 1 Nov 2026'), findsOneWidget);

    // Offline: the last reported time stays, it does not count on.
    w.live.at('feeders/fA/status').add({
      'lastSeen': DateTime.now().millisecondsSinceEpoch - 120000,
      'rtcTime': '2026-11-01T14:05:09',
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('14:05:09'), findsOneWidget);
    expect(find.textContaining('feeder is offline'), findsOneWidget);
    await done(tester, w);
  });

  testWidgets('bell: empty state, then a live active alert with a count', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    w.feeders.alerts('fA').add([]);
    await tester.pump();
    final badge = find.byKey(const ValueKey('alerts-bell'));
    expect(tester.widget<Badge>(badge).isLabelVisible, isFalse);

    await tester.tap(find.byIcon(Icons.notifications_none_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alerts-empty')), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('alerts-empty'))))
        .pop();
    await tester.pumpAndSettle();

    w.feeders.alerts('fA').add([
      alert('low_feed'),
      alert('stuck_feed', active: false),
    ]);
    await tester.pumpAndSettle();
    expect(tester.widget<Badge>(badge).isLabelVisible, isTrue);
    expect(
      find.descendant(of: badge, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.notifications_active_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Low feed'), findsOneWidget);
    expect(find.text('Feed blockage'), findsOneWidget);
    expect(find.text('SIMULATED'), findsNWidgets(2));
    await done(tester, w);
  });

  testWidgets('Settings: profile, feeder, controller; nothing else to manage', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    await openTab(tester, Icons.person_rounded);
    expect(find.text('Profile and account'), findsOneWidget);
    expect(find.text('AgriFeed'), findsNWidgets(2)); // app bar + name row
    expect(find.text('Asia/Manila'), findsOneWidget);
    expect(find.textContaining('Simulator (development)'), findsOneWidget);
    expect(find.byKey(const ValueKey('simulation-panel')), findsOneWidget);
    expect(find.text('Hopper capacity and low-feed threshold'), findsOneWidget);
    await done(tester, w);
  });

  testWidgets('Settings: calibrate the scale from the app (real feeder)', (
    tester,
  ) async {
    final w = await pumpOwner(tester, mode: 'live');
    final now = DateTime.now().millisecondsSinceEpoch;
    w.live.at('feeders/fA/status').add({'lastSeen': now});
    w.live.at('feeders/fA/config').add({'calibrationStatus': 'uncalibrated'});
    await openTab(tester, Icons.person_rounded);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('simulation-panel')), findsNothing);
    expect(find.text('Scale not calibrated'), findsOneWidget);

    // Step 1: set zero.
    await tester.tap(find.byKey(const ValueKey('cal-tare')));
    await tester.pump();
    final tare = w.live.updates.last['feeders/fA/calibration/request'] as Map;
    expect(tare['action'], 'tare');
    expect(tare.containsKey('knownG'), isFalse);
    expect(find.text('Waiting for the feeder...'), findsOneWidget);
    w.live.at('feeders/fA/calibration/state').add({
      'lastRequestId': tare['id'],
      'action': 'tare',
      'result': 'done',
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Zero set'), findsOneWidget);

    // Step 2: calibrate with 500 g; a refusal shows the controller's reason.
    await tester.enterText(find.byKey(const ValueKey('cal-known')), '500');
    await tester.tap(find.byKey(const ValueKey('cal-calibrate')));
    await tester.pump();
    final cal = w.live.updates.last['feeders/fA/calibration/request'] as Map;
    expect(cal['action'], 'calibrate');
    expect(cal['knownG'], 500);
    w.live.at('feeders/fA/calibration/state').add({
      'lastRequestId': cal['id'],
      'action': 'calibrate',
      'result': 'rejected',
      'reason': 'The reading did not change',
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Refused: The reading did not change'), findsOneWidget);

    // Accepted: the controller reports the scale as calibrated.
    await tester.tap(find.byKey(const ValueKey('cal-calibrate')));
    await tester.pump();
    final cal2 = w.live.updates.last['feeders/fA/calibration/request'] as Map;
    w.live.at('feeders/fA/calibration/state').add({
      'lastRequestId': cal2['id'],
      'action': 'calibrate',
      'result': 'done',
    });
    w.live.at('feeders/fA/config').add({'calibrationStatus': 'calibrated'});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Scale calibrated'), findsOneWidget);
    expect(find.textContaining('now in real grams'), findsOneWidget);
    await done(tester, w);
  });

  testWidgets('Settings: rename and change the time zone', (tester) async {
    final w = await pumpOwner(tester);
    await openTab(tester, Icons.person_rounded);

    await tester.tap(find.byTooltip('Edit feeder name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  North coop ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit feeder time zone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UTC'));
    await tester.pumpAndSettle();

    expect(w.feeders.writes, ['name:fA:North coop', 'timezone:fA:UTC']);
    await done(tester, w);
  });

  testWidgets('Settings: a failed save is reported, not hidden', (
    tester,
  ) async {
    final w = await pumpOwner(tester);
    w.feeders.failWith = Exception('permission-denied');
    await openTab(tester, Icons.person_rounded);
    await tester.tap(find.byTooltip('Edit feeder name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Other');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save the change'), findsOneWidget);
    expect(w.feeders.writes, isEmpty);
    await done(tester, w);
  });

  testWidgets('archived feeder: name and time zone are read-only', (
    tester,
  ) async {
    final w = await pumpOwner(tester, archived: true);
    await openTab(tester, Icons.person_rounded);
    expect(find.byTooltip('Edit feeder name'), findsNothing);
    expect(find.byTooltip('Edit feeder time zone'), findsNothing);
    await done(tester, w);
  });
}
