#!/bin/bash
#
# extract_partitions.sh - Carve and decompress all partitions from the SPI NOR dump.
#
# Unlike mount_partitions.sh this needs no root and no loop/MTD mounts: it carves
# each partition with dd, decompresses the SquashFS filesystems with unsquashfs,
# carves the kernel/ramdisk out of the Android boot image, and (best effort)
# unpacks the JFFS2 volumes if `jefferson` is installed.
#
# Usage:
#   tools/extract_partitions.sh <flash_dump.bin> [output_dir]
#
# Defaults output_dir to dumps/spi_flash/extracted/
#
# Requires: dd, python3, unsquashfs (squashfs-tools). Optional: jefferson (JFFS2).

set -u

DUMP="${1:-dumps/spi_flash/extracted_partitions/flash_dump_fixed.bin}"
OUT="${2:-dumps/spi_flash/extracted}"

if [ ! -f "$DUMP" ]; then
    echo "Error: dump '$DUMP' not found" >&2
    exit 1
fi

# name offset size  (hex, from the device DTS / U-Boot partition table)
PARTS=(
    "uboot       0x00000000 0x00060000"
    "boot        0x00060000 0x00240000"
    "rootfs      0x002a0000 0x00490000"
    "rootfs_data 0x00730000 0x00080000"
    "env         0x007b0000 0x00020000"
    "private     0x007d0000 0x00010000"
    "app         0x007e0000 0x006c0000"
    "udisk       0x00ea0000 0x00160000"
)

RAW="$OUT/raw"
mkdir -p "$RAW"

echo "== Carving partitions from $DUMP =="
for p in "${PARTS[@]}"; do
    read -r name off size <<< "$p"
    # 64 KiB block carve (all offsets/sizes are 64 KiB aligned)
    dd if="$DUMP" of="$RAW/$name.bin" bs=65536 \
        skip=$(( off / 65536 )) count=$(( size / 65536 )) status=none
    printf "  %-12s off=%s size=%s -> %s\n" "$name" "$off" "$size" "$RAW/$name.bin"
done

# ---- SquashFS filesystems ----
for fs in rootfs app; do
    src="$RAW/$fs.bin"
    dst="$OUT/$fs"
    if command -v unsquashfs >/dev/null 2>&1; then
        echo "== unsquashfs $fs -> $dst =="
        rm -rf "$dst"
        unsquashfs -no-progress -d "$dst" "$src" >/dev/null \
            && echo "  OK ($(find "$dst" -type f | wc -l) files)" \
            || echo "  FAILED"
    else
        echo "!! unsquashfs not found; skipping $fs (install squashfs-tools)" >&2
    fi
done

# ---- Android boot image: carve kernel + ramdisk ----
echo "== Unpacking Android boot image (boot.bin) =="
python3 -I - "$RAW/boot.bin" "$OUT/boot" <<'PY'
import sys, os, struct, math
src, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
with open(src, 'rb') as f:
    h = f.read(1648)
    if h[:8] != b'ANDROID!':
        print("  not an Android boot image; skipping"); sys.exit(0)
    (ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, ver, osver) = \
        struct.unpack('<10I', h[8:48])
    def carve(name, off, size):
        if size == 0: return
        with open(src, 'rb') as g:
            g.seek(off); data = g.read(size)
        path = os.path.join(outdir, name)
        with open(path, 'wb') as o:
            o.write(data)
        print(f"  {name:16} off=0x{off:x} size={size} (0x{size:x})")
    kpages = math.ceil(ksz / page)
    rpages = math.ceil(rsz / page)
    koff = page
    roff = (1 + kpages) * page
    soff = (1 + kpages + rpages) * page
    carve("kernel.Image", koff, ksz)
    carve("ramdisk.img",  roff, rsz)
    carve("second.img",   soff, ssz)
    print(f"  page_size={page} kernel_addr=0x{kaddr:x} ramdisk_addr=0x{raddr:x} tags_addr=0x{tags:x}")
PY

# ---- JFFS2 volumes (best effort) ----
for jf in rootfs_data udisk; do
    src="$RAW/$jf.bin"
    dst="$OUT/$jf"
    if command -v jefferson >/dev/null 2>&1; then
        echo "== jefferson $jf -> $dst =="
        rm -rf "$dst"; mkdir -p "$dst"
        jefferson -d "$dst" "$src" >/dev/null 2>&1 \
            && echo "  OK ($(find "$dst" -type f 2>/dev/null | wc -l) files)" \
            || echo "  (jefferson failed or volume empty)"
    else
        echo "!! jefferson not found; left $jf as raw ($src). Install with: pip install jefferson" >&2
    fi
done

echo
echo "Done. Extracted tree under: $OUT"
