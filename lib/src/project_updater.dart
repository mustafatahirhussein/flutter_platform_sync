import 'dart:io';

import 'gradle_versions.dart';

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

class PlannedUpdate {
  PlannedUpdate(this._rewrites);

  final List<_FileRewrite> _rewrites;

  bool get isEmpty => _rewrites.every((r) => r.changes.isEmpty);

  List<ChangeEntry> get allChanges =>
      _rewrites.expand((r) => r.changes).toList();

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

  int? get _agpMajorVersion {
    final match = RegExp(r'^(\d+)').firstMatch(target.agpVersion);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  String _applyBuiltInKotlinMigration(
    String content, {
    required bool isKts,
    required File file,
    required List<ChangeEntry> changes,
  }) {
    final agpMajor = _agpMajorVersion;
    if (agpMajor == null || agpMajor < 9) return content;

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

    if (isKts) {
      final block = _findBracedBlock(content, 'kotlinOptions');
      if (block != null) {
        final oldBlock = content.substring(block.start, block.end);
        final innerTrimmed = block.inner.trim();
        final isSingleJvmTargetAssignment =
            RegExp(r'^jvmTarget\s*=\s*\S.*$').hasMatch(innerTrimmed) &&
                !innerTrimmed.contains('\n');

        if (isSingleJvmTargetAssignment) {
          const newBlock = 'kotlin {\n'
              '        compilerOptions {\n'
              '            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17\n'
              '        }\n'
              '    }';
          content = content.replaceRange(block.start, block.end, newBlock);
          changes.add(ChangeEntry(
            file: file,
            description: 'Replace kotlinOptions block with the new '
                'kotlin { compilerOptions { } } block',
            oldLine: oldBlock,
            newLine: newBlock,
          ));
        } else {
          changes.add(ChangeEntry(
            file: file,
            description: 'MANUAL ACTION NEEDED: kotlinOptions block has '
                'more than just jvmTarget in it — not auto-converted, since '
                'guessing at unfamiliar properties risks a wrong rewrite. '
                'Move its contents into a kotlin { compilerOptions { ... } '
                '} block yourself (see: '
                'https://docs.flutter.dev/release/breaking-changes/'
                'migrate-to-built-in-kotlin). Left as-is for now, but the '
                'build WILL fail once the plugin line below is removed, '
                'since kotlinOptions becomes an unresolved reference '
                'without it.',
            oldLine: oldBlock,
            newLine: '(left unchanged — needs manual migration)',
          ));
        }
      }
    }

    return content;
  }

  ({int start, int end, String inner})? _findBracedBlock(
    String content,
    String name,
  ) {
    final head = RegExp('$name\\s*\\{').firstMatch(content);
    if (head == null) return null;

    var depth = 1;
    var i = head.end;
    final innerStart = i;
    while (i < content.length && depth > 0) {
      final char = content[i];
      if (char == '{') depth++;
      if (char == '}') depth--;
      i++;
    }
    if (depth != 0) return null;

    return (start: head.start, end: i, inner: content.substring(innerStart, i - 1));
  }

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
