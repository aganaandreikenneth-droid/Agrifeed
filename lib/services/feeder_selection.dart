import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../core/format.dart';

/// Member permissions, the same whitelist as the rules and Cloud Functions.
const kFeederPermissions = [
  'viewDashboard',
  'viewHistory',
  'viewAnalytics',
  'manualFeed',
  'manageSchedules',
  'downloadReports',
  'receiveAlerts',
];

enum FeederRole { owner, member }

/// One feeder the signed-in user can access, as the database says right now.
@immutable
class FeederSummary {
  const FeederSummary({
    required this.feederId,
    required this.role,
    required this.name,
    required this.mode,
    this.timezone = 'UTC',
    this.archived = false,
    this.permissions = const {},
  });

  final String feederId;
  final FeederRole role;
  final String name;

  /// 'simulated' or 'live' (set by the backend, never by the app).
  final String mode;

  /// IANA zone the feeder's schedules run in (`meta.timezone`).
  final String timezone;
  final bool archived;
  final Map<String, bool> permissions;

  bool get isOwner => role == FeederRole.owner;
  bool get isVirtual => mode == 'simulated';

  /// Owners hold every permission; members only those granted to them.
  /// The rules enforce this too; the app only uses it to hide or disable.
  bool can(String permission) => isOwner || permissions[permission] == true;

  @override
  bool operator ==(Object other) =>
      other is FeederSummary &&
      other.feederId == feederId &&
      other.role == role &&
      other.name == name &&
      other.mode == mode &&
      other.timezone == timezone &&
      other.archived == archived &&
      mapEquals(other.permissions, permissions);

  @override
  int get hashCode =>
      Object.hash(feederId, role, name, mode, timezone, archived);
}

/// Builds a summary from `feeders/{id}/meta` and `feeders/{id}/members/{uid}`.
/// Returns null when the user has no access: missing feeder, missing or
/// inactive membership (removed / left), or an owner record that does not
/// match `meta.ownerUid` (the same test as the rules).
FeederSummary? summarize({
  required String feederId,
  required String uid,
  required Map<String, dynamic>? meta,
  required Map<String, dynamic>? member,
}) {
  if (meta == null || member == null) return null;
  if (member['status'] != 'active') return null;
  final expiresAt = member['expiresAt'];
  if (expiresAt is num && expiresAt <= DateTime.now().millisecondsSinceEpoch) {
    return null;
  }
  final isOwner = member['role'] == 'owner' && meta['ownerUid'] == uid;
  if (!isOwner && member['role'] != 'member') return null;
  final perms = toMap(member['permissions']);
  return FeederSummary(
    feederId: feederId,
    role: isOwner ? FeederRole.owner : FeederRole.member,
    name: (meta['name'] as String?)?.trim().isNotEmpty == true
        ? meta['name'] as String
        : 'Unnamed feeder',
    mode: meta['mode'] == 'live' ? 'live' : 'simulated',
    timezone: meta['timezone'] is String ? meta['timezone'] as String : 'UTC',
    archived: meta['archivedAt'] != null,
    permissions: {for (final p in kFeederPermissions) p: perms[p] == true},
  );
}

/// Pure selection rule (one feeder per account): keep the current choice
/// while it is still accessible, else the saved one, else the first
/// available (owned first, then by name). Null only when there is none.
String? resolveSelection({
  required List<String> available,
  String? current,
  String? saved,
}) {
  if (current != null && available.contains(current)) return current;
  if (saved != null && available.contains(saved)) return saved;
  return available.isEmpty ? null : available.first;
}

/// Database access for [FeederSelectionController]; faked in widget tests.
abstract class FeederDataSource {
  /// `userFeeders/{uid}`: feederId -> role ('owner' / 'member').
  Stream<Map<String, String>> watchIndex(String uid);
  Stream<Map<String, dynamic>?> watchMeta(String feederId);
  Stream<Map<String, dynamic>?> watchMember(String feederId, String uid);
  Stream<bool> watchConnected();
  Future<String?> loadLastSelected(String uid);
  Future<void> saveLastSelected(String uid, String feederId);
}

