# PharmaFlow — Deployment Runbook

How to put PharmaFlow in front of a real pharmacy. The target order is
**Web (primary) → Android (secondary) → Windows (optional)**, with **iOS out of
scope** for now (it needs a Mac; the procedure is written out below for whoever has
one).

> **Status of this file.** The **Android sideload APK has been built and shipped**
> (section 3.1, D-061) — that is the one step here that has been executed. The
> **Vercel deploy now has a configuration and its own runbook** (`app/vercel.json`
> and [`docs/DEPLOY_VERCEL.md`](DEPLOY_VERCEL.md), §2 below), and **neither has been
> run**: nothing has been imported into Vercel yet, so the first deploy is the test of
> both. The publish-time Android keystore and Play listing, and the iOS runbook, are
> written to be runnable and **have not been run** either. Where a step was verified
> in development, it says so.

---

## 0. What the deployment actually is

Three independent pieces, and it helps to keep them apart:

| Piece | Where it lives | Accounts needed |
| --- | --- | --- |
| Database, Auth, RLS, Edge Functions | Hosted Supabase (project `yeroxzkpmodbzcvjlqwd`, Mumbai `ap-south-1`) | Supabase |
| The Flutter client | Static hosting (Vercel) for web; a store/APK for Android | Vercel; Google Play (Android) |
| Provider credentials | Supabase Edge Function secrets | Meta (WhatsApp Cloud API), SendGrid, Firebase |

The client is **self-contained**: it talks to Supabase directly with the
publishable (`anon`) key, so hosting it needs no backend of its own. There is no
server to deploy, and no runtime environment variables to configure at the host:
the Supabase URL and key are **compiled into the bundle** (see the `.env` note
below).

---

## 1. Before deploying anything

These are the same gates the repository uses for every handoff. All of them must
pass, on the commit you are about to ship:

```powershell
cd app
dart format lib test
dart run build_runner build --delete-conflicting-outputs
dart run custom_lint
flutter analyze
flutter test            # 637 tests

cd ..
deno test supabase/functions          # 181 tests
deno check supabase/functions/ocr-purchase-bill/index.ts
deno check supabase/functions/match-product/index.ts
deno check supabase/functions/backfill-embeddings/index.ts
deno check supabase/functions/send-notification/index.ts
deno check supabase/functions/chat-sql-agent/index.ts

supabase migration list               # local and remote must match 1:1 (30/30)
```

And the database must be at the same version as the repository:

```powershell
supabase link --project-ref yeroxzkpmodbzcvjlqwd
supabase db push --yes
```

---

## 2. Web (Vercel) — primary target

### 2.1 The `.env` problem, first

`flutter build web` compiles `app/.env` **into the bundle** as an asset, because
`flutter_dotenv` reads it at runtime through `rootBundle` and `pubspec.yaml` declares
it under `assets:`. So:

- `.env` must exist **at build time**, not at run time. `.env` is gitignored, so the
  build step must create it.
- The key in it is the **publishable/anon** key. That is public by design — it
  identifies the project, and Row Level Security is what protects the data. **Never**
  put a `service_role` key in the client.
- Rotating the key means rebuilding and redeploying the web bundle. There is nothing
  to change in Vercel's environment settings.

Two ways to supply it, pick one and be consistent:

```powershell
# Local / CI shell: create the file, then build.
Copy-Item app\.env.example app\.env
#   ... fill in SUPABASE_URL and SUPABASE_ANON_KEY ...

cd app
flutter build web --release            # -> app/build/web
```

Or, if the build runs in a container that has the two values as environment
variables, write them out before building:

```bash
printf 'SUPABASE_URL=%s\nSUPABASE_ANON_KEY=%s\n' "$SUPABASE_URL" "$SUPABASE_ANON_KEY" > app/.env
```

### 2.2 Deploying

