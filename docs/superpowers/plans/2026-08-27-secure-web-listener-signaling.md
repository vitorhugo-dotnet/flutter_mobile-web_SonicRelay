# Secure Flutter Web Listener Signaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Flutter Web authenticate and use the existing listener signaling flow without exposing the device bearer token or weakening native-client authentication.

**Architecture:** An authenticated HTTPS endpoint mints a 60-second, signaling-only JWT into a host-only HttpOnly cookie bound to the device, participant, and session. The signaling endpoint accepts the existing bearer scheme or this cookie scheme, rechecks live authorization and exact Origin before upgrade, while Flutter Web prepares the cookie before opening a headerless browser WebSocket.

**Tech Stack:** ASP.NET Core 10 minimal APIs, JWT bearer authentication, EF Core, xUnit integration tests, Flutter/Dart 3.11, Dio 5, `package:web`, Flutter test.

**Spec:** `docs/superpowers/specs/2026-08-27-web-listener-auth-and-log-export-design.md`

## Global Constraints

- Keep `Authorization: Bearer` unchanged for Android, iOS, desktop, and non-browser clients.
- Never put a bearer token or signaling grant in a URL, WebSocket subprotocol, application log, response body, or persistent browser storage.
- Cookie attributes are `HttpOnly`, `Secure`, `SameSite=Strict`, host-only, `Path=/ws/signaling`, and a 60-second lifetime.
- Cookie upgrades require an exact configured frontend Origin; bearer upgrades do not.
- Recheck live device, participant, session, and receive authorization before accepting the upgrade.
- Do not add or update dependencies.
- Run only the named API and Flutter test files, not full suites.

---

### Task 1: Signaling grant token service

**Files:**
- Create: `../dotnet_SonicRelay/services/SonicRelay.Api/Services/SignalingGrantService.cs`
- Modify: `../dotnet_SonicRelay/services/SonicRelay.Api/Services/DeviceIdentityOptions.cs`
- Create: `../dotnet_SonicRelay/tests/SonicRelay.Api.IntegrationTests/SignalingGrantServiceTests.cs`

**Interfaces:**
- Consumes: `DeviceIdentityOptions.TokenSigningKey`, issuer, `TimeProvider`, device/session/participant GUIDs.
- Produces: `SignalingGrantService.Issue(Guid deviceId, Guid sessionId, Guid participantId)` and validation parameters for authentication scheme `SignalingGrant`; claims `sub`, `session_id`, `participant_id`, `purpose=signaling`, and `jti`.

- [ ] **Step 1: Write failing service tests**

Add tests that issue a grant at a fixed time, validate it with the signaling audience, assert all binding claims and an expiry exactly 60 seconds later, then prove tampering, wrong audience, and a clock beyond expiry fail validation.

