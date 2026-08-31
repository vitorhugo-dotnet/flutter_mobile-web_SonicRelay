import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/device_identity/data/device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_api.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_session.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_response.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_response.dart';
import 'package:sonic_relay/features/device_identity/domain/device_credential.dart';
import 'package:sonic_relay/features/signaling/data/io_signaling_grant_preparer.dart';
import 'package:sonic_relay/features/signaling/data/signaling_grant_preparer.dart';

class _RecordingIdentitySession extends DeviceIdentitySession {
  _RecordingIdentitySession()
    : super(
        api: _UnusedDeviceIdentityApi(),
        storage: _UnusedDeviceCredentialStorage(),
        deviceName: 'test',
        platform: 'test',
      );

  final forceRefreshCalls = <bool>[];

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    forceRefreshCalls.add(forceRefresh);
    return Future<String>.value('cached-bearer');
  }
}

class _RecordingPostAdapter implements SignalingGrantPostAdapter {
  bool? credentialsEnabled;
  final requests = <({Uri uri, Map<String, Object?> data, String bearer})>[];
  Future<void> Function()? onPost;

  @override
  set withCredentials(bool value) => credentialsEnabled = value;

  @override
  Future<void> post(
    Uri uri, {
    required String bearer,
    required Map<String, Object?> data,
  }) {
    requests.add((uri: uri, data: data, bearer: bearer));
    return onPost?.call() ?? Future<void>.value();
  }
}

void main() {
  group('WebSignalingGrantPreparer', () {
    late _RecordingIdentitySession identity;
    late _RecordingPostAdapter postAdapter;
    late WebSignalingGrantPreparer preparer;

    setUp(() {
      identity = _RecordingIdentitySession();
      postAdapter = _RecordingPostAdapter();
      preparer = WebSignalingGrantPreparer(
        apiBaseUrl: Uri.parse('https://api.example.test/v1/'),
        deviceIdentitySession: identity,
        postAdapter: postAdapter,
      );
    });

    test('coalesces concurrent preparation for the same session', () async {
      final completion = Completer<void>();
      postAdapter.onPost = () => completion.future;

      final first = preparer.prepare('session-1');
      final second = preparer.prepare('session-1');
      await Future<void>.delayed(Duration.zero);

      expect(identical(first, second), isTrue);
      expect(postAdapter.requests, hasLength(1));

      completion.complete();
      await Future.wait([first, second]);
    });

    test('keeps a pending POST coalesced after a caller times out', () async {
      final completion = Completer<void>();
      postAdapter.onPost = () => completion.future;

      final first = preparer.prepare('session-1');
      await expectLater(
        first.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      final second = preparer.prepare('session-1');
      await Future<void>.delayed(Duration.zero);

      expect(identical(first, second), isTrue);
      expect(postAdapter.requests, hasLength(1));

      completion.complete();
      await second;
    });

    test(
      'posts the cached bearer, session JSON, and browser credentials',
      () async {
        await preparer.prepare('session-1');

        expect(identity.forceRefreshCalls, [false]);
        expect(postAdapter.credentialsEnabled, isTrue);
        expect(postAdapter.requests, hasLength(1));
        final request = postAdapter.requests.single;
        expect(
          request.uri,
          Uri.parse('https://api.example.test/api/signaling/grant'),
        );
        expect(request.data, <String, Object?>{'sessionId': 'session-1'});
        expect(request.bearer, 'cached-bearer');
      },
    );

    test('propagates a non-2xx POST failure', () async {
      final failure = DioException(
        requestOptions: RequestOptions(path: '/api/signaling/grant'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/signaling/grant'),
          statusCode: 403,
        ),
      );
      postAdapter.onPost = () => Future<void>.error(failure);

      await expectLater(preparer.prepare('session-1'), throwsA(same(failure)));
    });

    test('allows a later retry after a failed POST', () async {
      var attempts = 0;
      postAdapter.onPost = () {
        attempts += 1;
        if (attempts == 1) {
          return Future<void>.error(
            DioException(
              requestOptions: RequestOptions(path: '/api/signaling/grant'),
            ),
          );
        }
        return Future<void>.value();
      };

      await expectLater(
        preparer.prepare('session-1'),
        throwsA(isA<DioException>()),
      );
      await preparer.prepare('session-1');

      expect(attempts, 2);
    });
  });

  test('IO signaling grant preparation is a no-op', () async {
    await const IoSignalingGrantPreparer().prepare('session-1');
  });
}

class _UnusedDeviceIdentityApi implements DeviceIdentityApi {
  @override
  Future<BootstrapDeviceResponse> bootstrap(BootstrapDeviceRequest request) =>
      throw UnimplementedError();

  @override
  Future<DeviceTokenResponse> token(DeviceTokenRequest request) =>
      throw UnimplementedError();
}

class _UnusedDeviceCredentialStorage implements DeviceCredentialStorage {
  @override
  Future<void> clear() => throw UnimplementedError();

  @override
  Future<DeviceCredential?> read() => throw UnimplementedError();

  @override
  Future<void> write(DeviceCredential credential) => throw UnimplementedError();
}
