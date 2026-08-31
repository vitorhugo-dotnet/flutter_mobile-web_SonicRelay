import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/diagnostics/diagnostic_log.dart';
import '../../core/diagnostics/platform_diagnostic_log.dart';
import '../../core/http/auth_interceptor.dart';
import '../../core/http/dio_client.dart';
import '../../core/network/network_monitor.dart';
import '../../core/platform/host_device_name.dart';
import '../../core/platform/host_platform.dart';
import '../../core/storage/background_playback_storage.dart';
import '../../core/storage/coturn_override_storage.dart';
import '../../core/storage/onboarding_storage.dart';
import '../../core/storage/relay_mode_storage.dart';
import '../../core/storage/server_config_storage.dart';
import '../../core/storage/theme_mode_storage.dart';
import '../../core/webrtc/relay_modes.dart';
import '../../core/webrtc/relay_settings_api.dart';
import '../../features/background/data/foreground_stream_service.dart';
import '../../features/background/presentation/stream_lifecycle_controller.dart';
import '../../features/listener/presentation/listener_view_model.dart';
import '../../core/webrtc/ice_servers_api.dart';
import '../../core/webrtc/ice_servers_repository.dart';
import '../../core/webrtc/rtc_ice_server_config.dart';
import '../../core/webrtc/rtc_peer_connection_factory.dart';
import '../../core/websocket/platform_websocket_connector.dart';
import '../../core/websocket/websocket_client.dart';
import '../../features/device_identity/data/device_credential_storage.dart';
import '../../features/device_identity/data/device_identity_api.dart';
import '../../features/device_identity/data/device_identity_session.dart';
import '../../features/device_identity/data/in_memory_device_credential_storage.dart';
import '../../features/pairing/data/pairing_api.dart';
import '../../features/pairing/data/pairing_repository.dart';
import '../../features/pairing/domain/device_pairing.dart';
import '../../features/sessions/data/dto/discoverable_session.dart';
import '../../features/sessions/data/dto/public_room_info.dart';
import '../../features/sessions/data/sessions_api.dart';
import '../../features/sessions/data/sessions_repository.dart';
import '../../features/listener/data/audio_receiver_service.dart';
import '../../features/listener/data/webrtc_receiver_service.dart';
import '../../features/signaling/data/signaling_client.dart';
import '../../features/signaling/data/signaling_grant_preparer.dart';
import '../../features/signaling/data/platform_signaling_grant_preparer.dart';
import '../env/app_config.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

/// The directory DiagnosticLog writes under — resolved once at startup (see
/// main.dart) since path_provider's directory lookup is async and this
/// provider must be synchronous to construct DiagnosticLog eagerly.
final diagnosticsDirectoryProvider = Provider<String>(
  (ref) => throw UnimplementedError('overridden in main()'),
);

final diagnosticLogProvider = Provider<DiagnosticLog>(
  (ref) => createDiagnosticLog(ref.watch(diagnosticsDirectoryProvider)),
);

typedef DiagnosticFileShare = Future<void> Function(String path);

/// Shares an exported diagnostics file on platforms where [DiagnosticLog]
/// produces a filesystem path. This stays injectable so widget tests do not
/// invoke share_plus platform channels.
final diagnosticFileShareProvider = Provider<DiagnosticFileShare>((ref) {
  return (path) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  };
});

final serverConfigStorageProvider = Provider<ServerConfigStorage>(
  (ref) => ServerConfigStorage(ref.watch(secureStorageProvider)),
);

/// Holds the currently configured server base URL. The initial value is
/// injected at startup via an override in `main()` with the persisted URL
/// (falling back to [AppConfig.defaultServerUrl]). Updating it persists the
/// new URL and rebuilds every provider that depends on [appConfigProvider].
final serverUrlProvider = NotifierProvider<ServerUrlNotifier, String>(
  ServerUrlNotifier.new,
);

class ServerUrlNotifier extends Notifier<String> {
  ServerUrlNotifier([this._initialUrl = AppConfig.defaultServerUrl]);

  final String _initialUrl;

  @override
  String build() => AppConfig.normalizeServerUrl(_initialUrl);

