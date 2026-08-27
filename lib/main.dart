import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app/di/app_providers.dart';
import 'app/env/app_config.dart';
import 'app/sonic_relay_app.dart';
import 'core/storage/background_playback_storage.dart';
import 'core/storage/coturn_override_storage.dart';
import 'core/storage/onboarding_storage.dart';
import 'core/storage/relay_mode_storage.dart';
import 'core/storage/server_config_storage.dart';
import 'core/storage/theme_mode_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const secureStorage = FlutterSecureStorage();
  final savedServerUrl =
      await const ServerConfigStorage(secureStorage).read() ??
      AppConfig.defaultServerUrl;
  final savedRelayMode = await const RelayModeStorage(secureStorage).read();
  final savedCoturnOverride = await const CoturnOverrideStorage(
    secureStorage,
  ).read();
  final savedKeepPlaying = await const BackgroundPlaybackStorage(
    secureStorage,
  ).read();
  final savedThemeMode = await const ThemeModeStorage(secureStorage).read();
  final savedOnboardingCompleted = await const OnboardingStorage(
    secureStorage,
  ).read();
  final diagnosticsDirectory = kIsWeb
      ? 'web'
      : (await getApplicationSupportDirectory()).path;

  runApp(
    ProviderScope(
      overrides: [
        serverUrlProvider.overrideWith(() => ServerUrlNotifier(savedServerUrl)),
        relayModeProvider.overrideWith(() => RelayModeNotifier(savedRelayMode)),
        coturnOverrideProvider.overrideWith(
          () => CoturnOverrideNotifier(savedCoturnOverride),
        ),
        backgroundPlaybackEnabledProvider.overrideWith(
          () => BackgroundPlaybackNotifier(savedKeepPlaying),
        ),
        themeModeProvider.overrideWith(() => ThemeModeNotifier(savedThemeMode)),
        onboardingCompletedProvider.overrideWith(
          () => OnboardingCompletedNotifier(savedOnboardingCompleted),
        ),
        diagnosticsDirectoryProvider.overrideWithValue(diagnosticsDirectory),
      ],
      child: const SonicRelayApp(),
    ),
  );
}
