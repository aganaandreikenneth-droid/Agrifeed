import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'firebase_options.dart';
import 'design.dart';

// ---------------------------------------------------------------------------
// AgriFeed: Flutter app <-> Firebase Realtime Database <-> ESP32 feeder
//
// Database layout (one feeder):
//   feeders/feeder1/
//     status/   online info written by the ESP32 (lastSeen, lastFeedAt, condition, rssi)
//     hopper/   weightG (ESP32), capacityG, lowThresholdG
//     command/  dispense request written by the app, answered by the ESP32
//     schedules/<id>  { time: "07:00", amountG: 50, enabled: true }
//     history/<id>    { ts, amountG, type: scheduled|manual, status: done|partial|jam }
//     logs/<id>       { ts, type, message, user }
// ---------------------------------------------------------------------------

const String feederId = 'feeder1';
const double defaultCapacityG = 9000; // approx. full 15 L hopper; set hopper/capacityG to your real full weight
const double defaultLowG = 500;
// Firebase console > Authentication > Sign-in method > Google > Web SDK configuration > Web client ID
const String googleServerClientId = '467162433407-gb83a7hhqup1ao2nfiokphmmbne8dlki.apps.googleusercontent.com';
const bool gmailOnly = false; // set to true to accept only @gmail.com addresses
const int offlineAfterMs = 90000; // feeder is "offline" if no heartbeat for 90 s

const Color kField = kOrange; // accent (peach)
const Color kGrain = Color(0xFFE9794B); // deeper peach for text
const Color kSoil = kInk; // charcoal

DatabaseReference get feederRef =>
    FirebaseDatabase.instance.ref('feeders/$feederId');

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

Future<void> addLog(String type, String message) {
  return feederRef.child('logs').push().set({
    'ts': ServerValue.timestamp,
    'type': type,
    'message': message,
    'user': FirebaseAuth.instance.currentUser?.email ?? 'unknown',
  });
}

String nextFeeding(Map<String, dynamic> schedules) {
  final now = DateTime.now();
  DateTime? best;
  int bestAmount = 0;
  for (final v in schedules.values) {
    final s = toMap(v);
    if (s['enabled'] != true) continue;
    final parts = (s['time'] as String? ?? '').split(':');
    if (parts.length != 2) continue;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) continue;
    var t = DateTime(now.year, now.month, now.day, h, m);
    if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
    if (best == null || t.isBefore(best)) {
      best = t;
      bestAmount = (s['amountG'] as num?)?.toInt() ?? 0;
    }
  }
  if (best == null) return 'No active schedule';
  final today = best.day == now.day;
  return '${today ? 'Today' : 'Tomorrow'} ${two(best.hour)}:${two(best.minute)}\n$bestAmount g';
}

Future<int?> askAmount(
  BuildContext context, {
  required String title,
  int initial = 50,
  int max = 5000,
}) {
  final c = TextEditingController(text: '$initial');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: InputDecoration(suffixText: 'g', helperText: 'Up to $max g'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = int.tryParse(c.text.trim());
            if (v != null && v > 0 && v <= max) Navigator.pop(ctx, v);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> dispenseNow(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final snap = await feederRef.child('status/lastSeen').get();
    final ls = (snap.value as num?)?.toInt();
    final online = ls != null &&
        DateTime.now().millisecondsSinceEpoch - ls < offlineAfterMs;
    if (!online) {
      messenger.showSnackBar(const SnackBar(content: Text('The feeder is offline.')));
      return;
    }
    if (!context.mounted) return;
    final amount = await askAmount(context, title: 'Dispense now', initial: 50, max: 500);
    if (amount == null) return;
    await feederRef.child('command').set({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'amountG': amount,
      'status': 'pending',
      'requestedBy': FirebaseAuth.instance.currentUser?.email ?? 'unknown',
      'requestedAt': ServerValue.timestamp,
    });
    await addLog('manual_dispense', 'Dispense requested: $amount g');
    messenger.showSnackBar(SnackBar(content: Text('Sent $amount g request to the feeder')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not send request: $e')));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (!kIsWeb) {
    try {
      await GoogleSignIn.instance.initialize(serverClientId: googleServerClientId);
    } catch (e) {
      debugPrint('Google Sign-In init failed: $e');
    }
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgriFeed',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kField)
            .copyWith(primary: kSoil, onPrimary: Colors.white, secondary: kGrain),
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          foregroundColor: kSoil,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

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
        borderRadius: BorderRadius.circular(26),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.userChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) return const LoginPage();
        // Email/password accounts must confirm their email first.
        // Google accounts are already verified by Google.
        final usesPassword =
            user.providerData.any((p) => p.providerId == 'password');
        if (usesPassword && !user.emailVerified) {
          return VerifyEmailPage(onChecked: () => setState(() {}));
        }
        return const HomeShell();
      },
    );
  }
}

