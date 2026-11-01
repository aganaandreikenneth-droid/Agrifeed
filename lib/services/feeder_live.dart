import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../core/format.dart';

/// Live feeder data and the feeding controls. Everything shown here was
/// written by the feeder's controller (or the simulator, `source:
/// 'simulator'`); the app only writes requests (commands, gate requests,
/// schedules) and, for simulated feeders, the simulation controls. The
/// Security Rules check every write.
abstract class FeederLive {
  /// Value at [path] (absolute), live. [last] limits a list to its newest
  /// children by [orderBy].
  Stream<Object?> watch(String path, {String? orderBy, int? last});

  /// Atomic multi-path update; paths are absolute. [now] marks a server time.
  Future<void> update(Map<String, Object?> values);

  /// A new push ID under [path].
  String newKey(String path);

  /// Server timestamp placeholder for [update].
  Object get now;
}

class FirebaseFeederLive implements FeederLive {
  FirebaseFeederLive(this._db);

  final FirebaseDatabase _db;

  @override
  Stream<Object?> watch(String path, {String? orderBy, int? last}) {
    Query q = _db.ref(path);
    if (orderBy != null) q = q.orderByChild(orderBy);
    if (last != null) q = q.limitToLast(last);
    return q.onValue.map((e) => e.snapshot.value);
  }

  @override
  Future<void> update(Map<String, Object?> values) => _db.ref().update(values);

  @override
  String newKey(String path) => _db.ref(path).push().key!;

  @override
  Object get now => ServerValue.timestamp;
}

// --- models ------------------------------------------------------------------

/// A controller that has not reported for this long is shown offline.
const kOfflineAfter = Duration(seconds: 30);

/// A hopper weight older than this cannot be used to allow a feeding (the
/// controller sends one every second while it is connected).
const kWeightStaleAfter = Duration(seconds: 15);

/// At or below this the hopper counts as empty (the controller refuses to
/// feed at 3 g or less: no feed would come out).
const kHopperEmptyG = 3.0;

/// `status` + `telemetry/current` + `config`, as one dashboard reading.
@immutable
class FeederReading {
  const FeederReading({
    this.weightG,
    this.measuredAt,
    this.lastSeen,
    this.condition,
    this.rtcTime,
    this.quality,
    this.calibrated = false,
    this.simulated = false,
    this.capacityG = 2500,
    this.lowThresholdG = 500,
    this.maxDispenseG = 200,
    this.schedulesPaused = false,
  });

  /// Null until the controller has sent a weight.
  final double? weightG;
  final int? measuredAt;
  final int? lastSeen;

  /// The controller's RTC reading at [lastSeen], local feeder time
  /// (`status/rtcTime`, e.g. `2026-11-01T14:05:09`). Null without an RTC.
  final String? rtcTime;
  final String? condition;

  /// `telemetry/current/quality`: ok | unstable (gate open, feeding) | error.
  final String? quality;

  /// `config/calibrationStatus == 'calibrated'` (set by the controller).
  final bool calibrated;
  final bool simulated;
  final double capacityG;
  final double lowThresholdG;
  final double maxDispenseG;
  final bool schedulesPaused;

  bool online([DateTime? now]) =>
      lastSeen != null &&
      (now ?? DateTime.now()).millisecondsSinceEpoch - lastSeen! <
          kOfflineAfter.inMilliseconds;

  /// The hopper weight as shown: never below 0 g (sensor noise around an
  /// empty hopper can read slightly negative). Null until reported.
  double? get shownWeightG =>
      weightG == null ? null : (weightG! < 0 ? 0.0 : weightG!);

  /// Fill level 0..1 for gauges and percentages (never negative).
  double? get fraction => shownWeightG == null || capacityG <= 0
      ? null
      : (shownWeightG! / capacityG).clamp(0.0, 1.0);

  bool get low => weightG != null && weightG! <= lowThresholdG;

