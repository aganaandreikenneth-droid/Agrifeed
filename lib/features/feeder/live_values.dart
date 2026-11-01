import 'dart:async';

import 'package:flutter/material.dart';

import 'feeder_scope.dart';

/// One database read for [LiveValues].
class LiveQuery {
  const LiveQuery(this.sub, {this.orderBy, this.last});

  /// Path below `feeders/{id}/`.
  final String sub;
  final String? orderBy;
  final int? last;
}

/// Subscribes to [queries] of the current feeder and rebuilds with their
/// latest values (null until the first event). With [tick] it also rebuilds
/// on a timer, for "online" and countdowns.
class LiveValues extends StatefulWidget {
  const LiveValues({
    super.key,
    required this.queries,
    required this.builder,
    this.tick,
  });

  final Map<String, LiveQuery> queries;
  final Widget Function(BuildContext context, Map<String, Object?> v) builder;
  final Duration? tick;

  @override
  State<LiveValues> createState() => _LiveValuesState();
}

class _LiveValuesState extends State<LiveValues> {
  final _values = <String, Object?>{};
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _timer;
  String? _feederId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controls = FeederScope.of(context).controls;
    if (controls.feederId == _feederId) return;
    _feederId = controls.feederId;
    _cancel();
    _values.clear();
    widget.queries.forEach((key, q) {
      _subs.add(
        controls.live
            .watch(controls.path(q.sub), orderBy: q.orderBy, last: q.last)
            .listen(
              (v) {
                if (mounted) setState(() => _values[key] = v);
              },
              // A denied read (e.g. missing permission) shows as no data.
              onError: (_) {},
            ),
      );
    });
    final tick = widget.tick;
    if (tick != null) {
      _timer = Timer.periodic(tick, (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _cancel() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _timer?.cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _values);
}
