import 'package:http/http.dart' as http;

const String fixedCompileAndTargetSdk = '36';

class GradleVersions {
  GradleVersions({
    required this.flutterVersion,
    required this.gradleVersion,
    required this.agpVersion,
    required this.kotlinVersion,
    this.compileSdk,
    this.minSdk,
    this.targetSdk,
    this.ndkVersion,
  });

  final String flutterVersion;
  final String gradleVersion;
  final String agpVersion;
  final String kotlinVersion;
  final String? compileSdk;
  final String? minSdk;
  final String? targetSdk;
  final String? ndkVersion;

  @override
  String toString() {
    final b = StringBuffer()
      ..writeln('Flutter $flutterVersion template defaults:')
      ..writeln('  Gradle wrapper : $gradleVersion')
      ..writeln('  AGP            : $agpVersion')
      ..writeln('  Kotlin         : $kotlinVersion');
    if (compileSdk != null) b.writeln('  compileSdk     : $compileSdk');
    if (minSdk != null) b.writeln('  minSdk         : $minSdk');
    if (targetSdk != null) b.writeln('  targetSdk      : $targetSdk');
    if (ndkVersion != null) b.writeln('  ndkVersion     : $ndkVersion');
    return b.toString();
  }
}

class GradleVersionLookupException implements Exception {
  GradleVersionLookupException(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<GradleVersions> fetchGradleVersionsFor(String flutterVersion) async {
  final candidateTags = <String>[
    flutterVersion,
    if (!flutterVersion.startsWith('v')) 'v$flutterVersion',
  ];

  String? source;
  String? usedTag;
  final attempted = <String>[];

  for (final tag in candidateTags) {
    final url = Uri.parse(
      'https://raw.githubusercontent.com/flutter/flutter/$tag/'
      'packages/flutter_tools/lib/src/android/gradle_utils.dart',
    );
    attempted.add(url.toString());
    final response = await http.get(url);
    if (response.statusCode == 200) {
      source = response.body;
      usedTag = tag;
      break;
    }
  }

  if (source == null) {
    throw GradleVersionLookupException(
      'Could not find a Flutter release tagged "$flutterVersion" in the '
      'flutter/flutter repo (tried: ${attempted.join(', ')}).\n'
      'Double check the version number against '
      'https://github.com/flutter/flutter/tags — it must match a real '
      'release tag exactly (e.g. 3.47.0, not 3.47).',
    );
  }

  String? _extract(String constName) {
    final pattern = RegExp(
      '(?:const|final)\\s+(?:String\\s+)?$constName\\s*=\\s*[\'"]([^\'"]+)[\'"]',
    );
    return pattern.firstMatch(source!)?.group(1);
  }

  final gradle = _extract('templateDefaultGradleVersion');
  final agp = _extract('templateAndroidGradlePluginVersion');
  final kotlin = _extract('templateKotlinGradlePluginVersion');

  if (gradle == null || agp == null || kotlin == null) {
    throw GradleVersionLookupException(
      'Found gradle_utils.dart for tag "$usedTag" but could not parse the '
      'expected version constants out of it. Flutter may have renamed '
      'these constants in this release — check '
      'https://github.com/flutter/flutter/blob/$usedTag/packages/flutter_tools/'
      'lib/src/android/gradle_utils.dart manually.',
    );
  }

  final ndk = _extract('ndkVersion');

  return GradleVersions(
    flutterVersion: flutterVersion,
    gradleVersion: gradle,
    agpVersion: agp,
    kotlinVersion: kotlin,
    compileSdk: fixedCompileAndTargetSdk,
    minSdk: null,
    targetSdk: fixedCompileAndTargetSdk,
    ndkVersion: ndk,
  );
}

GradleVersions parseGradleVersionsFromSource(
  String flutterVersion,
  String source,
) {
  String? extract(String constName) {
    final pattern = RegExp(
      '(?:const|final)\\s+(?:String\\s+)?$constName\\s*=\\s*[\'"]([^\'"]+)[\'"]',
    );
    return pattern.firstMatch(source)?.group(1);
  }

  final gradle = extract('templateDefaultGradleVersion');
  final agp = extract('templateAndroidGradlePluginVersion');
  final kotlin = extract('templateKotlinGradlePluginVersion');

  if (gradle == null || agp == null || kotlin == null) {
    throw GradleVersionLookupException(
      'Could not parse version constants from provided source.',
    );
  }

  return GradleVersions(
    flutterVersion: flutterVersion,
    gradleVersion: gradle,
    agpVersion: agp,
    kotlinVersion: kotlin,
  );
}