**The repository now ships the config for this route: `app/vercel.json`, documented
step by step in [`docs/DEPLOY_VERCEL.md`](DEPLOY_VERCEL.md).** Import the repo into
Vercel, set **Root Directory** to `app`, set the two environment variables, and push.
That file installs the Flutter SDK in the build container, regenerates the
`build_runner` output (which is gitignored, so a fresh clone has no `.g.dart` files
at all), writes `.env` from `SUPABASE_URL`/`SUPABASE_ANON_KEY`, and builds — because
Vercel's build image does **not** ship the Flutter SDK, and nothing outside the
project directory survives between builds, every deploy spends minutes installing it.

If you would rather not pay that on every push, the alternative is still valid:
**build the static bundle, deploy the output**. Nothing about the running site needs
Flutter.

```powershell
flutter build web --release            # inside app/ -> app/build/web
npm i -g vercel
vercel login
vercel deploy app\build\web --prod     # static output; no build step on Vercel
```

The prebuilt route needs the Supabase values **at build time** either way (§2.1), and
`vercel deploy <dir>` deploys that directory as the whole site — so if you use it,
leave the Vercel project's Root Directory unset and ignore `app/vercel.json`, which
belongs to the other route.

Whichever route you take, `app/vercel.json` carries the two things this app needs on
top of static file serving: the **SPA rewrite** (every route to `index.html`, so a
deep link is not a 404) and a **`no-cache` header on `flutter_service_worker.js`** — a
cached service worker is how a web deploy "does not take" for a user who has already
visited.

### 2.3 What to verify after the first deploy

Verify the deploy **from the shell with `curl`**, not by driving a browser — a
status line and a header dump settle whether the bundle is served and whether the
function gateway answers, and they are reproducible:

```powershell
# 1. The app is served, and it is the app.
curl -s -o nul -w "%{http_code}\n" https://<your-domain>/
curl -s https://<your-domain>/ | findstr /I "pharmaflow flutter"

# 2. The deployed bundle knows which project it belongs to (the key is public).
curl -s https://<your-domain>/assets/assets/.env | findstr /I "SUPABASE_URL"

# 3. The function gateway answers, with CORS, unauthenticated.
curl -s -D - -o nul -X POST "https://yeroxzkpmodbzcvjlqwd.supabase.co/functions/v1/chat-sql-agent" ^
  -H "Origin: https://<your-domain>" -H "content-type: application/json" -d "{}"

# 4. ...and a preflight does too.
curl -s -D - -o nul -X OPTIONS "https://yeroxzkpmodbzcvjlqwd.supabase.co/functions/v1/chat-sql-agent" ^
  -H "Origin: https://<your-domain>" -H "Access-Control-Request-Method: POST"
```

`findstr` is case-sensitive: use `/I` whenever the question is *"is this present?"*.

Then, in the browser, sign in with a real account and work one sale and one purchase
end to end. That is the only step that proves the deploy is *usable*.

`flutter build web --release` has been verified locally; the Vercel deploy itself
has **not** been run.

---

## 3. Android — secondary target

The camera is why Android matters: photographing supplier bills is the workflow web
handles worst.

**Phase 6 ships a sideloading APK, and a debug-signed one** (D-061): a release-mode build
signed with the debug key, installed on staff devices by USB or a file share. No upload
keystore, no `key.properties`, no signing config change, and **no Play Store listing**.
The sections after 3.1 are the **publish-time** work, kept here because this file is
where a future maintainer will look for it.

### 3.1 The APK that ships

```powershell
cd app
flutter build apk --release        # -> build/app/outputs/flutter-apk/app-release.apk
```

