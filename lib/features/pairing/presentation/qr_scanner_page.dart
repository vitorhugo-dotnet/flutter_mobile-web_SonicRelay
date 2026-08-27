import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../domain/pairing_challenge_payload.dart';

typedef PairingPayloadCallback = FutureOr<bool> Function(String raw);

abstract interface class PairingScannerController {
  Future<void> start();

  Future<void> stop();

  Future<void> dispose();

  Widget buildScanner({required ValueChanged<String?> onDetected});
}

/// Maps a camera start failure onto the message the scanner surface shows.
///
/// Permission denial is called out separately because it is the one failure the
/// user can act on, and `QrScannerPage` keeps the manual-entry fallback visible
/// underneath either way.
@visibleForTesting
String scannerErrorMessage(Object error) {
  const deniedCodes = {
    'CameraAccessDenied',
    'CameraAccessDeniedWithoutPrompt',
    'CameraAccessRestricted',
  };

  if (error is CameraException && deniedCodes.contains(error.code)) {
    return 'Camera permission denied.';
  }
  return 'Unable to start the camera.';
}

/// Scans pairing QR codes with ZXing.
///
/// ZXing is compiled from source by `flutter_zxing`, which keeps every
/// distribution channel - F-Droid included - free of the proprietary MLKit
/// binaries the previous scanner pulled in (SonicRelay#37).
///
/// `ReaderWidget` owns its camera and exposes no start/stop handle, so this
/// controller maps the interface onto mounting and unmounting it: stopping
/// disposes the camera outright rather than leaving it open behind a paused
/// preview.
class ZxingPairingScannerController implements PairingScannerController {
  final ValueNotifier<_ScannerState> _state = ValueNotifier(
    const _ScannerState.stopped(),
  );
  bool _disposed = false;

  @override
  Future<void> start() async => _moveTo(const _ScannerState.running());

  @override
  Future<void> stop() async => _moveTo(const _ScannerState.stopped());

  @override
  Future<void> dispose() async {
    _disposed = true;
    _state.dispose();
  }

  /// Camera setup is asynchronous, so its result can land after the page is
  /// gone. Dropping it then keeps a late callback from writing to a disposed
  /// notifier.
  void _moveTo(_ScannerState next) {
    if (_disposed) return;
    _state.value = next;
  }

  @override
  Widget buildScanner({required ValueChanged<String?> onDetected}) {
    return ValueListenableBuilder<_ScannerState>(
      valueListenable: _state,
      builder: (context, state, _) {
        if (state.error case final message?) {
          return Center(child: Text(message));
        }
        if (!state.isRunning) {
          return const ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(),
          );
        }

        return ReaderWidget(
          codeFormat: Format.qrCode,
          tryHarder: true,
          tryRotate: true,
          tryDownscale: true,
          cropPercent: 1.0,
          showGallery: false,
          showToggleCamera: false,
          onScan: (code) {
            if (code.text case final raw?) onDetected(raw);
          },
          onControllerCreated: (_, error) {
            if (error != null) {
              _moveTo(_ScannerState.failed(scannerErrorMessage(error)));
            }
          },
        );
      },
    );
  }
}

class _ScannerState {
  const _ScannerState.running() : isRunning = true, error = null;
  const _ScannerState.stopped() : isRunning = false, error = null;
  const _ScannerState.failed(this.error) : isRunning = false;

  final bool isRunning;
  final String? error;
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({
    required this.onAccepted,
    this.onManualFallback,
    this.scannerController,
    super.key,
  });

  final PairingPayloadCallback onAccepted;
  final VoidCallback? onManualFallback;
  final PairingScannerController? scannerController;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage>
    with WidgetsBindingObserver {
  late final PairingScannerController _controller;
  bool _accepted = false;
  String? _lastRejectedRaw;

  @override
  void initState() {
    super.initState();
    _controller = widget.scannerController ?? ZxingPairingScannerController();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startScanner());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Once a QR frame has been accepted the page is on its way out; leave the
    // scanner alone so a background/foreground cycle during navigation can't
    // race a stray restart back in.
    if (_accepted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startScanner());
      case AppLifecycleState.inactive:
        // Android reports `inactive` for transient system UI that overlays the
        // app without backgrounding it - most notably the camera permission
        // prompt shown the first time this page opens. Tearing the scanner
        // down here raced camera setup against that prompt: dismissing the
        // dialog could leave `CameraController.initialize()` disposed mid-flight,
        // so the widget never started its image stream and no QR was ever
        // detected. Only stop for lifecycle states that mean the app is
        // actually no longer visible.
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_controller.stop());
    }
  }

  Future<void> _startScanner() async {
    try {
      await _controller.start();
    } catch (_) {
      // The scanner widget renders its permission/start error state. Pairing
      // remains available through the manual fallback below.
    }
  }

  Future<void> _handleDetection(String? raw) async {
    if (_accepted || raw == null) return;
    try {
      PairingChallengePayload.parse(raw);
    } on FormatException {
      // The camera keeps streaming frames of the same code while it's in
      // view, so only surface the error once per distinct rejected payload
      // rather than re-showing a SnackBar on every scan tick.
      if (raw != _lastRejectedRaw) {
        _lastRejectedRaw = raw;
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('That QR code is not a valid pairing code.'),
              ),
            );
        }
      }
      return;
    }

    await _controller.stop();
    final paired = await widget.onAccepted(raw);
    if (!mounted) return;
    if (paired) {
      _accepted = true;
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Unable to pair this device.')),
      );
    await _controller.start();
  }

  void _manualFallback() {
    final callback = widget.onManualFallback;
    if (callback != null) {
      callback();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing QR')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _controller.buildScanner(onDetected: _handleDetection),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _manualFallback,
                  child: const Text('Enter manually'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
