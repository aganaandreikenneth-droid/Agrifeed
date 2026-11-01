import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_live.dart';
import '../../services/feeder_repository.dart';
import '../../services/feeder_selection.dart';
import '../feeder/feeder_shell.dart';
import 'account_panel.dart';

/// Feeder owner home. AgriFeed has one machine per account: after sign-in
/// the feeder assigned in `userFeeders/{uid}` (written only by the backend)
/// opens directly. Shows, in order of what applies:
///  * loading, or an error with retry;
///  * the feeder (Home, Feeding, Activity, Settings);
///  * a notice when no machine is assigned to the account.
/// Access lost while the app is open moves the user back here with a short
/// message.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    this.selection,
    this.feeders,
    this.live,
    this.uid,
  });

  /// For tests; normally created here for the signed-in user.
  final FeederSelectionController? selection;

  /// For tests; normally taken from [AppScope].
  final FeederRepository? feeders;

  /// For tests; normally taken from [AppScope].
  final FeederLive? live;

  /// For tests; normally the signed-in user.
  final String? uid;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  FeederSelectionController? _owned;
  late FeederSelectionController _selection;
  late FeederRepository _feeders;
  late FeederLive _live;
  late String _uid;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final s = AppScope.maybeOf(context);
    final given = widget.selection;
    if (given != null) {
      _selection = given;
    } else {
      _selection = _owned = FeederSelectionController(
        s!.feederData,
        s.auth.currentUser!.uid,
      )..start();
    }
    _feeders = widget.feeders ?? s!.feeders;
    _live = widget.live ?? s!.live;
    _uid = widget.uid ?? s!.auth.currentUser!.uid;
    _selection.addListener(_showNotice);
  }

  @override
  void dispose() {
    _selection.removeListener(_showNotice);
    _owned?.dispose();
    super.dispose();
  }

  void _showNotice() {
    final notice = _selection.takeNotice();
    if (notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(notice)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final sel = _selection;
        if (sel.stage == FeederListStage.error) {
          return _ListPage(
            online: sel.online,
            child: Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Could not load your feeder. Check the connection and try again.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: sel.retry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        if (sel.stage == FeederListStage.loading ||
            (sel.selected == null && sel.resolving)) {
          return const _ListPage(
            online: true,
            child: Panel(child: Center(child: CircularProgressIndicator())),
          );
        }
        if (sel.selected != null) {
          return FeederShell(
            selection: sel,
            feeders: _feeders,
            live: _live,
            uid: _uid,
          );
        }
        return _ListPage(online: sel.online, child: const NoFeederPanel());
      },
    );
  }
}

/// Plain page for the states without a feeder.
class _ListPage extends StatelessWidget {
  const _ListPage({required this.child, required this.online});

  final Widget child;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: const IconBox(icon: Icons.egg_alt_outlined),
        title: const Text(
          'AgriFeed',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!online) ...[
            const Panel(
              color: kBeige,
              child: Text('Offline. Waiting for the connection to return.'),
            ),
            const SizedBox(height: 12),
          ],
          child,
          const SizedBox(height: 16),
          const AccountPanel(),
        ],
      ),
    );
  }
}

/// No machine is assigned to this account. Assignment is done by the
/// backend only (never from the app), so there is nothing to press here.
class NoFeederPanel extends StatelessWidget {
  const NoFeederPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HeroIcon(Icons.grain),
          const SizedBox(height: 16),
          const Text(
            'No AgriFeed machine yet',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: kSoil,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'No AgriFeed machine is assigned to this account yet.',
            key: ValueKey('no-feeder-assigned'),
          ),
          const SizedBox(height: 10),
          Text(
            'Once your machine is assigned to you, it opens here '
            'automatically.',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.55),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
