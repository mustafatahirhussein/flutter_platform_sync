# flutter_platform_sync

A CLI tool that syncs an existing Flutter project's platform-level build
config to match a **target Flutter version** you specify — instead of
hand-editing Gradle/Xcode/Podfile files yourself against Flutter's
migration docs.

> **Current scope: Android only.** The name is platform-neutral on purpose
> — iOS/Podfile/Xcode support is on the roadmap, not shipped yet. Until
> then, "platform sync" means "Android Gradle sync." This note stays here
> and gets removed the day iOS support actually lands, not before.

Right now it syncs Android's `Gradle` / `AGP` (Android Gradle Plugin) /
`Kotlin` / SDK version numbers to match your target Flutter version, via
`gradle-wrapper.properties`, `settings.gradle.kts`, and `build.gradle`.

## How it works

Flutter itself decides what Gradle/AGP/Kotlin/SDK versions a *fresh*
project should use for any given release, via constants in
[`gradle_utils.dart`](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)
inside the `flutter/flutter` repo. This tool fetches that exact file at the
git tag matching the Flutter version you ask for, reads those constants,
and then rewrites the matching values in **your** project's Android files —
so the numbers are always Flutter's own ground truth, not a hand-maintained
table that goes stale.

Files it knows how to update:

- `android/gradle/wrapper/gradle-wrapper.properties` — Gradle wrapper version
- `android/settings.gradle.kts` (or `.gradle`) — AGP + Kotlin plugin versions
  (current declarative-plugins project layout)
- `android/build.gradle` — `ext.kotlin_version` and the AGP `classpath`
  dependency (older, pre-declarative-plugins project layout)
- `android/app/build.gradle.kts` (or `.gradle`) — `compileSdk`, `minSdk`,
  `targetSdk`, `ndkVersion`. **`compileSdk`/`targetSdk` are always pinned to
  36**, not synced from the target Flutter version — see below. **`minSdk`
  is always your own choice**, asked interactively (or via `--min-sdk`),
  never auto-synced either.
- **Built-in-Kotlin migration (v0.2+)** — when the target version's AGP is
  9.0 or higher, AGP rejects the old explicit
  `id("kotlin-android")` / `org.jetbrains.kotlin.android` plugin
  application outright (this is the exact failure you'll hit if you skip
  this: `The 'org.jetbrains.kotlin.android' plugin is no longer required
  ... since AGP 9.0`). The tool now detects this and, in
  `android/app/build.gradle.kts` (or `.gradle`):
  - removes the explicit Kotlin Android plugin line
  - replaces the old `kotlinOptions { jvmTarget = ... }` block with the new
    `kotlin { compilerOptions { jvmTarget = ... } }` block (Kotlin DSL
    projects only — the Groovy block is left alone since it's still valid
    there)
  - adds `android.newDsl=false` to `android/gradle.properties` (the
    temporary compatibility flag Flutter's own migration guide calls for)

  This only fires when the target version's AGP is 9+; it's a no-op for
  older target versions, and a no-op if your project has already migrated
  (nothing left to remove).

- **`compileSdk` / `targetSdk` pinned to 36, `minSdk` asked interactively.**
  Unlike Gradle/AGP/Kotlin/ndkVersion, `compileSdk` and `targetSdk` are
  *not* read from the target Flutter version's template at all — they're
  always set to `36`, regardless of which `--version` you pass. This is
  intentional: 36 is what Play Store's 16 KB memory page size requirement
  needs, independent of your Flutter version, and Flutter's own source
  doesn't expose these constants under a stable name across releases
  anyway. `minSdk` is never auto-set from Flutter's template either — it's
  entirely your call, since it depends on your app's own device-support
  policy, not Flutter's defaults. Pass `--min-sdk <value>` for a
  non-interactive run, or leave it off to be prompted (an empty answer
  leaves `minSdk` untouched in your project).

## Setup

You need the Dart SDK, which you already have if you have Flutter
installed (Flutter ships with `dart`). From this folder:

```bash
dart pub get
```

## Testing this package

There are two different kinds of testing worth doing, and they check
different things — do both before trusting a change.

### 1. Unit tests (fast, no network, no real project needed)

```bash
dart test
```

This runs the tests in `test/`, which check the regex parsing logic
against sample file content directly (e.g. does
`parseGradleVersionsFromSource` correctly pull `9.3.1` / `9.1.0` / `2.4.0`
out of a fake `gradle_utils.dart` body). Fast feedback loop for catching
regressions in the parsing/rewriting logic itself, without touching any
real files or hitting GitHub.

Run this after *any* change to `lib/src/*.dart` before trying it against a
real project.

### 2. Manual/integration testing (slower, needs a real project, actually proves it works)

Unit tests only cover the regex logic in isolation — they don't prove the
tool correctly edits a *real* Gradle file end-to-end, or that the result
actually builds. For that:

1. **Use a disposable test project first, never your production app.**
   `flutter create test_app` gives you a clean, known-good project to
   validate against before pointing this at anything that matters. This is
   exactly what caught the AGP 9 built-in-Kotlin issue during development
   — a unit test alone wouldn't have surfaced that; only building the real
   output did.
2. **Always dry-run before applying:**
   ```bash
   dart run bin/flutter_platform_sync.dart --project /path/to/test_app --version 3.47.0 --dry-run
   ```
   Read every line of the diff. Does each change look like what you'd
   expect from Flutter's own migration docs for that version jump?
3. **Apply, then actually build** — a diff that "looks right" isn't proof;
   the build passing is:
   ```bash
   dart run bin/flutter_platform_sync.dart --project /path/to/test_app --version 3.47.0
   flutter clean && flutter pub get && flutter build apk
   ```
4. **Test more than one project shape.** A single successful run doesn't
   generalize — at minimum, test against:
   - A project on the modern Kotlin-DSL layout (`settings.gradle.kts`)
   - A project still on the older Groovy `build.gradle` layout, if you
     have one — this path is less exercised right now (see Known
     limitations)
   - A version jump that crosses the AGP 9 boundary (to exercise the
     built-in-Kotlin migration) and one that doesn't (to confirm it stays
     a no-op)
   - A project where `compileSdk`/`minSdk`/`targetSdk` reference
     `flutter.compileSdkVersion` etc. rather than hardcoded numbers (should
     result in *no* changes to those fields — that's correct behavior, not
     a miss)