class FirebaseFeederDataSource implements FeederDataSource {
  FirebaseFeederDataSource(this._db);

  final FirebaseDatabase _db;

  Map<String, dynamic>? _mapOrNull(DatabaseEvent e) =>
      e.snapshot.value == null ? null : toMap(e.snapshot.value);

  @override
  Stream<Map<String, String>> watchIndex(String uid) => _db
      .ref('userFeeders/$uid')
      .onValue
      .map(
        (e) => {
          for (final c in e.snapshot.children)
            c.key!: (toMap(c.value)['role'] as String?) ?? 'member',
        },
      );

  @override
  Stream<Map<String, dynamic>?> watchMeta(String feederId) =>
      _db.ref('feeders/$feederId/meta').onValue.map(_mapOrNull);

  @override
  Stream<Map<String, dynamic>?> watchMember(String feederId, String uid) =>
      _db.ref('feeders/$feederId/members/$uid').onValue.map(_mapOrNull);

  @override
  Stream<bool> watchConnected() =>
      _db.ref('.info/connected').onValue.map((e) => e.snapshot.value == true);

  @override
  Future<String?> loadLastSelected(String uid) async =>
      (await _db.ref('users/$uid/lastSelectedFeederId').get()).value as String?;

  @override
  Future<void> saveLastSelected(String uid, String feederId) =>
      _db.ref('users/$uid/lastSelectedFeederId').set(feederId);
}

enum FeederListStage { loading, error, ready }

/// Per-feeder listeners and their latest values.
class _Entry {
  _Entry(this.indexRole);

  String indexRole;
  Map<String, dynamic>? meta;
  Map<String, dynamic>? member;
  bool metaLoaded = false;
  bool memberLoaded = false;

  /// A listener was refused by the rules: access was removed.
  bool denied = false;
  final subs = <StreamSubscription<Object?>>[];

  bool get resolved => denied || (metaLoaded && memberLoaded);
}

/// Which feeders the signed-in user can open, and which one is selected.
///
/// Everything is live: a feeder appears when the backend adds it to
/// `userFeeders`, and disappears (with a [notice]) when the user is removed,
/// leaves, or the feeder is deleted, while the app is open. Feeder IDs only
/// ever come from the database.
class FeederSelectionController extends ChangeNotifier {
  FeederSelectionController(this._source, this.uid);

  final FeederDataSource _source;
  final String uid;

  final _entries = <String, _Entry>{};
  StreamSubscription<Map<String, String>>? _indexSub;
  StreamSubscription<bool>? _connectedSub;
  Timer? _offlineGrace;

  FeederListStage _stage = FeederListStage.loading;
  bool _indexLoaded = false;
  bool _savedLoaded = false;
  String? _saved;
  String? _selectedId;
  String? _pendingId;
  String? _notice;
  bool _connected = true;
  bool _everConnected = false;
  bool _graceOver = false;
  bool _disposed = false;

  FeederListStage get stage => _stage;

