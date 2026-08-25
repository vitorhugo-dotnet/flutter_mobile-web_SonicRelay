import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../diagnostics/sonic_log.dart';
import 'rtc_ice_server_config.dart';

/// Domain-neutral session description (offer/answer) used across the app so
/// higher layers never depend directly on `flutter_webrtc` types.
class RtcSessionDescription {
  const RtcSessionDescription({required this.sdp, required this.type});

  /// Parses a `webrtc.offer`/`webrtc.answer` signaling payload. Tolerates both
  /// a flat `{sdp, type}` shape and a nested `{sdp: {sdp, type}}` shape.
  factory RtcSessionDescription.fromSignalingPayload(
    Map<String, Object?> payload,
  ) {
    final nested = payload['sdp'];
    if (nested is Map) {
      final map = Map<String, Object?>.from(nested);
      return RtcSessionDescription(
        sdp: map['sdp'] as String? ?? '',
        type: map['type'] as String? ?? 'offer',
      );
    }
    return RtcSessionDescription(
      sdp: nested as String? ?? '',
      type: payload['type'] as String? ?? 'offer',
    );
  }

  final String sdp;
  final String type;

  Map<String, Object?> toSignalingPayload() => {'sdp': sdp, 'type': type};
}

/// Domain-neutral ICE candidate.
class RtcIceCandidate {
  const RtcIceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// Parses a `webrtc.ice_candidate` signaling payload. Tolerates both a flat
  /// shape and a nested `{candidate: {...}}` shape.
  factory RtcIceCandidate.fromSignalingPayload(Map<String, Object?> payload) {
    final source = payload['candidate'] is Map
        ? Map<String, Object?>.from(payload['candidate'] as Map)
        : payload;
    final line = source['sdpMLineIndex'];
    return RtcIceCandidate(
      candidate: source['candidate'] as String? ?? '',
      sdpMid: source['sdpMid'] as String?,
      sdpMLineIndex: line is int ? line : (line as num?)?.toInt(),
    );
  }

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  /// The `sdpMid` value that is safe to hand to the native WebRTC layer.
  ///
  /// Android's libwebrtc aborts the whole process (SIGABRT in `jvm.cc`, via
  /// `JniHelper.getStringBytes` on a null String) when `addIceCandidate`
  /// receives a null `sdpMid`. Publishers legitimately send candidates without
  /// a mid (routed purely by [sdpMLineIndex]), so callers crossing the native
  /// boundary must use this coalesced value; libwebrtc then routes by line
  /// index.
  String get nativeSafeSdpMid => sdpMid ?? '';

  Map<String, Object?> toSignalingPayload() => {
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
  };
}

/// High-level peer-connection lifecycle states, decoupled from
/// `RTCPeerConnectionState`.
enum RtcConnectionState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

/// How media is reaching the viewer, derived from the selected ICE candidate
/// pair.
enum RtcTransportMode {
  /// Peer-to-peer (host/srflx/prflx candidates).
  direct,

  /// Relayed through a TURN server.
  relay,

  /// Not yet known (no selected pair / stats unavailable).
  unknown,
}

/// Cumulative receiver-side counters from the audio `inbound-rtp` stats report
/// (windows_SonicRelay issue #31 companion). Values are cumulative since the
/// connection started; interval metrics (packet-loss %, concealment %, average
/// jitter-buffer delay) are derived by the listener layer from successive
/// polls. Any counter the platform does not report is null.
class RtcInboundAudioStats {
  const RtcInboundAudioStats({
    this.packetsReceived,
    this.packetsLost,
    this.packetsDiscarded,
    this.fecPacketsReceived,
    this.concealedSamples,
    this.concealmentEvents,
    this.totalSamplesReceived,
    this.jitterBufferDelaySeconds,
    this.jitterBufferTargetDelaySeconds,
    this.jitterBufferEmittedCount,
  });

