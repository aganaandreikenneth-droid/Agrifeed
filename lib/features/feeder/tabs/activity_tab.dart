import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/widgets/panel.dart';
import '../../../design.dart';
import '../../../services/feeder_live.dart';
import '../live_values.dart';
import 'tab_page.dart';

/// Activity: today's totals and every feeding outcome the controller
/// recorded in `history`, newest first.
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});

  @override
  Widget build(BuildContext context) {
    return FeederTabPage(
      title: 'Activity',
      subtitle: 'Feeding history reported by the controller',
      allowedIf: const ['viewHistory', 'viewAnalytics', 'downloadReports'],
      children: [
        LiveValues(
          queries: const {
            'history': LiveQuery('history', orderBy: 'ts', last: 100),
          },
          builder: (context, v) {
            if (!v.containsKey('history')) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final events = FeedEvent.listFrom(v['history']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Totals(events),
                const SectionTitle('History'),
                if (events.isEmpty)
                  const Panel(
                    key: ValueKey('history-empty'),
                    child: Text(
                      'Nothing recorded yet. Feedings appear here once the '
                      'controller reports them.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                else
                  Panel(
                    child: Column(
                      children: [
                        for (var i = 0; i < events.length; i++) ...[
                          if (i > 0) const Divider(height: 1, color: kBeige),
                          _EventRow(events[i]),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals(this.events);

  final List<FeedEvent> events;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final todays = events.where(
      (e) =>
          DateUtils.isSameDay(DateTime.fromMillisecondsSinceEpoch(e.ts), today),
    );
    final grams = todays
        .where((e) => e.delivered)
        .fold<double>(0, (a, e) => a + e.actualG);
    final week = gramsPerDay(events).fold<double>(0, (a, b) => a + b);
    Widget tile(String label, String value, Color bg) => Expanded(
      child: Panel(
        color: bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: kInk,
              ),
            ),
          ],
        ),
      ),
    );
    return Row(
      key: const ValueKey('activity-totals'),
      children: [
        tile('Today', weightLabel(grams), kAmberSoft),
        const SizedBox(width: 10),
        tile('Feedings', '${todays.length}', kIndigoSoft),
        const SizedBox(width: 10),
        tile('7 days', weightLabel(week), Colors.white),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow(this.e);

  final FeedEvent e;

  @override
  Widget build(BuildContext context) {
    final ok = e.status == 'completed';
    final color = ok
        ? const Color(0xFF34B36B)
        : e.delivered
        ? kGrain
        : kRose;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          IconTile(
            e.method == 'scheduled' ? Icons.schedule_rounded : Icons.grain,
            color: e.method == 'scheduled' ? kIndigoSoft : kAmberSoft,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${e.method == 'scheduled' ? 'Scheduled' : 'Manual'} · '
                  '${weightLabel(e.actualG)} of ${weightLabel(e.requestedG)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: kInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${fmtTs(e.ts)}${e.simulated ? '  ·  simulated' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.black45),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              e.status,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
