import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../core/format.dart';

/// One record from `feeders/{id}/alerts`. Alerts are written only by the
/// feeder's device (or the simulator, `source: 'simulator'`), never by the app.
@immutable
class FeederAlert {
  const FeederAlert({
    required this.id,
    required this.type,
    required this.severity,
    required this.active,
    required this.lastAt,
    required this.simulated,
  });

  final String id;
  final String type;
  final String severity;
  final bool active;
  final int lastAt;
  final bool simulated;

  static FeederAlert fromMap(String id, Map<String, dynamic> m) => FeederAlert(
    id: id,
    type: (m['type'] as String?) ?? 'unknown',
    severity: (m['severity'] as String?) ?? 'info',
    active: m['state'] == 'active',
    lastAt: (m['lastAt'] as num?)?.toInt() ?? 0,
    simulated: m['source'] == 'simulator',
  );
}

const _alertTitles = {
  'low_feed': 'Low feed',
  'stuck_feed': 'Feed blockage',
  'sensor_error': 'Sensor error',
  'dispense_failed': 'Feeding failed',
};

String alertTitle(FeederAlert a) => _alertTitles[a.type] ?? 'Feeder alert';

/// Per-feeder reads and the few owner writes the app makes directly
/// (everything else goes through Cloud Functions). Faked in widget tests.
abstract class FeederRepository {
  /// `feeders/{id}/alerts`, newest first.
  Stream<List<FeederAlert>> watchAlerts(String feederId);

  /// `feeders/{id}/meta/name` (owner only, not archived; the rules check).
  Future<void> rename(String feederId, String name);

  /// `feeders/{id}/meta/timezone` (owner only, not archived).
  Future<void> setTimezone(String feederId, String timezone);
}

class FirebaseFeederRepository implements FeederRepository {
  FirebaseFeederRepository(this._db);

  final FirebaseDatabase _db;

  DatabaseReference _meta(String feederId) => _db.ref('feeders/$feederId/meta');

  @override
  Stream<List<FeederAlert>> watchAlerts(String feederId) => _db
      .ref('feeders/$feederId/alerts')
      .orderByChild('lastAt')
      .limitToLast(50)
      .onValue
      .map((e) {
        final list = [
          for (final c in e.snapshot.children)
            FeederAlert.fromMap(c.key!, toMap(c.value)),
        ];
        list.sort((a, b) => b.lastAt.compareTo(a.lastAt));
        return list;
      });

  @override
  Future<void> rename(String feederId, String name) =>
      _meta(feederId).child('name').set(name);

  @override
  Future<void> setTimezone(String feederId, String timezone) =>
      _meta(feederId).child('timezone').set(timezone);
}
