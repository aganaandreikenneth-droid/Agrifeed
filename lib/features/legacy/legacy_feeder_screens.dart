// ---------------------------------------------------------------------------
// LEGACY single-feeder screens (pre-Phase 1), kept for Phase 2 integration.
//
// NOT MOUNTED in the Phase 1 build: nothing imports this file, so none of its
// database listeners run. It still targets the fixed legacy path
// `feeders/feeder1` and the default Firebase app. Phase 2 rebuilds these
// screens on a selected feeder ID and the new schema; do not import as-is.
// ---------------------------------------------------------------------------
// ignore_for_file: unused_element

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../core/format.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';

const String legacyFeederId = 'feeder1'; // legacy path only, see header
const double defaultCapacityG =
    9000; // NOTE: exceeds the proposal's 3 kg load cell; re-check in Phase 3
const double defaultLowG = 500;
const int offlineAfterMs =
    90000; // feeder is "offline" if no heartbeat for 90 s

DatabaseReference get feederRef =>
    FirebaseDatabase.instance.ref('feeders/$legacyFeederId');

Future<void> addLog(String type, String message) {
  return feederRef.child('logs').push().set({
    'ts': ServerValue.timestamp,
    'type': type,
    'message': message,
    'user': FirebaseAuth.instance.currentUser?.email ?? 'unknown',
  });
}

String nextFeeding(Map<String, dynamic> schedules) {
  final now = DateTime.now();
  DateTime? best;
  int bestAmount = 0;
  for (final v in schedules.values) {
    final s = toMap(v);
    if (s['enabled'] != true) continue;
    final parts = (s['time'] as String? ?? '').split(':');
    if (parts.length != 2) continue;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) continue;
    var t = DateTime(now.year, now.month, now.day, h, m);
    if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
    if (best == null || t.isBefore(best)) {
      best = t;
      bestAmount = (s['amountG'] as num?)?.toInt() ?? 0;
    }
  }
  if (best == null) return 'No active schedule';
  final today = best.day == now.day;
  return '${today ? 'Today' : 'Tomorrow'} ${two(best.hour)}:${two(best.minute)}\n$bestAmount g';
}