```csharp
var issued = service.Issue(deviceId, sessionId, participantId);
var principal = handler.ValidateToken(issued.Token, service.ValidationParameters, out _);
Assert.Equal(deviceId.ToString(), principal.FindFirst("sub")!.Value);
Assert.Equal(sessionId.ToString(), principal.FindFirst("session_id")!.Value);
Assert.Equal(participantId.ToString(), principal.FindFirst("participant_id")!.Value);
Assert.Equal("signaling", principal.FindFirst("purpose")!.Value);
Assert.Equal(now.AddSeconds(60), issued.ExpiresAt);
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `dotnet test tests/SonicRelay.Api.IntegrationTests --filter FullyQualifiedName~SignalingGrantServiceTests --no-restore`

Expected: compilation fails because `SignalingGrantService` and its grant settings do not exist.

- [ ] **Step 3: Implement the minimal grant service**

Create a sealed service that signs HS256 JWTs with the existing signing key but a distinct audience `${DeviceIdentity.Audience}:signaling`, 60-second lifetime, zero validation clock skew, and the exact binding claims above. Expose one immutable result:

```csharp
public sealed record SignalingGrant(string Token, DateTimeOffset ExpiresAt);
public SignalingGrant Issue(Guid deviceId, Guid sessionId, Guid participantId);
public TokenValidationParameters ValidationParameters { get; }
```

Register it as a singleton and keep key validation through `DeviceCredentialService.RequireKey`.

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run the Task 1 command. Expected: all `SignalingGrantServiceTests` pass.

- [ ] **Step 5: Commit the service**

```text
git add services/SonicRelay.Api/Services/SignalingGrantService.cs services/SonicRelay.Api/Services/DeviceIdentityOptions.cs tests/SonicRelay.Api.IntegrationTests/SignalingGrantServiceTests.cs services/SonicRelay.Api/Program.cs
git commit -m "feat(api): add short-lived signaling grants"
```

### Task 2: Authenticated grant preparation endpoint

**Files:**
- Create: `../dotnet_SonicRelay/services/SonicRelay.Api/Endpoints/SignalingGrantEndpoints.cs`
- Modify: `../dotnet_SonicRelay/services/SonicRelay.Api/Program.cs`
- Create: `../dotnet_SonicRelay/tests/SonicRelay.Api.IntegrationTests/SignalingGrantEndpointsTests.cs`

**Interfaces:**
- Consumes: authenticated `DeviceBearer` principal, `SignalingGrantService`, `AppDbContext`, JSON `{ "sessionId": "guid" }`.
- Produces: `POST /api/signaling/grant`, HTTP 204 with `Set-Cookie: sonicrelay_signaling=...` and no response body.

- [ ] **Step 1: Write failing endpoint tests**

Cover: no bearer returns 401; unknown/terminal session returns 404/410; device not an active participant returns 403; a permitted viewer returns 204 with an empty body and a cookie containing `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/ws/signaling`, `Max-Age=60`, and no `Domain`; the raw token occurs only in `Set-Cookie`.

```csharp
request.Headers.Authorization = new("Bearer", viewer.AccessToken);
var response = await client.SendAsync(request);
Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
Assert.Equal(string.Empty, await response.Content.ReadAsStringAsync());
var cookie = response.Headers.GetValues("Set-Cookie").Single();
Assert.Contains("HttpOnly", cookie);
Assert.Contains("Secure", cookie);
Assert.DoesNotContain("Domain=", cookie, StringComparison.OrdinalIgnoreCase);
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `dotnet test tests/SonicRelay.Api.IntegrationTests --filter FullyQualifiedName~SignalingGrantEndpointsTests --no-restore`

Expected: 404 because the grant endpoint is not mapped.

- [ ] **Step 3: Implement admission and cookie issuance**

Map the endpoint under the existing `signaling:connect` bearer policy. Resolve the device with `RequireDeviceAsync`, load the exact session participant, require an active session, connected participant, and viewer receive permission, issue the grant, append the cookie using `CookieOptions`, and return `Results.NoContent()`.

Register `MapSignalingGrantEndpoints()` immediately before `MapSignalingWebSocketEndpoint()`.

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run the Task 2 command. Expected: all endpoint tests pass.

- [ ] **Step 5: Commit the endpoint**

```text
git add services/SonicRelay.Api/Endpoints/SignalingGrantEndpoints.cs services/SonicRelay.Api/Program.cs tests/SonicRelay.Api.IntegrationTests/SignalingGrantEndpointsTests.cs
git commit -m "feat(api): issue browser signaling cookie"
```

### Task 3: Cookie authentication and Origin gate on WebSocket upgrade

**Files:**
- Create: `../dotnet_SonicRelay/services/SonicRelay.Api/Authorization/SignalingGrantAuthenticationHandler.cs`
- Create: `../dotnet_SonicRelay/services/SonicRelay.Api/Services/SignalingOriginOptions.cs`
- Modify: `../dotnet_SonicRelay/services/SonicRelay.Api/Program.cs`
- Modify: `../dotnet_SonicRelay/services/SonicRelay.Api/Endpoints/SignalingWebSocketEndpoint.cs`
- Modify: `../dotnet_SonicRelay/tests/SonicRelay.Api.IntegrationTests/SignalingWebSocketTests.cs`

