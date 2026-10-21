# Build libClusterHook.so for the V851S dongle (ARM EABI5, musl runtime).
#
# The dongle's CPAAProxyEx links against musl (/lib/ld-musl-armhf.so.1). We build
# with the glibc ARM cross-gcc but pass -nostdlib so the resulting .so carries NO
# libc DT_NEEDED at all — every external symbol (dlsym, getenv, MLOGD, CF*) is
# left undefined and resolved at load time from the musl libc and AirPlay libs
# already mapped into the CPAAProxyEx process. This avoids the glibc-vs-musl
# mismatch entirely.
#
#   make            # build libClusterHook.so
#   make verify     # show it has no NEEDED libc and exports the hook symbol
#   make clean

CROSS  ?= arm-linux-gnueabihf-
CC      = $(CROSS)gcc
READELF = $(CROSS)readelf

CFLAGS  = -O2 -fPIC -ffreestanding -fno-stack-protector -fno-builtin \
          -marm -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -Wall -Wextra
LDFLAGS = -shared -nostdlib -Wl,--no-undefined-version -Wl,-soname,libClusterHook.so

TARGET  = libClusterHook.so
SRC     = libClusterHook.c

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

.PHONY: verify clean
verify: $(TARGET)
	@echo "== file =="; file $(TARGET)
	@echo "== NEEDED (should be empty — no libc) =="; $(READELF) -d $(TARGET) | grep NEEDED || echo "  (none)"
	@echo "== exported hook symbol =="; $(READELF) --dyn-syms $(TARGET) | grep -E 'AirPlayInfoArrayAddScreenDisplay|cluster_request_ui' || true

clean:
	rm -f $(TARGET)
