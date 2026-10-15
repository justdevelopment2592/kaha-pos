import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/env.dart';
import 'core/secure_session_storage.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Env.isConfigured) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseKey,
      authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
    );
  }
  runApp(const ProviderScope(child: KahaApp()));
}
