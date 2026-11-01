import 'package:flutter/material.dart';

import '../../../core/timezones.dart';
import '../../../core/widgets/panel.dart';
import '../../../core/widgets/text_prompt.dart';
import '../../../services/feeder_repository.dart';
import '../../../services/feeder_selection.dart';
import '../../home/account_panel.dart';
import '../calibration_panel.dart';
import '../feeder_scope.dart';
import '../simulation_panel.dart';
import 'tab_page.dart';

/// Settings for the account's one feeder: profile and account, the feeder's
/// name and time zone (the `meta` fields the rules let the owner write), and
/// what later milestones add.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.feeders});

  final FeederRepository feeders;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _busy = false;

  void _say(ScaffoldMessengerState messenger, String text) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs one change at a time; a failure is reported, never hidden.
  Future<void> _run(Future<void> Function() change) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await change();
    } catch (_) {
      _say(
        messenger,
        'Could not save the change. Check the connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(FeederSummary f) async {
    final name = await showTextPrompt(
      context,
      title: 'Feeder name',
      label: 'Name',
      initial: f.name,
      maxLength: 40,
    );
    if (name == null || name == f.name || !mounted) return;
    if (name.isEmpty || name.length > 40) {
      _say(
        ScaffoldMessenger.of(context),
        'Enter a name of 1 to 40 characters.',
      );
      return;
    }
    await _run(() => widget.feeders.rename(f.feederId, name));
  }

  Future<void> _changeTimezone(FeederSummary f) async {
    final zones = [
      ...kFeederTimezones,
      if (!kFeederTimezones.contains(f.timezone)) f.timezone,
    ];
    final tz = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Time zone'),
        children: [
          for (final z in zones)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, z),
              child: Row(
                children: [
                  Expanded(child: Text(z)),
                  if (z == f.timezone)
                    const Icon(Icons.check_rounded, color: kSoil, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (tz == null || tz == f.timezone) return;
    await _run(() => widget.feeders.setTimezone(f.feederId, tz));
  }

  @override
  Widget build(BuildContext context) {
    final scope = FeederScope.of(context);
    final f = scope.feeder;
    final canEdit = f.isOwner && !f.archived && scope.online && !_busy;

    return FeederTabPage(
      title: 'Settings',
      subtitle: 'Your account and your feeder',
      children: [
        const SectionTitle('Profile and account'),
        const AccountPanel(),
        const SectionTitle('Feeder'),
        Panel(
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SettingRow(
                  key: const ValueKey('setting-name'),
                  icon: Icons.badge_outlined,
                  label: 'Name',
                  value: f.name,
                  onEdit: canEdit ? () => _rename(f) : null,
                ),
                _SettingRow(
                  key: const ValueKey('setting-timezone'),
                  icon: Icons.public_rounded,
                  label: 'Time zone',
                  value: f.timezone,
                  onEdit: canEdit ? () => _changeTimezone(f) : null,
                ),
                _SettingRow(
                  key: const ValueKey('setting-controller'),
                  icon: Icons.memory_rounded,
                  label: 'Controller',
                  value: f.isVirtual
                      ? 'Simulator (development). Readings are simulated.'
                      : 'AgriFeed controller (ESP32)',
                ),
                _SettingRow(
                  icon: Icons.tag_rounded,
                  label: 'Feeder ID',
                  value: f.feederId,
                ),
                if (!f.isOwner)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Only the owner can change this feeder.'),
                  ),
              ],
            ),
          ),
        ),
        if (!f.isVirtual && f.isOwner) ...[
          const SectionTitle('Scale calibration'),
          const CalibrationPanel(),
        ],
        if (f.isVirtual && f.isOwner) ...[
          const SectionTitle('Simulation'),
          const SimulationPanel(),
        ],
        const SectionTitle('Coming next'),
        const PlannedPanel(
          icon: Icons.inventory_2_outlined,
          title: 'Hopper capacity and low-feed threshold',
          milestone: 3,
          body:
              'Usable hopper capacity (provisional until the real machine is '
              'weighed and calibrated) and the low-feed warning level, set '
              'together with live weight monitoring.',
        ),
        const PlannedPanel(
          icon: Icons.notifications_outlined,
          title: 'Notification preferences',
          milestone: 5,
          body: 'Choose which alerts you receive.',
        ),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onEdit,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: IconTile(icon),
      title: Text(
        label,
        style: const TextStyle(color: Colors.black54, fontSize: 13),
      ),
      subtitle: Text(
        value,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: kSoil,
        ),
      ),
      trailing: onEdit == null
          ? null
          : IconButton(
              tooltip: 'Edit feeder ${label.toLowerCase()}',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
    );
  }
}
