#!/bin/sh
# Add libClusterHook.so as the FIRST DT_NEEDED of CPAAProxyEx so its exported
# AirPlayInfoArrayAddScreenDisplay interposes libAirPlay.so's (global-scope
# symbol search is in DT_NEEDED order; the first definer wins, and musl honours
# this). Uses patchelf, which does minimal surgery (code, .text and .dynsym are
# left byte-identical; only .dynstr/.dynamic change).
#
#   inject_dt_needed.sh <CPAAProxyEx> [libname]
#
# Edits the file in place. patchelf --add-needed inserts at position 0; we assert
# that afterwards and that it lands before libAirPlay.so.
set -e

BIN="${1:?usage: inject_dt_needed.sh <CPAAProxyEx> [libname]}"
LIB="${2:-libClusterHook.so}"
READELF="${READELF:-arm-linux-gnueabihf-readelf}"

command -v patchelf >/dev/null || { echo "error: patchelf not installed (apt install patchelf)"; exit 1; }

# idempotent: strip any prior copy first
patchelf --remove-needed "$LIB" "$BIN" 2>/dev/null || true
patchelf --add-needed "$LIB" "$BIN"

# assert ordering: hook must appear before libAirPlay.so
order=$("$READELF" -d "$BIN" | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}')
first=$(echo "$order" | head -1)
hook_line=$(echo "$order" | grep -n "^${LIB}$" | head -1 | cut -d: -f1)
air_line=$(echo "$order"  | grep -n '^libAirPlay.so$' | head -1 | cut -d: -f1)

echo "DT_NEEDED order:"; echo "$order" | nl -ba
[ "$first" = "$LIB" ] || { echo "ERROR: $LIB is not first (got '$first')"; exit 2; }
if [ -n "$air_line" ] && [ "$hook_line" -ge "$air_line" ]; then
    echo "ERROR: $LIB ($hook_line) not before libAirPlay.so ($air_line)"; exit 2
fi
echo "OK: $LIB is first and precedes libAirPlay.so"
