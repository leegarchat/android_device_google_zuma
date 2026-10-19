# SukiSU manager one-shot installer (zuma family: akita/husky/shiba).
#
# Included from device/google/zuma/common.mk. Active ONLY for custom kernels
# whose prebuilt directory name mentions ksu (case-insensitive), e.g.
#   device/google/pixel-kernels/shiba_cp2a_005_wksu_avgust
#   device/google/pixel-kernels/husky_cp2a_005_wksu_sukisu_september
# Stock kernels (no ksu in the name) get nothing: no files, no service.
#
# What lands in the build (only in the ksu case):
#   /system/etc/sukisu/SukiSU_<vercode>.apk  — INERT copy, NOT a system app
#   /system/etc/sukisu/install_manager.sh    — installer script
#   /vendor/etc/init/init.sukisu_manager.rc  — oneshot service + boot trigger
#
# How it works: after every boot_completed the service runs the script as
# root-in-shell-domain and silently installs the manager via `pm install`
# (same path as `adb install`). A versioned flag file
# /data/local/tmp/sukisu/manager_<vercode>.installed prevents repeats, so a
# deliberate user uninstall is respected; shipping a newer APK (new vercode
# in the filename) reinstalls exactly once.
#
# Bumping the manager: replace the .apk (keep the <label>_<vercode>.apk
# naming — the script parses vercode from the filename), nothing else.

# TARGET_KERNEL_DIR is already resolved by the device makefiles
# (device-*.mk) before zuma/common.mk includes this file.
_SUKISU_KERNEL_LC := $(shell echo "$(TARGET_KERNEL_DIR)" | tr 'A-Z' 'a-z')

ifneq ($(findstring ksu,$(_SUKISU_KERNEL_LC)),)
# NOTE: no $(info)/$(warning) here — release-config parser chokes on them
# during 'pre product config' phase.

PRODUCT_COPY_FILES += \
    device/google/zuma/sukisu/ReSukiSU_35061.apk:$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/ReSukiSU_35061.apk \
    device/google/zuma/sukisu/install_manager.sh:$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/install_manager.sh \
    device/google/zuma/sukisu/init.sukisu_manager.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.sukisu_manager.rc

else
endif
