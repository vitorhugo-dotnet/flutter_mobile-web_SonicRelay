import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/device_identity/data/device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/domain/device_credential.dart';

void main() {
  const secureStorage = FlutterSecureStorage();
  late DeviceCredentialStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureDeviceCredentialStorage(secureStorage);
  });

  test('round trips one atomic credential and clears it', () async {
    const value = DeviceCredential(
      deviceId: 'device-1',
      credentialSecret: 'secret',
      credentialVersion: 1,
      deviceType: 'flutter_viewer',
      platform: 'android',
    );

    await storage.write(value);

    expect(await storage.read(), value);
    expect(await secureStorage.readAll(), {
      'deviceIdentity.credential': jsonEncode({
        'deviceId': 'device-1',
        'credentialSecret': 'secret',
        'credentialVersion': 1,
        'deviceType': 'flutter_viewer',
        'platform': 'android',
      }),
    });

    await storage.clear();
    expect(await storage.read(), isNull);
  });

  test('rejects invalid credential fields when writing', () async {
    const invalidCredentials = [
      DeviceCredential(
        deviceId: '',
        credentialSecret: 'secret',
        credentialVersion: 1,
        deviceType: 'flutter_viewer',
        platform: 'android',
      ),
      DeviceCredential(
        deviceId: 'device-1',
        credentialSecret: '',
        credentialVersion: 1,
        deviceType: 'flutter_viewer',
        platform: 'android',
      ),
      DeviceCredential(
        deviceId: 'device-1',
        credentialSecret: 'secret',
        credentialVersion: 0,
        deviceType: 'flutter_viewer',
        platform: 'android',
      ),
      DeviceCredential(
        deviceId: 'device-1',
        credentialSecret: 'secret',
        credentialVersion: 1,
        deviceType: '',
        platform: 'android',
      ),
      DeviceCredential(
        deviceId: 'device-1',
        credentialSecret: 'secret',
        credentialVersion: 1,
        deviceType: 'flutter_viewer',
        platform: 'windows',
      ),
    ];

    for (final credential in invalidCredentials) {
      await expectLater(
        storage.write(credential),
        throwsA(isA<DeviceCredentialStorageException>()),
      );
    }

    expect(await secureStorage.readAll(), isEmpty);
  });

  // The browser publisher registers as `platform: web` (dotnet_SonicRelay#33),
  // so the closed platform list has to admit it — while still rejecting the
  // desktop values this app never bootstraps as.
  test('accepts the web platform and still rejects the desktop ones', () async {
    const webCredential = DeviceCredential(
      deviceId: 'device-1',
      credentialSecret: 'secret',
      credentialVersion: 1,
      deviceType: 'web_publisher',
      platform: 'web',
    );

    await storage.write(webCredential);
    expect(await storage.read(), webCredential);

    for (final platform in ['windows', 'macos', 'linux', '']) {
      await expectLater(
        storage.write(
          DeviceCredential(
            deviceId: 'device-1',
            credentialSecret: 'secret',
            credentialVersion: 1,
            deviceType: 'web_publisher',
            platform: platform,
          ),
        ),
        throwsA(isA<DeviceCredentialStorageException>()),
        reason: '$platform is not a platform the backend issues identities for',
      );
    }
  });

  test('reports corrupt stored JSON without exposing its secret', () async {
    const leakedSecret = 'never-include-this-secret';
    await secureStorage.write(
      key: 'deviceIdentity.credential',
      value: '{"credentialSecret":"$leakedSecret","credentialVersion":0}',
    );

    await expectLater(
      storage.read(),
      throwsA(
        isA<DeviceCredentialStorageException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains(leakedSecret)),
        ),
      ),
    );
  });
}
