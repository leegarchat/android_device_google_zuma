#!/system/bin/sh
# SukiSU dev-manager one-shot installer (user app, NOT a system app).
#
# Runs as an init oneshot service (root, ksu SELinux domain, see
# init.sukisu_manager.rc) triggered on sys.boot_completed=1.
#
# What it does, in order:
#   1. Installs/updates the bundled DEV manager (com.resukisu.resukisu.dev)
#      via PackageManager (silent, same path as `adb install`).
#   2. Migrates settings from the legacy manager (com.resukisu.resukisu):
#      both use the same DataStore proto (files/datastore/
#      app_preferences.preferences_pb, same keys incl. themes), so the file
#      is copied, re-owned and relabeled. Only when the legacy file exists
#      and the new one is missing or differs; both apps are force-stopped
#      first so no live process rewrites it mid-copy.
#   3. Uninstalls the legacy manager — two KSU managers cannot coexist
#      (conflicting su handling).
#
# State is a single Settings.Global key holding the last HANDLED vercode,
# so repeats are no-ops and a deliberate user uninstall of the NEW manager
# is respected (key stays == VER, script exits). The legacy manager is
# removed whenever present once the new one is OK, even if already handled.
#
# Layout on device (read-only, from the build):
#   /system/etc/sukisu/*.apk   — exactly ONE manager APK, named <label>_<vercode>.apk
# State:
#   Settings.Global sukisu_manager_dev_handled_vercode — last handled vercode
#   /data/local/tmp/sukisu_manager_install.apk         — staging copy for pm
#
# Exit 0 = nothing to do (or done); exit 1 = something failed, retry next
# boot (the handled key is left untouched on install failure, so the next
# boot_completed trigger retries).

TAG="sukisu-install"
PKG="com.resukisu.resukisu.dev"
OLD_PKG="com.resukisu.resukisu"
KEY="sukisu_manager_dev_handled_vercode"
APK_DIR="/system/etc/sukisu"
STAGE="/data/local/tmp/sukisu_manager_install.apk"
PROTO="files/datastore/app_preferences.preferences_pb"

log() {
    echo "$TAG: $*"
    # Mirror to logcat: stdio_to_kmsg goes only to the kernel buffer
    # (unreadable without root), this line is visible via `logcat -s`.
    command -p /system/bin/log -p i -t "$TAG" "$*" 2>/dev/null || true
}

is_installed() {
    pm list packages "$1" 2>/dev/null | grep -qx "package:$1"
}

installed_ver() {
    dumpsys package "$1" 2>/dev/null | grep -m1 'versionCode=' | sed 's/.*versionCode=\([0-9][0-9]*\).*/\1/'
}

mark_handled() {
    if settings put global "$KEY" "$VER" 2>/dev/null; then
        return 0
    fi
    log "failed to record $KEY=$VER, will retry next boot"
    return 1
}

pkg_uid() {
    # Owner uid of the app data dir; empty if never installed.
    stat -c %u "/data/user/0/$1" 2>/dev/null
}

# Exactly one bundled APK, named <anything>_<vercode>.apk
# (e.g. ReSukiSU_dev_35260.apk). The vercode is compared against both the
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

# --- Step 1: reconcile the NEW manager ---
if [ "$HANDLED" = "$VER" ]; then
    if is_installed "$PKG"; then
        log "already handled (global $KEY=$VER), nothing to do"
    else
        log "handled $VER but $PKG missing (user uninstall?), respecting it"
    fi
else
    INST_VER="$(installed_ver "$PKG")"
    case "$INST_VER" in
        ''|*[!0-9]*) INST_VER="" ;;
    esac

    # Same version already on device (side-load, backup restore, ...):
    # just record it, don't reinstall.
    if [ -n "$INST_VER" ] && [ "$INST_VER" = "$VER" ]; then
        log "package $PKG $VER already present, recording"
        mark_handled || exit 1
    # Newer version already on device: never downgrade, just record.
    elif [ -n "$INST_VER" ] && [ "$INST_VER" -gt "$VER" ] 2>/dev/null; then
        log "package $PKG $INST_VER newer than bundled $VER, keeping it"
        mark_handled || exit 1
    else
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
            if is_installed "$PKG"; then
                log "install OK"
                mark_handled || exit 1
            else
                log "pm reported success but package missing afterwards"
            fi
        else
            log "pm install failed"
        fi
        rm -f "$STAGE"
    fi
fi

if ! is_installed "$PKG"; then
    if [ "$HANDLED" = "$VER" ]; then
        log "new manager absent by user choice, legacy cleanup only"
    else
        log "new manager not installed, keeping legacy for now; retry next boot"
        exit 1
    fi
fi

# --- Step 2: migrate settings legacy -> new ---
OLD_PROTO="/data/user/0/$OLD_PKG/$PROTO"
NEW_PROTO="/data/user/0/$PKG/$PROTO"
if [ -f "$OLD_PROTO" ]; then
    if [ ! -f "$NEW_PROTO" ] || ! cmp -s "$OLD_PROTO" "$NEW_PROTO"; then
        log "migrating settings $OLD_PKG -> $PKG"
        am force-stop "$OLD_PKG" 2>/dev/null
        am force-stop "$PKG" 2>/dev/null
        UID="$(pkg_uid "$PKG")"
        if [ -z "$UID" ]; then
            log "no data dir for $PKG yet, skipping migration"
        else
            mkdir -p "/data/user/0/$PKG/files/datastore" 2>/dev/null
            # mkdir as root leaves root-owned dirs (no MLS categories) that
            # the app cannot write to — re-own the whole files/ subtree.
            chown -R "$UID:$UID" "/data/user/0/$PKG/files" 2>/dev/null
            restorecon -R "/data/user/0/$PKG/files" 2>/dev/null
            if cp "$OLD_PROTO" "$NEW_PROTO" 2>/dev/null \
                    && chown "$UID:$UID" "$NEW_PROTO" 2>/dev/null \
                    && chmod 600 "$NEW_PROTO" 2>/dev/null; then
                restorecon -R "/data/user/0/$PKG/files/datastore" 2>/dev/null
                if cmp -s "$OLD_PROTO" "$NEW_PROTO"; then
                    log "settings migrated OK"
                else
                    log "settings copy verify failed"
                fi
            else
                log "settings copy failed"
            fi
        fi
    else
        log "settings already in sync, nothing to migrate"
    fi
else
    log "no legacy settings found, nothing to migrate"
fi

# --- Step 3: remove the legacy manager (cannot coexist) ---
if is_installed "$OLD_PKG"; then
    log "removing legacy manager $OLD_PKG"
    if pm uninstall "$OLD_PKG" 2>&1; then
        if is_installed "$OLD_PKG"; then
            log "uninstall reported success but package still present, retry next boot"
            exit 1
        fi
        log "legacy manager removed"
    else
        log "legacy uninstall failed, retry next boot"
        exit 1
    fi
else
    log "no legacy manager installed"
fi

exit 0
