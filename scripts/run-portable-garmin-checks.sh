#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/weartak-garmin-checks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

cd "$repo_root"

swiftc -swift-version 5 -parse-as-library Shared/DiagnosticsLog.swift Tests/DiagnosticsChecks.swift \
  -o "$build_dir/diagnostics-checks"
"$build_dir/diagnostics-checks"

swiftc -swift-version 5 -parse-as-library Shared/NetworkTransportChecklist.swift Tests/NetworkTransportChecklistChecks.swift \
  -o "$build_dir/network-transport-checks"
"$build_dir/network-transport-checks"

swiftc -swift-version 5 -parse-as-library Shared/DashboardMetric.swift Shared/OutboundRouteReadiness.swift Tests/DashboardMetricChecks.swift \
  -o "$build_dir/dashboard-metric-checks"
"$build_dir/dashboard-metric-checks"

if [[ "$(uname -s)" == "Darwin" ]]; then
  swiftc -swift-version 5 -parse-as-library "WearTAK Watch App/MapCoordinateFormatter.swift" \
    Tests/MapCoordinateFormatterChecks.swift -o "$build_dir/map-coordinate-checks"
  "$build_dir/map-coordinate-checks"
fi

swiftc -swift-version 5 -parse-as-library Shared/MOPPStatus.swift Shared/DataSyncRequestGate.swift \
  "WearTAK Watch App/PluginCatalog.swift" Tests/PluginPreferenceChecks.swift \
  -o "$build_dir/plugin-preference-checks"
"$build_dir/plugin-preference-checks"

swiftc -swift-version 5 -parse-as-library Shared/ChatCommands.swift Tests/ChatCommandChecks.swift \
  -o "$build_dir/chat-command-checks"
"$build_dir/chat-command-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChat.swift Tests/TAKChatChecks.swift \
  -o "$build_dir/tak-chat-checks"
"$build_dir/tak-chat-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChat.swift Shared/ChatCommands.swift \
  "WearTAK Watch App/WatchChatCommandRuntime.swift" Tests/WatchChatCommandRuntimeChecks.swift \
  -o "$build_dir/watch-command-checks"
"$build_dir/watch-command-checks"

swiftc -swift-version 5 -parse-as-library Shared/DistanceUnits.swift Tests/DistanceUnitsChecks.swift \
  -o "$build_dir/distance-units-checks"
"$build_dir/distance-units-checks"

swiftc -swift-version 5 -parse-as-library Shared/ManualAlerts.swift Shared/OfflineOutbox.swift Tests/ManualAlertChecks.swift \
  -o "$build_dir/manual-alert-checks"
"$build_dir/manual-alert-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift \
  Shared/PhoneLocationReporting.swift Shared/CoTFieldSafety.swift Tests/CoTFieldSafetyChecks.swift \
  -o "$build_dir/cot-field-safety-checks"
"$build_dir/cot-field-safety-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/RemoteAlertLifecycle.swift Shared/CoTMapSymbol.swift "WearTAK Watch App/RelayProtocol.swift" \
  "WearTAK Watch App/SitxCoT.swift" Tests/BloodhoundAlertChecks.swift \
  -o "$build_dir/cot-map-alert-checks"
"$build_dir/cot-map-alert-checks"

swiftc -swift-version 5 -parse-as-library Tests/StringCatalogEncodingChecks.swift \
  -o "$build_dir/string-catalog-encoding-checks"
"$build_dir/string-catalog-encoding-checks" "$repo_root"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRelayProtocol.swift \
  Shared/CoTMapSymbol.swift \
  Shared/CoTFieldSafety.swift \
  Shared/PhoneLocationReporting.swift \
  Shared/UserMetrics.swift \
  Shared/BridgeWire.swift \
  Shared/WatchSelfStatus.swift \
  Shared/GarminRoutes.swift \
  Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift \
  Shared/TAKMissionModels.swift \
  Shared/TAKChat.swift \
  Shared/GarminDeliveryLedger.swift \
  Shared/DittoTrack.swift Shared/DittoDocuments.swift Shared/DittoChat.swift Tests/DittoDocumentChecks.swift \
  Tests/SavedChatMessageChecks.swift \
  Tests/GarminRelayProtocolTests.swift \
  -o "$build_dir/garmin-relay-checks"
"$build_dir/garmin-relay-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/RouteFollower.swift Shared/BloodhoundPicker.swift Shared/WatchPinTitle.swift \
  Tests/BloodhoundPickerChecks.swift -o "$build_dir/bloodhound-picker-checks"
"$build_dir/bloodhound-picker-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/RouteFollower.swift Tests/RouteFollowerChecks.swift \
  -o "$build_dir/route-follower-checks"
"$build_dir/route-follower-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Shared/RouteFollower.swift Shared/RouteNavigation.swift Shared/WatchRoutes.swift \
  Tests/RouteNavigationChecks.swift -o "$build_dir/route-navigation-checks"
"$build_dir/route-navigation-checks"

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
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionEndpoint.swift \
  Shared/CompanionServer.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChannels.swift \
  Shared/DittoPDL.swift Tests/BridgeProtocolChecks.swift \
  -o "$build_dir/bridge-checks"
"$build_dir/bridge-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/PhoneLocationReporting.swift \
  Tests/PhoneLocationReportingChecks.swift Tests/WatchSelfStatusChecks.swift \
  -o "$build_dir/phone-self-status-checks"
"$build_dir/phone-self-status-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionEndpoint.swift \
  Shared/CompanionServer.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Shared/TAKChannels.swift \
  Shared/DittoPDL.swift scripts/ValidateDittoPDL.swift \
  -o "$build_dir/validate-community-pdl"
"$build_dir/validate-community-pdl"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Tests/CompanionMapChecks.swift \
  -o "$build_dir/map-checks"
"$build_dir/map-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift Tests/DataSyncChecks.swift \
  -o "$build_dir/mission-checks"
"$build_dir/mission-checks"

if [[ "$(uname -s)" == Darwin ]]; then
  swiftc -swift-version 5 -parse-as-library \
    "WearTAK Watch App/AppSettings.swift" "WearTAK Watch App/DashboardStatus.swift" \
    "WearTAK Watch App/WatchSettingsLabels.swift" "WearTAK Watch App/PluginCatalog.swift" \
    "WearTAK Watch App/RelayProtocol.swift" "WearTAK Watch App/SitxCoT.swift" \
    "WearTAK Watch App/MulticastTAKTransport.swift" "WearTAK Watch App/SitxClient.swift" \
    Shared/BridgeWire.swift Shared/WatchSelfStatus.swift Shared/GarminRoutes.swift Shared/CompanionMapSnapshot.swift \
    Shared/CoTMapSymbol.swift Shared/TAKMulticast.swift Shared/TAKChannelModels.swift Shared/TAKMissionModels.swift \
    Shared/TAKChat.swift Shared/SitxShared.swift Shared/PhoneLocationReporting.swift Shared/CoTFieldSafety.swift \
    Shared/UserMetrics.swift Shared/DittoPDL.swift Shared/DashboardMetric.swift Shared/ManualAlerts.swift \
    Shared/MOPPStatus.swift Shared/SecurePDLStore.swift Shared/ChatCommands.swift \
    Tests/SitxProtocolChecks.swift -o "$build_dir/sitx-protocol-checks"
  "$build_dir/sitx-protocol-checks" --own-pin-deletion
  "$build_dir/sitx-protocol-checks" --developer-persistence
fi

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminDeliveryLedger.swift Tests/GarminDeliveryLedgerTests.swift \
  -o "$build_dir/garmin-ledger-checks"
"$build_dir/garmin-ledger-checks"
