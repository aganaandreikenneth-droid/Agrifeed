import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_selection.dart';
import '../home/account_panel.dart';
import 'feeder_scope.dart';
import 'feeder_switcher.dart';

/// Shown when the centre feed button is pressed (owner decision (d)).
const kManualFeedDisabledMessage =
    'Manual feeding will be enabled in Phase 5. No feeding command was sent.';

/// The selected feeder: app bar switcher, status banners, the four feeder
/// tabs and the original PillNav from design.dart.
///
/// Phase 2B: the tabs are wired to the selected feeder and its permissions;
/// their content (the original Dashboard, Schedule, History and Settings
/// screens) is reconnected in 2D. Until then they show what is coming,
/// never placeholder numbers.
class FeederShell extends StatefulWidget {
  const FeederShell({
    super.key,
    required this.selection,
    required this.onCreate,
  });

  final FeederSelectionController selection;
  final VoidCallback onCreate;

  @override
  State<FeederShell> createState() => _FeederShellState();
}

class _FeederShellState extends State<FeederShell> {
  int _tab = 0;

  static const _titles = [
    'Dashboard',
    'Feeding schedule',
    'History',
    'Settings',
  ];

  void _manualFeed() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(kManualFeedDisabledMessage)));
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final feeder = selection.selected!;
    return FeederScope(
      feeder: feeder,
      online: selection.online,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: const IconBox(icon: Icons.egg_alt_outlined),
          title: FeederSwitcherTitle(
            selected: feeder,
            feeders: selection.feeders,
            onSelect: selection.select,
            onCreate: widget.onCreate,
          ),
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
              // Keyed by feeder: switching feeders rebuilds the page from
              // scratch, so no listener of the previous feeder survives.
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
          onCenter: _manualFeed,
        ),
      ),
    );
  }

  Widget _page(int i) => switch (i) {
    0 => _TabPage(
      title: _titles[0],
      allowedIf: const ['viewDashboard'],
      body:
          'The live dashboard (hopper level, connection status, recent '
          'feedings) is reconnected to this feeder in milestone 2D.',
    ),
    1 => _TabPage(
      title: _titles[1],
      allowedIf: const ['viewDashboard', 'manageSchedules'],
      body:
          'Daily feeding schedules (add, edit, delete, enable or disable) '
          'return for this feeder in milestone 2D.',
    ),
    2 => _TabPage(
      title: _titles[2],
      allowedIf: const ['viewHistory', 'viewAnalytics'],
      body: 'Feeding history for this feeder returns in milestone 2D.',
    ),
    _ => const _SettingsPage(),
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

/// A feeder tab gated by permission: shown when the user holds at least one
/// of [allowedIf] (owners hold all), otherwise an explanation.
class _TabPage extends StatelessWidget {
  const _TabPage({
    required this.title,
    required this.allowedIf,
    required this.body,
  });

  final String title;
  final List<String> allowedIf;
  final String body;

  @override
  Widget build(BuildContext context) {
    final feeder = FeederScope.of(context).feeder;
    final allowed = allowedIf.any(feeder.can);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              if (allowed)
                Text(body)
              else
                Text(
                  "You don't have permission to view this for ${feeder.name}. "
                  'Ask the feeder owner if you need access.',
                  key: const ValueKey('no-permission'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

const _permissionLabels = {
  'viewDashboard': 'View dashboard',
  'viewHistory': 'View history',
  'viewAnalytics': 'View analytics',
  'manualFeed': 'Manual feeding',
  'manageSchedules': 'Manage schedules',
  'downloadReports': 'Download reports',
  'receiveAlerts': 'Receive alerts',
};

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    final f = FeederScope.of(context).feeder;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      f.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final b in feederBadges(f)) ...[
                    const SizedBox(width: 6),
                    b,
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${f.isOwner ? 'Owner' : 'Authorized member'} · '
                '${f.isVirtual ? 'Virtual (simulated) feeder' : 'Physical feeder'}',
              ),
              const SizedBox(height: 12),
              const Text(
                'Your access',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              for (final p in kFeederPermissions)
                Row(
                  children: [
                    Icon(
                      f.can(p)
                          ? Icons.check_circle
                          : Icons.remove_circle_outline,
                      size: 18,
                      color: f.can(p) ? kGrain : Colors.black26,
                    ),
                    const SizedBox(width: 8),
                    Text(_permissionLabels[p] ?? p),
                  ],
                ),
              const SizedBox(height: 12),
              Text(
                'Feeder settings and member management arrive in milestones '
                '2C and 2D.',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const AccountPanel(),
      ],
    );
  }
}
