#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/weartak-garmin-checks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

cd "$repo_root"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift \
  Shared/PhoneLocationReporting.swift Shared/CoTFieldSafety.swift Tests/CoTFieldSafetyChecks.swift \
  -o "$build_dir/cot-field-safety-checks"
"$build_dir/cot-field-safety-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/RemoteAlertLifecycle.swift "WearTAK Watch App/RelayProtocol.swift" \
  "WearTAK Watch App/SitxCoT.swift" Tests/BloodhoundAlertChecks.swift \
  -o "$build_dir/cot-map-alert-checks"
"$build_dir/cot-map-alert-checks"

swiftc -swift-version 5 -parse-as-library Tests/StringCatalogEncodingChecks.swift \
  -o "$build_dir/string-catalog-encoding-checks"
"$build_dir/string-catalog-encoding-checks" "$repo_root"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRelayProtocol.swift \
  Shared/CoTFieldSafety.swift \
  Shared/PhoneLocationReporting.swift \
  Shared/UserMetrics.swift \
  Shared/BridgeWire.swift \
  Shared/GarminRoutes.swift \
  Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift \
  Shared/TAKMissionModels.swift \
  Shared/TAKChat.swift \
  Shared/GarminDeliveryLedger.swift \
  Tests/GarminRelayProtocolTests.swift \
  -o "$build_dir/garmin-relay-checks"
"$build_dir/garmin-relay-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/RouteFollower.swift Shared/BloodhoundPicker.swift \
  Tests/BloodhoundPickerChecks.swift -o "$build_dir/bloodhound-picker-checks"
"$build_dir/bloodhound-picker-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/RouteFollower.swift Tests/RouteFollowerChecks.swift \
  -o "$build_dir/route-follower-checks"
"$build_dir/route-follower-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Tests/GarminRouteChecks.swift \
  -o "$build_dir/garmin-route-checks"
"$build_dir/garmin-route-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/TAKRoutePackage.swift Shared/WatchRoutes.swift \
  "WearTAK Companion/RoutePackageZIP.swift" Tests/RoutePackageChecks.swift \
  -lz -o "$build_dir/route-package-checks"
"$build_dir/route-package-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/GarminRoutes.swift Shared/CompanionEndpoint.swift \
  Shared/CompanionServer.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChannels.swift \
  Shared/DittoPDL.swift Tests/BridgeProtocolChecks.swift \
  -o "$build_dir/bridge-checks"
"$build_dir/bridge-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Tests/CompanionMapChecks.swift \
  -o "$build_dir/map-checks"
"$build_dir/map-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminDeliveryLedger.swift Tests/GarminDeliveryLedgerTests.swift \
  -o "$build_dir/garmin-ledger-checks"
"$build_dir/garmin-ledger-checks"
