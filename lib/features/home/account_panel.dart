import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/widgets/panel.dart';
import '../../core/widgets/text_prompt.dart';
import '../../design.dart';

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
    final s = AppScope.maybeOf(context); // absent in widget tests
    final user = s?.auth.currentUser;
    if (s == null || user == null) return const SizedBox.shrink();
    return Column(
      children: [
        StreamBuilder<String?>(
          stream: s.profiles.watchDisplayName(user.uid),
          builder: (context, snap) {
            final name = snap.data ?? user.displayName ?? '';
            final shown = name.isEmpty ? 'AgriFeed user' : name;
            return Panel(
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kAmber,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      shown.characters.first.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: kInk,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shown,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: kInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user.email ?? '',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 13,
                          ),
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
          height: 50,
          child: OutlinedButton.icon(
            onPressed: s.auth.signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: kRose,
              side: const BorderSide(color: kRoseSoft, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(25),
              ),
            ),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
