import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns server reasons into sentences a store owner understands.
String friendlyError(Object error) {
  String raw;
  if (error is PostgrestException) {
    raw = error.message;
  } else if (error is AuthException) {
    raw = error.message;
  } else {
    raw = error.toString();
  }
  const map = <String, String>{
    'missing_permission: catalog.manage': "Your role can't add or edit items. Ask an owner.",
    'missing_permission: staff.manage': "Your role can't manage users. Ask an owner.",
    'missing_permission: settings.manage': 'Only owners can change what each role can do.',
    'missing_permission: stock.receive': "Your role can't record stock deliveries.",
    'sku_already_used': 'Another item already uses that SKU.',
    'name_required': 'Add a name.',
    'price_required': 'Add a price.',
    'tax_code_not_found': 'Pick a tax type.',
    'sku_letters_numbers_dash_dot_only': 'SKU can only use letters, numbers, dot and dash.',
    'already_a_user_in_this_store': 'That person is already a user in this store.',
    'pick_at_least_one_branch': 'Pick at least one branch.',
    'only_owners_can_invite_owners': 'Only owners can invite another owner.',
    'only_owners_can_change_owners': 'Only owners can change an owner.',
    'you_cannot_change_your_own_role_or_access': "You can't change your own role or turn off your own access.",
    'store_needs_at_least_one_active_owner': 'The store needs at least one active owner.',
    'confirm_your_email_first': 'Confirm your email first, using the link we sent you.',
    'account_already_belongs_to_a_store': 'This account already belongs to a store.',
    'invitation_not_valid': 'That invitation has expired or was cancelled.',
    'quantity_must_be_a_whole_number_above_zero': 'Enter a whole number above zero.',
    'Invalid login credentials': 'Email or password is wrong.',
    'Email not confirmed': 'Confirm your email first, using the link we sent you.',
  };
  for (final entry in map.entries) {
    if (raw.startsWith(entry.key)) return entry.value;
  }
  if (raw.startsWith('barcode_already_used')) return 'Another item already uses barcode ${raw.split(': ').last}.';
  if (raw.contains('SocketException') || raw.contains('Failed host lookup')) {
    return "Can't reach the server. Check the internet connection and try again.";
  }
  return raw;
}
