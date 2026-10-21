Map<String, dynamic> toMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String two(int n) => n.toString().padLeft(2, '0');

String fmtTs(Object? ts) {
  if (ts is! num) return '--';
  final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
  return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

String ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String weightLabel(double g) =>
    g >= 1000 ? '${(g / 1000).toStringAsFixed(2)} kg' : '${g.round()} g';
