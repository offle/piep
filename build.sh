#!/bin/bash

set -euo pipefail

# Optional local configuration. Copy xcbuild.example.conf to xcbuild.conf
# for device-specific overrides. xcbuild.conf is intentionally ignored.
if [ -f xcbuild.conf ]; then
    export $(grep -v '^#' xcbuild.conf | xargs)
elif [ -f xcbuild.local.conf ]; then
    export $(grep -v '^#' xcbuild.local.conf | xargs)
fi

project="${project:-piep}"
build_timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

xcode_overrides=()
if [ -n "${bundle:-}" ]; then
    xcode_overrides+=("PRODUCT_BUNDLE_IDENTIFIER=$bundle")
fi
xcode_overrides+=("PIEP_BUILD_TIMESTAMP=$build_timestamp")
if [ -n "${development_team:-}" ]; then
    xcode_overrides+=("DEVELOPMENT_TEAM=$development_team")
else
    xcode_overrides+=("CODE_SIGNING_ALLOWED=NO")
fi

xcodebuild \
  -workspace "${project}.xcworkspace" \
  -scheme "$project" \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./build \
  "${xcode_overrides[@]}" \
  build

app_path="./build/Build/Products/Debug-iphoneos/${project}.app"
info_plist="${app_path}/Info.plist"
entitlements_path="./build/Build/Intermediates.noindex/${project}.build/Debug-iphoneos/${project}.build/${project}.app.xcent"

if [ -f "$info_plist" ]; then
    /usr/bin/plutil -replace PiepBuildTimestamp -string "$build_timestamp" "$info_plist"

    signing_identity="$(
        /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
            | /usr/bin/head -n 1
    )"

    if [ -n "$signing_identity" ] && [ -n "${development_team:-}" ]; then
        codesign_args=(--force --sign "$signing_identity" --timestamp=none --generate-entitlement-der)
        if [ -f "$entitlements_path" ]; then
            codesign_args+=(--entitlements "$entitlements_path")
        fi

        /usr/bin/codesign "${codesign_args[@]}" "$app_path"
    fi
fi
