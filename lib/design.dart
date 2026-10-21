import 'dart:math' as math;
import 'package:flutter/material.dart';

// Palette taken from the reference design: cream, white cards, peach, charcoal.
const Color kBg = Color(0xFFF4F1EA);
const Color kBeige = Color(0xFFE6E3D6);
const Color kOrange = Color(0xFFFF9F6B);
const Color kInk = Color(0xFF262626);

/// Hopper level drawn as a ring of rounded blocks (like the calorie gauge).
class SegmentGauge extends StatelessWidget {
  const SegmentGauge({
    super.key,
    required this.fraction,
    required this.color,
    required this.child,
  });

  final double fraction;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.05,
      child: CustomPaint(
        painter: _GaugePainter(fraction, color),
        child: Center(child: child),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.f, this.color);

  final double f;
  final Color color;
  static const int n = 12;
  static const double start = 2.35; // about 135 degrees
  static const double sweep = 4.45; // about 255 degrees

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 26;
    final seg = sweep / n;
    final filled = f <= 0 ? 0 : (f * n).ceil().clamp(1, n);
    for (var i = 0; i < n; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(start + (i + 0.5) * seg);
      final rect = Rect.fromCenter(
        center: Offset(r, 0),
        width: 38,
        height: r * seg - 8,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(11)),
        Paint()..color = i < filled ? color : kBeige,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.f != f || old.color != color;
}

/// White rounded-square icon button used in the header.
class IconBox extends StatelessWidget {
  const IconBox({super.key, required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: kInk, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Dark floating bar with an orange centre button (quick dispense).
class PillNav extends StatelessWidget {
  const PillNav({
    super.key,
    required this.index,
    required this.onTap,
    required this.onCenter,
  });

  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onCenter;

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, int i) => IconButton(
          onPressed: () => onTap(i),
          icon: Icon(
            icon,
            size: 26,
            color: index == i ? Colors.white : Colors.white38,
          ),
        );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Container(
          height: 70,
          decoration: BoxDecoration(
            color: kInk,
            borderRadius: BorderRadius.circular(35),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              item(Icons.home_rounded, 0),
              item(Icons.schedule_rounded, 1),
              GestureDetector(
                onTap: onCenter,
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: kOrange,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Transform.rotate(
                    angle: -math.pi / 12,
                    child: const Icon(Icons.grain, color: Colors.white, size: 28),
                  ),
                ),
              ),
              item(Icons.history_rounded, 2),
              item(Icons.settings_rounded, 3),
            ],
          ),
        ),
      ),
    );
  }
}