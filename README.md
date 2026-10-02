# weartak-ios

## Repository

- Canonical: https://git.tak.gov/core/weartak-core/weartak-ios
- Backup mirror: https://github.com/aegorsuch/weartak-ios

## Rights and contacts

### Rights

Unlimited rights granted to TAK Product Center.

### Point of contact

Alex Gorsuch on chat.tak.gov or Signal.

### Repositories

The TAK Forge repository is canonical. GitHub is a secondary repository.

## WearTAK Apple Watch

WearTAK is a watch-first TAK application for Apple Watch. It provides a MapKit
map, saved tactical points, Bloodhound navigation, manual alerts, physiological
and environmental monitoring, and direct Sit(x) connectivity. App code lives in
`WearTAK Watch App/`.

HealthKit supplies heart-rate readings; Core Motion supplies step activity,
relative altitude, and pressure where supported. Physiological sensing and
automatic alerts have separate preferences. Alert thresholds and durations are
configurable. The watch target requires the HealthKit capability when signing
for a device. Sensor monitoring and direct reporting stop in the background.

## Sit(x) TAK

### Setup

1. Open Settings > Network Preferences > Sit(x) TAK.
2. Set Address to the organization name. For example, `team` becomes
   `https://team.sitx.io`. An existing `.sitx.io` suffix is not duplicated.
3. Turn on Sit(x) TAK and approve the device using the code and authorization
   link in the authorization sheet.
4. Select Group. A single permitted group is selected automatically; the
   selection is remembered across launches.
5. Wait for Sit(x) State to show Connected. This means the authenticated TAK
   WebSocket has responded, not just that authorization succeeded.

The menu order is Sit(x) TAK toggle, Address, Group, Sit(x) State, Re-auth, Back.
The Network Preferences entry shows Sit(x) TAK with the current state below it.
Off stops direct reporting while preserving credentials and the selected group.
Re-auth discards the old credentials and starts a new device authorization.
Changing the address also invalidates the previous organization's credentials.

### Connection protocol

- POST `/api/v1/device/authorization/code` with the device scope and client ID.
- Poll POST `/api/v1/device/authorization/token` with the device-code grant.
  Respect the server's polling interval, `authorization_pending`, `slow_down`,
  and expiration responses.
- Store tokens securely. POST `/api/v1/refresh/token` authenticates with
  `Authorization: Bearer <refresh_token>` and rotates the saved refresh token.
- GET `/api/v1/tak_servers`, also using the refresh-token Bearer header, returns
  permitted groups with `flow_tag` and `name`.
- POST `/api/v1/access/token` with the refresh-token Bearer header and a form
  containing `grant_type=access`, `resource_type=TAKSERVER`, and
  `resource_key=<flow_tag>`. Persist any rotated refresh token.
- Connect to the returned `end_point` using its `access_token` as the Bearer
  header on the WebSocket handshake. Require a secure `wss` endpoint. Send and
  receive CoT XML through this socket.

The client stores credentials in Keychain, refreshes them on reconnect, and
retries transient network failures while the app is active. Transient failures
do not erase authorization. Connected is shown only after the socket responds.

### Delivery

PLI includes a stable device UID, position, callsign, team, role, and CoT
time/start/stale fields. Dynamic Reporting defaults to 3600 seconds stationary,
60 seconds on foot, 60 seconds in a vehicle, and 10 seconds while alerting.
Constant Reporting defaults to 60 seconds. Save Battery on WiFi multiplies the
selected interval by six on qualifying WiFi connections.

Manual, physiological, and environmental alert activations and cancellations,
point updates, and point deletions send independently of the PLI timer. Alert
and cancellation events share an alert UID; cancellations use `b-a-o-can` and
`<emergency cancel="true">`. Point deletion uses `t-x-d-d`, a link to the point
UID, and `__forcedelete`. Incoming nonexpired CoT users and points appear on
the map, excluding the watch's own PLI.

Failed alert/point events are retained in a bounded in-memory queue and retried
after reconnect. Cancellation supersedes a queued activation. Queued events do
not survive app termination and are discarded when reporting is turned Off,
the address changes, the destination group changes, or Re-auth starts.

### Limitations

Direct reporting is foreground-only; continuous screen-off/background tracking
is not implemented. Direct Sit(x) pauses when WatchConnectivity reports a
reachable phone companion. Physical Bluetooth pairing alone is not detectable
through that API. This repository does not yet contain a phone companion or
phone-relay transport. Chat delivery is not implemented.

watchOS cannot identify connected WiFi SSIDs or list saved networks. All WiFi
Connections and No WiFi Connections are supported; Some WiFi Connections is
disabled. Live Sit(x) WebSocket and physical-watch testing remain required.

### Protocol checks

Run these checks on macOS. They use mocked HTTP and in-memory tokens, not real
credentials.

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  'WearTAK Watch App/AppSettings.swift' \
  'WearTAK Watch App/RelayProtocol.swift' \
  'WearTAK Watch App/SitxCoT.swift' \
  'WearTAK Watch App/SitxClient.swift' \
  Tests/SitxProtocolChecks.swift -o /tmp/weartak-sitx-checks
/tmp/weartak-sitx-checks
```