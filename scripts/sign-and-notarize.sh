#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="imsg"
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"Developer ID Application: Peter Steinberger (Y5PE65HELJ)"}
ENTITLEMENTS="${ROOT}/Resources/imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
ZIP_PATH="${OUTPUT_DIR}/imsg-macos.zip"
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-dist.XXXXXX")"
API_KEY_FILE="$(mktemp "/tmp/${APP_NAME}-notary.XXXXXX.p8")"

cleanup() {
  rm -f "$API_KEY_FILE"
  rm -rf "$DIST_DIR"
}
trap cleanup EXIT

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_FILE"

for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c release --product imsg --arch "$ARCH"
done

BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
  BINARIES+=("$ROOT/.build/${ARCH}-apple-macosx/release/imsg")
done

lipo -create "${BINARIES[@]}" -output "$DIST_DIR/imsg"

codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$DIST_DIR/imsg"

FIRST_ARCH="${ARCH_LIST[0]}"
for bundle in "$ROOT/.build/${FIRST_ARCH}-apple-macosx/release"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

chmod -R u+rw "$DIST_DIR"
xattr -cr "$DIST_DIR"
find "$DIST_DIR" -name '._*' -delete

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
(
  cd "$DIST_DIR"
  "$DITTO_BIN" --norsrc -c -k . "$ZIP_PATH"
)

xcrun notarytool submit "$ZIP_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

codesign --verify --strict --verbose=4 "$DIST_DIR/imsg"
if ! spctl -a -t exec -vv "$DIST_DIR/imsg"; then
  echo "spctl check failed (CLI binaries often report 'not an app')." >&2
fi

echo "Done: $ZIP_PATH"
