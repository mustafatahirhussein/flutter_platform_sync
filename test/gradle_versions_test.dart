import 'package:test/test.dart';
import 'package:flutter_platform_sync/src/gradle_versions.dart';

const _sampleSource = '''
// A trimmed stand-in for flutter_tools' gradle_utils.dart, just enough
// shape to exercise the regexes without hitting the network.
const templateDefaultGradleVersion = '9.3.1';
const templateAndroidGradlePluginVersion = '9.1.0';
const templateAndroidGradlePluginVersionForModule = '9.1.0';
const templateKotlinGradlePluginVersion = '2.4.0';
const compileSdkVersionInt = 36;
const compileSdkVersion = '\$compileSdkVersionInt';
const minSdkVersionInt = 24;
const targetSdkVersion = '36';
const ndkVersion = '28.2.13676358';
''';

void main() {
  test('parses gradle/agp/kotlin versions out of gradle_utils.dart source',
      () {
    final versions = parseGradleVersionsFromSource('3.47.0', _sampleSource);

    expect(versions.flutterVersion, '3.47.0');
    expect(versions.gradleVersion, '9.3.1');
    expect(versions.agpVersion, '9.1.0');
    expect(versions.kotlinVersion, '2.4.0');
  });

  test('throws a clear error when constants are missing', () {
    expect(
      () => parseGradleVersionsFromSource('3.47.0', '// nothing here'),
      throwsA(isA<GradleVersionLookupException>()),
    );
  });
}
