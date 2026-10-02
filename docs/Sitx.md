# Sit(x) standalone connection

The watch now supports direct Sit(x) PLI, manual/physiological/environmental
alerts and cancellations, point updates and deletions, and incoming users and
points. These capabilities supersede the initial transport status in the root
README.

## Setup

1. Open Settings > Network Preferences > Sit(x) Device API and enter the HTTPS
   organization host.
2. Tap Auth Code and approve the device on the displayed authorization page.
3. Select a permitted TAK Group. A single permitted group is selected
   automatically; the selected group is remembered across launches.
4. Wait for Status to show Connected. This means the authenticated TAK
   WebSocket has responded, not just that authorization succeeded.

Authorization enables direct Sit(x) reporting without another opt-in switch.
The client uses `/api/v1/tak_servers` to discover groups, then
`/api/v1/access/token` to obtain the group's authenticated `wss` endpoint.
Tokens are stored in Keychain and refreshed on reconnect. Changing the host or
using Clear Sit(x) discards the old authorization.

## Delivery and limitations

PLI uses the configured Dynamic/Constant intervals and WiFi multiplier.
Manual, physiological, and environmental alert activations and cancellations,
point updates, and point deletions send independently of the PLI timer.
Incoming CoT users and points appear on the map. Failed alert/point events are
retained in a bounded in-memory queue and retried after reconnect; cancellation
supersedes a queued activation. Queued events do not survive app termination
and are discarded when the destination group changes. Pending Events shows
the queue count. Network/token failures are shown in Status and retry while
the app is active.

Direct reporting pauses in the background. This implementation does not claim
continuous screen-off/background tracking. It also pauses when WatchConnectivity
reports a reachable phone companion. Physical Bluetooth pairing alone is not
detectable through that API, and this repository does not yet contain a phone
companion or phone-relay transport. Chat delivery is not implemented.

## Protocol checks

Run these checks on macOS. They use mocked HTTP and in-memory tokens, not real
credentials. Live Sit(x) WebSocket and physical-watch checks remain required.

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  'WearTAK Watch App/AppSettings.swift' \
  'WearTAK Watch App/RelayProtocol.swift' \
  'WearTAK Watch App/SitxCoT.swift' \
  'WearTAK Watch App/SitxClient.swift' \
  Tests/SitxProtocolChecks.swift -o /tmp/weartak-sitx-checks
/tmp/weartak-sitx-checks
```