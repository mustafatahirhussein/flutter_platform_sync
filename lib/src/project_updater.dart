import 'dart:io';

import 'gradle_versions.dart';

/// One proposed (or applied) edit to a single file.
class ChangeEntry {
  ChangeEntry({
    required this.file,
    required this.description,
    required this.oldLine,
    required this.newLine,
  });

  final File file;
  final String description;
  final String oldLine;
  final String newLine;

  @override
  String toString() => '${file.path}\n'
      '  $description\n'
      '  - $oldLine\n'
      '  + $newLine';
}

/// Result of scanning a project: what would change, and which regex-based
/// rewrite rules matched. Nothing is written to disk until [apply] is
/// called on this result.
class PlannedUpdate {
  PlannedUpdate(this._rewrites);

  final List<_FileRewrite> _rewrites;

  bool get isEmpty => _rewrites.every((r) => r.changes.isEmpty);

  List<ChangeEntry> get allChanges =>
      _rewrites.expand((r) => r.changes).toList();

  /// Writes every planned change to disk. Each touched file gets a sibling
  /// `<name>.bak` written first (only once — if a `.bak` already exists it's
  /// left alone, so re-running the tool doesn't clobber your *original*
  /// backup with an already-modified version).
  Future<List<File>> apply() async {
    final touched = <File>[];
    for (final rewrite in _rewrites) {
      if (rewrite.changes.isEmpty) continue;
      final backup = File('${rewrite.file.path}.bak');
      if (!await backup.exists()) {
        await rewrite.file.copy(backup.path);
      }
      await rewrite.file.writeAsString(rewrite.newContent);
      touched.add(rewrite.file);
    }
    return touched;
  }
}

class _FileRewrite {
  _FileRewrite(this.file, this.newContent, this.changes);
  final File file;
  final String newContent;
  final List<ChangeEntry> changes;
}

/// Scans (and, when [PlannedUpdate.apply] is called, edits) the standard set
/// of Android files a Flutter project ships, updating Gradle/AGP/Kotlin/SDK
/// version numbers to match [target].
///
/// Handles both the current "declarative plugins {}" project layout
/// (`settings.gradle.kts` holding the AGP/Kotlin plugin versions) and the
/// older imperative layout (`android/build.gradle` holding
/// `ext.kotlin_version` and a `classpath 'com.android.tools.build:gradle:…'`
/// line), since plenty of projects that have been around a few years are
/// still on the old layout.
class ProjectUpdater {
  ProjectUpdater({required this.projectRoot, required this.target});

  final Directory projectRoot;
  final GradleVersions target;

  Directory get _android => Directory('${projectRoot.path}/android');

  Future<PlannedUpdate> plan() async {
    final rewrites = <_FileRewrite>[];

    rewrites.addAll(await _planGradleWrapper());
    rewrites.addAll(await _planSettingsGradleKts());
    rewrites.addAll(await _planRootBuildGradle());
    rewrites.addAll(await _planAppBuildGradle());
    rewrites.addAll(await _planGradlePropertiesNewDslFlag());

    return PlannedUpdate(rewrites);
  }

