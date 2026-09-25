#!/usr/bin/env bash
#
# Linker wrapper for macOS builds. Wired in via CARGO_TARGET_*_LINKER by
# scripts/build-macos.sh, so EVERY rustc link step goes through it — including
# the relink that `tauri build` performs (which is why a post-build
# install_name_tool patch doesn't survive: Tauri relinks and the Nix path
# comes back).
#
# Why a wrapper and not a config tweak: the devbox/Nix cc wrapper auto-appends
# `-liconv` on Darwin and supplies `-L/nix/store/...-libiconv` via NIX_LDFLAGS,
# so it bakes the absolute /nix/store libiconv path into the binary regardless
# of which `cc` PATH we point Cargo at (even /usr/bin/cc routes through it).
# That dylib is signed outside our Team ID, so the hardened-runtime,
# Developer-ID app aborts at launch with a "different Team IDs" dyld error. We
# can't drop the Nix flags without breaking the C-dep link (libcxx/compiler-rt
# come from the same NIX_LDFLAGS), so instead we do the normal Nix link, then
# rewrite the recorded libiconv path to the system copy
# (/usr/lib/libiconv.2.dylib — a platform binary, no Team-ID check).
#
# Safe to run on every linked artifact: `install_name_tool -change` is a no-op
# when the old path isn't a dependency, so build-script/proc-macro/test links
# that don't touch libiconv are unaffected.

set -uo pipefail

SYS_ICONV="/usr/lib/libiconv.2.dylib"

# Do the normal link with the toolchain's cc (the Nix wrapper — the proven
# linker that resolves all the C-dep symbols).
cc "$@"
status=$?
[ "$status" -eq 0 ] || exit "$status"

# Recover the output path from "-o <out>". rustc usually passes it directly, but
# can spill args into an @response-file for long link lines — handle both.
find_out() {
  local prev="" a
  for a in "$@"; do
    [ "$prev" = "-o" ] && { printf '%s\n' "$a"; return 0; }
    prev="$a"
  done
  return 1
}

out="$(find_out "$@")" || true
if [ -z "$out" ]; then
  for a in "$@"; do
    case "$a" in
      @*)
        f="${a#@}"
        # shellcheck disable=SC2046  # intentional word-split: output path has no spaces
        [ -f "$f" ] && out="$(find_out $(cat "$f"))" && [ -n "$out" ] && break
        ;;
    esac
  done
fi

# Repoint any Nix libiconv reference at the system copy.
if [ -n "$out" ] && [ -f "$out" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    install_name_tool -change "$p" "$SYS_ICONV" "$out" 2>/dev/null || true
  done < <(otool -L "$out" 2>/dev/null | awk '/nix\/store.*libiconv/{print $1}')
fi

exit "$status"
