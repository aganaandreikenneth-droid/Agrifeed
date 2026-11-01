import 'dart:math' as math;
import 'package:flutter/material.dart';

// Palette from the PoultryPro-style reference: light grey page, white
// cards, amber accent, sky-blue welcome screen, indigo and rose for charts.
const Color kBg = Color(0xFFF6F7FB);
const Color kBeige = Color(0xFFECEEF4); // tracks, chips, quiet panels
const Color kAmber = Color(0xFFF7B731);
const Color kAmberSoft = Color(0xFFFDEFC8);
const Color kBlue = Color(0xFF2B7BB9);
const Color kIndigo = Color(0xFF3F3DB8);
const Color kIndigoSoft = Color(0xFFD4D3F5);
const Color kRose = Color(0xFFE57586);
const Color kRoseSoft = Color(0xFFF9DCE1);
const Color kInk = Color(0xFF1E2230);

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
        elevation: 1,
        shadowColor: Colors.black12,
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

/// White floating bar: the selected tab sits in an amber circle and the
/// centre button (Feeding) is an amber rounded square.
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
    Widget item(IconData icon, int i) {
      final on = index == i;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: on ? kAmber : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 24,
            color: on ? Colors.white : Colors.black38,
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(34),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              item(Icons.home_rounded, 0),
              item(Icons.schedule_rounded, 1),
              GestureDetector(
                onTap: onCenter,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: kInk,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Transform.rotate(
                    angle: -math.pi / 12,
                    child: const Icon(Icons.grain, color: kAmber, size: 26),
                  ),
                ),
              ),
              item(Icons.bar_chart_rounded, 2),
              item(Icons.person_rounded, 3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tall rounded bar with a filled part from the bottom, as in the
/// reference's analytics chart. [fraction] is clamped to 0..1.
class BarMeter extends StatelessWidget {
  const BarMeter({
    super.key,
    required this.fraction,
    required this.color,
    required this.track,
    this.width = 54,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double width;

  @override
  Widget build(BuildContext context) {
    final f = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: f,
        widthFactor: 1,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}
