import 'package:flutter/material.dart';

import '../../services/feeder_actions.dart';

/// IANA time zones offered when creating a feeder (schedules run in the
/// feeder's zone). Asia/Manila first: the project's home region.
const kFeederTimezones = [
  'Asia/Manila',
  'UTC',
  'Asia/Singapore',
  'Asia/Tokyo',
  'Australia/Sydney',
  'Europe/London',
  'America/New_York',
  'America/Los_Angeles',
];

/// Asks for a name and time zone, registers a virtual feeder through the
/// backend and returns its ID (null when cancelled).
///
/// One requestId per dialog: pressing Create again after a timeout retries
/// the same request, so it can never create two feeders.
Future<String?> showCreateVirtualFeederDialog(
  BuildContext context,
  FeederActions actions,
) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CreateFeederDialog(actions: actions),
  );
}

class _CreateFeederDialog extends StatefulWidget {
  const _CreateFeederDialog({required this.actions});

  final FeederActions actions;

  @override
  State<_CreateFeederDialog> createState() => _CreateFeederDialogState();
}

class _CreateFeederDialogState extends State<_CreateFeederDialog> {
  // Owned here and disposed in dispose(), after the exit animation.
  final _name = TextEditingController();
  final _requestId = newRequestId();
  String _timezone = kFeederTimezones.first;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 40) {
      setState(() => _error = 'Enter a name of 1 to 40 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.actions.createVirtualFeeder(
        name: name,
        timezone: _timezone,
        requestId: _requestId,
      );
      if (mounted) Navigator.pop(context, id);
    } on FeederActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the server. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create virtual feeder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A virtual feeder is simulated: no hardware is needed and its '
            'readings are always labelled VIRTUAL.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            enabled: !_busy,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Feeder name'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _timezone,
            decoration: const InputDecoration(labelText: 'Time zone'),
            items: [
              for (final tz in kFeederTimezones)
                DropdownMenuItem(value: tz, child: Text(tz)),
            ],
            onChanged: _busy ? null : (v) => setState(() => _timezone = v!),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
