import 'dart:async';

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
  }) {
    meta(id).add({
      'name': name,
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
