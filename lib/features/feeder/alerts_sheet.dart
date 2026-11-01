import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_repository.dart';
import 'feeder_badge.dart';

/// App bar bell: the number of active alerts of the selected feeder, and a
/// sheet listing its alerts. Alerts come from `feeders/{id}/alerts`, which
/// only the feeder's device (or the simulator) writes.
class AlertsBell extends StatefulWidget {
  const AlertsBell({
    super.key,
    required this.feederId,
    required this.feederName,
    required this.feeders,
  });

  final String feederId;
  final String feederName;
  final FeederRepository feeders;

  @override
  State<AlertsBell> createState() => _AlertsBellState();
}

class _AlertsBellState extends State<AlertsBell> {
  StreamSubscription<List<FeederAlert>>? _sub;
  List<FeederAlert>? _alerts;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.feeders
        .watchAlerts(widget.feederId)
        .listen(
          (a) => setState(() {
            _alerts = a;
            _failed = false;
          }),
          onError: (Object _) => setState(() => _failed = true),
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  int get _active => _alerts?.where((a) => a.active).length ?? 0;

  void _open() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AlertsSheet(
        feederName: widget.feederName,
        stream: widget.feeders.watchAlerts(widget.feederId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _active;
    return Badge(
      key: const ValueKey('alerts-bell'),
      isLabelVisible: !_failed && n > 0,
      label: Text('$n'),
      backgroundColor: kGrain,
      offset: const Offset(-6, 6),
      child: IconBox(
        icon: n > 0
            ? Icons.notifications_active_outlined
            : Icons.notifications_none_rounded,
        onTap: _open,
      ),
    );
  }
}

class _AlertsSheet extends StatelessWidget {
  const _AlertsSheet({required this.feederName, required this.stream});

  final String feederName;
  final Stream<List<FeederAlert>> stream;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Alerts · $feederName',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: StreamBuilder<List<FeederAlert>>(
                  stream: stream,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const Panel(
                        child: Text(
                          'Alerts could not be loaded. Check the connection.',
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Panel(
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final alerts = snap.data!;
                    if (alerts.isEmpty) {
                      return const Panel(
                        key: ValueKey('alerts-empty'),
                        child: Text(
                          'No alerts. Low-feed, blockage and feeding-failure '
                          'alerts from this feeder will appear here.',
                        ),
                      );
                    }
                    return Panel(
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [for (final a in alerts) _AlertTile(a)],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile(this.alert);

  final FeederAlert alert;

  @override
  Widget build(BuildContext context) {
    final a = alert;
    final critical = a.severity == 'critical';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        a.active
            ? (critical ? Icons.error_outline : Icons.warning_amber_rounded)
            : Icons.check_circle_outline,
        color: a.active
            ? (critical ? Colors.red : Colors.orange)
            : Colors.black38,
      ),
      title: Row(
        children: [
          Flexible(child: Text(alertTitle(a))),
          if (a.simulated) ...[
            const SizedBox(width: 6),
            const FeederBadge('SIMULATED'),
          ],
        ],
      ),
      subtitle: Text(
        '${a.active ? 'Active' : 'Resolved'} · '
        '${a.lastAt > 0 ? ago(a.lastAt) : 'time unknown'}',
      ),
    );
  }
}
