import '../../device_identity/data/device_identity_session.dart';

/// Prepares the authentication grant required before browser signaling opens.
abstract interface class SignalingGrantPreparer {
  Future<void> prepare(String sessionId);
}

abstract interface class SignalingGrantPostAdapter {
  set withCredentials(bool value);

  Future<void> post(
    Uri uri, {
    required String bearer,
    required Map<String, Object?> data,
  });
}

/// Testable browser grant preparation independent of the browser HTTP adapter.
class WebSignalingGrantPreparer implements SignalingGrantPreparer {
  WebSignalingGrantPreparer({
    required Uri apiBaseUrl,
    required DeviceIdentitySession deviceIdentitySession,
    required SignalingGrantPostAdapter postAdapter,
  }) : _apiBaseUrl = apiBaseUrl,
       _deviceIdentitySession = deviceIdentitySession,
       _postAdapter = postAdapter {
    _postAdapter.withCredentials = true;
  }

  final Uri _apiBaseUrl;
  final DeviceIdentitySession _deviceIdentitySession;
  final SignalingGrantPostAdapter _postAdapter;
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  @override
  Future<void> prepare(String sessionId) {
    final existing = _inFlight[sessionId];
    if (existing != null) return existing;

    late final Future<void> current;
    current = _prepare(sessionId).whenComplete(() {
      if (identical(_inFlight[sessionId], current)) {
        _inFlight.remove(sessionId);
      }
    });
    _inFlight[sessionId] = current;
    return current;
  }

  Future<void> _prepare(String sessionId) async {
    final bearer = await _deviceIdentitySession.accessToken();
    await _postAdapter.post(
      _apiBaseUrl.resolve('/api/signaling/grant'),
      bearer: bearer,
      data: <String, Object?>{'sessionId': sessionId},
    );
  }
}
