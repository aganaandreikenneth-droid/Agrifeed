import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';

class SuspendedPage extends StatelessWidget {
  const SuspendedPage({super.key, this.reason, required this.onSignOut});

  final String? reason;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return NarrowPage(
      children: [
        const HeroIcon(Icons.block),
        const SizedBox(height: 20),
        const Text('Account suspended', style: kTitleStyle),
        const SizedBox(height: 8),
        const Text(
          'Access to AgriFeed has been suspended for this account. Contact the AgriFeed administrator to restore access.',
        ),
        if (reason != null && reason!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Panel(child: Text('Reason: $reason')),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: OutlinedButton.icon(
            onPressed: onSignOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ),
      ],
    );
  }
}

class SessionErrorPage extends StatelessWidget {
  const SessionErrorPage({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onSignOut,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return NarrowPage(
      children: [
        const HeroIcon(Icons.cloud_off),
        const SizedBox(height: 20),
        const Text('Something went wrong', style: kTitleStyle),
        const SizedBox(height: 8),
        Text(message),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: onSignOut,
            child: const Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
