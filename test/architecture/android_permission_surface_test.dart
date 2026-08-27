import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the promise made when the web publisher was scoped
/// (dotnet_SonicRelay#33): reusing this app for a browser publisher must not
/// cost mobile users a single new permission.
///
/// The manifest merger, not this repo's manifest alone, decides what the APK
/// asks for — every plugin contributes its own `uses-permission` lines — so the
/// durable risk is not the web work itself but the next dependency someone
/// adds. That is what these tests pin: the exact permission surface, and the
/// rule that no package may quietly widen it.
const _appManifest = 'android/app/src/main/AndroidManifest.xml';

/// Everything the shipped APK asks the user for. Changing this set changes the
/// Play Store listing, so it may only move deliberately.
const _requestedPermissions = {
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.ACCESS_WIFI_STATE',
  'android.permission.CAMERA',
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
  'android.permission.INTERNET',
  'android.permission.POST_NOTIFICATIONS',
  'android.permission.WAKE_LOCK',
};

/// Permissions a dependency declares that this app strips at merge time rather
/// than shipping unused.
const _removedPermissions = {
  'android.permission.READ_EXTERNAL_STORAGE',
  'android.permission.RECORD_AUDIO',
  'android.permission.WRITE_EXTERNAL_STORAGE',
};

final _usesPermission = RegExp(
  r'<uses-permission\b([^>]*)>',
  multiLine: true,
);
final _permissionName = RegExp(r'android:name="([^"]+)"');

({Set<String> requested, Set<String> removed}) _appPermissions() {
  final requested = <String>{};
  final removed = <String>{};

  for (final match in _usesPermission.allMatches(File(_appManifest).readAsStringSync())) {
    final attributes = match.group(1)!;
    final name = _permissionName.firstMatch(attributes)?.group(1);
    if (name == null) continue;
    if (attributes.contains('tools:node="remove"')) {
      removed.add(name);
    } else {
      requested.add(name);
    }
  }

  return (requested: requested, removed: removed);
}

/// Every `uses-permission` each resolved package declares in its own manifest,
/// keyed by package. These are merged into the APK unless the app manifest
/// removes them.
Map<String, Set<String>> _permissionsByDependency() {
  final config = File('.dart_tool/package_config.json');
  expect(
    config.existsSync(),
    isTrue,
    reason: 'Run `flutter pub get` before this test.',
  );

  final packages =
      (jsonDecode(config.readAsStringSync()) as Map<String, dynamic>)['packages']
          as List<dynamic>;

  final result = <String, Set<String>>{};
  for (final entry in packages.cast<Map<String, dynamic>>()) {
    final name = entry['name'] as String;
    if (name == 'sonic_relay') continue;

    final android = Directory.fromUri(
      config.absolute.uri.resolve('${entry['rootUri']}/android/'),
    );
    if (!android.existsSync()) continue;

    for (final file in android.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('AndroidManifest.xml')) continue;
      for (final match in _usesPermission.allMatches(file.readAsStringSync())) {
        final permission = _permissionName.firstMatch(match.group(1)!)?.group(1);
        if (permission != null) {
          (result[name] ??= <String>{}).add(permission);
        }
      }
    }
  }

  return result;
}

void main() {
  test('the app manifest asks for exactly the pinned permissions', () {
    final permissions = _appPermissions();

    expect(permissions.requested, _requestedPermissions);
    expect(permissions.removed, _removedPermissions);
  });

  // The web publisher adds only pure-Dart, web-only code, so it must leave this
  // untouched. A plugin with native Android code is the thing that would not.
  test('no dependency contributes an unaccounted permission', () {
    final accounted = {..._requestedPermissions, ..._removedPermissions};
    final unaccounted = <String, Set<String>>{};

    for (final entry in _permissionsByDependency().entries) {
      final extra = entry.value.difference(accounted);
      if (extra.isNotEmpty) unaccounted[entry.key] = extra;
    }

    expect(
      unaccounted,
      isEmpty,
      reason:
          'These dependencies would add permissions to the APK:\n'
          '${unaccounted.entries.map((e) => '  ${e.key}: ${e.value.join(', ')}').join('\n')}\n'
          'Either declare the permission in $_appManifest deliberately, or '
          'strip it there with tools:node="remove".',
    );
  });
}
