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

## Download and install

WearTAK is currently an early-development Apple Watch app. There is no
published TestFlight/App Store installation link in this repository yet.
GitHub source archives and simulator builds cannot be installed directly on a
physical Apple Watch. Do not treat this build's alerts as a safety service.

### Beta users: TestFlight

TestFlight is the recommended distribution route for users without Xcode.
When a signed beta is available, its invitation/public link will be included
in the [GitHub release notes](https://github.com/aegorsuch/weartak-ios/releases).
The link is not available until the Apple distribution steps below are done.

1. Check that your Apple Watch can run watchOS 26.2 or newer, the project's
  current minimum. Keep its paired iPhone on a compatible iOS version.
2. Install Apple's TestFlight app on the paired iPhone, open the WearTAK
  invitation/public link there, and accept the beta invitation.
3. In TestFlight, use the WearTAK Apple Watch installation option. Keep the
  watch paired, nearby, charged, and connected while installation completes.
4. Open WearTAK on the watch. Grant location, HealthKit heart-rate, and motion
  access when requested for the features you choose to use. watchOS does not
  use the iOS Local Network privacy prompt.
5. Keep WearTAK foregrounded during testing. Configure Sit(x) in Network
  Preferences or use TAK SA Multicast on a trusted multicast-capable WiFi
  network. Multicast is enabled by default and sends unencrypted CoT on the
  LAN; turn it off in Network Preferences when not wanted.

Beta builds expire after 90 days. Install a newer TestFlight build when one is
available. WearTAK Companion is optional; see its setup below. Selecting iTAK
or TAK Aware does not yet connect the watch to those partner apps.

### Developers: build from source onto a watch

This path requires a Mac, Xcode with the watchOS 26.2 SDK or newer, and an Apple
Developer team/provisioning profile authorized for this app's capabilities.
A simulator build is not a substitute for a signed device build. Your team and
profile must support the app's HealthKit and Keychain capabilities.

1. Download the Source code ZIP from a GitHub release, or clone this repository
  and check out the desired release tag. For the latest development code:

  ```sh
  git clone --branch develop https://github.com/aegorsuch/weartak-ios.git
  cd weartak-ios
  open WearTAK.xcodeproj
  ```

2. In Xcode, add your Apple Account under Settings > Accounts. Select the
  WearTAK Watch App target, open Signing & Capabilities, and select your team.
  If your team cannot use the repository's bundle ID, use a unique bundle ID
  and matching profiles for your own development build.
3. Ensure the app ID/profile includes HealthKit and Keychain access. Use a
  development certificate/profile for Product > Run on a physical watch; an
  App Store Connect distribution profile is for archives and uploads, not
  direct development installation. Do not add the iOS-family-only
  `com.apple.developer.networking.multicast` entitlement to the watch target.
4. Pair/connect the physical watch through Xcode's Devices and Simulators
  setup. Enable Developer Mode on the watch when Xcode requires it and follow
  the device trust/pairing prompts. A paired iPhone may be needed for setup.
5. Select scheme WearTAK Watch App and your physical watch as the run
  destination, then choose Product > Run. Xcode signs and installs the app.
  Launch it from the watch's app list and grant the requested permissions.

For simulator-only testing, select a watch simulator instead. This verifies UI
and simulated behavior, not hardware sensors, LAN multicast behavior, or
real-device signing. If you do not have approved provisioning, use an approved
TestFlight build once available rather than trying to install an unsigned app.

### Maintainers: publish a beta and GitHub release

GitHub hosts versioned source, notes, and installation links. TestFlight/App
Store distributes the signed app to ordinary Apple Watch users. Publishing a
ZIP, `.app`, or `.xcarchive` on GitHub does not make it generally installable.
Ad Hoc distribution is limited to registered devices and appropriate profiles;
it is not the recommended public-beta route.

Before the first distribution archive:

- Register the App Store container ID `com.aegorsuch.weartak` and watch app ID
  `com.aegorsuch.weartak.watchkitapp` with your Apple Developer Program team.
  The App Store Connect record uses the container ID.
- Use an Apple Distribution certificate and separate App Store Connect profiles:
  `WearTAK Container App Store` for `com.aegorsuch.weartak`, and the existing
  `WearTAK App Store` for `com.aegorsuch.weartak.watchkitapp`. The watch profile
  must support HealthKit and Keychain; the container does not implement them.
  Neither target should request the iOS-only multicast entitlement.
- Select the container profile in WearTAK Distribution > Signing & Capabilities
  > Release. Keep the watch profile on WearTAK Watch App. Both profiles can use
  the same Apple Distribution certificate; registered devices are not needed.
- The packaging target uses Skip Install No; the embedded watch target uses
  Skip Install Yes. Upload the container archive, not a bare watch archive.
- Verify the included opaque 1024x1024 watch app-icon image in the AppIcon asset
  set. It uses the central skull/WEARTAK artwork without the watch or outer ring.
- The project uses Version `5.8.0`, Build `4`, with separate Apple-compatible
  version/build fields. Increment the build number for each subsequent upload.
- Create the matching app record in App Store Connect; provide beta contact
  information, privacy information/policy, screenshots, export-compliance
  answers, and any review instructions needed for Sit(x) authorization.
- Physical-watch verification has been reported by the maintainer. Recheck
  PLI, alert activation/cancellation, marker updates/deletes, incoming users,
  compass, permissions, and battery behavior for each distribution build.

Then:

1. Run the protocol checks below and the watch build. For upload, choose the
  shared scheme WearTAK App Store and destination Any iOS Device, then Product
  > Archive. The iOS target is WearTAK Companion and embeds the independent
  watch app under `WearTAK.app/Watch/`. Continue using WearTAK Watch App for
  watch development or WearTAK Companion for phone development.
2. In Organizer, validate the archive and use Distribute App > App Store
  Connect to upload it. Resolve signing or validation failures; never upload
  the simulator/ad-hoc-signed build used during development.
3. Wait for processing in App Store Connect. Configure TestFlight testing,
  complete required beta review for external testers, and create the tester
  invitation/public link. HealthKit use requires accurate privacy disclosures.
4. Tag the exact tested source commit and create a GitHub prerelease from that
  tag. Include the approved TestFlight link, version/build, minimum watchOS,
  installation steps, known limitations, and testing guidance in the notes.
  GitHub provides source ZIP/tarball downloads for the tag automatically.
5. Update this README with the real invitation link. Do not claim a beta or
  installable download exists until Apple has processed/approved it and the
  link works. Avoid attaching private credentials or provisioning material.

The current checkout includes its app-icon image and Version `5.8.0`, Build `4`.
The maintainer reports physical-watch verification. Public-beta distribution
still requires the signing team, approved capabilities/profiles, App Store
Connect setup, and TestFlight processing/review described above.

The container archive structure has been verified locally. A bare watch
archive can be signed correctly but still be rejected for App Store distribution
and fall back to Ad Hoc export, which asks for devices. Do not resolve that by
registering devices for TestFlight: use the container scheme and profiles above.
Unsigned packaging checks are not uploadable builds, and no upload or App Store
validation is implied by a successful local archive build.

Apple references:
[TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
and [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Features

WearTAK is a watch-first TAK application for Apple Watch. It provides a MapKit
map, saved tactical points, Bloodhound navigation, manual alerts, physiological
and environmental monitoring, local TAK multicast, and direct Sit(x) connectivity.
App code lives in `WearTAK Watch App/`.

HealthKit supplies heart-rate readings; Core Motion supplies step activity,
relative altitude, and pressure where supported. Physiological sensing and
automatic alerts have separate preferences. Alert thresholds and durations are
configurable. The watch target requires the HealthKit capability when signing
for a device. Sensor monitoring and direct reporting stop in the background.

The watch Info.plist includes both HealthKit read and update purpose strings
required by App Store validation. The current monitor requests read access only
and does not save or modify Health data; the update-purpose text states this.

### Dashboard

The dashboard uses the watchOS status-area clock; it has no duplicate bottom
clock or More button. Marker tools remain available by holding the point
picker's center button.

Tap the center metric to choose Exertion or Heart Rate. Exertion is the default;
the selection is remembered. Heart Rate uses a heartbeat waveform icon and
displays BPM. The selection menu has the existing Physiological Alerts On/Off
toggle at the top. Exertion and Heart Rate show their current readings or
Unavailable beside each option; there is no separate Physiology link. The alert
toggle is independent of the Physiological Monitoring preference that controls
sensing.

The top Exertion/Heart Rate control gains a yellow outline for an active
physiological warning and a red outline for an active physiological alert.
Alerts take priority over warnings; the outline clears when neither is active.
This does not change the compass/Bloodhound ring.

The network icon reflects the active WiFi, cellular, unavailable, or other
network path and opens Network Preferences. A cellular path does not expose its
radio generation or signal strength. Phone-proxied paths may appear as another
network type rather than identifiable WiFi or cellular.

The TAK indicator distinguishes multicast broadcasts, the Sit(x) cloud, and a
phone-relay icon. Green checks require a ready transport, not just an enabled
preference. Concurrent active multicast and Sit(x) outputs show both symbols.
A selected phone-relay provider does not imply a working connection. Companion
readiness requires a reachable watch/phone session and a confirmed live server
connection; iTAK and TAK Aware integration remains incomplete. The TAK indicator
also opens Network Preferences.

### Dropped markers

The dashboard point-drop button opens a radial Hostile, Neutral, Friendly,
and Unknown picker. Selecting a type drops a point at the current location;
missing location is reported without creating a point. Tap the center X to
cancel, or hold it to open marker tools: Dropped Markers, Back, and Clear Last
Marker. Clear Last Marker removes the newest saved point after confirmation.

Dropped Markers shows each point's symbol, title, type, and local drop time.
Tap a row to reveal the three-dot button for the existing point editor and
the trash button for deleting that point. Clear All Markers removes all saved
points after confirmation. Incoming network entities remain on the map and
are not included in these local-marker deletion actions.

Map long-press starts with Unknown and then uses the most recently dropped or
changed marker type, remembered across launches. Dropping or changing a point
to Unknown restores Unknown as the default. Title/remark-only edits do not
change the default type.

### Map Layers Menu

The stacked-layers icon at the top of the map opens Layers Menu. Map Buttons
shows or hides zoom and snap controls; Layers, Channels and Back remain available.
Below it, Team Colors and Default Roles list only groups present among received
users, with incoming-user counts. Their headings remain visible as
`Team Colors (0)` and `Default Roles (0)` when no groups are present.
These groups come from CoT `__group name/role`
metadata received through multicast, Sit(x), or Companion, not from a fixed
option list.

All groups start visible. Switching a team or role off hides its users on the
map; both filters must allow a user for that user to appear. Hidden selections
are remembered across launches. Reception continues, and hidden users remain
in group counts so they can be shown again. Groups disappear from the menu as
their users are pruned from the incoming list. Missing team/role metadata does
not create an empty toggle. Filters do not hide your own location, saved points,
or incoming non-user markers. Incoming users use their reported team color
when recognized and their contact callsign when available.

## TAK Relay

TAK Relay integration with iTAK and TAK Aware is not complete. The project
developer is working with those partners to complete integration. The provider
selector currently saves a preference only; choosing iTAK or TAK Aware does not
establish a relay connection or enable phone-relayed delivery. Their submenu
rows use a small Teaming label rather than a general integration warning.

### WearTAK Companion

The optional iPhone app requires iOS 18 or newer, an existing TAK server, and
an administrator-provided client certificate or enrollment account. It does
not supply a server. The watch remains independently usable with direct Sit(x)
and local multicast without Companion.

1. On the phone, open WearTAK Companion and choose Add Server. Enter the server
  IP or hostname (or a root HTTPS URL) and CoT stream port, normally `8089`.
  Use the hostname matching the server certificate; TLS verification is strict.
2. Enroll with the administrator's username/password or import a `.p12` file
  with its password. Save the server, then turn its individual switch on.
  Additional servers can be saved, edited, enabled independently, or removed
  with confirmation. The Watch status appears above the TAK Servers list.
3. On the watch, select Companion in Settings > Network Preferences > TAK
  Relay. Keep both apps foregrounded and the paired phone reachable.
  Connected requires a successful mutual-TLS server connection, not just a
  saved certificate or Bluetooth pairing.

Enrollment uses HTTPS `8446` by default; an explicit HTTPS URL port overrides
that enrollment port, not the separately entered CoT stream port. Client
identities and import passwords are stored in endpoint-scoped Keychain entries.
Enrollment passwords are not persisted; renew by enrolling again. The UI
reports certificate expiration and a renewal warning within three days.

Watch CoT is sent to all connected, enabled servers. An acknowledgement means
at least one server socket accepted the write, not that a remote TAK user
received it. Incoming CoT is forwarded to a reachable watch. Readiness is
confirmed by a live handshake and expires if confirmations stop. Direct Sit(x)
pauses only while Companion is actually ready; multicast remains independent.
There is no guaranteed background relay or durable offline PLI replay.

### Map Channels

The connected-nodes button at the watch map's top right opens Channels; Layers
remains top center. Choose an enabled Companion server to load its assigned
channels, then toggle membership on the watch. Refresh reloads the server state.
Selections are shown only after the server confirms them. Empty, unsupported,
disconnected, and request-failure states are displayed explicitly.

Companion performs the mutually authenticated HTTPS requests on port `8443`:
`GET /Marti/api/groups/groupCacheEnabled`,
`GET /Marti/api/groups/all?useCache=true&sendLatestSA=true`, and
`PUT /Marti/api/groups/active?clientUid=<watch UID>`. Updates preserve the full
group payload and change matching IN/OUT records together. Confirmed membership
changes advance that server's map-source generation; stale entries from that
source are cleared without clearing local points or other-source entries.
Companion restarts clear Companion-sourced cache entries only.

Channels requires a TAK server supporting these group APIs. Multicast,
standalone Sit(x), iTAK and TAK Aware do not currently expose this channel menu's
server operations. Protocol checks and combined builds cover local behavior;
paired-device channel and CoT interoperability still require live verification.

## TAK SA Multicast

Open Settings > Network Preferences > TAK SA Multicast. The entry appears
above Sit(x) TAK and shows Enabled or Disabled. Multicast defaults to Enabled;
an explicitly saved Disabled selection is preserved.
The submenu contains a toggle, Address, Output Protocol, Port, and Back.
Defaults are `239.2.3.1`, `UDP`, and port `6969`.

The address must be an IPv4 multicast group in `224.0.0.0/4`; the port must be
between 1 and 65535. Output is CoT XML over UDP. TCP is not offered because it
cannot send to an IP multicast group. The transport joins the selected group
on the watch's WiFi interface, publishes PLI/alerts/points, and displays
incoming nonexpired CoT users and points on the map. Enabled means the
preference is on, not that delivery is confirmed. UDP has no receiver
acknowledgment. Runtime readiness and errors are tracked internally; there is
no State row in the multicast submenu.

Multicast and Sit(x) can run independently or together. They share the same
Dynamic/Constant PLI reporting intervals and Save Battery on WiFi multiplier.
Alerts, cancellations, marker updates, and marker deletions send immediately,
independently of the PLI timer. A failed output does not block a working one.
Disabling Sit(x) does not disable multicast, and vice versa.

Multicast sends tactical data in plaintext on the local network. Enable it
only on a trusted network. The watch and other TAK devices must share a WiFi
network that permits multicast; access-point/client isolation can block it.
Apple documents `com.apple.developer.networking.multicast` for iOS, iPadOS,
and visionOS, not watchOS. It is intentionally absent from this watch-only
target's entitlements; watchOS also does not implement iOS local-network
privacy. This does not prove multicast works in every watch/network condition:
the maintainer reports physical-watch verification, and LAN checks should be
repeated for distribution builds. Keep HealthKit/Keychain provisioning valid.
See [Apple's local-network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
and [multicast entitlement platforms](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast).

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
Off stops Sit(x) delivery while preserving credentials and the selected group.
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

### Delivery and shared reporting

PLI includes a stable device UID, position, callsign, team, role, and CoT
time/start/stale fields. Both multicast and standalone Sit(x) use the reporting
controls. Dynamic Reporting defaults to 3600 seconds stationary, 60 seconds on
foot, 60 seconds in a vehicle, and 10 seconds while alerting. Constant Reporting
defaults to 60 seconds. Save Battery on WiFi multiplies the selected interval
by six on qualifying WiFi connections.

Manual, physiological, and environmental alert activations and cancellations,
point updates, and point deletions send independently of the PLI timer. Alert
and cancellation events share an alert UID; cancellations use `b-a-o-can` and
`<emergency cancel="true">`. Point deletion uses `t-x-d-d`, a link to the point
UID, and `__forcedelete`. Incoming nonexpired CoT users and points appear on
the map, excluding the watch's own PLI and locally saved points.

Failed Sit(x) alert/point events are retained in a bounded in-memory queue and
retried after reconnect. Cancellation supersedes a queued activation. Queued
events do not survive app termination and are discarded when Sit(x) is turned
Off, its address changes, the destination group changes, or Re-auth starts.
Multicast does not retain offline events or retry unacknowledged datagrams.

### Limitations

Reporting is foreground-only; continuous screen-off/background tracking is not
implemented. Direct Sit(x) pauses only when the optional Companion transport is
confirmed ready. Physical Bluetooth pairing alone is not proof of relay
readiness. Chat delivery is not implemented.

watchOS cannot identify connected WiFi SSIDs or list saved networks. All WiFi
Connections and No WiFi Connections are supported; Some WiFi Connections is
disabled. The maintainer reports physical-watch verification; repeat device
and live Sit(x) WebSocket checks for distribution builds.

## Protocol checks

Run these checks on macOS. They use mocked HTTP, in-memory tokens, and fake
outputs; they do not use real credentials or broadcast onto the LAN.

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  'WearTAK Watch App/AppSettings.swift' \
  'WearTAK Watch App/DashboardStatus.swift' \
  'WearTAK Watch App/RelayProtocol.swift' \
  'WearTAK Watch App/SitxCoT.swift' \
  'WearTAK Watch App/MulticastTAKTransport.swift' \
  'WearTAK Watch App/SitxClient.swift' \
  Tests/SitxProtocolChecks.swift -o /tmp/weartak-sitx-checks
/tmp/weartak-sitx-checks
```

Bridge/channel checks cover bounded XML framing, message correlation, channel
payload preservation, endpoint parsing and multi-server record persistence:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionEndpoint.swift \
  Shared/CompanionServer.swift Shared/TAKChannels.swift \
  Tests/BridgeProtocolChecks.swift -o /tmp/weartak-bridge-checks
/tmp/weartak-bridge-checks
```

`Tests/CompanionSecurityChecks.swift` also checks generated CSR signatures,
certificate/key matching, expiry and `.p12` import/password handling with
temporary test identities. It requires the resolved SwiftASN1 module linked
alongside CertificateStore and EnrollmentClient. No simulator or mock test
establishes physical-device background reliability or live server compatibility.