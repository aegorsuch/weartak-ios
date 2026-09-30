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

## WearTAK Apple Watch rebuild

WearTAK is being rebuilt for Apple Watch from the Wear OS and Garmin
implementations as a standalone watch-first experience. The Apple-specific
repository and implementation identity is `weartak-ios`; the product name is
WearTAK. The first vertical slice lives in `WearTAKWatch/` and covers
connection state, location/PLI, marker creation, and confirmed SOS
alert/cancellation actions.

The Garmin implementation establishes the companion relay message boundary:
`relay_hello`, `marker`, `marker_delete`, `emergency`, `chat`, and inbound
`entity`/`entities` messages. Apple Watch transport code should preserve those
semantics while allowing direct TAK connectivity where watchOS permits it.

Platform-specific features remain separate adapters. Wear OS services, Samsung
Health, Android plugins, Garmin Connect IQ, and watchOS location/sensor APIs
must not leak into the shared operational model.
