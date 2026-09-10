import 'dart:io';

import 'package:args/args.dart';

import 'package:flutter_platform_sync/src/gradle_versions.dart';
import 'package:flutter_platform_sync/src/project_updater.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'version',
      abbr: 'v',
      help: 'Target Flutter version to sync Android files to, e.g. 3.47.0',
    )
    ..addOption(
      'project',
      abbr: 'p',
      defaultsTo: '.',
      help: 'Path to the root of the Flutter project (the folder that '
          'contains pubspec.yaml and android/).',
    )
    ..addOption(
      'min-sdk',
      help: 'minSdk value to apply, e.g. 24. This is always your own call, '
          'never auto-synced from the target Flutter version — if omitted, '
          'you\'ll be prompted for it (leave blank at the prompt to leave '
          'minSdk untouched). Pass this to run non-interactively.',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'Show what would change without writing any files.',
    )
    ..addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help: 'Apply changes without asking for confirmation.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this help text.',
    );

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Argument error: ${e.message}\n');
    stdout.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (args['help'] as bool) {
    stdout.writeln('flutter_platform_sync\n');
    stdout.writeln(
      'Syncs an existing Flutter project\'s Android Gradle/AGP/Kotlin/SDK\n'
      'version numbers to match a target Flutter SDK release, by reading\n'
      'the same version constants Flutter itself uses when scaffolding a\n'
      'fresh project on that version.\n',
    );
    stdout.writeln(parser.usage);
    return;
  }

  var targetVersion = args['version'] as String?;
  if (targetVersion == null || targetVersion.trim().isEmpty) {
    stdout.write(
      'Which Flutter version do you want to sync this project\'s Android '
      'files to?\n(e.g. 3.47.0 — must match a real release tag on '
      'https://github.com/flutter/flutter/tags)\n> ',
    );
    targetVersion = stdin.readLineSync()?.trim();
    if (targetVersion == null || targetVersion.isEmpty) {
      stderr.writeln('No version provided. Aborting.');
      exitCode = 1;
      return;
    }
  }

  final projectRoot = Directory(args['project'] as String);
  if (!await Directory('${projectRoot.path}/android').exists()) {
    stderr.writeln(
      'No android/ folder found under "${projectRoot.path}". '
      'Point --project at the root of a Flutter project.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('Looking up Android template defaults for Flutter '
      '$targetVersion ...');

  GradleVersions fetched;
  try {
    fetched = await fetchGradleVersionsFor(targetVersion);
  } on GradleVersionLookupException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
    return;
  } on SocketException catch (e) {
    stderr.writeln(
      'Network error while contacting GitHub: $e\n'
      'This tool needs internet access to read Flutter\'s release template.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Note: compileSdk and targetSdk are pinned to '
    '$fixedCompileAndTargetSdk regardless of target Flutter version, to '
    'satisfy Play Store\'s 16 KB page size requirement.',
  );

  var minSdk = args['min-sdk'] as String?;
  if (minSdk == null || minSdk.trim().isEmpty) {
    stdout.write(
      '\nminSdk is your own call, not something synced from Flutter\'s '
      'template — what minSdk do you want? (leave blank to leave minSdk '
      'untouched in the project)\n> ',
    );
    minSdk = stdin.readLineSync()?.trim();
  }
  if (minSdk != null && minSdk.isNotEmpty && int.tryParse(minSdk) == null) {
    stderr.writeln('minSdk must be a whole number, e.g. 24. Aborting.');
    exitCode = 1;
    return;
  }

  final target = GradleVersions(
    flutterVersion: fetched.flutterVersion,
    gradleVersion: fetched.gradleVersion,
    agpVersion: fetched.agpVersion,
    kotlinVersion: fetched.kotlinVersion,
    compileSdk: fetched.compileSdk,
    minSdk: (minSdk != null && minSdk.isNotEmpty) ? minSdk : null,
    targetSdk: fetched.targetSdk,
    ndkVersion: fetched.ndkVersion,
  );

  stdout.writeln('\n$target');

  final legacyLayout =
      await File('${projectRoot.path}/android/build.gradle').exists() &&
          !await File('${projectRoot.path}/android/settings.gradle.kts')
              .exists();
  if (legacyLayout) {
    stdout.writeln(
      '⚠ This project is still on the older imperative Gradle layout '
      '(no settings.gradle.kts). This tool will update version numbers in '
      'place, but if your target Flutter version expects the newer '
      'built-in-Kotlin / declarative-plugins layout, a version bump alone '
      'won\'t restructure the file — see: '
      'https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin\n',
    );
  }

  final updater = ProjectUpdater(projectRoot: projectRoot, target: target);
  final planned = await updater.plan();

  if (planned.isEmpty) {
    stdout.writeln(
      'Nothing to change — this project\'s Android files already match '
      'Flutter $targetVersion\'s defaults (or the relevant files/fields '
      'weren\'t found to update).',
    );
    return;
  }

  stdout.writeln('Planned changes:\n');
  for (final change in planned.allChanges) {
    stdout.writeln(change);
    stdout.writeln();
  }

  if (args['dry-run'] as bool) {
    stdout.writeln('(dry run — no files were modified)');
    return;
  }

  if (!(args['yes'] as bool)) {
    stdout.write('Apply these changes? A .bak copy of each file will be '
        'kept. [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      stdout.writeln('Aborted — no files were modified.');
      return;
    }
  }

  final touched = await planned.apply();
  stdout.writeln('\nUpdated ${touched.length} file(s):');
  for (final f in touched) {
    stdout.writeln('  ${f.path}  (backup: ${f.path}.bak)');
  }
  stdout.writeln(
    '\nNext: run your usual build (e.g. `flutter build apk` or open in '
    'Android Studio) to confirm it still builds before deleting the '
    '.bak files.',
  );
}
