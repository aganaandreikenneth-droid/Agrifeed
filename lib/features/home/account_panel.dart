import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/widgets/panel.dart';
import '../../core/widgets/text_prompt.dart';

/// Profile summary with name editing and sign-out (shared by user and admin).
class AccountPanel extends StatelessWidget {
  const AccountPanel({super.key});

  Future<void> _editName(
    BuildContext context,
    String uid,
    String current,
  ) async {
    final s = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = await showTextPrompt(
      context,
      title: 'Display name',
      label: 'Name',
      initial: current,
      maxLength: 60,
    );
    if (name == null || name.isEmpty) return;
    try {
      await s.profiles.setDisplayName(uid, name);
      await s.auth.updateDisplayName(name);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save your name.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final user = s.auth.currentUser;
    if (user == null) return const SizedBox.shrink();
    return Column(
      children: [
        StreamBuilder<String?>(
          stream: s.profiles.watchDisplayName(user.uid),
          builder: (context, snap) {
            final name = snap.data ?? user.displayName ?? '';
            return Panel(
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: kField,
                    child: Icon(Icons.person, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? 'AgriFeed user' : name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          user.email ?? '',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit name',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editName(context, user.uid, name),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: s.auth.signOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
