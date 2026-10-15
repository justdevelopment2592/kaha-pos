import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repository.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

final repositoryProvider = Provider<Repository>((ref) => Repository(ref.watch(supabaseProvider)));

/// Emits on sign-in, sign-out and token refresh.
final authStateProvider = StreamProvider<AuthState>((ref) => ref.watch(supabaseProvider).auth.onAuthStateChange);

final sessionProvider = Provider<Session?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentSession;
});

/// Who I am in the store, with permissions. Re-fetched whenever the signed-in user changes.
final profileProvider = FutureProvider<Profile?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;
  return ref.watch(repositoryProvider).myProfile();
});

/// Branch the user is looking at (stock figures depend on it).
final selectedBranchProvider = StateProvider<Branch?>((ref) {
  final p = ref.watch(profileProvider).valueOrNull;
  return (p == null || p.branches.isEmpty) ? null : p.branches.first;
});

final catalogProvider = FutureProvider<Catalog>((ref) async {
  final branch = ref.watch(selectedBranchProvider);
  return ref.watch(repositoryProvider).catalog(branch?.id);
});

final staffDirectoryProvider = FutureProvider<StaffDirectory>((ref) => ref.watch(repositoryProvider).staff());

final permissionCatalogProvider = FutureProvider<List<PermissionDef>>((ref) => ref.watch(repositoryProvider).permissionCatalog());

final rolePermissionsProvider = FutureProvider<Map<String, Set<String>>>((ref) => ref.watch(repositoryProvider).rolePermissions());
