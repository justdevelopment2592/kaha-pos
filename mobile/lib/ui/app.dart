import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../core/errors.dart';
import '../core/theme.dart';
import '../state/providers.dart';
import 'auth/sign_in_screen.dart';
import 'home/home_shell.dart';
import 'onboarding/onboarding_screen.dart';
import 'widgets/common.dart';

class KahaApp extends StatelessWidget {
  const KahaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kaha POS',
      debugShowCheckedModeBanner: false,
      theme: kahaTheme(Brightness.light),
      darkTheme: kahaTheme(Brightness.dark),
      home: Env.isConfigured ? const AuthGate() : const _NotConfigured(),
    );
  }
}

/// Signed out -> sign in. Signed in but not in a store -> onboarding. Otherwise -> app.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const SignInScreen();
    final profile = ref.watch(profileProvider);
    return profile.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: ErrorPanel(message: friendlyError(e), onRetry: () => ref.invalidate(profileProvider)),
      ),
      data: (p) {
        if (p == null) return const SignInScreen();
        if (!p.isMember) return OnboardingScreen(profile: p);
        return HomeShell(profile: p);
      },
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This build has no server settings.\nRun with --dart-define-from-file=config/env.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
