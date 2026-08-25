import '../domain/device_credential.dart';
import 'device_credential_storage.dart';

/// [DeviceCredentialStorage] that keeps the credential in memory and nowhere
/// else, for the ephemeral browser publisher.
///
/// dotnet_SonicRelay#33 is explicit that a web publisher's device secret must
/// not be persisted: the browser has `localStorage` sitting there ready to
/// become an incident, and the backend expires abandoned web identities on its
/// own. Closing the tab is the intended way for this identity to disappear, so
/// there is deliberately no durable store behind this class — not even a
/// best-effort one.
class InMemoryDeviceCredentialStorage implements DeviceCredentialStorage {
  DeviceCredential? _credential;

  @override
  Future<DeviceCredential?> read() async => _credential;

  @override
  Future<void> write(DeviceCredential credential) async {
    validateDeviceCredential(credential);
    _credential = credential;
  }

  @override
  Future<void> clear() async => _credential = null;
}