**Interfaces:**
- Consumes: cookie `sonicrelay_signaling`, configured `Signaling:AllowedWebOrigins`, session query, live EF records.
- Produces: policy `signaling:connect` accepting `DeviceBearer` or `SignalingGrant`; cookie-authenticated upgrades expose grant claims and pass only with an approved Origin.

- [ ] **Step 1: Add failing integration cases**

Prepare a grant cookie through Task 2, then cover valid exact Origin, missing Origin, `null`, sibling/unapproved Origin, wrong-session cookie, expired/tampered cookie, revoked device, disconnected participant, and changed receive permission. Keep and run an existing bearer WebSocket test without Origin to lock compatibility.

```csharp
client.ConfigureRequest = request =>
{
    request.Headers.Add("Cookie", grantCookie);
    request.Headers.Add("Origin", "https://sonicrelay.hugodotnet.dev");
};
using var socket = await client.ConnectAsync(uri, CancellationToken.None);
```

- [ ] **Step 2: Run the focused WebSocket tests and confirm RED**

Run: `dotnet test tests/SonicRelay.Api.IntegrationTests --filter FullyQualifiedName~SignalingWebSocketTests --no-restore`

Expected: cookie cases fail 401 because only `DeviceBearer` is accepted.

- [ ] **Step 3: Implement the cookie scheme and endpoint defense in depth**

Add an authentication handler that reads only the named cookie, validates it with `SignalingGrantService.ValidationParameters`, and creates a `SignalingGrant` identity. Configure `signaling:connect` with both schemes and keep `DeviceScopeRequirement("signaling:connect")` only for `DeviceBearer`; add an explicit assertion/requirement that accepts a valid grant purpose for the cookie identity.

At the start of `HandleAsync`, distinguish the authentication type. For a grant identity: require exact configured Origin, parse claim GUIDs, compare `session_id` to the query, reload device/session/participant, and ensure all are live and bound. Do not log header/cookie/claim token values. Call `AcceptWebSocketAsync()` only after every check passes.

- [ ] **Step 4: Run focused API regression tests**

Run:

```text
dotnet test tests/SonicRelay.Api.IntegrationTests --filter "FullyQualifiedName~SignalingWebSocketTests|FullyQualifiedName~SignalingGrantEndpointsTests|FullyQualifiedName~SignalingGrantServiceTests" --no-restore
```

Expected: all three focused classes pass, including legacy bearer cases.

- [ ] **Step 5: Commit authentication**

```text
git add services/SonicRelay.Api/Authorization/SignalingGrantAuthenticationHandler.cs services/SonicRelay.Api/Services/SignalingOriginOptions.cs services/SonicRelay.Api/Program.cs services/SonicRelay.Api/Endpoints/SignalingWebSocketEndpoint.cs tests/SonicRelay.Api.IntegrationTests/SignalingWebSocketTests.cs
git commit -m "feat(api): authenticate browser signaling grants"
```

### Task 4: Flutter signaling grant preparer

**Files:**
- Create: `lib/features/signaling/data/signaling_grant_preparer.dart`
- Create: `lib/features/signaling/data/platform_signaling_grant_preparer.dart`
- Create: `lib/features/signaling/data/io_signaling_grant_preparer.dart`
- Create: `lib/features/signaling/data/web_signaling_grant_preparer.dart`
- Modify: `lib/app/di/app_providers.dart`
- Test: `test/features/signaling/data/signaling_grant_preparer_test.dart`

**Interfaces:**
- Consumes: API base URL, `DeviceIdentitySession.accessToken()`, session ID, injected POST adapter.
- Produces: `abstract interface class SignalingGrantPreparer { Future<void> prepare(String sessionId); }`; IO implementation is a no-op, Web implementation posts `/api/signaling/grant` with bearer and credentials enabled; concurrent same-session calls share one Future.

- [ ] **Step 1: Write failing unit tests**

Assert the Web implementation posts once for concurrent calls, uses the cached bearer without `forceRefresh`, sends only `sessionId` in JSON, enables browser credentials, propagates non-2xx failures, and allows a later retry after failure. Assert IO is a no-op.

- [ ] **Step 2: Run and confirm RED**

Run: `flutter test test/features/signaling/data/signaling_grant_preparer_test.dart`

