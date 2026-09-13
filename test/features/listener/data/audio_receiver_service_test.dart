import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';
import 'package:sonic_relay/features/listener/data/audio_receiver_service.dart';

class FakeRtcMediaStream implements RtcMediaStream {
  FakeRtcMediaStream(this.id);

  @override
  final String id;

  bool? audioEnabled;
  bool outputAttached = false;
  Completer<void>? attachGate;
  Object? attachError;
  Object? detachError;

  @override
  Future<void> attachAudioOutput() async {
    await attachGate?.future;
    if (attachError case final error?) throw error;
    outputAttached = true;
  }

  @override
  Future<void> detachAudioOutput() async {
    if (detachError case final error?) throw error;
    outputAttached = false;
  }

  @override
  Future<void> setAudioEnabled(bool enabled) async => audioEnabled = enabled;
}

void main() {
  late WebRtcAudioReceiverService service;

  setUp(() => service = WebRtcAudioReceiverService());

  test(
    'play enables the stream audio, attaches output, and marks playing',
    () async {
      final stream = FakeRtcMediaStream('stream-1');

      await service.play(stream);

      expect(stream.audioEnabled, isTrue);
      expect(stream.outputAttached, isTrue);
      expect(service.isPlaying, isTrue);
    },
  );

  test('stop disables the current stream and clears playing', () async {
    final stream = FakeRtcMediaStream('stream-1');
    await service.play(stream);

    await service.stop();

    expect(stream.audioEnabled, isFalse);
    expect(stream.outputAttached, isFalse);
    expect(service.isPlaying, isFalse);
  });

  test('replacing a stream disables the previous one', () async {
    final first = FakeRtcMediaStream('stream-1');
    final second = FakeRtcMediaStream('stream-2');

    await service.play(first);
    await service.play(second);

    expect(first.audioEnabled, isFalse);
    expect(first.outputAttached, isFalse);
    expect(second.audioEnabled, isTrue);
    expect(second.outputAttached, isTrue);
    expect(service.isPlaying, isTrue);
  });

  test(
    'replacing a different stream with the same id releases the old output',
    () async {
      final first = FakeRtcMediaStream('reused-stream-id');
      final second = FakeRtcMediaStream('reused-stream-id');

      await service.play(first);
      await service.play(second);

      expect(first.audioEnabled, isFalse);
      expect(first.outputAttached, isFalse);
      expect(second.audioEnabled, isTrue);
      expect(second.outputAttached, isTrue);
    },
  );

  test('stop wins when called while playback is still attaching', () async {
    final stream = FakeRtcMediaStream('stream-1');
    final gate = stream.attachGate = Completer<void>();

    final play = service.play(stream);
    await Future<void>.delayed(Duration.zero);
    final stop = service.stop();
    gate.complete();
    await Future.wait([play, stop]);

    expect(stream.audioEnabled, isFalse);
    expect(stream.outputAttached, isFalse);
    expect(service.isPlaying, isFalse);
  });

  test(
    'attach failure rolls back the enabled track and playing state',
    () async {
      final stream = FakeRtcMediaStream('stream-1')
        ..attachError = StateError('attach failed');

      await expectLater(service.play(stream), throwsStateError);

      expect(stream.audioEnabled, isFalse);
      expect(stream.outputAttached, isFalse);
      expect(service.isPlaying, isFalse);
    },
  );

  test('detach failure cannot abort stop or leave the track enabled', () async {
    final stream = FakeRtcMediaStream('stream-1');
    await service.play(stream);
    stream.detachError = StateError('detach failed');

    await expectLater(service.stop(), completes);

    expect(stream.audioEnabled, isFalse);
    expect(service.isPlaying, isFalse);
  });
}
