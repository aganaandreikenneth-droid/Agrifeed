import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';

/// Shown when the app refuses to connect (emulator down, production disabled).
/// No Firebase service has been contacted at this point.
class BootBlockedPage extends StatelessWidget {
  const BootBlockedPage({
    super.key,
    required this.title,
    required this.details,
  });

  final String title;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    return NarrowPage(
      children: [
        const HeroIcon(Icons.shield_outlined),
        const SizedBox(height: 20),
        Text(title, style: kTitleStyle),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final d in details)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(d),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Restart the app after fixing the problem.',
          style: TextStyle(color: Colors.black54),
        ),
      ],
    );
  }
}
