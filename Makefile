PS5_PAYLOAD_SDK ?= /opt/ps5-payload-sdk
include $(PS5_PAYLOAD_SDK)/toolchain/prospero.mk

VERSION_TAG := $(shell git describe --abbrev=6 --dirty --always --tags 2>/dev/null || echo unknown)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Compiler and dependency flags
HOMEBREW_ROOT := $(PS5_PAYLOAD_SDK)/target/user/homebrew
HOMEBREW_CFLAGS := -I$(HOMEBREW_ROOT)/include
MHD_LIB := $(HOMEBREW_ROOT)/lib/libmicrohttpd.a
PNG_LIB := $(HOMEBREW_ROOT)/lib/libpng16.a
ZLIB_LIB := $(HOMEBREW_ROOT)/lib/libz.a
CFLAGS := -O3 -flto=thin -DNDEBUG -ffunction-sections -fdata-sections -Wall -Wextra -Wstrict-prototypes -Wmissing-prototypes -Werror=strict-prototypes -Werror=missing-prototypes -D_BSD_SOURCE -std=gnu11 -Iinclude -Isrc
CFLAGS += -DSHADOWMOUNT_VERSION=\"$(VERSION_TAG)\"

# Linker
LDFLAGS := -flto=thin -Wl,--gc-sections

# Libraries. Every entry is 1.7's; -lSceIpmi is the environment service's.
LIBS := -lSceNotification -lSceSystemService -lSceUserService -lSceAppInstUtil -lSceNet -lSceSsl -lSceHttp -lsqlite3 $(HOMEBREW_ROOT)/lib/libjson-c.a $(MHD_LIB) $(PNG_LIB) $(ZLIB_LIB) -lSceIpmi -lpthread -lm
PS5_SCE_STUBS_DIR ?= $(PS5_PAYLOAD_SDK)/src/sce_stubs
KERNEL_SYS_STUB_SO := src/libkernel_sys_ext.so
KERNEL_SYS_STUB_SRCS := $(PS5_SCE_STUBS_DIR)/libkernel_sys.c src/libkernel_sys_ext.c

ASSET_SRCS := src/notify_icon_asset.c src/config_ini_example_asset.c src/web_index_asset.c
ASSET_SRCS += src/shell_icon_param_asset.c
# The environment IPMI service. Named explicitly rather than swept up by the
# src/sm_*.c wildcard, because three of its four sources are not sm_ prefixed.
IPMI_SRCS := src/ipmi_symbols.c src/ipmi_client.c src/ipmi_handler.c
SRCS := src/main.c $(wildcard src/sm_*.c) $(IPMI_SRCS) $(ASSET_SRCS)
ASM_SRCS := src/sm_shellcore_bridge.S
OBJS := $(SRCS:.c=.o) $(ASM_SRCS:.S=.o)
HEADERS := $(wildcard include/*.h)
L10N_CATALOGS := $(wildcard include/lang/*.inc)

# Targets
all: shadowmountplus.elf

usb-info.elf: tools/usb_info.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< -lSceNotification
	$(PS5_PAYLOAD_SDK)/bin/prospero-strip --strip-all $@

# Build Daemon
shadowmountplus.elf: $(OBJS) $(KERNEL_SYS_STUB_SO)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(KERNEL_SYS_STUB_SO) $(LIBS)
	$(PS5_PAYLOAD_SDK)/bin/prospero-strip --strip-all $@

$(KERNEL_SYS_STUB_SO): $(KERNEL_SYS_STUB_SRCS)
	test -f "$(PS5_SCE_STUBS_DIR)/libkernel_sys.c"
	$(CC) -shared -Wl,-soname=libkernel_sys.sprx -o $@ $^

src/notify_icon_asset.c: smp_icon.png
	xxd -i $< > $@

src/config_ini_example_asset.c: config.ini.example
	xxd -i $< > $@

src/web_index_asset.c: web/index.html
	xxd -i $< > $@

src/shell_icon_param_asset.c: assets/shell_icon_param.json
	xxd -i $< > $@

src/sm_api_service.o src/sm_icon_thumb.o src/sm_gameinfo.o: CFLAGS += $(HOMEBREW_CFLAGS)
src/main.o src/sm_image_index.o: CFLAGS += -DSHADOWMOUNT_BUILD_TIME=\"$(BUILD_TIME)\"
src/main.o src/sm_image_index.o: FORCE

src/sm_l10n.o: $(L10N_CATALOGS)
src/sm_ampr_updater.o: src/sm_ampr_ca.inc
src/sm_shellcore_offsets.o: src/sm_shellcore_offsets.inc

.PHONY: FORCE
FORCE:

src/%.o: src/%.c $(HEADERS)
	$(CC) $(CFLAGS) -c -o $@ $<

src/%.o: src/%.S
	$(CC) $(CFLAGS) -c -o $@ $<

# VERSION_TAG reaches the code as a COMMAND-LINE macro, so nothing in the
# dependency graph moves when `git describe` does: a new commit leaves main.o
# alone and the banner then names the wrong build. Measured 2026-09-14 -- the
# console reported 1.6-6-ge19189 while running 26fa77c's code, which is the one
# thing we identify a deployed build by. The stamp carries the tag and is
# rewritten only when it actually changes, so the three objects that embed it
# rebuild exactly when they must and incremental builds stay incremental.
.PHONY: force
src/version_tag.stamp: force
	@printf '%s' '$(VERSION_TAG)' | cmp -s - $@ || printf '%s' '$(VERSION_TAG)' > $@

src/main.o src/sm_log.o src/sm_env_ipmi.o: src/version_tag.stamp

clean:
	rm -f shadowmountplus.elf usb-info.elf api-test.elf kill.elf src/*.o src/version_tag.stamp $(KERNEL_SYS_STUB_SO) $(ASSET_SRCS)