  /// Why the hopper weight cannot be trusted for dispensing, or null when
  /// it can: it must be recent, from a working, calibrated load cell.
  String? weightProblem([DateTime? now]) {
    if (weightG == null || measuredAt == null) {
      return 'No hopper weight from the load cell yet, so feeding is blocked.';
    }
    if (condition == 'error' || quality == 'error') {
      return 'The load cell is not responding, so feeding is blocked. '
          'Check the HX711 wiring.';
    }
    if (!calibrated && !simulated) {
      return 'The scale is not calibrated, so the hopper weight cannot be '
          'verified. Calibrate it in Settings > Scale calibration.';
    }
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch - measuredAt!;
    if (age > kWeightStaleAfter.inMilliseconds) {
      return 'The hopper weight is out of date (no reading for '
          '${age ~/ 1000} s), so feeding is blocked.';
    }
    return null;
  }

  /// Grams that can be dispensed now: the verified hopper weight, or null
  /// when the weight cannot be verified.
  double? availableG([DateTime? now]) =>
      weightProblem(now) == null ? shownWeightG : null;

  /// Null when [grams] can be dispensed, otherwise why not.
  String? cannotDispense(double grams, [DateTime? now]) {
    final problem = weightProblem(now);
    if (problem != null) return problem;
    if (shownWeightG! <= kHopperEmptyG) {
      return 'The hopper is empty (${weightLabel(shownWeightG!)}). Refill it '
          'before feeding.';
    }
    if (shownWeightG! < grams) {
      return 'Not enough feed: ${weightLabel(shownWeightG!)} in the hopper, '
          '${weightLabel(grams)} requested. Refill the hopper or choose a '
          'smaller amount.';
    }
    return null;
  }

  static FeederReading from({
    Object? status,
    Object? telemetry,
    Object? config,
  }) {
    final s = toMap(status), t = toMap(telemetry), c = toMap(config);
    double num_(Object? v, double d) => v is num ? v.toDouble() : d;
    return FeederReading(
      weightG: t['weightG'] is num ? (t['weightG'] as num).toDouble() : null,
      measuredAt: (t['measuredAt'] as num?)?.toInt(),
      lastSeen: (s['lastSeen'] as num?)?.toInt(),
      condition: s['condition'] as String?,
      rtcTime: s['rtcTime'] is String ? s['rtcTime'] as String : null,
      quality: t['quality'] as String?,
      calibrated: c['calibrationStatus'] == 'calibrated',
      simulated: s['source'] == 'simulator' || t['source'] == 'simulator',
      capacityG: num_(c['capacityG'], 2500),
      lowThresholdG: num_(c['lowThresholdG'], 500),
      maxDispenseG: num_(c['maxDispenseG'], 200),
      schedulesPaused: c['schedulesPaused'] == true,
    );
  }
}

/// One verified feeding outcome from `history`.
@immutable
class FeedEvent {
  const FeedEvent({
    required this.id,
    required this.method,
    required this.requestedG,
    required this.actualG,
    required this.status,
    required this.ts,
    required this.simulated,
  });

  final String id;
  final String method; // scheduled | manual
  final double requestedG;
  final double actualG;
  final String status;
  final int ts;
  final bool simulated;

  bool get delivered => status == 'completed' || status == 'partial';

  static List<FeedEvent> listFrom(Object? value) {
    final list = [
      for (final e in toMap(value).entries)
        if (e.value is Map)
          FeedEvent(
            id: e.key,
            method: toMap(e.value)['method'] as String? ?? 'manual',
            requestedG: (toMap(e.value)['requestedG'] as num?)?.toDouble() ?? 0,
            actualG: (toMap(e.value)['actualG'] as num?)?.toDouble() ?? 0,
            status: toMap(e.value)['status'] as String? ?? 'failed',
            ts: (toMap(e.value)['ts'] as num?)?.toInt() ?? 0,
            simulated: toMap(e.value)['source'] == 'simulator',
          ),
    ];
    list.sort((a, b) => b.ts.compareTo(a.ts));
    return list;
  }
}

