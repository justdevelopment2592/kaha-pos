import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 8) {
      setState(() {
        _message = 'Enter your email and a password of at least 8 characters.';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final auth = ref.read(supabaseProvider).auth;
    try {
      if (_creating) {
        final res = await auth.signUp(email: email, password: password);
        if (res.session == null) {
          setState(() {
            _creating = false;
            _message = 'Check $email for a confirmation link, then sign in here.';
            _messageIsError = false;
          });
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } catch (e) {
      setState(() {
        _message = friendlyError(e);
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: KahaColors.brand, borderRadius: BorderRadius.circular(10)),
                    alignment: Alignment.center,
                    child: const Text('K', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
                  ),
                  const SizedBox(width: 10),
                  Text('Kaha', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 28),
                Text(_creating ? 'Create your account' : 'Sign in', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  _creating
                      ? 'Use the email your store owner invited, or start a new store after you confirm it.'
                      : 'Use the email and password for your store account.',
                  style: TextStyle(color: scheme.outline),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: [_creating ? AutofillHints.newPassword : AutofillHints.password],
                  decoration: InputDecoration(labelText: 'Password', helperText: _creating ? 'At least 8 characters' : null),
                  onSubmitted: (_) => _submit(),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Text(_message!, style: TextStyle(color: _messageIsError ? scheme.error : KahaColors.brand)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Text(_creating ? 'Create account' : 'Sign in'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : () => setState(() {
                        _creating = !_creating;
                        _message = null;
                      }),
                  child: Text(_creating ? 'I already have an account' : 'Create an account'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
