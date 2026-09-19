# PharmaFlow — Deploying the Web App to Vercel

Web is the primary platform (D-005, D-059), and Vercel is where it is hosted. This
file is the runbook for that one deploy: importing the repository, the values the
Vercel dashboard needs, what the build does, and how to prove the result.

> **Status of this file.** `app/vercel.json` and this document are **written and
> not run** — no Vercel project exists yet (N-11). The parts that could be checked
> locally were: **`flutter build web --release` was run on this tree** and produced
> `build/web` (exit 0, ~5 minutes), with `index.html`, `flutter_service_worker.js` and
> the credentials at **`assets/.env`** — the path §5's second check reads, verified
> rather than assumed; the `.env` asset is what carries the Supabase project into the
> bundle; the generated Dart files that the build regenerates are gitignored; and the
> build command is valid POSIX shell (see §4). **The deploy itself has not been run**,
> so treat the first one as the test of this file.

---

## 0. What this deploys, and what it does not

| Piece | Where it lives |
| --- | --- |
| Database, Auth, RLS, Edge Functions | Hosted Supabase (`yeroxzkpmodbzcvjlqwd`, Mumbai) — **already deployed** |
| The Flutter client, compiled to static files | **Vercel** — this document |
| Android | A sideloading APK, built by hand (`docs/DEPLOYMENT.md` §3.1, D-061) |

The client is **self-contained**: it authenticates against Supabase and calls the
Edge Functions over HTTPS with the publishable key. Nothing about the running site
needs a server, a build step, or a runtime environment variable of ours — so the
deploy is "build some static files, serve them".

Two consequences worth knowing before starting:

- **The Supabase URL and key are compiled into the bundle.** `pubspec.yaml`
  declares `.env` under `assets:`, and `flutter_dotenv` reads it at runtime through
  `rootBundle`. `.env` is gitignored, so the build has to *create* it from the
  environment variables Vercel supplies — which is the only reason those variables
  matter at deploy time.
- **The publishable (`anon`) key is public by design.** It identifies the project;
  Row Level Security is what protects the data. A `service_role` key in a browser
  bundle would hand every visitor the whole database — it must never appear here.

---

## 1. Prerequisites

- A Vercel account, with this repository reachable from it (GitHub/GitLab/Bitbucket).
- The branch you intend to be production (`main`).
- The two values from Supabase → **Project Settings → API**:
  - `SUPABASE_URL` — `https://<project-ref>.supabase.co`
  - `SUPABASE_ANON_KEY` — the publishable / anon key (not `service_role`).

And, on the commit you are about to deploy, the repository's own gates must be
green (`docs/DEPLOYMENT.md` §1) and the database must be at the repository's
version:

```powershell
supabase migration list     # local and remote 1:1 (30/30)
```

---

## 2. Import the repository

1. Vercel dashboard → **Add New… → Project** → **Import** the `pharmaflow` repository.
2. Set the project's build settings **exactly** as follows:

   | Setting | Value |
   | --- | --- |
   | **Framework Preset** | **Other** |
   | **Root Directory** | **`app`** |
   | **Build Command** | *(leave the default — `app/vercel.json` overrides it)* |
   | **Install Command** | *(see below)* |
   | **Output Directory** | *(leave the default — `app/vercel.json` overrides it)* |

   `app/vercel.json` sets `buildCommand`, `installCommand` and `outputDirectory`
   for every deployment, and a value set there **overrides** the dashboard field.
   So the two "leave the default" rows are not laziness: the file is the source of
   truth, and the dashboard showing empty/derived values is the expected state.

   Framework Preset **Other** still matters, because it is what stops Vercel from
   guessing at a framework and rewriting the build. `"framework": null` in
   `app/vercel.json` sets the same thing.

3. **Do not** set an Install Command in the dashboard. There is no `package.json`
   in this repository; `app/vercel.json` sets it to the empty string, which tells
   Vercel to skip the install step entirely, and everything the build needs is
   done by the build command.

### Why the Root Directory is `app`

`app/` is the Flutter project: `pubspec.yaml`, `lib/`, `web/`, `test/`. Pointing
Vercel at it means the build command runs *inside* the project, so
`flutter build web --release` writes `app/build/web` and the Output Directory is
the simple relative `build/web`.

### Why the SPA rewrite is there even though nothing needs it yet

