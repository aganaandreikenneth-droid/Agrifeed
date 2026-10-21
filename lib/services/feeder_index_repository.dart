import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:firebase_database/firebase_database.dart';

import '../core/format.dart';

class FeederLink {
  const FeederLink({required this.feederId, required this.role, this.name});

  final String feederId;
  final String role;
  final String? name;
}

/// Reads `userFeeders/{uid}`: the feeders the signed-in user owns or was
/// invited to. Feeder IDs always come from the database, never from code.
class FeederIndexRepository {
  FeederIndexRepository(this._db);

  final FirebaseDatabase _db;

  Stream<List<FeederLink>> watchMyFeeders(String uid) =>
      _db.ref('userFeeders/$uid').onValue.asyncMap((e) async {
        final links = <FeederLink>[];
        for (final c in e.snapshot.children) {
          final id = c.key!;
          String? name;
          try {
            name =
                (await _db.ref('feeders/$id/meta/name').get()).value as String?;
          } on FirebaseException {
            name = null; // membership may have just been removed
          }
          links.add(
            FeederLink(
              feederId: id,
              role: (toMap(c.value)['role'] as String?) ?? 'member',
              name: name,
            ),
          );
        }
        return links;
      });
}
