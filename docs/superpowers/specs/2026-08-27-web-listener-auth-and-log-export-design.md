# Flutter Web listener authentication and diagnostics export design

**Date:** 2026-08-27  
**Issue:** flutter_mobile-web_SonicRelay#57

## Problem

The Flutter Web listener cannot authenticate the signaling WebSocket. Mobile
clients attach the device bearer token as an `Authorization` request header,
but the browser WebSocket API cannot set arbitrary request headers. The current
Web connector therefore rejects the connection before the signaling protocol
can reach `viewer.ready`, offer, answer, or ICE exchange.

Reconnect attempts request fresh device tokens and can amplify the failure into
`POST /api/devices/token` rate limiting. The `429` response is a secondary
effect, not the initial connection failure.

Web diagnostics export also fails intentionally: the browser uses an in-memory
diagnostic log whose export method throws because it has no filesystem path.

## Goals

- Authenticate browser signaling without putting credentials in a URL,
  JavaScript-persistent storage, WebSocket subprotocol, or diagnostic log.
- Preserve the existing bearer-header flow for Android, iOS, desktop, and
  non-browser signaling clients.
- Bind browser signaling authorization to the authenticated device and the
  requested session.
- Reject cross-site WebSocket attempts even when a browser has an applicable
  cookie.
- Avoid unnecessary device-token refreshes during ordinary reconnects.
- Export the browser's already-redacted in-memory diagnostics as a local file.

## Non-goals

- Changing the WebRTC offer/answer or ICE message contract.
- Persisting browser diagnostics across page reloads.
- Moving device credentials into browser local storage.
- Replacing the existing device bearer authentication used by HTTP APIs and
  non-browser clients.
- Refactoring unrelated lifecycle or reconnect behavior.

## Selected approach

### 1. Dedicated browser signaling grant

Add an authenticated HTTPS endpoint that prepares a short-lived signaling
grant for one session. The request uses the existing device bearer token in an
ordinary XHR header, which browsers support, and includes the target session
identifier.

The API performs the same device, active-session, participant, and receive
permission checks required by the signaling endpoint. On success it mints a
dedicated signed grant containing at least:

- device identifier;
- session identifier;
- participant identifier;
- signaling-only audience/purpose;
- issued-at and expiry timestamps;
- a cryptographically random token identifier.

The grant lifetime is intentionally short: 60 seconds, long enough to complete
an upgrade through normal network latency but not useful as a general API
credential. It cannot authorize HTTP endpoints or another session.

The API returns the grant only as a cookie with these attributes:

- `HttpOnly`;
- `Secure`;
- `SameSite=Strict`;
- `Path=/ws/signaling`;
- no broad `Domain` attribute (host-only);
- `Max-Age` aligned with the grant expiry.

The response body contains no grant value. The cookie name is specific to the
signaling grant and does not replace the normal device bearer token.

### 2. WebSocket authentication and origin enforcement

The signaling endpoint accepts either of two credentials:

1. the existing device bearer token from `Authorization`, for current
   non-browser clients; or
2. the dedicated signaling-grant cookie, for browser clients.

The grant is validated for signature, issuer, signaling-only audience,
expiration, device, participant, and exact `sessionId` query parameter before
the WebSocket upgrade is accepted. The device and participant records are
loaded again so revocation, session termination, or permission changes that
occurred after grant issuance still take effect.

Cookie-authenticated upgrades additionally require an `Origin` value from the
configured Web frontend allowlist. Missing, malformed, `null`, or unapproved
origins are rejected. Bearer-authenticated native clients are not required to
send an origin.

The grant is short-lived rather than a durable session cookie. Reconnecting
after expiry obtains a new grant through authenticated HTTPS. The client
coalesces concurrent grant preparation so one reconnect wave performs one
request.

No credential is written to request URLs, application logs, exception text,
or signaling messages. Server request logging must not include cookie values.

### 3. Flutter Web connection flow

The shared signaling client continues to request a current device access token
for HTTP authentication. Before the browser connector opens the socket, a
Web-only grant preparer calls the new HTTPS endpoint with that bearer token and
the session identifier, using credentials-enabled browser HTTP handling so the
host-only cookie is accepted.

