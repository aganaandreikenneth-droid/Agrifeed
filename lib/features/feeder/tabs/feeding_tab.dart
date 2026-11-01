import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/widgets/panel.dart';
import '../../../design.dart';
import '../../../services/feeder_live.dart';
import '../feeder_scope.dart';
import '../live_values.dart';
import 'tab_page.dart';

/// The app shows "No response" when a gate request is not acknowledged
/// within this time; the controller rejects older requests anyway.
const kGateAckTimeout = Duration(seconds: 10);

/// OPEN keeps the gate open until CLOSE (the controller ignores the
/// duration). durationS is still sent because the database rules require a
/// value of 1-15; kGateMaxS is that upper bound.
const kGateMaxS = 15;

const _kWeekdayLetters = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

/// Feeding: Gate Control, Manual Feeding and Automatic Feeding on one
/// screen. The app only writes requests; every state shown here is what the
/// controller (or the simulator) reported back.
class FeedingTab extends StatelessWidget {
  const FeedingTab({super.key});

  @override
  Widget build(BuildContext context) {
    return FeederTabPage(
      title: 'Feeding',
      subtitle: 'Gate, manual feeding and feeding times',
      allowedIf: const ['viewDashboard', 'manageSchedules', 'manualFeed'],
      children: [
        LiveValues(
          queries: const {
            'status': LiveQuery('status'),
            'telemetry': LiveQuery('telemetry/current'),
            'config': LiveQuery('config'),
            'gate': LiveQuery('gate/state'),
            'active': LiveQuery('activeCommand'),
            'commands': LiveQuery('commands', orderBy: 'requestedAt', last: 1),
            'schedules': LiveQuery('schedules'),
          },
          // Countdowns, "No response" and the online check.
          tick: const Duration(seconds: 1),
          builder: (context, v) {
            final reading = FeederReading.from(
              status: v['status'],
              telemetry: v['telemetry'],
              config: v['config'],
            );
            final last = toMap(v['commands']).entries.toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _GateSection(
                  report: GateReport.from(v['gate']),
                  controllerOnline: reading.online(),
                ),
                _ManualSection(
                  reading: reading,
                  locked: v['active'] != null,
                  command: last.isEmpty
                      ? null
                      : FeedCommand.from(last.first.key, last.first.value),
                ),
                _ScheduleSection(
                  schedules: FeedSchedule.listFrom(v['schedules']),
                  reading: reading,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Tall, fully rounded buttons as in the reference design.
ButtonStyle _pill(ButtonStyle base) => base.merge(
  ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size.fromHeight(50)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
    ),
  ),
);

void _say(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Why the controls of a section are disabled, or null when they work.
String? _blocked(
  BuildContext context,
  String permission,
  bool controllerOnline,
) {
  final scope = FeederScope.of(context);
  if (!scope.feeder.can(permission)) {
    return 'You do not have permission for this.';
  }
  if (scope.feeder.archived) return 'The feeder is archived.';
  if (!scope.online) return 'You are offline.';
  if (!controllerOnline) {
    return 'The controller is offline, so nothing can be sent.';
  }
  return null;
}

/// One Feeding section: heading, what it does and its controls. [dark]
/// draws the highlighted charcoal card.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.children,
    this.dark = false,
    this.trailing,
    this.note,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> children;
  final bool dark;
  final Widget? trailing;

  /// Small print under the controls, e.g. why they are disabled.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ink = dark ? Colors.white : kInk;
    final soft = dark ? Colors.white60 : Colors.black54;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Panel(
        color: dark ? kInk : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon, color: dark ? kAmber : kAmberSoft),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: ink,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: TextStyle(color: soft, fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 14),
            ...children,
            if (note != null) ...[
              const SizedBox(height: 10),
              Text(
                note!,
                key: ValueKey('note-$title'),
                style: TextStyle(
                  color: dark ? Colors.white38 : Colors.black38,
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// --- gate ----------------------------------------------------------------------

class _GateSection extends StatefulWidget {
  const _GateSection({required this.report, required this.controllerOnline});

  final GateReport report;
  final bool controllerOnline;

  @override
  State<_GateSection> createState() => _GateSectionState();
}

class _GateSectionState extends State<_GateSection> {
  String? _sentId;
  String? _sentAction;
  DateTime? _sentAt;
  bool _sending = false;

  /// True while a request of ours has not been acknowledged.
  bool get _waiting =>
      _sentId != null && widget.report.lastRequestId != _sentId;

  bool get _noResponse =>
      _waiting && DateTime.now().difference(_sentAt!) > kGateAckTimeout;

  Future<void> _send(String action) async {
    final controls = FeederScope.of(context).controls;
    setState(() => _sending = true);
    try {
      final id = await controls.gate(action, durationS: kGateMaxS);
      setState(() {
        _sentId = id;
        _sentAction = action;
        _sentAt = DateTime.now();
      });
    } catch (_) {
      if (mounted) _say(context, 'The gate request could not be sent.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final blocked = _blocked(context, 'manualFeed', widget.controllerOnline);
    final open = r.position == 'open';
    // CLOSE has priority: it can always be sent, even while waiting.
    final canOpen =
        blocked == null && !_sending && !open && !(_waiting && !_noResponse);
    final canClose = blocked == null && !_sending;

    final ours = _sentId != null && r.lastRequestId == _sentId;
    final String headline;
    final String detail;
    final IconData icon;
    if (_noResponse) {
      icon = Icons.portable_wifi_off_rounded;
      headline = 'No response';
      detail =
          'The controller did not acknowledge the ${_sentAction!.toUpperCase()} '
          'request within 10 s. Gate state is unknown; nothing was resent.';
    } else if (_waiting) {
      icon = Icons.hourglass_top_rounded;
      headline = 'Waiting for the controller...';
      detail = '${_sentAction!.toUpperCase()} request sent.';
    } else if (r.position == null) {
      icon = Icons.help_outline_rounded;
      headline = 'Gate: UNKNOWN';
      detail = 'No report from the controller yet.';
    } else if (ours && r.lastResult == 'rejected') {
      icon = Icons.block_rounded;
      headline = 'Request rejected';
      detail = r.reason ?? 'The controller rejected the request.';
    } else if (open) {
      icon = Icons.lock_open_rounded;
      headline = 'Gate: OPEN';
      detail = 'Stays open until you press CLOSE GATE. Controller-reported.';
    } else {
      icon = Icons.lock_rounded;
      headline = 'Gate: CLOSED';
      detail = 'Controller-reported, not physically verified.';
    }

    return _Section(
      key: const ValueKey('section-gate'),
      dark: true,
      icon: Icons.door_sliding_outlined,
      title: 'Gate Control',
      body:
          'OPEN GATE keeps the feeder outlet open until you press CLOSE GATE. '
          'For safety the controller also closes it if it loses the connection.',
      note: blocked,
      children: [
        Container(
          key: const ValueKey('gate-state'),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: open ? kAmber.withValues(alpha: 0.18) : Colors.white10,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: kAmber, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      key: const ValueKey('gate-headline'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('gate-open'),
                onPressed: canOpen ? () => _send('open') : null,
                style: _pill(
                  FilledButton.styleFrom(
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white38,
                  ),
                ),
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('OPEN GATE'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('gate-close'),
                onPressed: canClose ? () => _send('close') : null,
                style: _pill(
                  OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white38,
                    side: const BorderSide(color: Colors.white38),
                  ),
                ),
                icon: const Icon(Icons.lock_rounded),
                label: const Text('CLOSE GATE'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// --- manual feeding --------------------------------------------------------------

class _ManualSection extends StatefulWidget {
  const _ManualSection({
    required this.reading,
    required this.locked,
    required this.command,
  });

  final FeederReading reading;

  /// Another dispense holds the one-at-a-time lock.
  final bool locked;

  /// The most recent manual command, whoever sent it.
  final FeedCommand? command;

  @override
  State<_ManualSection> createState() => _ManualSectionState();
}

class _ManualSectionState extends State<_ManualSection> {
  double? _amount;
  bool _sending = false;

  List<double> _presets(double max) => [
    for (final g in const [25.0, 50.0, 100.0, 150.0, 200.0])
      if (g <= max) g,
  ];

  Future<void> _feed(double grams) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Feed now?'),
        content: Text(
          'Ask the feeder to dispense ${weightLabel(grams)}. The amount '
          'actually delivered is reported by the controller.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-feed'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Dispense'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Check again: the weight may have changed while the dialog was open.
    final problem = widget.reading.cannotDispense(grams);
    if (problem != null) {
      _say(context, problem);
      return;
    }
    final controls = FeederScope.of(context).controls;
    setState(() => _sending = true);
    try {
      await controls.feedNow(grams);
    } catch (_) {
      if (mounted) {
        _say(
          context,
          'The request was refused. Another feeding may be running.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reading;
    final c = widget.command;
    final presets = _presets(r.maxDispenseG);
    // Only amounts the verified hopper weight covers can be chosen.
    final available = r.availableG();
    bool fits(double g) =>
        available != null && available > kHopperEmptyG && g <= available;
    final allowed = presets.where(fits).toList();
    final preferred = _amount ?? (presets.contains(100.0) ? 100.0 : presets.last);
    // A choice that no longer fits moves to the largest amount that does.
    final amount = fits(preferred)
        ? preferred
        : (allowed.isNotEmpty ? allowed.last : preferred);
    final blocked = _blocked(context, 'manualFeed', r.online());
    // Hopper check: a recent, verified weight with enough feed for [amount].
    final feedProblem = blocked == null ? r.cannotDispense(amount) : null;
    final busy = widget.locked || (c != null && !c.finished);
    final stale =
        c != null &&
        c.status == 'pending' &&
        DateTime.now().millisecondsSinceEpoch - c.requestedAt >
            kCommandTtl.inMilliseconds;

    return _Section(
      key: const ValueKey('section-manual'),
      icon: Icons.grain,
      title: 'Manual Feeding',
      body:
          'Dispense a measured amount now, up to ${weightLabel(r.maxDispenseG)}.',
      note: blocked ?? (busy ? 'One feeding at a time.' : null),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final g in presets)
              ChoiceChip(
                key: ValueKey('preset-${g.round()}'),
                label: Text(weightLabel(g)),
                selected: g == amount && fits(g),
                selectedColor: kAmber,
                backgroundColor: kBg,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                // More than the hopper holds (or no verified weight): disabled.
                onSelected: fits(g) ? (_) => setState(() => _amount = g) : null,
              ),
          ],
        ),
        if (available != null &&
            allowed.isNotEmpty &&
            allowed.length < presets.length) ...[
          const SizedBox(height: 8),
          Text(
            'Amounts above ${weightLabel(available)} are disabled: not '
            'enough feed in the hopper.',
            key: const ValueKey('manual-limited'),
            style: const TextStyle(fontSize: 12, color: Colors.black45),
          ),
        ],
        const SizedBox(height: 12),
        if (r.shownWeightG != null) ...[
          Text(
            'In the hopper: ${weightLabel(r.shownWeightG!)}',
            key: const ValueKey('manual-hopper'),
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
          const SizedBox(height: 10),
        ],
        if (feedProblem != null) ...[
          Container(
            key: const ValueKey('manual-warning'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kRoseSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: kRose, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    feedProblem,
                    style: const TextStyle(fontSize: 13, color: kInk),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (c != null) ...[_CommandStatus(c), const SizedBox(height: 12)],
        SizedBox(
          width: double.infinity,
          child: stale
              ? OutlinedButton.icon(
                  key: const ValueKey('expire-command'),
                  onPressed: () =>
                      FeederScope.of(context).controls.expire(c.id),
                  style: _pill(OutlinedButton.styleFrom()),
                  icon: const Icon(Icons.timer_off_outlined),
                  label: const Text('Give up on this request'),
                )
              : FilledButton.icon(
                  key: const ValueKey('manual-feed'),
                  onPressed:
                      blocked == null &&
                          feedProblem == null &&
                          !busy &&
                          !_sending
                      ? () => _feed(amount)
                      : null,
                  style: _pill(FilledButton.styleFrom()),
                  icon: const Icon(Icons.grain),
                  label: Text('Feed ${weightLabel(amount)} now'),
                ),
        ),
      ],
    );
  }
}

/// Pending -> accepted -> dispensing -> completed / partial / failed, as the
/// controller reports it.
class _CommandStatus extends StatelessWidget {
  const _CommandStatus(this.c);

  final FeedCommand c;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, String text) = switch (c.status) {
      'pending' => (
        Icons.hourglass_top_rounded,
        kGrain,
        'Waiting for the feeder',
      ),
      'accepted' => (Icons.check_rounded, kGrain, 'Accepted by the feeder'),
      'dispensing' => (Icons.autorenew_rounded, kGrain, 'Dispensing...'),
      'completed' => (
        Icons.check_circle_rounded,
        const Color(0xFF34B36B),
        'Completed',
      ),
      'partial' => (Icons.error_outline_rounded, kGrain, 'Partly delivered'),
      'expired' => (Icons.timer_off_outlined, Colors.black45, 'Expired'),
      _ => (
        Icons.cancel_outlined,
        kRose,
        c.status == 'rejected' ? 'Rejected' : 'Failed',
      ),
    };
    final delivered = c.actualG == null
        ? ''
        : ' · ${weightLabel(c.actualG!)} of ${weightLabel(c.amountG)}';
    return Container(
      key: const ValueKey('command-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.finished
                  ? '$text$delivered${c.reason == null ? '' : ' · ${c.reason}'}'
                  : '$text (${weightLabel(c.amountG)})',
              style: const TextStyle(fontSize: 13, color: kInk),
            ),
          ),
          Text(
            ago(c.requestedAt),
            style: const TextStyle(fontSize: 11, color: Colors.black38),
          ),
        ],
      ),
    );
  }
}

// --- schedules ---------------------------------------------------------------------

class _ScheduleSection extends StatelessWidget {
  const _ScheduleSection({required this.schedules, required this.reading});

  final List<FeedSchedule> schedules;
  final FeederReading reading;

  Future<void> _guard(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      if (context.mounted) _say(context, 'Could not save the schedule.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FeederScope.of(context);
    final controls = scope.controls;
    final f = scope.feeder;
    // Schedules are saved for the controller to pick up later, so an
    // offline controller does not block editing.
    final editable = f.can('manageSchedules') && !f.archived && scope.online;
    final paused = reading.schedulesPaused;

    return _Section(
      key: const ValueKey('section-schedules'),
      icon: Icons.schedule_rounded,
      title: 'Automatic Feeding',
      body:
          'Feeding times in the feeder\'s time zone (${f.timezone}), daily or '
          'on chosen days. The controller runs them even without the app.',
      trailing: Switch(
        key: const ValueKey('schedules-active'),
        value: !paused,
        activeTrackColor: kAmber,
        onChanged: editable
            ? (on) => _guard(
                context,
                () => controls.live.update({
                  controls.path('config/schedulesPaused'): !on,
                }),
              )
            : null,
      ),
      note: paused ? 'All schedules are paused.' : null,
      children: [
        if (schedules.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: kBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              children: [
                Icon(Icons.event_note_rounded, color: Colors.black26),
                SizedBox(height: 6),
                Text(
                  'No feeding times yet',
                  style: TextStyle(color: Colors.black45),
                ),
              ],
            ),
          )
        else
          for (final s in schedules)
            Container(
              key: ValueKey('schedule-${s.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s.time}  ·  ${weightLabel(s.amountG)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: s.enabled && !paused ? kInk : Colors.black38,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.weekdays.length == 7
                              ? 'Every day'
                              : [
                                  for (final d in s.weekdays.toList()..sort())
                                    const [
                                      'Sun',
                                      'Mon',
                                      'Tue',
                                      'Wed',
                                      'Thu',
                                      'Fri',
                                      'Sat',
                                    ][d],
                                ].join(', '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: s.enabled,
                    activeTrackColor: kAmber,
                    onChanged: editable
                        ? (on) => _guard(
                            context,
                            () => controls.setScheduleEnabled(s, on),
                          )
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Delete ${s.time}',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: editable
                        ? () => _guard(
                            context,
                            () => controls.deleteSchedule(s.id),
                          )
                        : null,
                  ),
                ],
              ),
            ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('add-schedule'),
            onPressed: editable
                ? () async {
                    final s = await showDialog<_NewSchedule>(
                      context: context,
                      builder: (_) =>
                          _ScheduleDialog(maxG: reading.maxDispenseG),
                    );
                    if (s == null || !context.mounted) return;
                    await _guard(
                      context,
                      () => controls.saveSchedule(
                        time: s.time,
                        amountG: s.amountG,
                        weekdays: s.weekdays,
                      ),
                    );
                  }
                : null,
            style: _pill(OutlinedButton.styleFrom()),
            icon: const Icon(Icons.add),
            label: const Text('Add schedule'),
          ),
        ),
      ],
    );
  }
}

class _NewSchedule {
  const _NewSchedule(this.time, this.amountG, this.weekdays);

  final String time;
  final double amountG;
  final Set<int> weekdays;
}

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog({required this.maxG});

  final double maxG;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late TimeOfDay _time;
  double _amount = 50;
  final Set<int> _days = {0, 1, 2, 3, 4, 5, 6};

  @override
  void initState() {
    super.initState();
    // Two minutes from now, so a new schedule can be watched running.
    final t = DateTime.now().add(const Duration(minutes: 2));
    _time = TimeOfDay(hour: t.hour, minute: t.minute);
    _amount = _amount.clamp(5, widget.maxG);
  }

  @override
  Widget build(BuildContext context) {
    final time = '${two(_time.hour)}:${two(_time.minute)}';
    return AlertDialog(
      title: const Text('New feeding time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('schedule-time'),
            onPressed: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: _time,
              );
              if (t != null) setState(() => _time = t);
            },
            icon: const Icon(Icons.schedule_rounded),
            label: Text(time, style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: 14),
          Text('Amount: ${weightLabel(_amount)}'),
          Slider(
            value: _amount,
            min: 5,
            max: widget.maxG,
            divisions: ((widget.maxG - 5) / 5).round().clamp(1, 1000),
            activeColor: kAmber,
            onChanged: (x) => setState(() => _amount = (x / 5).round() * 5),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var d = 0; d < 7; d++)
                GestureDetector(
                  onTap: () => setState(
                    () => _days.contains(d) ? _days.remove(d) : _days.add(d),
                  ),
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: _days.contains(d) ? kAmber : kBeige,
                    child: Text(
                      _kWeekdayLetters[d],
                      style: const TextStyle(fontSize: 12, color: kInk),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('save-schedule'),
          onPressed: _days.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _NewSchedule(time, _amount, {..._days}),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
