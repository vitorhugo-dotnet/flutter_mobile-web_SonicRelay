# Flutter architecture

The viewer follows Feature Driven Development (FDD): reusable infrastructure in
`core`, composition in `app`, and user-facing capabilities in `features`.

## Layers

```text
lib/
  app/              bootstrap, device-first router, theme, env, providers
  core/             Dio, secure storage, WebSocket, WebRTC, widgets
  features/
    device_identity/ bootstrap, secure credential, token session
    pairing/         QR/manual pairing, list, revoke
    sessions/        join with a separate session code
    signaling/       DeviceBearer WebSocket + typed envelope
    listener/        receive-only WebRTC, audio, listener UI
    settings/        server, playback, pairing and identity reset
  main.dart
```

## Device-first composition

- Riverpod owns one shared `DeviceIdentitySession`. The raw identity Dio client
  calls `/api/devices/bootstrap` and `/api/devices/token`; the authenticated Dio
  client, pairing repository, sessions repository, and signaling client consume
  the resulting `DeviceBearer` token.
- `DeviceReadinessNotifier` exposes `restoring`, `deviceSetup`,
  `pairingRequired`, and `ready`. Startup finishes credential bootstrap and the
  active-pairing check before session screens are reachable.
- go_router exposes `/loading`, `/device-setup`, `/pair`, `/join`,
  `/session/waiting`, `/listener`, and `/settings`.
- `AuthInterceptor` renews once after `401`. GET/HEAD and explicitly replay-safe
  requests may be replayed once; unsafe mutations are not repeated. A later
  manual action uses the refreshed bearer.
- A token-exchange `401` clears the secure credential and publishes permanent
  invalidation. Readiness immediately enters `deviceSetup`, including while the
  listener is active.

The stored credential contains a server-issued id and secret and is protected by
`flutter_secure_storage`. Short-lived access tokens remain in memory. Neither is
written to SharedPreferences, notifications, intents, or logs.

## Pairing and session codes

Pairing and session join are intentionally distinct:

- Pairing accepts the exact QR JSON `{challengeId, code}` or the same two manual
  fields. The camera is opened only by the dedicated scanner screen.
- Session join accepts only `{"code":"ABC123"}`. Device identity comes from
  `Authorization: Bearer <device_access_token>`; the body has no device
  identifier.
- An active pairing is required for a new join. Revoking pairing leaves a stream
  that is already active alone.

## Signaling / WebRTC seam

- `core/websocket/WebSocketClient` is a reconnecting JSON transport with an
  injected error-classification policy.
- `features/signaling/SignalingClient` connects with only `sessionId` in the
  query and marks `DeviceIdentitySessionInvalidatedException` permanent, so a
  revoked credential cannot create a reconnect loop.
- Backoff alone is not enough on a phone, so two outside signals short-circuit
  it via `WebSocketClient.retryNow`: a transport handover reported by
  `core/network/NetworkMonitor`, and the app returning to the foreground. Both
  reset the delay to its start — a wait chosen while the device had no route at
  all says nothing about a device that now has one.
- `features/listener/data/WebRtcReceiverService` is signaling-agnostic and owns
  the receive-only peer connection. It answers; it never offers. An offer the
  publisher marks `renegotiation: true` is applied to the existing connection
  instead of rebuilding it, so a peer starting or stopping its audio never costs
  the stream.
- `features/listener/presentation/ListenerViewModel` bridges signaling messages,
  outbound answers/candidates, connection state, and coarse statistics.

SDP and ICE candidate bodies are never logged. Flutter never handles video and
never captures anything — not a microphone, and not the phone's own playback.

That last part is the reason a `duplex` session reaches this app as a one-way
stream. SonicRelay shares system/app audio, and capturing Android's playback
would need `MediaProjection` + `AudioPlaybackCaptureConfiguration` fed into a
custom WebRTC audio device module; `flutter_webrtc`'s only audio input is the
microphone (`JavaAudioDeviceModule`), and its `getDisplayMedia` yields video
only. So the viewer takes part in a two-way session as a listener, declares
`canSendAudio: false` so the peer does not wait on it, and says so on screen.

What it does honour is the permission model: the backend's
`participant.capabilities` broadcasts are the only source of truth for who may
publish, and since the API never parses SDP, refusing audio from an unauthorized
peer is this client's responsibility.

## Related docs

- [integration-flow.md](integration-flow.md) — Phase 3 end-to-end contract.
- [troubleshooting.md](troubleshooting.md) — device identity, pairing, and media
  failure modes.