class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({super.key, required this.onChecked});

  final VoidCallback onChecked;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  Timer? _timer;
  String? _msg;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _check(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check({bool silent = false}) async {
    try {
      await FirebaseAuth.instance.currentUser?.reload();
    } catch (_) {}
    if (!mounted) return;
    if (FirebaseAuth.instance.currentUser?.emailVerified ?? false) {
      widget.onChecked();
    } else if (!silent) {
      setState(() => _msg = 'Not verified yet. Open the link in your email first.');
    }
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _msg = null;
    });
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      _msg = 'Verification email sent again. Check your inbox and spam folder.';
    } on FirebaseAuthException catch (e) {
      _msg = e.code == 'too-many-requests'
          ? 'Please wait a moment before asking again.'
          : (e.message ?? e.code);
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kField,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.mark_email_unread_outlined,
                        color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Verify your email',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: kSoil),
                  ),
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
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_msg!),
                    ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      child: const Text('Use a different account'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

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

  String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'user-not-found':
      case 'wrong-password':
        return 'Email or password is incorrect. New here? Tap "Create account".';
      case 'email-already-in-use':
        return 'This email already has an account. Please sign in instead.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'invalid-email':
        return 'That email address does not look right.';
      case 'network-request-failed':
        return 'No internet connection.';
      default:
        return e.message ?? e.code;
    }
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    String? problem;
    if (_creating && _name.text.trim().isEmpty) {
      problem = 'Please enter your name.';
    } else if (email.isEmpty || !email.contains('@')) {
      problem = 'Please type a valid email address.';
    } else if (_creating && gmailOnly && !email.toLowerCase().endsWith('@gmail.com')) {
      problem = 'Please use your Gmail address (name@gmail.com).';
    } else if (_pass.text.length < 6) {
      problem = 'Password must be at least 6 characters.';
    } else if (_creating && _pass.text != _confirm.text) {
      problem = 'Passwords do not match.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      if (_creating) {
        final cred = await auth.createUserWithEmailAndPassword(
          email: email,
          password: _pass.text,
        );
        await cred.user?.updateDisplayName(_name.text.trim());
        try {
          await cred.user?.sendEmailVerification();
        } catch (_) {}
      } else {
        await auth.signInWithEmailAndPassword(email: email, password: _pass.text);
      }
      try {
        await addLog('login', _creating ? 'Account created' : 'Signed in');
      } catch (_) {}
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e));
    } catch (e) {
      setState(() => _error = 'Something went wrong: $e');
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
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
      } else {
        final googleUser = await GoogleSignIn.instance.authenticate();
        final idToken = googleUser.authentication.idToken;
        final credential = GoogleAuthProvider.credential(idToken: idToken);
        await FirebaseAuth.instance.signInWithCredential(credential);
      }
      // A first-time Google user gets a new AgriFeed account automatically.
      try {
        await addLog('login', 'Signed in with Google');
      } catch (_) {}
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e));
    } catch (e) {
      setState(() => _error = 'Google sign-in did not finish: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final c = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the email you registered with. We will send a link to choose a new password.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Send link'),
          ),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('If that email is registered, a reset link is on its way. Check your inbox and spam.'),
        ),
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e));
    }
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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kField,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.egg_alt, color: Colors.white, size: 32),
                  ),
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
                      label: Text(_creating ? 'Sign up with Google' : 'Continue with Google'),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation shell
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _i = 0;

  static const _titles = ['Dashboard', 'Feeding schedule', 'History', 'Settings'];
  static const _pages = <Widget>[
    DashboardPage(),
    SchedulePage(),
    HistoryPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: const IconBox(icon: Icons.egg_alt_outlined),
        title: Text(
          _titles[_i],
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        actions: [
          IconBox(
            icon: Icons.notifications_none_rounded,
            onTap: () => setState(() => _i = 2),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _pages[_i],
      bottomNavigationBar: PillNav(
        index: _i,
        onTap: (v) => setState(() => _i = v),
        onCenter: () => dispenseNow(context),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Re-evaluate "online/offline" even when no new data arrives.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _dispense() async {
    final amount = await askAmount(
      context,
      title: 'Dispense now',
      initial: 50,
      max: 500,
    );
    if (amount == null) return;
    final email = FirebaseAuth.instance.currentUser?.email ?? 'unknown';
    try {
      await feederRef.child('command').set({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'amountG': amount,
        'status': 'pending',
        'requestedBy': email,
        'requestedAt': ServerValue.timestamp,
      });
      await addLog('manual_dispense', 'Dispense requested: $amount g');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent $amount g request to the feeder')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send request: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Database error: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = toMap(snap.data!.snapshot.value);
        final status = toMap(data['status']);
        final hopper = toMap(data['hopper']);
        final schedules = toMap(data['schedules']);
        final cmd = toMap(data['command']);

        final lastSeen = (status['lastSeen'] as num?)?.toInt();
        final online = lastSeen != null &&
            DateTime.now().millisecondsSinceEpoch - lastSeen < offlineAfterMs;
        final condition = (status['condition'] as String?) ?? 'ok';
        final lastFeedAt = status['lastFeedAt'];

        final weight = (hopper['weightG'] as num?)?.toDouble() ?? 0;
        final capacity = (hopper['capacityG'] as num?)?.toDouble() ?? defaultCapacityG;
        final low = (hopper['lowThresholdG'] as num?)?.toDouble() ?? defaultLowG;
        final frac = (weight / capacity).clamp(0.0, 1.0);
        final levelColor = weight < low
            ? Colors.red
            : (frac < 0.25 ? Colors.orange : kField);

        final jam = condition == 'jam';
        final lowFeed = weight < low;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Feeder status
            Panel(
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: online ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          online ? 'Feeder online' : 'Feeder offline',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          lastSeen == null
                              ? 'Never connected'
                              : 'Last connection ${ago(lastSeen)}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    online ? Icons.wifi : Icons.wifi_off,
                    color: online ? kField : Colors.grey,
                  ),
                ],
              ),
            ),
            if (jam) ...[
              const SizedBox(height: 12),
              const Panel(
                color: Color(0xFFFDE7E7),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Feed jam detected. Check the gate and press the feeder button to reset the alarm.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (lowFeed && online) ...[
              const SizedBox(height: 12),
              Panel(
                color: const Color(0xFFFFF1DC),
                child: Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined, color: Colors.orange),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Low feed: ${weightLabel(weight)} left. Refill the hopper soon.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),

            // Hopper level (segmented gauge)
            SegmentGauge(
              fraction: frac,
              color: weight < low ? const Color(0xFFE5584A) : kOrange,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(online ? Icons.wifi : Icons.wifi_off, color: kOrange, size: 22),
                  const SizedBox(height: 6),
                  Text(
                    online ? 'Feeder online' : 'Feeder offline',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    weightLabel(weight),
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                      color: kSoil,
                    ),
                  ),
                  Text(
                    'Alert below ${low.round()} g',
                    style: const TextStyle(color: kGrain),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Next feeding + today's summary
            IntrinsicHeight(
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.schedule, color: kGrain),
                        const SizedBox(height: 8),
                        const Text('Next feeding', style: TextStyle(color: Colors.black54)),
                        const SizedBox(height: 4),
                        Text(
                          nextFeeding(schedules),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(child: TodayCard()),
              ],
            ),
            ),
            const SizedBox(height: 12),

            // Last feeding
            Panel(
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: kField),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      lastFeedAt == null
                          ? 'No successful feeding yet'
                          : 'Last successful feeding: ${fmtTs(lastFeedAt)}',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Dispense
            SizedBox(
              height: 58,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: kBeige,
                  foregroundColor: kSoil,
                  shape: const StadiumBorder(),
                ),
                onPressed: online ? () => dispenseNow(context) : null,
                icon: const Icon(Icons.add),
                label: const Text(
                  'Dispense now',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (!online)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The feeder is offline. Scheduled feedings still run on its own clock.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            if (cmd['status'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last request: ${cmd['amountG']} g (${cmd['status']})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
          ],
        );
      },
    );
  }
}

class TodayCard extends StatelessWidget {
  const TodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef.child('history').orderByChild('ts').limitToLast(100).onValue,
      builder: (context, snap) {
        int count = 0;
        int grams = 0;
        if (snap.hasData) {
          final now = DateTime.now();
          for (final c in snap.data!.snapshot.children) {
            final m = toMap(c.value);
            final ts = m['ts'];
            if (ts is! num) continue;
            final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
            if (d.year == now.year && d.month == now.month && d.day == now.day) {
              if (m['status'] == 'jam') continue;
              count++;
              grams += (m['amountG'] as num?)?.toInt() ?? 0;
            }
          }
        }
        return Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.today, color: kGrain),
              const SizedBox(height: 8),
              const Text("Today's feeding", style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 4),
              Text(
                '$count feedings\n$grams g',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------

Future<void> editSchedule(
  BuildContext context, {
  String? id,
  Map<String, dynamic>? existing,
}) async {
  var time = const TimeOfDay(hour: 7, minute: 0);
  final t = existing?['time'] as String?;
  if (t != null) {
    final p = t.split(':');
    if (p.length == 2) {
      time = TimeOfDay(
        hour: int.tryParse(p[0]) ?? 7,
        minute: int.tryParse(p[1]) ?? 0,
      );
    }
  }
  final picked = await showTimePicker(context: context, initialTime: time);
  if (picked == null || !context.mounted) return;
  final amount = await askAmount(
    context,
    title: 'Feed amount',
    initial: (existing?['amountG'] as num?)?.toInt() ?? 50,
    max: 500,
  );
  if (amount == null) return;
  final timeStr = '${two(picked.hour)}:${two(picked.minute)}';
  final ref = id == null
      ? feederRef.child('schedules').push()
      : feederRef.child('schedules/$id');
  await ref.set({
    'time': timeStr,
    'amountG': amount,
    'enabled': existing?['enabled'] ?? true,
  });
  await addLog(
    id == null ? 'schedule_added' : 'schedule_edited',
    'Schedule $timeStr, $amount g',
  );
}

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editSchedule(context),
        icon: const Icon(Icons.add),
        label: const Text('Add schedule'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: feederRef.child('schedules').onValue,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Database error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final raw = toMap(snap.data!.snapshot.value);
          final items = raw.entries
              .map((e) => MapEntry(e.key, toMap(e.value)))
              .toList()
            ..sort((a, b) =>
                ((a.value['time'] as String?) ?? '').compareTo((b.value['time'] as String?) ?? ''));
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No feeding schedules yet.\nTap "Add schedule" to set a time and amount.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final id = items[i].key;
              final s = items[i].value;
              final enabled = s['enabled'] == true;
              return Panel(
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => editSchedule(context, id: id, existing: s),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s['time'] ?? '--:--'}',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: enabled ? kSoil : Colors.black38,
                              ),
                            ),
                            Text('${s['amountG'] ?? 0} g'),
                          ],
                        ),
                      ),
                    ),
                    Switch(
                      value: enabled,
                      onChanged: (v) async {
                        await feederRef.child('schedules/$id/enabled').set(v);
                        await addLog(
                          'schedule_toggled',
                          '${s['time']} ${v ? 'enabled' : 'disabled'}',
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await feederRef.child('schedules/$id').remove();
                        await addLog('schedule_deleted', 'Deleted ${s['time']}');
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History + activity log
// ---------------------------------------------------------------------------

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Feedings'),
              Tab(text: 'Activity log'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                RecentList(path: 'history', feeding: true),
                RecentList(path: 'logs', feeding: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class RecentList extends StatelessWidget {
  const RecentList({super.key, required this.path, required this.feeding});

  final String path;
  final bool feeding;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: feederRef.child(path).orderByChild('ts').limitToLast(100).onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Database error: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items =
            snap.data!.snapshot.children.map((c) => toMap(c.value)).toList().reversed.toList();
        if (items.isEmpty) {
          return const Center(child: Text('Nothing recorded yet.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final m = items[i];
            if (feeding) {
              final status = '${m['status'] ?? ''}';
              final ok = status == 'done';
              return Panel(
                child: Row(
                  children: [
                    Icon(
                      ok ? Icons.check_circle : Icons.error_outline,
                      color: ok ? kField : Colors.orange,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${m['amountG'] ?? 0} g, ${m['type'] ?? ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text('${fmtTs(m['ts'])}  |  $status'),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }
            return Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m['message'] ?? m['type'] ?? ''}'),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtTs(m['ts'])}  |  ${m['user'] ?? ''}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Panel(
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: kField,
                child: Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (user?.displayName?.isNotEmpty ?? false)
                          ? user!.displayName!
                          : (user?.email ?? 'Unknown user'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(user?.email ?? '', style: const TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        StreamBuilder<DatabaseEvent>(
          stream: feederRef.child('hopper/lowThresholdG').onValue,
          builder: (context, snap) {
            final v = (snap.data?.snapshot.value as num?)?.toInt() ?? defaultLowG.toInt();
            return Panel(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Low-feed alert level'),
                subtitle: Text('Warn when the hopper is below $v g'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async {
                  final nv = await askAmount(
                    context,
                    title: 'Low-feed alert level',
                    initial: v,
                    max: 5000,
                  );
                  if (nv == null) return;
                  await feederRef.child('hopper/lowThresholdG').set(nv);
                  await addLog('settings', 'Low-feed level set to $nv g');
                },
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        const Panel(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.memory),
            title: Text('Feeder'),
            subtitle: Text('ID: $feederId'),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () async {
            try {
              await addLog('logout', 'Signed out');
            } catch (_) {}
            await FirebaseAuth.instance.signOut();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}