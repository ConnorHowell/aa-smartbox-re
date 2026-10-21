# Porting the "CarPlay → instrument cluster" patch to the V851S dongle

Goal: make the Pionray / V851S dongle (`CPAAProxyEx`) carry a **second CarPlay
display** (the Audi Virtual Cockpit) over wireless, the way
[`omke/wireless-carplay-virtual-cockpit`](https://github.com/omke/wireless-carplay-virtual-cockpit)
does for the MIPS "Smart Box AX1800M" (`sdDongle`).

Target cluster values (from omke / Audi MHI2Q + MIBSI, assumed identical here):
`uuid b7e6c5a0-2222-4000-8000-000000000002`, `1440×540`, viewArea `0,0,1440,540`,
showUI url `maps:/car/instrumentcluster/map`.

> Status: **static analysis only** (radare2 + pyelftools on the extracted
> `app/bin/CPAAProxyEx`). Nothing here has been run on hardware. Addresses are
> file VAs in the stock binary analysed; re-verify against your exact firmware
> build before patching.

---

## Why your car-side patch fails through the dongle

Same root cause omke documented. Over a **cable**, iOS talks to the head unit
directly, sees the MIBSI second display in the car's AirPlay `/info`, and sends a
second H.264 stream (type `111`/`0x6f`) with the cluster map. Through the
**dongle**, `CPAAProxyEx` is an AirPlay *receiver* to the phone and *sender* to
the car, and it is built around a **single screen**:

- It advertises **one** display to the phone (one `AirPlayInfoArrayAddScreenDisplay`
  call, at `0xd625c`), so iOS never offers the cluster stream.
- Its car-side SETUP hardcodes stream **type `0x6e` (110 = main)** and relays
  through a **single global screen context**.

So the cluster display is dropped in the middle. No car-side change can fix it;
the dongle has to be taught to (a) advertise the 2nd display to the phone,
(b) activate it, and (c) relay the 2nd stream to the car's cluster socket.

---

## Good news: this binary is far friendlier than `sdDongle`

| | omke `sdDongle` | this `CPAAProxyEx` |
|---|---|---|
| Arch | MIPS32r2 LE | **ARM EABI5 LE** |
| Layout | `ET_EXEC`, fixed VAs | `ET_EXEC`, fixed VAs (same — good for patching) |
| Symbols | fully stripped (omke recovered everything by hand) | **`.dynsym` exports 966 named functions with addresses** — effectively a symbol map |
| AirPlay core | statically linked in | **imported from `libAirPlay.so`** via PLT — interposable by `LD_PRELOAD`/`DT_NEEDED` |

Two consequences:

1. The **phone-facing** AirPlay functions are *imports* (`sym.imp.*`), so a
   preloaded/needed library that exports the same symbol **wins resolution** and
   intercepts them — no binary patch needed for that half.
2. The **car-facing** proxy-screen functions are *exported* from the executable
   at fixed VAs, so the hook library can **call them directly** (by address, or
   `dlsym`) instead of reconstructing them.

---

## Data flow and the exact hook points

```
iPhone ──AirPlay/Wi-Fi──▶ libAirPlay.so (receiver) ──▶ CPAAProxyEx bridge ──AirPlay/USB──▶ car (MHI2Q+MIBSI) ──▶ VC
        advertise displays │                           single global screen ctx │ type 110 hardcoded
```

### A. Phone-facing: advertise the 2nd display  — *imported, easy*
- **`AirPlayInfoArrayAddScreenDisplay`** (import from `libAirPlay.so`), called
  **once** at `0xd625c`, inside the receiver-`/info` builder
  (`fcn` spanning ~`0xd5a00–0xd6418`; it `CFEqual`-matches a display then adds it).
- **Hook:** interpose this import. On the call that adds the main display, also
  add a second entry for the cluster (uuid/w/h/type above). iOS then offers
  stream `111`.
- Need from libAirPlay.so: the function signature / how a display entry is built
  (its args — info array, uuid CFString, width, height, type, fps, …). Decompile
  it there (it is exported from `libAirPlay.so`).

### B. Activation: tell iOS to show the cluster UI  — *imported, medium*
- **`AirPlayReceiverSessionSendCommand`**, **`AirPlayReceiverSessionRequestUI`**,
  **`AirPlayReceiverSessionForceKeyFrame`** — all imports.
- **Hook:** when the phone connects the 111 data socket, send
  `showUI {uuid, url:"maps:/car/instrumentcluster/map"}` via
  `AirPlayReceiverSessionSendCommand`, and `ForceKeyFrame` until the first IDR.
- omke's warning applies: `SendCommand` does a `dispatch_sync`, so don't call it
  from inside a SETUP callback (deadlock) — call it from the frame/sink thread.

### C. Car-facing: set up + relay the 2nd stream  — *internal, hard*
This is the real work, and it differs from omke because the relay here is **not
context-parameterised**.

- **Car SETUP builder** (the worker `AirplayClientSendCmdSetupScreen@0xd7168`
  dispatches via `dispatch_async_f`): **`fcn.0xd66f8`**.
  - `GetRandomUUID64@0xd6778` → global `streamConnectionID`.
  - `0xd67d4: mov r2, 0x6e` → `CFDictionarySetInt64(dict, "type", 0x6e)` — **the
    hardcoded main type**. A cluster SETUP needs `0x6f` here and the cluster uuid
    instead of the main screen uuid.
- **SETUP entry points:** `SetupProxyScreen@0xd7214` → tail-calls
  `SetupProxyScreenEx@0xd71a0` (arg2 = `0x1388` = 5000, a latency/ms). Both act on
  one **global screen context** (mutex at `ctx+0x260`, setup flag `ctx+0`,
  session `ctx+4`, active byte `ctx+8`, crypto ctx `ctx+0xc`).
- **Frame relay:** **`SendProxyScreenFrame@0xd7590`** — builds a 128-byte header,
  encrypts the body with **ChaCha20-Poly1305** (`chacha20_poly1305_init_64x64` /
  `_add_aad`) using that **same single global context**. **It takes no ctx
  argument** (args are frame buffer/len). Related:
  `SendProxyScreenVideoConfigFrame@0xd72e0`, `SendProxyScreenKeepAliveFrame@0xd7840`,
  `TearDownProxyScreen@0xd724c`, `ProxyScreenIsSetup@0xd6c24`,
  `SetupProxyScreenSecurityInfo@0xd6908`.

Because the global context and `SendProxyScreenFrame` are hard-wired to one
screen, a second stream needs one of:
1. **A parallel cluster context + a private relay** in the hook lib: allocate a
   second ctx, run its own type-111 SETUP to the car, derive its keys, and write
   its frames (replicate the 0x80 header + ChaCha + socket write that
   `SendProxyScreenFrame` does). Cleanest, most code. *(This is the analog of
   what omke did, but omke could reuse `push_frame(ctx,…)`; here you reimplement
   the send because it isn't parameterised.)*
2. **Binary-patch `SendProxyScreenFrame`/`SetupProxyScreenEx`** to take a ctx
   pointer instead of the global, then drive two contexts. Smaller patch surface
   but riskier (touches the hot path).

---

## Recommended injection mechanism

Mirror omke, adapted to ARM:

- Build a small **`libClusterHook.so`** (ARM, musl) that:
  - **exports** `AirPlayInfoArrayAddScreenDisplay` (and any other imports you
    interpose), forwarding to the real one via `dlopen("libAirPlay.so")` +
    `dlsym` and adding the cluster entry;
  - in a **constructor**, resolves `CPAAProxyEx`'s exported proxy-screen symbols
    (fixed VAs / `dlsym(RTLD_DEFAULT,…)`) and sets up the cluster relay.
- **Load it** by adding a **`DT_NEEDED libClusterHook.so`** (and `DT_RUNPATH
  $ORIGIN`) to `CPAAProxyEx`, placed **before `libAirPlay.so`** so the interposed
  symbol wins — no change to the read-only `rootfs` (`rc.final`) needed. (Omke did
  exactly this.) Alternative: add `LD_PRELOAD=/mnt/app/lib/libClusterHook.so` to
  `rc.final`, but that means repacking the `rootfs` SquashFS too.
- **Fallback:** if the lib fails to load, the stock path runs and normal CarPlay
  is unaffected — keep that property (don't hard-fail the constructor).

### Delivery / flashing
`/mnt/app` is the `app` SquashFS (read-only). Workflow:
1. `unsquashfs` the `app` partition, drop in `libClusterHook.so`, apply the
   `DT_NEEDED` edit to `CPAAProxyEx`, `mksquashfs` back (xz, 256 KiB block — match
   the original superblock).
2. Write the new `app` partition into the dump at `0x7e0000` and flash via FEL
   (`tools/mount_partitions.sh write … app`, then `xfel spinor write`), or push
   the files live over the telnet/ADB root shell for faster iteration.
3. Keep a stock `app.bin` backup to restore.

---

## Open questions to resolve before building the full patch

1. **`libAirPlay.so` display-entry API** — exact signature of
   `AirPlayInfoArrayAddScreenDisplay` and how the main entry is constructed
   (decompile in `libAirPlay.so`). Determines how to add the 2nd display.
2. **Does the car's 2nd display even reach the dongle?** Confirm `HeadUnitInfo` /
   the "Recv proxy disply count:%d" path records both displays (so you can read
   the real cluster uuid/size at runtime instead of hardcoding). If the dongle
   drops it on receive too, that's an extra hook.
3. **2nd-stream key derivation** — per omke the phone→dongle 111 stream is
   ChaCha20-Poly1305 (`DataStream-Salt`/`-Output-Encryption-Key`); the dongle→car
   side here already uses ChaCha (`SendProxyScreenFrame`). Map the receiver-side
   key source (`GetStreamSecurityKeys` equivalent) for the cluster connID.
4. **Receiver frame routing** — how do decrypted 2nd-stream frames arrive?
   (`CarPlayProxyApp::recvCarPlayVideoFrame`, `setCarPlayVideoProcessCallBack`,
   and the single global data callback.) They must be routed to the cluster ctx,
   not the main one.
5. **Per-ctx send vs patch** — decide path (1) vs (2) above after reading the
   receiver routing.

## Symbol / address quick-reference (stock binary analysed)

| VA | Symbol | Role |
|---|---|---|
| `0xd625c` | (receiver-info builder) | the single `AirPlayInfoArrayAddScreenDisplay` call |
| `0xd66f8` | async car-SETUP builder | sets `type=0x6e`, global `streamConnectionID` |
| `0xd7168` | `AirplayClientSendCmdSetupScreen` | dispatches the SETUP builder |
| `0xd71a0` | `SetupProxyScreenEx` | main screen setup (global ctx) |
| `0xd7214` | `SetupProxyScreen` | wrapper (latency 5000) |
| `0xd724c` | `TearDownProxyScreen` | |
| `0xd72e0` | `SendProxyScreenVideoConfigFrame` | avcC/config to car |
| `0xd7590` | `SendProxyScreenFrame` | video relay to car (ChaCha, global ctx, **no ctx arg**) |
| `0xd6908` | `SetupProxyScreenSecurityInfo` | stream key setup |
| `0xd6c24` | `ProxyScreenIsSetup` | |
| import | `AirPlayInfoArrayAddScreenDisplay` | advertise display to phone (hook A) |
| import | `AirPlayReceiverSessionSendCommand` / `RequestUI` / `ForceKeyFrame` | activate cluster (hook B) |

Full raw string/xref evidence for this analysis is reproducible from
`dumps/spi_flash/extracted/app/bin/CPAAProxyEx` with radare2 (`aa`, `axt`, `pdf`).