/// Grams delivered per local day for the [days] days ending today; index 0
/// is the oldest.
List<double> gramsPerDay(List<FeedEvent> events, {int days = 7, DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final out = List<double>.filled(days, 0);
  for (final e in events) {
    if (!e.delivered) continue;
    final d = DateUtils.dateOnly(DateTime.fromMillisecondsSinceEpoch(e.ts));
    final i = days - 1 - today.difference(d).inDays;
    if (i >= 0 && i < days) out[i] += e.actualG;
  }
  return out;
}

/// A feeding time from `schedules`.
@immutable
class FeedSchedule {
  const FeedSchedule({
    required this.id,
    required this.time,
    required this.amountG,
    required this.enabled,
    this.weekdays = const {0, 1, 2, 3, 4, 5, 6},
    this.label,
    this.createdAt,
  });

  final String id;
  final String time; // HH:MM, feeder time zone
  final double amountG;
  final bool enabled;

  /// 0 = Sunday ... 6 = Saturday.
  final Set<int> weekdays;
  final String? label;
  final int? createdAt;

  int get minutes =>
      int.parse(time.substring(0, 2)) * 60 + int.parse(time.substring(3));

  bool runsOn(int weekday) => weekdays.contains(weekday);

  static List<FeedSchedule> listFrom(Object? value) {
    final list = <FeedSchedule>[];
    for (final e in toMap(value).entries) {
      final m = toMap(e.value);
      final time = m['time'];
      if (time is! String || time.length != 5) continue;
      // Keys "0".."6" may come back as a list.
      final raw = m['weekdays'];
      final w = raw is List
          ? {for (var i = 0; i < raw.length; i++) '$i': raw[i]}
          : toMap(raw);
      list.add(
        FeedSchedule(
          id: e.key,
          time: time,
          amountG: (m['amountG'] as num?)?.toDouble() ?? 0,
          enabled: m['enabled'] == true,
          weekdays:
              w.isEmpty
                    ? const {0, 1, 2, 3, 4, 5, 6}
                    : {
                        for (final d in w.entries)
                          if (d.value == true) int.tryParse(d.key) ?? -1,
                      }
                ..remove(-1),
          label: m['label'] as String?,
          createdAt: (m['createdAt'] as num?)?.toInt(),
        ),
      );
    }
    list.sort((a, b) => a.minutes.compareTo(b.minutes));
    return list;
  }
}

/// Dart weekday (Mon=1..Sun=7) to the schedule numbering (Sun=0..Sat=6).
int scheduleWeekday(DateTime d) => d.weekday % 7;

/// The gate as the controller last reported it.
@immutable
class GateReport {
  const GateReport({
    this.position,
    this.closesAt,
    this.lastRequestId,
    this.lastResult,
    this.reason,
  });

  /// 'open', 'closed', or null when nothing was reported yet.
  final String? position;
  final int? closesAt;
  final String? lastRequestId;
  final String? lastResult;
  final String? reason;

  static GateReport from(Object? value) {
    final m = toMap(value);
    return GateReport(
      position: m['position'] as String?,
      closesAt: (m['closesAt'] as num?)?.toInt(),
      lastRequestId: m['lastRequestId'] as String?,
      lastResult: m['lastResult'] as String?,
      reason: m['reason'] as String?,
    );
  }
}

/// `calibration/state`: the controller's answer to the last calibration step.
@immutable
class CalibrationReport {
  const CalibrationReport({
    this.lastRequestId,
    this.action,
    this.result,
    this.reason,
  });

  final String? lastRequestId;
  final String? action; // tare | calibrate
  final String? result; // done | rejected
  final String? reason;

  static CalibrationReport from(Object? value) {
    final m = toMap(value);
    return CalibrationReport(
      lastRequestId: m['lastRequestId'] as String?,
      action: m['action'] as String?,
      result: m['result'] as String?,
      reason: m['reason'] as String?,
    );
  }
}

/// A manual feeding request and how far it got.
@immutable
class FeedCommand {
  const FeedCommand({
    required this.id,
    required this.amountG,
    required this.status,
    required this.requestedAt,
    this.actualG,
    this.reason,
  });

  final String id;
  final double amountG;
  final String status;
  final int requestedAt;
  final double? actualG;
  final String? reason;

  static const terminal = {
    'completed',
    'partial',
    'failed',
    'rejected',
    'expired',
  };

  bool get finished => terminal.contains(status);

  static FeedCommand? from(String id, Object? value) {
    if (value is! Map) return null;
    final m = toMap(value);
    return FeedCommand(
      id: id,
      amountG: (m['amountG'] as num?)?.toDouble() ?? 0,
      status: m['status'] as String? ?? 'pending',
      requestedAt: (m['requestedAt'] as num?)?.toInt() ?? 0,
      actualG: (m['actualG'] as num?)?.toDouble(),
      reason: m['reason'] as String?,
    );
  }
}

/// Matches the rules: a pending command may be expired after this long.
const kCommandTtl = Duration(seconds: 120);

// --- requests -------------------------------------------------------------------

/// Paths and writes for one feeder. Requests only: the controller decides
/// and reports what really happened.
class FeederControls {
  FeederControls(this.live, this.feederId, this.uid);

  final FeederLive live;
  final String feederId;
  final String uid;

  String path(String sub) => 'feeders/$feederId/$sub';

  /// Creates a manual feeding command together with the one-at-a-time lock.
  Future<String> feedNow(double amountG) async {
    final cid = live.newKey(path('commands'));
    await live.update({
      path('commands/$cid'): {
        'amountG': amountG.round(),
        'requestedBy': uid,
        'requestedAt': live.now,
        'status': 'pending',
        'source': 'app',
      },
      path('activeCommand'): {'commandId': cid, 'requestedAt': live.now},
    });
    return cid;
  }

  /// Gives up on a command the feeder never picked up (allowed by the rules
  /// once it is older than [kCommandTtl]) and frees the lock.
  Future<void> expire(String cid) => live.update({
    path('commands/$cid/status'): 'expired',
    path('activeCommand'): null,
  });

  /// Sends one gate request; never resent automatically.
  Future<String> gate(String action, {int durationS = 5}) async {
    final id = live.newKey(path('gate/request'));
    await live.update({
      path('gate/request'): {
        'id': id,
        'action': action,
        'durationS': durationS,
        'requestedAt': live.now,
        'requestedBy': uid,
      },
    });
    return id;
  }

  /// Asks the controller to set the zero (`tare`, empty hopper) or to
  /// calibrate with [knownG] grams in the hopper (`calibrate`). Never resent.
  Future<String> calibrate(String action, {double? knownG}) async {
    final id = live.newKey(path('calibration/request'));
    await live.update({
      path('calibration/request'): {
        'id': id,
        'action': action,
        if (knownG != null) 'knownG': knownG.round(),
        'requestedAt': live.now,
        'requestedBy': uid,
      },
    });
    return id;
  }

  Future<void> saveSchedule({
    String? id,
    required String time,
    required double amountG,
    required Set<int> weekdays,
    bool enabled = true,
    Object? createdAt,
  }) {
    final sid = id ?? live.newKey(path('schedules'));
    return live.update({
      path('schedules/$sid'): {
        'time': time,
        'amountG': amountG.round(),
        'weekdays': {for (var d = 0; d < 7; d++) '$d': weekdays.contains(d)},
        'enabled': enabled,
        'createdAt': createdAt ?? live.now,
        'updatedAt': live.now,
        'updatedBy': uid,
      },
    });
  }

  Future<void> setScheduleEnabled(FeedSchedule s, bool enabled) => saveSchedule(
    id: s.id,
    time: s.time,
    amountG: s.amountG,
    weekdays: s.weekdays,
    enabled: enabled,
    createdAt: s.createdAt,
  );

  Future<void> deleteSchedule(String sid) =>
      live.update({path('schedules/$sid'): null});

  /// Simulated feeders only: tells the simulator the hopper was refilled.
  Future<void> refillSimulated(double grams) => live.update({
    path('simulator/controls/hopperWeightG'): grams.round(),
    path('simulator/controls/updatedAt'): live.now,
  });
}