  /// AGP's major version number, parsed from [target.agpVersion] (e.g.
  /// `"9.1.0"` -> `9`). Returns null if it can't be parsed.
  int? get _agpMajorVersion {
    final match = RegExp(r'^(\d+)').firstMatch(target.agpVersion);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Starting with AGP 9.0, explicitly applying the `kotlin-android` /
  /// `org.jetbrains.kotlin.android` plugin in `app/build.gradle(.kts)` is
  /// rejected outright — AGP now provides Kotlin support built in. Projects
  /// written against older AGP still apply that plugin explicitly and use a
  /// `kotlinOptions { jvmTarget = ... }` block, both of which need removing.
  /// Applied in-place to [content] (called from [_planAppBuildGradle] so
  /// both edits land in one rewrite of the file, not two competing ones).
  ///
  /// Only does anything when [target] is on AGP 9+ — a no-op for target
  /// versions still on AGP 8, where the old shape is still correct.
  String _applyBuiltInKotlinMigration(
    String content, {
    required bool isKts,
    required File file,
    required List<ChangeEntry> changes,
  }) {
    final agpMajor = _agpMajorVersion;
    if (agpMajor == null || agpMajor < 9) return content;

    // 1. Remove the explicit Kotlin Android plugin application line.
    final pluginLinePattern = isKts
        ? RegExp(
            r'''^[ \t]*id\("(?:kotlin-android|org\.jetbrains\.kotlin\.android)"\)[ \t]*\r?\n''',
            multiLine: true,
          )
        : RegExp(
            r'''^[ \t]*(?:id\s+['"](?:kotlin-android|org\.jetbrains\.kotlin\.android)['"]|apply\s+plugin:\s*['"]kotlin-android['"])[ \t]*\r?\n''',
            multiLine: true,
          );
    final pluginMatch = pluginLinePattern.firstMatch(content);
    if (pluginMatch != null) {
      final oldLine = pluginMatch.group(0)!;
      content = content.replaceFirst(oldLine, '');
      changes.add(ChangeEntry(
        file: file,
        description: 'Remove explicit Kotlin Android plugin application '
            '(AGP $agpMajor+ provides Kotlin support built in)',
        oldLine: oldLine.trim(),
        newLine: '(line removed — no longer needed)',
      ));
    }

    // 2. Replace the old `kotlinOptions { jvmTarget = ... }` block. Only
    // attempted for the Kotlin DSL file — the Groovy `kotlinOptions` block
    // is still valid syntax there for now, so it's left alone rather than
    // guessed at.
    if (isKts) {
      final kotlinOptionsPattern = RegExp(
        r'kotlinOptions\s*\{\s*jvmTarget\s*=[^\n}]*\n?\s*\}',
      );
      final koMatch = kotlinOptionsPattern.firstMatch(content);
      if (koMatch != null) {
        final oldBlock = koMatch.group(0)!;
        const newBlock = 'kotlin {\n'
            '        compilerOptions {\n'
            '            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17\n'
            '        }\n'
            '    }';
        content = content.replaceFirst(oldBlock, newBlock);
        changes.add(ChangeEntry(
          file: file,
          description: 'Replace kotlinOptions block with the new '
              'kotlin { compilerOptions { } } block',
          oldLine: oldBlock,
          newLine: newBlock,
        ));
      }
    }

    return content;
  }

  /// Adds the temporary `android.newDsl=false` compatibility flag to
  /// `gradle.properties`, per Flutter's built-in-Kotlin migration guide,
  /// when the target Flutter version is on AGP 9+ and the flag isn't
  /// already present.
  Future<List<_FileRewrite>> _planGradlePropertiesNewDslFlag() async {
    final agpMajor = _agpMajorVersion;
    if (agpMajor == null || agpMajor < 9) return [];

    final propsFile = File('${_android.path}/gradle.properties');
    if (!await propsFile.exists()) return [];

    final content = await propsFile.readAsString();
    if (RegExp(r'^\s*android\.newDsl\s*=', multiLine: true)
        .hasMatch(content)) {
      return [];
    }

    final newContent = '${content.trimRight()}\nandroid.newDsl=false\n';
    return [
      _FileRewrite(propsFile, newContent, [
        ChangeEntry(
          file: propsFile,
          description: 'Add built-in-Kotlin compatibility flag',
          oldLine: '(not present)',
          newLine: 'android.newDsl=false',
        ),
      ]),
    ];
  }

  Future<List<_FileRewrite>> _planGradleWrapper() async {
    final file =
        File('${_android.path}/gradle/wrapper/gradle-wrapper.properties');
    if (!await file.exists()) return [];

    final content = await file.readAsString();
    final pattern = RegExp(
      r'distributionUrl=.*gradle-([\d.]+)-(bin|all)\.zip',
    );
    final match = pattern.firstMatch(content);
    if (match == null) return [];

    final currentVersion = match.group(1)!;
    if (currentVersion == target.gradleVersion) return [];

    final oldLine = match.group(0)!;
    final newLine = oldLine.replaceFirst(currentVersion, target.gradleVersion);
    final newContent = content.replaceFirst(oldLine, newLine);

    return [
      _FileRewrite(file, newContent, [
        ChangeEntry(
          file: file,
          description: 'Gradle wrapper version',
          oldLine: oldLine,
          newLine: newLine,
        ),
      ]),
    ];
  }

  Future<List<_FileRewrite>> _planSettingsGradleKts() async {
    final results = <_FileRewrite>[];
    for (final name in ['settings.gradle.kts', 'settings.gradle']) {
      final file = File('${_android.path}/$name');
      if (!await file.exists()) continue;

      var content = await file.readAsString();
      final changes = <ChangeEntry>[];

      content = _replaceVersioned(
        content,
        idPattern: r'com\.android\.application',
        newVersion: target.agpVersion,
        description: 'Android Gradle Plugin (AGP) version',
        file: file,
        changes: changes,
      );
      content = _replaceVersioned(
        content,
        idPattern: r'org\.jetbrains\.kotlin\.android',
        newVersion: target.kotlinVersion,
        description: 'Kotlin Gradle Plugin version',
        file: file,
        changes: changes,
      );

      if (changes.isNotEmpty) {
        results.add(_FileRewrite(file, content, changes));
      }
    }
    return results;
  }

  /// Handles the older, pre-declarative-plugins project layout where the
  /// root `android/build.gradle` declares `ext.kotlin_version` and a
  /// `classpath 'com.android.tools.build:gradle:X.Y.Z'` dependency instead
  /// of a `settings.gradle.kts` plugins block.
  Future<List<_FileRewrite>> _planRootBuildGradle() async {
    final file = File('${_android.path}/build.gradle');
    if (!await file.exists()) return [];

    var content = await file.readAsString();
    final changes = <ChangeEntry>[];

    final kotlinExtPattern =
        RegExp(r'''ext\.kotlin_version\s*=\s*['"]([^'"]+)['"]''');
    final kotlinMatch = kotlinExtPattern.firstMatch(content);
    if (kotlinMatch != null && kotlinMatch.group(1) != target.kotlinVersion) {
      final oldLine = kotlinMatch.group(0)!;
      final newLine =
          oldLine.replaceFirst(kotlinMatch.group(1)!, target.kotlinVersion);
      content = content.replaceFirst(oldLine, newLine);
      changes.add(ChangeEntry(
        file: file,
        description: 'ext.kotlin_version (legacy layout)',
        oldLine: oldLine,
        newLine: newLine,
      ));
    }

    final agpClasspathPattern = RegExp(
      r'''classpath\s+['"]com\.android\.tools\.build:gradle:([^'"]+)['"]''',
    );
    final agpMatch = agpClasspathPattern.firstMatch(content);
    if (agpMatch != null && agpMatch.group(1) != target.agpVersion) {
      final oldLine = agpMatch.group(0)!;
      final newLine = oldLine.replaceFirst(agpMatch.group(1)!, target.agpVersion);
      content = content.replaceFirst(oldLine, newLine);
      changes.add(ChangeEntry(
        file: file,
        description: 'AGP classpath dependency (legacy layout)',
        oldLine: oldLine,
        newLine: newLine,
      ));
    }

    if (changes.isEmpty) return [];
    return [_FileRewrite(file, content, changes)];
  }

  Future<List<_FileRewrite>> _planAppBuildGradle() async {
    final results = <_FileRewrite>[];
    for (final name in ['app/build.gradle.kts', 'app/build.gradle']) {
      final file = File('${_android.path}/$name');
      if (!await file.exists()) continue;
      final isKts = name.endsWith('.kts');

      var content = await file.readAsString();
      final changes = <ChangeEntry>[];

      // Try the modern short field names first (compileSdk/minSdk/targetSdk,
      // used since AGP 8), falling back to the older *Version-suffixed
      // names still found in projects that haven't touched their app-level
      // build.gradle field names in a while. Many older/unmodified projects
      // instead reference `flutter.compileSdkVersion` etc. (a variable
      // supplied by Flutter's own Gradle plugin, not a literal number) — in
      // that case there's nothing to rewrite here, which is correct: those
      // projects pick up new SDK versions automatically from the Flutter
      // Gradle plugin itself, not from this file.
      if (target.compileSdk != null) {
        content = _replaceSdkField(
          content,
          fields: const ['compileSdk', 'compileSdkVersion'],
          newValue: target.compileSdk!,
          file: file,
          changes: changes,
        );
      }
      if (target.minSdk != null) {
        content = _replaceSdkField(
          content,
          fields: const ['minSdk', 'minSdkVersion'],
          newValue: target.minSdk!,
          file: file,
          changes: changes,
        );
      }
      if (target.targetSdk != null) {
        content = _replaceSdkField(
          content,
          fields: const ['targetSdk', 'targetSdkVersion'],
          newValue: target.targetSdk!,
          file: file,
          changes: changes,
        );
      }
      if (target.ndkVersion != null) {
        content = _replaceSdkField(
          content,
          fields: const ['ndkVersion'],
          newValue: target.ndkVersion!,
          file: file,
          changes: changes,
          quoted: true,
        );
      }

      content = _applyBuiltInKotlinMigration(
        content,
        isKts: isKts,
        file: file,
        changes: changes,
      );

      if (changes.isNotEmpty) {
        results.add(_FileRewrite(file, content, changes));
      }
    }
    return results;
  }

  /// Rewrites a Gradle Kotlin-DSL plugin declaration like:
  ///   id("com.android.application") version "8.7.0" apply false
  /// to use [newVersion], only if the version differs.
  String _replaceVersioned(
    String content, {
    required String idPattern,
    required String newVersion,
    required String description,
    required File file,
    required List<ChangeEntry> changes,
  }) {
    final pattern = RegExp(
      'id\\("$idPattern"\\)\\s+version\\s+"([^"]+)"',
    );
    final match = pattern.firstMatch(content);
    if (match == null || match.group(1) == newVersion) return content;

    final oldLine = match.group(0)!;
    final newLine = oldLine.replaceFirst(match.group(1)!, newVersion);
    changes.add(ChangeEntry(
      file: file,
      description: description,
      oldLine: oldLine,
      newLine: newLine,
    ));
    return content.replaceFirst(oldLine, newLine);
  }

  /// Rewrites a `compileSdk = 35` / `compileSdk 35` / `ndkVersion = "27.0.0"`
  /// style field. Supports both Groovy (`field 35`) and Kotlin DSL
  /// (`field = 35`) forms, and both quoted and bare numeric values.
  ///
  /// Tries each name in [fields] in order and stops at the first one that
  /// actually appears in the file with a literal value to replace — this
  /// lets callers offer both the modern short field name (`compileSdk`) and
  /// the older `*Version`-suffixed one (`compileSdkVersion`) without
  /// double-editing a file that happens to contain both words in unrelated
  /// contexts.
  String _replaceSdkField(
    String content, {
    required List<String> fields,
    required String newValue,
    required File file,
    required List<ChangeEntry> changes,
    bool quoted = false,
  }) {
    final valuePattern = quoted ? '"([^"]+)"' : r'"?(\d+)"?';
    for (final field in fields) {
      final pattern = RegExp('\\b$field\\s*=?\\s*$valuePattern');
      final match = pattern.firstMatch(content);
      if (match == null) continue;
      if (match.group(1) == newValue) return content;

      final oldLine = match.group(0)!;
      final newLine = oldLine.replaceFirst(match.group(1)!, newValue);
      changes.add(ChangeEntry(
        file: file,
        description: field,
        oldLine: oldLine,
        newLine: newLine,
      ));
      return content.replaceFirst(oldLine, newLine);
    }
    return content;
  }
}
