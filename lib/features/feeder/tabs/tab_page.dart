import 'package:flutter/material.dart';

import '../../../core/widgets/panel.dart';
import '../../../design.dart';
import '../feeder_scope.dart';
import '../feeder_badge.dart';

/// A feeder tab: a title and its panels, shown when the user holds at least
/// one of [allowedIf] (owners hold all; empty means everyone), otherwise an
/// explanation. The Security Rules enforce the same permissions.
class FeederTabPage extends StatelessWidget {
  const FeederTabPage({
    super.key,
    required this.title,
    required this.children,
    this.allowedIf = const [],
    this.header,
    this.subtitle,
  });

  final String title;

  /// One line under the title.
  final String? subtitle;

  /// Replaces the plain [title] heading when given.
  final Widget? header;
  final List<String> allowedIf;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final feeder = FeederScope.of(context).feeder;
    final allowed = allowedIf.isEmpty || allowedIf.any(feeder.can);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        header ??
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: kInk,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: Colors.black45,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        if (allowed)
          ...children
        else
          Panel(
            child: Text(
              "You don't have permission to view this for ${feeder.name}.",
              key: const ValueKey('no-permission'),
            ),
          ),
      ],
    );
  }
}

/// Small heading between the panels of a tab.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 16,
          color: kInk,
        ),
      ),
    );
  }
}

/// A feature that is not built yet: says which milestone brings it and
/// never shows sample numbers.
class PlannedPanel extends StatelessWidget {
  const PlannedPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.milestone,
    required this.body,
  });

  final IconData icon;
  final String title;
  final int milestone;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: kInk,
                          ),
                        ),
                      ),
                      FeederBadge('MILESTONE $milestone', color: kGrain),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Amber rounded-square icon used at the start of cards and rows.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color = kAmberSoft});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: kGrain, size: 22),
    );
  }
}
