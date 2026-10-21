import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../services/auth_service.dart';

class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({
    super.key,
    required this.auth,
    required this.onVerified,
  });

  final AuthService auth;

  /// Called once the email is verified and the ID token has been refreshed.
  final Future<void> Function() onVerified;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  Timer? _timer;
  String? _msg;
  bool _sending = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _check(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking) return;
    _checking = true;
    bool verified = false;
    try {
      verified = await widget.auth.reloadAndCheckVerified();
    } catch (_) {}
    _checking = false;
    if (!mounted) return;
    if (verified) {
      _timer?.cancel();
      await widget.onVerified();
    } else if (!silent) {
      setState(
        () => _msg = 'Not verified yet. Open the link in your email first.',
      );
    }
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _msg = null;
    });
    try {
      await widget.auth.resendVerification();
      _msg = 'Verification email sent again. Check your inbox and spam folder.';
    } on FirebaseAuthException catch (e) {
      _msg = e.code == 'too-many-requests'
          ? 'Please wait a moment before asking again.'
          : friendlyAuthError(e);
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.auth.currentUser?.email ?? '';
    return NarrowPage(
      children: [
        const HeroIcon(Icons.mark_email_unread_outlined),
        const SizedBox(height: 20),
        const Text('Verify your email', style: kTitleStyle),
        const SizedBox(height: 8),
        Text(
          'We sent a verification link to $email. Open it from your Gmail (or other inbox), then come back to the app.',
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            onPressed: () => _check(),
            child: const Text('I have verified my email'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: OutlinedButton(
            onPressed: _sending ? null : _resend,
            child: const Text('Resend email'),
          ),
        ),
        if (_msg != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!)),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: () => widget.auth.signOut(),
            child: const Text('Use a different account'),
          ),
        ),
      ],
    );
  }
}
