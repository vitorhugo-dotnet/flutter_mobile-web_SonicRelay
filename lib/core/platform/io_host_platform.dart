import 'dart:io';

/// Lowercase OS name, matching the `platform` values the backend already
/// accepts from the mobile clients (`android`, `ios`).
String get hostPlatformName => Platform.operatingSystem;

bool get isAndroidHost => Platform.isAndroid;

/// Android and iOS are the two platforms with a `connectivity_plus`
/// implementation and a real background story.
bool get isMobileHost => Platform.isAndroid || Platform.isIOS;

bool get isWebHost => false;
