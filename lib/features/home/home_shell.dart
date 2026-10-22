import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_selection.dart';
import '../feeder/create_feeder_dialog.dart';
import '../feeder/feeder_shell.dart';
import '../feeder/feeder_switcher.dart';
import 'account_panel.dart';

/// Owner / member home: loads the user's feeders from `userFeeders/{uid}`
/// and shows, in order of what applies:
///  * loading, or an error with retry;
///  * the selected feeder (one feeder is selected automatically, otherwise
///    the last one used);
///  * onboarding when the user has no feeder;
///  * the feeder list when there are several and none is selected.
/// Access lost while the app is open (removed, left, feeder deleted) moves
/// the user back here with a short message.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.selection});

  /// For tests; normally created here for the signed-in user.
  final FeederSelectionController? selection;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  FeederSelectionController? _owned;
  late FeederSelectionController _selection;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final given = widget.selection;
    if (given != null) {
      _selection = given;
    } else {
      final s = AppScope.of(context);
      _selection = _owned = FeederSelectionController(
        s.feederData,
        s.auth.currentUser!.uid,
      )..start();
    }
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

  Future<void> _create() async {
    final id = await showCreateVirtualFeederDialog(
      context,
      AppScope.of(context).feederActions,
    );
    if (id != null) _selection.select(id);
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
                    'Could not load your feeders. Check the connection and try again.',
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
        final feeders = sel.feeders;
        if (sel.stage == FeederListStage.loading ||
            (feeders.isEmpty && sel.resolving)) {
          return const _ListPage(
            online: true,
            child: Panel(child: Center(child: CircularProgressIndicator())),
          );
        }
        if (sel.selected != null) {
          return FeederShell(selection: sel, onCreate: _create);
        }
        if (feeders.isEmpty) {
          return _ListPage(
            online: sel.online,
            child: NoFeederPanel(onCreate: _create),
          );
        }
        return _ListPage(
          online: sel.online,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose a feeder',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              FeederList(feeders: feeders, onSelect: sel.select),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Create virtual feeder'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Plain page for the states without a selected feeder.
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

class NoFeederPanel extends StatelessWidget {
  const NoFeederPanel({super.key, this.onCreate});

  /// Null disables the button (e.g. while offline in tests).
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HeroIcon(Icons.grain),
          const SizedBox(height: 16),
          const Text(
            'No feeder registered',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: kSoil,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Create a virtual feeder or register a device to continue.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: onCreate,
              child: const Text('Create virtual feeder'),
            ),
          ),
          const SizedBox(height: 10),
          const SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: null,
              child: Text('Register a device'),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'A virtual feeder is simulated and needs no hardware. Physical '
            'devices are registered in the hardware phase. If a farm owner '
            'invites you, their feeder appears here once you join.',
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
