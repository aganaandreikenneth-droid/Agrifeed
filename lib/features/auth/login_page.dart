import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/panel.dart';
import '../../core/widgets/text_prompt.dart';
import '../../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth});

  final AuthService auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _creating = false; // false = Sign in (existing user), true = Create account (new user)
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _switchMode() => setState(() {
    _creating = !_creating;
    _error = null;
  });

  Future<void> _submit() async {
    final problem = validateAuthForm(
      creating: _creating,
      name: _name.text,
      email: _email.text,
      password: _pass.text,
      confirm: _confirm.text,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      if (_creating) {
        await widget.auth.register(_name.text.trim(), email, _pass.text);
      } else {
        await widget.auth.signIn(email, _pass.text);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = friendlyAuthError(e));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // A first-time Google user gets a new AgriFeed account automatically.
      await widget.auth.signInWithGoogle();
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = friendlyAuthError(e));
    } catch (_) {
      if (mounted) setState(() => _error = 'Google sign-in did not finish.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = await showTextPrompt(
      context,
      title: 'Reset password',
      label: 'Email',
      initial: _email.text.trim(),
      message: 'Enter the email you registered with. We will send a link to choose a new password.',
      confirmLabel: 'Send link',
      keyboardType: TextInputType.emailAddress,
    );
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await widget.auth.sendPasswordReset(email);
    } on FirebaseAuthException catch (e) {
      // Only report problems that do not reveal whether the account exists.
      if (e.code == 'invalid-email' || e.code == 'network-request-failed') {
        if (mounted) setState(() => _error = friendlyAuthError(e));
        return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'If that email is registered, a reset link is on its way. Check your inbox and spam.',
        ),
      ),
    );
  }

  Widget _input(
    TextEditingController c,
    String label, {
    bool secret = false,
    TextInputType? type,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: secret && _hide,
        keyboardType: type,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          suffixIcon: secret
              ? IconButton(
                  icon: Icon(_hide ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _hide = !_hide),
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NarrowPage(
      children: [
        const HeroIcon(Icons.egg_alt),
        const SizedBox(height: 20),
        Text(
          _creating ? 'Create account' : 'Welcome back',
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: kSoil,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _creating
              ? 'New to AgriFeed? Sign up to manage your poultry feeder.'
              : 'Sign in with your existing AgriFeed account.',
        ),
        const SizedBox(height: 24),
        if (_creating) _input(_name, 'Full name'),
        _input(_email, 'Email', type: TextInputType.emailAddress),
        _input(_pass, 'Password', secret: true),
        if (!_creating)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _forgot,
              child: const Text('Forgot password?'),
            ),
          ),
        if (_creating) _input(_confirm, 'Confirm password', secret: true),
        if (_creating)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Use at least $minNewPasswordLength characters.',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_creating ? 'Create account' : 'Sign in'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _google,
            icon: const Icon(Icons.g_mobiledata, size: 32),
            label: Text(
              _creating ? 'Sign up with Google' : 'Continue with Google',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _busy ? null : _switchMode,
            child: Text(
              _creating
                  ? 'Already have an account? Sign in'
                  : 'New to AgriFeed? Create account',
            ),
          ),
        ),
      ],
    );
  }
}
