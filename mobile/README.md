# Kaha POS · Flutter app (production track)

Talks to the Supabase project `opensource-pos`. M1 scope in this build:
sign in / create account, create a store or join one by invitation, **items** (add, edit, archive, barcodes, categories, receive stock),
**users** (invite, change role, branches, turn access off), **roles** (owner decides what each role can do), and **Me**.
Screens and buttons appear only when your permissions allow them; the server re-checks every call.

Checkout with offline SQLite (Drift) is the next milestone (M2).

## Build on your Mac
Requires Flutter (stable, Dart ≥ 3.6), Android Studio or the Android SDK, and Xcode for iOS.

```bash
cd mobile
./tool/setup.sh                       # generates android/ and ios/, adds INTERNET permission, minSdk 24
# edit config/env.json → SUPABASE_KEY = your publishable key (Dashboard → Project Settings → API Keys)
flutter pub get
flutter test                          # money formatting/parsing tests
flutter run --dart-define-from-file=config/env.json
flutter build apk --release --dart-define-from-file=config/env.json
# → build/app/outputs/flutter-apk/app-release.apk
```

A release APK without your own signing key is signed with the debug key (fine for testing, not for Play Store).

## First run
1. Create an account in the app with your email, confirm it from the email, sign in.
2. "Start your store" → you become the owner.
3. Users → Invite user → they create an account with that email and tap **Join**.

Supabase Auth must allow sign-ups (Dashboard → Authentication → Sign In / Providers → Email).

## Notes
- This code was written without a Flutter toolchain available, so it has not been compiled yet. Expect small fixes on first build; paste errors back and they'll be fixed.
- Session tokens live in Keychain / Keystore (`SecureSessionStorage`), never in plain storage.
