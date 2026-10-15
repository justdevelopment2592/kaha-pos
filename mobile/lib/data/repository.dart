import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Every server call in one place. All writes go through versioned RPC functions;
/// the server re-checks permissions, so the UI hiding a button is a convenience, not security.
class Repository {
  Repository(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>> _rpc(String fn, [Map<String, dynamic>? params]) async {
    final res = await _db.rpc(fn, params: params);
    return (res as Map).cast<String, dynamic>();
  }

  // ----- account -----
  Future<Profile> myProfile() async => Profile.fromJson(await _rpc('my_profile_v1'));

  Future<void> createStore({required String storeName, required String ownerName, required String branchCode, required String branchName}) =>
      _rpc('store_create_v1', {
        'p_store_name': storeName,
        'p_owner_name': ownerName,
        'p_branch_code': branchCode,
        'p_branch_name': branchName,
      });

  Future<void> acceptInvitation(String id) => _rpc('invitation_accept_v1', {'p_invitation_id': id});

  // ----- items -----
  Future<Catalog> catalog(String? branchId) async => Catalog.fromJson(await _rpc('catalog_admin_list_v1', {'p_branch_id': branchId}));

  Future<String> saveItem({
    String? variantId,
    required String name,
    required String sku,
    required String unit,
    required String taxCodeId,
    String? categoryId,
    required int priceCentavos,
    required List<String> barcodes,
  }) async {
    final r = await _rpc('item_save_v1', {
      'p': {
        'variant_id': variantId,
        'name': name,
        'sku': sku,
        'unit': unit,
        'tax_code_id': taxCodeId,
        'category_id': categoryId,
        'price_centavos': priceCentavos,
        'barcodes': barcodes,
      }
    });
    return r['variant_id'] as String;
  }

  Future<void> archiveItem(String variantId, bool archived) =>
      _rpc('item_archive_v1', {'p_variant_id': variantId, 'p_archived': archived});

  Future<String> saveCategory(String? id, String name) async =>
      (await _rpc('category_save_v1', {'p_category_id': id, 'p_name': name}))['category_id'] as String;

  Future<void> receiveStock({required String branchId, required String variantId, required int qty, String? reference}) =>
      _rpc('stock_receive_v1', {'p_branch_id': branchId, 'p_variant_id': variantId, 'p_qty': qty, 'p_reference': reference});

  // ----- users -----
  Future<StaffDirectory> staff() async => StaffDirectory.fromJson(await _rpc('staff_list_v1'));

  Future<void> invite({required String email, required String displayName, required StaffRole role, required List<String> branchIds}) =>
      _rpc('staff_invite_v1', {'p_email': email, 'p_display_name': displayName, 'p_role': role.name, 'p_branch_ids': branchIds});

  Future<void> revokeInvitation(String id) => _rpc('staff_invitation_revoke_v1', {'p_invitation_id': id});

  Future<void> updateStaff({required String staffId, required String displayName, required StaffRole role, required bool active, required List<String> branchIds}) =>
      _rpc('staff_update_v1', {
        'p_staff_id': staffId,
        'p_display_name': displayName,
        'p_role': role.name,
        'p_active': active,
        'p_branch_ids': branchIds,
      });

  // ----- roles -----
  Future<List<PermissionDef>> permissionCatalog() async {
    final rows = await _db.from('permissions').select().order('sort_order');
    return (rows as List).map((e) => PermissionDef.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  /// role name -> granted permission codes (owners are implicit: everything).
  Future<Map<String, Set<String>>> rolePermissions() async {
    final rows = await _db.from('role_permissions').select('role, permission');
    final out = <String, Set<String>>{};
    for (final r in rows as List) {
      final m = (r as Map).cast<String, dynamic>();
      out.putIfAbsent(m['role'] as String, () => <String>{}).add(m['permission'] as String);
    }
    return out;
  }

  Future<void> setRolePermissions(StaffRole role, Set<String> perms) =>
      _rpc('role_permissions_set_v1', {'p_role': role.name, 'p_permissions': perms.toList()});
}
