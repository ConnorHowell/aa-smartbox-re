#!/bin/bash
#
# repack_app.sh — build an "app" SquashFS that carries the cluster hook, and
# (optionally) splice it back into a full flash dump ready for FEL.
#
# Steps:
#   1. unsquashfs the stock app partition
#   2. drop libClusterHook.so into its /lib (reached via LD_LIBRARY_PATH=/mnt/app/lib)
#   3. patchelf a FIRST DT_NEEDED for it into bin/CPAAProxyEx
#   4. mksquashfs with the stock params (xz, 256 KiB block, all-root)
#   5. size-check against the 0x6c0000 partition budget
#   6. if a dump is given, write the new app at offset 0x7e0000 (with backup)
#
# Usage:
#   tools/cluster-hook/repack_app.sh <app.bin> [flash_dump.bin]
#
# <app.bin> is the stock app partition (e.g. dumps/spi_flash/extracted/raw/app.bin).
# Build libClusterHook.so first:  make -C tools/cluster-hook
#
# NOTE: this adds the hook lib but keeps it OFF by default — CPAAProxyEx only
# activates it when the process env has CLUSTER_HOOK_ENABLE=1. To actually enable
# it you must also export that var before CPAAProxyEx starts (edit rc.final in the
# rootfs partition, or export it from a telnet shell and relaunch). Keeping it off
# means this repacked app is safe to flash and behaves like stock.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${1:?usage: repack_app.sh <app.bin> [flash_dump.bin]}"
DUMP="${2:-}"
HOOK="$HERE/libClusterHook.so"

APP_OFFSET=$((0x7e0000))
APP_MAXSIZE=$((0x6c0000))      # app partition budget from the partition table
BLOCK=262144                   # 256 KiB, matches stock superblock
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$HOOK" ] || { echo "error: $HOOK not built — run: make -C $HERE"; exit 1; }
command -v patchelf   >/dev/null || { echo "error: need patchelf";   exit 1; }
command -v mksquashfs >/dev/null || { echo "error: need squashfs-tools"; exit 1; }

echo "== unsquashfs stock app =="
unsquashfs -no-progress -d "$WORK/app" "$APP_SRC" >/dev/null
echo "   $(find "$WORK/app" -type f | wc -l) files"

echo "== install hook lib + inject DT_NEEDED =="
cp "$HOOK" "$WORK/app/lib/libClusterHook.so"
READELF="${READELF:-arm-linux-gnueabihf-readelf}" "$HERE/inject_dt_needed.sh" "$WORK/app/bin/CPAAProxyEx"

echo "== mksquashfs (xz, ${BLOCK}B block) =="
OUT="$HERE/app.cluster.bin"
rm -f "$OUT"
mksquashfs "$WORK/app" "$OUT" -comp xz -b "$BLOCK" -all-root -noappend -no-progress >/dev/null
NEW=$(stat -c%s "$OUT")
printf "   new app size: %d bytes (0x%x); budget: %d (0x%x)\n" "$NEW" "$NEW" "$APP_MAXSIZE" "$APP_MAXSIZE"
if [ "$NEW" -gt "$APP_MAXSIZE" ]; then
    echo "ERROR: repacked app exceeds the partition budget — cannot flash."; exit 1
fi
echo "   OK, fits. Wrote $OUT"

if [ -n "$DUMP" ]; then
    echo "== splice into dump at 0x7e0000 =="
    BK="${DUMP}.bak.$(date +%Y%m%d_%H%M%S)"; cp "$DUMP" "$BK"; echo "   backup: $BK"
    dd if="$OUT" of="$DUMP" bs=1 seek="$APP_OFFSET" conv=notrunc status=none
    echo "   patched $DUMP (app region). Flash with:  xfel spinor write 0x7e0000 $OUT"
    echo "   (or write the whole dump back as per README)."
fi

cat <<EOF

Done.
  app image : $OUT
To enable the hook on the device, ensure CPAAProxyEx starts with
CLUSTER_HOOK_ENABLE=1 (see README). With it unset, CarPlay is unchanged.
EOF