The rewrite is **defensive**. The router uses hash URLs today (`/#/login`), so the
server never sees a deep path and a deep link cannot 404. It is in the config so that
switching to path-based URLs later is a client change and not a hosting change — and
because a rewrite is checked *after* the filesystem, it cannot shadow a real asset.

---

## 3. Environment variables

Vercel → the project → **Settings → Environment Variables**. Add both, for
**Production** and **Preview**:

| Name | Value | Notes |
| --- | --- | --- |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` | From Supabase → Project Settings → API |
| `SUPABASE_ANON_KEY` | the publishable / anon key | **Never** `service_role` |

Optional, and only if you want a Flutter version other than the pinned one:

| Name | Value | Notes |
| --- | --- | --- |
| `FLUTTER_VERSION` | e.g. `3.44.8` | Defaults to `3.44.8`, the SDK this app is developed against (`PROGRESS.md` → Environment) |

**Neither is a secret in the ordinary sense** — both end up inside a bundle that
anyone can download — but they must be *set*, because the build turns them into
the `.env` asset. There is no `.env` in the repository to fall back on.

> Rotating the anon key means **rebuilding and redeploying**; there is nothing to
> change in Vercel's settings at run time, because the value is not read at run
> time.

---

## 4. What the build actually does

`app/vercel.json`'s `buildCommand` is one shell command, run inside `app/`. In
order:

1. `export FLUTTER_SUPPRESS_ANALYTICS=true`, and put `$HOME/flutter/bin` on `PATH`.
2. Download the pinned Flutter SDK for Linux and unpack it to `$HOME/flutter`.
   Vercel's build image is Amazon Linux 2023 and **does not ship Flutter** — this
   is the step that costs minutes on every deploy, because nothing outside the
   project directory survives between builds.
3. `git config --global --add safe.directory "$HOME/flutter"` — the SDK is a git
   checkout, and its version check shells out to `git`, which refuses to read a
   repository owned by someone else.
4. `flutter --version` — prints the version **into the build log**, which is how
   you confirm the deploy used the SDK you meant.
5. `flutter pub get`.
6. `dart run build_runner build --delete-conflicting-outputs` — **required, and
   easy to miss.** The freezed / json_serializable / riverpod `.g.dart` and
   `.freezed.dart` files are **gitignored** (see the root `.gitignore`), so a
   fresh clone does not have them and the app does not compile without them.
7. Write `.env` from `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
8. `flutter build web --release` → `app/build/web`.

If you would rather not pay for steps 2 and 6 on every push, build the bundle
elsewhere and deploy the static output instead — that route is in
`docs/DEPLOYMENT.md` §2.2 (`vercel deploy app/build/web --prod`). It deploys the
same files; it just does the work before Vercel sees them.

**What has and has not been checked.** `flutter build web --release` (step 8) has been
run on this tree and succeeds; `app/vercel.json` parses as JSON; and the build command's
shell syntax is valid (`bash -n`). **Steps 2, 3, 5, 6 and 7 have never run anywhere** —
in particular nobody has confirmed that the Flutter archive URL resolves for the pinned
version, which is the first thing the first deploy will tell you (§7).

---

## 5. Deploy

Push to the production branch, or press **Deploy** in the dashboard. A Git
connection deploys on every push; the dashboard shows the build log, and the
project's URL is on the project page (`https://<project-name>.vercel.app`).

Then verify it — **from the shell with `curl`, not by driving a browser**. A
status line and a header dump settle whether the bundle is served and whether the
function gateway answers, and they are reproducible:

```powershell
# 1. The app is served, and it is the app.
curl -s -o nul -w "%{http_code}\n" https://<your-domain>/
curl -s https://<your-domain>/ | findstr /I "pharmaflow flutter"

# 2. The deployed bundle knows which project it belongs to (the key is public).
#    The credentials land at assets/.env — flutter_dotenv's own default path, checked
#    against a real `flutter build web` output rather than assumed.
curl -s https://<your-domain>/assets/.env | findstr /I "SUPABASE_URL"

# 3. The service worker is not cached, so a new deploy takes effect.
curl -s -D - -o nul https://<your-domain>/flutter_service_worker.js | findstr /I "cache-control"

# 4. The function gateway answers, with CORS, unauthenticated.
curl -s -D - -o nul -X POST "https://<project-ref>.supabase.co/functions/v1/chat-sql-agent" ^
  -H "Origin: https://<your-domain>" -H "content-type: application/json" -d "{}"

# 5. ...and a preflight does too.
curl -s -D - -o nul -X OPTIONS "https://<project-ref>.supabase.co/functions/v1/chat-sql-agent" ^
  -H "Origin: https://<your-domain>" -H "Access-Control-Request-Method: POST"
```

