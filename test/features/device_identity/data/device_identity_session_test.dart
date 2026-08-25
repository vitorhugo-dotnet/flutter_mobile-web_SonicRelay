import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/device_identity/data/device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_api.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_session.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_response.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_response.dart';
import 'package:sonic_relay/features/device_identity/data/in_memory_device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/domain/device_credential.dart';

void main() {
  const secureStorage = FlutterSecureStorage();
  late DeviceCredentialStorage storage;
  late _FakeDeviceIdentityApi api;
  late DateTime now;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureDeviceCredentialStorage(secureStorage);
    api = _FakeDeviceIdentityApi();
    now = DateTime.utc(2026, 7, 29, 12);
  });

  DeviceIdentitySession createSession({
    void Function()? onInvalidated,
    DeviceCredentialStorage? credentialStorage,
  }) => DeviceIdentitySession(
    api: api,
    storage: credentialStorage ?? storage,
    deviceName: 'Pixel 9',
    platform: 'android',
    now: () => now,
    onInvalidated: onInvalidated,
  );

  test('bootstraps an absent credential before exchanging a token', () async {
    api.tokenResponses.add(
      _token('token-1', now.add(const Duration(hours: 1))),
    );

    final value = await createSession().accessToken();

    expect(value, 'token-1');
    expect(api.bootstrapRequests, [
      const BootstrapDeviceRequest(
        name: 'Pixel 9',
        deviceType: 'flutter_viewer',
        platform: 'android',
      ),
    ]);
    expect(api.tokenRequests, [
      const DeviceTokenRequest(
        deviceId: 'device-1',
        credentialSecret: 'secret-1',
      ),
    ]);
    expect(
      await storage.read(),
      const DeviceCredential(
        deviceId: 'device-1',
        credentialSecret: 'secret-1',
        credentialVersion: 1,
        deviceType: 'flutter_viewer',
        platform: 'android',
      ),
    );
  });

  // The browser publisher shares this session but registers as its own device
  // type, so the backend can scope it and expire it (dotnet_SonicRelay#33).
  test('bootstraps with the device type it was given', () async {
    api.tokenResponses.add(
      _token('token-1', now.add(const Duration(hours: 1))),
    );
    final webStorage = InMemoryDeviceCredentialStorage();

    await DeviceIdentitySession(
      api: api,
      storage: webStorage,
      deviceName: 'SonicRelay web publisher',
      platform: 'web',
      deviceType: webPublisherDeviceType,
      now: () => now,
    ).accessToken();

    expect(api.bootstrapRequests, [
      const BootstrapDeviceRequest(
        name: 'SonicRelay web publisher',
        deviceType: 'web_publisher',
        platform: 'web',
      ),
    ]);
    expect((await webStorage.read())?.deviceType, 'web_publisher');
  });

  test('exchanges a stored credential without bootstrapping', () async {
    await storage.write(_credential);
    api.tokenResponses.add(
      _token('token-1', now.add(const Duration(hours: 1))),
    );

    expect(await createSession().accessToken(), 'token-1');

    expect(api.bootstrapCalls, 0);
    expect(api.tokenRequests.single.deviceId, 'stored-device');
  });

  test(
    'refreshes when the cached token is within the 30 second margin',
    () async {
      await storage.write(_credential);
      api.tokenResponses.addAll([
        _token('token-1', now.add(const Duration(seconds: 31))),
        _token('token-2', now.add(const Duration(hours: 1))),
      ]);
      final session = createSession();
      expect(await session.accessToken(), 'token-1');

      now = now.add(const Duration(seconds: 1));

      expect(await session.accessToken(), 'token-2');
      expect(api.tokenCalls, 2);
    },
  );

  test('returns a cached token outside the expiry margin', () async {
    await storage.write(_credential);
    api.tokenResponses.add(
      _token('token-1', now.add(const Duration(seconds: 31))),
    );
    final session = createSession();

    expect(await session.accessToken(), 'token-1');
    expect(await session.accessToken(), 'token-1');
    expect(api.tokenCalls, 1);
  });

  test('five concurrent callers share one successful exchange', () async {
    await storage.write(_credential);
    final pending = Completer<DeviceTokenResponse>();
    api.pendingToken = pending.future;
    final session = createSession();

    final result = Future.wait(List.generate(5, (_) => session.accessToken()));
    await Future<void>.delayed(Duration.zero);
    expect(api.tokenCalls, 1);
    pending.complete(_token('token-1', now.add(const Duration(hours: 1))));

    expect((await result).toSet(), {'token-1'});
    expect(api.tokenCalls, 1);
  });

  test('reset supersedes a pending exchange and the new token wins', () async {
    await storage.write(_credential);
    final pendingA = Completer<DeviceTokenResponse>();
    api.pendingToken = pendingA.future;
    final session = createSession();
    final tokenA = session.accessToken();
    await Future<void>.delayed(Duration.zero);
    expect(api.tokenCalls, 1);

    await session.reset();
    final pendingB = Completer<DeviceTokenResponse>();
    api.pendingToken = pendingB.future;
    final tokenB = session.accessToken();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final tokenAExpectation = expectLater(
      tokenA,
      throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
    );
    pendingA.complete(_token('token-a', now.add(const Duration(hours: 1))));
    await tokenAExpectation;

    expect(api.bootstrapCalls, 1);
    expect(api.tokenCalls, 2);
    pendingB.complete(_token('token-b', now.add(const Duration(hours: 1))));
    expect(await tokenB, 'token-b');
    expect(await session.accessToken(), 'token-b');
    expect(api.tokenCalls, 2);
  });

  test(
    'late 401 from a reset exchange cannot invalidate the new token',
    () async {
      var invalidations = 0;
      await storage.write(_credential);
      final pendingA = Completer<DeviceTokenResponse>();
      api.pendingToken = pendingA.future;
      final session = createSession(onInvalidated: () => invalidations++);
      final tokenA = session.accessToken();
      await Future<void>.delayed(Duration.zero);

      await session.reset();
      final pendingB = Completer<DeviceTokenResponse>();
      api.pendingToken = pendingB.future;
      final tokenB = session.accessToken();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final tokenAExpectation = expectLater(
        tokenA,
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      pendingA.completeError(
        DioException(
          requestOptions: RequestOptions(path: '/api/devices/token'),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/api/devices/token'),
            statusCode: 401,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      await tokenAExpectation;

      expect(invalidations, 0);
      expect(api.bootstrapCalls, 1);
      expect(api.tokenCalls, 2);
      pendingB.complete(_token('token-b', now.add(const Duration(hours: 1))));
      expect(await tokenB, 'token-b');
      expect(await session.accessToken(), 'token-b');
      expect((await storage.read())?.deviceId, 'device-1');
    },
  );

  test(
    'reset serializes behind a pending bootstrap write before B starts',
    () async {
      final mutationStorage = _PendingWriteCredentialStorage();
      addTearDown(() {
        if (!mutationStorage.releaseFirstWrite.isCompleted) {
          mutationStorage.releaseFirstWrite.complete();
        }
      });
      api.bootstrapResponses.addAll([
        _bootstrap('device-a', 'secret-a'),
        _bootstrap('device-b', 'secret-b'),
      ]);
      api.tokenResponses.add(
        _token('token-b', now.add(const Duration(hours: 1))),
      );
      final session = createSession(credentialStorage: mutationStorage);
      final tokenA = session.accessToken();
      final tokenAExpectation = expectLater(
        tokenA,
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(mutationStorage.writeCalls, 1);

      final reset = session.reset();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(mutationStorage.clearCalls, 0);
      } finally {
        mutationStorage.releaseFirstWrite.complete();
      }
      await tokenAExpectation;
      await reset;

      expect(await session.accessToken(), 'token-b');
      expect(api.bootstrapCalls, 2);
      expect(api.tokenRequests.single.deviceId, 'device-b');
      expect((await mutationStorage.read())?.deviceId, 'device-b');
      expect(await session.accessToken(), 'token-b');
      expect(api.tokenCalls, 1);
    },
  );

  test(
    'reset serializes behind a pending 401 clear before B commits',
    () async {
      var invalidations = 0;
      final mutationStorage = _PendingClearCredentialStorage(_credential);
      addTearDown(() {
        if (!mutationStorage.releaseFirstClear.isCompleted) {
          mutationStorage.releaseFirstClear.complete();
        }
      });
      api.tokenErrors.add(_unauthorizedTokenError());
      api.bootstrapResponses.add(_bootstrap('device-b', 'secret-b'));
      api.tokenResponses.add(
        _token('token-b', now.add(const Duration(hours: 1))),
      );
      final session = createSession(
        credentialStorage: mutationStorage,
        onInvalidated: () => invalidations++,
      );
      final tokenA = session.accessToken();
      final tokenAExpectation = expectLater(
        tokenA,
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(mutationStorage.clearCalls, 1);

      final reset = session.reset();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(mutationStorage.clearCalls, 1);
      } finally {
        mutationStorage.releaseFirstClear.complete();
      }
      await tokenAExpectation;
      await reset;

      expect(invalidations, 0);
      expect(await session.accessToken(), 'token-b');
      expect(api.bootstrapCalls, 1);
      expect(api.tokenRequests.last.deviceId, 'device-b');
      expect((await mutationStorage.read())?.deviceId, 'device-b');
      expect(await session.accessToken(), 'token-b');
      expect(api.tokenCalls, 2);
    },
  );

  test('force refresh exchanges a still valid cached token', () async {
    await storage.write(_credential);
    api.tokenResponses.addAll([
      _token('token-1', now.add(const Duration(hours: 1))),
      _token('token-2', now.add(const Duration(hours: 2))),
    ]);
    final session = createSession();

    expect(await session.accessToken(), 'token-1');
    expect(await session.accessToken(forceRefresh: true), 'token-2');
    expect(api.tokenCalls, 2);
  });

  test(
    'concurrent callers share a token failure and later retry succeeds',
    () async {
      await storage.write(_credential);
      final failure = DioException(
        requestOptions: RequestOptions(path: '/api/devices/token'),
        type: DioExceptionType.connectionError,
      );
      final pending = Completer<DeviceTokenResponse>();
      api.pendingToken = pending.future;
      final session = createSession();

      final calls = List.generate(5, (_) => session.accessToken());
      await Future<void>.delayed(Duration.zero);
      expect(api.tokenCalls, 1);
      pending.completeError(failure);
      for (final call in calls) {
        await expectLater(call, throwsA(same(failure)));
      }
      expect(api.tokenCalls, 1);

      api.pendingToken = null;
      api.tokenResponses.add(
        _token('token-2', now.add(const Duration(hours: 1))),
      );
      expect(await session.accessToken(), 'token-2');
      expect(api.tokenCalls, 2);
    },
  );

  test(
    'token 401 clears the credential and invalidates this session',
    () async {
      var invalidations = 0;
      await storage.write(_credential);
      final unauthorized = DioException(
        requestOptions: RequestOptions(path: '/api/devices/token'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/devices/token'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      );
      api.tokenErrors.add(unauthorized);
      final session = createSession(onInvalidated: () => invalidations++);

      await expectLater(
        session.accessToken(),
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      expect(await storage.read(), isNull);
      expect(api.tokenCalls, 1);
      expect(invalidations, 1);

      await expectLater(
        session.accessToken(),
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      expect(api.bootstrapCalls, 0);
      expect(api.tokenCalls, 1);
    },
  );

  test('reset explicitly permits a new bootstrap after token 401', () async {
    await storage.write(_credential);
    api.tokenErrors.add(
      DioException(
        requestOptions: RequestOptions(path: '/api/devices/token'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/devices/token'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      ),
    );
    final session = createSession();
    await expectLater(
      session.accessToken(),
      throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
    );

    await session.reset();
    api.tokenResponses.add(
      _token('token-2', now.add(const Duration(hours: 1))),
    );

    expect(await session.accessToken(), 'token-2');
    expect(api.bootstrapCalls, 1);
  });

  test(
    'failed revocation cleanup stays invalidated until reset clears storage',
    () async {
      var invalidations = 0;
      final failingStorage = _FailingClearCredentialStorage(
        credential: _credential,
        clearFailuresRemaining: 2,
      );
      api.tokenErrors.add(
        DioException(
          requestOptions: RequestOptions(path: '/api/devices/token'),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/api/devices/token'),
            statusCode: 401,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      final session = createSession(
        credentialStorage: failingStorage,
        onInvalidated: () => invalidations++,
      );

      await expectLater(
        session.accessToken(),
        throwsA(
          isA<DeviceIdentitySessionInvalidatedException>().having(
            (error) => error.toString(),
            'non-sensitive message',
            isNot(contains('secure storage unavailable')),
          ),
        ),
      );
      expect(invalidations, 1);
      expect(failingStorage.clearCalls, 1);

      await expectLater(
        session.accessToken(),
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      expect(api.bootstrapCalls, 0);
      expect(api.tokenCalls, 1);
      expect(invalidations, 1);

      await expectLater(
        session.reset(),
        throwsA(isA<DeviceCredentialStorageException>()),
      );
      expect(failingStorage.clearCalls, 2);
      await expectLater(
        session.accessToken(),
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
      expect(api.bootstrapCalls, 0);

      await session.reset();
      expect(failingStorage.clearCalls, 3);
      api.tokenResponses.add(
        _token('token-after-reset', now.add(const Duration(hours: 1))),
      );
      expect(await session.accessToken(), 'token-after-reset');
      expect(api.bootstrapCalls, 1);
    },
  );

  test(
    'network failure retains the credential and never rebootstraps',
    () async {
      await storage.write(_credential);
      final networkFailure = DioException(
        requestOptions: RequestOptions(path: '/api/devices/token'),
        type: DioExceptionType.connectionError,
      );
      api.tokenErrors.add(networkFailure);
      final session = createSession();

      await expectLater(session.accessToken(), throwsA(same(networkFailure)));

      expect(await storage.read(), _credential);
      expect(api.bootstrapCalls, 0);
    },
  );
}

const _credential = DeviceCredential(
  deviceId: 'stored-device',
  credentialSecret: 'stored-secret',
  credentialVersion: 2,
  deviceType: 'flutter_viewer',
  platform: 'android',
);

DeviceTokenResponse _token(String value, DateTime expiresAt) =>
    DeviceTokenResponse(
      accessToken: value,
      expiresAt: expiresAt,
      scopes: const ['stream:listen'],
    );

BootstrapDeviceResponse _bootstrap(String deviceId, String secret) =>
    BootstrapDeviceResponse(
      deviceId: deviceId,
      credentialSecret: secret,
      credentialVersion: 1,
    );

DioException _unauthorizedTokenError() => DioException(
  requestOptions: RequestOptions(path: '/api/devices/token'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/api/devices/token'),
    statusCode: 401,
  ),
  type: DioExceptionType.badResponse,
);

class _FakeDeviceIdentityApi implements DeviceIdentityApi {
  int bootstrapCalls = 0;
  int tokenCalls = 0;
  final List<BootstrapDeviceRequest> bootstrapRequests = [];
  final List<BootstrapDeviceResponse> bootstrapResponses = [];
  final List<DeviceTokenRequest> tokenRequests = [];
  final List<DeviceTokenResponse> tokenResponses = [];
  final List<Object> tokenErrors = [];
  Future<DeviceTokenResponse>? pendingToken;

  @override
  Future<BootstrapDeviceResponse> bootstrap(
    BootstrapDeviceRequest request,
  ) async {
    bootstrapCalls++;
    bootstrapRequests.add(request);
    if (bootstrapResponses.isNotEmpty) {
      return bootstrapResponses.removeAt(0);
    }
    return const BootstrapDeviceResponse(
      deviceId: 'device-1',
      credentialSecret: 'secret-1',
      credentialVersion: 1,
    );
  }

  @override
  Future<DeviceTokenResponse> token(DeviceTokenRequest request) async {
    tokenCalls++;
    tokenRequests.add(request);
    final pending = pendingToken;
    if (pending != null) return pending;
    if (tokenErrors.isNotEmpty) throw tokenErrors.removeAt(0);
    return tokenResponses.removeAt(0);
  }
}

class _PendingWriteCredentialStorage implements DeviceCredentialStorage {
  final releaseFirstWrite = Completer<void>();
  DeviceCredential? credential;
  int writeCalls = 0;
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    credential = null;
  }

  @override
  Future<DeviceCredential?> read() async => credential;

  @override
  Future<void> write(DeviceCredential value) async {
    writeCalls++;
    if (writeCalls == 1) await releaseFirstWrite.future;
    credential = value;
  }
}

class _PendingClearCredentialStorage implements DeviceCredentialStorage {
  _PendingClearCredentialStorage(this.credential);

  final releaseFirstClear = Completer<void>();
  DeviceCredential? credential;
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearCalls == 1) await releaseFirstClear.future;
    credential = null;
  }

  @override
  Future<DeviceCredential?> read() async => credential;

  @override
  Future<void> write(DeviceCredential value) async => credential = value;
}

class _FailingClearCredentialStorage implements DeviceCredentialStorage {
  _FailingClearCredentialStorage({
    required this.credential,
    required this.clearFailuresRemaining,
  });

  DeviceCredential? credential;
  int clearFailuresRemaining;
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearFailuresRemaining > 0) {
      clearFailuresRemaining--;
      throw const DeviceCredentialStorageException(
        'secure storage unavailable',
      );
    }
    credential = null;
  }

  @override
  Future<DeviceCredential?> read() async => credential;

  @override
  Future<void> write(DeviceCredential value) async => credential = value;
}
