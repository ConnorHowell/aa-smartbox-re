# Latency Analysis — AA SmartBox (V851S wireless CarPlay/AA dongle)

Analysis derived from the 16 MB SPI-NOR dump (`flash_dump_fixed.bin`), extracted with
`tools/extract_partitions.sh`. Findings come from the init scripts, the proxy/codec
binaries (`app/bin/CPAAProxyEx`, `app/bin/gocsdk`, `app/lib/*.so`), the device tree
(`info/decompiled-tree-linux.dts`) and the U-Boot env.

## The data path

```
  Phone  --(Wi-Fi: wireless CarPlay AP / AA WiFi-Direct P2P)-->  Dongle (V851S)  --(USB, emulated iPhone/AOA)-->  Car head unit
```

The dongle is an **AirPlay/GAL receiver** from the phone and a **video source** to the
car. It does **not** simply forward the phone's H.264 stream: it
**decodes → composites its own UI → re-encodes** and streams the result to the car.
Evidence: `CPAAProxyEx` contains `SendProxyScreenFrame`, `ScreenStreamSetWidthHeight`,
`ON_SET_CAR_RESOLUTION`, `sendRequestKeyFrame`, an LVGL UI (`liblvgl.so`), a hardware
decoder path (`libDecEnc.so` → CedarX `libawh264/awh265`, ION, G2D) **and** a full
software **x264** encoder.

## Hardware ceiling

| Item | Value | Why it matters for latency |
|------|-------|----------------------------|
| CPU | Allwinner V851S, **single** Cortex-A7, OPP 408 MHz–**1.2 GHz** (DTS has only `cpu@0`) | No second core to absorb encode + WiFi + protocol work |
| Wi-Fi | **Realtek RTL8733BS**, 1×1 **802.11b/g/n, 2.4 GHz only** (`8733bs.ko`, loaded in `rc.final`) | 2.4 GHz is congested; 1×1 n caps ~72 Mbps PHY (realistically far less). Genuine low-latency wireless CarPlay uses **5 GHz**. This is the single biggest structural limit. |
| Video decode | CedarX hardware (H.264/H.265/MJPEG) | Fine — not a bottleneck |
| Video encode | **x264 software** in `CPAAProxyEx`; **no hardware encoder path** found | Software H.264 encode on one A7 core is the dominant CPU/latency cost |

## Ranked latency contributors

### 1. Software (x264) re-encode on a single Cortex-A7  — *dominant, high confidence*
`CPAAProxyEx` carries the full x264 string set (`vbv_maxrate`, `rc_lookahead`,
`bframes`, `sliced_threads`, `lookahead_threads`, `crf`, `cabac`, `me`, `subme`,
`trellis`, `frame=… QP=… NAL=…`). The V851S has a hardware H.264 encoder (Cedar VE),
but the proxy does not use it — all car-facing frames are encoded in software on the
one available core. x264's threading knobs are moot with a single core.

Levers: ensure `--preset ultrafast --tune zerolatency` behaviour (no B-frames,
`rc_lookahead=0`, `sync-lookahead=0`, slice-based, `intra-refresh` instead of periodic
IDR). Better: move encode to the Cedar hardware encoder. Best: pass the phone's stream
through without a decode/encode round-trip where the car's requested format allows it.

### 2. Wi-Fi is 2.4 GHz-only, 1×1 802.11n  — *structural, high confidence*
`rc.final` loads `8733bs.ko` with `rtw_country_code='CN'`. The RTL8733BS has no 5 GHz
radio, so the phone link is always 2.4 GHz. Under real-world 2.4 GHz congestion this
produces throughput collapse and jitter that no software change can fully fix — it is a
hardware limitation of this dongle. (`hostapd.conf` in the image says `hw_mode=a
channel=36`, i.e. 5 GHz, but it is a stale test file — `ssid=BoxTestAP` — and is never
started: the `hostapd` line in `startap.sh` is commented out.)

### 3. CPU governor pinned to `performance` only for Android Auto, not CarPlay  — *high confidence*
`gocsdk` (the Android-Auto/GAL binary) runs `echo performance >
/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`. `CPAAProxyEx` (CarPlay) does
**not**. Nothing in `/etc/init.d` sets a governor at boot either. So during CarPlay the
CPU is left on the kernel default governor and can sit at a low OPP / ramp slowly —
exactly wrong for a bursty software encoder. Expect **CarPlay to feel laggier than
Android Auto** on this box.

Fix: set `performance` (or pin `scaling_min_freq` to 1.2 GHz) at boot in `rc.final`,
before `CPAAProxyEx` starts.

### 4. Wi-Fi power save (LPS/IPS) never disabled  — *medium confidence*
`8733bs.ko` contains the Realtek LPS (Leisure Power Save) / IPS machinery (`LPS ON/OFF`,
`LPS_CTRL_*`). No `rtw_power_mgnt=0` / `rtw_ips_mode=0` override is passed at insmod and
nothing disables PS from userspace, so the driver's compiled-in default (usually PS
**on**) is likely active. Wi-Fi power save adds tens of ms of periodic latency and
jitter on an interactive stream.

Fix: load with `rtw_power_mgnt=0 rtw_ips_mode=0` (or disable PS on `wlan0` once up).

### 5. Networking sysctls — *minor*
- `S41netparam` sets `tcp_low_latency=0` (deprecated knob, minor) and a small
  `wmem_max=307200`; `startap.sh` later raises socket buffers (`rmem_max=2 MB`,
  `wmem_max=1 MB`) and disables IPv6 on `wlan0/wlan1`. Order is fine (rc.final runs
  last).
- `cedarx.conf` has large player cache defaults (`start_play_cache_time = 5` s,
  `cache_buffer_size = 20480` KB). These apply to the CedarX **media player**, not the
  low-delay mirror path, so they should be irrelevant to mirroring latency — worth
  confirming the mirror decode uses the direct `libDecEnc` low-delay path and not the
  cached player.

## Suggested experiments (in rough priority order)

1. **Pin the governor for CarPlay** — add to `rc.final` before `CPAAProxyEx &`:
   `echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`.
   Cheapest possible win; measurable immediately.
2. **Disable Wi-Fi power save** — reload `8733bs.ko` with `rtw_power_mgnt=0 rtw_ips_mode=0`.
3. **Confirm the encoder is zero-latency** — instrument/flag `CPAAProxyEx` x264 params
   (bframes, rc_lookahead); force zerolatency if not already.
4. **Move encode to Cedar hardware** or passthrough the phone stream — the big
   architectural win, but the most work.
5. The 2.4 GHz radio is a hard ceiling; keep the car and phone physically close, pick a
   clear 2.4 GHz channel, and set expectations accordingly.

## Notes / open questions
- Whether the *entire* phone video is transcoded or only the dongle's UI/overlay screens
  is not 100% provable from strings alone; the screen-stream + resolution-negotiation +
  keyframe-request machinery in `CPAAProxyEx`, plus the absence of any hardware-encode
  path, strongly indicates the car-facing stream is x264-encoded in the hot path.
  Runtime tracing (`top`/`perf` on the device during a session) would confirm.
