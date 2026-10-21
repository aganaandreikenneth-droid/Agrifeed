import 'dart:io';

/// Returns a description for every emulator service that does not accept a
/// TCP connection. An empty list means all services are reachable.
Future<List<String>> unreachablePorts(
  String host,
  Map<String, int> ports,
) async {
  final failures = <String>[];
  for (final e in ports.entries) {
    try {
      final s = await Socket.connect(
        host,
        e.value,
        timeout: const Duration(seconds: 3),
      );
      s.destroy();
    } catch (_) {
      failures.add('${e.key} emulator at $host:${e.value}');
    }
  }
  return failures;
}