5. **Keep the `.bak` files until the build is confirmed working**, and
   ideally only test on projects already under version control so you have
   a second safety net beyond the tool's own backups.

If you find a project shape where the diff looks wrong or the build breaks
in a way the tool should have caught, that's exactly the kind of case
worth turning into a new fixture in `test/` — paste the relevant file
content and it can be added as a regression test.

## Usage

**Always dry-run first** on a project that has no uncommitted changes
(or better — a project inside a git repo, so you can diff/revert easily
regardless of the `.bak` files this tool also creates):

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/flutter/project \
  --version 3.47.0 \
  --dry-run
```

You'll be prompted for `minSdk` (blank = leave it untouched) unless you pass
`--min-sdk <value>` up front — do that for a non-interactive/CI run.
`compileSdk`/`targetSdk` need no input; they're always pinned to `36`.

Review the printed diff. If it looks right, run it again without
`--dry-run` (it will ask for a `y/N` confirmation before touching
anything):

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/flutter/project \
  --version 3.47.0
```

Add `--yes` to skip the confirmation prompt (useful in CI, not recommended
for your first run on a real project).

Every file the tool modifies gets a `<filename>.bak` copy written
alongside it first (only on the *first* run — it won't overwrite an
existing `.bak`, so you always keep your true original). To revert:

```bash
mv android/app/build.gradle.kts.bak android/app/build.gradle.kts
# repeat for any other .bak files it created
```

Or, since you're presumably in git anyway:

```bash
git checkout -- android/
rm android/**/*.bak
```

After applying, actually build the project before trusting it:

```bash
flutter clean
flutter build apk   # or: flutter run
```

## Known limitations

- Only validated so far against one real project, through one specific
  failure mode (the AGP 9 built-in-Kotlin break). Review every dry-run
  diff before applying, especially on less common project layouts — the
  older Groovy `build.gradle`/`settings.gradle` path in particular hasn't
  been exercised against a real Groovy project yet.
- If your project uses Jetpack Compose, a Kotlin version bump sometimes
  needs a matching `composeOptions { kotlinCompilerExtensionVersion = "..."
  }` update too — this tool doesn't handle that yet. If your build fails on
  a Compose/Kotlin mismatch after running this, that's why.

## License

See `LICENSE`.
