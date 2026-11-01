import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../../services/feeder_live.dart';
import 'feeder_scope.dart';
import 'live_values.dart';

/// The controller should answer a calibration step within this time.
const kCalibrationAckTimeout = Duration(seconds: 20);

/// Load cell calibration from the app (owner, real feeders): set the zero
/// with the empty hopper, then calibrate with a known weight. The app only
/// writes `calibration/request`; the controller does the work on the scale
/// and reports in `calibration/state` and `config/calibrationStatus`.
class CalibrationPanel extends StatelessWidget {
  const CalibrationPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveValues(
      queries: const {
        'state': LiveQuery('calibration/state'),
        'status': LiveQuery('status'),
        'telemetry': LiveQuery('telemetry/current'),
        'config': LiveQuery('config'),
      },
      tick: const Duration(seconds: 1),
      builder: (context, v) => _CalibrationBody(
        report: CalibrationReport.from(v['state']),
        reading: FeederReading.from(
          status: v['status'],
          telemetry: v['telemetry'],
          config: v['config'],
        ),
      ),
    );
  }
}

class _CalibrationBody extends StatefulWidget {
  const _CalibrationBody({required this.report, required this.reading});

  final CalibrationReport report;
  final FeederReading reading;

  @override
  State<_CalibrationBody> createState() => _CalibrationBodyState();
}

class _CalibrationBodyState extends State<_CalibrationBody> {
  final _known = TextEditingController(text: '500');
  String? _sentId;
  String? _sentAction;
  DateTime? _sentAt;
  bool _sending = false;

  @override
  void dispose() {
    _known.dispose();
    super.dispose();
  }

  bool get _waiting =>
      _sentId != null && widget.report.lastRequestId != _sentId;

  bool get _noResponse =>
      _waiting && DateTime.now().difference(_sentAt!) > kCalibrationAckTimeout;

  double? get _knownG {
    final g = double.tryParse(_known.text.trim());
    return g == null || g < 1 || g > 5000 ? null : g;
  }

  Future<void> _send(String action) async {
    final controls = FeederScope.of(context).controls;
    setState(() => _sending = true);
    try {
      final id = await controls.calibrate(
        action,
        knownG: action == 'calibrate' ? _knownG : null,
      );
      setState(() {
        _sentId = id;
        _sentAction = action;
        _sentAt = DateTime.now();
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The calibration request was refused.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FeederScope.of(context);
    final r = widget.reading;
    final online = r.online();
    final String? blocked = !scope.feeder.isOwner
        ? 'Only the owner can calibrate the scale.'
        : scope.feeder.archived
        ? 'The feeder is archived.'
        : !scope.online
        ? 'You are offline.'
        : !online
        ? 'The controller is offline, so it cannot calibrate now.'
        : null;
    final busy = _sending || (_waiting && !_noResponse);
    final canSend = blocked == null && !busy;

    // Result of our last request (or "waiting").
    Widget? result;
    final rep = widget.report;
    if (_noResponse) {
      result = _ResultLine(
        icon: Icons.portable_wifi_off_rounded,
        color: kRose,
        text: 'No response from the feeder. Nothing was changed; try again.',
      );
    } else if (_waiting) {
      result = const _ResultLine(
        icon: Icons.hourglass_top_rounded,
        color: kGrain,
        text: 'Waiting for the feeder...',
      );
    } else if (_sentId != null && rep.lastRequestId == _sentId) {
      result = rep.result == 'done'
          ? _ResultLine(
              icon: Icons.check_circle_rounded,
              color: const Color(0xFF34B36B),
              text: _sentAction == 'tare'
                  ? 'Zero set. Now put the known weight in the hopper.'
                  : 'Calibrated. The hopper weight is now in real grams.',
            )
          : _ResultLine(
              icon: Icons.cancel_outlined,
              color: kRose,
              text: 'Refused: ${rep.reason ?? 'the feeder did not accept it.'}',
            );
    }

    final reading = r.shownWeightG;
    return Panel(
      key: const ValueKey('calibration-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                r.calibrated ? Icons.verified_rounded : Icons.scale_outlined,
                color: r.calibrated ? const Color(0xFF34B36B) : kGrain,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r.calibrated ? 'Scale calibrated' : 'Scale not calibrated',
                  key: const ValueKey('calibration-status'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              if (reading != null)
                Text(
                  'Reading: ${weightLabel(reading)}',
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '1. Empty the hopper (leave it mounted on the scale), then tap '
            'Set zero.',
            style: TextStyle(fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('cal-tare'),
            onPressed: canSend ? () => _send('tare') : null,
            icon: const Icon(Icons.exposure_zero_rounded),
            label: const Text('Set zero'),
          ),
          const SizedBox(height: 14),
          const Text(
            '2. Put something of known weight in the hopper (for example a '
            'sealed 500 g bag), enter its weight and tap Calibrate.',
            style: TextStyle(fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('cal-known'),
                  controller: _known,
                  enabled: blocked == null,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Known weight',
                    suffixText: 'g',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('cal-calibrate'),
                  onPressed: canSend && _knownG != null
                      ? () => _send('calibrate')
                      : null,
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Calibrate'),
                ),
              ),
            ],
          ),
          if (result != null) ...[const SizedBox(height: 12), result],
          if (blocked != null) ...[
            const SizedBox(height: 10),
            Text(
              blocked,
              key: const ValueKey('calibration-blocked'),
              style: const TextStyle(color: Colors.black45, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('calibration-result'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
    ],
  );
}
