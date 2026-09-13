import '../../../core/diagnostics/sonic_log.dart';
import '../../../core/webrtc/rtc_peer_connection_factory.dart';

/// Plays the remote audio track received over WebRTC. The viewer is
/// receive-only: it never captures a microphone or adds a local track.
abstract class AudioReceiverService {
  /// Starts playing [stream]'s audio. Replacing a currently playing stream
  /// stops the previous one first.
  Future<void> play(RtcMediaStream stream);

  /// Stops playback and disables the current stream's audio.
  Future<void> stop();

  bool get isPlaying;
}

/// Default implementation backed by an [RtcMediaStream].
///
/// On native platforms flutter_webrtc routes a received, enabled remote audio
/// track to the output device automatically, so this deliberately only manages
/// the track's enabled state and the playing flag for the MVP.
class WebRtcAudioReceiverService implements AudioReceiverService {
  RtcMediaStream? _current;
  bool _isPlaying = false;
  Future<void> _operationTail = Future<void>.value();

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> play(RtcMediaStream stream) =>
      _serialize(() => _playNow(stream));

  Future<void> _playNow(RtcMediaStream stream) async {
    if (_current != null && !identical(_current, stream)) {
      await _stopStream(_current!);
    }
    _current = stream;
    _isPlaying = false;
    try {
      await stream.setAudioEnabled(true);
      await stream.attachAudioOutput();
      _isPlaying = true;
    } catch (error, stack) {
      await _stopStream(stream);
      if (identical(_current, stream)) _current = null;
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> stop() => _serialize(_stopNow);

  Future<void> _stopNow() async {
    final current = _current;
    _current = null;
    _isPlaying = false;
    if (current != null) {
      await _stopStream(current);
    }
  }

  Future<void> _stopStream(RtcMediaStream stream) async {
    try {
      await stream.detachAudioOutput();
    } catch (error) {
      sonicLog('Audio', 'failed to detach audio output: $error');
    }
    try {
      await stream.setAudioEnabled(false);
    } catch (error) {
      sonicLog('Audio', 'failed to disable remote audio track: $error');
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}
