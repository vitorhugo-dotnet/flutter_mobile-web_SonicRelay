import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:sonic_relay/features/pairing/presentation/qr_scanner_page.dart';

const validPayload =
    '{"challengeId":"00000000-0000-0000-0000-000000000001","code":"ABC12345"}';

void main() {
  group('scannerErrorMessage', () {
    test('names permission denial so the user knows what to fix', () {
      for (final code in [
        'CameraAccessDenied',
        'CameraAccessDeniedWithoutPrompt',
        'CameraAccessRestricted',
      ]) {
        expect(
          scannerErrorMessage(CameraException(code, 'denied')),
          'Camera permission denied.',
        );
      }
    });

    test('falls back to a generic message for any other failure', () {
      expect(
        scannerErrorMessage(CameraException('cameraNotFound', 'no camera')),
        'Unable to start the camera.',
      );
      expect(
        scannerErrorMessage(Exception('boom')),
        'Unable to start the camera.',
      );
    });
  });

  testWidgets('starts on open and submits only the first accepted QR frame', (
    tester,
  ) async {
    final controller = _FakeScannerController(raw: validPayload);
    var accepted = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: false),
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) {
            accepted += 1;
            return true;
          },
        ),
      ),
    );

    expect(controller.startCalls, 1);
    await tester.tap(find.byKey(const Key('scanner-detect')));
    await tester.tap(find.byKey(const Key('scanner-detect')));
    await tester.pump();

    expect(accepted, 1);
    expect(controller.stopCalls, 1);
  });

  testWidgets(
    'an unparseable QR surfaces an explicit error and keeps scanning',
    (tester) async {
      final controller = _FakeScannerController(raw: 'https://example.com');
      var accepted = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: QrScannerPage(
            scannerController: controller,
            onAccepted: (_) {
              accepted += 1;
              return true;
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('scanner-detect')));
      await tester.pump();

      expect(
        find.text('That QR code is not a valid pairing code.'),
        findsOneWidget,
      );
      expect(accepted, 0);
      expect(controller.stopCalls, 0);

      // Re-scanning the same rejected payload does not queue a second SnackBar.
      await tester.tap(find.byKey(const Key('scanner-detect')));
      await tester.pump();
      expect(
        find.text('That QR code is not a valid pairing code.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('keeps scanning when pairing rejects a valid QR', (tester) async {
    final controller = _FakeScannerController(raw: validPayload);

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => false,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('scanner-detect')));
    await tester.pump();

    expect(find.text('Unable to pair this device.'), findsOneWidget);
    expect(controller.stopCalls, 1);
    expect(controller.startCalls, 2);
  });

  testWidgets('camera denial keeps a manual fallback', (tester) async {
    final controller = _FakeScannerController(permissionDenied: true);
    var manualFallbacks = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => true,
          onManualFallback: () => manualFallbacks += 1,
        ),
      ),
    );

    expect(find.text('Camera permission denied.'), findsOneWidget);
    expect(find.text('Enter manually'), findsOneWidget);
    await tester.tap(find.text('Enter manually'));
    expect(manualFallbacks, 1);
  });

  testWidgets('stops for hidden paused detached and resumes safely', (
    tester,
  ) async {
    final controller = _FakeScannerController();
    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => true,
        ),
      ),
    );
    expect(controller.startCalls, 1);

    for (final lifecycleState in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(lifecycleState);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    expect(controller.stopCalls, 3);
    expect(controller.startCalls, 4);
  });

  testWidgets('keeps the camera running through inactive', (tester) async {
    // `inactive` covers transient system UI - most notably the camera
    // permission prompt shown the first time this page opens - that
    // overlays the app without backgrounding it. Tearing the scanner down
    // here previously raced camera setup against that prompt and could
    // leave the scanner dead for the rest of the session.
    final controller = _FakeScannerController();
    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => true,
        ),
      ),
    );
    expect(controller.startCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(controller.stopCalls, 0);
  });

  testWidgets('never restarts after submission or dispose', (tester) async {
    final controller = _FakeScannerController(raw: validPayload);
    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => true,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('scanner-detect')));
    await tester.pump();
    expect(controller.startCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.startCalls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    final startsAfterDispose = controller.startCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(controller.startCalls, startsAfterDispose);
    expect(controller.disposeCalls, 1);
  });

  testWidgets('disposes the scanner controller with the page', (tester) async {
    final controller = _FakeScannerController();
    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          scannerController: controller,
          onAccepted: (_) async => true,
        ),
      ),
    );

    expect(controller.disposeCalls, 0);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(controller.disposeCalls, 1);
  });

  group('ZxingPairingScannerController', () {
    // These exercise the real ZXing wiring - the fake used above stands in
    // for it everywhere else - so a regression in how the controller talks
    // to `ReaderWidget` (wrong widget, wrong callback shape, a state class
    // that never notifies) fails a test instead of only showing up on a
    // real device. No platform channels are mocked here, so the widget
    // never reaches a live camera; it only proves the surface it mounts is
    // the real ZXing scanner and that it responds to start/stop.
    testWidgets('mounts the real ZXing scanner surface only while running', (
      tester,
    ) async {
      final controller = ZxingPairingScannerController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: controller.buildScanner(onDetected: (_) {})),
        ),
      );
      expect(find.byType(ReaderWidget), findsNothing);

      await controller.start();
      await tester.pump();
      expect(find.byType(ReaderWidget), findsOneWidget);
      final reader = tester.widget<ReaderWidget>(find.byType(ReaderWidget));
      expect(reader.tryHarder, isTrue);
      expect(reader.tryRotate, isTrue);
      expect(reader.tryDownscale, isTrue);
      expect(reader.cropPercent, 1.0);

      await controller.stop();
      await tester.pump();
      expect(find.byType(ReaderWidget), findsNothing);
    });
  });
}

class _FakeScannerController implements PairingScannerController {
  _FakeScannerController({this.raw, this.permissionDenied = false});

  final String? raw;
  final bool permissionDenied;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Widget buildScanner({required ValueChanged<String?> onDetected}) {
    return Column(
      children: [
        if (permissionDenied) const Text('Camera permission denied.'),
        ElevatedButton(
          key: const Key('scanner-detect'),
          onPressed: () => onDetected(raw),
          child: const Text('Detect'),
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }

  @override
  Future<void> start() async {
    startCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}
