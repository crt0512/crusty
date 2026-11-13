#!/usr/bin/env bash
# downloads Chromium 95 for Android (snapshot r920003, the last build that still runs on Lollipop) and unpacks ChromePublic.apk where tools/build-emmc.py expects it.
# rerun whenever, if the apk is already there it does nothing.
#
#   tools/fetch-chromium.sh [work/]
set -euo pipefail
WORK=${1:-work}
REV=920003
SHA256=fa8ec6dc4680d218c6f335e067661a17955166f60c150ffe14493dbcb52ebaec
D="$WORK/downloads"; Z="$D/chrome-android-$REV.zip"; APK="$D/chromium-$REV/ChromePublic.apk"
mkdir -p "$D"
[ -f "$APK" ] && { echo "$APK already there, nothing to do"; exit 0; }
if [ ! -f "$Z" ]; then
    curl -fL --progress-bar -o "$Z.part" \
        "https://storage.googleapis.com/chromium-browser-snapshots/Android/$REV/chrome-android.zip"
    mv "$Z.part" "$Z"
fi
echo "$SHA256  $Z" | sha256sum -c --quiet
mkdir -p "$(dirname "$APK")"
unzip -p "$Z" chrome-android/apks/ChromePublic.apk > "$APK.part" && mv "$APK.part" "$APK"
ls -l "$APK"
