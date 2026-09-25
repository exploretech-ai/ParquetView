#!/usr/bin/env bash
#
# Build a universal (arm64 + x86_64), Developer-ID-signed, notarized macOS
# release: ParquetView.app plus a DMG installer.
#
# tauri.conf.json stays ad-hoc signed ("-") with an app-only bundle so plain
# `npm run tauri build` and install.sh keep working without the ExploreTech
# certificate. This script layers the release settings on top via --config
# (a JSON merge patch): the Developer ID identity, the notarization team, and
# the DMG target. Tauri notarizes + staples the .app itself when APPLE_ID /
# APPLE_PASSWORD / APPLE_TEAM_ID are set.
#
# Under devbox, the Nix cc wrapper bakes its own /nix/store libiconv into the
# executable. That dylib is signed outside our Team ID, so the hardened-runtime
# app aborts at launch ("different Team IDs"). Every rustc link — including the
# per-arch relinks `tauri build` does — is routed through scripts/macos-link.sh,
# which repoints libiconv at the system copy. See that script for details.
#
# Needs, on the Mac running it:
#   - the "Developer ID Application: Exploration Technologies, Inc" cert in the
#     login keychain
#   - an app-specific password in the keychain:
#       security add-generic-password -s AppleID -a tauri-signing -w <password>
#   - both Rust targets: rustup target add aarch64-apple-darwin x86_64-apple-darwin
#
# Usage: scripts/build-macos.sh   (inside the devbox shell; then scripts/publish-macos.sh)

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="universal-apple-darwin"
BUNDLE_DIR="src-tauri/target/$TARGET/release/bundle"
APP="$BUNDLE_DIR/macos/ParquetView.app"
SIGNING_IDENTITY="Developer ID Application: Exploration Technologies, Inc (CK8MVY2C3J)"

echo "==> Checking toolchain"
installed_targets="$(rustup target list --installed)"
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  if ! grep -qx "$t" <<<"$installed_targets"; then
    echo "!! missing Rust target $t. Run: rustup target add aarch64-apple-darwin x86_64-apple-darwin" >&2
    exit 1
  fi
done

echo "==> Loading notarization credentials"
export APPLE_ID='kai.wells@exploretech.ai'
export APPLE_TEAM_ID='CK8MVY2C3J'
APPLE_PASSWORD="$(security find-generic-password -s "AppleID" -a "tauri-signing" -w)"
export APPLE_PASSWORD

# The bundler calls `xattr` by name; a non-Apple one first on PATH (conda ships
# one) makes it fail after the .app is built. Shadow just that tool with the
# system copy rather than reordering the whole PATH.
shim_dir="$(mktemp -d)"
trap 'rm -rf "$shim_dir"' EXIT
ln -s /usr/bin/xattr "$shim_dir/xattr"
export PATH="$shim_dir:$PATH"

# Route every rustc link step through the wrapper that rewrites Nix libiconv ->
# the system copy. Absolute path: Tauri runs cargo from src-tauri/, so a
# relative linker path wouldn't resolve. Both arches, since this is a universal
# build.
WRAPPER="$PWD/scripts/macos-link.sh"
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$WRAPPER"
export CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$WRAPPER"

# Changing the linker doesn't invalidate Cargo's fingerprint, so force a relink
# of both per-arch binaries; otherwise a stale (Nix-linked) artifact slips into
# the universal binary that lipo assembles from them.
rm -f src-tauri/target/aarch64-apple-darwin/release/parquetview \
      src-tauri/target/x86_64-apple-darwin/release/parquetview

# tauri build overwrites same-named outputs but never purges the bundle dirs, so
# a version bump would leave the prior version's DMG (its name encodes the
# version) behind and trip publish-macos.sh's "exactly one *.dmg" guard. Clean
# both dirs so "one build = one artifact" stays true.
echo "==> Cleaning stale bundle dirs"
rm -rf "$BUNDLE_DIR/dmg" "$BUNDLE_DIR/macos"

release_config="$(jq -n --arg id "$SIGNING_IDENTITY" --arg team "$APPLE_TEAM_ID" '{
  bundle: {
    targets: ["app", "dmg"],
    macOS: { signingIdentity: $id, hardenedRuntime: true, providerShortName: $team }
  }
}')"

echo "==> Building + signing + notarizing (tauri build --target $TARGET)"
npm run tauri build -- --target "$TARGET" --config "$release_config"

echo "==> Verifying the bundle"
if [ ! -d "$APP" ]; then
  echo "!! Could not find the app bundle at: $APP" >&2
  exit 1
fi
exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
BUNDLED_BIN="$APP/Contents/MacOS/$exe"

archs="$(lipo -archs "$BUNDLED_BIN")"
echo "    architectures: $archs"
if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
  echo "!! expected a universal binary (arm64 + x86_64)." >&2
  exit 1
fi

# otool -L on a universal binary lists the load commands of both slices.
echo "    libiconv refs:"
otool -L "$BUNDLED_BIN" | grep -i iconv | sed 's/^/      /'
if otool -L "$BUNDLED_BIN" | grep -q nix/store; then
  echo "!! executable still references /nix/store dylibs:" >&2
  otool -L "$BUNDLED_BIN" | grep nix/store >&2
  echo "   The wrapper didn't apply (check CARGO_TARGET_*_LINKER reached cargo)," >&2
  echo "   or another Nix dylib (not libiconv) was linked — that one needs its own" >&2
  echo "   /usr/lib equivalent in scripts/macos-link.sh, or to be bundled + signed." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP"
echo "    signature OK"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

shopt -s nullglob
dmgs=( "$BUNDLE_DIR"/dmg/*.dmg )
shopt -u nullglob
echo "==> Done."
echo "    app: $APP"
echo "    dmg: ${dmgs[*]:-(none found)}"
