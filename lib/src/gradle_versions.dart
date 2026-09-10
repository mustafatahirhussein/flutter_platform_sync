import 'package:http/http.dart' as http;

/// `compileSdk` and `targetSdk` are pinned to this value rather than parsed
/// out of Flutter's `gradle_utils.dart`, regardless of the requested target
/// Flutter version.
///
/// Two independent reasons:
/// 1. The constant name Flutter uses for `compileSdk`/`minSdk` isn't stable
///    across releases (`compileSdkVersion` as a plain string on most tags,
///    a computed `compileSdkVersionInt` on newer ones) — the source-parsing
///    approach that works for gradle/AGP/kotlin/targetSdk/ndk doesn't hold
///    up for this field, so pinning avoids silently doing nothing.
/// 2. API 36 is also just the right floor independent of Flutter version:
///    Play Store's 16 KB memory page size requirement (Google Play policy,
///    effective for app updates since Nov 2025) needs `compileSdk`/
///    `targetSdk` at 36 with a 16 KB-aligned NDK — so "36" is the correct
///    answer here even when the target Flutter release itself still
///    defaults lower.
const String fixedCompileAndTargetSdk = '36';

/// The Android/Gradle/Kotlin version numbers that a specific Flutter SDK
/// release template ships with. These are read directly from Flutter's own
/// `gradle_utils.dart` source for the requested tag, so they stay accurate
/// as Flutter changes its defaults across releases — no hand-maintained
/// table to go stale.
///
/// The exceptions are [compileSdk] and [targetSdk], which are always
/// [fixedCompileAndTargetSdk] (see its doc comment), and [minSdk], which
/// this class never populates from Flutter's source at all — the CLI asks
/// the user for it directly instead, since it's a project-specific choice
/// Flutter's own template default doesn't have an opinion worth copying.
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

/// Fetches the canonical Gradle/AGP/Kotlin/SDK version constants that ship
/// with a given Flutter release, by reading
/// `packages/flutter_tools/lib/src/android/gradle_utils.dart` straight out
/// of the flutter/flutter repo at the git tag matching [flutterVersion].
///
/// This is the same file `flutter create` itself consults, so the numbers
/// returned are exactly what a *fresh* project on that Flutter version would
/// have — the ground truth for "what should my project's Android config
/// look like on version X".
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
    // Matches things like:
    //   const templateDefaultGradleVersion = '9.3.1';
    //   const String templateDefaultGradleVersion = '9.3.1';
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
    // minSdk is deliberately left unset here — the CLI fills it in from the
    // user's own choice, not from Flutter's template default.
    minSdk: null,
    targetSdk: fixedCompileAndTargetSdk,
    ndkVersion: ndk,
  );
}

/// Small helper kept separate so it's easy to unit test the regex parsing
/// without needing network access — feed it a raw file body directly.
GradleVersions parseGradleVersionsFromSource(
  String flutterVersion,
  String source,
) {
  // Delegates to the same regexes as [fetchGradleVersionsFor] by reusing the
  // private extraction logic would require refactor; for now this mirrors
  // it explicitly for test purposes.
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