  Future<void> update(String url) async {
    final normalized = AppConfig.normalizeServerUrl(url);
    await ref.read(serverConfigStorageProvider).write(normalized);
    state = normalized;
  }

  Future<void> reset() async {
    await ref.read(serverConfigStorageProvider).clear();
    state = AppConfig.normalizeServerUrl(AppConfig.defaultServerUrl);
  }
}

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromServerUrl(ref.watch(serverUrlProvider)),
);

final relayModeStorageProvider = Provider<RelayModeStorage>(
  (ref) => RelayModeStorage(ref.watch(secureStorageProvider)),
);

/// This device's relay policy. Local by design: it used to sync through a backend row that
/// was global to the whole deployment, so one device changing it changed the relay for every
/// other device the backend served.
final relayModeProvider = NotifierProvider<RelayModeNotifier, String>(
  RelayModeNotifier.new,
);

class RelayModeNotifier extends Notifier<String> {
  RelayModeNotifier([this._initial = RelayModes.automatic]);

  final String _initial;

  @override
  String build() => _initial;

  Future<void> set(String mode) async {
    await ref.read(relayModeStorageProvider).write(mode);
    state = mode;
  }
}

final themeModeStorageProvider = Provider<ThemeModeStorage>(
  (ref) => ThemeModeStorage(ref.watch(secureStorageProvider)),
);

/// The viewer's appearance preference, applied directly to
/// `MaterialApp.themeMode`. Local-only, like [relayModeProvider]; unlike it,
/// there is no backend counterpart to sync — appearance is a per-device
/// display setting, not something meaningful to share across paired devices.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  ThemeModeNotifier([this._initial = ThemeMode.system]);

  final ThemeMode _initial;

  @override
  ThemeMode build() => _initial;

  Future<void> set(ThemeMode mode) async {
    await ref.read(themeModeStorageProvider).write(mode);
    state = mode;
  }
}

final relaySettingsApiProvider = Provider<RelaySettingsApi>(
  (ref) => RelaySettingsApi(ref.watch(dioProvider)),
);

/// Best-effort two-way sync between the local relay preferences and the
/// backend's per-device relay settings. The backend resolves the effective
/// settings across this device's active pairings (latest write wins), so a
/// change made here reaches the paired desktop and a change made there shows
/// up here on the next [pull]. Every call is best-effort: an unreachable or
/// older backend leaves the local preferences untouched and fully functional.
final relaySettingsSyncProvider = Provider<RelaySettingsSync>(
  RelaySettingsSync.new,
);

class RelaySettingsSync {
  RelaySettingsSync(this._ref);

  final Ref _ref;

  Future<void> pull() async {
    if (_ref.read(deviceReadinessProvider).status !=
        DeviceReadinessStatus.ready) {
      return;
    }
    try {
      final settings = await _ref.read(relaySettingsApiProvider).fetch();
      if (RelayModes.isValid(settings.relayMode)) {
        await _ref.read(relayModeProvider.notifier).set(settings.relayMode);
      }
      await _ref
          .read(coturnOverrideProvider.notifier)
          .set(settings.turnUris.isEmpty ? null : settings.turnUris.first);
    } catch (_) {
      // Keep the local values; sync must never break the settings screen.
    }
  }

  Future<void> pushRelayMode(String mode) async {
    try {
      await _ref.read(relaySettingsApiProvider).update(relayMode: mode);
    } catch (_) {
      // The local save already succeeded; the next successful push wins.
    }
  }

  Future<void> pushCoturnUrl(String? url) async {
    final normalized = url?.trim();
    try {
      await _ref
          .read(relaySettingsApiProvider)
          .update(
            turnUris: normalized == null || normalized.isEmpty
                ? const []
                : [normalized],
          );
    } catch (_) {
      // Same best-effort contract as pushRelayMode.
    }
  }
}

final coturnOverrideStorageProvider = Provider<CoturnOverrideStorage>(
  (ref) => CoturnOverrideStorage(ref.watch(secureStorageProvider)),
);

