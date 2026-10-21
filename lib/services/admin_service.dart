import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/format.dart';

/// Privileged actions run in Cloud Functions (Admin SDK). The app only asks;
/// the function checks that the caller is an active administrator.
class AdminService {
  AdminService(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseDatabase _db;

  Future<void> setAdminRole(String uid, bool admin) =>
      _call('setAdminRole', {'uid': uid, 'admin': admin});

  Future<void> suspendUser(String uid, String reason) =>
      _call('suspendUser', {'uid': uid, 'reason': reason});

  Future<void> reactivateUser(String uid) =>
      _call('reactivateUser', {'uid': uid});

  Future<void> _call(String name, Map<String, Object?> data) async {
    try {
      await _functions.httpsCallable(name).call<Object?>(data);
    } on FirebaseFunctionsException catch (e) {
      throw AdminActionException(e.message ?? e.code);
    }
  }

  /// Latest platform audit entries, newest first.
  Stream<List<Map<String, dynamic>>> watchRecentAudit({int limit = 20}) => _db
      .ref('platformAudit')
      .orderByChild('ts')
      .limitToLast(limit)
      .onValue
      .map(
        (e) => e.snapshot.children
            .map((c) => toMap(c.value))
            .toList()
            .reversed
            .toList(),
      );
}

class AdminActionException implements Exception {
  AdminActionException(this.message);
  final String message;
  @override
  String toString() => message;
}