  final int? packetsReceived;
  final int? packetsLost;
  final int? packetsDiscarded;
  final int? fecPacketsReceived;
  final int? concealedSamples;
  final int? concealmentEvents;
  final int? totalSamplesReceived;

  /// Sum of time each emitted sample spent in the jitter buffer, in seconds.
  final double? jitterBufferDelaySeconds;

  /// Sum of the buffer's target delay at each emit, in seconds.
  final double? jitterBufferTargetDelaySeconds;

  final int? jitterBufferEmittedCount;
}

/// Formats the selected ICE candidate pair as `local/remote protocol`, or null
/// when neither side reported a candidate type. A side that reported no type
/// shows as `?` rather than dropping out, so the pair stays readable as a pair.
String? describeCandidatePair({
  required Object? localType,
  required Object? remoteType,
  required Object? protocol,
}) {
  if (localType == null && remoteType == null) return null;
  final pair = '${localType ?? '?'}/${remoteType ?? '?'}';
  return protocol == null ? pair : '$pair $protocol';
}

/// Coarse, display-only connection statistics polled from the peer connection.
/// Carries only numbers and a transport label — never SDP or candidate bodies.
class RtcConnectionStats {
  const RtcConnectionStats({
    this.rttMs,
    this.jitterMs,
    this.transport = RtcTransportMode.unknown,
    this.candidatePair,
    this.inboundAudio,
  });

  /// Estimated round-trip time in milliseconds, when available.
  final double? rttMs;

  /// Inbound audio jitter in milliseconds, when available.
  final double? jitterMs;

  final RtcTransportMode transport;

  /// The winning ICE candidate pair as `local/remote` candidate types plus the
  /// protocol, e.g. `relay/srflx udp`.
  ///
  /// [transport] only says relay-or-not, which is not enough to explain *why*
  /// a session relayed: `srflx/relay` (one side's direct path never worked) and
  /// `relay/relay` (neither did) point at different networks. Candidate types
  /// and protocol are metadata — no addresses, no SDP — so they are safe to
  /// keep in an exportable log.
  final String? candidatePair;

  /// Cumulative inbound audio counters, when the platform reports them.
  final RtcInboundAudioStats? inboundAudio;
}

/// A handle over a remote media stream. The viewer only ever consumes audio.
abstract class RtcMediaStream {
  String get id;

  Future<void> setAudioEnabled(bool enabled);
}

/// A local microphone capture track, used only in `duplex` sessions.
///
/// Kept separate from [RtcMediaStream] on purpose: a remote stream is something
/// the viewer consumes, while this is a capture device the app holds open, and
/// the two have opposite lifetimes — the microphone must be released the moment
/// it stops being sent, not when the peer connection happens to go away.
abstract class RtcLocalAudioTrack {
  String get id;

  /// Mutes/unmutes at the track level. A disabled track keeps the transceiver
  /// and the negotiated m-line in place and transmits silence, so mute and
  /// unmute never require renegotiation.
  Future<void> setEnabled(bool enabled);

  /// Stops capture and releases the microphone.
  Future<void> dispose();
}

/// Opens the microphone for duplex sessions. Abstracted so the duplex logic is
/// unit-testable without a real capture device, and so the receiver never
/// depends on `flutter_webrtc` directly.
abstract class RtcMicrophoneSource {
  /// Requests microphone access and starts capture. Returns `null` when the
  /// user denies permission or no capture device is available — a refusal is a
  /// normal outcome here, not an error to propagate.
  Future<RtcLocalAudioTrack?> open();
}

/// The subset of a WebRTC peer connection the receiver needs. Abstracted so
/// the receiver logic is unit-testable with a plain fake.
abstract class RtcPeerConnection {
  Future<void> setRemoteDescription(RtcSessionDescription description);

  /// Attaches [track] as this connection's outgoing audio, so the next answer
  /// negotiates `sendrecv` instead of `recvonly`. Idempotent per track.
  Future<void> attachLocalAudio(RtcLocalAudioTrack track);