/// This device's local override for the TURN URL the backend hands out, or null to use the
/// backend's own value. See [CoturnOverrideStorage] for why it is never pre-filled and only
/// works against a coturn sharing the deployment's static auth secret.
final coturnOverrideProvider =
    NotifierProvider<CoturnOverrideNotifier, String?>(
      CoturnOverrideNotifier.new,
    );

class CoturnOverrideNotifier extends Notifier<String?> {
  CoturnOverrideNotifier([this._initial]);

  final String? _initial;

  @override
  String? build() => _initial;

  Future<void> set(String? url) async {
    final normalized = (url == null || url.trim().isEmpty) ? null : url.trim();
    await ref.read(coturnOverrideStorageProvider).write(normalized);
    state = normalized;
  }
}

final onboardingStorageProvider = Provider<OnboardingStorage>(
  (ref) => OnboardingStorage(ref.watch(secureStorageProvider)),
);

/// Whether the viewer has completed (or skipped) the first-use onboarding.
/// Persisted; false by default so a fresh install (or one with app data
/// cleared) always sees it once. Seeded at startup by an override in
/// `main()`.
final onboardingCompletedProvider =
    NotifierProvider<OnboardingCompletedNotifier, bool>(
      OnboardingCompletedNotifier.new,
    );

class OnboardingCompletedNotifier extends Notifier<bool> {
  OnboardingCompletedNotifier([this._initial = false]);

  final bool _initial;

  @override
  bool build() => _initial;

  Future<void> complete() async {
    await ref.read(onboardingStorageProvider).write(true);
    state = true;
  }
}

/// The `platform` value this client reports at device bootstrap.
final devicePlatformProvider = Provider<String>((ref) => hostPlatformName);

