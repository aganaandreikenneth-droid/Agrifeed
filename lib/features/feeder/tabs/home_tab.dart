import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_scope.dart';
import '../../../core/format.dart';
import '../../../core/widgets/panel.dart';
import '../../../design.dart';
import '../../../services/feeder_live.dart';
import '../feeder_scope.dart';
import '../live_values.dart';
import 'tab_page.dart';

const _kDays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// Home: greeting, a week strip, the hopper gauge, next and last feeding and
/// the last seven days of delivered feed. Every number comes from what the
/// controller (or simulator) reported; nothing is shown before it has.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, this.onOpenFeeding});

  /// Switches to the Feeding tab. Home itself sends nothing.
  final VoidCallback? onOpenFeeding;

  @override
  Widget build(BuildContext context) {
    return FeederTabPage(
      title: 'Home',
      header: const _Greeting(),
      allowedIf: const ['viewDashboard'],
      children: [
        LiveValues(
          queries: const {
            'status': LiveQuery('status'),
            'telemetry': LiveQuery('telemetry/current'),
            'config': LiveQuery('config'),
            'schedules': LiveQuery('schedules'),
            'history': LiveQuery('history', orderBy: 'ts', last: 200),
          },
          // Re-evaluates "online" and the next feeding without new data.
          tick: const Duration(seconds: 5),
          builder: (context, v) => _Dashboard(
            reading: FeederReading.from(
              status: v['status'],
              telemetry: v['telemetry'],
              config: v['config'],
            ),
            schedules: FeedSchedule.listFrom(v['schedules']),
            // Null when history is not readable (no permission) or not loaded.
            events: v['history'] == null && !v.containsKey('history')
                ? null
                : FeedEvent.listFrom(v['history']),
            onOpenFeeding: onOpenFeeding,
          ),
        ),
      ],
    );
  }
}

/// "Good morning, Ana" and today's date.
class _Greeting extends StatelessWidget {
  const _Greeting();

  static String _salutation(int hour) => hour < 12
      ? 'Good morning'
      : hour < 18
      ? 'Good afternoon'
      : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final s = AppScope.maybeOf(context); // absent in widget tests
    final uid = FeederScope.of(context).controls.uid;
    Widget text(String? name) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_kDays[scheduleWeekday(now)]}, ${_month(now.month)} ${now.day}',
            style: const TextStyle(color: Colors.black45, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            name == null || name.isEmpty
                ? '${_salutation(now.hour)}!'
                : '${_salutation(now.hour)}, ${name.split(' ').first}!',
            key: const ValueKey('home-greeting'),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: kInk,
            ),
          ),
        ],
      ),
    );
    if (s == null) return text(null);
    return StreamBuilder<String?>(
      stream: s.profiles.watchDisplayName(uid),
      builder: (context, snap) =>
          text(snap.data ?? s.auth.currentUser?.displayName),
    );
  }
}

String _month(int m) => const [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
][m - 1];

class _Dashboard extends StatefulWidget {
  const _Dashboard({
    required this.reading,
    required this.schedules,
    required this.events,
    this.onOpenFeeding,
  });

  final FeederReading reading;
  final List<FeedSchedule> schedules;
  final List<FeedEvent>? events;
  final VoidCallback? onOpenFeeding;

