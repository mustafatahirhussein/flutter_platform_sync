# Example

`flutter_platform_sync` is a command-line tool, not a library you import —
so "using" it just means running it against a Flutter project.

Install dependencies once:

```bash
dart pub get
```

See what would change, without touching any files:

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/flutter/project \
  --version 3.35.5 \
  --dry-run
```

If the diff looks right, run it again without `--dry-run` to apply it:

```bash
dart run bin/flutter_platform_sync.dart \
  --project /path/to/your/flutter/project \
  --version 3.35.5
```

You'll be asked to confirm before anything is written, and asked what
`minSdk` you want (press Enter to leave it unchanged). See the main
[README](../README.md) for the full list of options.