/// Opens an external URL (currently the privacy policy). Behind a provider so a
/// widget test can assert what the app tried to open without driving the
/// url_launcher platform channel, which has no implementation under
/// `flutter test`. Returns false when no handler exists for the URL.
final externalLinkLauncherProvider =
    Provider<Future<bool> Function(Uri)>((ref) {
  return (uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
});

/// The device-name lookup the identity session uses at bootstrap. Behind a
/// provider so it can be overridden without driving the `device_info_plus`
/// platform channel.
final deviceDisplayNameProvider = Provider<Future<String?> Function()>(
  (ref) => resolveHostDeviceName,
);

/// Where this client keeps its device credential.
///
/// The browser gets the in-memory store: dotnet_SonicRelay#33 requires a web
/// publisher's identity to be ephemeral, and `flutter_secure_storage` on the
/// web is `localStorage` behind a reassuring name.
final deviceCredentialStorageProvider = Provider<DeviceCredentialStorage>(
  (ref) => isWebHost
      ? InMemoryDeviceCredentialStorage()
      : SecureDeviceCredentialStorage(ref.watch(secureStorageProvider)),
);

final deviceIdentityDioProvider = Provider<Dio>((ref) {
  final config = ref.watch(appConfigProvider);
  return Dio(
    BaseOptions(
      baseUrl: config.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
});

final deviceIdentityApiProvider = Provider<DeviceIdentityApi>(
  (ref) => DioDeviceIdentityApi(ref.watch(deviceIdentityDioProvider)),
);

final deviceIdentityInvalidationProvider =
    NotifierProvider<DeviceIdentityInvalidationNotifier, int>(
      DeviceIdentityInvalidationNotifier.new,
    );

class DeviceIdentityInvalidationNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void publish() => state += 1;
}

final deviceIdentitySessionProvider = Provider<DeviceIdentitySession>(
  (ref) => DeviceIdentitySession(
    api: ref.watch(deviceIdentityApiProvider),
    storage: ref.watch(deviceCredentialStorageProvider),
    deviceName: 'SonicRelay ${ref.watch(devicePlatformProvider)} viewer',
    deviceNameResolver: ref.watch(deviceDisplayNameProvider),
    platform: ref.watch(devicePlatformProvider),
    onInvalidated: () =>
        ref.read(deviceIdentityInvalidationProvider.notifier).publish(),
  ),
);

enum DeviceReadinessStatus { restoring, deviceSetup, pairingRequired, ready }

class DeviceReadinessState {
  const DeviceReadinessState.restoring()
    : status = DeviceReadinessStatus.restoring,
      errorMessage = null,
      requiresReset = false;

  const DeviceReadinessState.deviceSetup({
    this.errorMessage,
    this.requiresReset = false,
  }) : status = DeviceReadinessStatus.deviceSetup;

  const DeviceReadinessState.pairingRequired()
    : status = DeviceReadinessStatus.pairingRequired,
      errorMessage = null,
      requiresReset = false;

  const DeviceReadinessState.ready()
    : status = DeviceReadinessStatus.ready,
      errorMessage = null,
      requiresReset = false;

  final DeviceReadinessStatus status;
  final String? errorMessage;
  final bool requiresReset;
}

final deviceReadinessProvider =
    NotifierProvider<DeviceReadinessNotifier, DeviceReadinessState>(
      DeviceReadinessNotifier.new,
    );

class DeviceReadinessNotifier extends Notifier<DeviceReadinessState> {
  late DeviceIdentitySession _identitySession;
  late DeviceCredentialStorage _credentialStorage;
  late PairingRepository _pairingRepository;
  Future<void>? _initialization;

  @override
  DeviceReadinessState build() {
    _identitySession = ref.watch(deviceIdentitySessionProvider);
    _credentialStorage = ref.watch(deviceCredentialStorageProvider);
    _pairingRepository = ref.watch(pairingRepositoryProvider);
    ref.listen(deviceIdentityInvalidationProvider, (_, _) {
      requireDeviceSetup('This device identity must be reset.');
    });
    Future<void>.microtask(initialize);
    return const DeviceReadinessState.restoring();
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;

    late final Future<void> current;
    current = _initialize().whenComplete(() {
      if (identical(_initialization, current)) _initialization = null;
    });
    _initialization = current;
    return current;
  }

  Future<void> retry() async {
    final requiresReset = state.requiresReset;
    state = const DeviceReadinessState.restoring();
    if (requiresReset && !await _resetIdentity()) return;
    await initialize();
  }

  Future<void> resetAndInitialize() async {
    state = const DeviceReadinessState.restoring();
    if (!await _resetIdentity()) return;
    await initialize();
  }

  Future<bool> _resetIdentity() async {
    try {
      await _identitySession.reset();
      return true;
    } catch (_) {
      state = const DeviceReadinessState.deviceSetup(
        errorMessage: 'Unable to reset this device. Please retry.',
        requiresReset: true,
      );
      return false;
    }
  }

  void syncPairings(Iterable<DevicePairing> pairings) {
    if (state.status == DeviceReadinessStatus.restoring ||
        state.status == DeviceReadinessStatus.deviceSetup) {
      return;
    }
    _setPairingReadiness(pairings);
  }

  void requireDeviceSetup([String? message]) {
    state = DeviceReadinessState.deviceSetup(
      errorMessage: message,
      requiresReset: true,
    );
  }

  Future<void> _initialize() async {
    try {
      final existingCredential = await _credentialStorage.read();
      if (existingCredential == null) {
        state = const DeviceReadinessState.deviceSetup();
      }

      await _identitySession.accessToken();
      final credential = await _credentialStorage.read();
      if (credential == null) {
        state = const DeviceReadinessState.deviceSetup(
          errorMessage: 'Unable to prepare this device. Please retry.',
        );
        return;
      }

      _setPairingReadiness(await _pairingRepository.list(credential.deviceId));
    } on DeviceCredentialStorageException catch (error) {
      state = DeviceReadinessState.deviceSetup(
        errorMessage: error.message,
        requiresReset: true,
      );
    } on DeviceIdentitySessionInvalidatedException {
      state = const DeviceReadinessState.deviceSetup(
        errorMessage: 'This device identity must be reset.',
        requiresReset: true,
      );
    } on DioException catch (error) {
      state = DeviceReadinessState.deviceSetup(
        errorMessage: 'Unable to prepare this device. Please retry.',
        requiresReset: error.response?.statusCode == 401,
      );
    } on PairingFailure catch (error) {
      state = DeviceReadinessState.deviceSetup(errorMessage: error.message);
    } catch (_) {
      state = const DeviceReadinessState.deviceSetup(
        errorMessage: 'Unable to prepare this device. Please retry.',
      );
    }
  }

  void _setPairingReadiness(Iterable<DevicePairing> pairings) {
    state = pairings.any((pairing) => pairing.status == 'active')
        ? const DeviceReadinessState.ready()
        : const DeviceReadinessState.pairingRequired();
  }
}

final authInterceptorProvider = Provider<AuthInterceptor>((ref) {
  return AuthInterceptor(
    deviceIdentitySession: ref.watch(deviceIdentitySessionProvider),
    replayDio: ref.watch(deviceIdentityDioProvider),
  );
});

final dioProvider = Provider<Dio>((ref) {
  return createDioClient(
    ref.watch(appConfigProvider),
    ref.watch(authInterceptorProvider),
  );
});

final pairingRepositoryProvider = Provider<PairingRepository>(
  (ref) => PairingRepository(api: DioPairingApi(ref.watch(dioProvider))),
);

final sessionsApiProvider = Provider<SessionsApi>(
  (ref) => DioSessionsApi(ref.watch(dioProvider)),
);

final sessionsRepositoryProvider = Provider<SessionsRepository>(
  (ref) => SessionsRepository(
    api: ref.watch(sessionsApiProvider),
    config: ref.watch(appConfigProvider),
  ),
);

/// Polls for sessions of paired publishers while the join page is mounted. `autoDispose` so
/// the poll stops with the page, and a short period because the publisher can start a session
/// at any moment and this is the only signal the viewer gets.
final discoverableSessionsProvider =
    StreamProvider.autoDispose<List<DiscoverableSession>>((ref) async* {
  final repository = ref.watch(sessionsRepositoryProvider);
  while (true) {
    yield await repository.discover();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Polls the public radio room's availability while the join page is mounted. Fetching this
/// also auto-pairs this device with the room server-side, so — unlike
/// [discoverableSessionsProvider] — no prior manual pairing is ever required to see or join
/// it (docs/superpowers/specs/2026-08-19-public-radio-room-design.md in dotnet_SonicRelay).
final publicRoomProvider = StreamProvider.autoDispose<PublicRoomInfo>((ref) async* {
  final repository = ref.watch(sessionsRepositoryProvider);
  while (true) {
    yield await repository.getPublicRoom();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Watches the device's network transports so a Wi-Fi/cellular handover can
/// retry signaling immediately instead of waiting out a backoff scheduled while
/// there was no route at all, and so a device with no route at all parks instead
/// of spending its reconnect budget. Only Android and iOS have a plugin behind
/// `connectivity_plus` here; everything else (including tests) keeps the plain
/// backoff by always reporting itself online.
final networkMonitorProvider = Provider<NetworkMonitor>(
  (ref) => isMobileHost
      ? ConnectivityNetworkMonitor()
      : const NoopNetworkMonitor(),
);

final webSocketClientProvider = Provider<WebSocketClient>(
  (ref) => WebSocketClient(
    connector: defaultWebSocketConnector,
    diagnosticLog: ref.watch(diagnosticLogProvider),
    isNetworkAvailable: () => ref.read(networkMonitorProvider).isOnline,
  ),
);

final signalingAuthenticationPolicyProvider =
    Provider<SignalingAuthenticationPolicy>(
      (ref) => isWebHost
          ? SignalingAuthenticationPolicy.browserCookieGrant
          : SignalingAuthenticationPolicy.bearerHeader,
    );

final signalingClientProvider = Provider<SignalingClient>(
  (ref) => SignalingClient(
    webSocketClient: ref.watch(webSocketClientProvider),
    deviceIdentitySession: ref.watch(deviceIdentitySessionProvider),
    diagnosticLog: ref.watch(diagnosticLogProvider),
    authenticationPolicy: ref.watch(signalingAuthenticationPolicyProvider),
    signalingGrantPreparer: ref.watch(signalingGrantPreparerProvider),
    networkMonitor: ref.watch(networkMonitorProvider),
  ),
);

final signalingGrantPreparerProvider = Provider<SignalingGrantPreparer>(
  (ref) => createPlatformSignalingGrantPreparer(
    apiBaseUrl: Uri.parse(ref.watch(appConfigProvider).apiBaseUrl),
    deviceIdentitySession: ref.watch(deviceIdentitySessionProvider),
  ),
);

final rtcIceServerConfigProvider = Provider<RtcIceServerConfig>(
  (ref) => RtcIceServerConfig.defaults(),
);

final iceServersApiProvider = Provider<IceServersApi>(
  (ref) => DioIceServersApi(ref.watch(dioProvider)),
);

final iceServersRepositoryProvider = Provider<IceServersRepository>(
  (ref) => IceServersRepository(
    api: ref.watch(iceServersApiProvider),
    relayMode: () => ref.read(relayModeProvider),
    coturnOverride: () => ref.read(coturnOverrideProvider),
  ),
);

final rtcPeerConnectionFactoryProvider = Provider<RtcPeerConnectionFactory>(
  (ref) => const FlutterWebRtcPeerConnectionFactory(),
);

final audioReceiverServiceProvider = Provider<AudioReceiverService>(
  (ref) => WebRtcAudioReceiverService(),
);

final webRtcReceiverServiceProvider = Provider<WebRtcReceiverService>((ref) {
  final service = WebRtcReceiverService(
    peerConnectionFactory: ref.watch(rtcPeerConnectionFactoryProvider),
    audioReceiver: ref.watch(audioReceiverServiceProvider),
    iceServers: ref.watch(rtcIceServerConfigProvider),
    iceServersResolver: ref.watch(iceServersRepositoryProvider).resolve,
    // disableFallback needs no explicit handling here: the backend's ICE-servers endpoint
    // already omits TURN entries entirely when the effective relay mode is disableFallback
    // (dotnet_SonicRelay's TurnCredentialService), so this client naturally can't fall back
    // to relay — there's nothing to fall back to.
    forceRelay: () => ref.read(relayModeProvider) == RelayModes.forceRelay,
  );
  ref.onDispose(service.dispose);
  return service;
});

final backgroundPlaybackStorageProvider = Provider<BackgroundPlaybackStorage>(
  (ref) => BackgroundPlaybackStorage(ref.watch(secureStorageProvider)),
);

/// Whether the viewer keeps audio playing (via the Android foreground service)
/// while the app is backgrounded during an active stream. Persisted; on by
/// default. Seeded at startup by an override in `main()`.
final backgroundPlaybackEnabledProvider =
    NotifierProvider<BackgroundPlaybackNotifier, bool>(
      BackgroundPlaybackNotifier.new,
    );

class BackgroundPlaybackNotifier extends Notifier<bool> {
  BackgroundPlaybackNotifier([this._initial = true]);

  final bool _initial;

  @override
  bool build() => _initial;

  Future<void> set(bool value) async {
    await ref.read(backgroundPlaybackStorageProvider).write(value);
    state = value;
  }
}

/// The platform foreground service: a real `mediaPlayback` service on Android,
/// a no-op everywhere else (and in tests).
final foregroundStreamServiceProvider = Provider<ForegroundStreamService>((
  ref,
) {
  final service = isAndroidHost
      ? AndroidForegroundStreamServiceBridge()
      : NoopForegroundStreamService();
  ref.onDispose(service.dispose);
  return service;
});

/// Decides when the foreground service runs. Callbacks are read lazily so this
/// provider never builds the listener view model (avoiding a dependency cycle).
final streamLifecycleControllerProvider = Provider<StreamLifecycleController>((
  ref,
) {
  final controller = StreamLifecycleController(
    service: ref.watch(foregroundStreamServiceProvider),
    keepPlayingInBackground: () => ref.read(backgroundPlaybackEnabledProvider),
    onStopRequested: () => ref.read(listenerViewModelProvider.notifier).leave(),
    onReconnectRequested: () =>
        ref.read(listenerViewModelProvider.notifier).reconnect(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
