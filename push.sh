#!/bin/bash

set -euo pipefail

# Local configuration. Copy xcbuild.example.conf to xcbuild.conf and set your
# own bundle identifier and device IDs. xcbuild.conf is intentionally ignored.
if [ -f xcbuild.conf ]; then
    export $(grep -v '^#' xcbuild.conf | xargs)
elif [ -f xcbuild.local.conf ]; then
    export $(grep -v '^#' xcbuild.local.conf | xargs)
else
    echo "Fehler: xcbuild.conf nicht gefunden. Kopiere xcbuild.example.conf nach xcbuild.conf und passe die Werte lokal an."
    exit 1
fi

project="${project:-piep}"

# Wenn $1 leer ist, wird standardmäßig "device" genutzt.
target_key="${1:-device}"

device_id="${!target_key}"

if [ -z "$device_id" ]; then
    echo "Fehler: Variable '$target_key' wurde in xcbuild.conf nicht gefunden!"
    exit 1
fi

echo "Installiere auf: $target_key ($device_id)..."

xcrun devicectl device install app \
  --device "$device_id" \
  "./build/Build/Products/Debug-iphoneos/${project}.app"

xcrun devicectl device process launch \
  --device "$device_id" \
  "$bundle"
