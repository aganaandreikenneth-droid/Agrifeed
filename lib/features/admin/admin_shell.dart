import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../core/widgets/panel.dart';
import '../../design.dart';
import '../home/account_panel.dart';

/// System Admin home for Phase 1: account-access actions backed by Cloud
/// Functions, plus the platform audit trail. Admins have no feeder access.
/// The full dashboard (user list, statistics, device oversight) is Phase 9.
class AdminShell extends StatelessWidget {
  const AdminShell({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: const IconBox(icon: Icons.admin_panel_settings_outlined),
        title: const Text(
          'System Admin',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Panel(
            color: kBeige,
            child: Text(
              'Platform administration. Administrator accounts cannot view or control private feeders.',
            ),
          ),
          SizedBox(height: 12),
          AccountAccessPanel(),
          SizedBox(height: 12),
          AuditPanel(),
          SizedBox(height: 16),
          AccountPanel(),
        ],
      ),
    );
  }
}

enum _AdminAction { suspend, reactivate, grantAdmin, revokeAdmin }

class AccountAccessPanel extends StatefulWidget {
  const AccountAccessPanel({super.key});

  @override
  State<AccountAccessPanel> createState() => _AccountAccessPanelState();
}

class _AccountAccessPanelState extends State<AccountAccessPanel> {
  final _uid = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _uid.dispose();
    _reason.dispose();
    super.dispose();
  }

  static const _labels = {
    _AdminAction.suspend: 'Suspend account',
    _AdminAction.reactivate: 'Reactivate account',
    _AdminAction.grantAdmin: 'Grant admin role',
    _AdminAction.revokeAdmin: 'Revoke admin role',
  };

  Future<void> _run(_AdminAction action) async {
    final uid = _uid.text.trim();
    final reason = _reason.text.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(uid)) {
      setState(() => _result = 'Enter a valid user ID (UID).');
      return;
    }
    if (action == _AdminAction.suspend && reason.isEmpty) {
      setState(() => _result = 'A reason is required to suspend an account.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_labels[action]}?'),
        content: Text('User ID: $uid'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final admin = AppScope.of(context).admin;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      switch (action) {
        case _AdminAction.suspend:
          await admin.suspendUser(uid, reason);
        case _AdminAction.reactivate:
          await admin.reactivateUser(uid);
        case _AdminAction.grantAdmin:
          await admin.setAdminRole(uid, true);
        case _AdminAction.revokeAdmin:
          await admin.setAdminRole(uid, false);
      }
      _ok = true;
      _result = '${_labels[action]}: done.';
    } catch (e) {
      _ok = false;
      _result = '${_labels[action]} failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Account access',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _uid,
            decoration: const InputDecoration(labelText: 'User ID (UID)'),
          ),
          TextField(
            controller: _reason,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Reason (required to suspend)',
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in _AdminAction.values)
                OutlinedButton(
                  onPressed: _busy ? null : () => _run(a),
                  child: Text(_labels[a]!),
                ),
            ],
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _result!,
                style: TextStyle(
                  color: _ok ? Colors.green.shade800 : Colors.red,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AuditPanel extends StatelessWidget {
  const AuditPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recent administrative actions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: AppScope.of(context).admin.watchRecentAudit(),
            builder: (context, snap) {
              if (snap.hasError) {
                return const Text('Could not load the audit log.');
              }
              if (!snap.hasData) return const LinearProgressIndicator();
              final items = snap.data!;
              if (items.isEmpty) return const Text('No actions recorded yet.');
              return Column(
                children: [
                  for (final m in items)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${m['action'] ?? ''}'),
                      subtitle: Text(
                        '${fmtTs(m['ts'])}  |  target ${m['targetUid'] ?? '-'}  |  by ${m['actorUid'] ?? '-'}',
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