  @override
  State<_Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<_Dashboard> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final r = widget.reading;
    final events = widget.events;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WeekStrip(selected: _day, onSelect: (d) => setState(() => _day = d)),
        const SizedBox(height: 12),
        _DayPanel(day: _day, schedules: widget.schedules, events: events),
        const SizedBox(height: 12),
        if (r.condition == 'jam') ...[
          const _Notice(
            key: ValueKey('home-jam'),
            icon: Icons.warning_amber_rounded,
            color: kRoseSoft,
            iconColor: kRose,
            text: 'The controller reports a feed jam. Check the outlet.',
          ),
          const SizedBox(height: 12),
        ],
        if (r.low) ...[
          _Notice(
            key: const ValueKey('home-low-feed'),
            icon: Icons.inventory_2_outlined,
            color: kAmberSoft,
            iconColor: kGrain,
            text:
                'Low feed: ${weightLabel(r.shownWeightG!)} left '
                '(alert at ${r.lowThresholdG.round()} g). Refill the hopper.',
          ),
          const SizedBox(height: 12),
        ],
        _HopperCard(reading: r),
        const SizedBox(height: 12),
        _RtcClock(reading: r),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _NextFeeding(widget.schedules, r.schedulesPaused),
              ),
              const SizedBox(width: 12),
              Expanded(child: _LastFeeding(events)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _WeekChart(events),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('home-open-feeding'),
          onPressed: widget.onOpenFeeding,
          style: FilledButton.styleFrom(
            backgroundColor: kAmber,
            foregroundColor: kInk,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text(
            'Go to Feeding',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// The current week, Sunday first; today and the selected day stand out.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.selected, required this.onSelect});

  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final sunday = today.subtract(Duration(days: scheduleWeekday(today)));
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final d = DateUtils.addDaysToDate(sunday, i);
                final on = DateUtils.isSameDay(d, selected);
                final isToday = DateUtils.isSameDay(d, today);
                return GestureDetector(
                  key: ValueKey('day-$i'),
                  onTap: () => onSelect(d),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: on ? kAmber : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: isToday && !on
                          ? Border.all(color: kAmber, width: 1.5)
                          : null,
                    ),
                    child: Column(
                      children: [
                        Text(
                          _kDays[i],
                          style: TextStyle(
                            fontSize: 12,
                            color: on ? kInk : Colors.black45,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${d.day}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: kInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// What the schedules plan for [day] and, up to today, what was delivered.
class _DayPanel extends StatelessWidget {
  const _DayPanel({
    required this.day,
    required this.schedules,
    required this.events,
  });

  final DateTime day;
  final List<FeedSchedule> schedules;
  final List<FeedEvent>? events;

  @override
  Widget build(BuildContext context) {
    final planned = [
      for (final s in schedules)
        if (s.enabled && s.runsOn(scheduleWeekday(day))) s,
    ];
    final today = DateUtils.dateOnly(DateTime.now());
    final future = day.isAfter(today);
    final delivered = events
        ?.where(
          (e) =>
              e.delivered &&
              DateUtils.isSameDay(
                DateTime.fromMillisecondsSinceEpoch(e.ts),
                day,
              ),
        )
        .fold<double>(0, (sum, e) => sum + e.actualG);
    return Panel(
      key: const ValueKey('home-day'),
      child: Row(
        children: [
          Expanded(
            child: _Stat(
              label: 'Scheduled',
              value: planned.isEmpty
                  ? 'None'
                  : '${planned.length} × '
                        '${weightLabel(planned.fold(0.0, (a, s) => a + s.amountG))}',
              sub: planned.isEmpty
                  ? 'No feeding time set'
                  : planned.map((s) => s.time).join(' · '),
            ),
          ),
          Container(width: 1, height: 40, color: kBeige),
          const SizedBox(width: 14),
          Expanded(
            child: _Stat(
              label: 'Delivered',
              value: future
                  ? '--'
                  : delivered == null
                  ? '--'
                  : weightLabel(delivered),
              sub: future
                  ? 'Not yet'
                  : delivered == null
                  ? 'History not available'
                  : 'Reported by the controller',
            ),
          ),
        ],
      ),
    );
  }
}

/// The controller's RTC date and time (`status/rtcTime`). The reading
/// arrives with each heartbeat; between heartbeats the clock counts on from
/// it, and it stops counting while the controller is offline.
class _RtcClock extends StatefulWidget {
  const _RtcClock({required this.reading});

  final FeederReading reading;

  @override
  State<_RtcClock> createState() => _RtcClockState();
}

class _RtcClockState extends State<_RtcClock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reading;
    final timezone = FeederScope.of(context).feeder.timezone;
    final rtc = r.rtcTime == null ? null : DateTime.tryParse(r.rtcTime!);
    final online = r.online();
    DateTime? shown;
    if (rtc != null) {
      // Count on from the reading; the status write stamped lastSeen.
      final since = r.lastSeen == null || !online
          ? 0
          : (DateTime.now().millisecondsSinceEpoch - r.lastSeen!).clamp(
              0,
              kOfflineAfter.inMilliseconds,
            );
      shown = rtc.add(Duration(milliseconds: since));
    }
    String two(int v) => v.toString().padLeft(2, '0');
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return Panel(
      key: const ValueKey('home-rtc'),
      child: Row(
        children: [
          const Icon(Icons.access_time_rounded, color: kGrain, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Feeder clock (RTC)',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const SizedBox(height: 4),
                if (shown == null)
                  const Text(
                    'No RTC reading yet',
                    key: ValueKey('home-rtc-time'),
                    style: TextStyle(color: Colors.black54),
                  )
                else ...[
                  Text(
                    '${two(shown.hour)}:${two(shown.minute)}:${two(shown.second)}',
                    key: const ValueKey('home-rtc-time'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: kInk,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    '${_kDays[shown.weekday % 7]}, ${shown.day} '
                    '${months[shown.month - 1]} ${shown.year} · $timezone',
                    key: const ValueKey('home-rtc-date'),
                    style: const TextStyle(color: Colors.black54),
                  ),
                  if (!online)
                    const Text(
                      'Last reported time; the feeder is offline.',
                      style: TextStyle(color: Colors.black45, fontSize: 12),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hopper level as reported, on the segmented gauge.
class _HopperCard extends StatelessWidget {
  const _HopperCard({required this.reading});

  final FeederReading reading;

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final online = r.online();
    final w = r.shownWeightG; // never negative
    return Panel(
      key: const ValueKey('home-hopper'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Hopper',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const Spacer(),
              _Dot(online: online),
              const SizedBox(width: 6),
              Text(
                online
                    ? 'Online'
                    : r.lastSeen == null
                    ? 'Never connected'
                    : 'Offline · ${ago(r.lastSeen!)}',
                key: const ValueKey('home-connection'),
                style: const TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: SegmentGauge(
                fraction: (r.fraction ?? 0).clamp(0.0, 1.0),
                color: r.low ? kRose : kAmber,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      w == null ? '--' : weightLabel(w),
                      key: const ValueKey('home-weight'),
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        color: kInk,
                      ),
                    ),
                    Text(
                      w == null
                          ? 'No reading yet'
                          : '${((r.fraction ?? 0) * 100).round()}% of '
                                '${weightLabel(r.capacityG)}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    if (r.measuredAt != null)
                      Text(
                        'Measured ${ago(r.measuredAt!)}',
                        style: const TextStyle(
                          color: Colors.black38,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The next enabled schedule from now, in the next seven days.
class _NextFeeding extends StatelessWidget {
  const _NextFeeding(this.schedules, this.paused);

  final List<FeedSchedule> schedules;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    String? when;
    FeedSchedule? next;
    for (var d = 0; d < 7 && next == null; d++) {
      final day = DateUtils.addDaysToDate(DateUtils.dateOnly(now), d);
      for (final s in schedules) {
        if (!s.enabled || !s.runsOn(scheduleWeekday(day))) continue;
        if (d == 0 && s.minutes <= nowMin) continue;
        next = s;
        when = d == 0
            ? 'Today'
            : d == 1
            ? 'Tomorrow'
            : _kDays[scheduleWeekday(day)];
        break;
      }
    }
    return Panel(
      key: const ValueKey('home-next'),
      child: _Stat(
        icon: Icons.schedule_rounded,
        label: 'Next feeding',
        value: paused
            ? 'Paused'
            : next == null
            ? 'None'
            : '$when ${next.time}',
        sub: paused
            ? 'Schedules are paused'
            : next == null
            ? 'No schedule set'
            : weightLabel(next.amountG),
      ),
    );
  }
}

/// The most recent feeding outcome from history.
class _LastFeeding extends StatelessWidget {
  const _LastFeeding(this.events);

  final List<FeedEvent>? events;

  @override
  Widget build(BuildContext context) {
    final e = (events == null || events!.isEmpty) ? null : events!.first;
    return Panel(
      key: const ValueKey('home-last'),
      child: _Stat(
        icon: Icons.check_circle_outline_rounded,
        label: 'Last feeding',
        value: e == null ? 'None yet' : weightLabel(e.actualG),
        sub: e == null
            ? (events == null ? 'History not available' : 'Nothing recorded')
            : '${e.status} · ${e.method} · ${ago(e.ts)}',
      ),
    );
  }
}

/// Feed delivered per day for the last seven days, as bar meters.
class _WeekChart extends StatelessWidget {
  const _WeekChart(this.events);

  final List<FeedEvent>? events;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final grams = events == null ? null : gramsPerDay(events!);
    final total = grams?.fold<double>(0, (a, b) => a + b) ?? 0;
    final peak = grams == null
        ? 1.0
        : grams.fold<double>(0, (a, b) => a > b ? a : b);
    return Panel(
      key: const ValueKey('home-week'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Last 7 days',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const Spacer(),
              Text(
                grams == null ? '--' : '${weightLabel(total)} delivered',
                style: const TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (grams == null || total == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  grams == null
                      ? 'Feeding history is not available.'
                      : 'No feed delivered in the last 7 days.',
                  style: const TextStyle(color: Colors.black45),
                ),
              ),
            )
          else
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            grams[i] == 0 ? '' : '${grams[i].round()}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black45,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: BarMeter(
                              width: 22,
                              fraction: peak <= 0 ? 0 : grams[i] / peak,
                              color: i == 6 ? kAmber : kIndigo,
                              track: kBeige,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _kDays[scheduleWeekday(
                              DateUtils.addDaysToDate(today, i - 6),
                            )],
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.sub,
    this.icon,
  });

  final String label;
  final String value;
  final String sub;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: kAmberSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: kGrain, size: 20),
          ),
          const SizedBox(height: 10),
        ],
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 17,
            color: kInk,
          ),
        ),
        const SizedBox(height: 2),
        Text(sub, style: const TextStyle(color: Colors.black45, fontSize: 12)),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Panel(
      color: color,
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: online ? const Color(0xFF34B36B) : Colors.black26,
      shape: BoxShape.circle,
    ),
  );
}
