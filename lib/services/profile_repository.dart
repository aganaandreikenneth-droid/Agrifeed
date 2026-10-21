import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:firebase_database/firebase_database.dart';

/// `users/{uid}`: display profile only. Email addresses are not copied into the
/// database, and role fields are rejected by the Security Rules.
class ProfileRepository {
  ProfileRepository(this._db);

  final FirebaseDatabase _db;

  DatabaseReference _ref(String uid) => _db.ref('users/$uid');

  /// Creates the profile once. Safe to call on every sign-in.
  Future<void> ensureProfile(String uid, String? displayName) async {
    final ref = _ref(uid);
    if ((await ref.get()).exists) return;
    try {
      await ref.set({
        'displayName': cleanDisplayName(displayName),
        'createdAt': ServerValue.timestamp,
      });
    } on FirebaseException {
      // Another device may have created it first (create-only rule).
      if (!(await ref.get()).exists) rethrow;
    }
  }

  Stream<String?> watchDisplayName(String uid) =>
      _ref(uid)
          .child('displayName')
          .onValue
          .map((e) => e.snapshot.value as String?);

  Future<void> setDisplayName(String uid, String name) =>
      _ref(uid).child('displayName').set(cleanDisplayName(name));
}

String cleanDisplayName(String? name) {
  final n = (name ?? '').trim();
  if (n.isEmpty) return 'AgriFeed user';
  return n.length > 60 ? n.substring(0, 60) : n;
}
