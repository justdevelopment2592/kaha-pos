# Prototype Android shell

Wraps the UI prototype (`app/src/main/assets/www/index.html`) in a native WebView so it can be installed on a phone or tablet.
**Not the production app**: no Flutter, no SQLite, no Supabase connection. Data stays in the WebView's local storage.

Build: JDK 17+, Android SDK (platform 35, build-tools 35), Gradle 8.11; create `local.properties` with `sdk.dir=…`, then
`gradle assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`