Expected: compilation fails because the preparer does not exist.

- [ ] **Step 3: Implement the platform abstraction**

Use conditional export for IO/Web. Keep browser adapter creation inside the Web file; set `BrowserHttpClientAdapter.withCredentials = true`. Store one `_inFlight` Future keyed by session ID and clear it in `whenComplete` only if identical.

- [ ] **Step 4: Run and confirm GREEN**

Run the Task 4 command. Expected: all preparer tests pass.

- [ ] **Step 5: Commit the preparer**

```text
git add lib/features/signaling/data/*signaling_grant_preparer.dart lib/app/di/app_providers.dart test/features/signaling/data/signaling_grant_preparer_test.dart
git commit -m "feat(web): prepare signaling authentication grant"
```

### Task 5: Prepare Web grant before each socket attempt without token amplification

**Files:**
- Modify: `lib/core/websocket/websocket_client.dart`
- Modify: `lib/features/signaling/data/signaling_client.dart`
- Modify: `lib/core/websocket/web_websocket_connector.dart`
- Modify: `lib/app/di/app_providers.dart`
- Modify: `test/features/signaling/data/signaling_client_test.dart`
- Modify: `test/core/websocket/websocket_client_test.dart`

**Interfaces:**
- Consumes: Task 4 `SignalingGrantPreparer.prepare(sessionId)`.
- Produces: optional `beforeConnect(bool isReconnect)` hook on `WebSocketClient.connect`; browser signaling prepares the cookie on every attempt, IO still provides bearer headers; browser connector accepts an empty header map and rejects any accidental non-empty headers.

- [ ] **Step 1: Write failing signaling and reconnect tests**

Assert order `prepare -> connector`, including reconnect; one normal reconnect does not call `accessToken(forceRefresh: true)`; IO still supplies `Authorization`; and no token is present in browser URI/subprotocol/header arguments.

- [ ] **Step 2: Run and confirm RED**

Run:

```text
flutter test test/features/signaling/data/signaling_client_test.dart test/core/websocket/websocket_client_test.dart
```

Expected: tests fail because no pre-connect hook exists and reconnect forces token refresh.

- [ ] **Step 3: Implement minimal hook and platform wiring**

Invoke `beforeConnect(isReconnect)` immediately before resolving headers/connector. In `SignalingClient`, select either grant preparation with empty headers on Web or the existing bearer header provider on IO through a platform policy/provider. Remove the obsolete browser unsupported-contract text but retain fail-closed behavior if headers accidentally reach `webWebSocketConnector`.

- [ ] **Step 4: Run focused Flutter tests and static analysis**

Run:

```text
flutter test test/features/signaling/data/signaling_grant_preparer_test.dart test/features/signaling/data/signaling_client_test.dart test/core/websocket/websocket_client_test.dart
flutter analyze lib/features/signaling lib/core/websocket lib/app/di/app_providers.dart
```

Expected: tests and analysis pass.

- [ ] **Step 5: Commit Web signaling flow**

```text
git add lib/core/websocket lib/features/signaling/data lib/app/di/app_providers.dart test/core/websocket/websocket_client_test.dart test/features/signaling/data
git commit -m "fix(web): authenticate listener signaling"
```

### Task 6: Cross-project focused verification

**Files:** No production edits expected.

**Interfaces:** Verifies Tasks 1-5 as one flow.

- [ ] **Step 1: Run API focused tests**

Run the Task 3 combined API command. Expected: PASS.

- [ ] **Step 2: Run Flutter focused tests**

Run the Task 5 Flutter test and analyze commands. Expected: PASS.

- [ ] **Step 3: Inspect security-sensitive diff**

Run targeted `git diff --check` and `git diff --stat` in both repositories. Search changed files for bearer/grant interpolation in URLs, subprotocols, and logs; expected result is none.

- [ ] **Step 4: Record manual production checks without claiming them complete**

Document remaining deployment verification: Chrome and Firefox public radio playback, a regular desktop publisher, exact production Origin configuration, proxy cookie redaction, WebRTC connected/completed states, and absence of `/api/devices/token` 429 during one normal join.
