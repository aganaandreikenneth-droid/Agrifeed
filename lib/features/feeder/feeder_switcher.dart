import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_selection.dart';

/// Small rounded label, e.g. VIRTUAL or ARCHIVED.
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

/// The badges every feeder carries wherever it is shown: simulated feeders
/// are always marked VIRTUAL, so simulated data is never mistaken for real.
List<Widget> feederBadges(FeederSummary f) => [
  if (f.isVirtual) const FeederBadge('VIRTUAL'),
  if (f.archived) const FeederBadge('ARCHIVED', color: Colors.black54),
];

/// App bar title: the selected feeder's name and badges. Tapping it opens
/// the feeder list (switch feeder, or create a virtual one).
class FeederSwitcherTitle extends StatelessWidget {
  const FeederSwitcherTitle({
    super.key,
    required this.selected,
    required this.feeders,
    required this.onSelect,
    required this.onCreate,
  });

  final FeederSummary selected;
  final List<FeederSummary> feeders;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('feeder-switcher'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => showFeederSheet(
        context,
        feeders: feeders,
        selectedId: selected.feederId,
        onSelect: onSelect,
        onCreate: onCreate,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                selected.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            for (final b in feederBadges(selected)) ...[
              const SizedBox(width: 6),
              b,
            ],
            Icon(
              Icons.expand_more_rounded,
              size: 20,
              color: feeders.length > 1 ? kSoil : Colors.black26,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showFeederSheet(
  BuildContext context, {
  required List<FeederSummary> feeders,
  required String? selectedId,
  required ValueChanged<String> onSelect,
  required VoidCallback onCreate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBg,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your feeders',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FeederList(
                feeders: feeders,
                selectedId: selectedId,
                onSelect: (id) {
                  Navigator.pop(sheet);
                  onSelect(id);
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(sheet);
                onCreate();
              },
              icon: const Icon(Icons.add),
              label: const Text('Create virtual feeder'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Tappable feeder rows (used by the switcher sheet and the chooser).
class FeederList extends StatelessWidget {
  const FeederList({
    super.key,
    required this.feeders,
    required this.onSelect,
    this.selectedId,
  });

  final List<FeederSummary> feeders;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Panel(
      // Transparent Material so the row ripples paint above the white panel.
      child: Material(
        type: MaterialType.transparency,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final f in feeders)
              ListTile(
                key: ValueKey('feeder-${f.feederId}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  f.isVirtual ? Icons.science_outlined : Icons.memory,
                  color: kGrain,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(f.name, overflow: TextOverflow.ellipsis),
                    ),
                    for (final b in feederBadges(f)) ...[
                      const SizedBox(width: 6),
                      b,
                    ],
                  ],
                ),
                subtitle: Text(f.isOwner ? 'Owner' : 'Member'),
                trailing: f.feederId == selectedId
                    ? const Icon(Icons.check_rounded, color: kSoil)
                    : null,
                onTap: () => onSelect(f.feederId),
              ),
          ],
        ),
      ),
    );
  }
}
