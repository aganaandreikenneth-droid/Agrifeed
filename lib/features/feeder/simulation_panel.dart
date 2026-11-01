import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import 'feeder_scope.dart';
import 'live_values.dart';
import 'tabs/tab_page.dart';

/// Development controls for a simulated feeder (`simulator/controls`, owner
/// only, rejected by the rules for real feeders). The simulator picks them up
/// and reports the consequences like a real controller would.
class SimulationPanel extends StatelessWidget {
  const SimulationPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final controls = FeederScope.of(context).controls;
    final enabled = FeederScope.of(context).online;

    Future<void> set(BuildContext context, Map<String, Object?> values) async {
      try {
        await controls.live.update({
          for (final e in values.entries)
            controls.path('simulator/controls/${e.key}'): e.value,
          controls.path('simulator/controls/updatedAt'): controls.live.now,
        });
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('The simulator control was refused.')),
          );
        }
      }
    }

    return LiveValues(
      queries: const {
        'sim': LiveQuery('simulator/controls'),
        'config': LiveQuery('config'),
      },
      builder: (context, v) {
        final sim = toMap(v['sim']);
        final capacity =
            (toMap(v['config'])['capacityG'] as num?)?.toDouble() ?? 2500;
        final connected = sim['connected'] != false;
        final jam = sim['jam'] == true;
        return Panel(
          key: const ValueKey('simulation-panel'),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    IconTile(Icons.science_outlined),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'These change the simulated machine only. Run '
                        '"npm run simulator" on the PC to drive it.',
                        style: TextStyle(color: Colors.black54, fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      key: const ValueKey('sim-refill'),
                      avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                      label: Text('Refill to ${weightLabel(capacity)}'),
                      backgroundColor: kAmberSoft,
                      side: BorderSide.none,
                      onPressed: enabled
                          ? () => set(context, {
                              'hopperWeightG': capacity.round(),
                            })
                          : null,
                    ),
                    ActionChip(
                      key: const ValueKey('sim-low'),
                      avatar: const Icon(Icons.trending_down_rounded, size: 18),
                      label: const Text('Set to 400 g (low)'),
                      backgroundColor: kRoseSoft,
                      side: BorderSide.none,
                      onPressed: enabled
                          ? () => set(context, {'hopperWeightG': 400})
                          : null,
                    ),
                  ],
                ),
                SwitchListTile(
                  key: const ValueKey('sim-connected'),
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: kAmber,
                  title: const Text('Controller connected'),
                  subtitle: const Text('Off: the simulator stops reporting'),
                  value: connected,
                  onChanged: enabled
                      ? (on) => set(context, {'connected': on})
                      : null,
                ),
                SwitchListTile(
                  key: const ValueKey('sim-jam'),
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: kAmber,
                  title: const Text('Feed jam'),
                  subtitle: const Text('On: dispensing fails'),
                  value: jam,
                  onChanged: enabled ? (on) => set(context, {'jam': on}) : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
