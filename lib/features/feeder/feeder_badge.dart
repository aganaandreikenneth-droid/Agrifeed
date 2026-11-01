import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../services/feeder_selection.dart';

/// Small rounded label, e.g. SIMULATION or ARCHIVED.
class FeederBadge extends StatelessWidget {
  const FeederBadge(this.label, {super.key, this.color = kGrain});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// SIMULATION whenever the simulator (not a real controller) provides the
/// feeder's data, so simulated readings are never mistaken for real ones.
List<Widget> feederBadges(FeederSummary f) => [
  if (f.isVirtual) const FeederBadge('SIMULATION'),
  if (f.archived) const FeederBadge('ARCHIVED', color: Colors.black54),
];

/// App bar title: the feeder's name and its badges.
class FeederTitle extends StatelessWidget {
  const FeederTitle(this.feeder, {super.key});

  final FeederSummary feeder;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            feeder.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        for (final b in feederBadges(feeder)) ...[const SizedBox(width: 6), b],
      ],
    );
  }
}
