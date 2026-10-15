// Plain models parsed from the server's JSON. Money fields are int centavos.

enum StaffRole { owner, manager, cashier, inventory }

StaffRole roleFrom(String s) => StaffRole.values.firstWhere((r) => r.name == s);

String roleLabel(StaffRole r) => switch (r) {
      StaffRole.owner => 'Owner',
      StaffRole.manager => 'Manager',
      StaffRole.cashier => 'Cashier',
      StaffRole.inventory => 'Inventory staff',
    };

/// Permission codes used by the app. Must match public.permissions on the server.
class Perm {
  static const sell = 'checkout.sell';
  static const catalog = 'catalog.manage';
  static const stockReceive = 'stock.receive';
  static const stockAdjust = 'stock.adjust';
  static const staff = 'staff.manage';
  static const devices = 'devices.manage';
  static const reports = 'reports.view';
  static const settings = 'settings.manage';
}

class Branch {
  Branch({required this.id, required this.code, required this.name});
  final String id;
  final String code;
  final String name;
  factory Branch.fromJson(Map<String, dynamic> j) =>
      Branch(id: j['id'] as String, code: j['code'] as String, name: j['name'] as String);
}

class Invitation {
  Invitation({required this.id, required this.store, required this.role, required this.displayName});
  final String id;
  final String store;
  final StaffRole role;
  final String displayName;
  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
        id: j['id'] as String,
        store: (j['store'] ?? '') as String,
        role: roleFrom(j['role'] as String),
        displayName: (j['display_name'] ?? '') as String,
      );
}

/// Result of my_profile_v1: either a member of a store, or someone who still needs to join one.
class Profile {
  Profile({
    required this.email,
    required this.staffId,
    required this.displayName,
    required this.role,
    required this.storeName,
    required this.branches,
    required this.permissions,
    required this.invitations,
    required this.deactivated,
    required this.emailConfirmed,
  });

  final String email;
  final String? staffId;
  final String? displayName;
  final StaffRole? role;
  final String? storeName;
  final List<Branch> branches;
  final Set<String> permissions;
  final List<Invitation> invitations;
  final bool deactivated;
  final bool emailConfirmed;

  bool get isMember => staffId != null;
  bool can(String perm) => permissions.contains(perm);

  factory Profile.fromJson(Map<String, dynamic> j) {
    final staff = j['staff'] as Map<String, dynamic>?;
    final tenant = j['tenant'] as Map<String, dynamic>?;
    return Profile(
      email: (j['email'] ?? '') as String,
      staffId: staff?['id'] as String?,
      displayName: staff?['display_name'] as String?,
      role: staff == null ? null : roleFrom(staff['role'] as String),
      storeName: tenant?['name'] as String?,
      branches: ((j['branches'] ?? []) as List).map((e) => Branch.fromJson(e as Map<String, dynamic>)).toList(),
      permissions: ((j['permissions'] ?? []) as List).map((e) => e as String).toSet(),
      invitations: ((j['invitations'] ?? []) as List).map((e) => Invitation.fromJson(e as Map<String, dynamic>)).toList(),
      deactivated: (j['deactivated'] ?? false) as bool,
      emailConfirmed: (j['email_confirmed'] ?? true) as bool,
    );
  }
}

class TaxCode {
  TaxCode({required this.id, required this.code, required this.name, required this.treatment, required this.rateBp});
  final String id;
  final String code;
  final String name;
  final String treatment;
  final int rateBp;
  factory TaxCode.fromJson(Map<String, dynamic> j) => TaxCode(
        id: j['id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        treatment: j['treatment'] as String,
        rateBp: (j['rate_bp'] as num).toInt(),
      );
}

class Category {
  Category({required this.id, required this.name});
  final String id;
  final String name;
  factory Category.fromJson(Map<String, dynamic> j) => Category(id: j['id'] as String, name: j['name'] as String);
}

class CatalogItem {
  CatalogItem({
    required this.variantId,
    required this.name,
    required this.sku,
    required this.unit,
    required this.priceCentavos,
    required this.taxCodeId,
    required this.categoryId,
    required this.archived,
    required this.barcodes,
    required this.stock,
  });
  final String variantId;
  final String name;
  final String sku;
  final String unit;
  final int priceCentavos;
  final String taxCodeId;
  final String? categoryId;
  final bool archived;
  final List<String> barcodes;
  final num? stock;

