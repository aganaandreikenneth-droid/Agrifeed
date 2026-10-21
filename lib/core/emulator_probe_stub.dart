/// Web builds cannot open raw sockets, so the emulator cannot be verified
/// before connecting. Report it as unavailable instead of guessing.
Future<List<String>> unreachablePorts(
  String host,
  Map<String, int> ports,
) async => [
  'Emulator check is not supported on web in Phase 1. Use Android or desktop.',
];