After the grant endpoint succeeds, the browser opens a normal `wss:` URL with
only `sessionId` in its query. The browser adds the HttpOnly cookie itself. Dart
code never reads the grant.

The IO connector remains unchanged and continues sending `Authorization` in
the WebSocket handshake. A platform abstraction keeps browser-only APIs out of
mobile builds.

Grant preparation is coalesced per session while in flight. A reconnect does
not force-refresh the device bearer token merely because the WebSocket is
retrying; normal device-token caching remains authoritative. Authentication
failures invalidate or refresh credentials only according to the existing
device identity rules.

### 4. Browser diagnostics download

The browser diagnostic implementation keeps its current bounded, redacted,
memory-only storage. Export serializes the retained events oldest-first as
JSON Lines, creates a UTF-8 Blob, starts a browser download with a timestamped
`.jsonl` filename, and immediately revokes the temporary object URL after use.

The export API returns a platform-neutral result rather than pretending that a
browser download has a local filesystem path. Mobile retains its file path and
share-sheet behavior; Web reports success after the download is initiated.
No diagnostics are uploaded.

## Data flow

1. The listener has an existing device access token and joined session.
2. Flutter Web posts the session identifier to the signaling-grant endpoint
   with `Authorization: Bearer ...`.
3. The API verifies the device and participant, then sets the short-lived
   HttpOnly signaling cookie.
4. Flutter opens `wss://.../ws/signaling?sessionId=...`.
5. The API validates the cookie grant, approved origin, live records, and exact
   session binding before accepting the upgrade.
6. Existing signaling proceeds unchanged: roster/session announcement,
   `viewer.ready`, offer, answer, ICE candidates, and remote audio.

## Failure handling

- Grant endpoint authentication or authorization failures are terminal for the
  current attempt and surface through the existing connection error state.
- Transient grant endpoint/network failures use the existing bounded WebSocket
  reconnect policy; concurrent retries share the same in-flight grant request.
- An expired or mismatched grant is rejected before upgrade and never falls
  back to unauthenticated signaling.
- An unapproved browser origin receives `403` even with a valid cookie.
- Native bearer clients remain unaffected by browser-origin policy.
- Export failure leaves the in-memory events intact and shows the existing
  diagnostics error state.

## Security properties

- Long-lived bearer tokens never appear in a WebSocket URL or subprotocol.
- The signaling grant is HttpOnly, Secure, host-only, path-limited,
  signaling-only, session-bound, participant-bound, and short-lived.
- SameSite and explicit Origin checks provide defense in depth against
  cross-site WebSocket hijacking.
- Authorization is rechecked at upgrade time; a signed grant is not treated as
  proof that the participant is still active or permitted.
- The backend never accepts the cookie as authorization for general HTTP APIs.
- Existing redaction runs before diagnostic events enter the export buffer.
- Export is local-only and does not create durable browser storage.

## Tests

### API tests

- A valid device bearer and authorized participant receive a signaling cookie
  with the required security attributes and no token in the response body.
- Invalid device, inactive session, wrong participant, and missing receive
  permission are rejected.
- A valid grant authenticates only the matching session and participant.
- Expired, tampered, wrong-audience, wrong-session, and revoked grants fail.
- Cookie authentication rejects missing/unapproved origins and accepts the
  configured production Web origin.
- Existing bearer-authenticated signaling still connects without an Origin.

### Flutter tests

- The browser flow prepares a grant before opening the socket and uses no
  bearer value in the URL or subprotocol.
- Concurrent/reconnect attempts coalesce grant preparation and do not
  force-refresh a still-valid device token.
- IO signaling continues supplying the bearer header.
- Web export serializes redacted events in order and invokes the browser
  download adapter with the expected MIME type and filename.
- Mobile export continues returning a shareable file result.

## Deployment and compatibility

Deploy the API before or together with the Flutter Web build. Older mobile and
desktop clients remain compatible because bearer authentication is preserved.
The Web build requires HTTPS/WSS so the Secure cookie can be sent; local Web
development must use a secure local endpoint or an explicitly development-only
cookie configuration that cannot be enabled in production.

Production configuration must list exact allowed frontend origins rather than
wildcards. Reverse proxies must forward `Origin` unchanged and must not log
cookie values.
