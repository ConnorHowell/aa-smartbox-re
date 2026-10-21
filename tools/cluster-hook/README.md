# cluster-hook — CarPlay 2nd display (Audi Virtual Cockpit) for the V851S dongle

Scaffold for porting omke/wireless-carplay-virtual-cockpit's "CarPlay → instrument
cluster" trick to this dongle's ARM `CPAAProxyEx`. Background and the full
reverse-engineering map are in [`../../info/virtual_cockpit_port.md`](../../info/virtual_cockpit_port.md).

## What works today

- **Hook A — advertise the cluster display to the phone:** implemented. We
  interpose the imported `AirPlayInfoArrayAddScreenDisplay` (resolved from
  `libAirPlay.so`); after the stock main-display entry we append a cluster entry
  (`b7e6c5a0-2222-4000-8000-000000000002`, 1440×540), so iOS offers the type-111
  stream.
- **Hook B — showUI activation:** helper `cluster_request_ui()` is present but
  **not wired** (it needs the receiver session pointer, which only hook C has).
- **Hook C — relay the 2nd stream to the car:** **not implemented.** The stock
  relay (`SendProxyScreenFrame`) uses a single global screen context with no
  stream index, so the cluster needs its own parallel context + private relay.
  This is the remaining work; see the design doc.

> So this scaffold makes the cluster display **appear in the phone-facing
> `/info`** (verifiable in logs) but does not yet put the map on the cluster.
> Treat it as the plumbing + hook A, not a finished feature.

## Safety

Everything is gated behind the env var **`CLUSTER_HOOK_ENABLE=1`**. Unset (the
default), every interposed call forwards straight to the real function and the
dongle is bit-for-bit stock in behaviour. The hook lib is also added as a
`DT_NEEDED`, so if it fails to load the loader errors early — keep a stock
`app.bin` backup (the repack script makes dump backups automatically).

## Build

Needs an ARM cross-compiler and `patchelf` + `squashfs-tools` on the build host:

```sh
sudo apt-get install gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf patchelf squashfs-tools
make                 # -> libClusterHook.so (ARM, no libc DT_NEEDED)
make verify          # confirms: no NEEDED libc, exports the hook symbol
```

The `.so` is built `-nostdlib`: it has **no `libc` dependency**; its externs
(`dlsym`, `getenv`, `MLOGD`, `CFStringCreateWithCString`, `CFRelease`,
`AirPlayReceiverSessionRequestUI`) are resolved at load time from the musl libc
and AirPlay libs already mapped into the `CPAAProxyEx` process (all confirmed
present in `app/lib` + `rootfs/lib`).

## Install into the app partition

```sh
# produces app.cluster.bin, size-checked against the 0x6c0000 budget
../cluster-hook/repack_app.sh ../../dumps/spi_flash/extracted/raw/app.bin

# ...or also splice it straight into a full flash dump at 0x7e0000 (makes a backup):
../cluster-hook/repack_app.sh ../../dumps/spi_flash/extracted/raw/app.bin ../../dumps/spi_flash/extracted_partitions/flash_dump_fixed.bin
```

`repack_app.sh` unsquashfs-es the stock app, drops in `libClusterHook.so`,
`patchelf`-injects it as the **first** `DT_NEEDED` of `CPAAProxyEx` (so it
interposes `libAirPlay.so`), and `mksquashfs`-es back with the stock params
(xz, 256 KiB block, all-root).

Flash the result via FEL (`xfel spinor write 0x7e0000 app.cluster.bin`) or write
the whole dump back, per the top-level README. For fast iteration you can instead
push `libClusterHook.so` and the patched `CPAAProxyEx` over the telnet/ADB root
shell into a writable copy — but `/mnt/app` is a read-only SquashFS, so a real
install means reflashing the app partition.

## Enabling it on the device

Adding the lib does nothing until `CPAAProxyEx` runs with `CLUSTER_HOOK_ENABLE=1`.
Options:
- Edit `rc.final` in the **rootfs** partition to `export CLUSTER_HOOK_ENABLE=1`
  before `CPAAProxyEx &` (needs a rootfs repack/flash too), or
- From a telnet shell: `kill` CPAAProxyEx and relaunch with the env var set
  (quickest for testing).

Then watch the log for `ClusterHook ... added cluster display 1440x540`.

## Files

| file | role |
|---|---|
| `libClusterHook.c` | the hook lib (A implemented, B helper, C TODO) |
| `Makefile` | ARM `-nostdlib` build |
| `inject_dt_needed.sh` | patchelf a first `DT_NEEDED` + assert ordering |
| `repack_app.sh` | unsquashfs → inject → mksquashfs → size-check → (splice) |

Build artifacts (`libClusterHook.so`, `app.cluster.bin`) are git-ignored.
