@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/sonic_log.dart';
import 'package:sonic_relay/core/webrtc/rtc_ice_server_config.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';

void main() {
  test(
    'creating a Web peer connection skips native audio configuration',
    () async {
      final logged = <String>[];
      setSonicLogSink((tag, message) => logged.add('$tag: $message'));
      addTearDown(() => setSonicLogSink(null));

      final connection = await const FlutterWebRtcPeerConnectionFactory()
          .create(const RtcIceServerConfig([]));
      addTearDown(connection.dispose);

      expect(
        logged,
        isNot(contains(contains('failed to apply media audio profile'))),
      );
    },
  );
}