  factory CatalogItem.fromJson(Map<String, dynamic> j) => CatalogItem(
        variantId: j['variant_id'] as String,
        name: j['name'] as String,
        sku: j['sku'] as String,
        unit: j['unit'] as String,
        priceCentavos: (j['price_centavos'] as num).toInt(),
        taxCodeId: j['tax_code_id'] as String,
        categoryId: j['category_id'] as String?,
        archived: (j['archived'] ?? false) as bool,
        barcodes: ((j['barcodes'] ?? []) as List).map((e) => e as String).toList(),
        stock: j['stock'] as num?,
      );
}

class Catalog {
  Catalog({required this.items, required this.categories, required this.taxCodes});
  final List<CatalogItem> items;
  final List<Category> categories;
  final List<TaxCode> taxCodes;
  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        items: ((j['items'] ?? []) as List).map((e) => CatalogItem.fromJson(e as Map<String, dynamic>)).toList(),
        categories: ((j['categories'] ?? []) as List).map((e) => Category.fromJson(e as Map<String, dynamic>)).toList(),
        taxCodes: ((j['tax_codes'] ?? []) as List).map((e) => TaxCode.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

class StaffMember {
  StaffMember({
    required this.id,
    required this.displayName,
    required this.role,
    required this.active,
    required this.email,
    required this.branchIds,
    required this.isMe,
  });
  final String id;
  final String displayName;
  final StaffRole role;
  final bool active;
  final String? email;
  final List<String> branchIds;
  final bool isMe;
  factory StaffMember.fromJson(Map<String, dynamic> j) => StaffMember(
        id: j['id'] as String,
        displayName: j['display_name'] as String,
        role: roleFrom(j['role'] as String),
        active: j['active'] as bool,
        email: j['email'] as String?,
        branchIds: ((j['branch_ids'] ?? []) as List).map((e) => e as String).toList(),
        isMe: (j['is_me'] ?? false) as bool,
      );
}

class PendingInvite {
  PendingInvite({required this.id, required this.email, required this.displayName, required this.role, required this.branchIds});
  final String id;
  final String email;
  final String displayName;
  final StaffRole role;
  final List<String> branchIds;
  factory PendingInvite.fromJson(Map<String, dynamic> j) => PendingInvite(
        id: j['id'] as String,
        email: j['email'] as String,
        displayName: j['display_name'] as String,
        role: roleFrom(j['role'] as String),
        branchIds: ((j['branch_ids'] ?? []) as List).map((e) => e as String).toList(),
      );
}

class StaffDirectory {
  StaffDirectory({required this.staff, required this.invitations});
  final List<StaffMember> staff;
  final List<PendingInvite> invitations;
  factory StaffDirectory.fromJson(Map<String, dynamic> j) => StaffDirectory(
        staff: ((j['staff'] ?? []) as List).map((e) => StaffMember.fromJson(e as Map<String, dynamic>)).toList(),
        invitations: ((j['invitations'] ?? []) as List).map((e) => PendingInvite.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

class PermissionDef {
  PermissionDef({required this.code, required this.label, required this.description, required this.ownerOnly});
  final String code;
  final String label;
  final String description;
  final bool ownerOnly;
  factory PermissionDef.fromJson(Map<String, dynamic> j) => PermissionDef(
        code: j['code'] as String,
        label: j['label'] as String,
        description: j['description'] as String,
        ownerOnly: j['owner_only'] as bool,
      );
}
