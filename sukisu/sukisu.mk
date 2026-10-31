# SukiSU dev-manager one-shot installer (zuma family: akita/husky/shiba).
#
# Included from device/google/zuma/common.mk. Active ONLY for custom kernels
# whose prebuilt directory name mentions ksu (case-insensitive), e.g.
#   device/google/pixel-kernels/shiba_wksu21
#   device/google/pixel-kernels/husky-cp3a-261005
# Stock kernels (no ksu in the name) get nothing: no files, no service.
#
# What lands in the build (only in the ksu case):
#   /system/etc/sukisu/ReSukiSU_dev_<vercode>.apk — INERT copy, NOT a system app
#   /system/etc/sukisu/install_manager.sh          — installer script
#   /vendor/etc/init/init.sukisu_manager.rc        — oneshot service + boot trigger
#
# How it works: after every boot_completed the service runs the script as
# root in the ksu domain and silently installs the DEV manager
# (com.resukisu.resukisu.dev) via `pm install` (same path as `adb
# install`). A Settings.Global key holding the last handled vercode
# prevents repeats, so a deliberate user uninstall is respected; shipping
# a newer APK (new vercode in the filename) reinstalls exactly once.
# The script also migrates settings from the legacy manager
# (com.resukisu.resukisu, same DataStore proto incl. themes) and then
# uninstalls it — two KSU managers cannot coexist.
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
    device/google/zuma/sukisu/ReSukiSU_dev_35260.apk:$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/ReSukiSU_dev_35260.apk \
    device/google/zuma/sukisu/install_manager.sh:$(TARGET_COPY_OUT_SYSTEM)/etc/sukisu/install_manager.sh \
    device/google/zuma/sukisu/init.sukisu_manager.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.sukisu_manager.rc

else
endif
