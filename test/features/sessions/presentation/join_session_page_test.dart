import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonic_relay/app/di/app_providers.dart';
import 'package:sonic_relay/core/widgets/app_branding_header.dart';
import 'package:sonic_relay/features/sessions/data/dto/discoverable_session.dart';
import 'package:sonic_relay/features/sessions/data/dto/public_room_info.dart';
import 'package:sonic_relay/features/sessions/data/sessions_repository.dart';
import 'package:sonic_relay/features/sessions/domain/stream_session.dart';
import 'package:sonic_relay/features/sessions/presentation/join_session_page.dart';
import 'package:sonic_relay/features/sessions/presentation/join_session_view_model.dart';
import 'package:sonic_relay/features/sessions/presentation/widgets/discovered_sessions_list.dart';
import 'package:sonic_relay/features/sessions/presentation/widgets/public_room_card.dart';
import 'package:sonic_relay/features/support/presentation/widgets/support_project_card.dart';

const _discoveredSession = DiscoverableSession(
  sessionId: '11111111-1111-1111-1111-111111111111',
  publisherDeviceName: 'VITOR-DESKTOP',
  status: 'waiting',
  viewerCount: 0,
  maxViewers: 3,
);

Widget _wrap({
  List<DiscoverableSession> discoverable = const [],
  PublicRoomInfo publicRoom = const PublicRoomInfo.disabled(),
}) {
  return ProviderScope(
    overrides: [
      discoverableSessionsProvider.overrideWith(
        (ref) => Stream.value(discoverable),
      ),
      publicRoomProvider.overrideWith((ref) => Stream.value(publicRoom)),
    ],
    child: const MaterialApp(home: JoinSessionPage()),
  );
}

/// Records `joinById` calls instead of hitting a real backend, so the tap-to-join path can be
/// exercised without leaving a live Dio request pending after the test.
class _FakeSessionsRepository implements SessionsRepository {
  String? joinedSessionId;

  @override
  StreamSession? get currentSession => null;

  @override
  Future<List<DiscoverableSession>> discover() async => const [];

  @override
  Future<StreamSession> join(String code) => throw UnimplementedError();

  @override
  Future<StreamSession> joinById(String sessionId) async {
    joinedSessionId = sessionId;
    return StreamSession(
      sessionId: sessionId,
      signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
    );
  }

  @override
  Future<PublicRoomInfo> getPublicRoom() async => const PublicRoomInfo.disabled();
}

void main() {
  testWidgets('shows local validation before joining', (tester) async {
    await tester.pumpWidget(_wrap());

    await tester.tap(find.text('Join stream'));
    await tester.pump();

    expect(find.text('Enter a valid session code.'), findsOneWidget);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(JoinSessionPage)),
      ).read(joinSessionViewModelProvider).validationMessage,
      'Enter a valid session code.',
    );
  });

  testWidgets('lists discovered sessions below the code field', (tester) async {
    await tester.pumpWidget(
      _wrap(discoverable: const [_discoveredSession]),
    );
    await tester.pumpAndSettle();

    expect(find.text('VITOR-DESKTOP'), findsOneWidget);
  });

  testWidgets('renders nothing extra when no session is discovered', (tester) async {
    await tester.pumpWidget(_wrap(discoverable: const []));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoveredSessionsList), findsNothing);
  });

  testWidgets('shows the public room card when the room is enabled', (tester) async {
    await tester.pumpWidget(
      _wrap(
        publicRoom: const PublicRoomInfo(
          enabled: true,
          sessionId: 'public-room-session-id',
          maxViewers: 20,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PublicRoomCard), findsOneWidget);
    expect(find.text('Public Radio'), findsOneWidget);
  });

  testWidgets('hides the public room card when the room is disabled', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Public Radio'), findsNothing);
  });

  testWidgets(
    'tapping a discovered session joins it by id and navigates to waiting',
    (tester) async {
      final repository = _FakeSessionsRepository();
      final router = GoRouter(
        initialLocation: '/join',
        routes: [
          GoRoute(path: '/join', builder: (_, _) => const JoinSessionPage()),
          GoRoute(
            path: '/session/waiting',
            builder: (_, _) => const Scaffold(body: Text('Waiting')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            discoverableSessionsProvider.overrideWith(
              (ref) => Stream.value(const [_discoveredSession]),
            ),
            publicRoomProvider.overrideWith(
              (ref) => Stream.value(const PublicRoomInfo.disabled()),
            ),
            sessionsRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // The discovered-session list sits below the fold on the default 800x600
      // test surface now that the page leads with the branding header.
      await tester.ensureVisible(find.byType(ListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(repository.joinedSessionId, _discoveredSession.sessionId);
      expect(find.text('Waiting'), findsOneWidget);
    },
  );

  testWidgets('exposes a how-to-use entry point that opens /how-to-use', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/join',
      routes: [
        GoRoute(path: '/join', builder: (_, _) => const JoinSessionPage()),
        GoRoute(
          path: '/how-to-use',
          builder: (_, _) => const Scaffold(body: Text('How to use page')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoverableSessionsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          publicRoomProvider.overrideWith(
            (ref) => Stream.value(const PublicRoomInfo.disabled()),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.byTooltip('How to use'));
    await tester.pumpAndSettle();

    expect(find.text('How to use page'), findsOneWidget);
  });

  testWidgets('exposes a pair-a-new-device entry point that opens /pair', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/join',
      routes: [
        GoRoute(path: '/join', builder: (_, _) => const JoinSessionPage()),
        GoRoute(
          path: '/pair',
          builder: (_, _) => const Scaffold(body: Text('Pair device page')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoverableSessionsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          publicRoomProvider.overrideWith(
            (ref) => Stream.value(const PublicRoomInfo.disabled()),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.byTooltip('Pair a new device'));
    await tester.pumpAndSettle();

    expect(find.text('Pair device page'), findsOneWidget);
  });

  testWidgets('leads with the branding header above the join controls', (
    tester,
  ) async {
    // Testers read the screen as unfinished when nothing on it named or
    // explained the app (SonicRelay#50), so the logo, name and one-line
    // description come first — but stay above, never inside, the join card.
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byType(AppBrandingHeader), findsOneWidget);
    expect(find.text('SonicRelay'), findsOneWidget);
    expect(find.text(AppBrandingHeader.description), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(AppBrandingHeader)).dy,
      lessThan(tester.getTopLeft(find.text('Enter session code')).dy),
    );
  });

  testWidgets('the donation card sits below the join controls', (tester) async {
    // The relay is funded out of pocket, so the ask lives on the screen every
    // launch lands on — but under the join card, never competing with it.
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    final card = tester.widget<SupportProjectCard>(
      find.byType(SupportProjectCard),
    );
    expect(card.compact, isFalse);
    expect(
      tester.getTopLeft(find.byType(SupportProjectCard)).dy,
      greaterThan(tester.getTopLeft(find.text('Join stream')).dy),
    );
  });
}
