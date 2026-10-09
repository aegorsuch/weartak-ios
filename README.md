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

WearTAK is currently an early-development Apple Watch app. Join the beta through
[TestFlight](https://testflight.apple.com/join/UmM8AkNk).
GitHub source archives and simulator builds cannot be installed directly on a
physical Apple Watch. Do not treat this build's alerts as a safety service.

### Beta users: TestFlight

TestFlight is the recommended distribution route for users without Xcode.
Open the [WearTAK beta invitation](https://testflight.apple.com/join/UmM8AkNk)
on your paired iPhone. Build availability and tester capacity are managed in
TestFlight. The public invitation link normally stays the same across new
builds; it can stop working if the maintainer disables or replaces it.

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

#### Keep WearTAK easy to return to

No separate watch face is needed. To keep WearTAK as the app you return to
when you wake the watch:

1. On the watch, open **Settings > General > Return to Clock**.
2. Scroll down and select **WearTAK**, choose **Custom**, then select
  **After 1 hour** to use the longest return-to-clock timeout.
3. Open WearTAK again. While it remains the last app, raise your wrist or tap
  the display to wake the watch and return to it.

You can also find Return to Clock in the iPhone's **Watch app > My Watch >
General**. If the watch has already returned to its clock face, press the
Digital Crown and select WearTAK from your apps.

This setting delays returning to the clock; it does not pin WearTAK
indefinitely, keep the screen lit, or guarantee background execution.
watchOS still controls display sleep and app suspension. Sensor monitoring
and direct watch reporting stop when WearTAK is backgrounded, so reopening
it is still necessary. WearTAK does not currently include a watch-face
complication. See Apple's
[display and Return to Clock guidance](https://support.apple.com/guide/watch/adjust-the-display-settings-apd127ec93ac/watchos).

#### Build 12: tester message / What to Test

WearTAK 5.8.0 (12) includes draft Watch and Companion translations in all
36 supported languages: **Arabic, Bulgarian, Croatian, Czech, Danish, Dutch,
English, Estonian, Finnish, French, German, Greek, Hebrew, Hungarian,
Indonesian, Italian, Japanese, Korean, Latvian, Lithuanian, Malay, Norwegian
Bokmål, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish,
Swedish, Thai, Turkish, Ukrainian, Vietnamese, Simplified Chinese, and
Traditional Chinese**.

- Select your preferred app/device language and reopen both apps. Check menus,
  connection statuses, certificate-expiry notices, map role/team-color filters,
  and permission descriptions. Report incorrect wording, English labels that
  should translate, clipped text, and right-to-left layout issues.
- Check that filtering map roles and teams still hides/shows the intended users.
  Custom server text and TAK protocol abbreviations may remain unchanged.
- Test Bloodhound Remove All: it hides listed points only on this watch;
  server points and Data Sync map items should remain.
- Test a large Data Sync mission: up to 999 loaded items, 99 nearest drawn, and
  the mission still joined after restarting both apps.
- For locked-phone TAK relay testing, allow Companion Location **Always** with
  **Precise Location** on and keep phone location reporting running. Check
  wrist-raise reconnection and the warning shown when location settings are
  insufficient. Background delivery is not guaranteed.
- Include build number, watch/iPhone models, language, reproduction steps, and
  screenshots with feedback. The version label should include build 12 and
  revision `806f322`, rather than `unknown`.

#### Build 13: additional testing

Build 13 adds physiology/network admin controls and remote emergency alerts.
Test live alerts from another TAK device: alerts should appear first in
Bloodhound and as yellow warning triangles on the map. Check alert details,
silent navigation, In Position, sender cancellation, local dismissal, and stale
retention. Missing coordinates must disable navigation without hiding the alert
from the picker. Known manual alert categories
should translate (Injury is Lesión in Spanish); custom categories stay unchanged.
Check admin controls and reporting behavior on real paired devices.
Simulator demo alerts are excluded from release builds.

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

Runnable simulator builds need ad-hoc signing for Keychain access. Use
`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic` with
`xcodebuild` for simulator destinations. Unsigned builds can produce Keychain
error `-34018`; rebuild signed and reinstall without erasing simulator data.
Enroll or import certificates separately on the simulator and physical devices.

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
- The project uses Version `5.8.0`, Build `17`, with separate Apple-compatible
  version/build fields. Increment the build number for each subsequent upload.
- Create the matching app record in App Store Connect; provide beta contact
  information, privacy information/policy, screenshots, export-compliance
  answers, and any review instructions needed for Sit(x) authorization.
- Both apps set `ITSAppUsesNonExemptEncryption` to `NO` (iPhone in
  `WearTAKCompanion-Info.plist`, watch through its generated Info.plist), so
  App Store Connect skips the per-build encryption question. That matches the
  "None of the algorithms mentioned above" answer: all TLS, certificates and
  signing use Apple's Network/Security frameworks, and watch–phone transfer
  uses WatchConnectivity's built-in encryption. Revisit this if custom or
  third-party cryptography is added.
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

The current checkout includes its app-icon image and Version `5.8.0`, Build `17`.
The maintainer reports physical-watch verification. Public-beta distribution
still requires the signing team, approved capabilities/profiles, App Store
Connect setup, and TestFlight processing/review described above.

The container archive structure has been verified locally. A bare watch
archive can be signed correctly but still be rejected for App Store distribution
and fall back to Ad Hoc export, which asks for devices. Do not resolve that by
registering devices for TestFlight: use the container scheme and profiles above.
Unsigned packaging checks are not uploadable builds, and no upload or App Store
validation is implied by a successful local archive build.

### Build 6 release checks

Both app bundles include a privacy manifest declaring app-only UserDefaults
access (`CA92.1`) and no tracking. These required-reason declarations are not a
substitute for App Store Connect's App Privacy answers or the privacy policy.
Review collection disclosures based on the operated TAK/Sit(x) services and
their retention: transmitted positions, persistent TAK UID/callsign, messages,
point remarks, and opted-in physiological alert descriptions. Raw heart-rate
readings are used on the watch; they are not included in PLI messages.

Suggested ATS review explanation: WearTAK connects to user-configured TAK
servers, including administrator-managed private certificate authorities.
Their hostnames cannot be listed ahead of time in static ATS domain exceptions.
Companion uses HTTPS-only enrollment and Channels endpoints, TLS 1.2 or newer,
hostname and certificate-chain validation, approved CA anchors, and mutual TLS
for Channels. Redirects are rejected. The ATS exception does not bypass
certificate verification or add an HTTP fallback.

Before upload, verify on a physical paired phone/watch: enrollment and Channels;
incoming chat badge, haptic, read clearing and replies; dashboard point Drop
and Cancel, persisted title/remark and live server receipt; phone PLI with its
screen locked; alert interval activation and restoration after cancellation.
Watch reporting/chat reception is not guaranteed while the watch app is
backgrounded. ATAK and TAKX direct chat (incoming message, unread badge/read
clearing and replies) has been verified with the simulator and a live server.
WinTAK and other WearTAK peer interoperability remain unverified.
Archive validation, export-compliance answers, beta review credentials and
privacy disclosures still require App Store Connect/Organizer review. Commit
the tested source before the final archive so its embedded Git revision
identifies the released changes.

Apple references:
[TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
and [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Features

WearTAK is a watch-first TAK application for Apple Watch. It provides a MapKit
map, saved tactical points, Bloodhound navigation, manual alerts, physiological
and environmental monitoring, local TAK multicast, and direct Sit(x) connectivity.
App code lives in `WearTAK Watch App/`.

For a simulator-only crowded-map smoke test, launch the Debug watch app with
`--preview-crowded-map`. It opens a map with ten synthetic contacts, two nearby
points, and one isolated point. Tap the cluster to test the chooser and the
isolated point to test direct details. Network outputs are disabled using
temporary settings; synthetic items exist only in memory and expire after five
minutes. Relaunch without the argument to return to normal settings.

HealthKit supplies heart-rate readings; Core Motion supplies step activity,
relative altitude, and pressure where supported. Physiological sensing and
automatic alerts have separate preferences. Alert thresholds and durations are
configurable. The watch target requires the HealthKit capability when signing
for a device. Sensor monitoring and direct reporting stop in the background.
Position reports expire, and physiological values in them are marked
unavailable, after two reporting intervals plus 15 seconds. The BATDOK
preference controls whether PLI includes an `_atmist_` vital-sign element and
the `<biometrics>` block; it defaults on to match Wear OS.
Network Preferences can be locked from the developer-only Beta Features page;
the lock blocks its Settings and dashboard shortcuts.

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

The network icon gives a currently reachable paired phone priority over WiFi.
Otherwise it reflects the active WiFi, cellular, unavailable, or other network
path and opens Network Preferences. Phone reachability is independent of TAK
server health. A cellular path does not expose its radio generation or strength.
The TAK indicator above it shows multicast in multicast-only mode. A configured
server transport takes priority and shows the compact TAK logo with a small green
check for a confirmed server connection or red X when disconnected. Working
multicast does not turn a disconnected server's badge green. GPS stays at the
upper right.
The GPS icon is filled when watch location permission/services are enabled or
a reachable Companion confirms its phone location session is running. It is
crossed out otherwise; cached positions do not enable it. Phone status expires
with the live handshake. Tapping it opens Reporting Strategy settings.

The TAK indicator distinguishes multicast broadcasts, the Sit(x) cloud, and a
phone-relay icon. Green checks require a ready transport, not just an enabled
preference. Concurrent active multicast and Sit(x) outputs show both symbols.
A selected phone-relay provider does not imply a working connection. Companion
readiness requires a reachable watch/phone session and a confirmed live server
connection; iTAK and TAK Aware integration remains incomplete. The TAK indicator
also opens Network Preferences.

### Dropped markers

The dashboard point-drop button opens a radial Hostile, Neutral, Friendly,
and Unknown picker. Selecting a type opens a confirmation form at the current
location with optional Title and Remark fields, plus Drop and Cancel buttons.
Drop saves and sends the point; Cancel leaves saved points unchanged. A blank
title uses the existing callsign/UTC-time default. Missing location is reported
without creating a point. Tap the center X to
cancel, or hold it to open marker tools: Dropped Markers, Back, and Clear Last
Marker. Clear Last Marker removes the newest saved point after confirmation.

Dropped Markers shows each point's symbol, title, type, and local drop time.
Tap a row to reveal the three-dot button for the existing point editor and
the trash button for deleting that point. Clear All Markers removes all saved
points after confirmation. Incoming network entities remain on the map and
are not included in these local-marker deletion actions.

Map long-press starts with Unknown and then uses the most recently dropped or
changed marker type, remembered across launches. It immediately drops a point
at the pressed coordinate without prompting for a title or remark; tap the
dropped point to edit it. Dropping or changing a point
to Unknown restores Unknown as the default. Title/remark-only edits do not
change the default type.

Text fields use native watchOS entry. On Apple Watch SE 3, use Scribble,
dictation, or the paired iPhone's Apple Watch Keyboard notification. In
Simulator, enable Connect Hardware Keyboard to type using the Mac keyboard.

### Map Layers Menu

The self marker uses the selected team color. When the watch compass supplies
a valid heading, its arrow rotates with the watch orientation relative to the
map's camera heading. Without compass data it shows a colored dot; it does not
infer watch orientation from phone GPS or a cached position.

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

Every incoming user is drawn as a circular dot filled with its CoT
`__group name` team color, with a short role badge inside the dot. For
example, a Dark Green K9 user appears as a dark green dot labeled `K9`. Team
names match case-, space- and underscore-insensitively (`Dark Green`,
`dark_green`, `DarkGreen`); a missing or unrecognized team uses a gray dot.
Known roles use fixed badges (`TL`, `TM`, `HQ`, `K9`, `MED`, `RTO`, `SNP`,
`FO`, and LEO roles such as `ATL`, `CP`, `TOC`); other roles use up to three
initials, or the first three letters of a single word. A missing role leaves
the dot unlabeled. An event counts as a user when it is an `a-` event with a
`__group`, `takv`, contact `endpoint`, or ATAK `<uid Droid>` detail, or when
its type is `a-?-G-U-C?`, so a user is not shown as a pin, or left out of Team
Colors/Default Roles, because of its 2525 type (e.g. an ATAK `a-f-G` or
`a-f-G-E-V-C` self type). A later update for the same UID that omits
`__group`/contact detail keeps the last known team, role and callsign.
Other incoming `a-` events keep the hostile/friendly/unknown pin.

Below each user dot, a label such as `ODIN-ATAK ? 45s` shows the age of that
contact's last report. The age counts from the CoT event time, including for
positions restored from the Companion cache, and updates every second while the
map is open (`45s`, then `3m`, `2h`). No position is labeled live. After 60
seconds the dot dims, gets an orange ring, and its label turns orange.
VoiceOver reads the callsign, team, role, report age and stale state.
Incoming non-user pins show no age.

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
  Optionally enter a **Server Name** (for example, "Training"). Names appear in
  the phone server list and watch Channels/Data Sync pickers alongside the
  host and port, and lists sort by the displayed name. Leaving the name blank
  uses the host and port. Names can be edited while connected without restarting
  the connection; the server admin lock also locks name editing.
2. Enroll with the administrator's username/password or import a `.p12` file
  with its password. Saving a new server automatically enables it and attempts
  to connect; no separate switch tap is needed. If no client certificate is
  available, it remains enabled and reports that a certificate is required.
  Additional servers can be saved, edited, enabled independently, or removed
  with confirmation. Edit Server also has a Server enabled switch: turn it off
  to unlock address and authentication fields, including while a
  server is connecting or retrying. Locked address and authentication sections
  show Disable server to edit directly beneath their fields.
  Save changes before enabling again.
  The switch acts immediately on the saved server; Cancel discards form edits
  but does not undo enable/disable changes. Saving an existing server preserves the current switch
  state. The Watch status appears above the TAK Servers list.
  Each server row has a status dot (green connected, yellow connecting, red
  failed, gray off) and shows how long it has been connected or a
  plain-language error with the original error underneath. It also shows the
  client certificate expiry, in orange within 30 days or once it has expired.
  The ↻ button drops the stream and reconnects immediately instead of waiting
  for the 10-second retry. Open a server to see its full Status section at the
  bottom: connected-since time, the complete current error, the last error with
  its timestamp (kept after a reconnect), the certificate expiry, Reconnect Now
  and Copy Details, which copies a plain-text report to paste into a chat or
  ticket.
  An optional developer mode is enabled by tapping the version at the bottom
  of the main screen seven times. Its Beta Features page can lock server
  configuration, including Sit(x), while keeping connection status and
  reconnect controls available. This is an in-app editing safeguard, not
  authentication against someone with access to the phone.
3. On the watch, select Companion in Settings > Network Preferences > TAK
  Relay. Open the watch app while the paired phone is in range. A watch request
  can wake Companion for a short refresh while the phone is locked.
  Connected requires a successful mutual-TLS server connection, not just a
  saved certificate or Bluetooth pairing.

Enrollment uses HTTPS `8446` by default; an explicit HTTPS URL port overrides
that enrollment port, not the separately entered CoT stream port. Client
identities and import passwords are stored in endpoint-scoped Keychain entries.
Enrollment passwords are not persisted; renew by enrolling again. The UI
identifies whether an HTTP enrollment failure came from configuration or
certificate signing and shows the endpoint without query parameters or credentials.
Signing responses accept the required `signedCert` and optional `ca` or numbered
`caN` certificates, with the unnumbered CA first in the stored chain.
HTTP 401 means the endpoint rejected enrollment authorization; it is separate
from CoT stream TLS identity validation.
The UI reports certificate expiration and a renewal warning within three days.
Authentication shows "Certificate ready" after validation, "Save to finish setup"
for an unsaved certificate, and "Connected" only for a live server connection.
Password fields mask entered text but are cleared after enrollment; placeholder
dots are not used as a substitute for certificate or connection status.

TLS identities are managed in the background; Edit Server has no Advanced TLS
identity fields or manual inspection/approval controls. Existing saved stream
and API names are preserved when saving edits to the same endpoint. Changing
the endpoint clears those names so the new server can be discovered independently.
Stream identity affects hostname validation and TLS SNI on the CoT port;
API identity affects certificate hostname validation on HTTPS `8443` for
Channels, latest-position requests and Data Sync, not its URL, HTTP host or SNI.
Enrollment, certificate storage keys, CA trust, validity and mutual TLS remain
unchanged.

After enrollment/import and
enabling the saved server, a stream hostname-mismatch error automatically starts
certificate discovery when no TLS-name override is already saved. Channels,
latest-position and Data Sync do the same for API hostname mismatches.
For legacy private-CA TAK servers, a single exact DNS SAN is automatically saved
and the failed operation retried without a user prompt. Automatic inspection
restricts trust to the stored enrollment/import CA chain or explicitly configured
CA; publicly trusted certificates cannot use this fallback. Multiple exact names,
no supported SAN, missing/untrusted CA chains and expired certificates fail
explicitly and require administrator assistance. Previously saved identities are
not automatically replaced if validation later fails.

This default compatibility behavior deliberately substitutes CA-scoped server
identity for strict connection-hostname matching on the first legacy connection.
It does not prove that another server certificate issued by the same CA belongs
to the intended server. Administrators should provide a server-specific CA chain
or a matching hostname certificate, especially where a CA is shared with
other servers. No guessed names or credentials are sent by
inspection. API requests retry once; if a watch request times out during
discovery, refresh after the connection completes. Failed discovery is suppressed
until the server is disabled and re-enabled. Authentication errors, network
timeouts and other TLS errors do not trigger automatic identity changes.

Watch CoT is sent to all connected, enabled servers. An acknowledgement means
at least one server socket accepted the write, not that a remote TAK user
received it. Incoming CoT is forwarded to a reachable watch. Readiness is
confirmed by a live handshake and expires if confirmations stop. Direct Sit(x)
pauses only while Companion is actually ready; multicast remains independent.
The Companion's Watch status row shows "Paired" or "Not paired" using the phone's
watch pairing state, independently of whether the watch app is foregrounded.
Pairing status is not TAK server health or live-message availability.

### Phone GPS location reporting

Companion's **Background location reporting** section shows the current status
and a brief explanation. Expand **Details** for the location permission, last
position sent, any reason reporting is stopped, and a link to Location Settings.

There is no separate tracking switch. Companion starts reporting this iPhone's
GPS automatically when all of these are true: at least one enabled TAK server
has a client certificate, the paired watch has shared a verified WearTAK
identity, the watch's TAK Relay is Companion, Location Services are on, and
Companion has precise location access. The first start must happen while
Companion is open. iOS first asks for While Using access, then, once only, for
Always access. With Always, a watch request that wakes Companion can also
resume reporting in the background.

The position source is the phone's GPS, not the watch's. Reports are
`a-f-G-U-C` PLI using the watch's UID, callsign, team and role, with
`how="m-g"`, `precisionlocation` GPS and `takv` platform "WearTAK Companion".
The watch publishes this identity, plus its relay selection and reporting
intervals and combined manual/physiological/environmental alert state, through
WatchConnectivity application context whenever those
settings change, at session activation, and on watch app resume when the last
publish is over an hour old.
Companion verifies the UID and field bounds and rejects identities older than
seven days or dated more than five minutes in the future. It accepts identity
only from an activated session with a paired watch that has WearTAK installed.
Companion keeps no separate identity copy; WatchConnectivity persists the
latest context per paired watch, so switching watches cannot reuse another
user's identity. Companion never generates a phone UID. If the watch is
unavailable, the identity is missing or invalid, or the watch sends PLI with a
different UID, reporting stops and the reason is shown.

The interval follows the watch's Constant or Activity-based setting, chosen
from the phone's GPS speed, and is bounded to 10-600 seconds. While any watch
alert is active, the watch's While Alerting Reporting Interval overrides both
strategies, subject to the same bounds. Cancelling the last active alert restores
the normal strategy. Older watches without alert-state fields retain normal
Dynamic/Constant behavior. The phone's Wi-Fi battery multiplier is not applied.
Fixes are rejected if
they are invalid or `0,0`, have accuracy worse than 100 m, are older than 30
seconds, or are dated more than 5 seconds in the future. `time` is the send
time, `start` is the fix time, and `stale` is two reporting intervals plus
15 seconds, matching ATAK.
Phone GPS is preferred on the Companion relay. After a server accepts a phone
report, Companion suppresses the watch's own PLI for the same UID on that server
only, while the latest phone fix remains valid and the last accepted report is
within the interval plus 90 seconds. If phone GPS becomes stale or inaccurate,
reporting stops, or that server has no recent accepted phone report, watch PLI
is relayed again while the watch app is active and its relay is available.
This fallback cannot run while watchOS suspends the watch app, and cannot
bypass an unavailable Companion connection. Direct Sit(x) and multicast
continue using watch GPS. Watch alerts, alert cancels and dropped points are
always relayed. iTAK and TAK Aware do not supply WearTAK location or connectivity;
Companion requires its own permissions and TAK connection.

The watch's TAK Relay row shows only the selected provider; Companion's
Background location reporting section is the place to check phone reporting.
iOS shows a location indicator while Companion reports in the
background. The app uses the `location` background mode only for this active
location session; there is no workout session, silent audio or keepalive timer.
While reporting is active, server streams remain open and reconnect after
failures every 10 seconds. iOS still does not guarantee that sockets survive
network changes or suspension, and reports are not queued while disconnected.
Reporting stops when no enabled server has a certificate, location access is
revoked or reduced to approximate, Location Services are turned off, or the
identity becomes invalid. If access is While Using only, reporting can start
only while Companion is open. Force-quitting Companion, iOS terminating it,
or rebooting the phone stops reporting until Companion is opened again.

### Locked-phone map refresh

The foreground watch automatically requests a map refresh on resume and every
30 seconds while open. There is no connection-status or manual map-refresh
entry in Layers.
Live readiness confirmations run separately every five seconds, so a slow
snapshot request does not block the heartbeat or cause the 15-second readiness
deadline to expire. A missed confirmation still marks the relay unavailable.
WatchConnectivity can wake the iPhone app, which requests up to 25 seconds of
iOS background execution and reconnects enabled TAK streams. It requests
`/Marti/api/groups/all?useCache=true&sendLatestSA=true` to ask supported servers
to resend recent situational awareness, then returns a bounded map snapshot.
Streams stop when the background task expires and can reconnect on a subsequent
watch request. This short refresh task is separate from phone location
reporting and does not grant continuous background execution.

The watch's phone-link status rides out short drops. After a healthy reply, a
lost WatchConnectivity connection (phone locked, set down or switching
Bluetooth/Wi-Fi) shows an amber **Reconnecting…** badge for up to 45 seconds
instead of red; sends still require a fresh confirmation. On wrist raise the
watch checks immediately and shows **Checking…** for up to 10 seconds. When
Companion is backgrounded without phone location reporting, it tells the watch
the relay is paused and the watch shows **Phone paused – open Companion** with
the reporting reason. Turning on phone location reporting (Always permission)
keeps TAK streams running while the phone is locked. The status appears on the
dashboard TAK badge and under TAK Relay in Network Preferences.

Companion shows a **Keep watch connected** warning with an **Open Settings**
button whenever a TAK server is set up but Location isn't **Always** with
**Precise Location** on (or Location Services are off). The watch's paused
message names the same fix, for example "on iPhone, set Location to Always".

Both apps cache up to 50 incoming Companion events, with a conservative
256 KiB encoded-storage budget. Large XML details reduce how many events fit;
the oldest events are evicted first. This prevents watchOS from aborting the
app when a preferences value reaches its 1 MiB platform limit.

Incoming contact updates change the map immediately, but both apps batch cache
writes on a fixed one-second interval rather than writing on every event.
Pending writes flush when the app goes inactive (and when Companion's
background refresh ends). Source invalidation and snapshot saves remain
immediate. A sudden process termination can lose up to one interval of cached
updates; this cache is not the durable offline event outbox.

The watch displays cached positions immediately while refreshing. Cache replay preserves the original
CoT timestamp; reconnecting does not make an old position appear new. Entries
expire at the CoT stale time or after five minutes, whichever comes first.
Disabling/removing a server excludes its cached events on the next snapshot,
and channel changes invalidate that source's cached events. Snapshot payloads
are limited to 60 KB; truncation is recorded in the refresh error state.

The map and Layers menu do not display connection information. Incoming user
dots retain their age labels and stale styling. The map Back
button sits at the lower right, away from the upper-right Channels selector.
Failed refreshes leave unexpired cached contacts visible, not falsely labeled live. Local map
points and independent transports are not cleared by Companion restarts.

Compass sensing is owned by the active watch session, not individual screens.
Opening maps, sheets or point details cannot stop another screen's compass;
heading updates restart when the app resumes or location permission is granted
and stop when it backgrounds. Hardware without a compass, denied location
permission, or invalid sensor accuracy can still make headings unavailable.

Install matching phone/watch builds for snapshot support. The phone must be
in range, unlocked at least once after restarting for Keychain access, and
allowed by iOS to run. Force-quitting Companion, unavailable connectivity,
background-time expiration, or an unsupported/failing server SA API can prevent
a fresh snapshot. Test locked-phone and wrist-down/resume operation on paired
hardware; simulator tests cannot guarantee background wake-up. There is no
guaranteed continuous background relay, emergency-alert delivery, or durable
offline PLI replay.

### Map contact actions

Tap an incoming user dot to open its contact panel. Latitude, longitude and MGRS
appear first, followed by Start Chat and Bloodhound to Contact. Bloodhound uses
the contact's latest received position as it moves, shares the dashboard
direction/range and map line with point navigation, and stops when the contact
expires. Selecting a local point instead replaces the contact target.
The contact panel omits team, role and last-seen text; contact expiry still applies.

### Incoming points (RGR / nPos)

Each newly received live (non-user) point plays a haptic and adds a red count
badge to the dashboard Compass button; opening Compass clears it. Compass lists
incoming points with affiliation and range. Data Sync mission items are not
listed, notified or counted here; they stay on the map. Tapping one offers **RGR** (start
Bloodhound and send "Roger, bloodhounding to TITLE"), **Remove** (hide the point
on this watch) or **Cancel**. **Remove All** at the top of the list hides all
listed points on this watch. During that Bloodhound, **nPos** stops navigation,
removes the point and sends "In Position at TITLE".

Active CoT emergency alerts from other devices appear above ordinary incoming
points, newest first, with a yellow warning triangle, sender callsign/identity,
emergency category, range when available, and **Stale** status. The map and
picker use the same emergency state, deduplicated by CoT alert UID while keeping
ownership by each ingress source. Ordinary contact/point visibility filters do
not hide alerts. ATAK's reused `*-9-1-1` UIDs, standard `b-a-o` descendants,
`b-a-o-can`, and `<emergency cancel="true">` / `cancel="1"` are supported.
The watch suppresses its own emergencies.

The CoT stale deadline marks an alert **Stale**, not ended. Already-stale
emergencies are accepted as last-known reports; a newer fresh location update
clears Stale. Stale coordinates are explicitly labelled **Last-known location**
in details and navigation, with their location-update time in details.
Location-less updates can retain the same source's last valid coordinates, but
cannot make those coordinates live again. Without usable coordinates, the
alert remains readable in the picker, with no map marker or navigation action.

An explicit sender cancellation removes the emergency and stops its Bloodhound
navigation, without removing the sender's ordinary contact or unrelated points.
Ordering and cancellation records persist across restarts: delayed older
packets cannot resurrect a cancellation, but a genuinely newer activation may
reuse the same UID. Disconnecting/removing a source clears only its copies;
another owning source keeps the alert visible.

**Missed-cancellation limitation:** if cancellation is never received, an alert
can remain visible indefinitely, until **Dismiss locally** or applicable source
cleanup. Stale does not mean the emergency ended, and these alerts are not a
safety service.

Recognized manual alert categories use translated labels in the picker and
point details (for example, Injury becomes Lesión in Spanish); custom incoming
categories and CoT values remain unchanged.
Tapping either an alert's map triangle or picker row opens the same details.
**Bloodhound to Alert** starts navigation without an acknowledgement, automated
chat, assignment, or emergency cancellation. **nPos** stops navigation without
messaging or hiding the alert. This is not houndmaster behavior.
**Dismiss locally** hides the ongoing emergency from both surfaces, transmits
nothing, and persists across restarts and newer active refreshes. Only sender
cancellation at or after the latest observed update ends that dismissal; a
subsequent newer activation can reappear. A delayed older cancellation cannot
reset dismissal. **Remove All** still applies only to ordinary incoming points.
New emergency UI strings use the existing WatchMain catalog, with draft
translations in Arabic, French, German, Japanese, Spanish, and both Chinese
variants; other locales fall back to English for these new strings.

Diagnostics: watch OSLog category `RemoteAlerts` records CoT ingress byte counts,
parsed entity counts and specific parser rejections; `GeoChat` records emergency lifecycle outcomes
(`accepted`, `cancelled`, `dismissed`, `ownAlert`, `outOfOrder`, `invalid`) and
obsolete/disconnected-source rejection. No ingress log means no packet reached
the parser; a parse log with zero accepted entities means packets arrived but
were rejected or were not supported map entities. Include debug-level logs when
investigating missing alerts.

#### Supported languages (36)

The Watch app and WearTAK Companion localize their interface, common status
messages and permission descriptions in Arabic, Bulgarian, Croatian, Czech,
Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hebrew,
Hungarian, Indonesian, Italian, Japanese, Korean, Latvian, Lithuanian, Malay,
Norwegian Bokmål, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian,
Spanish, Swedish, Thai, Turkish, Ukrainian, Vietnamese, Simplified Chinese and
Traditional Chinese. The app follows the device's preferred language.

The translations are drafts marked for review and are intended for TestFlight
feedback. User-entered and server-provided content, TAK protocol values, and
some system or server error details remain in their original language.
Known TAK team colors and roles also use translated display labels in map
filters; custom server values and persisted filter keys remain unchanged.
Companion localizes server connection summaries and elapsed-time units.
Certificate-expiry notices also use translated wording, localized dates and
localized day counts, without changing the 30-day warning threshold.
The watch version label includes the build number and a Git revision bundled
as a resource, independently of Info.plist generation.

A point the sender deliberately sends again (a newer CoT `time` on a
human-entered `how="h-…"` point) notifies again, even if it is already listed
or was removed. Reconnect replays with the same `time` and machine-generated
track updates stay silent. Sit(x) portal markers (`<takv device="Map Marker"/>`)
and other points with a `p-p` sender link count as points, not users.

Replies go to the point's `link relation="p-p"` UID, which is the original
creator. ATAK keeps that link when re-sending another user's point, so replies
reach the creator, not the re-sender. If the creator is not currently visible,
the reply is sent immediately through the point's source and queued in memory;
it is resent with the same message ID when that user's PLI arrives (up to 24 hours,
lost if the watch app restarts).

Contact chat uses GeoChat CoT through the contact's source: Companion, local
multicast or standalone Sit(x). Companion sends through that contact's
source server only, never across all enabled servers. Multicast sends on the
shared local network with the recipient UID in the message; it is not private
point-to-point transport. A successful send means the transport accepted the
message, not confirmed recipient delivery.
Replies addressed to the watch UID appear in the matching source/contact
conversation. Conversations are in-memory and bounded to 50 contacts with 50
messages each. The dashboard Chat button shows the total unread count; the inbox
lists conversations with per-conversation counts. Opening an active conversation
marks it read. New unread incoming messages trigger a haptic when Chat is enabled.
These are in-app notifications while the watch app receives messages, not system
notifications or guaranteed background delivery. Companion keeps a five-minute
in-memory GeoChat retry buffer (32 events, 40 KB of XML), returned on watch
handshakes as well as attempted live delivery. Inbox deduplication prevents
repeated unread notifications. Disabled/removed server entries are pruned;
overflow evicts oldest events and is logged. Phone restart clears the buffer.
Quick Messages (Roger, Negative,
Objective Sighted, In Position) fill the draft; Send is still required. Known
conversations remain replyable without a current map contact, using their original
source. Unknown or unavailable sources show an explicit unavailable message;
live ATAK interoperability still needs paired-device/server testing.

The dashboard metric uses smaller, single-line, scaling text and a smaller
icon to preserve the full exertion percentage on small watch screens.

### Map Channels

The connected-nodes button at the watch map's top right opens Channels; Layers
remains top center. Choose an enabled Companion server to load its assigned
channels, then toggle membership on the watch. Refresh reloads the server state.
When no server is available, the menu shows "Connect to a TAK Server to configure channels."
Selections are shown only after the server confirms them. Empty, unsupported,
disconnected, and request-failure states are displayed explicitly.

Companion performs the mutually authenticated HTTPS requests on port `8443`:
`GET /Marti/api/groups/groupCacheEnabled`,
`GET /Marti/api/groups/all?useCache=true&sendLatestSA=true`, and
`PUT /Marti/api/groups/active?clientUid=<watch UID>`. Updates preserve the full
group payload and change matching IN/OUT records together. Confirmed membership
changes advance that server's map-source generation; stale entries from that
source are cleared without clearing local points or other-source entries.
Companion restarts reset source generations and channel listings while retaining
unexpired Companion positions with their original timestamps.

The Channels API uses HTTPS port `8443`, independently of the displayed CoT
stream port (normally `8089`). Request failures identify the API endpoint and
underlying error code; certificate-validation failures also include the trust
error when available. Both stream and Channels TLS verify the hostname and
certificate chain. An explicitly configured server CA restricts trust to that
CA; otherwise the client certificate's CA chain supplements system trust roots,
allowing an API listener with a publicly trusted certificate. Invalid configured
CA data is reported rather than silently ignored. Client-certificate challenges
are handled at both the URLSession session and task levels.

Enroll or import a client certificate (`.p12`) to access Channels. Successful
enrollment stores the client identity and CA chain; no additional `.p12` import
is needed. The server must support Channels and authorize the account.
Companion opts out of ATS's additional restrictions to support private CAs on
user-configured server names, which cannot be enumerated in a static domain
exception list. Enrollment and Channels still construct HTTPS-only URLs, require
TLS 1.2 or newer, validate certificate trust and hostname, and reject redirects.
Never trust a CA simply because an unauthenticated server supplies it.
Enrollment initially requires system trust (including an administrator-installed
trusted CA profile) or an explicitly imported server CA. After verified enrollment,
the stored CA chain supplements system roots for Channels and stream TLS.
This app-wide ATS exception requires App Store justification; any future
Companion URLSession requests must preserve the same safeguards.

Channels requires a TAK server supporting these group APIs. Multicast,
standalone Sit(x), iTAK and TAK Aware do not currently expose this channel menu's
server operations. Protocol checks and combined builds cover local behavior;
paired-device channel and CoT interoperability still require live verification.

### Data Sync missions

Open Settings → Tool Preferences → Plugins → DataSync, choose a server, then
toggle its feeds (missions) to subscribe or unsubscribe. Map Channels stay on
the map's top-right button. Subscribed mission items appear on the map and keep
updating from the live stream. Incoming points, including mission items, use
2525D affiliation frames from their CoT type: friendly or assumed friend is a
cyan rectangle; hostile, suspect, joker or faker is a red diamond; neutral is a
green square; unknown or pending is a yellow quatrefoil. Types that aren't
2525D symbols (for example `b-m-p-*` spot markers) remain yellow pins. Each server row shows how many missions are
subscribed or its current state; Refresh reloads the list.

Companion performs the requests on the watch's behalf. TAK Server uses the
client certificate on HTTPS port `8443` (`GET /Marti/api/missions`,
`PUT`/`DELETE /Marti/api/missions/<name>/subscription?uid=<watch UID>`,
`GET /Marti/api/missions/<name>/cot`). Sit(x) uses the same mission API under
`/api/v1` with the Sit(x) token. Subscriptions use the watch UID, so the server
delivers mission traffic over the watch identity's existing stream.

Mission items stay on the map while the mission is subscribed, regardless of
CoT stale time (like ATAK). Without this, older mission events would disappear
right away under the 5-minute live-contact rule. Items are refreshed quietly
at most once every 60 seconds after a map refresh. That refresh adds new items,
removes deleted ones and drops missions that were unsubscribed or deleted. The
watch keeps up to 40 missions per server and 999 items per mission and in total.
When a mission has more, Companion keeps the 999 nearest the watch's position
(it parses up to 5,000) and the mission row says "Showing nearest 999 of N
items". Items that don't fit in the first 60 KB phone-to-watch message are paged
in afterwards (`missionItemOffset`), roughly 200–300 items per page. Mission
items are saved in a file (`DataSyncMissions.json` in Application Support)
rather than UserDefaults, so they don't push the watch toward the ~1 MB
UserDefaults limit. The map draws only the 99 items nearest you, plus a
Bloodhound target. That set refreshes when the map opens, after you move 100 m
and when mission items change. Password-protected missions are listed but
can't be subscribed.

Joined missions persist across restarts of both apps: Companion saves each
server's subscribed mission names and the watch saves the items. On each sync,
Companion checks the watch UID's subscription and quietly re-subscribes if the
server dropped it, for example after a reconnect. A joined mission missing from
one mission listing keeps its saved items; it's forgotten only when the server
returns HTTP 404 for that mission.

Tap a DataSync item on the map to open the same Point Details as a dropped
marker: title, type, time, a Mission field naming its DataSync mission, remark, bearing, distance and coordinates.
It also offers Bloodhound to Marker, Change Title, Add/Change Remark, Change
Marker, Move to Current Location and Delete Marker. Companion reads the watch's
mission role (`GET .../missions/<name>/subscription?uid=<watch UID>`). Edits
are allowed with `MISSION_WRITE` and disabled for read-only roles. Every edit
and delete asks for confirmation first, because it changes the mission for
everyone subscribed. A confirmed edit is
sent to the mission's server as CoT with the item's UID and
`<marti><dest mission="<name>"/></marti>`, so the server updates the mission
and its subscribers. Edits keep the title, type, position and remark; other
CoT detail on the original item (custom icons, colors, links) isn't preserved.
Delete Marker removes the item from the mission for every subscriber
(`DELETE .../missions/<name>/contents?uid=`). Other received points open the
same screen with Bloodhound and Delete Marker, which hides them on this watch only.
Mission items also show "Mission: <name>" in point details. Mission invitations and change notifications
aren't handled yet. Subscribe and mission items were verified live on TAK
Server; Sit(x) listing works, but its subscribe and items requests haven't been
verified because the test account has no missions.

## TAK SA Multicast

Open Settings > Network Preferences > TAK SA Multicast. The entry appears
above Sit(x) TAK and shows Enabled or Disabled. Multicast defaults to Enabled;
an explicitly saved Disabled selection is preserved.
The submenu contains a toggle, Address, Output Protocol, Port, and Back.
Defaults are `239.2.3.1`, `UDP`, and port `6969`.

The address must be an IPv4 multicast group in `224.0.0.0/4`; the port must be
between 1 and 65535. Output is CoT XML over UDP. TCP is not offered because it
cannot send to an IP multicast group. The transport joins the selected SA group
plus ATAK GeoChat (`224.10.10.1:17012`) and direct CoT
(`224.10.10.1:6969`) on the watch's WiFi interface, without duplicate joins when
the configured endpoint matches one of these. GeoChat sends to the chat endpoint;
PLI, alerts, and points send to the configured SA endpoint. Only multicast PLI
copies advertise `224.10.10.1:17012:udp`; server PLI keeps its existing endpoint.
Reception accepts XML and TAK Protocol v1 (`bf 01 bf`) protobuf datagrams,
including typed contact/team/device details and opaque emergency/chat XML.
Unknown protobuf fields are skipped; malformed packets, unsupported versions,
and DTD/entity declarations are rejected with diagnostics. Control-only TAK
messages are not map events. Transmission remains XML.
The watch displays incoming nonexpired users/points and retained remote
emergencies using their shared lifecycle. Enabled means the
preference is on, not that delivery is confirmed. UDP has no receiver
acknowledgment. Runtime diagnostics are hidden by default. Tap the version
number at the bottom of watch Settings seven times to enable Developer mode.
The unlock shows only "Developer mode enabled" and persists across launches; turn off
Developer mode in Settings or at the bottom of the multicast diagnostics to
hide diagnostics again. Leaving Settings resets an unfinished tap sequence.
Developer-only controls appear at the bottom of their respective menus, below
normal settings. In multicast, the Runtime Status section shows readiness/errors, local
datagrams sent/received since launch, the last local send time/error, and the
stored-event count. Receive errors appear alongside send errors; OSLog category
`Multicast` logs the ingress endpoint, byte count, and decoder rejection reason.
Android multicast locks and network requests are not applicable to watchOS;
Apple's existing WiFi-only Network.framework transport remains in use.
A successful local send is not receiver confirmation;
use a separate TAK receiver to validate the watch-to-LAN path.

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

When Sit(x) is configured in Companion, the watch shows the phone's enabled
state, address, selected group and connection status. These phone-managed
settings are read-only on the watch; edit them or reauthorize in Companion.
Credentials are not copied to the watch. The last received settings are saved
on the watch across app restarts and refreshed when the devices reconnect.
When Companion is unreachable, the watch shows Needs iPhone: syncing settings
does not enable standalone Sit(x) WebSocket streaming on physical watchOS.

Sit(x) setup on both the watch and Companion ends with Remove Sit(x) connection.
After confirmation, it stops streaming, turns Sit(x) off, and clears saved
authorization, address and group settings; new setup requires authorization
again. Watch removal also removes the phone-held relay without returning its
refresh token and requires a reachable Companion when the phone owns the connection.
Companion removal clears its local connection and device-authorization identifier.
This removes local configuration, not the Sit(x) account or organization.

### Setup

Sit(x) can be set up on the watch or in WearTAK Companion on the iPhone. Both
use the same steps and menu. A physical watch streams Sit(x) through Companion
either way (see below), so setting it up on the phone is often simpler: the
authorization link opens directly in Safari and the code can be copied.

1. On the watch, open Settings > Network Preferences > Sit(x) TAK. On the
   phone, open Companion and tap Sit(x) TAK.
2. Set Address to the organization name. For example, `team` becomes
   `https://team.sitx.io`. An existing `.sitx.io` suffix is not duplicated.
3. Turn on Sit(x) TAK and approve the device using the code and authorization
   link in the authorization sheet. Eight-character codes are shown as
   `XXXX-XXXX`.
4. Select Group. A single permitted group is selected automatically; the
   selection is remembered across launches.
5. Wait for Sit(x) State to show Connected. This means the authenticated TAK
   WebSocket has responded, not just that authorization succeeded. Linked
   Account below it shows the Sit(x) account email (or callsign) from the
   device token, prefixed `NPE ·` for non-person-entity access, or `NPE`
   when the device is not linked to a person account.

The menu order is Sit(x) TAK toggle, Address, Group, Sit(x) State, Linked
Account, Re-auth, Back
(Companion uses the standard iOS back button, and the Group list can be pulled
to refresh).
The Network Preferences entry shows Sit(x) TAK with the current state below it.
Off stops Sit(x) delivery while preserving credentials and the selected group.
Re-auth discards the old credentials and starts a new device authorization.
It is greyed out while Sit(x) State is Connected; use Remove Sit(x) connection
to switch accounts.
Changing the address also invalidates the previous organization's credentials.

### Connection protocol

- POST `/api/v1/device/authorization/code` with the device scope and client ID.
- Poll POST `/api/v1/device/authorization/token` with the device-code grant.
  Respect the server's polling interval, `authorization_pending`, `slow_down`,
  and expiration responses.
  On iPhone and watch, transient connection loss, timeout, connectivity, or DNS
  failures allow up to three additional polls per authorization attempt, with
  5/10/20-second backoff (never shorter than the server's polling interval).
  The state shows "Retrying authorization" with the network error while waiting.
  Polling stops on cancellation, code expiry, definitive rejection, or exhausted
  retries. This recovery applies only to device-code polling, not requests that
  rotate refresh tokens, and does not bypass WiFi/VPN restrictions.
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
- After connecting, GET `/api/v1/messages?tak_group_tag=<flow_tag>` returns
  GeoChat and other CoT that Store and Forward held while the device was
  offline. Unacknowledged, unexpired messages for the group (up to 50, oldest
  first) are delivered like live CoT, then acknowledged with PATCH
  `/api/v1/messages/<resource_uid>`. Duplicate chats are dropped by the inbox.
- Token responses carry `sequestered_status`. Any value other than
  `not_sequestered` means the device is authenticated but muted, so the client
  does not stream and shows the reason instead (device limit, activation
  required, administrator approval, or organization connection limit),
  retrying every 60 seconds.

The client stores credentials in Keychain, refreshes them on reconnect, and
retries transient network failures while the app is active. Transient failures
do not erase authorization. Connected is shown only after the socket responds.
HTTP failures show the server's `error_description`/`message`/`detail`/`error`
text when present, for example `HTTP 406: <reason>`. OAuth error codes
(`access_denied`, `expired_token`, `invalid_grant`, `invalid_client`,
`invalid_scope`, `invalid_request`) are shown in plain language.

### Streaming through WearTAK Companion

watchOS blocks WebSockets on Apple Watch hardware for apps that are not audio or
VoIP apps ([TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)).
HTTPS still works, so authorization and group listing run on the watch, but
the live stream fails with `-1009`. The simulator does not enforce this.

When the iPhone is reachable, the watch hands its Sit(x) session to WearTAK
Companion after a group is selected:

- The watch sends the host, group `flow_tag`, group name, and refresh token.
  Companion stores the token in its Keychain and opens the Sit(x) WebSocket.
- Sit(x) rotates refresh tokens, and reusing an old one invalidates the whole
  token family. So only one device holds the token at a time: the watch
  deletes its copy once Companion accepts it.
- Sit(x) then acts like another Companion TAK server. Incoming PLI, points
  (including 2525 points for Compass/RGR), alerts, and GeoChat reach the watch.
  Outgoing PLI (watch and phone GPS), alerts and cancellations, points and
  deletions, and chats go out over Sit(x).
- Sit(x) State shows `Via iPhone: <phone status>`. Companion's Sit(x) TAK
  page shows the handed-over address and group.
- Turning Sit(x) Off on the watch stops the phone stream and returns the
  refresh token to the watch. Re-auth discards the relayed token. Changing the
  group updates Companion without re-sending a token.

When Sit(x) is set up in Companion, the phone runs its own device authorization
and owns the refresh token; the watch holds no Sit(x) credentials. Companion
reports this through its application context, so the watch relays through
the phone even when another TAK relay is selected, and its Sit(x) State shows
`On iPhone: <phone status>`. Turn it Off, change Address, or Re-auth in
Companion. Setting Sit(x) up on the watch later replaces the phone's
authorization (the most recent setup wins). Companion runs token requests one at
a time so a rotated refresh token is never reused.

Without a reachable Companion, a physical watch shows `Live stream needs WearTAK
Companion; watchOS blocks direct Sit(x) streaming` (menu: Sit(x) Needs iPhone)
instead of retrying.

### Delivery and shared reporting

PLI includes a stable device UID, position, callsign, team, role, and CoT
time/start/stale fields. It is an `a-f-G-U-C` event with ATAK contact detail:
`<contact endpoint="*:-1:stcp">`, `__group name/role`, `<takv platform="WearTAK"
device="Apple Watch">`, and `<uid Droid>`. A blank callsign is sent as
`WEARTAK-<first 8 UID characters>` and a blank role as `Team Member`, so
receivers never get an unnamed or roleless contact. The same XML goes to every
ready output: WearTAK Companion (relayed unchanged to each connected TAK
server), multicast, and standalone Sit(x) when the phone is unreachable. Both multicast and standalone Sit(x) use the reporting
controls. Dynamic Reporting defaults to 3600 seconds stationary, 60 seconds on
foot, 60 seconds in a vehicle, and 10 seconds while alerting. Constant Reporting
defaults to 60 seconds. Save Battery on WiFi multiplies the selected interval
by six on qualifying WiFi connections.

PLI also carries the watch's vitals in the same format as WearTAK for WearOS:
`<remarks>Exert:47%;HR:88</remarks>` plus
`<biometrics><device><model>WATCHOS</model><uid/><hr/><exert/></device></biometrics>`.
Exertion is heart rate as a percentage of age-predicted maximum. Apple Watch
does not capture skin temperature, so it is omitted. Heart rate and exertion
are `N/A` when missing or more than five minutes old. Companion's
phone-GPS PLI carries the same block using vitals the watch shares through
application context (at most every 30 seconds). Alert events include the
`<biometrics>` device block with `alertUid`, `alertState`, `alertCategory`,
`alertPriority="1"` and `alertDescription` attributes.

Manual, physiological, and environmental alert activations and cancellations,
point updates, and point deletions send independently of the PLI timer. Alert
picker choices are alphabetized by their displayed labels and include 911 Alert,
Gate Runner, Geofence Breached, Gunshot, Gunshot Injury, In Contact, Injury,
Ring The Bell, UAS, and Vehicle. Received emergency categories preserve those
same names; Geofence Breached is a manual alert, not automatic geofence monitoring.
Alert activation
and cancellation events share an alert UID; cancellations use `b-a-o-can` and
`<emergency cancel="true">`. Point deletion uses `t-x-d-d`, a link to the point
UID, and `__forcedelete`. Incoming nonexpired CoT users and points appear on
the map, excluding the watch's own PLI and locally saved points.

Failed Sit(x) alert/point events are retained in a bounded in-memory queue and
retried after reconnect. Cancellation supersedes a queued activation. Queued
events do not survive app termination and are discarded when Sit(x) is turned
Off, its address changes, the destination group changes, or Re-auth starts.
The watch persists a shared offline outbox for markers (including location-
pending drops), marker edits/deletions, manual/automatic/environmental alerts
and cancellations, and outgoing GeoChat/point replies. PLI is not backlogged.
Routine queue-storage and transport-acceptance updates do not show pop-ups on
the watch home screen. Errors and expiry warnings remain visible. The marker
confirmation screen explains deferred storage. A drop without a fresh valid fix
keeps its title/type/remark and original UID, then uses the next fresh watch
location. It does not claim that the eventual coordinates were the drop
location.

The outbox survives app restarts, holds at most 200 operations/1 MB, and expires
unsent operations after 24 hours with a visible warning. New edits/deletions
replace the same marker's pending state; alert cancellations replace pending
activations. Chat keeps its original XML/message ID, recipient, and source
route/server. Events wait if the network configuration changes rather than
being silently redirected to a different group or multicast endpoint.
Queue-full/storage errors are displayed; failed transport attempts remain
queued for retry while the watch app is active. Foreground retries run at most
once per five seconds. A location-pending marker becomes a normal saved map
marker once a valid fix arrives.

An operation is removed only when a transport accepts it. This is not a
recipient acknowledgement: multicast UDP can be lost even after a successful
send, and Companion acceptance is not proof that another TAK user received it.
Multicast does not retry datagrams after local transport acceptance. Offline
mission edits/subscriptions remain unavailable because they require current
server permissions; Data Sync is not replayed from this outbox.

### Limitations

Watch reporting is foreground-only; continuous screen-off/background watch
tracking is not implemented. Background PLI is available only from the phone's
GPS through Companion, as described in Phone GPS location reporting. Direct Sit(x) pauses only when the optional Companion transport is
confirmed ready. Physical Bluetooth pairing alone is not proof of relay
readiness. GeoChat sends are transport-accepted, not recipient delivery receipts.

watchOS cannot identify connected WiFi SSIDs or list saved networks. All WiFi
Connections and No WiFi Connections are supported; Some WiFi Connections is
disabled. Direct watch Sit(x) streaming works only in the simulator; physical
watches need the Companion relay above. Repeat device and live Sit(x) checks
for distribution builds.

## Protocol checks

Run these checks on macOS. They use mocked HTTP, in-memory tokens, and fake
outputs; they do not use real credentials or broadcast onto the LAN.

After building Companion (including the embedded Watch app), check that the
localized status/filter resources and revision stamp are actually packaged:

```sh
xcrun swiftc -parse-as-library Tests/LocalizationResourceChecks.swift -o /tmp/weartak-localization-checks
/tmp/weartak-localization-checks "/path/to/WearTAK.app" "$(git rev-parse --short=7 HEAD)"
```

The Foundation-only outbox checks can also run with Swift on Windows:

```powershell
swiftc -parse-as-library Shared\OfflineOutbox.swift Tests\OfflineOutboxChecks.swift -o "$env:TEMP\weartak-offline-checks.exe"
if ($LASTEXITCODE -eq 0) { & "$env:TEMP\weartak-offline-checks.exe" }
```

The shared device-authorization retry checks also run on Windows. They cover
the exact backoff, retry budget, server polling minimum, error classification,
and visible retry status:

```powershell
swiftc -parse-as-library Shared\SitxShared.swift Tests\SitxAuthorizationRetryChecks.swift -o "$env:TEMP\weartak-sitx-retry-checks.exe"
if ($LASTEXITCODE -eq 0) { & "$env:TEMP\weartak-sitx-retry-checks.exe" }
```

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  'WearTAK Watch App/AppSettings.swift' \
  'WearTAK Watch App/DashboardStatus.swift' \
  'WearTAK Watch App/WatchSettingsLabels.swift' \
  'WearTAK Watch App/RelayProtocol.swift' \
  'WearTAK Watch App/SitxCoT.swift' \
  'WearTAK Watch App/MulticastTAKTransport.swift' \
  'WearTAK Watch App/SitxClient.swift' \
  Shared/BridgeWire.swift Shared/CompanionMapSnapshot.swift Shared/TAKMulticast.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChat.swift Shared/SitxShared.swift \
  Shared/PhoneLocationReporting.swift Tests/SitxProtocolChecks.swift -o /tmp/weartak-sitx-checks
/tmp/weartak-sitx-checks
```

The Sit(x) protocol checks include mocked connection loss during device
authorization, successful group discovery after retry, visible retry status,
and expiry/cancellation while waiting to retry.

Remote alert checks cover ATAK/WearTAK formats, parent links, own-alert suppression,
already-stale and location-less events, cancellation flags and compatible relay
decoding. The Foundation-only lifecycle runner checks duplicate sources,
out-of-order delivery, stale retention/refresh, missing/retained locations,
persistent cancellation and dismissal, and cancel/reactivate with reused UIDs.
The existing simulator load test checks consistent map/picker state, source
cleanup, silent navigation/In Position, and preservation of ordinary contacts.
Companion map checks include retained stale/location-less alert snapshots.

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/RemoteAlertLifecycle.swift \
  'WearTAK Watch App/RelayProtocol.swift' 'WearTAK Watch App/SitxCoT.swift' \
  Tests/BloodhoundAlertChecks.swift -o /tmp/weartak-alert-checks
/tmp/weartak-alert-checks
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/RemoteAlertLifecycle.swift Tests/RemoteAlertLifecycleChecks.swift \
  -o /tmp/weartak-alert-lifecycle-checks
/tmp/weartak-alert-lifecycle-checks
```

Both alert runners also work with Swift for Windows:

```powershell
swiftc -swift-version 5 -parse-as-library Shared\RemoteAlertLifecycle.swift 'WearTAK Watch App\RelayProtocol.swift' 'WearTAK Watch App\SitxCoT.swift' Tests\BloodhoundAlertChecks.swift -o "$env:TEMP\weartak-alert-checks.exe"
& "$env:TEMP\weartak-alert-checks.exe"
swiftc -swift-version 5 -parse-as-library Shared\RemoteAlertLifecycle.swift Tests\RemoteAlertLifecycleChecks.swift -o "$env:TEMP\weartak-alert-lifecycle-checks.exe"
& "$env:TEMP\weartak-alert-lifecycle-checks.exe"
```

Multicast interoperability checks use the same standalone Swift runner pattern.
They cover SA/chat/direct-CoT endpoint selection and deduplication, multicast-only
UDP PLI identity, XML and TAK v1 decoding, typed/opaque detail precedence,
control-only messages, unknown fields, malformed packets and entity rejection.

```powershell
swiftc -swift-version 5 -parse-as-library Shared\RemoteAlertLifecycle.swift Shared\TAKMulticast.swift 'WearTAK Watch App\RelayProtocol.swift' 'WearTAK Watch App\SitxCoT.swift' Tests\TAKMulticastChecks.swift -o "$env:TEMP\weartak-multicast-checks.exe"
& "$env:TEMP\weartak-multicast-checks.exe"
```

On macOS use the equivalent `xcrun swiftc` command with POSIX paths. A native
watchOS build and physical-watch LAN test are still required to verify actual
Network.framework multicast delivery, including chat and TAK v1 packets.

Bridge/channel checks cover bounded XML framing, message correlation, channel
payload preservation, endpoint parsing and multi-server record persistence:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionEndpoint.swift \
  Shared/CompanionServer.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChannels.swift \
  Tests/BridgeProtocolChecks.swift -o /tmp/weartak-bridge-checks
/tmp/weartak-bridge-checks
```

Map cache/snapshot checks preserve CoT timestamps and expiry, invalidate
sources, reset bridge generations, and enforce 50-contact/60 KB snapshot and
256 KiB storage bounds, including large XML details and JSON escaping.
They also exercise a 5,000-contact burst and repeated updates. Map events parse
their immutable XML header once, including on cache restore, rather than
reparsing every contact during sorting and pruning. This reduces high-traffic
cache work on both the phone and watch without changing the saved-data format
or contact limit; it does not establish the cause of a device crash:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Tests/CompanionMapChecks.swift \
  -o /tmp/weartak-map-checks
/tmp/weartak-map-checks
```

The Debug simulator watch app also supports an isolated receive-path stress
test. After building, run:

```sh
python3 Tests/run_watch_load_checks.py "/path/to/WearTAK Watch App.app" \
  --artifacts /tmp/weartak-watch-load
```

The runner creates, boots and deletes a temporary unpaired SE 3 simulator
(watchOS 26.2 by default; override with `--runtime`). It never uses the paired
test watch or sends synthetic traffic to a real server. The app decodes
synthetic bridge messages through its real contact/cache handlers with offered
rates of 10, 100 and 500 events/sec, 48 KB details, a 5,000-event burst, new-point
notifications, and model background/resume/bridge-session changes. Malformed
and oversized messages must be rejected. JSON output and `report.json` include
elapsed processing time, main-actor heartbeat delay, cache size and sampled
process RSS. The runner fails on contact/storage bounds or heartbeat delay
over one second; offered rate is not achieved throughput.
These checks do not exercise radio delivery, actual OS suspension/reconnection,
physical haptics, map-screen rendering or physical-watch memory limits.
The large-detail test reproduced a watchOS preferences-size abort, now guarded
by the cache byte budget. It does not identify every reported physical crash.

Data Sync checks cover mission list filtering and bounds, single-segment
mission name encoding, mission CoT parsing (wrapped or bare events, nested
points, dedupe, limits, DTD rejection), mission bridge validation, nearest-999
selection and message-sized item paging (`CompanionMapChecks`):

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift \
  Tests/DataSyncChecks.swift -o /tmp/weartak-datasync-checks
/tmp/weartak-datasync-checks
```

Stream TLS-name checks cover validation, persistence, older settings without an
override, clearing the override and preserving the connection address:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/CompanionEndpoint.swift Shared/CompanionServer.swift \
  Tests/CompanionServerChecks.swift -o /tmp/weartak-server-checks
/tmp/weartak-server-checks
```

Server row status checks cover the status levels, connected-duration text,
plain-language error mapping (ignoring the stream's "TLS name" prefix) and
certificate expiry warnings:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/CompanionServerStatus.swift \
  Tests/CompanionServerStatusChecks.swift -o /tmp/weartak-status-checks
/tmp/weartak-status-checks
```

Directed GeoChat checks cover recipient addressing, XML escaping, message
bounds, incoming reply parsing, chat exclusion from map snapshots, unread/read
state, duplicate suppression, source isolation, quick messages and inbox eviction:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChat.swift Tests/TAKChatChecks.swift \
  -o /tmp/weartak-chat-checks
/tmp/weartak-chat-checks
```

Phone GPS reporting checks cover identity freshness and UID guards, interval and
fix bounds, PLI XML shape and exact timestamps, watch PLI suppression scope and
start/stop gating:

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/PhoneLocationReporting.swift \
  Tests/PhoneLocationReportingChecks.swift -o /tmp/weartak-phone-checks
/tmp/weartak-phone-checks
```

`Tests/CompanionSecurityChecks.swift` also checks generated CSR signatures,
certificate/key matching, expiry, `.p12` import/password handling, private-CA
server trust, hostname rejection, explicit CA restrictions, invalid CA data,
and endpoint/error diagnostics with temporary test identities. It requires the resolved SwiftASN1 module linked
alongside CertificateStore, EnrollmentClient, TAKHTTPS, TAKServerConnection and
its Shared dependencies (CompanionEndpoint, CompanionServer, BridgeWire,
CompanionMapSnapshot, TAKChannelModels and TAKMissionModels).
It also checks exact DNS SAN extraction, no Common Name
fallback, inspection trust/expiry rejection, and a local TLS listener proving
that inspection returns names without completing TLS; cancellation and repeated
inspections are covered. A private-CA fixture verifies automatic recovery from
a hostname mismatch to the single DNS SAN `takserver2`, while ambiguous-name
selection and missing CA chains are rejected. No simulator or mock test
establishes physical-device background reliability or live server compatibility.