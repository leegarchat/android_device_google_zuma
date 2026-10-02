#!/system/bin/sh
# SukiSU manager one-shot installer (user app, NOT a system app).
#
# Runs once per boot as an init oneshot service (root uid, shell SELinux
# domain via the stock init->shell transition) triggered on
# sys.boot_completed=1. Installs the bundled manager APK via PackageManager
# (silent, same path as `adb install`) and records a versioned flag file so
# it never reinstalls (e.g. after the user uninstalls it on purpose).
#
# Layout on device (read-only, from the build):
#   /system/etc/sukisu/*.apk   — exactly ONE manager APK, named <label>_<vercode>.apk
# Writable state:
#   /data/local/tmp/sukisu/manager_<vercode>.installed — flag file
#   /data/local/tmp/sukisu_manager_install.apk         — staging copy for pm
#
# Exit 0 = nothing to do (or done); exit 1 = install failed, retry next boot
# (no flag is written, so the next boot_completed trigger retries).

TAG="sukisu-install"
PKG="com.sukisu.ultra"
APK_DIR="/system/etc/sukisu"
STAGE="/data/local/tmp/sukisu_manager_install.apk"
FLAG_DIR="/data/local/tmp/sukisu"

log() {
    echo "$TAG: $*"
}

is_installed() {
    pm list packages "$PKG" 2>/dev/null | grep -qx "package:$PKG"
}

# Exactly one bundled APK, named <anything>_<vercode>.apk
# (e.g. SukiSU_40900.apk). The vercode versions the flag file, so shipping
# a newer manager later reinstalls exactly once.
APK=""
VER=""
for f in "$APK_DIR"/*.apk; do
    [ -f "$f" ] || continue
    if [ -n "$APK" ]; then
        log "more than one APK in $APK_DIR, using first match: $APK"
        break
    fi
    APK="$f"
done
if [ -z "$APK" ]; then
    log "no bundled APK in $APK_DIR, nothing to do"
    exit 0
fi
base="${APK##*/}"
VER="${base##*_}"
VER="${VER%.apk}"
case "$VER" in
    ''|*[!0-9]*)
        log "cannot parse vercode from $base, refusing to install"
        exit 1
        ;;
esac
FLAG="$FLAG_DIR/manager_${VER}.installed"

if [ -f "$FLAG" ]; then
    log "already handled (flag $FLAG present), nothing to do"
    exit 0
fi

# Manager already present (side-loaded newer build, restored backup, ...):
# respect it, just record the flag so we never fight the user.
if is_installed; then
    log "package $PKG already present, recording flag"
    mkdir -p "$FLAG_DIR" && echo "$PKG $VER" > "$FLAG"
    exit 0
fi

log "installing $PKG from $APK (vercode $VER)"
mkdir -p "$FLAG_DIR" || exit 1
cp "$APK" "$STAGE" 2>/dev/null || {
    log "staging copy failed"
    exit 1
}

if pm install -r "$STAGE" 2>&1; then
    rm -f "$STAGE"
    if is_installed; then
        echo "$PKG $VER" > "$FLAG"
        log "install OK, flag written"
        exit 0
    fi
    log "pm reported success but package missing afterwards"
else
    log "pm install failed"
fi

rm -f "$STAGE"
log "will retry on next boot"
exit 1
