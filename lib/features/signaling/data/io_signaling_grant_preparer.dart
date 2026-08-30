import '../../device_identity/data/device_identity_session.dart';
import 'signaling_grant_preparer.dart';

/// Native signaling keeps using bearer headers, so it needs no HTTP grant.
class IoSignalingGrantPreparer implements SignalingGrantPreparer {
  const IoSignalingGrantPreparer();

  @override
  Future<void> prepare(String sessionId) => Future<void>.value();
}

SignalingGrantPreparer createPlatformSignalingGrantPreparer({
  required Uri apiBaseUrl,
  required DeviceIdentitySession deviceIdentitySession,
}) => const IoSignalingGrantPreparer();
