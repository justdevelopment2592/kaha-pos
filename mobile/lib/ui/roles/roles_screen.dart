import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Owner-only: decide what managers, cashiers and inventory staff may do in this store.
class RolesScreen extends ConsumerStatefulWidget {
  const RolesScreen({super.key, required this.profile});
  final Profile profile;
  @override
  ConsumerState<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends ConsumerState<RolesScreen> {
  static const _editable = [StaffRole.manager, StaffRole.cashier, StaffRole.inventory];
  StaffRole _role = StaffRole.manager;
  Map<String, Set<String>>? _draft;
  bool _busy = false;

  Future<void> _save() async {
    final perms = _draft?[_role.name] ?? <String>{};
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => ref.read(repositoryProvider).setRolePermissions(_role, perms),
      success: '${roleLabel(_role)} permissions saved',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(rolePermissionsProvider);
      ref.invalidate(profileProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final defs = ref.watch(permissionCatalogProvider);
    final current = ref.watch(rolePermissionsProvider);
    if (defs.hasError || current.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Roles')),
        body: ErrorPanel(message: friendlyError(defs.error ?? current.error!), onRetry: () {
          ref.invalidate(permissionCatalogProvider);
          ref.invalidate(rolePermissionsProvider);
        }),
      );
    }
    if (!defs.hasValue || !current.hasValue) {
      return Scaffold(appBar: AppBar(title: const Text('Roles')), body: const Center(child: CircularProgressIndicator()));
    }
    _draft ??= {for (final e in current.value!.entries) e.key: {...e.value}};
    final granted = _draft!.putIfAbsent(_role.name, () => <String>{});
    final saved = current.value![_role.name] ?? <String>{};
    final dirty = granted.length != saved.length || !granted.containsAll(saved);

    return Scaffold(
      appBar: AppBar(title: const Text('Roles')),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<StaffRole>(
              segments: [for (final r in _editable) ButtonSegment(value: r, label: Text(roleLabel(r)))],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Owners can always do everything. Changes apply on each person\'s next action.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 16), children: [
              for (final d in defs.value!)
                CheckboxListTile(
                  value: d.ownerOnly ? false : granted.contains(d.code),
                  onChanged: d.ownerOnly ? null : (v) => setState(() => v == true ? granted.add(d.code) : granted.remove(d.code)),
                  title: Text(d.label),
                  subtitle: Text(d.ownerOnly ? '${d.description}. Owners only.' : d.description),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy || !dirty ? null : _save,
                child: Text(dirty ? 'Save ${roleLabel(_role)} permissions' : 'No changes'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
