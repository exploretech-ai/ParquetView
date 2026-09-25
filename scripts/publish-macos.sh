#!/usr/bin/env bash
#
# Publish an already-built macOS release: upload the DMG to S3 under a
# versioned key, then refresh the two mutable pointers:
#   parquetview/darwin/ParquetView.dmg  — stable "latest" download link
#   parquetview/darwin/latest.json      — { version, pub_date, dmg_url }
#
# Run this ON a Mac with the `fly-prod` AWS profile configured, AFTER
# scripts/build-macos.sh has produced a signed, notarized build (a single *.dmg
# under src-tauri/target/universal-apple-darwin/release/bundle/dmg/).
#
# The pointers are written only after the versioned upload succeeds and always
# overwrite the previous ones (--force-overwrite gates only the versioned key).
# CloudFront (fronting dl.exploretech.app) owns cache TTLs, so no Cache-Control
# is set here — the stable DMG/latest.json may lag until the cache expires or
# is invalidated.
#
# Usage: scripts/publish-macos.sh [--force-overwrite]
#   Overridable via env: BUCKET REGION AWS_PROFILE_NAME BASE_URL DMG_DIR

set -euo pipefail

cd "$(dirname "$0")/.."

BUCKET="${BUCKET:-downloads-d28db135aff5}"
REGION="${REGION:-us-east-2}"
PROFILE="${AWS_PROFILE_NAME:-fly-prod}"
BASE_URL="${BASE_URL:-https://dl.exploretech.app}"
DMG_DIR="${DMG_DIR:-src-tauri/target/universal-apple-darwin/release/bundle/dmg}"
PREFIX="parquetview/darwin"
STABLE_NAME="ParquetView.dmg"

FORCE_OVERWRITE=0
for arg in "$@"; do
  case "$arg" in
    --force-overwrite) FORCE_OVERWRITE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found on PATH." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found on PATH." >&2; exit 1; }

# Every aws call carries the profile + region; `command aws` calls the binary,
# not this wrapper (standard, recursion-safe pattern).
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

echo "==> Locating build artifacts"
shopt -s nullglob
dmg_matches=( "$DMG_DIR"/*.dmg )
shopt -u nullglob

if (( ${#dmg_matches[@]} != 1 )); then
  echo "!! expected exactly one *.dmg in $DMG_DIR, found ${#dmg_matches[@]}. Run scripts/build-macos.sh first." >&2
  exit 1
fi
dmg="${dmg_matches[0]}"
dmg_name="$(basename "$dmg")"
echo "  dmg: $dmg_name"

echo "==> Reading metadata"
version="$(jq -r '.version' src-tauri/tauri.conf.json)"
if [[ -z "$version" || "$version" == "null" ]]; then
  echo "!! could not read 'version' from src-tauri/tauri.conf.json" >&2
  exit 1
fi
if [[ "$dmg_name" != *"$version"* ]]; then
  echo "!! WARNING: dmg name '$dmg_name' does not contain version '$version' — double-check you rebuilt after bumping the version." >&2
fi
echo "  version: $version"

dmg_key="$PREFIX/$version/$dmg_name"
stable_key="$PREFIX/$STABLE_NAME"
dmg_url="$BASE_URL/$dmg_key"
stable_url="$BASE_URL/$stable_key"

# head-object exits nonzero when the key is absent; swallow that so `set -e`
# doesn't abort. Returns 0 (exists) / 1 (absent). Needs s3:GetObject.
object_exists() { aws s3api head-object --bucket "$BUCKET" --key "$1" >/dev/null 2>&1; }

if (( ! FORCE_OVERWRITE )) && object_exists "$dmg_key"; then
  echo "!! s3://$BUCKET/$dmg_key already exists (pass --force-overwrite to replace)." >&2
  exit 1
fi

echo "==> Uploading dmg -> s3://$BUCKET/$dmg_key"
aws s3 cp "$dmg" "s3://$BUCKET/$dmg_key"

echo "==> Updating stable dmg -> s3://$BUCKET/$stable_key"
aws s3 cp "s3://$BUCKET/$dmg_key" "s3://$BUCKET/$stable_key"

pub_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
manifest_json="$(jq -n \
  --arg version  "$version" \
  --arg pub_date "$pub_date" \
  --arg dmg_url  "$dmg_url" \
  '{ version: $version, pub_date: $pub_date, dmg_url: $dmg_url }')"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$manifest_json" > "$tmp"

echo "==> Uploading manifest -> s3://$BUCKET/$PREFIX/latest.json"
aws s3 cp "$tmp" "s3://$BUCKET/$PREFIX/latest.json" --content-type application/json

echo ""
echo "Published macOS release $version"
echo "  dmg URL:     $dmg_url"
echo "  stable URL:  $stable_url"
echo "  manifest:    $BASE_URL/$PREFIX/latest.json"
echo ""
printf '%s\n' "$manifest_json"
