# Changelog

## 1.0.0 - 2026-09-10

- `compileSdk` and `targetSdk` are now pinned to `36` unconditionally,
  instead of being parsed out of Flutter's `gradle_utils.dart` for the
  target version. Two reasons: the constant name Flutter uses for these
  fields isn't stable across releases (this was previously a silent no-op
  on every real Flutter tag — see below), and 36 is the correct floor
  regardless of Flutter version anyway, to satisfy Play Store's 16 KB
  memory page size requirement.
- `minSdk` is no longer auto-synced from Flutter's template default at all.
  It's now always the user's own call: pass `--min-sdk <value>`, or leave
  it off to be prompted interactively (blank answer = leave `minSdk`
  untouched in the project).
- Fixed: `compileSdk`/`minSdk` sync was silently a no-op against every real
  Flutter release — the old extraction looked for a `compileSdkVersionInt`
  /`minSdkVersionInt` constant that doesn't exist in any published (or even
  pre-release) `gradle_utils.dart`; real sources declare these as plain
  string constants (`compileSdkVersion`/`minSdkVersion`), so the regex
  never matched and the fields were quietly skipped with no warning. The
  new pin/prompt approach sidesteps this parsing entirely rather than
  trying to patch the regex again.
- Renamed package from `flutter_android_sync` to `flutter_platform_sync`
  ahead of planned iOS/Podfile/Xcode support, so the name doesn't need to
  change again once that lands. Functionality unchanged — still Android
  Gradle-only for now (see README scope note).

## 0.2.0

- Added automatic AGP 9+ built-in-Kotlin migration: removes the now-invalid
  explicit `id("kotlin-android")` / `org.jetbrains.kotlin.android` plugin
  application in `app/build.gradle.kts` (or `.gradle`), replaces the old
  `kotlinOptions { jvmTarget = ... }` block with the new
  `kotlin { compilerOptions { jvmTarget = ... } }` block, and adds
  `android.newDsl=false` to `gradle.properties`. Fixes the build failure:
  `The 'org.jetbrains.kotlin.android' plugin is no longer required for
  Kotlin support since AGP 9.0`.
- Fixed a bug where the SDK-field rewriter and the built-in-Kotlin migration
  would have independently rewritten the same `app/build.gradle.kts` file
  from two separately-read copies, silently discarding whichever change
  applied first. Both now operate on one shared, sequential read/write pass
  per file.
- Verified end-to-end against a real project: dry-run → apply → clean build
  succeeding after hitting and fixing a live AGP 9 build failure.

## 0.1.0

- Initial version. Fetches Gradle/AGP/Kotlin/SDK version constants for a
  target Flutter release directly from `flutter/flutter`'s
  `gradle_utils.dart` at the matching git tag.
- Syncs `gradle-wrapper.properties`, `settings.gradle.kts` (or the legacy
  `android/build.gradle` classpath/`ext.kotlin_version` layout), and
  `app/build.gradle(.kts)` SDK fields to those versions.
- Dry-run mode, confirmation prompt before writing, automatic `.bak` backup
  of every file touched.
