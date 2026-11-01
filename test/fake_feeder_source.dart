import 'dart:async';

import 'package:agrifeed/services/feeder_live.dart';
import 'package:agrifeed/services/feeder_repository.dart';
import 'package:agrifeed/services/feeder_selection.dart';

/// One database location: like an RTDB `onValue` listener, every new
/// subscriber first receives the current value (or the rules denial), then
/// each change.
class FakeLocation<T> {
  final _changes = StreamController<T>.broadcast();
  bool _has = false;
  T? _value;
  Object? _error;

  void add(T value) {
    _has = true;
    _value = value;
    _error = null;
    _changes.add(value);
  }

  /// E.g. permission-denied: the listener is refused.
  void addError(Object error) {
    _error = error;
    _changes.addError(error);
  }

  Stream<T> get stream async* {
    if (_error != null) throw _error!;
    if (_has) yield _value as T;
    yield* _changes.stream;
  }
}

/// In-memory stand-in for the database paths the feeder selection reads.
class FakeFeederSource implements FeederDataSource {
  FakeFeederSource({this.saved});

  String? saved;
  final savedWrites = <String>[];
  final index = FakeLocation<Map<String, String>>();
  final connected = FakeLocation<bool>();
  final _meta = <String, FakeLocation<Map<String, dynamic>?>>{};
  final _member = <String, FakeLocation<Map<String, dynamic>?>>{};

  FakeLocation<Map<String, dynamic>?> meta(String id) =>
      _meta.putIfAbsent(id, FakeLocation.new);
  FakeLocation<Map<String, dynamic>?> member(String id) =>
      _member.putIfAbsent(id, FakeLocation.new);

  @override
  Stream<Map<String, String>> watchIndex(String uid) => index.stream;
  @override
  Stream<Map<String, dynamic>?> watchMeta(String feederId) =>
      meta(feederId).stream;
  @override
  Stream<Map<String, dynamic>?> watchMember(String feederId, String uid) =>
      member(feederId).stream;
  @override
  Stream<bool> watchConnected() => connected.stream;
  @override
  Future<String?> loadLastSelected(String uid) async => saved;
  @override
  Future<void> saveLastSelected(String uid, String feederId) async =>
      savedWrites.add(feederId);

  /// Emits a complete, accessible feeder for user 'u1'.
  void feeder(
    String id, {
    String name = 'Coop',
    bool owner = true,
    String mode = 'simulated',
    Map<String, bool> permissions = const {'viewDashboard': true},
    bool archived = false,
    String timezone = 'Asia/Manila',
  }) {
    meta(id).add({
      'name': name,
      'timezone': timezone,
      'ownerUid': owner ? 'u1' : 'someone',
      'mode': mode,
      if (archived) 'archivedAt': 1,
    });
    member(id).add({
      'role': owner ? 'owner' : 'member',
      'status': 'active',
      if (!owner) 'permissions': permissions,
    });
  }
}

/// Lets queued stream events and futures run.
Future<void> flush() => Future<void>.delayed(Duration.zero);

/// In-memory [FeederRepository]: alerts per feeder, and a log of writes.
class FakeFeederRepository implements FeederRepository {
  final writes = <String>[];
  final _alerts = <String, FakeLocation<List<FeederAlert>>>{};

  /// Set to make the next write fail like a rules denial.
  Object? failWith;

  FakeLocation<List<FeederAlert>> alerts(String id) =>
      _alerts.putIfAbsent(id, FakeLocation.new);

  @override
  Stream<List<FeederAlert>> watchAlerts(String feederId) =>
      alerts(feederId).stream;

  Future<void> _write(String entry) async {
    if (failWith != null) throw failWith!;
    writes.add(entry);
  }

  @override
  Future<void> rename(String feederId, String name) =>
      _write('name:$feederId:$name');

  @override
  Future<void> setTimezone(String feederId, String timezone) =>
      _write('timezone:$feederId:$timezone');
}

/// In-memory [FeederLive]: one [FakeLocation] per absolute path, and a log
/// of every update the app sends.
class FakeFeederLive implements FeederLive {
  final updates = <Map<String, Object?>>[];
  final _paths = <String, FakeLocation<Object?>>{};
  var _keys = 0;

  FakeLocation<Object?> at(String path) =>
      _paths.putIfAbsent(path, FakeLocation.new);

  @override
  Stream<Object?> watch(String path, {String? orderBy, int? last}) =>
      at(path).stream;

  @override
  Future<void> update(Map<String, Object?> values) async => updates.add(values);

  @override
  String newKey(String path) => 'k${_keys++}';

  @override
  Object get now => 0;
}