`--release` means the build is AOT-compiled and carries no debug banner: it is a real
build of the app. It is *signed* with the debug key, which affects only how Android
attributes the install — sideloading is unaffected. `build.gradle.kts` already declares
`signingConfig = signingConfigs.getByName("debug")` for the release type (the Flutter
template's default), which is exactly what this target wants, so no code changes.

To install: copy `app-release.apk` to the device (USB, or a file share the device can
reach), allow installation from that source, and tap the file. The exact wording differs
by vendor. The app needs network access and, for the bill reader, camera permission.

> **When Play publication eventually happens, every staff device has to uninstall and
> reinstall once.** Android identifies an app by its signing key, so it refuses to update
> an install signed with a different key. That is the accepted cost of not creating a
> keystore before there was a reason to (D-061).

### 3.2 A release keystore, at publish time (never in git)

```powershell
keytool -genkeypair -v -keystore %USERPROFILE%\pharmaflow-upload.jks ^
  -storetype JKS -keyalg RSA -keysize 2048 -validity 9125 ^
  -alias pharmaflow-upload
```

Keep `pharmaflow-upload.jks` **outside the repository** and back it up: losing it
means never being able to update the app on Play under the same listing. Record the
alias and the passwords in whatever your team uses for secrets.

Then add `app/android/key.properties` (gitignored):

```properties
storePassword=<the keystore password>
keyPassword=<the key password>
keyAlias=pharmaflow-upload
storeFile=C:/Users/<you>/pharmaflow-upload.jks
```

### 3.3 Wire the signing config (publish time; nothing to do for the sideload APK)

`app/android/app/build.gradle.kts` signs `release` with the **debug** keys — the Flutter
template's default, and what D-061 relies on. At publish time, replace that with the real
config:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    // ...
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}
```

`key.properties` and `*.jks` must both be gitignored before this lands.

### 3.4 Build the AAB (publish time)

```powershell
cd app
flutter build appbundle --release      # -> build/app/outputs/bundle/release/app-release.aab   (Play)
flutter build apk --release            # -> build/app/outputs/flutter-apk/app-release.apk     (sideload)
```

The app needs `INTERNET` (already declared by the Flutter template) and camera
access for the bill reader — `mobile_scanner` and `image_picker` are behind guarded
paths, so a device without a camera still runs everything else.

### 3.5 Play Console (publish time)

Play is mostly paperwork that only the account holder can do. **None of it is in scope
for Phase 6** (D-061); it is here for when the publish decision is made.

1. Create the app in Play Console; the package id is `com.pharmaflow.app`.
2. Complete **App content**: privacy policy URL, data safety form (the app sends
   bill images to the Gemini API and stores data in Supabase — say so), target
   audience, and the fact that it is a business tool.
3. Upload the `.aab` to an **internal testing** track first, and test the camera
   flow on a real device from that track.
4. Only then promote to production. Note that Google requires a closed test with a
   minimum number of testers before a new personal developer account can publish.

An APK built and installed by hand (step 3.3) is enough to test the OCR flow before
any of that — and the app's release signing config is what has to exist first.

---

## 4. iOS — out of scope, with the runbook for later

iOS cannot be built on Windows at all: the toolchain, the codesigning and the
upload all need macOS with Xcode. Nothing about the app blocks it — the platform is
configured (`app/ios/`) and the plugins it uses are the same ones Android uses — so
the work is the procedure below, on a Mac:

```bash
# On a Mac with Xcode and CocoaPods installed
cd app
flutter pub get
flutter build ipa --release           # -> build/ios/ipa/*.ipa
```

Then either:

- **Xcode Organizer**: open `app/ios/Runner.xcworkspace`, set the team and the
  bundle id (`com.pharmaflow.app`), and use *Distribute App → App Store Connect*.
- **CLI**: `xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios -u <apple-id> -p <app-specific-password>`,
  or `xcrun notarytool`-style equivalents on newer Xcode.

App Store Connect needs: the app record, the bundle id registered under your Apple
Developer account, a privacy policy URL, the export-compliance answer (the app uses
HTTPS only), and app privacy details covering the same data the Play data-safety
form declares. TestFlight then takes the build before release.

---

## 5. Windows — optional

The build was broken (STL1011) and is **fixed**: `app/windows/CMakeLists.txt` now
defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` for
`permission_handler_windows_plugin`, which compiles through
`<experimental/coroutine>` — a hard error under MSVC 14.51 (Visual Studio 2026).

