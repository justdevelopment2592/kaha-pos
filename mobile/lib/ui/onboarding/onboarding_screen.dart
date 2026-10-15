import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Signed in, but not (or no longer) part of a store.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.profile});
  final Profile profile;
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _store = TextEditingController();
  final _owner = TextEditingController();
  final _branchName = TextEditingController(text: 'Main branch');
  final _branchCode = TextEditingController(text: 'MAIN');
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_store, _owner, _branchName, _branchCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async => ref.invalidate(profileProvider);

  Future<void> _accept(Invitation inv) async {
    setState(() => _busy = true);
    final ok = await runAction(context, () => ref.read(repositoryProvider).acceptInvitation(inv.id), success: 'Welcome to ${inv.store}');
    if (mounted) setState(() => _busy = false);
    if (ok) _refresh();
  }

  Future<void> _createStore() async {
    final code = _branchCode.text.trim().toUpperCase();
    if (_store.text.trim().isEmpty || _owner.text.trim().isEmpty || _branchName.text.trim().isEmpty || !RegExp(r'^[A-Z0-9]{2,8}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill in every field. Branch code is 2 to 8 letters or numbers.')));
      return;
    }
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => ref.read(repositoryProvider).createStore(
            storeName: _store.text.trim(),
            ownerName: _owner.text.trim(),
            branchCode: code,
            branchName: _branchName.text.trim(),
          ),
      success: 'Store created',
    );
    if (mounted) setState(() => _busy = false);
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join a store'),
        actions: [
          IconButton(onPressed: _refresh, tooltip: 'Check again', icon: const Icon(Icons.refresh)),
          TextButton(onPressed: () => ref.read(supabaseProvider).auth.signOut(), child: const Text('Sign out')),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Signed in as ${p.email}', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 16),
          if (p.deactivated)
            const Card(
              child: ListTile(
                leading: Icon(Icons.block),
                title: Text('Your access was turned off'),
                subtitle: Text('Ask the store owner to turn it back on.'),
              ),
            )
          else if (!p.emailConfirmed)
            Card(
              child: ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: const Text('Confirm your email'),
                subtitle: const Text('Open the link we emailed you, then tap Check again.'),
                trailing: IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
              ),
            )
          else ...[
            if (p.invitations.isNotEmpty) ...[
              Text('You were invited', style: t.titleLarge),
              const SizedBox(height: 8),
              for (final inv in p.invitations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      title: Text(inv.store),
                      subtitle: Text('${roleLabel(inv.role)}, as ${inv.displayName}'),
                      trailing: FilledButton(onPressed: _busy ? null : () => _accept(inv), child: const Text('Join')),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
            Text(p.invitations.isEmpty ? 'Start your store' : 'Or start a new store', style: t.titleLarge),
            const SizedBox(height: 4),
            Text(
              "Waiting for an invite? Ask the owner to invite ${p.email}, then tap Check again.",
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(controller: _store, decoration: const InputDecoration(labelText: 'Store name', hintText: 'e.g. Tindahan ni Aling Nena')),
            const SizedBox(height: 12),
            TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Your name')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: _branchName, decoration: const InputDecoration(labelText: 'First branch'))),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _branchCode,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Branch code'),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _createStore, child: const Text('Create store')),
          ],
        ]),
      ),
    );
  }
}
