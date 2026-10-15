import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps the Supabase session in Keychain / Keystore instead of plain app storage.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage();

  static const _key = 'kaha.supabase.session';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => (await _storage.read(key: _key)) != null;

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
