# flutter_platform_sync

A command-line tool that updates your Flutter project's Android build
files to match a Flutter version you choose — so you don't have to
hand-edit Gradle files yourself.

> Android only for now. iOS/Xcode support is planned but not here yet.

## What it does

Every Flutter release ships with specific Gradle, AGP, Kotlin, and SDK
version numbers. This tool reads those numbers straight from Flutter's own
source code for the version you specify, then updates your project to
match:

- `android/gradle/wrapper/gradle-wrapper.properties`
- `android/settings.gradle.kts` (or `build.gradle`)
- `android/app/build.gradle.kts` (or `.gradle`)

If you're jumping to a Flutter version that needs Android Gradle Plugin
(AGP) 9+, it also fixes the "Kotlin plugin no longer required" build error
for you automatically.

**Note:** `compileSdk` and `targetSdk` are always set to `36`, regardless
of which Flutter version you pick — this is required for Google Play's
16 KB page size rule. `minSdk` is always your own choice; the tool will
ask you for it.

## Install

You need Dart, which you already have if you have Flutter installed.

```bash
dart pub get
```

## Usage

**1. Dry-run first** — this shows you what would change without touching
any files:

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/project \
  --version 3.35.5 \
  --dry-run
```

**2. If the diff looks right, run it again without `--dry-run`:**

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/project \
  --version 3.35.5
```

You'll be asked to confirm before anything is written, and asked what
`minSdk` you want (just press Enter to leave it unchanged).

**3. Build your project** to make sure everything still works:

```bash
flutter clean
flutter build apk
```

Every file the tool changes gets a `.bak` backup saved next to it, so you
can always undo:

```bash
mv android/app/build.gradle.kts.bak android/app/build.gradle.kts
```

Or, if your project is in git:

```bash
git checkout -- android/
```

## Known limitations

- Only tested against one real project so far — always review the
  dry-run diff before applying, especially on older project layouts.
- Doesn't bump Jetpack Compose's `kotlinCompilerExtensionVersion` — you
  may need to update that yourself after a Kotlin version change.

## License

MIT — see [LICENSE](LICENSE).