`flutter build windows --debug` **was run and produced
`build\windows\x64\runner\Debug\app.exe`**. The **release** build was not verified
(deliberately: the debug build already proves the CMake fix, and a release build
costs minutes of toolchain time). Run this once on a machine with Visual Studio
before shipping a desktop build:

```powershell
cd app
flutter build windows --release
```

Windows is not a launch target: the desktop use case is covered by the web app.

---

## 6. Supabase Edge Function secrets

Five functions are deployed. The **Gemini** key is already set for the three that
need it; the WhatsApp and SendGrid secrets are **not set** — a dispatch without them
is recorded as `skipped` and names the missing secret, which is the honest answer
and the reason the dispatch log exists.

```powershell
supabase secrets set GEMINI_API_KEY=<gemini api key>

# Only once the provider accounts exist:
supabase secrets set WHATSAPP_TOKEN=<meta cloud api token>
supabase secrets set WHATSAPP_PHONE_NUMBER_ID=<meta phone number id>
supabase secrets set SENDGRID_API_KEY=<sendgrid key>
supabase secrets set SENDGRID_FROM_EMAIL=<a verified sender address>
```

Redeploy after changing a function, and read the secrets back only as names:

```powershell
supabase functions deploy chat-sql-agent
supabase secrets list
```

### 6.1 Proving a dispatch works, once the secrets exist

`send-notification` answers **200** with `status: sent|failed|skipped` for any
well-formed request, because the row is written first and the outcome is recorded on
it. So the check is the `status` field, not the HTTP class:

```powershell
curl -s -X POST "https://yeroxzkpmodbzcvjlqwd.supabase.co/functions/v1/send-notification" ^
  -H "Authorization: Bearer <a signed-in user's access token>" ^
  -H "content-type: application/json" ^
  -d "{\"channel\":\"whatsapp\",\"to\":\"+91XXXXXXXXXX\",\"recipient_type\":\"user\",\"notify_user_id\":\"<your own user id>\",\"type\":\"probe\",\"title\":\"PharmaFlow deployment probe\"}"
```

A `skipped` answer names the missing secret; a `sent` answer proves the credential,
the provider call and the log row together. The access token must come from a real
sign-in — the hosted project requires email confirmation, and the guard that refuses
a hand-edited `auth.users` row is correct.

---

## 7. Post-deploy checklist

- [ ] All gates pass on the shipped commit (section 1)
- [ ] `supabase migration list` shows local and remote matching (30/30)
- [ ] `flutter build web --release` succeeds and the deploy serves it
- [ ] The deployed bundle's `.env` asset names the right Supabase project
- [ ] The function gateway answers a POST and a preflight, with CORS
- [ ] One sale end to end in the browser, on the deployed URL
- [ ] One purchase received end to end, and the stock moved once
- [ ] The account policy for email confirmation is the one you meant: **on**, with
      accounts confirmed by hand in the dashboard (D-060 — settled, no action needed)
- [ ] The sideload APK installs on a staff device and the bill reader can use the camera
- [ ] A bill printed (web: PDF; Windows: native dialog)
- [ ] `send-notification` answers `sent` (once the WhatsApp/SendGrid secrets exist)

---

## 8. What is still outstanding

Honest list, current as of Phase 6 chunk 3:

| Outstanding | Needs |
| --- | --- |
| Vercel web deploy | **Configured, not run.** `app/vercel.json` + `docs/DEPLOY_VERCEL.md` are written; the Vercel account exists; the project has not been imported and no deploy has been made |
| Android APK for sideloading | **Shipped** — `flutter build apk --release`, debug-signed (D-061, §3.1) |
| Play Store publication | A generated keystore, a Google Play developer account, privacy policy and data-safety form — and one uninstall/reinstall per staff device (D-061) |
| WhatsApp/email dispatch (alerts, auto-send PO) | Meta WhatsApp Cloud API + SendGrid accounts |
| Push notifications | A Firebase project and the web service worker |
| iOS | A Mac |
| The vector-similarity floor re-measurement | A catalogue of 50+ products (it was measured against one) |