  /// Removes the outgoing audio track previously attached with
  /// [attachLocalAudio]. No-op when nothing is attached.
  Future<void> detachLocalAudio();

  Future<RtcSessionDescription> createAnswer();

  Future<void> setLocalDescription(RtcSessionDescription description);

  Future<void> addIceCandidate(RtcIceCandidate candidate);

  /// Polls coarse connection statistics (RTT, jitter, transport mode). Returns
  /// `null` when nothing usable is available.
  Future<RtcConnectionStats?> getStats();

  set onIceCandidate(void Function(RtcIceCandidate candidate)? callback);

  set onRemoteStream(void Function(RtcMediaStream stream)? callback);

  set onConnectionState(void Function(RtcConnectionState state)? callback);

  Future<void> dispose();
}

/// Creates [RtcPeerConnection] instances.
abstract class RtcPeerConnectionFactory {
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers);
}

/// Production factory backed by `flutter_webrtc`.
class FlutterWebRtcPeerConnectionFactory implements RtcPeerConnectionFactory {
  const FlutterWebRtcPeerConnectionFactory();

  /// Whether the native WebRTC stack was already initialized with the media
  /// audio configuration. `WebRTC.initialize` only takes effect before the
  /// first peer-connection factory comes up, so it must run exactly once.
  static bool _nativeAudioInitialized = false;

  /// Android audio profile for *concurrent* media playback (issue #19).
  ///
  /// SonicRelay is an audio-only remote viewer, so its audio must mix with
  /// whatever the device is already playing (Spotify, YouTube Music,
  /// podcasts…). The `AndroidAudioConfiguration.media` preset used previously
  /// keeps `manageAudioFocus: true` with `AUDIOFOCUS_GAIN`, which tells
  /// Android to take *continuous, exclusive* focus — other media apps get a
  /// focus-loss and pause (or duck) the moment the relay connects.
  ///
  /// `manageAudioFocus: false` stops flutter_webrtc from requesting (and
  /// abandoning) focus entirely, so connecting/disconnecting never touches
  /// the state of external players. The remaining fields preserve the issue
  /// #14 fix: `MODE_NORMAL` + `USAGE_MEDIA` + `STREAM_MUSIC` keep playback on
  /// the media volume stream at full quality, never call/communication
  /// routing. Exposed (rather than private) so tests can lock its meaning
  /// against dependency bumps.
  static final webrtc.AndroidAudioConfiguration
  concurrentPlaybackAudioConfiguration = webrtc.AndroidAudioConfiguration(
    manageAudioFocus: false,
    androidAudioMode: webrtc.AndroidAudioMode.normal,
    androidAudioStreamType: webrtc.AndroidAudioStreamType.music,
    androidAudioAttributesUsageType:
        webrtc.AndroidAudioAttributesUsageType.media,
    androidAudioAttributesContentType:
        webrtc.AndroidAudioAttributesContentType.music,
  );

