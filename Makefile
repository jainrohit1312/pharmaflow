# PharmaFlow - developer task runner.
#
# Requires `make` (or `mingw32-make` / WSL on Windows), the Flutter SDK and the
# Supabase CLI on PATH. App targets run from `app/`.
#
# Supabase is HOSTED-ONLY. There is no local stack, no Docker and no
# `supabase start`. Migrations reach the linked hosted project via
# `supabase db push`.

.PHONY: help setup migrate migrate-dry link gen watch lint format test test-functions run run-android run-web clean

help:
	@echo "PharmaFlow targets:"
	@echo "  setup         flutter pub get"
	@echo "  migrate       push migrations to the linked hosted project"
	@echo "  migrate-dry   preview what db push would apply (no changes)"
	@echo "  link          print the one-time supabase link command"
	@echo "  gen           run build_runner once (freezed / json_serializable / riverpod)"
	@echo "  watch         run build_runner in watch mode"
	@echo "  lint          custom_lint + flutter analyze"
	@echo "  format        dart format lib test"
	@echo "  test          flutter test"
	@echo "  test-functions  deno test + deno check for the Edge Functions"
	@echo "  run           run the app on Windows"
	@echo "  run-android   run the app on the attached Android device"
	@echo "  run-web       run the app in Chrome"
	@echo "  clean         flutter clean"

setup:
	cd app && flutter pub get

migrate:
	supabase db push

migrate-dry:
	supabase db push --dry-run

link:
	@echo "Run: supabase link --project-ref <your-project-ref>"

gen:
	cd app && dart run build_runner build --delete-conflicting-outputs

watch:
	cd app && dart run build_runner watch --delete-conflicting-outputs

lint:
	cd app && dart run custom_lint && flutter analyze

format:
	cd app && dart format lib test

test:
	cd app && flutter test

# The Edge Functions' gates (N-3). No Docker and no secrets: `deno test`
# type-checks and runs every function test, and one `deno check` per entry point
# covers the wiring, which no test imports. A new function adds a line here.
test-functions:
	deno test supabase/functions
	deno check supabase/functions/ocr-purchase-bill/index.ts
	deno check supabase/functions/match-product/index.ts

run:
	cd app && flutter run -d windows

run-android:
	cd app && flutter run

run-web:
	cd app && flutter run -d chrome

clean:
	cd app && flutter clean
