#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${repository_root}/build"
derived_data_path="${build_root}/DerivedData"
app_path="${derived_data_path}/Build/Products/Release-iphoneos/NetTool.app"
package_version="$(bash "${repository_root}/scripts/package_version.sh")"
ipa_path="${build_root}/NetTool-${package_version}.ipa"
staging_path="$(mktemp -d "${TMPDIR:-/tmp}/nettool-ipa.XXXXXX")"

cleanup() {
    rm -rf "$staging_path"
}
trap cleanup EXIT

cd "$repository_root"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null

xcodegen generate --spec project.yml

xcodebuild \
    -project NetTool.xcodeproj \
    -scheme NetTool \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

test -d "$app_path"
mkdir -p "$build_root" "$staging_path/Payload"
ditto "$app_path" "$staging_path/Payload/NetTool.app"
ditto -c -k --sequesterRsrc --keepParent "$staging_path/Payload" "$ipa_path"
unzip -t "$ipa_path"

echo "Unsigned IPA: $ipa_path"
