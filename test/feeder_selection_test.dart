import 'package:agrifeed/services/feeder_actions.dart';
import 'package:agrifeed/services/feeder_selection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_feeder_source.dart';

void main() {
  group('summarize', () {
    Map<String, dynamic> meta({String owner = 'u1', Object? archivedAt}) => {
      'name': 'Coop',
      'ownerUid': owner,
      'mode': 'simulated',
      'archivedAt': ?archivedAt,
    };

    test('an owner holds every permission', () {
      final s = summarize(
        feederId: 'f',
        uid: 'u1',
        meta: meta(),
        member: {'role': 'owner', 'status': 'active'},
      )!;
      expect(s.isOwner, isTrue);
      expect(kFeederPermissions.every(s.can), isTrue);
      expect(s.isVirtual, isTrue);
    });

    test('a member holds only the granted permissions', () {
      final s = summarize(
        feederId: 'f',
        uid: 'u1',
        meta: meta(owner: 'other'),
        member: {
          'role': 'member',
          'status': 'active',
          'permissions': {'viewDashboard': true, 'manualFeed': false},
        },
      )!;
      expect(s.isOwner, isFalse);
      expect(s.can('viewDashboard'), isTrue);
      expect(s.can('manualFeed'), isFalse);
      expect(s.can('viewHistory'), isFalse);
    });

    test(
      'no access: removed, left, expired, missing, or a fake owner record',
      () {
        final cases = <Map<String, dynamic>?>[
          null,
          {'role': 'member', 'status': 'removed'},
          {'role': 'member', 'status': 'left'},
          {'role': 'member', 'status': 'invited'},
          {'role': 'member', 'status': 'active', 'expiresAt': 1000},
          {'role': 'owner', 'status': 'active'}, // meta.ownerUid is 'other'
        ];
        for (final member in cases) {
          expect(
            summarize(
              feederId: 'f',
              uid: 'u1',
              meta: meta(owner: 'other'),
              member: member,
            ),
            isNull,
            reason: '$member',
          );
        }
        expect(
          summarize(
            feederId: 'f',
            uid: 'u1',
            meta: null,
            member: {'role': 'owner', 'status': 'active'},
          ),
          isNull,
        );
      },
    );

    test('mode and archive flags come from meta', () {
      final live = summarize(
        feederId: 'f',
        uid: 'u1',
        meta: {...meta(archivedAt: 5), 'mode': 'live'},
        member: {'role': 'owner', 'status': 'active'},
      )!;
      expect(live.isVirtual, isFalse);
      expect(live.archived, isTrue);
    });
  });

  group('resolveSelection', () {
    test('keeps the current choice while it is available', () {
      expect(
        resolveSelection(available: ['a', 'b'], current: 'b', saved: 'a'),
        'b',
      );
    });
    test('falls back to the saved choice, then the only feeder', () {
      expect(resolveSelection(available: ['a', 'b'], saved: 'b'), 'b');
      expect(resolveSelection(available: ['a'], current: 'gone'), 'a');
    });
    test('several feeders and no valid choice: the first one opens', () {
      expect(
        resolveSelection(available: ['a', 'b'], current: 'x', saved: 'y'),
        'a',
      );
      expect(resolveSelection(available: []), isNull);
    });
  });

  group('FeederSelectionController', () {
    late FakeFeederSource src;
    late FeederSelectionController c;

    Future<void> startWith(String? saved) async {
      src = FakeFeederSource(saved: saved);
      c = FeederSelectionController(src, 'u1')..start();
      await flush();
    }

    tearDown(() => c.dispose());

    test('loading until the index arrives; no feeders means empty', () async {
      await startWith(null);
      expect(c.stage, FeederListStage.loading);
      src.index.add({});
      await flush();
      expect(c.stage, FeederListStage.ready);
      expect(c.feeders, isEmpty);
      expect(c.selected, isNull);
    });

    test('a single feeder is selected automatically and remembered', () async {
      await startWith(null);
      src.index.add({'fA': 'owner'});
      src.feeder('fA', name: 'Coop A');
      await flush();
      expect(c.selected?.feederId, 'fA');
      expect(c.selected?.isVirtual, isTrue);
      expect(src.savedWrites, ['fA']);
    });

    test(
      'several feeders: the saved one is selected, else the first owned',
      () async {
        await startWith('fB');
        src.index.add({'fA': 'owner', 'fB': 'member'});
        src.feeder('fA');
        src.feeder('fB', owner: false);
        await flush();
        expect(c.selected?.feederId, 'fB');

        c.dispose();
        await startWith('stale');
        src.index.add({'fA': 'owner', 'fB': 'member'});
        src.feeder('fA');
        src.feeder('fB', owner: false);
        await flush();
        expect(c.selected?.feederId, 'fA');
        expect(c.feeders.map((f) => f.feederId), ['fA', 'fB']); // owned first
      },
    );

    test('switching feeders', () async {
      await startWith('fA');
      src.index.add({'fA': 'owner', 'fB': 'owner'});
      src.feeder('fA', name: 'A');
      src.feeder('fB', name: 'B');
      await flush();
      c.select('fB');
      expect(c.selected?.name, 'B');
      expect(c.takeNotice(), isNull);
    });

    test('removal while open: access ends, a notice explains it, '
        'and the remaining feeder is selected', () async {
      await startWith('fM');
      src.index.add({'fA': 'owner', 'fM': 'member'});
      src.feeder('fA', name: 'Mine');
      src.feeder('fM', name: 'Theirs', owner: false);
      await flush();
      expect(c.selected?.feederId, 'fM');

      // The backend writes the revocation marker; the rules then deny meta.
      src.member('fM').add({'role': 'member', 'status': 'removed'});
      src.meta('fM').addError(Exception('permission-denied'));
      await flush();
      expect(c.selected?.feederId, 'fA');
      expect(c.takeNotice(), contains('Theirs'));

      src.index.add({'fA': 'owner'}); // index entry removed too
      await flush();
      expect(c.feeders.map((f) => f.feederId), ['fA']);
      expect(c.takeNotice(), isNull);
    });

    test('feeder deleted while open: back to the empty state', () async {
      await startWith(null);
      src.index.add({'fA': 'owner'});
      src.feeder('fA', name: 'Gone soon');
      await flush();
      src.meta('fA').add(null);
      await flush();
      expect(c.selected, isNull);
      expect(c.takeNotice(), contains('Gone soon'));
      src.index.add({});
      await flush();
      expect(c.feeders, isEmpty);
    });

    test('permission changes apply live', () async {
      await startWith(null);
      src.index.add({'fM': 'member'});
      src.feeder('fM', owner: false, permissions: {'viewDashboard': true});
      await flush();
      expect(c.selected!.can('viewHistory'), isFalse);
      src.member('fM').add({
        'role': 'member',
        'status': 'active',
        'permissions': {'viewDashboard': true, 'viewHistory': true},
      });
      await flush();
      expect(c.selected!.can('viewHistory'), isTrue);
    });

    test(
      'a feeder created in the app is selected once the backend lists it',
      () async {
        await startWith('fA');
        src.index.add({'fA': 'owner'});
        src.feeder('fA');
        await flush();
        c.select('fNew');
        expect(c.selected?.feederId, 'fA'); // not listed yet
        src.index.add({'fA': 'owner', 'fNew': 'owner'});
        src.feeder('fNew', name: 'New');
        await flush();
        expect(c.selected?.feederId, 'fNew');
        expect(c.takeNotice(), isNull);
      },
    );

    test('an index error shows the error state; retry reloads', () async {
      await startWith(null);
      src.index.addError(Exception('denied'));
      await flush();
      expect(c.stage, FeederListStage.error);
      c.retry();
      expect(c.stage, FeederListStage.loading);
      src.index.add({});
      await flush();
      expect(c.stage, FeederListStage.ready);
    });

    test('connection loss is reported', () async {
      await startWith(null);
      src.connected.add(true);
      await flush();
      expect(c.online, isTrue);
      src.connected.add(false);
      await flush();
      expect(c.online, isFalse);
    });
  });

  group('describeFunctionsError', () {
    test('connection problems get a plain explanation, never a bare code', () {
      for (final code in ['unavailable', 'deadline-exceeded', 'internal']) {
        expect(
          describeFunctionsError(code, code.toUpperCase()),
          'Could not reach the server. Check the connection and try again.',
        );
      }
      expect(
        describeFunctionsError('failed-precondition', 'FAILED_PRECONDITION'),
        'Something went wrong. Try again.',
      );
    });
    test('messages the backend wrote for users are kept', () {
      const limit = 'You can own up to 3 virtual feeders.';
      expect(describeFunctionsError('resource-exhausted', limit), limit);
    });
  });
}
