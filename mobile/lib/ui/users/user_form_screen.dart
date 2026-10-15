import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Invite a new user (member == null) or change an existing user's role, branches and access.
class UserFormScreen extends ConsumerStatefulWidget {
  const UserFormScreen({super.key, required this.profile, this.member});
  final Profile profile;
  final StaffMember? member;
  @override
  ConsumerState<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends ConsumerState<UserFormScreen> {
  late final _name = TextEditingController(text: widget.member?.displayName ?? '');
  final _email = TextEditingController();
  late StaffRole _role = widget.member?.role ?? StaffRole.cashier;
  late bool _active = widget.member?.active ?? true;
  late Set<String> _branches = {...?widget.member?.branchIds};
  bool _busy = false;

  bool get _isNew => widget.member == null;
  bool get _iAmOwner => widget.profile.role == StaffRole.owner;
  bool get _isMe => widget.member?.isMe ?? false;
  bool get _lockedOwner => !_iAmOwner && widget.member?.role == StaffRole.owner;

  @override
  void initState() {
    super.initState();
    if (_isNew && widget.profile.branches.length == 1) _branches = {widget.profile.branches.first.id};
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repositoryProvider);
    String? problem;
    if (_name.text.trim().isEmpty) problem = 'Add the person\'s name.';
    if (_isNew && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) problem = 'Enter a valid email.';
    if (_role != StaffRole.owner && _active && _branches.isEmpty) problem = 'Pick at least one branch.';
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => _isNew
          ? repo.invite(email: _email.text.trim(), displayName: _name.text.trim(), role: _role, branchIds: _branches.toList())
          : repo.updateStaff(staffId: widget.member!.id, displayName: _name.text.trim(), role: _role, active: _active, branchIds: _branches.toList()),
      success: _isNew ? 'Invitation saved. Ask ${_name.text.trim()} to sign up with ${_email.text.trim()}.' : 'User updated',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final roles = [
      if (_iAmOwner) StaffRole.owner,
      StaffRole.manager,
      StaffRole.cashier,
      StaffRole.inventory,
    ];
    const roleHelp = {
      StaffRole.owner: 'Everything, including store settings and roles.',
      StaffRole.manager: 'Runs the branch: items, stock, users, approvals.',
      StaffRole.cashier: 'Sells at checkout.',
      StaffRole.inventory: 'Receives and counts stock. No payments.',
    };
    final canEditRole = !_isMe && !_lockedOwner;

    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Invite user' : 'Edit user')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          if (_lockedOwner)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Card(child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Only owners can change an owner.'))),
            ),
          TextField(controller: _name, enabled: !_lockedOwner, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name shown in the app')),
          const SizedBox(height: 12),
          if (_isNew)
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email they will sign up with'))
          else if (widget.member!.email != null)
            ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.mail_outline), title: Text(widget.member!.email!)),
          const SectionLabel('Role'),
          if (_isMe) const Text("You can't change your own role."),
          for (final r in roles)
            RadioListTile<StaffRole>(
              value: r,
              groupValue: _role,
              onChanged: canEditRole ? (v) => setState(() => _role = v!) : null,
              title: Text(roleLabel(r)),
              subtitle: Text(roleHelp[r]!),
              contentPadding: EdgeInsets.zero,
            ),
          if (_role != StaffRole.owner) ...[
            const SectionLabel('Branches'),
            for (final b in widget.profile.branches)
              CheckboxListTile(
                value: _branches.contains(b.id),
                onChanged: _lockedOwner ? null : (v) => setState(() => v == true ? _branches.add(b.id) : _branches.remove(b.id)),
                title: Text(b.name),
                subtitle: Text(b.code),
                contentPadding: EdgeInsets.zero,
              ),
          ],
          if (!_isNew) ...[
            const SectionLabel('Access'),
            SwitchListTile(
              value: _active,
              onChanged: canEditRole ? (v) => setState(() => _active = v) : null,
              title: const Text('Can sign in'),
              subtitle: const Text('Turning this off takes effect on their next action.'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || _lockedOwner ? null : _save,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(_isNew ? 'Save invitation' : 'Save changes'),
          ),
        ]),
      ),
    );
  }
}
