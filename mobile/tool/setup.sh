#!/usr/bin/env bash
# One-time: generate the Android/iOS folders around lib/ and apply Kaha's platform settings.
# Works on macOS and Linux (uses perl for in-place edits).
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --org com.kaha --project-name kaha_pos --platforms=android,ios .

# Release builds need the internet permission (Flutter only adds it to debug/profile).
MAN=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.INTERNET' "$MAN"; then
  perl -0pi -e 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MAN"
fi

# flutter_secure_storage needs Android 6+; Kaha targets Android 7+ (API 24).
for G in android/app/build.gradle.kts android/app/build.gradle; do
  [ -f "$G" ] || continue
  perl -pi -e 's/minSdk(Version)?\s*=?\s*flutter\.minSdkVersion/minSdk = 24/' "$G"
done

[ -f config/env.json ] || cp config/env.example.json config/env.json
echo
echo "Done. Put your publishable key in config/env.json, then:"
echo "  flutter run --dart-define-from-file=config/env.json"
echo "  flutter build apk --release --dart-define-from-file=config/env.json"
