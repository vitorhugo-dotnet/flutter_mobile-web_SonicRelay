import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/device_identity/data/device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/data/in_memory_device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/domain/device_credential.dart';

const _webCredential = DeviceCredential(
  deviceId: 'device-1',
  credentialSecret: 'secret',
  credentialVersion: 1,
  deviceType: 'web_publisher',
  platform: 'web',
);

void main() {
  late InMemoryDeviceCredentialStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = InMemoryDeviceCredentialStorage();
  });

  test('round trips one credential and clears it', () async {
    expect(await storage.read(), isNull);

    await storage.write(_webCredential);
    expect(await storage.read(), _webCredential);

    await storage.clear();
    expect(await storage.read(), isNull);
  });

  // The whole reason this class exists (dotnet_SonicRelay#33): a web
  // publisher's secret must not outlive the tab, and `flutter_secure_storage`
  // on the web is `localStorage` behind a reassuring name.
  test('writes nothing to the platform key store', () async {
    await storage.write(_webCredential);

    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });

  test('a fresh instance starts empty, as a reloaded tab would', () async {
    await storage.write(_webCredential);

    expect(await InMemoryDeviceCredentialStorage().read(), isNull);
  });

  test('rejects a credential the backend could not have issued', () async {
    await expectLater(
      storage.write(
        const DeviceCredential(
          deviceId: 'device-1',
          credentialSecret: 'secret',
          credentialVersion: 0,
          deviceType: 'web_publisher',
          platform: 'web',
        ),
      ),
      throwsA(isA<DeviceCredentialStorageException>()),
    );

    expect(await storage.read(), isNull);
  });
}