`findstr` is case-sensitive: use `/I` whenever the question is *"is this
present?"* (D-038).

Check 2 is the one that catches the most likely mistake silently: if
`SUPABASE_URL`/`SUPABASE_ANON_KEY` were not set at build time, the bundle still
loads and then fails on the first request with a configuration error.

Finally, **in the browser**, sign in with a real account and work one sale and one
purchase end to end. That is the only step that proves the deploy is *usable* —
the curls prove it is *served*.

---

## 6. Custom domain (optional)

Vercel → the project → **Settings → Domains → Add**. Add the domain, then follow
the DNS instructions (an `A` record for the apex, a `CNAME` for a subdomain;
Vercel issues the certificate itself).

Two things to do once the domain is live:

- Re-run the checks in §5 against the new hostname.
- Supabase → **Authentication → URL Configuration**: add the domain to **Site
  URL** and **Redirect URLs**, so a confirmation email or a password reset sends
  the user back to the deployed app rather than to `localhost`. The hosted project
  requires email confirmation (D-060), so this is on the critical path the first
  time somebody signs up.

---

## 7. When it fails — the ones worth recognising

| Symptom | Cause, and what to do |
| --- | --- |
| `curl: (22) … 404` on the Flutter tarball in the build log | The pinned version has no Linux archive under that name. Check the real archive names in `https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`, then set `FLUTTER_VERSION` to a version that exists (and, if you change it, re-run `flutter test` locally against it). |
| Build fails at `flutter pub get` with "no pubspec.yaml" | The Root Directory is not `app`. |
| Build succeeds, site is blank/white, console shows a configuration error | The environment variables were not set for this environment, so `.env` was written empty. Check §3, then **redeploy** — the values are baked in at build time, so a change needs a new build, not a restart. |
| `dart run build_runner` fails with "because of conflicting outputs" | The `--delete-conflicting-outputs` flag is missing from the build command; it is in `app/vercel.json`. |
| A deep link (e.g. `https://<domain>/login`) 404s | The SPA rewrite is not being applied — check that `app/vercel.json` exists in the repository **and** that Root Directory is `app` (§8). |
| The site shows an old version after a deploy | A cached service worker. The header in `app/vercel.json` prevents the *served* file from being cached; if a browser is still stale, a hard reload clears it once. |
| The build log shows `warning: … dubious ownership` | `git config --global --add safe.directory` did not run (step 3 of §4). |
| "Build Command" in the dashboard looks empty | Expected: `app/vercel.json` overrides it. If you would rather drive it from the dashboard, copy the command out of `app/vercel.json` into the field. |

---

## 8. Why `vercel.json` lives in `app/`, not at the repository root

Vercel reads `vercel.json` from the **project's root directory**, which is the
Root Directory setting — and with a Root Directory configured, the build *cannot
read files outside it*. So with **Root Directory: `app`**, the file Vercel reads
is `app/vercel.json`, and a copy at the repository root would be silently ignored
(the build would then find no Flutter SDK, no `build_runner` step and no
Supabase values, and fail in a way that looks like anything but a misplaced file).

The two arrangements that work, and the one that does not:

| Root Directory | `vercel.json` at | Result |
| --- | --- | --- |
| `app` | `app/vercel.json` | **This repository's choice.** Paths are relative to `app/`: `build/web`. |
| *(empty)* | repository root | Also works, but every command needs `cd app &&` and Output Directory becomes `app/build/web`. |
| `app` | repository root | **Broken.** The file is outside the Root Directory and is never read. |

---

## 9. What this document does not cover

- **Android** — the sideloading APK is `docs/DEPLOYMENT.md` §3.1; Play publication
  is §3.2–3.5 and is publish-time work (D-061).
- **iOS** — out of scope for this phase (D-059).
- **The Supabase side** — migrations, the Edge Functions and their secrets are
  `docs/DEPLOYMENT.md` §6. `WHATSAPP_TOKEN` and `SENDGRID_API_KEY` are still
  unset, so a dispatch answers `skipped`.
- **The user manual's screenshot pass** — it wants a live URL first; the manual is
  `docs/USER_MANUAL.md`.