  /// Accessible feeders: owned first, then by name.
  List<FeederSummary> get feeders {
    final list = [
      for (final e in _entries.entries) ?_summaryOf(e.key, e.value),
    ];
    list.sort((a, b) {
      if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// True until every listed feeder's meta and membership have loaded.
  bool get resolving => _entries.values.any((e) => !e.resolved);

  FeederSummary? get selected {
    final id = _selectedId;
    if (id == null) return null;
    final e = _entries[id];
    return e == null ? null : _summaryOf(id, e);
  }

  /// False when the database connection is down (after a short start-up
  /// grace period, so the first connection does not flash a banner).
  bool get online => _connected || (!_everConnected && !_graceOver);

  /// A one-off message for the user, e.g. that access to a feeder ended.
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  void start() {
    _stage = FeederListStage.loading;
    _indexSub = _source
        .watchIndex(uid)
        .listen(
          _onIndex,
          onError: (Object _) {
            _stage = FeederListStage.error;
            _notify();
          },
        );
    _connectedSub = _source.watchConnected().listen((c) {
      _connected = c;
      if (c) _everConnected = true;
      _notify();
    }, onError: (Object _) {});
    _offlineGrace = Timer(const Duration(seconds: 4), () {
      _graceOver = true;
      _notify();
    });
    _source
        .loadLastSelected(uid)
        .then(
          (v) => _saved = v,
          onError: (Object _) => _saved = null, // a preference, not essential
        )
        .whenComplete(() {
          _savedLoaded = true;
          _reselect();
        });
  }

  /// After an error: drop every listener and load again.
  void retry() {
    _cancelAll();
    _indexLoaded = false;
    start();
    _notify();
  }

  /// The user picked a feeder (also used right after creating one, before
  /// the backend's index update arrives).
  void select(String feederId) {
    _pendingId = feederId;
    if (_summaryOf(feederId, _entries[feederId]) != null) {
      _pendingId = null;
      _apply(feederId);
    }
    _notify();
  }

  void _apply(String feederId) {
    if (_selectedId == feederId) return;
    _selectedId = feederId;
    _saved = feederId;
    _lastName = selected?.name; // named in the notice if access ends later
    // Best effort: the rules only accept IDs that are in userFeeders.
    _source.saveLastSelected(uid, feederId).catchError((Object _) {});
  }

  void _onIndex(Map<String, String> index) {
    _indexLoaded = true;
    for (final id in _entries.keys.toList()) {
      if (!index.containsKey(id)) _drop(id);
    }
    index.forEach((id, role) {
      final existing = _entries[id];
      if (existing != null) {
        existing.indexRole = role;
        if (!existing.denied) return;
        _drop(id); // re-added after a removal: listen again
      }
      _watch(id, role);
    });
    _reselect();
  }

  void _watch(String id, String role) {
    final e = _entries[id] = _Entry(role);
    void denied(Object _) {
      e.denied = true;
      _reselect();
    }

    e.subs.add(
      _source.watchMeta(id).listen((m) {
        e.meta = m;
        e.metaLoaded = true;
        _reselect();
      }, onError: denied),
    );
    e.subs.add(
      _source.watchMember(id, uid).listen((m) {
        e.member = m;
        e.memberLoaded = true;
        _reselect();
      }, onError: denied),
    );
  }

  void _drop(String id) {
    final e = _entries.remove(id);
    if (e == null) return;
    for (final s in e.subs) {
      s.cancel();
    }
  }

  FeederSummary? _summaryOf(String id, _Entry? e) {
    if (e == null || e.denied || !e.metaLoaded || !e.memberLoaded) return null;
    return summarize(feederId: id, uid: uid, meta: e.meta, member: e.member);
  }

  /// Re-evaluates the selection after any change.
  void _reselect() {
    if (_disposed) return;
    if (!_indexLoaded || !_savedLoaded) return _notify();
    _stage = FeederListStage.ready;

    final previous = _selectedId;
    final previousName = _lastName;
    final available = feeders.map((f) => f.feederId).toList();

    // While a feeder is still loading, keep the current choice: it may be
    // about to resolve, and dropping it would flash the empty state.
    final current = _selectedId;
    final currentPending =
        current != null &&
        _entries[current] != null &&
        !_entries[current]!.resolved;
    if (currentPending) return _notify();

    if (_pendingId != null && available.contains(_pendingId)) {
      _apply(_pendingId!);
      _pendingId = null;
    } else if (!resolving || _selectedId != null) {
      final next = resolveSelection(
        available: available,
        current: _selectedId,
        saved: _pendingId ?? _saved,
      );
      if (next == null) {
        _selectedId = null;
      } else {
        _apply(next);
      }
    }

    if (previous != null &&
        _selectedId != previous &&
        !available.contains(previous)) {
      _notice =
          'You no longer have access to "${previousName ?? 'the feeder'}".';
    }
    _lastName = selected?.name;
    _notify();
  }

  String? _lastName;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _cancelAll() {
    _indexSub?.cancel();
    _connectedSub?.cancel();
    _offlineGrace?.cancel();
    for (final id in _entries.keys.toList()) {
      _drop(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAll();
    super.dispose();
  }
}