Future<int?> askAmount(
  BuildContext context, {
  required String title,
  int initial = 50,
  int max = 5000,
}) {
  final c = TextEditingController(text: '$initial');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: InputDecoration(
          suffixText: 'g',
          helperText: 'Up to $max g',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = int.tryParse(c.text.trim());
            if (v != null && v > 0 && v <= max) Navigator.pop(ctx, v);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> dispenseNow(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final snap = await feederRef.child('status/lastSeen').get();
    final ls = (snap.value as num?)?.toInt();
    final online =
        ls != null &&
        DateTime.now().millisecondsSinceEpoch - ls < offlineAfterMs;
    if (!online) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The feeder is offline.')),
      );
      return;
    }
    if (!context.mounted) return;
    final amount = await askAmount(
      context,
      title: 'Dispense now',
      initial: 50,
      max: 500,
    );
    if (amount == null) return;
    await feederRef.child('command').set({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'amountG': amount,
      'status': 'pending',
      'requestedBy': FirebaseAuth.instance.currentUser?.email ?? 'unknown',
      'requestedAt': ServerValue.timestamp,
    });
    await addLog('manual_dispense', 'Dispense requested: $amount g');
    messenger.showSnackBar(
      SnackBar(content: Text('Sent $amount g request to the feeder')),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not send request: $e')),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation shell
// ---------------------------------------------------------------------------

class LegacyHomeShell extends StatefulWidget {
  const LegacyHomeShell({super.key});

  @override
  State<LegacyHomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<LegacyHomeShell> {
  int _i = 0;

  static const _titles = [
    'Dashboard',
    'Feeding schedule',
    'History',
    'Settings',
  ];
  static const _pages = <Widget>[
    DashboardPage(),
    SchedulePage(),
    HistoryPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: const IconBox(icon: Icons.egg_alt_outlined),
        title: Text(
          _titles[_i],
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        actions: [
          IconBox(
            icon: Icons.notifications_none_rounded,
            onTap: () => setState(() => _i = 2),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _pages[_i],
      bottomNavigationBar: PillNav(
        index: _i,
        onTap: (v) => setState(() => _i = v),
        onCenter: () => dispenseNow(context),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Re-evaluate "online/offline" even when no new data arrives.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Database error: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = toMap(snap.data!.snapshot.value);
        final status = toMap(data['status']);
        final hopper = toMap(data['hopper']);
        final schedules = toMap(data['schedules']);
        final cmd = toMap(data['command']);

        final lastSeen = (status['lastSeen'] as num?)?.toInt();
        final online =
            lastSeen != null &&
            DateTime.now().millisecondsSinceEpoch - lastSeen < offlineAfterMs;
        final condition = (status['condition'] as String?) ?? 'ok';
        final lastFeedAt = status['lastFeedAt'];

        final weight = (hopper['weightG'] as num?)?.toDouble() ?? 0;
        final capacity =
            (hopper['capacityG'] as num?)?.toDouble() ?? defaultCapacityG;
        final low =
            (hopper['lowThresholdG'] as num?)?.toDouble() ?? defaultLowG;
        final frac = (weight / capacity).clamp(0.0, 1.0);

        final jam = condition == 'jam';
        final lowFeed = weight < low;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Feeder status
            Panel(
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: online ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          online ? 'Feeder online' : 'Feeder offline',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          lastSeen == null
                              ? 'Never connected'
                              : 'Last connection ${ago(lastSeen)}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    online ? Icons.wifi : Icons.wifi_off,
                    color: online ? kField : Colors.grey,
                  ),
                ],
              ),
            ),
            if (jam) ...[
              const SizedBox(height: 12),
              const Panel(
                color: Color(0xFFFDE7E7),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Feed jam detected. Check the gate and press the feeder button to reset the alarm.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (lowFeed && online) ...[
              const SizedBox(height: 12),
              Panel(
                color: const Color(0xFFFFF1DC),
                child: Row(
                  children: [
                    const Icon(
                      Icons.inventory_2_outlined,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Low feed: ${weightLabel(weight)} left. Refill the hopper soon.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),

            // Hopper level (segmented gauge)
            SegmentGauge(
              fraction: frac,
              color: weight < low ? const Color(0xFFE5584A) : kOrange,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    online ? Icons.wifi : Icons.wifi_off,
                    color: kOrange,
                    size: 22,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    online ? 'Feeder online' : 'Feeder offline',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    weightLabel(weight),
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                      color: kSoil,
                    ),
                  ),
                  Text(
                    'Alert below ${low.round()} g',
                    style: const TextStyle(color: kGrain),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Next feeding + today's summary
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.schedule, color: kGrain),
                          const SizedBox(height: 8),
                          const Text(
                            'Next feeding',
                            style: TextStyle(color: Colors.black54),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            nextFeeding(schedules),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: TodayCard()),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Last feeding
            Panel(
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: kField),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      lastFeedAt == null
                          ? 'No successful feeding yet'
                          : 'Last successful feeding: ${fmtTs(lastFeedAt)}',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Dispense
            SizedBox(
              height: 58,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: kBeige,
                  foregroundColor: kSoil,
                  shape: const StadiumBorder(),
                ),
                onPressed: online ? () => dispenseNow(context) : null,
                icon: const Icon(Icons.add),
                label: const Text(
                  'Dispense now',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (!online)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The feeder is offline. Scheduled feedings still run on its own clock.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            if (cmd['status'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last request: ${cmd['amountG']} g (${cmd['status']})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
          ],
        );
      },
    );
  }
}

class TodayCard extends StatelessWidget {
  const TodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef
          .child('history')
          .orderByChild('ts')
          .limitToLast(100)
          .onValue,
      builder: (context, snap) {
        int count = 0;
        int grams = 0;
        if (snap.hasData) {
          final now = DateTime.now();
          for (final c in snap.data!.snapshot.children) {
            final m = toMap(c.value);
            final ts = m['ts'];
            if (ts is! num) continue;
            final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
            if (d.year == now.year &&
                d.month == now.month &&
                d.day == now.day) {
              if (m['status'] == 'jam') continue;
              count++;
              grams += (m['amountG'] as num?)?.toInt() ?? 0;
            }
          }
        }
        return Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.today, color: kGrain),
              const SizedBox(height: 8),
              const Text(
                "Today's feeding",
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 4),
              Text(
                '$count feedings\n$grams g',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------

Future<void> editSchedule(
  BuildContext context, {
  String? id,
  Map<String, dynamic>? existing,
}) async {
  var time = const TimeOfDay(hour: 7, minute: 0);
  final t = existing?['time'] as String?;
  if (t != null) {
    final p = t.split(':');
    if (p.length == 2) {
      time = TimeOfDay(
        hour: int.tryParse(p[0]) ?? 7,
        minute: int.tryParse(p[1]) ?? 0,
      );
    }
  }
  final picked = await showTimePicker(context: context, initialTime: time);
  if (picked == null || !context.mounted) return;
  final amount = await askAmount(
    context,
    title: 'Feed amount',
    initial: (existing?['amountG'] as num?)?.toInt() ?? 50,
    max: 500,
  );
  if (amount == null) return;
  final timeStr = '${two(picked.hour)}:${two(picked.minute)}';
  final ref = id == null
      ? feederRef.child('schedules').push()
      : feederRef.child('schedules/$id');
  await ref.set({
    'time': timeStr,
    'amountG': amount,
    'enabled': existing?['enabled'] ?? true,
  });
  await addLog(
    id == null ? 'schedule_added' : 'schedule_edited',
    'Schedule $timeStr, $amount g',
  );
}

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editSchedule(context),
        icon: const Icon(Icons.add),
        label: const Text('Add schedule'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: feederRef.child('schedules').onValue,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Database error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final raw = toMap(snap.data!.snapshot.value);
          final items =
              raw.entries.map((e) => MapEntry(e.key, toMap(e.value))).toList()
                ..sort(
                  (a, b) => ((a.value['time'] as String?) ?? '').compareTo(
                    (b.value['time'] as String?) ?? '',
                  ),
                );
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No feeding schedules yet.\nTap "Add schedule" to set a time and amount.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final id = items[i].key;
              final s = items[i].value;
              final enabled = s['enabled'] == true;
              return Panel(
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => editSchedule(context, id: id, existing: s),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s['time'] ?? '--:--'}',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: enabled ? kSoil : Colors.black38,
                              ),
                            ),
                            Text('${s['amountG'] ?? 0} g'),
                          ],
                        ),
                      ),
                    ),
                    Switch(
                      value: enabled,
                      onChanged: (v) async {
                        await feederRef.child('schedules/$id/enabled').set(v);
                        await addLog(
                          'schedule_toggled',
                          '${s['time']} ${v ? 'enabled' : 'disabled'}',
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await feederRef.child('schedules/$id').remove();
                        await addLog(
                          'schedule_deleted',
                          'Deleted ${s['time']}',
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History + activity log
// ---------------------------------------------------------------------------

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Feedings'),
              Tab(text: 'Activity log'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                RecentList(path: 'history', feeding: true),
                RecentList(path: 'logs', feeding: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class RecentList extends StatelessWidget {
  const RecentList({super.key, required this.path, required this.feeding});

  final String path;
  final bool feeding;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef.child(path).orderByChild('ts').limitToLast(100).onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Database error: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snap.data!.snapshot.children
            .map((c) => toMap(c.value))
            .toList()
            .reversed
            .toList();
        if (items.isEmpty) {
          return const Center(child: Text('Nothing recorded yet.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final m = items[i];
            if (feeding) {
              final status = '${m['status'] ?? ''}';
              final ok = status == 'done';
              return Panel(
                child: Row(
                  children: [
                    Icon(
                      ok ? Icons.check_circle : Icons.error_outline,
                      color: ok ? kField : Colors.orange,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${m['amountG'] ?? 0} g, ${m['type'] ?? ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text('${fmtTs(m['ts'])}  |  $status'),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }
            return Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m['message'] ?? m['type'] ?? ''}'),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtTs(m['ts'])}  |  ${m['user'] ?? ''}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Panel(
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: kField,
                child: Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (user?.displayName?.isNotEmpty ?? false)
                          ? user!.displayName!
                          : (user?.email ?? 'Unknown user'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      user?.email ?? '',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        StreamBuilder<DatabaseEvent>(
          stream: feederRef.child('hopper/lowThresholdG').onValue,
          builder: (context, snap) {
            final v =
                (snap.data?.snapshot.value as num?)?.toInt() ??
                defaultLowG.toInt();
            return Panel(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Low-feed alert level'),
                subtitle: Text('Warn when the hopper is below $v g'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async {
                  final nv = await askAmount(
                    context,
                    title: 'Low-feed alert level',
                    initial: v,
                    max: 5000,
                  );
                  if (nv == null) return;
                  await feederRef.child('hopper/lowThresholdG').set(nv);
                  await addLog('settings', 'Low-feed level set to $nv g');
                },
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        const Panel(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.memory),
            title: Text('Feeder'),
            subtitle: Text('ID: $legacyFeederId'),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () async {
            try {
              await addLog('logout', 'Signed out');
            } catch (_) {}
            await FirebaseAuth.instance.signOut();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
