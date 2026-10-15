import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'user_form_screen.dart';

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key, required this.profile});
  final Profile profile;

  Future<void> _open(BuildContext context, WidgetRef ref, {StaffMember? member}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => UserFormScreen(profile: profile, member: member)),
    );
    if (changed == true) {
      ref.invalidate(staffDirectoryProvider);
      ref.invalidate(profileProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = ref.watch(staffDirectoryProvider);
    final branchName = {for (final b in profile.branches) b.id: b.name};
    String branches(List<String> ids) => ids.isEmpty ? 'All branches' : ids.map((i) => branchName[i] ?? 'Other branch').join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Users'),
        actions: [IconButton(tooltip: 'Refresh', onPressed: () => ref.invalidate(staffDirectoryProvider), icon: const Icon(Icons.refresh))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Invite user'),
      ),
      body: dir.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorPanel(message: friendlyError(e), onRetry: () => ref.invalidate(staffDirectoryProvider)),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(staffDirectoryProvider),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
            if (d.invitations.isNotEmpty) ...[
              const SectionLabel('Waiting to join'),
              for (final i in d.invitations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.mail_outline)),
                      title: Text(i.displayName),
                      subtitle: Text('${i.email}\n${roleLabel(i.role)}, ${branches(i.branchIds)}'),
                      isThreeLine: true,
                      trailing: TextButton(
                        onPressed: () async {
                          final ok = await runAction(context, () => ref.read(repositoryProvider).revokeInvitation(i.id), success: 'Invitation cancelled');
                          if (ok) ref.invalidate(staffDirectoryProvider);
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                  ),
                ),
            ],
            const SectionLabel('Users'),
            for (final s in d.staff)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    onTap: () => _open(context, ref, member: s),
                    leading: CircleAvatar(child: Text(s.displayName.isEmpty ? '?' : s.displayName[0].toUpperCase())),
                    title: Text(s.isMe ? '${s.displayName} (you)' : s.displayName),
                    subtitle: Text([
                      roleLabel(s.role),
                      if (s.role != StaffRole.owner) branches(s.branchIds),
                      if (s.email != null) s.email!,
                    ].join('\n')),
                    isThreeLine: true,
                    trailing: s.active ? null : const Chip(label: Text('Access off')),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Invited people create a Kaha account with the same email, then tap Join.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ]),
        ),
      ),
    );
  }
}
