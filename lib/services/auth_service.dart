import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

// Firebase console > Authentication > Sign-in method > Google > Web SDK configuration > Web client ID
const String googleServerClientId =
    '467162433407-gb83a7hhqup1ao2nfiokphmmbne8dlki.apps.googleusercontent.com';
const bool gmailOnly = false; // set to true to accept only @gmail.com addresses
const int minNewPasswordLength = 8;

/// Thin wrapper around Firebase Auth so screens can be tested with a fake.
class AuthService {
  AuthService(this._auth);

  final FirebaseAuth _auth;

  User? get currentUser => _auth.currentUser;

  Future<void> signIn(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  /// Creates the account and sends the verification email. The database
  /// profile is created later, after the email is verified (see SessionController).
  Future<void> register(String name, String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await cred.user?.updateDisplayName(name);
    try {
      await cred.user?.sendEmailVerification();
    } catch (_) {
      // The verify screen offers "Resend email".
    }
  }

  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      await _auth.signInWithPopup(GoogleAuthProvider());
      return;
    }
    final googleUser = await GoogleSignIn.instance.authenticate();
    final idToken = googleUser.authentication.idToken;
    if (idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-id-token',
        message: 'Google did not return an ID token.',
      );
    }
    await _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email);

  Future<void> resendVerification() async =>
      _auth.currentUser?.sendEmailVerification();

  /// Reloads the user and, once verified, forces a new ID token so that the
  /// `email_verified` claim seen by the Security Rules is up to date.
  Future<bool> reloadAndCheckVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    await user.reload();
    final fresh = _auth.currentUser;
    if (fresh == null || !fresh.emailVerified) return false;
    await fresh.getIdToken(true);
    return true;
  }

  Future<void> updateDisplayName(String name) async =>
      _auth.currentUser?.updateDisplayName(name);

  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    await _auth.signOut();
  }
}

String friendlyAuthError(FirebaseAuthException e) {
  switch (e.code) {
    case 'invalid-credential':
    case 'user-not-found':
    case 'wrong-password':
      return 'Email or password is incorrect. New here? Tap "Create account".';
    case 'email-already-in-use':
      return 'This email already has an account. Please sign in instead.';
    case 'weak-password':
      return 'Password is too weak. Use at least $minNewPasswordLength characters.';
    case 'invalid-email':
      return 'That email address does not look right.';
    case 'user-disabled':
      return 'This account has been suspended. Contact the AgriFeed administrator.';
    case 'too-many-requests':
      return 'Too many attempts. Please wait a moment and try again.';
    case 'network-request-failed':
      return 'No connection to the server.';
    default:
      return e.message ?? e.code;
  }
}

/// Returns an error message, or null when the form is valid.
String? validateAuthForm({
  required bool creating,
  required String name,
  required String email,
  required String password,
  required String confirm,
}) {
  if (creating && name.trim().isEmpty) return 'Please enter your name.';
  if (creating && name.trim().length > 60) {
    return 'Name must be 60 characters or fewer.';
  }
  final e = email.trim();
  if (e.isEmpty || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
    return 'Please type a valid email address.';
  }
  if (creating && gmailOnly && !e.toLowerCase().endsWith('@gmail.com')) {
    return 'Please use your Gmail address (name@gmail.com).';
  }
  if (password.isEmpty) return 'Please enter your password.';
  if (creating && password.length < minNewPasswordLength) {
    return 'Password must be at least $minNewPasswordLength characters.';
  }
  if (creating && password != confirm) return 'Passwords do not match.';
  return null;
}
