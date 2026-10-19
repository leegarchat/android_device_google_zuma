#!/system/bin/sh
# SukiSU manager one-shot installer (user app, NOT a system app).
#
# Runs as an init oneshot service (root uid, shell SELinux domain via the
# stock init->shell transition) triggered on sys.boot_completed=1.
# Installs the bundled manager APK via PackageManager (silent, same path as
# `adb install`). State is a single Settings.Global key holding the last
# HANDLED vercode, so repeats are no-ops and a deliberate user uninstall
# is respected (key stays == VER, script exits).
#
# Layout on device (read-only, from the build):
#   /system/etc/sukisu/*.apk   — exactly ONE manager APK, named <label>_<vercode>.apk
# State:
#   Settings.Global sukisu_manager_handled_vercode — last handled vercode
#   /data/local/tmp/sukisu_manager_install.apk     — staging copy for pm
#
# Exit 0 = nothing to do (or done); exit 1 = install failed, retry next boot
# (key is left untouched, so the next boot_completed trigger retries).

TAG="sukisu-install"
PKG="com.resukisu.resukisu"
KEY="sukisu_manager_handled_vercode"
APK_DIR="/system/etc/sukisu"
STAGE="/data/local/tmp/sukisu_manager_install.apk"

log() {
    echo "$TAG: $*"
    # Mirror to logcat: stdio_to_kmsg goes only to the kernel buffer
    # (unreadable without root), this line is visible via `logcat -s`.
    log -p i -t "$TAG" "$*" 2>/dev/null
}

is_installed() {
    pm list packages "$PKG" 2>/dev/null | grep -qx "package:$PKG"
}

installed_ver() {
    dumpsys package "$PKG" 2>/dev/null | grep -m1 'versionCode=' | sed 's/.*versionCode=\([0-9][0-9]*\).*/\1/'
}

mark_handled() {
    if settings put global "$KEY" "$VER" 2>/dev/null; then
        return 0
    fi
    log "failed to record $KEY=$VER, will retry next boot"
    return 1
}

# Exactly one bundled APK, named <anything>_<vercode>.apk
# (e.g. SukiSU_35171.apk). The vercode is compared against both the
# Settings key and the installed package versionCode.
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

HANDLED="$(settings get global "$KEY" 2>/dev/null)"
case "$HANDLED" in
    null|"") HANDLED="" ;;
esac

if [ "$HANDLED" = "$VER" ]; then
    log "already handled (global $KEY=$VER), nothing to do"
    exit 0
fi

INST_VER="$(installed_ver)"
case "$INST_VER" in
    ''|*[!0-9]*) INST_VER="" ;;
esac

# Same version already on device (side-load, backup restore, ...):
# just record it, don't reinstall.
if [ -n "$INST_VER" ] && [ "$INST_VER" = "$VER" ]; then
    log "package $PKG $VER already present, recording"
    mark_handled
    exit $?
fi

# Newer version already on device: never downgrade, just record.
if [ -n "$INST_VER" ] && [ "$INST_VER" -gt "$VER" ] 2>/dev/null; then
    log "package $PKG $INST_VER newer than bundled $VER, keeping it"
    mark_handled
    exit $?
fi

if [ -n "$INST_VER" ]; then
    log "updating $PKG $INST_VER -> $VER from $APK"
else
    log "installing $PKG from $APK (vercode $VER)"
fi

cp "$APK" "$STAGE" 2>/dev/null || {
    log "staging copy failed"
    exit 1
}

if pm install -r "$STAGE" 2>&1; then
    rm -f "$STAGE"
    if is_installed; then
        log "install OK"
        mark_handled
        exit $?
    fi
    log "pm reported success but package missing afterwards"
else
    log "pm install failed"
fi

rm -f "$STAGE"
log "will retry on next boot"
exit 1
