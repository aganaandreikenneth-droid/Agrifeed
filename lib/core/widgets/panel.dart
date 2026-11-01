import 'package:flutter/material.dart';

import '../../design.dart';

const Color kField = kAmber; // accent
const Color kGrain = Color(0xFFD9931A); // deeper amber for icons and text
const Color kSoil = kInk; // charcoal

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: color == null
            ? const [
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}

/// Amber rounded-square icon used at the top of the auth screens.
class HeroIcon extends StatelessWidget {
  const HeroIcon(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kField,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Icon(icon, color: Colors.white, size: 32),
    );
  }
}

/// Centered, width-limited scroll column shared by the auth and status screens.
class NarrowPage extends StatelessWidget {
  const NarrowPage({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const TextStyle kTitleStyle = TextStyle(
  fontSize: 30,
  fontWeight: FontWeight.w800,
  color: kSoil,
);
