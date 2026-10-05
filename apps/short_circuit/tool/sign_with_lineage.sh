#!/usr/bin/env bash
# Re-signs a release APK with the release key and attaches the key-rotation proof, so
# a phone that has the app signed with the previous key accepts it as an update and
# keeps its data. Reads android/key.properties:
#   storeFile, storePassword, keyAlias, keyPassword   the release key (as for Gradle)
#   lineageFile                                       the rotation proof (optional)
# Without lineageFile the APK is left as Gradle signed it.
#
# Only the v3 signature scheme is written. Older schemes would have to be signed with the
# previous key, which would then be needed for every release; v3 alone needs Android 9+.
#
#   tool/sign_with_lineage.sh build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail

apk="${1:?usage: sign_with_lineage.sh <apk>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
props="$root/android/key.properties"
[[ -f "$props" ]] || { echo "No android/key.properties: leaving the APK as built."; exit 0; }

prop() { sed -n "s/^$1=//p" "$props" | head -1; }
lineage="$(prop lineageFile)"
if [[ -z "$lineage" ]]; then
  echo "No lineageFile in key.properties: leaving the APK as built."
  exit 0
fi

store="$(prop storeFile)"
[[ "$store" == /* ]] || store="$root/android/app/$store"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
apksigner="$(find "$sdk/build-tools" -name apksigner | sort -V | tail -1)"

KS_PASS="$(prop storePassword)"
KEY_PASS="$(prop keyPassword)"
export KS_PASS KEY_PASS
out="$(mktemp -d)/signed.apk"
"$apksigner" sign \
  --ks "$store" --ks-key-alias "$(prop keyAlias)" --ks-pass env:KS_PASS --key-pass env:KEY_PASS \
  --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true \
  --lineage "$lineage" --rotation-min-sdk-version 28 --out "$out" "$apk"
unset KS_PASS KEY_PASS

report="$("$apksigner" verify --verbose --print-certs "$out")"
grep -q "Verified using v3 scheme (APK Signature Scheme v3): true" <<<"$report" || { echo "The re-signed APK has no v3 signature." >&2; exit 1; }
mv "$out" "$apk"
echo "Signed with the release key and the rotation proof:"
grep -E "certificate DN|SHA-256 digest" <<<"$report" | head -2 | sed 's/^/  /'
