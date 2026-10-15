import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defs = ref.watch(permissionCatalogProvider).valueOrNull ?? const <PermissionDef>[];
    final label = {for (final d in defs) d.code: d.label};
    return Scaffold(
      appBar: AppBar(title: const Text('Me')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: KahaColors.brandWash,
                child: Text((profile.displayName ?? '?')[0].toUpperCase(), style: const TextStyle(color: KahaColors.brand, fontWeight: FontWeight.w700)),
              ),
              title: Text(profile.displayName ?? ''),
              subtitle: Text('${roleLabel(profile.role!)} at ${profile.storeName}\n${profile.email}'),
              isThreeLine: true,
            ),
          ),
          const SectionLabel('Branches'),
          Card(
            child: Column(children: [
              for (final b in profile.branches) ListTile(leading: const Icon(Icons.storefront_outlined), title: Text(b.name), trailing: Text(b.code)),
            ]),
          ),
          const SectionLabel('What you can do'),
          Card(
            child: Column(children: [
              for (final p in profile.permissions)
                ListTile(dense: true, leading: const Icon(Icons.check, color: KahaColors.brand), title: Text(label[p] ?? p)),
            ]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: KahaColors.warnWash, borderRadius: BorderRadius.circular(12)),
            child: const Text(
              'Demo invoicing only. Receipts are not valid for tax purposes until the store is approved.',
              style: TextStyle(color: KahaColors.warn, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ]),
      ),
    );
  }
}
