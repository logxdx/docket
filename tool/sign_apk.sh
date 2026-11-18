#!/usr/bin/env bash
# Sign a release APK with Docket's release key, so it installs as an update over the Docket already on a phone.
#
#   tool/sign_apk.sh build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#
# Releases up to v0.4.0 were signed with an older key; that key vouches for the release key (key rotation, its
# lineage), so Android 9 and later see the release key, and Android 7 and 8 the older one. Both keys and the lineage
# stay outside the repository; their paths and passwords come from the environment or from the file
# DOCKET_SIGNING_ENV names (default: .signing.env in the repository, a link to it):
#
#   DOCKET_KEYSTORE, DOCKET_KEYSTORE_PASSWORD, DOCKET_KEY_ALIAS, DOCKET_KEY_PASSWORD   the release key
#   DOCKET_ORIGINAL_KEYSTORE, DOCKET_ORIGINAL_PASSWORD, DOCKET_ORIGINAL_ALIAS          the older key
#   DOCKET_LINEAGE                                                                     the lineage between them
set -euo pipefail
apk="${1:?usage: tool/sign_apk.sh app.apk}"
root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${DOCKET_SIGNING_ENV:-$root/.signing.env}"
# shellcheck disable=SC1090
if [ -z "${DOCKET_LINEAGE:-}" ] && [ -f "$env_file" ]; then source "$env_file"; fi
for v in DOCKET_KEYSTORE DOCKET_KEYSTORE_PASSWORD DOCKET_KEY_ALIAS DOCKET_KEY_PASSWORD \
  DOCKET_ORIGINAL_KEYSTORE DOCKET_ORIGINAL_PASSWORD DOCKET_ORIGINAL_ALIAS DOCKET_LINEAGE; do
  [ -n "${!v:-}" ] || { echo "sign_apk.sh: $v is not set (see the top of this file)" >&2; exit 1; }
done

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?ANDROID_HOME is not set}}"
tools="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
# Native libraries on 16 KB pages, as the build left them (aligned again only if they are not).
if ! "$tools/zipalign" -c -P 16 4 "$apk" >/dev/null; then
  "$tools/zipalign" -f -P 16 4 "$apk" "$apk.aligned" && mv "$apk.aligned" "$apk"
fi

"$tools/apksigner" sign \
  --ks "$DOCKET_ORIGINAL_KEYSTORE" --ks-key-alias "$DOCKET_ORIGINAL_ALIAS" \
  --ks-pass env:DOCKET_ORIGINAL_PASSWORD --key-pass env:DOCKET_ORIGINAL_PASSWORD \
  --next-signer \
  --ks "$DOCKET_KEYSTORE" --ks-key-alias "$DOCKET_KEY_ALIAS" \
  --ks-pass env:DOCKET_KEYSTORE_PASSWORD --key-pass env:DOCKET_KEY_PASSWORD \
  --lineage "$DOCKET_LINEAGE" --rotation-min-sdk-version 28 \
  --v4-signing-enabled false \
  "$apk"

"$tools/apksigner" verify --print-certs "$apk" | grep -E '^Signer|SHA-256' || true
"$tools/apksigner" verify --min-sdk-version 24 "$apk"
echo "signed: $apk"
