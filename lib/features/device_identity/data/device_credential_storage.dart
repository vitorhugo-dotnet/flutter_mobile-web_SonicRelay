import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/device_credential.dart';

class DeviceCredentialStorageException implements Exception {
  const DeviceCredentialStorageException(this.message);

  final String message;

  @override
  String toString() => 'DeviceCredentialStorageException: $message';
}

/// The `platform` values the backend issues a device identity for.
///
/// `web` joins the two mobile clients for the browser publisher
/// (dotnet_SonicRelay#33). The list stays closed rather than accepting any
/// string so a typo in the platform façade fails here, at bootstrap, instead of
/// registering a device the backend will not recognise.
const deviceCredentialPlatforms = {'android', 'ios', 'web'};

const _invalidCredentialMessage = 'Device credential is invalid.';

/// Where a device credential lives between token exchanges.
///
/// Mobile keeps it in the platform keystore so the identity survives a restart;
/// the browser keeps it in memory only, because dotnet_SonicRelay#33 requires a
/// web publisher's identity to be ephemeral and never to reach `localStorage`.
abstract interface class DeviceCredentialStorage {
  Future<DeviceCredential?> read();

  Future<void> write(DeviceCredential credential);

  Future<void> clear();
}

/// Throws [DeviceCredentialStorageException] unless [credential] is one the
/// backend could have issued.
void validateDeviceCredential(DeviceCredential credential) {
  if (credential.deviceId.trim().isEmpty ||
      credential.credentialSecret.trim().isEmpty ||
      credential.credentialVersion <= 0 ||
      credential.deviceType.trim().isEmpty ||
      !deviceCredentialPlatforms.contains(credential.platform)) {
    throw const DeviceCredentialStorageException(_invalidCredentialMessage);
  }
}

/// [DeviceCredentialStorage] backed by the platform keystore. The Android and
/// iOS behaviour, where the viewer keeps one identity across launches.
class SecureDeviceCredentialStorage implements DeviceCredentialStorage {
  const SecureDeviceCredentialStorage(this._storage);

  static const _credentialKey = 'deviceIdentity.credential';

  final FlutterSecureStorage _storage;

  @override
  Future<DeviceCredential?> read() async {
    final encoded = await _storage.read(key: _credentialKey);
    if (encoded == null) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw const DeviceCredentialStorageException(_invalidCredentialMessage);
    }

    if (decoded is! Map<String, dynamic>) {
      throw const DeviceCredentialStorageException(_invalidCredentialMessage);
    }

    final deviceId = decoded['deviceId'];
    final credentialSecret = decoded['credentialSecret'];
    final credentialVersion = decoded['credentialVersion'];
    final deviceType = decoded['deviceType'];
    final platform = decoded['platform'];
    if (deviceId is! String ||
        credentialSecret is! String ||
        credentialVersion is! int ||
        deviceType is! String ||
        platform is! String) {
      throw const DeviceCredentialStorageException(_invalidCredentialMessage);
    }

    final credential = DeviceCredential(
      deviceId: deviceId,
      credentialSecret: credentialSecret,
      credentialVersion: credentialVersion,
      deviceType: deviceType,
      platform: platform,
    );
    validateDeviceCredential(credential);
    return credential;
  }

  @override
  Future<void> write(DeviceCredential credential) async {
    validateDeviceCredential(credential);
    await _storage.write(
      key: _credentialKey,
      value: jsonEncode({
        'deviceId': credential.deviceId,
        'credentialSecret': credential.credentialSecret,
        'credentialVersion': credential.credentialVersion,
        'deviceType': credential.deviceType,
        'platform': credential.platform,
      }),
    );
  }

  @override
  Future<void> clear() => _storage.delete(key: _credentialKey);
}
