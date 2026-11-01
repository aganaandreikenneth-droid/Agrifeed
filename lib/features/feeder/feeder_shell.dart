import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_live.dart';
import '../../services/feeder_repository.dart';
import '../../services/feeder_selection.dart';
import 'alerts_sheet.dart';
import 'feeder_scope.dart';
import 'feeder_badge.dart';
import 'tabs/activity_tab.dart';
import 'tabs/feeding_tab.dart';
import 'tabs/home_tab.dart';
import 'tabs/settings_tab.dart';

/// Tab indexes, in the order of the PillNav icons in design.dart.
class FeederTab {
  static const home = 0;
  static const feeding = 1;
  static const activity = 2;
  static const settings = 3;
}

/// The account's feeder: app bar title and alerts bell, status banners,
/// the four tabs (Home, Feeding, Activity, Settings) and the original
/// PillNav from design.dart. The centre button opens the Feeding tab; it
/// sends nothing.
class FeederShell extends StatefulWidget {
  const FeederShell({
    super.key,
    required this.selection,
    required this.feeders,
    required this.live,
    required this.uid,
  });

  final FeederSelectionController selection;
  final FeederRepository feeders;
  final FeederLive live;
  final String uid;

  @override
  State<FeederShell> createState() => _FeederShellState();
}

class _FeederShellState extends State<FeederShell> {
  int _tab = FeederTab.home;
  FeederControls? _controls;

  FeederControls _controlsFor(String feederId) {
    final c = _controls;
    if (c != null && c.feederId == feederId) return c;
    return _controls = FeederControls(widget.live, feederId, widget.uid);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final feeder = selection.selected!;
    return FeederScope(
      feeder: feeder,
      online: selection.online,
      controls: _controlsFor(feeder.feederId),
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: const IconBox(icon: Icons.egg_alt_outlined),
          title: FeederTitle(feeder),
          actions: [
            AlertsBell(
              // A new listener per feeder.
              key: ValueKey('alerts-${feeder.feederId}'),
              feederId: feeder.feederId,
              feederName: feeder.name,
              feeders: widget.feeders,
            ),
          ],
        ),
        body: Column(
          children: [
            if (!selection.online)
              const _Banner(
                icon: Icons.cloud_off_rounded,
                text: 'Offline. Changes cannot be saved until the connection returns.',
              ),
            if (feeder.archived)
              const _Banner(
                icon: Icons.archive_outlined,
                text: 'This feeder is archived and read-only. Feeding and schedules are disabled.',
              ),
            Expanded(
              // Keyed by feeder: if the account's feeder ever changes, the
              // page is rebuilt so no listener of the old one survives.
              child: KeyedSubtree(
                key: ValueKey('${feeder.feederId}-$_tab'),
                child: _page(_tab),
              ),
            ),
          ],
        ),
        bottomNavigationBar: PillNav(
          index: _tab,
          onTap: (i) => setState(() => _tab = i),
          onCenter: () => setState(() => _tab = FeederTab.feeding),
        ),
      ),
    );
  }

  Widget _page(int i) => switch (i) {
    FeederTab.home => HomeTab(
      onOpenFeeding: () => setState(() => _tab = FeederTab.feeding),
    ),
    FeederTab.feeding => const FeedingTab(),
    FeederTab.activity => const ActivityTab(),
    _ => SettingsTab(feeders: widget.feeders),
  };
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Panel(
        color: kBeige,
        child: Row(
          children: [
            Icon(icon, color: kSoil, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      ),
    );
  }
}
