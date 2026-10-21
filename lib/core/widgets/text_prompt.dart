import 'package:flutter/material.dart';

/// Shows a dialog with one text field and returns the trimmed text, or null
/// when cancelled.
///
/// The dialog owns its TextEditingController and disposes it in its own
/// dispose(). Disposing a controller right after `showDialog` returns crashes,
/// because the dialog's exit animation still renders the TextField.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? message,
  String confirmLabel = 'Save',
  int? maxLength,
  TextInputType? keyboardType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      label: label,
      initial: initial,
      message: message,
      confirmLabel: confirmLabel,
      maxLength: maxLength,
      keyboardType: keyboardType,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.message,
    required this.confirmLabel,
    required this.maxLength,
    required this.keyboardType,
  });

  final String title;
  final String label;
  final String initial;
  final String? message;
  final String confirmLabel;
  final int? maxLength;
  final TextInputType? keyboardType;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _c,
            autofocus: true,
            maxLength: widget.maxLength,
            keyboardType: widget.keyboardType,
            decoration: InputDecoration(labelText: widget.label),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