  @override
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers) async {
    await _configureMediaPlaybackAudio();
    final connection = await webrtc.createPeerConnection(
      iceServers.toConfiguration(),
    );
    return _FlutterWebRtcPeerConnection(connection);
  }

  /// Forces flutter_webrtc's Android audio session into a *concurrent media
  /// playback* profile before the peer connection (and its audio device) come
  /// up.
  ///
  /// The viewer only ever plays a remote audio track — it is never a two-way
  /// call. Left to its defaults, flutter_webrtc's Android layer puts the whole
  /// device into `MODE_IN_COMMUNICATION` with `USAGE_VOICE_COMMUNICATION` /
  /// `STREAM_VOICE_CALL`. That routes media to the earpiece and drops *every*
  /// app's audio to muffled, low-bitrate "phone call" quality for as long as
  /// the session is up (issue #14). And it must not take audio focus either:
  /// received audio mixes with other apps' media instead of pausing it
  /// (issue #19) — see [concurrentPlaybackAudioConfiguration].
  ///
  /// Two pieces are required, and both matter (issue: audio still played on
  /// the *call* volume stream at low volume with only the Helper call):
  ///
  /// 1. `WebRTC.initialize(androidAudioConfiguration: ...)` — the native
  ///    `JavaAudioDeviceModule` builds its playback `AudioTrack` with the
  ///    audio attributes captured when the factory is first created. Without
  ///    this, the track keeps `USAGE_VOICE_COMMUNICATION` and Android routes
  ///    it through the call volume stream no matter what the `AudioManager`
  ///    mode says. It must run before the first `createPeerConnection`.
  /// 2. `Helper.setAndroidAudioConfiguration(...)` — pins the session's
  ///    `AudioManager` to `MODE_NORMAL` + `USAGE_MEDIA` + `STREAM_MUSIC`, so
  ///    global Android audio keeps full quality (issue #14). With
  ///    `manageAudioFocus: false` no focus is requested here and none has to
  ///    be abandoned on teardown, so connecting or disconnecting never
  ///    pauses, resumes, or ducks another app's playback (issue #19).
  ///
  /// Both calls are Android-only no-ops elsewhere, so this is safe to call
  /// unconditionally.
  Future<void> _configureMediaPlaybackAudio() async {
    try {
      if (!_nativeAudioInitialized && webrtc.WebRTC.platformIsAndroid) {
        sonicLog(
          'Audio',
          'initializing native WebRTC with media audio attributes '
              '(USAGE_MEDIA / CONTENT_TYPE_MUSIC, no audio focus) '
              'before first factory use',
        );
        await webrtc.WebRTC.initialize(
          options: {
            'androidAudioConfiguration':
                concurrentPlaybackAudioConfiguration.toMap(),
          },
        );
        _nativeAudioInitialized = true;
      }
      sonicLog(
        'Audio',
        'applying Android concurrent media playback profile '
            '(MODE_NORMAL / USAGE_MEDIA / STREAM_MUSIC, mix with other apps) '
            'before negotiation',
      );
      await webrtc.Helper.setAndroidAudioConfiguration(
        concurrentPlaybackAudioConfiguration,
      );
      if (webrtc.WebRTC.platformIsIOS) {
        // Playback category (not the default play-and-record/voice-chat one)
        // is what lets the AVAudioSession keep running when the phone locks or
        // the app is backgrounded — paired with the UIBackgroundModes "audio"
        // entry in Info.plist. mixWithOthers matches the Android profile:
        // never pause another app's media.
        sonicLog(
          'Audio',
          'applying iOS playback audio session '
              '(category=playback, mixWithOthers) before negotiation',
        );
        await webrtc.Helper.setAppleAudioConfiguration(
          webrtc.AppleAudioConfiguration(
            appleAudioCategory: webrtc.AppleAudioCategory.playback,
            appleAudioCategoryOptions: {
              webrtc.AppleAudioCategoryOption.mixWithOthers,
            },
            appleAudioMode: webrtc.AppleAudioMode.default_,
          ),
        );
      }
    } catch (error) {
      // Never let audio-routing configuration block a connection.
      sonicLog('Audio', 'failed to apply media audio profile: $error');
    }
  }
}

/// Production [RtcMicrophoneSource] backed by `getUserMedia`.
///
/// Opening the microphone also switches the platform audio session from the
/// media-playback profile to a communication one, and switches it back on
/// release. That is a deliberate trade against issue #14's fix: `MODE_NORMAL` /
/// `USAGE_MEDIA` is what keeps one-way listening at full media quality, but it
/// is also what stops the platform from engaging acoustic echo cancellation, so
/// a two-way call on a speakerphone feeds the remote peer its own voice back.
/// The communication profile is therefore applied only while a duplex call
/// actually holds the microphone, and one-way sessions never see it.
class FlutterWebRtcMicrophoneSource implements RtcMicrophoneSource {
  const FlutterWebRtcMicrophoneSource();

