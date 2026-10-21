import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../core/format.dart';
import 'profile_repository.dart';

enum SessionStage {
  loading,
  signedOut,
  unverified,
  suspended,
  admin,
  user,
  error,
}

class SessionState {
  const SessionState(this.stage, {this.message});

  final SessionStage stage;

  /// Suspension reason or error description, when relevant.
  final String? message;
}

/// Pure routing decision, kept separate so it can be unit tested.
///
/// [suspended] and [profileReady] are null while still being loaded.
SessionState resolveSession({
  required bool signedIn,
  required bool emailVerified,
  required bool? suspended,
  required bool isAdmin,
  required bool? profileReady,
  String? suspendReason,
  String? error,
}) {
  if (!signedIn) return const SessionState(SessionStage.signedOut);
  if (!emailVerified) return const SessionState(SessionStage.unverified);
  if (error != null) return SessionState(SessionStage.error, message: error);
  if (suspended == null) return const SessionState(SessionStage.loading);
  if (suspended) {
    return SessionState(SessionStage.suspended, message: suspendReason);
  }
  if (profileReady != true) return const SessionState(SessionStage.loading);
  return SessionState(isAdmin ? SessionStage.admin : SessionStage.user);
}

/// Combines Firebase Auth, the ID-token claims and `accountStatus/{uid}`.
///
/// Order matters for the Security Rules:
///  1. unverified accounts never touch the database;
///  2. after verification the ID token is refreshed so `email_verified` is true;
///  3. the account status is read before the profile is created, because the
///     rules reject profile writes from suspended accounts.
class SessionController extends ChangeNotifier {
  SessionController(this._auth, this._db, this._profiles);

  final FirebaseAuth _auth;
  final FirebaseDatabase _db;
  final ProfileRepository _profiles;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<DatabaseEvent>? _statusSub;
  int _generation = 0;

  bool _signedIn = false;
  bool _emailVerified = false;
  bool? _suspended;
  String? _suspendReason;
  bool _isAdmin = false;
  bool? _profileReady;
  String? _error;
  Object? _claimsStamp;

  SessionState get state => resolveSession(
    signedIn: _signedIn,
    emailVerified: _emailVerified,
    suspended: _suspended,
    isAdmin: _isAdmin,
    profileReady: _profileReady,
    suspendReason: _suspendReason,
    error: _error,
  );

  bool _started = false;
  bool get started => _started;

  void start() {
    _started = true;
    // authStateChanges (not userChanges): forcing a token refresh below must
    // not re-trigger this listener.
    _authSub = _auth.authStateChanges().listen((u) => _load(u));
  }

  /// Re-evaluates the current user, e.g. after the email was verified.
  Future<void> refresh() => _load(_auth.currentUser);

  Future<void> _load(User? user) async {
    final gen = ++_generation;
    await _statusSub?.cancel();
    _statusSub = null;
    _suspended = null;
    _suspendReason = null;
    _profileReady = null;
    _isAdmin = false;
    _error = null;
    _claimsStamp = null;
    _signedIn = user != null;
    _emailVerified = user?.emailVerified ?? false;
    notifyListeners();
    if (user == null || !user.emailVerified) return;

    try {
      final token = await user.getIdTokenResult(true);
      if (gen != _generation) return;
      _emailVerified = token.claims?['email_verified'] == true;
      _isAdmin = token.claims?['admin'] == true;
      if (!_emailVerified) {
        notifyListeners();
        return;
      }
    } catch (e) {
      if (gen != _generation) return;
      _error =
          'Could not refresh your session. Check the connection and try again.';
      notifyListeners();
      return;
    }

    _statusSub = _db
        .ref('accountStatus/${user.uid}')
        .onValue
        .listen(
          (event) => _onStatus(gen, user, toMap(event.snapshot.value)),
          onError: (Object e) {
            if (gen != _generation) return;
            _error = 'Could not load your account status.';
            notifyListeners();
          },
        );
  }

  Future<void> _onStatus(
    int gen,
    User user,
    Map<String, dynamic> status,
  ) async {
    if (gen != _generation) return;
    _suspended = status['suspended'] == true;
    _suspendReason = status['reason'] as String?;

    // The backend bumps claimsUpdatedAt after changing roles.
    final stamp = status['claimsUpdatedAt'];
    if (_claimsStamp != null && stamp != _claimsStamp) {
      try {
        final token = await user.getIdTokenResult(true);
        if (gen != _generation) return;
        _isAdmin = token.claims?['admin'] == true;
      } catch (_) {}
    }
    _claimsStamp = stamp ?? 0;

    if (!_suspended! && _profileReady != true) {
      try {
        await _profiles.ensureProfile(user.uid, user.displayName);
        if (gen != _generation) return;
        _profileReady = true;
      } catch (e) {
        if (gen != _generation) return;
        _error = 'Could not create your profile.';
      }
    }
    notifyListeners();
  }

  void clearErrorAndRetry() {
    _error = null;
    refresh();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
