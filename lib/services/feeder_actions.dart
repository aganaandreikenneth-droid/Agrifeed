import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

/// Feeder operations that only the backend may perform (Cloud Functions).
/// The app asks; the function checks the caller, the input and the limits.
class FeederActions {
  FeederActions(this._functions);

  final FirebaseFunctions _functions;

  /// Registers a virtual (simulated) feeder owned by the caller and returns
  /// its ID. [requestId] makes a retry of the same request return the same
  /// feeder instead of creating a second one.
  Future<String> createVirtualFeeder({
    required String name,
    required String timezone,
    required String requestId,
  }) async {
    final data = await _call('createVirtualFeeder', {
      'name': name,
      'timezone': timezone,
      'requestId': requestId,
    });
    return data['feederId'] as String;
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      final result = await _functions.httpsCallable(name).call<Object?>(data);
      final value = result.data;
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } on FirebaseFunctionsException catch (e) {
      throw FeederActionException(describeFunctionsError(e.code, e.message));
    }
  }
}

/// Connection problems get a plain explanation; errors the backend raised on
/// purpose (limits, validation, permissions) keep their message, which is
/// written for users.
String describeFunctionsError(String code, String? message) {
  switch (code) {
    case 'unavailable':
    case 'deadline-exceeded':
    case 'internal':
    case 'unknown':
      return 'Could not reach the server. Check the connection and try again.';
    case 'unauthenticated':
      return 'Your session has expired. Sign in again.';
  }
  final m = message?.trim() ?? '';
  // The plugin falls back to the bare code (e.g. "UNAVAILABLE") as message.
  if (m.isEmpty || m.toUpperCase() == m) {
    return 'Something went wrong. Try again.';
  }
  return m;
}

class FeederActionException implements Exception {
  FeederActionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A random idempotency key (matches the backend's [A-Za-z0-9_-]{8,64}).
String newRequestId() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final r = Random.secure();
  return List.generate(22, (_) => chars[r.nextInt(chars.length)]).join();
}