  /// Android profile while the microphone is open: `MODE_IN_COMMUNICATION` plus
  /// voice-communication attributes, which is what lets the platform apply
  /// hardware echo cancellation and noise suppression to the capture path.
  static final webrtc.AndroidAudioConfiguration duplexAudioConfiguration =
      webrtc.AndroidAudioConfiguration(
        manageAudioFocus: false,
        androidAudioMode: webrtc.AndroidAudioMode.inCommunication,
        androidAudioStreamType: webrtc.AndroidAudioStreamType.voiceCall,
        androidAudioAttributesUsageType:
            webrtc.AndroidAudioAttributesUsageType.voiceCommunication,
        androidAudioAttributesContentType:
            webrtc.AndroidAudioAttributesContentType.speech,
      );

  @override
  Future<RtcLocalAudioTrack?> open() async {
    try {
      await _applyDuplexAudioProfile();
      final stream = await webrtc.navigator.mediaDevices.getUserMedia({
        'audio': {
          // Software fallbacks for the platforms that do not provide the
          // hardware equivalents; without them a speakerphone call echoes.
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) {
        await stream.dispose();
        await _restorePlaybackAudioProfile();
        return null;
      }
      sonicLog('Audio', 'microphone opened for duplex session');
      return _FlutterWebRtcLocalAudioTrack(stream, tracks.first);
    } catch (error) {
      // A denied permission and a missing capture device both land here, and
      // neither is an error the caller can act on beyond not sending audio.
      sonicLog('Audio', 'microphone unavailable: $error');
      await _restorePlaybackAudioProfile();
      return null;
    }
  }

  static Future<void> _applyDuplexAudioProfile() async {
    try {
      if (webrtc.WebRTC.platformIsAndroid) {
        await webrtc.Helper.setAndroidAudioConfiguration(
          duplexAudioConfiguration,
        );
      }
      if (webrtc.WebRTC.platformIsIOS) {
        // playAndRecord + voiceChat is the only combination that opens the
        // capture path at all on iOS; `playback` (the one-way profile) has no
        // input route. defaultToSpeaker keeps a hands-free call on the speaker
        // instead of the earpiece.
        await webrtc.Helper.setAppleAudioConfiguration(
          webrtc.AppleAudioConfiguration(
            appleAudioCategory: webrtc.AppleAudioCategory.playAndRecord,
            appleAudioCategoryOptions: {
              webrtc.AppleAudioCategoryOption.mixWithOthers,
              webrtc.AppleAudioCategoryOption.defaultToSpeaker,
              webrtc.AppleAudioCategoryOption.allowBluetooth,
            },
            appleAudioMode: webrtc.AppleAudioMode.voiceChat,
          ),
        );
      }
    } catch (error) {
      sonicLog('Audio', 'failed to apply duplex audio profile: $error');
    }
  }

  static Future<void> _restorePlaybackAudioProfile() async {
    try {
      if (webrtc.WebRTC.platformIsAndroid) {
        await webrtc.Helper.setAndroidAudioConfiguration(
          FlutterWebRtcPeerConnectionFactory
              .concurrentPlaybackAudioConfiguration,
        );
      }
      if (webrtc.WebRTC.platformIsIOS) {
        await webrtc.Helper.setAppleAudioConfiguration(
          webrtc.AppleAudioConfiguration(
            appleAudioCategory: webrtc.AppleAudioCategory.playback,
            appleAudioCategoryOptions: {
              webrtc.AppleAudioCategoryOption.mixWithOthers,
            },
            appleAudioMode: webrtc.AppleAudioMode.default_,
          ),
        );
      }
    } catch (error) {
      sonicLog('Audio', 'failed to restore playback audio profile: $error');
    }
  }
}

class _FlutterWebRtcLocalAudioTrack implements RtcLocalAudioTrack {
  _FlutterWebRtcLocalAudioTrack(this.stream, this.track);

  /// Kept so the microphone itself can be released; `addTrack` also needs the
  /// owning stream so the remote peer sees a stream id rather than a bare track.
  final webrtc.MediaStream stream;
  final webrtc.MediaStreamTrack track;
  bool _disposed = false;

  @override
  String get id => track.id ?? stream.id;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (_disposed) return;
    track.enabled = enabled;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await track.stop();
    } catch (_) {
      // A track the platform already tore down must not fail teardown.
    }
    try {
      await stream.dispose();
    } catch (_) {
      // Same.
    }
    sonicLog('Audio', 'microphone released');
    await FlutterWebRtcMicrophoneSource._restorePlaybackAudioProfile();
  }
}

