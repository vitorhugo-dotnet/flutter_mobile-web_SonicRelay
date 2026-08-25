# Integration flow

This is the Phase 3 end-to-end contract between the Flutter viewer, the
SonicRelay backend control plane, and the Windows publisher, verified on
2026-07-29.

## Configuration

| Dart define | Default | Purpose |
| --- | --- | --- |
| `SONIC_RELAY_API_URL` | `http://localhost:5000` | HTTP API base URL |
| `SONIC_RELAY_WS_URL` | `ws://localhost:5000` | WebSocket base URL |

The join response does not carry a signaling URL. Flutter builds
`<SONIC_RELAY_WS_URL>/ws/signaling` and appends only `sessionId`. Production
deployments use `https://` and `wss://`.

## End-to-end sequence

1. **Prepare device identity.** If secure storage has no credential, Flutter
   calls `POST /api/devices/bootstrap` with the viewer name, device type
   `flutter_viewer`, and platform. It stores the returned device id, credential
   secret, version, type, and platform atomically in `flutter_secure_storage`.
2. **Obtain a device token.** Flutter exchanges the credential through
   `POST /api/devices/token`. A single shared `DeviceIdentitySession` caches the
   short-lived token in memory and supplies it to HTTP and signaling as:
   `Authorization: Bearer <device_access_token>`.
3. **Create a pairing challenge.** SonicRelay Windows displays both manual
   pairing fields and a QR payload containing exactly `challengeId` and `code`.
   Flutter requests camera access only after the user opens the QR scanner.
4. **Pair the viewer.** Flutter calls `POST /api/pairings/complete` with the QR
   or manual challenge. `GET /api/devices/{deviceId}/pairings` discovers active
   pairings. The router keeps an unpaired viewer on `/pair`.
5. **Create a stream session.** The paired Windows publisher creates a session
   and displays a separate temporary session code.
6. **Join the session.** Flutter calls `POST /api/sessions/join` with only:

   ```json
   {
     "code": "ABC123"
   }
   ```

   The backend resolves the authenticated viewer device from `DeviceBearer`
   and requires an active pairing with the publisher. The response is the full
   session record; Flutter reads `id` as the session id.
7. **Open signaling.** Flutter connects with only the session query parameter:

   ```text
   GET /ws/signaling?sessionId={sessionId}
   Authorization: Bearer <device_access_token>
   ```

8. **Negotiate WebRTC.** The publisher sends `publisher.ready`; Flutter replies
   `viewer.ready` to that participant. Offer, answer, and ICE candidates then
   use the typed signaling envelope. In a `duplex` session Flutter also announces
   `participant.capabilities` (`canSendAudio: false` — it has nothing to
   capture) and applies an offer marked `renegotiation: true` to the existing
   peer connection instead of rebuilding it.
9. **Play audio.** Flutter receives one remote audio track. The backend routes
   signaling only; media is peer-to-peer or relayed through TURN.
10. **Leave or revoke.** Explicit leave and `session.ended` tear down signaling,
    WebRTC, and audio. Pairing revocation blocks future joins but does not end an
    already active session.

## HTTP contracts

| Method | Route | Request | Result |
| --- | --- | --- | --- |
| `POST` | `/api/devices/bootstrap` | `{name, deviceType, platform}` | long-lived device credential |
| `POST` | `/api/devices/token` | `{deviceId, credentialSecret}` | short-lived token and scopes |
| `POST` | `/api/pairings/complete` | `{challengeId, code}` | active pairing |
| `GET` | `/api/devices/{deviceId}/pairings` | — | pairing list |
| `DELETE` | `/api/pairings/{pairingId}` | — | `204` |
| `POST` | `/api/sessions/join` | `{"code":"ABC123"}` | session record `{id, status, code, …}` |

On an API `401`, `AuthInterceptor` forces one credential exchange. Safe GET/HEAD
requests are replayed once with the new `DeviceBearer` token. Mutating requests
are never replayed automatically; the current action fails once and a later
manual action uses the refreshed token. If the credential exchange itself is
rejected, the session publishes permanent invalidation, secure credentials are
cleared, and the router moves to `/device-setup`.

## Signaling lifecycle

Every server frame follows the typed envelope:

```json
{
  "type": "webrtc.offer",
  "messageId": "<uuid>",
  "sessionId": "<uuid>",
  "from": "<sender-participant-uuid>",
  "to": "<recipient-participant-uuid>",
  "timestamp": "2026-07-29T14:00:00Z",
  "payload": {}
}
```

Routed messages use participant ids in `to`. `viewer.ready` is sent only in
reply to `publisher.ready`, addressed to its authenticated `from` participant.
Transient token/network failures use bounded exponential reconnect attempts. A
`DeviceIdentitySessionInvalidatedException` is permanent: reconnect stops and
device readiness routes even an active listener to `/device-setup`.
