#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/weartak-garmin-checks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

cd "$repo_root"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRelayProtocol.swift \
  Shared/PhoneLocationReporting.swift \
  Shared/UserMetrics.swift \
  Shared/BridgeWire.swift \
  Shared/CompanionMapSnapshot.swift \
  Shared/TAKChannelModels.swift \
  Shared/TAKMissionModels.swift \
  Shared/TAKChat.swift \
  Shared/GarminDeliveryLedger.swift \
  Tests/GarminRelayProtocolTests.swift \
  -o "$build_dir/garmin-relay-checks"
"$build_dir/garmin-relay-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminRoutes.swift Tests/GarminRouteChecks.swift \
  -o "$build_dir/garmin-route-checks"
"$build_dir/garmin-route-checks"

swiftc -swift-version 5 -parse-as-library \
  Shared/GarminDeliveryLedger.swift Tests/GarminDeliveryLedgerTests.swift \
  -o "$build_dir/garmin-ledger-checks"
"$build_dir/garmin-ledger-checks"
