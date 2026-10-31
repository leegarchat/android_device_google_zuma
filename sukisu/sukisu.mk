# SukiSU dev-manager one-shot installer (zuma family: akita/husky/shiba).
#
# Included from device/google/zuma/common.mk. Active ONLY for custom kernels
# whose prebuilt directory name mentions ksu (case-insensitive), e.g.
#   device/google/pixel-kernels/shiba_wksu21
#   device/google/pixel-kernels/husky-cp3a-261005
# Stock kernels (no ksu in the name) get nothing: no files, no service.
#
# What lands in the build (only in the ksu case):
#   /system/etc/sukisu/<manager>.apk   — INERT copy, NOT a system app
#   /system/etc/sukisu/install_manager.sh — installer script
#   /vendor/etc/init/init.sukisu_manager.rc — oneshot service + boot trigger
#
# Flavor switching (stable <-> dev) is purely version-driven: the tree
# holds exactly one APK (stable ReSukiSU_<ver>.apk or dev
# ReSukiSU_dev_<ver>.apk, enforced at build time); the installer detects
# the flavor from the filename and makes it the active manager.

# TARGET_KERNEL_DIR is already resolved by the device makefiles
# (device-*.mk) before zuma/common.mk includes this file.
_SUKISU_KERNEL_LC := $(shell echo "$(TARGET_KERNEL_DIR)" | tr 'A-Z' 'a-z')

ifneq ($(findstring ksu,$(_SUKISU_KERNEL_LC)),)
# NOTE: no $(info)/$(warning) here — release-config parser chokes on them
# during 'pre product config' phase.

# Exactly one manager APK lives in sukisu/ (stable ReSukiSU_<ver>.apk or
# dev ReSukiSU_dev_<ver>.apk); the installer detects the flavor from the
# filename. Two files = ambiguous, fail loudly.
_SUKISU_APKS := $(wildcard device/google/zuma/sukisu/*.apk)
ifneq ($(words $(_SUKISU_APKS)),1)
$(error sukisu: expected exactly one APK in device/google/zuma/sukisu, found: $(_SUKISU_APKS))
endif

PRODUCT_COPY_FILES += \
    $(_SUKISU_APKS):$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/$(notdir $(_SUKISU_APKS)) \
    device/google/zuma/sukisu/install_manager.sh:$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/install_manager.sh \
    device/google/zuma/sukisu/init.sukisu_manager.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.sukisu_manager.rc

else
endif