class _FlutterWebRtcMediaStream implements RtcMediaStream {
  _FlutterWebRtcMediaStream(this._stream);

  final webrtc.MediaStream _stream;

  @override
  String get id => _stream.id;

  @override
  Future<void> setAudioEnabled(bool enabled) async {
    for (final track in _stream.getAudioTracks()) {
      track.enabled = enabled;
    }
  }
}

class _FlutterWebRtcPeerConnection implements RtcPeerConnection {
  _FlutterWebRtcPeerConnection(this._connection) {
    _connection.onIceCandidate = (candidate) {
      final callback = _onIceCandidate;
      if (callback == null) return;
      callback(
        RtcIceCandidate(
          candidate: candidate.candidate ?? '',
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    _connection.onTrack = (event) {
      if (event.track.kind != 'audio') return;
      if (event.streams.isEmpty) return;
      _emitRemoteStream(event.streams.first);
    };
    _connection.onConnectionState = (state) {
      _onConnectionState?.call(_mapConnectionState(state));
    };
  }

  final webrtc.RTCPeerConnection _connection;

  void Function(RtcIceCandidate candidate)? _onIceCandidate;
  void Function(RtcMediaStream stream)? _onRemoteStream;
  void Function(RtcConnectionState state)? _onConnectionState;
  String? _lastStreamId;
  webrtc.RTCRtpSender? _localAudioSender;

  void _emitRemoteStream(webrtc.MediaStream stream) {
    if (stream.id == _lastStreamId) return;
    _lastStreamId = stream.id;
    _onRemoteStream?.call(_FlutterWebRtcMediaStream(stream));
  }

  @override
  set onIceCandidate(void Function(RtcIceCandidate candidate)? callback) =>
      _onIceCandidate = callback;

  @override
  set onRemoteStream(void Function(RtcMediaStream stream)? callback) =>
      _onRemoteStream = callback;

  @override
  set onConnectionState(void Function(RtcConnectionState state)? callback) =>
      _onConnectionState = callback;

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) {
    return _connection.setRemoteDescription(
      webrtc.RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> attachLocalAudio(RtcLocalAudioTrack track) async {
    if (track is! _FlutterWebRtcLocalAudioTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'Only tracks produced by FlutterWebRtcMicrophoneSource can be attached '
            'to a flutter_webrtc peer connection.',
      );
    }
    if (_localAudioSender != null) return;
    _localAudioSender = await _connection.addTrack(track.track, track.stream);
  }

  @override
  Future<void> detachLocalAudio() async {
    final sender = _localAudioSender;
    _localAudioSender = null;
    if (sender == null) return;
    try {
      await _connection.removeTrack(sender);
    } catch (_) {
      // Removing a sender from a connection that is already closing is not a
      // failure the caller can do anything about.
    }
  }

  @override
  Future<RtcSessionDescription> createAnswer() async {
    final answer = await _connection.createAnswer({});
    return RtcSessionDescription(
      sdp: answer.sdp ?? '',
      type: answer.type ?? 'answer',
    );
  }

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) {
    return _connection.setLocalDescription(
      webrtc.RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> addIceCandidate(RtcIceCandidate candidate) {
    return _connection.addCandidate(
      webrtc.RTCIceCandidate(
        candidate.candidate,
        candidate.nativeSafeSdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  @override
  Future<RtcConnectionStats?> getStats() async {
    try {
      final reports = await _connection.getStats();
      Map<Object?, Object?>? selectedPair;
      final candidates = <String, Map<Object?, Object?>>{};
      double? jitterMs;
      RtcInboundAudioStats? inboundAudio;

      for (final report in reports) {
        final values = Map<Object?, Object?>.from(report.values);
        switch (report.type) {
          case 'candidate-pair':
            final nominated = values['nominated'] == true;
            final succeeded = values['state'] == 'succeeded';
            if (nominated || (succeeded && selectedPair == null)) {
              selectedPair = values;
            }
          case 'local-candidate':
          case 'remote-candidate':
            candidates[report.id] = values;
          case 'inbound-rtp':
            final isAudio =
                values['kind'] == 'audio' || values['mediaType'] == 'audio';
            if (!isAudio) break;
            final jitter = values['jitter'];
            if (jitter is num) {
              jitterMs = jitter.toDouble() * 1000;
            }
            inboundAudio = RtcInboundAudioStats(
              packetsReceived: _asInt(values['packetsReceived']),
              packetsLost: _asInt(values['packetsLost']),
              packetsDiscarded: _asInt(values['packetsDiscarded']),
              fecPacketsReceived: _asInt(values['fecPacketsReceived']),
              concealedSamples: _asInt(values['concealedSamples']),
              concealmentEvents: _asInt(values['concealmentEvents']),
              totalSamplesReceived: _asInt(values['totalSamplesReceived']),
              jitterBufferDelaySeconds: _asDouble(
                values['jitterBufferDelay'],
              ),
              jitterBufferTargetDelaySeconds: _asDouble(
                values['jitterBufferTargetDelay'],
              ),
              jitterBufferEmittedCount: _asInt(
                values['jitterBufferEmittedCount'],
              ),
            );
        }
      }

      double? rttMs;
      var transport = RtcTransportMode.unknown;
      String? candidatePair;
      if (selectedPair != null) {
        final rtt =
            selectedPair['currentRoundTripTime'] ??
            selectedPair['roundTripTime'];
        if (rtt is num) rttMs = rtt.toDouble() * 1000;

        final local = candidates[selectedPair['localCandidateId']];
        final remote = candidates[selectedPair['remoteCandidateId']];
        final localType = local?['candidateType'];
        final remoteType = remote?['candidateType'];
        if (localType == 'relay' || remoteType == 'relay') {
          transport = RtcTransportMode.relay;
        } else if (localType != null || remoteType != null) {
          transport = RtcTransportMode.direct;
        }
        candidatePair = describeCandidatePair(
          localType: localType,
          remoteType: remoteType,
          protocol: local?['protocol'] ?? remote?['protocol'],
        );
      }

      if (rttMs == null &&
          jitterMs == null &&
          inboundAudio == null &&
          transport == RtcTransportMode.unknown) {
        return null;
      }
      return RtcConnectionStats(
        rttMs: rttMs,
        jitterMs: jitterMs,
        transport: transport,
        candidatePair: candidatePair,
        inboundAudio: inboundAudio,
      );
    } catch (_) {
      return null;
    }
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  @override
  Future<void> dispose() async {
    await _connection.close();
    await _connection.dispose();
  }

  RtcConnectionState _mapConnectionState(
    webrtc.RTCPeerConnectionState state,
  ) => switch (state) {
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateNew =>
      RtcConnectionState.idle,
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
      RtcConnectionState.connecting,
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
      RtcConnectionState.connected,
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
      RtcConnectionState.disconnected,
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
      RtcConnectionState.failed,
    webrtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
      RtcConnectionState.closed,
  };
}
