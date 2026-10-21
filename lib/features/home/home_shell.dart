import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_index_repository.dart';
import 'account_panel.dart';

/// Owner / member home for the Phase 1 build.
///
/// Feeders are listed from `userFeeders/{uid}`. The feeder screens (dashboard,
/// schedule, history, settings) are reconnected to the selected feeder in
/// Phase 2; until then no legacy `feeder1` listener is started.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final uid = s.auth.currentUser!.uid;
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
          StreamBuilder<List<FeederLink>>(
            stream: s.feeders.watchMyFeeders(uid),
            builder: (context, snap) {
              if (snap.hasError) {
                return const Panel(
                  child: Text(
                    'Could not load your feeders. Check the connection and try again.',
                  ),
                );
              }
              if (!snap.hasData) {
                return const Panel(
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final feeders = snap.data!;
              return feeders.isEmpty
                  ? const NoFeederPanel()
                  : FeederListPanel(feeders: feeders);
            },
          ),
          const SizedBox(height: 16),
          const AccountPanel(),
        ],
      ),
    );
  }
}

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
          const SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: null,
              child: Text('Create virtual feeder'),
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
            'Feeder registration is not available yet in this development build. '
            'Virtual feeders arrive in Phase 2; physical devices in the hardware phase. '
            'If a farm owner invites you, their feeder will appear here.',
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

class FeederListPanel extends StatelessWidget {
  const FeederListPanel({super.key, required this.feeders});

  final List<FeederLink> feeders;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your feeders',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final f in feeders)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.memory, color: kGrain),
              title: Text(f.name ?? 'Unnamed feeder'),
              subtitle: Text(f.role == 'owner' ? 'Owner' : 'Member'),
            ),
          const SizedBox(height: 4),
          const Text(
            'Feeder dashboards connect to the selected feeder in Phase 2.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
