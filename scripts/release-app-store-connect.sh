#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  APPLE_DISTRIBUTION_CERTIFICATE_P12
  APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD
  APPLE_CONTAINER_APP_STORE_PROFILE
  APPLE_WATCH_APP_STORE_PROFILE
  APP_STORE_CONNECT_API_PRIVATE_KEY
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID
  CI_PROJECT_DIR
  CI_COMMIT_TAG
  CI_COMMIT_SHA
  CI_PIPELINE_ID
  CI_PIPELINE_IID
)
for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'ERROR: Required GitLab CI variable %s is missing or empty.\n' "$variable" >&2
    exit 1
  fi
done

for variable in \
  APPLE_DISTRIBUTION_CERTIFICATE_P12 \
  APPLE_CONTAINER_APP_STORE_PROFILE \
  APPLE_WATCH_APP_STORE_PROFILE \
  APP_STORE_CONNECT_API_PRIVATE_KEY; do
  if [[ ! -f "${!variable}" ]]; then
    printf 'ERROR: GitLab CI variable %s must be a file-type variable.\n' "$variable" >&2
    exit 1
  fi
done

if [[ ! "$CI_COMMIT_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)(-testflight\.[1-9][0-9]*)?$ ]]; then
  echo "ERROR: Release tag must be vMAJOR.MINOR.PATCH[.BUILD], optionally suffixed -testflight.N." >&2
  exit 1
fi
marketing_version="${BASH_REMATCH[1]}"
if [[ ! "$CI_PIPELINE_IID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CI_PIPELINE_IID must be a positive numeric build number." >&2
  exit 1
fi
if [[ ! "$CI_PIPELINE_ID" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$CI_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: CI_PIPELINE_ID or CI_COMMIT_SHA is invalid for the upload receipt." >&2
  exit 1
fi
if [[ ! "$APP_STORE_CONNECT_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] ||
   [[ ! "$APP_STORE_CONNECT_API_ISSUER_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  echo "ERROR: App Store Connect API key ID or issuer ID has an invalid format." >&2
  exit 1
fi

team_id="H284X28FTP"
container_bundle_id="com.aegorsuch.weartak"
watch_bundle_id="com.aegorsuch.weartak.watchkitapp"
mkdir -p "$CI_PROJECT_DIR/build"
rm -f "$CI_PROJECT_DIR/build/app-store-connect-upload.json"
work_dir="$(mktemp -d "$CI_PROJECT_DIR/build/app-store-connect.XXXXXX")"
profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
api_key_dir="$work_dir/private_keys"
profile_backup_dir="$work_dir/profile-backups"
keychain_path="$work_dir/ci-signing.keychain-db"
container_profile_uuid=""
watch_profile_uuid=""
api_key_path="$api_key_dir/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
previous_default_keychain=""
previous_keychains=()
previous_keychain_count=0

cleanup() {
  local result=$?
  trap - EXIT
  set +e
  if [[ -n "$previous_default_keychain" ]]; then
    security default-keychain -d user -s "$previous_default_keychain" >/dev/null 2>&1
    if [[ "$previous_keychain_count" -gt 0 ]]; then
      security list-keychains -d user -s "${previous_keychains[@]}" >/dev/null 2>&1
    else
      security list-keychains -d user -s "$previous_default_keychain" >/dev/null 2>&1
    fi
  fi
  security delete-keychain "$keychain_path" >/dev/null 2>&1
  for uuid in "$container_profile_uuid" "$watch_profile_uuid"; do
    [[ -z "$uuid" ]] && continue
    if [[ -f "$profile_backup_dir/$uuid.mobileprovision" ]]; then
      cp "$profile_backup_dir/$uuid.mobileprovision" "$profile_dir/$uuid.mobileprovision"
    else
      rm -f "$profile_dir/$uuid.mobileprovision"
    fi
  done
  rm -rf "$work_dir"
  exit "$result"
}
trap cleanup EXIT

keychain_password="$(openssl rand -hex 32)"
mkdir -p "$profile_dir" "$api_key_dir" "$profile_backup_dir"
chmod 700 "$api_key_dir"

# GitLab variables hold text, so binary DER files (.p12, .mobileprovision) may be
# supplied base64-encoded; decode those into the temporary workspace.
decode_if_base64() {
  local variable=$1 decoded
  if [[ "$(head -c 2 "${!variable}")" == "MI" ]]; then
    decoded="$work_dir/$variable.der"
    if ! tr -d ' \r\n\t' < "${!variable}" | base64 -D > "$decoded" 2>/dev/null ||
       [[ ! -s "$decoded" ]]; then
      printf 'ERROR: GitLab CI variable %s is not valid base64.\n' "$variable" >&2
      exit 1
    fi
    printf -v "$variable" '%s' "$decoded"
  fi
}
decode_if_base64 APPLE_DISTRIBUTION_CERTIFICATE_P12
decode_if_base64 APPLE_CONTAINER_APP_STORE_PROFILE
decode_if_base64 APPLE_WATCH_APP_STORE_PROFILE
export API_PRIVATE_KEYS_DIR="$api_key_dir"

previous_default_keychain="$(security default-keychain -d user | sed 's/^ *"\(.*\)"$/\1/')"
while IFS= read -r keychain; do
  if [[ -n "$keychain" ]]; then
    previous_keychains+=("$keychain")
    previous_keychain_count=$((previous_keychain_count + 1))
  fi
done < <(security list-keychains -d user | sed 's/^ *"\(.*\)"$/\1/')

install_profile() {
  local source=$1 expected_name=$2 expected_bundle_id=$3
  local decoded="$work_dir/profile.plist" name app_identifier profile_team uuid
  security cms -D -i "$source" > "$decoded"
  name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded")"
  app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded")"
  profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded")"
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
  if [[ "$name" != "$expected_name" ]] ||
     [[ "$app_identifier" != "$team_id.$expected_bundle_id" ]] ||
     [[ "$profile_team" != "$team_id" ]] ||
     [[ ! "$uuid" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
    printf 'ERROR: Provisioning profile must be %s for %s and team %s.\n' \
      "$expected_name" "$expected_bundle_id" "$team_id" >&2
    exit 1
  fi
  if [[ -f "$profile_dir/$uuid.mobileprovision" ]]; then
    cp "$profile_dir/$uuid.mobileprovision" "$profile_backup_dir/$uuid.mobileprovision"
  fi
  cp "$source" "$profile_dir/$uuid.mobileprovision"
  printf '%s' "$uuid"
}

container_profile_uuid="$(install_profile \
  "$APPLE_CONTAINER_APP_STORE_PROFILE" 'WearTAK Container App Store' "$container_bundle_id")"
watch_profile_uuid="$(install_profile \
  "$APPLE_WATCH_APP_STORE_PROFILE" 'WearTAK App Store' "$watch_bundle_id")"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$APPLE_DISTRIBUTION_CERTIFICATE_P12" -f pkcs12 \
  -k "$keychain_path" -P "$APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path"
if [[ "$previous_keychain_count" -gt 0 ]]; then
  security list-keychains -d user -s "$keychain_path" "${previous_keychains[@]}"
else
  security list-keychains -d user -s "$keychain_path"
fi
security default-keychain -d user -s "$keychain_path"

cp "$APP_STORE_CONNECT_API_PRIVATE_KEY" "$api_key_path"
chmod 600 "$api_key_path"

companion_info="$work_dir/Companion-Info.plist"
python3 scripts/prepare-ditto-info.py \
  --template "$CI_PROJECT_DIR/WearTAKCompanion-Info.plist" \
  --output "$companion_info"
# Keep the credential out of Xcode's exported build settings and script-phase logs.
unset DITTO_COMMUNITY_PDL

archive_path="$work_dir/WearTAK.xcarchive"
export_path="$work_dir/export"
xcodebuild \
  -project WearTAK.xcodeproj \
  -scheme 'WearTAK App Store' \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$CI_PROJECT_DIR/build/DerivedData-Release" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$CI_PIPELINE_IID" \
  WEARTAK_COMPANION_INFO_PLIST="$companion_info" \
  archive

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist

shopt -s nullglob
ipas=("$export_path"/*.ipa)
if [[ ${#ipas[@]} -ne 1 || ! -f "${ipas[0]}" ]]; then
  echo "ERROR: Expected exactly one exported App Store IPA." >&2
  exit 1
fi
python3 scripts/prepare-ditto-info.py --template "$companion_info" --verify-ipa "${ipas[0]}"

artifact_dir="$(mktemp -d "$CI_PROJECT_DIR/build/app-store-connect-output.XXXXXX")"
cp -R "$archive_path" "$artifact_dir/WearTAK-iOS-$marketing_version-p$CI_PIPELINE_IID.xcarchive"
cp "${ipas[0]}" "$artifact_dir/WearTAK-iOS-$marketing_version-p$CI_PIPELINE_IID.ipa"
(
  cd "$artifact_dir"
  shasum -a 256 "WearTAK-iOS-$marketing_version-p$CI_PIPELINE_IID.ipa" \
    > "WearTAK-iOS-$marketing_version-p$CI_PIPELINE_IID.ipa.sha256"
)

xcrun altool --upload-app \
  --type ios \
  --file "${ipas[0]}" \
  --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
printf 'TestFlight upload accepted: WearTAK-iOS-%s-p%s; Apple processing and availability are not confirmed by this upload job.\n' \
  "$marketing_version" "$CI_PIPELINE_IID"
cat > "$CI_PROJECT_DIR/build/app-store-connect-upload.json" <<JSON
{"tag":"$CI_COMMIT_TAG","version":"$marketing_version","build":"$CI_PIPELINE_IID","sha":"$CI_COMMIT_SHA","pipelineID":"$CI_PIPELINE_ID","uploadAccepted":true}
JSON
