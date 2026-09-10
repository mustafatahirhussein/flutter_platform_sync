# Changelog

## 1.0.0 - 2026-09-10

- `compileSdk` and `targetSdk` are now always set to 36, no matter which Flutter version you're targeting. This lines up with Google Play's 16 KB page size requirement, and also fixes a bug (see below) where these two fields were silently never getting updated at all.
- `minSdk` is no longer copied from Flutter's defaults — it's your call, so the tool asks for it directly. Pass `--min-sdk <value>` to skip the prompt, or leave it blank to leave `minSdk` untouched.
- Fixed a bug in the AGP 9 Kotlin migration: if your `kotlinOptions` block had anything in it besides `jvmTarget` (like `freeCompilerArgs`), the tool would remove the old Kotlin plugin line but leave that block completely unconverted — with no warning — which would break your build. It now finds the whole block properly and tells you clearly when it can't convert it automatically.
- Fixed: `compileSdk` and `minSdk` were never actually being synced. The tool was looking for a version constant under a name Flutter doesn't use in any released version, so both fields were quietly skipped every single time, with nothing in the output to suggest anything was wrong.
- Network errors during the version lookup (bad proxy, TLS issues, etc.) now show a normal error message instead of crashing with a raw stack trace.
- Renamed the package from `flutter_android_sync` to `flutter_platform_sync`, ahead of iOS support landing down the line. Nothing about how it behaves has changed — it's still Android/Gradle only for now.

## 0.2.0

- Added support for Flutter's AGP 9 migration: removes the old, now-invalid `kotlin-android` plugin line, updates the `kotlinOptions` block to the new syntax, and adds the `android.newDsl=false` compatibility flag Flutter's migration guide calls for. This fixes the build error you'd otherwise run into: `The 'org.jetbrains.kotlin.android' plugin is no longer required for Kotlin support since AGP 9.0`.
- Fixed a bug where two parts of the tool could end up overwriting each other's edits to the same file. They now share a single read/write pass instead of working from separate copies.
- Tested end-to-end against a real project — dry run, apply, then a clean build — after using it to fix a live AGP 9 failure.

## 0.1.0

- First release. Reads the Gradle/AGP/Kotlin/SDK version numbers straight from Flutter's own source for whichever version you specify.
- Updates `gradle-wrapper.properties`, `settings.gradle.kts` (or the older `build.gradle` layout), and the app-level SDK fields to match.
- Includes a dry-run mode, a confirmation prompt before writing anything, and automatic `.bak` backups.
