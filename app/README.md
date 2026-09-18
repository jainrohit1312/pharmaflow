# PharmaFlow — Flutter client

The client for **PharmaFlow**, a multi-tenant Pharmacy ERP for Indian retail
pharmacies. Flutter for Android, iOS, Web and Windows; Supabase (hosted
PostgreSQL + Auth + Row Level Security) for the backend.

The [root README](../README.md) is the source of truth for the tech stack,
workspace layout, hosted-Supabase setup, migration workflow and the phase
roadmap. This file only covers working inside `app/`.

## Quick start

```powershell
flutter pub get
Copy-Item .env.example .env      # then fill in the hosted URL + anon key
dart run build_runner build --delete-conflicting-outputs
flutter run -d windows
```

`dart run build_runner build` is **required**: `.g.dart` / `.freezed.dart` are
gitignored, so a fresh clone does not compile until codegen has run.

## Quality gates

```powershell
dart run custom_lint       # riverpod_lint diagnostics (fatal on info)
flutter analyze
dart format lib test
flutter test
```

## Layout

| Path | Contents |
| --- | --- |
| `lib/core/` | constants, theme, router, errors, utils, shared widgets |
| `lib/data/` | Freezed models, Supabase datasource, repositories, mappers |
| `lib/domain/` | entities, usecases |
| `lib/features/` | `auth`, `dashboard`, and one folder per Phase 1+ module |
| `lib/services/` | notification / OCR / WhatsApp / email stubs |
| `lib/main.dart`, `lib/app.dart`, `lib/bootstrap.dart` | entrypoint, root widget, boot sequence |
| `test/` | unit tests (no codegen, no network) |

## Cross-platform rules

`mobile_scanner`, `image_picker` (camera) and `permission_handler` are not
imported unconditionally. Guard platform-specific code with
`lib/core/utils/platform.dart` (`isWeb` / `isDesktop` / `isMobile`), and never
touch `dart:io` `Platform` without a `!kIsWeb` short-circuit first — it throws
`UnsupportedError` on the web.

## Dependency constraints to leave alone

- `environment.sdk: ^3.8.0` — `json_serializable` needs language 3.8+ for the
  null-aware elements it generates.
- `riverpod_lint: '>=3.0.0 <3.1.0'` — 3.1.8 renamed its entrypoint and
  `custom_lint` 0.8.1 cannot load it.

Both are explained inline in `pubspec.yaml`.
