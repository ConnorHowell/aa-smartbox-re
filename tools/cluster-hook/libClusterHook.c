/*
 * libClusterHook.so — add a second CarPlay display (Audi Virtual Cockpit /
 * instrument cluster) to the V851S "CPAAProxyEx" wireless-CarPlay dongle.
 *
 * This is the ARM/CPAAProxyEx analogue of omke/wireless-carplay-virtual-cockpit's
 * libSdH.so (which targets the MIPS sdDongle). See info/virtual_cockpit_port.md
 * for the full reverse-engineering writeup and the hook-point map.
 *
 * Status of the three hooks (see README.md):
 *   A. advertise the cluster display to the phone  — IMPLEMENTED here.
 *   B. showUI activation when the 2nd stream opens  — helper provided, NOT wired.
 *   C. relay the 2nd (type-111) stream to the car   — NOT implemented (needs a
 *      parallel screen context; the stock relay is single-context, see the doc).
 *
 * SAFETY: everything is gated behind the env var CLUSTER_HOOK_ENABLE=1. When it
 * is unset (the default), every interposed function forwards straight to the
 * real implementation and the dongle behaves exactly like stock. Enable it only
 * for bench testing until hook C exists — advertising a display the dongle does
 * not yet relay can disturb the main screen.
 *
 * Build: see Makefile (arm-linux-gnueabihf-gcc, -nostdlib -shared -fPIC). The
 * .so deliberately has NO libc DT_NEEDED; every external symbol below is
 * resolved at load time from the already-loaded musl libc and the AirPlay libs
 * inside the CPAAProxyEx process.
 */

/* ---- externs resolved from the running process (musl libc + CF shim) ---- */
extern void *dlsym(void *handle, const char *symbol);
extern char *getenv(const char *name);
extern int   MLOGD(const char *tag, const char *fmt, ...); /* dongle logger */

/* CoreFoundation-lite shim (exported by libCoreUtils/libAirPlay in-process) */
extern void *CFStringCreateWithCString(void *alloc, const char *cStr, unsigned enc);
extern void  CFRelease(void *cf);
#define kCFStringEncodingUTF8 0x08000100u

#define RTLD_NEXT ((void *)-1L)

/* ---- the function we interpose (ABI recovered in virtual_cockpit_port.md) ----
 * int AirPlayInfoArrayAddScreenDisplay(
 *     void **infoArray, CFStringRef uuid,
 *     long features, long primaryInputDevice, long maxFPS,
 *     long widthPixels, long heightPixels, long widthPhysical, long heightPhysical);
 * All numeric fields are 32-bit slots on ARM32 (the stock code zero-extends each
 * to the int64 that CFDictionarySetInt64 wants). */
typedef int (*add_screen_fn)(void **, void *, long, long, long, long, long, long, long);

/* ---- Audi MHI2Q + MIBSI cluster identity (from omke; change for other mods) ---- */
#define CLUSTER_UUID "b7e6c5a0-2222-4000-8000-000000000002"
#define CLUSTER_W    1440
#define CLUSTER_H    540

#define TAG "ClusterHook"

static int hook_enabled(void)
{
    char *v = getenv("CLUSTER_HOOK_ENABLE");
    return v && v[0] == '1';
}

/*
 * Hook A — interpose the single AirPlayInfoArrayAddScreenDisplay call the proxy
 * makes while building the receiver /info for the phone. Forward the real (main)
 * display, then append a cluster entry so iOS offers the type-111 stream.
 */
int AirPlayInfoArrayAddScreenDisplay(void **infoArray, void *uuid,
                                     long features, long primaryInputDevice,
                                     long maxFPS, long widthPixels,
                                     long heightPixels, long widthPhysical,
                                     long heightPhysical)
{
    static add_screen_fn real;
    if (!real)
        real = (add_screen_fn)dlsym(RTLD_NEXT, "AirPlayInfoArrayAddScreenDisplay");

    /* main display, unchanged */
    int rc = real(infoArray, uuid, features, primaryInputDevice, maxFPS,
                  widthPixels, heightPixels, widthPhysical, heightPhysical);

    if (hook_enabled() && real) {
        void *cu = CFStringCreateWithCString(0, CLUSTER_UUID, kCFStringEncodingUTF8);
        if (cu) {
            /* reuse the main display's features + fps; no input device on the
             * cluster; physical size left 0 (refine once confirmed on-car). */
            long fps = maxFPS ? maxFPS : 30;
            int rc2 = real(infoArray, cu, features, 0 /*primaryInputDevice*/, fps,
                           CLUSTER_W, CLUSTER_H, 0 /*wmm*/, 0 /*hmm*/);
            CFRelease(cu);
            MLOGD(TAG, "added cluster display %dx%d uuid=%s (rc=%d)",
                  CLUSTER_W, CLUSTER_H, CLUSTER_UUID, rc2);
        } else {
            MLOGD(TAG, "CFStringCreateWithCString(cluster uuid) failed");
        }
    }
    return rc;
}

/*
 * Hook B — ask iOS to put the cluster map on the 2nd display. Build to be called
 * from hook C once the type-111 stream is set up (it needs the receiver session
 * pointer, which only hook C has). Not invoked yet.
 *
 * omke's warning carries over: AirPlayReceiverSessionSendCommand does a
 * dispatch_sync, so never call it from inside a SETUP callback (deadlock) — call
 * it from the frame/sink thread.
 */
extern int AirPlayReceiverSessionRequestUI(void *session, void *uuid, const char *url);
int cluster_request_ui(void *session)
{
    if (!session) return -1;
    void *cu = CFStringCreateWithCString(0, CLUSTER_UUID, kCFStringEncodingUTF8);
    int rc = AirPlayReceiverSessionRequestUI(session, cu,
                                             "maps:/car/instrumentcluster/map");
    if (cu) CFRelease(cu);
    MLOGD(TAG, "cluster_request_ui rc=%d", rc);
    return rc;
}

/* Constructor: runs from DT_INIT_ARRAY (the musl loader calls it even with
 * -nostdlib). Just announces load state so you can confirm interposition. */
__attribute__((constructor))
static void cluster_hook_init(void)
{
    MLOGD(TAG, "libClusterHook loaded; enabled=%d (set CLUSTER_HOOK_ENABLE=1)",
          hook_enabled());
}
